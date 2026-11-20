class_name Loot
extends RefCounted
# ------------------------------------------------------------------------------
# Killing a thing, and gaining a thing.
#
# Item and Stash were both written and both tested, and NOTHING connected a
# death to a drop. Every piece of gear in a save file could therefore only have
# come from the merchant — whose stock is rolled from the same table the player
# was never allowed to earn from — so "gear quietly moves your numbers"
# (Item.gd) was a premise with no acquisition path, which makes it a comment
# rather than a mechanic.
#
# This file is that path, and it keeps three rules:
#
#   * DETERMINISTIC. A drop is a pure function of (region seed, kill ordinal,
#     enemy level, tier, champion level) — the same discipline as a terrain
#     chunk (Rng.gd) and a crystal roll (Roster.open_crystal). Combat already
#     rolls its crits from a seeded stream so a fight can be replayed from a
#     save; loot that rerolled on reload would undo that, and would also be a
#     savescum exploit the moment the stash screen exists.
#   * GATED BY TIER AND BY LEVEL. Rarity comes from Campaign's table, capped by
#     the tier; item level is capped just above the champion's own. A Normal-tier
#     kill cannot hand out endgame gear, which would end the campaign in its
#     first ten minutes.
#   * NOTHING IS SILENTLY DESTROYED. A full stash REFUSES the item (Stash.add's
#     contract) and the orb stays on the ground, so the player is told to make
#     room instead of watching a legendary evaporate.
#
# The drop is deliberately a two-step: a visible orb in the world, then a
# pickup. A kill that posts straight into the stash is invisible — the player
# cannot tell a good kill from a bad one, which is the entire feedback loop an
# ARPG runs on.
# ------------------------------------------------------------------------------

## How often a kill drops gear AT ALL. Deliberately well under half: the stash
## caps at 300 (Stash.CAPACITY) and a guaranteed drop fills it inside one
## region, at which point every kill is an inventory chore instead of a reward.
const ITEM_CHANCE: float = 0.38

## Gold on every kill, so no fight is literally worthless — gold is the floor
## under the loot table (see Shop.gd) and the reason a failed item roll still
## pays something.
const GOLD_BASE: float = 3.0
const GOLD_PER_LEVEL: float = 1.7
## Fraction either side of the average, so two kills of the same thing are not
## the same number twice.
const GOLD_SPREAD: float = 0.45

## How far an item may out-level the champion wearing it. Gear that is unusable
## for twenty levels reads as a punishment for killing something hard, and gear
## that can never out-level you removes the "save this for later" decision the
## shared stash exists to create.
const LEVEL_HEADROOM: int = 3

## The best rarity each tier may drop.
##
## Only the first tier is actually capped, and that is the point: legendaries
## are the reward for having cleared the campaign once, not a lucky roll in the
## tutorial act. Without this, Campaign.roll_rarity's 0.6% legendary chance
## applies from the first skeleton, and one of them makes the next forty levels
## trivial, because a legendary's budget scales with ITEM level and a level-16
## legendary already beats a level-30 common.
const TIER_RARITY_CEILING: Dictionary = {
	Campaign.Tier.NORMAL: Item.Rarity.EPIC,
	Campaign.Tier.VETERAN: Item.Rarity.LEGENDARY,
	Campaign.Tier.MERCILESS: Item.Rarity.LEGENDARY,
	Campaign.Tier.ETERNAL: Item.Rarity.LEGENDARY,
}

## Where kill drops sit in Item.roll's id space. Item.roll is keyed on
## (seed, roll_id) and the region seed is shared with the merchant's stock
## (Shop.offers uses roll_id + 90000) and with region-clear loot
## (Campaign.roll_region_loot uses index * 1000 + tier * 100 + i), so without a
## band of its own the first kill in a region would drop the exact item already
## sitting in the merchant's window.
const ITEM_ROLL_BASE: int = 400000

## How close the champion has to get to pick something up, in metres.
##
## AUTO-PICKUP, NOT A TAP. The orb is about 30 cm across in a game played with a
## thumb on a dragged camera; asking the player to hit it would be a precision
## task in the one moment they are being swarmed. Walking over your loot is also
## the genre's oldest verb.
const PICKUP_RADIUS: float = 2.0

## How long a refused pickup waits before trying again, so a champion standing
## on an orb with a full stash is told once rather than sixty times a second.
const REFUSE_RETRY: float = 4.0

## Gold's own colour, kept here rather than borrowed from HeroTheme: this is a
## world-space object built by scripts/game, and the UI theme is not a
## dependency this layer should take on.
const GOLD_COLOUR: Color = Color("ffcf4a")


# ------------------------------------------------------------------------------
# Rolling
# ------------------------------------------------------------------------------

## One kill's reward: at most one piece of gear, plus gold.
class Drop extends RefCounted:
	var item: Item = null
	var gold: int = 0
	## The kill ordinal this was rolled from. Kept so a drop can be re-derived
	## from a save, and so a bug report can name it.
	var roll_id: int = 0
	## What died, for the wallet ledger and the pickup line.
	var source: String = ""


	func has_item() -> bool:
		return item != null


	func describe() -> String:
		var parts: PackedStringArray = []
		if item != null:
			parts.append("%s [%s]" % [item.item_name, item.rarity_name()])
		if gold > 0:
			parts.append("%d gold" % gold)
		return "  ".join(parts)


## Roll what a kill leaves behind.
##
## `kill_index` is the kill's ordinal within the region and IS the roll stream,
## so the n-th kill of a region always drops the same thing. It is the ordinal
## rather than, say, a position because position is a float the player's input
## decides and ordinals replay exactly.
static func roll(region_seed: int, kill_index: int, enemy_level: int, tier: int,
		champion_level: int) -> Drop:
	var d := Drop.new()
	d.roll_id = kill_index
	d.gold = gold_for(region_seed, kill_index, enemy_level, tier)

	if Rng.unit2(region_seed, kill_index, 8831) >= ITEM_CHANCE:
		return d

	var ilvl: int = item_level(enemy_level, champion_level)
	var rarity: int = mini(Campaign.roll_rarity(region_seed, kill_index, tier),
		rarity_ceiling(tier))
	d.item = Item.roll(region_seed, ITEM_ROLL_BASE + kill_index, ilvl, rarity)
	return d


static func rarity_ceiling(tier: int) -> int:
	return int(TIER_RARITY_CEILING.get(tier, Item.Rarity.LEGENDARY))


## The level a kill's drop is rolled at: the enemy's own level, but never more
## than LEVEL_HEADROOM above the champion's.
##
## The cap is the champion's level and not the tier's, because the tier is an
## account-wide unlock (Campaign.gd) — a level-10 hero taken into Merciless by a
## player who cleared it on someone else would otherwise fill the shared stash
## with gear nobody can use yet.
static func item_level(enemy_level: int, champion_level: int) -> int:
	var ceiling: int = maxi(champion_level, 1) + LEVEL_HEADROOM
	return clampi(mini(maxi(enemy_level, 1), ceiling), 1, HeroProgress.MAX_LEVEL)


## Gold for one kill. Scaled on the same per-tier curve as experience, so one
## tuning pass moves both and the two cannot drift apart.
static func gold_for(region_seed: int, kill_index: int, enemy_level: int,
		tier: int) -> int:
	var base: float = (GOLD_BASE + float(maxi(enemy_level, 1)) * GOLD_PER_LEVEL) \
		* float(Campaign.TIER_XP.get(tier, 1.0))
	var swing: float = (Rng.unit2(region_seed, kill_index, 8837) * 2.0 - 1.0) \
		* GOLD_SPREAD
	return maxi(int(round(base * (1.0 + swing))), 1)


# ------------------------------------------------------------------------------
# Banking it
# ------------------------------------------------------------------------------

## Move a drop into the player's account.
##
## Returns { "gold": int paid, "item": bool taken, "text": String } — the text is
## one line for the HUD, and the two flags are what let the caller leave a
## refused orb on the ground.
##
## GOLD AND THE ITEM ARE SEPARATE. Gold has no capacity and is always taken; the
## item can be refused. Paying the gold and dropping the item is the only
## division that never loses something the player earned.
static func bank(drop: Drop, stash: Stash, wallet: Wallet) -> Dictionary:
	var out: Dictionary = {"gold": 0, "item": false, "text": ""}
	if drop == null:
		return out

	if drop.gold > 0 and wallet != null:
		wallet.grant(Wallet.Kind.GOLD, drop.gold,
			"kill:%s" % (drop.source if drop.source != "" else "unknown"))
		out["gold"] = drop.gold
		# Zeroed the moment it is paid. A refused item leaves the orb on the
		# ground, so this same drop WILL be banked again when the player comes
		# back with room — and a second payout for one kill is the kind of bug
		# that turns an economy into a faucet. Same rule as Store.redeem().
		drop.gold = 0

	var parts: PackedStringArray = []
	if drop.item != null and stash != null:
		if stash.is_full():
			parts.append("Stash full — %s left where it fell" % drop.item.item_name)
		else:
			_make_id_unique(drop.item, stash)
			out["item"] = stash.add(drop.item)
			if bool(out["item"]):
				parts.append("%s [%s]" % [drop.item.item_name,
					drop.item.rarity_name()])
	if int(out["gold"]) > 0:
		parts.append("+%d gold" % int(out["gold"]))
	out["text"] = "  ".join(parts)
	return out


## Item ids come out of a 31-bit hash (Item.roll), so two drops in a long
## session can collide — and the stash looks items up BY id (Stash.find_index),
## which is how both equipping and selling identify a piece. A duplicate would
## quietly sell or equip the wrong one, which is unrecoverable for the player.
## Re-salting on the way in is cheaper than making every caller carry an index.
static func _make_id_unique(it: Item, stash: Stash) -> void:
	var guard: int = 0
	while stash.holds_id(it.id) and guard < 64:
		it.id = Rng.mix(it.id + 0x9e3779b1)
		guard += 1


# ------------------------------------------------------------------------------
# The orb
# ------------------------------------------------------------------------------

## A drop, visible in the world.
##
## Built from primitives and emissive material rather than art, like everything
## else in this project: a gem in the rarity colour, a beam above it so it can be
## seen over a ridge, and a light on the two rarities worth running back for. The
## rarity colours are Item.RARITY_COLOURS, so the orb on the ground, the row in
## the stash and the merchant's price tag all say the same thing.
class Orb extends Node3D:
	## Metres of bob, and radians per second of spin. Motion is what separates a
	## dropped item from a pebble in a procedurally scattered world.
	const BOB: float = 0.16
	const BOB_RATE: float = 2.3
	const SPIN: float = 1.9
	const GEM_R: float = 0.17
	const BEAM_H: float = 2.4

	var drop: Loot.Drop = null
	## Seconds before a refused pickup is attempted again.
	var retry_in: float = 0.0

	var _rest_y: float = 0.0
	var _t: float = 0.0


	static func make(d: Loot.Drop, at: Vector3) -> Orb:
		var orb := Orb.new()
		orb.drop = d
		# Lifted clear of the ground so the gem is never half-buried in a slope;
		# the terrain is sampled per-frame elsewhere but an orb does not move, so
		# the drop point is sampled once by the caller.
		orb.position = at + Vector3(0.0, GEM_R + 0.35, 0.0)
		orb._rest_y = orb.position.y

		var colour: Color = d.item.colour() if d.has_item() else Loot.GOLD_COLOUR
		var scale_k: float = 1.0 if d.has_item() else 0.62

		var gem := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = GEM_R * scale_k
		mesh.height = GEM_R * 2.6 * scale_k
		# Five segments and three rings: a faceted crystal rather than a ball,
		# which is both cheaper and reads as treasure at this size.
		mesh.radial_segments = 5
		mesh.rings = 3
		gem.mesh = mesh
		gem.material_override = _glow(colour, 1.6)
		gem.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		orb.add_child(gem)

		var beam := MeshInstance3D.new()
		var tube := CylinderMesh.new()
		tube.top_radius = 0.015
		tube.bottom_radius = 0.075 * scale_k
		tube.height = BEAM_H * (1.0 if d.has_item() else 0.55)
		tube.radial_segments = 8
		tube.rings = 1
		beam.mesh = tube
		beam.position = Vector3(0.0, tube.height * 0.5, 0.0)
		beam.material_override = _beam_material(colour)
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		orb.add_child(beam)

		# A light only on the rarities worth crossing a region for. One omni per
		# orb would be a real cost in a cleared arena; one per epic is nothing,
		# and it is exactly the signal the player should see from a distance.
		if d.has_item() and d.item.rarity >= Item.Rarity.EPIC:
			var lamp := OmniLight3D.new()
			lamp.light_color = colour
			lamp.light_energy = 1.5
			lamp.omni_range = 5.5
			lamp.shadow_enabled = false
			orb.add_child(lamp)
		return orb


	static func _glow(colour: Color, energy: float) -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.albedo_color = colour
		m.emission_enabled = true
		m.emission = colour
		m.emission_energy_multiplier = energy
		m.metallic = 0.3
		m.roughness = 0.25
		return m


	static func _beam_material(colour: Color) -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(colour.r, colour.g, colour.b, 0.30)
		# Additive, so the beam brightens the sky behind it instead of greying
		# it, and no depth write so two orbs behind each other do not clip.
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.no_depth_test = false
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		return m


	func _process(delta: float) -> void:
		_t += delta
		retry_in = maxf(retry_in - delta, 0.0)
		position.y = _rest_y + sin(_t * BOB_RATE) * BOB
		rotate_y(SPIN * delta)


	## Horizontal distance to a point, in metres. Horizontal because the orb
	## bobs and the champion stands on a heightfield: a spherical test would make
	## pickup depend on the slope the kill happened on.
	func flat_distance_to(p: Vector3) -> float:
		return Vector2(position.x - p.x, position.z - p.z).length()


# ------------------------------------------------------------------------------
# What is lying on the ground
# ------------------------------------------------------------------------------

## Everything lying on the ground in one region, and the only thing that moves
## loot from a corpse into the player's account.
##
## A node, because orbs are nodes and because pickup is a per-frame proximity
## test; everything it DECIDES is still in the static functions above, so the
## rules can be tested without a scene (tools/loottest.gd does both).
##
## Named `Ground` rather than the obvious `Field` because scripts/world/Field.gd
## already owns that global name, and an inner class that shadows one does not
## compile.
class Ground extends Node3D:
	## A drop has appeared in the world.
	signal dropped(drop: Loot.Drop, at: Vector3)
	## A drop has been taken. `text` is one line for the HUD.
	signal collected(text: String, drop: Loot.Drop)
	## A drop could not be taken — a full stash. The orb is still out there.
	signal refused(text: String)

	## The region's loot stream. Derive it from the world seed, not the campaign
	## seed, so one region's drops are reproducible on their own.
	var region_seed: int = 0
	var tier: int = Campaign.Tier.NORMAL
	## Caps item level; kept up to date by whoever owns the champion.
	var champion_level: int = 1

	## Where loot goes. Both may be null — a region played with no account
	## behind it (tools/, the editor) still drops and still shows orbs.
	var stash: Stash = null
	var wallet: Wallet = null

	## Who picks things up. Null until the champion exists.
	var follow: Node3D = null

	## Kills so far, which IS the roll stream. Not reset mid-region.
	var kills: int = 0

	var _orbs: Array[Orb] = []


	## Roll and spawn what a dead combatant leaves behind. Returns the drop so a
	## caller can log it; the orb is already in the world.
	func on_kill(body: Combatant, at: Vector3) -> Loot.Drop:
		var level: int = body.level if body != null else 1
		var d: Loot.Drop = Loot.roll(region_seed, kills, level, tier,
			champion_level)
		d.source = body.display_name if body != null else ""
		kills += 1
		if not d.has_item() and d.gold <= 0:
			return d
		var orb: Orb = Orb.make(d, at)
		add_child(orb)
		_orbs.append(orb)
		dropped.emit(d, at)
		return d


	func orb_count() -> int:
		_prune()
		return _orbs.size()


	func orbs() -> Array[Orb]:
		_prune()
		return _orbs


	## Take one orb's drop. Leaves the orb alone and reports if the stash refused
	## the item — see Loot.bank().
	func collect(orb: Orb) -> Dictionary:
		var out: Dictionary = Loot.bank(orb.drop, stash, wallet)
		var took_item: bool = bool(out["item"])
		if orb.drop.has_item() and not took_item:
			orb.retry_in = Loot.REFUSE_RETRY
			refused.emit(String(out["text"]))
			return out
		collected.emit(String(out["text"]), orb.drop)
		_orbs.erase(orb)
		orb.queue_free()
		return out


	func _process(_delta: float) -> void:
		if follow == null or not is_instance_valid(follow):
			return
		var here: Vector3 = follow.global_position
		# Backwards: collect() removes from the array.
		for i in range(_orbs.size() - 1, -1, -1):
			var orb: Orb = _orbs[i]
			if not is_instance_valid(orb):
				_orbs.remove_at(i)
				continue
			if orb.retry_in > 0.0:
				continue
			if orb.flat_distance_to(here) <= Loot.PICKUP_RADIUS:
				collect(orb)


	func _prune() -> void:
		for i in range(_orbs.size() - 1, -1, -1):
			if not is_instance_valid(_orbs[i]):
				_orbs.remove_at(i)
