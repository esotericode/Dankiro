"""Procedural pattern textures (numpy), tileable, in sRGB 0..1.

Each generator returns a dict with "color" (H, W, 3), "rough" (H, W) and "metal" (H, W),
plus "alpha" (H, W) where relevant. The model builder bakes them (with ambient occlusion and
edge wear) into the character's texture atlas, so these only need to hold the *pattern*.
"""
import math

import numpy as np

RNG = np.random.default_rng(7)


# ------------------------------------------------------------------ noise
def noise(h, w, scale, seed=None, octaves=3):
    """Tileable smooth noise in 0..1: white noise low-pass filtered in the frequency domain.
    scale: feature size in pixels."""
    rng = np.random.default_rng(seed) if seed is not None else RNG
    out = np.zeros((h, w))
    amp = 1.0
    tot = 0.0
    for o in range(octaves):
        s = max(scale / (2 ** o), 0.8)
        f = rng.standard_normal((h, w))
        fy = np.fft.fftfreq(h)[:, None]
        fx = np.fft.fftfreq(w)[None, :]
        g = np.exp(-(fx ** 2 + fy ** 2) * (math.pi * s) ** 2 / 2.0)
        n = np.real(np.fft.ifft2(np.fft.fft2(f) * g))
        n = (n - n.mean()) / (n.std() + 1e-9)
        out += n * amp
        tot += amp
        amp *= 0.5
    out /= tot
    return np.clip(0.5 + out * 0.22, 0.0, 1.0)


def mix(a, b, t):
    t = np.asarray(t)[..., None] if np.ndim(t) == 2 else t
    return a * (1.0 - t) + b * t


def col(rgb, h, w):
    return np.broadcast_to(np.asarray(rgb, dtype=float), (h, w, 3)).copy()


def result(color, rough, metal, alpha=None):
    d = {"color": np.clip(color, 0, 1), "rough": np.clip(rough, 0, 1), "metal": np.clip(metal, 0, 1)}
    if alpha is not None:
        d["alpha"] = np.clip(alpha, 0, 1)
    return d


def coords(h, w):
    y, x = np.mgrid[0:h, 0:w].astype(float)
    return (x + 0.5) / w, (y + 0.5) / h


# ------------------------------------------------------------------ materials
BLACK_LACQUER = (0.045, 0.040, 0.048)
RED_LACING = (0.62, 0.07, 0.055)
GOLD = (0.83, 0.62, 0.27)


def lacquer(size=128, color=BLACK_LACQUER, mottle=0.25, rough=0.22):
    h = w = size
    n = noise(h, w, size / 6, seed=11)
    c = col(color, h, w) * (1.0 - mottle * 0.5 + mottle * n[..., None])
    return result(c, np.full((h, w), rough) + (n - 0.5) * 0.08, np.zeros((h, w)))


def gold(size=128, color=GOLD, wear=0.3):
    h = w = size
    n = noise(h, w, size / 10, seed=12)
    fine = noise(h, w, 1.2, seed=13, octaves=1)
    c = col(color, h, w) * (0.82 + 0.3 * n[..., None]) * (0.94 + 0.12 * fine[..., None])
    return result(c, 0.28 + 0.2 * (1 - n) * wear, np.full((h, w), 1.0))


def cloth(size=128, color=(0.10, 0.09, 0.10), weave=0.10, rough=0.9, seed=21):
    h = w = size
    x, y = np.mgrid[0:h, 0:w]
    wv = ((x // 2 + y // 2) % 2).astype(float)
    n = noise(h, w, size / 5, seed=seed)
    c = col(color, h, w) * (1.0 - weave + weave * wv[..., None]) * (0.8 + 0.4 * n[..., None])
    return result(c, np.full((h, w), rough), np.zeros((h, w)))


def lamellar(lace=RED_LACING, lame=BLACK_LACQUER, px_per_m=2600.0, tile_w=0.096, lame_h=0.066,
             period=0.016, braid=0.0125, hishinui=False, top_band=0.26, edge=(0.20, 0.13, 0.07)):
    """One lame of kebiki-odoshi lamellar: a lacquered top band (the lame's upper edge) with
    the lacing holes, and dense vertical silk braids below. u across (tile_w metres),
    v down the lame (0 = top edge). hishinui: cream cross-knots on the bottom row."""
    w = int(round(tile_w * px_per_m))
    h = int(round(lame_h * px_per_m))
    u, v = coords(h, w)
    um = u * tile_w
    vm = v * lame_h
    c = col(lame, h, w)
    rough = np.full((h, w), 0.2)
    metal = np.zeros((h, w))
    # kozane scale boundaries (vertical, every half braid period), faint
    sc = np.abs(((um / (period * 0.5)) % 1.0) - 0.5)
    c *= (0.85 + 0.15 * np.clip(sc * 6, 0, 1))[..., None]
    # top band: glossy, with a thin warm edge line at the very top
    top = v < top_band
    edge_line = v < 0.035
    c[edge_line] = np.asarray(edge) * 1.0
    # braids
    pu = (um % period) / period                       # 0..1 across a braid period
    bw = braid / period
    inb = (pu < bw) & ~top
    xr = pu / bw                                      # 0..1 across the braid
    shade = 0.55 + 0.45 * np.sin(np.clip(xr, 0, 1) * math.pi)
    diag = (((um * 1000 / 2.2) + (vm * 1000 / 2.2)) % 1.0 < 0.5).astype(float)
    weave = 0.86 + 0.14 * diag
    bcol = np.asarray(lace)[None, None, :] * (shade * weave)[..., None]
    c = np.where(inb[..., None], bcol, c)
    rough = np.where(inb, 0.75, rough)
    # holes where braids enter under the top band
    hole = (np.abs(v - (top_band + 0.05)) < 0.04) & (np.abs(xr - 0.5) < 0.35) & (pu < bw)
    c[hole] *= 0.35
    # braid passing over the top band (narrower, shows the lacing going up to the next lame)
    over = top & (v > 0.06) & (np.abs(xr - 0.5) < 0.18) & (pu < bw)
    c = np.where(over[..., None], np.asarray(lace) * 0.55, c)
    if hishinui:
        # cream cross-knots every second braid period, in the lower half
        pu2 = (um % (period * 2)) / (period * 2)
        cx = (pu2 - 0.5) * (period * 2)
        cy = vm - lame_h * 0.66
        d1 = np.abs(cx - cy)
        d2 = np.abs(cx + cy)
        k = ((np.minimum(d1, d2) < 0.0022) & (np.abs(cy) < lame_h * 0.2) & (np.abs(cx) < period * 0.55))
        c[k] = np.array([0.86, 0.80, 0.68])
        rough[k] = 0.8
    return result(c, rough, metal)


def brocade(size=256, base=(0.30, 0.05, 0.05), motif=(0.78, 0.58, 0.25)):
    """Kikko (tortoise-shell hexagon) brocade with a small flower in each cell. The hex lattice
    is 7 cells across and 4 double-rows down, which tiles a square to within 1%."""
    h = w = size
    u, v = coords(h, w)
    x = u * 7.0
    y = v * 4.0 * math.sqrt(3.0)
    best = np.full((h, w), 9.0)
    rad = np.full((h, w), 9.0)
    for ox, oy in ((0.0, 0.0), (0.5, math.sqrt(3.0) / 2.0)):
        gx = np.round(x - ox) + ox
        gy = np.round((y - oy) / math.sqrt(3.0)) * math.sqrt(3.0) + oy
        dx = np.abs(x - gx)
        dy = np.abs(y - gy)
        d = np.maximum(dx, dx * 0.5 + dy * math.sqrt(3.0) / 2.0)
        closer = d < best
        best = np.where(closer, d, best)
        rad = np.where(closer, np.sqrt(dx ** 2 + dy ** 2), rad)
    line = np.abs(best - 0.5) < 0.045
    inner = np.abs(best - 0.40) < 0.02
    flower = (rad < 0.11) | (np.abs(rad - 0.2) < 0.03)
    c = col(base, h, w)
    n = noise(h, w, 6, seed=31)
    c *= (0.85 + 0.3 * n)[..., None]
    c[inner] = np.asarray(base) * 1.6
    c[line] = np.asarray(motif) * 0.85
    c[flower] = np.asarray(motif)
    gilt = line | flower
    return result(c, np.where(gilt, 0.45, 0.85), np.where(gilt, 0.6, 0.0))


def mail(size=128, base=(0.09, 0.07, 0.07), ring=(0.16, 0.15, 0.15), cells=10):
    """Kusari (chain mail) over cloth."""
    h = w = size
    u, v = coords(h, w)
    x = (u * cells) % 1.0 - 0.5
    y = (v * cells) % 1.0 - 0.5
    r = np.sqrt(x ** 2 + y ** 2)
    ring_m = np.abs(r - 0.3) < 0.11
    x2 = ((u * cells + 0.5) % 1.0) - 0.5
    y2 = ((v * cells + 0.5) % 1.0) - 0.5
    link = (np.abs(x2) < 0.09) | (np.abs(y2) < 0.09)
    link &= np.sqrt(x2 ** 2 + y2 ** 2) < 0.28
    c = cloth(size, base)["color"]
    m = ring_m | link
    c[m] = np.asarray(ring) * (0.9 + 0.2 * noise(h, w, 3, seed=41)[m][:, None])
    return result(c, np.where(m, 0.45, 0.9), np.where(m, 0.9, 0.0))


def leather(size=128, color=(0.06, 0.045, 0.04)):
    h = w = size
    n = noise(h, w, 3, seed=51)
    n2 = noise(h, w, 18, seed=52)
    c = col(color, h, w) * (0.75 + 0.35 * n[..., None]) * (0.85 + 0.3 * n2[..., None])
    return result(c, 0.55 + 0.2 * n, np.zeros((h, w)))


def straw(size=128, color=(0.55, 0.44, 0.27)):
    h = w = size
    u, v = coords(h, w)
    strand = 0.5 + 0.5 * np.sin(u * 2 * math.pi * 24 + np.sin(v * 2 * math.pi * 3) * 0.6)
    weft = ((v * 12) % 1.0 < 0.2).astype(float)
    c = col(color, h, w) * (0.7 + 0.35 * strand[..., None]) * (1.0 - 0.35 * weft[..., None])
    return result(c, np.full((h, w), 0.95), np.zeros((h, w)))


def cord(size=64, c1=RED_LACING, c2=(0.40, 0.04, 0.035)):
    """Braided silk cord: diagonal twill."""
    h = w = size
    u, v = coords(h, w)
    d = ((u * 6 + v * 6) % 1.0 < 0.5)
    c = np.where(d[..., None], np.asarray(c1), np.asarray(c2))
    shade = 0.75 + 0.25 * np.sin(u * math.pi)
    c = c * shade[..., None]
    return result(c, np.full((h, w), 0.7), np.zeros((h, w)))


def hair(w=128, h=512, color=(0.92, 0.90, 0.86), strands=90, seed=61):
    """White horsehair: many fine strands, alpha-tested edges, tapering at the tips (v=1)."""
    rng = np.random.default_rng(seed)
    u, v = coords(h, w)
    alpha = np.zeros((h, w))
    shade = np.zeros((h, w))
    for i in range(strands):
        x0 = rng.uniform(0.04, 0.96)
        wob = rng.uniform(0.004, 0.02)
        ph = rng.uniform(0, 6.28)
        length = rng.uniform(0.7, 1.0)
        width = rng.uniform(0.006, 0.016)
        x = x0 + wob * np.sin(v * 7.0 + ph)
        taper = np.clip((length - v) / 0.25, 0, 1)
        d = np.abs(u - x) / (width * (0.35 + 0.65 * taper) + 1e-4)
        a = np.clip(1.0 - d, 0, 1) * (v < length)
        alpha = np.maximum(alpha, a)
        shade = np.maximum(shade, a * rng.uniform(0.75, 1.0))
    c = np.asarray(color)[None, None, :] * (0.55 + 0.45 * shade[..., None])
    c *= (0.8 + 0.2 * (1 - v))[..., None]
    return result(c, np.full((h, w), 0.6), np.zeros((h, w)), alpha=np.clip(alpha * 1.6, 0, 1))


def to_uint8(d, alpha=False):
    rgb = (np.clip(d["color"], 0, 1) * 255 + 0.5).astype(np.uint8)
    if alpha and "alpha" in d:
        a = (np.clip(d["alpha"], 0, 1) * 255 + 0.5).astype(np.uint8)
        return np.concatenate([rgb, a[..., None]], axis=2)
    return rgb


def tsukamaki(w=128, h=64, silk=(0.52, 0.06, 0.05), under=(0.05, 0.04, 0.04)):
    """Diamond (hishi) silk wrap of a grip: two diagonal ribbons crossing, dark diamonds between.
    One tile = two diamonds around, one down."""
    u, v = coords(h, w)
    a = ((u * 2 + v) % 1.0)
    b = ((u * 2 - v) % 1.0)
    ra = np.abs(a - 0.5) < 0.30
    rb = np.abs(b - 0.5) < 0.30
    c = col(under, h, w)
    shade_a = 0.7 + 0.3 * np.cos((a - 0.5) / 0.30 * math.pi / 2)
    shade_b = 0.7 + 0.3 * np.cos((b - 0.5) / 0.30 * math.pi / 2)
    top_a = ((u * 2 + v) // 1.0 + (u * 2 - v) // 1.0) % 2 == 0
    sa = np.asarray(silk)[None, None, :] * shade_a[..., None]
    sb = np.asarray(silk)[None, None, :] * shade_b[..., None] * 0.92
    c = np.where((ra & (top_a | ~rb))[..., None], sa, c)
    c = np.where((rb & (~top_a | ~ra))[..., None], sb, c)
    rough = np.where(ra | rb, 0.7, 0.5)
    return result(c, rough, np.zeros((h, w)))


def hamon(w=128, h=512, seed=81):
    """Blade steel along v (0 = base, 1 = tip), across u (0 = spine, 1 = edge): polished dark
    steel, a groove (bo-hi) near the spine, a frosted wavy temper line and a hazy edge.
    Also returns "glow": an emission mask that lights the cutting edge."""
    rng = np.random.default_rng(seed)
    u, v = coords(h, w)
    ph = rng.uniform(0, 6.28)
    line = 0.66 + 0.05 * np.sin(v * 2 * math.pi * 7 + ph) + 0.02 * np.sin(v * 2 * math.pi * 19 + ph * 2)
    steel = np.array([0.30, 0.32, 0.36])
    c = steel[None, None, :] * (0.85 + 0.15 * noise(h, w, 6, seed=82)[..., None])
    frost = smoothstep_np(line - 0.03, line + 0.04, u)
    c = c * (1 - frost[..., None]) + np.array([0.78, 0.79, 0.80]) * frost[..., None] * (0.9 + 0.1 * noise(h, w, 2, seed=83)[..., None])
    groove = (np.abs(u - 0.2) < 0.045) & (v < 0.72)
    c[groove] *= 0.45
    rough = 0.16 + 0.22 * frost
    metal = np.full((h, w), 1.0)
    glow = np.clip(smoothstep_np(0.55, 0.95, u) * (0.6 + 0.4 * v), 0, 1)
    d = result(c, rough, metal)
    d["glow"] = glow
    return d


def smoothstep_np(e0, e1, x):
    t = np.clip((np.asarray(x, dtype=float) - e0) / (np.asarray(e1, dtype=float) - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def sash(w=64, h=256, silk=(0.56, 0.06, 0.05)):
    """Silk sash / tassel ribbon: u across, v along. Twill weave, darker hemmed edges, and a
    braided band before the fringe at the end (v near 1)."""
    u, v = coords(h, w)
    tw = (((u * 16 + v * 64) % 1.0) < 0.5).astype(float)
    c = np.asarray(silk)[None, None, :] * (0.88 + 0.12 * tw[..., None])
    c = c * (0.8 + 0.2 * np.sin(u * math.pi))[..., None]
    hem = (u < 0.08) | (u > 0.92)
    c[hem] *= 0.6
    band = (v > 0.80) & (v < 0.86)
    c[band] = np.array([0.80, 0.60, 0.26])
    fringe = v > 0.86
    c[fringe] *= (0.75 + 0.25 * ((u * 40) % 1.0 < 0.5))[fringe][:, None]
    return result(c, np.full((h, w), 0.6), np.where(band, 1.0, 0.0))
