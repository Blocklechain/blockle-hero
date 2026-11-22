extends SceneTree
# ------------------------------------------------------------------------------
# 139 champions as enemies, and they all fought identically.
#
# Every one of them walked into melee range and swung, which made a Ranger, a
# Mage and a Fighter the same encounter wearing different models — across a
# roster this size that was the single biggest thing the game was throwing
# away. And each woke up alone, so a pack of five was fought as five duels at
# the edge of aggro range: safe, slow, and nothing like the fight the
# encounter builder laid out.
#
#   godot --headless --path . --script tools/tactictest.gd
# ------------------------------------------------------------------------------

const REGION: int = 37

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	var account: Roster = Roster.create(HeroRig.animated_heroes())
	var who: String = String(account.owned.keys()[0])
	var play: Node = load("res://scenes/Play.tscn").instantiate()
	play.set("world_seed", Campaign.region_seed(4242, REGION))
	play.set("biome", Biome.tag(Campaign.biome_at(REGION),
		Campaign.dread(REGION)))
	play.set("hero", who)
	play.set("region_index", REGION)
	play.set("campaign_seed", 4242)
	play.set("tier", Campaign.Tier.OBLIVION)
	play.set("region_cells", 96)
	play.roster = account
	get_root().add_child(play)

	var frames: int = 0
	while frames < 2400 and play.get("_hero") == null:
		await process_frame
		frames += 1
	var me: HeroController = play.get("_hero")
	check("the region came up", me != null)
	if me == null:
		_done()
		return
	if bool(play.get("_flying")):
		play._cam.skip_flyover()
		await process_frame

	print("\n=== each fights like what it is ===")
	var melee: Array = []
	var ranged: Array = []
	for n in play.get_children():
		if not (n is HeroController) or n == me:
			continue
		var f := n as HeroController
		if f.rig == null:
			continue
		var school: int = HeroClass.school_of(
			HeroClass.for_hero(f.rig.hero_name))
		if school == HeroClass.School.MELEE:
			melee.append(f)
		else:
			ranged.append(f)

	check("the map has both kinds on it", not melee.is_empty()
		and not ranged.is_empty(),
		"%d melee, %d ranged" % [melee.size(), ranged.size()])
	if melee.is_empty() or ranged.is_empty():
		_done()
		return

	var m_stand: float = float(melee[0].get_meta("stand_off", -1.0))
	var r_stand: float = float(ranged[0].get_meta("stand_off", -1.0))
	check("melee wants to be on top of you", m_stand <= play.REACH + 0.01,
		"%.1f m" % m_stand)
	check("...and ranged wants to be a long way off", r_stand > play.REACH * 2.0,
		"%.1f m" % r_stand)

	# A ranged enemy standing on the player's toes must BACK AWAY, not trade.
	var r: HeroController = ranged[0]
	r.set_meta("pack", -2)
	play._awake[-2] = true
	r._place(me.ground_position() + Vector2(1.0, 0.0))
	var start_gap: float = r.ground_position().distance_to(
		me.ground_position())
	for i in range(240):
		await process_frame
	var end_gap: float = r.ground_position().distance_to(
		me.ground_position())
	check("a ranged enemy backs off when you close on it",
		end_gap > start_gap + 1.0, "%.1f m -> %.1f m" % [start_gap, end_gap])

	print("\n=== and a melee champion can still catch one ===")
	# THE WHOLE POINT. A ranged enemy that backs away at the speed the
	# champion chases is unkillable by any class without ranged abilities —
	# which is two of the three. It retreated by RUNNING, at exactly
	# RUN_SPEED, so the gap closed at 0 m/s forever.
	check("retreating is a walk, not a run", not play.RETREAT_RUN,
		"walk %.1f vs chase %.1f m/s" % [HeroController.WALK_SPEED,
			HeroController.RUN_SPEED])
	check("...so the champion gains ground on it",
		HeroController.RUN_SPEED > HeroController.WALK_SPEED,
		"%.1f m/s of closing speed" % [HeroController.RUN_SPEED
			- HeroController.WALK_SPEED])

	# Even Swift, the fastest an elite gets, must not outrun the chase.
	var swift: float = HeroController.WALK_SPEED * (1.0 + Elite.SWIFT_HASTE)
	check("...even against a Swift elite",
		swift < HeroController.RUN_SPEED,
		"swift retreat %.1f m/s vs chase %.1f" % [swift,
			HeroController.RUN_SPEED])

	# AND IT CANNOT BACK AWAY FOREVER. Driven directly rather than through a
	# chase: whether the champion pursues depends on which one the save
	# happens to own, and a ranged champion correctly stands and shoots
	# instead — so a chase loop here would be measuring the hero's class, not
	# the archer's budget.
	var kiter: HeroController = ranged[0]

	# STAND IT SOMEWHERE WITH ROOM BEHIND IT.
	#
	# _retreat() ends in move_to(), so it returns false when the pathfinder
	# cannot reach the goal — which means a boulder behind the archer reads
	# here as "it ran out of budget". That is the same contamination the
	# comment above avoids by driving _retreat directly instead of through a
	# chase: this measures a TIME budget, and whatever scenery the generator
	# happened to put at its feet is not the subject.
	#
	# It started mattering when map forms began dressing differently — a
	# hollow boosts landmarks, and in this harness's deliberately tiny 96-cell
	# region a couple of obelisks are enough to box an archer in. The real
	# 352-cell hollow has ample room; the test region does not.
	var terrain: Terrain = play.get("_terrain")
	if terrain != null:
		var path := Pathing.new(terrain)
		var here: Vector2 = me.ground_position()
		for step in range(24):
			var ang: float = TAU * float(step) / 24.0
			var dir := Vector2(cos(ang), sin(ang))
			var stand: Vector2 = here + dir * 4.0
			# Room for the whole 8m retreat the budget test asks for, plus a
			# margin so the last step is not a coin flip.
			var goal: Vector2 = here + dir * 13.0
			if path.is_walkable(stand) and path.is_walkable(goal) \
					and path.clear_line(stand, goal):
				kiter._place(stand)
				break

	kiter.set_meta("retreat_t", 0.0)
	kiter.set_meta("hold_until", 0.0)
	var gave_way: int = 0
	var planted: bool = false
	for i in range(12):
		if play._retreat(kiter, me.ground_position(), 8.0):
			gave_way += 1
		else:
			planted = true
			break
	check("...and it runs out of ground and plants", planted,
		"gave way %d times, then held" % gave_way)
	check("...for about the budget, not forever",
		gave_way >= 3 and gave_way <= 8,
		"%.1fs of budget at %.2fs a think" % [play.RETREAT_BUDGET,
			play.THINK])
	# Having planted, it must stay planted for the rest — otherwise it
	# alternates step-back/step-back and the chase never ends.
	check("...and holds rather than immediately giving way again",
		not play._retreat(kiter, me.ground_position(), 8.0))

	print("\n=== a pack wakes together ===")
	var packs: Dictionary = {}
	for n in play.get_children():
		if n is HeroController and n != me:
			var pk: int = int(n.get_meta("pack", -1))
			if pk >= 0:
				packs[pk] = true
	check("the enemies know which pack they are in", packs.size() > 0,
		"%d packs" % packs.size())
	check("...and waking is tracked per pack, not per enemy",
		play.get("_awake") != null)

	print("\n=== elites are worth noticing ===")
	var elites: Array = []
	for n in play.get_children():
		if n is HeroController and n != me \
				and int(n.get_meta("trait", Elite.Trait.NONE)) \
					!= Elite.Trait.NONE:
			elites.append(n)
	check("the map has elites on it", not elites.is_empty(),
		"%d of %d" % [elites.size(), melee.size() + ranged.size()])
	if not elites.is_empty():
		var e: HeroController = elites[0]
		var tr: int = int(e.get_meta("trait"))
		check("...each with exactly one named trait",
			Elite.name_of(tr) != "", Elite.name_of(tr))
		check("...wearing its colour so you can see it coming",
			e.get_node_or_null("EliteMark") != null)
		# The trait has to DO something, through the systems that already
		# exist rather than as a special case in the combat loop.
		var does: bool = false
		match tr:
			Elite.Trait.SWIFT:
				does = e.body.has(StatusEffect.Kind.HASTE)
			Elite.Trait.WARDED:
				does = e.body.has(StatusEffect.Kind.SHIELD)
			Elite.Trait.BRUTAL:
				does = e.body.damage_scale > 1.0
			Elite.Trait.VENOMOUS:
				var v := Combatant.make("v", Combatant.Team.PLAYER, 5,
					Stats.new(), HeroClass.School.MELEE, 1.0, 0.0, 1)
				Elite.on_hit(tr, e.body, v)
				does = v.has(StatusEffect.Kind.BURN)
		check("...that actually changes the fight", does,
			"%s is live" % Elite.name_of(tr))

	play.queue_free()
	await process_frame
	_done()


func _done() -> void:
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
