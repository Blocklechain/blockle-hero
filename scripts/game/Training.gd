class_name Training
extends RefCounted
# ------------------------------------------------------------------------------
# CHAMPIONS WHO GET BETTER WHILE THE APP IS SHUT.
#
# A roster of 139 champions and one of them gets played. The other 138 sit at
# level 1 forever, so trying a different class means grinding it back up from
# nothing, which is why nobody does. Training is the answer to that and not
# to anything else: it is a way for the bench to stay worth fielding, NOT a
# second way to play the game.
#
# That distinction is the whole balance. If a slot out-earns an actual run,
# the correct strategy becomes closing the app, and the game has been
# replaced by a timer. So the rate is deliberately a slow fraction of a
# level, and the accrual CAPS — a slot is a reason to come back tomorrow, not
# a reason to leave it running for a fortnight.
#
# ------------------------------------------------------------------------------
# THE CLOCK IS NOT TRUSTWORTHY, and this is the part worth reading.
#
# Offline progression is measured against the device clock, which the player
# controls completely. Set it forward a year and naive code hands out a
# year of XP. There is no honest way to prevent this on-device — proving
# elapsed time needs a server we do not have — so the goal is to BOUND it
# rather than to pretend:
#
#   * Accrual caps at CAP_HOURS. The most any amount of clock-winding can
#     ever yield is one capped slot, which is also exactly what an honest
#     player gets for waiting. So the exploit buys impatience, not power.
#   * A clock that moves BACKWARDS is detected and the slot re-anchored,
#     rather than banking a negative or a huge elapsed. Travelling across a
#     timezone must not corrupt a save.
#   * The highest timestamp ever seen is remembered, so winding forward and
#     back again does not reset the cap and let the trick be repeated.
#
# None of that is DRM and it is not trying to be. It makes cheating pointless
# rather than impossible, which for a single-player ARPG is the right place
# to stop.
# ------------------------------------------------------------------------------

## How many slots a player can ever have. Four is enough to keep a party's
## worth of alternates warm without making the menu the game.
const SLOTS_MAX: int = 4

## The first slot is free — a feature nobody can try is a feature nobody
## asks for. The rest cost gold, rising steeply enough to be a goal.
const SLOT_COSTS: PackedInt32Array = [0, 2500, 9000, 25000]

## Hours of accrual a slot holds before it stops counting. Eight is a
## night's sleep: check in the next morning and nothing was wasted.
const CAP_HOURS: float = 8.0

## Share of ONE LEVEL a champion trains per hour, measured against its own
## next-level requirement so a level 50 and a level 5 both progress at a
## rate that means something to them.
##
## At 0.06, a full capped slot is just under half a level. Two check-ins a
## day is roughly a level, against a few minutes of actual play for the
## same — which is the ratio that keeps playing the better option.
const XP_PER_HOUR: float = 0.06

## Below this, a slot reports nothing to claim rather than a rounding error.
const MIN_CLAIM_XP: float = 1.0


## Seconds that actually count toward training, out of a raw elapsed.
##
## Negative means the clock went backwards; that is zero, never a rollover
## into something enormous.
static func countable_seconds(elapsed: float) -> float:
	if elapsed <= 0.0:
		return 0.0
	return minf(elapsed, CAP_HOURS * 3600.0)


## XP a champion of this level earns for a span of countable seconds.
##
## Scaled to the champion's OWN next-level cost, so training is neither
## useless at high level nor absurd at low.
static func xp_for(progress: HeroProgress, seconds: float) -> float:
	if progress == null or progress.level >= HeroProgress.MAX_LEVEL:
		return 0.0
	var hours: float = countable_seconds(seconds) / 3600.0
	return progress.xp_to_next() * XP_PER_HOUR * hours


## Is a slot full? Used to tell the player there is nothing more to gain by
## leaving it, which is the honest version of a progress bar that silently
## stopped.
static func is_full(elapsed: float) -> bool:
	return elapsed >= CAP_HOURS * 3600.0


## 0..1 of the way to a full slot.
static func fill(elapsed: float) -> float:
	return clampf(elapsed / (CAP_HOURS * 3600.0), 0.0, 1.0)


## Cost of unlocking the slot at [index], or -1 if there is no such slot.
static func cost_of(index: int) -> int:
	if index < 0 or index >= SLOTS_MAX:
		return -1
	return SLOT_COSTS[index]


## Human text for how long is left before a slot stops earning.
static func remaining_text(elapsed: float) -> String:
	var left: float = CAP_HOURS * 3600.0 - elapsed
	if left <= 0.0:
		return "Full"
	var h: int = int(left / 3600.0)
	var m: int = int(fmod(left, 3600.0) / 60.0)
	if h > 0:
		return "%dh %02dm until full" % [h, m]
	return "%dm until full" % m


# ------------------------------------------------------------------------------
# A slot
# ------------------------------------------------------------------------------

## One training slot: which champion is in it and when they started.
class Slot:
	extends RefCounted

	var hero: String = ""
	## Unix seconds when the current stretch began. 0 = empty.
	var since: int = 0
	## The highest clock reading this slot has ever been evaluated against.
	## Winding the clock forward and back must not reset the cap.
	var high_water: int = 0

	func is_empty() -> bool:
		return hero.is_empty() or since <= 0

	## Raw elapsed, with the clock treated as hostile.
	##
	## Returns [seconds, rewound] — `rewound` says the device clock reads
	## earlier than this slot has already seen, so the caller re-anchors
	## instead of banking anything.
	func elapsed_at(now: int) -> Array:
		if is_empty():
			return [0.0, false]
		# Measure from the LATER of "when it started" and "the furthest the
		# clock has ever been". Without the high-water mark, winding forward
		# to fill a slot and then back again would leave `since` in the past
		# and hand out the same capped stretch over and over.
		var anchor: int = since
		if now < high_water:
			return [0.0, true]
		return [float(now - anchor), false]

	func to_dict() -> Dictionary:
		return {"hero": hero, "since": since, "high": high_water}

	static func from_dict(d: Dictionary) -> Slot:
		var s := Slot.new()
		s.hero = String(d.get("hero", ""))
		s.since = int(d.get("since", 0))
		s.high_water = int(d.get("high", 0))
		return s
