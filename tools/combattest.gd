extends SceneTree
# Combat, tested headlessly. Balance is the easiest thing in a game to get
# quietly wrong, and a system you can only check by playing it is one nobody
# re-checks after a tuning change.

var fails: int = 0

func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-54s %s" % ["PASS" if ok else "FAIL", label, detail])


func _mk(name: String, team: int, lv: int, cls: int, seed: int) -> Combatant:
	var st: Stats = HeroClass.base_stats(cls).plus(HeroClass.growth_to(cls, lv))
	return Combatant.make(name, team, lv, st, HeroClass.school_of(cls),
		10.0, 20.0, seed)


func _init() -> void:
	print("\n=== the stun rule ===")
	var hero := _mk("hero", Combatant.Team.PLAYER, 20, HeroClass.Kind.FIGHTER, 1)
	check("unstunned: can act", hero.can_act())
	check("unstunned: full speed", is_equal_approx(hero.move_multiplier(), 1.0))

	hero.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "test"))
	check("STUNNED: still moves (never frozen)", hero.move_multiplier() > 0.0,
		"x%.2f speed" % hero.move_multiplier())
	check("STUNNED: but slower", hero.move_multiplier() < 1.0,
		"x%.2f" % hero.move_multiplier())
	check("STUNNED: cannot use abilities", not hero.can_act())
	hero.tick(2.1)
	check("stun expires", not hero.is_stunned() and hero.can_act())

	check("stuns refresh, never stack",
		_stack_test(), "two 2s stuns != 4s")

	print("\n=== damage ===")
	var a := _mk("att", Combatant.Team.PLAYER, 20, HeroClass.Kind.FIGHTER, 2)
	var d := _mk("def", Combatant.Team.ENEMY, 20, HeroClass.Kind.FIGHTER, 3)
	var hp0: float = d.health

	var res: Dictionary = a.strike(d, 1.0)
	check("a hit removes health", d.health < hp0,
		"%.0f -> %.0f" % [hp0, d.health])
	check("armour mitigates but never fully", d.mitigation() > 0.0
		and d.mitigation() <= Combatant.MAX_MITIGATION,
		"%.0f%% mitigated" % (d.mitigation() * 100.0))

	# Mitigation must not run away with level.
	var tanky := Combatant.make("tank", Combatant.Team.ENEMY, 60,
		HeroClass.base_stats(HeroClass.Kind.FIGHTER), HeroClass.School.MELEE,
		0.0, 100000.0, 9)
	check("mitigation is capped", tanky.mitigation() <= Combatant.MAX_MITIGATION,
		"%.0f%% with absurd armour" % (tanky.mitigation() * 100.0))

	var shielded := _mk("sh", Combatant.Team.ENEMY, 20, HeroClass.Kind.FIGHTER, 4)
	shielded.apply(StatusEffect.make(StatusEffect.Kind.SHIELD, 10.0, 500.0, "t"))
	var before: float = shielded.health
	a.strike(shielded, 1.0)
	check("shields absorb before health", is_equal_approx(shielded.health, before),
		"shield took it")

	var burner := _mk("burn", Combatant.Team.ENEMY, 20, HeroClass.Kind.FIGHTER, 5)
	burner.apply(StatusEffect.make(StatusEffect.Kind.BURN, 2.0, 10.0, "t"))
	var bh: float = burner.health
	burner.tick(1.0)
	check("burn ticks over time", burner.health < bh,
		"-%.0f hp" % (bh - burner.health))

	print("\n=== abilities reach the right targets ===")
	var caster := _mk("caster", Combatant.Team.PLAYER, 25, HeroClass.Kind.FIGHTER, 6)
	var ctx := Combat.Context.new()
	ctx.caster = caster
	ctx.origin = Vector2.ZERO
	ctx.facing = 0.0        # facing +Z
	for i in range(6):
		var e := _mk("e%d" % i, Combatant.Team.ENEMY, 20, HeroClass.Kind.FIGHTER, 10 + i)
		ctx.targets.append(e)
	# three in front, two behind, one far away
	ctx.positions = PackedVector2Array([
		Vector2(0, 2), Vector2(1.2, 2), Vector2(-1.2, 2),
		Vector2(0, -2), Vector2(1, -2), Vector2(0, 40)])

	var kit: Array[Ability] = Ability.for_hero("test", HeroClass.Kind.FIGHTER)
	var cleave: Ability = kit[0]
	var r: Combat.Result = Combat.cast(cleave, ctx)
	check("arc hits only what is in front", r.hit.size() == 3, r.describe())
	check("nothing out of range is hit",
		not r.hit.has(ctx.targets[5]), "40m target ignored")

	var slam: Ability = kit[1]
	var r2: Combat.Result = Combat.cast(slam, ctx)
	var stunned_any: bool = false
	for t in r2.hit:
		if t.is_stunned():
			stunned_any = true
	check("control ability applies STUN", stunned_any, r2.describe())
	for t in r2.hit:
		if t.is_stunned():
			check("stunned enemy cannot act", not t.can_act())
			check("stunned enemy still moves", t.move_multiplier() > 0.0,
				"x%.2f" % t.move_multiplier())
			break

	var rally: Ability = kit[2]
	caster._take_raw(caster.max_health * 0.5, false, "setup")
	var hurt: float = caster.health
	Combat.cast(rally, ctx)
	check("self ability heals the caster", caster.health > hurt,
		"%.0f -> %.0f" % [hurt, caster.health])
	check("self ability shields the caster",
		caster.has(StatusEffect.Kind.SHIELD))

	print("\n=== every mage has unique spells ===")
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	var mages: PackedStringArray = PackedStringArray()
	for h in heroes:
		if HeroClass.for_hero(h) == HeroClass.Kind.MAGE:
			mages.append(h)
	print("  %d mages in a roster of %d" % [mages.size(), heroes.size()])

	var books: Dictionary = {}
	var spell_names: Dictionary = {}
	var elements: Dictionary = {}
	for m in mages:
		var kit_m: Array[Ability] = MageSpells.for_hero(m)
		var sig: String = "%s|%s|%s" % [kit_m[0].title, kit_m[1].title, kit_m[2].title]
		books[sig] = int(books.get(sig, 0)) + 1
		for sp in kit_m:
			spell_names[sp.title] = true
		var el: String = MageSpells.element_name(m)
		elements[el] = int(elements.get(el, 0)) + 1

	check("every mage has exactly 3 abilities",
		mages.size() == 0 or MageSpells.for_hero(mages[0]).size() == 3)
	check("no two mages share a spellbook", books.size() == mages.size(),
		"%d distinct books for %d mages" % [books.size(), mages.size()])
	print("  %d distinct spell names across all mages" % spell_names.size())
	print("  elements in play: %s" % ", ".join(elements.keys()))

	# Deterministic: the same mage must always get the same book.
	if mages.size() > 0:
		var again: Array[Ability] = MageSpells.for_hero(mages[0])
		var first: Array[Ability] = MageSpells.for_hero(mages[0])
		check("a mage's spells are stable across calls",
			again[0].title == first[0].title and again[1].title == first[1].title)

	# BALANCE: unique must not mean unequal.
	var lo: float = INF
	var hi: float = 0.0
	var lo_m: String = ""
	var hi_m: String = ""
	for m in mages:
		var p: float = MageSpells.kit_power(m)
		if p < lo:
			lo = p
			lo_m = m
		if p > hi:
			hi = p
			hi_m = m
	var spread: float = hi / maxf(lo, 0.0001)
	check("mage kits stay within 1.6x of each other", spread < 1.6,
		"%.2fx  (weakest %s %.2f, strongest %s %.2f)" % [spread, lo_m, lo, hi_m, hi])

	print("\n  sample spellbooks:")
	for i in range(mini(4, mages.size())):
		var m: String = mages[i]
		print("    %-9s [%-8s] %s" % [m, MageSpells.element_name(m),
			" / ".join(_titles(MageSpells.for_hero(m)))])

	print("\n=== fighters and rangers share a class kit ===")
	var f1: Array[Ability] = Ability.for_hero("aldous", HeroClass.Kind.FIGHTER)
	var f2: Array[Ability] = Ability.for_hero("brom", HeroClass.Kind.FIGHTER)
	check("two fighters have the same kit (learnable role)",
		f1[0].title == f2[0].title and f1[1].title == f2[1].title,
		f1[0].title)
	check("every class kit has exactly 3 abilities",
		Ability.for_hero("x", HeroClass.Kind.RANGER).size() == 3)
	check("slot grammar holds: slot 2 always controls",
		f1[1].applies == StatusEffect.Kind.STUN
		and Ability.for_hero("x", HeroClass.Kind.RANGER)[1].applies
			== StatusEffect.Kind.STUN
		and (mages.size() == 0 or MageSpells.for_hero(mages[0])[1].applies
			== StatusEffect.Kind.STUN))

	print("\n=== %d failure(s) ===" % fails)
	# GATES THE BUILD. This was a bare `quit()`, which always exits 0, so
	# this harness counted its failures, printed them, and passed the
	# build regardless. Five tests in CI had the same hole.
	quit(1 if fails > 0 else 0)
func _titles(kit: Array[Ability]) -> PackedStringArray:
	var out := PackedStringArray()
	for a in kit:
		out.append(a.title)
	return out


func _stack_test() -> bool:
	var c := _mk("s", Combatant.Team.ENEMY, 10, HeroClass.Kind.FIGHTER, 77)
	c.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "a"))
	c.apply(StatusEffect.make(StatusEffect.Kind.STUN, 2.0, 0.0, "b"))
	c.tick(2.1)
	return not c.is_stunned()
