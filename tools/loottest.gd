extends SceneTree
# ------------------------------------------------------------------------------
# Does killing a thing give you a thing, and does the thing do anything?
#
# Item.gd and Stash.gd were both written and both TESTED — and nothing in the
# game connected a death to a drop, so the stash could only ever be filled by
# the merchant, and the champion's combat body was built with 0 weapon power and
# 0 armour. Gear moved every figure on the character sheet and not one figure in
# a fight. None of that fails a compile, and none of it fails tools/metatest.gd,
# because an unreachable economy is perfectly self-consistent.
#
# So this check is about the LOOP, end to end, and deliberately asserts on
# observable change rather than on code being present:
#
#   1. a kill rolls a drop, and the same seed rolls the same drop
#   2. rarity and item level are gated by the campaign tier and the champion's
#      own level, so a first-tier kill cannot hand out endgame gear
#   3. a kill puts an orb in the world, and walking over it fills the stash and
#      pays the wallet
#   4. a full stash REFUSES the item and leaves it on the ground
#   5. equipping that item changes a damage number — through Combatant.strike,
#      not through a getter
#   6. all of it survives save and load
#   7. gold reaches the wallet from kills AND from selling, with a ledger entry
#   8. the real scene: Play.tscn, a generated region, an enemy registered through
#      the encounter seam, killed, and the loot banked in the player's account
#
#   godot --headless --path . --script tools/loottest.gd
# ------------------------------------------------------------------------------

## A small region for check 8. The shipping figure is 384 cells (192 m, about
## four seconds of generation); 160 is 80 m of real ground, generated the real
## way, in a fraction of the time. Anything smaller starts to crowd Layout's
## eleven nodes into each other.
const TEST_CELLS: int = 160
## Frames to wait for that region and its champion.
const BUILD_FRAMES: int = 6000

var fails: int = 0

## THE SAVE FILE IS BACKED UP AND RESTORED. Check 8 plays a region on a real
## account, and leaving a region writes what was picked up (Play._flush_account)
## — which is the behaviour being tested, and which must not cost a developer
## their own save. Same discipline as tools/uitest.gd.
var _backup: String = ""
var _had_save: bool = false


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	var playable: PackedStringArray = HeroRig.animated_heroes()
	if playable.is_empty():
		print("no hero models found")
		quit(1)
		return

	_keep_save()
	_a_kill_rolls_a_drop()
	_the_drop_is_gated()
	await _an_orb_reaches_the_stash()
	await _a_full_stash_refuses()
	_equipping_changes_the_damage(playable)
	_it_survives_save_and_load(playable)
	_gold_flows_through_the_wallet(playable)
	await _the_real_scene(playable)
	_restore_save()

	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _keep_save() -> void:
	_had_save = FileAccess.file_exists(Roster.SAVE_PATH)
	if not _had_save:
		return
	var f := FileAccess.open(Roster.SAVE_PATH, FileAccess.READ)
	if f != null:
		_backup = f.get_as_text()


func _restore_save() -> void:
	if not _had_save:
		DirAccess.remove_absolute(
			ProjectSettings.globalize_path(Roster.SAVE_PATH))
		return
	var f := FileAccess.open(Roster.SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(_backup)


# ------------------------------------------------------------------------------
# 1. A kill rolls a drop, reproducibly
# ------------------------------------------------------------------------------

func _a_kill_rolls_a_drop() -> void:
	print("\n=== a kill rolls a drop ===")
	const SEED: int = 4242
	var items: int = 0
	var goldless: int = 0
	for i in range(500):
		var d: Loot.Drop = Loot.roll(SEED, i, 12, Campaign.Tier.NORMAL, 14)
		if d.has_item():
			items += 1
		if d.gold <= 0:
			goldless += 1
	check("every kill pays gold", goldless == 0, "%d of 500 paid nothing" % goldless)
	# Not an exact figure — the point is that the published rate is roughly what
	# the stream produces, so a tuning change to ITEM_CHANCE is visible here.
	var rate: float = float(items) / 500.0
	check("gear drops at about the published rate",
		absf(rate - Loot.ITEM_CHANCE) < 0.06,
		"%.1f%% over 500 kills, ITEM_CHANCE %.0f%%" % [rate * 100.0,
			Loot.ITEM_CHANCE * 100.0])

	# THE HEADLINE OF THIS SECTION: a replay from a save must produce the loot
	# the player already saw. Rolled twice, compared field by field.
	var same: int = 0
	var differ: int = 0
	for i in range(200):
		var a: Loot.Drop = Loot.roll(SEED, i, 20, Campaign.Tier.VETERAN, 25)
		var b: Loot.Drop = Loot.roll(SEED, i, 20, Campaign.Tier.VETERAN, 25)
		if a.gold == b.gold and a.has_item() == b.has_item() \
				and (not a.has_item() or a.item.to_dict() == b.item.to_dict()):
			same += 1
		else:
			differ += 1
	check("the same seed and kill rolls the same drop", differ == 0,
		"%d of 200 identical" % same)

	var other: Loot.Drop = Loot.roll(SEED + 1, 7, 20, Campaign.Tier.VETERAN, 25)
	var here: Loot.Drop = Loot.roll(SEED, 7, 20, Campaign.Tier.VETERAN, 25)
	check("a different region seed rolls something else",
		other.gold != here.gold or other.has_item() != here.has_item()
			or (other.has_item() and other.item.to_dict() != here.item.to_dict()))

	# A drop and a merchant offer share the region seed; without separate roll-id
	# bands the first kill would drop the item already in the shop window.
	var collisions: int = 0
	for i in range(Shop.OFFER_COUNT * 20):
		var shop_item: Item = Item.roll(SEED, i + 90000, 20, Item.Rarity.RARE)
		for k in range(60):
			var kill: Loot.Drop = Loot.roll(SEED, k, 20, Campaign.Tier.VETERAN, 25)
			if kill.has_item() and kill.item.id == shop_item.id:
				collisions += 1
	check("kill drops do not share ids with merchant stock", collisions == 0,
		"%d collisions" % collisions)


# ------------------------------------------------------------------------------
# 2. Gating
# ------------------------------------------------------------------------------

func _the_drop_is_gated() -> void:
	print("\n=== rarity and level are gated ===")
	const SEED: int = 99001
	const N: int = 2000

	# An over-levelled enemy against a level-5 champion: the enemy's level is
	# what the item would be rolled at, and the champion's is what caps it.
	var worst: int = 0
	var best_rarity: int = -1
	for i in range(N):
		var d: Loot.Drop = Loot.roll(SEED, i, 50, Campaign.Tier.NORMAL, 5)
		if not d.has_item():
			continue
		worst = maxi(worst, d.item.item_level)
		best_rarity = maxi(best_rarity, d.item.rarity)
	check("a level-5 champion cannot be handed level-50 gear",
		worst <= 5 + Loot.LEVEL_HEADROOM,
		"highest item level %d, cap %d" % [worst, 5 + Loot.LEVEL_HEADROOM])
	check("the first tier cannot drop a legendary",
		best_rarity <= Loot.rarity_ceiling(Campaign.Tier.NORMAL),
		"best over %d kills was %s" % [N,
			Item.RARITY_NAMES.get(best_rarity, "nothing")])

	# ...and the last tier can, or the ceiling is a wall.
	var legendaries: int = 0
	var top_level: int = 0
	for i in range(N):
		var d: Loot.Drop = Loot.roll(SEED, i, 60, Campaign.Tier.ETERNAL, 60)
		if not d.has_item():
			continue
		top_level = maxi(top_level, d.item.item_level)
		if d.item.rarity == Item.Rarity.LEGENDARY:
			legendaries += 1
	check("the last tier does drop legendaries", legendaries > 0,
		"%d over %d kills" % [legendaries, N])
	check("item level follows the enemy, not the cap alone", top_level >= 50,
		"highest %d at enemy level 60" % top_level)

	# Gold rides the tier curve, so clearing harder content pays more for the
	# same enemy.
	var normal: int = 0
	var eternal: int = 0
	for i in range(400):
		normal += Loot.gold_for(SEED, i, 30, Campaign.Tier.NORMAL)
		eternal += Loot.gold_for(SEED, i, 30, Campaign.Tier.ETERNAL)
	check("gold scales with the tier", eternal > normal * 4,
		"%d vs %d gold over 400 kills" % [eternal, normal])


# ------------------------------------------------------------------------------
# 3. Kill -> orb -> stash
# ------------------------------------------------------------------------------

func _an_orb_reaches_the_stash() -> void:
	print("\n=== a kill drops an orb, and walking over it banks it ===")
	var stash := Stash.new()
	var wallet := Wallet.new()
	var field := Loot.Ground.new()
	field.region_seed = 777
	field.tier = Campaign.Tier.VETERAN
	field.champion_level = 20
	field.stash = stash
	field.wallet = wallet
	get_root().add_child(field)

	# Somewhere to stand. A plain Node3D is all the field wants — pickup is a
	# proximity test, not a collision shape.
	var walker := Node3D.new()
	walker.position = Vector3(40.0, 0.0, 40.0)
	get_root().add_child(walker)
	field.follow = walker

	# A real enemy, killed by a real strike, so the drop comes off the same
	# `died` signal the game uses rather than a direct call.
	var enemy: Combatant = Combatant.make("Husk", Combatant.Team.ENEMY, 22,
		Stats.make(8.0, 0.0, 0.0, 6.0), HeroClass.School.MELEE, 0.0, 0.0, 31337)
	var attacker: Combatant = Combatant.make("Champion", Combatant.Team.PLAYER,
		22, Stats.make(40.0, 0.0, 0.0, 20.0), HeroClass.School.MELEE,
		30.0, 0.0, 4242)
	# Find the first kill index that actually rolls an item, so the check below
	# is about the pipeline and not about a 38% dice roll.
	while not Loot.roll(field.region_seed, field.kills, 22, field.tier,
			field.champion_level).has_item():
		field.kills += 1

	var where := Vector3(3.0, 1.5, -2.0)
	# HELD so it can be disconnected again: a lambda that captures the combatant
	# is held BY that combatant's own signal, which is a reference cycle and the
	# exact leak Hud.track_enemy had to unpick by hand. Play.gd avoids it by
	# binding an id instead; a test that leaks is a test that trains people to
	# ignore the leak warning.
	var on_died: Callable = func() -> void: field.on_kill(enemy, where)
	enemy.died.connect(on_died)
	var swings: int = 0
	while enemy.alive and swings < 200:
		attacker.strike(enemy, 4.0, "test")
		swings += 1
	enemy.died.disconnect(on_died)
	check("the enemy died of combat damage", not enemy.alive,
		"%d swings" % swings)
	check("the kill put an orb in the world", field.orb_count() == 1,
		"%d orb(s)" % field.orb_count())
	check("nothing was banked before it was picked up",
		stash.count() == 0 and wallet.gold == 0,
		"%d item(s), %d gold" % [stash.count(), wallet.gold])

	var orb: Loot.Orb = field.orbs()[0]
	check("the orb is where the enemy fell",
		Vector2(orb.position.x, orb.position.z)
			.distance_to(Vector2(where.x, where.z)) < 0.01,
		"%s vs %s" % [str(orb.position), str(where)])
	var name_of: String = orb.drop.item.item_name
	var gold_due: int = orb.drop.gold

	# Standing next to it is not standing on it.
	await process_frame
	check("an orb out of reach is not collected", stash.count() == 0)

	walker.position = orb.position + Vector3(Loot.PICKUP_RADIUS * 0.5, 0.0, 0.0)
	await process_frame
	await process_frame
	check("walking over it puts the item in the stash", stash.count() == 1,
		"'%s'" % (stash.items[0].item_name if stash.count() > 0 else ""))
	check("...and the gold in the wallet", wallet.gold == gold_due,
		"%d gold" % wallet.gold)
	check("...and the item is the one that dropped",
		stash.count() == 1 and stash.items[0].item_name == name_of)
	check("the orb is gone from the field", field.orb_count() == 0)
	check("the wallet says where the gold came from",
		wallet.ledger.size() > 0
			and String(wallet.ledger[wallet.ledger.size() - 1]["why"]).begins_with("kill:"),
		"'%s'" % String(wallet.ledger[wallet.ledger.size() - 1]["why"]))

	# Bobbing and spinning: an orb that sits perfectly still in a procedurally
	# scattered world is a pebble.
	var marker := Loot.Orb.make(Loot.roll(1, 0, 10, Campaign.Tier.NORMAL, 10),
		Vector3.ZERO)
	get_root().add_child(marker)
	var y0: float = marker.position.y
	var r0: float = marker.rotation.y
	for i in range(8):
		await process_frame
	check("an orb moves, so it reads as a drop",
		absf(marker.position.y - y0) > 0.001 and absf(marker.rotation.y - r0) > 0.001,
		"dy %.3f m, dyaw %.3f rad" % [marker.position.y - y0,
			marker.rotation.y - r0])
	marker.queue_free()

	field.queue_free()
	walker.queue_free()
	await process_frame


# ------------------------------------------------------------------------------
# 4. A full stash
# ------------------------------------------------------------------------------

func _a_full_stash_refuses() -> void:
	print("\n=== a full stash refuses, and loses nothing ===")
	var stash := Stash.new()
	for i in range(Stash.CAPACITY):
		stash.add(Item.roll(5, i, 4, Item.Rarity.COMMON))
	check("the stash is at capacity", stash.is_full(),
		"%d of %d" % [stash.count(), Stash.CAPACITY])

	var wallet := Wallet.new()
	var field := Loot.Ground.new()
	field.region_seed = 20260101
	field.tier = Campaign.Tier.MERCILESS
	field.champion_level = 40
	field.stash = stash
	field.wallet = wallet
	get_root().add_child(field)

	while not Loot.roll(field.region_seed, field.kills, 40, field.tier,
			field.champion_level).has_item():
		field.kills += 1
	var enemy: Combatant = Combatant.make("Husk", Combatant.Team.ENEMY, 40,
		Stats.make(1.0, 0.0, 0.0, 1.0), HeroClass.School.MELEE, 0.0, 0.0, 11)
	var refusals: Array[String] = []
	field.refused.connect(func(text: String) -> void: refusals.append(text))
	var drop: Loot.Drop = field.on_kill(enemy, Vector3(1.0, 0.0, 1.0))
	var due: int = drop.gold

	var walker := Node3D.new()
	walker.position = field.orbs()[0].position
	get_root().add_child(walker)
	field.follow = walker
	await process_frame
	await process_frame

	check("the item was refused, not discarded",
		stash.count() == Stash.CAPACITY and field.orb_count() == 1,
		"%d orb(s) still on the ground" % field.orb_count())
	check("the player is told why", refusals.size() >= 1
		and refusals[0].contains("Stash full"),
		"'%s'" % (refusals[0] if refusals.size() > 0 else ""))
	check("the gold was still paid", wallet.gold == due, "%d gold" % wallet.gold)

	# Standing on a refused orb must not pay for it again — the orb is still
	# there, so it WILL be tried again, and a repeat payout is a gold faucet.
	var before: int = wallet.gold
	for i in range(4):
		await process_frame
	check("a refused orb cannot pay twice", wallet.gold == before,
		"%d gold" % wallet.gold)

	# Make room, and the same orb pays out.
	stash.remove_at(0)
	field.orbs()[0].retry_in = 0.0
	await process_frame
	await process_frame
	check("making room lets the same orb be collected",
		stash.count() == Stash.CAPACITY and field.orb_count() == 0,
		"%d item(s), %d orb(s)" % [stash.count(), field.orb_count()])
	check("and still only paid once", wallet.gold == before,
		"%d gold" % wallet.gold)

	field.queue_free()
	walker.queue_free()
	await process_frame


# ------------------------------------------------------------------------------
# 5. Equipping changes a damage number
# ------------------------------------------------------------------------------

## A weapon with NO attribute bonus, so the only thing that changes between the
## two bodies below is flat weapon power. A rolled item moves agility too, which
## moves crit and dodge, which would make the comparison a different fight
## rather than the same fight with a sword.
func _plain(slot: int, power: float, id: int) -> Item:
	var it := Item.new()
	it.id = id
	it.item_name = "Proving %s" % String(Item.SLOT_NAMES.get(slot, "Piece"))
	it.slot = slot
	it.rarity = Item.Rarity.COMMON
	it.item_level = 20
	it.power = power
	it.bonus = Stats.new()
	return it


func _equipping_changes_the_damage(playable: PackedStringArray) -> void:
	print("\n=== equipping changes a damage number ===")
	var roster: Roster = Roster.create(playable, 500)
	var hero: String = roster.owned_names()[0]
	var p: HeroProgress = roster.progress(hero)
	p.level = 20

	var bare: Combatant = Combat.champion_body(roster, hero, 1, 7)
	check("an unarmed champion still hits for something",
		bare.weapon_power == Stash.UNARMED_POWER and bare.attack_power() > 0.0,
		"%.0f weapon, %.1f attack" % [bare.weapon_power, bare.attack_power()])
	check("an unarmed champion mitigates nothing",
		is_zero_approx(bare.mitigation()), "%.3f" % bare.mitigation())

	roster.stash.add(_plain(Item.Slot.WEAPON, 55.0, 90001))
	roster.stash.add(_plain(Item.Slot.CHEST, 48.0, 90002))
	check("the stash holds them", roster.stash.count() == 2)
	check("equipping the weapon succeeds", roster.stash.equip(hero, 90001))
	check("equipping the chest succeeds", roster.stash.equip(hero, 90002))
	check("equipped gear leaves the shared pool", roster.stash.count() == 0,
		"%d loose" % roster.stash.count())

	var armed: Combatant = Combat.champion_body(roster, hero, 1, 7)
	check("the weapon reached the combat body",
		armed.attack_power() > bare.attack_power(),
		"%.1f -> %.1f attack power" % [bare.attack_power(), armed.attack_power()])
	check("the armour reached the combat body",
		armed.mitigation() > bare.mitigation(),
		"%.1f%% -> %.1f%% mitigated" % [bare.mitigation() * 100.0,
			armed.mitigation() * 100.0])
	check("armour is health too", armed.max_health > bare.max_health,
		"%.0f -> %.0f hp" % [bare.max_health, armed.max_health])
	# The sheet and the fight have to be the same arithmetic, or the merchant's
	# "better than equipped by 14" is a guess.
	check("the character sheet agrees with the fight",
		absf(roster.effective_damage(hero) - armed.attack_power()) < 0.01,
		"sheet %.2f, body %.2f" % [roster.effective_damage(hero),
			armed.attack_power()])

	# AND IT SHOWS UP IN A REAL HIT, not only in a getter. Two identical fights
	# from the same seed; the only difference is the sword.
	var bare_total: float = _fight(bare)
	var armed_total: float = _fight(armed)
	check("the damage number the player sees goes up",
		armed_total > bare_total * 1.2,
		"%.0f -> %.0f damage over 10 swings" % [bare_total, armed_total])

	# The other half: gear has to protect as well as hurt.
	var hit_bare: float = _incoming(bare)
	var hit_armed: float = _incoming(armed)
	check("and incoming damage goes down", hit_armed < hit_bare,
		"%.1f -> %.1f over 10 hits" % [hit_bare, hit_armed])


## Ten swings at a dummy that cannot dodge, returning the total dealt.
func _fight(attacker: Combatant) -> float:
	var total: float = 0.0
	for i in range(10):
		var dummy: Combatant = Combatant.make("Dummy", Combatant.Team.ENEMY, 20,
			Stats.make(0.0, 0.0, 0.0, 400.0), HeroClass.School.MELEE,
			0.0, 0.0, 606)
		total += float(attacker.strike(dummy, 1.0, "proving")["damage"])
	return total


## What ten standard hits do to this champion, healed between each so it cannot
## die out from under the measurement.
##
## Ten rather than one because a champion with any agility at all can dodge:
## both bodies here share a seed and have taken the same number of rolls, so
## they dodge the SAME hits, but a single hit that happens to be dodged would
## measure nothing at all.
func _incoming(target: Combatant) -> float:
	var total: float = 0.0
	for i in range(10):
		var ogre: Combatant = Combatant.make("Ogre", Combatant.Team.ENEMY, 30,
			Stats.make(60.0, 0.0, 0.0, 30.0), HeroClass.School.MELEE,
			20.0, 0.0, 9)
		target.health = target.max_health
		ogre.strike(target, 1.0, "proving")
		total += target.max_health - target.health
	target.health = target.max_health
	return total


# ------------------------------------------------------------------------------
# 6. Save and load
# ------------------------------------------------------------------------------

## Through to_dict/from_dict rather than Roster.save(), deliberately: the save
## path is user://roster.json and a test must not overwrite the file on the
## machine it is running on.
func _it_survives_save_and_load(playable: PackedStringArray) -> void:
	print("\n=== it survives save and load ===")
	var roster: Roster = Roster.create(playable, 900)
	var hero: String = roster.owned_names()[0]
	roster.progress(hero).level = 30

	var region: int = Rng.seed_of(1234, "loot")

	# Twenty kills, rolled and banked through the static half of Loot, so this
	# section does not depend on the scene tree at all.
	for i in range(20):
		var d: Loot.Drop = Loot.roll(region, i, 28, Campaign.Tier.VETERAN, 30)
		d.source = "Husk"
		Loot.bank(d, roster.stash, roster.wallet)
	check("twenty kills filled the stash", roster.stash.count() > 0,
		"%d item(s), %d gold" % [roster.stash.count(), roster.wallet.gold])

	# Wear the best of it, which is what the player would do.
	var worn: int = roster.stash.auto_equip(hero, roster.progress(hero).hero_class)
	check("the champion wore what dropped", worn > 0, "%d slot(s)" % worn)
	var before: Combatant = Combat.champion_body(roster, hero, 1, 11)
	var loose_before: int = roster.stash.count()
	var gold_before: int = roster.wallet.gold

	var reloaded: Roster = Roster.from_dict(roster.to_dict(), playable)
	check("the loose pool survived", reloaded.stash.count() == loose_before,
		"%d of %d" % [reloaded.stash.count(), loose_before])
	check("the gold survived", reloaded.wallet.gold == gold_before,
		"%d of %d" % [reloaded.wallet.gold, gold_before])
	var kept: int = 0
	for slot in Item.Slot.values():
		var mine: Item = roster.stash.equipped_in(hero, slot)
		var theirs: Item = reloaded.stash.equipped_in(hero, slot)
		if mine == null:
			continue
		if theirs != null and theirs.to_dict() == mine.to_dict():
			kept += 1
	check("every equipped piece came back identical", kept == worn,
		"%d of %d slot(s)" % [kept, worn])

	var after: Combatant = Combat.champion_body(reloaded, hero, 1, 11)
	check("the reloaded champion hits exactly as hard",
		is_equal_approx(after.attack_power(), before.attack_power()),
		"%.3f vs %.3f" % [before.attack_power(), after.attack_power()])
	check("...and mitigates exactly as much",
		is_equal_approx(after.mitigation(), before.mitigation()),
		"%.4f vs %.4f" % [before.mitigation(), after.mitigation()])

	# Ids have to stay unique across a reload, because that is what equipping
	# and selling address an item by.
	var ids: Dictionary = {}
	var dupes: int = 0
	for it in reloaded.stash.items:
		if ids.has(it.id):
			dupes += 1
		ids[it.id] = true
	check("no two items in the pool share an id", dupes == 0,
		"%d duplicate(s) over %d items" % [dupes, reloaded.stash.count()])


# ------------------------------------------------------------------------------
# 7. Gold
# ------------------------------------------------------------------------------

func _gold_flows_through_the_wallet(playable: PackedStringArray) -> void:
	print("\n=== gold flows through the wallet ===")
	var roster: Roster = Roster.create(playable, 1600)
	var start: int = roster.wallet.gold

	var drop: Loot.Drop = Loot.roll(55, 3, 18, Campaign.Tier.VETERAN, 20)
	drop.source = "Husk"
	var paid: Dictionary = Loot.bank(drop, roster.stash, roster.wallet)
	check("a kill's gold lands in the wallet",
		roster.wallet.gold == start + int(paid["gold"]),
		"+%d gold" % int(paid["gold"]))
	check("the ledger names the kill",
		String(roster.wallet.ledger[roster.wallet.ledger.size() - 1]["why"])
			== "kill:Husk")

	# And selling, which is the other half of "most drops are not upgrades".
	var sellable: Item = _plain(Item.Slot.RING, 12.0, 70007)
	roster.stash.add(sellable)
	var held: int = roster.wallet.gold
	var value: int = Shop.sell_value(sellable)
	var got: int = Shop.sell(roster, 70007)
	check("selling a drop pays its value", got == value and got > 0,
		"%d gold" % got)
	check("the wallet went up by exactly that",
		roster.wallet.gold == held + value)
	check("the item left the stash", roster.stash.find_index(70007) < 0)
	check("the ledger names the sale",
		String(roster.wallet.ledger[roster.wallet.ledger.size() - 1]["why"])
			.begins_with("sell:"))


# ------------------------------------------------------------------------------
# 8. The real scene
# ------------------------------------------------------------------------------

## Everything above tests the loot system. This tests THE GAME: scenes/Play.tscn,
## a generated region, a champion built from a real account's gear, an enemy
## registered through the encounter seam, killed, and its drop walked over.
##
## It is the only check here that would have failed for the original reason —
## that nothing in Play.gd connected `died` to anything that paid out.
func _the_real_scene(playable: PackedStringArray) -> void:
	print("\n=== the real scene ===")
	var roster: Roster = Roster.create(playable, 2600)
	var hero: String = ""
	for h in roster.owned_names():
		if HeroRig.is_animated(h):
			hero = h
			break
	if hero == "":
		check("an animated starter champion exists", false)
		return
	roster.progress(hero).level = 16
	# Worn BEFORE the region is entered, which is the case that was broken: the
	# body is assembled on entry, so gear equipped in the menus had to reach it.
	roster.stash.add(_plain(Item.Slot.WEAPON, 64.0, 80001))
	roster.stash.equip(hero, 80001)

	var packed: PackedScene = load("res://scenes/Play.tscn") as PackedScene
	if packed == null:
		check("scenes/Play.tscn loads", false)
		return
	var play: Node3D = packed.instantiate() as Node3D
	play.set("hero", hero)
	play.set("roster", roster)
	play.set("tier", Campaign.Tier.VETERAN)
	play.set("region_cells", TEST_CELLS)
	get_root().add_child(play)

	var controller: HeroController = null
	var waited: int = 0
	while waited < BUILD_FRAMES:
		await process_frame
		waited += 1
		controller = play.get("_hero") as HeroController
		if controller != null and controller.body != null:
			break
	if controller == null or controller.body == null:
		check("the region builds and the champion lands in it", false,
			"gave up after %d frames" % waited)
		_teardown(play)
		return
	print("  region built in %d frames (%d cells)" % [waited, TEST_CELLS])

	check("the champion swings the sword it equipped in the menus",
		is_equal_approx(controller.body.weapon_power, 64.0),
		"%.0f weapon power" % controller.body.weapon_power)
	check("the champion's level came from the save",
		controller.body.level == 16, "level %d" % controller.body.level)

	var field: Loot.Ground = play.get("_loot") as Loot.Ground
	check("the region has a loot ground", field != null)
	if field == null:
		_teardown(play)
		return
	check("the ground banks into the player's own account",
		field.stash == roster.stash and field.wallet == roster.wallet)
	check("the champion is what picks loot up", field.follow == controller)

	# Register an enemy exactly the way an encounter will — but OUT OF PICKUP
	# RANGE, so the drop has to be walked to. Killed within two metres, the loot
	# is vacuumed up in the same frame it lands and this check could not tell an
	# orb from a direct deposit.
	var node := Node3D.new()
	play.add_child(node)
	var here: Vector2 = controller.ground_position()
	node.global_position = Vector3(here.x + Loot.PICKUP_RADIUS * 4.0,
		controller.position.y, here.y)
	var enemy: Combatant = Combatant.make("Husk", Combatant.Team.ENEMY, 18,
		Stats.make(6.0, 0.0, 0.0, 4.0), HeroClass.School.MELEE, 0.0, 0.0, 808)
	var listeners_before: int = enemy.died.get_connections().size()
	play.call("add_enemy", enemy, node)
	check("registering an enemy adds a loot listener to `died`",
		enemy.died.get_connections().size() > listeners_before + 1,
		"%d listener(s): audio, the HUD bar, and the drop"
			% enemy.died.get_connections().size())

	# Guarantee the kill under test actually rolls an item, so this is about the
	# wiring and not about a 38% chance.
	while not Loot.roll(field.region_seed, field.kills, 18, field.tier,
			field.champion_level).has_item():
		field.kills += 1

	var stash_before: int = roster.stash.count()
	var gold_before: int = roster.wallet.gold
	enemy._take_raw(enemy.max_health * 2.0, false, "proving")
	check("the kill registered", not enemy.alive)
	await process_frame
	check("the kill dropped an orb in the region", field.orb_count() == 1,
		"%d orb(s)" % field.orb_count())
	if field.orb_count() != 1:
		_teardown(play)
		return
	check("...and it waits to be walked to",
		roster.stash.count() == stash_before and roster.wallet.gold == gold_before,
		"%d item(s), %d gold" % [roster.stash.count(), roster.wallet.gold])

	# Walk the champion onto it. Teleported rather than pathed: the walk is
	# HeroController's business and tools/playtest.gd already proves it.
	var orb: Loot.Orb = field.orbs()[0]
	controller.position = Vector3(orb.position.x, controller.position.y,
		orb.position.z)
	await process_frame
	await process_frame
	check("the champion picked it up", roster.stash.count() == stash_before + 1,
		"%d -> %d item(s)" % [stash_before, roster.stash.count()])
	check("...and was paid for the kill", roster.wallet.gold > gold_before,
		"%d -> %d gold" % [gold_before, roster.wallet.gold])
	var hud: Hud = play.get_node_or_null("Hud") as Hud
	check("...and told about it on screen",
		hud != null and hud._message.text != "",
		"'%s'" % (hud._message.text if hud != null else ""))

	# The loop, closed: equip what just dropped and the champion hits differently.
	var gained: Item = roster.stash.items[roster.stash.count() - 1]
	var gained_id: int = gained.id
	var before_power: float = controller.body.attack_power()
	roster.stash.equip(hero, gained_id)
	var after: Combatant = Combat.champion_body(roster, hero, 1, 11)
	check("what dropped can be worn, and changes the champion",
		not is_equal_approx(after.attack_power(), before_power)
			or after.max_health != controller.body.max_health,
		"%.1f -> %.1f attack, %.0f -> %.0f hp" % [before_power,
			after.attack_power(), controller.body.max_health, after.max_health])

	# AND LEAVING THE REGION KEEPS IT. Nothing writes the save while a region is
	# being played — the menus are the shell's single writer and they are not on
	# screen — so without Play flushing on the way out, an hour of loot dies with
	# a force-quit. The file is removed first so this cannot pass on a leftover.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Roster.SAVE_PATH))
	_teardown(play)
	check("leaving the region wrote the loot to the save file",
		FileAccess.file_exists(Roster.SAVE_PATH))
	var reloaded: Roster = Roster.load_or_create(playable)
	check("the dropped item is in the reloaded account",
		reloaded.stash.holds_id(gained_id), "id %d" % gained_id)
	check("...and so is the gold the kill paid",
		reloaded.wallet.gold == roster.wallet.gold,
		"%d of %d gold" % [reloaded.wallet.gold, roster.wallet.gold])

	for i in range(30):
		await process_frame


## Audio's voice pool and stream cache are STATIC, so a cue still ringing when
## quit() lands is reported as a leaked instance — tidied the same way
## tools/hudtest.gd and tools/feedbacktest.gd do it.
func _teardown(play: Node3D) -> void:
	if play != null:
		get_root().remove_child(play)
		play.free()
	# Not boot()ed here on purpose: booting one in order to free it would add a
	# node by deferred call and then free it before the call lands.
	if Audio._node != null and is_instance_valid(Audio._node):
		Audio._node.free()
	Audio._node = null
	Audio._streams.clear()
