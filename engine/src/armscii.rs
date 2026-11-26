//! ArmSCII-8, the 8-bit Armenian encoding of the old fonts ("Arial Armenian", "Times Armenian",
//! "ArTarumian…", "… LatArm"). Word keeps their text as the Latin-1 characters with the same byte
//! values (symbol fonts as U+F0xx), so "²³" only looks like "Աա" while that font is installed.

/// Whether `family` is one of the old 8-bit Armenian fonts.
pub fn is_legacy_font(family: &str) -> bool {
    let f = family.trim().to_ascii_lowercase();
    if f.is_empty()
        || f.starts_with("noto")
        || f.contains("unicode")
        || f.contains(" amu")
        || f.ends_with("amu")
    {
        return false;
    }
    f.contains("armenian")
        || f.contains("latarm")
        || f.contains("armscii")
        || f.starts_with("artarumian")
        || f.starts_with("ar tarumian")
        || f.starts_with("dallak")
}

/// The Unicode character for one character of ArmSCII-8 text; others are returned unchanged.
pub fn map_char(c: char) -> char {
    let mut cp = c as u32;
    if (0xF0A0..=0xF0FF).contains(&cp) {
        cp -= 0xF000;
    }
    let mapped = match cp {
        0xA0 => 0x00A0,
        0xA2 => 0x0587, // և
        0xA3 => 0x0589, // ։
        0xA4 => 0x0029, // )
        0xA5 => 0x0028, // (
        0xA6 => 0x00BB, // »
        0xA7 => 0x00AB, // «
        0xA8 => 0x2014, // —
        0xA9 => 0x002E, // .
        0xAA => 0x055D, // ՝
        0xAB => 0x002C, // ,
        0xAC => 0x002D, // -
        0xAD => 0x058A, // ֊
        0xAE => 0x2026, // …
        0xAF => 0x055C, // ՜
        0xB0 => 0x055B, // ՛
        0xB1 => 0x055E, // ՞
        0xB2..=0xFD => {
            let i = (cp - 0xB2) / 2;
            if (cp - 0xB2) % 2 == 0 {
                0x0531 + i
            } else {
                0x0561 + i
            }
        }
        0xFE => 0x055A, // ՚
        _ => return c,
    };
    char::from_u32(mapped).unwrap_or(c)
}

/// ArmSCII-8 text (as Word stores it) in Unicode.
pub fn to_unicode(text: &str) -> String {
    text.chars().map(map_char).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_and_punctuation() {
        // "Բարև ձեզ։" typed in Arial Armenian.
        let legacy: String = [0xB4u32, 0xB3, 0xF1, 0xA2, 0x20, 0xD3, 0xBB, 0xBD, 0xA3]
            .iter()
            .map(|&b| char::from_u32(b).unwrap())
            .collect();
        assert_eq!(to_unicode(&legacy), "Բարև ձեզ։");
        assert_eq!(map_char('\u{F0B2}'), 'Ա');
        assert_eq!(map_char('\u{00FC}'), 'Ֆ');
        assert_eq!(map_char('\u{00FD}'), 'ֆ');
        assert_eq!(map_char('A'), 'A');
    }

    #[test]
    fn legacy_font_names() {
        for f in [
            "Arial Armenian",
            "Times Armenian",
            "ArTarumianTimes",
            "Arial LatArm",
            "Dallak Helv",
        ] {
            assert!(is_legacy_font(f), "{f}");
        }
        for f in [
            "Noto Sans Armenian",
            "Arial AMU",
            "GHEA Grapalat",
            "Sylfaen",
            "Calibri",
            "",
        ] {
            assert!(!is_legacy_font(f), "{f}");
        }
    }
}
