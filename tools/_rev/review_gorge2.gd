extends SceneTree
const Spells := preload("res://scripts/game/MageSpells.gd")
const Elite := preload("res://scripts/game/Elite.gd")

func _init() -> void:
	print("--- Campaign.enemy_health_mult by tier ---")
	for t in range(Campaign.max_tier() + 1):
		print("  tier %2d  hp_mult %.2f  name %s" % [t,
			Campaign.enemy_health_mult(t),
			Campaign.tier_name(t)])

	print("--- does health flatline? CHAIN mage, cd 3.0, burn 5.0s, L30, tier-scaled bar ---")
	var mult: float = float(Spells.FORM_DAMAGE[Spells.Form.CHAIN]) * (3.0 / 3.8)
	var g: Combatant = _enemy(30, Campaign.enemy_health_mult(Campaign.max_tier()))
	Elite.apply(g, Elite.Trait.GORGING)
	var mage: Combatant = _hero(30)
	var last_move: int = -1
	var prev: float = g.health
	for i in range(400):
		mage.strike(g, mult, "Bolt")
		if g.alive:
			g.apply(StatusEffect.make(StatusEffect.Kind.BURN, 5.0,
				mage.attack_power() * 0.18, "Bolt"))
		g.tick(3.5)
		if absf(g.health - prev) > 0.0001:
			last_move = i
			prev = g.health
		if i < 8 or i == 399:
			var w: StatusEffect = g.effect_of(StatusEffect.Kind.SHIELD)
			print("  cast %3d  hp %.1f/%.1f  ward %.1f" % [i, g.health,
				g.max_health, w.magnitude if w != null else 0.0])
	print("  mult %.3f  mage AP %.1f  direct/cast %.1f  ward granted %.1f" % [
		mult, mage.attack_power(), mage.attack_power() * mult * (1.0 - g.mitigation()),
		minf(mage.attack_power() * 0.18 * 10.0 * Elite.GORGE_WARD,
			g.max_health * Elite.GORGE_WARD_CAP)])
	print("  LAST cast that moved health: %d of 400.  alive=%s  hp %.1f/%.1f" % [
		last_move, g.alive, g.health, g.max_health])
	quit(0)

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
