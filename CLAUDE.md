# Notes for Claude sessions on Dankiro

Dankiro is a Sekiro-style boss fight for Godot 4.7. The combat is tuned against
`docs/SEKIRO_MECHANICS.md`, where real Sekiro behaviour wins every tie. The README covers the
controls, the mechanics, the content pipeline and the tests.

## You can run Godot here. Install it first.

Earlier sessions assumed Godot couldn't be installed in the cloud container. It can. Direct
downloads (godotengine.org, GitHub release assets, tuxfamily) are blocked by the egress policy,
and conda-forge has no Godot. Docker Hub is reachable, though, and the public image
`barichello/godot-ci:<version>` contains the official binary.

```
bash tools/setup_godot.sh                 # ~1 min: Godot 4.7.2 -> /usr/local/bin/godot
godot --headless --editor --quit          # once per fresh checkout: imports audio/textures/fonts
```

The script uses no Docker daemon. It reads the image manifest from the registry API, finds
the layer created by the step that wgets Godot, streams it (about 1.4 GB), and extracts only
`usr/local/bin/godot`. It also installs Xvfb, Mesa lavapipe (software Vulkan) and ffmpeg for
rendering, plus the Python packages for `tools/`. Docker Hub often answers HTTP 429 at first;
the script backs off and retries, so let it run. For another version, set
`GODOT_VERSION=4.x.y` (list tags with the registry API: `/v2/barichello/godot-ci/tags/list`).

## Testing in the engine

- Combat lab (headless, about 6 min for everything, exits 0 when all checks pass; any engine or
  script error during the run also fails it):
  `godot --headless --fixed-fps 120 res://tests/combat_lab.tscn -- [suite ...] [--verbose]`
  Suites: reach, tells, deflect, flurry, punish, loop, phases, menu, camera, ribbons, spam, mikiri, dodge,
  sweep, shuriken, attack, cancel, inferno, tempest, soak. `camera` loads the real arena (main.tscn), like
  `menu`. `menu` drives the real menus with simulated gamepad input
  (`Input.parse_input_event`); it sets `Game.save_enabled = false` so tests never overwrite the
  saved options.
- Rendered frames (to actually *see* a change), using Movie Maker with software Vulkan:
  ```
  printf '[display]\nwindow/size/window_width_override=960\nwindow/size/window_height_override=540\n' > override.cfg
  VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json xvfb-run -a -s "-screen 0 1280x720x24" \
    godot --write-movie /tmp/cap/f.png --fixed-fps 30 res://tests/capture.tscn -- deflect
  ```
  Rendering takes about 3.5 s per frame at 640x360 (about 2.4 s before the forest and the
  mountains; 0.7 s before the floor model) and roughly twice that at 960x540, plus 20-30 s to
  start. Adding
  `[rendering]` `textures/default_filters/anisotropic_filtering_level=0` to `override.cfg` cuts a
  third while iterating. `override.cfg` is git-ignored. The shots are
  the `shot_*` functions in `tests/capture.gd`; `-- attack <clip> [distance]` films any boss
  attack from the lock-on camera, `diagnostics` shows the hitbox overlay, `edge` the lock-on camera
  with your back to the fence round the rim, `deathblow [final]` a
  posture break and the kill (the camera's deathblow shot, blood, 忍殺), `help` and
  `menu_controls` the controls sheet, `tempest` (`side`, `hold`) phase 3's six-blow string, and `inferno`
  (`stand`, `wide`) films phase 2's fire move (about 16 s: render it at 640x360 to iterate). Contact-sheet the
  PNGs with PIL, then look at them. `--fixed-fps 10` renders a third of the frames for a quick look.
- The game boots to a title menu. The capture harness sets `Game.skip_title` (and ignores the
  saved options: `Game.start_phase`, `Game.debug`) so shots go straight into the fight; the
  `menu_*` shots boot to the menu like the game. Options live in `user://settings.cfg`.
- Quick script-error check: `godot --headless --quit-after 600`.

## The UI (built in code)

- `scripts/ui/`: `Hud` (the fight's HUD and its overlays), `GameMenu` (title, pause, Options,
  Controls), `ControlsSheet` (bindings + how to fight), `VitalityBar`, `PostureBar`, and `UiTheme`,
  which holds the look: the colours, the two fonts (`UiTheme.sans(weight, tracking)` is Jost,
  `serif()` Cormorant Garamond, both variable: `FontVariation`s cached by weight and tracking),
  label and placement helpers, the blurred backdrop (`shaders/ui_backdrop.gdshader`), and the key
  and button glyphs (`UiTheme.chip`, `HintBar`). Keep new UI in that style: ink and ivory, vermilion
  only for what matters, thin flat shapes, no frames.
- Prompts follow `GameInput.gamepad` (the device you last pressed; `device_changed` fires when it
  flips). The menu marks its navigation events handled in `_input`, before the autoload's `_input`
  sees them, so it calls `GameInput.notice(event)` itself.
- The lab's `menu` suite finds menu items by their text ("Start fight", "Options", "Starting
  phase"...): an option's value is a child label, so the button's text stays the option's name.
- Iterate in flat mode: `DANKIRO_FLAT=<png>` makes `tests/capture.gd` skip the 3D world and put
  that still picture behind the live UI. Render the plate once at 1920x1080 (shots `plate_fight`,
  `menu_plate`), then `ui_hud`, `ui_hud_low`, `ui_moment <namecard|callout|deathblow|execution|death|victory|help>`,
  `menu_title`, `menu_options`, `menu_controls`, `menu_pause` take about 15 s each. The HUD's
  animations cap a frame's time at 0.1 s, so render at 10 fps or more to see them at speed. Check
  the result on real 3D frames too (the blur reads the screen).

## The boss model (Blender, scripted)

The boss is `models/boss.glb` (skinned) + `models/boss_staff.glb`, built by
`tools/build_boss_model.py` with Blender as a Python module. PyPI is reachable, so:

```
pip install bpy==4.5.9                      # Blender 4.5 LTS; needs Python 3.11 (the container has it)
python3 tools/build_boss_model.py --preview # ~3 min (Cycles bake); Blender renders in tools/preview_out/
python3 tools/build_models.py               # if material specs / ribbons changed
godot --headless --editor --quit            # import the new .glb (also registers new class_name scripts)
```

Then look at it in the engine with the capture shots `model`, `model_head`, `model_face` and
`model_combo`. Keep `gltf/embedded_image_handling=3` in the `.glb.import` files, or Godot
extracts duplicate texture PNGs into `models/`. CC0 asset sites (ambientCG, Poly Haven, Kenney,
Sketchfab, OpenGameArt) are blocked here; raw.githubusercontent.com and npm are reachable, and
the textures are generated by code anyway (`tools/model3d/textures.py`).

## The shinobi, the player's model (Blender, scripted)

The player is `models/player.glb` (skinned to the player rig) + `models/player_katana.glb`,
built by `tools/build_player_model.py` the same way as the boss (the pieces both builds share are
in `tools/model3d/charkit.py`; the helper bones and the jacket's skirt panels in
`tools/model3d/player_spec.py`).

```
python3 tools/build_player_model.py --preview   # ~3.5 min (Cycles bake); renders in tools/preview_out/player_*.png
python3 tools/build_player_model.py --shapes    # ~40 s: no bake or export, just a look at the shapes
python3 tools/build_models.py                   # the ribbons (scarf and headband tails) and the gourd
godot --headless --editor --quit                # import
```

- The eye slit is cut from the lofted hood along its columns (`HOOD_SEGS` = 60, so `SLIT_PHI`
  must be a multiple of 6 degrees). The face behind it is an object of its own (`player_face`)
  whose skin, brows and eyes are painted in the patch's (s, t) space (`face_texture`); the mask
  over the lower face is a separate layer.
- The katana's origin, blade direction and grip must match `data/rigs.json` "katana" (the hands
  grip it by IK, the trail and hit windows follow its blade polyline).
- Look at it with the capture shots `player_model`, `player_head`, `player_face` and
  `player_moves` (his slashes, a backstep, a jump and the gourd).

## The arena floor (Blender, scripted)

The plaza is `models/arena_floor.glb` (meshes `Stones`, `Bed`, `Water`) plus `textures/floor/`,
built by `tools/build_arena_floor.py` (layout, bevelled slabs, damage, Cycles AO bake, export) and
`tools/model3d/floor_textures.py` (tileable stone, moss, crack decals, the medallion carving). It
also needs `pip install shapely`.

```
python3 tools/build_arena_floor.py            # ~3-5 min (AO bake); --no-bake for layout work, --textures for textures only
godot --headless --editor --quit              # import
```

- Per-stone data rides in UV2 (x = id, y = type + 8 * crack decal + 64 * condition, plus
  0.05 + 0.9 * the edge factor). Blender's glTF exporter writes `(u, 1 - v)`, so the build pre-flips
  every exported UV (`gltf_uv`). The glb imports with `meshes/force_disable_compression=true` and no
  LODs, so that data survives; the floor textures import VRAM-compressed with mipmaps. Keep those
  `.import` settings.
- `shaders/flagstones.gdshader` (the stones), `floor_bed.gdshader` (the mortar in the joints) and
  `puddle.gdshader`; `Arena._build_floor()` binds textures to uniforms by name (the ground round the
  plaza is Scenery's terrain). Collision is still the flat box at y = 0: stone tops stay within
  5 mm of it and the curb at about +2.5 cm, so floor effects sit at y >= 0.03.
- Screen-space reflections don't show in lavapipe captures, so the puddle mirrors the fog itself
  (see its shader) and the lanterns streak across it through their specular.
- Look at it with the capture shot `floor <view>` (`overview`, `centre`, `medallion`, `puddle`, `moss`,
  `broken`, `rim`, `low`, `sweep`).

## The world round the plaza (Blender, scripted)

Everything past the plaza's rim is `models/scenery/*.glb` plus `textures/scenery/`, built by
`tools/build_scenery.py` (geometry, occlusion bakes, export) and `tools/model3d/scenery_textures.py`
(bark, leaf sprays, weathering, copper, boards, dry-stone wall, gravel, the torii's plaque).
`scripts/world/scenery.gd` (`Scenery`, built by `Arena`) loads them, swaps each material for a
game shader by its name (the `MATERIALS` table) and places everything.

```
python3 tools/build_scenery.py                 # all families, about a minute; --only trees torii ...
python3 tools/build_scenery.py --only trees --preview    # Blender renders in tools/preview_out/
godot --headless --editor --quit               # import
```

- Families (one glb each): `trees` (three cedars, the roped sacred cedar, black pines, red maples,
  shrubs, ferns, rocks), `torii`, `props` (the stone lantern and its paper, a fence post, a rail),
  `approach` (the shrine hall, its walled court with steps, the path; modelled in world
  coordinates) and `backdrop` (the summit's ground with the cliff to the east, three rings of
  mountains). `textures` writes the textures.
- A tree's crown is clumps (the inner mass, `foliage.gdshader`) under cards of leaf sprays
  (`leaves.gdshader`): squares in the object's xy plane that the shader turns to face the camera.
  It finds a card's centre from its UV and `card_size`, so `card_size` in `Scenery.MATERIALS` must
  match what the build passes to `Crown.parts()`. Cards sit out of the occlusion bake and copy
  it from the clump under them.
- UV2.x is baked occlusion, UV2.y a per-part value (a clump's tone, a mountain range's layer).
  UVs are pre-flipped (`gltf_uv`) as for the floor, and the glbs import with
  `meshes/force_disable_compression=true`, no LODs (they would drop leaf cards) and
  `gltf/embedded_image_handling=3`; the textures VRAM-compressed with mipmaps. Keep those settings.
- The scene's fog would bury the mountains, so they skip it and are drawn half-transparent over
  the sky, farthest range first (`render_priority`): they fade into whatever the sky looks like.
  Each range's haze and snow line are in `Scenery.MATERIALS`. Their faces must point up (a range
  that faced down drew unlit and black). The cloud sea (`cloud_sea.gdshader`, a plane at
  `Scenery.CLOUD_Y`) takes the normal fog.
- `Scenery.edge_radius()` repeats the build's `edge_radius()` (where the summit falls away; trees
  keep back from it): change both together.
- The fence you see is Scenery's; the wall that keeps the fight in is `Arena._build_boundary()`.
- Look at it with the capture shot `scenery <view>` (`torii`, `gate`, `north`, `south`, `east`,
  `west`, `vista`, `cliff`, `grove`, `shrine`, `lantern`, `high`).

## Conventions and pitfalls

- `data/*.json` is generated. Edit `tools/build_animations.py` or `tools/build_models.py`
  (or `tools/gen_audio.py` for sounds) and re-run them. `python3 tools/anim_preview.py <clip>`
  renders contact sheets, and `--all --check` reports IK and reach errors, rotations that take
  the long way between keys, and boss recoveries that whip back faster than 18 m/s.
- Rotations are interpolated as Euler angles. The build unwinds the boss's keys
  (`unwrap_rotations`) so each rotation takes the shortest way to the next key; a spin meant
  to happen has to be authored as many small steps.
- Set a CharacterBody3D's `position` *before* `add_child`. Spawning two bodies at the origin
  makes one depenetrate onto the other's head, and platform logic then carries it around.
- Hit-stop and slow-mo count unscaled frame time (`Game`), and `Game.deterministic` stamps
  inputs with the tick clock, so the lab and Movie Maker captures are reproducible.
- Drive the player in tests through `press_guard` / `release_guard` / `press_action` (the same
  entry points real input uses), with `bot_enabled = true`. Set `camera_yaw` so "forward"
  means toward the boss.
- Godot writes `.uid` and `.import` files next to assets. They're committed on purpose.
- Phase 2's fire move lives in `scripts/combat/inferno.gd` (the boss hands over to it in
  `Boss.S.INFERNO`); its fire is `scripts/fx/fire_fx.gd` and `staff_fire.gd`. Every flame is a
  shader (tongues, walls, embers, smoke) scrolling through `textures/fx/fire_noise.png`
  (`tools/gen_fx_textures.py`); a flame particle's colour is (heat, brightness, -, opacity).
  Fire is drawn additively in HDR: keep its colours near 1.0 and thin out overlapping flames, or
  it blows out to white under the glow. The staff's smoulder (his normal fighting) is kept low so
  strikes stay readable; captures `fire_staff [level]`, `fire_combo`, `inferno spin|plunge`.
  Phase 3 adds waves (`_send_waves` / `_move_waves`): rings of fire sent from his ring so they
  reach you on the half-beats between the arms (`WAVE_BEATS`), each steered like the turn
  (speed within `WAVE_STEER`), with the turn slowed to `GAP_WAVES` so there's 0.9 s between
  jumps (a jump and landing take ~0.77 s). The lab's `inferno` suite proves it's clearable;
  its bot can jump out of a landing after 0.08 s like a player. Captures: add `p3`.
- Cosmetic randomness in effects (blood splatter) comes from `Fx._rand`, not the global RNG: the
  lab seeds the global RNG and the AI draws from it, so an effect that called `randf()` would
  change how fights play out.
- Blood on the stones is `Decal`s (`Fx._splatter`: at most 36, each fading after 12 s) with the
  `textures/fx/blood_splat_*.png` from `tools/gen_fx_textures.py`.
- `foliage.gdshader` and `leaves.gdshader` spot the moon's shadow pass by its orthographic
  projection (`PROJECTION_MATRIX[3][3]`) and drop every other shadow-map texel there (the clumps
  also get gaps), so tree crowns cast a light dappled shade on the plaza instead of dark smears.
  An orthographic camera would see the crowns the same way.
- Sounds are built by `tools/gen_audio.py` from recordings listed in `tools/audio_sources.py`
  (pinned commits on GitHub/GitLab, fetched into `tools/.cache/audio_src/`; freesound, OpenGameArt
  and Kenney's site are blocked here, so new sources have to come from repos). Only CC0, public
  domain or CC BY: add each file's author and licence to the table, and a full build rewrites
  `audio/CREDITS.md`. Each sound is set to a loudness target (`save(name, x, lufs)`), so tune its
  level there and keep the volumes in code for mixing. You can't listen here: judge a sound by its
  log-frequency spectrogram and envelope, and Movie Maker captures write the game's mix to a WAV
  next to the frames. Sfx's randomness is its own RNG, like `Fx._rand`. The deflect
  (`Sfx.play_deflect`) is two layers, the strike (`deflect_N`, positional) and the ring
  (`deflect_ring_N`, flat stereo, pitched up `Sfx.DEFLECT_STEPS` through a flurry), on the
  "Deflect" bus, which the SFX and Ambience buses duck under (sidechain compressors): keep other
  sounds off that bus, and keep the note out of the strike (two notes a jitter apart go sour).
- Physics layers (`Combat.LAYER_*`): 1 is the world (the floor), 2 the invisible wall round the
  plaza, which only the fighters collide with. The camera's spring arm only hits layer 1, so at
  the rim it swings out over the fence instead of being squeezed onto your back; foliage and bark
  it comes close to out there dissolve (`shaders/near_fade.gdshaderinc`, not in the shadow pass).
- Cloth and hair are `SpringChain`s (`scripts/rig/spring_chain.gd`, set up per chain in
  `tools/build_models.py`: the SCARF, BAND, MANE, SASH and TASSEL presets). Physical units: gravity,
  drag across a ribbon's face (or a strand) and along it, a pose spring toward the rest shape with a
  natural frequency and damping ratio, a shared breeze with a flutter wave, a speed cap. Keep the
  pull toward the rest shape relative to the root (a pose), not to each point's parent: pulling a
  point toward its parent + rest pushes without pushing back and a towed ribbon snakes. Keep sway
  near 1 Hz and flutter well above it (they resonate). The lab's `ribbons` suite measures it; for
  tuning, `RIBBON_SET="flutter=0,..."`, `RIBBON_NOCOLLIDE=1`, `RIBBON_DUMP=<json>` and
  `RIBBON_BENCH=1` (see the suite's comment), and the capture shot `ribbons` films it.
- A boss string that steps in with every blow (phase 3's Tempest of Fangs, `b_tempest`) sets
  `hold_distance` on its clip: root motion stops that far from you (`Boss.hold_distance()`, and
  `anim_preview.py` clamps the same way), and its `close` windows (a list, one per gap between
  blows) bring him back to it if you back off. Without it he walks into you and the fighters
  overlap. A sequence's `min_phase` keeps a move to the later phases.
- The combat camera frames deathblows itself (`CombatCamera.play_deathblow`, called by the
  player): it swings beside the fighters while the kill plays out, then eases back.
