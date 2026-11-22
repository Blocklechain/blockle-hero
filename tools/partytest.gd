extends SceneTree
# ------------------------------------------------------------------------------
# THREE MORE CHAMPIONS, AND THE TWO WAYS THAT RUINS THE GAME.
#
# Partners are the one feature here that can break the game by WORKING. Four
# champions against an encounter built for one is not a difficulty tweak, it
# is an autoplayer, and the two things standing between those outcomes are
# both easy to lose in a refactor and invisible when lost:
#
#   * THE CONTRIBUTION FRACTION. If partners fight at full strength the party
#     is four times a hero instead of a little over twice. Nothing on screen
#     says which it is — the game just gets easy.
#
#   * ENEMIES MUST TARGET THEM. If _threat_for ever goes back to returning
#     the champion unconditionally, partners become three untouchable damage
#     dealers and the correct play is to stand still. Again: no error, no
#     log line, the game just gets easy.
#
# Both are asserted against the REAL Play scene with a real party on the
# field, not against the arithmetic. The arithmetic was never the risk.
# ------------------------------------------------------------------------------

const PartyS := preload("res://scripts/game/Party.gd")
const PartyScreenS := preload("res://scripts/ui/PartyScreen.gd")

var _fails: int = 0
var _done: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _roster() -> Roster:
	var r := Roster.create(HeroRig.animated_heroes(), 909)
	# Enough champions for a full party plus the one being driven.
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	for i in range(6):
		if not r.owns(heroes[i]):
			r.owned[heroes[i]] = HeroProgress.create(heroes[i])
	r.wallet.grant(Wallet.Kind.GOLD, 10_000_000, "test")
	return r


func _init() -> void:
	_slots(); _done += 1
	_persistence(); _done += 1
	await _on_the_field(); _done += 1
	_balance(); _done += 1
	await _they_fight(); _done += 1
	await _the_screen(); _done += 1
	print("")
	check("every section ran to completion", _done == 6, "%d of 6" % _done)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ---- slots -------------------------------------------------------------------

func _slots() -> void:
	print("\n=== slots ===")
	var r := _roster()
	var heroes: PackedStringArray = r.owned_names()
	var leader: String = heroes[0]

	check("the first slot is free and open",
		r.party_slot_is_unlocked(0) and PartyS.cost_of(0) == 0)
	check("...and the rest are not", not r.party_slot_is_unlocked(1))
	check("a locked slot cannot be filled",
		not r.set_companion(1, heroes[1], leader))

	check("a slot can be filled", r.set_companion(0, heroes[1], leader))
	check("...and reads back", r.party_slot(0) == heroes[1])

	# THE CHAMPION BEING DRIVEN CANNOT BE THEIR OWN PARTNER. The same hero in
	# two bodies is two copies of one HeroProgress levelling in parallel, and
	# on screen it is simply two of the same model standing next to each
	# other.
	check("the champion being played cannot join their own party",
		not r.set_companion(0, leader, leader))
	check("...and the slot is unchanged by the refusal",
		r.party_slot(0) == heroes[1])

	r.unlock_party_slot()
	check("a second slot opens with the gold", r.party_slot_is_unlocked(1))
	check("the same champion cannot hold two slots",
		not r.set_companion(1, heroes[1], leader))
	check("...while a different one can",
		r.set_companion(1, heroes[2], leader))
	check("an unowned champion cannot join",
		not r.set_companion(1, "definitely-not-a-hero", leader))

	# The ceiling holds.
	var bought: int = 0
	while r.unlock_party_slot():
		bought += 1
	check("slots run out at the maximum",
		r.party_unlocked == PartyS.SLOTS_MAX,
		"%d unlocked" % r.party_unlocked)

	check("a slot can be emptied", r.clear_companion(1)
		and r.party_slot(1).is_empty())
	check("...and emptying an empty slot is a refusal, not a crash",
		not r.clear_companion(1) and not r.clear_companion(99))

	# companions() IS THE GATE every consumer reads, so it has to be the
	# thing that filters — not each caller.
	r.set_companion(1, heroes[2], leader)
	var took: PackedStringArray = r.companions(leader)
	check("companions() lists the party", took.size() == 2, "%s" % took)
	check("...and never the champion being driven",
		not r.companions(heroes[1]).has(heroes[1]),
		"driving %s" % heroes[1])
	# A save can name a champion the account no longer owns.
	r.owned.erase(heroes[2])
	check("...and never a champion the account does not own",
		not r.companions(leader).has(heroes[2]))


# ---- it survives a restart ---------------------------------------------------

func _persistence() -> void:
	print("\n=== surviving a restart ===")
	var r := _roster()
	var heroes: PackedStringArray = r.owned_names()
	r.unlock_party_slot()
	r.set_companion(0, heroes[1], heroes[0])
	r.set_companion(1, heroes[2], heroes[0])

	var back := Roster.from_dict(r.to_dict(), HeroRig.animated_heroes())
	check("the unlocked count survives", back.party_unlocked == 2,
		"%d" % back.party_unlocked)
	check("the party survives", back.party_slot(0) == heroes[1]
		and back.party_slot(1) == heroes[2])

	# A save from before the party existed must load with one empty slot.
	var old: Dictionary = r.to_dict()
	old.erase("party")
	old.erase("party_unlocked")
	var migrated := Roster.from_dict(old, HeroRig.animated_heroes())
	check("a save from before the party loads with one empty slot",
		migrated.party_unlocked == 1 and migrated.party_slot(0).is_empty()
			and migrated.companions().is_empty())


# ---- on the field ------------------------------------------------------------

## Build the real Play scene with a real party and wait for the world.
func _play_with(party_size: int) -> Node:
	var r := _roster()
	var heroes: PackedStringArray = r.owned_names()
	var leader: String = heroes[0]
	while r.unlock_party_slot():
		pass
	for i in range(party_size):
		r.set_companion(i, heroes[i + 1], leader)

	var play: Node = load("res://scenes/Play.tscn").instantiate()
	play.set("roster", r)
	play.set("hero", leader)
	play.set("region_cells", 96)   # Seconds, not minutes.
	play.set("region_index", 3)
	play.set("campaign_seed", 4242)
	root.add_child(play)
	# The world is generated on a thread; wait for the hero to exist.
	for i in range(900):
		await process_frame
		if play.get("_hero") != null and play.get("_terrain") != null:
			break
	return play


func _on_the_field() -> void:
	print("\n=== on the field ===")
	var play: Node = await _play_with(3)
	var hero_node = play.get("_hero")
	var party: Array = play.get("_party")
	check("the world built", hero_node != null and play.get("_terrain") != null)
	check("the partners are actually on the field", party.size() == 3,
		"%d of 3" % party.size())
	if party.size() == 0:
		play.queue_free()
		return

	# They are the player's real champions, with their real gear and level.
	var mate = party[0]
	check("a partner has a combat body", mate.body != null)
	check("...and is one of the player's own champions",
		play.get("_account").owns(mate.rig.hero_name),
		mate.rig.hero_name)

	# WEAKENED. Compared against an UNWEAKENED body built the same way, so
	# this measures the weakening rather than restating the constant.
	var who: String = mate.rig.hero_name
	var full: Combatant = Combat.champion_body(play.get("_account"), who, 1,
		Rng.seed_of(int(play.get("world_seed")), who), who)
	check("a partner fights at a FRACTION of their own strength",
		mate.body.weapon_power < full.weapon_power * 0.95
			and mate.body.max_health < full.max_health * 0.95,
		"%.0f of %.0f power" % [mate.body.weapon_power, full.weapon_power])
	check("...and not so weak as to be decoration",
		mate.body.weapon_power > full.weapon_power * 0.3,
		"%.2f of full" % (mate.body.weapon_power / full.weapon_power))

	# ENEMIES MUST BE ABLE TO COME FOR THEM. Driven through the real
	# _threat_for: a partner standing next to an enemy, the champion far
	# away.
	var foes: Array = play.get("_enemy_nodes")
	check("the region has enemies", foes.size() > 0, "%d" % foes.size())
	if foes.size() > 0:
		var foe = foes[0]
		var at: Vector2 = foe.ground_position()
		# Put the partner on top of the enemy and the champion off in the
		# distance; the enemy must pick the partner.
		mate._place(at + Vector2(1.5, 0.0))
		hero_node._place(at + Vector2(0.0, 30.0))
		var picked = play.call("_threat_for", foe)
		check("an enemy comes for the NEAREST party member, not the player",
			picked == mate,
			"picked %s" % ("the partner" if picked == mate
				else ("the champion" if picked == hero_node else "nothing")))
		# And the other way round, or the fix is "enemies always ignore you".
		hero_node._place(at + Vector2(1.0, 0.0))
		mate._place(at + Vector2(0.0, 30.0))
		check("...and for the champion when the champion is nearest",
			play.call("_threat_for", foe) == hero_node)

		# A DOWNED PARTNER IS NOT A TARGET, or enemies stand over a corpse
		# while the player is hit by nothing.
		#
		# KILLED THROUGH take_hit, not by setting health to 0: the controller
		# learns it is dead from the body's `died` signal, so assigning the
		# field directly leaves is_dead() false and the first version of this
		# assertion was measuring a partner that was still very much alive —
		# and passing, because its fallback clause was true for any party
		# containing the champion.
		mate._place(at + Vector2(1.5, 0.0))
		hero_node._place(at + Vector2(0.0, 30.0))
		mate.body.take_hit(mate.body.max_health * 10.0, "test")
		check("the partner actually went down", mate.body.health <= 0.0
			and mate.is_dead(),
			"%.0f hp, is_dead=%s" % [mate.body.health, mate.is_dead()])
		check("a downed partner leaves the living party",
			not (play.call("_living_party") as Array).has(mate))
		# NOT "go back to the champion": there are two other partners alive
		# and one of them is probably nearer than a champion standing 30 m
		# away, so that assertion was wrong about its own scenario. What
		# must hold is that the DEAD one is never picked.
		var after = play.call("_threat_for", foe)
		check("...and the downed one is never picked again",
			after != mate and after != null,
			"picked %s" % (after.rig.hero_name if after != null
				and after.rig != null else "nothing"))

		# AND THEY GET UP between waves, or one bad pack ends the party for
		# the rest of a ten-wave descent.
		play.call("_revive_party")
		check("a downed partner is back on its feet for the next wave",
			not mate.is_dead() and mate.body.health > 0.0,
			"%.0f hp" % mate.body.health)

	# A partner who cannot be fielded is not fielded.
	var solo: Node = await _play_with(0)
	check("a player with no party plays alone",
		(solo.get("_party") as Array).is_empty())
	# And the single-hero fight is unchanged: with nobody else alive, the
	# threat is always the champion.
	var solo_foes: Array = solo.get("_enemy_nodes")
	if solo_foes.size() > 0:
		check("...and every enemy still comes for them",
			solo.call("_threat_for", solo_foes[0]) == solo.get("_hero"))
	solo.queue_free()
	play.queue_free()


# ---- balance -----------------------------------------------------------------

func _balance() -> void:
	print("\n=== balance ===")
	# THE RATIO IS THE WHOLE DESIGN. A full party must be about twice a hero,
	# not four times — this is the number that, drifting upward, turns the
	# feature into an autoplayer without anything saying so.
	var full_party: float = 1.0 + 3.0 * PartyS.CONTRIBUTION
	check("a full party is roughly twice a champion, not four times",
		full_party >= 1.8 and full_party <= 3.0,
		"%.2f champions' worth of output" % full_party)

	# And they are genuinely killable: health is scaled too, so a partner is
	# not an immortal wall.
	var body: Combatant = Combatant.make("x", Combatant.Team.PLAYER, 10,
		Stats.new(), HeroClass.School.MELEE, 10.0, 0.0, 1)
	var hp: float = body.max_health
	var power: float = body.weapon_power
	PartyS.weaken(body)
	check("weakening scales health as well as damage",
		body.max_health < hp and body.weapon_power < power,
		"%.0f hp of %.0f, %.0f power of %.0f"
			% [body.max_health, hp, body.weapon_power, power])
	check("...and leaves it at full health, not injured",
		is_equal_approx(body.health, body.max_health))

	# Partners earn less than the champion, and more than nothing.
	check("a partner earns a share of a kill, not all of it and not none",
		PartyS.XP_SHARE > 0.0 and PartyS.XP_SHARE < 1.0,
		"%.2f" % PartyS.XP_SHARE)

	# The leash keeps them near the player rather than off hunting.
	check("the leash is shorter than the aggro range they would chase into",
		PartyS.LEASH < 18.0 * 2.5,
		"%.1f m" % PartyS.LEASH)
	check("the follow gap leaves the champion visible",
		PartyS.FOLLOW_GAP > 1.5, "%.1f m" % PartyS.FOLLOW_GAP)
	# Three partners must not stand on one another.
	var seen: Dictionary = {}
	for i in range(PartyS.SLOTS_MAX):
		seen["%.1f/%.1f" % [PartyS.FORMATION[i].x, PartyS.FORMATION[i].y]] = true
	check("the formation gives each partner its own spot",
		seen.size() == PartyS.SLOTS_MAX, "%d distinct" % seen.size())


# ---- the screen --------------------------------------------------------------

func _the_screen() -> void:
	print("\n=== the screen ===")
	var r := _roster()
	var heroes: PackedStringArray = r.owned_names()
	var leader: String = heroes[0]

	var screen: UiScreen = PartyScreenS.new()
	screen.roster = r
	screen.hero = leader
	var saves: Array = [0]
	var notices: Array = []
	screen.state_changed.connect(func() -> void: saves[0] += 1)
	screen.notified.connect(func(t: String) -> void: notices.append(t))
	root.add_child(screen)
	await process_frame

	var buttons: Array = _buttons(screen)
	check("the screen builds", buttons.size() > 0, "%d buttons" % buttons.size())

	# Open the picker for slot 0 and choose someone, by PRESSING.
	var open: Button = _button_called(buttons, "Choose a champion")
	check("an empty slot offers a picker", open != null)
	if open != null:
		open.pressed.emit()
		await process_frame
		var choices: Array = _buttons(screen)
		# The picker must not list the champion being driven.
		var listed_self: bool = _button_called(choices,
			"%s  ·  level %d" % [ChampionName.of(leader),
				r.progress(leader).level]) != null
		check("the picker does not offer the champion being played",
			not listed_self)

		var chose: bool = false
		for b in choices:
			var text: String = (b as Button).text
			if text.find("·  level") < 0:
				continue
			(b as Button).pressed.emit()
			chose = true
			break
		check("pressing a champion puts them in the slot",
			chose and not r.party_slot(0).is_empty(),
			"slot 0 = '%s'" % r.party_slot(0))
		check("...and asks the shell to save", int(saves[0]) >= 1,
			"%d" % int(saves[0]))
		await process_frame

	# Removing works through the button too.
	var remove: Button = _button_called(_buttons(screen), "Remove")
	check("a filled slot offers Remove", remove != null)
	if remove != null:
		remove.pressed.emit()
		check("...which empties it", r.party_slot(0).is_empty())

	# The locked slot must show its price and buy with the gold.
	var buy: Button = _button_called(_buttons(screen), "Open slot")
	check("a locked slot can be bought", buy != null)
	if buy != null:
		var before: int = r.party_unlocked
		buy.pressed.emit()
		check("...and buying opens it", r.party_unlocked == before + 1,
			"%d -> %d" % [before, r.party_unlocked])

	# And it refuses without the gold, with a message rather than silently.
	var poor := Roster.create(HeroRig.animated_heroes(), 7)
	var s2: UiScreen = PartyScreenS.new()
	s2.roster = poor
	s2.hero = poor.owned_names()[0]
	var said: Array = []
	s2.notified.connect(func(t: String) -> void: said.append(t))
	root.add_child(s2)
	await process_frame
	var buy2: Button = _button_called(_buttons(s2), "Open slot")
	if buy2 != null:
		buy2.pressed.emit()
		check("a slot refused for lack of gold SAYS SO", said.size() == 1,
			"" if said.is_empty() else String(said[0]))
	else:
		check("a locked slot is buyable on a fresh account", false,
			"no Open slot button")

	screen.queue_free()
	s2.queue_free()


func _buttons(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is Button:
			out.append(c)
		out.append_array(_buttons(c))
	return out


func _button_called(buttons: Array, text: String) -> Button:
	for b in buttons:
		if (b as Button).text == text:
			return b
	return null


# ---- do they actually do anything? -------------------------------------------

func _they_fight() -> void:
	print("\n=== they follow, and they fight ===")
	# THE POINT OF THIS SECTION. Every other assertion here would pass on a
	# party that stands still forever: the slots would fill, the bodies would
	# be weakened, the enemies would target them, and the player would watch
	# three statues get killed. _think_party is the thing that has to be
	# running, and the only way to know it is to drive the clock and watch
	# them move.
	var play: Node = await _play_with(2)
	var hero_node = play.get("_hero")
	var party: Array = play.get("_party")
	if party.is_empty() or hero_node == null:
		check("a party reached the field to be driven", false)
		play.queue_free()
		return

	var mate = party[0]
	var foes: Array = play.get("_enemy_nodes")
	if foes.is_empty():
		check("the region had enemies to fight", false)
		play.queue_free()
		return

	# ---- they fight what the champion has walked into ----------------------
	# The champion and the partner next to an enemy; the partner must close
	# or swing rather than stand there.
	var foe = foes[0]
	var at: Vector2 = foe.ground_position()
	hero_node._place(at + Vector2(3.0, 0.0))
	mate._place(at + Vector2(7.0, 0.0))
	mate.stop()
	var engaged: bool = false
	# A ONE-ELEMENT ARRAY again: a bool captured by a GDScript lambda is
	# captured BY VALUE, so the first version of this never saw the signal
	# and reported "used an ability=false" for a partner that was swinging.
	var acted: Array = [false]
	mate.ability_used.connect(func(_slot: int) -> void: acted[0] = true)
	for i in range(40):
		play.call("_think_party")
		if mate.is_moving() or bool(acted[0]):
			engaged = true
			break
		await process_frame
	check("a partner engages an enemy the champion is standing next to",
		engaged, "moving=%s used an ability=%s"
			% [mate.is_moving(), bool(acted[0])])
	# AND IT USES ITS WHOLE KIT. _choose_action, the ENEMY chooser, caps the
	# kit by Campaign.enemy_actions(tier) — a partner pointed at it fought
	# with one ability on Normal and three on Merciless, their kit getting
	# BETTER as the game got harder.
	#
	# Asserted as the actual DIFFERENCE between the two choosers at point
	# blank on Normal, not as "the partner chooser returned something": it
	# returns 0 for the basic attack, so any >= 0 check passes trivially.
	var normal_allows: int = Campaign.enemy_actions(Campaign.Tier.NORMAL)
	check("Normal deliberately limits what an ENEMY may use",
		normal_allows < 4, "%d action(s)" % normal_allows)
	# Clear every cooldown so the choice is about the kit, not about timing.
	for slot in range(1, 4):
		var ab: Ability = mate.ability_in_slot(slot)
		if ab != null:
			mate._cooldowns[ab.id] = 0.0
	var top: int = 0
	for slot in range(3, 0, -1):
		var ab2: Ability = mate.ability_in_slot(slot)
		if ab2 != null and (ab2.shape == Ability.Shape.SELF
				or ab2.range_m >= 1.0):
			top = slot
			break
	var as_partner: int = play.call("_partner_action", mate, 0.5)
	var as_enemy: int = play.call("_choose_action", mate, 0.5)
	check("a partner reaches its highest ability at point blank",
		as_partner == top, "slot %d, highest usable is %d"
			% [as_partner, top])
	check("...which the enemy chooser on Normal would not have given it",
		top > as_enemy or normal_allows > top,
		"partner %d vs enemy-rules %d" % [as_partner, as_enemy])

	# ---- and they come back when there is nothing to fight -----------------
	# Everything hostile moved far outside the leash, so the only correct
	# behaviour is to regroup on the champion.
	for n in foes:
		if n != null and is_instance_valid(n):
			n._place(at + Vector2(0.0, 120.0))
	var target = play.call("_partner_target", mate, hero_node.ground_position())
	check("nothing inside the leash is nothing to fight", target == null,
		"picked %s" % ("something" if target != null else "nothing"))

	# ON WALKABLE GROUND, found rather than assumed: the first version put
	# the partner 25 m east of the champion, which in this region is inside a
	# rock — and a partner standing somewhere the pathfinder cannot route
	# from cannot walk home, so the test was measuring the scenery.
	hero_node._place(at)
	var path := Pathing.new(play.get("_terrain"))
	var parked: Vector2 = at
	for radius in [18.0, 14.0, 10.0, 7.0]:
		for step in range(36):
			var ang: float = TAU * float(step) / 36.0
			var spot: Vector2 = at + Vector2(cos(ang), sin(ang)) * radius
			if path.is_walkable(spot):
				parked = spot
				break
		if parked != at:
			break
	check("the partner can be parked somewhere it can walk back from",
		parked != at, "%.1f m away" % parked.distance_to(at))
	mate._place(parked)
	mate.stop()
	var came_back: bool = false
	var started: float = mate.ground_position().distance_to(at)
	for i in range(40):
		play.call("_think_party")
		await process_frame
		if mate.ground_position().distance_to(at) < started - 1.0:
			came_back = true
			break
	check("a partner left behind walks back to the champion", came_back,
		"%.1f m -> %.1f m" % [started,
			mate.ground_position().distance_to(at)])

	# ---- and they earn experience ------------------------------------------
	# A partner that never levels makes the only correct party "the three
	# already highest", which is the roster problem this feature exists to
	# fix, made worse.
	var account: Roster = play.get("_account")
	var who: String = mate.rig.hero_name
	var p: HeroProgress = account.progress(who)
	var before_level: int = p.level
	var before_xp: float = p.xp
	# Through _award_xp, which is what a KILL calls — not _award_party_xp
	# directly, because the question is whether a kill pays the party.
	play.call("_award_xp")
	check("a kill pays the partners too",
		p.level > before_level or p.xp > before_xp,
		"%.1f -> %.1f xp" % [before_xp, p.xp])

	# A DOWNED PARTNER EARNS NOTHING. It is the only cost of letting one die.
	var other = party[1] if party.size() > 1 else null
	if other != null:
		var who2: String = other.rig.hero_name
		var p2: HeroProgress = account.progress(who2)
		other.body.take_hit(other.body.max_health * 10.0, "test")
		var xp_before: float = p2.xp
		var lvl_before: int = p2.level
		play.call("_award_xp")
		check("...but a downed partner earns nothing",
			p2.level == lvl_before and is_equal_approx(p2.xp, xp_before),
			"%.1f xp" % p2.xp)

	play.queue_free()
