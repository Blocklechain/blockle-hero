class_name Prefs
extends RefCounted

# Preloaded by path. A new class_name is absent from Godot's global class cache
# until the EDITOR reimports, so a bare `Audio` or `Narration` here would make
# this file — and every consumer of it — fail to parse in the headless
# harnesses. See tools/classcheck.gd for the four times that has happened.
const AudioS := preload("res://scripts/game/Audio.gd")
const NarrationS := preload("res://scripts/game/Narration.gd")
# ------------------------------------------------------------------------------
# THE PLAYER'S PREFERENCES, IN THEIR OWN FILE.
#
# user://prefs.json. NOT user://roster.json, and that separation is the whole
# reason this file exists rather than eight more fields on Roster:
#
#   * A CORRUPT PREF MUST NOT COST A CAMPAIGN. roster.json is forty levels,
#     a stash and every champion the player has opened. This file is nine
#     numbers that can be re-picked in ten seconds. Sharing one file means a
#     half-written byte in "master_volume" takes the campaign with it.
#   * ROSTER HAS EXACTLY ONE WRITER (UiShell._on_state_changed — see
#     Roster.gd and UiShell.gd). Volume changes fire sixty times a second
#     while a finger is on a slider. Routing those through the roster writer
#     would rewrite the save file sixty times a second, which is how a save
#     gets truncated by a suspend.
#
# So: a settings screen NEVER emits state_changed, and this file never touches
# SAVE_PATH. tools/prefstest.gd asserts the second half of that by hashing
# roster.json across a run of pref writes.
#
# ------------------------------------------------------------------------------
# EVERY KEY HAS A SPEC, AND THERE IS ONE CLAMP.
#
# SPEC carries the type, the default and the range, and `coerce()` is the only
# thing that turns an incoming value into a stored one. Both set_value() and
# the loader go through it, because the classic version of this bug is a
# setter that clamps and a loader that does not: the file then holds a volume
# of 40.0 that the UI can never produce and nothing ever corrects.
#
# ------------------------------------------------------------------------------
# WHAT IS ACTUALLY WIRED TODAY, which is not all of it.
#
# apply() reaches the three levers that already exist in the engine:
# the Master bus (master volume), Audio.enabled (sfx muted) and
# Narration.enabled (voice muted). Those have real, assertable effects.
#
# The remaining four — sfx/voice TRIM, subtitles, stick side, damage numbers,
# camera shake — have no consumer in this repo yet, so they are exposed as
# read helpers (sfx_gain_db, subtitles, stick_on_left, damage_numbers,
# shake_scale) for Audio.gd, Narration.gd, Hud.gd and Joystick.gd to ask. A
# preference nobody reads is this project's most common bug (five features
# shipped wired to nothing), so it is written down here rather than assumed:
# until those call sites ask, those controls store the player's choice and
# change nothing. Camera shake has no consumer at all — there is no screen
# shake in the game yet — and the key is here so that the accessibility
# option exists the day one is added, rather than a release later.
# ------------------------------------------------------------------------------

const PATH: String = "user://prefs.json"
const VERSION: int = 1

## Which side of the glass the movement stick is summoned on.
enum Hand { LEFT, RIGHT }

const K_MASTER: String = "master_volume"
const K_SFX: String = "sfx_volume"
const K_VOICE: String = "voice_volume"
const K_VOICE_ON: String = "voice_enabled"
const K_SUBTITLES: String = "subtitles"
const K_SHAKE: String = "camera_shake"
const K_HAND: String = "joystick_side"
const K_DAMAGE: String = "damage_numbers"

## kind / default / range. The single source for "what is a legal value".
##
## DEFAULTS LEAN ACCESSIBLE where there is a choice to make: subtitles start
## ON, because a line of dialogue the player cannot hear — muted phone, no
## headphones on a bus, deaf — is a line of dialogue that did not happen, and
## a player who needs them should not have to find a menu first. Master starts
## just under full so there is headroom to turn something UP.
const SPEC: Dictionary = {
	K_MASTER: {"kind": TYPE_FLOAT, "def": 0.85, "lo": 0.0, "hi": 1.0},
	K_SFX: {"kind": TYPE_FLOAT, "def": 1.0, "lo": 0.0, "hi": 1.0},
	K_VOICE: {"kind": TYPE_FLOAT, "def": 1.0, "lo": 0.0, "hi": 1.0},
	K_VOICE_ON: {"kind": TYPE_BOOL, "def": true},
	K_SUBTITLES: {"kind": TYPE_BOOL, "def": true},
	# Full shake is the authored look; 0 is a first-class value, not a
	# degenerate one. Motion sickness and vestibular disorders make a shaking
	# camera the difference between a game someone can play and one they
	# cannot, so "off" has to be reachable and has to mean off.
	K_SHAKE: {"kind": TYPE_FLOAT, "def": 1.0, "lo": 0.0, "hi": 1.0},
	K_HAND: {"kind": TYPE_INT, "def": Hand.LEFT, "lo": 0, "hi": 1},
	K_DAMAGE: {"kind": TYPE_BOOL, "def": true},
}

## Silence, in dB. linear_to_db(0.0) is -inf, which AudioServer will take and
## then hand back as -inf forever — a bus that can never be un-muted by
## arithmetic. A floor well below audible is the same thing to an ear and
## still a number.
const MUTE_DB: float = -72.0

static var _values: Dictionary = {}
static var _loaded: bool = false
## Whether the file on disk parsed cleanly last time it was read. False after a
## corrupt or absent file, which is how a caller can tell "the player chose
## the defaults" from "we fell back to them".
static var _clean: bool = true
## Set by set_value(..., write=false) — a value held in memory and applied, but
## not yet on disk. See flush().
static var _dirty: bool = false


# ------------------------------------------------------------------------------
# Reading
# ------------------------------------------------------------------------------

static func keys() -> PackedStringArray:
	var out := PackedStringArray()
	for k in SPEC.keys():
		out.append(String(k))
	return out


static func defaults() -> Dictionary:
	var out: Dictionary = {}
	for k in SPEC.keys():
		out[k] = (SPEC[k] as Dictionary)["def"]
	return out


## Read-through: the first ask loads the file.
##
## Lazily rather than from a boot() call, because the consumers are Hud,
## Joystick and Audio — things built deep inside a run, by code that has no
## idea whether the menu shell ever ran. A pref that only works if someone
## remembered to initialise it is a pref that is wrong on the first launch
## after a crash.
static func _ensure() -> void:
	if not _loaded:
		load_prefs()


static func get_value(key: String) -> Variant:
	_ensure()
	if not SPEC.has(key):
		return null
	return _values.get(key, (SPEC[key] as Dictionary)["def"])


static func num(key: String) -> float:
	var v: Variant = get_value(key)
	return float(v) if v != null else 0.0


static func flag(key: String) -> bool:
	var v: Variant = get_value(key)
	return bool(v) if v != null else false


static func choice(key: String) -> int:
	var v: Variant = get_value(key)
	return int(v) if v != null else 0


## A copy. Callers must not be handed the live dictionary: a screen that
## mutated it directly would skip coerce() and skip the save.
static func values() -> Dictionary:
	_ensure()
	return _values.duplicate(true)


static func load_was_clean() -> bool:
	_ensure()
	return _clean


# ------------------------------------------------------------------------------
# Writing
# ------------------------------------------------------------------------------

## Store `value` under `key`, clamped, applied, and (by default) written.
##
## Returns the value ACTUALLY STORED, so a caller that handed over 4.0 can put
## 1.0 back on its slider instead of displaying a number the store rejected.
##
## `write` false holds the file write back — for a slider being dragged, where
## the value must be live (you hear the volume you are setting) but sixty file
## writes a second are not. The drag's end calls flush(). The value itself is
## never deferred; only the bytes are.
static func set_value(key: String, value: Variant, write: bool = true) -> Variant:
	_ensure()
	if not SPEC.has(key):
		return null
	var stored: Variant = coerce(key, value)
	if _values.get(key) == stored and not _dirty:
		# Nothing changed. Still applied below is pointless; return early so a
		# slider resting on a value does not rewrite the file every frame.
		return stored
	_values[key] = stored
	apply()
	if write:
		save()
	else:
		_dirty = true
	return stored


## Write the deferred value, if there is one. Cheap and safe to call always.
static func flush() -> bool:
	if not _dirty:
		return true
	return save()


static func reset(write: bool = true) -> void:
	_values = defaults()
	_loaded = true
	_clean = true
	_dirty = false
	apply()
	if write:
		save()


# ------------------------------------------------------------------------------
# The one clamp
# ------------------------------------------------------------------------------

## Turn anything at all into a legal value for `key`.
##
## A value of the wrong TYPE is treated as corruption and replaced by the
## default rather than converted: "0.5" arriving as a string means something
## else wrote this file, and guessing at it is how a nonsense value becomes
## sticky. A value of the right type that is out of RANGE is clamped, because
## that one is just an old build or a hand edit.
static func coerce(key: String, value: Variant) -> Variant:
	if not SPEC.has(key):
		return null
	var spec: Dictionary = SPEC[key]
	var kind: int = int(spec["kind"])
	var def: Variant = spec["def"]
	var t: int = typeof(value)
	var numeric: bool = t == TYPE_INT or t == TYPE_FLOAT
	match kind:
		TYPE_BOOL:
			if t == TYPE_BOOL:
				return value
			# JSON has no bool/int distinction in every writer, and 0/1 is
			# unambiguous. Anything else is corruption.
			if numeric:
				return float(value) != 0.0
			return def
		TYPE_FLOAT:
			if not numeric:
				return def
			var f: float = float(value)
			# NaN compares false against everything, so it survives a clamp.
			# It then poisons every volume computed from it.
			if is_nan(f):
				return def
			return clampf(f, float(spec["lo"]), float(spec["hi"]))
		TYPE_INT:
			if not numeric:
				return def
			var g: float = float(value)
			if is_nan(g):
				return def
			return clampi(int(round(g)), int(spec["lo"]), int(spec["hi"]))
	return def


# ------------------------------------------------------------------------------
# The file
# ------------------------------------------------------------------------------

## Read user://prefs.json. Returns true if it parsed cleanly.
##
## NEVER THROWS, AND NEVER LEAVES THE STORE EMPTY. Absent file, unreadable
## file, truncated JSON, a JSON array where a dictionary was expected, a value
## of the wrong type — every one of them ends with a full set of defaults in
## memory. The failure mode this prevents is a game that will not start
## because a settings file is three bytes short.
static func load_prefs() -> bool:
	_values = defaults()
	_loaded = true
	_clean = false
	_dirty = false

	if not FileAccess.file_exists(PATH):
		# Not an error and not worth a log line: this is every first launch.
		_clean = true
		apply()
		return true

	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_warning("Prefs: cannot read %s — using defaults" % PATH)
		apply()
		return false
	var text: String = f.get_as_text()
	f.close()

	# JSON.new().parse rather than the static JSON.parse_string: the static
	# one PUSHES AN ENGINE ERROR on malformed input. A corrupt preferences
	# file is a handled condition — the defaults are right there — so it must
	# not print the same red "Parse JSON failed" that a real fault does, every
	# launch, in a log someone is reading to find a real fault.
	var reader := JSON.new()
	var err: int = reader.parse(text)
	if err != OK or typeof(reader.data) != TYPE_DICTIONARY:
		push_warning("Prefs: %s is unreadable (%s) — using defaults"
			% [PATH, reader.get_error_message()])
		apply()
		return false

	var data: Dictionary = reader.data
	for key in SPEC.keys():
		if data.has(key):
			# Through coerce, so an out-of-range value on disk is corrected on
			# the way in rather than handed to the game.
			_values[key] = coerce(String(key), data[key])
	# UNKNOWN KEYS ARE IGNORED, not copied through. A key from a newer build,
	# or junk, must not survive into the next save — writing back something we
	# do not understand means it can never be removed.
	_clean = true
	apply()
	return true


static func save() -> bool:
	_ensure()
	var out: Dictionary = {"version": VERSION}
	for key in SPEC.keys():
		out[key] = _values.get(key, (SPEC[key] as Dictionary)["def"])
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		# A pref that cannot be written is a pref that will be re-picked next
		# launch. It is not worth an error dialog and it is certainly not
		# worth failing the thing the player was doing.
		push_warning("Prefs: cannot write %s" % PATH)
		return false
	f.store_string(JSON.stringify(out, "\t", true))
	f.close()
	_dirty = false
	return true


# ------------------------------------------------------------------------------
# Making the values mean something
# ------------------------------------------------------------------------------

## Push the preferences onto the engine state that can take them NOW.
##
## Idempotent, and safe to call before anything has booted: AudioServer always
## exists, and Audio/Narration's flags are static, so neither needs its node in
## the tree. Called from set_value and from load, so there is no path that
## stores a value without applying it.
static func apply() -> void:
	var master: int = AudioServer.get_bus_index("Master")
	if master >= 0:
		var v: float = float(_values.get(K_MASTER,
			(SPEC[K_MASTER] as Dictionary)["def"]))
		AudioServer.set_bus_volume_db(master, MUTE_DB if v <= 0.0
			else linear_to_db(v))
		# Muted as well as turned down. A bus at -72 dB is still mixing every
		# voice in the game; mute stops the work as well as the sound, which
		# on a phone is battery.
		AudioServer.set_bus_mute(master, v <= 0.0)

	# SFX at zero is a mute, not a trim: Audio.play() checks `enabled` before
	# it synthesises or claims a voice, so this is the only lever that makes
	# silence actually free. The gradation in between needs a call site in
	# Audio.gd to ask sfx_gain_db() — see the header.
	AudioS.enabled = float(_values.get(K_SFX, 1.0)) > 0.0

	# VOICE OFF STILL SHOWS THE WORDS. Narration._pump sets the subtitle
	# before it ever looks at `enabled` (text first, unconditionally — see
	# Narration.gd), so this silences the speech without silencing the story.
	# That is exactly the behaviour the "voice" toggle should have and it is
	# why the toggle is wired here rather than to a bus.
	NarrationS.enabled = flag_or_default(K_VOICE_ON) \
		and float(_values.get(K_VOICE, 1.0)) > 0.0


## Like flag(), but without the read-through — apply() is called FROM the
## loader, and re-entering it there would recurse.
static func flag_or_default(key: String) -> bool:
	return bool(_values.get(key, (SPEC[key] as Dictionary)["def"]))


# ------------------------------------------------------------------------------
# What consumers ask
# ------------------------------------------------------------------------------

## Trim for every synthesised combat cue, in dB, to be ADDED to the cue's own
## authored gain. 0 dB at full, so an unpatched call site and a default
## preference sound identical.
static func sfx_gain_db() -> float:
	var v: float = num(K_SFX)
	return MUTE_DB if v <= 0.0 else linear_to_db(v)


## Trim for spoken lines, in dB, added to the beat's authored gain.
static func voice_gain_db() -> float:
	if not flag(K_VOICE_ON):
		return MUTE_DB
	var v: float = num(K_VOICE)
	return MUTE_DB if v <= 0.0 else linear_to_db(v)


## Multiplier for any camera shake. 0 means none at all, and a consumer must
## treat it as a hard off rather than as "very little" — a tiny shake is still
## a moving horizon.
static func shake_scale() -> float:
	return num(K_SHAKE)


static func subtitles() -> bool:
	return flag(K_SUBTITLES)


static func damage_numbers() -> bool:
	return flag(K_DAMAGE)


## Which side Joystick's summoning zone belongs on.
static func stick_on_left() -> bool:
	return choice(K_HAND) == Hand.LEFT


static func hand_name(hand: int) -> String:
	return "Right" if hand == Hand.RIGHT else "Left"
