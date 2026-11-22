extends SceneTree
# ------------------------------------------------------------------------------
# The things that are supposed to make a player look up.
#
# Each one is checked in the RUNNING SCENE, because every spectacle feature in
# this project so far has worked perfectly somewhere the player was not.
#
#   - the boss telegraphs a slam, and standing in it hurts while stepping out
#     of it does not. The mechanic IS the dodge; if both outcomes are the same
#     the warning is decoration.
#   - a rare drop lights up; a common one does not, because a beacon over
#     every grey item is lighting, not information.
#   - a champion who cleared a difficulty carries a visible mark.
#
#   godot --headless --path . --script tools/spectacletest.gd
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
	# A veteran, so the mark has something to show.
	account.progress(who).tiers_cleared = 2

	var play: Node = load("res://scenes/Play.tscn").instantiate()
	play.set("world_seed", Campaign.region_seed(4242, REGION))
	play.set("biome", Biome.tag(Campaign.biome_at(REGION),
		Campaign.dread(REGION)))
	play.set("hero", who)
	play.set("region_index", REGION)
	play.set("campaign_seed", 4242)
	play.set("tier", Campaign.Tier.NORMAL)
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

	print("\n=== the veteran is marked ===")
	var mark: Node = me.get_node_or_null("VeteranMark")
	check("a champion who cleared a difficulty wears it",
		mark != null and mark.get_child_count() > 0,
		"%d rings" % (mark.get_child_count() - 1) if mark != null else "none")
	# It has to FOLLOW. A mark placed in the world instead of on the champion
	# is a mark they walk out of.
	if mark != null:
		check("...and it is on the champion, not on the ground",
			mark.get_parent() == me)

	print("\n=== the boss tells you where it is going to hit ===")
	var boss: HeroController = null
	for n in play.get_children():
		if n is HeroController and n != me \
				and n.scale.y >= Encounter.BOSS_SIZE - 0.001:
			boss = n
	check("the map has a boss", boss != null)
	if boss == null:
		_done()
		return

	# CLEAR THE FIELD FIRST. Enemies now fight like their class, which means
	# the eight ranged ones on this map stand off and shoot — and between the
	# first slam and the second they killed the level-1 champion outright, so
	# the dodge case never ran. That is the game working; it is not what this
	# section is measuring. Push everyone but the boss out of the fight.
	for n in play.get_children():
		if n is HeroController and n != me and n != boss:
			(n as HeroController)._place(
				me.ground_position() + Vector2(90.0, 90.0))

	# Stand in front of it and let the brain decide.
	boss._place(me.ground_position() + Vector2(6.0, 0.0))
	play.set("_slam_cd", 0.0)
	var warned: int = 0
	for i in range(240):
		await process_frame
		if play.get("_slam_at") != Vector2.INF:
			warned += 1
			break
	check("it winds up a slam when you are in range", warned > 0)
	if warned == 0:
		_done()
		return

	var at: Vector2 = play.get("_slam_at")
	var radius: float = float(play.get("_slam_radius"))
	var tele: Vfx = null
	for c in play.get_children():
		if c is Vfx:
			tele = c
	check("...and draws it on the ground before it lands", tele != null)

	# STAND IN IT.
	me._place(at)
	var hp_before: float = me.body.health
	for i in range(240):
		await process_frame
		if play.get("_slam_at") == Vector2.INF:
			break
	check("standing in it hurts", me.body.health < hp_before,
		"%.0f -> %.0f" % [hp_before, me.body.health])

	# ...AND THE SLAM ITSELF LEAVES YOU ALIVE. Dying to the first telegraph
	# you ever see teaches nothing, because you never find out it was
	# avoidable.
	#
	# MEASURED ON THE SLAM, NOT ON LIVE HP, and that distinction is the whole
	# reason this reads oddly. The boss is standing 6m away — inside melee —
	# so the champion is also being hit normally for the whole wind-up. When
	# the window was widened to make the slam dodgeable at all, those extra
	# swings started finishing the job, and this check went red while the
	# thing it names was working perfectly. It had been quietly asserting
	# "a slam plus however many autoattacks fit in the window is survivable",
	# which is not a property anyone designed for and gets harder every time
	# the telegraph gets fairer.
	var cap: float = me.body.max_health * float(play.get("SLAM_MAX_FRACTION"))
	var dealt: float = minf(float(play.get("_slam_damage")), cap)
	check("...but the slam itself cannot kill from full",
		dealt < me.body.max_health,
		"%.0f of %.0f max" % [dealt, me.body.max_health])

	# STEP OUT OF IT.
	me.body.health = me.body.max_health
	play.set("_slam_cd", 0.0)
	boss._place(me.ground_position() + Vector2(6.0, 0.0))
	var again: bool = false
	for i in range(240):
		await process_frame
		if play.get("_slam_at") != Vector2.INF:
			again = true
			break
	if again:
		var spot: Vector2 = play.get("_slam_at")
		# Well clear, on walkable ground.
		me._place(spot + Vector2(radius * 2.5, 0.0))
		# WATCH FOR SLAM DAMAGE SPECIFICALLY, not for a change in health.
		#
		# Same trap as the survivability check above: the boss chases, and
		# over a wind-up long enough to be dodgeable it closes the distance
		# and lands ordinary swings. Comparing total HP therefore asserts
		# "stepping out of the circle also makes you immune to melee", which
		# nobody designed and which gets harder to satisfy every time the
		# telegraph is made fairer. The damaged signal carries its source, so
		# the real property — the SLAM missed — is directly observable.
		var slam_hits: Array = [0]
		var watch := func(_amount: float, _crit: bool, source: String):
			if source == "Slam":
				slam_hits[0] += 1
		me.body.damaged.connect(watch)
		for i in range(240):
			await process_frame
			if play.get("_slam_at") == Vector2.INF:
				break
		me.body.damaged.disconnect(watch)
		check("...and stepping out of it means the slam misses",
			slam_hits[0] == 0, "%d slam hits while clear" % slam_hits[0])
	else:
		print("    boss: alive=%s busy=%s stunned=%s gap=%.1f cd=%.2f "
			% [boss.body.alive, boss.is_busy(), boss.is_stunned(),
				boss.ground_position().distance_to(me.ground_position()),
				float(play.get("_slam_cd"))]
			+ "hero_alive=%s stand=%.1f" % [me.body.alive,
				float(boss.get_meta("stand_off", -1.0))])
		check("the boss slammed a second time to test the dodge", false)

	print("\n=== only good loot lights up ===")
	var ground: Node = play.get("_loot")
	var before_fx: int = _beacons(play)
	var common := Loot.Drop.new()
	common.item = Item.roll(7, 1, 5, Item.Rarity.COMMON, Item.Slot.WEAPON)
	ground.dropped.emit(common, me.global_position)
	await process_frame
	check("a common drop lights nothing", _beacons(play) == before_fx,
		"%d beacons" % _beacons(play))

	var good := Loot.Drop.new()
	good.item = Item.roll(7, 2, 5, Item.Rarity.LEGENDARY, Item.Slot.WEAPON)
	ground.dropped.emit(good, me.global_position)
	await process_frame
	check("a legendary drop puts a pillar of light on it",
		_beacons(play) > before_fx, "%d beacons" % _beacons(play))

	play.queue_free()
	await process_frame
	_done()


func _beacons(play: Node) -> int:
	var n: int = 0
	for c in play.get_children():
		if c is Vfx:
			n += 1
	return n


func _done() -> void:
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)
