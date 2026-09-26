"""Textures for the arena floor (tools/build_arena_floor.py), all numpy and all tileable where
they repeat: granite detail (crystal grains, pits, veins, dark inclusions), moss, hairline crack
decals and the medallion's engraving. Colour arrays are sRGB 0..1, top row first.
"""
import math

import numpy as np
from PIL import Image, ImageDraw
from scipy.spatial import cKDTree


# ------------------------------------------------------------------ periodic helpers
def _freqs(h, w):
    return np.fft.fftfreq(h)[:, None], np.fft.fftfreq(w)[None, :]


def blur(a, sigma):
    """Periodic Gaussian blur, sigma in pixels (2D or (H, W, C))."""
    if sigma <= 0:
        return a
    h, w = a.shape[:2]
    fy, fx = _freqs(h, w)
    g = np.exp(-2.0 * (math.pi * sigma) ** 2 * (fx ** 2 + fy ** 2))
    if a.ndim == 2:
        return np.real(np.fft.ifft2(np.fft.fft2(a) * g))
    return np.stack([np.real(np.fft.ifft2(np.fft.fft2(a[..., c]) * g)) for c in range(a.shape[2])], 2)


def fnoise(h, w, scale, seed, octaves=1, gain=0.5, aniso=1.0, angle=0.0):
    """Tileable Gaussian-filtered noise with zero mean and unit deviation.
    scale: feature size in pixels; aniso > 1 stretches the features along `angle`."""
    rng = np.random.default_rng(seed)
    fy, fx = _freqs(h, w)
    ca, sa = math.cos(angle), math.sin(angle)
    u = fx * ca + fy * sa
    v = -fx * sa + fy * ca
    out = np.zeros((h, w))
    amp = 1.0
    for o in range(octaves):
        s = max(scale / (2 ** o), 0.5)
        g = np.exp(-2.0 * (math.pi * s * 0.5) ** 2 * ((u * aniso) ** 2 + v ** 2))
        n = np.real(np.fft.ifft2(np.fft.fft2(rng.standard_normal((h, w))) * g))
        out += amp * (n - n.mean()) / (n.std() + 1e-12)
        amp *= gain
    return (out - out.mean()) / (out.std() + 1e-12)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def voronoi(h, w, n, seed, warp=0.0, warp_scale=6.0):
    """Periodic Voronoi over an (h, w) pixel grid: (nearest distance, second distance, cell index,
    cell points (x, y))."""
    rng = np.random.default_rng(seed)
    pts = rng.random((n, 2)) * [w, h]
    tree = cKDTree(pts, boxsize=[w, h])
    yy, xx = np.mgrid[0:h, 0:w].astype(float)
    qx, qy = xx + 0.5, yy + 0.5
    if warp > 0:
        qx = qx + warp * fnoise(h, w, warp_scale, seed + 101)
        qy = qy + warp * fnoise(h, w, warp_scale, seed + 102)
    q = np.stack([np.mod(qx, w).ravel(), np.mod(qy, h).ravel()], 1)
    d, i = tree.query(q, k=2, workers=-1)
    return d[:, 0].reshape(h, w), d[:, 1].reshape(h, w), i[:, 0].reshape(h, w), pts


def normal_map(height, strength):
    """OpenGL-convention (green = up the image) tangent-space normals from a periodic height
    field (height in pixels * strength = slope scale). Returns (H, W, 3) in 0..1."""
    dx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 0.5 * strength
    dy = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 0.5 * strength
    n = np.stack([-dx, dy, np.ones_like(height)], 2)
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    return n * 0.5 + 0.5


def srgb_to_linear(c):
    c = np.asarray(c, dtype=float)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(np.asarray(c, dtype=float), 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def save_rgb(path, arr, quality=None):
    img = Image.fromarray((np.clip(arr, 0, 1) * 255.0 + 0.5).astype(np.uint8), "RGB")
    if path.endswith(".jpg"):
        img.save(path, quality=quality or 92, subsampling=0)
    else:
        img.save(path, optimize=True)


def save_rgba(path, arr):
    Image.fromarray((np.clip(arr, 0, 1) * 255.0 + 0.5).astype(np.uint8), "RGBA").save(path, optimize=True)


# ------------------------------------------------------------------ stone detail
# Granite minerals (sRGB): feldspar, quartz, plagioclase, biotite/hornblende.
MINERALS = [
    ((0.48, 0.47, 0.45), 0.44, 0.0, 0.74),
    ((0.39, 0.395, 0.40), 0.24, 0.35, 0.58),
    ((0.56, 0.55, 0.535), 0.17, 0.12, 0.70),
    ((0.17, 0.17, 0.175), 0.15, -0.45, 0.52),
]


def stone_detail(size=2048, seed=3, period_m=2.4):
    """Tileable granite: returns (albedo sRGB normalised so its linear mean is 0.5, normal map,
    data RGB = roughness, cavity, layering). One pixel = period_m / size metres."""
    h = w = size
    px_mm = period_m * 1000.0 / size
    rng = np.random.default_rng(seed)
    # crystals ~5 mm across, with wobbly boundaries
    cell_px = 4.6 / px_mm
    n_cells = int(h * w / (cell_px * cell_px))
    d1, d2, idx, pts = voronoi(h, w, n_cells, seed, warp=0.9 * cell_px / 4.0, warp_scale=1.4)
    probs = np.array([m[1] for m in MINERALS])
    kind = rng.choice(len(MINERALS), size=n_cells, p=probs / probs.sum())
    base = np.array([m[0] for m in MINERALS])
    # dark minerals clump together in granite: bias each cell's mineral by a clump field
    clump = fnoise(h, w, 14.0 / px_mm, seed + 1, octaves=2)
    at = clump[pts[:, 1].astype(int) % h, pts[:, 0].astype(int) % w]
    flip = rng.random(n_cells)
    kind = np.where((kind == 0) & (at > 0.9) & (flip < 0.45), 3, kind)
    kind = np.where((kind == 3) & (at < -0.5) & (flip < 0.6), 0, kind)
    cell_col = base[kind] * rng.uniform(0.86, 1.12, (n_cells, 1))
    cell_col *= 1.0 + rng.normal(0.0, 0.025, (n_cells, 3))            # slight hue scatter
    col = cell_col[idx]
    relief = np.array([m[2] for m in MINERALS])[kind][idx]
    rough = np.array([m[3] for m in MINERALS])[kind][idx]
    boundary = np.clip((d2 - d1) / (0.35 * cell_px), 0.0, 1.0)
    col *= (0.86 + 0.14 * boundary)[..., None]
    col *= (1.0 + 0.05 * fnoise(h, w, 0.9, seed + 2))[..., None]
    # mid-scale mottling and a gentle large-scale tone drift
    mott = fnoise(h, w, 110.0 / px_mm, seed + 3, octaves=3)
    col *= (1.0 + 0.11 * mott)[..., None]
    col *= (1.0 + 0.08 * fnoise(h, w, 500.0 / px_mm, seed + 4, octaves=2))[..., None]
    # weathered patches: soft darker and paler areas a hand's width across
    wz = fnoise(h, w, 160.0 / px_mm, seed + 12, octaves=2)
    col *= (1.0 - 0.1 * smoothstep(0.4, 1.4, wz) + 0.06 * smoothstep(-0.6, -1.5, wz))[..., None]
    # dark inclusions (xenoliths): soft-edged elongated blobs a few centimetres long
    yy, xx = np.mgrid[0:h, 0:w].astype(float)
    incl = np.zeros((h, w))
    edge_n = fnoise(h, w, 4.0 / px_mm, seed + 5)
    for _ in range(9):
        cx, cy = rng.random(2) * [w, h]
        ln = rng.uniform(18, 55) / px_mm
        wd = ln * rng.uniform(0.3, 0.6)
        ang = rng.uniform(0, math.pi)
        dx = (xx - cx + w / 2) % w - w / 2
        dy = (yy - cy + h / 2) % h - h / 2
        u = dx * math.cos(ang) + dy * math.sin(ang)
        v = -dx * math.sin(ang) + dy * math.cos(ang)
        e = np.sqrt((u / ln) ** 2 + (v / wd) ** 2) + 0.18 * edge_n
        incl = np.maximum(incl, smoothstep(1.0, 0.8, e))
    col = col * (1.0 - 0.55 * incl[..., None]) + np.array([0.13, 0.13, 0.14]) * 0.55 * incl[..., None]
    # light veins (aplite): the zero lines of a broad noise field, faded in and out
    vein = np.zeros((h, w))
    for k in range(2):
        f = fnoise(h, w, 900.0 / px_mm, seed + 20 + k, octaves=2, gain=0.3)
        gx = (np.roll(f, -1, 1) - np.roll(f, 1, 1)) * 0.5
        gy = (np.roll(f, -1, 0) - np.roll(f, 1, 0)) * 0.5
        dist = np.abs(f) / (np.sqrt(gx * gx + gy * gy) + 1e-9)
        wpx = rng.uniform(1.5, 3.5) / px_mm
        wob = 1.0 + 0.35 * fnoise(h, w, 40.0 / px_mm, seed + 40 + k)
        band = smoothstep(wpx * wob, wpx * wob * 0.3, dist)
        keep = smoothstep(-0.2, 0.6, fnoise(h, w, 500.0 / px_mm, seed + 30 + k))
        vein = np.maximum(vein, band * keep)
    col = col * (1.0 - 0.6 * vein[..., None]) + np.array([0.62, 0.60, 0.575]) * 0.6 * vein[..., None]
    col = blur(col, 0.5)

    # height (millimetres): crystal relief, pits, dressing, undulation, shallow spalls
    hgt = relief * 0.10 * (0.6 + 0.4 * boundary)
    hgt += 0.05 * fnoise(h, w, 0.8, seed + 6)
    hgt += 0.5 * fnoise(h, w, 120.0 / px_mm, seed + 7, octaves=2)
    n_pits = int(h * w / (70.0 / px_mm) ** 2 * 6)
    pits = np.zeros((h, w))
    pr = rng.uniform(0.5, 2.2, n_pits) / px_mm
    py = rng.integers(0, h, n_pits)
    pxs = rng.integers(0, w, n_pits)
    pits[py, pxs] = rng.uniform(0.15, 0.5, n_pits) * pr ** 2
    pits = blur(pits, 0.9 / px_mm)
    pits = pits / (pits.max() + 1e-9)
    hgt -= 0.35 * np.clip(pits * 2.0, 0.0, 1.0)
    spall = np.zeros((h, w))
    sn = fnoise(h, w, 6.0 / px_mm, seed + 8)
    for _ in range(6):
        cx, cy = rng.random(2) * [w, h]
        rad = rng.uniform(12, 32) / px_mm
        dx = (xx - cx + w / 2) % w - w / 2
        dy = (yy - cy + h / 2) % h - h / 2
        e = np.sqrt(dx * dx + dy * dy) / rad + 0.25 * sn
        spall = np.maximum(spall, smoothstep(1.0, 0.75, e))
    hgt -= 0.5 * spall
    hgt += 0.06 * vein - 0.04 * incl
    # the spalls expose fresher, slightly lighter stone
    col *= (1.0 + 0.06 * spall)[..., None]

    # normalise the albedo so its linear mean is 0.5 (the shader multiplies it by a palette)
    lin = srgb_to_linear(col)
    lin *= 0.5 / lin.mean()
    albedo = linear_to_srgb(lin)
    nrm = normal_map(hgt / px_mm, 2.2)
    cav = np.clip((blur(hgt, 3.0 / px_mm) - hgt) * 3.5, 0.0, 1.0)
    rough = np.clip(rough + 0.05 * fnoise(h, w, 30.0 / px_mm, seed + 9) + 0.18 * cav + 0.04 * spall, 0.3, 1.0)
    layer = fnoise(h, w, 60.0 / px_mm, seed + 10, octaves=3, gain=0.6, aniso=7.0, angle=0.0)
    layer = 0.5 + 0.5 * np.tanh(layer * 0.9 + 0.35 * fnoise(h, w, 1.5 / px_mm, seed + 11, aniso=5.0))
    data = np.stack([rough, cav, layer], 2)
    return albedo, nrm, data


# ------------------------------------------------------------------ moss
def moss(size=512, seed=5, period_m=0.6):
    """Tileable moss cushion: (RGBA sRGB with alpha = height, normal map)."""
    h = w = size
    px_mm = period_m * 1000.0 / size
    rng = np.random.default_rng(seed)
    cell_px = 7.5 / px_mm
    n = int(h * w / (cell_px * cell_px))
    d1, d2, idx, _ = voronoi(h, w, n, seed, warp=cell_px * 0.3, warp_scale=cell_px * 0.6)
    size_k = rng.uniform(0.75, 1.25, n)
    lift = rng.uniform(0.55, 1.0, n)
    hue = rng.uniform(0.0, 1.0, n)
    r = d1 / (cell_px * 0.62 * size_k[idx])
    dome = np.clip(1.0 - r * r, 0.0, 1.0) ** 0.6 * lift[idx]
    fib = fnoise(h, w, 0.7, seed + 1)
    fib2 = fnoise(h, w, 2.0, seed + 2)
    tall = dome + 0.12 * fib + 0.08 * fib2
    big = fnoise(h, w, 60.0 / px_mm, seed + 3, octaves=2)
    tall = np.clip(tall * (0.8 + 0.2 * smoothstep(-1.2, 1.0, big)), 0.0, 1.0)
    base = np.array([0.13, 0.17, 0.055])
    tip = np.array([0.40, 0.48, 0.15])
    yel = np.array([0.52, 0.52, 0.17])
    brown = np.array([0.28, 0.23, 0.12])
    t = np.clip(tall, 0, 1) ** 1.3
    col = base + (tip - base) * t[..., None]
    hv = hue[idx]
    col = col + (yel - col) * (smoothstep(0.75, 1.0, hv) * t * 0.6)[..., None]
    col = col + (brown - col) * (smoothstep(0.12, 0.0, hv) * 0.55)[..., None]
    col *= (0.9 + 0.2 * smoothstep(-1, 1, fib))[..., None]
    col = blur(col, 0.4)
    nrm = normal_map(blur(tall, 0.6) * 6.0, 1.2)
    rgba = np.dstack([col, tall])
    return rgba, nrm


# ------------------------------------------------------------------ cracks
def _crack_path(rng, start, heading, length, step_px, wobble):
    pts = [np.array(start, dtype=float)]
    ang = heading
    n = max(2, int(length / step_px))
    for _ in range(n):
        ang += rng.normal(0.0, wobble)
        pts.append(pts[-1] + step_px * np.array([math.cos(ang), math.sin(ang)]))
    return pts


def _draw_crack(draw, pts, w0, w1):
    n = len(pts) - 1
    for i in range(n):
        t = i / max(1, n - 1)
        wd = w0 + (w1 - w0) * t
        a, b = pts[i], pts[i + 1]
        draw.line([tuple(a), tuple(b)], fill=255, width=max(1, int(round(wd))))
        r = wd * 0.5
        draw.ellipse([b[0] - r, b[1] - r, b[0] + r, b[1] + r], fill=255)


def cracks(size=2048, seed=9, cell_m=1.6):
    """2x2 atlas of hairline crack decals in tile-local space (each cell spans cell_m metres,
    centred on the stone). R = crack, G = soft halo (grime and moss follow cracks)."""
    rng = np.random.default_rng(seed)
    half = size // 2
    ss = 2
    out = np.zeros((size, size, 3))
    px_per_m = half / cell_m
    for k in range(4):
        canvas = Image.new("L", (half * ss, half * ss), 0)
        draw = ImageDraw.Draw(canvas)
        c = half * ss / 2.0
        s = px_per_m * ss
        # start near a stone edge, head across it
        a0 = rng.uniform(0, 2 * math.pi)
        start = (c + math.cos(a0) * 0.62 * s, c + math.sin(a0) * 0.62 * s)
        heading = a0 + math.pi + rng.normal(0.0, 0.35)
        length = rng.uniform(0.55, 1.15) * s
        main = _crack_path(rng, start, heading, length, 0.02 * s, 0.22)
        _draw_crack(draw, main, 2.6 * ss, 0.9 * ss)
        for _ in range(int(rng.integers(1, 3))):
            j = int(rng.integers(len(main) // 4, max(len(main) // 4 + 1, 3 * len(main) // 4)))
            p0 = main[j]
            d = main[min(j + 1, len(main) - 1)] - main[j]
            h0 = math.atan2(d[1], d[0]) + rng.choice([-1, 1]) * rng.uniform(0.5, 1.1)
            br = _crack_path(rng, tuple(p0), h0, rng.uniform(0.12, 0.35) * s, 0.018 * s, 0.3)
            _draw_crack(draw, br, 1.6 * ss, 0.6 * ss)
        img = np.asarray(canvas.resize((half, half), Image.LANCZOS), dtype=float) / 255.0
        img = np.clip(img * 1.25, 0.0, 1.0)
        halo = np.clip(blur(img, 5.0) * 5.0, 0.0, 1.0)
        oy, ox = (k // 2) * half, (k % 2) * half
        out[oy:oy + half, ox:ox + half, 0] = img
        out[oy:oy + half, ox:ox + half, 1] = halo
    return out


# ------------------------------------------------------------------ medallion engraving
def engraving(size=1024, radius=0.72):
    """The moon medallion's carving, in the medallion's local space (x right, z down the image;
    one image spans 2 * radius metres). R = depth 0..1, G = the chamfer (worn, lighter edges)."""
    n = size
    m_per_px = 2.0 * radius / n
    c = (np.arange(n) + 0.5) * m_per_px - radius
    X, Z = np.meshgrid(c, c)
    R = np.sqrt(X * X + Z * Z)
    ch = 0.0045                       # chamfer width (m)

    def cut(sd):                      # sd < 0 inside the carved area
        return smoothstep(0.0, -ch, sd)

    depth = np.zeros((n, n))
    # two ring grooves framing a band of moon phases
    for rr, wd in ((0.655, 0.0075), (0.455, 0.006)):
        depth = np.maximum(depth, cut(np.abs(R - rr) - wd))
    # eight phases around the band, new moon at the top (far side), waxing clockwise
    pr = 0.036
    for k in range(8):
        a = -math.pi / 2 + k * math.pi / 4
        cx, cz = math.cos(a) * 0.555, math.sin(a) * 0.555
        dx, dz = X - cx, Z - cz
        d = np.sqrt(dx * dx + dz * dz)
        disc = d - pr
        # lit fraction: 0 new, 0.5 quarter, 1 full; the terminator is an ellipse
        ph = k / 8.0
        lit_frac = 0.5 - 0.5 * math.cos(2 * math.pi * ph)
        waxing = ph <= 0.5
        side = 1.0 if waxing else -1.0
        # terminator x-position across the disc, from +pr (new) to -pr (full) on the lit side
        tx = pr * (1.0 - 2.0 * lit_frac)
        lit = side * dx > tx * np.sqrt(np.clip(1.0 - (dz / pr) ** 2, 0.0, 1.0))
        if k == 0:
            shape = np.abs(d - pr + 0.004) - 0.003          # new moon: an outline
        else:
            shape = np.where(lit, disc, np.maximum(disc, 0.004))
        depth = np.maximum(depth, cut(shape))
    # the crescent at the heart
    c1 = np.sqrt(X * X + Z * Z) - 0.30
    c2 = np.sqrt((X - 0.115) ** 2 + (Z + 0.075) ** 2) - 0.255
    crescent = np.maximum(c1, -c2)
    depth = np.maximum(depth, cut(crescent))
    # a small star beside it
    sx, sz = 0.10, -0.065
    ang = np.arctan2(Z - sz, X - sx)
    rs = np.sqrt((X - sx) ** 2 + (Z - sz) ** 2)
    star = rs - (0.018 + 0.022 * np.abs(np.cos(ang * 2.0)) ** 6)
    depth = np.maximum(depth, cut(star))
    chamfer = np.clip(depth * (1.0 - depth) * 4.0, 0.0, 1.0)
    depth = blur(depth, 0.8)
    return np.stack([depth, chamfer, np.zeros_like(depth)], 2)
