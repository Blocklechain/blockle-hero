extends SceneTree
# Proves the one thing about the campaign clear reward that costs real money to
# get wrong: clearing a whole difficulty pays ONE spawn crystal, ONCE EVER.
#
# A spawn crystal is a premium IAP currency, so "grant once" here is the same
# invariant storetest.gd defends for purchases, approached from the other side:
# the free payout must not be farmable by replaying the last map, by reloading
# the save, or by shipping the feature into a save file that predates it.
#
# NOTHING in this file hardcodes 4, 8, 16 or 100. The campaign's shape is read
# from Campaign, because the enum is being widened to eight difficulties and the
# map count to a hundred while this test exists — a test that restated either
# number would start passing against the wrong campaign.

var fails: int = 0

func check(label: String, ok: bool, detail: String = "") -> void:
	if not ok:
		fails += 1
	print("  %s %-56s %s" % ["PASS" if ok else "FAIL", label, detail])


func _init() -> void:
	var heroes: PackedStringArray = HeroRig.animated_heroes()
	if heroes.is_empty():
		print("no hero models found"); quit(); return

	var tiers: int = Roster.difficulty_count()
	var maps: int = Roster.maps_per_difficulty()
	print("\n=== the campaign's own shape, not this test's ===")
	print("  %d difficulties x %d maps, reward %d crystal(s)" % [
		tiers, maps, Roster.DIFFICULTY_REWARD_CRYSTALS])
	check("the counts come from Campaign",
		tiers == Campaign.Tier.size() and maps == Campaign.region_count(),
		"Tier.size()=%d region_count()=%d" % [Campaign.Tier.size(),
			Campaign.region_count()])
	check("there is more than one map and more than one difficulty",
		maps > 1 and tiers > 1)

	# No save file is ever touched: `Roster` is built in memory and round-tripped
	# through its own dictionary, so running this cannot damage a real account.
	var r := Roster.create(heroes, 9931)
	var completed: Array[int] = []
	var paid: Array[int] = []
	r.difficulty_completed.connect(
		func(t: int) -> void: completed.append(t))
	r.difficulty_reward_granted.connect(
		func(t: int, n: int) -> void: paid.append(n))

	var tier: int = Campaign.Tier.NORMAL
	var start: int = r.wallet.crystals

	# --- every map but one ---------------------------------------------
	print("\n=== %d of %d maps cleared pays nothing ===" % [maps - 1, maps])
	var granted_so_far: int = 0
	for i in range(maps - 1):
		granted_so_far += r.record_map_cleared(tier, i)
	check("not one crystal for an unfinished difficulty",
		granted_so_far == 0 and r.wallet.crystals == start,
		"%d crystals" % r.wallet.crystals)
	check("progress is counted exactly",
		r.cleared_map_count(tier) == maps - 1,
		"%d/%d" % [r.cleared_map_count(tier), maps])
	check("the difficulty does not read as cleared",
		not r.is_difficulty_cleared(tier))
	check("nothing is claimed", not r.difficulty_reward_claimed(tier))
	check("no completion was announced", completed.is_empty())

	# Re-clearing maps already beaten must not advance anything. This is the
	# replay a counter would have been fooled by.
	for i in range(maps - 1):
		granted_so_far += r.record_map_cleared(tier, i)
	check("re-clearing beaten maps changes neither progress nor wallet",
		granted_so_far == 0 and r.cleared_map_count(tier) == maps - 1
		and r.wallet.crystals == start,
		"%d/%d, %d crystals" % [r.cleared_map_count(tier), maps,
			r.wallet.crystals])

	# --- the last map ---------------------------------------------------
	print("\n=== the final map pays exactly one crystal ===")
	var last: int = maps - 1
	var payout: int = r.record_map_cleared(tier, last)
	check("the clearing call reports the grant",
		payout == Roster.DIFFICULTY_REWARD_CRYSTALS, "returned %d" % payout)
	check("exactly one crystal reached the wallet",
		r.wallet.crystals == start + Roster.DIFFICULTY_REWARD_CRYSTALS,
		"%d -> %d" % [start, r.wallet.crystals])
	check("the difficulty reads as cleared and claimed",
		r.is_difficulty_cleared(tier) and r.difficulty_reward_claimed(tier))
	check("completion announced once",
		completed.size() == 1 and completed[0] == tier, str(completed))
	check("the payout announced matches the payout made",
		paid.size() == 1 and paid[0] == Roster.DIFFICULTY_REWARD_CRYSTALS,
		str(paid))
	check("the grant is in the wallet ledger with a reason",
		JSON.stringify(r.wallet.ledger).contains("difficulty_cleared:%d" % tier))

	# --- doing it again -------------------------------------------------
	print("\n=== beating it again pays nothing ===")
	var held: int = r.wallet.crystals
	var again: int = r.record_map_cleared(tier, last)
	check("re-clearing the final map grants none",
		again == 0 and r.wallet.crystals == held, "%d crystals" % held)
	for i in range(maps):
		again += r.record_map_cleared(tier, i)
	check("re-clearing the entire difficulty grants none",
		again == 0 and r.wallet.crystals == held, "%d crystals" % held)
	check("no second completion or payout was announced",
		completed.size() == 1 and paid.size() == 1,
		"%d completions, %d payouts" % [completed.size(), paid.size()])

	# --- the difficulties are independent -------------------------------
	print("\n=== each difficulty carries its own one-time reward ===")
	var other: int = tier + 1
	check("clearing one difficulty claimed nothing on the next",
		not r.is_difficulty_cleared(other)
		and not r.difficulty_reward_claimed(other)
		and r.cleared_map_count(other) == 0)
	var second: int = 0
	for i in range(maps):
		second += r.record_map_cleared(other, i)
	check("the next difficulty pays its own single crystal",
		second == Roster.DIFFICULTY_REWARD_CRYSTALS
		and r.wallet.crystals == held + Roster.DIFFICULTY_REWARD_CRYSTALS,
		"%d crystals" % r.wallet.crystals)

	# --- out of range ---------------------------------------------------
	print("\n=== a bad tier or map index pays nothing and stores nothing ===")
	var junk := Roster.create(heroes, 77)
	var bad: int = junk.record_map_cleared(tiers, 0) \
		+ junk.record_map_cleared(-1, 0) \
		+ junk.record_map_cleared(tier, maps) \
		+ junk.record_map_cleared(tier, -1)
	check("refused, with no crystal and no save state",
		bad == 0 and junk.wallet.crystals == 0 and junk.cleared_maps.is_empty()
		and junk.difficulty_claimed.is_empty())

	# --- the save file --------------------------------------------------
	print("\n=== it survives the one save file, through real JSON ===")
	var text: String = JSON.stringify(r.to_dict())
	var parsed = JSON.parse_string(text)
	check("the save is still valid JSON", typeof(parsed) == TYPE_DICTIONARY)
	var back := Roster.from_dict(parsed, heroes)
	check("the cleared set survives",
		back.cleared_map_count(tier) == maps
		and back.cleared_map_count(other) == maps,
		"%d and %d of %d" % [back.cleared_map_count(tier),
			back.cleared_map_count(other), maps])
	var every_index: bool = true
	for i in range(maps):
		if not back.is_map_cleared(tier, i):
			every_index = false
	check("...map by map, not just by count", every_index)
	check("the claimed flags survive",
		back.difficulty_reward_claimed(tier)
		and back.difficulty_reward_claimed(other))
	check("the crystals survive", back.wallet.crystals == r.wallet.crystals,
		"%d crystals" % back.wallet.crystals)
	var after_load: int = 0
	for i in range(maps):
		after_load += back.record_map_cleared(tier, i)
	check("a reload cannot re-earn the reward",
		after_load == 0 and back.wallet.crystals == r.wallet.crystals,
		"%d crystals" % back.wallet.crystals)
	check("the save carries no second progress file",
		r.to_dict().has("cleared_maps")
		and r.to_dict().has("claimed_difficulties")
		and Roster.SAVE_PATH == "user://roster.json")

	# A save round-tripped twice must be byte-identical, or the cleared set is
	# being reordered and no two saves can ever be compared.
	check("a second round trip is identical",
		JSON.stringify(back.to_dict()) == JSON.stringify(
			Roster.from_dict(JSON.parse_string(
				JSON.stringify(back.to_dict())), heroes).to_dict()))

	# --- a save from before this existed --------------------------------
	print("\n=== a legacy save loads clean, and free ===")
	var legacy: Dictionary = r.to_dict()
	legacy.erase("cleared_maps")
	legacy.erase("claimed_difficulties")
	var old := Roster.from_dict(
		JSON.parse_string(JSON.stringify(legacy)), heroes)
	var any_cleared: bool = false
	var any_claimed: bool = false
	for t in range(tiers):
		if old.cleared_map_count(t) != 0 or old.is_difficulty_cleared(t):
			any_cleared = true
		if old.difficulty_reward_claimed(t):
			any_claimed = true
	check("nothing cleared", not any_cleared)
	check("nothing claimed", not any_claimed)
	check("loading granted no crystals of its own",
		old.wallet.crystals == r.wallet.crystals,
		"%d crystals, same as the save it came from" % old.wallet.crystals)
	# The failure this guards is the worst one available: shipping the feature
	# and handing every existing player a crystal per difficulty on first launch.
	var mass: int = 0
	for t in range(tiers):
		mass += old._claim_difficulty_reward(t)
	check("a legacy save cannot claim %d rewards it never earned" % tiers,
		mass == 0 and old.wallet.crystals == r.wallet.crystals,
		"%d crystals granted" % mass)
	# ...but it is not written off either: the player can still earn it.
	var earned: int = 0
	for i in range(maps):
		earned += old.record_map_cleared(tier, i)
	check("a legacy save can still earn the reward by clearing",
		earned == Roster.DIFFICULTY_REWARD_CRYSTALS,
		"%d crystal(s)" % earned)

	# --- a tampered or stale save ---------------------------------------
	print("\n=== a save that cannot prove a clear does not get paid ===")
	var forged: Dictionary = Roster.create(heroes, 5).to_dict()
	# Junk indices and a short list: a save written against a longer campaign,
	# or edited by hand. Key count alone would read this as complete.
	forged["cleared_maps"] = {str(tier): [0, 999999, 1000000]}
	var fake := Roster.from_dict(
		JSON.parse_string(JSON.stringify(forged)), heroes)
	check("out-of-range indices do not count as progress",
		fake.cleared_map_count(tier) == 1 and not fake.is_difficulty_cleared(tier),
		"%d of %d" % [fake.cleared_map_count(tier), maps])
	check("...and claim nothing", fake._claim_difficulty_reward(tier) == 0
		and fake.wallet.crystals == 0)

	print("\n=== %d failure(s) ===" % fails)
	# GATES THE BUILD. This was a bare `quit()`, which always exits 0, so
	# this harness counted its failures, printed them, and passed the
	# build regardless. Five tests in CI had the same hole.
	quit(1 if fails > 0 else 0)