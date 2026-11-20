class_name Audio
extends Node
# ------------------------------------------------------------------------------
# Every sound in the game, synthesised from maths at runtime.
#
# WHY THERE ARE NO SOUND FILES: this project already generates all of its art
# from maths, there is no audio pipeline, and the only other option on the table
# was shipping silence. A silent action game does not read as "quiet", it reads
# as broken — the player assumes the mute switch, then assumes the app. So the
# five cues that combat actually needs are built here as raw PCM: a thud, a crit
# ring, a death fall, a cast sweep, a footstep.
#
# It is deliberately low-fi: 22 kHz, mono, 16-bit, a few kilobytes each, no
# reverb, no layering. That is a style decision rather than a compromise — a
# clean short synthetic thud sounds intentional, where a stretched or clipped
# sample sounds like a mistake. Each cue is generated once, cached, and played
# through a small round-robin voice pool.
#
# ROUTING, which is the part that matters as the game grows:
#
#   * boot() registers a hook on Combatant.on_spawn, so EVERY combatant — the
#     player's champion and every enemy, from whichever spawner — gets its
#     damaged/died cues without that spawner remembering to ask. Feedback that
#     has to be wired per spawn site is feedback that is missing at the next one.
#   * HeroController plays the cast and footstep cues, because only it knows
#     that a button was pressed or that a foot moved. It deliberately does NOT
#     play the hit cue: the spawn hook already covers the champion's own body.
#
# A cleave still reports six hits inside one frame, and RETRIGGER collapses
# those into one audible thud — see play().
# ------------------------------------------------------------------------------

## Mono, 22 kHz. High enough for a 1.7 kHz crit partial, a quarter the memory of
## 44.1 kHz stereo, and part of the intended lo-fi character.
const RATE: int = 22050

enum Cue { HIT, CRIT, DEATH, CAST, STEP }

## Per-cue mix, in dB. Hits sit under the music-free ambience, footsteps sit far
## under everything — a footstep you consciously hear is a footstep that will
## drive the player mad within a minute of walking.
const GAIN: Dictionary = {
	Cue.HIT: -7.0,
	Cue.CRIT: -3.5,
	Cue.DEATH: -4.5,
	Cue.CAST: -9.0,
	Cue.STEP: -21.0,
}

## The same cue cannot restart inside this window. A six-enemy cleave resolves
## six hits inside one frame, and six copies of one 170 ms thud starting within
## microseconds of each other is a flange, not a hit.
const RETRIGGER: float = 0.035

## Round-robin voices. Eight covers a cleave plus a death plus footsteps with
## the longest cue (death, 0.85 s) still ringing.
const VOICES: int = 8

## Off switches everything at the source, so a settings toggle costs nothing.
static var enabled: bool = true

## Test hooks. Playback itself cannot be asserted on a dummy audio driver, so
## the headless checks assert that the cue was *requested* and that the stream
## behind it is real PCM. See tools/feedbacktest.gd.
static var cues_played: int = 0
static var last_cue: int = -1

static var _streams: Dictionary = {}          # Cue -> AudioStreamWAV
static var _last_play: Dictionary = {}        # Cue -> seconds
static var _node: Audio = null

var _pool: Array[AudioStreamPlayer] = []
var _next: int = 0
var _steps: int = 0


# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------

## Create the voice pool and attach the combatant hook. Idempotent, and safe to
## call before there is anything to play.
##
## The node is parented deferred because boot() is called from inside another
## node's setup, when the tree is busy adding children. The hook, however, is
## registered SYNCHRONOUSLY: a combatant created later in the same frame as the
## boot would otherwise be born silent.
##
## PASS `ctx` — any node already in the tree — WHENEVER THERE IS ONE.
## Engine.get_main_loop() is null for the whole of a MainLoop script's own
## _init(), which is where a headless harness does its setup, so relying on it
## alone makes boot() a no-op that returns null and reports nothing. The result
## is a completely silent game and not one error to explain it, which is the
## same symptom as the audio never having been written.
static func boot(ctx: Node = null) -> Audio:
	if _node != null:
		if is_instance_valid(_node):
			return _node
		# A scene reload freed the old node while its Callable stayed behind in
		# Combatant.on_spawn, which is a static array. Left there, EVERY spawn
		# after the reload calls into a freed object.
		_drop_dead_hooks()
		_node = null

	var tree: SceneTree = null
	if ctx != null and ctx.is_inside_tree():
		tree = ctx.get_tree()
	else:
		var loop: MainLoop = Engine.get_main_loop()
		if loop is SceneTree:
			tree = loop as SceneTree
	if tree == null or tree.root == null:
		return null

	_node = Audio.new()
	_node.name = "HeroAudio"
	if not Combatant.on_spawn.has(Callable(_node, "_on_combatant_spawned")):
		Combatant.on_spawn.append(Callable(_node, "_on_combatant_spawned"))
	tree.root.add_child.call_deferred(_node)
	return _node


static func _drop_dead_hooks() -> void:
	var live: Array[Callable] = []
	for cb in Combatant.on_spawn:
		if cb.is_valid():
			live.append(cb)
	Combatant.on_spawn = live


func _ready() -> void:
	for i in range(VOICES):
		var p := AudioStreamPlayer.new()
		# Non-positional on purpose. The camera is overhead and the player drags
		# it around constantly, so 3D panning would swing the sound of your own
		# sword from ear to ear while you look about.
		p.bus = &"Master"
		add_child(p)
		_pool.append(p)


## Attached to every Combatant at construction. This is the whole of enemy audio
## until enemies have bodies of their own: a skeleton that is only a Combatant
## still thuds when hit and still groans when it dies.
func _on_combatant_spawned(c: Combatant) -> void:
	if c == null:
		return
	c.damaged.connect(func(_amount: float, crit: bool, _source: String) -> void:
		Audio.hit(crit))
	c.died.connect(func() -> void:
		Audio.death())


# ------------------------------------------------------------------------------
# Cues
# ------------------------------------------------------------------------------

static func hit(crit: bool = false) -> void:
	play(Cue.CRIT if crit else Cue.HIT)


static func death() -> void:
	play(Cue.DEATH)


## One sweep, pitched per slot. Four recognisably different casts out of a single
## 0.26 s buffer — cheaper and more consistent than four hand-tuned cues, and it
## reinforces that slot 3 is the big one.
static func ability(slot: int) -> void:
	const PITCH: Array[float] = [0.92, 1.0, 1.1, 1.22]
	play(Cue.CAST, PITCH[clampi(slot, 0, 3)])


static func footstep() -> void:
	# Alternating pitch so a run does not turn into a metronome.
	var n: Audio = _node
	var alt: float = 1.0
	if n != null:
		n._steps += 1
		alt = 1.07 if (n._steps % 2) == 0 else 0.93
	play(Cue.STEP, alt)


static func play(cue: int, pitch: float = 1.0) -> void:
	if not enabled:
		return
	var now: float = float(Time.get_ticks_msec()) / 1000.0
	if now - float(_last_play.get(cue, -999.0)) < RETRIGGER:
		return
	_last_play[cue] = now
	cues_played += 1
	last_cue = cue
	if _node != null:
		_node._emit(cue, pitch)


func _emit(cue: int, pitch: float) -> void:
	if _pool.is_empty():
		return                        # booted this frame; not in the tree yet
	var p: AudioStreamPlayer = _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = Audio.stream_for(cue)
	p.volume_db = float(GAIN[cue])
	p.pitch_scale = clampf(pitch, 0.5, 2.0)
	p.play()


# ------------------------------------------------------------------------------
# Synthesis
# ------------------------------------------------------------------------------

static func stream_for(cue: int) -> AudioStreamWAV:
	if _streams.has(cue):
		return _streams[cue]
	var s: AudioStreamWAV = _synth(cue)
	_streams[cue] = s
	return s


static func _synth(cue: int) -> AudioStreamWAV:
	match cue:
		Cue.CRIT: return _wav(_crit())
		Cue.DEATH: return _wav(_death())
		Cue.CAST: return _wav(_cast())
		Cue.STEP: return _wav(_step())
		_: return _wav(_thud())


## Deterministic white noise. A seeded LCG rather than randf() so a cue is
## byte-identical on every device and in every test run — audio that differs
## between runs cannot be regression-tested.
##
## NOT named `Noise`: Godot has a native class by that name, and an inner class
## that shadows one does not merely warn, it fails to parse — which took the
## whole of this file, and therefore every sound in the game, out of the build
## silently. The symptom was indistinguishable from "audio not wired up yet".
class Lcg extends RefCounted:
	var _s: int = 0x2545F49

	func _init(seed_v: int) -> void:
		_s = seed_v | 1

	func next() -> float:
		_s = (_s * 1103515245 + 12345) & 0x7FFFFFFF
		return float(_s % 20001) / 10000.0 - 1.0


static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var n: int = samples.size()
	# A buffer that stops on a non-zero sample clicks on EVERY play, and that
	# click is the single most recognisable sound of amateur procedural audio.
	var fade: int = mini(96, n)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in range(n):
		var v: float = samples[i]
		var tail: int = n - i
		if tail < fade:
			v *= float(tail) / float(fade)
		bytes.encode_s16(i * 2, int(round(clampf(v, -1.0, 1.0) * 32767.0)))

	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.loop_mode = AudioStreamWAV.LOOP_DISABLED
	s.data = bytes
	return s


static func _len(seconds: float) -> int:
	return int(round(seconds * float(RATE)))


## A hit: low body with a downward pitch drift, plus a noise transient for the
## impact. Short, so it can fire four times a second without becoming a drone.
static func _thud() -> PackedFloat32Array:
	var n: int = _len(0.17)
	var out := PackedFloat32Array()
	out.resize(n)
	var nz := Lcg.new(1337)
	for i in range(n):
		var t: float = float(i) / float(RATE)
		# Quadratic phase = linearly falling frequency: 118 Hz down to ~99 Hz.
		var body: float = sin(TAU * (118.0 * t - 55.0 * t * t))
		var click: float = nz.next() * exp(-t * 120.0)
		# ~18 samples of attack. Without it the very first sample IS the noise
		# transient at full amplitude, and a buffer that STARTS at 0.29 clicks
		# just as surely as one that ends there.
		var env: float = minf(t / 0.0008, 1.0) * exp(-t * 24.0)
		out[i] = clampf((body * 0.85 + click * 0.45) * env * 1.25, -1.0, 1.0)
	return out


## A crit: the same thud with a metallic ring on top. The ring, not the volume,
## is what makes it read as "that one was special" — a crit that is merely
## louder just sounds like the mix is wrong.
static func _crit() -> PackedFloat32Array:
	var n: int = _len(0.30)
	var out := PackedFloat32Array()
	out.resize(n)
	var nz := Lcg.new(90210)
	for i in range(n):
		var t: float = float(i) / float(RATE)
		var body: float = sin(TAU * (140.0 * t - 70.0 * t * t)) * exp(-t * 26.0)
		# Inharmonic partials (1 : 1.5 : 2.37) so it rings like struck metal
		# rather than sounding a musical note that fights the ambience.
		var ring: float = (sin(TAU * 742.0 * t) * 0.55
			+ sin(TAU * 1113.0 * t) * 0.33
			+ sin(TAU * 1759.0 * t) * 0.18) * exp(-t * 11.0)
		var click: float = nz.next() * exp(-t * 150.0) * 0.5
		var attack: float = minf(t / 0.0008, 1.0)        # see _thud()
		out[i] = clampf((body * 0.8 + ring * 0.6 + click) * attack * 1.1, -1.0, 1.0)
	return out


## A death: pitch collapsing from 190 Hz to a 48 Hz floor over most of a second,
## with a rumble under it and one last thud as the body lands. Long enough that
## it is still sounding while the corpse is on the ground, which is what ties
## the sound to the animation rather than to the health reaching zero.
static func _death() -> PackedFloat32Array:
	var n: int = _len(0.85)
	var out := PackedFloat32Array()
	out.resize(n)
	var nz := Lcg.new(424242)
	var phase: float = 0.0
	var lp: float = 0.0
	for i in range(n):
		var t: float = float(i) / float(RATE)
		# Phase is accumulated rather than solved, because an exponential
		# frequency fall has no tidy closed-form phase and getting it wrong
		# shows up as an audible chirp in the wrong direction.
		var f: float = 48.0 + 190.0 * exp(-t * 3.0)
		phase += TAU * f / float(RATE)
		lp += (nz.next() - lp) * 0.08             # one-pole: noise -> rumble
		var attack: float = minf(t / 0.008, 1.0)
		var env: float = attack * exp(-t * 2.6)
		var land: float = 0.0
		if t > 0.55:
			var u: float = t - 0.55
			land = sin(TAU * 70.0 * u) * exp(-u * 22.0) * 0.6
		out[i] = clampf((sin(phase) * 0.75 + lp * 1.6) * env + land, -1.0, 1.0)
	return out


## A cast: a fast rising sweep with its own octave above it. Rising, because a
## cast is an intention — the result is what gets a thud.
static func _cast() -> PackedFloat32Array:
	var dur: float = 0.26
	var n: int = _len(dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var nz := Lcg.new(777)
	var phase: float = 0.0
	var lp: float = 0.0
	for i in range(n):
		var t: float = float(i) / float(RATE)
		var f: float = 300.0 + 1500.0 * pow(t / dur, 1.6)
		phase += TAU * f / float(RATE)
		lp += (nz.next() - lp) * 0.25
		var env: float = minf(t / 0.006, 1.0) * exp(-t * 9.0)
		var tone: float = sin(phase) * 0.6 + sin(phase * 2.0) * 0.2
		out[i] = clampf((tone + lp * 0.25) * env, -1.0, 1.0)
	return out


## A footstep: a double-filtered noise burst, 80 ms, no tone at all. Anything
## pitched here starts to sound like a hoof.
static func _step() -> PackedFloat32Array:
	var n: int = _len(0.08)
	var out := PackedFloat32Array()
	out.resize(n)
	var nz := Lcg.new(5150)
	var a: float = 0.0
	var b: float = 0.0
	for i in range(n):
		var t: float = float(i) / float(RATE)
		var x: float = nz.next()
		a += (x - a) * 0.30
		b += (a - b) * 0.30
		var env: float = minf(t / 0.0015, 1.0) * exp(-t * 60.0)
		out[i] = clampf(b * env * 3.2, -1.0, 1.0)
	return out
