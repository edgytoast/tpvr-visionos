#!/usr/bin/env python3
# Builds res/logo.png and res/icon.png from visionos/art/tpvr-icon.svg: the icon as it is, and the
# logo as that head in a VR headset beside a "TPVR" wordmark, whose letters are Alegreya SC Bold's
# outlines (res/, SIL OFL), written into visionos/art/tpvr-logo.svg first. (The sources live here,
# not in res/, which the app carries whole.)
#
#   pip install cairosvg fonttools   (cairosvg needs Cairo: brew install cairo)
#   visionos/art/make-art.py
import pathlib, re
import cairosvg
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

art = pathlib.Path(__file__).resolve().parent
res = art.parent.parent / "res"
icon = (art / "tpvr-icon.svg").read_text()
head = re.search(r"<g stroke-linejoin.*</g>", icon, re.S).group(0)
defs = re.search(r"<defs>.*?</defs>", icon, re.S).group(0)

def word(text, x, baseline, size):
    """The text's outlines as one path, left edge at x; and its width."""
    font = TTFont(res / "AlegreyaSC-Bold.ttf")
    glyphs, cmap = font.getGlyphSet(), font.getBestCmap()
    scale = size / font["head"].unitsPerEm
    pen = SVGPathPen(glyphs)
    advance = 0
    for char in text:
        name = cmap[ord(char)]
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x + advance, baseline)))
        advance += glyphs[name].width * scale
    return pen.getCommands(), advance

# The headset over her eye: a visor, its strap and three cameras.
headset = """
  <g stroke="#141018" stroke-linejoin="round">
    <path d="M300 520 C 296 470, 336 448, 512 448 C 688 448, 728 470, 724 520 L 724 600 C 724 640, 690 654, 512 654 C 334 654, 300 640, 300 600 Z" fill="#f4f5f8" stroke-width="16"/>
    <path d="M320 600 C 400 628, 624 628, 704 600" fill="none" stroke="#c9ced8" stroke-width="10"/>
    <ellipse cx="430" cy="548" rx="22" ry="30" fill="#1d2230" stroke-width="6"/>
    <ellipse cx="512" cy="548" rx="22" ry="30" fill="#1d2230" stroke-width="6"/>
    <ellipse cx="594" cy="548" rx="22" ry="30" fill="#1d2230" stroke-width="6"/>
  </g>"""

tp, tp_width = word("TP", 0, 0, 300)
vr, vr_width = word("VR", 0, 0, 300)
left = 470
logo = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1250 495" width="1250" height="495">
  <!-- TPVR's logo: its icon's Midna in a VR headset, and the wordmark (Alegreya SC Bold's outlines).
       Built by make-art.py from tpvr-icon.svg: edit those, not this. -->
  {defs}
  <g transform="translate(-36 26) scale(0.46)">
  {head}
  {headset}
  </g>
  <g transform="translate({left} 345)" stroke-linejoin="round">
    <path d="{tp}" fill="none" stroke="#141018" stroke-width="22"/>
    <path d="{tp}" fill="#e3313d"/>
  </g>
  <g transform="translate({left + tp_width + 12} 345)" stroke-linejoin="round">
    <path d="{vr}" fill="none" stroke="#2fe8ff" stroke-opacity="0.12" stroke-width="44"/>
    <path d="{vr}" fill="none" stroke="#2fe8ff" stroke-opacity="0.22" stroke-width="28"/>
    <path d="{vr}" fill="none" stroke="#2fe8ff" stroke-opacity="0.4" stroke-width="14"/>
    <path d="{vr}" fill="#2fe8ff"/>
  </g>
</svg>
"""
(art / "tpvr-logo.svg").write_text(logo)
cairosvg.svg2png(bytestring=logo.encode(), write_to=str(res / "logo.png"), output_width=1250, output_height=495)
cairosvg.svg2png(bytestring=icon.encode(), write_to=str(res / "icon.png"), output_width=1024, output_height=1024)
print(f"logo.png, icon.png (wordmark {tp_width + 12 + vr_width:.0f} wide from x {left})")
