//! Command-line check of the engine: `hd-convert [--fonts DIR]... [--no-system-fonts] <in> <out.pdf|out.txt>`,
//! or `hd-convert ... --export request.json <in|-> <out.docx|out.odt>` to save with the drawings and
//! picture pages (the request as `hd_export` takes it; `-`: no original, pictures only). After an
//! export it opens the saved file again and says how far each drawing landed from its place.
//! `--check` with `--export` only does that check on a file saved before (by the app, say); the
//! request may then be just the list of drawings.

use std::path::Path;

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut font_dirs = Vec::new();
    while let Some(i) = args.iter().position(|a| a == "--fonts") {
        args.remove(i);
        if i < args.len() {
            font_dirs.push(args.remove(i));
        }
    }
    let mut export_request = None;
    if let Some(i) = args.iter().position(|a| a == "--export") {
        args.remove(i);
        if i < args.len() {
            export_request = Some(args.remove(i));
        }
    }
    let check_only = match args.iter().position(|a| a == "--check") {
        Some(i) => {
            args.remove(i);
            true
        }
        None => false,
    };
    if let Some(i) = args.iter().position(|a| a == "--no-system-fonts") {
        args.remove(i);
        wordcraft_fonts::FontDb::global().set_system_fallback(false);
    }
    let mut files = Vec::new();
    for dir in &font_dirs {
        for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let p = entry.path();
            if wordcraft_fonts::is_font_file_name(&p.to_string_lossy()) {
                files.push(p.to_string_lossy().into_owned());
            }
        }
    }
    let added = haydocs_engine::add_font_files(&files);
    eprintln!("fonts: {} files, {added} faces", files.len());
    let (Some(input), Some(output)) = (args.first(), args.get(1)) else {
        eprintln!("usage: hd-convert [--fonts DIR]... [--no-system-fonts] <in> <out.pdf|out.txt>");
        std::process::exit(2);
    };
    let opts = haydocs_engine::Options::default();
    if let Some(request) = export_request {
        let text = std::fs::read_to_string(&request).expect("read the request");
        let mut v: serde_json::Value = serde_json::from_str(&text).expect("request JSON");
        if v.is_array() {
            v = serde_json::json!({ "drawings": v });
        }
        if input != "-" {
            v["input"] = serde_json::Value::from(input.as_str());
        }
        v["output"] = serde_json::Value::from(output.as_str());
        let req = haydocs_engine::export::ExportRequest::from_json(&v).expect("request");
        if !check_only {
            match haydocs_engine::export::export(&req, &opts) {
                Ok(r) => eprintln!("ok: {r:?}"),
                Err(e) => {
                    eprintln!("error: {e}");
                    std::process::exit(1);
                }
            }
        }
        match haydocs_engine::export::check_saved(&req, &opts) {
            Ok(offs) => {
                for (i, (d, off)) in req.drawings.iter().zip(&offs).enumerate() {
                    match off {
                        Some((dx, dy)) => eprintln!(
                            "check: drawing {i} on page {}: {:.2} pt from its place ({dx:+.2}, {dy:+.2})",
                            d.page + 1,
                            dx.hypot(*dy)
                        ),
                        None => eprintln!("check: drawing {i} on page {}: NOT FOUND", d.page + 1),
                    }
                }
            }
            Err(e) => eprintln!("check: cannot reopen: {e}"),
        }
        return;
    }
    if output.ends_with(".txt") {
        match haydocs_engine::plain_text(Path::new(input), &opts) {
            Ok(t) => std::fs::write(output, t).expect("write"),
            Err(e) => {
                eprintln!("error: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    match haydocs_engine::convert(Path::new(input), Path::new(output), &opts) {
        Ok(r) => eprintln!("ok: {r:?}"),
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}
