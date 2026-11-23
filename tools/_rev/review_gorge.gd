extends SceneTree
# REVIEW SCRATCH — delete after. Asks the one question the report claims is
# structurally impossible: can a real mage, casting its real slot-1 spell with
# Combat.cast's own arithmetic, fail to move a Gorging elite's health bar?

const Spells := preload("res://scripts/game/MageSpells.gd")
const Elite := preload("res://scripts/game/Elite.gd")


func _init() -> void:
	# A real enemy body, then its health scaled the way Campaign's tiers scale
	# it, so we can see where the 0.30*max_health ward cap stops binding.
	for hp_mult in [1.0, 2.0, 4.0, 8.0, 20.0]:
		for level in [10, 30, 60]:
			var worst_frac: float = 2.0
			var worst: String = ""
			var survivors: int = 0
			var tried: int = 0
			for mult in _slot1_mults():
				for dur in [3.0, 4.0, 5.0]:
					tried += 1
					var g: Combatant = _enemy(level, hp_mult)
					Elite.apply(g, Elite.Trait.GORGING)
					var mage: Combatant = _hero(level)
					var hp0: float = g.max_health
					var lowest: float = g.health
					for i in range(400):
						if not g.alive:
							break
						# Exactly what Combat.cast does, in its order: strike,
						# then the burn whose magnitude is attack_power()*0.18.
						mage.strike(g, mult, "Bolt")
						if g.alive:
							g.apply(StatusEffect.make(StatusEffect.Kind.BURN,
								dur, mage.attack_power() * 0.18, "Bolt"))
						g.tick(3.5)   # one cooldown of real time between casts
						lowest = minf(lowest, g.health)
					if g.alive:
						survivors += 1
						var frac: float = (hp0 - lowest) / hp0
						if frac < worst_frac:
							worst_frac = frac
							worst = "mult %.2f burn %.1fs" % [mult, dur]
			if worst != "":
				print("hp_mult %5.1f L%-3d  %d/%d kits SURVIVED 400 casts; worst %s took %.2f%% of the bar off" % [
					hp_mult, level, survivors, tried, worst, worst_frac * 100.0])
			else:
				print("hp_mult %5.1f L%-3d  all %d kits killed it" % [hp_mult, level, tried])
	quit(0)


## Every slot-1 damage_mult the generator can actually produce: FORM_DAMAGE for
## the four slot-1 forms x element bonus x the cooldown/3.8 normalisation.
func _slot1_mults() -> Array:
	var out: Array = []
	for form in Spells.SLOT1_FORMS:
		for bonus in [0.0, 0.22, -0.10, -0.05]:
			for cd in [3.0, 3.8, 4.6]:
				out.append(float(Spells.FORM_DAMAGE[form]) * (1.0 + bonus)
					* (cd / 3.8))
	return out


func _enemy(level: int, hp_mult: float) -> Combatant:
	var base: Stats = HeroClass.base_stats(HeroClass.Kind.FIGHTER)
	var grown: Stats = base.plus(HeroClass.growth_to(HeroClass.Kind.FIGHTER, level))
	var c: Combatant = Combatant.make("elite", Combatant.Team.ENEMY, level, grown,
		HeroClass.school_of(HeroClass.Kind.FIGHTER), 4.0 * float(level),
		3.0 * float(level), 77)
	c.max_health *= hp_mult
	c.health = c.max_health
	return c


func _hero(level: int) -> Combatant:
	var base: Stats = HeroClass.base_stats(HeroClass.Kind.MAGE)
	var grown: Stats = base.plus(HeroClass.growth_to(HeroClass.Kind.MAGE, level))
	return Combatant.make("mage", Combatant.Team.PLAYER, level, grown,
		HeroClass.school_of(HeroClass.Kind.MAGE), 4.0 * float(level), 0.0, 9)
