extends Node
## Sound banks + voice pools. Sounds are built by tools/gen_audio.py into res://audio (from the
## recordings credited in audio/CREDITS.md). A bank deals its variations like a shuffled deck, so
## the same one never plays twice in a row and each comes round before any repeats, with a small
## random pitch offset on top: repeated deflects never sound machine-gunned. The randomness is
## Sfx's own, off the game's RNG (the lab seeds that one and the AI draws from it).
##
## The deflect is the one sound that must stand apart: play_deflect() plays it in two layers (the
## positional strike and a flat, wide ring carrying its note) on a bus of its own, "Deflect", and
## the SFX and Ambience buses duck under it (sidechain compressors), so for a moment it's all you
## hear.

const BANKS := {
	"deflect": ["deflect_1", "deflect_2", "deflect_3", "deflect_4", "deflect_5", "deflect_6"],
	"deflect_ring": ["deflect_ring_1", "deflect_ring_2", "deflect_ring_3", "deflect_ring_4",
		"deflect_ring_5", "deflect_ring_6"],
	"boss_parry": ["boss_parry_1", "boss_parry_2", "boss_parry_3"],
	"block": ["block_1", "block_2", "block_3", "block_4", "block_5"],
	"hit": ["hit_1", "hit_2", "hit_3", "hit_4"],
	"swing_light": ["swing_light_1", "swing_light_2", "swing_light_3", "swing_light_4"],
	"swing_heavy": ["swing_heavy_1", "swing_heavy_2", "swing_heavy_3", "swing_heavy_4"],
	"thrust": ["thrust"],
	"sweep": ["sweep"],
	"jab": ["jab_1", "jab_2"],
	"perilous": ["perilous"],
	"mikiri": ["mikiri"],
	"posture_break": ["posture_break"],
	"guard_break": ["guard_break"],
	"deathblow": ["deathblow"],
	"deathblow_pull": ["deathblow_pull"],
	"flick": ["flick"],
	"kick": ["kick"],
	"step": ["step_1", "step_2", "step_3", "step_4", "step_5", "step_6"],
	"stamp": ["stamp"],
	"land": ["land"],
	"dodge": ["dodge_1", "dodge_2"],
	"jump": ["jump"],
	"heal": ["heal"],
	"death": ["death"],
	"victory": ["victory"],
	"roar": ["roar"],
	"ground_impact": ["ground_impact"],
	"kneel": ["kneel"],
	"body_fall": ["body_fall"],
	"lockon": ["lockon"],
	"leap": ["leap"],
	"throw": ["throw_1", "throw_2"],
	"draw": ["draw"],
	"fire_charge": ["fire_charge"],
	"fire_blast": ["fire_blast"],
	"fire_ignite": ["fire_ignite"],
	"fire_whoosh": ["fire_whoosh"],
	"fire_flare": ["fire_flare"],
	"fire_hiss": ["fire_hiss"],
	"fire_gutter": ["fire_gutter"],
	"burn": ["burn"],
	"fire_fuse": ["fire_fuse"],
	"fire_eruption": ["fire_eruption"],
}

const POOL_3D := 24
## The deflect's note, climbing through a flurry: up the major pentatonic (root, 2nd, 3rd, 5th),
## so rings that overlap stay in tune with each other.
const DEFLECT_STEPS := [1.0, 1.125, 1.25, 1.5]
const POOL_2D := 8

var _streams: Dictionary = {}     ## bank -> Array[AudioStream]
var _decks: Dictionary = {}       ## bank -> Array[int]: the variations still to deal, in order
var _last: Dictionary = {}        ## bank -> the variation dealt last
var _rng := RandomNumberGenerator.new()
var _pool3d: Array[AudioStreamPlayer3D] = []
var _pool2d: Array[AudioStreamPlayer] = []
var _next3d := 0
var _next2d := 0
var _ambience: AudioStreamPlayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 7
	_setup_buses()
	for bank in BANKS:
		var arr: Array = []
		for file in BANKS[bank]:
			var path := "res://audio/%s.wav" % file
			if ResourceLoader.exists(path):
				var st := load(path) as AudioStream
				if st != null:
					arr.append(st)
		_streams[bank] = arr
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.unit_size = 9.0
		p.max_db = 6.0
		p.attenuation_filter_cutoff_hz = 12000.0
		p.panning_strength = 0.7
		add_child(p)
		_pool3d.append(p)
	for i in POOL_2D:
		var p2 := AudioStreamPlayer.new()
		p2.bus = "SFX"
		add_child(p2)
		_pool2d.append(p2)
	_ambience = AudioStreamPlayer.new()
	_ambience.bus = "Ambience"
	_ambience.volume_db = -14.0     # kept level with the SFX bus's -4 dB
	add_child(_ambience)


func _setup_buses() -> void:
	if AudioServer.get_bus_index("SFX") == -1:
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, "SFX")
		AudioServer.set_bus_send(idx, "Master")
		# Headroom: at 0 dB a close deflect peaked ~4 dB over the master limiter, which flattened
		# its snap. The limiter is only a safety net now.
		AudioServer.set_bus_volume_db(idx, -4.0)
		AudioServer.add_bus_effect(idx, _room())
		AudioServer.add_bus_effect(idx, _ducker())
	if AudioServer.get_bus_index("Ambience") == -1:
		AudioServer.add_bus()
		var idx2 := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx2, "Ambience")
		AudioServer.set_bus_send(idx2, "Master")
		AudioServer.add_bus_effect(idx2, _ducker())
	# After the others, so it's mixed first and their duckers hear it in the same block.
	if AudioServer.get_bus_index("Deflect") == -1:
		AudioServer.add_bus()
		var idx3 := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx3, "Deflect")
		AudioServer.set_bus_send(idx3, "Master")
		AudioServer.set_bus_volume_db(idx3, -4.0)
		AudioServer.add_bus_effect(idx3, _room())
	var master := AudioServer.get_bus_index("Master")
	if AudioServer.get_bus_effect_count(master) == 0 and ClassDB.class_exists("AudioEffectHardLimiter"):
		var lim := ClassDB.instantiate("AudioEffectHardLimiter") as AudioEffect
		if lim != null:
			lim.set("ceiling_db", -0.5)
			AudioServer.add_bus_effect(master, lim)


## The plaza's air: a short, open reverb.
func _room() -> AudioEffectReverb:
	var rev := AudioEffectReverb.new()
	rev.room_size = 0.62
	rev.damping = 0.55
	rev.spread = 0.9
	rev.predelay_msec = 28.0
	rev.wet = 0.13
	rev.dry = 1.0
	return rev


## Ducks a bus under the deflect: up to ~7 dB on its strike, let go over a quarter second.
func _ducker() -> AudioEffectCompressor:
	var c := AudioEffectCompressor.new()
	c.sidechain = &"Deflect"
	c.threshold = -16.0
	c.ratio = 3.0
	c.attack_us = 300.0
	c.release_ms = 260.0
	c.gain = 0.0
	return c


## The next variation of `bank`: dealt from a shuffled deck, reshuffled when it runs out (never
## starting the new deck with the one just played).
func _pick(bank: String) -> AudioStream:
	var arr: Array = _streams.get(bank, [])
	if arr.is_empty():
		return null
	if arr.size() == 1:
		return arr[0]
	var deck: Array = _decks.get(bank, [])
	if deck.is_empty():
		for i in arr.size():
			deck.append(i)
		for i in range(deck.size() - 1, 0, -1):
			var j := _rng.randi_range(0, i)
			var tmp: int = deck[i]
			deck[i] = deck[j]
			deck[j] = tmp
		if deck[0] == int(_last.get(bank, -1)):
			deck.append(deck.pop_front())
	var k: int = deck.pop_front()
	_decks[bank] = deck
	_last[bank] = k
	return arr[k]


func _jitter(pitch: float, jitter: float) -> float:
	return maxf(0.05, pitch * (1.0 + _rng.randf_range(-jitter, jitter)))


## Your deflect: the strike at `pos` and the ring over it, on the Deflect bus, which ducks
## everything else. `chain` counts the deflects of a flurry (1 for the first): the note climbs.
func play_deflect(pos: Vector3, chain := 1) -> void:
	play("deflect", pos, 4.0, 1.0, 0.03, &"Deflect")
	play_ui("deflect_ring", 0.0, DEFLECT_STEPS[clampi(chain - 1, 0, DEFLECT_STEPS.size() - 1)], 0.0, &"Deflect")


## Positional one-shot.
func play(bank: String, pos: Vector3, volume_db := 0.0, pitch := 1.0, jitter := 0.04,
		bus: StringName = &"SFX") -> void:
	var st := _pick(bank)
	if st == null:
		return
	var p := _pool3d[_next3d]
	_next3d = (_next3d + 1) % _pool3d.size()
	p.stop()
	p.stream = st
	p.bus = bus
	p.global_position = pos
	p.volume_db = volume_db
	p.pitch_scale = _jitter(pitch, jitter)
	p.play()


## Non-positional one-shot (UI and feedback that must always be heard clearly).
func play_ui(bank: String, volume_db := 0.0, pitch := 1.0, jitter := 0.0,
		bus: StringName = &"SFX") -> void:
	var st := _pick(bank)
	if st == null:
		return
	var p := _pool2d[_next2d]
	_next2d = (_next2d + 1) % _pool2d.size()
	p.stop()
	p.stream = st
	p.bus = bus
	p.volume_db = volume_db
	p.pitch_scale = _jitter(pitch, jitter)
	p.play()


## The wind: a seamless loop (the file's tail is crossfaded into its head), looped by the stream
## itself so there's no gap.
func start_ambience() -> void:
	var path := "res://audio/ambience_wind.wav"
	if not ResourceLoader.exists(path):
		return
	if _ambience.stream == null:
		var st := (load(path) as AudioStreamWAV).duplicate() as AudioStreamWAV
		if st == null:
			return
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_begin = 0
		st.loop_end = int(st.get_length() * st.mix_rate)
		_ambience.stream = st
	if not _ambience.playing:
		_ambience.play()


func stop_ambience() -> void:
	_ambience.stop()
