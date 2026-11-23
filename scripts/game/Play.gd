extends Node3D

# Preloaded rather than relied on by class_name: a newly added script is not in
# Godot's global class cache until the editor has reimported, and every
# headless harness that loads this scene would fail to PARSE until someone
# opened the project. A preload resolves by path and has no such dependency.
const MapShape := preload("res://scripts/game/MapShape.gd")
const GameMode := preload("res://scripts/game/GameMode.gd")
const Party := preload("res://scripts/game/Party.gd")
# ------------------------------------------------------------------------------
# The playable slice: generate a region on the background thread, drop a hero in
# it, and let the player fight in it.
#
# INPUT IS TOUCH-FIRST, because this ships on iOS only:
#   tap / click        walk there
#   hold / drag        keep walking toward the finger
#   on-screen keys     basic attack and the three abilities (scripts/ui/Hud.gd)
#   1-4                the same four actions, for desktop testing only
#
# The keyboard bindings are kept deliberately: every tools/ harness and every
# editor run is driven from them, and they cost nothing on a device that has no
# keyboard. They are a developer convenience, NOT the shipping control scheme —
# that is the HUD, and until it existed the game could not be played at all.
#
# A TAP ON A CONTROL MUST NEVER ALSO MOVE THE CHAMPION, which is the classic bug
# in a touch game that mixes a world-space tap target with on-screen buttons.
# Two guards, see `_unhandled_input` and Hud.blocks_point().
#
# THE LOOT LOOP CLOSES HERE: an enemy's death rolls a drop (Loot.gd), the orb
# lands where it fell, walking over it banks it in the account's stash and
# wallet, and the champion's own combat body is built FROM that stash — so the
# next region is fought with what the last one paid out.
# ------------------------------------------------------------------------------

@export var world_seed: int = 7000
@export var biome: String = "greenwood"
@export var hero: String = ""

## The champion's level. The shell knows the real figure from the save (see
## Roster/HeroProgress) and may set it before this node enters the tree; on its
## own — tools/, the editor — the slice plays a fresh level 1 champion rather
## than reading the player's save file behind their back.
##
## Ignored when a roster IS supplied: the save is then the authority on what
## level the champion is, and two sources for one number is one too many.
@export var champion_level: int = 1

## The difficulty tier being played. Drives enemy scaling and, through Loot,
## what a kill is allowed to drop — see Campaign.gd.
@export var tier: int = Campaign.Tier.NORMAL

## WHICH MAP THIS IS, and the campaign it belongs to.
##
## Encounter.build() needs both: the map index picks the cast, the pack count,
## the elite rate and how far down the lane the boss stands, and the campaign
## seed is what makes map 7 of YOUR campaign the same map every time you play
## it. Neither was ever passed, which is the whole reason a campaign map was
## empty — the encounter builder was complete, tested and never called.
@export var region_index: int = 0
@export var campaign_seed: int = 0

## Region size in walk cells, at 0.5 m each. 384 is the shipping figure (192 m
## of ground, about four seconds of generation); it is an export only so a
## headless harness can ask for a small region and still exercise the real
## scene rather than a stub of it.
## Region size in walk cells, at 0.5 m each.
##
## ZERO MEANS "ask the map's shape" (MapShape.gd), which is what the campaign
## wants. A positive value overrides it, which is what the headless harnesses
## do — they run the REAL scene on a 96-cell region so a test is seconds
## rather than minutes. Zero-as-unset rather than a separate flag because the
## harnesses set this with `play.set("region_cells", n)`, and a flag they do
## not know to set would silently never be true.
@export var region_cells: int = 0

## THE PLAYER'S ACCOUNT, assigned by whoever launched this scene (UiShell.gd)
## before it enters the tree.
##
## Play.gd never calls Roster.load_or_create() itself. Persistence is one file
## by design (Roster.gd) and a second reader becomes a second writer the moment
## loot is picked up, at which point the stash the menus are showing and the
## stash the region is filling are different objects and one of them is about to
## be overwritten. See `_resolve_roster`.
var roster: Roster = null

## Which world generator this scene uses. LANE is the campaign; PvP will set
## ARENA when it exists. Settable from outside before the scene is added, the
## same way `biome` and `hero` are.
var layout_kind: int = Terrain.Kind.LANE

## WHICH KIND OF RUN THIS IS. Campaign unless a launcher says otherwise, so
## every existing caller keeps the behaviour it had. See GameMode.gd.
@export var mode: int = GameMode.Id.CAMPAIGN

## Which wave of a multi-wave mode is on the field. Always 0 in the campaign.
var _wave: int = 0
## Kept so later waves can be placed without rebuilding the world — a descent
## that regenerated its arena between waves would be a loading screen with
## combat in it.
var _terrain: Terrain = null
var _plan: Layout = null
var _player_hero: String = ""

var _builder: WorldBuilder
var _cam: ArpgCamera
var _hero: HeroController
var _hud: Hud
## Everything lying on the ground, and the only path from a kill into the stash.
var _loot: Loot.Ground
## The account this region is being played on — `roster`, or the scratch one
## `_resolve_roster` falls back to. Never null once _ready has run.
var _account: Roster
## Set when loot has been banked but not yet written to disk. See `_bank_now`.
var _unsaved: bool = false
var _holding: bool = false
var _hold_at: Vector2 = Vector2.ZERO
## The touch that is currently steering. Releases are matched against it, so a
## second finger landing on an ability key cannot cancel the walk the first one
## is still giving.
var _hold_index: int = -1

## The movement stick, and the live touches NOT claimed by it or the HUD.
##
## Pinch needs two fingers that are genuinely free: the stick owns one and the
## ability keys own others, so pinching while walking must not be read as the
## stick jumping across the screen. Tracking position by index is what keeps
## the three input sources from stealing each other's fingers.
var _stick: Joystick = null
var _free_touches: Dictionary = {}        # index -> Vector2
var _pinch_prev: float = -1.0

## The boss is down and the map is banked. Carries the run summary; UiShell
## turns it into the clear screen.
signal region_cleared(summary: Dictionary)

## Everything hostile in the region, and the node each one is drawn at.
##
## THE ENCOUNTER SEAM. Nothing spawns enemies yet; when something does, it calls
## add_enemy() and gets target acquisition, cast resolution, health bars,
## damage numbers AND loot without touching this file again. Parallel arrays
## because Combat.Context wants them that way.
var _enemies: Array[Combatant] = []
var _enemy_nodes: Array[Node3D] = []
## A stable id per enemy, parallel to the two arrays above. A death is reported
## by id rather than by index because those arrays are compacted as corpses are
## pruned, so an index captured at spawn would name a different enemy by the
## time it died — or nothing at all.
var _enemy_ids: PackedInt32Array = PackedInt32Array()
var _next_enemy_id: int = 1

## THE PARTY — up to three more of the player's own champions, fighting
## alongside the one being driven. See Party.gd for why they fight at a
## fraction of their strength and why enemies are allowed to kill them.
##
## NOT in _enemy_nodes, obviously, but also not merged into one "combatants"
## list: the enemy arrays are compacted as corpses are pruned, and a party
## that lived in them would be pruned too.
var _party: Array[HeroController] = []
## Which way the party is facing, in ground space, and where the champion was
## when it was last recomputed. See Party.station() for why this is not read
## off the champion's rotation every tick.
var _party_heading: Vector2 = Vector2(0.0, -1.0)
var _heading_from: Vector2 = Vector2.INF


func _ready() -> void:
	_cam = ArpgCamera.new()
	add_child(_cam)

	# Declared in scenes/Play.tscn so the HUD exists from the first frame — load
	# progress is reported through it — but built in code if this script is run
	# from a scene of someone else's making.
	_hud = get_node_or_null("Hud") as Hud
	if _hud == null:
		_hud = Hud.new()
		_hud.name = "Hud"
		add_child(_hud)
	_hud.action.connect(_on_hud_action)
	_hud.dodge_pressed.connect(_on_hud_dodge)

	# Added ABOVE the HUD in draw order but below it in input priority: the
	# stick runs in _input (which sees events before _unhandled_input) yet only
	# consumes presses inside its own zone, so the ability keys on the right
	# keep working while a thumb is on the stick.
	_stick = Joystick.new()
	_stick.name = "Joystick"
	_stick.moved.connect(_on_stick)
	add_child(_stick)

	_account = _resolve_roster()
	_build_loot_ground()

	_builder = WorldBuilder.new()
	add_child(_builder)
	_builder.progress.connect(func(s: String, f: float):
		_hud.set_message("%s  %d%%" % [s, int(f * 100.0)], true))
	_builder.finished.connect(_on_world_ready)
	# THE MAP'S SHAPE COMES FROM ITS INDEX, not from literals here.
	#
	# This call used to pass `Kind.LANE, 384 cells, 11 nodes` for every one of
	# the hundred campaign maps, so the whole campaign was one floor plan in
	# sixteen palettes. MapShape.at() gives each map a form — a spine, a
	# warren, a long causeway, an open hollow, a looping crossroads — and acts
	# end on the big colosseum. See MapShape.gd.
	#
	# `region_cells` stays an override rather than being ignored: headless
	# harnesses set it small to exercise the real scene quickly, and a shape
	# that forced 448 cells on them would make every test slow. A caller that
	# has not asked for a size gets the shape's own.
	# A descent or a gauntlet is fought in its own arena, not in whatever
	# form the region index happened to pick — see GameMode.shape_of().
	var shape: Dictionary = MapShape.at(region_index)
	if mode != GameMode.Id.CAMPAIGN:
		var mode_shape: Dictionary = GameMode.shape_of(mode)
		if not mode_shape.is_empty():
			shape = mode_shape
	var cells: int = (region_cells if region_cells > 0
		else int(shape.get("cells", 384)))
	_builder.build(world_seed, biome, maxi(cells, 32), 0.5,
		Layout.Sym.ASYMMETRIC, int(shape.get("nodes", 11)),
		int(shape.get("kind", Terrain.Kind.LANE)),
		String(shape.get("id", "")))
	layout_kind = int(shape.get("kind", Terrain.Kind.LANE))
	_hud.set_message("%s — %s" % [shape.get("name", ""),
		shape.get("blurb", "")])


## The account loot is banked into.
##
## Assigned by the launcher if it has one; failing that, asked of the node that
## launched this scene, which keeps UiShell's "ONE ROSTER" rule true without
## this file knowing what a UiShell is. Failing even that, a scratch account
## that is NEVER saved — a region played from tools/ or from the editor still
## drops, still shows orbs and still fills a stash, and cannot touch the
## player's file while doing it.
func _resolve_roster() -> Roster:
	if roster != null:
		return roster
	var launcher: Node = get_parent()
	if launcher != null:
		var theirs = launcher.get("roster")
		if theirs is Roster:
			roster = theirs
			return roster
	# MARKED EPHEMERAL, because this file calls _account.save() in five places
	# and every one of them would otherwise write this empty account straight
	# over the player's real one. The claim above that it is never saved was
	# false until the flag existed.
	var scratch := Roster.new()
	scratch.ephemeral = true
	return scratch


func _build_loot_ground() -> void:
	_loot = Loot.Ground.new()
	_loot.name = "Loot"
	# Keyed off the WORLD seed, not the account's, so one region's drops are
	# reproducible from the region alone — the same property the terrain has.
	_loot.region_seed = Rng.seed_of(world_seed, "loot")
	_loot.tier = tier
	_loot.champion_level = champion_level
	_loot.stash = _account.stash
	_loot.wallet = _account.wallet
	_loot.collected.connect(_on_loot_collected)
	# `dropped` was emitted and nothing listened. A good item landed as an orb
	# among procedurally scattered props and looked exactly like a pebble.
	_loot.dropped.connect(_on_loot_dropped)
	_loot.refused.connect(func(text: String) -> void: _hud.set_message(text))
	add_child(_loot)


func _on_world_ready(root: Node3D, ter: Terrain, plan: Layout) -> void:
	add_child(root)

	var we := WorldEnvironment.new()
	we.environment = Mesher.build_environment(biome)
	add_child(we)
	add_child(Mesher.build_sun(biome))

	var heroes: PackedStringArray = HeroRig.animated_heroes()
	var pick: String = hero if hero != "" else (heroes[0] if heroes.size() > 0 else "")
	if pick == "":
		_hud.set_message("No hero models found", true)
		return

	var entry: Dictionary = plan.node_of_kind(Layout.ENTRY)
	var at: Vector2 = entry.get("pos", Vector2.ZERO)

	_hero = HeroController.new()
	add_child(_hero)
	if not _hero.setup(ter, pick, at):
		_hud.set_message("Failed to load hero '%s'" % pick, true)
		return

	_give_combat_body(pick)

	_cam.terrain = ter
	_cam.target = _hero
	_cam.snap_to_target()
	# The champion is what picks loot up, so the ground cannot collect anything
	# until this point — orbs dropped before it simply wait, which is correct.
	_loot.follow = _hero
	_hud.bind_champion(_hero, _cam)
	# THE REGION IS A PLACE, and until now the player met all hundred of them
	# from the same three-metre bubble around their own feet. Sweep from the
	# boss end of the lane back to where they are standing, so the map they
	# are about to walk is seen once, whole, before they walk it.
	var boss_node: Dictionary = plan.node_of_kind(Layout.BOSS)
	var from: Vector2 = boss_node.get("pos", Vector2.INF)
	if from != Vector2.INF and from.distance_to(at) > 12.0:
		_flying = true
		_cam.flyover_done.connect(_on_flyover_done, CONNECT_ONE_SHOT)
		_cam.flyover(from, at)
		_hud.set_message("%s" % Campaign.region_title(region_index))
	else:
		_on_flyover_done()

	# AFTER the champion exists: every spawn is placed relative to where the
	# player stands, so this cannot run before `at` is a real position.
	_snapshot = {
		"gold": _account.wallet.balance(Wallet.Kind.GOLD),
		"items": _account.stash.items.size(),
		"level": _hero.body.level if _hero.body != null else 1,
	}
	_terrain = ter
	_plan = plan
	_player_hero = pick
	# BEFORE _populate, so the encounter builder places its packs relative to
	# a party that already exists rather than to a lone champion who is about
	# to be joined by three more bodies.
	_spawn_party(ter, at, pick)
	_populate(ter, plan, at, pick, 0)

	var rigged: String = "rigged" if _hero.rig.is_rigged else "STATIC (procedural stand-in)"
	print("hero '%s': %s" % [pick, rigged])
	if _hero.rig.is_rigged:
		print("  missing clips: ", _hero.rig.missing_states())


## Give the champion a body and its kit.
##
## WITHOUT THIS the controller has no `basic` and no `abilities`, which means
## every one of the four actions falls through to the attack clip, every cooldown
## reads as zero, and the champion has no health to lose — so the HUD would be
## four identical buttons over an empty bar. It is also what makes a stun mean
## anything: `is_stunned()` is false forever on a controller with no body.
##
## THE GEAR IS IN HERE. The body is assembled by Combat.champion_body from the
## account's stash, so the sword the player equipped on the stash screen is the
## sword that swings — this used to pass 0 weapon and 0 armour, which made every
## drop in the game a number that moved the character sheet and nothing else.
func _give_combat_body(name: String) -> void:
	var cls: int = HeroClass.for_hero(name)
	var body: Combatant = Combat.champion_body(_account, name, champion_level,
		Rng.seed_of(world_seed, name), ChampionName.of(name))
	# The save is the authority on level when there is one, and item level is
	# capped against the champion's (Loot.item_level).
	_loot.champion_level = body.level
	_hero.setup_combat(body, cls, name)
	_hero.cast_landed.connect(_on_cast_landed)
	_remark()


## The sweep is over — hand the region to the player.
func _on_flyover_done() -> void:
	_flying = false
	_cam.snap_to_target()
	_hud.set_message("Drag anywhere on the left to move. The keys on the "
		+ "right are your four actions. Pinch to zoom.")


## Put the veteran rings on the champion, or take them off.
##
## A champion who has cleared a whole difficulty is carrying something no
## amount of gear can buy, and until now the only place that showed was a
## number on a screen they were not looking at.
func _remark() -> void:
	if _mark != null and is_instance_valid(_mark):
		_mark.queue_free()
	_mark = null
	if _hero == null or _hero.rig == null:
		return
	var p: HeroProgress = _account.progress(_hero.rig.hero_name)
	if p == null or p.tiers_cleared <= 0:
		return
	_mark = Vfx.veteran_mark(_hero, p.tiers_cleared)


## A drop landed. Light it if it is worth crossing the map for.
##
## Common and uncommon get nothing on purpose: a beacon over every grey item
## is not a beacon, it is lighting, and the colour stops meaning anything.
func _on_loot_dropped(drop: Loot.Drop, at: Vector3) -> void:
	if drop == null or not drop.has_item():
		return
	var rarity: int = drop.item.rarity
	if rarity < Item.Rarity.RARE:
		return
	Vfx.loot_beacon(self, at,
		Item.RARITY_COLOURS.get(rarity, Color.WHITE))
	# Named on the HUD as well as lit: the colour says how good, the name says
	# what, and at a distance the pillar is all you can see.
	_hud.set_message("%s — %s" % [drop.item.item_name,
		String(Item.RARITY_NAMES.get(rarity, "?"))])
	Audio.play(Audio.Cue.CAST, 1.4 + 0.12 * float(rarity))


# ------------------------------------------------------------------------------
# Populating the region
# ------------------------------------------------------------------------------

## How far an enemy will notice the champion and come for them, in metres.
## Generous enough that walking into a pack starts a fight, short enough that
## the whole map does not converge on the player at once.
const AGGRO: float = 18.0
## A boss holds its ground at the end of the lane until you are close.
const AGGRO_BOSS: float = 26.0
## How close an enemy wants to be before it swings.
const REACH: float = 2.6
## Re-think this often, in seconds. Enemies do not need a decision every frame,
## and 139 rigs asking the pathfinder sixty times a second does not ship.
const THINK: float = 0.35

## How much closer than its preferred range an enemy tolerates before backing
## away. 0.6 means a mage happy at 8m starts retreating inside 4.8m.
const KITE_INNER: float = 0.6
## Share of its longest reaching ability a ranged enemy wants to stand at.
## Not the full range: standing at the exact edge means every step the player
## takes puts it out of range and it spends the fight shuffling.
const STAND_FRACTION: float = 0.72

## A RETREATING ENEMY WALKS. It used to run, at exactly the speed the champion
## runs — so a melee champion chasing an archer closed at 0 m/s and the fight
## was unwinnable without ranged abilities the class does not have. Walking
## away from a running champion loses ground at about 2.8 m/s, which is a
## chase the player wins in a couple of seconds and still has to commit to.
const RETREAT_RUN: bool = false

## ...AND ONLY FOR SO LONG. Speed alone still lets an archer back down the
## whole length of a lane, dragging the player through two more packs. After
## this many seconds of giving ground it plants and fights.
const RETREAT_BUDGET: float = 2.0
## How long it holds before it is allowed to give ground again.
const RETREAT_REST: float = 4.0

## THE BOSS MECHANIC. A boss that is only bigger and tougher is an endurance
## test; one you have to read is a fight. It winds up a ground slam, the
## ground tells you exactly where, and slam_warn() seconds to not be standing
## there — a window derived from how long leaving the circle actually takes,
## not picked by feel. See below.
const SLAM_RANGE: float = 16.0
const SLAM_RADIUS: float = 6.5
const SLAM_COOLDOWN: float = 7.0

## THE WINDOW IS DERIVED, NOT PICKED, because the picked one was impossible.
##
## The slam is aimed where the champion is STANDING, so the player always
## starts at dead centre and the worst case is the only case. Clearing
## SLAM_RADIUS at RUN_SPEED takes 6.5 / 6.2 = 1.05s of pure running. The old
## hand-tuned window was 1.15s, which left 0.1s to notice the ground light up
## and push a virtual joystick — so "dodge the telegraph" was not a hard
## mechanic, it was an unwinnable one wearing a mechanic's clothes. Every
## player was eating it every time and concluding the boss just hits hard.
##
## So the window is computed from the geometry it has to beat:
##
##   warn = reaction + (radius / run speed) * margin
##
## Change the radius or the run speed and the window follows. slamtest.gd
## asserts it stays survivable at every tier, so neither number can be tuned
## into impossibility again.
const SLAM_REACTION: float = 0.45
## Headroom over the theoretical minimum: nobody runs the perfect radial line
## out of a circle, and a thumb on glass is not a keyboard.
const SLAM_ESCAPE_MARGIN: float = 1.35

## Seconds of warning before the slam lands, for a difficulty tier.
##
## Harder tiers trim the margin — never the reaction time, and never below
## the time it physically takes to leave the circle.
static func slam_warn(tier: int) -> float:
	var tiers: int = maxi(Campaign.tier_count() - 1, 1)
	var hard: float = clampf(float(tier) / float(tiers), 0.0, 1.0)
	# Full margin on the gentlest tier, two thirds of it on the harshest.
	var margin: float = lerpf(SLAM_ESCAPE_MARGIN, SLAM_ESCAPE_MARGIN * 0.66,
		hard)
	var travel: float = SLAM_RADIUS / HeroController.RUN_SPEED
	return SLAM_REACTION + travel * maxf(margin, 1.0)
## Multiplier on the boss's attack power. It hurts, because it is avoidable —
## an avoidable hit that tickles teaches the player to ignore it.
const SLAM_POWER: float = 2.4
const SLAM_MAX_FRACTION: float = 0.55
## ...but never more than this share of the champion's maximum health.
##
## IT MUST BE SURVIVABLE FROM FULL. A telegraph exists to be read and dodged;
## one that kills outright is not a mechanic the player learns, it is a wipe
## they resent. Uncapped it took a champion from 194 to 0 in one hit, and a
## player who dies the first time they see a thing never finds out it was
## avoidable. Capped, standing in it is a serious mistake with a lesson
## attached.

var _brain_t: float = 0.0
## Pack indices that have noticed the player. See _think.
var _awake: Dictionary = {}
## Seconds since the region opened. The retreat budget is measured against it
## rather than against frame counts, so it behaves the same at 60 and 120 Hz.
var _clock: float = 0.0
## The enemy id of this map's boss, -1 once it is dead or was never placed.
var _boss_id: int = -1
var _kills: int = 0
## WHAT THIS RUN PRODUCED, for the quest board. Counted here rather than
## reconstructed afterwards: the stash cannot tell you WHICH region a piece
## came from, and "bring something back from map 23" is exactly that question.
var _elites_killed: int = 0
## rarity -> how many collected this run.
var _drops_by_rarity: Dictionary = {}
## equipment slot -> how many collected this run.
var _drops_by_slot: Dictionary = {}
## What the account held on arrival, so the clear screen can report what the
## run actually earned rather than what the player happens to own.
var _snapshot: Dictionary = {}

## The boss's slam: where it is landing, how big, and when it resolves. A
## telegraph has to be readable for a beat and then LAND, and the landing is
## resolved here rather than inside the effect so that killing the boss
## mid-wind-up cancels it.
var _slam_at: Vector2 = Vector2.INF
var _slam_radius: float = 0.0
var _slam_in: float = 0.0
var _slam_damage: float = 0.0
var _slam_cd: float = 0.0
## Freed and rebuilt when the champion's body changes, so a level-up does not
## leave two sets of rings turning.
var _mark: Node3D = null
## True while the opening sweep is running. Input is held: a champion being
## steered by a player who cannot see them is worse than no flyover.
var _flying: bool = false


## Put the map's encounters in the world.
##
## THE SEAM THAT WAS NEVER CLOSED. Encounter.build() and Encounter.body_for()
## were both written, both unit-tested and both unreachable: nothing in the
## playable scene called either, so every campaign map generated its lane, its
## packs and its boss and then loaded an empty region. A test that exercises a
## generator proves the generator works, not that the game uses it.
func _populate(ter: Terrain, plan: Layout, player_at: Vector2,
		player_hero: String, wave: int) -> void:
	var playable: PackedStringArray = HeroRig.animated_heroes()
	if playable.is_empty():
		return
	var pathing := Pathing.new(ter)

	# WHICH DIFFICULTY THIS WAVE BORROWS. Rather than a second balance curve,
	# a mode reuses the campaign's — enemy level, health, damage, elite rate
	# and loot odds all come free and stay consistent with what the player
	# already understands. See GameMode.scaling_index().
	var idx: int = GameMode.scaling_index(mode, wave) if mode != GameMode.Id.CAMPAIGN \
		else region_index
	var over: float = GameMode.overdrive(mode, wave)
	# A later wave must not be the same pack in the same spots: the seed moves
	# with the wave, so depth 7 is a different fight from depth 6.
	var seed_for_wave: int = campaign_seed + wave * 7919

	var spawns: Array = Encounter.build(idx, tier, seed_for_wave,
		playable, player_hero, pathing, player_at,
		null if mode != GameMode.Id.CAMPAIGN else plan)
	if GameMode.boss_only(mode, wave):
		# A gauntlet is bosses and nothing else. Filtering rather than asking
		# Encounter for a special case keeps one placement path under test.
		var only: Array = []
		for s2 in spawns:
			if (s2 as Encounter.Spawn) != null and (s2 as Encounter.Spawn).is_boss:
				only.append(s2)
		spawns = only

	var made: int = 0
	for s in spawns:
		var spawn := s as Encounter.Spawn
		if spawn == null:
			continue
		var foe := HeroController.new()
		add_child(foe)
		if not foe.setup(ter, spawn.hero, spawn.at):
			# A hero whose model will not load is skipped, not fatal: one bad
			# rig must not empty the rest of the map.
			foe.queue_free()
			continue
		# Bosses and elites read as dangerous by being BIGGER. It is the one
		# cue that survives a small screen with a thumb over half of it.
		foe.scale = Vector3.ONE * spawn.size
		var body: Combatant = Encounter.body_for(spawn, tier)
		# PAST THE END OF THE CAMPAIGN'S CURVE. A descent cannot stop getting
		# harder just because there are no deeper maps to borrow from; an
		# endless mode that plateaus ends in boredom rather than in death.
		if over > 1.0:
			body.max_health *= over
			body.health = body.max_health
			body.weapon_power *= over
		foe.setup_combat(body, spawn.cls, spawn.hero)
		foe.cast_landed.connect(_on_enemy_cast.bind(foe))
		var id: int = add_enemy(foe.body, foe)
		if spawn.is_boss:
			_boss_id = id

		# WHAT THIS ONE IS. Stamped on the node rather than kept in a parallel
		# array: the arrays are compacted as corpses are pruned and an index
		# captured here would name a different enemy ten seconds later — the
		# same trap the enemy ids exist to avoid.
		foe.set_meta("pack", spawn.pack)
		foe.set_meta("stand_off", _stand_off(foe, spawn))
		var trait_id: int = Elite.Trait.NONE
		if spawn.is_elite:
			trait_id = Elite.roll(world_seed, made)
			Elite.apply(foe.body, trait_id)
			Elite.mark(foe, trait_id)
		foe.set_meta("trait", trait_id)
		if spawn.is_elite:
			foe.set_meta("is_elite", true)
		made += 1

	print("region %d tier %d wave %d: %d enemies (x%.2f)"
		% [idx, tier, wave, made, over])
	if made == 0:
		# Loud, because an empty map is the exact failure this function exists
		# to end and it is invisible from inside the game.
		push_warning("Encounter.build placed nothing for region %d"
			% region_index)


## Enemies decide what to do, a few times a second.
func _think(delta: float) -> void:
	if _hero == null or _hero.is_dead():
		return
	_brain_t -= delta
	if _brain_t > 0.0:
		return
	_brain_t = THINK
	# The party thinks on the same clock as the enemies, so a partner never
	# gets a free extra action per frame relative to what it is fighting.
	_think_party()
	# Cooled down on the brain's clock, which is also the clock the slam is
	# resolved on — see _advance_slam, called every frame from _process.
	pass

	var here: Vector2 = _hero.ground_position()

	# PACKS WAKE TOGETHER. Each enemy used to notice the player on its own, so
	# a pack of five was fought as five separate duels at the edge of aggro
	# range — safe, slow, and nothing like the fight the encounter builder
	# laid out. One of them seeing you now wakes the group, which is what
	# makes a pack a pack.
	for n in _enemy_nodes:
		var w := n as HeroController
		if w == null or w.is_dead():
			continue
		var pack: int = int(w.get_meta("pack", -1))
		if pack < 0 or _awake.has(pack):
			continue
		# ANY member of the party walking into range wakes the pack, not just
		# the champion — a partner sent ahead is still someone walking into
		# the room.
		for member in _living_party():
			if w.ground_position().distance_to(
					member.ground_position()) <= AGGRO:
				_awake[pack] = true
				break

	for n in _enemy_nodes:
		var foe := n as HeroController
		if foe == null or foe.is_dead() or foe.body == null:
			continue
		if foe.is_busy() or foe.is_stunned():
			continue
		var at: Vector2 = foe.ground_position()
		# WHO THIS ONE IS COMING FOR. The nearest member of the party, which
		# with no partners is simply the champion — so the single-hero fight
		# is bit-for-bit what it was. See _threat_for().
		var mark: HeroController = _threat_for(foe)
		if mark == null:
			continue
		var aim: Vector2 = mark.ground_position()
		var gap: float = at.distance_to(aim)
		var is_boss: bool = foe.scale.y >= Encounter.BOSS_SIZE - 0.001
		var notice: float = AGGRO_BOSS if is_boss else AGGRO
		# Awake because a packmate saw you, or because this one did.
		if gap > notice and not _awake.has(int(foe.get_meta("pack", -1))):
			continue
		# Even an awake pack has a limit: enemies on the far side of the map
		# should not sprint the length of the lane at you.
		if gap > notice * 2.5:
			continue

		if is_boss and _slam_cd <= 0.0 and gap <= SLAM_RANGE:
			_begin_slam(foe, aim)
			continue

		# IT FIGHTS LIKE WHAT IT IS. Every enemy used to walk into melee range
		# and swing, which made a Ranger and a Mage and a Fighter the same
		# encounter wearing different models — across a roster of 139, that is
		# the single biggest thing the game was throwing away.
		var stand: float = float(foe.get_meta("stand_off", REACH))
		if gap > stand:
			# Back at a comfortable distance: it has earned its footing back.
			foe.set_meta("retreat_t", 0.0)
			if not foe.is_moving():
				foe.move_to(aim, true)
			continue
		if gap < stand * KITE_INNER and stand > REACH * 2.0:
			# Too close for what it does. Back off rather than trade punches
			# it is not built to win — but only while it has ground to give.
			# A cornered archer is a fight, not a chase.
			if _retreat(foe, aim, stand):
				continue
		foe.stop()
		# THE TARGET IS REMEMBERED for the cast, because _on_enemy_cast runs
		# a frame or more later from the animation and would otherwise resolve
		# against whoever is nearest THEN. An enemy that winds up on a partner
		# and lands on the player is the kind of damage nobody can account
		# for.
		foe.set_meta("mark", mark)
		foe.use_ability(_choose_action(foe, gap), aim)


# ------------------------------------------------------------------------------
# THE PARTY
# ------------------------------------------------------------------------------

## Put the player's partners on the field beside them.
##
## They are built exactly like the champion — Combat.champion_body, so their
## real level, their real stats and THEIR OWN EQUIPPED GEAR all come along —
## and then weakened to their contribution. A partner assembled any other way
## would be a different character from the one on the roster screen, which is
## the whole thing this feature is selling.
func _spawn_party(ter: Terrain, at: Vector2, leader: String) -> void:
	if _account == null or ter == null:
		return
	var pathing := Pathing.new(ter)
	var who_list: PackedStringArray = _account.companions(leader)
	for i in range(who_list.size()):
		var who: String = who_list[i]
		var want: Vector2 = Party.station(i, at, _party_heading)
		# A station inside a rock is a partner that cannot be placed at all,
		# so fall back to the champion's own cell rather than skipping them:
		# a missing partner is a far worse bug than two heroes standing close.
		if not pathing.is_walkable(want):
			want = at
		var mate := HeroController.new()
		add_child(mate)
		if not mate.setup(ter, who, want):
			# One unloadable rig must not take the rest of the party with it.
			mate.queue_free()
			continue
		var body: Combatant = Combat.champion_body(_account, who,
			champion_level, Rng.seed_of(world_seed, who), ChampionName.of(who))
		Party.weaken(body)
		mate.setup_combat(body, HeroClass.for_hero(who), who)
		# THE CONNECTION THAT MAKES A PARTNER DANGEROUS. Damage lands at the
		# END of an animation (HeroController._on_rig_state_finished), so a
		# controller whose cast_landed goes nowhere swings, recovers, and
		# hurts nothing at all.
		mate.cast_landed.connect(_on_ally_cast.bind(mate))
		# STAMPED, so _think can tell a partner from the champion without
		# searching _party every tick, and so the stand-off is computed once.
		mate.set_meta("is_partner", true)
		mate.set_meta("partner_slot", i)
		mate.set_meta("stand_off", _partner_stand_off(mate, who))
		_party.append(mate)
	if not _party.is_empty():
		print("party: %d partner(s) at x%.2f" % [_party.size(),
			Party.CONTRIBUTION])


## How far a partner wants to be from what it is hitting. Same rule the
## enemies use, so a partner Ranger kites and a partner Fighter closes.
func _partner_stand_off(mate: HeroController, who: String) -> float:
	if HeroClass.school_of(HeroClass.for_hero(who)) == HeroClass.School.MELEE:
		return REACH
	var longest: float = REACH
	for slot in range(1, 4):
		var ab: Ability = mate.ability_in_slot(slot)
		if ab != null and ab.shape != Ability.Shape.SELF:
			longest = maxf(longest, ab.range_m)
	return maxf(REACH, longest * STAND_FRACTION)


## Every member of the party still standing, champion first.
##
## CHAMPION FIRST, because this is what enemies pick their target from: an
## ordering accident here is the difference between "enemies come for whoever
## is closest" and "enemies ignore the player".
func _living_party() -> Array[HeroController]:
	var out: Array[HeroController] = []
	if _hero != null and not _hero.is_dead():
		out.append(_hero)
	for mate in _party:
		if mate != null and is_instance_valid(mate) and not mate.is_dead():
			out.append(mate)
	return out


## Who this enemy is coming for.
##
## THE NEAREST MEMBER OF THE PARTY, not the player. Without this, partners are
## three free damage dealers that nothing can touch, the player can stand
## behind them, and an encounter built for one champion is a formality. It is
## also what makes a partner's position mean something: putting one in front
## is a real decision with a real cost.
func _threat_for(foe: HeroController) -> HeroController:
	var party: Array[HeroController] = _living_party()
	if party.is_empty():
		return null
	var at: Vector2 = foe.ground_position()
	var best: HeroController = party[0]
	var best_gap: float = at.distance_to(best.ground_position())
	for i in range(1, party.size()):
		var gap: float = at.distance_to(party[i].ground_position())
		if gap < best_gap:
			best_gap = gap
			best = party[i]
	return best


## Partners pick a fight, or come back to the champion.
func _think_party() -> void:
	if _party.is_empty() or _hero == null:
		return
	var leader: Vector2 = _hero.ground_position()
	# The formation turns with where the champion is GOING, recomputed only
	# once they have actually covered some ground.
	if _heading_from == Vector2.INF:
		_heading_from = leader
	elif leader.distance_to(_heading_from) >= Party.HEADING_STEP:
		_party_heading = (leader - _heading_from).normalized()
		_heading_from = leader
	for mate in _party:
		if mate == null or not is_instance_valid(mate) or mate.is_dead():
			continue
		if mate.body == null or mate.is_busy() or mate.is_stunned():
			continue

		var target: HeroController = _partner_target(mate, leader)
		if target == null:
			# NOTHING TO FIGHT: fall in beside the champion. Measured from the
			# CHAMPION rather than from a fixed station, so a party that has
			# scattered during a fight regroups instead of walking back to
			# where the fight started.
			var station: Vector2 = Party.station(
				int(mate.get_meta("partner_slot", 0)), leader, _party_heading)
			var away: float = mate.ground_position().distance_to(station)
			# HYSTERESIS. One threshold makes a partner sitting exactly at the
			# gap start and stop on alternate ticks, which is a visible
			# twitch three times over. It sets off at FOLLOW_GAP and does not
			# settle until it is well inside.
			if away > Party.FOLLOW_GAP:
				if not mate.is_moving():
					mate.move_to(station, true)
			elif away < Party.FOLLOW_GAP * 0.55 and mate.is_moving():
				mate.stop()
			continue

		var aim: Vector2 = target.ground_position()
		var gap: float = mate.ground_position().distance_to(aim)
		var stand: float = float(mate.get_meta("stand_off", REACH))
		if gap > stand:
			# RE-PATHS WHEN THE TARGET HAS MOVED. "Only if not already
			# moving" means a partner walks to where an enemy USED to be and
			# then starts again from there, which against anything that kites
			# is an endless stutter one step behind.
			var going_to: Vector2 = mate.get_meta("chasing", Vector2.INF)
			if not mate.is_moving() or going_to == Vector2.INF \
					or going_to.distance_to(aim) > stand * 0.5:
				if mate.move_to(aim, true):
					mate.set_meta("chasing", aim)
			continue
		if gap < stand * KITE_INNER and stand > REACH * 2.0:
			if _retreat(mate, aim, stand):
				continue
		mate.stop()
		mate.set_meta("aim", aim)
		mate.use_ability(_partner_action(mate, gap), aim)


## Which ability a partner uses.
##
## NOT _choose_action, which is the ENEMY chooser: that one caps the kit by
## Campaign.enemy_actions(tier), because an enemy on Normal is deliberately
## allowed fewer abilities than the same enemy on Oblivion. Pointing a
## partner at it meant the player's own level-40 champion fought with one
## ability on Normal and three on Merciless — their kit getting BETTER as the
## game got harder, for no reason anyone could discover.
##
## A partner is the player's champion and uses everything it has.
func _partner_action(mate: HeroController, gap: float) -> int:
	for slot in range(3, 0, -1):
		var ab: Ability = mate.ability_in_slot(slot)
		if ab == null or mate.cooldown_left(slot) > 0.0:
			continue
		# A short-ranged ability thrown across the field whiffs and puts
		# itself on cooldown for nothing.
		if ab.shape != Ability.Shape.SELF and gap > ab.range_m:
			continue
		return slot
	# Slot 0 is the basic attack, which has no cooldown and always connects
	# at the range the stand-off already put them at.
	return 0


## The enemy a partner should go for, or null to regroup.
##
## LEASHED TO THE CHAMPION, not to the partner. A partner leashed to itself
## walks one enemy at a time across the whole map and is never where the
## player needs it; leashed to the champion it fights what the player has
## walked into and nothing else.
func _partner_target(mate: HeroController, leader: Vector2) -> HeroController:
	var best: HeroController = null
	var best_gap: float = INF
	for n in _enemy_nodes:
		var foe := n as HeroController
		if foe == null or foe.is_dead() or foe.body == null:
			continue
		var at: Vector2 = foe.ground_position()
		if at.distance_to(leader) > Party.LEASH:
			continue
		var gap: float = at.distance_to(mate.ground_position())
		if gap < best_gap:
			best_gap = gap
			best = foe
	return best


## Get the party back on its feet for a new wave.
##
## A PARTNER IS DOWN FOR THE WAVE, NOT THE RUN. Permanent death in a game
## whose premise is a collection of champions makes the correct play "never
## field the ones you like"; a partner who pops straight back up is not a
## cost at all. The wave boundary is the one line that is neither.
func _revive_party() -> void:
	for mate in _party:
		if mate == null or not is_instance_valid(mate) or mate.body == null:
			continue
		if not mate.is_dead():
			continue
		# Rebuilt rather than healed: a HeroController that has played its
		# death animation and started its corpse timer cannot be un-killed,
		# so the body is replaced and the node re-placed.
		var who: String = mate.rig.hero_name if mate.rig != null else ""
		if who.is_empty():
			continue
		var fresh: Combatant = Combat.champion_body(_account, who,
			champion_level, Rng.seed_of(world_seed, who), ChampionName.of(who))
		Party.weaken(fresh)
		mate.setup_combat(fresh, HeroClass.for_hero(who), who)
		# AND CLEAR THE DEATH LATCHES. setup_combat gives it a living body;
		# it does not un-kill the controller or the rig, so without this the
		# partner stands there at full health and does nothing at all.
		mate.revive()
		if _hero != null:
			mate._place(Party.station(int(mate.get_meta("partner_slot", 0)),
				_hero.ground_position(), _party_heading))


## How far from the champion this enemy wants to be.
##
## Melee wants to be on top of you. A ranger or a mage wants to be at most of
## the way out along whatever it can actually throw — computed from the kit it
## was given rather than per class, so a mage who rolled a short cone fights
## closer than one who rolled a long bolt, which is the whole reason the
## spellbook is rolled per champion.
func _stand_off(foe: HeroController, spawn: Encounter.Spawn) -> float:
	if HeroClass.school_of(spawn.cls) == HeroClass.School.MELEE:
		return REACH
	var longest: float = REACH
	for slot in range(1, 4):
		var ab: Ability = foe.ability_in_slot(slot)
		if ab != null and ab.shape != Ability.Shape.SELF:
			longest = maxf(longest, ab.range_m)
	return maxf(REACH, longest * STAND_FRACTION)


## Step away from the champion, staying on ground that exists.
##
## Returns false when this enemy is out of retreat and must stand and fight.
func _retreat(foe: HeroController, from: Vector2, want: float) -> bool:
	# Resting: it gave ground recently and has to hold for a beat.
	if _clock < float(foe.get_meta("hold_until", 0.0)):
		return false
	var spent: float = float(foe.get_meta("retreat_t", 0.0)) + THINK
	if spent >= RETREAT_BUDGET:
		# Out of room. Plant, and do not try again until the rest is over.
		foe.set_meta("retreat_t", 0.0)
		foe.set_meta("hold_until", _clock + RETREAT_REST)
		foe.stop()
		return false
	foe.set_meta("retreat_t", spent)

	if foe.is_moving():
		return true
	var away: Vector2 = (foe.ground_position() - from)
	if away.length_squared() < 0.01:
		away = Vector2(1, 0)
	var goal: Vector2 = from + away.normalized() * want
	# move_to pathfinds, so a retreat into a cliff simply does not happen —
	# it returns false, and the enemy fights where it stands.
	return foe.move_to(goal, RETREAT_RUN)


## Which of its actions this enemy uses, out of the ones the difficulty lets it.
##
## THE DIFFICULTY IS THE KIT, not just the numbers. Below Merciless an enemy is
## its basic attack and its signature ability; from Merciless it gains a
## second; only at Oblivion does it bring everything, which means the stun, the
## charge and the self-heal all arrive at once and the fight is a different
## shape rather than the same shape with more health.
##
## Within the allowance it prefers the strongest action that is off cooldown
## and actually in range — highest slot first, since slot order is roughly
## power order in every kit — and falls back to the basic, which has no
## cooldown and is therefore always available.
func _choose_action(foe: HeroController, gap: float) -> int:
	var allowed: int = Campaign.enemy_actions(tier)
	for slot in range(allowed - 1, 0, -1):
		var ab: Ability = foe.ability_in_slot(slot)
		if ab == null:
			continue
		if foe.cooldown_left(slot) > 0.0:
			continue
		# A ranged ability used point blank is fine; a short one used from
		# across the field whiffs and puts itself on cooldown for nothing.
		if ab.shape != Ability.Shape.SELF and gap > ab.range_m:
			continue
		return slot
	return 0


## Start a slam at where the champion is standing NOW.
##
## Aimed at the present position, not a predicted one: the whole point is that
## moving is the answer, and a telegraph that tracks you is not a telegraph.
func _begin_slam(boss: HeroController, at: Vector2) -> void:
	_slam_at = at
	_slam_radius = SLAM_RADIUS
	_slam_in = slam_warn(tier)
	_slam_damage = boss.body.attack_power() * SLAM_POWER
	_slam_cd = SLAM_COOLDOWN
	boss.stop()
	# The wind-up animation is the boss's heaviest ability, so the body reads
	# as doing something rather than standing still while the ground lights up.
	boss.use_ability(2, at)
	# The telegraph lasts exactly as long as the window, so what the player
	# sees and what the game counts are the same number.
	Vfx.telegraph(self, Vector3(at.x, boss.position.y + 0.05, at.y),
		_slam_radius, _slam_in)


## Run the wind-up down, and resolve it where it was aimed.
func _advance_slam(delta: float) -> void:
	_slam_cd = maxf(_slam_cd - delta, 0.0)
	if _slam_at == Vector2.INF:
		return
	_slam_in -= delta
	if _slam_in > 0.0:
		return
	var at: Vector2 = _slam_at
	_slam_at = Vector2.INF
	if _hero == null or _hero.body == null or _hero.is_dead():
		return
	# INSIDE OR OUTSIDE, nothing in between. A falloff would make "did I dodge
	# that" a question the player cannot answer from the picture they were
	# given, and the picture is the mechanic.
	if _hero.ground_position().distance_to(at) > _slam_radius:
		_hud.set_message("Dodged.")
		return
	_hero.body.take_hit(minf(_slam_damage,
		_hero.body.max_health * SLAM_MAX_FRACTION), "Slam")


## An enemy's swing lands. Same resolution path as the champion's, with the
## champion as the only possible target — without this enemies would animate
## attacks that never did anything, which looks exactly like a broken game.
func _on_enemy_cast(ability: Ability, foe: HeroController) -> void:
	if foe == null or foe.body == null or _hero == null or _hero.body == null:
		return
	var ctx := Combat.Context.new()
	ctx.caster = foe.body
	ctx.origin = foe.ground_position()
	ctx.facing = foe.rotation.y
	# THE TARGET IT WOUND UP ON, not whoever is nearest now. _think stamps
	# "mark" before the cast; a cast with no mark — the auto-attack path, or a
	# partner who died mid-animation — falls back to the champion.
	var mark := foe.get_meta("mark", null) as HeroController
	if mark == null or not is_instance_valid(mark) or mark.is_dead() \
			or mark.body == null:
		mark = _hero
	var targets: Array[Combatant] = [mark.body]
	ctx.targets = targets
	ctx.positions = PackedVector2Array([mark.ground_position()])
	var r: Combat.Result = Combat.cast(ability, ctx)
	Elite.on_hit(int(foe.get_meta("trait", Elite.Trait.NONE)),
		foe.body, mark.body)
	_show_cast(ability, foe, mark.ground_position())
	_show_impacts(r, ability, foe)


## Flash every body this cast actually connected with.
##
## EVERY EFFECT IN THIS GAME PLAYED AT THE CASTER. From the player's side that
## meant the biggest spell they own was a light show around their own feet
## while the thing they were trying to kill registered nothing at all — the
## link between pressing the button and hurting something was never drawn.
##
## Driven off the Result rather than the targets the context was handed: the
## context holds everyone who COULD have been hit, and lighting up an enemy
## the cone missed teaches the player their aim was fine when it was not.
func _show_impacts(r: Combat.Result, ability: Ability,
		caster: HeroController) -> void:
	if r == null or r.hit.is_empty() or caster == null or caster.rig == null:
		return
	var sig: Dictionary = Vfx.signature(caster.rig.hero_name,
		HeroClass.for_hero(caster.rig.hero_name))
	if ability.element >= 0:
		sig = Vfx._elemental(sig, ability.element)
	var tint: Color = sig["secondary"]
	# A crit on any target makes that target's flash the bigger one; the rest
	# get the ordinary hit. Result only counts crits, so the first `crits`
	# bodies wear them — good enough for a quarter-second flash and far
	# cheaper than threading per-target detail through the combat layer.
	var crits_left: int = r.crits
	for body in r.hit:
		var at: Vector3 = _body_position(body)
		if at == Vector3.INF:
			continue
		Vfx.impact(self, at, tint, crits_left > 0)
		crits_left -= 1


## Where a combatant is standing, or INF if its body has already gone.
func _body_position(body: Combatant) -> Vector3:
	if _hero != null and body == _hero.body:
		return _hero.global_position
	for i in range(_enemies.size()):
		if _enemies[i] == body:
			var n: Node3D = _enemy_nodes[i]
			if n != null and is_instance_valid(n):
				return n.global_position
			return Vector3.INF
	return Vector3.INF


## Draw the ability.
##
## ONE PLACE FOR BOTH SIDES. An effect the champion gets and the enemies do not
## tells the player, wrongly, that the enemy attack was a miss — so the player's
## cast and the enemy's cast come through the same call, and the only thing
## that differs is whose signature Vfx reads.
func _show_cast(ability: Ability, caster: HeroController,
		target: Vector2) -> void:
	if caster == null or ability == null or caster.rig == null:
		return
	var who: String = caster.rig.hero_name
	if who == "":
		return
	Vfx.play(self, ability, who, HeroClass.for_hero(who),
		caster.ground_position(), caster.rotation.y,
		target if target != Vector2.INF else caster.ground_position(),
		caster.position.y)


# ------------------------------------------------------------------------------
# Enemies
# ------------------------------------------------------------------------------

## Register something hostile: its combat body and the node it is drawn at.
##
## THE FOURTH LISTENER ON `died`, and the one that pays out. The other three are
## each attached from the only place that can know what they need: Audio hooks
## Combatant.on_spawn, because a death cue needs nothing but the combatant;
## HeroController connects its own champion's body, because a corpse has to stop
## taking orders; and Hud.track_enemy is handed the node at registration,
## because a health bar needs to know where the thing is. A DROP needs the same
## thing a health bar does — a position — so it is wired from the same place,
## which is here, the one door every enemy in the region comes through.
func add_enemy(body: Combatant, node: Node3D) -> int:
	if body == null or node == null:
		return -1
	var id: int = _next_enemy_id
	_next_enemy_id += 1
	_enemies.append(body)
	_enemy_nodes.append(node)
	_enemy_ids.append(id)
	# A bound method rather than a lambda: a lambda that captured the body would
	# be held BY the body's own signal, which is the reference cycle Hud.gd had
	# to unpick by hand. `self` is a Node and outlives every enemy in it.
	body.died.connect(_on_enemy_died.bind(id))
	_hud.track_enemy(body, node)
	return id


## Roll and drop what an enemy was carrying, where it fell.
##
## Reading the position at the moment of death is the whole reason this is wired
## here: a corpse may be despawned at any time (HeroController.CORPSE_LINGER is
## a suggestion, not a rule), and loot that spawned at the origin because the
## node had already gone is a bug the player sees as "my kill dropped nothing".
func _on_enemy_died(id: int) -> void:
	var i: int = _enemy_index(id)
	if i < 0:
		return
	_kills += 1
	# Counted on DEATH, from the flag stamped at spawn. Counting at spawn
	# would credit a quest for elites the player walked past.
	var corpse: Node = _enemy_nodes[i] if i < _enemy_nodes.size() else null
	if corpse != null and bool(corpse.get_meta("is_elite", false)):
		_elites_killed += 1
	_award_xp()
	var node: Node3D = _enemy_nodes[i]
	if node != null and is_instance_valid(node):
		_loot.on_kill(_enemies[i], node.global_position)
	if id == _boss_id:
		_boss_id = -1
		_clear_region()


## Pay the champion for a kill.
##
## NOTHING DID THIS. HeroProgress.gain_xp() and Campaign.xp_per_kill() were
## both written and both called only by tests, so a champion could clear a
## region, a difficulty, the whole campaign, and still be level 1. Every system
## downstream — skill points, the merchant's stock level, enemy scaling, the
## gear the stash will let you wear — reads that level, so none of them had
## ever moved either.
##
## The live body is levelled too, not just the save. A level that only appears
## after you walk back to the menu is a level the player does not connect to
## the kill that earned it.
## Pay the partners for a kill they were present for.
##
## THEY HAVE TO LEVEL. Without this the only correct party is the three
## champions who are already highest, and a feature meant to make a 139-hero
## roster worth owning would instead make three heroes matter and 136 not.
## Less than the champion earns (Party.XP_SHARE), because the player is the
## one playing.
##
## A PARTNER WHO IS DOWN EARNS NOTHING, which is the only cost of letting one
## die — and the reason positioning is worth anything.
##
## The live body is NOT re-derived at the new level, unlike the champion's. A
## partner's numbers are visible only through how fast things die next to the
## player, so a mid-fight stat refresh would be invisible, and the next run
## builds them from the save anyway.
func _award_party_xp() -> void:
	if _party.is_empty() or _account == null:
		return
	var share: float = Campaign.xp_per_kill(region_index, tier) \
		* Party.XP_SHARE
	if share <= 0.0:
		return
	for mate in _party:
		if mate == null or not is_instance_valid(mate) or mate.is_dead():
			continue
		if mate.rig == null:
			continue
		var p: HeroProgress = _account.progress(mate.rig.hero_name)
		if p == null:
			continue
		if p.gain_xp(share) > 0:
			_hud.set_message("%s reaches level %d."
				% [ChampionName.of(mate.rig.hero_name), p.level])


func _award_xp() -> void:
	_award_party_xp()
	if _hero == null or _hero.rig == null:
		return
	var who: String = _hero.rig.hero_name
	var p: HeroProgress = _account.progress(who)
	if p == null:
		return
	var before: int = p.level
	var gained: int = p.gain_xp(Campaign.xp_per_kill(region_index, tier))
	if gained <= 0:
		return
	_hud.set_message("%s reaches level %d." % [ChampionName.of(who), p.level])
	Audio.play(Audio.Cue.CAST, 1.9)
	# Re-derive the body at the new level, keeping the damage already taken:
	# a level-up that healed you to full would make levelling mid-fight the
	# strongest move in the game.
	var hurt: float = _hero.body.max_health - _hero.body.health
	var fresh: Combatant = Combat.champion_body(_account, who, p.level,
		Rng.seed_of(world_seed, who), ChampionName.of(who))
	_hero.body.level = fresh.level
	_hero.body.stats = fresh.stats
	_hero.body.max_health = fresh.max_health
	_hero.body.health = maxf(fresh.max_health - hurt, 1.0)
	_hero.body.weapon_power = fresh.weapon_power
	_hero.body.armour = fresh.armour
	_loot.champion_level = p.level
	print("%s: level %d -> %d" % [who, before, p.level])


## THE BOSS IS DOWN. Bank the clear and tell whoever launched this scene.
##
## Roster.record_map_cleared() — which counts the map, fires
## difficulty_completed and pays the one-time spawn crystal for finishing a
## whole difficulty — was written, unit-tested in rewardtest.gd, and called by
## NOTHING but that test. A player could clear all hundred maps of Normal and
## the save would still say they had cleared none, because the only thing that
## could have said otherwise was never asked.
func _clear_region() -> void:
	# A MULTI-WAVE MODE IS NOT OVER. The campaign ends when its boss falls;
	# a descent or a gauntlet treats that as one wave down and sends the
	# next, in the same arena, without a loading screen.
	if mode != GameMode.Id.CAMPAIGN and not GameMode.is_final_wave(mode, _wave):
		_next_wave()
		return
	if mode != GameMode.Id.CAMPAIGN:
		_finish_run()
		return
	var crystals: int = _account.record_map_cleared(tier, region_index)
	_account.save()

	var summary: Dictionary = {
		"region": region_index,
		"tier": tier,
		"hero": _hero.rig.hero_name if _hero != null and _hero.rig != null
			else hero,
		"kills": _kills,
		"gold": _account.wallet.balance(Wallet.Kind.GOLD)
			- int(_snapshot.get("gold", 0)),
		"items": _account.stash.items.size()
			- int(_snapshot.get("items", 0)),
		"levels": (_hero.body.level if _hero != null and _hero.body != null
			else 1) - int(_snapshot.get("level", 1)),
		"crystals": crystals,
		"cleared": _account.cleared_map_count(tier),
		"total": Campaign.map_count(),
		# ---- what the quest board reads ----
		# Flattened into the summary rather than passed as nested maps, so
		# the one signal Play already emits carries everything and no new
		# integration point is needed. Quest.note_run() reads these keys.
		"cleared_this_run": true,
		"elites_killed": _elites_killed,
		"depth_reached": 0,
		# There is always a next map unless this was the hundredth.
		"next": region_index + 1 if region_index + 1 < Campaign.map_count()
			else -1,
	}
	_merge_drop_keys(summary)
	_apply_quests(summary)
	_hud.set_message("%s has fallen." % Campaign.region_title(region_index))
	region_cleared.emit(summary)


## Send the next wave into the arena that is already standing.
func _next_wave() -> void:
	if _terrain == null or _hero == null:
		return
	_wave += 1
	_boss_id = -1
	# A new wave is a new set of packs. Without this, pack ids from the last
	# wave stay marked awake and the newcomers all charge from the moment
	# they appear.
	_awake.clear()
	_slam_at = Vector2.INF
	_slam_cd = 0.0
	# Partners get up between waves. See _revive_party.
	_revive_party()

	var here: Vector2 = _hero.ground_position()
	_populate(_terrain, _plan, here, _player_hero, _wave)
	_hud.set_message("%s" % GameMode.wave_label(mode, _wave))
	# Banked every wave, not at the end: a descent ends in death, and a run
	# whose record is only written on a clean exit records nothing.
	_bank_record()


## The run is over, win or lose. Report it the same way a cleared map does so
## the clear screen needs no mode-specific branch.
func _finish_run() -> void:
	_bank_record()
	_account.save()
	var summary: Dictionary = {
		"region": region_index,
		"tier": tier,
		"mode": mode,
		"mode_name": GameMode.name_of(mode),
		"wave": _wave + 1,
		"hero": _hero.rig.hero_name if _hero != null and _hero.rig != null
			else hero,
		"kills": _kills,
		"gold": _account.wallet.balance(Wallet.Kind.GOLD)
			- int(_snapshot.get("gold", 0)),
		"items": _account.stash.items.size()
			- int(_snapshot.get("items", 0)),
		"levels": (_hero.body.level if _hero != null and _hero.body != null
			else 1) - int(_snapshot.get("level", 1)),
		"crystals": 0,
		"cleared": _wave + 1,
		"total": GameMode.wave_count(mode),
		"cleared_this_run": false,
		"elites_killed": _elites_killed,
		# A descent's depth is the quest-visible number; other modes report 0
		# so a REACH_DEPTH quest is not satisfied by a gauntlet.
		"depth_reached": (_wave + 1) if mode == GameMode.Id.DESCENT else 0,
		# Nothing to advance to: a mode run is its own thing.
		"next": -1,
	}
	_merge_drop_keys(summary)
	_apply_quests(summary)
	_hud.set_message("%s complete." % GameMode.name_of(mode))
	region_cleared.emit(summary)


## Record how far this run got, if it is the furthest yet.
func _bank_record() -> void:
	var key: String = GameMode.record_key(mode)
	if key.is_empty() or _account == null:
		return
	# Through Roster so it lands in the SAVE. Metadata on a RefCounted is not
	# serialised, so a record kept there would be lost on the next launch —
	# which for a mode whose only reward is the number is the whole feature.
	if _account.note_mode_run(key, _wave + 1):
		_account.save()


## How many pieces of AT LEAST this rarity were collected this run.
##
## "At least" rather than "exactly", because a quest for Rare gear is
## satisfied by an Epic — a player who brings back something better and is
## told it does not count has been punished for good luck.
func _drops_at_least(rarity: int) -> int:
	var n: int = 0
	for r in _drops_by_rarity.keys():
		if int(r) >= rarity:
			n += int(_drops_by_rarity[r])
	return n


## Write the per-slot and per-rarity drop counts into [summary].
##
## WRITTEN IN ONE PLACE because there are two run endings — the campaign clear
## and the mode run — and the first version of this spelled the keys out
## inline in one of them only. A quest for boots was then completable from the
## campaign and silently impossible from a gauntlet, which is not a bug a
## player can report in any useful way: it just looks like bad luck.
func _merge_drop_keys(summary: Dictionary) -> void:
	for s in range(Item.Slot.size()):
		summary["drops_slot_%d" % s] = int(_drops_by_slot.get(s, 0))
	for r in range(Item.RARITY_NAMES.size()):
		summary["drops_at_least_%d" % r] = _drops_at_least(r)


## Let the quest board read the finished run, and report back what it finished.
##
## Done HERE, where the only complete picture of the run exists, rather than in
## the shell: the shell sees the summary, but a quest advanced after the clear
## screen has already been built cannot be shown on it.
func _apply_quests(summary: Dictionary) -> void:
	if _account == null:
		return
	var finished: PackedStringArray = _account.note_quest_run(summary)
	summary["quests_done"] = finished
	if not finished.is_empty():
		_account.save()


func _enemy_index(id: int) -> int:
	for i in range(_enemy_ids.size()):
		if _enemy_ids[i] == id:
			return i
	return -1


## Loot has landed in the account. Reported on the HUD line, because an invisible
## reward is not a reward, and the cast cue pitched up stands in for a chime —
## this project synthesises its five cues (Audio.gd) and does not ship a sixth.
func _on_loot_collected(text: String, drop: Loot.Drop) -> void:
	if text != "":
		_hud.set_message(text)
	# COLLECTED, not dropped: "bring back" means it is in the stash, and a
	# piece left glowing on the ground when the player walks out is not.
	if drop.has_item():
		var r: int = drop.item.rarity
		_drops_by_rarity[r] = int(_drops_by_rarity.get(r, 0)) + 1
		var sl: int = drop.item.slot
		_drops_by_slot[sl] = int(_drops_by_slot.get(sl, 0)) + 1
	Audio.play(Audio.Cue.CAST, 1.7)
	_unsaved = true
	# A rare-or-better piece is written out immediately. Everything else waits
	# for the way out of the region (`_exit_tree`), because stringifying a
	# 300-item stash on every common drop is a hitch in the middle of a fight —
	# but losing a legendary to a force-quit is the thing a player never forgives.
	if drop.has_item() and drop.item.rarity >= Item.Rarity.RARE:
		_flush_account()


## Write the account out, if this region has anything to write and a real
## account to write it to. Roster.save() is the single file and the single door
## to it (Roster.gd); what this adds is a reason to walk through it, which the
## menus cannot supply because loot is earned while they are not on screen.
func _flush_account() -> void:
	if not _unsaved or _account == null or _account != roster:
		return
	_unsaved = false
	_account.save()


func _exit_tree() -> void:
	_flush_account()


## Live enemies and their ground positions, as Combat wants them. Dead and freed
## entries are dropped here rather than on a timer, so one pass does both.
func _enemy_context() -> Dictionary:
	var bodies: Array[Combatant] = []
	var points := PackedVector2Array()
	for i in range(_enemies.size() - 1, -1, -1):
		var node: Node3D = _enemy_nodes[i]
		if node == null or not is_instance_valid(node):
			_enemies.remove_at(i)
			_enemy_nodes.remove_at(i)
			_enemy_ids.remove_at(i)
			continue
		if not _enemies[i].alive:
			continue
		bodies.append(_enemies[i])
		points.append(Vector2(node.global_position.x, node.global_position.z))
	return {"bodies": bodies, "points": points}


## Resolve a cast at the moment it LANDS, which is the end of the animation —
## see HeroController.cast_landed. Pressing the key only starts the swing.
func _on_cast_landed(ability: Ability) -> void:
	_on_ally_cast(ability, _hero)


## A CAST BY ANYONE ON THE PLAYER'S SIDE lands on the enemies.
##
## This was written for the champion alone and PARTNERS WERE NEVER CONNECTED
## TO IT. A partner chose an ability, played the animation, cleared its
## pending cast and emitted cast_landed into nothing — so for the whole life
## of the feature a partner did exactly zero damage. Nothing errored, nothing
## logged, and partytest passed because it asserted that `ability_used` was
## EMITTED rather than that anything was hurt. Signals are not effects.
##
## Generalised rather than copied, so there is one resolver for the player's
## side and a third ally cannot be added without going through it.
func _on_ally_cast(ability: Ability, who: HeroController) -> void:
	if who == null or not is_instance_valid(who) or who.body == null:
		return
	var env: Dictionary = _enemy_context()
	var ctx := Combat.Context.new()
	ctx.caster = who.body
	ctx.origin = who.ground_position()
	ctx.facing = who.rotation.y
	ctx.targets = env["bodies"]
	ctx.positions = env["points"]
	var r: Combat.Result = Combat.cast(ability, ctx)
	# The champion aims at whatever it can reach; a partner already chose a
	# target and stamped it, so the effect plays toward the thing it swung at
	# rather than toward the champion's pick.
	var at: Vector2 = _aim_point() if who == _hero \
		else who.get_meta("aim", _aim_point())
	_show_cast(ability, who, at)
	_show_impacts(r, ability, who)


## The nearest living enemy's ground position, or Vector2.INF. Used to turn the
## champion toward what it is about to hit: on a phone the player has no way to
## aim, so pressing an ability has to mean "hit that one".
func _aim_point(ability: Ability = null) -> Vector2:
	if _hero == null or _hero.body == null:
		return Vector2.INF
	var env: Dictionary = _enemy_context()
	var bodies: Array[Combatant] = env["bodies"]
	var points: PackedVector2Array = env["points"]
	var here: Vector2 = _hero.ground_position()

	# AIMED AT SOMETHING IT CAN ACTUALLY HIT. Picking the globally nearest
	# enemy and turning to face it is not auto-target if that enemy is twelve
	# metres away and the ability reaches three — Combat.cast then finds
	# nothing inside the cone and the press is spent on empty ground, which
	# reads as the button being broken.
	if ability != null and ability.range_m > 0.0:
		var best: Vector2 = Vector2.INF
		var best_d: float = INF
		for i in range(bodies.size()):
			if bodies[i] == null or not bodies[i].alive:
				continue
			if bodies[i].team == _hero.body.team:
				continue
			var d: float = here.distance_to(points[i])
			if d <= ability.range_m and d < best_d:
				best_d = d
				best = points[i]
		if best != Vector2.INF:
			return best
		# Nothing in reach: fall through and still turn toward the nearest, so
		# the champion faces the fight rather than casting over its shoulder.

	var target: Combatant = Combat.nearest_enemy(here, _hero.body.team,
		bodies, points)
	if target == null:
		return Vector2.INF
	return points[bodies.find(target)]


# ------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------

## Releases only, and deliberately BEFORE the GUI gets a look in.
##
## A finger that starts a walk on open ground and then lifts over an ability key
## has its release consumed by that key, so `_unhandled_input` never sees it and
## `_holding` stays true for the rest of the region — the champion keeps
## re-pathing to wherever the finger last was. The press still goes through the
## normal route, which is what lets the keys steal it; it is only the end of the
## gesture that has to be unconditional.
##
## Nothing is consumed here. This is an observer, not a handler.
func _input(e: InputEvent) -> void:
	# A tap during the sweep means "I have seen this". Consumed, so the same
	# tap does not also order a move the instant control returns.
	if _flying:
		var tapped: bool = (e is InputEventScreenTouch
			and (e as InputEventScreenTouch).pressed) \
			or (e is InputEventMouseButton
				and (e as InputEventMouseButton).pressed)
		if tapped:
			_cam.skip_flyover()
			get_viewport().set_input_as_handled()
		return
	if not _holding:
		return
	if e is InputEventScreenTouch:
		var t := e as InputEventScreenTouch
		if not t.pressed and t.index == _hold_index:
			_release()
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_release()


func _unhandled_input(e: InputEvent) -> void:
	if _hero == null:
		return

	# THE STICK GETS FIRST REFUSAL. It runs in _input and consumes what it
	# claims, so a press that becomes a stick never reaches here — but the
	# zone test is repeated because iOS synthesises a mouse event from every
	# touch and a synthesised event takes its own path through the stack.
	if _stick != null and e is InputEventScreenTouch \
		and (e as InputEventScreenTouch).pressed \
		and _stick.claims((e as InputEventScreenTouch).position):
		return

	if _track_pinch(e):
		return

	if e is InputEventScreenTouch or e is InputEventMouseButton:
		if e is InputEventMouseButton:
			var mb := e as InputEventMouseButton
			# iOS synthesises a click from every touch, so one tap arrives twice.
			# Both would path to the same place, but the duplicate costs a whole
			# A* search on a 300-cell grid for nothing.
			if mb.button_index != MOUSE_BUTTON_LEFT \
					or mb.device == InputEvent.DEVICE_ID_EMULATION:
				return
		if not e.pressed:
			_release()
			return
		# THE SECOND GUARD. The keys consume their own presses, so in practice
		# this never fires — but iOS synthesises a mouse event from every touch,
		# and a synthesised event is a second event with its own path through the
		# input stack. A geometric test cannot be bypassed by one.
		if _hud != null and _hud.blocks_point(e.position):
			return
		_holding = true
		_hold_index = (e as InputEventScreenTouch).index \
			if e is InputEventScreenTouch else -1
		_hold_at = e.position
		_order_move(e.position)
	elif e is InputEventScreenDrag or e is InputEventMouseMotion:
		if _holding:
			_hold_at = e.position
	elif e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_1: _use(0)
			KEY_2: _use(1)
			KEY_3: _use(2)
			KEY_4: _use(3)
			KEY_ESCAPE: get_tree().quit()


## Track the fingers nobody else claimed and turn two of them into zoom.
##
## Returns true when the event was a pinch and must not also be read as a tap.
## A two-finger gesture that also issued a move order would have the champion
## sprint off every time the player adjusted the camera.
func _track_pinch(e: InputEvent) -> bool:
	if e is InputEventScreenTouch:
		var t2 := e as InputEventScreenTouch
		var claimed: bool = (_stick != null and _stick.is_active() \
			and not _free_touches.has(t2.index) and _stick.claims(t2.position)) \
			or (_hud != null and _hud.blocks_point(t2.position))
		if t2.pressed:
			if not claimed:
				_free_touches[t2.index] = t2.position
		else:
			_free_touches.erase(t2.index)
		# Releasing a finger ends the gesture; the next pair starts fresh rather
		# than measuring against a span from two fingers ago and snapping.
		if _free_touches.size() < 2:
			_pinch_prev = -1.0
		return false

	if e is InputEventScreenDrag:
		var d := e as InputEventScreenDrag
		if not _free_touches.has(d.index):
			return false
		_free_touches[d.index] = d.position
		if _free_touches.size() < 2:
			return false
		var pts: Array = _free_touches.values()
		var span: float = (pts[0] as Vector2).distance_to(pts[1] as Vector2)
		if span < 1.0:
			return true
		if _pinch_prev > 0.0 and _cam != null:
			# Fingers apart = zoom IN (the world grows), which is the gesture
			# every photo viewer has taught; distance grows, so the camera
			# distance must shrink.
			_cam.pinch(_pinch_prev / span)
		_pinch_prev = span
		return true

	return false


## The stick moved. Screen space in, world space out.
##
## ROTATED BY THE CAMERA'S YAW, not used raw. ArpgCamera holds a fixed 35-degree
## yaw and deliberately never turns, so screen-up is not world-north; feeding
## the raw vector to drive() sends the champion off at an angle to the thumb,
## which feels like drift and is the single most common bug in a stick like
## this. Screen -y (up) must become "away from the camera".
func _on_stick(dir: Vector2) -> void:
	if _hero == null or _hero.is_dead():
		return
	if dir == Vector2.ZERO:
		_hero.drive(Vector2.ZERO)
		return
	_hero.drive(ArpgCamera.stick_to_world(dir), _stick.wants_run())


func _release() -> void:
	_holding = false
	_hold_index = -1


func _on_hud_action(slot: int) -> void:
	_use(slot)


## The roll key. ROLLS THE WAY THE STICK IS POINTING, falling back to the way the
## champion faces when it is released — a roll that always went forwards would be
## useless for backing out of something, which is most of what it is for.
##
## The direction is converted through ArpgCamera.stick_to_world for the same
## reason _on_stick does: the stick is in SCREEN space and the world is rotated
## under the camera, so a raw screen vector rolls somewhere other than where the
## thumb pointed.
func _on_hud_dodge() -> void:
	if _hero == null or _hero.is_dead():
		return
	var dir: Vector2 = Vector2.ZERO
	if _stick != null and _stick.is_active():
		var raw: Vector2 = _stick.direction()
		if raw != Vector2.ZERO:
			dir = ArpgCamera.stick_to_world(raw)
	_hero.dodge(dir)


## The one door every action goes through, whether it came from a thumb or a
## number key, so the two can never drift apart.
func _use(slot: int) -> void:
	if _hero == null:
		return
	_hero.use_ability(slot, _aim_point(_hero.ability_in_slot(slot)))


func _process(d: float) -> void:
	if _flying:
		# Nothing else runs during the sweep: no auto-attack, no brain, no
		# held-finger move orders. The enemies are not yet the player's
		# problem and the champion must still be standing where the sweep
		# ends when it hands over.
		return

	# Held finger: keep re-issuing toward where it is now, so dragging steers
	# rather than requiring a tap per step. Re-pathing every frame would be
	# wasteful, so only when the target has moved meaningfully.
	if _holding and _hero != null and not _hero.is_busy():
		if not _hero.is_moving():
			_order_move(_hold_at)
	_clock += d
	_auto_attack()
	_think(d)
	_advance_slam(d)


## Swing at whatever is standing next to you, without being told.
##
## A phone ARPG cannot ask the player to tap an attack button once per swing
## while also steering with the other thumb. The basic attack has no cooldown
## and no cost, so there is never a reason NOT to be using it on something in
## reach — holding it back is busywork, not a decision. The three abilities
## stay manual, because those are the decisions.
##
## Deliberately does nothing while the champion is MOVING: walking past an
## enemy should not stop you dead to trade a hit, and a player dragging the
## stick is telling you where they want to be.
func _auto_attack() -> void:
	if _hero == null or _hero.body == null or _hero.is_dead():
		return
	if _hero.is_busy() or _hero.is_moving() or _hero.is_stunned():
		return
	if _stick != null and _stick.is_active():
		return
	var basic: Ability = _hero.ability_in_slot(0)
	if basic == null:
		return
	var at: Vector2 = _aim_point(basic)
	if at == Vector2.INF:
		return
	if _hero.ground_position().distance_to(at) > basic.range_m:
		return
	_hero.use_ability(0, at)


func _order_move(screen: Vector2) -> void:
	# Checked here as well as on the press, because a drag that wanders over the
	# pad would otherwise keep issuing orders from under the player's thumb.
	if _hud != null and _hud.blocks_point(screen):
		return
	var g: Vector2 = _cam.screen_to_ground(screen)
	if g == Vector2.INF:
		return
	_hero.move_to(g, true)
