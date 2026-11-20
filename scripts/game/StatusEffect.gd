class_name StatusEffect
extends RefCounted
# ------------------------------------------------------------------------------
# Timed effects on a combatant: stuns, slows, shields, damage over time.
#
# THE STUN RULE, because it is a design decision rather than a detail:
# a stun does NOT freeze you. It forces you down to a walk and locks out your
# abilities. You keep moving, you keep steering, you simply cannot run and
# cannot fight back for a moment.
#
# Being unable to move at all is the least pleasant thing an action game can do
# to a player on a touchscreen — they tap, nothing happens, and it reads as the
# game being broken rather than the enemy being strong. Forcing a walk keeps
# them in control of something while still being a real, legible punishment:
# the run animation drops to a walk, and you can see you are in trouble.
#
# It also lines up with what the rigs actually have. Every hero is being
# animated with walk AND run, so "stunned" has a genuine animation to play
# instead of needing a bespoke stagger clip for 200 models.
# ------------------------------------------------------------------------------

enum Kind {
	STUN,        # forced to walk, abilities locked out
	SLOW,        # movement multiplier
	HASTE,       # movement and attack-speed multiplier
	SHIELD,      # absorbs damage before health
	BURN,        # damage over time
	WEAKEN,      # outgoing damage multiplier
}

const KIND_NAMES: Dictionary = {
	Kind.STUN: "Stunned", Kind.SLOW: "Slowed", Kind.HASTE: "Hastened",
	Kind.SHIELD: "Shielded", Kind.BURN: "Burning", Kind.WEAKEN: "Weakened",
}

## How much a stun slows you, on top of being forced out of a run. Not zero —
## see the note above.
const STUN_SPEED_MULT: float = 0.55

var kind: int = Kind.STUN
var remaining: float = 0.0
var magnitude: float = 0.0        # meaning depends on kind
var source: String = ""

## For DOTs: how often it ticks, and time until the next tick.
var tick_every: float = 0.5
var tick_in: float = 0.5


static func make(kind: int, duration: float, magnitude: float = 0.0,
		source: String = "") -> StatusEffect:
	var e := StatusEffect.new()
	e.kind = kind
	e.remaining = duration
	e.magnitude = magnitude
	e.source = source
	return e


func is_expired() -> bool:
	# A shield expires when it is used up, not only when it times out.
	if kind == Kind.SHIELD:
		return remaining <= 0.0 or magnitude <= 0.0
	return remaining <= 0.0


func name_of() -> String:
	return String(KIND_NAMES.get(kind, "?"))
