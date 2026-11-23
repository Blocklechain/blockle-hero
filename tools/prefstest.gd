extends SceneTree
# ------------------------------------------------------------------------------
# PREFERENCES, AND THE ONE THING THEY MUST NEVER DO.
#
# Prefs is nine numbers in a file, so most of what could go wrong here is
# cheap: a bad volume costs a volume. Exactly one failure in this file is
# expensive, and it is the reason the store is separate from the roster at all:
#
#   A PREFERENCE WRITE MUST NOT TOUCH user://roster.json.
#
# That file is every champion, every level and every item the player owns.
# Section "the roster is untouched" hashes it, drives a long run of pref
# writes — including a whole settings screen being used — and hashes it again.
# It also checks the modification time, because a rewrite with identical bytes
# is still a rewrite, and a rewrite is still a chance to be interrupted.
#
# The rest of the file is about the OTHER classic: a settings screen whose
# controls are connected to nothing. So the screen is mounted for real and
# driven through its own buttons, and the assertions are on what changed —
# the stored value, the Master bus's volume, Audio.enabled — never on whether
# a handler ran. Five features in this project shipped wired to nothing and
# every one of them had a signal that fired perfectly.
#
# Run:
#   /opt/homebrew/bin/godot --headless --path . --script tools/prefstest.gd
# ------------------------------------------------------------------------------

const PrefsS := preload("res://scripts/game/Prefs.gd")
const SettingsScreenS := preload("res://scripts/ui/SettingsScreen.gd")
const RosterS := preload("res://scripts/game/Roster.gd")
const AudioS := preload("res://scripts/game/Audio.gd")
const NarrationS := preload("res://scripts/game/Narration.gd")

const SECTIONS: int = 11

var _fails: int = 0
var _done: int = 0

## The developer's real prefs.json, put back at the end. This harness writes
## corrupt files on purpose and it is not allowed to cost anyone their
## settings.
var _saved_prefs: String = ""
var _had_prefs: bool = false


func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	_had_prefs = FileAccess.file_exists(PrefsS.PATH)
	if _had_prefs:
		var f := FileAccess.open(PrefsS.PATH, FileAccess.READ)
		if f != null:
			_saved_prefs = f.get_as_text()
			f.close()

	# Snapshot the roster BEFORE anything runs, so every pref write in this
	# file is inside the window the invariant covers.
	var roster_before: Dictionary = _roster_snapshot()

	_defaults(); _done += 1
	_round_trip(); _done += 1
	_clamping(); _done += 1
	_corrupt(); _done += 1
	_unknown_keys(); _done += 1
	_real_audio(); _done += 1
	await _real_voice(); _done += 1
	await _the_screen(); _done += 1
	await _dragging(); _done += 1
	_only_prefs_changed(); _done += 1
	_roster_untouched(roster_before); _done += 1

	_restore_prefs()

	print("")
	# A runtime error aborts the function it is in and GDScript carries on, so
	# a crash halfway through reads as zero failures. This is the line that
	# makes that impossible.
	check("every section ran to completion", _done == SECTIONS,
		"%d of %d" % [_done, SECTIONS])
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------

func _defaults() -> void:
	print("\n=== defaults ===")
	_wipe()
	PrefsS.load_prefs()

	var d: Dictionary = PrefsS.defaults()
	check("every key in the spec has a default",
		d.size() == PrefsS.SPEC.size(), "%d keys" % d.size())

	var in_range: bool = true
	for key in PrefsS.SPEC.keys():
		var spec: Dictionary = PrefsS.SPEC[key]
		if int(spec["kind"]) == TYPE_BOOL:
			continue
		var v: float = float(spec["def"])
		if v < float(spec["lo"]) or v > float(spec["hi"]):
			in_range = false
	check("...and every default is inside its own range", in_range)

	# The two that matter. A default of "subtitles off" means a deaf player
	# has to find this screen before the game will talk to them.
	check("subtitles start on", PrefsS.subtitles())
	check("voices start on", PrefsS.flag(PrefsS.K_VOICE_ON))
	check("damage numbers start on", PrefsS.damage_numbers())
	check("the stick starts on the left", PrefsS.stick_on_left())

	var master: float = PrefsS.num(PrefsS.K_MASTER)
	check("master volume starts audible and not maxed",
		master > 0.3 and master <= 1.0, "%.2f" % master)
	check("shake starts at the authored amount",
		is_equal_approx(PrefsS.shake_scale(), 1.0))

	# At full volume the trims are 0 dB, so a call site that has not been
	# patched to ask yet sounds EXACTLY like one that has. Without this the
	# default install would get quieter the day the trim is wired up.
	check("full volume is a 0 dB trim",
		is_equal_approx(PrefsS.sfx_gain_db(), 0.0)
		and is_equal_approx(PrefsS.voice_gain_db(), 0.0))

	check("an absent file still counts as a clean load",
		PrefsS.load_was_clean())


# ------------------------------------------------------------------------------
# Round trip
# ------------------------------------------------------------------------------

func _round_trip() -> void:
	print("\n=== a value survives save and load ===")
	_wipe()
	PrefsS.load_prefs()

	PrefsS.set_value(PrefsS.K_MASTER, 0.3)
	PrefsS.set_value(PrefsS.K_SUBTITLES, false)
	PrefsS.set_value(PrefsS.K_HAND, PrefsS.Hand.RIGHT)
	PrefsS.set_value(PrefsS.K_SHAKE, 0.0)
	check("the file exists after a write",
		FileAccess.file_exists(PrefsS.PATH))

	# FORGET EVERYTHING IN MEMORY FIRST. Reading back the static dictionary
	# that was just written to proves nothing about the file — the first
	# version of this test did exactly that and would have passed with save()
	# commented out.
	PrefsS.load_prefs()

	check("a float round-trips",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.3),
		"%.3f" % PrefsS.num(PrefsS.K_MASTER))
	check("a bool round-trips", PrefsS.subtitles() == false)
	check("an enum round-trips", not PrefsS.stick_on_left())
	check("zero round-trips as zero, not as missing",
		is_equal_approx(PrefsS.shake_scale(), 0.0))
	check("a key nobody set keeps its default",
		is_equal_approx(PrefsS.num(PrefsS.K_SFX), 1.0))

	# The deferred write is what a slider drag uses. If flush() ever stops
	# working, every drag in the game silently stops persisting.
	PrefsS.set_value(PrefsS.K_SFX, 0.2, false)
	PrefsS.flush()
	PrefsS.load_prefs()
	check("a deferred write lands on flush",
		is_equal_approx(PrefsS.num(PrefsS.K_SFX), 0.2),
		"%.3f" % PrefsS.num(PrefsS.K_SFX))


# ------------------------------------------------------------------------------
# Clamping
# ------------------------------------------------------------------------------

func _clamping() -> void:
	print("\n=== out of range is clamped, not accepted ===")
	_wipe()
	PrefsS.load_prefs()

	check("a volume above the top clamps to the top",
		is_equal_approx(float(PrefsS.set_value(PrefsS.K_MASTER, 4.0)), 1.0),
		"%.2f" % PrefsS.num(PrefsS.K_MASTER))
	check("a negative volume clamps to zero",
		is_equal_approx(float(PrefsS.set_value(PrefsS.K_SHAKE, -3.0)), 0.0))
	check("an out-of-range enum clamps into the enum",
		int(PrefsS.set_value(PrefsS.K_HAND, 77)) == PrefsS.Hand.RIGHT,
		"%d" % PrefsS.choice(PrefsS.K_HAND))

	# set_value returns what it STORED, so a screen can put the corrected
	# value back on its control instead of showing a number the store refused.
	check("set_value reports the stored value, not the asked one",
		is_equal_approx(float(PrefsS.set_value(PrefsS.K_SFX, 9.9)), 1.0))

	# A wrong type is corruption rather than a unit mistake, so it goes to the
	# default instead of being guessed at.
	check("a string where a float belongs falls back to the default",
		is_equal_approx(float(PrefsS.coerce(PrefsS.K_MASTER, "loud")), 0.85))
	check("a string where a bool belongs falls back to the default",
		bool(PrefsS.coerce(PrefsS.K_SUBTITLES, "yes")) == true)
	check("NaN never reaches the store",
		is_equal_approx(float(PrefsS.coerce(PrefsS.K_MASTER, NAN)), 0.85))
	check("an unknown key cannot be set",
		PrefsS.set_value("fly_mode", true) == null
		and not PrefsS.values().has("fly_mode"))

	# ON THE WAY IN, TOO. A setter that clamps and a loader that does not
	# leaves an illegal value in the file that nothing ever corrects — the
	# store would hand the game a volume of 40.0 for ever.
	_write_raw('{"version":1,"master_volume":9.0,"camera_shake":-2.0,'
		+ '"joystick_side":77}')
	PrefsS.load_prefs()
	check("a file holding out-of-range values is clamped on load",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 1.0)
		and is_equal_approx(PrefsS.shake_scale(), 0.0)
		and PrefsS.choice(PrefsS.K_HAND) == PrefsS.Hand.RIGHT)

	_write_raw('{"version":1,"master_volume":"loud","damage_numbers":"nope"}')
	PrefsS.load_prefs()
	check("a file holding wrong types falls back per key",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.85)
		and PrefsS.damage_numbers())


# ------------------------------------------------------------------------------
# Corruption
# ------------------------------------------------------------------------------

func _corrupt() -> void:
	print("\n=== a corrupt file loads defaults and does not throw ===")

	# Each of these is a real way the file ends up broken: a suspend during a
	# write, a truncated copy, a sync tool replacing the contents.
	var broken: Array = [
		"",
		"{",
		'{"master_volume": }',
		"not json at all",
		'["master_volume", 0.5]',          # valid JSON, wrong shape
		"   ",                             # whitespace only
	]
	for i in range(broken.size()):
		_write_raw(String(broken[i]))
		var clean: bool = PrefsS.load_prefs()
		var defaulted: bool = is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.85) \
			and PrefsS.subtitles() and PrefsS.stick_on_left()
		check("corrupt file %d loads full defaults" % i, defaulted)
		check("...and reports itself as not clean" , not clean)

	# And the game must still be playable afterwards: the store is usable, and
	# a write over the corruption fixes it rather than failing on it.
	PrefsS.set_value(PrefsS.K_MASTER, 0.5)
	PrefsS.load_prefs()
	check("writing over a corrupt file repairs it",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.5)
		and PrefsS.load_was_clean())

	_wipe()
	var clean_absent: bool = PrefsS.load_prefs()
	check("an absent file is not treated as corruption", clean_absent)
	check("...and the defaults are in place",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.85))


# ------------------------------------------------------------------------------
# Unknown keys
# ------------------------------------------------------------------------------

func _unknown_keys() -> void:
	print("\n=== unknown keys are ignored ===")
	_write_raw('{"version":1,"master_volume":0.4,"nonsense":"x",'
		+ '"camera_shake":0.25}')
	PrefsS.load_prefs()
	check("the known keys are read",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.4)
		and is_equal_approx(PrefsS.shake_scale(), 0.25))
	check("the unknown key is not in the store",
		not PrefsS.values().has("nonsense"))

	# NOT COPIED THROUGH EITHER. A key we do not understand that survives the
	# next save can never be removed, and two builds disagreeing about it is
	# how a settings file grows junk for ever.
	PrefsS.save()
	var text: String = _read_raw()
	check("...and it is not written back", text.find("nonsense") < 0)
	check("the version is stamped", text.find("version") >= 0)


# ------------------------------------------------------------------------------
# Effects: the Master bus and the sfx gate
# ------------------------------------------------------------------------------

func _real_audio() -> void:
	print("\n=== the volume actually moves something ===")
	_wipe()
	PrefsS.load_prefs()

	var bus: int = AudioServer.get_bus_index("Master")
	check("there is a Master bus to drive", bus >= 0, "index %d" % bus)
	if bus < 0:
		return

	PrefsS.set_value(PrefsS.K_MASTER, 0.5)
	check("a master volume reaches the bus",
		is_equal_approx(AudioServer.get_bus_volume_db(bus),
			linear_to_db(0.5)),
		"%.2f dB" % AudioServer.get_bus_volume_db(bus))
	check("...and the bus is not muted", not AudioServer.is_bus_mute(bus))

	PrefsS.set_value(PrefsS.K_MASTER, 0.0)
	check("zero mutes the bus rather than nearly muting it",
		AudioServer.is_bus_mute(bus)
		and AudioServer.get_bus_volume_db(bus) <= PrefsS.MUTE_DB + 0.01)

	PrefsS.set_value(PrefsS.K_MASTER, 0.85)
	check("turning it back up unmutes", not AudioServer.is_bus_mute(bus))

	# THE SFX GATE. Audio.play() checks `enabled` before it synthesises or
	# claims a voice, so this is the only lever that makes silence free.
	AudioS.boot(root)
	PrefsS.set_value(PrefsS.K_SFX, 0.0)
	check("sfx at zero closes Audio's gate", not AudioS.enabled)
	var before: int = AudioS.cues_played
	AudioS.hit(false)
	check("...and a cue asked for while muted never plays",
		AudioS.cues_played == before, "%d cues" % AudioS.cues_played)

	PrefsS.set_value(PrefsS.K_SFX, 1.0)
	check("turning sfx back up reopens the gate", AudioS.enabled)
	AudioS.hit(false)
	check("...and the same cue now plays",
		AudioS.cues_played == before + 1, "%d cues" % AudioS.cues_played)


# ------------------------------------------------------------------------------
# Effects: voices off must not take the words with them
# ------------------------------------------------------------------------------

func _real_voice() -> void:
	print("\n=== voices off, words still there ===")
	_wipe()
	PrefsS.load_prefs()

	NarrationS.boot(root)
	await process_frame
	await process_frame

	var keys: PackedStringArray = NarrationS.keys()
	check("there are lines to say", keys.size() > 0, "%d lines" % keys.size())
	if keys.size() == 0:
		return
	var key: String = keys[0]

	# Voices ON first, to find out whether this environment can voice anything
	# at all — headless uses a dummy audio driver. The contrast below is only
	# meaningful if the baseline voiced something, so it is measured rather
	# than assumed.
	NarrationS.reset()
	PrefsS.set_value(PrefsS.K_VOICE_ON, true)
	PrefsS.apply()                      # reset() turns `enabled` back on
	NarrationS.say(key)
	NarrationS.advance(0.01)
	var voiced_on: int = NarrationS.lines_voiced

	NarrationS.reset()
	PrefsS.set_value(PrefsS.K_VOICE_ON, false)
	PrefsS.apply()
	var heard: PackedStringArray = PackedStringArray()
	# The subtitle sink the HUD uses. Asserting through it rather than on the
	# flag is the point: the words have to arrive somewhere.
	NarrationS.on_line.append(func(_k: String, text: String) -> void:
		heard.append(text))
	NarrationS.say(key)
	NarrationS.advance(0.01)

	check("the line is still presented with voices off",
		NarrationS.lines_shown == 1, "%d shown" % NarrationS.lines_shown)
	check("...and its words reach a subtitle sink",
		heard.size() == 1 and not heard[0].is_empty(),
		heard[0] if heard.size() > 0 else "nothing")
	check("...and nothing was spoken",
		NarrationS.lines_voiced == 0,
		"baseline voiced %d" % voiced_on
		+ ("" if voiced_on > 0 else " — no audio in this environment"))

	NarrationS.on_line.clear()
	NarrationS.reset()
	PrefsS.reset()


# ------------------------------------------------------------------------------
# The screen
# ------------------------------------------------------------------------------

## Drive the real SettingsScreen through its own buttons.
##
## The assertions are all on the STORE, not on the screen: a control that
## emits a signal into a listener nobody connected is this project's most
## common bug, and the only way to tell the difference is to ask whether the
## value changed.
func _the_screen() -> void:
	print("\n=== the screen writes through ===")
	_wipe()
	PrefsS.load_prefs()

	var screen: UiScreen = SettingsScreenS.new()
	# state_changed is the shell's trigger for writing user://roster.json. A
	# settings screen that emits it rewrites the campaign save on every
	# control, so the invariant is that it NEVER fires here.
	var roster_writes: Array[int] = [0]
	screen.state_changed.connect(func() -> void:
		roster_writes[0] += 1)
	var toasts: Array[String] = []
	screen.notified.connect(func(text: String) -> void: toasts.append(text))
	root.add_child(screen)
	await process_frame

	check("the screen is titled", screen.screen_title() == "Settings")

	# --- the shake off switch, which is the accessibility one ---------------
	PrefsS.set_value(PrefsS.K_SHAKE, 1.0)
	var shake_off: Button = _find(screen, "Pick_camera_shake_0")
	check("there is a one-tap shake off", shake_off != null,
		shake_off.text if shake_off != null else "missing")
	if shake_off != null:
		shake_off.pressed.emit()
		check("...and it puts shake at exactly zero",
			is_equal_approx(PrefsS.shake_scale(), 0.0),
			"%.3f" % PrefsS.shake_scale())
		var full: Button = _find(screen, "Pick_camera_shake_2")
		if full != null:
			full.pressed.emit()
			check("...and full puts it back to 1",
				is_equal_approx(PrefsS.shake_scale(), 1.0))

	# --- subtitles ----------------------------------------------------------
	var subs_off: Button = _find(screen, "Pick_subtitles_1")
	if subs_off != null:
		subs_off.pressed.emit()
		check("subtitles can be turned off", not PrefsS.subtitles())
		var subs_on: Button = _find(screen, "Pick_subtitles_0")
		subs_on.pressed.emit()
		check("...and back on", PrefsS.subtitles())
	else:
		check("the subtitle control exists", false, "missing")

	# --- the step buttons, and the bus behind them -------------------------
	PrefsS.set_value(PrefsS.K_MASTER, 0.5)
	var down: Button = _find(screen, "Down_master_volume")
	var up: Button = _find(screen, "Up_master_volume")
	check("the volume has step buttons", down != null and up != null)
	if down != null and up != null:
		down.pressed.emit()
		check("a step down lowers the stored volume",
			is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.4),
			"%.3f" % PrefsS.num(PrefsS.K_MASTER))
		var bus: int = AudioServer.get_bus_index("Master")
		check("...and the bus went with it",
			bus < 0 or is_equal_approx(AudioServer.get_bus_volume_db(bus),
				linear_to_db(0.4)))
		up.pressed.emit()
		check("a step up raises it again",
			is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.5))
		# The bottom and the top are reachable and nothing runs past them.
		for _i in range(20):
			down.pressed.emit()
		check("stepping down repeatedly stops at zero",
			is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.0))
		for _i in range(30):
			up.pressed.emit()
		check("stepping up repeatedly stops at full",
			is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 1.0))

	# --- the stick side -----------------------------------------------------
	var right: Button = _find(screen, "Pick_joystick_side_1")
	if right != null:
		right.pressed.emit()
		check("the stick can be moved to the right hand",
			not PrefsS.stick_on_left())
	else:
		check("the stick-side control exists", false, "missing")

	# --- damage numbers -----------------------------------------------------
	var dmg_off: Button = _find(screen, "Pick_damage_numbers_1")
	if dmg_off != null:
		dmg_off.pressed.emit()
		check("damage numbers can be turned off", not PrefsS.damage_numbers())
	else:
		check("the damage-number control exists", false, "missing")

	# --- it all persisted ---------------------------------------------------
	PrefsS.flush()
	PrefsS.load_prefs()
	check("everything the screen set is on disk",
		not PrefsS.stick_on_left() and not PrefsS.damage_numbers()
		and is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 1.0))

	# --- reset --------------------------------------------------------------
	var reset: Button = _find_by_text(screen, "default")
	check("there is a reset", reset != null)
	if reset != null:
		reset.pressed.emit()
		check("reset restores every default",
			PrefsS.stick_on_left() and PrefsS.damage_numbers()
			and PrefsS.subtitles()
			and is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.85))
		check("...and says so", toasts.size() == 1,
			toasts[0] if toasts.size() > 0 else "silent")
		PrefsS.load_prefs()
		check("...and the defaults are written, not just held",
			is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.85))

	check("the screen never asked for a roster save",
		roster_writes[0] == 0, "%d state_changed" % roster_writes[0])

	# The readouts have to say something, because a bar with no number beside
	# it is the one control a player cannot report a problem with.
	var readout_ok: bool = false
	for l in _labels(screen):
		if (l as Label).text == "85%":
			readout_ok = true
	check("the readout shows the stored percentage", readout_ok)

	root.remove_child(screen)
	screen.queue_free()
	await process_frame


# ------------------------------------------------------------------------------
# The drag
# ------------------------------------------------------------------------------

## A finger on the bar, and the one way that write goes missing.
##
## The bar defers its file write until the finger lifts, and the release is NOT
## guaranteed to arrive: TouchScroll watches raw touches in _input, ahead of
## GUI dispatch, and once a drag has wandered 24 px vertically it swallows the
## gesture — so the bar can stop hearing a drag it started. Section asserts
## both halves: a normal drag writes on release, and a hijacked one writes
## when the screen goes away. Without the second, a volume set by dragging
## would be right until the next launch and then quietly wrong.
func _dragging() -> void:
	print("\n=== a drag on the bar ===")
	_wipe()
	PrefsS.load_prefs()
	PrefsS.set_value(PrefsS.K_MASTER, 1.0)

	var screen: UiScreen = SettingsScreenS.new()
	root.add_child(screen)
	await process_frame

	var bar: Control = _bar_for(screen, PrefsS.K_MASTER)
	check("the volume has a bar", bar != null)
	if bar == null:
		root.remove_child(screen)
		screen.queue_free()
		return
	# Given a size by hand: a container has not laid it out yet and a bar with
	# no width cannot resolve a position into a value.
	bar.size = Vector2(1000, 112)

	# Press at three tenths across. Fed as a real event to the real handler,
	# because that is the code a finger reaches.
	bar._gui_input(_click(Vector2(300, 56), true))
	check("a press on the bar sets the value under it",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.3),
		"%.3f" % PrefsS.num(PrefsS.K_MASTER))

	# DRAGGED, NOT YET RELEASED: live in memory, deliberately not on disk.
	bar._gui_input(_motion(Vector2(700, 56)))
	check("dragging moves it further",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.7),
		"%.3f" % PrefsS.num(PrefsS.K_MASTER))
	check("...and the drag has not been written yet",
		_read_raw().find("0.7") < 0)

	bar._gui_input(_click(Vector2(700, 56), false))
	PrefsS.load_prefs()
	check("the release writes it",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.7),
		"%.3f" % PrefsS.num(PrefsS.K_MASTER))

	# THE HIJACKED DRAG: a press and a drag, and the release never arrives
	# because TouchScroll took the gesture.
	bar._gui_input(_click(Vector2(200, 56), true))
	bar._gui_input(_motion(Vector2(100, 56)))
	check("a drag with no release is live in memory",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.1),
		"%.3f" % PrefsS.num(PrefsS.K_MASTER))

	root.remove_child(screen)
	screen.queue_free()
	await process_frame

	PrefsS.load_prefs()
	check("leaving the screen writes what the drag left behind",
		is_equal_approx(PrefsS.num(PrefsS.K_MASTER), 0.1),
		"%.3f" % PrefsS.num(PrefsS.K_MASTER))


func _click(at: Vector2, down: bool) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = down
	e.position = at
	return e


func _motion(at: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.position = at
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	return e


## The bar belonging to `key`. Found by walking for the control type rather
## than by reaching into the screen's dictionary, so the test breaks if the
## bar stops being on screen rather than if a member is renamed.
func _bar_for(screen: Node, key: String) -> Control:
	var down: Button = _find(screen, "Down_" + key)
	if down == null:
		return null
	var row: Node = down.get_parent()
	for c in row.get_children():
		if c is Control and not (c is Button):
			return c as Control
	return null


# ------------------------------------------------------------------------------
# THE INVARIANT, WIDENED
# ------------------------------------------------------------------------------

## A preference write must modify prefs.json AND NOTHING ELSE IN user://.
##
## _roster_untouched names roster.json, which is the file whose loss hurts. This
## section asserts the general shape instead, and it does so because the saves
## in this project are not finished growing: a stash file, a quest log or a
## settings-adjacent cache added later would be outside an assertion that only
## names roster.json, and the collateral-write bug would then ship unseen.
##
## Directories are deliberately not walked — Godot's own user://logs/godot.log
## is written throughout this run, and a test that fails because the engine
## logged something is a test that gets deleted.
func _only_prefs_changed() -> void:
	print("\n=== a pref write touches one file and no other ===")
	var before: Dictionary = _user_files()

	# A deliberately broad run of writes: every key, every path into the store
	# (direct, deferred, reset), because the collateral write this guards
	# against would most likely sit in the rarely-used one.
	for key in PrefsS.SPEC.keys():
		var spec: Dictionary = PrefsS.SPEC[key]
		if int(spec["kind"]) == TYPE_BOOL:
			PrefsS.set_value(String(key), false)
			PrefsS.set_value(String(key), true)
		else:
			PrefsS.set_value(String(key), spec["lo"], false)
			PrefsS.flush()
			PrefsS.set_value(String(key), spec["hi"])
	PrefsS.reset()
	PrefsS.save()

	var after: Dictionary = _user_files()

	# prefs.json is the one file allowed to appear or change, so it is dropped
	# from both sides rather than special-cased in the comparison below.
	before.erase(PrefsS.PATH.get_file())
	after.erase(PrefsS.PATH.get_file())

	check("prefs.json itself was written",
		FileAccess.file_exists(PrefsS.PATH))
	check("no other file in user:// appeared or vanished",
		before.keys() == after.keys(),
		"%d before, %d after" % [before.size(), after.size()])

	var changed: PackedStringArray = PackedStringArray()
	for name in before.keys():
		if after.has(name) and after[name] != before[name]:
			changed.append(String(name))
	check("no other file in user:// was modified",
		changed.is_empty(),
		"untouched: %s" % ", ".join(before.keys()) if changed.is_empty()
		else "CHANGED: %s" % ", ".join(changed))

	# The assertion above is only worth anything if there was something there to
	# protect. With an empty user:// it would pass against nothing at all.
	check("...and there was at least one other save file to protect",
		before.size() > 0, "%d files" % before.size())


## Top-level files in user://, as name -> "size:mtime". Size as well as time
## because get_modified_time has one-second granularity, so a same-second
## rewrite is invisible to the clock alone.
func _user_files() -> Dictionary:
	var out: Dictionary = {}
	var dir := DirAccess.open("user://")
	if dir == null:
		return out
	for name in dir.get_files():
		var path: String = "user://" + name
		out[name] = "%d:%d" % [_file_size(path),
			FileAccess.get_modified_time(path)]
	return out


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n: int = f.get_length()
	f.close()
	return n


# ------------------------------------------------------------------------------
# THE INVARIANT
# ------------------------------------------------------------------------------

func _roster_snapshot() -> Dictionary:
	var path: String = RosterS.SAVE_PATH
	var existed: bool = FileAccess.file_exists(path)
	if not existed:
		# Nothing to protect yet, so plant something to protect: a sentinel
		# proves the "a pref write creates roster.json" failure is covered as
		# well as the "a pref write overwrites it" one.
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string('{"sentinel":"prefstest"}')
			f.close()
	var text: String = ""
	var g := FileAccess.open(path, FileAccess.READ)
	if g != null:
		text = g.get_as_text()
		g.close()
	return {
		"existed": existed,
		"text": text,
		"mtime": FileAccess.get_modified_time(path),
	}


func _roster_untouched(before: Dictionary) -> void:
	print("\n=== the roster is untouched ===")
	var path: String = RosterS.SAVE_PATH
	var text: String = ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		text = f.get_as_text()
		f.close()

	check("roster.json still exists", not text.is_empty())
	check("roster.json is byte-for-byte what it was",
		text == String(before["text"]),
		"%d bytes before, %d after" % [String(before["text"]).length(),
			text.length()])
	# A rewrite with identical content is still a rewrite, and still a window
	# in which a suspend truncates the save.
	check("roster.json was not even rewritten",
		FileAccess.get_modified_time(path) == int(before["mtime"]))
	check("the prefs file is a different file",
		PrefsS.PATH != RosterS.SAVE_PATH)

	if not bool(before["existed"]):
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove(path.get_file())


# ------------------------------------------------------------------------------
# Plumbing
# ------------------------------------------------------------------------------

func _wipe() -> void:
	if FileAccess.file_exists(PrefsS.PATH):
		var dir := DirAccess.open("user://")
		if dir != null:
			dir.remove(PrefsS.PATH.get_file())


func _write_raw(text: String) -> void:
	var f := FileAccess.open(PrefsS.PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _read_raw() -> String:
	var f := FileAccess.open(PrefsS.PATH, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f.close()
	return text


func _restore_prefs() -> void:
	_wipe()
	if _had_prefs:
		_write_raw(_saved_prefs)
	PrefsS.load_prefs()


func _find(node: Node, name: String) -> Button:
	return node.find_child(name, true, false) as Button


func _find_by_text(node: Node, needle: String) -> Button:
	for b in _buttons(node):
		if (b as Button).text.findn(needle) >= 0:
			return b
	return null


func _buttons(node: Node, out: Array = []) -> Array:
	if node is Button:
		out.append(node)
	for c in node.get_children():
		_buttons(c, out)
	return out


func _labels(node: Node, out: Array = []) -> Array:
	if node is Label:
		out.append(node)
	for c in node.get_children():
		_labels(c, out)
	return out
