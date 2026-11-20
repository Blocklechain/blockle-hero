class_name Ability
extends RefCounted
# ------------------------------------------------------------------------------
# The four things a champion can do: a basic attack plus three abilities.
#
# EXACTLY THREE abilities per champion, because that is what the models are
# being rigged with — ability_1, ability_2, ability_3 alongside walk and run.
# The content is built to the rig rather than the rig being asked to grow, so
# nothing here can ask for an animation that will not exist.
#
# Each class gets the same SHAPE of kit so the controls are learnable across 200
# champions, and different CONTENT so the classes feel distinct:
#
#   slot 1  the damage ability     — the one you press on cooldown
#   slot 2  the control ability    — stuns or slows; sets up slot 1
#   slot 3  the self ability       — heal, shield or burst of speed
#
# A player who learns one Fighter knows roughly what any Fighter does, which
# matters enormously when the roster is this large.
# ------------------------------------------------------------------------------

## How an ability picks what it hits.
enum Shape {
	SINGLE,     # nearest target in range
	ARC,        # cone in front, `arc_degrees` wide
	CIRCLE,     # everything around the caster
	SELF,       # no target
}

var id: String = ""
var title: String = ""
var slot: int = 0                  # 0 basic attack, 1..3 abilities
var shape: int = Shape.SINGLE
var range_m: float = 2.2
var arc_degrees: float = 90.0
var cooldown: float = 0.0
var damage_mult: float = 1.0
var max_targets: int = 1

## Status applied to everything hit. -1 for none.
var applies: int = -1
var applies_duration: float = 0.0
var applies_magnitude: float = 0.0

## Status applied to the CASTER (shields, haste). -1 for none.
var self_applies: int = -1
var self_duration: float = 0.0
var self_magnitude: float = 0.0

## Fraction of the caster's max health restored.
var heal_fraction: float = 0.0

## HOW THE CASTER MOVES WHEN THIS IS USED.
##
## THE RIG PROVIDES EXACTLY EIGHT CLIPS, so a charge or a blink can never be a
## fourth ability with its own animation — it has to RIDE one of the three that
## exist. A charge plays ability_2 and travels during it; a blink plays
## ability_3 and the champion is simply elsewhere when it ends. The clip is
## unchanged; what changed is where the body is by the time it finishes.
enum Move {
	NONE,
	CHARGE,    # travel to the target, arriving as the clip lands
	BLINK,     # vanish and reappear, instantly, at the end of the cast
	RETREAT,   # the same but backwards, away from what you are facing
}

var move_kind: int = Move.NONE
## Metres. For CHARGE this is the furthest it will close; for BLINK/RETREAT the
## distance travelled.
var move_distance: float = 0.0

var description: String = ""


static func _make(id: String, title: String, slot: int) -> Ability:
	var a := Ability.new()
	a.id = id
	a.title = title
	a.slot = slot
	return a


## Which rig animation this ability plays. Slot 0 is the attack clip; 1-3 map
## straight onto the three rigged ability clips.
func anim_state() -> int:
	match slot:
		1: return HeroRig.State.ABILITY_1
		2: return HeroRig.State.ABILITY_2
		3: return HeroRig.State.ABILITY_3
		_: return HeroRig.State.ATTACK


# ------------------------------------------------------------------------------
# The kits
# ------------------------------------------------------------------------------

static func basic_attack(cls: int) -> Ability:
	var a := _make("basic", "Attack", 0)
	match cls:
		HeroClass.Kind.RANGER:
			a.range_m = 11.0
			a.cooldown = 0.55
		HeroClass.Kind.MAGE:
			a.range_m = 9.0
			a.cooldown = 0.75
		_:
			a.range_m = 2.4
			a.cooldown = 0.65
	a.damage_mult = 1.0
	a.description = "A basic strike."
	return a


## A champion's three abilities.
##
## Fighters and Rangers share a class kit — their identity is their role, and a
## player who picks up any Fighter should already know what the buttons do.
##
## MAGES DO NOT. Every mage gets its own spellbook, composed per hero from an
## element and a delivery form (see MageSpells.gd). The slot grammar still
## holds — damage, control, self — so the controls stay learnable even though
## no two mages cast the same thing.
static func for_hero(hero: String, cls: int) -> Array[Ability]:
	match cls:
		HeroClass.Kind.FIGHTER: return _fighter()
		HeroClass.Kind.RANGER: return _ranger()
		_: return MageSpells.for_hero(hero)


## Kept for callers that have no hero in hand (previews, tests). A mage asked
## for generically gets a representative book, not a shared one.
static func for_class(cls: int) -> Array[Ability]:
	return for_hero("", cls)


static func _fighter() -> Array[Ability]:
	var cleave := _make("cleave", "Cleave", 1)
	cleave.shape = Shape.ARC
	cleave.range_m = 3.4
	cleave.arc_degrees = 120.0
	cleave.max_targets = 5
	cleave.cooldown = 4.0
	cleave.damage_mult = 1.85
	cleave.description = "A wide swing. Hits everything in front."

	var slam := _make("shield_slam", "Shield Slam", 2)
	# A CHARGE, not a standing shove. The fighter's problem is reaching a ranger
	# who is kiting them; a stun they can only land in melee solves nothing at
	# the range the stun is needed. Travelling to the target and arriving with
	# the blow is the same button doing both jobs, on the clip it already had.
	slam.move_kind = Move.CHARGE
	slam.move_distance = 9.0
	slam.range_m = 9.0
	slam.shape = Shape.ARC
	slam.range_m = 2.8
	slam.arc_degrees = 90.0
	slam.max_targets = 3
	slam.cooldown = 9.0
	slam.damage_mult = 0.9
	slam.applies = StatusEffect.Kind.STUN
	slam.applies_duration = 2.0
	slam.description = "Staggers enemies — they can only walk, and cannot strike back."

	var rally := _make("rally", "Rally", 3)
	rally.shape = Shape.SELF
	rally.cooldown = 16.0
	rally.damage_mult = 0.0
	rally.heal_fraction = 0.25
	rally.self_applies = StatusEffect.Kind.SHIELD
	rally.self_duration = 8.0
	rally.self_magnitude = 0.0      # filled from max health at cast time
	rally.description = "Recover, and raise a shield."

	return [cleave, slam, rally] as Array[Ability]


static func _ranger() -> Array[Ability]:
	var volley := _make("volley", "Volley", 1)
	volley.shape = Shape.ARC
	volley.range_m = 12.0
	volley.arc_degrees = 45.0
	volley.max_targets = 4
	volley.cooldown = 5.0
	volley.damage_mult = 1.55
	volley.description = "A spread of arrows down a narrow cone."

	var pin := _make("pin", "Pinning Shot", 2)
	pin.shape = Shape.SINGLE
	pin.range_m = 13.0
	pin.cooldown = 8.0
	pin.damage_mult = 1.2
	pin.applies = StatusEffect.Kind.STUN
	pin.applies_duration = 1.6
	pin.description = "Pins one target in place — it can only walk."

	var evade := _make("evade", "Evade", 3)
	evade.shape = Shape.SELF
	evade.cooldown = 12.0
	evade.damage_mult = 0.0
	# A BACKSTEP, then the speed. Haste alone asks a ranger already in melee to
	# outrun the thing hitting them, which they lose; the distance has to come
	# first and the speed is what keeps it.
	evade.move_kind = Move.RETREAT
	evade.move_distance = 6.5
	evade.self_applies = StatusEffect.Kind.HASTE
	evade.self_duration = 5.0
	evade.self_magnitude = 0.55
	evade.description = "Break away at speed."

	return [volley, pin, evade] as Array[Ability]


static func _mage() -> Array[Ability]:
	var bolt := _make("firebolt", "Firebolt", 1)
	bolt.shape = Shape.SINGLE
	bolt.range_m = 11.0
	bolt.cooldown = 3.5
	bolt.damage_mult = 2.1
	bolt.applies = StatusEffect.Kind.BURN
	bolt.applies_duration = 4.0
	bolt.applies_magnitude = 0.0    # filled from caster power at cast time
	bolt.description = "A searing bolt that keeps burning."

	var nova := _make("frost_nova", "Frost Nova", 2)
	nova.shape = Shape.CIRCLE
	nova.range_m = 5.5
	nova.max_targets = 8
	nova.cooldown = 10.0
	nova.damage_mult = 0.8
	nova.applies = StatusEffect.Kind.STUN
	nova.applies_duration = 2.2
	nova.description = "Freezes everything nearby — they can only walk."

	var ward := _make("ward", "Ward", 3)
	ward.shape = Shape.SELF
	ward.cooldown = 14.0
	ward.damage_mult = 0.0
	ward.self_applies = StatusEffect.Kind.SHIELD
	ward.self_duration = 10.0
	ward.self_magnitude = 0.0
	ward.description = "A barrier that absorbs damage."

	return [bolt, nova, ward] as Array[Ability]


# ------------------------------------------------------------------------------

## Is `target_pos` a legal target for this ability cast from `origin` facing
## `facing` (radians, Godot Y-rotation convention)?
func covers(origin: Vector2, facing: float, target_pos: Vector2) -> bool:
	var to: Vector2 = target_pos - origin
	var dist: float = to.length()
	if dist > range_m:
		return false
	match shape:
		Shape.CIRCLE, Shape.SELF:
			return true
		Shape.ARC:
			if dist < 0.0001:
				return true
			# Facing follows the controller's convention: atan2(x, y).
			var face := Vector2(sin(facing), cos(facing))
			var cosang: float = face.dot(to / dist)
			return cosang >= cos(deg_to_rad(arc_degrees * 0.5))
		_:
			return true


func describe() -> String:
	var bits: PackedStringArray = []
	if damage_mult > 0.0:
		bits.append("%.0f%% dmg" % (damage_mult * 100.0))
	if applies >= 0:
		bits.append("%s %.1fs" % [
			String(StatusEffect.KIND_NAMES[applies]), applies_duration])
	if heal_fraction > 0.0:
		bits.append("heal %.0f%%" % (heal_fraction * 100.0))
	if self_applies >= 0:
		bits.append("self %s" % String(StatusEffect.KIND_NAMES[self_applies]))
	return "%-14s cd %4.1fs  %s" % [title, cooldown, ", ".join(bits)]
