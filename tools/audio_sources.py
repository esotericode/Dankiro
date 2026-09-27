"""The recordings the sound effects are built from: where each comes from, who made it, its licence.

Every source is CC0 / public domain or CC BY (credit given in audio/CREDITS.md, which
tools/gen_audio.py writes from this table). Nothing here is share-alike or non-commercial.
Files are fetched from pinned commits into tools/.cache/audio_src/ (git-ignored) on first use.

    from audio_sources import load
    x = load("anvil_1")          # float64 mono at 44.1 kHz, peak 1
"""
import os
import subprocess
import urllib.parse
import urllib.request

import numpy as np

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "tools", ".cache", "audio_src")

# Collections, pinned. `raw` builds a file's URL from its path.
REPOS = {
    "vcsl": dict(
        name="Versilian Community Sample Library (VCSL)", by="Versilian Studios and contributors",
        link="https://github.com/sgossner/VCSL", license="CC0 1.0",
        raw="https://raw.githubusercontent.com/sgossner/VCSL/c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e/"),
    "sonicpi": dict(
        name="Sonic Pi sample set (from freesound.org, CC0)", by="the freesound.org authors below",
        link="https://github.com/sonic-pi-net/sonic-pi/tree/main/etc/samples", license="CC0 1.0",
        raw="https://raw.githubusercontent.com/sonic-pi-net/sonic-pi/42ff6e2dd5edf5e6ddd333c226650566f3180d6f/etc/samples/"),
    "blanket": dict(
        name="Blanket (ambient sounds app)", by="",
        link="https://github.com/rafaelmardojai/blanket/blob/master/SOUNDS_LICENSING.md", license="see each file",
        raw="https://raw.githubusercontent.com/rafaelmardojai/blanket/9d229d2be7cb6619135d55ff9e49926e40298686/data/resources/sounds/"),
    "minetest": dict(
        name="Minetest Game", by="",
        link="https://github.com/luanti-org/minetest_game", license="see each file",
        raw="https://raw.githubusercontent.com/luanti-org/minetest_game/c42e4d0c0ff9d27ff7b9b308c3cfc14098dd3a0f/mods/"),
    "kenney_fps": dict(
        name="Kenney Starter Kit FPS", by="Kenney (kenney.nl)",
        link="https://github.com/KenneyNL/Starter-Kit-FPS", license="CC0 1.0",
        raw="https://raw.githubusercontent.com/KenneyNL/Starter-Kit-FPS/185fd2326d74a5cf858cffc616f87cf9696f9cc0/sounds/"),
    "kenney_plat": dict(
        name="Kenney Starter Kit 3D Platformer", by="Kenney (kenney.nl)",
        link="https://github.com/KenneyNL/Starter-Kit-3D-Platformer", license="CC0 1.0",
        raw="https://raw.githubusercontent.com/KenneyNL/Starter-Kit-3D-Platformer/3fa8a04b1c01ab23db43123d4ce814a34c3fc7f0/sounds/"),
    "veloren": dict(
        name="Veloren (authors and licences from its assets/credits.ron)", by="",
        link="https://gitlab.com/veloren/veloren", license="see each file",
        raw="https://gitlab.com/veloren/veloren/-/raw/b68cd6ea60302bcba0de8fd27bdf8af277789002/assets/voxygen/audio/sfx/"),
}

CC0 = "CC0 1.0"
CC_BY3 = "CC BY 3.0"
CC_BY4 = "CC BY 4.0"
PD = "Public domain"

_VC = "Idiophones/Struck Idiophones/"
_VM = "Membranophones/Struck Membranophones/"

# key: (repo, path, credit or None, licence or None (the repo's), origin link or None)
SOURCES = {
    # --- metal, struck (VCSL)
    **{"anvil_%d%d" % (h, v): ("vcsl", _VC + "Anvil/Anvil_Hit%d_v%d_rr1_Mid.wav" % (h, v), None, None, None)
       for h in (1, 2, 3) for v in (1, 2, 3)},
    "brake_1": ("vcsl", _VC + "Brake Drum/BrakeDrum1_Hammer_v3_rr1_Mid.wav", None, None, None),
    "brake_2": ("vcsl", _VC + "Brake Drum/BrakeDrum1_Hammer_v2_rr1_Mid.wav", None, None, None),
    "brake_3": ("vcsl", _VC + "Brake Drum/BrakeDrum2_Hammer1_v2_rr1_Mid.wav", None, None, None),
    "brake_4": ("vcsl", _VC + "Brake Drum/BrakeDrum2_Hammer3_v3_rr1_Mid.wav", None, None, None),
    "brake_5": ("vcsl", _VC + "Brake Drum/BrakeDrum2_Hammer3_v2_rr1_Mid.wav", None, None, None),
    "brake_6": ("vcsl", _VC + "Brake Drum/BrakeDrum1_Hammer_v1_rr1_Mid.wav", None, None, None),
    "finger_cymbal": ("vcsl", _VC + "Finger Cymbals/Fing_Cymb.wav", None, None, None),
    "gong_f": ("vcsl", _VC + "Gong 1/gong_f.wav", None, None, None),
    "gong_fff": ("vcsl", _VC + "Gong 1/gong_fff.wav", None, None, None),
    "gong_mf": ("vcsl", _VC + "Gong 1/gong_mf.wav", None, None, None),
    "gong2_f": ("vcsl", _VC + "Gong 1/gong_2_f.wav", None, None, None),
    "gong_scrape": ("vcsl", _VC + "Gong 1/gong_scrape_mf.wav", None, None, None),
    "crash_short_1": ("vcsl", _VC + "Clash Cymbals 1/cymbal_crash1_short1.wav", None, None, None),
    "crash_short_2": ("vcsl", _VC + "Clash Cymbals 1/cymbal_crash1_short2.wav", None, None, None),
    "crash_ff": ("vcsl", _VC + "Clash Cymbals 1/cymbal_crash1_ff2.wav", None, None, None),
    "cym_stick": ("vcsl", _VC + "Suspended Cymbal 1/susCymb1_hit_stick_f1.wav", None, None, None),
    "cym_bell": ("vcsl", _VC + "Suspended Cymbal 1/susCymb1_hit_bell_fff1.wav", None, None, None),
    "cym_bell_mf": ("vcsl", _VC + "Suspended Cymbal 1/susCymb1_hit_bell_mf1.wav", None, None, None),
    "cym_cresc": ("vcsl", _VC + "Suspended Cymbal 1/susCymb1_cresc_2s.wav", None, None, None),
    "cym_scrape": ("vcsl", _VC + "Suspended Cymbal 1/susCymb1_scrape_1.wav", None, None, None),
    "handbell_1": ("vcsl", _VC + "Hand Bells, Nepalese/HB_1.wav", None, None, None),
    "handbell_2": ("vcsl", _VC + "Hand Bells, Nepalese/HB_2.wav", None, None, None),
    "handbell_3": ("vcsl", _VC + "Hand Bells, Nepalese/HB_3.wav", None, None, None),
    "tubular_c3": ("vcsl", _VC + "Tubular Bells 1/chimes_C3_f_rr1.wav", None, None, None),
    "tubular_d3": ("vcsl", _VC + "Tubular Bells 1/chimes_D3_ff_rr1.wav", None, None, None),
    "tubular_e3": ("vcsl", _VC + "Tubular Bells 1/chimes_E3_ff_rr2.wav", None, None, None),
    "tubular_g#3": ("vcsl", _VC + "Tubular Bells 1/chimes_G#3_ff_rr1.wav", None, None, None),
    "tubular_c4": ("vcsl", _VC + "Tubular Bells 1/chimes_C4_ff_rr2.wav", None, None, None),
    "triangle": ("vcsl", _VC + "Triangles/Legacy/1/triangle1_hit_mp.wav", None, None, None),
    "triangle_muted": ("vcsl", _VC + "Triangles/Legacy/1/triangle1_hit_mp_muted1.wav", None, None, None),
    "triangle2": ("vcsl", _VC + "Triangles/Legacy/2/triangle2_hit_mp.wav", None, None, None),
    "chimes_desc": ("vcsl", _VC + "Mark Trees/Legacy/windchimes_desc1.wav", None, None, None),
    # --- wood (VCSL)
    "wood_f1": ("vcsl", _VC + "Woodblock/wood_click_f_rr1.wav", None, None, None),
    "wood_f2": ("vcsl", _VC + "Woodblock/wood_click_f_rr2.wav", None, None, None),
    "wood_mp": ("vcsl", _VC + "Woodblock/wood_click_mp.wav", None, None, None),
    "wood_pp": ("vcsl", _VC + "Woodblock/wood_click_pp_rr1.wav", None, None, None),
    "claves_1": ("vcsl", _VC + "Claves/Claves1_Hit_v2_rr1_Mid.wav", None, None, None),
    "claves_2": ("vcsl", _VC + "Claves/Claves2_Hit_v2_rr1_Mid.wav", None, None, None),
    "slapstick_1": ("vcsl", _VC + "Slapstick/slapstick_rr1.wav", None, None, None),
    "slapstick_2": ("vcsl", _VC + "Slapstick/slapstick_rr2.wav", None, None, None),
    "slapstick_q": ("vcsl", _VC + "Slapstick/slapstick_quiet_rr1.wav", None, None, None),
    "logdrum_lo": ("vcsl", _VC + "Slit Drum/LogDrumLo_MedM_v3_rr1_Sum.wav", None, None, None),
    "cajon_bass": ("vcsl", _VC + "Cajon/Cajon_hit1_fff_rr1.wav", None, None, None),
    "cajon_slap": ("vcsl", _VC + "Cajon/Cajon_hit3_f_rr1.wav", None, None, None),
    # --- drums (VCSL)
    "bass_drum_1": ("vcsl", _VM + "Bass Drum 1/BDrumNew_hit_v7_rr1_Sum.wav", None, None, None),
    "bass_drum_2": ("vcsl", _VM + "Bass Drum 1/BDrumNew_hit_v7_rr2_Sum.wav", None, None, None),
    "bass_drum_soft": ("vcsl", _VM + "Bass Drum 1/BDrumNew_hit_v3_rr1_Sum.wav", None, None, None),
    "frame_1": ("vcsl", _VM + "Frame Drum/HDrumL_Hit_v3_rr1_Sum.wav", None, None, None),
    "frame_2": ("vcsl", _VM + "Frame Drum/HDrumL_Hit_v3_rr2_Sum.wav", None, None, None),
    "frame_muted": ("vcsl", _VM + "Frame Drum/HDrumL_HitMuted_v3_rr1_Sum.wav", None, None, None),
    "frame_s_muted": ("vcsl", _VM + "Frame Drum/HDrumS_HitMuted_v3_rr1_Sum.wav", None, None, None),
    "timpani_lo": ("vcsl", _VM + "Timpani 1/Hit/Timpani1_Hit_v4_rr1_Sum.wav", None, None, None),
    "timpani_2": ("vcsl", _VM + "Timpani 1/Hit/Timpani2_Hit_v4_rr1_Sum.wav", None, None, None),
    "timpani_roll": ("vcsl", _VM + "Timpani 1/Roll/Timpani1_Roll_v5_rr1_Sum.wav", None, None, None),
    # --- Sonic Pi (freesound CC0)
    "cineboom": ("sonicpi", "misc_cineboom.flac", "Northern_Monkey", None, "https://freesound.org/s/177242/"),
    "swoosh": ("sonicpi", "perc_swoosh.flac", "hullum", None, "https://freesound.org/s/415580/"),
    "swash": ("sonicpi", "perc_swash.flac", "qubodup", None, "https://freesound.org/s/60009/"),
    "ambi_swoosh": ("sonicpi", "ambi_swoosh.flac", "Halgrimm", None, "https://freesound.org/s/169867/"),
    "dark_woosh": ("sonicpi", "ambi_dark_woosh.flac", "EcoDTR", None, "https://freesound.org/s/27281/"),
    "impact_1": ("sonicpi", "perc_impact1.flac", "hullum", None, "https://freesound.org/s/415578/"),
    "impact_2": ("sonicpi", "perc_impact2.flac", "hullum", None, "https://freesound.org/s/415581/"),
    "heavy_kick": ("sonicpi", "drum_heavy_kick.flac", "Zajo", None, "https://freesound.org/s/4832/"),
    "bd_boom": ("sonicpi", "bd_boom.flac", "Snapper4298", None, "https://freesound.org/s/157245/"),
    "lunar_land": ("sonicpi", "ambi_lunar_land.flac", "maqsim", None, "https://freesound.org/s/172157/"),
    "snap": ("sonicpi", "perc_snap.flac", "SoundCollectah", None, "https://freesound.org/s/109400/"),
    "splash_hard": ("sonicpi", "drum_splash_hard.flac", "menegass", None, "https://freesound.org/s/100060/"),
    "hat_metal": ("sonicpi", "hat_metal.flac", "Stereo surgeon", None, "https://freesound.org/s/262516/"),
    "perc_bell": ("sonicpi", "perc_bell.flac", "AlaskaRobotics", None, "https://freesound.org/s/221515/"),
    "perc_door": ("sonicpi", "perc_door.flac", "hullum", None, "https://freesound.org/s/415579/"),
    "haunted_hum": ("sonicpi", "ambi_haunted_hum.flac", "kaligari", None, "https://freesound.org/s/35392/"),
    "glass_rub": ("sonicpi", "ambi_glass_rub.flac", "ani_music", None, "https://freesound.org/s/198403/"),
    "drone": ("sonicpi", "ambi_drone.flac", "Autistic Lucario", None, "https://freesound.org/s/195341/"),
    # --- ambience and fire
    "wind": ("blanket", "wind.ogg", "felix.blume (edited by Porrumentzio)", CC0, "https://freesound.org/s/217506/"),
    "fireplace": ("blanket", "fireplace.ogg", "ezwa", PD, "https://soundbible.com/1543-Fireplace.html"),
    "fire_1": ("minetest", "fire/sounds/fire_fire.1.ogg", "Dynamicell", CC_BY3, "https://freesound.org/s/17548/"),
    "fire_2": ("minetest", "fire/sounds/fire_fire.2.ogg", "Dynamicell", CC_BY3, "https://freesound.org/s/17548/"),
    "fire_3": ("minetest", "fire/sounds/fire_fire.3.ogg", "Dynamicell", CC_BY3, "https://freesound.org/s/17548/"),
    "fire_large": ("minetest", "fire/sounds/fire_large.ogg", "Dynamicell", CC_BY3, "https://freesound.org/s/17548/"),
    "flare_burn": ("minetest", "tnt/sounds/tnt_gunpowder_burning.ogg", "frankelmedico", CC0, "https://freesound.org/s/348767/"),
    "sparkler": ("minetest", "tnt/sounds/tnt_ignite.ogg", "theneedle.tv", CC0, "https://freesound.org/s/316682/"),
    "explode": ("minetest", "tnt/sounds/tnt_explode.ogg", "TumeniNodes", CC0, None),
    "metal_step_1": ("minetest", "default/sounds/default_metal_footstep.1.ogg", "mypantsfelldown", CC0, "https://freesound.org/s/398937/"),
    "metal_dug_1": ("minetest", "default/sounds/default_dug_metal.1.ogg", "qubodup", CC0, None),
    "metal_dug_2": ("minetest", "default/sounds/default_dug_metal.2.ogg", "qubodup", CC0, None),
    "metal_place_1": ("minetest", "default/sounds/default_place_node_metal.1.ogg", "Ogrebane", CC0,
                      "https://opengameart.org/content/wood-and-metal-sound-effects-volume-2"),
    "metal_place_2": ("minetest", "default/sounds/default_place_node_metal.2.ogg", "Ogrebane", CC0,
                      "https://opengameart.org/content/wood-and-metal-sound-effects-volume-2"),
    **{"stone_step_%d" % i: ("minetest", "default/sounds/default_hard_footstep.%d.ogg" % i, "Erdie", CC_BY3,
                             "https://freesound.org/s/41579/") for i in (1, 2, 3)},
    **{"sand_step_%d" % i: ("minetest", "default/sounds/default_sand_footstep.%d.ogg" % i, "worthahep88", CC0,
                            "https://freesound.org/s/319224/") for i in (1, 2, 3)},
    "chop_1": ("minetest", "default/sounds/default_dig_choppy.1.ogg", "lolamadeus", CC0, "https://freesound.org/s/179341/"),
    "gravel_dug_1": ("minetest", "default/sounds/default_gravel_dug.1.ogg", "lolamadeus", CC0, "https://freesound.org/s/179341/"),
    "walking": ("kenney_fps", "walking.ogg", None, None, None),
    "land_fps": ("kenney_fps", "land.ogg", None, None, None),
    "jump_a": ("kenney_fps", "jump_a.ogg", None, None, None),
    "land_plat": ("kenney_plat", "land.ogg", None, None, None),
    "fall_plat": ("kenney_plat", "fall.ogg", None, None, None),
    "break_plat": ("kenney_plat", "break.ogg", None, None, None),
    **{k: ("veloren", "abilities/%s.ogg" % k, "riccifl0w", CC_BY4, None)
       for k in ("fire_breath", "fire_dash", "flame_cloak", "napalm_pool", "napalm_strike", "pyroclasm_bolt",
                 "pyroclasm_charge")},
}

_used = set()


def fetch(key):
    """Path of the cached source file, downloading it first if needed."""
    repo, path = SOURCES[key][0], SOURCES[key][1]
    ext = os.path.splitext(path)[1]
    dst = os.path.join(CACHE, repo, key + ext)
    if not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        url = REPOS[repo]["raw"] + urllib.parse.quote(path)
        with urllib.request.urlopen(url, timeout=120) as r:
            data = r.read()
        if len(data) < 200 or data[:40].startswith(b"version https://git-lfs"):
            raise RuntimeError("%s: got %d bytes from %s" % (key, len(data), url))
        with open(dst + ".part", "wb") as f:
            f.write(data)
        os.replace(dst + ".part", dst)
    return dst


def load(key, stereo=False):
    """The source decoded to float64 at 44.1 kHz, peak-normalised to 1 (mono unless `stereo`)."""
    _used.add(key)
    path = fetch(key)
    ch = 2 if stereo else 1
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", str(ch), "-ar", str(SR), "-"],
                         check=True, capture_output=True).stdout
    x = np.frombuffer(raw, dtype=np.float32).astype(np.float64)
    if stereo:
        x = x.reshape(-1, 2)
    return x / (np.max(np.abs(x)) + 1e-12)


def used():
    return sorted(_used)


def credits_markdown(keys):
    """audio/CREDITS.md: every recording the shipped sounds are built from."""
    lines = ["# Sound credits", "",
             "The sound effects in this folder are built by `tools/gen_audio.py`: recordings from the",
             "collections below, cut, pitched, filtered and layered with synthesized parts. Every source is",
             "CC0 / public domain or CC BY; the CC BY ones are credited here as their licences ask (all of",
             "them modified: trimmed, pitched, filtered, mixed with other sounds).", ""]
    by_repo = {}
    for k in keys:
        by_repo.setdefault(SOURCES[k][0], []).append(k)
    for repo in sorted(by_repo, key=lambda r: REPOS[r]["name"].lower()):
        info = REPOS[repo]
        lines.append("## %s" % info["name"])
        lines.append("")
        if info["license"] == "see each file":
            lines.append("<%s>. Each file's author and licence:" % info["link"])
        else:
            lines.append("By %s, <%s>. Licence: %s." % (info["by"], info["link"], info["license"]))
        lines.append("")
        for k in sorted(by_repo[repo], key=lambda k: SOURCES[k][1].lower()):
            _, path, who, lic, origin = SOURCES[k]
            bits = ["`%s`" % path]
            if who:
                bits.append("by %s" % who)
            bits.append(lic or info["license"])
            if origin:
                bits.append("<%s>" % origin)
            lines.append("- " + ", ".join(bits))
        lines.append("")
    lines.append("Licences: CC0 1.0 <https://creativecommons.org/publicdomain/zero/1.0/>, "
                 "CC BY 3.0 <https://creativecommons.org/licenses/by/3.0/>, "
                 "CC BY 4.0 <https://creativecommons.org/licenses/by/4.0/>.")
    lines.append("")
    return "\n".join(lines)
