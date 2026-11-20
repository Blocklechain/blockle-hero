extends SceneTree
# ------------------------------------------------------------------------------
# Is a lane INHABITED, and does the campaign have a cast?
#
# scripts/game/Encounter.gd answers two questions that look like one: WHERE the
# enemies of a map stand, and WHICH champions they are. Both have failure modes
# that compile, run, and look fine in a print-out:
#
#   * "distributed along the lane" that is in fact one crowd at the entrance,
#     because an even spread was asked for and a random draw was written
#   * spawns ON the lane that are three metres into the hillside beside it —
#     invisible, unkillable, and heard rather than seen
#   * a pack inside the entrance's safe radius, so the map opens in contact
#   * a boss standing in the corridor instead of its arena, met by a player who
#     still has four packs behind them
#   * a "per-map cast" that is a uniform random draw, which makes all hundred
#     maps the same statistical soup of 139 names
#   * a cast that is stable only until the game is restarted
#   * a late map that is longer but not harder, because density, elites and the
#     boss were each tuned in their own place instead of from Campaign.dread
#   * a boss whose numbers all look plausible one tier at a time, while the tier
#     multiplier is in fact applied to it twice — which is what body_for()
#     shipped doing. See _the_bodies: the symptom is a boss/pack ratio that is a
#     function of the difficulty, and no single-tier assertion can see it.
#
# So this is a measuring instrument. It builds the cast table for the whole
# hundred-map campaign and measures the recurrence in it, then builds TWO REAL
# REGIONS — an early map and a late one, full 384-cell terrain with real noise,
# real rim and real walkability — populates them, and PATH-FINDS from the
# entrance to every single spawn. Then it does the same to EVERY ELEVENTH MAP of
# the campaign, because the two maps read closely while writing a test are the
# two it is easiest to accidentally fit, and a dread curve measured at two points
# is not yet a curve.
#
# The arena ring is tested too, in the same region: it is the PvP placement, it
# predates the lane, and the one thing a new code path must not do is quietly
# break it.
#
#   godot --headless --path . --script tools/encountertest.gd
# ------------------------------------------------------------------------------

## The shipping region: 384 cells at 0.5 m.
const CELLS: int = 384
const CELL: float = 0.5

const CAMPAIGN_SEED: int = 12345
## The player's own champion, which must never appear as an enemy.
const AVOID: String = "aldous"

## The two maps measured on real terrain. Map 3 of 100 and map 97 of 100: far
## enough apart in dread that every curve has somewhere to go, and both are
## real campaign positions rather than the end stops.
const EARLY: int = 3
const LATE: int = 97

## How far outside the carved floor a body may be measured and still counted as
## standing on the lane. Half a cell plus a little: a spawn is snapped to a cell
## CENTRE (Pathing.nearest_walkable_centre), so a body placed exactly on the rim
## of the floor can be measured up to that far beyond it.
const FLOOR_TOL: float = 0.8

var fails: int = 0
var _width_cache: Dictionary = {}


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	var roster: PackedStringArray = HeroRig.animated_heroes()
	print("\n=== roster ===")
	check("the playable roster is the 139 champions", roster.size() == 139,
		"%d heroes" % roster.size())

	_the_cast(roster)
	_the_spellbooks(roster)

	var early: Dictionary = _populate(EARLY, roster)
	var late: Dictionary = _populate(LATE, roster)
	_the_lane(early, roster)
	_the_lane(late, roster)
	_early_against_late(early, late)
	_the_bodies(late)
	_determinism(early, late, roster)
	_the_campaign(roster)
	_the_ring_survives(early, roster)

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------------------
# The cast: who is in which map
# ------------------------------------------------------------------------------

func _the_cast(roster: PackedStringArray) -> void:
	var table: Array[PackedStringArray] = Encounter.cast_table(
		CAMPAIGN_SEED, roster, AVOID)
	print("\n=== the cast of %d maps ===" % table.size())

	# A handful of maps printed in full, so the assignment can be READ and not
	# only asserted on. Two neighbours and two acts apart, which is where the
	# recurrence rules are supposed to show.
	for i in [0, 1, 2, 11, 50, 97, 99]:
		var cast: PackedStringArray = table[i]
		var parts: PackedStringArray = PackedStringArray()
		for h in cast:
			parts.append("%s(%s,%s)" % [h,
				HeroClass.display_name(HeroClass.for_hero(h)).substr(0, 3),
				Champion.rarity_name(h).substr(0, 4)])
		print("  map %2d  act %d  dread %.2f  %s" % [i + 1, Campaign.act_of(i) + 1,
			Campaign.dread(i), ", ".join(parts)])

	var sized: bool = true
	var schooled: bool = true
	var clean: bool = true
	var in_roster: bool = true
	var uses: Dictionary = {}
	var signatures: Dictionary = {}
	for i in range(table.size()):
		var cast: PackedStringArray = table[i]
		if cast.size() < 4 or cast.size() > 6:
			sized = false
		var classes: Dictionary = {}
		for h in cast:
			classes[HeroClass.for_hero(h)] = true
			uses[h] = int(uses.get(h, 0)) + 1
			if h == AVOID:
				clean = false
			if not (h in roster):
				in_roster = false
		if classes.size() < 3:
			schooled = false
		var sorted: PackedStringArray = cast.duplicate()
		sorted.sort()
		signatures[", ".join(sorted)] = true

	check("every map fields four to six champions", sized)
	check("every map fields all three schools", schooled,
		"melee, ranged and spell on all %d maps" % table.size())
	check("every enemy is a real roster champion", in_roster)
	check("the player's own champion is never an enemy", clean, AVOID)

	# Identity: a map is not interchangeable with its neighbour.
	check("no two maps have the same cast", signatures.size() == table.size(),
		"%d distinct casts over %d maps" % [signatures.size(), table.size()])

	# Recurrence, which is the whole point of a table rather than a draw.
	var warlord_runs: bool = true
	for a in range(Campaign.act_count()):
		var first: String = table[a * Campaign.maps_per_act()][0]
		for s in range(Campaign.maps_per_act()):
			if table[a * Campaign.maps_per_act() + s][0] != first:
				warlord_runs = false
	check("each act has a warlord in all ten of its maps", warlord_runs)

	var most: String = ""
	var most_n: int = 0
	var singles: int = 0
	for h in uses.keys():
		var n: int = int(uses[h])
		if n > most_n:
			most_n = n
			most = String(h)
		if n <= 2:
			singles += 1
	check("some champions recur across many maps", most_n >= 10,
		"%s appears in %d maps" % [most, most_n])
	check("...and most are local to a few", singles >= 60,
		"%d champions appear in at most 2 maps" % singles)

	# Coverage. 138 usable champions over 100 maps of 4-6 means every one of them
	# should get used; a table that leaves forty champions unseen has wasted
	# forty rigged models.
	var pool: int = roster.size() - 1
	check("every champion is used somewhere in the campaign",
		uses.size() == pool, "%d of %d champions cast" % [uses.size(), pool])

	# Stability, which is what makes a bug report reproducible.
	var again: Array[PackedStringArray] = Encounter.cast_table(
		CAMPAIGN_SEED, roster, AVOID)
	var stable: bool = true
	for i in range(table.size()):
		if ", ".join(table[i]) != ", ".join(again[i]):
			stable = false
	check("the same campaign seed gives the same casts", stable)

	var other: Array[PackedStringArray] = Encounter.cast_table(
		CAMPAIGN_SEED + 1, roster, AVOID)
	var differs: int = 0
	for i in range(table.size()):
		if ", ".join(table[i]) != ", ".join(other[i]):
			differs += 1
	check("a different campaign seed gives a different campaign",
		differs >= table.size() - 2, "%d of %d maps re-cast" % [differs, table.size()])

	# recurring_pool() is the inspection hook on the DESIGNED half of a cast —
	# the twelve champions the campaign reuses on purpose — and it has to agree
	# with the table it claims to describe, or the two drift and the "warlord of
	# act 4" the tooling reports is not the one the player fights.
	var recur: PackedStringArray = Encounter.recurring_pool(CAMPAIGN_SEED, roster,
		AVOID)
	var agrees: bool = recur.size() == Encounter.RECURRING
	for a in range(Campaign.act_count()):
		if table[a * Campaign.maps_per_act()][0] != recur[a % recur.size()]:
			agrees = false
	check("the recurring pool names the warlord of every act", agrees,
		"%d recurring: %s" % [recur.size(), ", ".join(recur)])


# ------------------------------------------------------------------------------
# The kits the cast fights with
#
# "An enemy mage casts its OWN generated spellbook" is the premise of building
# monsters out of champions, and it is the one claim here that a per-map check
# cannot test: a map fields four to six champions, of which one or two are
# mages, so one lane is far too small a sample to tell 39 individual spellbooks
# apart from one shared book. It is measured over the WHOLE campaign cast
# instead.
# ------------------------------------------------------------------------------

func _the_spellbooks(roster: PackedStringArray) -> void:
	print("\n=== the kits of the campaign's cast ===")
	var mages: Dictionary = {}
	var cast_size: int = 0
	for cast in Encounter.cast_table(CAMPAIGN_SEED, roster, AVOID):
		cast_size += cast.size()
		for h in cast:
			if HeroClass.for_hero(h) == HeroClass.Kind.MAGE:
				mages[h] = true

	# A spellbook's SIGNATURE, not just its first spell id: two mages could share
	# a book and differ only by name prefix, and a signature over every slot's
	# damage, range and shape would catch that.
	var books: Dictionary = {}
	var names: Array = mages.keys()
	names.sort()
	for h in names:
		var kit: Array[Ability] = Ability.for_hero(String(h), HeroClass.Kind.MAGE)
		var sig: PackedStringArray = PackedStringArray()
		for a in kit:
			sig.append("%d/%.2f/%.1f/%d/%d" % [a.shape, a.damage_mult, a.range_m,
				a.applies, a.self_applies])
		books[", ".join(sig)] = true
		if names.find(h) < 3:
			print("  %-6s %s" % [h, ", ".join(sig)])

	print("  %d champions cast across the campaign, %d of them mages" % [
		cast_size, mages.size()])
	check("enemy mages are cast on every scale of the campaign", mages.size() >= 20,
		"%d distinct mage champions appear as enemies" % mages.size())
	check("...and no two of them cast the same spellbook",
		books.size() == mages.size(),
		"%d distinct books over %d mages" % [books.size(), mages.size()])


# ------------------------------------------------------------------------------
# The bodies: what a tier does, and what a boss is
#
# body_for() is where an encounter becomes a fight, and it is the easiest place
# in the file to be quietly wrong, because every number it produces looks
# plausible in isolation. The failure it SHIPPED with was exactly that: the tier
# health multiplier was applied to the boss's whole stat block and then to its
# max health again, so the boss/pack health ratio was a function of the tier
# (x8 at Normal, x1802 at Oblivion), the health multiplier silently doubled as a
# damage multiplier, and the boss's dodge and crit sat pinned at Stats' caps
# from Eternal upward. Every one of those passes "the boss has more health".
#
# So the ratios are measured ACROSS tiers, which is what makes the double
# application visible, and against a real pack rather than against a constant.
# ------------------------------------------------------------------------------

func _the_bodies(m: Dictionary) -> void:
	print("\n=== a boss against the pack that guards its door ===")
	var spawns: Array = m["spawns"]
	var boss = null
	var last_pack: int = -1
	for s in spawns:
		if s.is_boss:
			boss = s
		else:
			last_pack = maxi(last_pack, s.pack)

	# The guard: the deepest pack on the lane, the one standing in the doorway.
	var guard: Array = []
	for s in spawns:
		if not s.is_boss and s.pack == last_pack:
			guard.append(s)

	print("  %-10s %12s %12s %10s %8s %8s" % ["tier", "boss health",
		"pack health", "ratio", "boss atk", "mook atk"])
	var ratios: Array[float] = []
	# A PLAIN pack member, not guard[0]: the door pack's first body is an elite by
	# rule, so comparing the boss against it would quietly be a boss-vs-elite
	# comparison printed under a column headed "mook".
	var mook = guard[0]
	for s in guard:
		if not s.is_elite:
			mook = s
			break
	for t in range(Campaign.tier_count()):
		var bb: Combatant = Encounter.body_for(boss, t)
		var mb: Combatant = Encounter.body_for(mook, t)
		var pack_hp: float = 0.0
		for s in guard:
			pack_hp += Encounter.body_for(s, t).max_health
		ratios.append(bb.max_health / mb.max_health)
		print("  %-10s %12.0f %12.0f %10.2f %8.0f %8.0f" % [
			Campaign.tier_name(t), bb.max_health, pack_hp,
			bb.max_health / mb.max_health, bb.attack_power(), mb.attack_power()])

	# THE RATIO MUST NOT MOVE WITH THE TIER. A tier is allowed to make everything
	# tougher; it is not allowed to change what a boss IS relative to the pack
	# beside it, and a ratio that drifts is a multiplier applied twice.
	var spread: float = 0.0
	for r in ratios:
		spread = maxf(spread, absf(r - ratios[0]))
	check("the tier multiplier is applied to a boss exactly once", spread < 0.01,
		"boss/mook health is x%.2f at every one of the %d tiers" % [
			ratios[0], Campaign.tier_count()])

	var n: Combatant = Encounter.body_for(boss, Campaign.Tier.NORMAL)
	var o: Combatant = Encounter.body_for(boss, Campaign.Tier.OBLIVION)
	var want: float = Campaign.enemy_health_mult(Campaign.Tier.OBLIVION)
	check("...so its health tracks Campaign.enemy_health_mult",
		absf(o.max_health / n.max_health - want) < want * 0.01,
		"x%.1f measured against x%.1f asked for" % [o.max_health / n.max_health,
			want])

	# The attributes a boss fights with are its champion's own. If a health
	# multiplier is leaking into the stat block this is where it shows: a boss at
	# the eighth tier would be sitting on both caps.
	var same_stats: bool = true
	for t in range(Campaign.tier_count()):
		var bb: Combatant = Encounter.body_for(boss, t)
		if absf(bb.stats.total() - n.stats.total()) > 0.01:
			same_stats = false
	check("a boss's attributes are its champion's, not a health constant's",
		same_stats and o.stats.dodge_chance() < Stats.DODGE_CAP
			and o.stats.crit_chance() < Stats.CRIT_CAP,
		"dodge %.2f of a %.2f cap, crit %.2f of %.2f at the eighth tier" % [
			o.stats.dodge_chance(), Stats.DODGE_CAP, o.stats.crit_chance(),
			Stats.CRIT_CAP])

	# And the boss is still the fight the map leads up to: one body worth roughly
	# the pack guarding its door.
	var pack_hp_n: float = 0.0
	for s in guard:
		pack_hp_n += Encounter.body_for(s, Campaign.Tier.NORMAL).max_health
	check("a boss is worth about the pack that guards it",
		n.max_health > pack_hp_n * 0.6 and n.max_health < pack_hp_n * 2.5,
		"%.0f health against the door pack's %.0f (%d bodies)" % [
			n.max_health, pack_hp_n, guard.size()])
	check("...and hits harder than they do, but not many times harder",
		n.attack_power() > Encounter.body_for(mook, Campaign.Tier.NORMAL).attack_power()
			and n.attack_power() < Encounter.body_for(mook,
				Campaign.Tier.NORMAL).attack_power() * 2.0,
		"x%.2f of a pack member's hit" % (n.attack_power()
			/ Encounter.body_for(mook, Campaign.Tier.NORMAL).attack_power()))


# ------------------------------------------------------------------------------
# A real region, populated
# ------------------------------------------------------------------------------

## Build map `index` for real — lane plan, 384-cell terrain, walk grid — and put
## its inhabitants in it, announcing what it cost. The sweep uses the silent
## form: ten of these would bury the table it prints.
func _populate(index: int, roster: PackedStringArray) -> Dictionary:
	var m: Dictionary = _populate_quiet(index, roster)
	var lane: Lane = m["lane"]
	print("\n=== map %d of %d — %s ===" % [index + 1, Campaign.map_count(),
		Campaign.region_title(index)])
	print("  %.0f m lane, %d nodes, terrain + walk grid %.0f ms, populated in %.1f ms" % [
		lane.spine_length, lane.nodes.size(), m["build_ms"], m["pop_ms"]])
	return m


func _populate_quiet(index: int, roster: PackedStringArray) -> Dictionary:
	var world_seed: int = Campaign.region_seed(CAMPAIGN_SEED, index)
	var biome: String = Campaign.biome_at(index)
	var extent: float = float(CELLS) * CELL
	var lane: Lane = Terrain.plan_for(Terrain.Kind.LANE, world_seed,
		Vector2(extent, extent)) as Lane

	var t0: int = Time.get_ticks_usec()
	var ter: Terrain = Terrain.generate(world_seed, biome, CELLS, CELL, lane)
	var path := Pathing.new(ter)
	var build_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0

	var start: Vector2 = path.nearest_walkable_centre(lane.position_at(0.0))
	var t1: int = Time.get_ticks_usec()
	var spawns: Array = Encounter.build(index, Campaign.Tier.NORMAL,
		CAMPAIGN_SEED, roster, AVOID, path, start, lane)
	var pop_ms: float = float(Time.get_ticks_usec() - t1) / 1000.0

	return {
		"index": index, "lane": lane, "ter": ter, "path": path,
		"start": start, "spawns": spawns,
		"build_ms": build_ms, "pop_ms": pop_ms,
	}


func _the_lane(m: Dictionary, roster: PackedStringArray) -> void:
	var index: int = int(m["index"])
	var lane: Lane = m["lane"]
	var path: Pathing = m["path"]
	var start: Vector2 = m["start"]
	var spawns: Array = m["spawns"]
	var cast: PackedStringArray = Encounter.cast_for(index, CAMPAIGN_SEED,
		roster, AVOID)

	var boss_node: Dictionary = lane.node_of_kind(Layout.BOSS)
	var boss_c: Vector2 = boss_node["pos"]
	var boss_r: float = float(boss_node["radius"])

	# ---- the table. Every pack, in travel order, with how far the player has to
	# WALK to reach it — not how far away it is, which on a folded lane is a
	# different and much smaller number.
	var packs: Dictionary = {}
	var boss = null
	for s in spawns:
		if s.is_boss:
			boss = s
			continue
		if not packs.has(s.pack):
			packs[s.pack] = []
		packs[s.pack].append(s)

	var keys: Array = packs.keys()
	keys.sort()
	print("  %-5s %5s %6s %7s %8s %6s %s" % ["pack", "n", "elite", "progress",
		"walked", "lv", "champions"])
	var walked_first: float = 0.0
	var walked_boss: float = 0.0
	var centres: Array[float] = []
	for k in keys:
		var group: Array = packs[k]
		var t_sum: float = 0.0
		var t_min: float = 1.0
		var t_max: float = 0.0
		var elites: int = 0
		var lv: int = 0
		var who: Dictionary = {}
		for s in group:
			t_sum += s.progress
			t_min = minf(t_min, s.progress)
			t_max = maxf(t_max, s.progress)
			lv = maxi(lv, s.level)
			who[s.hero] = true
			if s.is_elite:
				elites += 1
		var t_mean: float = t_sum / float(group.size())
		centres.append(t_mean)
		var walked: float = _walk(path, start, group[0].at)
		if k == keys[0]:
			walked_first = walked
		print("  %-5d %5d %6d %7.3f %7.0fm %6d %s" % [int(k) + 1, group.size(),
			elites, t_mean, walked, lv, ", ".join(PackedStringArray(who.keys()))])
	walked_boss = _walk(path, start, boss.at)
	print("  boss  %5s %6s %7.3f %7.0fm %6d %s  (%.1f m into a %.0f m arena)" % [
		"1", "-", boss.progress, walked_boss, boss.level,
		boss.hero, boss.at.distance_to(boss_c), boss_r])
	# DIAGNOSTIC, NOT AN ASSERTION, and deliberately printed rather than hidden:
	# how much of the lane the player can skip. 68% of a region's cells are
	# walkable, so the folds of the serpentine are joined by open ground and the
	# boss can be reached without meeting most of the packs. Spine placement
	# cannot fix that from here — it is the walk mask the carve produces (Terrain)
	# and the spacing of the sweeps (Lane) — so it is measured and reported.
	print("  bypass: A* reaches the boss in %.0f m of a %.0f m lane (%.0f%%)" % [
		walked_boss, lane.spine_length,
		100.0 * walked_boss / maxf(lane.spine_length, 1.0)])

	var tag: String = "[map %d]" % (index + 1)

	# ---- every spawn is legal ground
	var unwalkable: int = 0
	var inside_safe: int = 0
	var off_cast: int = 0
	var off_lane: float = 0.0
	var unreachable: int = 0
	var in_arena: int = 0
	for s in spawns:
		if not path.is_walkable(s.at):
			unwalkable += 1
		if s.at.distance_to(start) < Encounter.SAFE_RADIUS:
			inside_safe += 1
		if not (s.hero in cast):
			off_cast += 1
		if _walk(path, start, s.at) <= 0.0:
			unreachable += 1
		if s.is_boss:
			continue
		off_lane = maxf(off_lane, _floor_gap(lane, s.at))
		if s.at.distance_to(boss_c) <= boss_r:
			in_arena += 1

	check("%s every spawn stands on walkable ground" % tag, unwalkable == 0,
		"%d of %d off the mask" % [unwalkable, spawns.size()])
	check("%s nothing spawns inside the entrance safe radius" % tag,
		inside_safe == 0, "radius %.0f m" % Encounter.SAFE_RADIUS)
	check("%s every spawn is reachable on foot from the entrance" % tag,
		unreachable == 0, "%d of %d unreachable" % [unreachable, spawns.size()])
	check("%s every enemy is one of the map's cast" % tag, off_cast == 0,
		"cast of %d" % cast.size())
	check("%s every spawn stands ON the lane" % tag, off_lane <= FLOOR_TOL,
		"worst body is %.2f m outside the carved floor" % off_lane)
	check("%s only the boss is in the boss arena" % tag, in_arena == 0,
		"%d pack members inside the %.0f m arena" % [in_arena, boss_r])

	# ---- the packs are a sequence, not a crowd
	var min_gap: float = 1e9
	var ordered: bool = true
	for i in range(1, centres.size()):
		if centres[i] <= centres[i - 1]:
			ordered = false
		min_gap = minf(min_gap, (centres[i] - centres[i - 1]) * lane.spine_length)
	var span: float = (centres[centres.size() - 1] - centres[0]) * lane.spine_length
	check("%s there are several packs" % tag, centres.size() >= Encounter.PACKS_EARLY,
		"%d packs, %d bodies" % [centres.size(), spawns.size() - 1])
	check("%s packs are ordered along the lane" % tag, ordered)
	check("%s ...with clear ground between them" % tag, min_gap >= 12.0,
		"closest two packs are %.0f m apart" % min_gap)
	check("%s ...spread over the length of the lane" % tag,
		span >= lane.spine_length * 0.5,
		"%.0f m of a %.0f m lane" % [span, lane.spine_length])
	# THE SEQUENCE IS MEASURED IN PROGRESS, NOT IN WALKED METRES, and the
	# `walked` column above shows why: it is not monotonic. The lane folds back on
	# itself three or four times and the ground between the folds is walkable
	# (see the bypass diagnostic printed below), so A* reaches a point 232 m along
	# the lane in 44 m by cutting across. That is a property of the carve and the
	# walk mask, not of the placement — what Encounter owns and what this asserts
	# is that the packs are an ordered sequence along the route.
	check("%s the boss is the deepest thing on the map" % tag,
		walked_boss > walked_first, "%.0f m walked against %.0f m to pack 1" % [
			walked_boss, walked_first])

	# ---- the boss
	var deepest: int = 0
	var mook = null
	for s in spawns:
		if s.is_boss:
			continue
		deepest = maxi(deepest, s.level)
		if mook == null and not s.is_elite:
			mook = s
	check("%s the boss waits in the boss arena" % tag,
		boss.at.distance_to(boss_c) <= boss_r,
		"%.1f m from the centre of a %.0f m floor" % [
			boss.at.distance_to(boss_c), boss_r])
	check("%s ...at the far end, not up the lane" % tag, boss.progress >= 0.97,
		"progress %.3f" % boss.progress)
	check("%s the boss is scaled up" % tag, boss.size > 1.4,
		"x%.2f against x%.2f" % [boss.size, mook.size])
	check("%s the boss out-levels everything on the lane" % tag,
		boss.level > deepest, "lv %d against lv %d" % [boss.level, deepest])

	var bb: Combatant = Encounter.body_for(boss, Campaign.Tier.NORMAL)
	var mb: Combatant = Encounter.body_for(mook, Campaign.Tier.NORMAL)
	check("%s the boss has far more health" % tag,
		bb.max_health > mb.max_health * 3.0,
		"%.0f against %.0f" % [bb.max_health, mb.max_health])
	check("%s the boss hits harder" % tag, bb.attack_power() > mb.attack_power(),
		"%.1f against %.1f" % [bb.attack_power(), mb.attack_power()])
	check("%s enemies are on the ENEMY team" % tag,
		bb.team == Combatant.Team.ENEMY)

	# ---- they still fight with their own generated kits, through exactly the
	# four actions the rig has clips for. A fifth action is unanimatable, so an
	# enemy that asked for one would be a champion the player cannot read.
	var slotted: int = 0
	var mages: int = 0
	for s in spawns:
		if s.cls == HeroClass.Kind.MAGE:
			mages += 1
		var kit: Array[Ability] = Ability.for_hero(s.hero, s.cls)
		var slots: Dictionary = {}
		for ab in kit:
			slots[ab.slot] = true
		if kit.size() != 3 or slots.size() != 3 or slots.has(0) \
				or Ability.basic_attack(s.cls).slot != 0:
			slotted += 1
	check("%s every enemy has exactly the rig's four actions" % tag, slotted == 0,
		"basic + three abilities in slots 1-3, on all %d bodies" % spawns.size())
	check("%s ...and the lane fields spellcasters" % tag, mages > 0,
		"%d of %d bodies are mages" % [mages, spawns.size()])


# ------------------------------------------------------------------------------
# The dread curve, measured between two real maps
# ------------------------------------------------------------------------------

func _early_against_late(early: Dictionary, late: Dictionary) -> void:
	print("\n=== map %d against map %d ===" % [EARLY + 1, LATE + 1])
	var a: Dictionary = _summary(early)
	var b: Dictionary = _summary(late)
	print("  %-26s %10s %10s" % ["", "map %d" % (EARLY + 1), "map %d" % (LATE + 1)])
	for key in ["dread", "bodies", "packs", "elite_pct", "top_level",
			"boss_depth_m", "door_m"]:
		print("  %-26s %10.2f %10.2f" % [key, a[key], b[key]])

	check("a late map is denser", b["bodies"] > a["bodies"],
		"%d bodies against %d" % [int(b["bodies"]), int(a["bodies"])])
	check("...in more packs", b["packs"] > a["packs"],
		"%d packs against %d" % [int(b["packs"]), int(a["packs"])])
	check("...with more elites", b["elite_pct"] > a["elite_pct"],
		"%.0f%% against %.0f%%" % [b["elite_pct"], a["elite_pct"]])
	check("...at higher levels", b["top_level"] > a["top_level"],
		"lv %d against lv %d" % [int(b["top_level"]), int(a["top_level"])])
	check("...whose boss waits deeper in its arena",
		b["boss_depth_m"] > a["boss_depth_m"],
		"%.1f m against %.1f m" % [b["boss_depth_m"], a["boss_depth_m"]])
	check("...and gives no breather before the door",
		b["door_m"] < a["door_m"],
		"%.0f m of clear ground against %.0f m" % [b["door_m"], a["door_m"]])

	# The same bodies, and therefore the same fight, measured through Combat.
	var ha: float = _toughest(early)
	var hb: float = _toughest(late)
	check("...so its boss is tougher at the same tier", hb > ha,
		"%.0f health against %.0f" % [hb, ha])


func _summary(m: Dictionary) -> Dictionary:
	var lane: Lane = m["lane"]
	var spawns: Array = m["spawns"]
	var boss_node: Dictionary = lane.node_of_kind(Layout.BOSS)
	var boss_c: Vector2 = boss_node["pos"]
	var boss_r: float = float(boss_node["radius"])

	var packs: Dictionary = {}
	var elites: int = 0
	var bodies: int = 0
	var top: int = 0
	var last_t: float = 0.0
	var depth: float = 0.0
	for s in spawns:
		if s.is_boss:
			depth = s.at.distance_to(boss_c)
			continue
		bodies += 1
		packs[s.pack] = true
		top = maxi(top, s.level)
		last_t = maxf(last_t, s.progress)
		if s.is_elite:
			elites += 1
	return {
		"dread": Campaign.dread(int(m["index"])),
		"bodies": float(bodies),
		"packs": float(packs.size()),
		"elite_pct": 100.0 * float(elites) / float(maxi(bodies, 1)),
		"top_level": float(top),
		"boss_depth_m": depth,
		# Clear ground between the deepest body and the rim of the boss arena.
		"door_m": (1.0 - last_t) * lane.spine_length - boss_r,
	}


func _toughest(m: Dictionary) -> float:
	for s in m["spawns"]:
		if s.is_boss:
			return Encounter.body_for(s, Campaign.Tier.NORMAL).max_health
	return 0.0


# ------------------------------------------------------------------------------
# The whole campaign, on real ground
#
# Two maps prove that the code can work. They cannot prove that it works for the
# hundred maps that will ship, and the two measured above are precisely the two
# whose output was read while writing this — which is the oldest way to pass a
# test. So ten maps spread across the campaign are built for real, every spawn
# on every one of them is checked against the same rules, and the dread curve is
# re-measured as a TREND across all ten rather than as a single comparison.
# ------------------------------------------------------------------------------

## Every eleventh map, so the sample spans both end stops (map 1 and map 100,
## dread 0 and 1) and lands in nine different acts.
const SWEEP_STEP: int = 11

func _the_campaign(roster: PackedStringArray) -> void:
	print("\n=== every %dth map, on real terrain ===" % SWEEP_STEP)
	print("  %-5s %5s %6s %6s %7s %6s %7s %7s %6s" % ["map", "lane", "packs",
		"bodies", "rolled%", "top lv", "boss m", "door m", "bad"])

	var bodies: Array[float] = []
	var elite: Array[float] = []
	var top: Array[float] = []
	var door: Array[float] = []
	var illegal: int = 0
	var maps: int = 0

	for index in range(0, Campaign.map_count(), SWEEP_STEP):
		var m: Dictionary = _populate_quiet(index, roster)
		var lane: Lane = m["lane"]
		var path: Pathing = m["path"]
		var start: Vector2 = m["start"]
		var cast: PackedStringArray = Encounter.cast_for(index, CAMPAIGN_SEED,
			roster, AVOID)
		var boss_node: Dictionary = lane.node_of_kind(Layout.BOSS)
		var boss_c: Vector2 = boss_node["pos"]
		var boss_r: float = float(boss_node["radius"])

		# Every rule the two detailed maps are held to, on every body.
		var bad: int = 0
		var bosses: int = 0
		var packs: Dictionary = {}
		var sums: Dictionary = {}
		var elites: int = 0
		var n: int = 0
		var lv: int = 0
		var deepest: float = 0.0
		var boss = null
		# The door pack's first member is an elite BY RULE, so the rolled elite
		# rate — the one dread actually drives — has to be measured away from it.
		# Including it, a 15-body early map reads 20% against a nominal 8%, which
		# flattens the curve enough to hide whether it is being sampled at all.
		var last_pack: int = -1
		for s in m["spawns"]:
			if not s.is_boss:
				last_pack = maxi(last_pack, s.pack)
		var rolled: int = 0
		var rolled_n: int = 0
		for s in m["spawns"]:
			if s.is_boss or s.pack == last_pack:
				continue
			rolled_n += 1
			if s.is_elite:
				rolled += 1
		for s in m["spawns"]:
			if not path.is_walkable(s.at) \
					or s.at.distance_to(start) < Encounter.SAFE_RADIUS \
					or not (s.hero in cast) \
					or _walk(path, start, s.at) <= 0.0:
				bad += 1
			if s.is_boss:
				bosses += 1
				boss = s
				if s.at.distance_to(boss_c) > boss_r or s.progress < 0.97:
					bad += 1
				continue
			n += 1
			lv = maxi(lv, s.level)
			deepest = maxf(deepest, s.progress)
			if s.is_elite:
				elites += 1
			if s.at.distance_to(boss_c) <= boss_r:
				bad += 1          # a pack member loose in the boss's arena
			if _floor_gap(lane, s.at) > FLOOR_TOL:
				bad += 1          # standing in the hillside beside the lane
			packs[s.pack] = true
			sums[s.pack] = float(sums.get(s.pack, 0.0)) + s.progress

		# The packs are still an ordered sequence, map by map.
		var keys: Array = packs.keys()
		keys.sort()
		var prev: float = -1.0
		for k in keys:
			var centre: float = float(sums[k]) / float(maxi(_count_in_pack(
				m["spawns"], int(k)), 1))
			if centre <= prev:
				bad += 1
			prev = centre
		if bosses != 1 or keys.size() < Encounter.PACKS_EARLY:
			bad += 1

		bodies.append(float(n))
		elite.append(100.0 * float(rolled) / float(maxi(rolled_n, 1)))
		top.append(float(lv))
		door.append((1.0 - deepest) * lane.spine_length - boss_r)
		illegal += bad
		maps += 1
		print("  %-5d %4.0fm %6d %6d %7.0f %6d %7.1f %7.0f %6d" % [index + 1,
			lane.spine_length, keys.size(), n, elite[elite.size() - 1], lv,
			boss.at.distance_to(boss_c), door[door.size() - 1], bad])

	check("ten maps across the campaign place every body legally", illegal == 0,
		"%d rule violations over %d maps" % [illegal, maps])

	# The trend, not a single pair: the first three maps of the sample against
	# the last three. A curve read from two points can be a coincidence.
	check("the campaign gets denser as dread rises",
		_mean(bodies, true) > _mean(bodies, false) * 1.8,
		"%.1f bodies at the start against %.1f at the end" % [
			_mean(bodies, false), _mean(bodies, true)])
	check("...and rolls far more of them as elites",
		_mean(elite, true) > _mean(elite, false) * 2.0,
		"%.0f%% of the pack against %.0f%%, off a %.0f-%.0f%% curve" % [
			_mean(elite, false), _mean(elite, true),
			100.0 * Encounter.ELITE_RATE_EARLY, 100.0 * Encounter.ELITE_RATE_LATE])
	check("...at higher levels", _mean(top, true) > _mean(top, false) + 10.0,
		"lv %.1f against lv %.1f" % [_mean(top, false), _mean(top, true)])
	check("...with less breathing room before the boss's door",
		_mean(door, true) < _mean(door, false) * 0.5,
		"%.0f m against %.0f m" % [_mean(door, false), _mean(door, true)])


## Mean of the first or last three entries.
func _mean(a: Array[float], tail: bool) -> float:
	var sum: float = 0.0
	for i in range(3):
		sum += a[a.size() - 1 - i] if tail else a[i]
	return sum / 3.0


func _count_in_pack(spawns: Array, pack: int) -> int:
	var n: int = 0
	for s in spawns:
		if not s.is_boss and s.pack == pack:
			n += 1
	return n


# ------------------------------------------------------------------------------
# Determinism
# ------------------------------------------------------------------------------

func _determinism(early: Dictionary, late: Dictionary,
		roster: PackedStringArray) -> void:
	print("\n=== the same map is the same fight ===")
	for m in [early, late]:
		var index: int = int(m["index"])
		var again: Array = Encounter.build(index, Campaign.Tier.NORMAL,
			CAMPAIGN_SEED, roster, AVOID, m["path"], m["start"], m["lane"])
		check("[map %d] repopulating gives the same inhabitants" % (index + 1),
			_same(m["spawns"], again),
			"%d spawns" % again.size())

	# A different map must be a different fight — and on a lane that means both
	# the cast and the placement, not one or the other.
	var other: Array = Encounter.build(int(early["index"]) + 1,
		Campaign.Tier.NORMAL, CAMPAIGN_SEED, roster, AVOID,
		early["path"], early["start"], early["lane"])
	check("the next map over is a different fight",
		not _same(early["spawns"], other),
		"%d spawns against %d" % [other.size(), early["spawns"].size()])

	# And a harder tier has to land on the same bodies.
	var boss = null
	for s in early["spawns"]:
		if s.is_boss:
			boss = s
	var n: Combatant = Encounter.body_for(boss, Campaign.Tier.NORMAL)
	var o: Combatant = Encounter.body_for(boss, Campaign.Tier.OBLIVION)
	check("the eighth tier outguns the first", o.max_health > n.max_health * 10.0,
		"%.0f health against %.0f" % [o.max_health, n.max_health])


func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if a[i].hero != b[i].hero or a[i].at != b[i].at \
				or a[i].level != b[i].level or a[i].is_boss != b[i].is_boss \
				or a[i].is_elite != b[i].is_elite or a[i].pack != b[i].pack:
			return false
	return true


# ------------------------------------------------------------------------------
# The arena ring — the PvP placement, which the lane must not have broken
# ------------------------------------------------------------------------------

func _the_ring_survives(m: Dictionary, roster: PackedStringArray) -> void:
	print("\n=== the arena ring still works ===")
	# No plan, so no lane: the ring strategy is what `build` must fall back to.
	# Run on real walkable ground, because "in a ring around the player" is a
	# claim about where bodies END UP after the walkability snap.
	var path: Pathing = m["path"]
	var start: Vector2 = m["start"]
	var ring: Array = Encounter.build(int(m["index"]), Campaign.Tier.NORMAL,
		CAMPAIGN_SEED, roster, AVOID, path, start, null)

	var bosses: int = 0
	var inside: int = 0
	var unwalkable: int = 0
	var lane_state: int = 0
	var angles: Array[float] = []
	var near: float = 1e9
	var far: float = 0.0
	for s in ring:
		if s.is_boss:
			bosses += 1
		var d: float = s.at.distance_to(start)
		near = minf(near, d)
		far = maxf(far, d)
		if d < Encounter.SAFE_RADIUS:
			inside += 1
		if not path.is_walkable(s.at):
			unwalkable += 1
		if s.pack != -1 or s.progress != 0.0:
			lane_state += 1
		angles.append((s.at - start).angle())

	var widest: float = 0.0
	for i in range(angles.size()):
		for j in range(i + 1, angles.size()):
			widest = maxf(widest, absf(angle_difference(angles[i], angles[j])))

	print("  %d spawns, %.0f-%.0f m out, widest separation %.0f degrees" % [
		ring.size(), near, far, rad_to_deg(widest)])

	check("the ring still populates a region", ring.size() > 0,
		"%d spawns" % ring.size())
	check("...within the readable pack range",
		ring.size() >= Encounter.MIN_PACK + 1 and ring.size() <= Encounter.MAX_PACK + 1,
		"%d including the boss" % ring.size())
	check("...with exactly one boss", bosses == 1)
	check("...all on walkable ground", unwalkable == 0)
	check("...none inside the safe radius", inside == 0)
	check("...surrounding the player rather than lined up",
		widest > deg_to_rad(90.0), "%.0f degrees apart" % rad_to_deg(widest))
	check("...and carrying no lane state", lane_state == 0,
		"pack -1 and progress 0 on all %d" % ring.size())

	# The kept behaviour: the ring boss comes from the rarest champions in the
	# WHOLE roster, not from a per-map cast. An arena has no map index.
	var best: int = Item.Rarity.COMMON
	for h in roster:
		if h != AVOID:
			best = maxi(best, Champion.rarity_of(h))
	for s in ring:
		if s.is_boss:
			check("...and a boss drawn from the rarest champions",
				Champion.rarity_of(s.hero) == best,
				"%s is %s" % [s.hero, Champion.rarity_name(s.hero)])


# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

## Metres the player actually has to WALK from `a` to `b`, or 0 if there is no
## route at all. The straight-line distance is not the question on a lane that
## folds back on itself four times.
func _walk(path: Pathing, a: Vector2, b: Vector2) -> float:
	var legs: PackedVector2Array = path.find(a, b)
	if legs.size() < 2:
		return 0.0
	var d: float = 0.0
	for i in range(legs.size() - 1):
		d += legs[i].distance_to(legs[i + 1])
	return d


## How far OUTSIDE the lane's carved floor a point is, in metres. Zero or less
## means it is standing on the lane.
##
## THE FLOOR IS A UNION — the station discs plus the corridor ribbons between
## them, which is exactly what Terrain stamps from the plan's nodes and edges.
## Distance to the nearest centreline sample, measured against the width there,
## is the obvious metric and it is wrong in both directions: a body standing
## legally in the middle of a 28 m clearing is 12 m off the centreline, and a
## body 3 m off it at a pinch is inside the hillside. Measuring against the union
## asks the question the player experiences — is there floor under its feet.
func _floor_gap(lane: Lane, p: Vector2) -> float:
	var best: float = 1e9
	for n in lane.nodes:
		best = minf(best, p.distance_to(n["pos"] as Vector2) - float(n["radius"]))
	var widths: PackedFloat32Array = _widths(lane)
	for i in range(lane.spine.size()):
		best = minf(best, p.distance_to(lane.spine[i]) - widths[i] * 0.5)
	return best


## Carved width at every spine sample, cached per lane: _floor_gap is called
## once per spawn and the width table is the same for all of them.
func _widths(lane: Lane) -> PackedFloat32Array:
	if _width_cache.has(lane):
		return _width_cache[lane]
	var out := PackedFloat32Array()
	var arc: float = 0.0
	for i in range(lane.spine.size()):
		if i > 0:
			arc += lane.spine[i - 1].distance_to(lane.spine[i])
		out.append(lane.width_at(arc / maxf(lane.spine_length, 0.001)))
	_width_cache[lane] = out
	return out
