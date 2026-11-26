//! Saving a document as Word (.docx) or OpenDocument (.odt) with the Pencil drawings made over
//! its pages.
//!
//! A document the engine made the pages of (Word, ODT, RTF, text…) is opened again and laid out
//! as its PDF was. The app gives each group of strokes drawn close together (a signature, a note,
//! a circle round a word) as one picture with a see-through background, and each picture is
//! anchored to the text it was drawn on: the nearest paragraph that starts on that page, or the
//! table cell it is in, at the offsets that put it exactly where it was drawn. Word, LibreOffice
//! or a phone may lay the text out differently (other fonts, other page breaks); a signature then
//! moves with its line instead of staying at a place on the page over other text.
//!
//! In a Word file the offsets count from the start of the paragraph and from the column: the
//! only way iPhone and Mac previews (Quick Look: Files, Mail, WhatsApp) keep a picture with its
//! text. They show the document as one long page and put any other picture by its offsets from
//! the top of the whole document, so a signature anchored the usual way ended up near the top.
//!
//! The document keeps its own fonts: the Armenian fonts the PDF uses in their place only serve to
//! find where the lines were in the app. Old ArmSCII text is turned into Unicode as for the PDF.
//!
//! Pages that have no text to put drawings on (pages added in the app, PDF pages, photos and
//! scans) come from the app as pictures with the ink drawn in and become whole pages: after the
//! text, or the whole document when there is no text.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::Value;
use wordcraft_doc::numbering::Level;
use wordcraft_doc::para::{Anchor, COLUMN_BREAK, Float, PAGE_BREAK, Wrap};
use wordcraft_doc::section::{NumFormat, SectionStart};
use wordcraft_doc::{CharProps, Document, InlineObject, Paragraph, Pos, SectionProps, StoryRef};
use wordcraft_engine::layout::{DocLayout, LayoutCache, LayoutOptions, LineEnd, Placed};
use wordcraft_geom::{Point, Rect};

use crate::{Options, Report, prepare};

/// The lowest stacking order a floating object read from a Word file has (`Float::z` is one more
/// than its `relativeHeight`, which starts at 251658240 for objects made in Word).
const FIRST_STORED_Z: u32 = 251_658_241;
/// Pictures larger than this are not read.
const MAX_PICTURE: u64 = 64 << 20;
/// Pages and drawings one request may carry.
const MAX_PAGES: usize = 2_000;
const MAX_DRAWINGS: usize = 5_000;
/// The largest side of a drawing or a page, points.
const MAX_SIDE: f32 = 4_000.0;
/// How much farther than the nearest text a paragraph that starts on the page may be and still
/// hold a drawing, and how far below the paragraph's top the drawing's middle may be (points).
/// Farther, the drawing is placed on the page by the nearest line instead: an offset that large
/// from a paragraph would carry the drawing off the page when other fonts move the paragraph.
const PARAGRAPH_REACH: f32 = 48.0;
const PARAGRAPH_DEPTH: f32 = 160.0;

/// A drawing: a picture (PNG with a see-through background) laid over page `page` at (`x`, `y`),
/// `w` × `h` points, from the page's top left corner.
#[derive(Clone, Debug)]
pub struct Drawing {
    /// Page index, from 0, in the document's PDF.
    pub page: usize,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub path: PathBuf,
    /// Behind the text (highlighter marks), else in front of it.
    pub behind: bool,
}

/// A page given as a picture (PNG or JPEG), `w` × `h` points.
#[derive(Clone, Debug)]
pub struct PagePicture {
    pub path: PathBuf,
    pub w: f32,
    pub h: f32,
}

#[derive(Clone, Debug, Default)]
pub struct ExportRequest {
    /// The original file; `None` makes a document of `pictures` only.
    pub input: Option<PathBuf>,
    /// `.docx` or `.odt` (the extension picks the format).
    pub output: PathBuf,
    pub drawings: Vec<Drawing>,
    /// Pages added after the document's own pages (or all pages, without `input`).
    pub pictures: Vec<PagePicture>,
    /// Title for a document made of pictures.
    pub title: String,
}

/// What an export did.
#[derive(Debug, Default)]
pub struct ExportReport {
    /// Pages of the original document as laid out (0 without one).
    pub pages: usize,
    /// Drawings put on the pages.
    pub drawings: usize,
    /// Of them, those placed on the page by a word of a paragraph that began on an earlier page,
    /// and those anchored in a table cell.
    pub on_pages: usize,
    pub in_cells: usize,
    /// Pages whose drawings could not be put on them (no such page, or no text there to hold them).
    pub skipped_pages: Vec<usize>,
    pub pictures: usize,
    /// The Armenian fixes made to the saved text.
    pub fixes: Report,
}

impl ExportRequest {
    /// From the app's JSON (see `hd_export`).
    pub fn from_json(v: &Value) -> Result<ExportRequest, String> {
        let output = v
            .get("output")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or("output is required")?;
        let input = v
            .get("input")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(PathBuf::from);
        let drawings = v
            .get("drawings")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .take(MAX_DRAWINGS)
                    .filter_map(drawing_from_json)
                    .collect()
            })
            .unwrap_or_default();
        let pictures = v
            .get("pictures")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .take(MAX_PAGES)
                    .filter_map(|p| {
                        let path = p.get("path").and_then(Value::as_str)?;
                        let w = p.get("width").and_then(Value::as_f64)? as f32;
                        let h = p.get("height").and_then(Value::as_f64)? as f32;
                        (w.is_finite() && h.is_finite() && w >= 1.0 && h >= 1.0).then(|| {
                            PagePicture {
                                path: PathBuf::from(path),
                                w: w.min(1584.0),
                                h: h.min(1584.0),
                            }
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let title = v
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        Ok(ExportRequest {
            input,
            output: PathBuf::from(output),
            drawings,
            pictures,
            title,
        })
    }
}

fn drawing_from_json(v: &Value) -> Option<Drawing> {
    let page = usize::try_from(v.get("page")?.as_u64()?).ok()?;
    let num = |key: &str| {
        v.get(key)
            .and_then(Value::as_f64)
            .map(|n| n as f32)
            .filter(|n| n.is_finite())
    };
    let (x, y, w, h) = (num("x")?, num("y")?, num("width")?, num("height")?);
    let path = v
        .get("path")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())?;
    let behind = v.get("behind").and_then(Value::as_bool).unwrap_or(false);
    (w >= 0.1 && h >= 0.1).then(|| Drawing {
        page,
        x: x.clamp(-MAX_SIDE, MAX_SIDE),
        y: y.clamp(-MAX_SIDE, MAX_SIDE),
        w: w.min(MAX_SIDE),
        h: h.min(MAX_SIDE),
        path: PathBuf::from(path),
        behind,
    })
}

/// Make the document `req` asks for and write it.
pub fn export(req: &ExportRequest, opts: &Options) -> Result<ExportReport, String> {
    let name = req.output.to_string_lossy().to_string();
    let ext = name
        .rsplit('.')
        .next()
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !matches!(ext.as_str(), "docx" | "odt") {
        return Err(format!("{name}: only .docx and .odt are made here"));
    }
    let mut report = ExportReport::default();
    let mut doc = match &req.input {
        Some(input) => {
            let region = wordcraft_geom::Region::from_tag(&opts.region);
            let (mut doc, _) =
                wordcraft_engine::io::open_path_in(input, opts.password.as_deref(), &region)?;
            // The text as the app shows it (ArmSCII turned into Unicode), in the document's fonts.
            report.fixes = prepare(
                &mut doc,
                &Options {
                    armenian_fallback: false,
                    ..opts.clone()
                },
            );
            doc
        }
        None => {
            let mut doc = Document::new();
            doc.core.title = req.title.clone();
            doc
        }
    };

    if req.input.is_some() {
        // Laid out as the app's PDF is: with the Armenian fonts in place of those without
        // Armenian letters. That changes fonts only, so places in the text stay the same.
        let shown = Options {
            armscii: false,
            ..opts.clone()
        };
        let lay = |d: &Document| {
            let mut d = d.clone();
            prepare(&mut d, &shown);
            pdf_layout(&d)
        };
        let layout = lay(&doc);
        report.pages = layout.pages.len();
        put_drawings(
            &mut doc,
            &layout,
            &req.drawings,
            &lay,
            ext == "docx",
            &mut report,
        );
    } else {
        report.skipped_pages = pages_of(&req.drawings);
    }

    report.pictures = add_picture_pages(&mut doc, &req.pictures, req.input.is_none())?;
    if ext == "odt" {
        keep_normal_font(&mut doc);
        plain_bullets(&mut doc);
    }
    let bytes = wordcraft_engine::io::save_bytes(&format!("document.{ext}"), &doc)?;
    std::fs::write(&req.output, bytes).map_err(|e| format!("{}: {e}", req.output.display()))?;
    Ok(report)
}

/// The ODT writer gives the default paragraph style ("Standard") the document defaults' font, so
/// a font set on Normal itself (the usual way: "GHEA Grapalat" for a whole document) would be
/// lost and the text shown in the theme font. Normal's font becomes the defaults' font.
fn keep_normal_font(doc: &mut Document) {
    let normal = doc.styles.resolve_char(None, &CharProps::default()).font;
    if !normal.trim().is_empty() && doc.styles.default_chr.font.as_deref() != Some(normal.as_str())
    {
        Arc::make_mut(&mut doc.styles).default_chr.font = Some(normal);
    }
}

/// Bullets in symbol fonts (Word's round bullet is U+F0B7 in Symbol, its square one U+F0A7 in
/// Wingdings) become the Unicode characters they show, in the text's font. The ODT writer keeps
/// a bullet's character but not its font, so those characters would show as empty boxes.
fn plain_bullets(doc: &mut Document) {
    fn fix(level: &mut Level) {
        if level.format != NumFormat::Bullet {
            return;
        }
        let mut chars = level.text.chars();
        let (Some(c), None) = (chars.next(), chars.next()) else {
            return;
        };
        let font = level
            .chr
            .font
            .as_deref()
            .unwrap_or_default()
            .to_ascii_lowercase();
        let symbol_font =
            font.contains("symbol") || font.contains("wingdings") || font.contains("webdings");
        let code = c as u32;
        // Symbol fonts have their signs at U+F020-U+F0FF, or at the plain 8-bit code.
        let low = match code {
            0xF020..=0xF0FF => code - 0xF000,
            0x20..=0xFF if symbol_font => code,
            _ => return,
        };
        let plain = if font.contains("wingdings") {
            match low {
                0x6C => '●',
                0x6E => '■',
                0x71 => '❑',
                0x75 => '◆',
                0x76 => '❖',
                0x9F => '•',
                0xA7 => '▪',
                0xA8 => '◻',
                0xD8 => '➢',
                0xE0 => '➔',
                0xFB => '✗',
                0xFC => '✓',
                _ => '•',
            }
        } else if font.contains("symbol") {
            match low {
                0x2D => '−',
                0xA7 => '♣',
                0xA8 => '♦',
                0xA9 => '♥',
                0xAA => '♠',
                0xAE => '→',
                0xDE => '⇒',
                _ => '•',
            }
        } else {
            '•'
        };
        level.text = plain.to_string();
        level.chr.font = None;
        level.chr.sym_font = None;
    }
    let numbering = Arc::make_mut(&mut doc.numbering);
    for list in &mut numbering.abstracts {
        list.levels.iter_mut().for_each(fix);
    }
    for num in &mut numbering.nums {
        num.level_overrides
            .iter_mut()
            .for_each(|(_, level)| fix(level));
    }
}

/// The document laid out as its PDF is: printed pages, final text, field results as printed.
pub fn pdf_layout(doc: &Document) -> DocLayout {
    let opts = LayoutOptions {
        hide_deleted: true,
        output_page_refs: true,
        ..Default::default()
    };
    // The fields as printed, when that changes no paragraphs (the drawings go into `doc`).
    let printed = wordcraft_engine::cmd::references::output_fields(doc)
        .filter(|d| d.paragraph_count() == doc.paragraph_count());
    wordcraft_engine::layout::layout(
        printed.as_ref().unwrap_or(doc),
        &mut LayoutCache::new(),
        &opts,
    )
}

fn pages_of(drawings: &[Drawing]) -> Vec<usize> {
    let mut pages: Vec<usize> = drawings.iter().map(|d| d.page).collect();
    pages.sort_unstable();
    pages.dedup();
    pages
}

/// Where a drawing is anchored and how its offsets count.
#[derive(Clone, Debug)]
struct Anchoring {
    /// Where the picture's U+FFFC goes: a paragraph's start, or a word in it.
    pos: Pos,
    h_rel: Anchor,
    v_rel: Anchor,
    /// Where the offsets start on the page, as far as the layout's lines tell (the second
    /// layout corrects it).
    origin: (f32, f32),
    in_cell: bool,
}

/// Lines `l0..l1` of a body paragraph on a page, and the area they cover.
struct Fragment<'a> {
    path: &'a wordcraft_doc::Path,
    para: &'a wordcraft_engine::layout::ParaLayout,
    l0: usize,
    l1: usize,
    /// Column left and the top of line `l0`.
    x: f32,
    y: f32,
    /// The lines' room: from the leftmost line's left edge to the rightmost's right, from the
    /// first line's top to the last one's bottom.
    area: Rect,
}

impl Fragment<'_> {
    /// Whether the paragraph begins here.
    fn starts(&self) -> bool {
        self.l0 == 0
    }
    fn in_cell(&self) -> bool {
        self.path.depth() > 0
    }
    /// The table cell it is in: its table's path, row and cell (`None` outside tables).
    fn cell(&self) -> Option<(&[u32], u32, u32)> {
        let p = &self.path.0;
        (p.len() >= 4).then(|| (&p[..p.len() - 3], p[p.len() - 3], p[p.len() - 2]))
    }
    /// Top of line `li` on the page.
    fn line_top(&self, li: usize) -> f32 {
        let first = self.para.lines.get(self.l0).map_or(0.0, |l| l.top);
        self.y + self.para.lines.get(li).map_or(0.0, |l| l.top - first)
    }
}

/// The body paragraphs' lines on page `page`. Left out: turned table text, and a paragraph's
/// lines that hold nothing but a page or column break (a paragraph that begins with a break
/// begins after it in Word and LibreOffice, on the next page).
fn fragments<'a>(layout: &'a DocLayout, doc: &Document, page: usize) -> Vec<Fragment<'a>> {
    let Some(pg) = layout.pages.get(page) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for item in &pg.items {
        let Placed::Lines {
            story: StoryRef::Body,
            path,
            para,
            l0,
            l1,
            x,
            y,
            turn,
        } = item
        else {
            continue;
        };
        if turn.is_turned() || l1 <= l0 {
            continue;
        }
        let Some(lines) = para.lines.get(*l0..*l1) else {
            continue;
        };
        let text = doc
            .para(StoryRef::Body, path)
            .map(|p| p.text.as_str())
            .unwrap_or_default();
        let only_break = |l: &wordcraft_engine::layout::para::Line| {
            matches!(l.end, LineEnd::PageBreak | LineEnd::ColumnBreak)
                && text.get(l.start..l.stop).is_some_and(|t| {
                    t.chars()
                        .all(|c| c.is_whitespace() || c == PAGE_BREAK || c == COLUMN_BREAK)
                })
        };
        if lines.iter().all(only_break) {
            continue;
        }
        let (first, last) = (&lines[0], &lines[lines.len() - 1]);
        let left = lines.iter().map(|l| l.left).fold(f32::INFINITY, f32::min);
        let right = lines
            .iter()
            .map(|l| l.right)
            .fold(f32::NEG_INFINITY, f32::max);
        let height = (last.top + last.height - first.top).max(0.0);
        let area = Rect::new(x + left, *y, (right - left).max(0.0), height);
        out.push(Fragment {
            path,
            para,
            l0: *l0,
            l1: *l1,
            x: *x,
            y: *y,
            area,
        });
    }
    out
}

/// Distance from point `c` to rectangle `r` (0 inside it).
fn distance(r: &Rect, c: Point) -> f32 {
    let dx = (r.x - c.x).max(c.x - r.right()).max(0.0);
    let dy = (r.y - c.y).max(c.y - r.bottom()).max(0.0);
    dx.hypot(dy)
}

/// Where drawing `d` is anchored on its page: in the table cell it lies in, else to the body text
/// outside tables; to the nearest paragraph that starts on the page, its offsets counted from the
/// paragraph's top, else (only the middle of a long paragraph near) to a word on the nearest line,
/// placed on the page.
///
/// `quick_look` (Word files): the way iPhone and Mac previews show Word files (Files, Mail,
/// WhatsApp; Apple's Quick Look) is taken into account too. Quick Look places a picture whose
/// across offset counts from the column where its paragraph's first line starts, moved by the
/// two offsets; any other picture it places by its offsets from the top of the whole document,
/// whatever they count from. So a Word file's drawing is anchored at the start of a paragraph,
/// across from the column, never on the page; preferably a paragraph Quick Look starts where
/// Word does (see [`quick_look_cost`]).
fn anchor_for(
    layout: &DocLayout,
    doc: &Document,
    d: &Drawing,
    quick_look: bool,
) -> Option<Anchoring> {
    let pg = layout.pages.get(d.page)?;
    let frags = fragments(layout, doc, d.page);
    if frags.is_empty() {
        return None;
    }
    let c = Point::new(d.x + d.w / 2.0, d.y + d.h / 2.0);
    // The innermost table cell the drawing lies in. One that reaches out of its cell is anchored
    // outside the table: a drawing anchored in a cell is kept inside it (LibreOffice moves it in,
    // and Word 2013 and later lay a cell's drawings out in the cell whatever the file says).
    let drawn = Rect::new(d.x, d.y, d.w, d.h);
    let cell = pg
        .items
        .iter()
        .filter_map(|it| match it {
            Placed::Cell {
                rect,
                covered: false,
                table,
                row,
                cell,
                story: StoryRef::Body,
                ..
            } if rect.contains(c) => Some((table.0.as_slice(), *row as u32, *cell as u32, *rect)),
            _ => None,
        })
        .min_by(|a, b| (a.3.w * a.3.h).total_cmp(&(b.3.w * b.3.h)));
    let inside = |r: &Rect| {
        let slack = 2.0;
        drawn.x >= r.x - slack
            && drawn.y >= r.y - slack
            && drawn.right() <= r.right() + slack
            && drawn.bottom() <= r.bottom() + slack
    };
    let in_this_cell: Vec<&Fragment> = match cell {
        Some((table, row, col, rect)) if inside(&rect) => frags
            .iter()
            .filter(|f| f.cell() == Some((table, row, col)))
            .collect(),
        _ => Vec::new(),
    };
    let mut pool = in_this_cell;
    if pool.is_empty() {
        pool = frags.iter().filter(|f| !f.in_cell()).collect();
    }
    if pool.is_empty() {
        pool = frags.iter().collect();
    }
    let near = |f: &&Fragment| distance(&f.area, c);
    let best = pool.iter().copied().min_by(|a, b| {
        near(a)
            .total_cmp(&near(b))
            .then(b.starts().cmp(&a.starts()))
    })?;
    let reach = near(&best) + PARAGRAPH_REACH;
    let start = if quick_look {
        // Any paragraph that starts on the page; one farther than the reach and depth below, or
        // one Quick Look starts elsewhere than Word, only for want of a better one.
        let beyond =
            |f: &&Fragment| (near(f) - reach).max(0.0) + (c.y - f.y - PARAGRAPH_DEPTH).max(0.0);
        let cost = |f: &&Fragment| near(f) + beyond(f) + quick_look_cost(f);
        pool.iter()
            .copied()
            .filter(|f| f.starts())
            .min_by(|a, b| cost(a).total_cmp(&cost(b)))
    } else {
        pool.iter()
            .copied()
            .filter(|f| f.starts() && near(f) <= reach && c.y - f.y <= PARAGRAPH_DEPTH)
            .min_by(|a, b| near(a).total_cmp(&near(b)))
    };
    if let Some(f) = start {
        // Offsets from the paragraph's top: in a table cell across from the cell (LibreOffice
        // counts "from the page" inside a cell from the cell); elsewhere from the page's left
        // edge, or (Word files) from the column, the one Quick Look follows.
        let (h_rel, x0) = if f.in_cell() || quick_look {
            (Anchor::Column, f.x)
        } else {
            (Anchor::Page, 0.0)
        };
        return Some(Anchoring {
            pos: Pos {
                story: StoryRef::Body,
                path: f.path.clone(),
                off: 0,
            },
            h_rel,
            v_rel: Anchor::Paragraph,
            origin: (x0, f.y),
            in_cell: f.in_cell(),
        });
    }
    // No paragraph starts near (the middle of a long paragraph, or the margin far below one): the
    // drawing is placed on the page, anchored in the first word of the line nearest it, so it is
    // on the page that line is on. (Offsets from a line are counted differently by different
    // programs.)
    let li = (best.l0..best.l1)
        .min_by(|&a, &b| {
            let mid = |li: usize| {
                let top = best.line_top(li);
                let h = best.para.lines.get(li).map_or(0.0, |l| l.height);
                (top + h / 2.0 - c.y).abs()
            };
            mid(a).total_cmp(&mid(b))
        })
        .unwrap_or(best.l0);
    let line = best.para.lines.get(li)?;
    let text = doc
        .para(StoryRef::Body, best.path)
        .map(|p| p.text.as_str())
        .unwrap_or_default();
    Some(Anchoring {
        pos: Pos {
            story: StoryRef::Body,
            path: best.path.clone(),
            off: first_word_end(text, line.start, line.stop),
        },
        h_rel: Anchor::Page,
        v_rel: Anchor::Page,
        origin: (0.0, 0.0),
        in_cell: best.in_cell(),
    })
}

/// How far Quick Look would put a picture anchored at the start of paragraph `f` from where Word
/// puts it, points (roughly; a centred or right-aligned paragraph counts as very far). Quick Look
/// counts the offsets from where the paragraph's first line starts: after the space before it,
/// and across after its indents (or, in a centred or right-aligned paragraph, after the room the
/// alignment leaves, or a list item's number); Word counts from the paragraph's top above its
/// space before and from the column's edge.
fn quick_look_cost(f: &Fragment) -> f32 {
    use wordcraft_doc::Align;
    let rp = &f.para.rp;
    let mut cost = rp.space_before.max(0.0) + (rp.indent_left + rp.indent_first).abs();
    if matches!(rp.align, Align::Center | Align::Right) {
        cost += 1_000.0;
    }
    if f.para.label.is_some() {
        cost += 30.0;
    }
    cost
}

/// The end of the first word in `text[start..stop]` (`start` when there is none): a place inside
/// the line, which a line break before the word can't move to the line above.
fn first_word_end(text: &str, start: usize, stop: usize) -> usize {
    let Some(line) = text.get(start..stop.min(text.len())) else {
        return start;
    };
    let mut seen_word = false;
    for (i, ch) in line.char_indices() {
        if ch.is_whitespace() || ch == wordcraft_doc::para::OBJ {
            if seen_word {
                return start + i;
            }
        } else {
            seen_word = true;
        }
    }
    if seen_word { start + line.len() } else { start }
}

/// Put each drawing on its page, anchored to the text it was drawn on (see [`anchor_for`]), then
/// lay the document out again (with `lay`) and move each one by what it is off from where it was
/// drawn, so its offsets count as Word counts them (from above a paragraph's space before, say).
fn put_drawings(
    doc: &mut Document,
    layout: &DocLayout,
    drawings: &[Drawing],
    lay: &dyn Fn(&Document) -> DocLayout,
    quick_look: bool,
    report: &mut ExportReport,
) {
    struct Item {
        at: Anchoring,
        drawing: usize,
        obj: InlineObject,
    }
    let mut items: Vec<Item> = Vec::new();
    let mut skipped = Vec::new();
    // Stacking orders above the document's own objects, in the drawings' order (the app sends
    // the highlighter pictures first, so the ink stays above them).
    let top_z = top_stacking_order(doc).max(FIRST_STORED_Z);
    for (i, d) in drawings.iter().enumerate() {
        let Some(at) = anchor_for(layout, doc, d, quick_look) else {
            skipped.push(d.page);
            continue;
        };
        let Some((bytes, ext)) = read_picture(&d.path)
            .ok()
            .and_then(|b| picture_ext(&b).map(|e| (b, e)))
        else {
            skipped.push(d.page);
            continue;
        };
        let media = doc.add_media(bytes, ext);
        let float = Float {
            // Highlighter strokes go behind the text, but not in Word files: Quick Look shows a
            // picture behind the text at a quarter of its strength, so a highlight would all but
            // vanish there. In front, they look as in the app's own PDF.
            wrap: if d.behind && !quick_look {
                Wrap::BehindText
            } else {
                Wrap::InFrontOfText
            },
            h_rel: at.h_rel,
            v_rel: at.v_rel,
            x: d.x - at.origin.0,
            y: d.y - at.origin.1,
            z: top_z.saturating_add(1 + i.min(u32::MAX as usize - 1) as u32),
            ..Default::default()
        };
        let obj = InlineObject::Image {
            media,
            w: d.w,
            h: d.h,
            alt: String::new(),
            float,
            crop: [0.0; 4],
            fx: Default::default(),
            ole: None,
        };
        items.push(Item {
            at,
            drawing: i,
            obj,
        });
    }

    // Insert from the end of each paragraph backwards, so the places found in the layout stay
    // right; drawings at one place go in in drawing order.
    let key = |it: &Item| (it.at.pos.story, it.at.pos.path.clone(), it.at.pos.off);
    let mut order: Vec<usize> = (0..items.len()).collect();
    order.sort_by(|&a, &b| key(&items[b]).cmp(&key(&items[a])).then(b.cmp(&a)));
    let mut inserted = vec![false; items.len()];
    for &i in &order {
        let pos = &items[i].at.pos;
        // The text's own look for the picture's place, so it changes no line's height.
        let props = doc
            .para(pos.story, &pos.path)
            .map(|p| p.props_at(pos.off).clone())
            .unwrap_or_default();
        inserted[i] = doc.insert_object(pos, items[i].obj.clone(), &props).is_ok();
        if !inserted[i] {
            skipped.push(drawings[items[i].drawing].page);
        }
    }
    // Each picture's place now: its own place, after the pictures put before it in its paragraph.
    let obj_len = wordcraft_doc::para::OBJ.len_utf8();
    let mut finals: Vec<Option<Pos>> = vec![None; items.len()];
    let mut ascending: Vec<usize> = (0..items.len()).filter(|&i| inserted[i]).collect();
    ascending.sort_by(|&a, &b| key(&items[a]).cmp(&key(&items[b])).then(a.cmp(&b)));
    let mut before = 0;
    for (n, &i) in ascending.iter().enumerate() {
        let p = &items[i].at.pos;
        let same = n > 0 && {
            let q = &items[ascending[n - 1]].at.pos;
            q.story == p.story && q.path == p.path
        };
        before = if same { before + 1 } else { 0 };
        finals[i] = Some(Pos {
            off: p.off + before * obj_len,
            ..p.clone()
        });
    }

    // Where the layout puts each picture, against where it was drawn.
    let second = lay(doc);
    let index = second.object_index();
    for (i, item) in items.iter().enumerate() {
        let Some(pos) = &finals[i] else { continue };
        let d = &drawings[item.drawing];
        let hit = index.object(pos, d.page).filter(|h| h.page == d.page);
        let Ok(p) = doc.para_mut(pos.story, &pos.path) else {
            continue;
        };
        let Some(InlineObject::Image { float, .. }) = p.object_at_mut(pos.off) else {
            continue;
        };
        match hit {
            Some(h) => {
                float.x += d.x - h.rect.x;
                float.y += d.y - h.rect.y;
            }
            None => {
                // Not laid out on its page (a paragraph pushed to another one): placed on the
                // page by its corner instead, which holds while the paragraph stays there.
                float.h_rel = Anchor::Page;
                float.v_rel = Anchor::Page;
                float.x = d.x;
                float.y = d.y;
            }
        }
        report.drawings += 1;
        if item.at.v_rel == Anchor::Page {
            report.on_pages += 1;
        }
        if item.at.in_cell {
            report.in_cells += 1;
        }
    }
    skipped.sort_unstable();
    skipped.dedup();
    report.skipped_pages = skipped;
}

/// The highest stacking order (`Float::z`) of the floating objects in the document's text, its
/// tables, headers and footers (0: none has one).
fn top_stacking_order(doc: &Document) -> u32 {
    let mut stories = vec![StoryRef::Body];
    stories.extend(doc.parts.keys().map(|k| StoryRef::Part(*k)));
    let mut top = 0;
    for story in stories {
        for path in doc.para_paths(story) {
            let Some(p) = doc.para(story, &path) else {
                continue;
            };
            for (_, _, f) in p.objects.iter().filter_map(InlineObject::frame) {
                top = top.max(f.z);
            }
        }
    }
    top
}

/// The pictures of `doc` laid out (`layout`) that came from drawings: page and frame, in the
/// order they are in the text. For checks.
pub fn placed_pictures(layout: &DocLayout) -> Vec<(usize, Rect)> {
    let mut out = Vec::new();
    for (i, pg) in layout.pages.iter().enumerate() {
        for it in &pg.items {
            if let Placed::Object {
                rect,
                wrap,
                story: StoryRef::Body,
                ..
            } = it
                && matches!(wrap, Wrap::InFrontOfText | Wrap::BehindText)
            {
                out.push((i, *rect));
            }
        }
    }
    out
}

/// How far each drawing of `req` is from where it was drawn once its saved file is opened again
/// and laid out as the app lays it out: (across, down) in points, `None` when it is not on its
/// page. For checks.
pub fn check_saved(req: &ExportRequest, opts: &Options) -> Result<Vec<Option<(f32, f32)>>, String> {
    let region = wordcraft_geom::Region::from_tag(&opts.region);
    let (mut doc, _) = wordcraft_engine::io::open_path_in(&req.output, None, &region)?;
    prepare(&mut doc, opts);
    let placed = placed_pictures(&pdf_layout(&doc));
    Ok(req
        .drawings
        .iter()
        .map(|d| {
            placed
                .iter()
                .filter(|(page, r)| {
                    *page == d.page && (r.w - d.w).abs() < 0.5 && (r.h - d.h).abs() < 0.5
                })
                .map(|(_, r)| (r.x - d.x, r.y - d.y))
                .min_by(|a, b| a.0.hypot(a.1).total_cmp(&b.0.hypot(b.1)))
        })
        .collect())
}

/// Add `pictures` as whole pages at the end: each a picture behind the text, the size of its
/// page. `alone`: the document has nothing else (its first, empty paragraph holds the first
/// page). Returns how many were added.
fn add_picture_pages(
    doc: &mut Document,
    pictures: &[PagePicture],
    alone: bool,
) -> Result<usize, String> {
    let mut added = 0;
    for (i, picture) in pictures.iter().enumerate() {
        let bytes = read_picture(&picture.path)?;
        let ext = picture_ext(&bytes)
            .ok_or_else(|| format!("{}: not a PNG or JPEG picture", picture.path.display()))?;
        let media = doc.add_media(bytes, ext);
        let first = alone && i == 0;
        let page = page_section(picture);
        if alone {
            // Each page its own size: a new section where the size changes.
            if first {
                doc.last_section = page.clone();
            } else if !same_size(&doc.last_section, &page) {
                let ended = std::mem::replace(&mut doc.last_section, page.clone());
                if let Some(last) = last_paragraph(doc) {
                    last.section = Some(Box::new(ended));
                }
            }
        }
        let picture_object = InlineObject::Image {
            media,
            w: picture.w,
            h: picture.h,
            alt: String::new(),
            float: Float {
                wrap: Wrap::BehindText,
                h_rel: Anchor::Page,
                v_rel: Anchor::Page,
                x: 0.0,
                y: 0.0,
                ..Default::default()
            },
            crop: [0.0; 4],
            fx: Default::default(),
            ole: None,
        };
        let new_section =
            alone && !first && last_paragraph(doc).is_some_and(|p| p.section.is_some());
        let mut p = Paragraph::new();
        if !first && !new_section {
            p.props.page_break_before = Some(true);
        }
        p.insert_object(0, picture_object, &CharProps::default())
            .map_err(|e| e.to_string())?;
        if first {
            // The blank document's own empty paragraph becomes the first page.
            if let Some(last) = last_paragraph(doc) {
                *last = p;
            }
        } else {
            doc.body.push(wordcraft_doc::para_block(p));
        }
        added += 1;
    }
    Ok(added)
}

fn last_paragraph(doc: &mut Document) -> Option<&mut Paragraph> {
    let block = doc.body.last_mut()?;
    match Arc::make_mut(block) {
        wordcraft_doc::Block::Para(p) => Some(p),
        _ => None,
    }
}

/// A section for a page of pictures: the page's size, small margins, no header or footer.
fn page_section(picture: &PagePicture) -> SectionProps {
    SectionProps {
        start: SectionStart::NextPage,
        page_w: picture.w,
        page_h: picture.h,
        landscape: picture.w > picture.h,
        margin_top: 18.0,
        margin_bottom: 18.0,
        margin_left: 18.0,
        margin_right: 18.0,
        header: 9.0,
        footer: 9.0,
        ..SectionProps::default()
    }
}

fn same_size(a: &SectionProps, b: &SectionProps) -> bool {
    (a.page_w - b.page_w).abs() < 0.5 && (a.page_h - b.page_h).abs() < 0.5
}

fn read_picture(path: &Path) -> Result<Vec<u8>, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if !meta.is_file() || meta.len() > MAX_PICTURE {
        return Err(format!("{}: not a picture file", path.display()));
    }
    std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn picture_ext(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("jpeg")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drawings_read_from_json_are_kept_in_range() {
        let v = serde_json::json!({"page": 2, "x": -9000, "y": 5, "width": 100, "height": 40, "path": "/tmp/a.png", "behind": true});
        let d = drawing_from_json(&v).expect("drawing");
        assert_eq!(
            (d.page, d.x, d.y, d.w, d.h, d.behind),
            (2, -MAX_SIDE, 5.0, 100.0, 40.0, true)
        );
        assert!(drawing_from_json(&serde_json::json!({"page": 0, "x": 1, "y": 1, "width": 0, "height": 4, "path": "a"})).is_none());
        assert!(
            drawing_from_json(
                &serde_json::json!({"page": 0, "x": 1, "y": 1, "width": 3, "height": 4})
            )
            .is_none()
        );
    }

    #[test]
    fn first_word_end_stays_inside_the_line() {
        let t = "ab cd  ef";
        assert_eq!(first_word_end(t, 0, t.len()), 2);
        assert_eq!(first_word_end(t, 2, t.len()), 5);
        assert_eq!(first_word_end(t, 7, t.len()), 9);
        assert_eq!(first_word_end("   ", 0, 3), 0);
        assert_eq!(first_word_end("Բարև ձեզ", 0, 13), "Բարև".len());
    }

    #[test]
    fn symbol_font_bullets_become_unicode() {
        let level = |text: &str, font: &str| Level {
            format: NumFormat::Bullet,
            text: text.to_string(),
            chr: CharProps {
                font: Some(font.to_string()),
                ..Default::default()
            },
            ..Default::default()
        };
        let mut doc = Document::new();
        let numbering = Arc::make_mut(&mut doc.numbering);
        numbering
            .abstracts
            .push(wordcraft_doc::numbering::AbstractNum {
                levels: vec![
                    level("\u{F0B7}", "Symbol"),
                    level("o", "Courier New"),
                    level("\u{F0A7}", "Wingdings"),
                    level("\u{B7}", "Symbol"),
                ],
                ..Default::default()
            });
        plain_bullets(&mut doc);
        let shown: Vec<(&str, Option<&str>)> = doc.numbering.abstracts[0]
            .levels
            .iter()
            .map(|l| (l.text.as_str(), l.chr.font.as_deref()))
            .collect();
        assert_eq!(
            shown,
            [
                ("\u{2022}", None),
                ("o", Some("Courier New")),
                ("\u{25AA}", None),
                ("\u{2022}", None)
            ]
        );
    }

    #[test]
    fn distance_is_zero_inside_and_straight_beside() {
        let r = Rect::new(10.0, 10.0, 100.0, 20.0);
        assert_eq!(distance(&r, Point::new(50.0, 15.0)), 0.0);
        assert_eq!(distance(&r, Point::new(50.0, 40.0)), 10.0);
        assert_eq!(distance(&r, Point::new(113.0, 34.0)), 5.0);
    }
}
