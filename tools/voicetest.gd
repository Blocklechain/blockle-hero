extends SceneTree
# ------------------------------------------------------------------------------
# DOES THE NARRATION REACH THE PLAYER — AND DOES IT STILL REACH THEM WITH NO
# AUDIO AT ALL?
#
# The second half is the one worth a harness. The game ships before every line
# is rendered: wavs arrive in batches out of tools/gen_voice.py, and a build is
# cut whenever a build is needed. So the normal state of this system is "some
# lines have audio and some do not", and the failure it must never have is a
# beat that shows NOTHING because its wav has not been recorded yet. That is
# invisible to a compile, to a balance test and to a reviewer reading the diff.
#
# WHAT IS ASSERTED IS THE EFFECT, NEVER THE SIGNAL. This project's single most
# common bug is a feature that emits perfectly into a listener nobody connected
# — five features shipped wired to nothing — so nothing below is satisfied by
# "a function was called":
#
#   * the subtitle is read back off Narration.current_text, and separately out
#     of a sink registered on `on_line`, because a subtitle only one of those
#     routes can see is a subtitle half the game cannot show;
#   * "playable" means the real AudioStreamPlayer is holding that exact stream
#     and reports itself playing, at the volume its BEAT asks for;
#   * "the queue did not drop a line" means the second line's words are on
#     screen afterwards, in order, not that a queue array had size 2;
#   * "skip stopped it" means the player reports playing == false;
#   * "the words are canon" means every story line in the table is compared
#     CHARACTER FOR CHARACTER against Story.gd, which is the only thing that
#     can catch the prose quietly forking into two versions. It already had
#     once: the manifest used to carry its own copy of the narration.
#
# IT DOES NOT DEPEND ON THE GENERATED AUDIO EXISTING. assets/voice may be
# empty, half full, or complete, and this harness behaves identically: it points
# Narration at its own scratch directories and writes the one real wav it needs
# (a 0.2 s silent PCM_16 file) itself. A harness that only passes after someone
# remembers to run a two-minute render is a harness that gets skipped.
#
# ON THE DUMMY AUDIO DRIVER an AudioStreamPlayer reports playing == true, never
# advances its position and NEVER emits `finished`. Both facts are load-bearing
# here: the first is what makes playback assertable at all, and the second is
# why Narration paces its queue on advance(delta) — which is also the seam this
# harness uses to retire a line without waiting on wall time.
#
# SECTIONS ARE COUNTED. A runtime error aborts the function it happens in and
# GDScript carries on to the next, so a crash in the middle of a section reads
# as zero failures. The count is the guard.
#
#   godot --headless --path . --script tools/voicetest.gd
# ------------------------------------------------------------------------------

const NarrationS := preload("res://scripts/game/Narration.gd")
const StoryS := preload("res://scripts/game/Story.gd")

const SECTIONS: int = 8

## Where the harness builds its own voice directories. NOT assets/voice: these
## have to be exactly as empty or as full as each section needs, and deleting
## the shipped lines to prove the silent path would be a poor trade.
const SCRATCH: String = "user://voicetest"

## gen_voice.py's record of what it last rendered. Read-only, and its absence
## is not a failure — see section 8.
const LEDGER: String = "res://assets/voice/.render.json"

var _fails: int = 0
var _done: int = 0
var _ctx: Node = null


func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	# A frame first: nothing added from a MainLoop's own _init() is inside the
	# tree yet, and Narration cannot play from outside it.
	await process_frame
	_ctx = Node.new()
	_ctx.name = "VoiceTestCtx"
	root.add_child(_ctx)
	await process_frame

	_the_casting_table(); _done += 1
	_the_words_are_canon(); _done += 1
	await _silence_when_there_is_no_audio(); _done += 1
	await _a_present_wav_is_found_and_plays(); _done += 1
	await _the_queue_keeps_the_second_line(); _done += 1
	await _skip_stops_playback(); _done += 1
	await _muting_keeps_the_words(); _done += 1
	await _say_story_speaks_a_whole_beat(); _done += 1

	print("")
	check("every section ran to completion", _done == SECTIONS,
		"%d of %d" % [_done, SECTIONS])
	await _teardown()
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

## An empty directory, emptied again if a previous run left anything in it.
func _scratch(name: String) -> String:
	var path: String = SCRATCH.path_join(name)
	DirAccess.make_dir_recursive_absolute(path)
	var dir := DirAccess.open(path)
	if dir != null:
		for f in dir.get_files():
			dir.remove(f)
	return path


## A real, loadable, 16-bit mono PCM wav of silence.
##
## Written by hand rather than rendered: the whole point is that this harness
## never waits on Kokoro. 0.2 s is long enough to be a legitimate stream and
## short enough that writing it costs nothing.
func _silent_wav(path: String, rate: int = 24000, secs: float = 0.2) -> bool:
	var frames: int = int(round(float(rate) * secs))
	var bytes: int = frames * 2
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(36 + bytes)
	f.store_buffer("WAVE".to_ascii_buffer())
	f.store_buffer("fmt ".to_ascii_buffer())
	f.store_32(16)                      # fmt chunk size
	f.store_16(1)                       # PCM
	f.store_16(1)                       # mono
	f.store_32(rate)
	f.store_32(rate * 2)                # byte rate
	f.store_16(2)                       # block align
	f.store_16(16)                      # bits per sample
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(bytes)
	var zeros := PackedByteArray()
	zeros.resize(bytes)
	f.store_buffer(zeros)
	f.close()
	return FileAccess.file_exists(path)


## Narration's state is static and would otherwise leak between sections.
func _fresh(dir: String) -> void:
	NarrationS.reset()
	NarrationS.set_voice_dir(dir)
	NarrationS.reload_table()


func _player() -> AudioStreamPlayer:
	var n = NarrationS.boot(_ctx)
	return null if n == null else n._player


## Retire the line on screen and let the NEXT one come up — and stop there.
##
## Two advances, deliberately, because that is exactly what the queue does: the
## first expires the hold and ends the line (opening the inter-line gap), the
## second closes that gap and pumps the next line. An earlier version of this
## helper advanced eight times "to be safe" and sailed straight past the second
## line as well, so every assertion about it read FAIL against a queue that was
## working perfectly. Draining a queue and stepping a queue are not the same
## operation.
func _next_line() -> void:
	NarrationS.advance(60.0)
	NarrationS.advance(60.0)


## Run the queue dry, however many lines are in it.
func _drain() -> void:
	for i in range(2 * (NarrationS.QUEUE_MAX + 2)):
		NarrationS.advance(60.0)


func _teardown() -> void:
	NarrationS.stop()
	var n = NarrationS.boot(_ctx)
	if n != null and is_instance_valid(n):
		n.free()
	NarrationS._node = null
	NarrationS.reset()
	if _ctx != null and is_instance_valid(_ctx):
		_ctx.free()
	# Freeing an AudioStreamPlayer only queues its playback for release; the
	# AudioServer needs mix frames to let go, and a harness that ends in a
	# leaked-instance warning is a harness people learn to ignore.
	for i in range(20):
		await process_frame


# ------------------------------------------------------------------------------
# 1. Casting
# ------------------------------------------------------------------------------

func _the_casting_table() -> void:
	print("\n=== the casting table: every beat is cast, to the right voice ===")
	NarrationS.reload_table()
	var keys: PackedStringArray = NarrationS.keys()
	check("the table loads", keys.size() >= 20, "%d lines" % keys.size())

	# THE ASSERTION THAT CATCHES A BEAT GOING QUIETLY UNVOICED. Story.beats()
	# is the authority on what beats exist; a beat added there and not cast in
	# the manifest would show its subtitle in silence forever, and nothing else
	# in the project would ever mention it.
	var uncast: PackedStringArray = NarrationS.uncast_story_beats()
	check("every beat Story advertises is cast", uncast.is_empty(),
		"uncast: " + ",".join(uncast) if not uncast.is_empty()
		else "%d beats" % StoryS.beats().size())

	var bad_key: String = ""
	var no_text: String = ""
	var no_beat: String = ""
	var no_voice: String = ""
	var re := RegEx.create_from_string("^[a-z0-9_]+$")
	for k in keys:
		# A key IS a filename (assets/voice/<key>.wav). A space or a slash in
		# one renders to a path nothing can load back, and the symptom is a
		# silent line rather than an error.
		if re.search(k) == null:
			bad_key = k
		if NarrationS.text_of(k).strip_edges().is_empty():
			no_text = k
		var beat: String = NarrationS.beat_of(k)
		if beat.is_empty():
			no_beat = k
		elif NarrationS.voice_of_beat(beat).is_empty():
			no_voice = k
	check("every key is filename-safe", bad_key.is_empty(), bad_key)
	check("every line has words", no_text.is_empty(), no_text)
	check("every line names a speaking role", no_beat.is_empty(), no_beat)
	check("every role has a voice behind it", no_voice.is_empty(), no_voice)

	# THE BRIEF, AS DATA: the narrator is British and graver, the boss taunts
	# are the other voice. Asserted through a real line's key rather than by
	# reading the manifest back, because what matters is what the line that
	# gets spoken is cast as — the indirection is the feature, so the test goes
	# through it.
	var opener: String = "act_01_open_1"
	var taunt: String = "act_01_taunt"
	check("the narrator speaks the act openers with bm_george",
		NarrationS.voice_of_beat(NarrationS.beat_of(opener)) == "bm_george",
		"%s -> %s" % [opener,
			NarrationS.voice_of_beat(NarrationS.beat_of(opener))])
	check("a boss taunt speaks with am_michael",
		NarrationS.voice_of_beat(NarrationS.beat_of(taunt)) == "am_michael",
		"%s -> %s" % [taunt,
			NarrationS.voice_of_beat(NarrationS.beat_of(taunt))])
	check("the narrator is slowed down, the boss is not",
		NarrationS.speed_of_beat("narrator") < 1.0
		and is_equal_approx(NarrationS.speed_of_beat("boss"), 1.0),
		"x%.2f vs x%.2f" % [NarrationS.speed_of_beat("narrator"),
			NarrationS.speed_of_beat("boss")])
	check("roles carry their own mix level",
		not is_equal_approx(NarrationS.gain_of_beat("narrator"),
			NarrationS.gain_of_beat("boss")),
		"narrator %.1f dB vs boss %.1f dB" % [
			NarrationS.gain_of_beat("narrator"),
			NarrationS.gain_of_beat("boss")])

	# The acts are the spine of the campaign; a table that lost one would still
	# pass everything above.
	var acts: int = 0
	for act in range(StoryS.ACT_COUNT):
		if NarrationS.story_keys("act_open", act).size() == 2 \
				and NarrationS.story_keys("boss_taunt", act).size() == 1:
			acts += 1
	check("all ten acts have an opener and a taunt",
		acts == StoryS.ACT_COUNT, "%d of %d" % [acts, StoryS.ACT_COUNT])


# ------------------------------------------------------------------------------
# 2. The prose has not forked
# ------------------------------------------------------------------------------

func _the_words_are_canon() -> void:
	print("\n=== the words are Story.gd's, character for character ===")
	NarrationS.reload_table()

	# Walk every beat Story advertises and compare what Narration would show
	# against what Story says, key by key. This is the assertion that keeps the
	# subtitle, the wav and canon the same three sentences: the manifest used to
	# hold a second copy of the narration, and by the time anyone looked the two
	# had drifted into contradicting each other about who the player is.
	var mismatched: String = ""
	var counted: int = 0
	# DISTINCT keys, not comparisons. A beat indexed `once` (first_death) is
	# the same single line whatever act you ask for, so counting comparisons
	# would expect ten lines where the table correctly holds one.
	var seen: Dictionary = {}
	for beat_v in StoryS.beats():
		var beat: String = String(beat_v)
		if beat == "region_flavour":
			continue                    # map-indexed; below
		for act in range(StoryS.ACT_COUNT):
			var lines: PackedStringArray = StoryS.lines(beat, act)
			var keys: PackedStringArray = NarrationS.story_keys(beat, act)
			if keys.size() != lines.size():
				mismatched = "%s act %d: %d keys for %d lines" % [beat, act,
					keys.size(), lines.size()]
				continue
			for i in range(lines.size()):
				counted += 1
				seen[keys[i]] = true
				if NarrationS.text_of(keys[i]) != lines[i]:
					mismatched = "%s -> %s" % [keys[i],
						NarrationS.text_of(keys[i]).substr(0, 30)]
	check("every act-indexed story line matches Story.gd exactly",
		mismatched.is_empty(), mismatched if not mismatched.is_empty()
		else "%d lines compared" % counted)

	var flavour_bad: String = ""
	var flavours: int = 0
	for index in StoryS.flavour_indices():
		var keys: PackedStringArray = NarrationS.story_keys("region_flavour",
			0, index)
		if keys.size() != 1:
			flavour_bad = "map %d: %d keys" % [index, keys.size()]
			continue
		flavours += 1
		seen[keys[0]] = true
		if NarrationS.text_of(keys[0]) != StoryS.region_flavour(index):
			flavour_bad = keys[0]
	check("every flavoured map's line matches Story.gd exactly",
		flavour_bad.is_empty(), flavour_bad if not flavour_bad.is_empty()
		else "%d maps" % flavours)

	# A map with nothing to say must produce no key at all, not a key with no
	# words behind it — that would be a wav gen_voice could never render and a
	# subtitle that never appears.
	var silent_maps: int = 0
	for index in range(100):
		if not StoryS.has_region_flavour(index) \
				and NarrationS.story_keys("region_flavour", 0, index).is_empty():
			silent_maps += 1
	check("maps with no flavour claim no line",
		silent_maps == 100 - StoryS.flavour_indices().size(),
		"%d quiet maps" % silent_maps)

	# Nothing lost and nothing invented: the number of story-sourced lines in
	# the table is exactly the number Story advertises. A beat Narration failed
	# to index at all would pass every comparison above by never being compared.
	var story_keys: int = 0
	for k in NarrationS.keys():
		if NarrationS.source_of(k).begins_with("story:"):
			story_keys += 1
	check("the table holds every story line and no others",
		story_keys == seen.size() and seen.size() > 0,
		"%d in table, %d reachable through Story" % [story_keys, seen.size()])


# ------------------------------------------------------------------------------
# 3. No audio anywhere — the path the game actually ships in
# ------------------------------------------------------------------------------

func _silence_when_there_is_no_audio() -> void:
	print("\n=== zero wavs: the words still arrive ===")
	var empty: String = _scratch("none")
	_fresh(empty)
	var n = NarrationS.boot(_ctx)
	await process_frame
	check("Narration booted against an empty directory", n != null
		and is_instance_valid(n), empty)
	check("the directory really is empty",
		DirAccess.open(empty) != null
		and DirAccess.open(empty).get_files().is_empty())

	# A sink registered the way the HUD registers one. Asserted separately from
	# current_text: a line only one of the two routes can see is a line half
	# the game cannot show.
	var heard: Array[String] = []
	var ended: Array[String] = []
	NarrationS.on_line.append(func(key: String, _t: String) -> void:
		heard.append(key))
	NarrationS.on_line_end.append(func(key: String) -> void:
		ended.append(key))

	var said: PackedStringArray = ["act_01_open_1", "act_01_taunt",
		"quest_offered"]
	var accepted: int = 0
	for k in said:
		if NarrationS.say(k):
			accepted += 1
	check("every line was accepted with no audio to play",
		accepted == said.size(), "%d of %d" % [accepted, said.size()])
	check("no wav was found for any of them",
		not NarrationS.has_audio(said[0]) and not NarrationS.has_audio(said[1]))

	# THE ASSERTION THIS HARNESS EXISTS FOR.
	check("the first line's words are on screen anyway",
		NarrationS.current_text == NarrationS.text_of(said[0]),
		"\"%s\"" % NarrationS.current_text.substr(0, 34))
	check("a silent line still holds long enough to read",
		NarrationS._hold >= NarrationS.READ_MIN,
		"%.2fs" % NarrationS._hold)

	_drain()
	check("all three were presented", NarrationS.lines_shown == 3,
		"shown %d" % NarrationS.lines_shown)
	check("all three counted as silent, none as voiced",
		NarrationS.lines_silent == 3 and NarrationS.lines_voiced == 0,
		"silent %d voiced %d" % [NarrationS.lines_silent,
			NarrationS.lines_voiced])
	check("the sink heard all three, in order",
		",".join(heard) == ",".join(said), ",".join(heard))
	check("each line reported its end", ended.size() == 3,
		"%d ends" % ended.size())
	check("nothing is left speaking", not NarrationS.is_speaking()
		and NarrationS.current_text.is_empty())


# ------------------------------------------------------------------------------
# 4. A wav that IS there
# ------------------------------------------------------------------------------

func _a_present_wav_is_found_and_plays() -> void:
	print("\n=== one wav present: found, loaded, playing ===")
	var dir: String = _scratch("one")
	var key: String = "act_01_taunt"
	check("the harness wrote its own wav",
		_silent_wav(dir.path_join("%s.wav" % key)), dir)
	_fresh(dir)

	check("the wav is found", NarrationS.has_audio(key))
	var stream: AudioStreamWAV = NarrationS.stream_for(key)
	check("it loaded as real PCM", stream != null
		and stream.data.size() > 0 and stream.mix_rate == 24000,
		"" if stream == null else "%d B @ %d Hz, %.2fs" % [stream.data.size(),
			stream.mix_rate, stream.get_length()])
	check("a line with no wav in the same directory is still silent",
		not NarrationS.has_audio("act_01_open_1"))

	var p: AudioStreamPlayer = _player()
	await process_frame
	NarrationS.say(key)
	check("the player is playing", p != null and p.playing)
	check("...that exact stream", p != null and p.stream == stream)
	# Proves the per-beat mix reaches the hardware, which is the other half of
	# "the voice is configurable, not hardcoded at the call site".
	check("...at its role's mix level", p != null and is_equal_approx(
		p.volume_db, NarrationS.gain_of_beat(NarrationS.beat_of(key))),
		"%.1f dB" % [0.0 if p == null else p.volume_db])
	check("counted as voiced, not silent", NarrationS.lines_voiced == 1
		and NarrationS.lines_silent == 0)
	check("and the subtitle is up as well",
		NarrationS.current_text == NarrationS.text_of(key))


# ------------------------------------------------------------------------------
# 5. The queue
# ------------------------------------------------------------------------------

func _the_queue_keeps_the_second_line() -> void:
	print("\n=== two beats cannot talk over each other ===")
	var dir: String = _scratch("queue")
	check("wav written for the first line",
		_silent_wav(dir.path_join("act_01_open_1.wav")))
	_fresh(dir)
	var p: AudioStreamPlayer = _player()
	await process_frame

	NarrationS.say("act_01_open_1")
	NarrationS.say("act_01_open_2")
	check("the first line is the one on screen",
		NarrationS.current_key == "act_01_open_1", NarrationS.current_key)
	check("the second is waiting, not playing", NarrationS.pending() == 1,
		"%d pending" % NarrationS.pending())
	check("only one line has been presented", NarrationS.lines_shown == 1)

	_next_line()
	check("the second line was NOT dropped",
		NarrationS.current_key == "act_01_open_2", NarrationS.current_key)
	check("its words are the ones on screen",
		NarrationS.current_text == NarrationS.text_of("act_01_open_2"))
	check("both were presented, in order",
		NarrationS.lines_shown == 2
		and ",".join(NarrationS.history) == "act_01_open_1,act_01_open_2",
		",".join(NarrationS.history))
	check("the second had no wav, so it is silent and still timed",
		NarrationS.lines_voiced == 1 and NarrationS.lines_silent == 1
		and NarrationS._hold > 0.0, "%.2fs" % NarrationS._hold)
	# The first line's audio must not still be running underneath the second
	# line's subtitle: two voices, one set of words, and the only clue is that
	# they do not match.
	check("the first line's audio was stopped when it retired",
		p != null and not p.playing)
	_drain()

	# Overflow is a real policy, not an accident: a backlog means the line at
	# the FRONT is about something the player walked past, so that is the one
	# that goes. The newest must survive.
	_fresh(dir)
	var keys: PackedStringArray = ["act_01_open_1", "act_02_open_1",
		"act_03_open_1", "act_04_open_1", "act_05_open_1", "act_06_open_1",
		"act_07_open_1"]
	for k in keys:
		NarrationS.say(k)
	for k in keys:
		_drain()
	check("an overflowing queue drops the oldest pending line",
		NarrationS.lines_dropped > 0,
		"dropped %d of %d" % [NarrationS.lines_dropped, keys.size()])
	check("...and never the newest",
		",".join(NarrationS.history).ends_with(keys[keys.size() - 1]),
		",".join(NarrationS.history))


# ------------------------------------------------------------------------------
# 6. skip()
# ------------------------------------------------------------------------------

func _skip_stops_playback() -> void:
	print("\n=== skip() ===")
	var dir: String = _scratch("skip")
	var key: String = "act_03_open_1"
	check("wav written", _silent_wav(dir.path_join("%s.wav" % key)))
	_fresh(dir)
	var p: AudioStreamPlayer = _player()
	await process_frame

	NarrationS.say(key)
	check("playing before the skip", p != null and p.playing)
	NarrationS.skip()
	check("the audio stopped", p != null and not p.playing)
	check("nothing is being said", not NarrationS.is_speaking()
		and NarrationS.current_key.is_empty(), NarrationS.current_key)
	check("the skip was counted", NarrationS.lines_skipped == 1)

	# A skip is "next", not "shut up": whatever was queued behind it must come
	# straight up, with no gap to wait out.
	_fresh(dir)
	NarrationS.say(key)
	NarrationS.say("act_04_open_1")
	NarrationS.skip()
	check("the queued line comes up immediately",
		NarrationS.current_key == "act_04_open_1", NarrationS.current_key)
	check("its words are on screen",
		NarrationS.current_text == NarrationS.text_of("act_04_open_1"))

	# stop() is the other half: a scene change must not leave the last map's
	# narration queued up for the next one.
	NarrationS.say("act_05_open_1")
	NarrationS.stop()
	check("stop() clears the queue and the line",
		not NarrationS.is_speaking() and NarrationS.pending() == 0
		and NarrationS.current_text.is_empty())
	_drain()
	check("...and nothing arrives afterwards", NarrationS.current_key.is_empty(),
		NarrationS.current_key)


# ------------------------------------------------------------------------------
# 7. Muting, and a key nobody wrote a line for
# ------------------------------------------------------------------------------

func _muting_keeps_the_words() -> void:
	print("\n=== muting the voice must not mute the story ===")
	var dir: String = _scratch("mute")
	var key: String = "act_06_open_1"
	check("wav written", _silent_wav(dir.path_join("%s.wav" % key)))
	_fresh(dir)
	var p: AudioStreamPlayer = _player()
	await process_frame

	NarrationS.enabled = false
	NarrationS.say(key)
	check("the words are still on screen",
		NarrationS.current_text == NarrationS.text_of(key))
	check("but nothing is playing", p != null and not p.playing)
	check("and it is timed as a silent line",
		NarrationS.lines_silent == 1 and NarrationS.lines_voiced == 0
		and NarrationS._hold >= NarrationS.READ_MIN,
		"%.2fs" % NarrationS._hold)
	NarrationS.enabled = true
	_drain()

	_fresh(dir)
	check("a key with no line anywhere is refused rather than shown blank",
		not NarrationS.say("no_such_line") and NarrationS.lines_shown == 0)
	check("...but a runtime line carrying its own words is presented",
		NarrationS.say("no_such_line", "I know that stance. I taught it.")
		and NarrationS.current_text == "I know that stance. I taught it.")
	_drain()


# ------------------------------------------------------------------------------
# 8. say_story(), and the renderer's record of what it made
# ------------------------------------------------------------------------------

func _say_story_speaks_a_whole_beat() -> void:
	print("\n=== say_story(): the call site names an event, not a line ===")
	var dir: String = _scratch("story")
	_fresh(dir)
	NarrationS.boot(_ctx)
	await process_frame

	# An act opener is two lines. The call site says "the act opened" and gets
	# both, in order, without naming either.
	var queued: int = NarrationS.say_story("act_open", 0)
	check("an act opener queues both of its lines", queued == 2,
		"%d queued" % queued)
	check("the first is up, the second is waiting",
		NarrationS.current_key == "act_01_open_1"
		and NarrationS.pending() == 1, NarrationS.current_key)
	check("with Story's words, not a key",
		NarrationS.current_text == StoryS.act_open(0)[0],
		"\"%s\"" % NarrationS.current_text.substr(0, 34))
	_next_line()
	check("then the second, in order",
		NarrationS.current_key == "act_01_open_2"
		and NarrationS.current_text == StoryS.act_open(0)[1],
		NarrationS.current_key)
	_drain()

	check("a boss taunt is one line, in the boss's voice",
		NarrationS.say_story("boss_taunt", 9) == 1
		and NarrationS.current_text == StoryS.boss_taunt(9)
		and NarrationS.voice_of_beat(NarrationS.beat_of(
			NarrationS.current_key)) == "am_michael",
		NarrationS.current_key)
	_drain()

	# A map with nothing to say must say nothing — not an empty subtitle, and
	# not somebody else's line.
	var quiet: int = -1
	for index in range(100):
		if not StoryS.has_region_flavour(index):
			quiet = index
			break
	check("a map with no flavour line says nothing at all",
		NarrationS.say_story("region_flavour", 0, quiet) == 0
		and not NarrationS.is_speaking(), "map %d" % quiet)
	var flavoured: int = StoryS.flavour_indices()[0]
	check("a flavoured map says its one line",
		NarrationS.say_story("region_flavour", 0, flavoured) == 1
		and NarrationS.current_text == StoryS.region_flavour(flavoured),
		"map %d" % flavoured)
	_drain()

	# An act beyond the last one must read the nearest act rather than crash or
	# go blank — Story clamps, and the KEY has to clamp with it or the words and
	# the audio come from different acts.
	var over: PackedStringArray = NarrationS.story_keys("act_open", 99)
	check("an out-of-range act clamps to the last one, key and words together",
		over.size() == 2 and over[0] == "act_%02d_open_1" % StoryS.ACT_COUNT
		and NarrationS.text_of(over[0]) == StoryS.act_open(99)[0],
		",".join(over))

	# gen_voice.py's ledger: every line it rendered must still be a line this
	# script knows how to ask for. A key scheme that moved under the renderer
	# would leave the wavs on disk under names nothing looks for — the game
	# would go quiet with every piece of it still "working".
	#
	# Conditional ON PURPOSE: the ledger only exists after a render, and this
	# harness must pass on a fresh checkout with no audio in it at all.
	var ledger_text: String = ""
	if FileAccess.file_exists(LEDGER):
		ledger_text = FileAccess.get_file_as_string(LEDGER)
	if ledger_text.is_empty():
		print("  note  no render ledger yet; nothing rendered to cross-check")
		return
	var parsed: Variant = JSON.parse_string(ledger_text)
	var rendered: Dictionary = {}
	if typeof(parsed) == TYPE_DICTIONARY:
		var l: Variant = (parsed as Dictionary).get("lines", {})
		if typeof(l) == TYPE_DICTIONARY:
			rendered = l
	var orphan: String = ""
	for key in rendered.keys():
		if not NarrationS.has_line(String(key)):
			orphan = String(key)
	check("every wav the renderer made still belongs to a line",
		not rendered.is_empty() and orphan.is_empty(),
		orphan if not orphan.is_empty() else "%d rendered" % rendered.size())

	# And the other direction, reported rather than asserted: how much of the
	# table is actually voiced today. Not a failure at any number — that is the
	# entire premise of this file.
	NarrationS.set_voice_dir(NarrationS.DEFAULT_VOICE_DIR)
	var voiced: int = 0
	for k in NarrationS.keys():
		if NarrationS.has_audio(k):
			voiced += 1
	print("  note  %d of %d lines have audio on disk" % [voiced,
		NarrationS.keys().size()])
