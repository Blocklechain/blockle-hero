class_name GameMode
extends RefCounted
# ------------------------------------------------------------------------------
# WHAT KIND OF RUN THIS IS.
#
# The campaign is a hundred maps with a gate between each one. That is the
# spine of the game and it should stay the spine — but it is also the ONLY
# thing to do, and it is strictly linear, so a player who wants one more fight
# before bed has to pick up where they left off at whatever difficulty they
# left it.
#
# These two modes were chosen because they are almost entirely made of parts
# that already exist and were already tested. Neither needs a server, netcode,
# new art, or a new scene:
#
#   DESCENT   Endless waves in one arena. Encounter's ring placement already
#             surrounds the player with a scaled pack — that IS a wave
#             spawner, it had simply never been asked twice. Campaign's
#             difficulty curves already take an index, so depth just keeps
#             feeding it one. Ends when you die; the score is how deep you got.
#
#   GAUNTLET  Boss after boss, no trash. Every region already generates a
#             titled boss scaled to its index, so a gauntlet is that generator
#             called ten times with the index climbing. It is also the mode
#             that showcases the slam, now that the slam is dodgeable.
#
# Deliberately NOT chosen, and why, so the next person does not assume they
# were forgotten: arena PvP (Layout.Sym.ROTATIONAL exists and is unused, but
# PvP is netcode, matchmaking and a cheat surface — a whole product); daily
# challenges (the generation is already deterministic enough, but a daily
# without a leaderboard is just a seed, and a leaderboard is a backend).
#
# EVERY RULE HERE IS PURE AND STATIC so modetest.gd can check the shape of a
# run without building a world.
# ------------------------------------------------------------------------------

# Preloaded by path, not by class_name: a newly added script is absent from
# Godot's global class cache until the editor reimports, and every headless
# harness would fail to parse until someone opened the project.
const MapShape := preload("res://scripts/game/MapShape.gd")

enum Id { CAMPAIGN, DESCENT, GAUNTLET }

## How many bosses a gauntlet is. Ten is long enough to be a run and short
## enough to finish in one sitting on a phone.
const GAUNTLET_BOSSES: int = 10

## Waves in a descent before the difficulty stops borrowing campaign indices
## and starts compounding instead. See scaling_index().
const DESCENT_RAMP: int = 40

## Extra multiplier per wave once a descent has run out of campaign to borrow.
## Small, because it compounds — at 6% a wave, wave 80 is about 10x wave 40.
const DESCENT_COMPOUND: float = 0.06


static func all() -> Array[int]:
	return [Id.CAMPAIGN, Id.DESCENT, Id.GAUNTLET]


static func name_of(id: int) -> String:
	match id:
		Id.DESCENT: return "Descent"
		Id.GAUNTLET: return "Gauntlet"
		_: return "Campaign"


static func blurb_of(id: int) -> String:
	match id:
		Id.DESCENT:
			return "Waves without end. Last as long as you can."
		Id.GAUNTLET:
			return "%d bosses, back to back, and nothing in between." \
				% GAUNTLET_BOSSES
		_:
			return "A hundred maps, one at a time."


## True when the run has no finish line and ends only in death.
static func is_endless(id: int) -> bool:
	return id == Id.DESCENT


## How many waves a run contains. 0 means endless.
##
## The campaign is one "wave" in this vocabulary: its map has a pack layout
## and a boss, and clearing it ends the run.
static func wave_count(id: int) -> int:
	match id:
		Id.DESCENT: return 0
		Id.GAUNTLET: return GAUNTLET_BOSSES
		_: return 1


## Is this wave the last one? Always false for an endless mode.
static func is_final_wave(id: int, wave: int) -> bool:
	var n: int = wave_count(id)
	return n > 0 and wave >= n - 1


## Does this wave consist only of a boss?
static func boss_only(id: int, _wave: int) -> bool:
	return id == Id.GAUNTLET


## WHICH CAMPAIGN INDEX'S DIFFICULTY THIS WAVE BORROWS.
##
## Rather than invent a second balance curve, a wave reuses the one the
## campaign already has — enemy level, health and damage multipliers, elite
## rate, loot odds all come free and stay consistent with what the player
## already understands. A gauntlet walks the whole campaign in ten steps so
## its bosses are drawn from across the game rather than all from the shallows.
static func scaling_index(id: int, wave: int) -> int:
	var last: int = Campaign.map_count() - 1
	match id:
		Id.GAUNTLET:
			var n: int = maxi(GAUNTLET_BOSSES - 1, 1)
			return clampi(int(round(float(wave) * float(last) / float(n))),
				0, last)
		Id.DESCENT:
			# Two and a half campaign maps of difficulty per wave, so a
			# descent reaches the deep end in about DESCENT_RAMP waves
			# rather than in a hundred.
			return clampi(int(float(wave) * float(last)
				/ float(maxi(DESCENT_RAMP, 1))), 0, last)
		_:
			return clampi(wave, 0, last)


## Difficulty beyond the end of the campaign's own curve.
##
## A descent cannot stop getting harder at wave 40 just because the campaign
## ran out of maps — an endless mode whose difficulty plateaus is a mode that
## ends in boredom rather than in death. Past the ramp, every further wave
## compounds on top of whatever the last campaign index gave.
##
## Returns 1.0 while there is still campaign curve left to borrow, so the
## early waves are exactly as hard as the maps they mirror.
static func overdrive(id: int, wave: int) -> float:
	if id != Id.DESCENT:
		return 1.0
	var over: int = wave - DESCENT_RAMP
	if over <= 0:
		return 1.0
	return pow(1.0 + DESCENT_COMPOUND, float(over))


## The map form a run is played on.
##
## Descents and gauntlets are fought in ONE place rather than travelled
## through, so both want an arena rather than a lane — a spine you cannot
## advance down is just a corridor you back up. The colosseum is the biggest
## one and is already the campaign's act finale, which makes it read as an
## occasion.
static func shape_of(id: int) -> Dictionary:
	match id:
		Id.DESCENT, Id.GAUNTLET:
			return MapShape.finale()
		_:
			return {}


## What to call the thing the player is fighting through, for the HUD.
static func wave_label(id: int, wave: int) -> String:
	match id:
		Id.DESCENT: return "Depth %d" % (wave + 1)
		Id.GAUNTLET: return "Crown %d of %d" % [wave + 1, GAUNTLET_BOSSES]
		_: return ""


## Where a run's record is kept, so Roster does not need a case per mode.
static func record_key(id: int) -> String:
	match id:
		Id.DESCENT: return "best_descent"
		Id.GAUNTLET: return "best_gauntlet"
		_: return ""
