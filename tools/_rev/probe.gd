extends SceneTree

const Spells := preload("res://scripts/game/MageSpells.gd")

func _init() -> void:
	# A REAL mage rotation against Gorging, using Combat.gd's own figures:
	# direct damage = strike(ability.damage_mult); burn = attack_power()*0.18
	# for ability.applies_duration seconds.
	for form_mult in [1.90, 1.19, 0.86, 0.68]:
		for armour in [0.0]:
			var g: Combatant = Combatant.make("gorger", Combatant.Team.ENEMY, 10,
				Stats.make(12, 12, 12, 12), HeroClass.School.MELEE, 12.0, armour, 5)
			Elite.apply(g, Elite.Trait.GORGING)
			var mage: Combatant = Combatant.make("mage", Combatant.Team.PLAYER, 10,
				Stats.make(12, 12, 12, 12), HeroClass.School.SPELL, 12.0, 0.0, 9)
			var casts: int = 0
			var hp0: float = g.health
			while g.alive and casts < 500:
				mage.strike(g, form_mult, "Bolt")
				if g.alive:
					g.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0,
						mage.attack_power() * 0.18, "Bolt"))
				g.tick(0.5)   # a cast every half second-ish; burn gets to tick
				casts += 1
			print("form_mult %.2f  AP %.1f  mh %.1f  casts %d  alive %s  hp %.1f/%.1f" % [
				form_mult, mage.attack_power(), g.max_health, casts, g.alive, g.health, hp0])
	# And without any tick at all (pure per-cast economy)
	for form_mult in [1.90, 0.68]:
		var g2: Combatant = Combatant.make("gorger", Combatant.Team.ENEMY, 10,
			Stats.make(12, 12, 12, 12), HeroClass.School.MELEE, 12.0, 0.0, 5)
		Elite.apply(g2, Elite.Trait.GORGING)
		var m2: Combatant = Combatant.make("mage", Combatant.Team.PLAYER, 10,
			Stats.make(12, 12, 12, 12), HeroClass.School.SPELL, 12.0, 0.0, 9)
		var c2: int = 0
		while g2.alive and c2 < 500:
			m2.strike(g2, form_mult, "Bolt")
			if g2.alive:
				g2.apply(StatusEffect.make(StatusEffect.Kind.BURN, 4.0,
					m2.attack_power() * 0.18, "Bolt"))
			c2 += 1
		var w: StatusEffect = g2.effect_of(StatusEffect.Kind.SHIELD)
		print("NO-TICK form %.2f casts %d alive %s hp %.1f/%.1f ward %.1f" % [
			form_mult, c2, g2.alive, g2.health, g2.max_health,
			w.magnitude if w != null else 0.0])
	quit(0)
