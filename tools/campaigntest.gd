extends SceneTree
# ------------------------------------------------------------------------------
# Is the campaign actually a hundred maps and eight difficulties, and does the
# ladder hold all the way up?
#
#   godot --headless --path . --script tools/campaigntest.gd
#
# WHY THIS FILE EXISTS. The old campaign was 16 regions and 4 tiers, with the
# per-tier numbers in FIVE separate hand-written dictionaries. The predictable
# failure of widening that to 8 was a tier present in one table and missing from
# another — a difficulty that is enterable but pays Normal's XP, which no
# compile and no existing check would notice. So the per-tier numbers are now
# curves, and this file's first job is to prove the curves answer for EVERY
# tier, not just the four that used to be typed out.
#
# Its second job is the dread curve. Tasks E/F/G (palette shift, concept-art
# bands, encounter density) all read Campaign.dread(), so if dread stops rising
# — or biome_at() starts handing out the same four biomes for a hundred maps —
# five systems quietly go flat together.
#
# The SHIPPED_* tables below are the four tiers' values as they shipped, copied
# here on purpose: the curve is allowed to be a curve, but Normal..Eternal
# balance is not allowed to move while it becomes one.
# ------------------------------------------------------------------------------

## What the four hand-written dictionaries held before the curves replaced them.
const SHIPPED_MIN_LEVEL: PackedInt32Array = [1, 18, 34, 48]
const SHIPPED_ENEMY_LEVEL: PackedInt32Array = [0, 16, 32, 46]
const SHIPPED_HEALTH: PackedFloat32Array = [1.0, 2.6, 6.5, 15.0]
const SHIPPED_DAMAGE: PackedFloat32Array = [1.0, 1.9, 3.4, 5.8]
const SHIPPED_XP: PackedFloat32Array = [1.0, 2.2, 4.5, 8.0]
const SHIPPED_LOOT: PackedFloat32Array = [0.0, 0.12, 0.26, 0.42]

## How far a fitted value may sit from the shipped one. Levels are compared in
## whole levels; multipliers proportionally.
const LEVEL_TOLERANCE: int = 1
const MULT_TOLERANCE: float = 0.03
const LOOT_TOLERANCE: float = 0.005

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_structure()
	_biomes()
	_dread()
	_tiers()
	_balance_did_not_jump()
	_ladder()
	_tables()

	print("\n%s (%d failure%s)" % ["OK" if fails == 0 else "FAILED", fails,
		"" if fails == 1 else "s"])
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------
# A hundred maps in ten acts
# ------------------------------------------------------------------------------

func _structure() -> void:
	print("\n=== structure ===")
	check("100 maps", Campaign.map_count() == 100,
		"%d" % Campaign.map_count())
	check("region_count() still answers for the old callers",
		Campaign.region_count() == Campaign.map_count())
	check("10 acts of 10",
		Campaign.act_count() == 10 and Campaign.maps_per_act() == 10,
		"%d acts x %d" % [Campaign.act_count(), Campaign.maps_per_act()])
	check("acts x maps covers the campaign exactly",
		Campaign.act_count() * Campaign.maps_per_act() == Campaign.map_count())

	# Every map in exactly one act, at exactly one stage of it. A modulo bug
	# here would overlap two acts and lose ten maps from the stage select.
	var seen: Dictionary = {}
	var per_act: Array[int] = []
	for a in range(Campaign.act_count()):
		per_act.append(0)
	for i in range(Campaign.map_count()):
		var a: int = Campaign.act_of(i)
		var s: int = Campaign.stage_in_act(i)
		seen["%d.%d" % [a, s]] = true
		if a >= 0 and a < per_act.size():
			per_act[a] += 1
	var even: bool = true
	for n in per_act:
		if n != Campaign.maps_per_act():
			even = false
	check("every (act, stage) pair is used once",
		seen.size() == Campaign.map_count(), "%d pairs" % seen.size())
	check("every act holds the same number of maps", even, str(per_act))
	check("the first and last map land where they should",
		Campaign.act_of(0) == 0 and Campaign.stage_in_act(0) == 0
		and Campaign.act_of(99) == 9 and Campaign.stage_in_act(99) == 9)

	# Titles are what the player reads in the stage list, so a hundred maps need
	# a hundred distinct ones — "The Bone Marches — Boneyard" four times over is
	# a navigation bug, not a cosmetic one.
	var titles: Dictionary = {}
	var empty_title: bool = false
	for i in range(Campaign.map_count()):
		var t: String = Campaign.region_title(i)
		if t.strip_edges().is_empty():
			empty_title = true
		titles[t] = true
	check("all 100 maps have a distinct, non-empty title",
		titles.size() == Campaign.map_count() and not empty_title,
		"%d titles, e.g. %s" % [titles.size(), Campaign.region_title(57)])

	# Determinism: the same map is the same ground forever, and the tier may not
	# enter into it (the point of replaying a difficulty).
	var seeds: Dictionary = {}
	for i in range(Campaign.map_count()):
		seeds[Campaign.region_seed(777, i)] = true
	check("region_seed is stable",
		Campaign.region_seed(777, 42) == Campaign.region_seed(777, 42))
	check("each of the 100 maps has its own seed",
		seeds.size() == Campaign.map_count(), "%d seeds" % seeds.size())


# ------------------------------------------------------------------------------
# Biomes: 100 maps onto 16 biomes, deliberately
# ------------------------------------------------------------------------------

func _biomes() -> void:
	print("\n=== biomes ===")
	var ids: PackedStringArray = Biome.IDS
	var bad: int = 0
	var used: Dictionary = {}
	for i in range(Campaign.map_count()):
		var id: String = Campaign.biome_at(i)
		if ids.find(id) < 0:
			bad += 1
		used[id] = int(used.get(id, 0)) + 1
	check("every map index returns a real Biome.IDS entry", bad == 0,
		"%d of %d bad" % [bad, Campaign.map_count()])
	check("out-of-range indices are clamped, not crashed",
		ids.find(Campaign.biome_at(-5)) >= 0
		and ids.find(Campaign.biome_at(9999)) >= 0,
		"%s .. %s" % [Campaign.biome_at(-5), Campaign.biome_at(9999)])
	check("all %d biomes are used by the campaign" % ids.size(),
		used.size() == ids.size(), "%d used" % used.size())

	check("the campaign opens in the first biome and ends in the last",
		Campaign.biome_at(0) == ids[0]
		and Campaign.biome_at(Campaign.map_count() - 1) == ids[ids.size() - 1],
		"%s .. %s" % [Campaign.biome_at(0),
			Campaign.biome_at(Campaign.map_count() - 1)])

	# THE ORDER MATTERS (task F's dread curve reads it): the biome band has to
	# walk from the temperate head of the list to the hostile tail. Measured as
	# the mean Biome.IDS position per act, which must never step backwards.
	var means: Array[float] = []
	var rising: bool = true
	for a in range(Campaign.act_count()):
		var total: float = 0.0
		for s in range(Campaign.maps_per_act()):
			total += float(ids.find(Campaign.biome_at(a * Campaign.maps_per_act() + s)))
		var m: float = total / float(Campaign.maps_per_act())
		if means.size() > 0 and m <= means[means.size() - 1]:
			rising = false
		means.append(m)
	check("the biome band advances act over act", rising,
		"means %.1f -> %.1f" % [means[0], means[means.size() - 1]])

	var half: int = ids.size() / 2
	var early_ok: bool = true
	var late_ok: bool = true
	for s in range(Campaign.maps_per_act()):
		if ids.find(Campaign.biome_at(s)) >= half:
			early_ok = false
		if ids.find(Campaign.biome_at(Campaign.map_count() - 1 - s)) < half:
			late_ok = false
	check("act 1 draws only from the temperate half", early_ok)
	check("act 10 draws only from the hostile half", late_ok)


# ------------------------------------------------------------------------------
# Dread
# ------------------------------------------------------------------------------

func _dread() -> void:
	print("\n=== dread ===")
	check("dread starts at ~0", absf(Campaign.dread(0)) < 0.001,
		"%.3f" % Campaign.dread(0))
	check("dread ends at ~1",
		absf(Campaign.dread(Campaign.map_count() - 1) - 1.0) < 0.001,
		"%.3f" % Campaign.dread(Campaign.map_count() - 1))
	var rising: bool = true
	var in_range: bool = true
	for i in range(1, Campaign.map_count()):
		var d: float = Campaign.dread(i)
		if d <= Campaign.dread(i - 1):
			rising = false
		if d < 0.0 or d > 1.0:
			in_range = false
	check("dread rises on every single map", rising)
	check("dread never leaves 0..1, even out of range", in_range
		and Campaign.dread(-99) == 0.0 and Campaign.dread(99999) == 1.0)
	check("the midpoint is the midpoint",
		absf(Campaign.dread(49) - 0.49) < 0.02, "%.3f" % Campaign.dread(49))

	# dread_band is what the concept-art plates key off; the bands must cover
	# 0..n-1 with no out-of-range index for any map.
	var bands: Dictionary = {}
	var band_ok: bool = true
	for i in range(Campaign.map_count()):
		var b: int = Campaign.dread_band(i, 5)
		if b < 0 or b > 4:
			band_ok = false
		bands[b] = true
	check("dread_band(i, 5) stays inside 0..4 and uses all five",
		band_ok and bands.size() == 5, "%d bands" % bands.size())


# ------------------------------------------------------------------------------
# Eight difficulties, nothing missing
# ------------------------------------------------------------------------------

func _tiers() -> void:
	print("\n=== difficulties ===")
	check("8 tiers", Campaign.tier_count() == 8, "%d" % Campaign.tier_count())
	check("max_tier() is the last one",
		Campaign.max_tier() == Campaign.tier_count() - 1)
	check("Normal..Eternal keep their old ordinals (old saves still mean it)",
		Campaign.Tier.NORMAL == 0 and Campaign.Tier.VETERAN == 1
		and Campaign.Tier.MERCILESS == 2 and Campaign.Tier.ETERNAL == 3)

	var names: Dictionary = {}
	var named: bool = true
	for t in range(Campaign.tier_count()):
		var n: String = Campaign.tier_name(t)
		if n.strip_edges().is_empty() or n == "?":
			named = false
		names[n] = true
	check("all 8 tiers are named, distinctly", named
		and names.size() == Campaign.tier_count(),
		", ".join(PackedStringArray(names.keys())))

	# THE WHOLE POINT. Every tier must produce every number — a level gate, an
	# enemy level, health, damage, XP and loot — with no hole a dictionary
	# default could paper over. A hole shows up as a repeat of the tier below.
	var holes: PackedStringArray = []
	for t in range(Campaign.tier_count()):
		if Campaign.min_level(t) < 1:
			holes.append("min_level@%d" % t)
		if Campaign.enemy_level(0, t) < 1:
			holes.append("enemy_level@%d" % t)
		if Campaign.enemy_health_mult(t) < 1.0 or not is_finite(Campaign.enemy_health_mult(t)):
			holes.append("health@%d" % t)
		if Campaign.enemy_damage_mult(t) < 1.0 or not is_finite(Campaign.enemy_damage_mult(t)):
			holes.append("damage@%d" % t)
		if Campaign.xp_mult(t) < 1.0 or not is_finite(Campaign.xp_mult(t)):
			holes.append("xp@%d" % t)
		if Campaign.loot_bonus(t) < 0.0 or Campaign.loot_bonus(t) > 1.0:
			holes.append("loot@%d" % t)
		if Campaign.xp_per_kill(0, t) <= 0.0:
			holes.append("xp_per_kill@%d" % t)
	check("every tier has a level / health / damage / XP / loot value",
		holes.is_empty(), "missing: " + ", ".join(holes) if holes.size() > 0 else "")

	# Monotonic, and strictly so where a flat step would mean a difficulty that
	# is harder in name only.
	var mono: PackedStringArray = []
	for t in range(1, Campaign.tier_count()):
		if Campaign.min_level(t) < Campaign.min_level(t - 1):
			mono.append("min_level")
		if Campaign.enemy_level_bonus(t) <= Campaign.enemy_level_bonus(t - 1):
			mono.append("enemy_level")
		if Campaign.enemy_health_mult(t) <= Campaign.enemy_health_mult(t - 1):
			mono.append("health")
		if Campaign.enemy_damage_mult(t) <= Campaign.enemy_damage_mult(t - 1):
			mono.append("damage")
		if Campaign.xp_mult(t) <= Campaign.xp_mult(t - 1):
			mono.append("xp")
		if Campaign.loot_bonus(t) < Campaign.loot_bonus(t - 1):
			mono.append("loot")
	check("every curve is monotonic across all 8 tiers", mono.is_empty(),
		"broke at: " + ", ".join(mono) if mono.size() > 0 else "")

	# A level gate above the character cap would make a tier permanently
	# unenterable, which is the one way this curve can brick the game.
	var gate_ok: bool = true
	for t in range(Campaign.tier_count()):
		if Campaign.min_level(t) > HeroProgress.MAX_LEVEL:
			gate_ok = false
	check("no tier is gated above the level cap (%d)" % HeroProgress.MAX_LEVEL,
		gate_ok, "top gate L%d" % Campaign.min_level(Campaign.max_tier()))

	var top: int = Campaign.max_tier()
	check("difficulty 8 is meaningfully harder than difficulty 1",
		Campaign.enemy_health_mult(top) > 50.0 * Campaign.enemy_health_mult(0)
		and Campaign.enemy_damage_mult(top) > 10.0 * Campaign.enemy_damage_mult(0)
		and Campaign.enemy_level(99, top) > Campaign.enemy_level(99, 0) + 50,
		"x%.0f hp, x%.1f dmg, L%d vs L%d" % [Campaign.enemy_health_mult(top),
			Campaign.enemy_damage_mult(top), Campaign.enemy_level(99, top),
			Campaign.enemy_level(99, 0)])
	check("...and pays for it",
		Campaign.xp_mult(top) > 20.0 * Campaign.xp_mult(0)
		and Campaign.loot_bonus(top) > 3.0 * Campaign.loot_bonus(1),
		"x%.0f xp, +%.2f loot" % [Campaign.xp_mult(top),
			Campaign.loot_bonus(top)])
	check("health still outpaces damage (fights get longer, not sharper)",
		Campaign.enemy_health_mult(top) > Campaign.enemy_damage_mult(top))

	# Within a tier the ramp has to climb too, or a hundred maps are one map.
	var within_ok: bool = true
	for t in range(Campaign.tier_count()):
		for i in range(1, Campaign.map_count()):
			if Campaign.enemy_level(i, t) < Campaign.enemy_level(i - 1, t):
				within_ok = false
			if Campaign.xp_per_kill(i, t) < Campaign.xp_per_kill(i - 1, t):
				within_ok = false
	check("enemy level and XP rise across the 100 maps of every tier",
		within_ok, "L%d -> L%d at Normal" % [Campaign.enemy_level(0, 0),
			Campaign.enemy_level(99, 0)])


# ------------------------------------------------------------------------------
# The four shipped tiers did not move
# ------------------------------------------------------------------------------

func _balance_did_not_jump() -> void:
	print("\n=== the shipped four, re-measured on the curve ===")
	var off: PackedStringArray = []
	for t in range(SHIPPED_MIN_LEVEL.size()):
		if absi(Campaign.min_level(t) - SHIPPED_MIN_LEVEL[t]) > LEVEL_TOLERANCE:
			off.append("min_level@%d (%d vs %d)" % [t, Campaign.min_level(t),
				SHIPPED_MIN_LEVEL[t]])
		if absi(Campaign.enemy_level_bonus(t) - SHIPPED_ENEMY_LEVEL[t]) > LEVEL_TOLERANCE:
			off.append("enemy_level@%d (%d vs %d)" % [t,
				Campaign.enemy_level_bonus(t), SHIPPED_ENEMY_LEVEL[t]])
		_near("health", t, Campaign.enemy_health_mult(t), SHIPPED_HEALTH[t], off)
		_near("damage", t, Campaign.enemy_damage_mult(t), SHIPPED_DAMAGE[t], off)
		_near("xp", t, Campaign.xp_mult(t), SHIPPED_XP[t], off)
		if absf(Campaign.loot_bonus(t) - SHIPPED_LOOT[t]) > LOOT_TOLERANCE:
			off.append("loot@%d (%.3f vs %.3f)" % [t, Campaign.loot_bonus(t),
				SHIPPED_LOOT[t]])
	check("Normal..Eternal still hold their shipped values", off.is_empty(),
		"drifted: " + ", ".join(off) if off.size() > 0 else
		"within %dL / %d%% / %.3f" % [LEVEL_TOLERANCE,
			int(MULT_TOLERANCE * 100.0), LOOT_TOLERANCE])


func _near(what: String, tier: int, got: float, want: float,
		off: PackedStringArray) -> void:
	if absf(got - want) / maxf(want, 0.0001) > MULT_TOLERANCE:
		off.append("%s@%d (%.2f vs %.2f)" % [what, tier, got, want])


# ------------------------------------------------------------------------------
# The ladder is climbable to the top
# ------------------------------------------------------------------------------

func _ladder() -> void:
	print("\n=== the unlock ladder reaches tier 8 ===")
	# Roster holds the account-wide unlock, and it used to stop at ETERNAL. With
	# Eternal now the FOURTH of eight, a stale cap there would lock the last
	# four difficulties away forever while every table above claimed they exist.
	var r := Roster.new()
	var reached: int = r.unlocked_tier
	for t in range(Campaign.tier_count()):
		r.complete_campaign("nobody", t)
		reached = maxi(reached, r.unlocked_tier)
	check("clearing each difficulty unlocks the next, up to the last",
		reached == Campaign.max_tier(),
		"reached %s (%d)" % [Campaign.tier_name(reached), reached])

	# A capped champion may enter every unlocked tier; a level-1 one may not.
	var maxed := HeroProgress.create("Hero")
	maxed.level = HeroProgress.MAX_LEVEL
	var fresh := HeroProgress.create("Rookie")
	var all_open: bool = true
	var all_refused: bool = true
	for t in range(1, Campaign.tier_count()):
		if not Campaign.can_enter(t, maxed, Campaign.max_tier()):
			all_open = false
		if Campaign.can_enter(t, fresh, Campaign.max_tier()):
			all_refused = false
		if Campaign.entry_blocked_reason(t, fresh,
				Campaign.max_tier()).is_empty():
			all_refused = false
	check("a level-%d champion may enter all 8" % HeroProgress.MAX_LEVEL,
		all_open)
	check("a level-1 champion is refused, with a reason", all_refused,
		Campaign.entry_blocked_reason(Campaign.max_tier(), fresh,
			Campaign.max_tier()))
	check("a locked tier says what to clear",
		Campaign.entry_blocked_reason(4, maxed, 3) == "Clear Eternal to unlock",
		Campaign.entry_blocked_reason(4, maxed, 3))


# ------------------------------------------------------------------------------
# What the curves actually produced
# ------------------------------------------------------------------------------

func _tables() -> void:
	print("\n=== the eight difficulties as generated ===")
	print("  %-10s %5s %6s %8s %7s %7s %7s" % ["tier", "gate", "+lvl",
		"health", "damage", "xp", "loot"])
	for t in range(Campaign.tier_count()):
		print("  %-10s %5d %6d %8.1f %7.2f %7.2f %7.2f" % [
			Campaign.tier_name(t), Campaign.min_level(t),
			Campaign.enemy_level_bonus(t), Campaign.enemy_health_mult(t),
			Campaign.enemy_damage_mult(t), Campaign.xp_mult(t),
			Campaign.loot_bonus(t)])

	print("\n=== the hundred maps, every tenth ===")
	print("  %4s %6s %-22s %-34s %5s" % ["map", "dread", "biome", "title",
		"L(T1)"])
	for i in range(0, Campaign.map_count(), 10):
		print("  %4d %6.2f %-22s %-34s %5d" % [i + 1, Campaign.dread(i),
			Campaign.biome_at(i), Campaign.region_title(i),
			Campaign.enemy_level(i, 0)])
	var last: int = Campaign.map_count() - 1
	print("  %4d %6.2f %-22s %-34s %5d" % [last + 1, Campaign.dread(last),
		Campaign.biome_at(last), Campaign.region_title(last),
		Campaign.enemy_level(last, 0)])
