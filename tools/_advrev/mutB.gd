extends SceneTree
# ------------------------------------------------------------------------------
# THE BALANCE INSTRUMENT: what the campaign's numbers actually do to a champion.
#
# Every balance figure in this game is reasoned and none of it has been played.
# Campaign.gd fits six curves to four shipped tiers, Encounter.gd scales a boss
# by x8 health, Stats.gd is linear in four attributes, Item.gd gives a weapon
# 4 + 1.8 per item level while Encounter gives an enemy 4 per level — and each of
# those is defensible on its own. What nobody has measured is the PRODUCT: how
# long a fight on map 46 of Merciless lasts, how much of a health bar one body
# costs, and whether the Mage and the Fighter are playing the same game.
#
# So this is a measuring instrument, not a unit test. It builds REAL maps (384
# cells of real terrain, real lane, real walk grid), populates them with the REAL
# encounter (Encounter.build → the map's own cast, packs, elites and boss), gives
# the champion a REAL body (Combat.champion_body over a real Roster, a real
# HeroProgress and a real Stash of gear rolled by Loot), and resolves the fights
# with the REAL combat code (Combat.cast / Combatant.strike, real Abilities, real
# MageSpells, real StatusEffects, real Elite traits, real seeded crit and dodge).
#
# ------------------------------------------------------------------------------
# WHAT IT CANNOT DO, STATED FIRST, BECAUSE THE NUMBERS MEAN NOTHING WITHOUT IT.
#
# A fight in the shipped game is resolved by Play.gd: a brain tick that walks
# enemies to a stand-off distance, retreats the ranged ones, aims a boss slam at
# the ground, and a player with two thumbs who kites, dodges, chases and breaks
# off. None of that is reachable headlessly — Play.gd is a Node3D needing a
# scene, 139 rigs and input — and a headless reimplementation of it would be
# measuring a model of the game instead of the game.
#
# So the instrument deliberately measures the part that is NOT the AI: a stand-up
# fight between real bodies, at contact range, with nobody moving.
#
#   * EVERY COMBATANT IS IN CONTACT, at HeroController.ATTACK_RANGE, spread over
#     the champion's facing — so which bodies an ability reaches is decided by
#     the real Ability.covers over real positions, while the approach is not
#     simulated at all. Nobody ever spends a tick walking.
#   * NOBODY KITES AND NOBODY CHASES. In Play a crowded ranged enemy gives ground
#     for RETREAT_BUDGET seconds instead of attacking, and a player does the
#     same. Removing both gives every combatant perfect uptime: harsher than real
#     play on damage taken, kinder on clear time.
#   * THE CHAMPION IS DRIVEN BY Play's OWN ENEMY RULE — the highest-numbered
#     action off cooldown and in range (mirrors Play._choose_action) — every
#     frame it is free. That is a FLOOR on player skill: it never holds Rally for
#     the moment it is needed and never saves a stun.
#   * THE BOSS SLAM IS DODGED, which is the designed outcome of a telegraph, so
#     it is excluded from damage taken and reported separately as what one missed
#     dodge would cost.
#   * A CAST TAKES HeroRig's STAND-IN 0.45 s rather than the rigged clip's real
#     length, so every TTK in seconds is in stand-in units. A rigged clip that
#     runs 0.8 s stretches them all by a common factor — which moves the absolute
#     seconds and cannot move the shape of a curve or a ratio between classes.
#   * NO PARTNERS. Party.gd fields up to three more champions at CONTRIBUTION
#     0.55, so a full party is a little over twice one hero. Solo is the hardest
#     legal configuration, which is the right one for "is this winnable at all".
#
# WHAT IS THEREFORE CLAIMED, AND WHAT IS NOT. The headline numbers are DUELS —
# the champion against one real body of the map, and against the map's real boss
# — because a duel needs none of the missing AI: there is nothing to kite, no
# pack to pull, and no positioning to get right. Those carry the curve, the
# winnability and the class band.
#
# The PACK figure is reported as a capacity and nothing stronger: the largest
# number of the deepest pack's real bodies the champion survives when all of them
# are in contact at once with no retreat and no partner. That is a worst case, not
# a prediction of play — in the real game the player meets a pack while moving,
# and pack_capacity is a measure of how much headroom the maths leaves them.
#
#   godot --headless --path . --script tools/balancetest.gd
#
# Findings, and the constants to move, are written up in docs/BALANCE.md.
# ------------------------------------------------------------------------------

## Play.gd holds the fight's cadence and the boss mechanic as constants. Read
## through a PRELOAD rather than copied, so a tuning pass on SLAM_POWER or THINK
## moves this harness too instead of silently leaving it measuring an old game.
## By path and not by name: Play has no class_name, and a bare name would be the
## global-cache trap this project has been bitten by four times.
const PlayRules := preload("res://scripts/game/Play.gd")

## The shipping region, as tools/encountertest.gd builds it.
const CELLS: int = 384
const CELL: float = 0.5

## One campaign, fixed, so a re-run measures the same hundred maps.
const CAMPAIGN_SEED: int = 12345

## Every fifth map: twenty samples across the hundred. The gap is also what makes
## the cliff test meaningful — a jump between two samples is five maps of ramp,
## not one noisy neighbour.
const MAP_STRIDE: int = 5

## The tiers measured. Normal is the curve every player meets; Veteran is one
## whole step of the fitted tier curve; Merciless is where enemies gain a third
## action (Campaign.HARD_TIER) and the last tier whose enemy levels still fit
## under HeroProgress.MAX_LEVEL — above it "an on-level champion" cannot exist,
## which is a finding in itself rather than something to measure around.
const TIERS: Array = [Campaign.Tier.NORMAL, Campaign.Tier.VETERAN,
	Campaign.Tier.MERCILESS]

## Simulation step. Well under the 0.35 s brain tick and the 0.45 s cast, so
## quantisation cannot move a result.
const DT: float = 0.05

## How long one cast locks a body out. HeroRig's stand-in one-shot duration —
## see the caveat in the header.
const CAST_TIME: float = 0.45

## Where an enemy stands: the champion's own basic-attack reach. Play walks
## enemies to REACH (2.6 m) and stops; the champion closes the last 40 cm
# itself, and a sim where neither side moved would be a stalemate the real game
## does not have.
const CONTACT: float = HeroController.ATTACK_RANGE

## Half-angle a pack is spread over, in degrees. Wide enough that an arc
## ability's cone and its max_targets both decide something, narrow enough that
## the pack reads as being in front of the champion rather than surrounding it.
const SPREAD_DEG: float = 55.0

## Give up on a fight after this long. Generous on purpose: a boss fight that
## takes two minutes is a number worth having rather than a clipped one, and the
## one-sided runs below need room to finish. A fight still going at five minutes
## has answered the question either way.
const FIGHT_TIMEOUT: float = 300.0

## Rolls per measurement. Crits and dodges come from a seeded stream, so ONE
## fight is a single sample and a crit streak looks exactly like a cliff.
const REPEATS: int = 3

## How much gear the champion wears: this many kills' worth of drops, rolled
## through the real Loot.roll — so ITEM_CHANCE, the tier's rarity ceiling and the
## item-level cap against the champion's level all apply — and then auto-equipped
## like a player pressing the button.
##
## THE STREAM IS KEYED ON (LEVEL, TIER) AND NOT ON THE MAP, deliberately. Rolling
## it from the map's own seed made the champion's power a random variable per map:
## a level-20 champion on map 21 came out with 1417 health while a level-18 one on
## map 6 had 1504, because the drops happened to roll better, and the difficulty
## curve then jittered by a third for reasons that are nothing to do with the
## maps. Typical gear for a level and a tier is the thing being held constant.
##
## A hundred and twenty is about three maps of bodies, which is roughly what a
## player's best-in-slot is drawn from before the next level makes it obsolete.
const GEAR_KILLS: int = 120

## Where the skill points go. A champion at level L has (L-1)*3 of them and a
## player spends them; leaving them unspent would measure a build nobody plays.
## PRIMARY is what the UI nudges toward (HeroClass.PRIMARY); MIXED is the
## two-thirds damage, one-third health build a cautious player lands on.
enum Build { PRIMARY, MIXED }

## THE DIFFICULTY INDEX, in health bars: the map's PRESSURE times the time the
## champion has to stand in it. See `bars` in _measure_at — it is the cost of the
## map to a champion with no sustain, because the two quantities it multiplies
## each depend on one side of the fight and neither can saturate.
##
## IT USED TO BE ttk/ttl PER BODY, and that index is why this harness could not
## be trusted: ttl is a STEP FUNCTION. Rally and Ward put back about 3% of a
## health bar a second, so a body landing slightly under that is survived for
## ever (ttl pinned at the 300 s timeout, cost ~0) and a body landing slightly
## over kills in two seconds (cost enormous). Measured that way, one third of a
## Fighter's skill points moved the cost of map 96 by x47 and the three classes
## were x51 apart — neither of which is a fact about the game. Sustain is
## measured on its own instead (_sustain) and reported beside the pressure it is
## up against.
##
## No map may cost this many times what the map five before it cost.
const CLIFF: float = 3.0

## Seconds of a one-sided beating used to measure pressure. Longer than the
## longest cooldown in any kit (16 s), so a window cannot miss an enemy's
## signature ability and read as a quiet fight.
const PRESSURE_WINDOW: float = 20.0

## What a shield with no authored magnitude is worth, as a fraction of the
## caster's health bar. COPIED from Combat.cast, which writes it inline, and the
## one number in this harness that can silently drift away from the game — see the
## patch request at the end of docs/BALANCE.md.
const SHIELD_OF_MAX_HEALTH: float = 0.30

## A boss that dies in under this long is not a boss.
const BOSS_FLOOR: float = 2.0

## Smallest pack capacity worth calling a fight: a champion that cannot survive
## two bodies at once has no answer to a pack of four.
const CAPACITY_FLOOR: int = 2

## THE LOCKOUT CEILING: the largest share of a fight an enemy may keep the
## champion unable to act for.
##
## Combatant.can_act is false for the whole duration of a STUN, so an enemy whose
## stun rider lasts longer than its own cooldown holds the champion in a loop it
## cannot play out of — and because the only measurement that would show it is
## time-to-kill, a stun lock reads in every other section as "this boss has a lot
## of health". Half is already past the point the fight is the player's; it is set
## there rather than lower so the figure accuses only a genuine lock.
const LOCKOUT_CEILING: float = 0.5

## Largest share of its own stun rider's cooldown that the rider may last. Above
## 1.0 the lock is unbreakable; this is the band where the player still gets
## turns. Both of the authored class kits sit near 0.2 (Shield Slam is 2 s on 9 s,
## Pinning Shot 1.6 s on 8 s), so this is a ceiling with room under it and not a
## restatement of what the kits happen to do.
const STUN_DUTY_CEILING: float = 0.6

## How much of its OWN HEALTH BAR a boss may put back by healing itself over one
## fight.
##
## MEASURED AGAINST THE BOSS'S OWN POOL and not against the damage done to it,
## which is the denominator this check first used and got wrong: the harness's
## `dealt` counts only the health that actually left the boss each step, so a heal
## landing in the same step nets itself out of the figure it is being compared
## against, and a boss regenerating three times its own bar scored under 50% and
## passed. Against its own max health the number means one thing only — how many
## bars the champion had to chew through on top of the first.
##
## Half a bar is already generous for a fight the player is meant to win by
## attrition; the failure this catches is a boss healing FASTER than a champion
## damages it, which no amount of player skill answers.
const BOSS_HEAL_SHARE: float = 0.5

## How far apart the three classes may land on the same map before class choice
## stops being preference and becomes a trap. On time to kill, and on cost.
const CLASS_BAND_TIME: float = 2.0
const CLASS_BAND_COST: float = 3.0

var fails: int = 0
## SECTIONS THAT RAN TO THE END. A runtime error aborts a function and GDScript
## carries on, so a crash halfway through the sweep otherwise reports zero
## failures and a clean bill of health.
var sections: int = 0
const SECTIONS_EXPECTED: int = 11

## map index -> { "spawns": { tier -> Array[Encounter.Spawn] }, "seed": int }
var _maps: Dictionary = {}
## Every measurement taken, for the curve sections.
var _rows: Array = []
var _roster_names: PackedStringArray = PackedStringArray()
var _starters: PackedStringArray = PackedStringArray()
## map index -> the level the campaign's own XP curve has given a champion by the
## time it arrives there. Filled by section 9, read by section 10.
var _granted: Dictionary = {}


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, detail])


# ------------------------------------------------------------------------------
# One combatant in a simulated fight: a body, its kit, and its clocks.
#
# Deliberately NOT a HeroController. The controller is a Node3D driving a rig and
# a path follower, and a headless copy of it would be a second implementation of
# the thing being measured. What is copied is only the ACTION CADENCE —
# cooldowns, the cast lock-out, and Play's choose-the-highest-action rule — and
# every number those clocks feed is resolved by the real Combat code.
# ------------------------------------------------------------------------------
class Unit extends RefCounted:
	var body: Combatant
	var basic: Ability
	var kit: Array[Ability] = []
	## How many of its four actions this unit may use, basic included — see
	## Campaign.enemy_actions. The champion has all four, as the player does.
	var allowed: int = 4
	var at: Vector2 = Vector2.ZERO
	## Seconds left of the current cast, and what resolves when it ends. Damage
	## lands at the END of the clip, as it does in Play (cast_landed).
	var busy: float = 0.0
	var pending: Ability = null
	var cd: Dictionary = {}
	var trait_id: int = Elite.Trait.NONE
	var is_boss: bool = false
	var is_elite: bool = false
	var label: String = ""
	## A PUNCHING BAG: never decides, so it never fights back. Used for the one
	## model check that needs to see damage arrive with no shield in the way.
	var passive: bool = false
	## HEALTH PUT BACK EVERY STEP, so the fight runs to the other side's death
	## however long that takes. One side immortal is how time-to-kill and
	## time-to-live are measured separately — see _ttk and _ttl.
	var immortal: bool = false
	## Health this unit has healed ONTO ITSELF over the fight, taken from
	## Combat.Result.healed — the real figure the real cast returned, not a
	## reconstruction from health deltas, which an immortal unit's top-up would
	## make meaningless.
	var healed: float = 0.0


	func ability_in_slot(slot: int) -> Ability:
		if slot <= 0:
			return basic
		return kit[slot - 1] if slot - 1 < kit.size() else null


	func cooldown_left(slot: int) -> float:
		var a: Ability = ability_in_slot(slot)
		return float(cd.get(a.id, 0.0)) if a != null else 0.0


	## Advance the clocks. The body's own tick — burns, expiry — is the real one.
	func advance(delta: float) -> void:
		if body != null:
			body.tick(delta)
		for k in cd.keys():
			cd[k] = maxf(float(cd[k]) - delta, 0.0)
		if busy > 0.0:
			busy = maxf(busy - delta, 0.0)


	func ready() -> bool:
		return body != null and body.alive and busy <= 0.0 and body.can_act()


	## Mirrors Play._choose_action: the strongest action that is off cooldown and
	## actually in range, falling back to the basic, which has no cooldown.
	func choose(gap: float) -> int:
		for slot in range(mini(allowed, 4) - 1, 0, -1):
			var ab: Ability = ability_in_slot(slot)
			if ab == null or cooldown_left(slot) > 0.0:
				continue
			if ab.shape != Ability.Shape.SELF and gap > ab.range_m:
				continue
			return slot
		return 0


	## Begin a cast. The cooldown starts on the press and the damage lands when
	## the clip ends, exactly as HeroController.use_ability does it.
	##
	## A PRESS ON A COOLDOWN IS REFUSED, and that is not a detail. Play's chooser
	## falls back to `return 0` without consulting the basic attack's cooldown —
	## its comment calls the basic "always available" — but HeroController.use_
	## ability checks the cooldown of whatever slot it is handed and refuses,
	## so in the real game that fallback press simply does not happen. This
	## harness used to start the cast regardless, which made EVERY class swing
	## its basic once per CAST_TIME (0.45 s) instead of on its own cooldown:
	## Fighter 0.65 s, Ranger 0.55 s, Mage 0.75 s. That inflated basic-attack
	## throughput by 1.44x, 1.22x and 1.67x respectively — unevenly, and worst
	## for the slowest class — which is precisely the measurement section 7
	## uses to decide whether the three classes are the same game.
	func begin(slot: int) -> bool:
		var ab: Ability = ability_in_slot(slot)
		if ab == null:
			return false
		if float(cd.get(ab.id, 0.0)) > 0.0:
			return false
		if ab.cooldown > 0.0:
			cd[ab.id] = ab.cooldown
		pending = ab
		busy = CAST_TIME
		return true


func _init() -> void:
	print("\n================ THE BALANCE INSTRUMENT ================")
	_roster_names = HeroRig.animated_heroes()
	_starters = Champion.starters(_roster_names)
	print("roster %d champions; the three starters are %s" % [
		_roster_names.size(), ", ".join(_starters)])

	_the_model()
	_the_two_bodies()
	_build_maps()
	_sweep()
	_the_curve()
	_winnable_and_not_trivial()
	_the_classes()
	_the_loot_curve()
	_the_level_the_campaign_grants()
	_the_champion_the_campaign_makes()
	_why_a_boss_fight_is_long()

	print("\n=== %d of %d sections completed ===" % [sections, SECTIONS_EXPECTED])
	if sections != SECTIONS_EXPECTED:
		fails += 1
		push_error("balancetest: %d sections of %d ran — something aborted"
			% [sections, SECTIONS_EXPECTED])
	print("=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------
# 1. Does the instrument resolve a fight at all?
#
# THE FAILURE THIS SECTION EXISTS FOR: a simulation loop that quietly does
# nothing produces a flat, clean and entirely wrong set of curves — every TTK is
# the timeout, every map costs no health, and the monotonic test passes because
# nothing moves. So before any balance claim, prove the EFFECTS: health leaves an
# enemy, health leaves the champion, a fight ends in a death rather than in the
# timeout, a stun stops a unit acting, and the gear is actually on the champion.
# ------------------------------------------------------------------------------

func _the_model() -> void:
	print("\n=== 1. the model resolves fights ===")
	var hero: Unit = _champion(_starters[0], 20, 20, Campaign.Tier.NORMAL,
		Build.PRIMARY, 0)
	var foe: Unit = _dummy(20, HeroClass.Kind.FIGHTER, 991)
	var out: Dictionary = _fight(hero, [foe], Campaign.Tier.NORMAL, false)

	check("a fight ends in a death, not the timeout",
		bool(out["resolved"]) and float(out["time"]) < FIGHT_TIMEOUT,
		"%.1fs, %d killed" % [float(out["time"]), int(out["kills"])])
	check("the champion's damage reaches the enemy", int(out["kills"]) == 1,
		"%.0f dealt" % float(out["dealt"]))

	# MEASURED ON A BAG, because a champion with Rally up takes literally nothing
	# from one body: the shield is 30% of a health bar and the body is dead in two
	# seconds. Checking it on a defended champion asserted 0 > 0 and failed, which
	# is the right answer to the wrong question.
	var bag: Unit = _champion(_starters[0], 20, 20, Campaign.Tier.NORMAL,
		Build.PRIMARY, 0)
	bag.passive = true
	var hitter: Unit = _dummy(20, HeroClass.Kind.FIGHTER, 992)
	var out_bag: Dictionary = _fight(bag, [hitter], Campaign.Tier.NORMAL, false)
	check("the enemy's damage reaches the champion",
		float(out_bag["taken"]) > 0.0 and not bag.body.alive,
		"%.0f taken, dead in %.1fs" % [float(out_bag["taken"]),
			float(out_bag["time"])])

	# A stunned unit must not act. Proven on the EFFECT: the dummy gets a stun
	# and a free second, and must do nothing with it.
	var mute: Unit = _dummy(20, HeroClass.Kind.FIGHTER, 7)
	var target: Unit = _dummy(20, HeroClass.Kind.FIGHTER, 8)
	target.body.team = Combatant.Team.PLAYER
	mute.body.apply(StatusEffect.make(StatusEffect.Kind.STUN, 1.0, 0.0, "probe"))
	var hp0: float = target.body.health
	for _i in range(10):
		_step([mute], [target], true)
	check("a stunned unit cannot act", is_equal_approx(target.body.health, hp0),
		"%.0f hp unchanged through a 1 s stun" % target.body.health)

	# Gear has to be ON the champion, or every number below is a naked hero.
	var naked: Combatant = Combat.champion_body(null, _starters[0], 20, 1)
	check("the champion is wearing the gear it was given",
		hero.body.weapon_power > naked.weapon_power and hero.body.armour > 0.0,
		"weapon %.0f vs unarmed %.0f, armour %.0f" % [hero.body.weapon_power,
			naked.weapon_power, hero.body.armour])

	# The mercy ramp has to be in the enemy bodies, or map 1 is not a tutorial.
	var first: float = Campaign.mercy(0, Campaign.Tier.NORMAL)
	var last: float = Campaign.mercy(99, Campaign.Tier.NORMAL)
	check("the opening's mercy ramp is in play", first < 0.2 and last >= 1.0,
		"map 1 enemies at %.0f%% strength, map 100 at %.0f%%"
			% [first * 100.0, last * 100.0])
	sections += 1


# ------------------------------------------------------------------------------
# 2. The two bodies: is a champion built from the same parts as its enemy?
#
# Enemies in this game ARE champions (Encounter.gd's premise), but the two are
# assembled by different code: the player's by Combat.champion_body out of a
# Stash of rolled Items, the enemy's by Encounter.body_for out of flat formulas
# (weapon 4/level, armour 3/level). Nothing has ever compared them, and a
# systematic gap between the two is the one balance error that no amount of
# per-tier tuning can fix, because it is present at every tier at once.
# ------------------------------------------------------------------------------

func _the_two_bodies() -> void:
	print("\n=== 2. the champion against a same-level enemy ===")
	print("  lv  champion dmg/hp      enemy dmg/hp        dmg ratio  hp ratio")
	var worst_dmg: float = INF
	var worst_at: int = 0
	for level in [1, 10, 20, 30, 40, 50, 60]:
		var hero: Unit = _champion(_starters[0], level, _map_for_level(level),
			Campaign.Tier.NORMAL, Build.PRIMARY, 0)
		# A level-matched enemy Fighter at full strength: no mercy, no tier
		# multiplier, no boss multiplier — just the other construction path.
		var spawn := Encounter.Spawn.new()
		spawn.hero = _starters[0]
		spawn.cls = HeroClass.Kind.FIGHTER
		spawn.level = level
		spawn.seed = 31
		var enemy: Combatant = Encounter.body_for(spawn, Campaign.Tier.NORMAL)
		var dmg_ratio: float = hero.body.attack_power() \
			/ maxf(enemy.attack_power(), 0.001)
		var hp_ratio: float = hero.body.max_health \
			/ maxf(enemy.max_health, 0.001)
		print("  %2d  %7.0f / %-7.0f   %7.0f / %-7.0f   %8.2f  %8.2f" % [level,
			hero.body.attack_power(), hero.body.max_health,
			enemy.attack_power(), enemy.max_health, dmg_ratio, hp_ratio])
		if dmg_ratio < worst_dmg:
			worst_dmg = dmg_ratio
			worst_at = level

	check("a champion hits at least as hard as its own kind", worst_dmg >= 1.0,
		"worst x%.2f at level %d" % [worst_dmg, worst_at])
	sections += 1


# ------------------------------------------------------------------------------
# 3. The maps, built for real
# ------------------------------------------------------------------------------

func _build_maps() -> void:
	print("\n=== 3. building %d real maps ===" % (Campaign.map_count() / MAP_STRIDE))
	var t0: int = Time.get_ticks_msec()
	for index in range(0, Campaign.map_count(), MAP_STRIDE):
		var world_seed: int = Campaign.region_seed(CAMPAIGN_SEED, index)
		var extent: float = float(CELLS) * CELL
		var lane: Lane = Terrain.plan_for(Terrain.Kind.LANE, world_seed,
			Vector2(extent, extent)) as Lane
		var ter: Terrain = Terrain.generate(world_seed, Campaign.biome_at(index),
			CELLS, CELL, lane)
		var path := Pathing.new(ter)
		var start: Vector2 = path.nearest_walkable_centre(lane.position_at(0.0))
		var per_tier: Dictionary = {}
		for tier in TIERS:
			# The player's own champion is excluded from the cast exactly as the
			# game excludes it; the Fighter starter stands in for all three, so
			# all three classes meet the same map.
			per_tier[tier] = Encounter.build(index, tier, CAMPAIGN_SEED,
				_roster_names, _starters[0], path, start, lane)
		_maps[index] = {"spawns": per_tier, "seed": world_seed}
	print("  %d maps, %d tiers each, in %.1f s" % [_maps.size(), TIERS.size(),
		float(Time.get_ticks_msec() - t0) / 1000.0])

	var populated: bool = true
	var bossed: bool = true
	for index in _maps.keys():
		for tier in TIERS:
			var spawns: Array = _maps[index]["spawns"][tier]
			if spawns.size() < 4:
				populated = false
			var has_boss: bool = false
			for s in spawns:
				if (s as Encounter.Spawn).is_boss:
					has_boss = true
			if not has_boss:
				bossed = false
	check("every sampled map is populated", populated)
	check("every sampled map has a boss", bossed)
	sections += 1


# ------------------------------------------------------------------------------
# 4. The sweep: every sampled map, every tier, all three classes
# ------------------------------------------------------------------------------

func _sweep() -> void:
	print("\n=== 4. the sweep ===")
	print("  on-level = clamp(Campaign.enemy_level(map, tier), "
		+ "Campaign.min_level(tier), %d)" % HeroProgress.MAX_LEVEL)
	print("  ttk = time to kill it (projected from the damage actually dealt "
		+ "when the fight was lost)")
	print("  ttl = time it needs to kill an undefended champion")
	print("  bars = projected cost of the map in health bars at the measured "
		+ "exchange rate (ttk/ttl x bodies, plus the boss)")
	var t0: int = Time.get_ticks_msec()

	# IS A MEASUREMENT A FUNCTION OF ITS ARGUMENTS, OR OF WHAT RAN BEFORE IT?
	#
	# This is the instrument's own calibration and it is not optional. The sweep
	# resolves tens of thousands of fights and allocates a Combatant for every
	# body in every one of them; if any of the combat code keeps state that
	# outlives a body, then a map measured late reads differently from the same
	# map measured early, and the rising curve this harness is built to detect
	# could be an artefact of measurement order rather than a fact about the
	# campaign. The same row is therefore taken NOW and again at the very END of
	# the sweep, and the two must agree.
	#
	# It is a real risk rather than a theoretical one: Elite.gd keys a static
	# table on body.get_instance_id() and prunes it only every 256 entries, and
	# three of its traits connect a signal per body. An earlier version of this
	# harness changed one map's pack capacity from 1 to 2 purely by allocating
	# two extra bodies per measurement elsewhere in the function.
	for tier in TIERS:
		print("\n  --- %s ---" % Campaign.tier_name(tier))
		print("  map  lv  class    hp  bodies  ttk/body ttl/body  ttk/boss"
			+ " ttl/boss   slam   bars  pack  loot  the boss it fought"
			+ "         lost")
		for index in _sorted_maps():
			for hero_name in _starters:
				var row: Dictionary = _measure(index, tier, hero_name,
					Build.PRIMARY)
				_rows.append(row)
				print(("  %3d %3d  %-7s %5.0f %5d  %7.2fs %7.1fs  %7.1fs"
					+ " %7.1fs %5.0f%% %6.2f  %d/%-3d %5d  L%-2d %-7s %6.0f hp"
					+ " %2.0f%%dg  %s") % [
					index + 1, int(row["level"]),
					String(row["class"]).substr(0, 7), float(row["max_hp"]),
					int(row["bodies"]), float(row["ttk_body"]),
					float(row["ttl_body"]), float(row["ttk_boss"]),
					float(row["ttl_boss"]), float(row["slam_pct"]) * 100.0,
					float(row["bars"]), int(row["capacity"]),
					int(row["pack_size"]), int(row["loot"]),
					int(row["boss_lv"]), String(row["boss_cls"]).substr(0, 7),
					float(row["boss_hp"]), float(row["boss_dodge"]) * 100.0,
					_lost_label(row)])
	print("\n  %d measurements in %.1f s" % [_rows.size(),
		float(Time.get_ticks_msec() - t0) / 1000.0])
	check("every map/tier/class was measured",
		_rows.size() == _maps.size() * TIERS.size() * 3,
		"%d rows" % _rows.size())

	# The other half of the calibration: THE WHOLE SWEEP AGAIN, row for row.
	#
	# Not a sampled probe. The first attempt at this re-measured one map and
	# passed — twice, including on the most elite-heavy map in the game — while
	# the drift it was looking for was still demonstrably present somewhere
	# else in the table. Order-dependence does not show up wherever you decide
	# to look for it: whether a given row is affected depends on exactly how
	# many bodies were allocated before it, so the only honest check is every
	# row. It costs one more pass over a sweep that takes twelve seconds.
	var drifted: PackedStringArray = PackedStringArray()
	var at: int = 0
	for tier in TIERS:
		for index in _sorted_maps():
			for hero_name in _starters:
				var a_row: Dictionary = _rows[at]
				at += 1
				var b_row: Dictionary = _measure(index, tier, hero_name,
					Build.PRIMARY)
				for field in ["ttk_body", "ttl_body", "ttk_boss", "ttl_boss",
						"press_body", "press_boss", "bars", "capacity",
						"max_hp", "boss_hp", "loot"]:
					if is_equal_approx(float(a_row[field]),
							float(b_row[field])):
						continue
					drifted.append("%s map %d %s %s %.3f->%.3f" % [
						Campaign.tier_name(tier), index + 1,
						String(a_row["class"]).substr(0, 3), field,
						float(a_row[field]), float(b_row[field])])
	check("every row is reproducible: the sweep run twice agrees",
		drifted.is_empty(), "%d of %d rows drifted%s" % [drifted.size(),
			_rows.size(), "" if drifted.is_empty() else ": " + ", ".join(
				PackedStringArray(drifted.slice(0, 4)))])
	sections += 1


func _lost_label(row: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if bool(row["lost_body"]):
		parts.append("body")
	if bool(row["lost_boss"]):
		parts.append("BOSS")
	if bool(row["timeout"]):
		parts.append("timeout")
	return "-" if parts.is_empty() else ",".join(parts)


# ------------------------------------------------------------------------------
# 5. The curve: does difficulty rise, and does it ever jump?
# ------------------------------------------------------------------------------

func _the_curve() -> void:
	print("\n=== 5. the difficulty curve ===")
	for tier in TIERS:
		# Averaged over the three classes: a cliff only one class feels is a
		# class problem (section 7), not a curve problem.
		var cost: Array = []
		var boss: Array = []
		var maps: Array = _sorted_maps()
		for index in maps:
			cost.append(_mean_of(tier, index, "bars"))
			boss.append(_mean_of(tier, index, "ttk_boss"))

		var third: int = maxi(maps.size() / 3, 1)
		var head: float = _mean_slice(cost, 0, third)
		var tail: float = _mean_slice(cost, maps.size() - third, maps.size())
		print("  %-10s first third %.2f bars -> last third %.2f bars  "
			% [Campaign.tier_name(tier), head, tail]
			+ "(boss %.0fs -> %.0fs)" % [_mean_slice(boss, 0, third),
				_mean_slice(boss, maps.size() - third, maps.size())])

		check("[%s] the campaign gets harder than it starts"
			% Campaign.tier_name(tier), tail > head,
			"%.2f -> %.2f health bars a map" % [head, tail])

		# MONOTONICALLY-ISH: most steps up, rather than every step.
		var ups: int = 0
		for i in range(1, cost.size()):
			if cost[i] >= cost[i - 1]:
				ups += 1
		check("[%s] ...and mostly rises along the way"
			% Campaign.tier_name(tier),
			float(ups) / float(maxi(cost.size() - 1, 1)) >= 0.6,
			"%d of %d steps up" % [ups, cost.size() - 1])

		# NO CLIFF. Against a floor as well as a ratio: 0.02 bars to 0.08 bars is
		# a 4x on nothing, and calling that a cliff fires the test on the
		# quietest maps in the game.
		var worst: float = 1.0
		var worst_at: int = -1
		for i in range(1, cost.size()):
			var prev: float = maxf(float(cost[i - 1]), 0.0001)
			var ratio: float = float(cost[i]) / prev
			if ratio > worst and float(cost[i]) > 0.15:
				worst = ratio
				worst_at = i
		check("[%s] no cliff: no map costs %.0fx the map five before it"
			% [Campaign.tier_name(tier), CLIFF], worst < CLIFF,
			"worst step x%.2f%s" % [worst, "" if worst_at < 0
				else " at map %d" % (int(maps[worst_at]) + 1)])
	sections += 1


# ------------------------------------------------------------------------------
# 6. Is every map winnable, and is any map trivial?
# ------------------------------------------------------------------------------

func _winnable_and_not_trivial() -> void:
	print("\n=== 6. winnable, and worth winning ===")
	var lost_body: Array = []
	var lost_boss: Array = []
	var timeouts: Array = []
	var trivial: Array = []
	var cheap: Array = []
	var thin: Array = []
	var stuck: Array = []
	for row in _rows:
		var tag: String = "%s map %d %s" % [
			Campaign.tier_name(int(row["tier"])), int(row["index"]) + 1,
			String(row["class"])]
		if bool(row["lost_body"]):
			lost_body.append(tag)
		if bool(row["lost_boss"]):
			lost_boss.append("%s (%.0f%% in)" % [tag,
				float(row["boss_left"]) * 100.0])
		if bool(row["timeout"]):
			timeouts.append(tag)
		if float(row["ttk_boss"]) < BOSS_FLOOR and not bool(row["lost_boss"]):
			trivial.append("%s (%.1fs)" % [tag, float(row["ttk_boss"])])
		# Measured on the EXCHANGE RATE, not on damage actually taken: a shielded
		# champion takes nothing from one body, which says the kit is good, not
		# that the body is free.
		var rate: float = float(row["ttk_body"]) / maxf(float(row["ttl_body"]),
			0.001)
		if rate < 0.005:
			cheap.append("%s (%.4f bars a body)" % [tag, rate])
		if int(row["capacity"]) < CAPACITY_FLOOR:
			thin.append("%s (%d of %d)" % [tag, int(row["capacity"]),
				int(row["pack_size"])])
		# A ttk PINNED AT THE TIMEOUT is not a measurement, and it is the one
		# reading that quietly corrupts everything downstream: `bars` is
		# pressure x ttk, so a ttk that stopped at the 300 s wall reports the
		# map as costing exactly as much as a 300 s fight would and no more,
		# when the truth is that the champion's damage never got through at all
		# and the real figure is unbounded. Every such row makes the curve, the
		# cliff test and the class band read LOWER than the game is.
		if bool(row["unkillable"]):
			stuck.append("%s (%.0fs/%.0fs body/boss)" % [tag,
				float(row["ttk_body"]), float(row["ttk_boss"])])

	check("no map's rank and file can kill an on-level champion",
		lost_body.is_empty(), "%d lost duels%s" % [lost_body.size(),
			"" if lost_body.is_empty() else ": " + ", ".join(
				PackedStringArray(lost_body.slice(0, 5)))])
	check("no map's boss can kill an on-level champion", lost_boss.is_empty(),
		"%d lost boss fights%s" % [lost_boss.size(),
			"" if lost_boss.is_empty() else ": " + ", ".join(
				PackedStringArray(lost_boss.slice(0, 5)))])
	check("no fight runs out of time", timeouts.is_empty(),
		"%d timeouts%s" % [timeouts.size(),
			"" if timeouts.is_empty() else ": " + ", ".join(
				PackedStringArray(timeouts.slice(0, 5)))])
	check("no boss dies inside %.0f s" % BOSS_FLOOR, trivial.is_empty(),
		"%d trivial%s" % [trivial.size(),
			"" if trivial.is_empty() else ": " + ", ".join(
				PackedStringArray(trivial.slice(0, 5)))])
	check("no body in the game is free", cheap.is_empty(),
		"%d bodies cost under 0.2%% of a bar%s" % [cheap.size(),
			"" if cheap.is_empty() else ": " + ", ".join(
				PackedStringArray(cheap.slice(0, 5)))])
	check("a champion can hold at least %d of a pack at once" % CAPACITY_FLOOR,
		thin.is_empty(), "%d maps below it%s" % [thin.size(),
			"" if thin.is_empty() else ": " + ", ".join(
				PackedStringArray(thin.slice(0, 5)))])
	check("every time-to-kill is a measurement, not the %.0f s wall"
		% FIGHT_TIMEOUT, stuck.is_empty(),
		"%d rows pinned at the timeout%s" % [stuck.size(),
			"" if stuck.is_empty() else ": " + ", ".join(
				PackedStringArray(stuck.slice(0, 5)))])

	# A boss must also be worth more than the trash around it. BOSS_HEALTH_MULT
	# is x8 on paper; this measures it as a RATIO OF TIME, which is what the
	# player experiences, against the real bodies of the real map.
	var ratios: Array = []
	for row in _rows:
		if float(row["ttk_body"]) > 0.0 and not bool(row["lost_boss"]):
			ratios.append(float(row["ttk_boss"]) / float(row["ttk_body"]))
	ratios.sort()
	var median: float = float(ratios[ratios.size() / 2]) if not ratios.is_empty() \
		else 0.0
	check("a boss is a real fight next to the rank and file", median >= 4.0,
		"median boss takes %.1fx a body's time" % median)

	# HOW MUCH OF A PACK THE MATHS LEAVES ROOM FOR. Not an assertion beyond the
	# floor above — a worst case, reported as what it is.
	print("  pack capacity (bodies survivable at once, of the deepest pack):")
	for tier in TIERS:
		var caps: Array = []
		var sizes: Array = []
		for row in _rows:
			if int(row["tier"]) == tier:
				caps.append(float(row["capacity"]))
				sizes.append(float(row["pack_size"]))
		print("    %-10s mean %.1f of %.1f bodies" % [Campaign.tier_name(tier),
			_mean(caps), _mean(sizes)])
	sections += 1


# ------------------------------------------------------------------------------
# 7. Are the three classes playing the same game?
# ------------------------------------------------------------------------------

func _the_classes() -> void:
	print("\n=== 7. the three classes ===")
	# SUSTAIN AGAINST PRESSURE is printed here rather than asserted on (see
	# CLIFF): it is the one place the three kits are plainly not the same game —
	# a Ranger's slot 3 is a backstep and puts back no health at all — and the
	# question a tuning pass needs is whether the pressure of the map is above or
	# below what the class can answer.
	# TAKEN is the only one of these that is damage the champion ACTUALLY lost,
	# in the real interleaved duel with its whole kit up. It belongs beside the
	# others and not in place of them: it is the figure that saturates (see
	# CLIFF), reading near zero for a class whose shield covers a whole fight,
	# so it says "this kit answered this body" rather than "this body is cheap".
	print("  class     mean bars  mean ttk/body  mean ttk/boss  mean pack cap"
		+ "  taken/duel  sustain/s  press/s")
	var by_class: Dictionary = {}
	for row in _rows:
		var k: String = String(row["class"])
		if not by_class.has(k):
			by_class[k] = []
		(by_class[k] as Array).append(row)
	for k in by_class.keys():
		var rows: Array = by_class[k]
		print("  %-9s %9.2f  %12.2fs  %12.1fs  %13.1f  %9.1f%%  %9.4f %8.4f" % [k,
			_mean_field(rows, "bars"), _mean_field(rows, "ttk_body"),
			_mean_field(rows, "ttk_boss"), _mean_field(rows, "capacity"),
			_mean_field(rows, "taken") * 100.0,
			_mean_field(rows, "sustain"), _mean_field(rows, "press_body")])

	# PER MAP, not on the averages: a Mage twice as fast early and half as fast
	# late averages out to parity and is a trap at both ends.
	var worst_time: float = 1.0
	var worst_time_at: String = ""
	var worst_cost: float = 1.0
	var worst_cost_at: String = ""
	for tier in TIERS:
		for index in _sorted_maps():
			var times: Array = []
			var costs: Array = []
			for row in _rows:
				if int(row["tier"]) == tier and int(row["index"]) == index:
					times.append(float(row["ttk_body"]))
					costs.append(float(row["bars"]))
			if times.size() < 3:
				continue
			times.sort()
			costs.sort()
			var tr: float = float(times[2]) / maxf(float(times[0]), 0.001)
			if tr > worst_time:
				worst_time = tr
				worst_time_at = "%s map %d" % [Campaign.tier_name(tier), index + 1]
			# Same floor rule as the cliff test: a ratio between two tiny numbers
			# is not a balance problem.
			if float(costs[2]) > 0.15:
				var cr: float = float(costs[2]) / maxf(float(costs[0]), 0.001)
				if cr > worst_cost:
					worst_cost = cr
					worst_cost_at = "%s map %d" % [Campaign.tier_name(tier),
						index + 1]

	check("classes kill a body within %.1fx of each other" % CLASS_BAND_TIME,
		worst_time < CLASS_BAND_TIME, "worst x%.2f at %s" % [worst_time,
			worst_time_at if worst_time_at != "" else "nowhere"])
	check("...and pay within %.1fx of each other for a map" % CLASS_BAND_COST,
		worst_cost < CLASS_BAND_COST, "worst x%.2f at %s" % [worst_cost,
			worst_cost_at if worst_cost_at != "" else "nowhere"])

	# THE BUILD SENSITIVITY. Everything above spends skill points on the class's
	# primary attribute. If the band holds for only one build policy, the band is
	# an artefact of this harness rather than a property of the game.
	print("\n  build sensitivity (Normal) — primary vs mixed, bars / ttk-body:")
	var worst_build: float = 1.0
	var worst_build_at: String = ""
	for index in [0, 45, 95]:
		if not _maps.has(index):
			continue
		var line: PackedStringArray = PackedStringArray()
		for hero_name in _starters:
			var a: Dictionary = _measure(index, Campaign.Tier.NORMAL, hero_name,
				Build.PRIMARY)
			var b: Dictionary = _measure(index, Campaign.Tier.NORMAL, hero_name,
				Build.MIXED)
			line.append("%s %.2f/%.1fs vs %.2f/%.1fs" % [
				String(a["class"]).substr(0, 3), float(a["bars"]),
				float(a["ttk_body"]), float(b["bars"]), float(b["ttk_body"])])
			# EITHER WAY ROUND: the question is whether the choice of where the
			# skill points went decides the run, not which of the two is better.
			var hi: float = maxf(float(a["bars"]), float(b["bars"]))
			var lo: float = maxf(minf(float(a["bars"]), float(b["bars"])), 0.001)
			if hi / lo > worst_build:
				worst_build = hi / lo
				worst_build_at = "%s map %d" % [String(a["class"]), index + 1]
		print("    map %3d  %s" % [index + 1, "   ".join(line)])
	check("the two spending policies land within 1.5x of each other",
		worst_build < 1.5, "worst x%.2f at %s" % [worst_build,
			worst_build_at if worst_build_at != "" else "nowhere"])
	sections += 1


# ------------------------------------------------------------------------------
# 8. The loot
# ------------------------------------------------------------------------------

func _the_loot_curve() -> void:
	print("\n=== 8. the loot curve ===")
	print("  tier        first map   last map   ratio   gold a body")
	var rising: bool = true
	for tier in TIERS:
		var maps: Array = _sorted_maps()
		var first: float = _mean_of(tier, int(maps[0]), "loot")
		var last: float = _mean_of(tier, int(maps[maps.size() - 1]), "loot")
		var per_body: Array = []
		for row in _rows:
			if int(row["tier"]) == tier:
				per_body.append(float(row["loot"])
					/ maxf(float(row["bodies"]), 1.0))
		print("  %-10s %9.0f %10.0f %7.2f %13.1f" % [Campaign.tier_name(tier),
			first, last, last / maxf(first, 0.001), _mean(per_body)])
		if last <= first:
			rising = false
	check("a later map pays more than an earlier one", rising)

	# The tier step has to pay for itself, or the replay ladder is a punishment.
	var normal: float = _mean_tier("loot", Campaign.Tier.NORMAL)
	var hard: float = _mean_tier("loot", Campaign.Tier.MERCILESS)
	check("a harder tier pays more for the same hundred maps",
		hard > normal * 1.5,
		"Normal %.0f -> Merciless %.0f gold a map" % [normal, hard])

	# PAID PER SECOND, which is what a player optimising their time feels. A late
	# map that pays more in total but less per second is a reason to farm map 1.
	for tier in TIERS:
		var early: Array = []
		var late: Array = []
		var maps: Array = _sorted_maps()
		for row in _rows:
			if int(row["tier"]) != tier:
				continue
			# Seconds of fighting the map projects to: one duel per body.
			var secs: float = float(row["ttk_body"]) * float(row["bodies"]) \
				+ float(row["ttk_boss"])
			var rate: float = float(row["loot"]) / maxf(secs, 0.001)
			if int(row["index"]) <= int(maps[maps.size() / 4]):
				early.append(rate)
			elif int(row["index"]) >= int(maps[maps.size() * 3 / 4]):
				late.append(rate)
		print("  %-10s gold a second: first quarter %.1f, last quarter %.1f"
			% [Campaign.tier_name(tier), _mean(early), _mean(late)])
		check("[%s] late maps are not worse paid per second than early ones"
			% Campaign.tier_name(tier), _mean(late) >= _mean(early) * 0.75,
			"%.1f vs %.1f gold a second" % [_mean(late), _mean(early)])
	sections += 1


# ------------------------------------------------------------------------------
# 9. The level the campaign expects, against the level it grants
# ------------------------------------------------------------------------------

func _the_level_the_campaign_grants() -> void:
	print("\n=== 9. the level the campaign expects vs the level it grants ===")
	# WHAT THE CAMPAIGN GIVES YOU. Every kill pays Campaign.xp_per_kill through
	# the real HeroProgress.gain_xp; bodies per map come from the real encounters
	# of the sampled maps, with a sampled map standing in for its four
	# neighbours. No partner share, which would only make the gap wider.
	var p: HeroProgress = HeroProgress.create(_starters[0])
	var tier: int = Campaign.Tier.NORMAL
	print("  map   enemy lv   champion lv")
	var worst_over: int = 0
	var worst_at: int = 0
	for index in range(Campaign.map_count()):
		var sample: int = (index / MAP_STRIDE) * MAP_STRIDE
		var bodies: int = (_maps[sample]["spawns"][tier] as Array).size()
		# The level the champion ARRIVES at the map with, before its own kills.
		_granted[index] = p.level
		for _k in range(bodies):
			p.gain_xp(Campaign.xp_per_kill(index, tier))
		var want: int = Campaign.enemy_level(index, tier)
		if p.level - want > worst_over:
			worst_over = p.level - want
			worst_at = index
		if index == 0 or index % 10 == 9:
			print("  %3d %9d %13d" % [index + 1, want, p.level])

	check("the XP curve does not run away from the enemy curve",
		worst_over <= 12, "champion is +%d levels over the enemies by map %d"
			% [worst_over, worst_at + 1])
	check("...and the campaign does level a champion at all", p.level > 1,
		"level %d after one hundred maps" % p.level)
	sections += 1


# ------------------------------------------------------------------------------
# 10. The champion the campaign actually makes
#
# Sections 4 to 7 measure an ON-LEVEL champion, which is the only definition the
# code supports: level-matched to Campaign.enemy_level. Section 9 shows that is
# NOT the champion a player brings — the XP curve hands out levels far faster
# than the enemy curve climbs. So the same boss fights are re-measured at the
# level the campaign actually grants by that map, which separates two very
# different findings:
#
#   the boss numbers are wrong                 (it loses at both levels)
#   the on-level DEFINITION is wrong           (it loses on-level, wins at the
#                                               level the campaign grants)
# ------------------------------------------------------------------------------

func _the_champion_the_campaign_makes() -> void:
	print("\n=== 10. the same maps, at the level the campaign grants ===")
	# THE MARGIN, not a verdict: ttl / ttk is how many times over the champion
	# can survive the boss fight it is in. Above 1 it wins; 0.5 means it needs
	# twice the survivability it has, which is a quantity a tuning pass can use
	# and "LOST" is not.
	print("  map  on-level granted   boss margin (ttl/ttk) on-level"
		+ "     as played")
	var tier: int = Campaign.Tier.NORMAL
	var lost_on_level: int = 0
	var lost_granted: int = 0
	var rows: int = 0
	var worst_granted: float = INF
	for index in _sorted_maps():
		var want: int = _on_level(index, tier)
		var got: int = clampi(int(_granted.get(index, 1)), 1,
			HeroProgress.MAX_LEVEL)
		var on_line: PackedStringArray = PackedStringArray()
		var got_line: PackedStringArray = PackedStringArray()
		for hero_name in _starters:
			var a: Dictionary = _measure_at(index, tier, hero_name,
				Build.PRIMARY, want)
			var b: Dictionary = _measure_at(index, tier, hero_name,
				Build.PRIMARY, got)
			rows += 1
			if bool(a["lost_boss"]):
				lost_on_level += 1
			if bool(b["lost_boss"]):
				lost_granted += 1
			on_line.append("%s %.2f" % [String(a["class"]).substr(0, 3),
				_margin(a)])
			got_line.append("%s %.2f" % [String(b["class"]).substr(0, 3),
				_margin(b)])
			worst_granted = minf(worst_granted, _margin(b))
		print("  %3d %8d %7d   %-28s %s" % [index + 1, want, got,
			" ".join(on_line), " ".join(got_line)])

	print("  boss fights lost: %d of %d on-level, %d of %d at the granted level"
		% [lost_on_level, rows, lost_granted, rows])
	check("the boss is beatable by the champion the campaign actually makes",
		lost_granted == 0, "%d of %d lost, worst margin x%.2f"
			% [lost_granted, rows, worst_granted])
	check("...and levelling past the enemy curve at least helps",
		lost_granted <= lost_on_level,
		"on-level loses %d, as played loses %d" % [lost_on_level, lost_granted])

	# THE CEILING. If a champion at the level cap, in level-cap gear, still loses
	# the fight, then no amount of levelling or farming is the answer and the
	# boss's own multipliers are the thing that is wrong. Measured on the last
	# sampled map of every tier, which is where the curve is steepest.
	print("\n  a champion at the level cap (L%d), on the last sampled map:"
		% HeroProgress.MAX_LEVEL)
	print("  tier        class     ttk/boss  ttl/boss  margin   ttk/body"
		+ " ttl/body")
	var maps: Array = _sorted_maps()
	var last: int = int(maps[maps.size() - 1])
	var capped_ok: bool = true
	for t2 in TIERS:
		for hero_name in _starters:
			var row: Dictionary = _measure_at(last, t2, hero_name,
				Build.PRIMARY, HeroProgress.MAX_LEVEL)
			print("  %-10s %-8s %8.1fs %8.1fs %7.2f %9.1fs %8.1fs" % [
				Campaign.tier_name(t2), String(row["class"]),
				float(row["ttk_boss"]), float(row["ttl_boss"]), _margin(row),
				float(row["ttk_body"]), float(row["ttl_body"])])
			if bool(row["lost_boss"]):
				capped_ok = false
	check("a champion at the level cap can beat the campaign's last boss",
		capped_ok)
	sections += 1


# ------------------------------------------------------------------------------
# 11. WHY a boss fight is the length it is
#
# Sections 4 to 10 measure the campaign and report that some boss fights are many
# times longer than their neighbours — Normal map 36's boss takes 162 s where map
# 31's takes 27 s, and both are a level-10 Mage with 3389 health. Identical bodies
# and a six-fold difference in time is not a fact about the campaign curve, and a
# tuning pass given only the curve would move the wrong constant.
#
# So this section separates the three things that can make a champion's
# time-to-kill large, which every earlier section necessarily reports as one
# number:
#
#   THE BODY        the boss simply has a lot of health and armour. The intended
#                   mechanism, and the only one BOSS_HEALTH_MULT controls.
#   THE LOCKOUT     the champion spent the fight unable to act. Combatant.can_act
#                   is false for a STUN's whole duration, so an enemy whose stun
#                   rider outlasts its own cooldown holds the champion in a loop,
#                   and the fight reads as a boss with a lot of health.
#   THE HEALING     the boss put the damage back. Combat.cast heals the caster on
#                   any ability with heal_fraction, and a boss heals off an 8x
#                   health pool.
#
# The second and third are properties of WHICH CHAMPION the map rolled as its
# boss, not of the map, which is why they look like noise in the curve.
# ------------------------------------------------------------------------------

func _why_a_boss_fight_is_long() -> void:
	print("\n=== 11. why a boss fight is the length it is ===")

	# THE STATIC HALF, over the whole roster rather than the sampled maps: an
	# enemy kit whose stun lasts longer than its cooldown is a lock wherever it is
	# met, and sampling every fifth map would only tell us which twenty maps
	# happened to roll one. Only the slots the tier actually lets an enemy press
	# are counted — Campaign.enemy_actions is the gate.
	var offenders: Array = []
	var worst_duty: float = 0.0
	var worst_duty_at: String = ""
	for hero_name in _roster_names:
		var cls: int = HeroClass.for_hero(hero_name)
		var kit: Array[Ability] = Ability.for_hero(hero_name, cls)
		for slot in range(1, kit.size() + 1):
			var ab: Ability = kit[slot - 1]
			if ab.applies != StatusEffect.Kind.STUN:
				continue
			var duty: float = ab.applies_duration / maxf(ab.cooldown, 0.001)
			if duty > worst_duty:
				worst_duty = duty
				worst_duty_at = "%s slot %d (%s, %.1fs stun / %.1fs cd)" % [
					hero_name, slot, ab.title, ab.applies_duration, ab.cooldown]
			if duty > STUN_DUTY_CEILING:
				# The lowest tier that lets an enemy press this slot at all.
				var from_tier: int = -1
				for t in range(Campaign.tier_count()):
					if Campaign.enemy_actions(t) > slot:
						from_tier = t
						break
				offenders.append({"hero": hero_name, "slot": slot, "duty": duty,
					"tier": from_tier, "title": ab.title,
					"dur": ab.applies_duration, "cd": ab.cooldown,
					"kind": "%s %s" % [MageSpells.element_name(hero_name),
						HeroClass.display_name(cls)]
						if cls == HeroClass.Kind.MAGE
						else HeroClass.display_name(cls)})

	print("  stun riders over the %.0f%% duty ceiling, across all %d champions:"
		% [STUN_DUTY_CEILING * 100.0, _roster_names.size()])
	if offenders.is_empty():
		print("    none")
	else:
		offenders.sort_custom(func(a, b): return float(a["duty"]) > float(b["duty"]))
		var shown: int = mini(offenders.size(), 6)
		for i in range(shown):
			var o: Dictionary = offenders[i]
			print("    %-6s %-15s slot %d  %-14s %.1fs stun / %.1fs cd"
				% [o["hero"], String(o["kind"]), int(o["slot"]),
					String(o["title"]), float(o["dur"]), float(o["cd"])]
				+ " = %.0f%% uptime, from %s" % [float(o["duty"]) * 100.0,
					Campaign.tier_name(int(o["tier"]))])
		# Which classes and which slot, because that is what names the constant:
		# a slot-2 offender is the authored control ability and a slot-1 offender
		# is a stun riding the spammable damage ability.
		var on_slot1: int = 0
		for o in offenders:
			if int(o["slot"]) == 1:
				on_slot1 += 1
		print("    %d of %d sit on SLOT 1, the damage ability every tier allows"
			% [on_slot1, offenders.size()])

	check("no enemy's stun lasts longer than %.0f%% of its own cooldown"
		% (STUN_DUTY_CEILING * 100.0), offenders.is_empty(),
		"%d of %d champions%s" % [offenders.size(), _roster_names.size(),
			"" if worst_duty_at == "" else "; worst is " + worst_duty_at])

	# THE MEASURED HALF: the same boss fights section 4 took, instrumented. The
	# champion is immortal, so nothing here is about whether it wins — only about
	# how much of the fight it was allowed to play.
	print("\n  the boss fights, by what made them long"
		+ " (champion immortal, on-level):")
	print("  tier        map  class    ttk/boss  locked  boss healed  boss hp"
		+ "   the boss")
	var locked_rows: Array = []
	for tier in TIERS:
		for index in _sorted_maps():
			var level: int = _on_level(index, tier)
			var boss: Dictionary = _the_boss(_maps[index]["spawns"][tier])
			for hero_name in _starters:
				var hero: Unit = _champion(hero_name, level, index, tier,
					Build.PRIMARY, 0)
				hero.immortal = true
				var boss_unit: Unit = _unit_of(boss, tier, index, 0)
				var out: Dictionary = _fight(hero, [boss_unit], tier, true)
				var secs: float = maxf(float(out["time"]), DT)
				# BARS THE BOSS PUT BACK: its own healing over its own health
				# pool — see BOSS_HEAL_SHARE for why the damage dealt is the
				# wrong denominator.
				var share: float = boss_unit.healed \
					/ maxf(boss_unit.body.max_health, 0.001)
				locked_rows.append({
					"tier": tier, "index": index,
					"class": HeroClass.display_name(
						HeroClass.for_hero(hero_name)),
					"ttk": secs, "locked": float(out["locked"]),
					"heal_share": share, "healed": boss_unit.healed,
					"boss": (boss["spawn"] as Encounter.Spawn).hero,
					"boss_hp": boss_unit.body.max_health,
					"boss_cls": _kind_of(boss["spawn"] as Encounter.Spawn),
				})

	# Sorted by lockout: the rows a tuning pass needs to look at first, rather
	# than the whole 180 again.
	var by_lock: Array = locked_rows.duplicate()
	by_lock.sort_custom(func(a, b): return float(a["locked"]) > float(b["locked"]))
	for i in range(mini(by_lock.size(), 10)):
		var r: Dictionary = by_lock[i]
		print("  %-10s %4d  %-7s %8.1fs %6.0f%% %11.0f %8.0f   %s the %s" % [
			Campaign.tier_name(int(r["tier"])), int(r["index"]) + 1,
			String(r["class"]).substr(0, 7), float(r["ttk"]),
			float(r["locked"]) * 100.0, float(r["healed"]), float(r["boss_hp"]),
			String(r["boss"]), String(r["boss_cls"])])

	# AND THE SAME TABLE BY LENGTH. Sorting only by lockout answers "which fights
	# were a stun lock" and silently drops the opposite finding: a fight that is
	# enormous while the champion had every turn is the one row where the boss's
	# own multipliers really are the problem, and it never appears above.
	print("  the longest boss fights, whatever the cause:")
	var by_time: Array = locked_rows.duplicate()
	by_time.sort_custom(func(a, b): return float(a["ttk"]) > float(b["ttk"]))
	for i in range(mini(by_time.size(), 8)):
		var r2: Dictionary = by_time[i]
		print("  %-10s %4d  %-7s %8.1fs %6.0f%% %11.0f %8.0f   %s the %s" % [
			Campaign.tier_name(int(r2["tier"])), int(r2["index"]) + 1,
			String(r2["class"]).substr(0, 7), float(r2["ttk"]),
			float(r2["locked"]) * 100.0, float(r2["healed"]),
			float(r2["boss_hp"]), String(r2["boss"]), String(r2["boss_cls"])])

	var locked_over: Array = []
	var healed_over: Array = []
	for r in locked_rows:
		var tag: String = "%s map %d %s (boss %s)" % [
			Campaign.tier_name(int(r["tier"])), int(r["index"]) + 1,
			String(r["class"]), String(r["boss"])]
		if float(r["locked"]) > LOCKOUT_CEILING:
			locked_over.append("%s %.0f%% locked" % [tag,
				float(r["locked"]) * 100.0])
		if float(r["heal_share"]) > BOSS_HEAL_SHARE:
			healed_over.append("%s put back %.1f of its own bars" % [tag,
				float(r["heal_share"])])

	check("no boss keeps a champion unable to act for over %.0f%% of the fight"
		% (LOCKOUT_CEILING * 100.0), locked_over.is_empty(),
		"%d of %d boss fights%s" % [locked_over.size(), locked_rows.size(),
			"" if locked_over.is_empty() else ": " + ", ".join(
				PackedStringArray(locked_over.slice(0, 3)))])
	check("no boss heals back over %.0f%% of its own health bar"
		% (BOSS_HEAL_SHARE * 100.0), healed_over.is_empty(),
		"%d of %d boss fights%s" % [healed_over.size(), locked_rows.size(),
			"" if healed_over.is_empty() else ": " + ", ".join(
				PackedStringArray(healed_over.slice(0, 3)))])

	# HOW MUCH OF THE SPREAD IN BOSS TIME IS THE LOCKOUT. The headline question:
	# if the long fights are long because the champion was stunned, then
	# BOSS_HEALTH_MULT is not the constant to move.
	var free_ttk: Array = []
	var stuck_ttk: Array = []
	for r in locked_rows:
		if float(r["locked"]) > LOCKOUT_CEILING:
			stuck_ttk.append(float(r["ttk"]))
		else:
			free_ttk.append(float(r["ttk"]))
	print("  boss fights where the champion could act: mean %.0fs over %d fights"
		% [_mean(free_ttk), free_ttk.size()])
	print("  boss fights where it mostly could not:    mean %.0fs over %d fights"
		% [_mean(stuck_ttk), stuck_ttk.size()])
	sections += 1


## What a body IS, for the diagnostic tables: its class, and for a mage its
## ELEMENT as well. Every mage rolls its own spellbook from an element
## (MageSpells.element_of), and the element is what decides whether its damage
## spell carries a stun, a heal or nothing — so "Mage" alone is the one label
## that cannot explain why two bosses with identical bodies fought differently.
func _kind_of(spawn: Encounter.Spawn) -> String:
	var cls: String = HeroClass.display_name(spawn.cls)
	if spawn.cls == HeroClass.Kind.MAGE:
		return "%s %s" % [MageSpells.element_name(spawn.hero), cls]
	return cls


## How many times over the champion can survive the boss fight it is in: the
## boss's time to kill the champion, over the champion's time to kill the boss.
## Above 1.0 it wins.
func _margin(row: Dictionary) -> float:
	return float(row["ttl_boss"]) / maxf(float(row["ttk_boss"]), 0.001)


# ------------------------------------------------------------------------------
# Measuring one map
# ------------------------------------------------------------------------------

## Measure one map, at one tier, for one champion.
##
## WHAT IS MEASURED, AND WHY IT IS MEASURED IN PIECES.
##
##   ttk   time to kill, with the CHAMPION immortal — the champion's throughput
##         against that body and nothing else
##   ttl   time to live, with the ENEMY immortal and the champion fighting back
##         with its whole kit — the champion's survivability against that body
##   duel  one real interleaved fight, which supplies the VERDICT: would the
##         champion have died
##   cap   how many of the deepest pack it survives at once
##
## ONE SIDE IMMORTAL, and this is the fix for two separate wrong numbers.
##
## Damage actually TAKEN in a duel is useless as a difficulty index: Rally and
## Ward absorb 30% of a health bar every 16 and 14 seconds, which is more than
## one ordinary body produces in the two seconds it survives, so the figure reads
## 0.000 for two classes out of three and then jumps to 1.000 the instant a fight
## is lost. It saturates.
##
## And the DURATION of a lost fight is worse than useless as a time-to-kill: it
## reads as a SHORT boss fight, so the hardest maps in the game come out looking
## like the easiest. Extrapolating it from the damage dealt helps, but a fight
## lost at 6% of the boss's health is a projection off a sixteenth of the data
## and it moved the measured cost of a map by a factor of eight.
##
## Measured separately, both are stable: ttk is bounded by the enemy's health
## pool, ttl by the champion's, and `bars` — ttk / ttl summed over the map — is
## the share of the champion's whole survivability budget the map consumes. It
## cannot saturate, and it is built from two numbers that each depend on only one
## side of the fight.
func _measure(index: int, tier: int, hero_name: String, build: int) -> Dictionary:
	var spawns: Array = _maps[index]["spawns"][tier]
	var level: int = _on_level(index, tier)
	return _measure_at(index, tier, hero_name, build, level)


## The same measurement at an arbitrary champion level, so section 10 can ask
## what the campaign's own XP curve makes of the same maps.
func _measure_at(index: int, tier: int, hero_name: String, build: int,
		level: int) -> Dictionary:
	var spawns: Array = _maps[index]["spawns"][tier]
	var typical: Dictionary = _typical_body(spawns)
	var boss: Dictionary = _the_boss(spawns)
	var deepest: Array = _deepest_pack(spawns)

	var slam_pct: float = 0.0
	var slam_raw: float = 0.0
	var boss_left: float = 0.0
	var lost_body: bool = false
	var lost_boss: bool = false
	var stalemate: bool = false
	var max_hp: float = 0.0
	var sustain: float = 0.0
	# DAMAGE TAKEN PER FIGHT, as a fraction of the champion's health bar, in the
	# real interleaved duel — the champion defending itself with its whole kit.
	# Reported rather than asserted on: it is the quantity that saturates (see
	# CLIFF), which is why `bars` is built out of pressure instead.
	var taken: float = 0.0
	var cls_name: String = HeroClass.display_name(HeroClass.for_hero(hero_name))

	# THE VERDICT: real interleaved duels, repeated, because near parity the
	# winner is decided by the crit and dodge streams and one fight is one sample.
	for trial in range(REPEATS):
		var hero: Unit = _champion(hero_name, level, index, tier, build, trial)
		max_hp = hero.body.max_health
		sustain = _sustain(hero)
		var foe: Unit = _unit_of(typical, tier, index, trial)
		var out: Dictionary = _fight(hero, [foe], tier, false)
		lost_body = lost_body or not hero.body.alive
		taken += float(out["taken"]) / maxf(max_hp, 0.001) / float(REPEATS)
		stalemate = stalemate or bool(out["timeout"])

		# THE BOSS, from full health: a boss fight the player arrives at on
		# fumes is a question about the lane, not about the boss.
		var champ2: Unit = _champion(hero_name, level, index, tier, build, trial)
		var boss_unit: Unit = _unit_of(boss, tier, index, trial)
		var out2: Dictionary = _fight(champ2, [boss_unit], tier, true)
		slam_pct = maxf(slam_pct, float(out2["slam_pct"]))
		slam_raw = maxf(slam_raw, float(out2["slam_raw"]))
		if not champ2.body.alive:
			lost_boss = true
			# How much of the boss was left, so a lost fight says whether it was
			# close or hopeless.
			boss_left = maxf(boss_left, boss_unit.body.health_fraction())
		stalemate = stalemate or bool(out2["timeout"])

	# THE ONE-SIDED RUNS. One trial each: with one side immortal the fight runs
	# for thousands of rolls, so the crit and dodge streams have already averaged
	# out by the end of it.
	var ttk_body: float = _ttk(hero_name, level, index, tier, build, typical,
		false)
	var ttk_boss: float = _ttk(hero_name, level, index, tier, build, boss, true)
	var ttl_body: float = _ttl(hero_name, level, index, tier, build, typical,
		false)
	var ttl_boss: float = _ttl(hero_name, level, index, tier, build, boss, true)
	# PRESSURE: health bars a second this map takes off an undefended champion.
	var press_body: float = _pressure(hero_name, level, index, tier, build,
		typical, false)
	var press_boss: float = _pressure(hero_name, level, index, tier, build, boss,
		true)
	# A champion the enemy cannot kill at all. Not a failure — it is the shape of
	# the early campaign, and the capped ttl simply makes those maps cost little.
	var outlasts: bool = ttl_body >= FIGHT_TIMEOUT or ttl_boss >= FIGHT_TIMEOUT
	# A champion that cannot kill the enemy at all, which IS a failure.
	var unkillable: bool = ttk_body >= FIGHT_TIMEOUT or ttk_boss >= FIGHT_TIMEOUT

	# HOW MANY AT ONCE. Also one trial: a capacity, not a distribution.
	var capacity: int = 0
	for k in range(1, deepest.size() + 1):
		var hero3: Unit = _champion(hero_name, level, index, tier, build, 0)
		var foes: Array = []
		for i in range(k):
			foes.append(_unit_of(deepest[i], tier, index, 0))
		_place(foes)
		_fight(hero3, foes, tier, false)
		if not hero3.body.alive:
			break
		capacity = k

	# THE DIFFICULTY INDEX: health bars the map costs a champion with no sustain.
	# One body's cost is the pressure it applies times how long the champion has
	# to stand in it, which is exactly "fraction of a health bar per body"; the
	# map is that once per body plus the boss's own.
	var bodies: int = maxi(spawns.size() - 1, 1)
	var bars_body: float = press_body * ttk_body
	var bars_boss: float = press_boss * ttk_boss
	var bars: float = bars_body * float(bodies) + bars_boss

	# THE BODIES THAT WERE ACTUALLY MEASURED, carried out so a strange row can be
	# read rather than guessed at. The first version of this harness reported a
	# boss on one map taking six times the time of the boss five maps earlier and
	# there was no way to tell from the output whether that was its health, its
	# level or its class — which made the single most interesting finding in the
	# sweep unusable.
	var boss_body: Combatant = _unit_of(boss, tier, index, 0).body
	var body_body: Combatant = _unit_of(typical, tier, index, 0).body

	return {
		"index": index, "tier": tier, "hero": hero_name, "class": cls_name,
		"level": level, "max_hp": max_hp, "bodies": bodies,
		"boss_lv": boss_body.level, "boss_hp": boss_body.max_health,
		"boss_cls": HeroClass.display_name((boss["spawn"] as Encounter.Spawn).cls),
		"boss_dodge": boss_body.stats.dodge_chance(),
		"body_lv": body_body.level, "body_hp": body_body.max_health,
		"ttk_body": ttk_body, "ttl_body": ttl_body,
		"ttk_boss": ttk_boss, "ttl_boss": ttl_boss,
		"press_body": press_body, "press_boss": press_boss,
		"bars_body": bars_body, "bars_boss": bars_boss,
		"sustain": sustain, "taken": taken,
		"boss_left": boss_left, "bars": bars,
		"slam_pct": slam_pct, "slam_raw": slam_raw, "capacity": capacity,
		"pack_size": deepest.size(),
		"loot": _loot_of_map(spawns, index, tier, level),
		"lost_body": lost_body, "lost_boss": lost_boss,
		"outlasts": outlasts, "unkillable": unkillable, "timeout": stalemate,
	}


## TIME TO KILL: how long the champion needs to put one enemy down, with the
## champion immortal so the answer depends on the champion's output and the
## enemy's health pool and on nothing else.
func _ttk(hero_name: String, level: int, index: int, tier: int, build: int,
		entry: Dictionary, boss_phase: bool) -> float:
	var hero: Unit = _champion(hero_name, level, index, tier, build, 0)
	hero.immortal = true
	var foe: Unit = _unit_of(entry, tier, index, 0)
	return float(_fight(hero, [foe], tier, boss_phase)["time"])


## TIME TO LIVE: how long the champion survives one enemy it cannot kill, FIGHTING
## BACK with its whole kit — so the shield, the heal and the stun all count, which
## is the honest measure of what the class brings defensively.
func _ttl(hero_name: String, level: int, index: int, tier: int, build: int,
		entry: Dictionary, boss_phase: bool) -> float:
	var hero: Unit = _champion(hero_name, level, index, tier, build, 0)
	var foe: Unit = _unit_of(entry, tier, index, 0)
	foe.immortal = true
	return float(_fight(hero, [foe], tier, boss_phase)["time"])


## PRESSURE: fractions of the champion's health bar a second that this enemy takes
## off an UNDEFENDED champion. The map's OUTPUT, with the champion's answer to it
## deliberately left out of the measurement.
##
## Undefended because a defended figure saturates, which is the whole reason this
## function exists: Rally and Ward each put up 30% of a health bar on a 16 s and a
## 14 s cooldown, which is more than one ordinary body produces in the two seconds
## it survives. Measured on a defended champion, damage taken reads 0.000 for two
## classes out of three and then jumps to 1.000 the instant a fight is lost — it is
## a step function, not a difficulty index (see CLIFF). What the map applies and
## what the champion answers it with are two different quantities, so they are
## measured apart: pressure here, the champion's own sustain in _sustain.
##
## The champion is a BAG — never decides, so no shield is ever up, no heal ever
## lands and no stun it would have placed ever takes an enemy's turn away — and
## IMMORTAL, so the window runs its full length instead of ending early at a
## death. The enemy is immortal too: a bag deals no damage, but a burn left on it
## by nothing at all is cheaper to rule out than to reason about.
##
## Its armour and its dodge chance DO count. Those are the body the campaign built,
## not a decision the player makes in the fight, and `bars` is meant to be the cost
## of the map to this champion.
func _pressure(hero_name: String, level: int, index: int, tier: int, build: int,
		entry: Dictionary, boss_phase: bool) -> float:
	var bag: Unit = _champion(hero_name, level, index, tier, build, 0)
	bag.passive = true
	bag.immortal = true
	var foe: Unit = _unit_of(entry, tier, index, 0)
	foe.immortal = true
	var out: Dictionary = _fight(bag, [foe], tier, boss_phase, PRESSURE_WINDOW)
	return float(out["taken"]) / maxf(bag.body.max_health, 0.001) \
		/ maxf(float(out["time"]), DT)


## SUSTAIN: fractions of a health bar a second the champion's own kit puts back,
## amortised over its cooldowns. The quantity pressure is up against.
##
## READ FROM THE REAL ABILITIES rather than simulated, and the reason is the call
## site: this is called on the champion that is about to fight, and measuring
## sustain by simulation would mean casting its abilities first, which would put
## that body into the duel with its cooldowns already spent and its shield already
## burnt. Combat.cast's own defaulting rule is honoured here (an authored shield
## magnitude of zero means 30% of the caster's bar), so the figure moves when the
## kit moves.
##
## It is therefore a CEILING — perfect uptime, nothing overhealed, nothing wasted
## on a full bar — and it is reported beside pressure rather than asserted on,
## because what a player gets out of a 16 s cooldown depends on when they press it.
func _sustain(hero: Unit) -> float:
	if hero == null or hero.body == null:
		return 0.0
	var per_second: float = 0.0
	var kit: Array = []
	kit.append_array(hero.kit)
	kit.append(hero.basic)
	for a in kit:
		var ab := a as Ability
		if ab == null:
			continue
		var put_back: float = hero.body.max_health * ab.heal_fraction
		if ab.self_applies == StatusEffect.Kind.SHIELD:
			put_back += ab.self_magnitude if ab.self_magnitude > 0.0 \
				else hero.body.max_health * SHIELD_OF_MAX_HEALTH
		if put_back <= 0.0:
			continue
		# The basic attack is the only ability that can have no cooldown, and it
		# sustains nothing — but dividing by zero here would hand every class an
		# infinite one, so the step is the floor.
		per_second += put_back / maxf(ab.cooldown, DT)
	return per_second / maxf(hero.body.max_health, 0.001)


## THE LEVEL THE CAMPAIGN EXPECTS AT A MAP, which the game never states.
##
## Nothing in the codebase names one: the campaign gates a TIER on
## Campaign.min_level and scales enemies with Campaign.enemy_level, and that is
## all. So an on-level champion is defined here as level-matched to the enemies it
## is facing, raised to the tier's own gate (a player cannot be below it) and
## capped at HeroProgress.MAX_LEVEL. Every number in the sweep is relative to this
## definition, so it is printed in the output rather than buried here.
func _on_level(index: int, tier: int) -> int:
	return clampi(maxi(Campaign.enemy_level(index, tier),
		Campaign.min_level(tier)), 1, HeroProgress.MAX_LEVEL)


## Which map a champion of this level belongs on at Normal — only used to dress
## the champion in level-appropriate gear for the section-2 comparison.
func _map_for_level(level: int) -> int:
	for index in range(Campaign.map_count()):
		if Campaign.enemy_level(index, Campaign.Tier.NORMAL) >= level:
			return index
	return Campaign.map_count() - 1


## The body a map is MOSTLY made of: the median-level ordinary pack member. Not
## the mean and not the first — a map's pack levels ramp down the lane
## (Encounter.LANE_LEVEL_RAMP) and elites sit a level above, so the median
## ordinary body is the one the player meets most.
func _typical_body(spawns: Array) -> Dictionary:
	var ordinary: Array = []
	for i in range(spawns.size()):
		var s := spawns[i] as Encounter.Spawn
		if s == null or s.is_boss or s.is_elite:
			continue
		ordinary.append({"spawn": s, "ord": i})
	if ordinary.is_empty():
		# A map of nothing but elites is legal at high dread; take the median of
		# everything that is not the boss rather than giving up.
		for i in range(spawns.size()):
			var s2 := spawns[i] as Encounter.Spawn
			if s2 != null and not s2.is_boss:
				ordinary.append({"spawn": s2, "ord": i})
	ordinary.sort_custom(func(a, b): return (a["spawn"] as Encounter.Spawn).level \
		< (b["spawn"] as Encounter.Spawn).level)
	return ordinary[ordinary.size() / 2]


func _the_boss(spawns: Array) -> Dictionary:
	for i in range(spawns.size()):
		var s := spawns[i] as Encounter.Spawn
		if s != null and s.is_boss:
			return {"spawn": s, "ord": i}
	return _typical_body(spawns)


## The pack at the boss's door: the deepest, the biggest-levelled, and the one
## that always fields an elite (see Encounter._spine). The hardest group the map
## asks the player to take at once.
func _deepest_pack(spawns: Array) -> Array:
	var best: int = -1
	for s in spawns:
		var spawn := s as Encounter.Spawn
		if spawn != null and not spawn.is_boss:
			best = maxi(best, spawn.pack)
	var out: Array = []
	for i in range(spawns.size()):
		var spawn2 := spawns[i] as Encounter.Spawn
		if spawn2 != null and not spawn2.is_boss and spawn2.pack == best:
			out.append({"spawn": spawn2, "ord": i})
	return out


## One enemy, exactly as the game builds it: the real body, the real kit, the
## tier's action allowance, and its elite trait if it has one.
func _unit_of(entry: Dictionary, tier: int, index: int, trial: int) -> Unit:
	var spawn := entry["spawn"] as Encounter.Spawn
	var u := Unit.new()
	# Encounter.body_for carries the tier multipliers, the mercy ramp, the boss
	# multipliers and the level the lane gave it.
	u.body = Encounter.body_for(spawn, tier)
	# Salted per repeat so the crit/dodge stream differs between trials; the body
	# itself is identical, so only the luck moves.
	u.body.rng_seed = Rng.hash2(u.body.rng_seed, trial, 4241)
	u.basic = Ability.basic_attack(spawn.cls)
	u.kit = Ability.for_hero(spawn.hero, spawn.cls)
	u.allowed = Campaign.enemy_actions(tier)
	u.is_boss = spawn.is_boss
	u.is_elite = spawn.is_elite
	u.label = spawn.hero
	u.at = Vector2(0.0, CONTACT)
	if spawn.is_elite:
		# Play rolls the trait from the world seed and the spawn's ordinal.
		u.trait_id = Elite.Trait.NONE
	return u


## Where a pack stands: spread across the champion's facing at contact range, so
## an arc ability's cone and its max_targets both decide what it reaches, through
## the real Ability.covers.
func _place(foes: Array) -> void:
	var n: int = foes.size()
	for i in range(n):
		var frac: float = 0.0 if n <= 1 else (float(i) / float(n - 1) - 0.5) * 2.0
		var ang: float = deg_to_rad(SPREAD_DEG) * frac
		(foes[i] as Unit).at = Vector2(sin(ang), cos(ang)) * CONTACT


# ------------------------------------------------------------------------------
# The fight
# ------------------------------------------------------------------------------

## Resolve one fight to its end. Returns what it cost and how long it took.
##
## `limit` is the wall the fight stops at. It is the give-up timeout for a real
## fight, and a deliberate WINDOW for _pressure, where neither side can die and
## the question is not who won but how hard the enemy hits over a fixed span.
func _fight(hero: Unit, foes: Array, tier: int, boss_phase: bool,
		limit: float = FIGHT_TIMEOUT) -> Dictionary:
	var t: float = 0.0
	var dealt: float = 0.0
	var ttk: Array = []
	var dead: Array = []
	var last_death: float = 0.0
	var slam_pct: float = 0.0

	# THE REAL SIGNAL, rather than a health diff: Combatant.damaged is what the
	# HUD, the audio and the floating numbers all read, and a heal mid-fight would
	# make a health diff understate what the champion actually absorbed.
	var taken_box: Array = [0.0]
	var cb := func(amount: float, _crit: bool, _source: String) -> void:
		taken_box[0] += amount
	hero.body.damaged.connect(cb)

	# The boss's slam, on Play's clock. _slam_cd starts at zero there, so the
	# first wind-up begins as soon as the fight does.
	var slam_cd: float = 0.0
	var slam_in: float = -1.0
	var slam_dmg: float = 0.0
	var slam_raw: float = 0.0
	var brain: float = 0.0
	# THE HEALTH THE FIGHT STARTED WITH, so a LOST fight still yields a time to
	# kill. Reporting the duration of a fight the champion lost as its "time to
	# kill the boss" is the worst kind of wrong number: it reads as a SHORT boss
	# fight, so the hardest maps in the game come out looking like the easiest.
	# What is reported instead is the projected full kill time, elapsed divided by
	# the share of the enemy's health that was actually removed.
	var hp0: float = maxf(_total_health(foes), 0.001)

	# STEPS THE CHAMPION SPENT UNABLE TO ACT, against steps it was alive for. A
	# stun lock is invisible in every other figure this harness takes: the
	# champion simply deals no damage, so the fight reads as a boss with a lot of
	# health rather than as a champion that never got a turn. See section 11.
	var locked_steps: int = 0
	var live_steps: int = 0

	while t < limit:
		if not hero.body.alive:
			break
		live_steps += 1
		if not hero.body.can_act():
			locked_steps += 1
		var living: int = 0
		for f in foes:
			if (f as Unit).body.alive:
				living += 1
		if living == 0:
			break

		# Enemies decide on the brain's clock, not every frame — Play.THINK.
		var think: bool = false
		brain -= DT
		if brain <= 0.0:
			brain = PlayRules.THINK
			think = true

		if boss_phase:
			slam_cd = maxf(slam_cd - DT, 0.0)
			if slam_in > 0.0:
				slam_in -= DT
				if slam_in <= 0.0:
					# DODGED, which is the designed outcome of a telegraph —
					# recorded as what a missed dodge would have cost rather
					# than applied to the champion.
					slam_pct = maxf(slam_pct, minf(slam_dmg,
						hero.body.max_health * PlayRules.SLAM_MAX_FRACTION)
						/ maxf(hero.body.max_health, 0.001))
					# UNCAPPED TOO, because the cap is itself a balance figure:
					# once the raw slam is above SLAM_MAX_FRACTION, SLAM_POWER
					# has stopped meaning anything and the cap is the mechanic.
					slam_raw = maxf(slam_raw,
						slam_dmg / maxf(hero.body.max_health, 0.001))
					slam_in = -1.0
			elif think and slam_cd <= 0.0:
				for f in foes:
					var b := f as Unit
					if b.is_boss and b.body.alive:
						slam_dmg = b.body.attack_power() * PlayRules.SLAM_POWER
						slam_in = PlayRules.slam_warn(tier)
						slam_cd = PlayRules.SLAM_COOLDOWN
						# The wind-up IS the boss's heaviest ability, so it costs
						# the boss that action too — Play calls use_ability(2).
						b.begin(2)
						break

		var before: float = _total_health(foes)
		_step([hero], foes, think)
		dealt += maxf(before - _total_health(foes), 0.0)

		for f in foes:
			var u := f as Unit
			if not u.body.alive and not dead.has(u):
				dead.append(u)
				ttk.append(t - last_death)
				last_death = t
		t += DT

	hero.body.damaged.disconnect(cb)
	var alive_left: int = 0
	for f in foes:
		if (f as Unit).body.alive:
			alive_left += 1
	var progress: float = clampf(1.0 - _total_health(foes) / hp0, 0.01, 1.0)
	return {
		"time": t, "proj": t / progress, "progress": progress,
		"taken": float(taken_box[0]), "dealt": dealt,
		"kills": dead.size(), "ttk": ttk, "dead": dead,
		"slam_pct": slam_pct, "slam_raw": slam_raw,
		"timeout": t >= limit and alive_left > 0,
		"resolved": alive_left == 0,
		"locked": float(locked_steps) / float(maxi(live_steps, 1)),
	}


## One simulated frame. `allies` act every frame — the player's hand is on the
## glass and Play's auto-attack runs per frame; `foes` act on the brain tick.
func _step(allies: Array, foes: Array, think: bool = true) -> void:
	# Before anything else, so a body that was killed last step is back up and
	# acting rather than spending this step dead.
	for u in allies + foes:
		var unit := u as Unit
		if unit != null and unit.immortal:
			unit.body.health = unit.body.max_health
			unit.body.alive = true
	for a in allies:
		_advance_unit(a as Unit, foes, true)
	for f in foes:
		_advance_unit(f as Unit, allies, think)


## Advance one unit by DT: statuses, cooldowns, the cast that is landing, and
## then the next decision.
func _advance_unit(u: Unit, enemies: Array, may_decide: bool) -> void:
	if u == null or u.body == null or not u.body.alive:
		return
	var was_busy: bool = u.busy > 0.0
	u.advance(DT)
	if was_busy and u.busy <= 0.0 and u.pending != null:
		var ab: Ability = u.pending
		u.pending = null
		_resolve(u, ab, enemies)
		return
	if u.passive or u.busy > 0.0 or not u.ready() or not may_decide:
		return
	var nearest: Unit = _nearest_living(u, enemies)
	if nearest == null:
		return
	u.begin(u.choose(u.at.distance_to(nearest.at)))


## A cast lands. Straight through the real Combat.cast, over real positions.
func _resolve(u: Unit, ab: Ability, enemies: Array) -> void:
	var ctx := Combat.Context.new()
	ctx.caster = u.body
	ctx.origin = u.at
	# Facing what it is swinging at, as HeroController.use_ability turns the body
	# toward its target before the clip plays.
	ctx.facing = 0.0
	var nearest: Unit = _nearest_living(u, enemies)
	if nearest != null:
		var d: Vector2 = nearest.at - u.at
		if d.length_squared() > 0.0001:
			ctx.facing = atan2(d.x, d.y)
	var ts: Array[Combatant] = []
	var ps := PackedVector2Array()
	for e in enemies:
		var other := e as Unit
		if other == null or other.body == null or not other.body.alive:
			continue
		ts.append(other.body)
		ps.append(other.at)
	ctx.targets = ts
	ctx.positions = ps
	var r: Combat.Result = Combat.cast(ab, ctx)
	u.healed += r.healed
	# Play calls Elite.on_hit on whatever the cast landed on, so venom, rot and
	# the mender's own lifesteal all ride the hit that did the damage.
	if u.trait_id != Elite.Trait.NONE:
		for hit in r.hit:
			Elite.on_hit(u.trait_id, u.body, hit)


func _nearest_living(u: Unit, candidates: Array) -> Unit:
	var best: Unit = null
	var best_d: float = INF
	for c in candidates:
		var other := c as Unit
		if other == null or other.body == null or not other.body.alive:
			continue
		var d: float = u.at.distance_squared_to(other.at)
		if d < best_d:
			best_d = d
			best = other
	return best


func _total_health(foes: Array) -> float:
	var total: float = 0.0
	for f in foes:
		var u := f as Unit
		if u.body.alive:
			total += u.body.health
	return total


# ------------------------------------------------------------------------------
# The champion
# ------------------------------------------------------------------------------

## Build the champion the way the game does: a real Roster, a real HeroProgress
## at the level the campaign expects, its skill points spent, and the gear the
## previous map's drops gave it — then Combat.champion_body, which is the one
## door from progression into combat.
func _champion(hero_name: String, level: int, index: int, tier: int, build: int,
		trial: int) -> Unit:
	var roster: Roster = Roster.create(_roster_names, CAMPAIGN_SEED)
	var p: HeroProgress = roster.progress(hero_name)
	p.level = clampi(level, 1, HeroProgress.MAX_LEVEL)
	_spend(p, build)
	_gear(roster, hero_name, index, tier, p.level)

	var u := Unit.new()
	u.body = Combat.champion_body(roster, hero_name, p.level,
		Rng.hash2(Rng.seed_of(CAMPAIGN_SEED, hero_name), trial, 9311), hero_name)
	var cls: int = HeroClass.for_hero(hero_name)
	u.basic = Ability.basic_attack(cls)
	u.kit = Ability.for_hero(hero_name, cls)
	u.allowed = 4
	u.at = Vector2.ZERO
	u.label = hero_name
	return u


## Spend every skill point the level entitles the champion to.
func _spend(p: HeroProgress, build: int) -> void:
	var points: int = p.unspent_points()
	if points <= 0:
		return
	var primary: int = HeroClass.primary_attr(p.hero_class)
	if build == Build.PRIMARY:
		p.spend(primary, points)
		return
	var con: int = int(float(points) / 3.0)
	p.spend(Stats.Attr.CONSTITUTION, con)
	p.spend(primary, points - con)


## Dress the champion in typical gear for its level and tier — see GEAR_KILLS for
## why the stream is keyed on those two and not on the map.
##
## The drops are rolled at the champion's own level, which is what Loot.item_level
## caps them to anyway (champion level + LEVEL_HEADROOM), so this is the gear a
## player who has been killing things at their own level is wearing.
func _gear(roster: Roster, hero_name: String, _index: int, tier: int,
		level: int) -> void:
	var seed: int = Rng.seed_of(CAMPAIGN_SEED, "gear.%d.%d" % [level, tier])
	for k in range(GEAR_KILLS):
		var d: Loot.Drop = Loot.roll(seed, k, level, tier, level)
		if d.has_item():
			roster.stash.add(d.item)
	roster.stash.auto_equip(hero_name, HeroClass.for_hero(hero_name))


## A plain level-matched body, for the model checks in section 1 only.
func _dummy(level: int, cls: int, seed: int) -> Unit:
	var u := Unit.new()
	var st: Stats = HeroClass.base_stats(cls).plus(HeroClass.growth_to(cls, level))
	u.body = Combatant.make("dummy", Combatant.Team.ENEMY, level, st,
		HeroClass.school_of(cls), 4.0 * float(level), 3.0 * float(level), seed)
	u.basic = Ability.basic_attack(cls)
	u.kit = Ability.for_hero("dummy", cls)
	u.at = Vector2(0.0, CONTACT)
	u.label = "dummy"
	return u


# ------------------------------------------------------------------------------
# Loot
# ------------------------------------------------------------------------------

## What clearing the map is worth, in gold: the real Loot.roll once per body, in
## the kill order the region would see, with an item valued at what the merchant
## would pay for it (Shop.sell_value) — the only common currency between a sword
## and a pile of coins.
func _loot_of_map(spawns: Array, index: int, tier: int, level: int) -> float:
	var region_seed: int = Campaign.region_seed(CAMPAIGN_SEED, index)
	var total: float = 0.0
	for i in range(spawns.size()):
		var s := spawns[i] as Encounter.Spawn
		if s == null:
			continue
		var d: Loot.Drop = Loot.roll(region_seed, i, s.level, tier, level)
		total += float(d.gold)
		if d.has_item():
			total += float(Shop.sell_value(d.item))
	return total


# ------------------------------------------------------------------------------
# Arithmetic over the rows
# ------------------------------------------------------------------------------

func _sorted_maps() -> Array:
	var keys: Array = _maps.keys()
	keys.sort()
	return keys


func _mean(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total: float = 0.0
	for v in values:
		total += float(v)
	return total / float(values.size())


func _mean_slice(values: Array, from: int, to: int) -> float:
	return _mean(values.slice(maxi(from, 0), mini(to, values.size())))


## One field, averaged over the three classes of one map at one tier.
func _mean_of(tier: int, index: int, field: String) -> float:
	var out: Array = []
	for row in _rows:
		if int(row["tier"]) == tier and int(row["index"]) == index:
			out.append(float(row[field]))
	return _mean(out)


func _mean_field(rows: Array, field: String) -> float:
	var out: Array = []
	for row in rows:
		out.append(float(row[field]))
	return _mean(out)


func _mean_tier(field: String, tier: int) -> float:
	var out: Array = []
	for row in _rows:
		if int(row["tier"]) == tier:
			out.append(float(row[field]))
	return _mean(out)
