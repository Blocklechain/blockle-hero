class_name Encounter
extends RefCounted
# ------------------------------------------------------------------------------
# What is in a region: a pack of hostile champions and the boss at the end.
#
# THE ENEMIES ARE THE ROSTER. Every monster is one of the 139 rigged champions,
# built through the SAME HeroClass/Stats/Ability path the player's champion is.
# That is not a shortcut to avoid making monsters — it is the premise:
#
#   * an enemy Mage casts from its OWN generated spellbook (MageSpells keys off
#     the hero name), so no two mage encounters play alike;
#   * an enemy Fighter stuns you with Shield Slam, which is the same stun that
#     forces YOU to a walk, so the mechanic is taught by being used on you;
#   * every enemy already has eight animation clips, a death, and a silhouette
#     the player will later recognise as a champion they can unlock.
#
# The boss is the same thing scaled up — literally: the same model at a larger
# size multiplier with a tier-scaled body. A boss that is a familiar champion
# grown huge reads instantly at a glance on a phone, which a bespoke monster
# would not without art nobody has made.
#
# DETERMINISM. Everything here is drawn from Campaign.region_seed, so a region
# has the same inhabitants every time it is entered and a save can be replayed.
# Combat already rolls crits and dodges from a seeded stream for the same
# reason; an encounter that reshuffles on reload cannot be debugged from a save.
#
# TWO PLACEMENT STRATEGIES, ONE PER LAYOUT KIND, and both are wanted:
#
#   RING    `_ring` — spawns in a ring around the player outside a safe radius.
#           This is the ARENA placement, and the arena generator is the PvP mode
#           (see Layout.gd and docs/DESIGN-ROADMAP.md). An arena has no "far
#           end": every direction is contested ground, so the fight comes from
#           all round and the only ordering that exists is distance.
#   SPINE   `_spine` — packs distributed ALONG a Lane by progress, with gaps
#           between them and the boss waiting in the boss arena at the far end.
#           A lane is a journey, so its enemies have to arrive in an order;
#           ringing the player on a lane would put half the pack behind them in
#           ground they have already cleared, which is an ambush, not a march.
#
# `build()` picks by the kind of the plan it is handed, exactly as Terrain does
# (Terrain.kind_of): the plan's own type decides, so there is no kind argument
# that can disagree with the layout it describes.
#
# PER-MAP CAST. Which champions a map features is a separate question from where
# they stand, and it is answered by `cast_for()` — a seeded, inspectable
# assignment of a handful of champions to each of the hundred maps, built so
# that recurrence is DELIBERATE (an act has a warlord present in all ten of its
# maps; a travelling rival crosses acts) rather than the accident of a uniform
# random draw. 139 champions over 100 maps must repeat; this decides how.
# ------------------------------------------------------------------------------

## One thing to spawn. Plain data — the caller owns nodes and the scene tree.
class Spawn extends RefCounted:
	var hero: String = ""
	var level: int = 1
	var cls: int = HeroClass.Kind.FIGHTER
	var at: Vector2 = Vector2.ZERO
	var is_boss: bool = false
	## Recorded rather than inferred from `size`: "is this an elite" is a fact
	## about the encounter, and a caller comparing a float against ELITE_SIZE to
	## find out is one retune away from being wrong.
	var is_elite: bool = false
	## Multiplier on HeroRig.TARGET_HEIGHT. 1.0 is player-sized.
	var size: float = 1.0
	var seed: int = 0
	## SPINE PLACEMENT ONLY: how far down the lane this spawn stands (0 at the
	## entrance, 1 at the boss) and which pack it belongs to, -1 for the boss.
	## Ring placement is angular around the player and has no "along", so it
	## leaves both at their defaults.
	var progress: float = 0.0
	var pack: int = -1
	## How much of their full strength this enemy brings, 0..1 — see
	## Campaign.mercy(). Carried on the spawn rather than recomputed in
	## body_for() because body_for has the tier but not the map index, and
	## passing the index to it as well would give two sources for one number.
	var mercy: float = 1.0
	var mercy_health: float = 1.0

	func display_name() -> String:
		return ChampionName.of(hero) if is_boss == false else "%s, %s" % [
			ChampionName.of(hero), _BOSS_TITLES[seed % _BOSS_TITLES.size()]]


## Titles are picked by seed so a boss is named consistently for its region.
## Deliberately generic-heroic: the drama comes from the champion being one the
## player knows, not from the adjective.
## Written as a bare array literal: GDScript will not constant-fold a
## `PackedStringArray(...)` CONSTRUCTOR CALL, so the spelling this shipped with
## was a parse error — and because nothing had ever run this file, nothing said
## so. Same trap Lane.BEATS documents.
const _BOSS_TITLES: PackedStringArray = [
	"the Unbroken", "the Risen", "Warden of the Pass", "the Iron Crown",
	"the Hollow King", "the Last Oath", "Bane of the Vale", "the Sundered",
]

## How big a boss is. 1.55x is a clear head-and-shoulders over the pack without
## the model clipping scenery or its feet losing the ground on a slope.
const BOSS_SIZE: float = 1.55

## How a boss differs from a pack member in the FIGHT, as opposed to in the
## silhouette. Named rather than inlined in body_for() because the three of them
## are one balance decision and have to be read together.
##
## HEALTH does the work: a boss is what a whole lane leads up to, so it is worth
## roughly the pack that guards its door — one body, a pack's worth of
## commitment. tools/encountertest.gd measures it against the real last pack of
## a real map rather than trusting this constant.
##
## DAMAGE is deliberately the smallest of the three. A boss that kills in two
## hits is not a longer fight, it is a faster loading screen; the fight gets its
## weight from lasting, which is the health figure's job.
const BOSS_HEALTH_MULT: float = 8.0
const BOSS_DAMAGE_MULT: float = 1.35
const BOSS_ARMOUR_MULT: float = 1.6
## Elites are a half-step: big enough to notice, not big enough to be the boss.
const ELITE_SIZE: float = 1.18

## Pack size by region. Grows slowly — a phone screen in landscape holds about
## eight bodies before the fight becomes unreadable.
const MIN_PACK: int = 4
const MAX_PACK: int = 9

## Metres from the player's spawn that nothing hostile may start inside, so a
## region never opens with the champion already surrounded.
const SAFE_RADIUS: float = 14.0


# ------------------------------------------------------------------------------
# The dread-driven numbers
#
# EVERY ONE OF THESE IS SAMPLED BY Campaign.dread(index) AND NOTHING ELSE. The
# roadmap's named risk is "tuning scary in five places independently, so map 60
# looks menacing, plays like map 10 and is scored like map 90" — so the encounter
# system owns no difficulty curve of its own. It owns the two ENDS of each curve,
# and dread says where between them a map sits.
# ------------------------------------------------------------------------------

## Packs along the lane. Early maps are a handful of fights with quiet road
## between them; late maps are a gauntlet. Pack COUNT rather than pack size does
## most of the work here, because a longer gauntlet lengthens the map while a
## bigger pack just makes one screen unreadable.
const PACKS_EARLY: int = 4
const PACKS_LATE: int = 9

## Bodies per pack, before the width of the lane at that point modulates it.
const PACK_EARLY: float = 3.0
const PACK_LATE: float = 5.5

## Bodies in one LANE pack, capped below the arena's MAX_PACK. An arena pack is
## the whole encounter and the player can give ground in any direction; a lane
## pack is one of nine met head-on in a corridor, so seven is already a wall.
const LANE_PACK_MAX: int = 7

## Chance a pack member is an elite.
const ELITE_RATE_EARLY: float = 0.08
const ELITE_RATE_LATE: float = 0.34

## HOW FAR DOWN THE LANE THE BOSS SITS, in two parts, because a lane has only
## one place a boss can legally be — the arena at its end, which is the only
## floor wide enough for a 1.55x body and the only ground the approach leads to.
## So dread moves the boss WITHIN that arena, and moves the last pack toward it:
##
##   DOOR    metres of clear ground between the last pack and the arena rim. 26 m
##           early is a breather before the fight; 3 m late means the guard is
##           standing in the doorway and the boss joins what you are already in.
##   DEPTH   how far past the arena's centre the boss waits, as a fraction of its
##           radius. Early it comes to meet you near the entrance; late it waits
##           at the back, so you have to commit to the whole floor to reach it.
##
## It never leaves the arena, and the pack placement never enters it: a boss that
## wandered up the lane would be met mid-corridor by a player who still had four
## packs behind them.
const BOSS_DOOR_EARLY: float = 26.0
const BOSS_DOOR_LATE: float = 3.0
const BOSS_DEPTH_EARLY: float = 0.18
const BOSS_DEPTH_LATE: float = 0.76

## Smallest gap between two pack anchors, in metres — a pack is a group you
## clear before meeting the next one, and two anchors 8 m apart are one pack of
## twelve. Capped against the actual spacing available (see `_anchors`) so a
## short lane crowds its packs rather than dropping them.
const PACK_GAP_MIN: float = 16.0

## How far a pack's members scatter along the lane from their anchor, in metres,
## and how far across it. Both are ceilings: the along-figure is cut down to a
## fraction of the gap to the next pack (see `_spine`), so two packs can never
## interleave, and the across-figure stops a WIDE station 28 m across from
## spreading six bodies over its whole floor, which reads as six lone enemies
## rather than as a pack.
const PACK_SPREAD: float = 5.5
const PACK_SPREAD_LAT: float = 6.0
## Fraction of the gap to the next pack that a pack may scatter into.
const PACK_SPREAD_GAP: float = 0.45

## Metres kept between a body and the carved edge of the lane, so a pack member
## standing at the rim is not half inside the hillside.
const BODY_CLEAR: float = 1.4

## Clear ground past the safe radius before the first pack anchor.
const PACK_CLEAR: float = 4.0

## Levels gained from the entrance to the boss door, within one map. Small on
## purpose: the campaign ramp is Campaign.enemy_level's business and the tier
## step is where difficulty actually comes from. This is just enough that the
## far end of a lane out-levels its mouth.
const LANE_LEVEL_RAMP: float = 2.0

## Levels the boss adds on top of the deepest pack.
const BOSS_LEVELS: int = 2


# ------------------------------------------------------------------------------
# Who is in a map: the cast
# ------------------------------------------------------------------------------

## The recurring pool: the champions the campaign reuses on purpose.
##
## TWELVE, AGAINST TEN ACTS. Each act takes one of them as its WARLORD and that
## champion is in the cast of all ten of the act's maps — which is what makes an
## act feel inhabited rather than randomly staffed. The two left over appear only
## ever as the travelling RIVAL, so the recurring half of a cast cannot be read
## off the act number alone.
const RECURRING: int = 12

## Stride of the rival through the recurring pool. Coprime with RECURRING, so the
## rival walks all twelve before repeating and its appearances cross act
## boundaries instead of lining up with them.
const RIVAL_STRIDE: int = 7

## Smallest cast. The warlord and the rival can be the SAME champion — the
## rival's stride walks it onto the act's own warlord every so often, which is
## wanted, because the act's warlord turning up as a travelling rival in another
## act is a story — so locals are taken until the cast reaches this size rather
## than two at a time. Without that, those maps shipped a cast of three.
const CAST_MIN: int = 4

## How far the local window advances per map.
##
## Two, and a map takes the champions at `w` and `w + 1`: that walks the whole
## local list in order, so every local is reached within the first 63 maps and
## COVERAGE IS BY CONSTRUCTION rather than by luck, and the second half of the
## campaign then brings back champions the player met at its start, sixty maps of
## dread later. tools/encountertest.gd measures the coverage instead of assuming
## it, because the diversity fill below can shift which locals a map ends on.
const LOCAL_STEP: int = 2


## The champions one map features, in a fixed order:
##
##   [0] the act's warlord       recurring, present in all ten maps of the act
##   [1] the travelling rival    recurring, crossing acts
##   [2..] locals                this map's own, from the sliding window
##   then, only if a school is missing, one local per missing school
##
## FOUR TO SIX NAMES, and the variable length is the point: the trailing slots
## exist solely to guarantee that every map fields something that closes to
## melee, something that shoots and something that casts. A cast of five mages
## is a legal random draw and an unplayable map.
##
## Seeded from the campaign seed, so a given save always meets the same
## champions on map 37 and two different saves do not.
static func cast_for(map_index: int, campaign_seed: int,
		playable: PackedStringArray, avoid: String) -> PackedStringArray:
	var pool: PackedStringArray = _pool(playable, avoid)
	var out := PackedStringArray()
	if pool.is_empty():
		return out

	var order: PackedStringArray = _cast_order(campaign_seed, pool)
	var recur: int = clampi(RECURRING, 1, order.size())
	var locals: int = order.size() - recur
	var i: int = clampi(map_index, 0, Campaign.map_count() - 1)

	out.append(order[Campaign.act_of(i) % recur])
	var rival: String = order[(i * RIVAL_STRIDE + 5) % recur]
	if not (rival in out):
		out.append(rival)

	if locals <= 0:
		return out

	# The window. `w` advances with the map and wraps, so the whole local list is
	# consumed in order and then revisited.
	var w: int = (i * LOCAL_STEP) % locals
	var scan: int = 0
	while out.size() < CAST_MIN and scan < locals:
		var h: String = order[recur + (w + scan) % locals]
		scan += 1
		if h in out:
			continue
		out.append(h)

	# Fill only what is missing. Scanning forward from the window keeps these
	# picks near the map's own stretch of the local list rather than dragging in
	# a champion from the far end of the campaign.
	for cls in [HeroClass.Kind.FIGHTER, HeroClass.Kind.RANGER, HeroClass.Kind.MAGE]:
		if _has_class(out, cls):
			continue
		for n in range(locals):
			var h: String = order[recur + (w + scan + n) % locals]
			if h in out or HeroClass.for_hero(h) != cls:
				continue
			out.append(h)
			break
	return out


## The whole cast table, map by map. Exists so the assignment can be INSPECTED —
## by tools/encountertest.gd, and by anyone asking why map 61 is the way it is —
## rather than only sampled one map at a time.
static func cast_table(campaign_seed: int, playable: PackedStringArray,
		avoid: String) -> Array[PackedStringArray]:
	var out: Array[PackedStringArray] = []
	for i in range(Campaign.map_count()):
		out.append(cast_for(i, campaign_seed, playable, avoid))
	return out


## The twelve recurring champions of a campaign, in warlord order: entry `a` is
## the warlord of act `a`.
static func recurring_pool(campaign_seed: int, playable: PackedStringArray,
		avoid: String) -> PackedStringArray:
	var order: PackedStringArray = _cast_order(campaign_seed,
		_pool(playable, avoid))
	return order.slice(0, mini(RECURRING, order.size()))


## The roster, shuffled once per campaign: the first RECURRING entries are the
## recurring pool and the rest are locals. ONE shuffle for the whole campaign,
## not one per map — that single ordering is what lets recurrence be designed
## (this champion is act 4's warlord, that one is local to maps 12-13) instead of
## emerging from a hundred independent draws.
static func _cast_order(campaign_seed: int,
		pool: PackedStringArray) -> PackedStringArray:
	var a: PackedStringArray = pool.duplicate()
	var seed: int = Rng.seed_of(campaign_seed, "encounter.cast")
	# Fisher-Yates. `pool` arrives sorted (HeroRig.animated_heroes sorts), so the
	# input order is stable and the shuffle is the only thing deciding roles.
	for i in range(a.size() - 1, 0, -1):
		var j: int = int(Rng.unit2(seed, i, 17) * float(i + 1)) % (i + 1)
		var t: String = a[i]
		a[i] = a[j]
		a[j] = t
	return a


static func _has_class(names: PackedStringArray, cls: int) -> bool:
	for h in names:
		if HeroClass.for_hero(h) == cls:
			return true
	return false


## The roster minus the player's own champion — fighting your own model is
## confusing in a game whose entire enemy design is "other champions".
static func _pool(playable: PackedStringArray, avoid: String) -> PackedStringArray:
	var pool := PackedStringArray()
	for h in playable:
		if h != avoid:
			pool.append(h)
	return pool if not pool.is_empty() else playable


# ------------------------------------------------------------------------------
# Building a region
# ------------------------------------------------------------------------------

## Build the inhabitants of one region.
##
## `playable` is the roster to draw from (HeroRig.animated_heroes()), `avoid` is
## the player's own champion. `plan` is the layout the region was built from: a
## Lane gets spine placement and its map's cast, anything else (or nothing) gets
## the arena ring.
static func build(region_index: int, tier: int, campaign_seed: int,
		playable: PackedStringArray, avoid: String,
		pathing: Pathing, player_at: Vector2, plan: Layout = null) -> Array:
	if playable.is_empty():
		return []
	var out: Array = []
	if plan is Lane:
		out = _spine(plan as Lane, region_index, tier, campaign_seed,
			cast_for(region_index, campaign_seed, playable, avoid),
			pathing, player_at)
	else:
		out = _ring(region_index, tier, campaign_seed,
			_pool(playable, avoid), pathing, player_at)

	# Stamped here, after placement, so every path through this function gets
	# it — a ramp applied in only one of the two placers is the early campaign
	# being merciful on lanes and lethal in arenas.
	var m: float = Campaign.mercy(region_index, tier)
	var mh: float = Campaign.mercy_health(region_index, tier)
	for s in out:
		s.mercy = m
		s.mercy_health = mh
	return out


# ------------------------------------------------------------------------------
# RING PLACEMENT — the arena, and therefore PvP. Unchanged.
# ------------------------------------------------------------------------------

## How many bodies share a pack in a ring placement. Three keeps a group
## small enough to fight and large enough to feel like a group.
const RING_PACK_SIZE: int = 3


static func _ring(region_index: int, tier: int, campaign_seed: int,
		pool: PackedStringArray, pathing: Pathing, player_at: Vector2) -> Array:
	var out: Array = []
	var seed: int = Campaign.region_seed(campaign_seed, region_index)
	var level: int = Campaign.enemy_level(region_index, tier)

	var span: int = MAX_PACK - MIN_PACK
	var count: int = MIN_PACK + int(Rng.unit2(seed, region_index, 11) * float(span + 1))
	count = clampi(count, MIN_PACK, MAX_PACK)

	for i in range(count):
		var s := Spawn.new()
		s.seed = Rng.hash2(seed, i, 101)
		s.hero = pool[absi(s.seed) % pool.size()]
		s.cls = HeroClass.for_hero(s.hero)
		# A couple of elites per pack, picked by the same stream.
		var elite: bool = Rng.unit2(seed, i, 29) < 0.22
		s.is_elite = elite
		s.size = ELITE_SIZE if elite else 1.0
		s.level = level + (1 if elite else 0)
		# PACK MEMBERSHIP, which _ring used to leave at its default of -1 —
		# and -1 is the BOSS marker, so every arena enemy was reading as a
		# boss to anything that groups by pack. The ring has no lane to walk
		# down, so membership is by proximity instead: consecutive spawns
		# share a pack, which is also how they end up standing together.
		s.pack = i / maxi(RING_PACK_SIZE, 1)
		s.at = _place(pathing, player_at, seed, i, 9.0, 34.0)
		out.append(s)

	# The boss. Drawn from the rarest champions available so the silhouette at
	# the end of a region is one the player wants rather than one they have
	# already seen four of in the pack.
	var boss := Spawn.new()
	boss.is_boss = true
	boss.seed = Rng.hash2(seed, 9999, 7)
	var rare: PackedStringArray = Champion.of_rarity(pool, Item.Rarity.LEGENDARY)
	if rare.is_empty():
		rare = Champion.of_rarity(pool, Item.Rarity.EPIC)
	if rare.is_empty():
		rare = pool
	boss.hero = rare[absi(boss.seed) % rare.size()]
	boss.cls = HeroClass.for_hero(boss.hero)
	boss.size = BOSS_SIZE
	boss.level = level + 2
	boss.at = _place(pathing, player_at, seed, 777, 26.0, 46.0)
	out.append(boss)
	return out


## A walkable point in a ring around the player. Rejects anything inside
## SAFE_RADIUS and falls back to the nearest walkable cell rather than returning
## an unwalkable point, because a spawn inside geometry is invisible and
## unkillable and the player just hears something hitting them.
static func _place(pathing: Pathing, origin: Vector2, seed: int, i: int,
		near: float, far: float) -> Vector2:
	for attempt in range(12):
		var a: float = Rng.unit2(seed, i * 31 + attempt, 3) * TAU
		var r: float = near + Rng.unit2(seed, i * 31 + attempt, 5) * (far - near)
		var p: Vector2 = origin + Vector2(cos(a), sin(a)) * r
		if p.distance_to(origin) < SAFE_RADIUS:
			continue
		if pathing.is_walkable(p):
			return pathing.nearest_walkable_centre(p)
	# Everything was blocked — push out along one axis and snap.
	return pathing.nearest_walkable_centre(origin + Vector2(far, 0.0))


# ------------------------------------------------------------------------------
# SPINE PLACEMENT — the campaign lane
#
# A lane is a journey, so its inhabitants are a sequence: packs anchored along
# the route with clear ground between them, each one met, fought and left behind
# before the next is in range, and the boss waiting at the end of it.
# ------------------------------------------------------------------------------

## "No legal spot here." A pack member is DROPPED rather than placed illegally:
## a body inside a hillside is invisible and unkillable, and one inside the safe
## radius turns the first second of a map into an ambush. Both are worse than a
## pack of four where five was asked for.
const _NOWHERE: Vector2 = Vector2(INF, INF)

## Lateral placements tried per pack member before the spawn is given up on.
const PLACE_ATTEMPTS: int = 5


static func _spine(lane: Lane, index: int, tier: int, campaign_seed: int,
		cast: PackedStringArray, pathing: Pathing, player_at: Vector2) -> Array:
	var out: Array = []
	if cast.is_empty():
		return out

	var seed: int = Campaign.region_seed(campaign_seed, index)
	var dread: float = Campaign.dread(index)
	var level: int = Campaign.enemy_level(index, tier)
	var length: float = maxf(lane.total_length(), 0.001)

	var boss_node: Dictionary = lane.node_of_kind(Layout.BOSS)
	var boss_r: float = float(boss_node.get("radius", 0.0))
	var boss_c: Vector2 = boss_node.get("pos", lane.position_at(1.0))

	# The stretch of lane a pack may stand in: past the entrance's safe radius,
	# stopping short of the boss arena rim by the dread-driven door.
	var from_arc: float = SAFE_RADIUS + PACK_CLEAR
	var to_arc: float = length - boss_r \
		- lerpf(BOSS_DOOR_EARLY, BOSS_DOOR_LATE, dread)

	# THE RIM OF THE BOSS FLOOR, which no pack member may cross. The anchors stop
	# short of it by the door above, but the SCATTER does not: at dread 1 the door
	# is 3 m and a body may scatter 5.5 m along the lane, so the last pack of the
	# last map stood two bodies inside the arena — met at the same moment as the
	# fight the whole lane leads up to, which is the one thing spine placement
	# exists to prevent. Only the sweep over the whole campaign in
	# tools/encountertest.gd caught it; maps 4 and 98 both looked clean.
	var ceiling: float = length - boss_r - BODY_CLEAR

	var packs: int = int(round(lerpf(float(PACKS_EARLY), float(PACKS_LATE), dread)))
	var anchors: PackedFloat32Array = _anchors(lane, seed, from_arc, to_arc,
		packs, player_at)

	# How far a pack may scatter along the lane, measured from the gap the lane
	# ACTUALLY left between the anchors rather than from the constant. A pack
	# that scatters half way to its neighbour is not a pack, and on a short lane
	# the constant alone would let two of them interleave into one long smear.
	var spread: float = clampf(_closest_gap(anchors) * PACK_SPREAD_GAP, 1.0,
		PACK_SPREAD)

	for k in range(anchors.size()):
		var arc: float = anchors[k]
		var t: float = clampf(arc / length, 0.0, 1.0)
		# WIDTH MODULATES THE PACK, so the lane's own rhythm becomes the fight's:
		# a pinch holds a line of three that has to be broken through, a clearing
		# holds a crowd that surrounds. Lane.width_at reads the carved ground
		# rather than an intention, so this follows what was actually built.
		var want: float = lerpf(PACK_EARLY, PACK_LATE, dread) \
			* clampf(lane.width_at(t) / 8.0, 0.62, 1.35)
		var members: int = clampi(int(round(want)), 2, LANE_PACK_MAX)
		for j in range(members):
			var salt: int = k * 97 + j
			var at: Vector2 = _on_lane(lane, pathing, player_at, arc, spread,
				ceiling, boss_c, boss_r, seed, salt)
			if not at.is_finite():
				continue
			var s := Spawn.new()
			s.seed = Rng.hash2(seed, salt, 101)
			# From the MAP'S CAST, not the roster: the champions a lane fields
			# are its identity, and a fresh draw per body would make every map
			# the same statistical soup of 139 names.
			s.hero = cast[absi(Rng.hash2(seed, salt, 211)) % cast.size()]
			s.cls = HeroClass.for_hero(s.hero)
			# The pack at the boss door always fields an elite — it is the boss's
			# guard, and a guard that is four identical mooks does not read as one.
			var elite: bool = Rng.unit2(seed, salt, 29) \
					< lerpf(ELITE_RATE_EARLY, ELITE_RATE_LATE, dread) \
				or (k == anchors.size() - 1 and j == 0)
			s.is_elite = elite
			s.size = ELITE_SIZE if elite else 1.0
			s.pack = k
			s.at = at
			s.progress = lane.progress_at(at)
			s.level = level + int(round(s.progress * LANE_LEVEL_RAMP)) \
				+ (1 if elite else 0)
			out.append(s)

	out.append(_boss_at_the_end(lane, pathing, boss_node, cast, seed, dread, level))
	return out


## Where the packs stand, as arc lengths along the lane.
##
## AN EVEN SPREAD, jittered, then snapped to the lane's own rooms. Even because
## "distributed along the lane" is the requirement and uniform noise clusters:
## two of nine draws landing 5 m apart is unremarkable for a random stream and
## reads in play as one double pack followed by a long empty walk. Snapped
## because Lane already alternates PINCH / OPEN / WIDE stations, and a pack
## standing in a room is a fight the ground was shaped for.
static func _anchors(lane: Lane, seed: int, from_arc: float, to_arc: float,
		packs: int, player_at: Vector2) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var span: float = to_arc - from_arc
	if packs <= 0 or span <= 0.0:
		return out

	var step: float = span / float(maxi(packs - 1, 1))
	# The floor on spacing cannot exceed the spacing the lane has room for, or a
	# short lane pushes every anchor into the last one and loses its packs.
	var gap_min: float = minf(PACK_GAP_MIN, step * 0.7)
	var used: Array[int] = []
	var prev: float = -1e9

	for k in range(packs):
		var a: float = from_arc + span * 0.5 if packs == 1 \
			else from_arc + step * float(k)
		a += Rng.range2(seed, k, 71, -step * 0.18, step * 0.18)
		a = _snap_to_station(lane, a, minf(step * 0.45, 18.0), used)
		var lo: float = maxf(from_arc, prev + gap_min)
		if lo > to_arc:
			break
		a = _clear_of_entrance(lane, clampf(a, lo, to_arc), to_arc, player_at)
		if a < 0.0 or a <= prev:
			continue
		out.append(a)
		prev = a
	return out


## The smallest gap the anchors ended up with, in metres.
static func _closest_gap(anchors: PackedFloat32Array) -> float:
	if anchors.size() < 2:
		return PACK_SPREAD / PACK_SPREAD_GAP
	var best: float = 1e9
	for i in range(1, anchors.size()):
		best = minf(best, anchors[i] - anchors[i - 1])
	return best


## Pull an anchor onto the nearest unclaimed station within `reach` metres.
static func _snap_to_station(lane: Lane, arc: float, reach: float,
		used: Array[int]) -> float:
	var length: float = maxf(lane.total_length(), 0.001)
	var best: int = -1
	var best_d: float = reach
	for k in range(lane.stations.size()):
		if k in used:
			continue
		# Never the entrance or the boss arena. One is inside the safe radius;
		# the other is the boss's floor, and a pack waiting in there would be met
		# at the same moment as the fight the whole map leads up to.
		var kind: String = String(lane.nodes[lane.stations[k]]["kind"])
		if kind == Layout.ENTRY or kind == Layout.BOSS:
			continue
		var d: float = absf(lane.station_progress(k) * length - arc)
		if d < best_d:
			best_d = d
			best = k
	if best < 0:
		return arc
	used.append(best)
	return lane.station_progress(best) * length


## Slide an anchor further down the lane until the ground under it is genuinely
## outside the entrance's safe radius. Returns -1 if the lane runs out first.
##
## ARC LENGTH IS NOT DISTANCE on a serpentine lane: the route folds back on
## itself three or four times, so a point ninety metres along it can pass within
## a few metres of the mouth. Walking the anchor forward is the honest fix —
## refusing it would leave a hole in the sequence, and placing it anyway opens
## the map with the player already in contact.
static func _clear_of_entrance(lane: Lane, arc: float, to_arc: float,
		player_at: Vector2) -> float:
	var length: float = maxf(lane.total_length(), 0.001)
	var a: float = arc
	while a <= to_arc:
		if lane.position_at(a / length).distance_to(player_at) \
				>= SAFE_RADIUS + PACK_CLEAR:
			return a
		a += 4.0
	return -1.0


## A legal spot for one pack member: on the lane, on walkable ground, outside the
## entrance's safe radius AND outside the boss's arena.
##
## The attempts shrink the LATERAL offset toward zero, so the last one is the
## centreline itself — the one point the generator guarantees, because the spine
## is what Terrain carved the floor from. Scatter can still stand a boulder on a
## single cell, so a one-cell snap is allowed after that, and then the spawn is
## dropped rather than placed somewhere it does not belong.
##
## `ceiling` is the furthest arc length a body may stand at — the rim of the boss
## floor. It CLAMPS the along-lane scatter rather than rejecting it, so a late
## map's door pack crowds up against the arena instead of losing the two bodies
## whose jitter happened to point forward.
static func _on_lane(lane: Lane, pathing: Pathing, player_at: Vector2,
		arc: float, spread: float, ceiling: float, boss_c: Vector2,
		boss_r: float, seed: int, salt: int) -> Vector2:
	var length: float = maxf(lane.total_length(), 0.001)
	# Scattered along the lane as well as across it, so a pack is a group rather
	# than a rank standing shoulder to shoulder on one contour.
	var t: float = clampf(minf(arc + Rng.range2(seed, salt, 73, -spread, spread),
		ceiling) / length, 0.0, 1.0)
	var p: Vector2 = lane.position_at(t)
	var tan: Vector2 = lane.tangent_at(t)
	var perp: Vector2 = Vector2(-tan.y, tan.x)
	var half: float = clampf(lane.width_at(t) * 0.5 - BODY_CLEAR, 0.0,
		PACK_SPREAD_LAT)
	var lat: float = Rng.range2(seed, salt, 74, -half, half)

	for attempt in range(PLACE_ATTEMPTS):
		var shrink: float = 1.0 - float(attempt) / float(PLACE_ATTEMPTS - 1)
		var q: Vector2 = p + perp * (lat * shrink)
		if not pathing.is_walkable(q):
			continue
		# Checked on the SNAPPED point, not the candidate: the cell centre is
		# where the body will actually stand.
		var c: Vector2 = pathing.nearest_walkable_centre(q)
		if _legal(c, player_at, boss_c, boss_r):
			return c

	var fallback: Vector2 = pathing.nearest_walkable_centre(p)
	if fallback.distance_to(p) <= BODY_CLEAR * 2.0 \
			and _legal(fallback, player_at, boss_c, boss_r):
		return fallback
	return _NOWHERE


## Ground a pack member is allowed to stand on. The arc clamp in `_on_lane`
## keeps the scatter out of the arena in ARC LENGTH; this is the same rule in
## METRES, and it is the one that actually holds, because a lane arrives at its
## arena on a curve and the last few metres of arc are not the last few metres
## of distance.
static func _legal(p: Vector2, player_at: Vector2, boss_c: Vector2,
		boss_r: float) -> bool:
	return p.distance_to(player_at) >= SAFE_RADIUS \
		and (boss_r <= 0.0 or p.distance_to(boss_c) > boss_r)


## The boss, in its arena at the far end of the lane.
##
## It does not move up the lane and it is not placed by progress: the arena is
## the only floor on the map wide enough for a 1.55x body, and the approach to it
## is a processional the whole lane leads down. What dread moves is how far
## INSIDE the arena it waits — see BOSS_DEPTH_*.
static func _boss_at_the_end(lane: Lane, pathing: Pathing,
		boss_node: Dictionary, cast: PackedStringArray, seed: int, dread: float,
		level: int) -> Spawn:
	var s := Spawn.new()
	s.is_boss = true
	s.seed = Rng.hash2(seed, 9999, 7)
	s.hero = _rarest(cast, seed)
	s.cls = HeroClass.for_hero(s.hero)
	s.size = BOSS_SIZE
	s.progress = 1.0
	s.level = level + int(round(LANE_LEVEL_RAMP)) + BOSS_LEVELS

	var centre: Vector2 = lane.position_at(1.0)
	var r: float = 0.0
	if not boss_node.is_empty():
		centre = boss_node["pos"]
		r = float(boss_node["radius"])

	# Along the heading the lane ARRIVED on, so "deeper" means away from the door
	# rather than some arbitrary direction that might put the boss back in the
	# corridor the player is walking down.
	var at: Vector2 = centre + lane.tangent_at(1.0) \
		* (lerpf(BOSS_DEPTH_EARLY, BOSS_DEPTH_LATE, dread) * r)
	if not pathing.is_walkable(at):
		at = pathing.nearest_walkable_centre(at)
	# A snap must never carry the boss out of its own arena; the centre of the
	# floor is always walkable, because the carve flattens it.
	if at.distance_to(centre) > r:
		at = pathing.nearest_walkable_centre(centre)
	s.at = at
	return s


## The boss champion: the RAREST member of the map's cast.
##
## A boss is a silhouette the player is meant to want, and the cast is where a
## map's identity lives — so the two should be the same champion rather than two
## unrelated draws. Ties are broken by a seeded per-name key so the answer is
## stable rather than "whichever the cast happened to list first".
static func _rarest(cast: PackedStringArray, seed: int) -> String:
	var best: String = cast[0]
	var best_r: int = Champion.rarity_of(best)
	var best_k: int = absi(Rng.seed_of(seed, best))
	for h in cast:
		var r: int = Champion.rarity_of(h)
		var k: int = absi(Rng.seed_of(seed, h))
		if r > best_r or (r == best_r and k > best_k):
			best = h
			best_r = r
			best_k = k
	return best


## The combat body for a spawn, tier-scaled.
##
## Health and damage multipliers come from Campaign so that NORMAL..OBLIVION mean
## the same thing to an enemy champion as they do to everything else, and the
## boss gets a further multiplier on top because one body that dies as fast as
## a pack member is not a boss fight.
##
## THE TIER MULTIPLIER IS APPLIED ONCE, TO HEALTH, AND NEVER TO THE ATTRIBUTES.
## This shipped doing both — the boss's whole Stats block was scaled by the
## HEALTH multiplier and then its max_health was multiplied by it again — and
## because nothing had ever run this file, nothing said so. Measured, that gave:
##
##   * a boss/pack health ratio that was not a ratio at all but a function of
##     the tier: x8 at Normal, x96 at Eternal, x1802 at Oblivion;
##   * the health multiplier acting as a DAMAGE multiplier, because STR/AGI/INT
##     were scaled with CON — 45,463 attack power against a mook's 2,564;
##   * dodge and crit pinned at Stats' 0.40 / 0.60 caps from Eternal upward, so
##     the climax of every late map was a 40%-miss wall. A cap reached by a
##     health constant is a balance decision nobody made.
##
## So the attributes a boss fights with are its champion's own, grown to its
## level and scaled by Champion.stat_multiplier like everything else, and all
## three ways a boss is harder are the explicit BOSS_* constants above.
static func body_for(s: Spawn, tier: int) -> Combatant:
	var base: Stats = HeroClass.base_stats(s.cls)
	var grown: Stats = base.plus(HeroClass.growth_to(s.cls, s.level))
	grown = grown.scaled(Champion.stat_multiplier(s.hero))

	var hp_mult: float = Campaign.enemy_health_mult(tier) \
		* (BOSS_HEALTH_MULT if s.is_boss else 1.0) * s.mercy_health
	var dmg_mult: float = Campaign.enemy_damage_mult(tier) \
		* (BOSS_DAMAGE_MULT if s.is_boss else 1.0) * s.mercy

	# dmg_mult carries the TIER and boss multipliers only; the early-campaign
	# ramp rides damage_scale above, so it is not applied twice here.
	var weapon: float = 4.0 * float(s.level) \
		* (dmg_mult / maxf(s.mercy, 0.0001))
	var armour: float = 3.0 * float(s.level) \
		* (BOSS_ARMOUR_MULT if s.is_boss else 1.0)

	var c: Combatant = Combatant.make(
		s.display_name(), Combatant.Team.ENEMY, s.level, grown,
		HeroClass.school_of(s.cls), weapon, armour, s.seed)
	# Health is multiplied here rather than through the stat block so that the
	# tier scales the one number it is meant to scale. Stats.max_health() is
	# linear in constitution, so the result is identical for health and leaves
	# damage, crit, dodge and haste alone.
	# The ramp reaches the whole output, not just the weapon component — see
	# Combatant.damage_scale.
	c.damage_scale = s.mercy
	c.max_health *= hp_mult
	c.health = c.max_health
	return c
