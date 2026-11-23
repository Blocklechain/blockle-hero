extends Node
# ------------------------------------------------------------------------------
# THE SPOKEN LINE, AND THE SUBTITLE THAT DOES NOT DEPEND ON IT.
#
# One line at a time, through one player, from a queue — and it degrades to
# silence without noticing. That last property is the whole design, not a
# fallback bolted on:
#
#   THE GAME SHIPS BEFORE EVERY LINE IS RENDERED. There are seventy-odd lines
#   in the table today and there will be more; wavs arrive in batches out of
#   tools/gen_voice.py, and a build is cut whenever a build is needed. So a
#   missing wav is NORMAL. It is not an error, it is not a warning, and above
#   all it must not take the TEXT with it — a beat that silently shows nothing
#   because its audio has not been recorded yet is a hole in the story that no
#   compile, no test and no reviewer would ever see.
#
# Therefore: the text is presented from the line table, the audio is an
# optional decoration on top of it, and the queue is timed by a clock this
# script owns rather than by the audio finishing.
#
# WHICH IS ALSO WHY THE QUEUE DOES NOT WAIT ON `finished`. On the headless
# dummy audio driver an AudioStreamPlayer reports `playing == true`, never
# advances its position, and NEVER emits `finished` — so a queue that advances
# only on that signal wedges after its first line, forever, with no error. It
# would wedge on any platform that dropped the callback, too. `advance(delta)`
# retires a line when its time is up; `finished` arriving early is allowed to
# retire it sooner, and neither is load-bearing on its own.
#
# ------------------------------------------------------------------------------
# WHERE THE WORDS COME FROM, AND WHY NOT FROM HERE.
#
# Story.gd owns the prose. It is canon, it is checked against docs/STORY.md,
# and this script holds not one word of it. The first version of this pipeline
# kept its own copy of the narration in assets/voice/lines.json because
# Story.gd did not exist yet, and by the time it did the two copies had already
# contradicted each other on who the player is. So the manifest was demoted to
# CASTING — which voice, which speed, which mix level, and what each line's wav
# is called — and the text is read straight out of Story.gd here.
#
# THE KEY SCHEME HAS EXACTLY ONE IMPLEMENTATION, and it is this file. A
# renderer that derived its own filenames would be a second implementation,
# which would eventually name a wav something this script does not look for;
# the line would then go silent with every individual piece of the system
# working exactly as written. So tools/gen_voice.py does not derive anything:
# it calls render_table() and renders what it is handed.
#
# WIRING. `on_line` / `on_line_end` are static Callable arrays rather than
# signals on this node, following Combatant.on_spawn: a subtitle sink can
# register before the node exists and without resolving an instance, and a line
# said during a load screen is not lost because nobody had connected yet. The
# node also emits `line_started` / `line_ended` for anything that prefers to
# connect.
#
# PRELOAD IT BY PATH. This script deliberately declares no class_name: one
# added outside the editor is not in Godot's global cache, so every consumer
# naming it fails to PARSE, and the failure surfaces in whatever unrelated
# harness loads that consumer first. That has cost this project four debugging
# sessions; see tools/classcheck.gd.
#
#   const NarrationS := preload("res://scripts/game/Narration.gd")
#
#   NarrationS.boot(self)                       # once, from Play
#   NarrationS.on_line.append(_show_subtitle)   # from the HUD
#   NarrationS.say_story("act_open", act)       # both lines of the opener
#   NarrationS.say_story("boss_taunt", act)
#   NarrationS.say_story("region_flavour", 0, map_index)
#   NarrationS.say("quest_paid")                # a utility line
#   NarrationS.skip()
# ------------------------------------------------------------------------------

# A SCRIPT CANNOT NAME ITSELF by class_name either, so `Narration.new()` inside
# this file would not compile on a fresh checkout. Preloading itself resolves to
# the same resource either way.
const Self := preload("res://scripts/game/Narration.gd")

## Canon. Taken by path, never by a bare class_name, for the reason in the
## header. This script reads it and never writes it.
const StoryS := preload("res://scripts/game/Story.gd")

## The casting table: beats to voices, and the filename pattern for each of
## Story's beats. Also read by tools/gen_voice.py for the voice ids.
const MANIFEST_PATH: String = "res://assets/voice/lines.json"

## Where the rendered wavs live: <dir>/<key>.wav. Swappable because the harness
## points it at a scratch directory to prove both paths — a tree with no audio
## at all, and a tree with one file in it. See set_voice_dir().
const DEFAULT_VOICE_DIR: String = "res://assets/voice"

## How a line with NO audio is timed: words / second of reading, clamped. These
## are a reading speed, not a guess at the missing wav's length — the thing on
## screen is text, and the only question is how long it takes to read.
const SILENT_WPS: float = 2.6
const READ_MIN: float = 1.4
const READ_MAX: float = 7.5

## A voiced line holds for at least this long even if its wav is shorter. A
## clipped or truncated render would otherwise flash its subtitle for three
## frames and read as a glitch rather than as a line.
const READ_FLOOR: float = 1.1

## Breath between queued lines. Back-to-back narration with no gap sounds like
## one run-on sentence spoken by two people.
const GAP: float = 0.35

## How many lines may be WAITING. Narration is triggered by events — entering an
## act, a boss noticing you — and a line whose moment has passed is worse than
## no line, so an overflowing queue drops its OLDEST pending entry, never the
## newest. Four is "the boss taunt you just earned, plus a little slack".
const QUEUE_MAX: int = 4

## Audio off switch, at the source, for a settings toggle. TEXT IS UNAFFECTED:
## muting the narrator must not mute the story.
static var enabled: bool = true

# --- observable state ---------------------------------------------------------
#
# Deliberately state, not just signals. The single most common bug in this
# project is a feature that emits perfectly into a listener nobody connected,
# so what is spoken is readable after the fact: tools/voicetest.gd asserts on
# these, and so can the HUD, without subscribing to anything.

## The line on screen right now, "" between lines.
static var current_key: String = ""
static var current_text: String = ""
## Lines PRESENTED (text shown) — always the sum of the two below.
static var lines_shown: int = 0
## ...of which had a wav behind them, and had not.
static var lines_voiced: int = 0
static var lines_silent: int = 0
## Lines retired early by skip(), and lines dropped by queue overflow.
static var lines_skipped: int = 0
static var lines_dropped: int = 0
## Keys said, oldest first. Capped — it is a diagnostic, not a save file.
static var history: PackedStringArray = PackedStringArray()
const HISTORY_MAX: int = 64

## Subtitle sinks. `on_line` is called with (key, text) the moment a line is
## presented; `on_line_end` with (key) when it retires. See the header for why
## these are arrays and not signals.
static var on_line: Array[Callable] = []
static var on_line_end: Array[Callable] = []

signal line_started(key: String, text: String)
signal line_ended(key: String)

static var _node: Self = null
static var _voice_dir: String = DEFAULT_VOICE_DIR
static var _lines: Dictionary = {}          # key -> {text, beat, source}
static var _beats: Dictionary = {}          # beat -> {voice, speed, gain_db}
static var _story_beats: Dictionary = {}    # story beat -> {cast, key, index}
static var _default_beat: String = ""
static var _loaded: bool = false
## key -> AudioStreamWAV, or null for "looked, not there". The null entries are
## the point: a missing line must cost one filesystem check, not one per say().
static var _streams: Dictionary = {}

static var _queue: Array[Dictionary] = []
static var _in_flight: bool = false
static var _hold: float = 0.0
static var _gap: float = 0.0
static var _warned: Dictionary = {}

var _player: AudioStreamPlayer = null


# ------------------------------------------------------------------------------
# Lifecycle
# ------------------------------------------------------------------------------

## Put a narrator in the tree. Idempotent, and safe before there is anything to
## say — say() works unbooted, it simply has no audio to attach.
##
## PASS `ctx` — any node already in the tree — WHENEVER THERE IS ONE.
## Engine.get_main_loop() is null for the whole of a MainLoop script's own
## _init(), which is where a headless harness sets itself up, so relying on it
## alone makes boot() a no-op returning null. The result is a game that shows
## every subtitle in silence and not one error explaining why, which is
## indistinguishable from the wavs never having been rendered.
static func boot(ctx: Node = null) -> Self:
	if _node != null:
		if is_instance_valid(_node):
			return _node
		_node = null                    # scene reload freed it

	var tree: SceneTree = null
	if ctx != null and ctx.is_inside_tree():
		tree = ctx.get_tree()
	else:
		var loop: MainLoop = Engine.get_main_loop()
		if loop is SceneTree:
			tree = loop as SceneTree
	if tree == null or tree.root == null:
		return null

	_node = Self.new()
	_node.name = "Narration"
	# DEFERRED, like Audio.boot(): this is called from inside another node's
	# setup, when the tree is busy adding children, and a direct add_child there
	# errors out and leaves the game with no narrator at all.
	tree.root.add_child.call_deferred(_node)
	return _node


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	# Non-positional: a narrator has no position in the world, and the boss
	# taunt has to be audible wherever the player has dragged the camera to.
	_player.bus = &"Master"
	add_child(_player)
	# Allowed to retire a line EARLY, never to be the only thing that can —
	# see the header on the dummy driver never emitting this.
	_player.finished.connect(_on_stream_finished)
	_catch_up()


## Start the audio of a line that was said in the frame BEFORE this node reached
## the tree. Without this, the first narration of a session — the act opener,
## said by whatever boots the map, in the same frame as boot() — is the one line
## in the game that is always silent, and only on a cold start, which is as
## thin a repro as this project has had.
func _catch_up() -> void:
	if not Self._in_flight or not Self.enabled or Self.current_key.is_empty():
		return
	var stream: AudioStreamWAV = Self.stream_for(Self.current_key)
	if stream == null:
		return
	var length: float = _speak(stream, Self.beat_of(Self.current_key))
	if length <= 0.0:
		return
	# It was counted as silent when it was presented; it is not.
	Self.lines_silent = maxi(Self.lines_silent - 1, 0)
	Self.lines_voiced += 1
	Self._hold = maxf(Self._hold, maxf(length, READ_FLOOR))


func _process(delta: float) -> void:
	Self.advance(delta)


## Forget everything said and everything loaded. For harnesses: the state above
## is static and would otherwise leak between sections of one run.
static func reset() -> void:
	stop()
	current_key = ""
	current_text = ""
	lines_shown = 0
	lines_voiced = 0
	lines_silent = 0
	lines_skipped = 0
	lines_dropped = 0
	history = PackedStringArray()
	on_line.clear()
	on_line_end.clear()
	_streams.clear()
	_warned.clear()
	enabled = true


# ------------------------------------------------------------------------------
# The line table: casting from the manifest, words from Story.gd
# ------------------------------------------------------------------------------

## Load the table once. A table that will not parse leaves the game with no
## narration and no crash, which is the correct failure for cosmetic content —
## but it is pushed as an error because, unlike a missing wav, it is a bug.
static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_lines = {}
	_beats = {}
	_story_beats = {}
	_default_beat = ""
	var text: String = ""
	if FileAccess.file_exists(MANIFEST_PATH):
		text = FileAccess.get_file_as_string(MANIFEST_PATH)
	if text.is_empty():
		push_error("Narration: no casting table at %s" % MANIFEST_PATH)
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Narration: %s is not a JSON object" % MANIFEST_PATH)
		return
	var data: Dictionary = parsed

	var beats: Variant = data.get("beats", {})
	if typeof(beats) == TYPE_DICTIONARY:
		_beats = beats
	_default_beat = String(data.get("default_beat", ""))
	if _default_beat.is_empty() and not _beats.is_empty():
		_default_beat = String(_beats.keys()[0])

	var story: Variant = data.get("story", {})
	if typeof(story) == TYPE_DICTIONARY:
		var sb: Variant = (story as Dictionary).get("beats", {})
		if typeof(sb) == TYPE_DICTIONARY:
			_story_beats = sb

	# Utility lines first, so a story beat colliding with one is reported
	# against the story table — which is the half that generates its keys and
	# therefore the half that is wrong.
	_index_manifest_lines(data)
	_index_story()


## The handful of lines whose text lives in the manifest because it has no other
## home: board and reward chatter, which is not story.
static func _index_manifest_lines(data: Dictionary) -> void:
	var raw: Variant = data.get("lines", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for key in (raw as Dictionary).keys():
		var line: Variant = (raw as Dictionary)[key]
		# A bare string is allowed: `"quest_paid": "..."` for a line that wants
		# nothing but the default beat.
		if typeof(line) == TYPE_STRING:
			_lines[String(key)] = {
				"text": String(line), "beat": _default_beat,
				"source": "manifest",
			}
			continue
		if typeof(line) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = line
		var beat: String = String(d.get("beat", _default_beat))
		_lines[String(key)] = {
			"text": String(d.get("text", "")),
			"beat": beat if _beats.has(beat) else _default_beat,
			"source": "manifest",
		}


## Walk every beat Story.gd advertises and give each of its lines a key.
##
## WALKED, NOT LISTED. Story.beats() is the authority on what beats exist, so a
## beat added there and not cast here is reported rather than silently going
## unvoiced — that is this project's signature bug (a feature wired to nothing)
## in its narration-shaped form, and it would otherwise be invisible: the game
## would show the subtitle, in silence, forever.
static func _index_story() -> void:
	for beat_v in StoryS.beats():
		var beat: String = String(beat_v)
		var spec: Variant = _story_beats.get(beat, null)
		if spec == null:
			push_error("Narration: Story advertises beat '%s', which %s does "
				% [beat, MANIFEST_PATH] + "not cast — it will never be voiced")
			continue
		var d: Dictionary = spec
		var cast: String = String(d.get("cast", _default_beat))
		if not _beats.has(cast):
			push_error("Narration: beat '%s' is cast as '%s', which is not a "
				% [beat, cast] + "declared speaking role")
			cast = _default_beat
		var pattern: String = String(d.get("key", ""))
		var mode: String = String(d.get("index", ""))
		match mode:
			"act_line":
				for act in range(StoryS.ACT_COUNT):
					var lines: PackedStringArray = StoryS.lines(beat, act)
					for i in range(lines.size()):
						_add_story_line(beat, cast,
							_format_key(beat, pattern, [act + 1, i + 1]),
							lines[i])
			"act":
				for act in range(StoryS.ACT_COUNT):
					var lines: PackedStringArray = StoryS.lines(beat, act)
					if lines.is_empty():
						continue
					_add_story_line(beat, cast,
						_format_key(beat, pattern, [act + 1]), lines[0])
			"map":
				# The only map-indexed beat is region_flavour, and most maps
				# have no line at all, so the index list comes from Story
				# rather than from counting to a hundred.
				for index in StoryS.flavour_indices():
					var lines: PackedStringArray = StoryS.lines(beat, 0, index)
					if lines.is_empty():
						continue
					_add_story_line(beat, cast,
						_format_key(beat, pattern, [index]), lines[0])
			"once":
				var lines: PackedStringArray = StoryS.lines(beat)
				if not lines.is_empty():
					_add_story_line(beat, cast, pattern, lines[0])
			_:
				push_error("Narration: beat '%s' has index mode '%s', which "
					% [beat, mode] + "is not one of act_line, act, map, once")


static func _add_story_line(beat: String, cast: String, key: String,
		text: String) -> void:
	if key.is_empty():
		return
	if _lines.has(key):
		# Two lines, one filename: whichever renders last wins the wav, and the
		# other is heard speaking the wrong words. Loud, because no amount of
		# listening would tell you which half is at fault.
		push_error("Narration: key '%s' from story beat '%s' collides with an "
			% [key, beat] + "existing line")
		return
	_lines[key] = {"text": text, "beat": cast, "source": "story:" + beat}


## printf the key pattern, and catch an arity mismatch here rather than letting
## a filename containing a literal "%" reach the filesystem — where it becomes
## a line that is simply always silent.
static func _format_key(beat: String, pattern: String, args: Array) -> String:
	if pattern.is_empty():
		push_error("Narration: story beat '%s' has no key pattern" % beat)
		return ""
	var key: String = pattern % args
	if key.contains("%"):
		push_error("Narration: key pattern '%s' for beat '%s' does not take "
			% [pattern, beat] + "%d argument(s)" % args.size())
		return ""
	return key


## Force a reload — the harness swaps directories between sections.
static func reload_table() -> void:
	_loaded = false
	_load()


static func keys() -> PackedStringArray:
	_load()
	var out := PackedStringArray()
	for k in _lines.keys():
		out.append(String(k))
	return out


static func has_line(key: String) -> bool:
	_load()
	return _lines.has(key)


## The words for a key, or "" if the table has never heard of it.
static func text_of(key: String) -> String:
	_load()
	var d: Variant = _lines.get(key, null)
	return "" if d == null else String((d as Dictionary).get("text", ""))


static func beat_of(key: String) -> String:
	_load()
	var d: Variant = _lines.get(key, null)
	return _default_beat if d == null \
		else String((d as Dictionary).get("beat", _default_beat))


## "story:<beat>" or "manifest". For a harness or an editor tool that wants to
## know which half of the table a line came from.
static func source_of(key: String) -> String:
	_load()
	var d: Variant = _lines.get(key, null)
	return "" if d == null else String((d as Dictionary).get("source", ""))


## Mix level for a beat, in dB. The reason a call site never sets a volume: the
## boss sitting louder than the herald is one number in the manifest.
static func gain_of_beat(beat: String) -> float:
	return float(_beat_field(beat, "gain_db", 0.0))


## The Kokoro voice id for a speaking role. Read by tools/gen_voice.py through
## render_table(); nothing in the game needs it.
static func voice_of_beat(beat: String) -> String:
	return String(_beat_field(beat, "voice", ""))


static func speed_of_beat(beat: String) -> float:
	return float(_beat_field(beat, "speed", 1.0))


static func _beat_field(beat: String, field: String, fallback: Variant) -> Variant:
	_load()
	var b: Variant = _beats.get(beat, null)
	return fallback if b == null else (b as Dictionary).get(field, fallback)


## Speaking roles the manifest declares.
static func speaking_roles() -> PackedStringArray:
	_load()
	var out := PackedStringArray()
	for k in _beats.keys():
		out.append(String(k))
	return out


## Story beats that the manifest fails to cast. Empty is the only acceptable
## answer; tools/voicetest.gd fails on anything else. See _index_story().
static func uncast_story_beats() -> PackedStringArray:
	_load()
	var out := PackedStringArray()
	for beat_v in StoryS.beats():
		if not _story_beats.has(String(beat_v)):
			out.append(String(beat_v))
	return out


# ------------------------------------------------------------------------------
# The render table — what tools/gen_voice.py renders
# ------------------------------------------------------------------------------

## Every line that should exist as a wav, with the voice that speaks it.
##
## THIS IS THE RENDERER'S ONLY INPUT, on purpose. gen_voice.py derives no
## filenames and holds no prose: it asks the game what to render and renders
## exactly that, so a wav cannot be written under a name this script will not
## look for. See the header.
static func render_table() -> Array:
	_load()
	var out: Array = []
	var ordered: Array = _lines.keys()
	ordered.sort()
	for key_v in ordered:
		var key: String = String(key_v)
		var beat: String = beat_of(key)
		out.append({
			"key": key,
			"text": text_of(key),
			"beat": beat,
			"voice": voice_of_beat(beat),
			"speed": speed_of_beat(beat),
			"gain_db": gain_of_beat(beat),
			"source": source_of(key),
		})
	return out


# ------------------------------------------------------------------------------
# Audio, loaded lazily and allowed to be absent
# ------------------------------------------------------------------------------

static func voice_dir() -> String:
	return _voice_dir


## Point at a different directory of wavs, clearing what was loaded from the
## last one. Exists for the harness, which must be able to prove the
## no-audio-at-all path without deleting the shipped lines.
static func set_voice_dir(dir: String) -> void:
	_voice_dir = dir
	_streams.clear()


static func path_of(key: String) -> String:
	return _voice_dir.path_join("%s.wav" % key)


## Is there audio for this line? Answers from the cache after the first look.
static func has_audio(key: String) -> bool:
	return stream_for(key) != null


## The wav for a line, or null. NEVER AN ERROR WHEN ABSENT — see the header.
##
## Read with AudioStreamWAV.load_from_file rather than load(): a wav that the
## editor has not imported yet has no .import sibling, and ResourceLoader
## refuses it — which would make every line silent in exactly the situation
## this pipeline exists for (wavs dropped in from a script, nobody has opened
## the editor). ResourceLoader is still tried second, because an EXPORTED build
## may ship the imported resource and not the raw file.
static func stream_for(key: String) -> AudioStreamWAV:
	if _streams.has(key):
		return _streams[key]
	var stream: AudioStreamWAV = null
	var path: String = path_of(key)
	if FileAccess.file_exists(path):
		stream = AudioStreamWAV.load_from_file(path)
	if stream == null and ResourceLoader.exists(path, "AudioStreamWAV"):
		var res: Resource = ResourceLoader.load(path, "AudioStreamWAV")
		if res is AudioStreamWAV:
			stream = res
	_streams[key] = stream
	return stream


# ------------------------------------------------------------------------------
# Saying things
# ------------------------------------------------------------------------------

## The wav names for a story beat, in the order they are spoken. The one
## implementation of the key scheme in the project.
##
## [param act] is 0-BASED, as Campaign.act_of() returns it. The filename is
## 1-based, because act_00_open_1 reads like a bug every time anyone opens the
## directory. Out-of-range acts clamp exactly as Story clamps them, so the key
## and the words can never come from different acts.
static func story_keys(beat: String, act: int = 0,
		index: int = -1) -> PackedStringArray:
	_load()
	var out := PackedStringArray()
	var spec: Variant = _story_beats.get(beat, null)
	if spec == null:
		return out
	var d: Dictionary = spec
	var pattern: String = String(d.get("key", ""))
	var act1: int = clampi(act, 0, StoryS.ACT_COUNT - 1) + 1
	match String(d.get("index", "")):
		"act_line":
			var n: int = StoryS.lines(beat, act).size()
			for i in range(n):
				var key: String = _format_key(beat, pattern, [act1, i + 1])
				if not key.is_empty():
					out.append(key)
		"act":
			var key: String = _format_key(beat, pattern, [act1])
			if not key.is_empty():
				out.append(key)
		"map":
			if index >= 0 and StoryS.has_region_flavour(index):
				var key: String = _format_key(beat, pattern, [index])
				if not key.is_empty():
					out.append(key)
		"once":
			out.append(pattern)
	return out


## Say a story beat: every line of it, in order, queued so they cannot overlap.
## Returns how many lines were queued — 0 is legitimate (a map with no flavour).
##
## THE CALL SITE SAYS WHAT HAPPENED, NOT WHAT IS SPOKEN. No words, no voice, no
## volume, no filename. That is what makes the narrator recastable and the prose
## editable without touching the game.
static func say_story(beat: String, act: int = 0, index: int = -1) -> int:
	var queued: int = 0
	for key in story_keys(beat, act, index):
		if say(key):
			queued += 1
	return queued


## Queue a line by key. Returns true if there is something to present.
##
## `text` overrides the table, for a line assembled at runtime — a boss taunt
## carrying a seeded champion's title, say. The table is still the default,
## because a call site that carries its own words is a call site gen_voice.py
## cannot render.
static func say(key: String, text: String = "") -> bool:
	var words: String = text if not text.is_empty() else text_of(key)
	if words.is_empty():
		# The ONE case where nothing is presented, and it is a programming
		# error rather than a missing asset: no text anywhere. Warned once per
		# key so a line said every frame cannot flood the log.
		if not _warned.has(key):
			_warned[key] = true
			push_warning("Narration: no text for line '%s'" % key)
		return false
	_queue.append({"key": key, "text": words, "beat": beat_of(key)})
	while _queue.size() > QUEUE_MAX:
		# Oldest pending, not newest: by the time a backlog has built up, the
		# line at the front of it is about something the player has walked past.
		var lost: Dictionary = _queue.pop_front()
		lines_dropped += 1
		_warn_dropped(String(lost.get("key", "")))
	_pump()
	return true


static func _warn_dropped(key: String) -> void:
	if key.is_empty() or _warned.has("drop:" + key):
		return
	_warned["drop:" + key] = true
	push_warning("Narration: queue full, dropped '%s'" % key)


## Is anything being said, or waiting to be?
static func is_speaking() -> bool:
	return _in_flight


static func pending() -> int:
	return _queue.size()


## End the current line now and move to the next. What a tap on the subtitle, or
## the skip button, does.
static func skip() -> void:
	if not _in_flight:
		_queue.clear()
		return
	lines_skipped += 1
	_end_current()
	# No breath after a skip: the player asked for the next thing, not for a
	# pause before it.
	_gap = 0.0
	_pump()


## Stop everything and forget what was waiting. For a scene change — the lines
## queued for the map you just left must not arrive on the next one.
static func stop() -> void:
	_queue.clear()
	if _in_flight:
		_end_current()
	else:
		_silence_player()
	_gap = 0.0
	_hold = 0.0


## THE CLOCK. Called by _process, and directly by harnesses so a queue can be
## driven without waiting on wall time. See the header for why the audio's
## `finished` signal is not in charge of this.
static func advance(delta: float) -> void:
	var d: float = maxf(delta, 0.0)
	if _in_flight:
		_hold -= d
		if _hold <= 0.0:
			_end_current()
		return
	if _gap > 0.0:
		_gap = maxf(_gap - d, 0.0)
		if _gap > 0.0:
			return
	_pump()


static func _pump() -> void:
	if _in_flight or _gap > 0.0 or _queue.is_empty():
		return
	var item: Dictionary = _queue.pop_front()
	var key: String = String(item.get("key", ""))
	var words: String = String(item.get("text", ""))

	# TEXT FIRST, UNCONDITIONALLY. Everything below this point can fail — no
	# wav, no node, audio muted — and the line is still on screen.
	current_key = key
	current_text = words
	lines_shown += 1
	history.append(key)
	if history.size() > HISTORY_MAX:
		history.remove_at(0)
	_in_flight = true

	var stream: AudioStreamWAV = stream_for(key) if enabled else null
	var length: float = 0.0
	if stream != null and _node != null and is_instance_valid(_node):
		length = _node._speak(stream, String(item.get("beat", "")))
	if length > 0.0:
		lines_voiced += 1
		# A wav shorter than its own subtitle still holds for the read.
		_hold = maxf(length, READ_FLOOR)
	else:
		lines_silent += 1
		_hold = _read_time(words)

	for cb in on_line:
		if cb.is_valid():
			cb.call(key, words)
	if _node != null and is_instance_valid(_node):
		_node.line_started.emit(key, words)


## Retire the line on screen. ALWAYS SILENCES THE PLAYER, which is not
## redundant with the stream having finished: a line whose hold expires first
## (a wav longer than its own subtitle, a dropped `finished` callback, a
## platform that keeps the voice alive) would otherwise go on speaking
## underneath the NEXT line's text — two voices, one subtitle, and the only
## clue is that the words on screen do not match what is being said.
static func _end_current() -> void:
	var key: String = current_key
	_silence_player()
	_in_flight = false
	_hold = 0.0
	_gap = GAP
	current_key = ""
	current_text = ""
	for cb in on_line_end:
		if cb.is_valid():
			cb.call(key)
	if _node != null and is_instance_valid(_node):
		_node.line_ended.emit(key)


## How long a line with no audio stays on screen.
static func _read_time(words: String) -> float:
	var count: int = words.split(" ", false).size()
	return clampf(float(count) / SILENT_WPS, READ_MIN, READ_MAX)


static func _silence_player() -> void:
	if _node != null and is_instance_valid(_node) and _node._player != null:
		_node._player.stop()


## Start a stream and return its length, or 0.0 if it could not be played.
## Returning the length is what keeps the timing honest: the queue is paced by
## the audio that actually started, not by what was requested.
func _speak(stream: AudioStreamWAV, beat: String) -> float:
	if _player == null or not _player.is_inside_tree():
		return 0.0                      # booted this frame; not in the tree yet
	_player.stream = stream
	_player.volume_db = Self.gain_of_beat(beat)
	_player.play()
	return stream.get_length()


## The audio ended before the hold did. Allowed to retire the line early; not
## allowed to be the only thing that can (the dummy driver never sends this).
func _on_stream_finished() -> void:
	if Self._in_flight:
		Self._end_current()
		Self._pump()
