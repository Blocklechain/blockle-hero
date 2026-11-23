extends RefCounted
# ------------------------------------------------------------------------------
# THE STORY, AS DATA.
#
# Consumers must take this by path:
#
#     const StoryS := preload("res://scripts/game/Story.gd")
#
# and never by a bare class_name. This file deliberately declares none. A
# class_name added outside the editor is not in Godot's global cache, so every
# consumer referring to it fails to PARSE, and the failure surfaces in whatever
# unrelated harness happens to load that consumer first. That has cost this
# project four debugging sessions; see tools/classcheck.gd.
#
# WHY A DATA MODULE AND NOT PROSE IN THE CALLERS. The lines have to be
# auditable in bulk, because they are spoken: a stray em dash, an ellipsis
# character, a piece of UI markup or an emoji reaches the player as a mangled
# syllable or a read-aloud "asterisk". Keeping every line in one table lets
# tools/storytest.gd walk all of them and enforce that. Prose scattered through
# Play.gd and Hud.gd could not be checked at all.
#
# ------------------------------------------------------------------------------
# THE SPINE (full version in docs/STORY.md — do not contradict it).
#
# THERE IS NO PROTAGONIST. The player fields any of 139 champions and swaps
# them between runs, so no line may name, gender, or characterise the walker.
# The subject of this story is THE ROAD. Second person at most.
#
# The Trail is a hundred maps long and ends at a broken crown. It was broken so
# no one could hold it whole, and its ten pieces were set at ten rings along the
# road. Whoever reaches a ring holds it. That is canon the code already tells
# you: every pack on the Trail is champions (Encounter.gd), every boss is a
# champion from the same roster scaled up and titled Warden of the Pass, the
# Iron Crown, the Hollow King (Encounter._BOSS_TITLES), and every act ends in a
# colosseum (MapShape.finale()). The enemies are not monsters. They are the
# people who walked this road before you and stopped where they stopped.
#
# THE DREAD CURVE IS THE STORY. Campaign.dread() climbs 0 to 99% across the
# hundred maps, and the biomes march from a late-afternoon wood to a tear in the
# world. The reason is not that the road gets more evil: it is that it gets
# further from anything that has a name for you. Act 1 has keepers, fields and
# weather. Act 7 has no living witnesses. Act 9 is not natural at all. So the
# early lines are spoken like directions and the late ones like evidence.
#
# THE ENDING LANDS ON THE COLOSSEUM, not on a dark lord. Map 100 is the largest
# arena the game builds, in the throne biome, gold and marble, blurb "Ground
# made for an audience". Arriving with all ten shards makes the crown whole, and
# the only question the Trail has ever asked is whether someone puts it on —
# because the one who does becomes the next gate, and the road stays full. That
# is also why the campaign is replayable at eight difficulties: it is diegetic.
# ------------------------------------------------------------------------------

## Acts, matching Campaign.ACT_COUNT. Kept as a literal rather than reading
## Campaign so a story lookup cannot drag the campaign tables into a text-only
## caller, and so storytest runs without the world.
const ACT_COUNT: int = 10

## Beat names this module advertises. storytest.gd walks these through lines()
## and fails on any beat with nothing behind it — which is the failure mode of a
## table like this one: a beat gets named in the API and the data never arrives.
##
## Written as a bare array literal. GDScript will NOT constant-fold a
## `PackedStringArray(...)` constructor call in a const, and the parse error it
## raises is only found when something loads the file. Encounter._BOSS_TITLES
## shipped broken for exactly this reason.
const BEATS: PackedStringArray = [
	"act_open", "act_close", "boss_taunt", "first_death", "region_flavour",
]

## Spoken-length ceiling, in characters. Two lines of this is about eleven
## seconds of speech, which is the most a player mid-run will sit through before
## they start walking and talk over it.
const MAX_SPOKEN: int = 180


# ---- act openings ------------------------------------------------------------
# Two lines each. The first names the place and its weather, the second tells
# you what the road does with you here. No act opening may describe the walker.
const _OPEN: Array = [
	[
		"This is the Trail of Heroes, and it starts in somebody's woods on an ordinary afternoon.",
		"Walk it far enough and it ends at a broken crown. Nobody has walked it that far and come back.",
	],
	[
		"The Broken Shore. Salt wind, and cliffs chewed down to teeth with the road running along the top of them.",
		"Keep the sea on your left. It finishes in a moor so thick you will hear the next ring before you see it.",
	],
	[
		"The Long Dark. The last autumn woods on the Trail, and then the cold comes up to meet you.",
		"Count the rings behind you rather than the ones ahead. The fog here is honest about nothing else.",
	],
	[
		"The Howling Reach. Drowned moor first, then high ground where the lightning picks its own targets.",
		"Nothing here especially wants to fight you. The weather will do it for free.",
	],
	[
		"Under Dusk. Half the Trail is behind you, and this is where the daylight gives up for good.",
		"Everything that glows from here on is alive, and none of it is glowing for your benefit.",
	],
	[
		"The Thornfields. The road is still under you, somewhere beneath the brambles that grew over it.",
		"Fewer feet come this way every year, and you can measure that in thorns.",
	],
	[
		"The Bone Marches. This is where the Trail stops hiding what it does with the people who walk it.",
		"Every one of them was a champion. A good many of them were better than the one you brought.",
	],
	[
		"The Ash Hollows. The road runs under the world now, through ash that was somewhere else before it burned.",
		"Keep going down. There is a light at the far end of it with no business being there.",
	],
	[
		"The Glass Wastes. Bone, then crystal, then black rock with fire running through it like water.",
		"None of this was made by weather. Past here the world stops bothering to look real.",
	],
	[
		"The Shattered Crown. Beyond the last tear in the world there is gold, and marble, and a city with nobody in it.",
		"At the end of it is a ring with seats for a hundred thousand, and every champion who stopped is in them.",
	],
]


# ---- act closings ------------------------------------------------------------
# Spoken over the act boss going down in the colosseum. These must deliver a
# CONSEQUENCE: a shard taken, and the road's next demand. The count of rings is
# the player's progress read back to them, which is the only scoreboard the
# fiction has.
const _CLOSE: Array = [
	[
		"One ring, one piece of the crown.",
		"Past this gate the road leaves everything that has a keeper, and nothing out there will ask your name again.",
	],
	[
		"Two pieces, and the sea is behind you for good.",
		"The Trail only runs inland from here, which is the direction that does not grow back.",
	],
	[
		"Three. The light that was going is gone now, and it does not come back on this road.",
	],
	[
		"Four, and the storms thin out past this gate. That is not mercy.",
		"What comes after the weather is the dusk, and the dusk does not lift.",
	],
	[
		"Five pieces. Halfway, and further along the Trail than all but a handful have ever stood.",
		"Everyone ahead of you stopped because they were the best there was.",
	],
	[
		"Six. Past this ring is the ash, where nothing grows at all.",
		"You will miss the thorns.",
	],
	[
		"Seven, taken off a champion who outlived a whole field of them.",
		"The marches end at a hole in the world, and the road goes down it.",
	],
	[
		"Eight. That light in the rock was the crown, bleeding through from the far end of the road.",
		"You are close enough now that the Trail has started showing you things on purpose.",
	],
	[
		"Nine. One piece left, and the ground ahead is a tear with a city on the other side of it.",
	],
	[
		"The crown is whole in your hands, and the colosseum is louder than the whole road was long.",
		"Put it on and the Trail starts again at your gate. Leave it broken on the sand and the road is finally over.",
	],
]


# ---- boss greetings ----------------------------------------------------------
# One line, in the boss's voice. The boss is a champion from the same roster the
# player draws from, who reached this ring and stayed to hold it, so these are
# not threats from a monster. They are what someone says after years of standing
# in one place. The voice hardens as the acts go on because the ones further
# along gave up more to get there.
const _TAUNT: Array = [
	"I stopped here, while it was still pretty. Stop with me and we can both be the ones who lived.",
	"I held this edge eleven years and the sea took everything else. Leave me the ring.",
	"You still walk like somebody expecting morning. I used to do that too.",
	"Hear it? That is the sky doing my work. Stand still and let it finish.",
	"I came this far on the second day of a very good year. Nobody is coming for either of us.",
	"I cut this road open for a mile and a half. Count it. That was my whole life.",
	"I did not kill one of them. The road did. All I ever did was stay.",
	"Down here I can hear it humming. Eight pieces of a crown, and every one of them wants you to keep walking.",
	"I was first into the Wastes. First is not the same as through.",
	"I wore it for one afternoon. Take it off me and you will understand why the road is still full.",
]


# ---- the first death ---------------------------------------------------------
# Shown once, the first time a champion dies. NOT mocking, and not consoling
# either: it has to make the swap diegetic, because the player is about to pick
# somebody else out of a roster of 139 and the game should not pretend that is
# a defeat screen.
const _FIRST_DEATH: String = "That is what the Trail costs, and it has been paid by better. Choose who walks next. Your place on the road is kept."


# ---- region flavour ----------------------------------------------------------
# Optional, keyed by 0-based map index. Only maps where the ground CHANGES get
# one, because a line on every map becomes noise the player learns to ignore and
# then misses the act beats inside. The indices are the biome boundaries
# Campaign.biome_at() actually produces, so each line describes the ground the
# player is standing on. If you move the biome bands, move these.
const _FLAVOUR: Dictionary = {
	0: "Somebody's woods, with a gate at the end of them and ninety nine more after that.",
	3: "The cliffs along here are called the first teeth. They are not the last teeth.",
	5: "Autumn, with ash coming down through it from a fire nobody has ever found.",
	8: "Thin air. Breathe twice for every step up here and you will keep your hands.",
	18: "Drowned ground, and fog that hands you back your own footsteps.",
	28: "High and bare, and the lightning has nothing else out here to aim at.",
	35: "Violet light with no sun behind it. This is as bright as the rest of the Trail gets.",
	38: "Black water, black trees, and something underneath both of them keeping time.",
	48: "Brambles the colour of dried blood. The gaps between them are the road.",
	58: "Grey all the way out. Nothing has grown here since the crown was broken.",
	65: "A field of the dead under a sick light. A few of them are still holding their ground.",
	68: "The road goes under the world at this point, and the world closes over the top of it.",
	78: "Crystal, and a light coming out of it that no fire anybody owns could make.",
	88: "Black rock, with fire running in the cracks like it has somewhere to be.",
	95: "A tear in the world, and the road going straight through the middle of it.",
	98: "Gold, marble, open gates. The citadel was built to be walked into.",
	99: "The last ring. Ground made for an audience, and the audience came.",
}


# ---- API ---------------------------------------------------------------------

## Beats this module can produce lines for. Walk this rather than hardcoding
## beat names at the call site.
static func beats() -> PackedStringArray:
	return BEATS


## The first map of an act. Two lines, place then road.
static func act_open(act: int) -> PackedStringArray:
	return PackedStringArray(_OPEN[_act(act)])


## The act's boss is down. One or two lines of consequence.
static func act_close(act: int) -> PackedStringArray:
	return PackedStringArray(_CLOSE[_act(act)])


## What the act boss says when it notices you. One line.
static func boss_taunt(act: int) -> String:
	return _TAUNT[_act(act)]


## Shown once, on the first champion lost.
static func first_death() -> String:
	return _FIRST_DEATH


## An optional one-liner for map [index], 0-based. Empty when this map has
## nothing to say, which is most of them — callers must handle "".
static func region_flavour(index: int) -> String:
	return String(_FLAVOUR.get(index, ""))


## Does map [index] have flavour? Saves the caller comparing against "" and
## getting it subtly wrong with is_empty on a null.
static func has_region_flavour(index: int) -> bool:
	return _FLAVOUR.has(index)


## Every line for one beat, as a list. The single dispatcher every consumer and
## the harness go through, so a beat cannot be advertised in BEATS and then have
## no data: that mismatch is a test failure here rather than a silent empty
## subtitle in front of a player.
##
## [param act] is required by the per-act beats, [param index] by
## region_flavour. The beats that ignore an argument ignore it.
static func lines(beat: String, act: int = 0, index: int = -1) -> PackedStringArray:
	match beat:
		"act_open":
			return act_open(act)
		"act_close":
			return act_close(act)
		"boss_taunt":
			return PackedStringArray([boss_taunt(act)])
		"first_death":
			return PackedStringArray([first_death()])
		"region_flavour":
			# Asked for a specific map: that map's line, if it has one. Asked
			# for the beat in general (no index): everything the beat holds, so
			# the harness can audit lines no single map index would reveal.
			if index >= 0:
				var one: String = region_flavour(index)
				return PackedStringArray([one] if one != "" else [])
			var all: Array = []
			for k in _FLAVOUR.keys():
				all.append(String(_FLAVOUR[k]))
			return PackedStringArray(all)
	return PackedStringArray()


## Map indices carrying flavour, ascending. For an editor or a shot tool that
## wants to visit them.
static func flavour_indices() -> PackedInt32Array:
	var out: Array = _FLAVOUR.keys().duplicate()
	out.sort()
	return PackedInt32Array(out)


## Clamped rather than asserted: a story line is cosmetic, and an off-by-one act
## from a caller should read the nearest act, never take down the run.
static func _act(act: int) -> int:
	return clampi(act, 0, ACT_COUNT - 1)
