#!/usr/bin/env python3
"""Builds the sample documents shipped in Resources/Samples (Armenian text in every format).

Needs python-docx, Pillow and LibreOffice (soffice) with Noto Sans/Serif Armenian installed.
Usage: python3 tools/make_samples.py <output folder>
"""
import io
import os
import shutil
import subprocess
import sys
import tempfile

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Cm
from PIL import Image, ImageDraw

TITLE = "Հայերեն փաստաթղթի օրինակ"
INTRO = ("Բարև ձեզ։ Սա HayDocs ծրագրի փորձնական փաստաթուղթն է։ Այստեղ կարող եք կարդալ "
         "PDF, Word և ODT ֆայլեր, ինչպես նաև նկարել Apple Pencil-ով։")
UPPER = "Ա Բ Գ Դ Ե Զ Է Ը Թ Ժ Ի Լ Խ Ծ Կ Հ Ձ Ղ Ճ Մ Յ Ն Շ Ո Չ Պ Ջ Ռ Ս Վ Տ Ր Ց Ւ Փ Ք Օ Ֆ"
LOWER = "ա բ գ դ ե զ է ը թ ժ ի լ խ ծ կ հ ձ ղ ճ մ յ ն շ ո չ պ ջ ռ ս վ տ ր ց ւ փ ք օ ֆ և"
POEM = [
    "Ես իմ անուշ Հայաստանի արևահամ բառն եմ սիրում,",
    "Մեր հին սազի ողբանվագ, լացակումած լարն եմ սիրում,",
    "Արնանման ծաղիկների ու վարդերի բույրը վառման,",
    "Ու նաիրյան աղջիկների հեզաճկուն պարն եմ սիրում։",
]
POET = "Եղիշե Չարենց"
RUSSIAN = "Русский текст в том же документе: проверка смешанного набора."
ENGLISH = "English text: The quick brown fox jumps over the lazy dog."
LIST = ["Կարդալ փաստաթղթեր", "Նկարել Apple Pencil-ով", "Պահպանել և արտահանել"]
TABLE = [("Անուն", "Քաղաք", "Հեռախոս"),
         ("Արամ", "Երևան", "010 12-34-56"),
         ("Անի", "Գյումրի", "0312 3-45-67"),
         ("Мария", "Ванадзор", "0322 4-56-78")]
PAGE2_TITLE = "Երկրորդ էջ"
PAGE2 = "Այս էջում կարող եք փորձել նկարել։ Ընտրեք մատիտը և գրեք ձեր նշումները։"

# ArmSCII-8: Unicode -> byte, for the old 8-bit fonts ("Arial Armenian", "Times Armenian").
ARMSCII = {0x00A0: 0xA0, 0x0587: 0xA2, 0x0589: 0xA3, 0x00BB: 0xA6, 0x00AB: 0xA7, 0x2014: 0xA8,
           0x055D: 0xAA, 0x058A: 0xAD, 0x2026: 0xAE, 0x055C: 0xAF, 0x055B: 0xB0, 0x055E: 0xB1,
           0x055A: 0xFE}
for i in range(38):
    ARMSCII[0x0531 + i] = 0xB2 + 2 * i
    ARMSCII[0x0561 + i] = 0xB3 + 2 * i


def to_armscii(text):
    """The Latin-1 characters an old ArmSCII font shows as Armenian letters."""
    return "".join(chr(ARMSCII[ord(c)]) if ord(c) in ARMSCII else c for c in text)


def set_font(run, name, size=None, bold=None, italic=None, color=None):
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    fonts = rpr.find(qn("w:rFonts"))
    if fonts is None:
        fonts = rpr.makeelement(qn("w:rFonts"), {})
        rpr.insert(0, fonts)
    for attr in ("w:ascii", "w:hAnsi", "w:cs", "w:eastAsia"):
        fonts.set(qn(attr), name)
    if size:
        run.font.size = Pt(size)
    if bold is not None:
        run.bold = bold
    if italic is not None:
        run.italic = italic
    if color:
        run.font.color.rgb = RGBColor(*color)


def picture():
    img = Image.new("RGB", (600, 160), (246, 248, 252))
    d = ImageDraw.Draw(img)
    colors = [(217, 0, 18), (0, 51, 160), (242, 168, 0)]  # the flag's red, blue, apricot
    for i, c in enumerate(colors):
        d.rectangle([0, 20 + i * 40, 600, 20 + (i + 1) * 40], fill=c)
    buf = io.BytesIO()
    img.save(buf, "PNG")
    buf.seek(0)
    return buf


def unicode_docx(path):
    doc = Document()
    sec = doc.sections[0]
    sec.page_width, sec.page_height = Cm(21), Cm(29.7)
    sec.left_margin = sec.right_margin = Cm(2)
    sec.top_margin = sec.bottom_margin = Cm(2)

    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_font(p.add_run(TITLE), "GHEA Grapalat", 20, bold=True, color=(20, 50, 120))

    p = doc.add_paragraph()
    set_font(p.add_run(INTRO), "Sylfaen", 12)

    p = doc.add_paragraph()
    set_font(p.add_run("Հայոց այբուբեն"), "GHEA Grapalat", 14, bold=True)
    p = doc.add_paragraph()
    set_font(p.add_run(UPPER), "Sylfaen", 13)
    p = doc.add_paragraph()
    set_font(p.add_run(LOWER), "Sylfaen", 13)

    for line in POEM:
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        set_font(p.add_run(line), "GHEA Grapalat", 12, italic=True)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    set_font(p.add_run(POET), "Arial AMU", 11, bold=True)

    p = doc.add_paragraph()
    set_font(p.add_run(RUSSIAN), "Times New Roman", 12)
    p = doc.add_paragraph()
    set_font(p.add_run(ENGLISH), "Calibri", 12)

    for item in LIST:
        p = doc.add_paragraph(style="List Bullet")
        set_font(p.add_run(item), "Sylfaen", 12)

    table = doc.add_table(rows=len(TABLE), cols=3)
    table.style = "Table Grid"
    for r, row in enumerate(TABLE):
        for c, value in enumerate(row):
            cell = table.cell(r, c)
            cell.text = ""
            set_font(cell.paragraphs[0].add_run(value), "Sylfaen", 11, bold=(r == 0))

    doc.add_paragraph()
    doc.add_picture(picture(), width=Cm(12))

    p = doc.add_paragraph()
    p.add_run().add_break(WD_BREAK.PAGE)
    set_font(p.add_run(PAGE2_TITLE), "GHEA Grapalat", 16, bold=True)
    p = doc.add_paragraph()
    set_font(p.add_run(PAGE2), "Sylfaen", 12)
    doc.save(path)


def armscii_docx(path):
    doc = Document()
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_font(p.add_run(to_armscii("Հին ArmSCII տառատեսակ")), "Arial Armenian", 18, bold=True)
    p = doc.add_paragraph()
    set_font(p.add_run("Этот документ набран старым шрифтом «Arial Armenian» в кодировке ArmSCII-8. "
                       "Без перевода в Юникод на телефоне видны латинские буквы."), "Times New Roman", 11)
    p = doc.add_paragraph()
    set_font(p.add_run(to_armscii(INTRO)), "Arial Armenian", 12)
    for line in POEM:
        p = doc.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        set_font(p.add_run(to_armscii(line)), "Times Armenian", 13)
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
    set_font(p.add_run(to_armscii(POET)), "Arial Armenian", 11, bold=True)
    doc.save(path)


def convert(src, fmt, outdir):
    subprocess.run(["soffice", "--headless", "--convert-to", fmt, "--outdir", outdir, src],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Resources/Samples"
    os.makedirs(out, exist_ok=True)
    tmp = tempfile.mkdtemp()
    word = os.path.join(tmp, "Пример Word.docx")
    unicode_docx(word)
    arm = os.path.join(tmp, "Пример ArmSCII.docx")
    armscii_docx(arm)
    convert(word, "odt", tmp)
    convert(word, "rtf", tmp)
    convert(word, "pdf", tmp)
    doc_src = os.path.join(tmp, "Пример DOC.docx")
    shutil.copy(word, doc_src)
    convert(doc_src, "doc:MS Word 97", tmp)
    os.remove(doc_src)
    os.rename(os.path.join(tmp, "Пример Word.odt"), os.path.join(tmp, "Пример ODT.odt"))
    os.rename(os.path.join(tmp, "Пример Word.rtf"), os.path.join(tmp, "Пример RTF.rtf"))
    os.rename(os.path.join(tmp, "Пример Word.pdf"), os.path.join(tmp, "Пример PDF.pdf"))
    with open(os.path.join(tmp, "Пример TXT.txt"), "w", encoding="utf-8") as f:
        f.write(TITLE + "\n\n" + INTRO + "\n\n" + "\n".join(POEM) + "\n" + POET + "\n\n" + RUSSIAN + "\n")
    for name in sorted(os.listdir(tmp)):
        shutil.copy(os.path.join(tmp, name), os.path.join(out, name))
        print(name, os.path.getsize(os.path.join(out, name)))
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
