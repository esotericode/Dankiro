"""Textures for the world round the arena (tools/build_scenery.py): tileable bark, leaf cards,
lacquer weathering, copper roofing and the torii's plaque. numpy and PIL; colour arrays are
sRGB 0..1, top row first; all tileable except the plaque.
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from .floor_textures import blur, fnoise, normal_map, smoothstep, voronoi


def _mix(a, b, t):
    t = np.asarray(t)[..., None] if np.ndim(t) == 2 else t
    return a * (1.0 - t) + np.asarray(b) * t


def _col(rgb, h, w):
    return np.broadcast_to(np.asarray(rgb, dtype=float), (h, w, 3)).copy()


# ------------------------------------------------------------------ bark
def bark_sugi(size=512, seed=31):
    """Cryptomeria: long reddish fibres peeling in vertical ribbons. Tile: 1 m around x 2 m up.
    Returns (albedo, normal map, roughness)."""
    h = w = size
    strips = fnoise(h, w, 26.0, seed, octaves=3, gain=0.55, aniso=9.0, angle=math.pi / 2)
    fine = fnoise(h, w, 5.0, seed + 1, octaves=2, aniso=6.0, angle=math.pi / 2)
    blot = fnoise(h, w, 90.0, seed + 2, octaves=2)
    ridge = np.tanh(strips * 1.3)
    groove = smoothstep(-0.2, -0.8, strips)
    base = _col((0.36, 0.215, 0.145), h, w)
    light = np.array([0.52, 0.42, 0.34])
    dark = np.array([0.1, 0.06, 0.045])
    c = _mix(base, light, smoothstep(0.2, 1.2, ridge + 0.4 * fine) * 0.7)
    c = _mix(c, dark, groove * 0.85)
    c *= (0.85 + 0.25 * smoothstep(-1.0, 1.0, blot))[..., None]
    hgt = ridge * 2.0 + fine * 0.5 - groove * 1.5
    return c, normal_map(blur(hgt, 0.7), 1.6), np.clip(0.82 + 0.1 * groove, 0, 1)


def bark_pine(size=512, seed=41):
    """Black pine: dark grey plates split by deep cracks. Tile: 1 m around x 1.5 m up."""
    h = w = size
    d1, d2, idx, _ = voronoi(h, w, 70, seed, warp=6.0, warp_scale=14.0)
    edge = d2 - d1
    crack = smoothstep(7.0, 1.0, edge)
    rng = np.random.default_rng(seed)
    tone = rng.uniform(0.75, 1.15, idx.max() + 1)[idx]
    fine = fnoise(h, w, 4.0, seed + 1, octaves=2)
    c = _col((0.27, 0.245, 0.23), h, w) * tone[..., None]
    c *= (0.9 + 0.15 * fine)[..., None]
    c = _mix(c, (0.05, 0.04, 0.035), crack * 0.9)
    # a reddish inner bark shows where plates have flaked
    flake = smoothstep(0.55, 0.9, 0.5 + 0.2 * fnoise(h, w, 20.0, seed + 2)) * (1.0 - crack)
    c = _mix(c, (0.45, 0.25, 0.16), flake * 0.5)
    hgt = (1.0 - crack) * (1.0 + 0.3 * fine) - flake * 0.4
    return c, normal_map(blur(hgt * 3.0, 0.8), 1.4), np.clip(0.85 + 0.1 * crack, 0, 1)


# ------------------------------------------------------------------ foliage
def _wrap_draw(draw, size, fn):
    for ox in (-size, 0, size):
        for oy in (-size, 0, size):
            fn(draw, ox, oy)


def needles(size=512, seed=51, palette=((0.1, 0.17, 0.08), (0.2, 0.3, 0.12), (0.06, 0.11, 0.07))):
    """Conifer foliage card: clusters of needles on twigs, with gaps between them. RGBA, alpha =
    coverage (the foliage shader cuts its leafy fringe with it). Tile: ~0.6 m."""
    rng = np.random.default_rng(seed)
    S = size * 2
    rgb = Image.new("RGB", (S, S), (0, 0, 0))
    cov = Image.new("L", (S, S), 0)
    dr, dc = ImageDraw.Draw(rgb), ImageDraw.Draw(cov)
    pal = [np.array(p) for p in palette]
    for _ in range(900):
        cx, cy = rng.uniform(0, S, 2)
        base_ang = rng.uniform(0, 2 * math.pi)
        tone = pal[rng.integers(0, len(pal))] * rng.uniform(0.8, 1.25)
        for _ in range(int(rng.integers(10, 22))):
            a = base_ang + rng.normal(0.0, 0.7)
            ln = rng.uniform(10, 26)
            r0 = rng.uniform(0, 10)
            x0, y0 = cx + math.cos(a) * r0, cy + math.sin(a) * r0
            x1, y1 = x0 + math.cos(a) * ln, y0 + math.sin(a) * ln
            col = tuple(int(255 * min(1.0, v * rng.uniform(0.85, 1.2))) for v in tone)
            wdt = int(rng.integers(2, 4))

            def fn(d, ox, oy, x0=x0, y0=y0, x1=x1, y1=y1, col=col, wdt=wdt):
                d.line([(x0 + ox, y0 + oy), (x1 + ox, y1 + oy)], fill=col, width=wdt)
            _wrap_draw(dr, S, fn)
            _wrap_draw(dc, S, lambda d, ox, oy, x0=x0, y0=y0, x1=x1, y1=y1, wdt=wdt:
                       d.line([(x0 + ox, y0 + oy), (x1 + ox, y1 + oy)], fill=255, width=wdt))
    rgb = np.asarray(rgb.resize((size, size), Image.LANCZOS), dtype=float) / 255.0
    a = np.asarray(cov.resize((size, size), Image.LANCZOS), dtype=float) / 255.0
    # fill the gaps with a dark underlayer so holes read as depth, not as sky
    under = np.array(palette[-1]) * 0.55
    rgb = rgb + under * (1.0 - a[..., None])
    a = np.clip(a * 1.35, 0, 1)
    return np.dstack([np.clip(rgb, 0, 1), a])


def maple_leaves(size=512, seed=61):
    """Japanese maple in autumn: small five-lobed leaves, scarlet through orange to a little gold."""
    rng = np.random.default_rng(seed)
    S = size * 2
    rgb = Image.new("RGB", (S, S), (0, 0, 0))
    cov = Image.new("L", (S, S), 0)
    dr, dc = ImageDraw.Draw(rgb), ImageDraw.Draw(cov)
    pal = [np.array(p) for p in ((0.62, 0.07, 0.04), (0.72, 0.16, 0.05), (0.8, 0.32, 0.07), (0.5, 0.05, 0.05),
                                 (0.78, 0.5, 0.12))]
    wts = np.array([0.3, 0.28, 0.2, 0.15, 0.07])
    for _ in range(1500):
        cx, cy = rng.uniform(0, S, 2)
        r = rng.uniform(9, 17)
        rot = rng.uniform(0, 2 * math.pi)
        pts = []
        for k in range(10):
            ang = rot + k * math.pi / 5
            rr = r if k % 2 == 0 else r * 0.42
            pts.append((cx + math.cos(ang) * rr, cy + math.sin(ang) * rr))
        tone = pal[rng.choice(len(pal), p=wts / wts.sum())] * rng.uniform(0.8, 1.15)
        col = tuple(int(255 * min(1.0, v)) for v in tone)

        def fn(d, ox, oy, pts=pts, col=col):
            d.polygon([(x + ox, y + oy) for x, y in pts], fill=col)
        _wrap_draw(dr, S, fn)
        _wrap_draw(dc, S, lambda d, ox, oy, pts=pts: d.polygon([(x + ox, y + oy) for x, y in pts], fill=255))
    rgb = np.asarray(rgb.resize((size, size), Image.LANCZOS), dtype=float) / 255.0
    a = np.asarray(cov.resize((size, size), Image.LANCZOS), dtype=float) / 255.0
    rgb = rgb + np.array([0.18, 0.03, 0.02]) * (1.0 - a[..., None])
    return np.dstack([np.clip(rgb, 0, 1), np.clip(a * 1.3, 0, 1)])


# ------------------------------------------------------------------ built things
def grime(size=512, seed=71):
    """Weathering for lacquered wood and stone: R = grime (rain streaks running down, blotches),
    G = wear (chipped, sun-faded spots). Tile: 1 m."""
    h = w = size
    streak = fnoise(h, w, 12.0, seed, octaves=2, aniso=10.0, angle=math.pi / 2)
    blot = fnoise(h, w, 70.0, seed + 1, octaves=3)
    g = np.clip(0.35 + 0.25 * streak + 0.2 * blot, 0, 1)
    chips = smoothstep(0.62, 0.75, 0.5 + 0.2 * fnoise(h, w, 3.0, seed + 2)) * smoothstep(0.0, 0.8, blot)
    fade = np.clip(0.5 + 0.2 * fnoise(h, w, 120.0, seed + 3, octaves=2), 0, 1)
    return np.stack([g, np.clip(chips + 0.3 * fade, 0, 1), fade], 2)


def copper_roof(size=512, seed=81):
    """Weathered copper roofing: standing seams and courses of plates under a verdigris patina.
    Tile: 1 m. Returns (albedo, normal map)."""
    h = w = size
    y, x = np.mgrid[0:h, 0:w].astype(float) / size
    seam_v = np.abs(((x * 2.0) % 1.0) - 0.5) * 2.0          # two standing seams per metre
    seam = smoothstep(0.92, 0.99, seam_v)
    course = np.abs(((y * 3.0) % 1.0) - 0.5) * 2.0          # three courses per metre
    lap = smoothstep(0.9, 0.98, course)
    pat = fnoise(h, w, 30.0, seed, octaves=3, gain=0.6)
    streak = fnoise(h, w, 10.0, seed + 1, octaves=2, aniso=8.0, angle=math.pi / 2)
    c = _mix(_col((0.2, 0.43, 0.39), h, w), (0.1, 0.24, 0.22), smoothstep(-0.8, 1.0, pat) * 0.8)
    c = _mix(c, (0.3, 0.2, 0.12), smoothstep(0.8, 1.8, streak) * 0.35)      # brown copper showing
    c *= (1.0 - 0.3 * lap - 0.15 * seam)[..., None]
    hgt = seam * 1.5 + lap * 0.8 + 0.1 * pat
    return c, normal_map(blur(hgt * 3.0, 1.0), 1.2)


def plaque(font_path, text="月門", w=384, h=640):
    """The torii's plaque: black lacquer, a raised gilt border and the name in gilt brush script,
    top to bottom. RGBA: rgb colour, a = gilt (metallic) mask."""
    img = Image.new("RGB", (w, h), (12, 11, 12))
    gilt = Image.new("L", (w, h), 0)
    d, g = ImageDraw.Draw(img), ImageDraw.Draw(gilt)
    gold = (206, 160, 72)
    for k, inset in enumerate((10, 24)):
        box = [inset, inset, w - inset, h - inset]
        d.rectangle(box, outline=gold, width=8 if k == 0 else 3)
        g.rectangle(box, outline=255, width=8 if k == 0 else 3)
    if font_path:
        font = ImageFont.truetype(font_path, int(w * 0.62))
        chars = list(text)
        step = (h - 110) / len(chars)
        for i, ch in enumerate(chars):
            bb = d.textbbox((0, 0), ch, font=font)
            tw, th = bb[2] - bb[0], bb[3] - bb[1]
            cx = (w - tw) / 2 - bb[0]
            cy = 55 + step * i + (step - th) / 2 - bb[1]
            d.text((cx, cy), ch, font=font, fill=gold)
            g.text((cx, cy), ch, font=font, fill=255)
    rgb = np.asarray(img, dtype=float) / 255.0
    a = np.asarray(gilt, dtype=float) / 255.0
    return np.dstack([rgb, a])


def wood(size=512, seed=91):
    """Weathered boards, silver-brown, the grain running up them: four boards to the 1 m tile.
    Returns (albedo, normal)."""
    h = w = size
    grain = fnoise(h, w, 3.0, seed, octaves=2, aniso=14.0, angle=math.pi / 2)
    streak = fnoise(h, w, 18.0, seed + 1, octaves=2, aniso=6.0, angle=math.pi / 2)
    x = np.arange(w)[None, :].repeat(h, 0)
    board = (x * 4) // w
    rng = np.random.default_rng(seed)
    tone = rng.uniform(0.8, 1.15, 4)[board]
    shift = rng.uniform(0, 1, 4)[board]
    rings = np.sin((x / w * 4 % 1.0) * 23.0 + shift * 9.0 + grain * 1.5)
    gap = smoothstep(0.012, 0.0, np.minimum((x / w * 4) % 1.0, 1.0 - (x / w * 4) % 1.0))
    c = _col((0.3, 0.25, 0.2), h, w) * tone[..., None]
    c = _mix(c, (0.42, 0.39, 0.35), smoothstep(0.3, 1.2, streak) * 0.5)      # silvered by weather
    c *= (0.9 + 0.08 * rings + 0.05 * grain)[..., None]
    c = _mix(c, (0.05, 0.04, 0.03), gap * 0.9)
    hgt = 0.3 * rings + 0.4 * grain - 2.0 * gap
    return np.clip(c, 0, 1), normal_map(blur(hgt, 0.6), 1.2)


def ishigaki(size=1024, seed=101):
    """A dry-laid stone wall, 3 m to the tile: irregular fieldstones bulging out of dark gaps.
    Returns (RGBA albedo with alpha = height: 0 deep in the gaps, 1 on the stone faces, normal)."""
    h = w = size
    d1, d2, idx, _ = voronoi(h, w, 60, seed, warp=14.0, warp_scale=40.0)
    edge = d2 - d1
    rng = np.random.default_rng(seed)
    n = idx.max() + 1
    face = smoothstep(2.0, 26.0, edge)
    bulge = np.sqrt(np.clip(face, 0, 1))
    tone = rng.uniform(0.7, 1.2, n)[idx]
    warm = rng.uniform(-1.0, 1.0, n)[idx]
    fine = fnoise(h, w, 3.0, seed + 1, octaves=3, gain=0.6)
    blot = fnoise(h, w, 60.0, seed + 2, octaves=2)
    c = _col((0.33, 0.32, 0.3), h, w) * tone[..., None]
    c = c + np.array([0.03, 0.01, -0.02]) * warm[..., None]
    c *= (0.85 + 0.12 * fine + 0.1 * blot)[..., None]
    c *= (0.55 + 0.45 * bulge)[..., None]                      # the stone's edges turn away into shadow
    c = _mix(c, (0.03, 0.028, 0.025), smoothstep(6.0, 1.0, edge) * 0.92)
    hgt = bulge * (1.0 + 0.1 * fine) * 8.0
    return np.dstack([np.clip(c, 0, 1), np.clip(bulge, 0, 1)]), normal_map(blur(hgt, 1.2), 0.6)


def gravel(size=512, seed=111):
    """White shrine gravel, 0.8 m to the tile: rounded pebbles, pale greys, dark between.
    Returns (albedo, normal)."""
    h = w = size
    d1, d2, idx, _ = voronoi(h, w, 1500, seed, warp=1.5, warp_scale=4.0)
    edge = d2 - d1
    rng = np.random.default_rng(seed)
    n = idx.max() + 1
    peb = np.sqrt(np.clip(smoothstep(0.3, 5.0, edge), 0, 1))
    tone = rng.uniform(0.6, 1.1, n)[idx]
    tint = rng.uniform(-1, 1, n)[idx]
    c = _col((0.62, 0.61, 0.58), h, w) * tone[..., None] + np.array([0.02, 0.01, -0.015]) * tint[..., None]
    c *= (0.5 + 0.5 * peb)[..., None]
    c = _mix(c, (0.08, 0.075, 0.07), smoothstep(1.2, 0.2, edge) * 0.8)
    return np.clip(c, 0, 1), normal_map(blur(peb * 4.0, 0.7), 0.7)
