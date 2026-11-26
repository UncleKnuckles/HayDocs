#!/bin/sh
# What macOS Quick Look makes of the same files (its preview HTML, if it still writes one, and thumbnails).
set -u
O=out/mac
mkdir -p "$O/preview" "$O/thumbs"
{ sw_vers; uname -m; xcodebuild -version; } > "$O/tools.txt" 2>&1
ls /System/Library/QuickLook/ > "$O/generators.txt" 2>&1
qlmanage -m plugins > "$O/plugins.txt" 2>&1 &
p=$!; sleep 20; kill $p 2>/dev/null
for f in probe/docs/p1_A_engine.docx probe/docs/p1_B_vpage.docx probe/docs/p1_G_vmltext.docx probe/docs/p1_I1_alt_page.docx probe/docs/p2_A_engine.docx probe/docs/p2_B_vpage.docx; do
  perl -e 'alarm shift; exec @ARGV' 60 qlmanage -p -o "$O/preview" "$f" >> "$O/qlmanage.log" 2>&1
  perl -e 'alarm shift; exec @ARGV' 60 qlmanage -t -s 1400 -o "$O/thumbs" "$f" >> "$O/qlmanage.log" 2>&1
done
ls -R "$O" | head -80
