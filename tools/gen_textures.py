"""Renders the brush kanji textures and installs the UI fonts.

  textures/kanji_danger.png       危  perilous-attack warning (white, tinted in game)
  textures/kanji_danger_icon.png  危  small red icon for the controls sheet
  textures/kanji_death.png        死  death screen
  textures/kanji_execution.png    忍殺 victory ("shinobi execution")
  fonts/ui_sans.ttf               Jost, variable weight (Latin): the UI's text, OFL
  fonts/ui_serif.ttf              Cormorant Garamond, variable weight (Latin): titles and names, OFL

Fonts are fetched into tools/.cache on first run (all SIL OFL 1.1): Yuji Boku from the npm
registry (fontsource), Jost and Cormorant Garamond from the Google Fonts repository on GitHub,
cut down to Latin with the weight axis kept. The kanji are rendered with Yuji Boku; only the
rendered images ship with the game.
"""
import io
import os
import tarfile
import urllib.request

import numpy as np
from fontTools import subset
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "tools", ".cache")
PACKAGES = {
    "yuji-boku": ("https://registry.npmjs.org/@fontsource/yuji-boku/-/yuji-boku-5.3.0.tgz",
                  "package/files/yuji-boku-japanese-400-normal.woff"),
}
GOOGLE_FONTS = "https://raw.githubusercontent.com/google/fonts/main/ofl/"
VARIABLE = {        # name: (font, license) under GOOGLE_FONTS
    "jost": ("jost/Jost%5Bwght%5D.ttf", "jost/OFL.txt"),
    "cormorant-garamond": ("cormorantgaramond/CormorantGaramond%5Bwght%5D.ttf", "cormorantgaramond/OFL.txt"),
}
# Basic Latin, Latin-1, general punctuation, arrows, the multiplication sign and a few shapes.
LATIN = "U+0020-007E,U+00A0-00FF,U+0131,U+0152-0153,U+02C6,U+02DA,U+02DC,U+2010-2027,U+2030-203A,U+2044,U+20AC," \
        "U+2122,U+2190-2193,U+2212,U+25A0-25CF"


def fetch_font(name):
    os.makedirs(CACHE, exist_ok=True)
    ttf = os.path.join(CACHE, name + ".ttf")
    lic = os.path.join(CACHE, name + "-LICENSE.txt")
    if os.path.exists(ttf):
        return ttf, lic
    url, member = PACKAGES[name]
    print("downloading", url)
    data = urllib.request.urlopen(url).read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        woff = tf.extractfile(member).read()
        with open(lic, "wb") as f:
            f.write(tf.extractfile("package/LICENSE").read())
    font = TTFont(io.BytesIO(woff))
    font.flavor = None
    font.save(ttf)
    return ttf, lic


def fetch_variable(name):
    """A variable font from Google Fonts cut down to LATIN (weight axis and OpenType features kept)."""
    os.makedirs(CACHE, exist_ok=True)
    ttf = os.path.join(CACHE, name + "-var.ttf")
    lic = os.path.join(CACHE, name + "-var-OFL.txt")
    if os.path.exists(ttf):
        return ttf, lic
    font_path, lic_path = VARIABLE[name]
    print("downloading", GOOGLE_FONTS + font_path)
    data = urllib.request.urlopen(GOOGLE_FONTS + font_path).read()
    with open(lic, "wb") as f:
        f.write(urllib.request.urlopen(GOOGLE_FONTS + lic_path).read())
    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    options.glyph_names = False
    font = TTFont(io.BytesIO(data))
    sub = subset.Subsetter(options)
    sub.populate(unicodes=subset.parse_unicodes(LATIN))
    sub.subset(font)
    font.save(ttf)
    return ttf, lic


def render(text, font_path, size, canvas, glow=True, color=(255, 255, 255), glow_color=(255, 255, 255),
           glow_radius=18, glow_alpha=0.55, spacing=0, seed=1):
    W, H = canvas
    font = ImageFont.truetype(font_path, size)
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    bbox = d.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (W - tw) // 2 - bbox[0]
    y = (H - th) // 2 - bbox[1]
    if spacing and len(text) > 1:
        # draw characters one by one with extra spacing
        widths = [d.textbbox((0, 0), ch, font=font)[2] for ch in text]
        total = sum(widths) + spacing * (len(text) - 1)
        cx = (W - total) // 2
        for ch, wch in zip(text, widths):
            d.text((cx - d.textbbox((0, 0), ch, font=font)[0], y), ch, font=font, fill=255)
            cx += wch + spacing
    else:
        d.text((x, y), text, font=font, fill=255)
    a = np.asarray(mask).astype(np.float32) / 255.0
    # ink texture: slightly uneven density, rougher toward stroke edges
    rng = np.random.default_rng(seed)
    grain = np.asarray(Image.fromarray((rng.random((H // 4, W // 4)) * 255).astype(np.uint8)).resize((W, H), Image.BICUBIC)) / 255.0
    edge = np.asarray(mask.filter(ImageFilter.GaussianBlur(2.0))).astype(np.float32) / 255.0
    ink = np.clip(a * (0.86 + 0.14 * grain) * np.clip(edge * 1.6, 0, 1) + a * 0.1, 0, 1)
    out = np.zeros((H, W, 4), np.float32)
    if glow:
        g = np.asarray(mask.filter(ImageFilter.GaussianBlur(glow_radius))).astype(np.float32) / 255.0
        g = np.clip(g * 1.6, 0, 1) * glow_alpha
        out[..., :3] = np.array(glow_color, np.float32) / 255.0
        out[..., 3] = g
    fill = np.array(color, np.float32) / 255.0
    alpha = ink + out[..., 3] * (1 - ink)
    rgb = (fill[None, None, :] * ink[..., None] + out[..., :3] * (out[..., 3] * (1 - ink))[..., None]) / np.maximum(alpha, 1e-6)[..., None]
    img = np.dstack([rgb, alpha])
    return Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA")


def main():
    brush, brush_lic = fetch_font("yuji-boku")
    tex = os.path.join(ROOT, "textures")
    os.makedirs(tex, exist_ok=True)
    render("危", brush, 400, (512, 512), glow_radius=22, glow_alpha=0.6).save(os.path.join(tex, "kanji_danger.png"))
    render("危", brush, 56, (64, 64), glow=False, color=(255, 70, 50)).save(os.path.join(tex, "kanji_danger_icon.png"))
    render("死", brush, 760, (1024, 1024), glow_radius=34, glow_alpha=0.45, seed=3).save(os.path.join(tex, "kanji_death.png"))
    render("忍殺", brush, 560, (1400, 800), glow_radius=30, glow_alpha=0.45, spacing=40, seed=5).save(
        os.path.join(tex, "kanji_execution.png"))
    fonts = os.path.join(ROOT, "fonts")
    os.makedirs(fonts, exist_ok=True)
    for name, out, lic_out in [("jost", "ui_sans.ttf", "OFL-Jost.txt"),
                               ("cormorant-garamond", "ui_serif.ttf", "OFL-CormorantGaramond.txt")]:
        ttf, lic = fetch_variable(name)
        with open(ttf, "rb") as src, open(os.path.join(fonts, out), "wb") as dst:
            dst.write(src.read())
        with open(lic, "rb") as src, open(os.path.join(fonts, lic_out), "wb") as dst:
            dst.write(src.read())
    with open(brush_lic, "rb") as src, open(os.path.join(tex, "OFL-YujiBoku.txt"), "wb") as dst:
        dst.write(src.read())
    print("textures + fonts written")


if __name__ == "__main__":
    main()
