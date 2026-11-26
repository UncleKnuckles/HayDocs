//! Saving a document as Word (.docx) or OpenDocument (.odt) with the Pencil drawings made over
//! its pages.
//!
//! A document the engine made the pages of (Word, ODT, RTF, text…) is opened again and laid out
//! as its PDF was, and each ink stroke becomes a freeform ink shape on its page, over the text
//! (a highlighter behind it), so the text stays text and the ink stays ink that Word and
//! LibreOffice can move or delete. Pages that have no text to put the ink on (pages added in
//! the app, PDF pages, photos and scans) come from the app as pictures with the ink drawn in
//! and become whole pages: after the text, or the whole document when there is no text.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::Value;
use wordcraft_doc::freeform::{Freeform, InkTool, MAX_INK_PER_PAGE, MAX_POINTS};
use wordcraft_doc::para::{Anchor, Float, ShapeKind, Wrap};
use wordcraft_doc::section::SectionStart;
use wordcraft_doc::{CharProps, Document, InlineObject, Paragraph, Pos, Rgb, SectionProps, StoryRef};
use wordcraft_engine::layout::{DocLayout, LayoutCache, LayoutOptions, Placed};

use crate::{Options, Report, prepare};

/// Widths a stroke may have, points (the engine's own Draw tab limits).
const MIN_WIDTH: f32 = 0.25;
const MAX_WIDTH: f32 = 72.0;
/// Pictures larger than this are not read.
const MAX_PICTURE: u64 = 64 << 20;
/// Pages and strokes one request may carry.
const MAX_PAGES: usize = 2_000;
const MAX_STROKES: usize = 200_000;

/// One ink stroke, in page points from the page's top left corner.
#[derive(Clone, Debug)]
pub struct Stroke {
    /// Page index, from 0, in the document's PDF.
    pub page: usize,
    pub tool: InkTool,
    pub color: Rgb,
    /// Opacity 0–1.
    pub alpha: f32,
    pub width: f32,
    pub points: Vec<[f32; 2]>,
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
    pub strokes: Vec<Stroke>,
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
    /// Strokes put on the pages.
    pub strokes: usize,
    /// Pages whose strokes could not be put on them (no such page, or no text there to hold them).
    pub skipped_pages: Vec<usize>,
    pub pictures: usize,
    /// The Armenian fixes, as for the PDF.
    pub fixes: Report,
}

impl ExportRequest {
    /// From the app's JSON (see `hd_export`).
    pub fn from_json(v: &Value) -> Result<ExportRequest, String> {
        let output = v.get("output").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or("output is required")?;
        let input = v.get("input").and_then(Value::as_str).filter(|s| !s.is_empty()).map(PathBuf::from);
        let strokes = v
            .get("strokes")
            .and_then(Value::as_array)
            .map(|a| a.iter().take(MAX_STROKES).filter_map(stroke_from_json).collect())
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
                        (w.is_finite() && h.is_finite() && w >= 1.0 && h >= 1.0).then(|| PagePicture {
                            path: PathBuf::from(path),
                            w: w.min(1584.0),
                            h: h.min(1584.0),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let title = v.get("title").and_then(Value::as_str).unwrap_or_default().to_string();
        Ok(ExportRequest { input, output: PathBuf::from(output), strokes, pictures, title })
    }
}

fn stroke_from_json(v: &Value) -> Option<Stroke> {
    let page = usize::try_from(v.get("page")?.as_u64()?).ok()?;
    let tool = v.get("tool").and_then(Value::as_str).and_then(InkTool::parse).unwrap_or(InkTool::Pen);
    let color = v.get("color").and_then(Value::as_str).and_then(Rgb::parse).unwrap_or(Rgb(0, 0, 0));
    let alpha = v.get("alpha").and_then(Value::as_f64).map(|a| a as f32).filter(|a| a.is_finite()).unwrap_or_else(|| tool.alpha());
    let width = v.get("width").and_then(Value::as_f64).map(|w| w as f32).filter(|w| w.is_finite()).unwrap_or_else(|| tool.default_width());
    let points: Vec<[f32; 2]> = v
        .get("points")?
        .as_array()?
        .iter()
        .filter_map(|p| {
            let a = p.as_array()?;
            let (x, y) = (a.first()?.as_f64()? as f32, a.get(1)?.as_f64()? as f32);
            (x.is_finite() && y.is_finite()).then_some([x, y])
        })
        .collect();
    (!points.is_empty()).then_some(Stroke { page, tool, color, alpha: alpha.clamp(0.05, 1.0), width: width.clamp(MIN_WIDTH, MAX_WIDTH), points })
}

/// Make the document `req` asks for and write it.
pub fn export(req: &ExportRequest, opts: &Options) -> Result<ExportReport, String> {
    let name = req.output.to_string_lossy().to_string();
    let ext = name.rsplit('.').next().unwrap_or_default().to_ascii_lowercase();
    if !matches!(ext.as_str(), "docx" | "odt") {
        return Err(format!("{name}: only .docx and .odt are made here"));
    }
    let mut report = ExportReport::default();
    let mut doc = match &req.input {
        Some(input) => {
            let region = wordcraft_geom::Region::from_tag(&opts.region);
            let (mut doc, _) = wordcraft_engine::io::open_path_in(input, opts.password.as_deref(), &region)?;
            report.fixes = prepare(&mut doc, opts);
            doc
        }
        None => {
            let mut doc = Document::new();
            doc.core.title = req.title.clone();
            doc
        }
    };

    if req.input.is_some() {
        let layout = pdf_layout(&doc);
        report.pages = layout.pages.len();
        let (placed, skipped) = put_ink(&mut doc, &layout, &req.strokes);
        report.strokes = placed;
        report.skipped_pages = skipped;
    } else {
        report.skipped_pages = pages_of(&req.strokes);
    }

    report.pictures = add_picture_pages(&mut doc, &req.pictures, req.input.is_none())?;
    let bytes = wordcraft_engine::io::save_bytes(&format!("document.{ext}"), &doc)?;
    std::fs::write(&req.output, bytes).map_err(|e| format!("{}: {e}", req.output.display()))?;
    Ok(report)
}

/// The document laid out as its PDF is: printed pages, final text, field results as printed.
fn pdf_layout(doc: &Document) -> DocLayout {
    let opts = LayoutOptions { hide_deleted: true, output_page_refs: true, ..Default::default() };
    // The fields as printed, when that changes no paragraphs (the ink goes into `doc`).
    let printed = wordcraft_engine::cmd::references::output_fields(doc).filter(|d| d.paragraph_count() == doc.paragraph_count());
    wordcraft_layout_of(printed.as_ref().unwrap_or(doc), &opts)
}

fn wordcraft_layout_of(doc: &Document, opts: &LayoutOptions) -> DocLayout {
    wordcraft_engine::layout::layout(doc, &mut LayoutCache::new(), opts)
}

fn pages_of(strokes: &[Stroke]) -> Vec<usize> {
    let mut pages: Vec<usize> = strokes.iter().map(|s| s.page).collect();
    pages.sort_unstable();
    pages.dedup();
    pages
}

/// Where ink on `page` is anchored: a body paragraph that starts on the page, else the first body
/// line on it (a table cell's, or a paragraph's continued from the page before). The flag is set
/// for a place in a table (the ink is then placed on the page, not in the cell).
fn anchor_on(layout: &DocLayout, page: usize) -> Option<(Pos, bool)> {
    let pg = layout.pages.get(page)?;
    for item in &pg.items {
        if let Placed::Lines { story: StoryRef::Body, path, l0: 0, .. } = item
            && path.depth() == 0
        {
            return Some((Pos { story: StoryRef::Body, path: path.clone(), off: 0 }, false));
        }
    }
    let lines = wordcraft_engine::layout::hit::page_lines(pg, StoryRef::Body);
    let line = lines.first()?;
    let off = line.para.lines.get(line.li)?.start;
    Some((Pos { story: StoryRef::Body, path: line.path.clone(), off }, line.path.depth() > 0))
}

/// Put each stroke on its page as an ink shape. Returns how many were placed and the pages
/// whose strokes could not be.
fn put_ink(doc: &mut Document, layout: &DocLayout, strokes: &[Stroke]) -> (usize, Vec<usize>) {
    // Strokes by anchor, in drawing order: (anchor, in a table, page, objects).
    let mut groups: Vec<(Pos, bool, usize, Vec<InlineObject>)> = Vec::new();
    let mut skipped = Vec::new();
    let mut per_page: std::collections::HashMap<usize, usize> = std::collections::HashMap::new();
    let mut order = 0u32;
    for stroke in strokes {
        let Some(pg) = layout.pages.get(stroke.page) else {
            skipped.push(stroke.page);
            continue;
        };
        let group = match groups.iter().position(|g| g.2 == stroke.page) {
            Some(i) => i,
            None => match anchor_on(layout, stroke.page) {
                Some((pos, in_table)) => {
                    groups.push((pos, in_table, stroke.page, Vec::new()));
                    groups.len() - 1
                }
                None => {
                    skipped.push(stroke.page);
                    continue;
                }
            },
        };
        let in_table = groups[group].1;
        // The page's own size, without a comment area beside it.
        let (pw, ph) = ((pg.w - pg.markup).max(1.0), pg.h.max(1.0));
        for piece in pieces(&stroke.points) {
            let count = per_page.entry(stroke.page).or_default();
            if *count >= MAX_INK_PER_PAGE {
                skipped.push(stroke.page);
                break;
            }
            *count += 1;
            order += 1;
            groups[group].3.push(ink_shape(stroke, piece, (pw, ph), in_table, order));
        }
    }
    // Insert from the end of each paragraph backwards, so the places found in the layout stay
    // right; each group's strokes go in at one place, in drawing order.
    groups.sort_by(|a, b| (b.0.story, &b.0.path, b.0.off).cmp(&(a.0.story, &a.0.path, a.0.off)));
    let mut placed = 0;
    for (pos, _, page, objects) in groups {
        for obj in objects.into_iter().rev() {
            match doc.insert_object(&pos, obj, &CharProps::default()) {
                Ok(_) => placed += 1,
                Err(_) => skipped.push(page),
            }
        }
    }
    skipped.sort_unstable();
    skipped.dedup();
    (placed, skipped)
}

/// A stroke's points in runs of at most `MAX_POINTS`, each run starting where the last ended.
fn pieces(points: &[[f32; 2]]) -> Vec<&[[f32; 2]]> {
    if points.len() <= MAX_POINTS {
        return vec![points];
    }
    let mut out = Vec::new();
    let mut start = 0;
    while start + 1 < points.len() {
        let end = (start + MAX_POINTS).min(points.len());
        out.push(&points[start..end]);
        start = end - 1;
    }
    out
}

/// The ink shape for `points` of `stroke`: a freeform the size of the points' bounds, placed on
/// the page. The frame is not grown by the stroke's width: LibreOffice puts an ODT path's own
/// bounds at the frame's corner, so a grown frame would shift the ink by half its width.
fn ink_shape(stroke: &Stroke, points: &[[f32; 2]], (pw, ph): (f32, f32), in_table: bool, order: u32) -> InlineObject {
    let width = stroke.width;
    let pts: Vec<[f32; 2]> = points.iter().map(|[x, y]| [x.clamp(0.0, pw), y.clamp(0.0, ph)]).collect();
    let first = pts.first().copied().unwrap_or([0.0, 0.0]);
    let (mut x0, mut y0, mut x1, mut y1) = (first[0], first[1], first[0], first[1]);
    for [x, y] in &pts {
        (x0, y0, x1, y1) = (x0.min(*x), y0.min(*y), x1.max(*x), y1.max(*y));
    }
    let (fx, fy) = (x0, y0);
    let (fw, fh) = ((x1 - x0).max(1.0), (y1 - y0).max(1.0));
    // A single dot: two points, so it is drawn.
    let mut local: Vec<[f32; 2]> = pts.iter().map(|[x, y]| [x - fx, y - fy]).collect();
    if local.len() == 1 {
        local.push([local[0][0] + 0.01, local[0][1]]);
    }
    let wrap = if stroke.tool == InkTool::Highlighter { Wrap::BehindText } else { Wrap::InFrontOfText };
    let ink = Freeform { order: Some(order), ..Freeform::ink(stroke.tool, fw, fh, local) };
    InlineObject::Shape {
        kind: ShapeKind::Freeform,
        w: fw,
        h: fh,
        fill: None,
        stroke: Some(stroke.color),
        stroke_width: width,
        float: Float {
            wrap,
            h_rel: Anchor::Page,
            v_rel: Anchor::Page,
            x: fx,
            y: fy,
            outside_cell: in_table,
            ..Default::default()
        },
        story: None,
        freeform: Some(Arc::new(Freeform { alpha: stroke.alpha.clamp(0.0, 1.0), ..ink })),
        effects: Default::default(),
        extra: Default::default(),
    }
}

/// Add `pictures` as whole pages at the end: each a picture behind the text, the size of its
/// page. `alone`: the document has nothing else (its first, empty paragraph holds the first
/// page). Returns how many were added.
fn add_picture_pages(doc: &mut Document, pictures: &[PagePicture], alone: bool) -> Result<usize, String> {
    let mut added = 0;
    for (i, picture) in pictures.iter().enumerate() {
        let bytes = read_picture(&picture.path)?;
        let ext = picture_ext(&bytes).ok_or_else(|| format!("{}: not a PNG or JPEG picture", picture.path.display()))?;
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
            float: Float { wrap: Wrap::BehindText, h_rel: Anchor::Page, v_rel: Anchor::Page, x: 0.0, y: 0.0, ..Default::default() },
            crop: [0.0; 4],
            fx: Default::default(),
            ole: None,
        };
        let new_section = alone && !first && last_paragraph(doc).is_some_and(|p| p.section.is_some());
        let mut p = Paragraph::new();
        if !first && !new_section {
            p.props.page_break_before = Some(true);
        }
        p.insert_object(0, picture_object, &CharProps::default()).map_err(|e| e.to_string())?;
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
    fn long_strokes_are_cut_into_joined_pieces() {
        let pts: Vec<[f32; 2]> = (0..12_000).map(|i| [i as f32 * 0.01, 1.0]).collect();
        let parts = pieces(&pts);
        assert_eq!(parts.len(), 3);
        assert!(parts.iter().all(|p| p.len() <= MAX_POINTS));
        assert_eq!(parts[0].last(), parts[1].first());
        assert_eq!(parts[2].last(), pts.last());
    }

    #[test]
    fn strokes_read_from_json_are_kept_in_range() {
        let v = serde_json::json!({"page": 2, "tool": "highlighter", "color": "FFEE00", "width": 500, "points": [[1, 2], [3, "x"], [4, 5]]});
        let s = stroke_from_json(&v).expect("stroke");
        assert_eq!((s.page, s.tool, s.color, s.width, s.points.len()), (2, InkTool::Highlighter, Rgb(0xFF, 0xEE, 0), MAX_WIDTH, 2));
        assert!((s.alpha - 0.5).abs() < 1e-6);
    }
}
