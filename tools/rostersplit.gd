extends SceneTree
# Audits the consequences of shipping ONLY the animated subset of heroes.
# Compares the rarity/class distribution of the full tex/ roster against the
# animated/ roster, and checks the two hard invariants:
#   * Roster.open_crystal() refunds (and hands back nothing) if a rarity tier
#     has zero champions.
#   * Champion.starters() yields fewer than 3 heroes unless there is at least
#     one COMMON of each class.

const ANIM_DIR := "/Volumes/ExtremePro/raid/assets/heroes/animated"
const TEX_DIR := "/Volumes/ExtremePro/raid/assets/heroes/tex"

const TIERS := [Item.Rarity.COMMON, Item.Rarity.UNCOMMON, Item.Rarity.RARE,
	Item.Rarity.EPIC, Item.Rarity.LEGENDARY]
const CLASSES := [HeroClass.Kind.FIGHTER, HeroClass.Kind.RANGER,
	HeroClass.Kind.MAGE]

var fails: int = 0


func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, detail])


func names_in(d: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(d)
	if dir == null:
		return out
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if f.ends_with(".glb"):
			out.append(f.get_basename())
		f = dir.get_next()
	out.sort()
	return out


func report(label: String, heroes: PackedStringArray) -> Dictionary:
	print("\n=== %s : %d heroes ===" % [label, heroes.size()])
	var rc: Dictionary = {}
	var cc: Dictionary = {}
	var cross: Dictionary = {}   # "tier|class" -> count
	for h in heroes:
		var r: int = Champion.rarity_of(h)
		var c: int = HeroClass.for_hero(h)
		rc[r] = int(rc.get(r, 0)) + 1
		cc[c] = int(cc.get(c, 0)) + 1
		var k: String = "%d|%d" % [r, c]
		cross[k] = int(cross.get(k, 0)) + 1

	print("  rarity:")
	for t in TIERS:
		var n: int = int(rc.get(t, 0))
		print("    %-10s %3d  (%5.2f%%, design target %5.2f%%)" % [
			String(Item.RARITY_NAMES[t]), n,
			100.0 * float(n) / float(maxi(heroes.size(), 1)),
			100.0 * float(Champion.RARITY_WEIGHTS[t])])
	print("  class:")
	for c in CLASSES:
		var n2: int = int(cc.get(c, 0))
		print("    %-10s %3d  (%5.2f%%)" % [HeroClass.display_name(c), n2,
			100.0 * float(n2) / float(maxi(heroes.size(), 1))])
	print("  rarity x class:")
	print("    %-10s %8s %8s %8s" % ["", "Fighter", "Ranger", "Mage"])
	for t in TIERS:
		var row: String = "    %-10s" % String(Item.RARITY_NAMES[t])
		for c in CLASSES:
			row += " %8d" % int(cross.get("%d|%d" % [t, c], 0))
		print(row)
	return {"rarity": rc, "class": cc, "cross": cross}


func _init() -> void:
	var anim: PackedStringArray = names_in(ANIM_DIR)
	var tex: PackedStringArray = names_in(TEX_DIR)
	print("HeroRig.animated_heroes() returns %d heroes (the gated playable roster)"
		% HeroRig.animated_heroes().size())

	# which tex names are missing from animated
	var animset: Dictionary = {}
	for h in anim:
		animset[h] = true
	var missing := PackedStringArray()
	for h in tex:
		if not animset.has(h):
			missing.append(h)
	print("\n=== static-only heroes (in tex/, NOT in animated/) : %d ==="
		% missing.size())
	print("  " + ", ".join(missing))

	var full: Dictionary = report("FULL ROSTER (tex/, 200)", tex)
	var cut: Dictionary = report("ANIMATED-ONLY ROSTER (animated/)", anim)

	print("\n=== invariants on the animated-only roster ===")
	var rc: Dictionary = cut["rarity"]
	for t in TIERS:
		check("rarity tier %s is non-empty" % String(Item.RARITY_NAMES[t]),
			int(rc.get(t, 0)) > 0, "%d heroes" % int(rc.get(t, 0)))
	check("all 5 rarity tiers populated (open_crystal never dead-ends)",
		rc.size() == 5, "%d/5 tiers" % rc.size())

	var cc: Dictionary = cut["class"]
	for c in CLASSES:
		check("class %s is non-empty" % HeroClass.display_name(c),
			int(cc.get(c, 0)) > 0, "%d heroes" % int(cc.get(c, 0)))

	var cross: Dictionary = cut["cross"]
	for c in CLASSES:
		var n: int = int(cross.get("%d|%d" % [Item.Rarity.COMMON, c], 0))
		check("COMMON %s exists (starters needs one)"
			% HeroClass.display_name(c), n > 0, "%d heroes" % n)

	# Prove it through the real call paths, not just the counts.
	var st: PackedStringArray = Champion.starters(anim)
	check("Champion.starters() returns 3", st.size() == 3, ", ".join(st))
	var st_classes: Array = []
	for h in st:
		st_classes.append(HeroClass.display_name(HeroClass.for_hero(h)))
	check("starters cover all three classes",
		st_classes.has("Fighter") and st_classes.has("Ranger")
			and st_classes.has("Mage"), ", ".join(st_classes))

	for t in TIERS:
		var pool: PackedStringArray = Champion.of_rarity(anim, t)
		check("Champion.of_rarity(%s) non-empty" % String(Item.RARITY_NAMES[t]),
			not pool.is_empty(), "%d in pool" % pool.size())

	# Live crystal test: open many crystals, count refunds (empty results).
	var r := Roster.create(anim, 12345)
	r.wallet.grant(Wallet.Kind.CRYSTALS, 2000, "audit")
	var refunds: int = 0
	var got: Dictionary = {}
	for i in range(2000):
		var res: Dictionary = r.open_crystal()
		if res.is_empty():
			refunds += 1
			continue
		got[res["rarity"]] = int(got.get(res["rarity"], 0)) + 1
	check("open_crystal() never refunds on an empty pool", refunds == 0,
		"%d refunds in 2000 opens" % refunds)
	var line: String = ""
	for t in TIERS:
		line += "%s=%d " % [String(Item.RARITY_NAMES[t]), int(got.get(t, 0))]
	print("    crystal results by tier: " + line)
	print("    champions owned after 2000 crystals: %d / %d"
		% [r.owned.size(), anim.size()])

	# What the cut costs per tier.
	print("\n=== delta (full -> animated-only) ===")
	var fr: Dictionary = full["rarity"]
	for t in TIERS:
		var a: int = int(fr.get(t, 0))
		var b: int = int(rc.get(t, 0))
		print("  %-10s %3d -> %3d  (%+d)" % [String(Item.RARITY_NAMES[t]), a, b,
			b - a])
	var fc: Dictionary = full["class"]
	for c in CLASSES:
		var a2: int = int(fc.get(c, 0))
		var b2: int = int(cc.get(c, 0))
		print("  %-10s %3d -> %3d  (%+d)" % [HeroClass.display_name(c), a2, b2,
			b2 - a2])

	print("\n=== %d failure(s) ===" % fails)
	quit()
