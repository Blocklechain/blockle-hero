extends SceneTree
# ------------------------------------------------------------------------------
# THE STORY HAS TO BE SAYABLE OUT LOUD, AND COMPLETE.
#
# Story lines are not code, so none of the usual failures announce themselves.
# A line that is too long, or has an em dash in it, or is simply missing, does
# not raise anything: it reaches a player as a subtitle that scrolls off the
# phone, a TTS voice saying "dash", or silence where an act was supposed to
# turn. Nobody writing the next act will run the game at act 7 to check.
#
# So this audits the whole table:
#
#   * every act 0..9 has an opening and a closing and a boss
#   * no line is empty, and none is longer than one mobile breath
#   * every beat the API ADVERTISES has data behind it — the dispatcher is
#     walked, not the tables, because the real bug is a beat named in BEATS
#     that nothing ever filled in
#   * every character in every line is one a TTS can pronounce. No emoji, no
#     em dash, no ellipsis character, no curly quotes, no markup, no numerals
#   * the flavour lines sit on the map indices where the GROUND actually
#     changes, so a line describing crystal is not read out on a moor
#   * no named protagonist, mechanically: no gendered pronoun and no format
#     token that a caller could substitute a champion's name into
#
# Pure data and static calls, so this needs no scene and no rigs.
# ------------------------------------------------------------------------------

const StoryS := preload("res://scripts/game/Story.gd")
const CampaignS := preload("res://scripts/game/Campaign.gd")

## Characters a TTS voice renders as speech. Everything else either gets read
## aloud as punctuation, gets skipped, or comes out as a glyph name.
##
## Numerals are excluded ON PURPOSE: "100" is spoken differently by every
## engine and locale, and "1-2" becomes "one minus two". Numbers in these lines
## are spelled out as words.
const SPEAKABLE: String = ("abcdefghijklmnopqrstuvwxyz"
	+ "ABCDEFGHIJKLMNOPQRSTUVWXYZ" + " ,.'!?-")

## A walker with a gender is a walker with an identity, and the player fields
## any of 139 champions. Matched as whole words so "there" and "shield" are not
## false positives.
const GENDERED: PackedStringArray = [
	"he", "him", "his", "she", "her", "hers", "himself", "herself",
]

## Anything that implies a caller splices a name in. A story that formats a name
## into itself has a protagonist by the back door.
const FORMAT_TOKENS: PackedStringArray = ["%s", "%d", "{", "}", "[", "]"]

var _fails: int = 0
var _done: int = 0


func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _init() -> void:
	_acts_are_covered(); _done += 1
	_every_line_is_speakable(); _done += 1
	_every_advertised_beat_has_data(); _done += 1
	_flavour_sits_on_the_ground(); _done += 1
	_lookups_are_safe(); _done += 1
	_the_ending_lands(); _done += 1
	print("")
	# A runtime error aborts the function it happens in and GDScript carries on,
	# so a crash would otherwise be reported as zero failures. Count the
	# sections that actually finished.
	check("every section ran to completion", _done == 6, "%d of 6" % _done)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ---- coverage ----------------------------------------------------------------

func _acts_are_covered() -> void:
	print("\n-- every act has its beats --")
	check("the story spans as many acts as the campaign",
		StoryS.ACT_COUNT == CampaignS.act_count(),
		"story %d, campaign %d" % [StoryS.ACT_COUNT, CampaignS.act_count()])

	var thin_open: Array = []
	var thin_close: Array = []
	var no_boss: Array = []
	for act in range(StoryS.ACT_COUNT):
		# Two lines means two: the brief is place, then what the road does.
		if StoryS.act_open(act).size() != 2:
			thin_open.append("%d has %d" % [act + 1, StoryS.act_open(act).size()])
		var cl: int = StoryS.act_close(act).size()
		if cl < 1 or cl > 2:
			thin_close.append("%d has %d" % [act + 1, cl])
		if StoryS.boss_taunt(act).strip_edges() == "":
			no_boss.append(str(act + 1))

	check("every act opens with two lines", thin_open.is_empty(),
		", ".join(thin_open))
	check("every act closes with one or two lines", thin_close.is_empty(),
		", ".join(thin_close))
	check("every act boss has a greeting", no_boss.is_empty(),
		", ".join(no_boss))
	check("the first death has a line",
		StoryS.first_death().strip_edges() != "")

	# Ten acts of identical dread would be a worse story than one act. The
	# cheapest proof the table was actually written and not copy-pasted.
	var seen: Dictionary = {}
	for act in range(StoryS.ACT_COUNT):
		seen[StoryS.act_open(act)[0]] = true
		seen[StoryS.boss_taunt(act)] = true
	check("no act reuses another act's opening or boss line",
		seen.size() == StoryS.ACT_COUNT * 2,
		"%d distinct of %d" % [seen.size(), StoryS.ACT_COUNT * 2])


# ---- speakability ------------------------------------------------------------

func _every_line_is_speakable() -> void:
	print("\n-- every line can be spoken --")
	var all: Array = _all_lines()
	check("there are lines to check", all.size() >= 40, "%d lines" % all.size())

	var empty: Array = []
	var long: Array = []
	var unsayable: Array = []
	for entry in all:
		var where: String = entry[0]
		var line: String = entry[1]
		if line.strip_edges() == "":
			empty.append(where)
			continue
		if line.length() > StoryS.MAX_SPOKEN:
			long.append("%s is %d" % [where, line.length()])
		var bad: String = _unspeakable_chars(line)
		if bad != "":
			unsayable.append("%s has %s" % [where, bad])

	check("no line is empty", empty.is_empty(), ", ".join(empty))
	check("no line is longer than one mobile breath", long.is_empty(),
		"max %d: %s" % [StoryS.MAX_SPOKEN, ", ".join(long)])
	check("every character is one a TTS can say", unsayable.is_empty(),
		", ".join(unsayable))

	# A double hyphen is how an em dash gets smuggled past a charset check, and
	# it is read aloud as nothing or as "dash dash".
	var dashes: Array = []
	for entry in all:
		if String(entry[1]).contains("--"):
			dashes.append(String(entry[0]))
	check("no line fakes an em dash with hyphens", dashes.is_empty(),
		", ".join(dashes))


func _unspeakable_chars(line: String) -> String:
	var bad: String = ""
	for i in range(line.length()):
		var c: String = line[i]
		if not SPEAKABLE.contains(c):
			# Report the code point: an emoji or a curly quote is invisible in
			# a terminal diff, and the number is what a writer can search for.
			if not bad.contains(c):
				bad += "%s(U+%04X) " % [c, c.unicode_at(0)]
	return bad.strip_edges()


# ---- the API's own promises --------------------------------------------------

func _every_advertised_beat_has_data() -> void:
	print("\n-- every advertised beat has lines --")
	var beats: PackedStringArray = StoryS.beats()
	check("the module advertises its beats", beats.size() >= 5,
		"%d beats" % beats.size())

	# Walk the DISPATCHER, not the tables. A beat added to BEATS whose data was
	# never written, or whose case was never added to lines(), is this module's
	# one structural failure mode and it is invisible from the tables.
	var dead: Array = []
	for beat in beats:
		var got: int = 0
		for act in range(StoryS.ACT_COUNT):
			got += StoryS.lines(beat, act).size()
		if got == 0:
			dead.append(beat)
	check("every beat in BEATS returns lines", dead.is_empty(),
		", ".join(dead))

	# And the other direction: the beats the brief asked for are all present,
	# so a rename cannot quietly drop one.
	var required: PackedStringArray = [
		"act_open", "act_close", "boss_taunt", "first_death", "region_flavour",
	]
	var missing: Array = []
	for r in required:
		if not beats.has(r):
			missing.append(r)
	check("every beat the brief asked for is advertised", missing.is_empty(),
		", ".join(missing))

	# An unknown beat must come back empty rather than throw: the HUD asks for
	# beats by string and a typo there should drop a subtitle, not a run.
	check("an unknown beat returns nothing",
		StoryS.lines("no_such_beat", 0).is_empty())

	var no_proto: Array = []
	for entry in _all_lines():
		var low: String = String(entry[1]).to_lower()
		for w in GENDERED:
			# Whole words only: "shore" must not trip on "he".
			for sep in [" %s " % w, " %s," % w, " %s." % w]:
				if (" " + low + " ").contains(sep):
					no_proto.append("%s says %s" % [entry[0], w])
					break
		for t in FORMAT_TOKENS:
			if String(entry[1]).contains(t):
				no_proto.append("%s has %s" % [entry[0], t])
	check("no line gives the walker a name or a gender", no_proto.is_empty(),
		", ".join(no_proto))


# ---- flavour is attached to real ground --------------------------------------

func _flavour_sits_on_the_ground() -> void:
	print("\n-- flavour describes the map it plays on --")
	var idx: PackedInt32Array = StoryS.flavour_indices()
	check("some maps carry flavour", idx.size() >= 8, "%d maps" % idx.size())

	var out_of_range: Array = []
	var floating: Array = []
	for i in idx:
		if i < 0 or i >= CampaignS.map_count():
			out_of_range.append(str(i))
			continue
		# A flavour line names the ground, so it may only sit where the ground
		# changes — the first map of a biome run — or on an act finale, which
		# is the colosseum the act has been climbing towards. Anywhere else and
		# the line is read out over scenery it is not describing.
		var fresh: bool = i == 0 or (CampaignS.biome_at(i)
			!= CampaignS.biome_at(i - 1))
		var finale: bool = CampaignS.stage_in_act(i) == CampaignS.maps_per_act() - 1
		if not (fresh or finale):
			floating.append("map %d is mid %s" % [i + 1, CampaignS.biome_at(i)])

	check("every flavour map exists", out_of_range.is_empty(),
		", ".join(out_of_range))
	check("every flavour line sits on new ground or a finale",
		floating.is_empty(), ", ".join(floating))

	# The dispatcher and the direct getter must agree, or a caller that went
	# through one and a tool that went through the other disagree about which
	# maps speak.
	var disagree: Array = []
	for i in range(CampaignS.map_count()):
		var direct: String = StoryS.region_flavour(i)
		var via: PackedStringArray = StoryS.lines("region_flavour", 0, i)
		var want: int = 1 if direct != "" else 0
		if via.size() != want or (want == 1 and via[0] != direct):
			disagree.append(str(i + 1))
		if StoryS.has_region_flavour(i) != (direct != ""):
			disagree.append("has %d" % (i + 1))
	check("region_flavour agrees with the dispatcher and has_",
		disagree.is_empty(), ", ".join(disagree))

	check("a map with nothing to say says nothing",
		StoryS.region_flavour(1) == "" and not StoryS.has_region_flavour(1))


# ---- lookups never take down a run ------------------------------------------

func _lookups_are_safe() -> void:
	print("\n-- a bad lookup reads the nearest act --")
	# Story lines are cosmetic. A caller that is one act out — Campaign.act_of
	# on a map index that has not been clamped yet, say — must get the nearest
	# act's words, never an index error in the middle of a boss fight.
	check("act -1 reads as the first act",
		StoryS.act_open(-1)[0] == StoryS.act_open(0)[0])
	check("act 99 reads as the last act",
		StoryS.act_close(99)[0] == StoryS.act_close(StoryS.ACT_COUNT - 1)[0])
	check("boss lookups clamp too",
		StoryS.boss_taunt(-5) == StoryS.boss_taunt(0)
		and StoryS.boss_taunt(50) == StoryS.boss_taunt(StoryS.ACT_COUNT - 1))
	check("a flavour lookup off the map is empty, not an error",
		StoryS.region_flavour(-1) == "" and StoryS.region_flavour(10_000) == "")


# ---- the ending has to land on the colosseum --------------------------------

func _the_ending_lands() -> void:
	print("\n-- the payoff is the crown in the colosseum --")
	# The brief: act 10 is The Shattered Crown and map 100 is the largest arena
	# the game builds, so the ending pays off THERE. These assert the words are
	# actually about that place, because an ending rewritten to be about a dark
	# lord somewhere else would otherwise pass every other check in this file.
	var last_act: int = StoryS.ACT_COUNT - 1
	var open_text: String = " ".join(StoryS.act_open(last_act)).to_lower()
	var close_text: String = " ".join(StoryS.act_close(last_act)).to_lower()
	var final_map: String = StoryS.region_flavour(
		CampaignS.map_count() - 1).to_lower()

	check("the last act opens on the citadel and its ring",
		open_text.contains("marble") and (open_text.contains("ring")
			or open_text.contains("seats")), open_text.left(40))
	check("the last act closes on the crown",
		close_text.contains("crown"))
	check("the ending offers the choice the Trail is about",
		close_text.contains("put it on") or close_text.contains("wear"),
		"whoever wears it becomes the next gate")
	check("the final map says it is built for an audience",
		final_map.contains("audience"), final_map)
	check("the campaign still ends where the story says it does",
		CampaignS.biome_at(CampaignS.map_count() - 1) == "throne",
		CampaignS.biome_at(CampaignS.map_count() - 1))


# ---- helpers -----------------------------------------------------------------

## Every line the module can produce, each tagged with where it came from so a
## failure names the line instead of printing a number.
func _all_lines() -> Array:
	var out: Array = []
	for act in range(StoryS.ACT_COUNT):
		var n: int = 0
		for l in StoryS.act_open(act):
			out.append(["act %d open %d" % [act + 1, n], l]); n += 1
		n = 0
		for l in StoryS.act_close(act):
			out.append(["act %d close %d" % [act + 1, n], l]); n += 1
		out.append(["act %d boss" % (act + 1), StoryS.boss_taunt(act)])
	out.append(["first death", StoryS.first_death()])
	for i in StoryS.flavour_indices():
		out.append(["map %d flavour" % (i + 1), StoryS.region_flavour(i)])
	return out
