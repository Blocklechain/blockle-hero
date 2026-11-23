class_name Elite
extends RefCounted
# ------------------------------------------------------------------------------
# What makes an elite worth noticing.
#
# Elites already existed — Encounter marks roughly a tenth of a pack as one and
# scales them 1.18x — and they fought EXACTLY like the trash around them. A
# slightly bigger champion with slightly more health is not an elite, it is a
# rounding error, and the player had no reason to treat it differently or even
# to spot it.
#
# Each one now carries a single trait that changes how the fight goes, and
# wears its colour so the decision is available BEFORE the first hit lands.
# One trait, not a stack of them: two modifiers on one enemy is a soup the
# player cannot read, and the whole point is readability.
#
# EVERY TRAIT RIDES AN EXISTING SYSTEM. Swift is a permanent haste, Warded is a
# shield, Brutal is the damage scale the difficulty ramp already uses, and
# Venomous is the burn that fire spells apply. Nothing here is a special case
# in the combat loop, which is why none of it can drift out of sync with it.
#
# THE SECOND PASS added five traits that change the SHAPE of a fight rather
# than its numbers, because four traits that all resolved to "same fight,
# different multiplier" still left every pack feeling identical:
#
#   Frenzied   speeds up as it bleeds, so finishing it is the dangerous part
#   Mending    puts the pack's health back, so it has to be killed first
#   Brood      bursts into two lesser copies, so the kill is not the end
#   Festering  denies the ground it died on
#   Unbowed    cannot be stunned or slowed, so a control build must improvise
#
# THREE OF THOSE NEED A HOOK IN A FILE THIS ONE DOES NOT OWN (Play.gd), and
# that is stated rather than faked: the pack heal, the death split and the
# death pool are implemented here as pure functions over Combatants, tested
# headlessly in tools/elitetest.gd, and Play calls them. Each of those three
# ALSO carries something that is live the moment it spawns — Brood is bloated
# and slow, Festering rots what it touches, Mending licks its own wounds — so
# none of them is ever an elite that does nothing at all.
#
# THE THIRD PASS added three more, all of which attack a PLAN rather than a
# health bar — the complaint they answer is that a pack was still nine flavours
# of "hit it until it falls over":
#
#   Rimeclad   the cold your whole build is made of barely marks it
#   Undying    the kill is a lie; it gets up once, angrier
#   Sundering  tears the ward or the quickening straight back off you
#
# Undying and Sundering need NOTHING from anyone: Undying rides the `damaged`
# signal, which Combatant emits BEFORE it decides the body is dead, and
# Sundering rides the on_hit call Play already makes. Rimeclad's frost
# IMMUNITY is likewise live — frost's only rider is the slow, and the slow
# slides off it — but the damage side of a resistance cannot be done from this
# file at all, because nothing in the damage path is told which element a hit
# was. That half is `incoming_multiplier()` here, under test, and a one-line
# call requested in Combat.gd rather than faked (see NEEDS_HOOK).
#
# THE FOURTH PASS had to START by finishing the third. Rimeclad, Undying and
# Sundering were in the enum, in the name table, in the colour table, in the
# blurbs — and `roll()` divides by COUNT, so a quarter of every elite pack was
# already rolling one of them. Not one of the three had an arm in `apply()`, in
# `on_hit()` or in `proven()`, and `incoming_multiplier()` did not exist at all.
# They were the project's signature bug in its purest form: three traits that
# parsed, documented themselves, marked their own ring on the ground, announced
# "it gets back up — once" to the player, and then did absolutely nothing. The
# harness it shipped with could not catch it because its trait list stopped at
# nine. tools/elitetest.gd now derives that list from the enum itself, so a
# trait cannot be declared without being tested.
#
# THEN it added two more, both of which beat a PLAN and neither of which needs
# anything from anyone — on_hit and status_applied are already wired:
#
#   Shackling  its bite drags you down, so it cannot be kited
#   Galvanic   control FEEDS it: every stun or slow comes back as speed
#
# Galvanic is deliberately not a second Unbowed. Unbowed ignores control, which
# costs a control build its slot-2 button; Galvanic PUNISHES control, which
# costs that build the fight if it keeps pressing. "Nothing happened" and "that
# made it worse" are different lessons, and the player can see which is which
# because the hoop on the ground is a different colour.
#
# THE FIFTH PASS went after the one thing fourteen traits still had in common:
# every single one of them was answered by the same plan. Hit it with your best
# thing until it falls over. Swift made that plan harder, Warded made it longer,
# Unbowed deleted a button — none of them made the plan WRONG. Three traits now
# do, one for each of the three ways this game deals damage:
#
#   Adamant    the big hit is the wrong hit — nothing takes more than a sliver
#   Gorging    the burn is the wrong burn — it swallows it and wears it
#   Emberclad  the mirror of Rimeclad, so "which element am I" is a question
#              with two answers instead of one special case
#
# ADAMANT AND GORGING NEED NOTHING FROM ANYONE. Adamant rides `damaged`, which
# Combatant emits after it has written health and before it decides the body is
# dead — the same window Undying stands in — so the blow is trimmed back to the
# cap and the kill check that follows sees the trimmed figure. Gorging rides
# `status_applied`, which only fires for a kind that is NEW, which is exactly
# when there is a fresh burn to swallow.
#
# EMBERCLAD'S DAMAGE HALF RIDES RIMECLAD'S ALREADY-REQUESTED HOOK and adds no
# new one: the two are now one mechanic with two settings (CLAD) rather than a
# pair of special cases, so incoming_multiplier() still needs exactly the one
# call in Combat.cast that it needed before. Its live half is the burn going
# SLUGGISH rather than weaker, and that is not a detail — see EMBER_BURN_SLOW
# for why dampening a magnitude cannot work from this file at all.
#
# THE SIXTH PASS FOUND THE FIFTH PASS'S THREE TRAITS IN EXACTLY THE STATE THE
# FOURTH PASS FOUND THE THIRD'S. Adamant, Gorging and Emberclad were in the enum,
# in ALL, in COUNT, in every table and in the paragraphs above describing how
# they worked — and `roll()` divides by COUNT, so a sixth of every elite pack was
# rolling one of three traits with no arm in apply(), no arm in on_hit(), no arm
# in proven(), no entry in SHAPES, no constants and, for Emberclad, no second
# setting in a CLAD table that did not exist. They marked a ring, named
# themselves in the death log, and did nothing. The previous harness caught it on
# the two assertions the fourth pass left behind for exactly this — "every trait
# that claims no hook is live from apply()+on_hit() alone" and "every applied
# trait proves itself on its own body" — and was ignored. All three are now
# implemented, and none of them needed a hook that did not already exist:
#
#   Adamant    rides `damaged` and hands back everything past its cap, so the
#              kill check that follows in _take_raw sees the trimmed figure
#   Gorging    rides `status_applied`, which only fires for a kind that is NEW,
#              which is exactly when there is a fresh burn to swallow
#   Emberclad  rides the same status hook, and shares Rimeclad's one requested
#              damage-multiplier call through CLAD
#
# IT ALSO FIXED THE ROT POOL'S CLOCK, which is the same class of bug one layer
# down. pool_tick subtracted a frame delta from two floats and compared them
# against exactly 0.0; 0.5 - 0.1*5 is 1.1e-16, not zero, so a pool DROPPED a
# bite mid-life and then landed a free one AFTER its own art had taken itself
# away — an invisible hazard hurting the player in a cleared room, which is the
# worst reading of a mechanic there is. Both clocks now settle against
# CLOCK_EPS. The three failing assertions were already in the harness.
# ------------------------------------------------------------------------------

## SELF-PRELOAD, not `Elite.x`: a script cannot reach itself by class_name, and
## the global cache this project has been bitten by four times only knows names
## the editor has rebuilt. Paths always resolve.
const Self := preload("res://scripts/game/Elite.gd")

## BY PATH for the same reason, even though MageSpells is old enough to be in
## the cache: Elite.gd is loaded on the world build thread by way of Play, and
## that is the one place where a cache miss shows up as a map that silently
## never finishes rather than as an error anyone reads.
##
## Only the Element enum is wanted — elements are DEFINED by the spell
## generator, and a second list of them here is a second list to forget to
## update.
const Spells := preload("res://scripts/game/MageSpells.gd")

enum Trait {
	NONE,
	SWIFT,
	WARDED,
	BRUTAL,
	VENOMOUS,
	FRENZIED,
	MENDING,
	BROOD,
	FESTERING,
	UNBOWED,
	RIMECLAD,
	UNDYING,
	SUNDERING,
	SHACKLING,
	GALVANIC,
	ADAMANT,
	GORGING,
	EMBERCLAD,
}

## Every trait but NONE, derived from the enum so a trait cannot be added to one
## and forgotten in the other.
##
## THIS IS WHAT THE THIRD PASS NEEDED AND DID NOT HAVE. `COUNT` was a hand-typed
## 12 while the tables and the harness still described nine, and roll() divides
## by COUNT — so three traits were being handed out that nothing had wired up.
## A list that cannot disagree with the enum is the only version of this that
## stays true, and every table below is asserted against it.
const ALL: Array = [
	Trait.SWIFT, Trait.WARDED, Trait.BRUTAL, Trait.VENOMOUS, Trait.FRENZIED,
	Trait.MENDING, Trait.BROOD, Trait.FESTERING, Trait.UNBOWED, Trait.RIMECLAD,
	Trait.UNDYING, Trait.SUNDERING, Trait.SHACKLING, Trait.GALVANIC,
	Trait.ADAMANT, Trait.GORGING, Trait.EMBERCLAD,
]

## How many rollable traits there are. A literal because a const initialiser
## cannot call a method, and cross-checked against the enum, against ALL and
## against every table in elitetest — which is what a hand-typed 12 beside a
## nine-trait harness failed to be.
const COUNT: int = 17

const NAMES: Dictionary = {
	Trait.SWIFT: "Swift",
	Trait.WARDED: "Warded",
	Trait.BRUTAL: "Brutal",
	Trait.VENOMOUS: "Venomous",
	Trait.FRENZIED: "Frenzied",
	Trait.MENDING: "Mending",
	Trait.BROOD: "Brood",
	Trait.FESTERING: "Festering",
	Trait.UNBOWED: "Unbowed",
	Trait.RIMECLAD: "Rimeclad",
	Trait.UNDYING: "Undying",
	Trait.SUNDERING: "Sundering",
	Trait.SHACKLING: "Shackling",
	Trait.GALVANIC: "Galvanic",
	Trait.ADAMANT: "Adamant",
	Trait.GORGING: "Gorging",
	Trait.EMBERCLAD: "Emberclad",
}

## One line each, for a tooltip or a death log. Written as what the PLAYER has
## to do about it, not as what the code does.
const BLURBS: Dictionary = {
	Trait.SWIFT: "Runs you down.",
	Trait.WARDED: "Break the ward before its health will move.",
	Trait.BRUTAL: "Hits far harder than its kin.",
	Trait.VENOMOUS: "Every hit leaves poison behind.",
	Trait.FRENZIED: "The more it bleeds, the faster it comes.",
	Trait.MENDING: "Mends its pack. Kill it first.",
	Trait.BROOD: "Bloated and slow — and it bursts when it dies.",
	Trait.FESTERING: "Rots what it touches, and the ground it dies on.",
	Trait.UNBOWED: "Stuns and slows slide off it.",
	Trait.RIMECLAD: "Frost barely marks its rime. Burn it instead.",
	Trait.UNDYING: "It gets back up. Once.",
	Trait.SUNDERING: "Its bite tears your wards off.",
	Trait.SHACKLING: "Its bite drags you down. You cannot walk away.",
	Trait.GALVANIC: "Hold it and it only comes faster.",
	Trait.ADAMANT: "No one blow moves it far. Keep hitting.",
	Trait.GORGING: "It swallows fire and wears it as a ward. Cut it.",
	Trait.EMBERCLAD: "Fire washes off it. Freeze it instead.",
}

## What each one looks like at a glance. Chosen to be unmistakable from each
## other at a thumb's distance on a phone, not to be pretty.
##
## NINE is past what colour alone can carry, so the mark varies in SHAPE too —
## see SHAPES. elitetest asserts every pair differs in one or the other.
##
## AT SEVENTEEN every pair is still separated by COLOUR alone (the closest two
## are Undying's parchment and Unbowed's steel, and the harness prints the
## margin), which is deliberate: shape is the second cue, not the only one,
## because the mark is read at a thumb's distance with a finger over half of it.
##
## It is also why Shackling is cold iron rather than the obvious grey — grey is
## Unbowed's — and why Galvanic is arc-yellow and not Warded's gold.
##
## The two clads are a PAIR and are coloured as one: the same mark at opposite
## ends of the same axis, because the question they ask the player is the same
## question ("what element am I?") with the answer reversed.
const COLOURS: Dictionary = {
	Trait.SWIFT: Color("5ad7ff"),      # quick, cold blue
	Trait.WARDED: Color("ffd75a"),     # gold, like a barrier
	Trait.BRUTAL: Color("ff4d3d"),     # red, like a threat
	Trait.VENOMOUS: Color("7ce04a"),   # green, like poison
	Trait.FRENZIED: Color("ff8a1f"),   # orange, like a fire getting away
	Trait.MENDING: Color("36e0c8"),    # clinical teal, the healer's colour
	Trait.BROOD: Color("a95ff0"),      # violet, wrong and fleshy
	Trait.FESTERING: Color("b8862b"),  # ochre, like rot
	Trait.UNBOWED: Color("cfd8e3"),    # pale steel, immovable
	Trait.RIMECLAD: Color("2f8fff"),   # deep glacier, not Swift's bright cyan
	Trait.UNDYING: Color("efe0a6"),    # old bone, parchment
	Trait.SUNDERING: Color("ff2fa8"),  # raw magenta, like something torn
	Trait.SHACKLING: Color("6f7d8c"),  # cold iron, the colour of a chain
	Trait.GALVANIC: Color("ffe600"),   # arc-yellow, live and painful to look at
	Trait.ADAMANT: Color("3b4a7a"),    # dark slate, the colour of a plate
	Trait.GORGING: Color("a01028"),    # clotted red, the colour of a gullet
	Trait.EMBERCLAD: Color("d93a00"),  # banked coal, Rimeclad's opposite
}

## The GEOMETRY of the mark, per trait. `rings` concentric ground rings,
## `inner`/`outer` the band of the first one, `scale` a flat multiplier on the
## footprint, `upright` adds a standing hoop.
##
## The shape is picked to MEAN something: Brood wears three rings because it is
## more than one creature, Festering's ring is the width of the pool it will
## leave, Unbowed's is a thick solid band. A player who learns one mark has
## learned the mechanic.
const SHAPES: Dictionary = {
	Trait.FRENZIED: {"rings": 2},
	Trait.MENDING: {"upright": true},
	Trait.BROOD: {"rings": 3, "inner": 0.60, "outer": 0.68},
	Trait.FESTERING: {"inner": 0.94, "outer": 1.0, "scale": 3.2},
	Trait.UNBOWED: {"inner": 0.66, "outer": 0.90},
	Trait.RIMECLAD: {"rings": 2, "inner": 0.70, "outer": 0.78},
	# A ring at the feet AND one at eye level: the second mark is the one that
	# is still there after the player thinks they have killed it.
	Trait.UNDYING: {"rings": 2, "upright": true},
	# Wide and thin — a ring that reads as cut rather than drawn.
	Trait.SUNDERING: {"inner": 0.50, "outer": 0.56, "scale": 1.40},
	# A heavy band lying wide on the ground: the shape of what it will do to
	# the player's footwork, drawn where the player's feet are going to be.
	Trait.SHACKLING: {"inner": 0.58, "outer": 0.64, "scale": 1.60},
	# Three tight rings, like charge arcing off it.
	Trait.GALVANIC: {"rings": 3, "inner": 0.72, "outer": 0.77},
	# One band so thick it reads as a plate rather than a ring: the shape of a
	# thing that does not care how hard the last hit was.
	Trait.ADAMANT: {"inner": 0.46, "outer": 0.94, "scale": 1.15},
	# A small tight ring INSIDE the footprint — a gullet, not a barrier. It is
	# deliberately the opposite of Festering's wide rim, because the two are the
	# traits most likely to be met in the same pack.
	Trait.GORGING: {"inner": 0.26, "outer": 0.50},
	# THE SAME GEOMETRY AS RIMECLAD, on purpose. The two clads ask the player the
	# same question with the answer reversed, so they wear one mark in two
	# colours: a player who has learnt the twin rings has learnt "check which
	# element this one eats", which is the whole mechanic.
	Trait.EMBERCLAD: {"rings": 2, "inner": 0.70, "outer": 0.78},
}

## How long "permanent" is. Longer than any region will last; the effect is
## cleaned up with the body rather than expiring.
const FOREVER: float = 100000.0

## Movement and attack speed a Swift elite gains.
const SWIFT_HASTE: float = 0.45
## Share of its own maximum health a Warded elite absorbs before taking any.
const WARD_FRACTION: float = 0.6
## Extra damage a Brutal elite deals.
const BRUTAL_BONUS: float = 0.5
## Burn a Venomous elite leaves on every hit.
const VENOM_SECONDS: float = 4.0
const VENOM_FRACTION: float = 0.12

## Frenzied: haste at full health, and haste at death's door. The low end is
## not zero so the trait is VISIBLE on an untouched elite — a mechanic that
## only switches on after the player has already committed is a mechanic they
## learn by dying to it.
const FRENZY_BASE: float = 0.12
const FRENZY_MAX: float = 0.90

## Mending: the bite that closes its own wounds, and the pulse that closes its
## pack's. Both as a share of its attack power, so one number works at level 1
## and at level 60.
const MEND_SELF_FRACTION: float = 0.30
const MEND_PACK_FRACTION: float = 0.55

## Brood: fat, slow, and two of it.
const BROOD_BLOAT: float = 1.5
const BROOD_SLOW: float = 0.30
const SPLIT_COUNT: int = 2
## Each spawn's share of the parent's health, damage and on-screen size.
const SPLIT_HEALTH: float = 0.35
const SPLIT_POWER: float = 0.60
const SPLIT_SIZE: float = 0.65

## Festering: the WEAKEN it smears on a victim, and the pool it dies into.
const ROT_WEAKEN: float = 0.25
const ROT_SECONDS: float = 3.0
const POOL_RADIUS: float = 3.2
const POOL_SECONDS: float = 8.0
## Pool damage per second, as a share of the dead elite's attack power.
const POOL_DPS_FRACTION: float = 0.35
## Pools tick on the same cadence a burn does. Damaging per FRAME would be the
## same total through a wall of damage numbers nobody can read.
const POOL_TICK: float = 0.5

## How close to zero a pool's clocks have to get before they ARE zero.
##
## THIS IS A BUG FIX, NOT A TOLERANCE. Both clocks are advanced by subtracting a
## frame delta and were compared against exactly 0.0: 0.5 - 0.1*5 is 1.1e-16, so
## a tick that was due landed a frame late, and 8.0 - 0.1*80 left the pool with
## a sliver of life after its own art had taken itself away — an invisible hazard
## still hurting the player in a room they had cleared. One dropped bite mid-life
## and one free bite after death, from float drift alone.
const CLOCK_EPS: float = 0.0001

## Rimeclad: what the cold does to it, and what heat does.
##
## THE FROST FIGURE IS NOT ZERO, deliberately. A mage's whole spellbook is ONE
## element (MageSpells.element_of), so a true immunity would leave a frost mage
## with nothing but their basic attack against this elite — an elite that a
## whole build cannot kill is the unfinishable map the harness exists to catch.
## A quarter says "do not bother casting", which is the decision the trait is
## for, while leaving the map clearable by anyone.
const RIME_FROST_TAKEN: float = 0.25
const RIME_FIRE_TAKEN: float = 1.60

## And whatever heat does get through eats the rime: a DOT on it bites harder
## and lasts longer.
##
## KEYED ON THE BURN, NOT ON THE ELEMENT, because a status effect does not carry
## one — so venom melts it as well as fire. That is the honest reading of the
## mechanic ("burn it"), not an element check pretending to be one: Rimeclad's
## blurb says burn, and both of this game's burns qualify.
const RIME_BURN_BONUS: float = 0.75
const RIME_BURN_LONGER: float = 1.5

## Undying: how many times it gets up, how much it gets up with, and how much
## faster it is when it does.
##
## ONE rise. Two is a health bar in disguise, and the mechanic is the surprise
## rather than the total. A third of its health, so the second fight is short —
## the player has to finish it, not fight it twice.
const UNDYING_RISES: int = 1
const UNDYING_FRACTION: float = 0.35
## It comes back FASTER, which is the only cue available from this file: there
## is no node here to re-colour, and an enemy that stands back up at the same
## speed as before reads as the health bar glitching.
const UNDYING_RAGE: float = 0.35

## Sundering: which of the player's wards its bite tears off, in order.
##
## ONE per hit, and only these two. Stripping everything would make the whole
## slot-3 self ability pointless rather than mistimed, and stripping a BURN or a
## WEAKEN would be the elite curing the player.
const SUNDER_ORDER: Array = [
	StatusEffect.Kind.SHIELD, StatusEffect.Kind.HASTE,
]

## Shackling: how hard its bite drags, and for how long.
##
## A SLOW AND NOT A STUN. A stun on every landed hit is the "tap and nothing
## happens" failure StatusEffect.gd opens by refusing, and it would also lock
## the player out of the abilities they need to answer the trait with. A slow
## leaves them in full control of a character that is simply not going to
## outwalk this one — which is the decision the trait exists to force.
##
## SHORT, and refreshed by each hit rather than stacked (Combatant.apply takes
## the greater of the two), so it lifts the moment the elite stops connecting.
## A slow that outlived the fight would read as the player's gear breaking.
const SHACKLE_SECONDS: float = 2.0
## 0.45 is a limp, not a root: move_multiplier floors a slow at 0.15, and
## anything approaching that floor is the immobilisation this is avoiding.
const SHACKLE_MAGNITUDE: float = 0.45

## Galvanic: what one piece of control is worth to it, and the ceiling.
##
## CAPPED, and the cap matters more than the step: a player with a slow on a
## short cooldown would otherwise keep feeding it until it was faster than
## anything in the game could outrun, and "I made this unwinnable by playing my
## build" is the worst lesson an elite can teach. At the cap it is roughly a
## Swift elite and a half — frightening, catchable, and it has STILL gained no
## health and no damage, so it cannot be the reason a map is unfinishable.
const GALVANIC_STEP: float = 0.22
const GALVANIC_CAP: float = 0.88

## Adamant: the most of its own health bar any ONE blow may take.
##
## A FRACTION OF max_health, NOT A FLAT FIGURE, so the trait says the same thing
## at level 1 and level 60: "the big hit is the wrong hit". A flat cap would be
## everything early and nothing later.
##
## 0.12 IS THE KILLABILITY GUARANTEE AS WELL AS THE TUNING. Any positive cap
## means ceil(1/cap) landed blows kill it no matter how large or small each one
## was — nine here — so there is no value of this constant that produces an
## immortal elite, only slower ones. Picked so the fight is noticeably longer
## than a normal elite's without being a wall the player walks away from: the
## harness asserts no trait costs more than 3x its health bar, and this one
## costs 1/0.12 x the attacker's chosen bite.
const ADAMANT_CAP: float = 0.12

## Gorging: what a swallowed burn is worth to it as a ward, and the ceiling.
##
## STRICTLY LESS THAN THE BURN IT ATE, and that is a structural guarantee rather
## than a tuning choice: the ward is a share of the damage the player elected to
## pour in as a DOT, so no amount of burning can buy the elite more health than
## the burning would have cost it. At 1.0 or above, a venom or fire mage could
## ward it faster than their own spells landed, which is the unfinishable map the
## harness exists to catch.
##
## Every spell in this game deals DIRECT damage as well as its rider
## (MageSpells.spellbook), so the direct half always lands and the elite always
## dies — Gorging deletes the DOT, it does not delete the mage.
const GORGE_WARD: float = 0.35
## And the ward can never be worth more of its bar than this however big the
## burn was, so a long high-magnitude DOT cannot hand it a second health bar.
const GORGE_WARD_CAP: float = 0.30

## Emberclad: the mirror of Rimeclad. Same arithmetic, opposite elements.
const EMBER_FIRE_TAKEN: float = 0.25
const EMBER_FROST_TAKEN: float = 1.60

## WHY THE BURN IS SLOWED RATHER THAN WEAKENED. Dampening a magnitude cannot work
## from this file: Combatant.apply refreshes a repeated kind to the GREATER
## magnitude and emits NOTHING, so the first re-cast would restore the full
## figure and never re-enter the handler — a trait that works once and then
## silently stops. Rimeclad gets away with mutating a magnitude only because it
## mutates it UPWARDS, which maxf keeps.
##
## tick_every is the one field on a StatusEffect that apply() never touches, so
## stretching the cadence survives every refresh: half as many ticks over the
## same duration is half the burn, honestly, and permanently.
const EMBER_BURN_SLOW: float = 2.0

## And the cold it is weak to bites deeper and holds longer — the mirror of a
## burn eating Rimeclad's rime. Upwards, so a refresh keeps it.
const EMBER_SLOW_BONUS: float = 0.50
const EMBER_SLOW_LONGER: float = 1.5
## Not past this, because move_multiplier floors a slow at 0.15 and an enemy
## nailed to the floor reads as the pathing having hung rather than as frost
## working unusually well.
const EMBER_SLOW_MAX: float = 0.80

## The two clads as ONE mechanic with two settings. Which element barely marks
## it, which one it cannot stand, and what each costs.
##
## The RIDER each element carries is not duplicated here: it is read from
## MageSpells.ELEMENT_STATUS at the point of use, because that table is where an
## element's mechanical identity is defined and a second copy of it is a second
## copy to forget to update.
const CLAD: Dictionary = {
	Trait.RIMECLAD: {
		"resists": Spells.Element.FROST, "taken": RIME_FROST_TAKEN,
		"weak_to": Spells.Element.FIRE, "weak_taken": RIME_FIRE_TAKEN,
	},
	Trait.EMBERCLAD: {
		"resists": Spells.Element.FIRE, "taken": EMBER_FIRE_TAKEN,
		"weak_to": Spells.Element.FROST, "weak_taken": EMBER_FROST_TAKEN,
	},
}

## Which traits need a call from a file this one does not own before their
## headline effect can happen. Published rather than commented so a harness can
## assert on it.
const NEEDS_HOOK: Dictionary = {
	Trait.MENDING: "Elite.mend() from the brain tick",
	Trait.BROOD: "Elite.split() from the enemy-death handler",
	Trait.FESTERING: "Elite.death_pool()/pool_tick() from death and _process",
	Trait.RIMECLAD: "Elite.incoming_multiplier() from Combat.cast's damage "
		+ "multiplier — nothing in the damage path is told the element",
	# THE SAME ONE CALL, not a second one. Listed because the list is keyed by
	# TRAIT and the harness reads it to decide which traits are allowed to be
	# less than whole — leaving Emberclad out would have claimed its damage half
	# was live, which is the lie this table exists to prevent.
	Trait.EMBERCLAD: "Elite.incoming_multiplier() from Combat.cast — the same "
		+ "one call Rimeclad needs, through CLAD",
}


# ------------------------------------------------------------------------------
# Which elite is which
# ------------------------------------------------------------------------------

## Trait by body, so a system holding only a Combatant can still ask.
##
## Play stamps the trait on the NODE, which is right for the node's own
## purposes and useless to Combat, the pool, or anything else that only ever
## sees bodies. Keyed by instance id rather than by the body itself because a
## Dictionary key is a strong reference and this is a static table: keeping the
## body alive here would leak every enemy of every region for the whole run.
static var _by_body: Dictionary = {}

## Prune when the table passes this. A region is ~40 enemies, so this is
## several regions of slack and the sweep is rare.
const PRUNE_AT: int = 256


static func trait_of(body: Combatant) -> int:
	if body == null:
		return Trait.NONE
	return int(_by_body.get(body.get_instance_id(), Trait.NONE))


static func _remember(body: Combatant, t: int) -> void:
	if _by_body.size() >= PRUNE_AT:
		_forget_freed()
	_by_body[body.get_instance_id()] = t


## Drop the dead. Instance ids are never reused, so a lapsed id can only mean
## the combatant is gone.
static func _forget_freed() -> void:
	for id in _by_body.keys():
		if not is_instance_id_valid(int(id)):
			_by_body.erase(id)
	# The rise ledger is pruned on the same sweep. Kept separate from _by_body
	# so a trait's bookkeeping cannot be mistaken for the trait itself, but it
	# must not be the table that grows for the whole run.
	for id in _rises.keys():
		if not is_instance_id_valid(int(id)):
			_rises.erase(id)
	# Adamant's ledger is pruned on the same sweep, for the same reason: it is
	# written on every landed blow, and a table that only ever grows is a leak
	# with a slow fuse.
	for id in _plate.keys():
		if not is_instance_id_valid(int(id)):
			_plate.erase(id)


## Which trait this elite has. Seeded, so the same spawn on the same map is
## the same elite every time the player walks in.
static func roll(seed: int, index: int) -> int:
	return 1 + int(Rng.unit2(seed, index, 991) * float(COUNT)) % COUNT


static func name_of(t: int) -> String:
	return String(NAMES.get(t, ""))


static func blurb_of(t: int) -> String:
	return String(BLURBS.get(t, ""))


static func colour_of(t: int) -> Color:
	return COLOURS.get(t, Color.WHITE)


# ------------------------------------------------------------------------------
# Spawn
# ------------------------------------------------------------------------------

## Put the trait on `body`. Called once, at spawn.
##
## IDEMPOTENT, and it has to be: Brutal multiplies damage_scale and Brood
## multiplies max_health, so a second call — a respawn path, a retry, a wave
## rebuilt over the same body — used to silently square the elite. The first
## trait wins, which is also the "one trait, not a stack" rule enforced
## instead of merely documented.
static func apply(body: Combatant, t: int) -> void:
	if body == null or t == Trait.NONE:
		return
	if trait_of(body) != Trait.NONE:
		return
	_remember(body, t)

	match t:
		Trait.SWIFT:
			body.apply(StatusEffect.make(StatusEffect.Kind.HASTE,
				FOREVER, SWIFT_HASTE, "elite_swift"))
		Trait.WARDED:
			body.apply(StatusEffect.make(StatusEffect.Kind.SHIELD,
				FOREVER, body.max_health * WARD_FRACTION, "elite_warded"))
		Trait.BRUTAL:
			# Multiplies whatever the difficulty ramp already set, so a Brutal
			# elite on map 1 is still inside the opening's mercy.
			body.damage_scale *= 1.0 + BRUTAL_BONUS
		Trait.VENOMOUS:
			pass    # lands on the victim, not the caster — see on_hit()
		Trait.FRENZIED:
			body.apply(StatusEffect.make(StatusEffect.Kind.HASTE,
				FOREVER, FRENZY_BASE, "elite_frenzy"))
			_watch_damage(body)
		Trait.MENDING:
			pass    # heals itself in on_hit(), its pack in mend()
		Trait.BROOD:
			# Bloated: what it is carrying is why it is slow, and why there is
			# more of it to chew through. Live without any hook at all — the
			# split on top of it is Play's call.
			body.max_health *= BROOD_BLOAT
			body.health = body.max_health
			body.apply(StatusEffect.make(StatusEffect.Kind.SLOW,
				FOREVER, BROOD_SLOW, "elite_brood"))
		Trait.FESTERING:
			pass    # rot on hit, pool on death
		Trait.UNBOWED:
			_watch_status(body)
		Trait.RIMECLAD, Trait.EMBERCLAD:
			# The clad itself: the rider of the element it resists is blunted and
			# the rider of the element it cannot stand bites deeper. The DAMAGE
			# half of both is incoming_multiplier(), which needs a caller that
			# knows the element (see NEEDS_HOOK) — this half is live the moment it
			# spawns, so neither clad is ever an elite that does nothing.
			_watch_clad(body)
		Trait.UNDYING:
			_watch_rise(body)
		Trait.SUNDERING:
			pass    # tears the player's wards off in on_hit()
		Trait.SHACKLING:
			pass    # drags the player down in on_hit()
		Trait.GALVANIC:
			_watch_galvanic(body)
		Trait.ADAMANT:
			_watch_plate(body)
		Trait.GORGING:
			_watch_gorge(body)


## Frenzied needs to know when it has been hurt.
##
## THE CALLABLE CAPTURES AN INSTANCE ID, NOT THE BODY. A Callable that held the
## body would be held in turn by that body's own signal — the reference cycle
## Hud.gd had to unpick by hand and Play.gd warns about at add_enemy. An int
## cannot close a cycle.
static func _watch_damage(body: Combatant) -> void:
	var id: int = body.get_instance_id()
	body.damaged.connect(func(_amount: float, _crit: bool, _source: String) \
		-> void: _frenzy_bleed(id))


static func _watch_status(body: Combatant) -> void:
	var id: int = body.get_instance_id()
	body.status_applied.connect(func(kind: int, _duration: float) -> void:
		_shrug_off(id, kind))


## Faster the worse it is hurt.
##
## Monotonic by construction: Combatant.apply refreshes a repeated kind to the
## GREATER magnitude, so a frenzy never recedes. One that eased off when the
## elite was healed would have the player watching an enemy's speed flicker
## with no way to tell what caused it.
static func _frenzy_bleed(id: int) -> void:
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	if body == null or not body.alive:
		return
	var lost: float = 1.0 - body.health_fraction()
	body.apply(StatusEffect.make(StatusEffect.Kind.HASTE, FOREVER,
		FRENZY_BASE + (FRENZY_MAX - FRENZY_BASE) * lost, "elite_frenzy"))


## Control does not stick to an Unbowed elite.
##
## Erased the instant it lands, from the signal Combatant.apply emits when a
## NEW kind is appended — so the effect is gone before any tick, any movement
## multiplier or any HUD read can see it. It cannot be refused earlier without
## a hook inside Combatant.apply, and a status this one holds for part of a
## frame is indistinguishable, to everything downstream, from one it refused.
##
## Only STUN and SLOW: this is immunity to CONTROL, not to damage. An elite
## that also shrugged off burns and weakens would be a damage-immunity trait
## wearing the wrong name.
static func _shrug_off(id: int, kind: int) -> void:
	if kind != StatusEffect.Kind.STUN and kind != StatusEffect.Kind.SLOW:
		return
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	if body == null:
		return
	var e: StatusEffect = body.effect_of(kind)
	if e != null:
		body.effects.erase(e)


# ------------------------------------------------------------------------------
# The clads: one element barely marks it, the other one undoes it
# ------------------------------------------------------------------------------

static func _watch_clad(body: Combatant) -> void:
	var id: int = body.get_instance_id()
	body.status_applied.connect(func(kind: int, _duration: float) -> void:
		_clad_bite(id, kind))


## What lands on a clad elite, and what slides off it.
##
## ONE FUNCTION FOR BOTH CLADS, keyed off the status rather than off the element,
## because a StatusEffect does not carry an element and inventing one here would
## be a second source of truth for MageSpells.ELEMENT_STATUS to drift from. The
## rider of the element it RESISTS is blunted, the rider of the element it is
## WEAK TO bites deeper, and the table says which is which:
##
##   Rimeclad   resists frost → its SLOW slides off entirely
##              weak to fire  → its BURN bites harder and lasts longer
##   Emberclad  resists fire  → its BURN ticks half as often (see EMBER_BURN_SLOW)
##              weak to frost → its SLOW bites deeper and lasts longer
##
## The two elements in a clad always carry DIFFERENT riders, so a kind is never
## ambiguous between the two arms — asserted in elitetest rather than assumed.
##
## NOT the stun, for either of them. A clad is an ELEMENT trait, and one that
## also could not be stunned would be Unbowed wearing a different colour — the
## player would learn the wrong rule off whichever they met first.
static func _clad_bite(id: int, kind: int) -> void:
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	if body == null:
		return
	var clad: Dictionary = CLAD.get(trait_of(body), {})
	if clad.is_empty():
		return
	if kind == int(Spells.ELEMENT_STATUS[clad["resists"]]):
		_blunt_rider(body, kind)
	elif kind == int(Spells.ELEMENT_STATUS[clad["weak_to"]]):
		_sharpen_rider(body, kind)


## Take the resisted element's rider off it, as far as it can honestly be taken.
##
## A SLOW IS ERASED — frost's whole rider, so a frost mage's control against
## Rimeclad is gone and "burn it instead" is literal.
##
## A BURN IS STRETCHED, NOT ERASED AND NOT DAMPENED. Erasing it would be Gorging
## (which pays itself a ward for it, and is a different lesson); dampening the
## magnitude cannot survive a refresh at all — see EMBER_BURN_SLOW. Halving the
## number of ticks over the same duration halves the burn, permanently, and is
## the one version of this that a re-cast cannot undo.
static func _blunt_rider(body: Combatant, kind: int) -> void:
	var rider: StatusEffect = body.effect_of(kind)
	if rider == null:
		return
	if kind == StatusEffect.Kind.BURN:
		rider.tick_every *= EMBER_BURN_SLOW
		rider.tick_in *= EMBER_BURN_SLOW
		return
	body.effects.erase(rider)


## Make the element it cannot stand hurt more.
##
## Mutated in place rather than re-applied: Combatant.apply would see the kind
## already present, take the GREATER of the two magnitudes and emit nothing — so
## a re-apply would both no-op and not re-enter here. Growing the effect that is
## already on it is the only version that works, and it is why a refreshed rider
## keeps the bonus instead of compounding it.
static func _sharpen_rider(body: Combatant, kind: int) -> void:
	var rider: StatusEffect = body.effect_of(kind)
	if rider == null:
		return
	if kind == StatusEffect.Kind.BURN:
		rider.magnitude *= 1.0 + RIME_BURN_BONUS
		rider.remaining *= RIME_BURN_LONGER
		return
	if kind == StatusEffect.Kind.SLOW:
		rider.magnitude = minf(rider.magnitude * (1.0 + EMBER_SLOW_BONUS),
			EMBER_SLOW_MAX)
		rider.remaining *= EMBER_SLOW_LONGER


## How much of an `element`'s damage a trait actually takes. 1.0 for everything
## that has no opinion, which is every trait but the two clads.
##
## NEEDS A CALL FROM Combat.cast (see NEEDS_HOOK), ONE call for both of them. It
## cannot be done from this file: `Combatant.strike` is handed a flat multiplier
## and is never told what kind of damage it is resolving, and Ability.element is
## the only place the answer exists. Implemented and tested here so the hook is
## one line of arithmetic rather than a design decision in somebody else's file.
##
## `element` is -1 on every non-mage ability — a fighter's sword is not frost,
## so it is not resisted.
static func incoming_multiplier(t: int, element: int) -> float:
	if element < 0 or not CLAD.has(t):
		return 1.0
	var clad: Dictionary = CLAD[t]
	if element == int(clad["resists"]):
		return float(clad["taken"])
	if element == int(clad["weak_to"]):
		return float(clad["weak_taken"])
	return 1.0


# ------------------------------------------------------------------------------
# Undying: the kill that was not one
# ------------------------------------------------------------------------------

## How many rises each Undying body has spent, by instance id. Same reasoning as
## _by_body: an int key cannot keep a dead enemy alive.
static var _rises: Dictionary = {}


static func _watch_rise(body: Combatant) -> void:
	var id: int = body.get_instance_id()
	_rises[id] = 0
	body.damaged.connect(func(_amount: float, _crit: bool, _source: String) \
		-> void: _rise(id))


## Rises left on this body — 0 once it is spent, so a HUD or a death log can say
## "it is not getting up again" rather than making the player find out.
static func rises_left(body: Combatant) -> int:
	if body == null or trait_of(body) != Trait.UNDYING:
		return 0
	return maxi(UNDYING_RISES - int(_rises.get(body.get_instance_id(), 0)), 0)


## Get back up, once.
##
## THIS WORKS BECAUSE OF THE ORDER INSIDE Combatant._take_raw: health is written
## to, `damaged` is emitted, and only THEN is `health <= 0.0` tested. Putting
## health back from inside the signal means the test that follows is false, so
## the body never dies, `died` never fires, and `_take_raw` reports no kill.
## Nothing downstream — the loot drop, the kill count, the corpse prune — has to
## know this trait exists, and none of them can disagree with each other about
## whether the thing is dead.
##
## ONE rise, hard. Every arm of this is guarded rather than trusted, because
## the failure mode of the alternative is an enemy that cannot be killed, in a
## lane the player has to clear to continue.
static func _rise(id: int) -> void:
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	# `alive` is still true here: _take_raw has not reached its own death check.
	if body == null or not body.alive or body.health > 0.0:
		return
	var spent: int = int(_rises.get(id, 0))
	if spent >= UNDYING_RISES:
		return
	_rises[id] = spent + 1
	body.health = maxf(body.max_health * UNDYING_FRACTION, 1.0)
	# Faster, because it is the only cue this file can give: there is no node
	# here to re-colour, and a health bar that silently refills reads as a bug
	# rather than as a mechanic.
	body.apply(StatusEffect.make(StatusEffect.Kind.HASTE, FOREVER,
		UNDYING_RAGE, "elite_undying"))


# ------------------------------------------------------------------------------
# Galvanic: control is food
# ------------------------------------------------------------------------------

static func _watch_galvanic(body: Combatant) -> void:
	var id: int = body.get_instance_id()
	body.status_applied.connect(func(kind: int, _duration: float) -> void:
		_galvanise(id, kind))


## Every stun and every slow comes back as speed.
##
## Deliberately NOT Unbowed. Unbowed drops the effect and nothing else happens,
## which teaches "do not bother"; this one drops it and pays itself, which
## teaches "stop". Both lessons are legible on their own, and they are only
## confusable if the player cannot tell the two elites apart — which is why the
## iron ring and the arc-yellow ring are nowhere near each other.
##
## NO RECURSION, by construction: applying HASTE re-enters this handler with
## kind == HASTE, which is neither of the two kinds it acts on. Worth stating
## because the obvious implementation — re-apply the control effect's own kind —
## would recurse until the stack gave out.
static func _galvanise(id: int, kind: int) -> void:
	if kind != StatusEffect.Kind.STUN and kind != StatusEffect.Kind.SLOW:
		return
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	if body == null:
		return
	var control: StatusEffect = body.effect_of(kind)
	if control != null:
		body.effects.erase(control)
	var have: StatusEffect = body.effect_of(StatusEffect.Kind.HASTE)
	var at: float = have.magnitude if have != null else 0.0
	body.apply(StatusEffect.make(StatusEffect.Kind.HASTE, FOREVER,
		minf(at + GALVANIC_STEP, GALVANIC_CAP), "elite_galvanic"))


# ------------------------------------------------------------------------------
# Adamant: the big hit is the wrong hit
# ------------------------------------------------------------------------------

## The health each Adamant body had before the blow currently being resolved,
## by instance id. An int key for the same reason as _by_body: a Dictionary key
## is a strong reference, and keeping the body here would leak every enemy of
## every region for the whole run.
##
## WHY A LEDGER AT ALL. Combatant._take_raw clamps `health` at zero before it
## emits `damaged`, so on an overkill blow the figure the health came DOWN FROM
## is unrecoverable from inside the signal: health is 0 and `amount` is only an
## upper bound on what was actually taken. Without the number it started from,
## capping the blow would mean handing back health the elite never had.
static var _plate: Dictionary = {}


static func _watch_plate(body: Combatant) -> void:
	var id: int = body.get_instance_id()
	_plate[id] = body.health
	body.damaged.connect(func(amount: float, _crit: bool, _source: String) \
		-> void: _blunt(id, amount))
	# THE LEDGER HAS TO FOLLOW A HEAL TOO. A Mending packmate topping this one up
	# would otherwise leave the ledger below the real health, and the next capped
	# blow would snap it back down to a figure from before the heal — the heal
	# would visibly undo itself, which reads as the health bar being broken.
	body.healed.connect(func(_amount: float) -> void: _plate_seen(id))


static func _plate_seen(id: int) -> void:
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	if body != null:
		_plate[id] = body.health


## Trim one blow back to the cap.
##
## THIS WORKS BECAUSE OF THE ORDER INSIDE Combatant._take_raw, exactly as Undying
## does: health is written to, `damaged` is emitted, and only THEN is
## `health <= 0.0` tested. Putting the excess back from inside the signal means
## the kill check that follows sees the trimmed figure, so a blow that cannot
## take more than a sliver cannot kill either. Nothing downstream — the loot
## drop, the kill count, the corpse prune — has to know this trait exists.
##
## IT CANNOT PRODUCE AN IMMORTAL ELITE, by construction rather than by tuning:
## every landed blow takes min(blow, cap) and the ledger only ever moves DOWN,
## so ceil(1/ADAMANT_CAP) hits of any size at all finish it.
static func _blunt(id: int, amount: float) -> void:
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	# `alive` is still true here: _take_raw has not reached its own death check.
	if body == null or not body.alive:
		return
	var cap: float = body.max_health * ADAMANT_CAP
	if amount <= cap:
		# A small hit lands in full — this is a cap, not a damage reduction, and
		# a burn tick or a pool bite must still cost exactly what it says.
		_plate[id] = body.health
		return
	# The LOWER of the ledger and health+amount. On an ordinary blow health+amount
	# is the exact figure it came down from and corrects a ledger that something
	# wrote around; on an overkill blow health is clamped at zero and the ledger
	# is the only record left.
	var before: float = minf(float(_plate.get(id, body.max_health)),
		body.health + amount)
	body.health = clampf(before - cap, 0.0, body.max_health)
	_plate[id] = body.health


## What a floating damage number over an Adamant elite should say.
##
## `damaged` carries the figure the attack ROLLED, which for this trait is not
## the figure that came off — a 500 over a bar that moved by 30 reads as the
## health bar being broken rather than as the mechanic working. The signal's
## argument cannot be changed from here, so the correction is published for
## whatever draws the number (see NEEDS_HOOK notes in the report) and is a no-op
## for every other trait.
static func shown_damage(body: Combatant, amount: float) -> float:
	if body == null or trait_of(body) != Trait.ADAMANT:
		return amount
	return minf(amount, body.max_health * ADAMANT_CAP)


# ------------------------------------------------------------------------------
# Gorging: it swallows the burn and wears it
# ------------------------------------------------------------------------------

static func _watch_gorge(body: Combatant) -> void:
	var id: int = body.get_instance_id()
	body.status_applied.connect(func(kind: int, _duration: float) -> void:
		_gorge(id, kind))


## Swallow a fresh burn and wear it as a ward.
##
## RIDES status_applied, WHICH ONLY FIRES FOR A KIND THAT IS NEW — which is
## exactly when there is a fresh burn to swallow, and is why this needs no hook
## from anybody. A refresh of a burn it has already eaten cannot re-enter here,
## because there is no burn on it to refresh.
##
## NO RECURSION, by construction: applying SHIELD re-enters this handler with
## kind == SHIELD, which is not BURN. Worth stating because the obvious
## implementation — convert the rider into more of the same kind — would recurse
## until the stack gave out.
##
## THE WARD IS A SHARE OF THE BURN IT ATE AND NOTHING ELSE, so the player can
## never hand it more health than the burning would have cost it (GORGE_WARD),
## and a single enormous DOT cannot buy it a second bar (GORGE_WARD_CAP). Every
## spell in this game also deals direct damage, so the map stays clearable by a
## fire or venom mage — they lose their rider, not their spellbook.
static func _gorge(id: int, kind: int) -> void:
	if kind != StatusEffect.Kind.BURN:
		return
	if not is_instance_id_valid(id):
		return
	var body := instance_from_id(id) as Combatant
	if body == null:
		return
	var burn: StatusEffect = body.effect_of(kind)
	if burn == null:
		return
	var swallowed: float = burn_total(burn)
	body.effects.erase(burn)
	if swallowed <= 0.0:
		return
	# Refreshed rather than stacked — Combatant.apply takes the greater of the
	# two magnitudes — so a second mouthful tops the ward up towards the cap and
	# never past it.
	body.apply(StatusEffect.make(StatusEffect.Kind.SHIELD, FOREVER,
		minf(swallowed * GORGE_WARD, body.max_health * GORGE_WARD_CAP),
		"elite_gorge"))


## What a burn has left to deal: its per-tick bite times the ticks it has left.
##
## Read off the effect rather than from the spell that applied it, because by the
## time this file sees the burn the ability is long gone — and because Rimeclad
## may already have grown it, in which case the swallowed figure has to be the
## grown one.
static func burn_total(burn: StatusEffect) -> float:
	if burn == null or burn.magnitude <= 0.0:
		return 0.0
	return burn.magnitude \
		* maxf(burn.remaining, 0.0) / maxf(burn.tick_every, 0.01)


# ------------------------------------------------------------------------------
# On a landed hit
# ------------------------------------------------------------------------------

## What an elite leaves behind when it connects. Called from the cast-resolution
## path, so it rides the same hit the damage did.
static func on_hit(t: int, attacker: Combatant, victim: Combatant) -> void:
	if attacker == null or victim == null or not attacker.alive:
		return
	match t:
		Trait.VENOMOUS:
			if not victim.alive:
				return
			victim.apply(StatusEffect.make(StatusEffect.Kind.BURN,
				VENOM_SECONDS, attacker.attack_power() * VENOM_FRACTION,
				"elite_venom"))
		Trait.FESTERING:
			# The rot takes the strength out of you. WEAKEN rather than more
			# damage: the trait's job is to make the fight go differently, and
			# a player whose own hits have gone soft feels that immediately.
			if not victim.alive:
				return
			victim.apply(StatusEffect.make(StatusEffect.Kind.WEAKEN,
				ROT_SECONDS, ROT_WEAKEN, "elite_rot"))
		Trait.MENDING:
			# Closes its own wounds as it feeds. Capped by Combatant.heal at
			# max_health, so this can never make it unkillable — it only ever
			# gives back a share of ONE hit it managed to land.
			attacker.heal(attacker.attack_power() * MEND_SELF_FRACTION)
		Trait.SUNDERING:
			# ONE ward per hit, in SUNDER_ORDER, and nothing else: the shield
			# first because it is the one the player spent a cooldown on.
			#
			# A corpse check is not enough here — stripping a shield off a dead
			# body is harmless, but it would spend the strip on nothing while
			# the player watched their ward survive the hit that killed them.
			if not victim.alive:
				return
			for kind in SUNDER_ORDER:
				var ward: StatusEffect = victim.effect_of(kind)
				if ward != null:
					victim.effects.erase(ward)
					return
		Trait.SHACKLING:
			# Refreshed, not stacked — Combatant.apply takes the greater of the
			# two — so the drag lasts exactly as long as it keeps connecting.
			if not victim.alive:
				return
			victim.apply(StatusEffect.make(StatusEffect.Kind.SLOW,
				SHACKLE_SECONDS, SHACKLE_MAGNITUDE, "elite_shackle"))


# ------------------------------------------------------------------------------
# Mending: the pack heal
# ------------------------------------------------------------------------------

## Put health back into the most wounded member of `allies`. Returns how much
## was actually restored, so a caller can show it.
##
## NEEDS A CALL FROM Play.gd (see NEEDS_HOOK) — this file cannot see a pack.
## Written as a pure function over bodies so the choice of target and the
## amount are both testable headlessly, which is the half that goes wrong.
##
## The most wounded, not the nearest: a healer that tops up whoever happens to
## be beside it reads as random, and the player cannot learn to kill it first
## from behaviour they cannot predict.
static func mend(t: int, healer: Combatant, allies: Array) -> float:
	if t != Trait.MENDING or healer == null or not healer.alive:
		return 0.0
	var worst: Combatant = null
	var worst_f: float = 1.0
	for a in allies:
		var ally := a as Combatant
		# Itself excluded: it has on_hit for that, and a mender that healed
		# itself from this pulse too would be a lifesteal trait by accident.
		if ally == null or ally == healer or not ally.alive:
			continue
		var f: float = ally.health_fraction()
		if f >= 1.0 or f >= worst_f:
			continue
		worst_f = f
		worst = ally
	if worst == null:
		return 0.0
	var before: float = worst.health
	worst.heal(healer.attack_power() * MEND_PACK_FRACTION)
	return worst.health - before


# ------------------------------------------------------------------------------
# Brood: the split
# ------------------------------------------------------------------------------

## The two lesser copies a Brood elite bursts into. Built here, placed by
## Play.gd (see NEEDS_HOOK) — this file owns no scene tree.
##
## Through Combatant.make, never Combatant.new(), so the spawn hooks that wire
## a body's audio and health bar fire for the spawn exactly as they do for a
## champion. A split that produced silent, un-tracked enemies would read as the
## game glitching rather than as a mechanic.
##
## THE SPAWN IS NOT AN ELITE. Nothing registers a trait on it, so trait_of()
## returns NONE and a Brood cannot split into two more Broods — an elite that
## did would make a map that cannot be finished.
static func split(t: int, parent: Combatant) -> Array:
	var out: Array = []
	if t != Trait.BROOD or parent == null:
		return out
	for i in range(SPLIT_COUNT):
		var c: Combatant = Combatant.make(
			"%s Spawn" % parent.display_name,
			parent.team,
			parent.level,
			parent.stats.scaled(SPLIT_POWER),
			parent.school,
			parent.weapon_power * SPLIT_POWER,
			parent.armour * SPLIT_POWER,
			# Deterministic, and different per spawn: a replayed fight has to
			# roll the same crits, including for things born mid-fight.
			Rng.hash2(parent.rng_seed, i, 7177))
		# Set against the PARENT's health rather than left to the scaled stats:
		# the spawn is a share of what the player had already chewed through,
		# and stats alone would ignore every tier and endless multiplier that
		# built the parent.
		c.max_health = maxf(parent.max_health * SPLIT_HEALTH, 1.0)
		c.health = c.max_health
		c.damage_scale = parent.damage_scale * SPLIT_POWER
		out.append(c)
	return out


# ------------------------------------------------------------------------------
# Festering: the pool it dies into
# ------------------------------------------------------------------------------

## The hazard a Festering elite leaves where it fell. A Dictionary rather than
## a class so Play can hold it in an array, serialise it, and pass it straight
## back to pool_tick without this file owning any state.
static func death_pool(t: int, body: Combatant) -> Dictionary:
	if t != Trait.FESTERING or body == null:
		return {}
	return {
		"radius": POOL_RADIUS,
		"dps": body.attack_power() * POOL_DPS_FRACTION,
		"left": POOL_SECONDS,
		"tick_in": POOL_TICK,
	}


## Advance a pool by `delta` and hurt everything `inside` it. Returns the total
## damage dealt, and leaves "left" at 0 when the pool is spent.
##
## NEEDS A CALL FROM Play.gd (see NEEDS_HOOK): the caller owns positions, so
## the caller decides who is standing in it. Everything else — the cadence, the
## expiry, the mitigation — is here and under test.
##
## Routed through take_hit, so armour applies and the damage number, the shield
## soak and the death all behave exactly as they do for a boss slam.
static func pool_tick(pool: Dictionary, delta: float, inside: Array) -> float:
	if pool.is_empty() or float(pool.get("left", 0.0)) <= 0.0:
		return 0.0
	# Snapped, not merely clamped: a pool left holding 1e-15 seconds passes the
	# guard above on the next frame and lands a bite after it is over.
	pool["left"] = maxf(float(pool["left"]) - delta, 0.0)
	if float(pool["left"]) <= CLOCK_EPS:
		pool["left"] = 0.0
	pool["tick_in"] = float(pool.get("tick_in", POOL_TICK)) - delta
	var dealt: float = 0.0
	while float(pool["tick_in"]) <= CLOCK_EPS:
		pool["tick_in"] = float(pool["tick_in"]) + POOL_TICK
		var bite: float = float(pool.get("dps", 0.0)) * POOL_TICK
		for b in inside:
			var body := b as Combatant
			if body == null or not body.alive:
				continue
			var before: float = body.health
			body.take_hit(bite, "Rot")
			dealt += before - body.health
		# A pool that expired mid-frame does not get a free extra bite.
		if float(pool["left"]) <= 0.0:
			break
	return dealt


## The pool, drawn. Reads the SAME Dictionary pool_tick advances, so the puddle
## on the ground and the damage under the player's feet cannot disagree — a
## hazard that is still hurting after its art has gone is indistinguishable
## from a bug.
static func pool_mark(parent: Node, at: Vector3, pool: Dictionary) -> Node3D:
	if parent == null or pool.is_empty():
		return null
	var radius: float = float(pool.get("radius", POOL_RADIUS))
	var tint: Color = colour_of(Trait.FESTERING)

	var node := Node3D.new()
	node.name = "RotPool"
	node.position = at

	var fill := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.0
	disc.bottom_radius = 1.0
	disc.height = 0.05
	disc.radial_segments = 24
	disc.rings = 1
	fill.mesh = disc
	var fmat: StandardMaterial3D = Vfx._glow(tint, 1.1)
	fill.material_override = fmat
	fill.scale = Vector3(radius, 1.0, radius)
	fill.position.y = 0.04
	node.add_child(fill)

	var edge := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.93
	torus.outer_radius = 1.0
	torus.rings = 24
	torus.ring_segments = 4
	edge.mesh = torus
	edge.material_override = Vfx._glow(tint, 2.0)
	edge.scale = Vector3(radius, 1.0, radius)
	edge.position.y = 0.06
	node.add_child(edge)

	var fade := PoolFade.new()
	fade.pool = pool
	fade.fill = fmat
	fade.total = maxf(float(pool.get("left", POOL_SECONDS)), 0.01)
	node.add_child(fade)

	parent.add_child(node)
	return node


## Dims the pool as it runs out and takes the whole mark with it.
##
## A node rather than a lambda because nothing else is ticking it, and it reads
## the pool's own remaining time rather than keeping a second clock: two clocks
## is how the art and the damage come apart.
class PoolFade extends Node:
	var pool: Dictionary = {}
	var fill: StandardMaterial3D = null
	var total: float = 1.0

	func _process(_delta: float) -> void:
		var left: float = float(pool.get("left", 0.0))
		if fill != null:
			var k: float = clampf(left / maxf(total, 0.01), 0.0, 1.0)
			fill.albedo_color = Color(fill.albedo_color, 0.16 + 0.26 * k)
		if left <= 0.0:
			var owner_node: Node = get_parent()
			if owner_node != null:
				owner_node.queue_free()


# ------------------------------------------------------------------------------
# The mark
# ------------------------------------------------------------------------------

## The ring an elite wears. Same machinery as the veteran mark — rings at the
## feet, in the trait's colour — so "which of these is dangerous, and how" is
## answered from across the field rather than by reading a health bar.
##
## COLOUR ALONE STOPPED BEING ENOUGH AT NINE TRAITS, so the shape carries
## meaning too: see SHAPES.
static func mark(on: Node3D, t: int) -> Node3D:
	if on == null or t == Trait.NONE:
		return null
	var shape: Dictionary = SHAPES.get(t, {})
	var rings: int = int(shape.get("rings", 1))
	var inner: float = float(shape.get("inner", 0.74))
	var outer: float = float(shape.get("outer", 0.86))
	var scale: float = float(shape.get("scale", 1.0))
	var tint: Color = colour_of(t)

	var mark := Node3D.new()
	mark.name = "EliteMark"
	on.add_child(mark)

	var turning: Array = []
	for i in range(maxi(rings, 1)):
		var mi := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = inner + 0.14 * float(i)
		torus.outer_radius = outer + 0.14 * float(i)
		torus.rings = 18
		torus.ring_segments = 4
		mi.mesh = torus
		mi.material_override = Vfx._glow(tint, 1.8)
		mi.position.y = 0.06
		if scale != 1.0:
			mi.scale = Vector3(scale, 1.0, scale)
		mark.add_child(mi)
		turning.append(mi)

	if bool(shape.get("upright", false)):
		# A standing hoop, which reads at eye level rather than at the feet —
		# the cue for the one trait the player must look UP to find in a crowd.
		var halo := MeshInstance3D.new()
		var ring := TorusMesh.new()
		ring.inner_radius = 0.40
		ring.outer_radius = 0.48
		ring.rings = 16
		ring.ring_segments = 4
		halo.mesh = ring
		halo.material_override = Vfx._glow(tint, 1.8)
		halo.rotation.x = PI * 0.5
		halo.position.y = 1.55
		mark.add_child(halo)
		turning.append(halo)

	var spin := Vfx.VeteranSpin.new()
	spin.rings = turning
	mark.add_child(spin)
	return mark


# ------------------------------------------------------------------------------
# Audit
# ------------------------------------------------------------------------------

## Is this trait actually DOING something to this body, right now?
##
## This project's most expensive recurring bug is a feature wired to nothing —
## the signal fires, the listener was never connected, and the test that
## checked the signal passed anyway. So every arm of this proves an EFFECT:
## health moved, a status stuck, a victim came away poisoned, a spawn exists.
##
## AND IT HAS TO COVER EVERY TRAIT. The version of this function that stopped at
## Unbowed returned false for Rimeclad, Undying and Sundering — which was
## correct, because those three did nothing, and completely silent, because
## nobody asked it. A match statement with a missing arm reads as "not proven",
## and "not proven" is indistinguishable from "not checked" unless something
## walks the whole of ALL. elitetest does.
##
## Safe to call on a live enemy mid-map. Nothing here damages `body`: the
## victims are scratch Combatants, the split bodies are thrown away, and the
## Unbowed check applies a control effect that — if the trait works — is gone
## before the call returns.
static func proven(t: int, body: Combatant) -> bool:
	if body == null or t == Trait.NONE:
		return false
	match t:
		Trait.SWIFT:
			return body.has(StatusEffect.Kind.HASTE)
		Trait.WARDED:
			return body.has(StatusEffect.Kind.SHIELD)
		Trait.BRUTAL:
			return body.damage_scale > 1.0
		Trait.VENOMOUS:
			var v: Combatant = _scratch(body)
			on_hit(t, body, v)
			return v.has(StatusEffect.Kind.BURN)
		Trait.FRENZIED:
			return body.has(StatusEffect.Kind.HASTE)
		Trait.MENDING:
			var hurt: Combatant = _scratch(body)
			hurt.health = hurt.max_health * 0.4
			return mend(t, body, [hurt]) > 0.0
		Trait.BROOD:
			return body.has(StatusEffect.Kind.SLOW) \
				and split(t, body).size() == SPLIT_COUNT
		Trait.FESTERING:
			var v2: Combatant = _scratch(body)
			on_hit(t, body, v2)
			return v2.has(StatusEffect.Kind.WEAKEN) \
				and float(death_pool(t, body).get("dps", 0.0)) > 0.0
		Trait.UNBOWED:
			body.apply(StatusEffect.make(StatusEffect.Kind.STUN, 1.0, 0.0,
				"audit"))
			return not body.has(StatusEffect.Kind.STUN)
		Trait.RIMECLAD:
			# A slow that slid off leaves nothing behind, so this one can be run
			# on the real body without changing the fight.
			body.apply(StatusEffect.make(StatusEffect.Kind.SLOW, 2.0, 0.5,
				"audit"))
			return not body.has(StatusEffect.Kind.SLOW) \
				and incoming_multiplier(t, Spells.Element.FROST) < 1.0 \
				and incoming_multiplier(t, Spells.Element.FIRE) > 1.0
		Trait.EMBERCLAD:
			# ON A TWIN. Unlike Rimeclad's, this one's live half is what happens
			# to a burn that STAYS on it, and leaving an audit's burn ticking on
			# a live elite would be the audit killing it.
			var clad: Combatant = _twin(body, t)
			var fuse: StatusEffect = StatusEffect.make(StatusEffect.Kind.BURN,
				4.0, 10.0, "audit")
			var cadence: float = fuse.tick_every
			clad.apply(fuse)
			var caught: StatusEffect = clad.effect_of(StatusEffect.Kind.BURN)
			return caught != null and caught.tick_every > cadence \
				and incoming_multiplier(t, Spells.Element.FIRE) < 1.0 \
				and incoming_multiplier(t, Spells.Element.FROST) > 1.0 \
				and _listening(body.status_applied)
		Trait.ADAMANT:
			# ON A TWIN: the only proof of this trait is a blow big enough to
			# kill, and the live elite is what the player is still fighting.
			var plated: Combatant = _twin(body, t)
			var was: float = plated.health
			var cap: float = plated.max_health * ADAMANT_CAP
			plated.take_hit(plated.max_health * 10.0, "audit")
			return plated.alive and plated.health > 0.0 \
				and plated.health >= was - cap * 1.01 \
				and _plate.has(body.get_instance_id()) \
				and _listening(body.damaged)
		Trait.GORGING:
			# A twin again: a burn swallowed off the live elite would be a ward
			# handed to it by the audit.
			var gullet: Combatant = _twin(body, t)
			gullet.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0,
				maxf(gullet.max_health * 0.05, 1.0), "audit"))
			return not gullet.has(StatusEffect.Kind.BURN) \
				and gullet.has(StatusEffect.Kind.SHIELD) \
				and _listening(body.status_applied)
		Trait.UNDYING:
			# ON A TWIN, not on the subject. The only proof of this trait is a
			# lethal hit, and spending the live elite's one rise to audit it
			# would hand the player a free kill — the audit would be the bug.
			# The twin proves the MECHANIC; _rises proves THIS body is wired to
			# it, which is the half that goes missing.
			var twin: Combatant = _twin(body, t)
			twin.take_hit(twin.max_health * 10.0, "audit")
			return twin.alive and twin.health > 0.0 \
				and _rises.has(body.get_instance_id()) \
				and _listening(body.damaged)
		Trait.SUNDERING:
			var warded: Combatant = _scratch(body)
			warded.apply(StatusEffect.make(StatusEffect.Kind.SHIELD, 10.0,
				50.0, "audit"))
			on_hit(t, body, warded)
			return not warded.has(StatusEffect.Kind.SHIELD)
		Trait.SHACKLING:
			var runner: Combatant = _scratch(body)
			var before: float = runner.move_multiplier()
			on_hit(t, body, runner)
			# The MOVEMENT, not the status: a slow matters only because
			# move_multiplier reads it, and that is the link that breaks quietly.
			return runner.move_multiplier() < before
		Trait.GALVANIC:
			# A twin again: if the trait works, control makes it FASTER, and
			# auditing a live elite must not buff it.
			var fed: Combatant = _twin(body, t)
			fed.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0,
				"audit"))
			return not fed.is_stunned() and fed.has(StatusEffect.Kind.HASTE) \
				and _listening(body.status_applied)
	return false


## Has anything actually connected to `sig`?
##
## THIS IS NOT "assert the signal fired" — it is the opposite. The twin above
## proves the MECHANIC works; this proves THIS body is plugged into it. A
## listener nobody connected is the single bug this project keeps shipping, and
## for a trait whose whole implementation is a connection made in apply(), the
## empty connection list IS the defect. Checked alongside an effect, never
## instead of one.
static func _listening(sig: Signal) -> bool:
	return sig.get_connections().size() > 0


## A throwaway body on the other team, for the arms of proven() that need
## something to hit. Level-matched so the numbers are in the right range.
static func _scratch(like: Combatant) -> Combatant:
	var team: int = Combatant.Team.PLAYER if like.team == Combatant.Team.ENEMY \
		else Combatant.Team.ENEMY
	return Combatant.make("scratch", team, like.level, Stats.make(8, 8, 8, 8),
		HeroClass.School.MELEE, 1.0, 0.0, 99)


## A throwaway copy of `like`, carrying trait `t`, for the arms of proven()
## whose only proof is destructive — Undying has to actually be killed, Galvanic
## has to actually be controlled, Adamant has to be hit for everything it has,
## and the two that eat a status (Gorging, Emberclad) would be paid a ward or
## left burning by the audit itself.
##
## Same health as the original rather than the same stats, because Undying
## returns a FRACTION of max_health and a twin with a different bar would prove
## a different number than the one the player will meet.
static func _twin(like: Combatant, t: int) -> Combatant:
	var c: Combatant = Combatant.make("twin", like.team, like.level, like.stats,
		like.school, like.weapon_power, like.armour, like.rng_seed)
	c.max_health = like.max_health
	c.health = c.max_health
	c.damage_scale = like.damage_scale
	# Only ever called with UNDYING, GALVANIC, ADAMANT, GORGING or EMBERCLAD,
	# none of which scales health or damage in apply(). Handed a trait that does
	# — Brutal, Brood — it would compound the figures copied above, which is the
	# squaring the idempotence guard exists to prevent, so keep it to the five
	# that need it.
	apply(c, t)
	return c
