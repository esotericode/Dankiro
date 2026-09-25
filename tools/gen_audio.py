"""Synthesizes every sound effect into res://audio (44.1 kHz, 16-bit stereo WAV).

Run:  python3 tools/gen_audio.py            (all)
      python3 tools/gen_audio.py deflect    (only names containing "deflect")

Nothing is sampled: metal is built from inharmonic free-bar modes, swings from swept
resonant noise, impacts from filtered noise + pitch-dropping sines, space from a small
synthetic reverb. Tweak the recipes below and re-run.
"""
import math
import os
import sys
import wave

import numpy as np
from scipy import signal

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
    return signal.sosfilt(sos, x)


def lowpass(x, fc, order=2):
    sos = signal.butter(order, min(fc, SR / 2 - 100), btype="low", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def highpass(x, fc, order=2):
    sos = signal.butter(order, fc, btype="high", fs=SR, output="sos")
    return signal.sosfilt(sos, x)


def swept_bandpass(x, f_curve, q=4.0, block=256):
    """Time-varying resonant bandpass (block-wise biquads). f_curve: per-sample center freq."""
    out = np.zeros_like(x)
    zi = None
    for i in range(0, len(x), block):
        fc = float(np.clip(f_curve[min(i + block // 2, len(x) - 1)], 40, SR / 2 - 500))
        bw = fc / q
        b, a = signal.iirpeak(fc, fc / bw, fs=SR)
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


def partials(dur, f0, ratios, taus, amps, detune=0.0025, seed=0):
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
            out += a * 0.6 * np.sin(2 * math.pi * f * (1 + detune) * t + ph * 1.3) * np.exp(-t / (tau * 0.9))
    return out


def pad(x, dur):
    n = int(dur * SR)
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x))])


def mix(*parts, dur=None):
    n = max(len(p) for p in parts) if dur is None else int(dur * SR)
    out = np.zeros(n)
    for p in parts:
        m = min(n, len(p))
        out[:m] += p[:m]
    return out


def delay(x, seconds):
    return np.concatenate([np.zeros(int(seconds * SR)), x])


def reverb(x, decay=1.2, wet=0.25, predelay=0.012, bright=6000, seed=11):
    """Convolution with a synthetic exponentially decaying noise impulse response."""
    rng = np.random.default_rng(seed)
    n = int(decay * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal(n) * np.exp(-t * 6.9 / decay)
    ir = lowpass(ir, bright)
    ir[: int(predelay * SR)] = 0
    ir /= np.sqrt(np.sum(ir ** 2)) + 1e-9
    y = signal.fftconvolve(x, ir)
    dry = np.concatenate([x, np.zeros(n)])
    if len(y) < len(dry):
        y = np.concatenate([y, np.zeros(len(dry) - len(y))])
    return dry + wet * y[: len(dry)]


def stereo(x, width=0.35, seed=3):
    """Decorrelated stereo from mono: small delay + gentle allpass-ish smear on one side."""
    rng = np.random.default_rng(seed)
    d = int(0.00035 * SR)
    left = x
    right = np.concatenate([np.zeros(d), x])[: len(x)]
    smear = signal.fftconvolve(x, rng.standard_normal(64) * np.exp(-np.arange(64) / 10.0) * 0.05)[: len(x)]
    left = left + smear * width
    right = right - smear * width
    return np.stack([left, right], axis=1)


def fade(x, fin=0.002, fout=0.02):
    n = len(x)
    a, b = int(fin * SR), int(fout * SR)
    e = np.ones(n)
    if a > 0:
        e[:a] = np.linspace(0, 1, a)
    if b > 0:
        e[-b:] *= np.linspace(1, 0, b)
    return x * e if x.ndim == 1 else x * e[:, None]


def save(name, x, peak_db=-1.0, st=True, width=0.35):
    if x.ndim == 1:
        x = fade(x)
        x = stereo(x, width) if st else np.stack([x, x], axis=1)
    else:
        x = fade(x)
    peak = np.max(np.abs(x)) + 1e-9
    x = x / peak * (10 ** (peak_db / 20))
    data = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    return path


# ----------------------------------------------------------------------------- recipes
def metal_hit(f0, dur=1.2, ring=1.0, brightness=1.0, click=1.0, body=1.0, thump=0.4, seed=0):
    """Blade-on-blade contact."""
    taus = [0.55 * ring, 0.38 * ring, 0.2 * ring, 0.09 * ring, 0.05 * ring]
    amps = [0.7, 1.0 * brightness, 0.55 * brightness, 0.3 * brightness, 0.15 * brightness]
    tone = partials(dur, f0, BAR, taus, amps, detune=0.003, seed=seed)
    # a second, slightly different "blade" rings with it (two weapons)
    tone += 0.55 * partials(dur, f0 * 1.187, BAR, [x * 0.8 for x in taus], amps, detune=0.004, seed=seed + 5)
    clk = highpass(noise(0.006, seed + 1), 2500) * env_exp(0.006, 0.0015, 0.0001) * 3.0 * click
    bod = bandpass(noise(0.06, seed + 2), 1500, 7000) * env_exp(0.06, 0.012, 0.0003) * 1.2 * body
    th = np.sin(2 * math.pi * 170 * t_axis(0.12)) * env_exp(0.12, 0.03, 0.001) * thump
    return mix(tone * 0.5, clk, bod, th, dur=dur)


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


def flesh(dur=0.35, seed=0):
    n = noise(dur, seed)
    u = t_axis(dur) / dur
    slice_ = swept_bandpass(n, 4200 - 3000 * np.clip(u * 5, 0, 1), q=2.5) * env_exp(dur, 0.035, 0.001) * 1.4
    squish = bandpass(noise(dur, seed + 1), 500, 1600) * env_exp(dur, 0.09, 0.004)
    squish *= 0.6 + 0.4 * np.sin(2 * math.pi * 38 * t_axis(dur)) ** 2
    th = thud(dur, 110, 55, 0.06, 0.5, 500, seed + 2)
    return mix(slice_, squish * 0.9, th * 0.9)


def gong(dur, f0, tau=1.6, seed=0, amt=1.0):
    ratios = [1.0, 1.52, 2.11, 2.73, 3.42, 4.18, 5.1]
    taus = [tau, tau * 0.8, tau * 0.6, tau * 0.45, tau * 0.35, tau * 0.25, tau * 0.18]
    amps = [1.0, 0.7, 0.55, 0.4, 0.3, 0.2, 0.12]
    x = partials(dur, f0, ratios, taus, amps, detune=0.004, seed=seed)
    t = t_axis(dur)
    x *= 1 - np.exp(-t / 0.004)
    return x * amt


# ----------------------------------------------------------------------------- sound list
def build(only=None):
    made = []

    def out(name, x, **kw):
        if only and only not in name:
            return
        made.append(save(name, x, **kw))

    # --- deflect: bright, ringing "shing" with a hard transient
    for i, f0 in enumerate([1420, 1540, 1660, 1780]):
        x = metal_hit(f0, 1.1, ring=1.0, brightness=1.15, click=1.2, body=1.0, thump=0.35, seed=10 + i)
        shimmer = bandpass(noise(0.5, 40 + i), 6000, 12000) * env_exp(0.5, 0.06, 0.001) * 0.25
        x = mix(x, shimmer)
        out("deflect_%d" % (i + 1), reverb(x, 0.9, 0.18, bright=9000), peak_db=-0.5)
    # --- boss parrying the player: heavier, lower
    x = metal_hit(1080, 1.3, ring=1.1, brightness=0.9, click=1.1, body=1.2, thump=0.7, seed=60)
    out("boss_parry", reverb(x, 1.0, 0.2), peak_db=-0.8)
    # --- block: dull clank, short ring, more body
    for i, f0 in enumerate([640, 720, 800]):
        x = metal_hit(f0, 0.5, ring=0.3, brightness=0.55, click=0.8, body=1.6, thump=0.9, seed=80 + i)
        x = lowpass(x, 5200)
        out("block_%d" % (i + 1), reverb(x, 0.6, 0.12, bright=5000), peak_db=-1.5)
    # --- hits
    for i in range(3):
        out("hit_%d" % (i + 1), reverb(flesh(0.4, 100 + i * 3), 0.5, 0.1), peak_db=-1.0)
    # --- swings
    for i in range(3):
        x = swing(0.24, 420, 2400 + i * 200, q=3.2, seed=120 + i, whistle=0.4, peak=0.42)
        out("swing_light_%d" % (i + 1), x, peak_db=-4.0)
    for i in range(3):
        x = swing(0.42, 160, 900 + i * 90, q=2.6, seed=130 + i, whistle=0.2, peak=0.5)
        x += 0.5 * swing(0.42, 300, 1400, q=3.0, seed=140 + i, whistle=0.1, peak=0.62)
        out("swing_heavy_%d" % (i + 1), x, peak_db=-2.5)
    x = swing(0.3, 500, 3200, q=4.0, seed=150, whistle=0.5, peak=0.35)
    x = mix(x, 0.35 * partials(0.4, 2400, BAR[:3], [0.12, 0.08, 0.05], [0.4, 0.6, 0.3], seed=151))
    out("thrust", x, peak_db=-2.0)
    x = swing(0.55, 120, 700, q=2.2, seed=160, whistle=0.1, peak=0.4)
    x *= 1 + 0.35 * np.sin(2 * math.pi * 7 * t_axis(0.55))
    out("sweep", x, peak_db=-2.0)
    for i in range(2):
        out("jab_%d" % (i + 1), swing(0.14, 600, 2800, q=3.5, seed=170 + i, whistle=0.3, peak=0.3), peak_db=-3.0)
    dur = 1.4
    whirl = np.zeros(int(dur * SR))
    for k in range(6):
        s = swing(0.28, 200, 1300, q=2.8, seed=180 + k, whistle=0.15, peak=0.5)
        st = int((0.08 + k * 0.215) * SR)
        whirl[st:st + len(s)] += s[: max(0, len(whirl) - st)]
    whirl += lowpass(noise(dur, 190), 250) * env_bell(dur, 0.5, 1.0) * 0.25
    out("whirl", whirl, peak_db=-2.5)
    out("leap", swing(0.45, 150, 1100, q=2.4, seed=195, whistle=0.1, peak=0.3), peak_db=-3.0)

    # --- perilous: deep drum + dissonant metal + sharp sting, long tail
    dur = 2.2
    drum = thud(dur, 120, 42, 0.35, 0.9, 400, 200) * 1.2
    g = gong(dur, 210, 1.3, 201, 0.9) + gong(dur, 297, 1.0, 202, 0.55)   # ~tritone above
    sting = metal_hit(2300, 0.8, ring=0.5, brightness=1.3, click=1.4, body=0.8, thump=0.0, seed=203) * 0.6
    swell = bandpass(noise(dur, 204), 300, 2000) * env_exp(dur, 0.25, 0.002) * 0.3
    x = mix(drum, g * 0.7, sting, swell)
    out("perilous", reverb(x, 1.8, 0.35, predelay=0.02, bright=4500), peak_db=-0.5)

    # --- mikiri: heavy stomp + blade grinding into stone + ring
    dur = 1.4
    stomp = thud(dur, 95, 38, 0.12, 1.0, 700, 210) * 1.4
    scrape = swept_bandpass(noise(dur, 211), 5200 - 3000 * t_axis(dur) / dur, q=5) * env_exp(dur, 0.18, 0.003)
    ring = metal_hit(1150, dur, ring=0.9, brightness=1.0, click=1.5, body=1.4, thump=0.6, seed=212)
    out("mikiri", reverb(mix(stomp, scrape * 0.5, ring * 0.9), 1.2, 0.22), peak_db=-0.5)

    # --- posture break: boom + metal crash
    dur = 2.4
    boom = thud(dur, 70, 30, 0.5, 1.0, 300, 220) * 1.3
    crash = bandpass(noise(dur, 221), 900, 9000) * env_exp(dur, 0.25, 0.001)
    ring = metal_hit(880, dur, ring=1.6, brightness=1.0, click=1.6, body=1.6, thump=0.0, seed=222)
    g = gong(dur, 140, 1.6, 223, 0.6)
    out("posture_break", reverb(mix(boom, crash * 0.7, ring, g), 2.0, 0.3, bright=6000), peak_db=-0.3)
    dur = 1.2
    x = mix(metal_hit(520, dur, ring=0.5, brightness=0.6, click=1.2, body=1.8, thump=1.0, seed=230),
            thud(dur, 85, 40, 0.15, 0.8, 500, 231) * 0.9,
            bandpass(noise(dur, 232), 700, 4000) * env_exp(dur, 0.08, 0.001) * 0.6)
    out("guard_break", reverb(x, 1.0, 0.2), peak_db=-0.8)

    # --- deathblow
    dur = 1.8
    stab = flesh(0.5, 240) * 1.3
    boom = thud(dur, 80, 32, 0.45, 0.8, 300, 241)
    shing = metal_hit(1900, 0.7, ring=0.4, brightness=1.0, click=1.0, body=0.4, thump=0.0, seed=242) * 0.35
    out("deathblow", reverb(mix(stab, boom, shing), 1.6, 0.3), peak_db=-0.3)
    dur = 0.9
    slide = swept_bandpass(noise(dur, 250), 600 + 2600 * t_axis(dur) / dur, q=3.0) * env_bell(dur, 0.3, 1.5)
    splat = np.zeros(int(dur * SR))
    for k in range(9):
        s = bandpass(noise(0.05, 260 + k), 300, 3000) * env_exp(0.05, 0.01, 0.001) * RNG.uniform(0.3, 1.0)
        st = int(RNG.uniform(0.15, 0.7) * SR)
        splat[st:st + len(s)] += s[: max(0, len(splat) - st)]
    out("deathblow_pull", reverb(mix(slide * 0.8, splat, flesh(0.3, 270) * 0.5), 0.8, 0.15), peak_db=-1.0)
    out("flick", swing(0.2, 700, 3000, q=3.0, seed=280, whistle=0.3, peak=0.35), peak_db=-5.0)

    # --- body sounds
    out("kick", reverb(mix(thud(0.35, 120, 55, 0.05, 0.9, 900, 290) * 1.3,
                           bandpass(noise(0.05, 291), 1500, 5000) * env_exp(0.05, 0.006, 0.0005) * 0.8), 0.4, 0.1),
        peak_db=-1.0)
    for i in range(4):
        x = mix(highpass(noise(0.03, 300 + i), 1500) * env_exp(0.03, 0.004, 0.0005) * 0.5,
                thud(0.16, 70 + i * 6, 40, 0.025, 1.0, 900 + i * 150, 310 + i) * 0.9)
        out("step_%d" % (i + 1), x, peak_db=-6.0, width=0.1)
    out("land", mix(thud(0.4, 80, 35, 0.07, 1.0, 700, 320), bandpass(noise(0.3, 321), 400, 3000) * env_exp(0.3, 0.05, 0.002) * 0.4),
        peak_db=-2.0)
    for i in range(2):
        x = swing(0.3, 250, 1600, q=1.8, seed=330 + i, whistle=0.0, peak=0.3)
        x = mix(x, highpass(noise(0.12, 335 + i), 2000) * env_exp(0.12, 0.03, 0.005) * 0.25)
        out("dodge_%d" % (i + 1), x, peak_db=-4.0)
    out("jump", swing(0.25, 300, 1500, q=2.0, seed=340, whistle=0.0, peak=0.25), peak_db=-6.0)
    out("ground_impact", reverb(mix(thud(1.0, 65, 28, 0.3, 1.0, 400, 350) * 1.3,
                                    bandpass(noise(1.0, 351), 200, 3000) * env_exp(1.0, 0.12, 0.002) * 0.7,
                                    metal_hit(700, 0.8, ring=0.4, brightness=0.5, click=1.0, body=0.8, thump=0.0, seed=352) * 0.4),
                                1.2, 0.25), peak_db=-0.8)
    rattle = np.zeros(int(0.7 * SR))
    for k in range(7):
        s = metal_hit(RNG.uniform(900, 2600), 0.2, ring=0.15, brightness=0.6, click=0.6, body=0.8, thump=0.0, seed=360 + k)
        st = int(k * 0.035 * SR + RNG.uniform(0, 0.02) * SR)
        rattle[st:st + len(s)] += s[: max(0, len(rattle) - st)] * (1 - k * 0.1)
    out("kneel", reverb(mix(rattle * 0.6, thud(0.7, 75, 35, 0.12, 0.9, 500, 370)), 0.8, 0.15), peak_db=-1.5)
    out("body_fall", reverb(mix(thud(1.0, 70, 30, 0.2, 1.0, 400, 380) * 1.2, rattle * 0.5), 1.0, 0.2), peak_db=-1.0)

    # --- magic / ui / music-ish
    t = t_axis(1.4)
    chime = sum(a * np.sin(2 * math.pi * f * t) * np.exp(-t / tau)
                for f, a, tau in [(880, 0.5, 0.9), (1320, 0.35, 0.7), (1760, 0.25, 0.5), (2640, 0.12, 0.3)])
    gulp = sine_sweep(0.12, 220, 150, 1.0) * env_bell(0.12, 0.3) * 0.25
    out("heal", reverb(mix(chime * 0.6, delay(gulp, 0.05)), 1.2, 0.3), peak_db=-4.0)
    out("lockon", np.sin(2 * math.pi * 2200 * t_axis(0.04)) * env_exp(0.04, 0.008, 0.0005), peak_db=-8.0, st=False)
    dur = 4.0
    t = t_axis(dur)
    drone = sum(signal.sawtooth(2 * math.pi * f * t) for f in (55.0, 55.4, 82.4)) / 3.0
    drone = lowpass(drone, 380) * env_bell(dur, 0.35, 1.2)
    out("death", reverb(mix(drone * 0.7, gong(dur, 98, 2.2, 400, 0.9)), 2.5, 0.35, bright=3500), peak_db=-1.0)
    dur = 4.0
    rise = sum(a * np.sin(2 * math.pi * f * t_axis(dur)) * np.exp(-t_axis(dur) / tau) for f, a, tau in
               [(440, 0.4, 1.5), (660, 0.3, 1.3), (880, 0.25, 1.1), (1320, 0.15, 0.8)])
    out("victory", reverb(mix(gong(dur, 130, 2.4, 410, 1.0), thud(dur, 90, 38, 0.4, 0.8, 300, 411), delay(rise, 0.25) * 0.6),
                          2.8, 0.35, bright=4000), peak_db=-1.0)
    dur = 2.2
    t = t_axis(dur)
    vib = 1 + 0.03 * np.sin(2 * math.pi * 5.5 * t)
    growl = signal.sawtooth(2 * math.pi * np.cumsum(78 * vib) / SR) + 0.5 * signal.sawtooth(2 * math.pi * np.cumsum(117 * vib) / SR)
    growl = bandpass(growl, 150, 1400) * (0.7 + 0.3 * np.abs(np.sin(2 * math.pi * 17 * t)))
    growl += bandpass(noise(dur, 420), 300, 2500) * 0.4
    growl *= env_bell(dur, 0.25, 1.3)
    out("roar", reverb(mix(growl * 0.8, thud(dur, 70, 30, 0.5, 0.9, 300, 421) * 0.8), 2.0, 0.35, bright=4000), peak_db=-0.8)

    # --- ambience: seamless 16 s wind loop
    dur = 16.0
    t = t_axis(dur)
    base = lowpass(np.cumsum(noise(dur + 1, 500))[: len(t)], 420)
    base = highpass(base, 40)
    base /= np.max(np.abs(base)) + 1e-9
    lfo = 0.6 + 0.4 * np.sin(2 * math.pi * t / dur * 3) * np.sin(2 * math.pi * t / dur * 2 + 1.0)
    gust = swept_bandpass(noise(dur, 501), 500 + 350 * (1 + np.sin(2 * math.pi * t / dur * 4)), q=2.0) * 0.12
    x = base * lfo + gust * (0.5 + 0.5 * np.sin(2 * math.pi * t / dur * 5 + 2.0) ** 2)
    xf = int(1.5 * SR)
    head, tail = x[:xf].copy(), x[-xf:].copy()
    ramp = np.linspace(0, 1, xf)
    x = x[:-xf]
    x[:xf] = head * ramp + tail * (1 - ramp)
    if not only or only in "ambience_wind":
        st_x = np.stack([x, np.roll(x, int(0.013 * SR))], axis=1)
        peak = np.max(np.abs(st_x)) + 1e-9
        st_x = st_x / peak * 0.5
        data = (np.clip(st_x, -1, 1) * 32767).astype(np.int16)
        path = os.path.join(OUT, "ambience_wind.wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(data.tobytes())
        made.append(path)
    return made


if __name__ == "__main__":
    only = sys.argv[1] if len(sys.argv) > 1 else None
    files = build(only)
    total = sum(os.path.getsize(f) for f in files)
    print(f"wrote {len(files)} files, {total / 1e6:.1f} MB")
