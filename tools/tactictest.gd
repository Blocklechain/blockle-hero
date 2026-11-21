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
