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
	#
	# THE PAIR IS PLACED ON GROUND WITH ROOM, both of them, rather than the
	# archer being dropped a metre from wherever the champion happened to
	# spawn. _retreat ends in move_to, so an archer with a rock behind it
	# cannot back off at all — and this is a 96-cell harness region, where
	# that is the common case rather than the rare one. It failed on CI for
	# exactly this reason while passing locally, which is the signature of a
	# test measuring the scenery instead of the behaviour.
	#
	# The retreat goal is measured from the CHAMPION (`from + away * want`),
	# so the line that has to be clear runs from the champion outward past
	# the archer, for the full stand-off plus a margin.
	var r: HeroController = ranged[0]
	r.set_meta("pack", -2)
	play._awake[-2] = true
	var want_room: float = r_stand + 3.0
	var path2 := Pathing.new(play.get("_terrain") as Terrain)
	var anchor: Vector2 = me.ground_position()
	var lane: Vector2 = Vector2.ZERO
	for radius in [0.0, 4.0, 8.0, 12.0]:
		for step in range(48):
			var ang: float = TAU * float(step) / 48.0
			var dir := Vector2(cos(ang), sin(ang))
			var stand_at: Vector2 = me.ground_position() + dir * radius
			if not path2.is_walkable(stand_at):
				continue
			for out_ang in range(48):
				var d2 := Vector2(cos(TAU * float(out_ang) / 48.0),
					sin(TAU * float(out_ang) / 48.0))
				var far: Vector2 = stand_at + d2 * want_room
				if path2.is_walkable(far) \
						and path2.clear_line(stand_at, far):
					anchor = stand_at
					lane = d2
					break
			if lane != Vector2.ZERO:
				break
		if lane != Vector2.ZERO:
			break
	check("the pair can be stood somewhere the archer has room behind it",
		lane != Vector2.ZERO, "needed %.1f m of clear ground" % want_room)
	me._place(anchor)
	r._place(anchor + lane * 1.0)
	var start_gap: float = r.ground_position().distance_to(
		me.ground_position())
	# THE CHAMPION IS HELD ALIVE for the duration.
	#
	# Play._think() returns immediately for a dead champion, so the whole
	# enemy brain — including the archer's retreat — simply stops. This
	# section stands the champion still for 240 frames in a region with six
	# awake enemies, and on CI they died: the archer froze 0.1 m from where
	# it started and the failure read as "a ranged enemy does not back off",
	# with no mention of the champion anywhere. (The same dead-champion
	# mechanism was behind spectacletest's CI-only dodge failure.)
	#
	# The subject here is the archer's footwork, not the champion's
	# survival, which is measured elsewhere — so it is topped up rather than
	# left to luck, and asserted afterwards so this cannot silently become
	# vacuous.
	# GIVEN A POOL NOTHING CAN CHEW THROUGH, rather than healed every frame.
	#
	# The frame-by-frame top-up was still not enough and CI still killed
	# them: once Combatant.alive latches false, assigning health does not
	# resurrect anything, and a champion can be taken from full to zero
	# inside a single frame by a pack of six. Raising max_health means there
	# is no frame in which they can reach zero at all, so the latch never
	# flips and there is nothing to undo.
	if me.body != null:
		me.body.max_health = 1_000_000.0
		me.body.health = me.body.max_health
	for i in range(240):
		if me.body != null and not me.body.alive:
			# Belt and braces: if something kills them anyway, say so by
			# failing the assertion below rather than by silently measuring
			# a frozen archer.
			break
		await process_frame
	check("the champion survived to watch it", me.body != null
		and me.body.alive and not me.is_dead())
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
	# THE SEARCH HAS TO ASK FOR WHAT _retreat ACTUALLY NEEDS, which is less
	# than it looks. The goal is `from + away * want` — measured from the
	# THREAT, not from the archer — so with the threat 4 m behind it and
	# want = 8, the archer is asked to walk 4 m. The first version of this
	# demanded 13 m of clear line, found nowhere in a 96-cell region that
	# satisfied it, never placed the archer at all, and then measured a boxed
	# -in archer giving way zero times — while reporting PASS, because
	# "it plants" is trivially true for something that cannot move.
	#
	# The threat is SYNTHESISED rather than taken from the champion, because
	# _retreat takes a plain Vector2: that lets the retreat line be chosen to
	# be clear instead of hoping the champion is standing somewhere useful.
	var terrain: Terrain = play.get("_terrain")
	var threat: Vector2 = me.ground_position()
	var placed: bool = false
	if terrain != null:
		var path := Pathing.new(terrain)
		var here: Vector2 = kiter.ground_position()
		# Several radii, because the open ground may not be adjacent.
		for radius in [0.0, 3.0, 6.0, 9.0]:
			for step in range(48):
				var ang: float = TAU * float(step) / 48.0
				var dir := Vector2(cos(ang), sin(ang))
				var stand: Vector2 = here + dir * radius
				if not path.is_walkable(stand):
					continue
				# The retreat line: 6 m of clear walkable ground beyond the
				# archer, which is the 4 m it is asked for plus a margin so
				# the last step is not a coin flip.
				var goal: Vector2 = stand + dir * 6.0
				if path.is_walkable(goal) and path.clear_line(stand, goal):
					kiter._place(stand)
					threat = stand - dir * 4.0
					placed = true
					break
			if placed:
				break
	# SAID OUT LOUD. A harness that could not set up its own scenario must
	# not go on to report that the thing it could not test is fine.
	check("the archer can be stood somewhere with room behind it", placed,
		"searched 4 radii x 48 angles")

	kiter.set_meta("retreat_t", 0.0)
	kiter.set_meta("hold_until", 0.0)

	# WAIT FOR THE ARCHER TO BE FREE, and get the champion out of its way.
	#
	# The loop below drives _retreat twelve times with NO frames in between,
	# which is deliberate — it is measuring a budget in think-ticks, not in
	# seconds. But _retreat ends in move_to, and move_to refuses outright
	# while a controller is busy or dead. So an archer that is mid-cast when
	# this section starts refuses all twelve calls and the section reports
	# "it ran out of ground" for an archer that never tried: gave_way 0,
	# which is what CI was seeing while this passed locally.
	#
	# The champion is moved off first for two reasons: it stops the archer
	# casting at them, and it stops the champion's own auto-attack killing
	# the archer mid-section.
	me._place(anchor + lane * 60.0)
	if kiter.body != null:
		kiter.body.max_health = 1_000_000.0
		kiter.body.health = kiter.body.max_health
	for i in range(240):
		if not kiter.is_busy() and not kiter.is_dead():
			break
		await process_frame
	check("the archer is free to be driven", not kiter.is_busy()
		and not kiter.is_dead(),
		"busy=%s dead=%s" % [kiter.is_busy(), kiter.is_dead()])
	kiter.set_meta("retreat_t", 0.0)
	kiter.set_meta("hold_until", 0.0)
	var gave_way: int = 0
	var planted: bool = false
	for i in range(12):
		if play._retreat(kiter, threat, 8.0):
			gave_way += 1
		else:
			planted = true
			break
	check("...and it gave ground at all before planting", gave_way > 0,
		"%d times" % gave_way)
	check("...and it runs out of ground and plants", planted,
		"gave way %d times, then held" % gave_way)
	# ONLY THE UPPER BOUND IS A REAL INVARIANT.
	#
	# This asserted 3 <= gave_way <= 8 and failed about one run in three,
	# because the LOWER bound is not a property of the budget at all — it is
	# a property of how much open ground the generator happened to leave
	# behind the archer. _retreat() returns false when the pathfinder cannot
	# reach the goal, so "it stopped after two steps" can mean "the budget
	# ran out" or "there is a rock there", and the test cannot tell which.
	# Planting EARLY is correct behaviour; planting never is the bug.
	#
	# So the upper bound is checked against the simulation, and the budget
	# arithmetic — which is what the lower bound was really reaching for — is
	# checked as arithmetic, where no scenery can get at it.
	var budget_thinks: int = int(ceil(play.RETREAT_BUDGET / play.THINK))
	check("...for no longer than the budget allows",
		gave_way <= budget_thinks + 1,
		"gave way %d times, budget allows %d" % [gave_way, budget_thinks])
	check("...and the budget is a few seconds of backing off, not one step",
		budget_thinks >= 3 and budget_thinks <= 12,
		"%.1fs of budget at %.2fs a think = %d steps"
			% [play.RETREAT_BUDGET, play.THINK, budget_thinks])
	# Having planted, it must stay planted for the rest — otherwise it
	# alternates step-back/step-back and the chase never ends.
	check("...and holds rather than immediately giving way again",
		not play._retreat(kiter, threat, 8.0))

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
