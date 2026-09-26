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


# ------------------------------------------------------------------ leaf cards
# Sprays of foliage for the cards that fringe each crown clump: RGBA on transparent, the twig
# entering at the bottom middle. Drawn at twice the size and scaled down for clean edges.
def _card(size, draw_fn, seed):
    S = size * 2
    rgb = Image.new("RGB", (S, S), (0, 0, 0))
    cov = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(rgb), ImageDraw.Draw(cov), S, np.random.default_rng(seed))
    rgb = np.asarray(rgb.resize((size, size), Image.LANCZOS), dtype=float) / 255.0
    a = np.asarray(cov.resize((size, size), Image.LANCZOS), dtype=float) / 255.0
    # bleed colour into the transparent border so mipmaps don't darken the edges
    wsum = blur(a, 6.0)[..., None] + 1e-4
    fill = np.stack([blur(rgb[..., c] * a, 6.0) for c in range(3)], 2) / wsum
    rgb = np.where(a[..., None] > 0.02, rgb / np.maximum(a[..., None], 1e-3) * (a[..., None] > 0.02), fill)
    return np.dstack([np.clip(rgb, 0, 1), a])


def _tone(rng, pal, jitter=0.15):
    c = np.asarray(pal[rng.integers(0, len(pal))]) * rng.uniform(1.0 - jitter, 1.0 + jitter)
    return tuple(int(255 * min(1.0, v)) for v in c)


def sugi_spray(size=512, seed=121):
    """Japanese cedar: a forked twig of cord-like branchlets clad in short awl needles."""
    pal = [(0.12, 0.2, 0.09), (0.17, 0.27, 0.11), (0.09, 0.15, 0.08), (0.22, 0.31, 0.13)]

    def draw(dr, dc, S, rng):
        def cord(p0, ang, ln, w, depth):
            n = int(ln / (S * 0.012))
            x, y = p0
            for i in range(n):
                t = i / max(n - 1, 1)
                ang2 = ang + rng.normal(0, 0.05)
                x2, y2 = x + math.cos(ang2) * ln / n, y + math.sin(ang2) * ln / n
                col = _tone(rng, pal)
                ww = max(2, int(w * (1.0 - 0.5 * t)))
                for k in range(4):                          # the needles standing off the cord
                    na = ang2 + rng.choice([-1, 1]) * rng.uniform(0.5, 1.1)
                    nl = S * rng.uniform(0.012, 0.022) * (1.0 - 0.4 * t)
                    xe, ye = x + math.cos(na) * nl, y + math.sin(na) * nl
                    dr.line([(x, y), (xe, ye)], fill=col, width=ww)
                    dc.line([(x, y), (xe, ye)], fill=255, width=ww)
                dr.line([(x, y), (x2, y2)], fill=col, width=ww + 2)
                dc.line([(x, y), (x2, y2)], fill=255, width=ww + 2)
                if depth > 0 and i > 1 and i % 3 == 0 and rng.random() < 0.8:
                    side = rng.choice([-1, 1])
                    cord((x, y), ang + side * rng.uniform(0.5, 0.9), ln * (1.0 - t) * rng.uniform(0.45, 0.65),
                         w * 0.8, depth - 1)
                x, y = x2, y2
        cord((S * 0.5, S * 0.98), -math.pi / 2 + rng.normal(0, 0.08), S * 0.9, S * 0.012, 2)
    return _card(size, draw, seed)


def pine_spray(size=512, seed=131):
    """Black pine: tufts of long paired needles bursting from the ends of a short twig."""
    pal = [(0.1, 0.17, 0.09), (0.15, 0.24, 0.11), (0.08, 0.13, 0.08), (0.19, 0.28, 0.12)]

    def draw(dr, dc, S, rng):
        tips = []
        base = (S * 0.5, S * 0.98)
        for j in range(3):
            ang = -math.pi / 2 + (j - 1) * 0.55 + rng.normal(0, 0.1)
            ln = S * rng.uniform(0.3, 0.42)
            tip = (base[0] + math.cos(ang) * ln, base[1] + math.sin(ang) * ln)
            dr.line([base, tip], fill=(40, 30, 22), width=int(S * 0.012))
            dc.line([base, tip], fill=255, width=int(S * 0.012))
            tips.append((tip, ang))
        for tip, ang in tips:
            for k in range(150):
                na = ang + rng.normal(0, 0.8)
                nl = S * rng.uniform(0.14, 0.27)
                o = S * rng.uniform(0.0, 0.06)
                x0, y0 = tip[0] - math.cos(ang) * o, tip[1] - math.sin(ang) * o
                x1, y1 = x0 + math.cos(na) * nl, y0 + math.sin(na) * nl
                col = _tone(rng, pal)
                dr.line([(x0, y0), (x1, y1)], fill=col, width=6)
                dc.line([(x0, y0), (x1, y1)], fill=255, width=6)
    return _card(size, draw, seed)


def maple_spray(size=512, seed=141):
    """Japanese maple in autumn: five- and seven-lobed leaves on thin stalks along a twig,
    scarlet to orange with a little gold."""
    pal = [(0.62, 0.07, 0.04), (0.72, 0.15, 0.05), (0.8, 0.3, 0.07), (0.52, 0.05, 0.05), (0.78, 0.47, 0.12)]

    def leaf(dr, dc, cx, cy, r, rot, col):
        lobes = 7
        step = 2 * math.pi / lobes
        pts = []
        for k in range(lobes):
            a = rot + k * step
            rr = r * (0.72 if k in (3, 4) else 1.0)      # the lobes by the stalk are shorter
            pts.append((cx + math.cos(a - step * 0.5) * r * 0.28, cy + math.sin(a - step * 0.5) * r * 0.28))
            pts.append((cx + math.cos(a - step * 0.2) * rr * 0.62, cy + math.sin(a - step * 0.2) * rr * 0.62))
            pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr))
            pts.append((cx + math.cos(a + step * 0.2) * rr * 0.62, cy + math.sin(a + step * 0.2) * rr * 0.62))
        dr.polygon(pts, fill=col)
        dc.polygon(pts, fill=255)
        dark = tuple(int(v * 0.62) for v in col)
        for k in range(lobes):
            a = rot + k * step
            dr.line([(cx, cy), (cx + math.cos(a) * r * 0.8, cy + math.sin(a) * r * 0.8)], fill=dark, width=2)

    def twig(dr, dc, S, rng, start, ang, n, seg):
        pts = [start]
        for i in range(n):
            ang += rng.normal(0, 0.22)
            x, y = pts[-1]
            pts.append((x + math.cos(ang) * seg, y + math.sin(ang) * seg))
        dr.line(pts, fill=(60, 25, 20), width=int(S * 0.009))
        dc.line(pts, fill=255, width=int(S * 0.009))
        return pts, ang

    def draw(dr, dc, S, rng):
        main, ang = twig(dr, dc, S, rng, (S * 0.5, S * 0.98), -math.pi / 2, 6, S * 0.12)
        branches = [main]
        for i in (2, 3, 4):
            side = 1 if i % 2 else -1
            b, _ = twig(dr, dc, S, rng, main[i], ang + side * rng.uniform(0.7, 1.0), 3, S * 0.1)
            branches.append(b)
        for b in branches:
            for i in range(1, len(b)):
                for side in (-1, 1):
                    x, y = b[i]
                    sa = math.atan2(b[i][1] - b[i - 1][1], b[i][0] - b[i - 1][0]) + side * rng.uniform(0.6, 1.3)
                    sl = S * rng.uniform(0.04, 0.09)
                    cx, cy = x + math.cos(sa) * sl, y + math.sin(sa) * sl
                    dr.line([(x, y), (cx, cy)], fill=(90, 30, 20), width=3)
                    dc.line([(x, y), (cx, cy)], fill=255, width=3)
                    leaf(dr, dc, cx, cy, S * rng.uniform(0.06, 0.085), sa + math.pi / 2 + rng.normal(0, 0.3),
                         _tone(rng, pal, 0.2))
            leaf(dr, dc, b[-1][0], b[-1][1], S * 0.075, rng.uniform(0, 2 * math.pi), _tone(rng, pal, 0.2))
    return _card(size, draw, seed)


def shrub_spray(size=512, seed=151):
    """Evergreen shrub (azalea, boxwood): small glossy oval leaves crowded on short twigs."""
    pal = [(0.1, 0.18, 0.08), (0.14, 0.24, 0.1), (0.08, 0.14, 0.07), (0.18, 0.28, 0.11)]

    def draw(dr, dc, S, rng):
        for k in range(160):
            r = S * 0.42 * math.sqrt(rng.random())
            a = rng.uniform(0, 2 * math.pi)
            cx, cy = S * 0.5 + math.cos(a) * r, S * 0.55 + math.sin(a) * r * 0.9
            lw, lh = S * rng.uniform(0.03, 0.05), S * rng.uniform(0.015, 0.025)
            rot = rng.uniform(0, math.pi)
            pts = [(cx + math.cos(rot) * lw * math.cos(t) - math.sin(rot) * lh * math.sin(t),
                    cy + math.sin(rot) * lw * math.cos(t) + math.cos(rot) * lh * math.sin(t))
                   for t in np.linspace(0, 2 * math.pi, 12, endpoint=False)]
            col = _tone(rng, pal)
            dr.polygon(pts, fill=col)
            dc.polygon(pts, fill=255)
    return _card(size, draw, seed)


def fern_spray(size=512, seed=161):
    """Ferns under the cedars: fronds fanning up and out from the root, pinnae along each."""
    pal = [(0.13, 0.22, 0.08), (0.18, 0.29, 0.1), (0.1, 0.17, 0.07), (0.22, 0.32, 0.11)]

    def draw(dr, dc, S, rng):
        root = (S * 0.5, S * 0.97)
        for f in range(7):
            ang = -math.pi / 2 + (f - 3) * 0.33 + rng.normal(0, 0.08)
            ln = S * rng.uniform(0.6, 0.85)
            bend = rng.uniform(0.6, 1.1) * (1 if ang > -math.pi / 2 else -1)
            pts = []
            n = 24
            for i in range(n + 1):
                t = i / n
                a = ang + bend * t * t * 0.9
                if pts:
                    x, y = pts[-1]
                    pts.append((x + math.cos(a) * ln / n, y + math.sin(a) * ln / n))
                else:
                    pts.append(root)
            col = _tone(rng, pal)
            dr.line(pts, fill=col, width=4)
            dc.line(pts, fill=255, width=4)
            for i in range(2, n):
                t = i / n
                x, y = pts[i]
                dx, dy = pts[i + 1][0] - x, pts[i + 1][1] - y
                a = math.atan2(dy, dx)
                pl = S * 0.1 * (1.0 - t) ** 0.7 * (0.4 + t * 1.2 if t < 0.3 else 1.0)
                for side in (-1, 1):
                    pa = a + side * 1.2
                    tip = (x + math.cos(pa) * pl, y + math.sin(pa) * pl)
                    mid = (x + math.cos(pa) * pl * 0.5 + math.cos(a) * pl * 0.12,
                           y + math.sin(pa) * pl * 0.5 + math.sin(a) * pl * 0.12)
                    poly = [(x, y), mid, tip, (x + dx * 0.9, y + dy * 0.9)]
                    c2 = _tone(rng, pal, 0.12)
                    dr.polygon(poly, fill=c2)
                    dc.polygon(poly, fill=255)
    return _card(size, draw, seed)
