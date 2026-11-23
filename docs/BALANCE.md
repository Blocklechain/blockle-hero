# Balance, measured

Every balance number in this game was reasoned and none of it had been played.
`tools/balancetest.gd` is the instrument that measures it. This is what the
instrument says, and which constant to move.

Run it:

```
/opt/homebrew/bin/godot --headless --path . --script tools/balancetest.gd
```

**It is a measurement, not a verdict.** 33 checks pass, 11 fail, 11 of 11
sections complete. The failures below are findings about the game, not bugs in
the harness — but read "What this cannot measure" before moving anything, because
two of the eleven are statements about a definition rather than about a number.

---

## What was measured

Twenty maps (every 5th of 100), three tiers, three champion classes: 180
measurements, each the real `Encounter.build` cast fought with the real
`Combat.cast` by a real `Combat.champion_body` in real `Loot`-rolled gear. The
sweep is run twice and every row agrees, so nothing below is an artefact of
measurement order.

| Tier | Cost of a map, first third → last third | Boss TTK, first → last | Loot, map 1 → map 96 | Gold a body |
|---|---|---|---|---|
| Normal | 3.03 → 7.80 health bars | 25s → 24s | 340 → 4139 (x12.2) | 44.5 |
| Veteran | 5.72 → 15.51 | 39s → 49s | 2373 → 13207 (x5.6) | 175.5 |
| Merciless | 18.13 → 53.61 | 80s → 111s | 7760 → 31349 (x4.0) | 459.6 |

| Class | Cost of a map | TTK a body | TTK a boss | Pack capacity | Damage taken a duel |
|---|---|---|---|---|---|
| Fighter | 14.94 bars | 4.01s | 65.5s | 2.8 bodies | 9.7% of a bar |
| Ranger | 15.44 | 4.69s | 57.2s | 2.1 | 14.7% |
| Mage | 29.32 | 7.35s | 85.4s | 1.8 | 16.8% |

**What is right.** The four properties the campaign was built to have, it has.
Difficulty rises within every tier (x2.6 to x3.0 across the hundred maps) and
rises between tiers. There is **no cliff** — the worst five-map step is x2.68 and
the ceiling is x3.0. No boss dies inside 2 seconds and no body is free; a boss
takes a median **10.6x** a rank-and-file body's time, so the thing at the end of
the lane reads as a boss. Loot rises with the map, rises with the tier, and
rises *per second spent*, so there is no reason to farm map 1. Where the skill
points went moves the cost of a map by at most x1.11, so the build is a
preference and not a trap.

---

## Where the curve is wrong

### 1. A Storm mage's stun lock makes one map in twenty unplayable

The clearest finding, and it is not a curve problem at all.

`MageSpells` gives a Storm mage's **slot 1 — the damage spell, the one every
tier allows an enemy to press** — a STUN rider whose duration is rolled from a
band that overlaps its own cooldown:

```gdscript
s1.cooldown          = 3.0 + rand(0 .. 1.6)   # 3.0 – 4.6 s
s1.applies_duration  = 3.0 + rand(0 .. 2.0)   # 3.0 – 5.0 s   ← can exceed the cooldown
```

`Combatant.can_act()` is false for a stun's whole duration, so a rider that
outlasts its cooldown is an **unbreakable lock**. Five of 139 champions roll one;
the worst is `g110` at **152% uptime** (4.7 s stun on a 3.1 s cooldown).

Map 36's boss is `g027` the Storm Mage. Measured, with the champion immortal so
the only question is how much of the fight it was allowed to play:

| Where | TTK boss | Champion unable to act |
|---|---|---|
| Normal map 36, Mage | 300.0s (never killed it) | **96%** |
| Normal map 36, Fighter | 291.6s | 93% |
| Veteran map 36, Mage | 284.2s | 82% |
| Merciless map 36, Mage | 300.0s | 70% |

Boss fights where the champion could act: mean **62 s**. Where it mostly could
not: mean **213 s**. This single roll is also what produces the worst
class-cost spread in the game (x3.11 at Normal map 36) and the worst boss margin
at the level the campaign actually grants (x0.08 — the champion needs twelve
times the survivability it has).

**Change:** `scripts/game/MageSpells.gd`, `for_hero()`. Either drop the STUN
rider off slot 1 — `ELEMENT_STATUS[Element.STORM]` is the only element whose
rider is a hard control effect on the spammable damage button, and the slot
grammar already puts the stun on slot 2 for every class — or bound the duration
against the cooldown, e.g. `s1.applies_duration = min(3.0 + rand(0..2.0),
s1.cooldown * 0.5)`. **Direction: down, hard.** Storm currently *pays* for
carrying the rider — `ELEMENT_DAMAGE_BONUS[STORM] = -0.10` — so if the rider
goes, that penalty should go back to 0.0 with it, or Storm becomes the weakest
element rather than the most oppressive.

The harness asserts this roster-wide, so the fix is checkable:
`no enemy's stun lasts longer than 60% of its own cooldown`.

### 2. A Radiance mage boss heals faster than any champion can damage it

`Radiance`'s slot-1 damage spell carries `heal_fraction = 0.05` — 5% of the
caster's **max health** per cast, on a ~3.8 s cooldown, so ~1.3% of its own bar
per second. That is a reasonable number for a champion. It is not one for a
boss, because `Encounter.BOSS_HEALTH_MULT = 8.0` multiplies the pool the 5% is
taken from while nothing multiplies the champion's damage.

Merciless map 56's boss is `g039` the Radiance Mage, 65,884 health. Over a
300-second fight it healed itself **207,534** — three times its own bar — and
all three classes failed to kill it. The champion's throughput there is ~1.0% of
the boss's bar per second against the boss's 1.3%: the fight cannot be won by
standing in it, at any level, with any gear.

**Change:** `scripts/game/MageSpells.gd`, `s1.heal_fraction = 0.05`.
**Direction: down, to ~0.015, or off `max_health` entirely** — scaling it off
`caster.attack_power()` the way `Combat.cast` already defaults BURN magnitude
(`caster.attack_power() * 0.18`) removes the interaction with `BOSS_HEALTH_MULT`
and is the structurally correct fix. Asserted as `no boss heals back over 50% of
its own health bar`.

### 3. The Mage is not playing the same game

The Mage costs **x1.96** what the Fighter costs for the same map (29.32 bars vs
14.94), takes x1.83 as long to kill a body, and holds one body fewer of a pack.
Per map the worst spreads are x2.86 (time) and x3.11 (cost) — both over the
x2.0 / x3.0 bands. Class choice is currently a trap.

The cause is `MageSpells.FORM_DAMAGE`, and the comment above it is half right.
Per-target damage is normalised so every *form* has the same **blended**
throughput — `SINGLE_WEIGHT 0.40` single-target, `GROUP_WEIGHT 0.60` against
`GROUP_SIZE 5`. That holds for packs. But **a boss fight is 100%
single-target**, and the four forms allowed on the damage slot span
`BOLT 1.90 / ORB 1.19 / LANCE 0.86 / CHAIN 0.68` — a **2.8x spread** in the only
number that matters in a duel. A mage that rolled CHAIN brings a third of a
mage that rolled BOLT to every boss in the game, and the player never chose that.

**Change:** `scripts/game/MageSpells.gd`. Raise `SINGLE_WEIGHT` toward 0.6–0.7
so the normalisation is fitted to a mix that includes the boss fights, which
compresses `FORM_DAMAGE` upward at the wide end. **Direction: `SINGLE_WEIGHT`
up.** Note `tools/combattest.gd` asserts the *blended* kit spread, so it will
not catch this — the band it guards is the one that is already fine.

### 4. "On-level" is not a level any player is ever at

37 of 60 on-level boss fights are lost; only 4 of 60 are lost at the level the
campaign's own XP curve actually grants. **The boss numbers are mostly fine and
the definition is what is wrong**, which is why this is a finding and not a
tuning target.

By map 100 at Normal, `Campaign.enemy_level` wants level **16** while
`HeroProgress` has granted the player level **28** — the champion runs **+12
levels** ahead, and the whole hundred maps of Normal use 16 of a 60-level sheet.

**Change:** `scripts/game/Campaign.gd`, `LEVEL_SPAN = 15.0`. **Direction: up, to
~27**, so the within-tier ramp lands where the XP curve actually puts the player
and "on-level" becomes a real definition. This is a deliberate decision, not an
obvious fix: raising it also raises every enemy's health and damage through
`Encounter.body_for`, so re-run the harness after. The alternative lever is
`HeroProgress.XP_BASE / XP_EXP` (80.0 / 1.45) downward, which is worse — it
makes the same maps slower rather than better matched.

### 5. Merciless is unwinnable at the level cap

A champion at **level 60, the cap**, in level-60 gear, on the last sampled map:

| Tier | Fighter margin | Ranger | Mage |
|---|---|---|---|
| Normal | x69.77 | x12.16 | x25.89 |
| Veteran | x8.54 | x1.51 | x1.58 |
| Merciless | **x0.34** | **x0.18** | **x0.12** |

Margin is `boss's time to kill the champion / champion's time to kill the boss`;
below 1.0 the champion loses. No amount of levelling or farming answers x0.12 —
the ceiling is the problem, not the player.

The product is the cause. At Merciless `enemy_health_mult` is **x6.41** and
`BOSS_HEALTH_MULT` is a further **x8**, so a Merciless boss carries **x51** a
Normal pack member's health while `enemy_damage_mult` has only reached x3.41 —
and a champion's own damage is capped by level 60 and `Item` scaling. Each
constant is defensible; the product is not. Note also that `Campaign.min_level`
saturates at 60 from Infernal up, so tiers 5–8 have no on-level champion at all.

**Change:** `scripts/game/Encounter.gd`, `BOSS_HEALTH_MULT = 8.0`.
**Direction: down, to ~5.0.** It is the better of the two levers: it is one
number, it leaves the within-tier curve untouched, and the boss already keeps
its weight from `BOSS_ARMOUR_MULT 1.6` and a 10.6x time ratio over a body. The
alternative, `HEALTH_FIRST 2.6` down toward 2.3, moves all eight tiers and the
four shipped ones are the balance `tools/campaigntest.gd` pins.

### 6. A pack is wider than any champion can hold

62 of 180 map/class pairs cannot survive even **2** bodies of the deepest pack at
once. Mean capacity falls 3.3 → 2.2 → **1.1** bodies across the three tiers,
against a deepest pack of **5.1**.

Read this one carefully — it is the measurement most distorted by what the
harness cannot do (below): every body is in contact at once with no retreat, no
kiting and no partner, which is strictly the worst case. It is reported as
headroom, not as a prediction. But a mean capacity of 1.1 against a pack of 5
says the maths leaves **no** headroom at Merciless, and the player's answer there
has to come entirely from movement and from `Party`'s three partners.

**Change:** if the pack is the lever, `Encounter.ELITE_RATE_LATE = 0.34`
**down** toward 0.22 is the cheapest — an elite is a half-step boss and late
packs are a third elites. Prefer fixing (3) and (5) first and re-measuring: the
Mage's capacity of 1.8 is doing a lot of the damage to this number.

---

## What this cannot measure, stated plainly

A fight in the shipped game is resolved by `Play.gd` — a brain tick that walks
enemies to a stand-off, retreats ranged ones, aims the boss slam at the ground,
and a player with two thumbs who kites, dodges and breaks off. None of that is
reachable headlessly, and a headless reimplementation would be measuring a model
of the game instead of the game. So:

* **Every combatant is in contact and nobody moves.** Perfect uptime for both
  sides: harsher than real play on damage taken, kinder on clear time.
* **No partners.** `Party` fields up to three more champions at 0.55
  contribution, so a full party is a little over twice one hero. Solo is the
  hardest legal configuration — the right one for "is this winnable at all",
  and the reason finding (6) is headroom rather than a prediction.
* **The champion is driven by Play's own enemy rule** (highest action off
  cooldown and in range). That is a *floor* on player skill: it never holds
  Rally for the moment it is needed.
* **The boss slam is dodged**, which is the designed outcome of a telegraph, and
  reported separately as what one missed dodge would cost.
* **A cast takes `HeroRig`'s stand-in 0.45 s**, not the rigged clip's real
  length. Every TTK in seconds is in stand-in units; a real clip of 0.8 s
  stretches them all by a common factor, which moves the absolute seconds and
  cannot move the shape of a curve or a ratio between classes.

The duel figures — a champion against one real body, and against the map's real
boss — need none of the missing AI, and they carry findings 1 to 5. Finding 6 is
a worst-case capacity and is labelled as one.

---

## Patch requests in files I do not own

Nothing here is load-bearing for the measurements; both are drift risks.

**1. `scripts/game/Combat.gd` — a shield's default magnitude is written inline.**
`Combat.cast` defaults an unauthored SHIELD to 30% of the caster's max health as
a bare literal:

```gdscript
if ability.self_applies == StatusEffect.Kind.SHIELD and mag <= 0.0:
    mag = caster.max_health * 0.30
```

`tools/balancetest.gd` has to copy that number (`SHIELD_OF_MAX_HEALTH`) to
compute a class's sustain, and it is the one figure in the harness that can
silently drift away from the game. Please name it:

```gdscript
## What a shield with no authored magnitude is worth, as a fraction of the
## caster's health bar. Named because it is a balance figure two kits depend on
## (Rally, Ward) and tools/balancetest.gd has to read it to measure sustain.
const SHIELD_OF_MAX_HEALTH: float = 0.30
```

…and use it at the call site, so the harness can `preload` it instead of
restating it.

**2. `scripts/game/MageSpells.gd` — Shadow's element rider does nothing.**
Not a balance curve finding, so it is listed here rather than above. `for_hero`
sets `s1.applies = ELEMENT_STATUS[elem]` but never sets `s1.applies_magnitude`,
and `Combat.cast` only defaults a magnitude for BURN:

```gdscript
if ability.applies == StatusEffect.Kind.BURN and mag <= 0.0:
    mag = caster.attack_power() * 0.18
```

`WEAKEN` therefore lands with magnitude 0.0, and
`Combatant.outgoing_multiplier()` returns `1.0 - 0.0` — no effect at all. Every
Shadow mage in the roster is a mage with no rider **and** without Arcane's
`+0.22` damage compensation for having none. Either default WEAKEN's magnitude
in `Combat.cast` the way BURN is defaulted, or author
`s1.applies_magnitude` in `MageSpells`.
