"""Builds every sound effect into res://audio (44.1 kHz, 16-bit WAV) and audio/CREDITS.md.

Run:  python3 tools/gen_audio.py            (all)
      python3 tools/gen_audio.py deflect    (only names containing "deflect")

Recorded sources (tools/audio_sources.py: CC0 / public domain / CC BY, fetched from pinned
commits into tools/.cache/audio_src/) are cut, pitched, filtered, enveloped and layered with
synthesized parts: blade rings from inharmonic free-bar modes, air from swept noise, a vocal
roar from a glottal pulse through formants. Each sound is then set to a loudness (momentary,
K-weighted) and peak-limited, so the volumes the game plays them at mean the same thing for all.

3D sounds are written mono (Godot's 3D players fold stereo anyway); sounds played flat (the
perilous warning, posture break, deathblow, roar, death, victory, the lock-on tick) and the
ambience are stereo.
"""
import math
import os
import sys
import wave
from fractions import Fraction

import numpy as np
from scipy import signal
from scipy.ndimage import maximum_filter1d, minimum_filter1d, uniform_filter1d

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audio_sources  # noqa: E402

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "audio")
RNG = np.random.default_rng(7)

# Free-free steel bar mode ratios (inharmonic) -> "blade" timbre.
BAR = [1.0, 2.756, 5.404, 8.933, 13.34]


# ----------------------------------------------------------------------------- primitives
def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def noise(dur, seed=None):
    rng = RNG if seed is None else np.random.default_rng(seed)
    return rng.standard_normal(int(dur * SR))


def env_exp(dur, tau, attack=0.001):
    t = t_axis(dur)
    e = np.exp(-t / tau)
    if attack > 0:
        e *= np.clip(t / attack, 0, 1)
    return e


def env_bell(dur, peak=0.4, sharp=2.0):
    t = t_axis(dur) / dur
    e = np.where(t < peak, (t / peak) ** sharp, ((1 - t) / (1 - peak)) ** (sharp * 0.8))
    return np.clip(e, 0, 1)


def bandpass(x, lo, hi, order=2):
    lo = max(lo, 20)
    hi = min(hi, SR / 2 - 100)
    sos = signal.butter(order, [lo, hi], btype="band", fs=SR, output="sos")
    return signal.sosfilt(sos, x, axis=0)


def lowpass(x, fc, order=2):
    sos = signal.butter(order, min(fc, SR / 2 - 100), btype="low", fs=SR, output="sos")
    return signal.sosfilt(sos, x, axis=0)


def highpass(x, fc, order=2):
    sos = signal.butter(order, fc, btype="high", fs=SR, output="sos")
    return signal.sosfilt(sos, x, axis=0)


def swept_bandpass(x, f_curve, q=4.0, block=256):
    """Time-varying resonant bandpass (block-wise biquads). f_curve: per-sample center freq."""
    out = np.zeros_like(x)
    zi = None
    for i in range(0, len(x), block):
        fc = float(np.clip(f_curve[min(i + block // 2, len(x) - 1)], 40, SR / 2 - 500))
        b, a = signal.iirpeak(fc, q, fs=SR)
        if zi is None:
            zi = signal.lfilter_zi(b, a) * 0
        seg, zi = signal.lfilter(b, a, x[i:i + block], zi=zi)
        out[i:i + block] = seg
    return out


def sine_sweep(dur, f0, f1, curve=2.0, phase=0.0):
    t = t_axis(dur)
    u = t / dur
    f = f1 + (f0 - f1) * (1 - u) ** curve
    ph = phase + 2 * math.pi * np.cumsum(f) / SR
    return np.sin(ph)


def partials(dur, f0, ratios, taus, amps, detune=0.0025, seed=0, pair=0.6):
    rng = np.random.default_rng(seed)
    t = t_axis(dur)
    out = np.zeros_like(t)
    for r, tau, a in zip(ratios, taus, amps):
        f = f0 * r
        if f > SR / 2 - 1000:
            continue
        ph = rng.uniform(0, 2 * math.pi)
        out += a * np.sin(2 * math.pi * f * t + ph) * np.exp(-t / tau)
        if detune:
            out += a * pair * np.sin(2 * math.pi * f * (1 + detune) * t + ph * 1.3) * np.exp(-t / (tau * 0.9))
    return out


def pad(x, dur):
    n = int(dur * SR)
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros((n - len(x),) + x.shape[1:])])


def mix(*parts, dur=None):
    """Sums the parts; cut to `dur` (with a short fade, so nothing clicks off) if given."""
    n = max(len(p) for p in parts) if dur is None else int(dur * SR)
    out = np.zeros(n)
    for p in parts:
        m = min(n, len(p))
        out[:m] += p[:m]
    if dur is not None and any(len(p) > n for p in parts):
        out = fade(out, 0.0, 0.04)
    return out


def delay(x, seconds):
    return np.concatenate([np.zeros(int(seconds * SR)), x])


def fade(x, fin=0.002, fout=0.02):
    n = len(x)
    a, b = min(int(fin * SR), n), min(int(fout * SR), n)
    e = np.ones(n)
    if a > 0:
        e[:a] = np.linspace(0, 1, a)
    if b > 0:
        e[-b:] *= np.linspace(1, 0, b)
    return x * e if x.ndim == 1 else x * e[:, None]


def _ir(decay, predelay, bright, seed):
    rng = np.random.default_rng(seed)
    n = int(decay * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal(n) * np.exp(-t * 6.9 / decay)
    ir = lowpass(ir, bright)
    ir[: int(predelay * SR)] = 0
    return ir / (np.sqrt(np.sum(ir ** 2)) + 1e-9)


def reverb(x, decay=1.2, wet=0.25, predelay=0.012, bright=6000, seed=11):
    """Convolution with a synthetic exponentially decaying noise impulse response (mono)."""
    y = signal.fftconvolve(x, _ir(decay, predelay, bright, seed))
    return mix(x, wet * y)


def reverb_st(x, decay=1.8, wet=0.3, predelay=0.02, bright=5000, width=1.0, seed=21):
    """Mono in, stereo out: the dry sound in the middle, a decorrelated tail each side."""
    tails = [signal.fftconvolve(x, _ir(decay, predelay, bright, seed + k)) for k in (0, 1)]
    n = max(len(t) for t in tails)
    mid = pad(x, n / SR + 1e-6)[:n]
    side = pad(tails[0] - tails[1], n / SR + 1e-6)[:n] * 0.5 * width
    common = pad(tails[0] + tails[1], n / SR + 1e-6)[:n] * 0.5
    left = mid + wet * (common + side)
    right = mid + wet * (common - side)
    return np.stack([left, right], axis=1)


def crackle(dur, rate, seed=0, rate_end=None, lo=1400, hi=7500):
    """Fire crackle: sparse random pops (Poisson, `rate` per second, ramping to `rate_end`)."""
    rng = np.random.default_rng(seed)
    n = int(dur * SR)
    out = np.zeros(n)
    t = 0.0
    while True:
        u = t / dur
        r = rate if rate_end is None else rate + (rate_end - rate) * u
        t += rng.exponential(1.0 / max(r, 0.1))
        if t >= dur:
            break
        i = int(t * SR)
        k = int(rng.uniform(0.002, 0.012) * SR)
        pop = rng.standard_normal(k) * np.exp(-np.arange(k) / (k * 0.25)) * rng.uniform(0.3, 1.0)
        out[i:i + k] += pop[: max(0, min(k, n - i))]
    return bandpass(out, lo, hi)


# --- filters (RBJ biquads)
def _rbj(x, b, a):
    return signal.lfilter(np.array(b) / a[0], np.array(a) / a[0], x, axis=0)


def peq(x, f, gain_db, q=1.0):
    A = 10 ** (gain_db / 40)
    w = 2 * math.pi * f / SR
    al = math.sin(w) / (2 * q)
    return _rbj(x, [1 + al * A, -2 * math.cos(w), 1 - al * A], [1 + al / A, -2 * math.cos(w), 1 - al / A])


def hshelf(x, f, gain_db):
    A = 10 ** (gain_db / 40)
    w = 2 * math.pi * f / SR
    c, s = math.cos(w), math.sin(w)
    al = s / 2 * math.sqrt(2)
    r = 2 * math.sqrt(A) * al
    return _rbj(x, [A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - r)],
                [(A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - r])


def lshelf(x, f, gain_db):
    A = 10 ** (gain_db / 40)
    w = 2 * math.pi * f / SR
    c, s = math.cos(w), math.sin(w)
    al = s / 2 * math.sqrt(2)
    r = 2 * math.sqrt(A) * al
    return _rbj(x, [A * ((A + 1) - (A - 1) * c + r), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - r)],
                [(A + 1) + (A - 1) * c + r, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - r])


# --- dynamics and shaping
def sat(x, drive=1.5):
    """Soft saturation (tanh), level-matched."""
    return np.tanh(x * drive) / np.tanh(drive)


def comp(x, thresh_db=-18.0, ratio=3.0, attack=0.002, release=0.08):
    """Feed-forward compressor on the peak envelope (unity gain at the threshold)."""
    a = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    ga, gr = math.exp(-1 / (attack * SR)), math.exp(-1 / (release * SR))
    env = np.empty_like(a)
    e = 0.0
    for i, v in enumerate(a):
        e = (ga * e + (1 - ga) * v) if v > e else (gr * e + (1 - gr) * v)
        env[i] = e
    thr = 10 ** (thresh_db / 20)
    over = np.maximum(env / thr, 1.0)
    g = over ** (1.0 / ratio - 1.0)
    return x * g if x.ndim == 1 else x * g[:, None]


def limit(x, ceiling_db=-0.8, look=0.003):
    """Brick-wall peak limiter with a short look-ahead, so transients keep their shape."""
    c = 10 ** (ceiling_db / 20)
    a = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    w = max(3, int(look * SR))
    g = np.minimum(1.0, c / (maximum_filter1d(a, w) + 1e-12))
    g = uniform_filter1d(minimum_filter1d(g, w), w)
    y = x * g if x.ndim == 1 else x * g[:, None]
    return np.clip(y, -c, c)


def kweight(x):
    b1, a1 = [1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585]
    b2, a2 = [1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621]
    return signal.lfilter(b2, a2, signal.lfilter(b1, a1, x))


def loudness(x):
    """Momentary loudness (the loudest 100 ms, K-weighted), in LUFS."""
    m = x if x.ndim == 1 else x.mean(axis=1)
    y = kweight(m)
    ms = uniform_filter1d(y ** 2, int(0.1 * SR))
    return -0.691 + 10 * math.log10(float(ms.max()) + 1e-12)


def decay(x, tau, hold=0.0):
    """Shortens a sound: an exponential fade with time constant `tau` after `hold` seconds."""
    t = np.arange(len(x)) / SR
    e = np.exp(-np.maximum(t - hold, 0) / tau)
    return x * e if x.ndim == 1 else x * e[:, None]


def repitch(x, ratio):
    """Plays `x` at `ratio` times the speed (pitch up and shorter above 1), band-limited."""
    fr = Fraction(ratio).limit_denominator(96)
    if fr == 1:
        return x.copy()
    return signal.resample_poly(x, fr.denominator, fr.numerator, axis=0)


def onset(x, thresh=0.04):
    a = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    idx = np.where(a > thresh * a.max())[0]
    return int(idx[0]) if len(idx) else 0


def S(key, start=0.0, dur=None, at_onset=True, stereo=False, fout=0.012):
    """A source recording (peak 1), from its onset (less 1.5 ms) + `start`, cut to `dur`."""
    x = audio_sources.load(key, stereo=stereo)
    i0 = max(0, onset(x) - int(0.0015 * SR)) if at_onset else 0
    x = x[i0 + int(start * SR):]
    if dur is not None:
        x = x[:int(dur * SR)]
    return fade(x, 0.0005, fout)


def seg_split(x, n, min_gap=0.1):
    """Splits `x` at its `n - 1` quietest points between bursts (e.g. separate steps)."""
    env = uniform_filter1d(np.abs(x), int(0.01 * SR))
    peaks, _ = signal.find_peaks(env, height=0.2 * env.max(), distance=int(min_gap * SR))
    cuts = [0]
    for a, b in zip(peaks[:-1], peaks[1:]):
        cuts.append(a + int(np.argmin(env[a:b])))
    cuts.append(len(x))
    return [x[c0:c1] for c0, c1 in zip(cuts[:-1], cuts[1:])][:n]


# ----------------------------------------------------------------------------- synth layers
def blade_ring(f0, dur, tau=0.5, bright=1.0, beat=0.0035, shimmer=0.25, seed=0):
    """A struck blade: free-bar modes, the fundamental carrying, the upper modes dying fast,
    each with a faint twin that beats against it (the shimmer of a long thin blade)."""
    taus = [tau, tau * 0.45, tau * 0.2, tau * 0.1, tau * 0.06]
    amps = [1.0, 0.45 * bright, 0.22 * bright, 0.1 * bright, 0.05 * bright]
    x = partials(dur, f0, BAR, taus, amps, detune=beat, seed=seed, pair=shimmer)
    return x * (1 - np.exp(-t_axis(dur) / 0.0008))


def swing(dur, f_lo, f_hi, q=3.5, amp=1.0, seed=0, whistle=0.15, peak=0.45):
    n = noise(dur, seed)
    u = t_axis(dur) / dur
    bell = np.exp(-((u - peak) / 0.22) ** 2)
    fc = f_lo + (f_hi - f_lo) * bell
    x = swept_bandpass(n, fc, q=q) * env_bell(dur, peak, 1.6)
    ph = 2 * math.pi * np.cumsum(fc * 1.02) / SR
    x += whistle * np.sin(ph) * env_bell(dur, peak, 2.5) * 0.08
    return x * amp


def thud(dur, f0=90, f1=45, tau=0.07, noise_amt=0.6, lp=600, seed=0):
    s = sine_sweep(dur, f0, f1, 1.5) * env_exp(dur, tau, 0.001)
    n = lowpass(noise(dur, seed), lp) * env_exp(dur, tau * 0.6, 0.0005) * noise_amt
    return s + n


def slice_noise(dur=0.12, f0=5200, f1=1400, seed=0):
    """The hiss of a blade parting cloth and flesh: a fast downward sweep."""
    u = np.clip(t_axis(dur) / (dur * 0.35), 0, 1)
    return swept_bandpass(noise(dur, seed), f0 + (f1 - f0) * u, q=2.2) * env_exp(dur, dur * 0.25, 0.0015)


def squelch(dur=0.2, seed=0):
    """Wet: mid-band noise, gurgling (amplitude-modulated), dying away."""
    t = t_axis(dur)
    x = bandpass(noise(dur, seed), 350, 1500) * env_exp(dur, dur * 0.3, 0.004)
    return x * (0.55 + 0.45 * np.sin(2 * math.pi * 34 * t + 1.0) ** 2)


def splats(dur, count, seed=0, t0=0.05, t1=0.6):
    rng = np.random.default_rng(seed)
    out = np.zeros(int(dur * SR))
    for _ in range(count):
        s = bandpass(noise(0.05, int(rng.integers(1 << 30))), 300, 2600) * env_exp(0.05, 0.009, 0.001)
        st = int(rng.uniform(t0, t1) * SR)
        m = min(len(s), len(out) - st)
        if m > 0:
            out[st:st + m] += s[:m] * rng.uniform(0.3, 1.0)
    return out


def glottal_roar(dur, f0=82.0, seed=0):
    """A beast's roar: a rough glottal buzz (jitter, a subharmonic, a growl) through the formants
    of an open 'ah' closing to 'oh', with breath."""
    rng = np.random.default_rng(seed)
    t = t_axis(dur)
    u = t / dur
    jit = lowpass(rng.standard_normal(len(t)), 18.0)
    jit /= np.max(np.abs(jit)) + 1e-9
    contour = 1.0 + 0.18 * np.sin(math.pi * np.clip(u * 1.4, 0, 1)) - 0.12 * u
    f = f0 * contour * (1 + 0.035 * jit)
    ph = np.cumsum(f) / SR
    buzz = 2 * (ph % 1.0) - 1
    buzz += 0.55 * (2 * ((ph * 0.5) % 1.0) - 1)                  # subharmonic: the growl
    buzz *= 0.6 + 0.4 * np.sin(2 * math.pi * 29 * t) ** 2          # roughness
    breath = noise(dur, seed + 1) * 0.35
    src = lowpass(buzz, 4000) + breath
    out = np.zeros_like(t)
    for fa, fb, g in [(720, 540, 1.0), (1150, 880, 0.8), (2600, 2400, 0.5), (3400, 3300, 0.3)]:
        out += swept_bandpass(src, fa + (fb - fa) * u, q=5.0) * g
    out = sat(out / (np.max(np.abs(out)) + 1e-9), 2.2)
    return out * env_bell(dur, 0.18, 1.2)


# ----------------------------------------------------------------------------- output
def save(name, x, lufs, ceiling=-0.8, stereo=None):
    """Sets the loudness, limits the peaks, writes res://audio/<name>.wav (mono or stereo)."""
    x = np.asarray(x, dtype=np.float64)
    if stereo is None:
        stereo = x.ndim == 2
    if not stereo and x.ndim == 2:
        x = x.mean(axis=1)
    if stereo and x.ndim == 1:
        x = np.stack([x, x], axis=1)
    x = trim_tail(x)
    x = fade(x, 0.0008, 0.03)
    x = x * 10 ** ((lufs - loudness(x)) / 20)
    x = limit(x, ceiling)
    data = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(2 if stereo else 1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    return path


def trim_tail(x, floor_db=-66.0):
    """Drops the silence at the end (below `floor_db` under the peak), keeping 40 ms."""
    a = np.abs(x) if x.ndim == 1 else np.max(np.abs(x), axis=1)
    env = maximum_filter1d(a, int(0.02 * SR))
    live = np.where(env > a.max() * 10 ** (floor_db / 20))[0]
    end = min(len(x), (int(live[-1]) if len(live) else len(x)) + int(0.04 * SR))
    return x[:end]


def loop_xfade(x, xf):
    """A seamless loop: the tail crossfaded (equal power) into the head."""
    n = int(xf * SR)
    head, tail = x[:n].copy(), x[-n:].copy()
    ramp = np.linspace(0, 1, n)
    if x.ndim == 2:
        ramp = ramp[:, None]
    y = x[:-n].copy()
    y[:n] = head * np.sqrt(ramp) + tail * np.sqrt(1 - ramp)
    return y


# ----------------------------------------------------------------------------- recipes
# Impacts: the deflect is the brightest, loudest short sound in the fight (Sekiro's clang), with
# a pure ring rather than a harsh one: its 2.5-4.5 kHz presence is held down and its sparkle
# dies fast; the block is a damped, lower clunk with no ring to speak of. Tell them apart
# without looking.

# (anvil hit, its pitch, the blade's ring, the sparkle's source)
DEFLECTS = [
    ("anvil_23", 0.86, 1245.0, "finger_cymbal"),
    ("anvil_33", 0.80, 1397.0, "splash_hard"),
    ("anvil_13", 0.70, 1175.0, "finger_cymbal"),
    ("anvil_22", 0.84, 1319.0, "cym_bell"),
    ("anvil_32", 0.92, 1480.0, "splash_hard"),
    ("anvil_12", 0.76, 1109.0, "finger_cymbal"),
]


def sparkle(key, dur=0.5, tau=0.07):
    """Sparks: the top of a cymbal's strike, above 5 kHz, dying fast."""
    return decay(highpass(S(key, dur=dur), 5200, order=4), tau)


def deflect(i):
    anvil, r, ring_f, spk = DEFLECTS[i]
    dur = 1.1
    clack = highpass(S("brake_%d" % (1 + i % 5), dur=0.03), 1200) * 0.7
    core = decay(repitch(S(anvil, dur=1.4), r), 0.2, 0.01)
    core = hshelf(peq(highpass(core, 500), 3500, -6.0, 0.9), 9000, -4.0)
    body = decay(lowpass(repitch(S("brake_%d" % (1 + (i + 2) % 5), dur=0.2), 0.5), 1400), 0.035) * 0.8
    ring = blade_ring(ring_f, dur, tau=0.22, bright=0.8, seed=10 + i)
    ring += 0.45 * blade_ring(ring_f * 1.19, dur, tau=0.14, bright=0.6, seed=20 + i)   # the other blade
    thump = decay(lowpass(repitch(S("frame_muted", dur=0.3), 1.5), 500), 0.05) * 0.8
    x = mix(sat(mix(clack, core, body), 1.4), ring * 0.3, sparkle(spk) * 0.35, thump, dur=dur)
    return reverb(x, 0.6, 0.1, bright=8000, seed=30 + i)


def boss_parry(i):
    """The boss deflecting your blade: the same clang, heavier and lower, and less sparkle."""
    anvil, r, ring_f = [("anvil_23", 0.6, 880.0), ("anvil_33", 0.56, 988.0), ("anvil_22", 0.64, 831.0)][i]
    dur = 1.3
    clack = lowpass(S("brake_%d" % (2 + i), dur=0.06), 5000) * 0.8
    core = decay(repitch(S(anvil, dur=1.6), r), 0.35, 0.01)
    core = hshelf(peq(highpass(core, 300), 3000, -5.0, 0.9), 8000, -5.0)
    ring = blade_ring(ring_f, dur, tau=0.28, bright=0.7, seed=40 + i)
    thump = decay(lowpass(S("frame_muted", dur=0.4), 400), 0.08) * 1.1
    x = mix(sat(mix(clack, core), 1.6), ring * 0.3, sparkle("finger_cymbal") * 0.12, thump, dur=dur)
    return reverb(x, 0.9, 0.14, bright=6000, seed=45 + i)


def block(i):
    """Held guard taking a blow: a damped clunk, blade on blade with the hands soaking it."""
    brake, r = [("brake_1", 0.9), ("brake_3", 0.84), ("brake_4", 0.96), ("brake_2", 0.8), ("brake_5", 0.88)][i]
    dur = 0.5
    hitx = decay(repitch(S(brake, dur=0.6), r), 0.07, 0.008)
    hitx = lowpass(peq(hitx, 3000, -4.0, 1.0), 3600)
    clank = lowpass(S("metal_place_%d" % (1 + i % 2), dur=0.09), 4500) * 0.7
    body = decay(lowpass(repitch(S("cajon_slap", dur=0.3), 0.72), 1600), 0.05) * 0.5
    thump = decay(lowpass(repitch(S("frame_muted", dur=0.3), 1.2), 450), 0.05) * 0.5
    ring = blade_ring(560.0 + 45 * i, dur, tau=0.07, bright=0.4, seed=50 + i) * 0.3
    x = mix(sat(mix(hitx, clank), 1.3), body, thump, ring, dur=dur)
    return reverb(x, 0.45, 0.08, bright=4500, seed=55 + i)


def hit(i):
    """A blade cutting you: the hiss of the cut, a meaty slap, a thud, and something wet."""
    dur = 0.6
    cut = slice_noise(0.14, 5400 - 350 * i, 1300, seed=60 + i) * 0.8
    slap = decay(lowpass(repitch(S("cajon_slap", dur=0.3), 0.68 + 0.05 * i), 2400), 0.06)
    th = decay(S("heavy_kick", dur=0.27), 0.08) * 0.75
    wet = squelch(0.22, seed=65 + i) * 0.45
    x = mix(cut, delay(slap, 0.005), th, delay(wet, 0.012), dur=dur)
    return reverb(sat(x, 1.3), 0.5, 0.08, seed=68 + i)


def swoosh_pass(i):
    """One of the two strokes in the recorded swoosh (hullum, CC0)."""
    p = seg_split(S("swoosh", at_onset=False), 2, min_gap=0.08)[i % 2]
    return fade(p[max(0, onset(p) - 40):], 0.0005, 0.06)


def swing_light(i):
    """The katana: a quick, thin cut of air with a whistle of steel in it."""
    r = [1.22, 1.08, 1.34, 1.16][i]
    air = decay(highpass(repitch(swoosh_pass(i), r), 380), 0.07, 0.1)
    edge = swing(0.24, 700, 3200 + 250 * i, q=6.0, seed=120 + i, whistle=0.8, peak=0.38)
    return fade(mix(delay(air, 0.02), edge * 0.45), 0.0, 0.08)


def swing_heavy(i):
    """His staff: a heavy, low 'vwoom'."""
    r = [0.8, 0.72, 0.9, 0.76][i]
    wood = lowpass(repitch(S("swash"), r), 2500)
    low = lowpass(repitch(swoosh_pass(i + 1), 0.55 + 0.05 * i), 1600)
    synth = swing(0.46, 150, 850 + 90 * i, q=2.6, seed=130 + i, whistle=0.15, peak=0.5)
    return mix(delay(wood, 0.06), delay(low, 0.1) * 0.6, synth * 0.55)


def build(only=None):
    made = []

    def out(name, x, lufs, **kw):
        if only and only not in name:
            return
        made.append(save(name, x, lufs, **kw))

    def want(*names):
        return not only or any(only in n for n in names)

    # --- blade contact
    if want("deflect"):
        for i in range(len(DEFLECTS)):
            out("deflect_%d" % (i + 1), deflect(i), -9.5)
    if want("boss_parry"):
        for i in range(3):
            out("boss_parry_%d" % (i + 1), boss_parry(i), -10.5)
    if want("block"):
        for i in range(5):
            out("block_%d" % (i + 1), block(i), -14.5)
    if want("hit"):
        for i in range(4):
            out("hit_%d" % (i + 1), hit(i), -12.5)

    # --- swings and throws
    if want("swing_light"):
        for i in range(4):
            out("swing_light_%d" % (i + 1), swing_light(i), -17.0)
    if want("swing_heavy"):
        for i in range(4):
            out("swing_heavy_%d" % (i + 1), swing_heavy(i), -16.5)
    if want("thrust"):
        air = highpass(repitch(swoosh_pass(0), 1.45), 600)
        x = mix(delay(air, 0.03), swing(0.32, 500, 3400, q=4.0, seed=150, whistle=0.6, peak=0.3) * 0.6,
                delay(blade_ring(2350.0, 0.4, tau=0.06, bright=0.5, seed=151), 0.08) * 0.12)
        out("thrust", x, -15.0)
    if want("sweep"):
        dur = 0.7
        low = highpass(lowpass(pad(repitch(S("ambi_swoosh", start=0.1), 1.7), dur), 2200), 90)
        sw = swing(dur, 120, 750, q=2.2, seed=160, whistle=0.1, peak=0.42)
        x = mix(low * env_bell(dur, 0.45, 1.5), sw * 0.7) * (1 + 0.3 * np.sin(2 * math.pi * 7 * t_axis(dur)))
        out("sweep", x, -16.0)
    if want("jab"):
        for i in range(2):
            x = mix(highpass(repitch(swoosh_pass(i), 1.55 + 0.1 * i), 500),
                    swing(0.15, 600, 2800, q=3.5, seed=170 + i, whistle=0.3, peak=0.3) * 0.5)
            out("jab_%d" % (i + 1), x, -15.5)
    if want("leap"):
        whoosh = fade(lowpass(repitch(S("dark_woosh", start=0.4, dur=1.6), 1.8), 2500), 0.02, 0.3)
        x = mix(whoosh * 0.8, delay(repitch(S("swash"), 0.9), 0.02) * 0.6)
        out("leap", x, -18.0)
    if want("flick"):
        out("flick", highpass(repitch(swoosh_pass(1), 1.7), 700), -18.0)
    if want("throw"):
        for i in range(2):
            whip = highpass(repitch(swoosh_pass(i), 2.0 + 0.2 * i), 1200)
            whir = partials(0.18, 2600 + 180 * i, [1.0, 2.76], [0.05, 0.03], [0.25, 0.12], seed=310 + i)
            out("throw_%d" % (i + 1), mix(whip, whir * 0.5), -12.5)
    if want("draw"):
        scrape = decay(highpass(S("cym_scrape", dur=0.5), 2200), 0.09, 0.04)
        ting = decay(highpass(S("triangle_muted", dur=0.3), 1500), 0.05) * 0.25
        out("draw", reverb(mix(scrape, delay(ting, 0.11)), 0.4, 0.1), -15.0)

    # --- the big moments
    if want("perilous"):
        drum = mix(lowpass(repitch(S("frame_1", dur=2.0), 0.62), 900), S("bass_drum_1", dur=1.5) * 0.8,
                   lowpass(S("timpani_lo", dur=2.2), 600) * 0.6)
        gong = decay(S("gong_fff", dur=3.0), 0.9) * 0.45
        sting = mix(decay(highpass(S("anvil_31", dur=1.0), 800), 0.22) * 0.55, sparkle("finger_cymbal", 0.8, 0.12) * 0.3)
        bells = mix(decay(S("tubular_c3", dur=2.6), 0.8) * 0.4, decay(repitch(S("tubular_c3", dur=3.6), 1.4142), 0.7) * 0.3)
        x = mix(drum, gong, sting, bells, dur=2.6)
        out("perilous", reverb_st(x, 2.0, 0.28, bright=5000), -11.0)
    if want("mikiri"):
        stomp = mix(S("bass_drum_1", dur=0.6) * 0.9, decay(lowpass(repitch(S("frame_muted"), 0.8), 600), 0.08) * 0.8)
        pin = S("metal_place_1", dur=0.3) * 0.8
        scrape = decay(highpass(S("gong_scrape", dur=0.8), 1500), 0.22) * 0.45
        clang = decay(hshelf(repitch(S("anvil_21", dur=1.0), 0.66), 8000, -4.0), 0.25) * 0.6
        x = mix(stomp, delay(pin, 0.005), delay(scrape, 0.02), clang, blade_ring(990.0, 1.2, tau=0.3, seed=212) * 0.25)
        out("mikiri", reverb(x, 1.0, 0.18, seed=213), -12.5)
    if want("posture_break"):
        gong = decay(S("gong_fff", dur=4.0), 1.1) * 0.8
        crash = decay(S("crash_ff", dur=2.5), 0.6) * 0.5
        clang = decay(hshelf(repitch(S("anvil_31", dur=1.5), 0.55), 7000, -4.0), 0.4) * 0.6
        boom = mix(S("bd_boom") * 0.8, lowpass(S("timpani_lo", dur=2.5), 500) * 0.6)
        x = mix(boom, gong, crash, clang, dur=3.6)
        out("posture_break", reverb_st(x, 2.4, 0.3, bright=5000, seed=222), -11.5)
    if want("guard_break"):
        clang = mix(decay(repitch(S("brake_1"), 0.7), 0.15), decay(repitch(S("anvil_21"), 0.6), 0.2) * 0.5)
        crash = decay(S("crash_short_1", dur=1.0), 0.25) * 0.6
        th = mix(S("heavy_kick") * 0.8, lowpass(S("frame_1", dur=1.0), 700) * 0.6)
        out("guard_break", reverb(mix(sat(clang, 1.5), crash, th, dur=1.4), 1.0, 0.18, seed=230), -12.5)
    if want("deathblow"):
        stab = mix(slice_noise(0.18, 6000, 1200, seed=240),
                   delay(decay(lowpass(repitch(S("cajon_slap"), 0.62), 2000), 0.08), 0.01) * 0.9,
                   delay(squelch(0.35, 241), 0.02) * 0.7)
        boom = mix(S("bd_boom") * 0.9, lowpass(S("timpani_lo", dur=2.5), 500) * 0.7, S("heavy_kick") * 0.6)
        shing = mix(decay(highpass(S("finger_cymbal", dur=2.0), 2500), 0.5) * 0.25,
                    blade_ring(1568.0, 1.5, tau=0.35, seed=242) * 0.12)
        low = decay(repitch(S("gong_f", dur=4.0), 0.8), 1.0) * 0.35
        x = mix(stab, boom, delay(shing, 0.03), low, dur=3.0)
        out("deathblow", reverb_st(x, 2.2, 0.3, bright=4500, seed=243), -12.0)
    if want("deathblow_pull"):
        slide = decay(bandpass(repitch(S("cym_scrape", dur=1.0), 1.1), 1500, 9000), 0.3) * 0.5
        x = mix(slide, delay(squelch(0.4, 250), 0.05) * 0.8, splats(0.9, 9, seed=260, t0=0.12, t1=0.7) * 0.7,
                slice_noise(0.25, 2000, 5000, seed=270) * 0.5)
        out("deathblow_pull", reverb(x, 0.8, 0.15, seed=271), -15.0)

    # --- bodies
    steps = seg_split(S("walking", at_onset=False), 13, min_gap=0.25)
    steps = [fade(highpass(s[max(0, onset(s) - 60):], 60), 0.0005, 0.02) for s in steps]
    if want("step"):
        for i, k in enumerate([1, 3, 5, 7, 9, 11]):
            out("step_%d" % (i + 1), steps[k], -21.0)
    if want("kick"):
        x = mix(S("heavy_kick"), decay(lowpass(repitch(S("cajon_bass"), 0.9), 1500), 0.08) * 0.8,
                highpass(repitch(S("swash"), 1.2), 300) * 0.3)
        out("kick", reverb(x, 0.4, 0.08, seed=290), -11.5)
    if want("stamp"):
        x = mix(S("bass_drum_1", dur=0.5) * 0.9, repitch(steps[4], 0.7) * 0.8,
                delay(S("metal_dug_1", dur=0.25), 0.012) * 0.35, decay(lowpass(S("frame_muted"), 700), 0.06) * 0.6)
        out("stamp", reverb(x, 0.5, 0.12, seed=346), -12.0)
    if want("land"):
        x = mix(S("land_fps") * 0.8, decay(lowpass(repitch(S("frame_muted"), 0.9), 600), 0.06) * 0.9, steps[2] * 0.7,
                decay(highpass(S("gravel_dug_1", dur=0.2), 1500), 0.05) * 0.15)
        out("land", x, -13.5)
    if want("dodge"):
        for i in range(2):
            cloth = highpass(repitch(S("swash"), 1.3 + 0.15 * i), 250)
            air = swing(0.3, 250, 1600, q=1.8, seed=330 + i, whistle=0.0, peak=0.3) * 0.5
            scuff = decay(bandpass(S("sand_step_%d" % (1 + i)), 300, 6000), 0.05) * 0.4
            out("dodge_%d" % (i + 1), mix(cloth, air, delay(scuff, 0.02)), -18.0)
    if want("jump"):
        out("jump", mix(highpass(repitch(S("swash"), 1.6), 300) * 0.8,
                        decay(bandpass(S("sand_step_3"), 300, 6000), 0.04) * 0.4), -20.0)
    rattle = np.zeros(int(0.7 * SR))
    for k, (key, t, g) in enumerate([("metal_dug_1", 0.0, 1.0), ("metal_place_2", 0.05, 0.7),
                                     ("metal_dug_2", 0.11, 0.6), ("metal_place_1", 0.2, 0.4)]):
        rattle = mix(rattle, delay(lowpass(S(key, dur=0.3), 7000), t) * g)
    if want("kneel"):
        x = mix(rattle * 0.6, delay(decay(lowpass(S("frame_muted"), 700), 0.08), 0.09),
                repitch(S("swash"), 0.9) * 0.3)
        out("kneel", reverb(x, 0.8, 0.15, seed=370), -15.0)
    if want("body_fall"):
        x = mix(S("impact_2") * 0.9, S("heavy_kick") * 0.8, delay(rattle, 0.02) * 0.5,
                delay(decay(highpass(S("gravel_dug_1", dur=0.3), 1200), 0.1), 0.03) * 0.2)
        out("body_fall", reverb(x, 1.0, 0.2, seed=380), -13.5)
    if want("ground_impact"):
        x = mix(S("impact_1") * 0.9, lowpass(S("explode"), 2500) * 0.7, decay(S("break_plat"), 0.12) * 0.6,
                decay(repitch(S("anvil_21", dur=0.6), 0.5), 0.08) * 0.3,
                delay(decay(highpass(S("gravel_dug_1"), 1500), 0.12), 0.03) * 0.3)
        out("ground_impact", reverb(x, 1.2, 0.22, seed=352), -11.0)

    # --- the gourd, and the ends of the fight
    if want("heal"):
        cork = decay(bandpass(repitch(S("claves_1", dur=0.2), 0.55), 300, 3000), 0.02) * 0.5
        gulp = mix(*[delay(sine_sweep(0.13, 250, 140, 1.0) * env_bell(0.13, 0.3) * 0.5
                           + lowpass(noise(0.13, 440 + k), 900) * env_bell(0.13, 0.3) * 0.15, t)
                     for k, t in enumerate((0.18, 0.46))])
        chime = mix(decay(S("handbell_2", dur=2.4), 0.9) * 0.35, highpass(S("chimes_desc", dur=2.2), 3000) * 0.12)
        out("heal", reverb(mix(cork, gulp, delay(chime, 0.3)), 1.2, 0.25, seed=441), -18.0)
    if want("death"):
        g = decay(repitch(S("gong_f", dur=7.0), 0.75), 2.5)
        hum = lowpass(S("haunted_hum", dur=6.0), 1200) * 0.5
        drum = mix(lowpass(repitch(S("frame_1"), 0.6), 500) * 0.8, S("bass_drum_1") * 0.6)
        x = decay(mix(drum, g * 0.7, delay(hum, 0.1), dur=6.0), 1.4, 2.2)
        out("death", reverb_st(x, 3.0, 0.35, bright=3500, seed=400), -12.0)
    if want("victory"):
        drum = mix(lowpass(repitch(S("frame_1"), 0.65), 900) * 0.9, S("bass_drum_1") * 0.6)
        bells = mix(S("tubular_c3", dur=5.0) * 0.5, delay(S("tubular_e3", dur=5.0), 0.28) * 0.45,
                    delay(S("tubular_c4", dur=5.0), 0.56) * 0.4)
        g = decay(S("gong_f", dur=6.0), 2.0) * 0.4
        x = mix(drum, g, delay(bells, 0.15), dur=6.5)
        out("victory", reverb_st(x, 2.8, 0.35, bright=4000, seed=410), -11.0)
    if want("roar"):
        v = glottal_roar(2.8, 78.0, seed=420)
        bed = lowpass(S("dark_woosh", dur=3.2), 800) * 0.5
        fire = lowpass(S("fire_large", dur=3.2, at_onset=False), 3000) * env_bell(3.2, 0.3) * 0.3
        out("roar", reverb_st(mix(v, bed, fire), 2.2, 0.3, bright=4000, seed=421), -12.5)
    if want("lockon"):
        out("lockon", decay(repitch(S("wood_pp", dur=0.2), 1.25), 0.03), -17.0, stereo=True)

    # --- fire (the Inferno)
    bed = lowpass(S("fire_large", at_onset=False), 6000)
    if want("fire_charge"):
        ch = S("pyroclasm_charge")
        dur = 1.6
        u = t_axis(dur) / dur
        x = mix(pad(repitch(ch, len(ch) / SR / dur), dur), crackle(dur, 20, 601, rate_end=120) * (0.3 + 0.7 * u) * 0.5,
                pad(bed, dur) * (0.2 + 0.8 * u ** 2) * 0.5)
        out("fire_charge", x, -13.0)
    if want("fire_blast"):
        x = mix(S("napalm_strike"), lowpass(S("explode"), 3000) * 0.8, delay(S("fire_breath", start=0.3) * 0.6, 0.05),
                decay(bed[:int(2.2 * SR)], 0.6) * 0.5)
        out("fire_blast", reverb(x, 1.8, 0.25, bright=4000, seed=612), -10.5)
    if want("fire_ignite"):
        x = mix(S("flame_cloak", start=0.1), thud(0.9, 90, 40, 0.12, 0.6, 400, 621) * 0.4, crackle(0.9, 60, 622) * 0.3)
        out("fire_ignite", reverb(x, 0.8, 0.2, seed=623), -12.0)
    if want("fire_whoosh"):
        dur = 0.7
        bell = env_bell(dur, 0.4, 1.8)
        ws = swept_bandpass(noise(dur, 630), 350 + 1500 * bell, q=1.8) * bell
        x = mix(ws, delay(fade(S("fire_dash"), 0.0, 0.25), 0.12) * 0.8, crackle(dur, 90, 632) * bell * 0.4, dur=dur)
        out("fire_whoosh", x, -12.0)
    if want("fire_flare"):
        hiss = S("flare_burn") * np.linspace(0.2, 1.0, len(S("flare_burn")))
        x = mix(S("fire_breath", start=0.2, dur=1.1), delay(hiss, 0.15) * 0.4, thud(1.0, 110, 50, 0.1, 0.8, 600, 641) * 0.5)
        out("fire_flare", reverb(x, 1.0, 0.25, seed=642), -12.0)
    if want("fire_hiss"):
        x = mix(decay(S("flare_burn", dur=0.5), 0.14, 0.02),
                decay(highpass(S("anvil_12", dur=0.3), 1500), 0.04) * 0.25, decay(crackle(0.5, 80, 652), 0.15) * 0.3)
        out("fire_hiss", x, -14.0)
    if want("burn"):
        x = mix(decay(S("flare_burn", dur=0.6), 0.16) * 0.9, fade(hit(1)[:int(0.35 * SR)], 0.0, 0.1) * 0.7,
                decay(crackle(0.6, 110, 662), 0.2) * 0.5)
        out("burn", x, -12.5)
    if want("fire_gutter"):
        dur = 1.5
        t = t_axis(dur)
        g = swept_bandpass(pad(bed, dur) + noise(dur, 670) * 0.05, 1600 * np.exp(-t * 2.2) + 150, q=0.8)
        x = mix(g * np.exp(-t / 0.55), crackle(dur, 70, 671, rate_end=6) * 0.4)
        out("fire_gutter", reverb(x, 1.0, 0.2, seed=672), -13.0)
    if want("fire_fuse"):
        dur = 0.45
        u = t_axis(dur) / dur
        x = mix(pad(S("sparkler"), dur) * (0.3 + 0.7 * u), sine_sweep(dur, 34, 60, 1.0) * (0.3 + 0.7 * u) * 0.5,
                swept_bandpass(noise(dur, 690), 90 + 900 * u ** 1.5, q=1.3) * (0.2 + 0.8 * u ** 1.8) * 0.8)
        out("fire_fuse", x, -14.0)
    if want("fire_eruption"):
        x = mix(lowpass(S("explode"), 3000), S("napalm_strike") * 0.8, delay(S("fire_breath", start=0.3), 0.08) * 0.7,
                decay(bed[:int(2.6 * SR)], 0.9) * 0.7, crackle(2.6, 220, 698, rate_end=20) * 0.3)
        out("fire_eruption", reverb(x, 2.2, 0.3, bright=4000, seed=699), -10.5)
    if want("fire_roar"):
        n = int(3.6 * SR)
        x = bed[int(1.0 * SR):int(1.0 * SR) + n] + lowpass(S("fireplace", at_onset=False)[:n], 7000) * 0.3
        out("fire_roar", loop_xfade(x, 0.6), -17.0, ceiling=-3.0)

    # --- ambience: a seamless loop of real wind (felix.blume, CC0)
    if want("ambience_wind"):
        w = S("wind", at_onset=False, stereo=True, fout=0.0)
        out("ambience_wind", loop_xfade(w, 1.5), -21.5, ceiling=-6.0, stereo=True)
    return made


if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    files = build(only)
    total = sum(os.path.getsize(f) for f in files)
    print(f"wrote {len(files)} files, {total / 1e6:.1f} MB")
    if not only:
        with open(os.path.join(OUT, "CREDITS.md"), "w") as f:
            f.write(audio_sources.credits_markdown(audio_sources.used()))
