//! HayDocs document engine: Word (.docx, .doc), OpenDocument (.odt), RTF, HTML, Markdown and text
//! files become PDF through the WordCraft engine. The iOS app calls the C functions at the end.
//!
//! Before the PDF is written, two things happen to the text:
//! - text typed in the old 8-bit Armenian fonts (ArmSCII-8: "Arial Armenian", "Times Armenian"…)
//!   is turned into Unicode Armenian and set in a Unicode Armenian font;
//! - Armenian words in a font that has no Armenian letters (Calibri, or "GHEA Grapalat" when it
//!   isn't installed) are set in the chosen Armenian font: serif for serif fonts, sans otherwise.

use std::collections::BTreeSet;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::sync::Mutex;

use serde_json::{Value, json};
use wordcraft_doc::{CharProps, Document, Paragraph, Run, StoryRef, StyleSheet};
use wordcraft_fonts::FontDb;

pub mod armscii;

/// Settings for one conversion (JSON from the app).
#[derive(Clone, Debug)]
pub struct Options {
    /// Turn ArmSCII-8 text into Unicode.
    pub armscii: bool,
    /// Set Armenian words in `serif` / `sans` / `mono` where the run's font has no Armenian.
    pub armenian_fallback: bool,
    pub serif: String,
    pub sans: String,
    pub mono: String,
    /// Locale tag giving the paper for files without a page size (text, HTML, Markdown).
    pub region: String,
    pub password: Option<String>,
}

impl Default for Options {
    fn default() -> Self {
        Options {
            armscii: true,
            armenian_fallback: true,
            serif: "Noto Serif Armenian".into(),
            sans: "Noto Sans Armenian".into(),
            mono: "DejaVu Sans Mono".into(),
            region: "hy-AM".into(),
            password: None,
        }
    }
}

impl Options {
    pub fn from_json(v: &Value) -> Options {
        let d = Options::default();
        let text = |key: &str, default: String| {
            v.get(key).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(String::from).unwrap_or(default)
        };
        Options {
            armscii: v.get("armscii").and_then(Value::as_bool).unwrap_or(d.armscii),
            armenian_fallback: v.get("armenianFallback").and_then(Value::as_bool).unwrap_or(d.armenian_fallback),
            serif: text("serif", d.serif),
            sans: text("sans", d.sans),
            mono: text("mono", d.mono),
            region: text("region", d.region),
            password: v.get("password").and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from),
        }
    }
}

/// What a conversion changed, for the app's notes.
#[derive(Debug, Default)]
pub struct Report {
    /// Runs of ArmSCII-8 text turned into Unicode.
    pub armscii_runs: usize,
    /// Runs whose Armenian words were set in an Armenian font.
    pub fallback_runs: usize,
    /// Fonts the document asks for that aren't available (for Armenian text).
    pub missing_fonts: BTreeSet<String>,
    /// The old fonts found.
    pub legacy_fonts: BTreeSet<String>,
}

/// Add font files (TTF, OTF, TTC, WOFF…) to the engine. Returns the number of faces added.
pub fn add_font_files(paths: &[String]) -> usize {
    let files: Vec<(Vec<u8>, String)> = paths
        .iter()
        .filter_map(|p| std::fs::read(p).ok())
        .filter_map(|bytes| wordcraft_fonts::decode_font_file(&bytes).ok())
        .map(|bytes| (bytes, String::new()))
        .collect();
    if files.is_empty() {
        return 0;
    }
    FontDb::global().add_document_fonts(files)
}

/// Open `input`, fix its Armenian text and write it as PDF to `output`.
pub fn convert(input: &Path, output: &Path, opts: &Options) -> Result<Report, String> {
    let region = wordcraft_geom::Region::from_tag(&opts.region);
    let (mut doc, _) = wordcraft_engine::io::open_path_in(input, opts.password.as_deref(), &region)?;
    let report = prepare(&mut doc, opts);
    let bytes = wordcraft_engine::io::save_bytes("document.pdf", &doc)?;
    std::fs::write(output, bytes).map_err(|e| format!("{}: {e}", output.display()))?;
    Ok(report)
}

/// The text of `input` (for checks).
pub fn plain_text(input: &Path, opts: &Options) -> Result<String, String> {
    let region = wordcraft_geom::Region::from_tag(&opts.region);
    let (mut doc, _) = wordcraft_engine::io::open_path_in(input, opts.password.as_deref(), &region)?;
    prepare(&mut doc, opts);
    let bytes = wordcraft_engine::io::save_bytes("document.txt", &doc)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Fix the Armenian text of every paragraph: body, tables, headers, footers, notes, text boxes.
pub fn prepare(doc: &mut Document, opts: &Options) -> Report {
    let mut report = Report::default();
    if !opts.armscii && !opts.armenian_fallback {
        return report;
    }
    let styles = doc.styles.clone();
    let mut stories = vec![StoryRef::Body];
    stories.extend(doc.parts.keys().map(|k| StoryRef::Part(*k)));
    for story in stories {
        for path in doc.para_paths(story) {
            let fixed = doc.para(story, &path).and_then(|p| fixed_paragraph(p, &styles, opts, &mut report));
            if let Some((text, runs)) = fixed
                && let Ok(p) = doc.para_mut(story, &path)
            {
                p.text = text;
                p.runs = runs;
                p.rev = wordcraft_doc::para::next_rev();
            }
        }
    }
    report
}

/// The paragraph's new text and runs, or `None` when nothing changes.
fn fixed_paragraph(p: &Paragraph, styles: &StyleSheet, opts: &Options, report: &mut Report) -> Option<(String, Vec<Run>)> {
    if p.text.is_empty() {
        return None;
    }
    let whole = [Run { len: p.text.len(), props: CharProps::default() }];
    let runs: &[Run] = if p.runs.is_empty() { &whole } else { &p.runs };
    let para_style = p.props.style.as_deref();
    let mut text = String::with_capacity(p.text.len() + 16);
    let mut out: Vec<Run> = Vec::with_capacity(runs.len());
    let mut changed = false;
    let mut start = 0usize;
    for (i, run) in runs.iter().enumerate() {
        let end = if i + 1 == runs.len() { p.text.len() } else { start.saturating_add(run.len).min(p.text.len()) };
        // A run that doesn't end on a character boundary: leave the paragraph as it is.
        let slice = p.text.get(start..end)?;
        start = end;
        if slice.is_empty() {
            out.push(Run { len: 0, props: run.props.clone() });
            continue;
        }
        let resolved = styles.resolve_char(para_style, &run.props);
        let family = resolved.font.clone();

        if opts.armscii && armscii::is_legacy_font(&family) {
            let converted = armscii::to_unicode(slice);
            let target = pick_family(&family, opts).to_string();
            let mut props = run.props.clone();
            props.font = Some(target.clone());
            if props.font_cs.as_deref().is_some_and(armscii::is_legacy_font) {
                props.font_cs = Some(target.clone());
            }
            if props.font_ea.as_deref().is_some_and(armscii::is_legacy_font) {
                props.font_ea = Some(target);
            }
            report.armscii_runs += 1;
            report.legacy_fonts.insert(family);
            text.push_str(&converted);
            out.push(Run { len: converted.len(), props });
            changed = true;
            continue;
        }

        if opts.armenian_fallback && slice.chars().any(is_armenian) {
            let face = wordcraft_fonts::word::resolve(&family, resolved.bold, resolved.italic);
            if !face.face.covers('\u{0561}') {
                if face.substituted && !family.trim().is_empty() {
                    report.missing_fonts.insert(family.clone());
                }
                let target = pick_family(&family, opts).to_string();
                for (segment, armenian) in split_armenian(slice) {
                    let mut props = run.props.clone();
                    if armenian {
                        props.font = Some(target.clone());
                    }
                    text.push_str(segment);
                    out.push(Run { len: segment.len(), props });
                }
                report.fallback_runs += 1;
                changed = true;
                continue;
            }
        }

        text.push_str(slice);
        out.push(Run { len: slice.len(), props: run.props.clone() });
    }
    changed.then_some((text, out))
}

/// Armenian letters and punctuation (U+0531–U+058F) and the Armenian ligatures (U+FB13–U+FB17).
pub fn is_armenian(c: char) -> bool {
    matches!(c, '\u{0531}'..='\u{058F}' | '\u{FB13}'..='\u{FB17}')
}

/// Spaces, digits and punctuation: they go with the Armenian words around them.
fn is_neutral(c: char) -> bool {
    c.is_whitespace()
        || c.is_ascii_digit()
        || c.is_ascii_punctuation()
        || matches!(c, '\u{00A0}' | '\u{00AB}' | '\u{00BB}' | '\u{2010}'..='\u{2027}')
}

/// `s` cut into pieces that are Armenian (true) or not (false). Spaces, digits and punctuation
/// join the piece before them (at the start, the piece after them).
fn split_armenian(s: &str) -> Vec<(&str, bool)> {
    let chars: Vec<(usize, char)> = s.char_indices().collect();
    let first = chars.iter().find(|(_, c)| !is_neutral(*c)).map(|(_, c)| is_armenian(*c)).unwrap_or(false);
    let mut current = first;
    let mut out: Vec<(&str, bool)> = Vec::new();
    let mut piece_start = 0usize;
    let mut piece_kind = first;
    for &(at, c) in &chars {
        if !is_neutral(c) {
            current = is_armenian(c);
        }
        if current != piece_kind {
            if at > piece_start {
                out.push((&s[piece_start..at], piece_kind));
            }
            piece_start = at;
            piece_kind = current;
        }
    }
    if piece_start < s.len() {
        out.push((&s[piece_start..], piece_kind));
    }
    out
}

/// The Armenian font for text that was in `family`: monospaced, serif or sans.
fn pick_family<'a>(family: &str, opts: &'a Options) -> &'a str {
    let f = family.to_ascii_lowercase();
    const MONO: &[&str] = &["courier", "mono", "consol", "code", "typewriter", "fixed"];
    const SERIF: &[&str] = &[
        "times", "serif", "roman", "georgia", "garamond", "cambria", "caladea", "book", "grapalat", "sylfaen", "palatino", "baskerville",
        "minion", "century", "bodoni", "mariam", "dallak time", "tarumiantimes", "tarumian times", "kamar", "mincho", "song", "cambo",
    ];
    if MONO.iter().any(|k| f.contains(k)) {
        &opts.mono
    } else if !f.contains("sans") && SERIF.iter().any(|k| f.contains(k)) {
        &opts.serif
    } else {
        &opts.sans
    }
}

// MARK: C interface

static LOCK: Mutex<()> = Mutex::new(());

fn read_c_string(s: *const c_char) -> Option<String> {
    if s.is_null() {
        return None;
    }
    // SAFETY: the caller passes a NUL-terminated string that stays valid during the call.
    unsafe { CStr::from_ptr(s) }.to_str().ok().map(String::from)
}

fn into_c_string(v: Value) -> *mut c_char {
    let text = v.to_string().replace('\0', "");
    CString::new(text).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

fn panic_text(e: &Box<dyn std::any::Any + Send>) -> String {
    e.downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| e.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown error".into())
}

/// Add fonts: `paths_json` is a JSON array of file paths. Returns the number of faces added.
#[unsafe(no_mangle)]
pub extern "C" fn hd_add_fonts(paths_json: *const c_char) -> i32 {
    let Some(json) = read_c_string(paths_json) else { return -1 };
    let paths: Vec<String> = serde_json::from_str(&json).unwrap_or_default();
    let _guard = LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    match catch_unwind(AssertUnwindSafe(|| add_font_files(&paths))) {
        Ok(n) => i32::try_from(n).unwrap_or(i32::MAX),
        Err(_) => -2,
    }
}

/// Convert a document to PDF. `request_json`: {"input", "output", "armscii", "armenianFallback",
/// "serif", "sans", "mono", "region", "password"}. Returns JSON (free it with `hd_free`):
/// {"ok": true, "armsciiRuns", "fallbackRuns", "missingFonts", "legacyFonts"} or
/// {"ok": false, "error", "needsPassword", "wrongPassword"}.
#[unsafe(no_mangle)]
pub extern "C" fn hd_convert(request_json: *const c_char) -> *mut c_char {
    let response = (|| {
        let Some(json) = read_c_string(request_json) else { return json!({"ok": false, "error": "no request"}) };
        let Ok(request) = serde_json::from_str::<Value>(&json) else { return json!({"ok": false, "error": "bad request"}) };
        let (Some(input), Some(output)) = (request.get("input").and_then(Value::as_str), request.get("output").and_then(Value::as_str)) else {
            return json!({"ok": false, "error": "input and output are required"});
        };
        let opts = Options::from_json(&request);
        let _guard = LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        match catch_unwind(AssertUnwindSafe(|| convert(Path::new(input), Path::new(output), &opts))) {
            Ok(Ok(r)) => json!({
                "ok": true,
                "armsciiRuns": r.armscii_runs,
                "fallbackRuns": r.fallback_runs,
                "missingFonts": r.missing_fonts.into_iter().collect::<Vec<_>>(),
                "legacyFonts": r.legacy_fonts.into_iter().collect::<Vec<_>>(),
            }),
            Ok(Err(e)) => json!({
                "ok": false,
                "error": e,
                "needsPassword": wordcraft_engine::io::needs_password(&e),
                "wrongPassword": wordcraft_engine::io::wrong_password(&e),
            }),
            Err(p) => json!({"ok": false, "error": format!("engine stopped: {}", panic_text(&p))}),
        }
    })();
    into_c_string(response)
}

/// Free a string returned by `hd_convert`.
#[unsafe(no_mangle)]
pub extern "C" fn hd_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: `s` came from `CString::into_raw` in this library and is freed once.
        drop(unsafe { CString::from_raw(s) });
    }
}

/// The engine's version, for the app's About line (a static string, don't free).
#[unsafe(no_mangle)]
pub extern "C" fn hd_version() -> *const c_char {
    concat!("haydocs-engine ", env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_armenian_words_with_their_spaces() {
        let parts = split_armenian("HayDocs ծրագրի փորձ, PDF ու Word");
        let kinds: Vec<(&str, bool)> = parts;
        assert_eq!(kinds, vec![("HayDocs ", false), ("ծրագրի փորձ, ", true), ("PDF ", false), ("ու ", true), ("Word", false)]);
        assert_eq!(split_armenian("  Բարև"), vec![("  Բարև", true)]);
        assert_eq!(split_armenian("abc"), vec![("abc", false)]);
    }

    #[test]
    fn picks_serif_for_serif_fonts() {
        let o = Options::default();
        assert_eq!(pick_family("Times New Roman", &o), "Noto Serif Armenian");
        assert_eq!(pick_family("GHEA Grapalat", &o), "Noto Serif Armenian");
        assert_eq!(pick_family("Arial", &o), "Noto Sans Armenian");
        assert_eq!(pick_family("Courier New", &o), "DejaVu Sans Mono");
        assert_eq!(pick_family("Liberation Sans", &o), "Noto Sans Armenian");
    }
}
