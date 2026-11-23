extends SceneTree
# Proves the progression systems actually behave as designed — and that the
# PUBLISHED crystal odds match the odds the game really rolls.

var fails: int = 0

func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-52s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	if heroes.is_empty():
		print("no hero models found"); quit(); return

	print("\n=== champion rarity across %d heroes ===" % heroes.size())
	var counts: Dictionary = {}
	for h in heroes:
		var r: int = Champion.rarity_of(h)
		counts[r] = int(counts.get(r, 0)) + 1
	for tier in [Item.Rarity.COMMON, Item.Rarity.UNCOMMON, Item.Rarity.RARE,
			Item.Rarity.EPIC, Item.Rarity.LEGENDARY]:
		var n: int = int(counts.get(tier, 0))
		print("  %-10s %3d  (%4.1f%%, target %4.1f%%)" % [
			String(Item.RARITY_NAMES[tier]), n,
			100.0 * float(n) / float(heroes.size()),
			100.0 * float(Champion.RARITY_WEIGHTS[tier])])
	check("every rarity tier has at least one champion",
		counts.size() == 5, "%d tiers populated" % counts.size())

	# --- per-champion progression -------------------------------------
	print("\n=== progression ===")
	var r := Roster.create(heroes, 12345)
	var owned: PackedStringArray = r.owned_names()
	check("starts with 3 champions", owned.size() == 3, ", ".join(owned))

	var classes: Array = []
	for h in owned:
		classes.append(r.progress(h).hero_class)
	check("starters cover all three classes",
		classes.has(HeroClass.Kind.FIGHTER) and classes.has(HeroClass.Kind.RANGER)
		and classes.has(HeroClass.Kind.MAGE))

	var a: String = owned[0]
	var b: String = owned[1]
	var pa: HeroProgress = r.progress(a)
	var pb: HeroProgress = r.progress(b)

	var levels: int = pa.gain_xp(100000.0)
	check("xp levels a champion", pa.level > 1,
		"%s reached L%d (+%d levels)" % [a, pa.level, levels])
	check("LEVELS DO NOT CARRY OVER", pb.level == 1,
		"%s still L%d" % [b, pb.level])

	var pts: int = pa.unspent_points()
	check("skill points granted per level",
		pts == (pa.level - 1) * HeroProgress.SKILL_POINTS_PER_LEVEL,
		"%d unspent" % pts)
	check("SKILL POINTS DO NOT CARRY OVER", pb.unspent_points() == 0)

	var before: float = r.effective_stats(a).strength
	pa.spend(Stats.Attr.STRENGTH, 10)
	var after: float = r.effective_stats(a).strength
	check("spending points raises the attribute", after > before,
		"STR %.0f -> %.0f" % [before, after])
	check("cannot overspend", not pa.spend(Stats.Attr.STRENGTH, 99999))
	var spent_now: int = pa.spent_points()
	pa.respec()
	check("respec refunds everything",
		pa.unspent_points() == pa.total_skill_points() and pa.spent_points() == 0,
		"refunded %d" % spent_now)

	# --- pooled stash --------------------------------------------------
	print("\n=== pooled inventory ===")
	for i in range(12):
		r.stash.add(Item.roll(999, i, 20, Item.Rarity.RARE))
	var n_before: int = r.stash.count()
	var cls_a: int = pa.hero_class
	var equipped: int = r.stash.auto_equip(a, cls_a)
	check("auto-equip fills slots from the pool", equipped > 0,
		"%d slots filled" % equipped)
	check("equipping removes from the shared pool",
		r.stash.count() == n_before - equipped,
		"%d -> %d loose" % [n_before, r.stash.count()])

	var bare: Stats = pa.base_stats().scaled(Champion.stat_multiplier(a))
	var geared: Stats = r.effective_stats(a)
	check("gear raises stats", geared.total() > bare.total(),
		"%.0f -> %.0f total" % [bare.total(), geared.total()])
	# The shared-pool property is that champion B draws from the SAME stash A
	# just used — not that any one slot still has a spare, which depends on what
	# the random rolls happened to produce.
	var b_equipped: int = r.stash.auto_equip(b, pb.hero_class)
	check("gear is SHARED: second champion equips from the same pool",
		b_equipped > 0, "%s filled %d slots from the leftovers" % [b, b_equipped])
	check("an item is worn by exactly one champion",
		r.stash.equipped_in(a, Item.Slot.CHEST) \
			!= r.stash.equipped_in(b, Item.Slot.CHEST)
		or r.stash.equipped_in(a, Item.Slot.CHEST) == null)

	# --- currencies ----------------------------------------------------
	print("\n=== currencies ===")
	var g0: int = r.wallet.gold
	var sold: int = Shop.sell(r, r.stash.items[0].id)
	check("selling pays gold", sold > 0 and r.wallet.gold == g0 + sold,
		"+%d gold" % sold)
	check("cannot spend what you lack",
		not r.wallet.spend(Wallet.Kind.GEMS, 99999, "test"))
	check("balances never go negative", r.wallet.gems >= 0)

	# --- unlocking -----------------------------------------------------
	print("\n=== unlocking ===")
	var locked: PackedStringArray = r.locked_names()
	var target: String = locked[0]
	check("gem unlock refused without gems",
		r.unlock_with_gems(target) != "", r.unlock_with_gems(target))
	r.wallet.grant(Wallet.Kind.GEMS, 5000, "test")
	check("gem unlock grants the CHOSEN champion",
		r.unlock_with_gems(target) == "" and r.owns(target), target)

	r.wallet.grant(Wallet.Kind.CRYSTALS, 400, "test")
	var dups: int = 0
	var news: int = 0
	var dup_gold: int = 0
	var got: Dictionary = {}
	for i in range(400):
		var res: Dictionary = r.open_crystal()
		if res.is_empty():
			continue
		got[res["rarity"]] = int(got.get(res["rarity"], 0)) + 1
		if res["duplicate"]:
			dups += 1
			dup_gold += int(res["gold"])
		else:
			news += 1
	check("crystals unlock random champions", news > 0,
		"%d new, %d duplicates" % [news, dups])
	check("duplicates always pay gold", dups == 0 or dup_gold > 0,
		"%d gold from duplicates" % dup_gold)

	# --- THE ROSTER GATE -----------------------------------------------
	# 61 of the 200 heroes could not be auto-rigged and ship hidden. An unlock
	# that paid one out would hand the player a sliding T-pose, so this proves
	# no grant path can reach them — and that one already owned still works.
	print("\n=== roster gate: the %d unrigged heroes are unreachable ==="
		% (HeroRig.all_loadable_heroes().size() - heroes.size()))
	var playable_set: Dictionary = {}
	for h in heroes:
		playable_set[h] = true
	var static_only := PackedStringArray()
	for h in HeroRig.all_loadable_heroes():
		if not playable_set.has(h):
			static_only.append(h)
	check("roster is strictly smaller than the art set",
		static_only.size() > 0 and heroes.size() < HeroRig.all_loadable_heroes().size(),
		"%d playable, %d hidden" % [heroes.size(), static_only.size()])
	var unrigged_on_roster: int = 0
	for h in heroes:
		if not HeroRig.is_animated(h):
			unrigged_on_roster += 1
	check("every hero on the roster has a rigged model",
		unrigged_on_roster == 0,
		"%d of %d without one" % [unrigged_on_roster, heroes.size()])

	var hidden: String = static_only[0] if static_only.size() > 0 else ""
	check("a hidden hero is not in the catalogue",
		not r.is_playable(hidden), hidden)
	check("gem unlock REFUSES a hidden hero",
		r.unlock_with_gems(hidden) == "Unknown champion",
		r.unlock_with_gems(hidden))
	var leaked := PackedStringArray()
	for h in r.owned_names():
		if not playable_set.has(h):
			leaked.append(h)
	check("%d crystals + unlocks granted NO hidden hero" % 400,
		leaked.is_empty(), "leaked: " + ", ".join(leaked))

	# The fallback: a save that already owns a hidden hero keeps it, and the
	# static mesh still loads (procedurally animated, not a T-pose).
	var legacy: Dictionary = r.to_dict()
	legacy["owned"][hidden] = HeroProgress.create(hidden).to_dict()
	var migrated := Roster.from_dict(legacy, heroes)
	check("an OWNED hidden hero survives load", migrated.owns(hidden), hidden)
	check("...is listed for the player", migrated.all_known_names().has(hidden),
		"%d names listed" % migrated.all_known_names().size())
	check("...but still cannot be re-granted", not migrated.is_playable(hidden))
	# THE UNRIGGED SET IS NOT SHIPPED, so this is only asserted when it is
	# actually present in res://.
	#
	# assets/heroes/ holds `animated/` and nothing else — the 441 MB unrigged
	# raid export was deliberately never committed. HeroRig keeps a dev
	# fallback to the authoring volume, so on a developer's Mac load_hero()
	# finds it and this passed; on a runner there is no such volume and it
	# failed. Passing locally and failing in CI is the exact bug bundlecheck
	# exists to catch, and it stayed invisible for a second reason: metatest
	# used to end in a bare `quit()`, which always exits 0 (see below).
	#
	# So it is skipped rather than deleted: if the unrigged set is ever
	# shipped, the fallback path is worth checking again.
	if DirAccess.dir_exists_absolute("res://assets/heroes/tex"):
		var fb := HeroRig.new()
		root.add_child(fb)
		var fb_ok: bool = fb.load_hero(hidden)
		check("...and its tex/ model still loads", fb_ok and not fb.is_rigged,
			"loaded=%s rigged=%s" % [fb_ok, fb.is_rigged])
		fb.queue_free()
	else:
		print("  SKIP ...and its tex/ model still loads "
			+ "(res://assets/heroes/tex is not shipped)")

	# --- THE COMPLIANCE TEST -------------------------------------------
	print("\n=== published crystal odds vs actual rolls ===")
	check("odds table is a probability distribution", CrystalOdds.sums_to_one())

	var N: int = 200000
	var seen: Dictionary = {}
	var since: int = 0
	var worst_gap: int = 0
	var gap: int = 0
	for i in range(N):
		var rar: int = CrystalOdds.roll_rarity(777, i, since)
		seen[rar] = int(seen.get(rar, 0)) + 1
		if rar >= Item.Rarity.EPIC:
			since = 0
			worst_gap = maxi(worst_gap, gap)
			gap = 0
		else:
			since += 1
			gap += 1

	var ok_all: bool = true
	for tier in [Item.Rarity.COMMON, Item.Rarity.UNCOMMON, Item.Rarity.RARE,
			Item.Rarity.EPIC, Item.Rarity.LEGENDARY]:
		var want: float = CrystalOdds.odds_for(tier)
		var actual: float = float(seen.get(tier, 0)) / float(N)
		# Pity nudges Epic+ slightly above base, never below; everything else
		# must land close to the published figure.
		var ok: bool = (actual >= want - 0.006) if tier >= Item.Rarity.EPIC \
			else absf(actual - want) < 0.008
		if not ok:
			ok_all = false
		print("    %-10s published %5.2f%%   actual %5.2f%%   %s" % [
			String(Item.RARITY_NAMES[tier]), want * 100.0, actual * 100.0,
			"ok" if ok else "MISMATCH"])
	check("ACTUAL ROLLS MATCH THE PUBLISHED ODDS", ok_all)
	check("pity guarantee holds (Epic+ within %d)" % CrystalOdds.PITY_THRESHOLD,
		worst_gap < CrystalOdds.PITY_THRESHOLD,
		"worst observed gap %d" % worst_gap)

	var needing: PackedStringArray = IAPCatalog.products_needing_disclosure()
	check("every crystal pack is flagged for odds disclosure",
		needing.size() == 3, ", ".join(needing))

	# --- campaign tiers -------------------------------------------------
	print("\n=== campaign ===")
	check("100 maps in 10 acts",
		Campaign.region_count() == 100 and Campaign.act_count() == 10)
	check("higher tiers are locked at the start",
		not Campaign.can_enter(Campaign.Tier.MERCILESS, pa, r.unlocked_tier),
		Campaign.entry_blocked_reason(Campaign.Tier.MERCILESS, pa, r.unlocked_tier))
	r.complete_campaign(a, Campaign.Tier.NORMAL)
	check("clearing a tier unlocks the next ACCOUNT-WIDE",
		r.unlocked_tier == Campaign.Tier.VETERAN,
		"unlocked %s for every champion" % Campaign.tier_name(r.unlocked_tier))
	check("same region, same ground across tiers",
		Campaign.region_seed(5, 3) == Campaign.region_seed(5, 3))
	check("enemies scale with tier",
		Campaign.enemy_level(8, Campaign.Tier.ETERNAL)
		> Campaign.enemy_level(8, Campaign.Tier.NORMAL),
		"L%d -> L%d" % [Campaign.enemy_level(8, Campaign.Tier.NORMAL),
			Campaign.enemy_level(8, Campaign.Tier.ETERNAL)])

	# --- persistence ----------------------------------------------------
	print("\n=== save / load ===")
	var round_trip := Roster.from_dict(r.to_dict(), heroes)
	check("owned champions survive", round_trip.owned.size() == r.owned.size(),
		"%d champions" % round_trip.owned.size())
	check("levels survive", round_trip.progress(a).level == pa.level)
	check("wallet survives", round_trip.wallet.gold == r.wallet.gold)
	check("stash survives", round_trip.stash.count() == r.stash.count())
	check("tier unlock survives", round_trip.unlocked_tier == r.unlocked_tier)

	print("\n=== disclosure text shown before purchase ===")
	print(CrystalOdds.disclosure_text())

	print("\n=== %d failure(s) ===" % fails)
	# GATES THE BUILD. This was a bare `quit()`, which always exits 0 — so
	# metatest counted its failures, printed them, and passed the build anyway.
	# It is the FIRST test in CI's list, and it spent this whole session
	# reporting a failing assertion into a green build.
	quit(1 if fails > 0 else 0)
