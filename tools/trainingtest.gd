extends SceneTree
# ------------------------------------------------------------------------------
# OFFLINE TRAINING, AND THE FACT THAT THE CLOCK LIES.
#
# Training pays XP for wall-clock time while the app is shut. The device
# clock is entirely under the player's control, so the interesting tests are
# not "does it accrue" — they are what happens when someone winds it.
#
# There is no honest way to PREVENT clock-winding without a server. The goal
# is to bound it: the most any amount of winding can yield is one capped
# slot, which is exactly what waiting honestly yields. So the exploit buys
# impatience rather than power, and that bound is what these pin.
#
# The other half is balance. If a slot out-earns a run, the best strategy
# becomes closing the game, and a timer has replaced the ARPG.
# ------------------------------------------------------------------------------

const TrainingS := preload("res://scripts/game/Training.gd")

const HOUR: int = 3600
var _fails: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _roster() -> Roster:
	var r := Roster.new()
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	for i in range(3):
		r.owned[heroes[i]] = HeroProgress.create(heroes[i])
	return r


## Sections that reached their end. A runtime error inside one aborts that
## function silently and GDScript carries on, so without this a crash reads
## as "0 failures" — which is exactly what happened the first time this ran.
var _done: int = 0

func _init() -> void:
	_accrual(); _done += 1
	_the_clock(); _done += 1
	_slots(); _done += 1
	_persistence(); _done += 1
	_balance(); _done += 1
	print("")
	check("every section ran to completion", _done == 5,
		"%d of 5" % _done)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ---- it accrues, and it stops ------------------------------------------------

func _accrual() -> void:
	print("\n=== accrual ===")
	var r := _roster()
	var who: String = r.owned.keys()[0]
	var t0: int = 1_700_000_000

	check("a slot starts empty", r.slot(0).is_empty())
	check("putting a champion in starts the clock",
		r.begin_training(0, who, t0) and not r.slot(0).is_empty())

	check("nothing is owed immediately",
		r.pending_training(0, t0) == 0.0)

	var four: float = r.pending_training(0, t0 + 4 * HOUR)
	check("four hours is worth something", four > 0.0, "%.0f xp" % four)

	# THE CAP. Past it, waiting longer must pay nothing more, or the
	# feature is "leave the app shut for a month".
	var at_cap: float = r.pending_training(0, t0 + int(TrainingS.CAP_HOURS) * HOUR)
	var way_past: float = r.pending_training(0, t0 + 400 * HOUR)
	check("accrual stops at the cap",
		is_equal_approx(at_cap, way_past),
		"%.0f at cap vs %.0f after 400h" % [at_cap, way_past])
	check("...and the cap is more than four hours' worth", at_cap > four)

	# Claiming banks it and restarts.
	var before: int = r.progress(who).level
	var before_xp: float = r.progress(who).xp
	var paid: float = r.claim_training(0, t0 + 400 * HOUR)
	check("claiming pays out", paid > 0.0, "%.0f xp" % paid)
	check("...and the champion actually has it",
		r.progress(who).level > before or r.progress(who).xp > before_xp)
	check("...and claiming again immediately pays nothing",
		r.claim_training(0, t0 + 400 * HOUR) == 0.0)

	# No rollover: a capped slot that is claimed does not keep paying out
	# the uncounted remainder.
	var after_claim: float = r.pending_training(0, t0 + 401 * HOUR)
	check("a claimed slot restarts from now, it does not roll over",
		after_claim < at_cap, "%.0f vs %.0f at cap" % [after_claim, at_cap])

	# A maxed champion earns nothing rather than erroring.
	var maxed := HeroProgress.create("x")
	maxed.level = HeroProgress.MAX_LEVEL
	check("a champion at max level earns nothing",
		TrainingS.xp_for(maxed, 100.0 * float(HOUR)) == 0.0)


# ---- the clock is hostile ----------------------------------------------------

func _the_clock() -> void:
	print("\n=== the clock cannot be trusted ===")
	var r := _roster()
	var who: String = r.owned.keys()[0]
	var t0: int = 1_700_000_000
	r.begin_training(0, who, t0)

	# WINDING FORWARD is bounded by the cap, not prevented. A year buys
	# exactly what a night buys.
	var night: float = r.pending_training(0, t0 + 8 * HOUR)
	var year: float = r.pending_training(0, t0 + 24 * 365 * HOUR)
	check("winding the clock a YEAR pays the same as one night",
		is_equal_approx(night, year),
		"%.0f vs %.0f xp" % [night, year])

	# WINDING BACK must not bank a negative, crash, or pay out.
	var r2 := _roster()
	var who2: String = r2.owned.keys()[0]
	r2.begin_training(0, who2, t0)
	var back: float = r2.pending_training(0, t0 - 50 * HOUR)
	check("a clock that moved backwards owes nothing, not a negative",
		back == 0.0, "%.1f" % back)
	var lvl_before: int = r2.progress(who2).level
	var xp_before: float = r2.progress(who2).xp
	r2.claim_training(0, t0 - 50 * HOUR)
	check("...and claiming on a rewound clock changes nothing",
		r2.progress(who2).level == lvl_before
			and is_equal_approx(r2.progress(who2).xp, xp_before))
	check("...but the slot re-anchors rather than staying broken",
		r2.slot(0).since == t0 - 50 * HOUR)

	# FORWARD THEN BACK is the repeatable version of the exploit: fill the
	# slot, claim, wind back, fill again. The high-water mark is what stops
	# the second fill.
	var r3 := _roster()
	var who3: String = r3.owned.keys()[0]
	r3.begin_training(0, who3, t0)
	var first: float = r3.claim_training(0, t0 + 400 * HOUR)
	check("wind forward and claim once", first > 0.0, "%.0f xp" % first)
	var second: float = r3.claim_training(0, t0 + 10 * HOUR)
	check("...then wind BACK and the second claim pays nothing",
		second == 0.0, "%.0f xp" % second)


# ---- slots -------------------------------------------------------------------

func _slots() -> void:
	print("\n=== slots ===")
	var r := _roster()
	var heroes: Array = r.owned.keys()

	check("the first slot is free and already open",
		r.slot_is_unlocked(0) and TrainingS.cost_of(0) == 0)
	check("...and the rest are not", not r.slot_is_unlocked(1))

	check("an unopened slot cannot be used",
		not r.begin_training(1, String(heroes[0]), 1))

	# Buying needs the gold.
	check("a slot cannot be bought without the gold", not r.unlock_slot())
	r.wallet.grant(Wallet.Kind.GOLD, TrainingS.cost_of(1), "test")
	check("...and can be with it", r.unlock_slot())
	check("...which opens it", r.slot_is_unlocked(1))

	# ONE SLOT PER CHAMPION, or two slots stack and the cap is not a cap.
	var who: String = String(heroes[0])
	check("a champion can be put in a slot", r.begin_training(0, who, 1))
	check("...but not in two at once", not r.begin_training(1, who, 1))
	check("...while a different champion is fine",
		r.begin_training(1, String(heroes[1]), 1))

	# Cannot train a champion that is not owned.
	check("an unowned champion cannot be trained",
		not r.begin_training(0, "definitely-not-a-hero", 1))

	# The ceiling holds.
	var r2 := _roster()
	r2.wallet.grant(Wallet.Kind.GOLD, 10_000_000, "test")
	var bought: int = 0
	while r2.unlock_slot():
		bought += 1
	check("slots run out at the maximum",
		r2.slots_unlocked == TrainingS.SLOTS_MAX,
		"%d unlocked after buying %d" % [r2.slots_unlocked, bought])


# ---- it survives a restart ---------------------------------------------------

func _persistence() -> void:
	print("\n=== surviving a restart ===")
	# Training is time spent with the app SHUT, so a slot that does not
	# round-trip through the save is the entire feature not working.
	var r := _roster()
	var who: String = r.owned.keys()[0]
	var t0: int = 1_700_000_000
	r.wallet.grant(Wallet.Kind.GOLD, TrainingS.cost_of(1), "test")
	r.unlock_slot()
	r.begin_training(0, who, t0)

	var back := Roster.from_dict(r.to_dict(), HeroRig.animated_heroes())
	check("the unlocked count survives", back.slots_unlocked == 2,
		"%d" % back.slots_unlocked)
	check("the occupant survives", back.slot(0).hero == who)
	check("the start time survives", back.slot(0).since == t0)
	check("...so a slot keeps earning across a restart",
		back.pending_training(0, t0 + 4 * HOUR) > 0.0)

	# A save written before training existed must load, not crash.
	var old: Dictionary = r.to_dict()
	old.erase("training")
	old.erase("slots_unlocked")
	var migrated := Roster.from_dict(old, HeroRig.animated_heroes())
	check("a save from before training loads with one free slot",
		migrated.slots_unlocked == 1 and migrated.slot(0) != null
			and migrated.slot(0).is_empty())


# ---- it must not replace the game --------------------------------------------

func _balance() -> void:
	print("\n=== balance ===")
	var p := HeroProgress.create("x")
	var need: float = p.xp_to_next()

	var full: float = TrainingS.xp_for(p, TrainingS.CAP_HOURS * 3600.0)
	check("a full slot is a fraction of a level, not a level",
		full < need, "%.0f of %.0f xp to next" % [full, need])
	check("...but is worth collecting", full > need * 0.2,
		"%.0f%% of a level" % (100.0 * full / need))

	# Scaled to the champion's own curve, so it stays meaningful at depth
	# rather than becoming a rounding error at level 50.
	var high := HeroProgress.create("y")
	high.level = 50
	var hi_full: float = TrainingS.xp_for(high, TrainingS.CAP_HOURS * 3600.0)
	check("a level 50 earns the same SHARE of their own next level",
		is_equal_approx(hi_full / high.xp_to_next(), full / need),
		"%.3f vs %.3f" % [hi_full / high.xp_to_next(), full / need])
	check("...which in raw xp is much more", hi_full > full * 5.0,
		"%.0f vs %.0f raw" % [hi_full, full])
