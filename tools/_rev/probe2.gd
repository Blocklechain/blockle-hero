extends SceneTree

const Spells := preload("res://scripts/game/MageSpells.gd")

# Worst-but-REAL mage: the weakest slot-1 form (CHAIN 0.68) on the shortest
# cooldown (3.0 -> x0.79) with the longest burn MageSpells can roll (5.0s).
func _init() -> void:
	for level in [5, 10, 20, 40, 60]:
		for mult in [0.68 * (3.0 / 3.8), 0.86, 1.19, 1.90]:
			for dur in [3.0, 5.0]:
				var g: Combatant = _enemy(level)
				Elite.apply(g, Elite.Trait.GORGING)
				var mage: Combatant = _enemy(level)
				mage.team = Combatant.Team.PLAYER
				var casts: int = 0
				var floor_hp: float = g.health
				while g.alive and casts < 2000:
					mage.strike(g, mult, "Bolt")
					if g.alive:
						g.apply(StatusEffect.make(StatusEffect.Kind.BURN, dur,
							mage.attack_power() * 0.18, "Bolt"))
					g.tick(0.5)
					floor_hp = minf(floor_hp, g.health)
					casts += 1
				if g.alive:
					print("L%-3d mult %.2f dur %.1f  UNKILLABLE after %d casts  hp %.1f/%.1f (lowest %.1f)  mit %.2f" % [
						level, mult, dur, casts, g.health, g.max_health, floor_hp,
						g.mitigation()])
				else:
					print("L%-3d mult %.2f dur %.1f  dead in %d casts" % [level, mult, dur, casts])
	quit(0)

func _enemy(level: int) -> Combatant:
	var base: Stats = HeroClass.base_stats(HeroClass.Kind.MAGE)
	var grown: Stats = base.plus(HeroClass.growth_to(HeroClass.Kind.MAGE, level))
	return Combatant.make("e", Combatant.Team.ENEMY, level, grown,
		HeroClass.School.SPELL, 4.0 * float(level), 3.0 * float(level), 77)
