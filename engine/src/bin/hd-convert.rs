//! Command-line check of the engine: `hd-convert [--fonts DIR]... [--no-system-fonts] <in> <out.pdf|out.txt>`.

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
