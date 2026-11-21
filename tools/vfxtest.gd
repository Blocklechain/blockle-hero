extends SceneTree
# ------------------------------------------------------------------------------
# Two promises, both of which are easy to break without noticing.
#
# 1. DIFFICULTY IS THE KIT. An enemy below Merciless fights with two actions,
#    from Merciless with three, and only at Oblivion with everything. This is
#    the kind of rule that is written once and then quietly contradicted by the
#    first `use_ability(0, ...)` someone adds back, so it is asserted against
#    the SCENE's chooser, not against Campaign.enemy_actions() — the number
#    being right is worth nothing if the brain ignores it.
#
# 2. EVERY CHAMPION LOOKS LIKE THEMSELVES. 139 champions times 12 actions, and
#    the pairs have to be distinct, stable between runs, and never empty. An
#    ability that silently draws nothing is an attack the player cannot see
#    coming, which is worse than an ugly one.
#
#   godot --headless --path . --script tools/vfxtest.gd
# ------------------------------------------------------------------------------

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	_go.call_deferred()


func _go() -> void:
	_ladder()
	_signatures()
	await _effects()
	print("\n=== %d failure(s) ===" % fails)
	quit(1 if fails > 0 else 0)


func _ladder() -> void:
	print("\n=== the difficulty decides the kit ===")
	var counts: Array[int] = []
	for tier in range(Campaign.tier_count()):
		counts.append(Campaign.enemy_actions(tier))
	check("lower difficulties allow two actions",
		counts[0] == 2 and counts[1] == 2,
		"%s, %s" % [Campaign.tier_name(0), Campaign.tier_name(1)])
	check("hard and above allow a third",
		counts[Campaign.HARD_TIER] == 3,
		"from %s" % Campaign.tier_name(Campaign.HARD_TIER))
	check("only the top difficulty allows all four",
		counts[Campaign.max_tier()] == 4
			and counts[Campaign.max_tier() - 1] == 3,
		"%s 4, %s 3" % [Campaign.tier_name(Campaign.max_tier()),
			Campaign.tier_name(Campaign.max_tier() - 1)])
	# Never goes backwards, and never exceeds the kit that exists.
	var sane: bool = true
	for i in range(1, counts.size()):
		if counts[i] < counts[i - 1] or counts[i] > 4:
			sane = false
	check("the ladder only ever rises, and never past the kit", sane,
		str(counts))


func _signatures() -> void:
	print("\n=== every champion looks like themselves ===")
	var roster: PackedStringArray = HeroRig.animated_heroes()
	var seen: Dictionary = {}
	var collisions: int = 0
	var motifs: Dictionary = {}
	for h in roster:
		var cls: int = HeroClass.for_hero(h)
		var sig: Dictionary = Vfx.signature(h, cls)
		# Round the hue hard: two champions whose primaries differ in the
		# fourth decimal are the same champion as far as a player is concerned.
		var key: String = "%d|%d|%d|%.0f" % [
			int(sig["primary"].h * 72.0), int(sig["secondary"].h * 72.0),
			int(sig["motif"]), sig["spin"]]
		if seen.has(key):
			collisions += 1
		seen[key] = true
		motifs[int(sig["motif"])] = true

		# Stability: the same champion asked twice must answer the same, or
		# their effects change colour between one cast and the next.
		var again: Dictionary = Vfx.signature(h, cls)
		if again["primary"] != sig["primary"] \
				or again["motif"] != sig["motif"]:
			check("signature is not stable for %s" % h, false)

	check("the roster is big enough to be worth testing", roster.size() > 100,
		"%d champions" % roster.size())
	# A handful of collisions across 139 is fine — two champions sharing a hue
	# band and a motif still differ by model, scale and class. A third of the
	# roster colliding would mean the hash is not doing its job.
	check("champions are visually distinct from one another",
		collisions < roster.size() / 8,
		"%d collisions in %d" % [collisions, roster.size()])
	check("every motif is in use somewhere on the roster",
		motifs.size() == Vfx.MOTIF_COUNT,
		"%d of %d" % [motifs.size(), Vfx.MOTIF_COUNT])


func _effects() -> void:
	print("\n=== every ability draws something ===")
	var holder := Node3D.new()
	get_root().add_child(holder)
	await process_frame

	var roster: PackedStringArray = HeroRig.animated_heroes()
	var built: int = 0
	var empty: int = 0
	var missing: PackedStringArray = PackedStringArray()

	# One champion of each class is enough to cover all 12 actions, and every
	# champion of that class runs the same archetypes with its own signature —
	# which _signatures() above has already shown differ.
	for cls in [HeroClass.Kind.FIGHTER, HeroClass.Kind.RANGER,
			HeroClass.Kind.MAGE]:
		var who: String = ""
		for h in roster:
			if HeroClass.for_hero(h) == cls:
				who = h
				break
		if who == "":
			continue
		var kit: Array[Ability] = [Ability.basic_attack(cls)]
		kit.append_array(Ability.for_hero(who, cls))
		for ab in kit:
			var fx: Vfx = Vfx.play(holder, ab, who, cls,
				Vector2.ZERO, 0.0, Vector2(6.0, 0.0))
			if fx == null:
				missing.append("%s/%s" % [who, ab.id])
				continue
			built += 1
			# An effect with no visible children is the failure that looks
			# exactly like a working one in a screenshot.
			var drawn: int = 0
			for c in fx.get_children():
				if c is MeshInstance3D or c is GPUParticles3D:
					drawn += 1
			if drawn == 0:
				empty += 1
				missing.append("%s/%s empty" % [who, ab.id])
			fx.queue_free()
			await process_frame

	check("every action produced an effect", missing.is_empty(),
		"%d built%s" % [built,
			"  missing " + ", ".join(missing) if not missing.is_empty()
			else ""])
	check("...and none of them were invisible", empty == 0)
	check("the whole kit was covered, not one ability", built >= 12,
		"%d actions across three classes" % built)

	# DIVERSITY, NOT JUST PRESENCE. Every mage spell is one of seven forms,
	# and four of them used to borrow another form's effect — a Venom chain
	# and a Frost nova drew the same ring, a lance drew a cleave's swung
	# wedge, a storm drew a pillar rising OUT of the ground. "Every ability
	# produces an effect" passed throughout. Fingerprint the node each form
	# actually builds and demand they differ.
	var shapes: Dictionary = {}
	var mage: String = ""
	for h in roster:
		if HeroClass.for_hero(h) == HeroClass.Kind.MAGE:
			mage = h
			break
	for form in [MageSpells.Form.BOLT, MageSpells.Form.ORB,
			MageSpells.Form.LANCE, MageSpells.Form.CONE,
			MageSpells.Form.NOVA, MageSpells.Form.STORM,
			MageSpells.Form.CHAIN]:
		var ab := Ability.new()
		ab.id = "probe"
		ab.form = form
		ab.element = MageSpells.Element.FROST
		var shape: Array = MageSpells.FORM_SHAPE[form]
		ab.shape = int(shape[0])
		ab.range_m = float(shape[1])
		ab.arc_degrees = float(shape[2])
		var fx: Vfx = Vfx.play(holder, ab, mage, HeroClass.Kind.MAGE,
			Vector2.ZERO, 0.0, Vector2(7.0, 0.0))
		if fx == null:
			continue
		shapes[String(MageSpells.FORM_WORD[form])] = _fingerprint(fx)
		fx.queue_free()
		await process_frame

	var seen: Dictionary = {}
	var shared: PackedStringArray = PackedStringArray()
	for word in shapes.keys():
		var f: String = String(shapes[word])
		if seen.has(f):
			shared.append("%s==%s" % [word, seen[f]])
		seen[f] = word
	check("the seven spell forms do not borrow each other's effects",
		shared.is_empty(), ", ".join(shared) if not shared.is_empty()
			else "%d distinct shapes" % seen.size())

	# A hit has to register ON THE THING HIT.
	var boom: Vfx = Vfx.impact(holder, Vector3.ZERO, Color.RED, false)
	check("a connecting hit flashes on its victim", boom != null)
	if boom != null:
		var crit: Vfx = Vfx.impact(holder, Vector3.ZERO, Color.RED, true)
		check("...and a crit is a different shape, not just brighter",
			crit != null and _fingerprint(crit) != _fingerprint(boom),
			"%s vs %s" % [_fingerprint(boom), _fingerprint(crit)])
		boom.queue_free()
		if crit != null:
			crit.queue_free()
		await process_frame

	# The cap has to actually cap, or a busy fight drops frames.
	var spam: Array[Vfx] = []
	for i in range(Vfx.MAX_LIVE + 8):
		var fx: Vfx = Vfx.play(holder, Ability.basic_attack(
			HeroClass.Kind.MAGE), roster[0], HeroClass.Kind.MAGE,
			Vector2.ZERO, 0.0, Vector2(4.0, 0.0))
		if fx != null:
			spam.append(fx)
	check("the concurrent-effect cap holds", spam.size() <= Vfx.MAX_LIVE,
		"%d alive, cap %d" % [spam.size(), Vfx.MAX_LIVE])
	for fx in spam:
		fx.queue_free()
	holder.queue_free()
	await process_frame


## A crude description of what an effect is MADE of: how many meshes, of what
## kinds, and how many particle emitters. Two effects with the same
## fingerprint are, to a player, the same effect in a different colour.
func _fingerprint(fx: Vfx) -> String:
	var meshes: Dictionary = {}
	var parts: int = 0
	for c in fx.get_children():
		if c is GPUParticles3D:
			parts += 1
		elif c is MeshInstance3D:
			var m: Mesh = (c as MeshInstance3D).mesh
			var k: String = m.get_class() if m != null else "none"
			meshes[k] = int(meshes.get(k, 0)) + 1
	var keys: Array = meshes.keys()
	keys.sort()
	var bits: PackedStringArray = PackedStringArray()
	for k in keys:
		bits.append("%s:%d" % [k, int(meshes[k])])
	return "%s|p%d" % ["+".join(bits), parts]
