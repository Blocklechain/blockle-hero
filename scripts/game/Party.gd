class_name Party
extends RefCounted
# ------------------------------------------------------------------------------
# THE OTHER THREE.
#
# A roster of 139 champions where exactly one of them is ever on the field is
# a collection, not a party. Partners are up to three more of the player's OWN
# champions, fighting alongside the one they are driving — the same heroes,
# the same levels, the same gear, fought by the same AI that drives the
# enemies.
#
# ------------------------------------------------------------------------------
# THE BALANCE PROBLEM, WHICH IS THE WHOLE DESIGN PROBLEM.
#
# Four champions against an encounter built for one is not "a bit easier", it
# is a different game: the player can stand behind three bodies and watch. Two
# things stop that, and both are deliberate rather than tuned:
#
#   * PARTNERS HIT SOFTER AND DIE EASIER than the champion being driven
#     (CONTRIBUTION below). Three of them at full strength would quadruple the
#     party's output; at this fraction they roughly double it, which is help
#     rather than replacement.
#
#   * THEY ARE TARGETS. Enemies pick the nearest member of the party, not the
#     player, so a partner standing in front genuinely takes the hit — and can
#     go down, which is what makes positioning matter instead of being free
#     extra damage. See Play._threat_for().
#
# A partner that goes down is down for the rest of that WAVE and gets up for
# the next one. Permanent death in a game whose whole premise is a collection
# of champions would mean the correct play is to never field the ones you
# like, and a partner that pops straight back up is not a cost at all.
# ------------------------------------------------------------------------------

const SLOTS_MAX: int = 3

## Gold per slot. The first partner is free because it is the headline of the
## feature and a feature behind a paywall of grinding is a feature most
## players never see. The other two are priced as real goals.
const SLOT_COSTS: Array[int] = [0, 9000, 32000]

## What fraction of their own strength a partner fights at. Applied to damage
## and health together, so they feel like the champion they are rather than
## like a weaker class.
##
## 0.55 is chosen, not tuned: three partners at 0.55 add 1.65 champions' worth
## of party output, so a full party of four is a little over twice as strong
## as one hero rather than four times. partytest pins that ratio, because the
## number drifting upward is how this feature quietly becomes an autoplayer.
const CONTRIBUTION: float = 0.55

## How far a partner will stray from the champion to take a fight. Beyond
## this they break off and come back — a partner that chases across the map
## is a partner that is never where the player needs it.
const LEASH: float = 14.0

## How close a partner tries to stay when there is nothing to fight. Not
## zero: three bodies standing on the player's feet hide the champion the
## player is actually driving, and on a phone that is the only thing on
## screen that matters.
const FOLLOW_GAP: float = 3.2

## Spread so they do not stack on one another on spawn or on regroup.
const FORMATION: Array[Vector2] = [
	Vector2(-2.6, -1.4), Vector2(2.6, -1.4), Vector2(0.0, -3.4),
]

## Share of a kill's experience a partner earns, per partner.
##
## THEY HAVE TO LEVEL, or the only correct party is the three champions who
## are already highest and the feature makes the roster problem worse instead
## of better. Less than the champion being driven, because the player is the
## one playing.
const XP_SHARE: float = 0.45


static func cost_of(index: int) -> int:
	if index < 0 or index >= SLOT_COSTS.size():
		return 0
	return SLOT_COSTS[index]


## Where partner [index] stands relative to a champion facing `facing`.
static func station(index: int, leader: Vector2, facing: float) -> Vector2:
	if index < 0 or index >= FORMATION.size():
		return leader
	var off: Vector2 = FORMATION[index]
	# Rotated with the champion so the formation reads as a formation rather
	# than as three heroes who happen to be north-west of you.
	return leader + off.rotated(facing)


## Scale a partner's body down to its contribution.
##
## HEALTH AND DAMAGE TOGETHER. Scaling only damage makes partners immortal
## meat shields; scaling only health makes them useless. Armour is left alone
## — it is a ratio, not a pool, and halving it would make them take wildly
## more damage at depth than the numbers above describe.
static func weaken(body: Combatant) -> void:
	if body == null:
		return
	body.max_health *= CONTRIBUTION
	body.health = body.max_health
	body.weapon_power *= CONTRIBUTION
