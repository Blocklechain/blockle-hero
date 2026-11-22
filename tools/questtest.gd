extends SceneTree
# ------------------------------------------------------------------------------
# A QUEST MUST BE COMPLETABLE WHEN IT IS OFFERED.
#
# That is the whole point of this harness, and it is not something arithmetic
# can be trusted on, because the two ways to break it are both invisible from
# the player's side:
#
#   * A quest naming a map the tier has SEALED. They look for it, cannot find
#     it, and conclude the UI is broken.
#   * A quest asking for a rarity the tier CANNOT DROP. They grind for an
#     evening and conclude the drop rate is a lie.
#
# Neither produces an error, a log line, or a crash. So the board is offered
# across every tier and every state of progress and every offer is checked
# against what that tier can actually produce.
#
# The second half is the WIRING, which is where this project's bugs actually
# live: a quest system that is unit-tested and connected to nothing is the
# default outcome. So these drive the real Roster, the real QuestScreen, and a
# summary shaped exactly like the one Play builds — and the screen test is
# forbidden from calling the thing it is testing. It presses the button.
# ------------------------------------------------------------------------------

const QuestS := preload("res://scripts/game/Quest.gd")
const QuestScreenS := preload("res://scripts/ui/QuestScreen.gd")

var _fails: int = 0
var _done: int = 0

func check(label: String, ok: bool, note: String = "") -> void:
	print("  %s %-58s %s" % ["PASS" if ok else "FAIL", label, note])
	if not ok:
		_fails += 1


func _roster(tier: int = Campaign.Tier.NORMAL, cleared: int = 0) -> Roster:
	var r := Roster.create(HeroRig.animated_heroes(), 4242)
	r.unlocked_tier = tier
	for i in range(cleared):
		r.record_map_cleared(tier, i)
	return r


func _init() -> void:
	_offers_are_possible(); _done += 1
	_progress(); _done += 1
	_board(); _done += 1
	_persistence(); _done += 1
	await _the_screen(); _done += 1
	_scaling(); _done += 1
	_the_scratch_account(); _done += 1
	print("")
	check("every section ran to completion", _done == 7, "%d of 7" % _done)
	print("\n=== %d failure(s) ===" % _fails)
	quit(1 if _fails > 0 else 0)


# ---- the invariant -----------------------------------------------------------

func _offers_are_possible() -> void:
	print("\n=== every offer is possible ===")
	var reachable: int = 0
	var droppable: int = 0
	var checked: int = 0
	var kinds: Dictionary = {}

	for tier in range(Campaign.tier_count()):
		var ceiling: int = Loot.rarity_ceiling(tier)
		# Every state of progress, not a sampled few: the bug is in the
		# arithmetic that maps "how far you are" onto "which map to name", and
		# that is exactly the kind of thing that is right for 90 values and
		# off by one at the ends.
		for furthest in range(Campaign.map_count()):
			for power in [1, 12, 50, 99]:
				var q: QuestS = QuestS.offer(777, checked, tier, furthest,
					power)
				checked += 1
				kinds[q.kind] = int(kinds.get(q.kind, 0)) + 1
				if q.region >= 0 and q.region <= furthest:
					reachable += 1
				if q.kind != QuestS.Kind.FIND_RARITY or q.want <= ceiling:
					droppable += 1

	check("every offer names a map the player has unlocked",
		reachable == checked, "%d of %d" % [reachable, checked])
	check("...and never asks for a rarity the tier cannot drop",
		droppable == checked, "%d of %d" % [droppable, checked])
	check("...and the board uses every kind of quest",
		kinds.size() == 5, "%d kinds over %d offers" % [kinds.size(), checked])

	# THE LOWEST TIER IS THE DANGEROUS ONE: it has the tightest rarity
	# ceiling, so it is where a rarity quest is most likely to be impossible.
	var floor_ceiling: int = Loot.rarity_ceiling(0)
	var bad: int = 0
	for i in range(400):
		var q: QuestS = QuestS.offer(11, i, 0, 40, 20)
		if q.kind == QuestS.Kind.FIND_RARITY and q.want > floor_ceiling:
			bad += 1
	check("no impossible rarity quest on the lowest difficulty", bad == 0,
		"%d bad" % bad)

	# A BRAND NEW ACCOUNT, which has unlocked exactly map 0 — the degenerate
	# case where lo, span and region all collapse to zero.
	var fresh: int = 0
	for i in range(60):
		var q: QuestS = QuestS.offer(99, i, 0, 0, 1)
		if q.region == 0 and q.need >= 1:
			fresh += 1
	check("a brand new account gets quests for map 0", fresh == 60,
		"%d of 60" % fresh)

	# Offers must not be identical: three rows of the same quest is a board
	# that looks broken even when it is working.
	var seen: Dictionary = {}
	for i in range(30):
		var q: QuestS = QuestS.offer(5, i, 2, 60, 30)
		seen["%d/%d/%d" % [q.kind, q.region, q.want]] = true
	check("consecutive offers differ", seen.size() > 10,
		"%d distinct of 30" % seen.size())

	# EVERY OFFER PAYS SOMETHING. A contract worth zero gold is a contract
	# that tells the player, after they finish it, that it was not worth
	# doing — and the screen would say "Paid 0 gold".
	var unpaid: int = 0
	for tier in range(Campaign.tier_count()):
		for i in range(120):
			if QuestS.offer(31, i, tier, 50, 1).reward_gold <= 0:
				unpaid += 1
	check("every offer is worth gold", unpaid == 0, "%d unpaid" % unpaid)


# ---- progress against a real summary -----------------------------------------

## Shaped exactly like what Play emits, so a key renamed on one side fails here.
func _summary(region: int, tier: int, extra: Dictionary = {}) -> Dictionary:
	var s: Dictionary = {
		"region": region, "tier": tier, "cleared_this_run": true,
		"elites_killed": 0, "depth_reached": 0,
	}
	for sl in range(Item.Slot.size()):
		s["drops_slot_%d" % sl] = 0
	for r in range(Item.RARITY_NAMES.size()):
		s["drops_at_least_%d" % r] = 0
	for k in extra.keys():
		s[k] = extra[k]
	return s


func _progress() -> void:
	print("\n=== progress ===")

	# CLEAR_MAP — the right map on the right difficulty, and nothing else.
	var q := QuestS.new()
	q.kind = QuestS.Kind.CLEAR_MAP
	q.region = 7
	q.tier = 1
	q.need = 1
	check("the wrong map does not count",
		not q.note_run(_summary(6, 1)) and not q.is_complete())
	check("the right map on the wrong difficulty does not count",
		not q.note_run(_summary(7, 0)) and not q.is_complete())
	check("abandoning the right map does not count",
		not q.note_run(_summary(7, 1, {"cleared_this_run": false})))
	check("clearing it does", q.note_run(_summary(7, 1)) and q.is_complete())
	check("...and a replay does not advance it further",
		not q.note_run(_summary(7, 1)))

	# FIND_RARITY — "at least", so good luck is never punished.
	var r := QuestS.new()
	r.kind = QuestS.Kind.FIND_RARITY
	r.region = 3
	r.tier = 0
	r.want = Item.Rarity.RARE
	r.need = 1
	check("a common drop does not finish a Rare contract",
		not r.note_run(_summary(3, 0, {"drops_at_least_2": 0})))
	check("...but something BETTER than asked for does",
		r.note_run(_summary(3, 0, {"drops_at_least_2": 1}))
			and r.is_complete())

	# FIND_SLOT — boots, not "something good".
	var sl := QuestS.new()
	sl.kind = QuestS.Kind.FIND_SLOT
	sl.region = 2
	sl.tier = 0
	sl.want = Item.Slot.FEET
	sl.need = 2
	sl.note_run(_summary(2, 0, {"drops_slot_%d" % Item.Slot.HEAD: 3}))
	check("the wrong slot does not count", sl.done == 0, "%d" % sl.done)
	sl.note_run(_summary(2, 0, {"drops_slot_%d" % Item.Slot.FEET: 1}))
	check("the right slot counts, and partially", sl.done == 1
		and not sl.is_complete())
	sl.note_run(_summary(2, 0, {"drops_slot_%d" % Item.Slot.FEET: 5}))
	check("...and progress is CLAMPED to what was asked",
		sl.done == 2 and sl.is_complete(), "%d of %d" % [sl.done, sl.need])

	# SLAY_ELITES — anywhere, so place and difficulty are both ignored.
	var e := QuestS.new()
	e.kind = QuestS.Kind.SLAY_ELITES
	e.region = 4
	e.tier = 2
	e.need = 10
	e.note_run(_summary(0, 0, {"elites_killed": 4}))
	e.note_run(_summary(90, 3, {"elites_killed": 4}))
	check("elites count from anywhere, on any difficulty", e.done == 8,
		"%d" % e.done)

	# REACH_DEPTH — the BEST reached, not the sum, or three shallow runs
	# complete a deep contract.
	var d := QuestS.new()
	d.kind = QuestS.Kind.REACH_DEPTH
	d.need = 10
	d.note_run(_summary(0, 0, {"depth_reached": 6}))
	d.note_run(_summary(0, 0, {"depth_reached": 5}))
	check("depth takes the deepest run, it does not accumulate", d.done == 6,
		"%d" % d.done)
	check("...and a shallower run cannot un-do progress", d.done == 6)
	d.note_run(_summary(0, 0, {"depth_reached": 10}))
	check("...and reaching it finishes the contract", d.is_complete())

	# A CAMPAIGN clear reports depth 0, so it must not satisfy a Descent
	# contract.
	var d2 := QuestS.new()
	d2.kind = QuestS.Kind.REACH_DEPTH
	d2.need = 4
	d2.note_run(_summary(50, 1))
	check("a campaign clear does not advance a Descent contract",
		d2.done == 0, "%d" % d2.done)


# ---- the board ---------------------------------------------------------------

func _board() -> void:
	print("\n=== the board ===")
	var r := _roster(Campaign.Tier.NORMAL, 20)

	var board: Array = r.quest_board()
	check("the board is full", board.size() == Roster.QUEST_SLOTS,
		"%d" % board.size())
	var all_real: bool = true
	for q in board:
		if q == null or not (q is QuestS):
			all_real = false
	check("...with real quests in every slot", all_real)

	# Claiming an unfinished quest must pay NOTHING.
	var before: int = r.wallet.balance(Wallet.Kind.GOLD)
	check("an unfinished contract cannot be claimed",
		r.claim_quest(0).is_empty()
			and r.wallet.balance(Wallet.Kind.GOLD) == before)

	# Finish one by hand and claim it.
	var q0: QuestS = r.quest(0)
	q0.done = q0.need
	var paid: Dictionary = r.claim_quest(0)
	check("a finished contract pays", not paid.is_empty()
		and int(paid.get("gold", 0)) > 0, "%d gold" % int(paid.get("gold", 0)))
	check("...and the gold actually lands",
		r.wallet.balance(Wallet.Kind.GOLD) == before + int(paid["gold"]))
	check("...and the slot is REPLACED, not left dead",
		r.quest(0) != null and r.quest(0) != q0 and not r.quest(0).is_complete())
	check("...and it cannot be claimed twice", r.claim_quest(0).is_empty())

	# Out-of-range indices must be refusals, not crashes.
	check("a nonsense index is a refusal", r.claim_quest(99).is_empty()
		and r.claim_quest(-1).is_empty() and r.quest(99) == null
		and not r.reroll_quest(7))

	# Re-rolling: free, but never on a finished quest.
	var q1: QuestS = r.quest(1)
	check("an unfinished contract can be swapped", r.reroll_quest(1)
		and r.quest(1) != q1)
	var q2: QuestS = r.quest(2)
	q2.done = q2.need
	check("a FINISHED contract cannot be swapped away",
		not r.reroll_quest(2) and r.quest(2) == q2)

	# THE COUNTER ONLY GOES UP, which is what stops reload-rerolling.
	var counted: int = r.quest_counter
	r.reroll_quest(0)
	check("every offer advances the counter", r.quest_counter > counted,
		"%d -> %d" % [counted, r.quest_counter])

	# A board offered at Merciless must name Merciless-reachable maps, not
	# Normal ones.
	var hard := _roster(Campaign.HARD_TIER, 5)
	var right_tier: bool = true
	for q in hard.quest_board():
		var quest_obj := q as QuestS
		if quest_obj.tier != Campaign.HARD_TIER:
			right_tier = false
		if quest_obj.region > hard.furthest_unlocked(Campaign.HARD_TIER):
			right_tier = false
	check("the board is offered at the highest unlocked difficulty",
		right_tier)


# ---- it survives a restart ---------------------------------------------------

func _persistence() -> void:
	print("\n=== surviving a restart ===")
	var r := _roster(Campaign.Tier.NORMAL, 30)
	var board: Array = r.quest_board()
	var q0: QuestS = board[0]
	q0.done = maxi(q0.need - 1, 0)   # Half done, which is the risky state.
	var counter: int = r.quest_counter

	var back := Roster.from_dict(r.to_dict(), HeroRig.animated_heroes())
	var b0: QuestS = back.quest(0)
	check("the board survives", back.quest_board().size()
		== Roster.QUEST_SLOTS)
	check("...with the same contracts", b0.kind == q0.kind
		and b0.region == q0.region and b0.want == q0.want)
	check("...and PARTIAL progress is not lost", b0.done == q0.done,
		"%d vs %d" % [b0.done, q0.done])
	check("...and the counter does not rewind", back.quest_counter == counter,
		"%d vs %d" % [back.quest_counter, counter])

	# A save written before quests existed must load and get a fresh board —
	# scaled to the account it loaded, not to a blank one. This is the bug
	# that an _ensure_quests() call inside from_dict would have caused: the
	# board would be filled before `owned` and `cleared_maps` were read.
	var old: Dictionary = r.to_dict()
	old.erase("quests")
	old.erase("quest_counter")
	old.erase("quest_seed")
	var migrated := Roster.from_dict(old, HeroRig.animated_heroes())
	check("a save from before contracts loads with a full board",
		migrated.quest_board().size() == Roster.QUEST_SLOTS)
	var scaled: bool = false
	for q in migrated.quest_board():
		# furthest_unlocked is 30 for this save, so a board built against a
		# blank roster would be stuck naming maps 0-1.
		if (q as QuestS).region > 5:
			scaled = true
	check("...scaled to the progress in that save, not to a blank one",
		scaled, "furthest unlocked is %d"
			% migrated.furthest_unlocked(Campaign.Tier.NORMAL))

	# A board with a hole in it must not renumber.
	var holed: Dictionary = r.to_dict()
	var qs: Array = holed["quests"]
	qs[1] = {}
	var patched := Roster.from_dict(holed, HeroRig.animated_heroes())
	check("an empty slot is refilled in place, without shifting the others",
		patched.quest(0).kind == q0.kind
			and patched.quest(0).done == q0.done)


# ---- THE WIRING --------------------------------------------------------------

func _the_screen() -> void:
	print("\n=== the screen, and the run that feeds it ===")
	var r := _roster(Campaign.Tier.NORMAL, 25)

	# Force a known quest into slot 0 so there is something to finish.
	# Through quest_board() first, because the board is built LAZILY — the
	# array is empty until something asks for it, and writing quests[0] on a
	# roster nobody has read the board from is an index error.
	r.quest_board()
	var q := QuestS.new()
	q.kind = QuestS.Kind.CLEAR_MAP
	q.region = 12
	q.tier = Campaign.Tier.NORMAL
	q.need = 1
	# A hand-built quest is not an OFFER, so it has no reward unless one is
	# set — and a claim that pays nothing is indistinguishable from a claim
	# that is broken.
	q.reward_gold = 500
	r.quests[0] = q

	# A RUN, routed the way Play routes it. Not QuestS.note_run() directly:
	# that would pass with the roster hook missing, which is the failure this
	# whole project keeps producing.
	var finished: PackedStringArray = r.note_quest_run(
		_summary(12, Campaign.Tier.NORMAL))
	check("a finished run is reported through the ROSTER",
		finished.size() == 1, "%d reported" % finished.size())
	check("...naming the contract it finished",
		finished.size() == 1 and String(finished[0]) == q.title(),
		"" if finished.is_empty() else String(finished[0]))
	check("...and the board agrees", r.quest(0).is_complete())
	check("...and a second identical run reports nothing new",
		r.note_quest_run(_summary(12, Campaign.Tier.NORMAL)).is_empty())

	# THE SCREEN. Built for real, and driven only by pressing its buttons.
	var screen: UiScreen = QuestScreenS.new()
	screen.roster = r
	screen.hero = r.owned_names()[0]
	var notices: Array = []
	# A ONE-ELEMENT ARRAY, not an int. GDScript lambdas capture locals BY
	# VALUE, so `saves += 1` inside one increments a copy and the counter
	# outside stays at zero — which reads as "the screen never asked the
	# shell to save" when it did.
	var saves: Array = [0]
	var routes: Array = []
	screen.notified.connect(func(t: String) -> void: notices.append(t))
	screen.state_changed.connect(func() -> void: saves[0] += 1)
	screen.navigate.connect(func(route: String, arg: Variant) -> void:
		routes.append([route, arg]))
	root.add_child(screen)
	# A Control's _ready — and so UiScreen.build() — is deferred to the first
	# PROCESSED FRAME, not to add_child. Without this the screen is an empty
	# node and every assertion below reads "0 buttons", which looks like the
	# screen is broken rather than like the harness never let it start.
	await process_frame

	var buttons: Array = _buttons(screen)
	check("the screen builds and has buttons", buttons.size() >= 3,
		"%d buttons" % buttons.size())

	var collect: Button = _button_called(buttons, "Collect")
	check("a finished contract shows a Collect button", collect != null)
	if collect != null:
		var gold_before: int = r.wallet.balance(Wallet.Kind.GOLD)
		collect.pressed.emit()
		check("...pressing it pays the gold",
			r.wallet.balance(Wallet.Kind.GOLD) > gold_before,
			"+%d" % (r.wallet.balance(Wallet.Kind.GOLD) - gold_before))
		check("...tells the player what landed", notices.size() == 1,
			"" if notices.is_empty() else String(notices[0]))
		check("...and asks the shell to SAVE", int(saves[0]) >= 1,
			"%d" % int(saves[0]))

	# The Go button must launch the quest's own map at the quest's own tier.
	var r2 := _roster(Campaign.Tier.MERCILESS if Campaign.tier_count() > 1
		else 0, 40)
	r2.quest_board()
	var want := QuestS.new()
	want.kind = QuestS.Kind.FIND_SLOT
	want.region = 31
	want.tier = r2.unlocked_tier
	want.want = Item.Slot.FEET
	want.need = 1
	r2.quests[0] = want
	var s2: UiScreen = QuestScreenS.new()
	s2.roster = r2
	s2.hero = r2.owned_names()[0]
	var launched: Array = []
	s2.navigate.connect(func(route: String, arg: Variant) -> void:
		if route == UiRoute.LAUNCH:
			launched.append(arg))
	root.add_child(s2)
	await process_frame
	var go: Button = _button_called(_buttons(s2), "Go")
	check("an unfinished map contract offers a way IN", go != null)
	if go != null:
		go.pressed.emit()
		check("...which launches the contract's own map",
			launched.size() == 1
				and int((launched[0] as Dictionary).get("region", -1)) == 31,
			"%s" % launched)
		check("...on the contract's own difficulty, not the last one picked",
			launched.size() == 1
				and int((launched[0] as Dictionary).get("tier", -1))
					== want.tier)

	screen.queue_free()
	s2.queue_free()


func _buttons(node: Node) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is Button:
			out.append(c)
		out.append_array(_buttons(c))
	return out


func _button_called(buttons: Array, text: String) -> Button:
	for b in buttons:
		if (b as Button).text == text:
			return b
	return null


# ---- scaling -----------------------------------------------------------------

func _scaling() -> void:
	print("\n=== scaled to the roster ===")
	# "Scaled to overall hero levels" is the requirement; the reward and the
	# ask both have to move, or a level-50 player is sent to kill six elites
	# for 300 gold.
	var weak: QuestS = QuestS.offer(1, 1, 0, 40, 1)
	var strong: QuestS = QuestS.offer(1, 1, 0, 40, 60)
	check("the same offer pays more to a stronger roster",
		strong.reward_gold > weak.reward_gold * 3,
		"%d vs %d gold" % [weak.reward_gold, strong.reward_gold])

	var elites_weak: int = 0
	var elites_strong: int = 0
	for i in range(300):
		var a: QuestS = QuestS.offer(2, i, 0, 40, 1)
		var b: QuestS = QuestS.offer(2, i, 0, 40, 80)
		if a.kind == QuestS.Kind.SLAY_ELITES:
			elites_weak = maxi(elites_weak, a.need)
			elites_strong = maxi(elites_strong, b.need)
	check("...and asks a stronger roster for more",
		elites_strong > elites_weak,
		"%d vs %d elites" % [elites_weak, elites_strong])

	# AND IT HAS A CEILING, or a level-99 roster is offered 400 elites.
	# Checked over a SWEEP, not one offer: the first version of this drew a
	# CLEAR_MAP, whose need is 1, so the assertion passed without ever
	# looking at a counted objective.
	var biggest: int = 0
	var counted: int = 0
	for i in range(400):
		var o: QuestS = QuestS.offer(3, i, Campaign.tier_count() - 1, 90, 99)
		if o.need > 1:
			counted += 1
			biggest = maxi(biggest, o.need)
	check("the ask is bounded even for a maxed roster",
		counted > 0 and biggest <= 40,
		"largest of %d counted asks was %d" % [counted, biggest])

	# Harder difficulties pay more for the same words.
	var easy: QuestS = QuestS.offer(9, 9, 0, 40, 20)
	var hard: QuestS = QuestS.offer(9, 9, Campaign.tier_count() - 1, 40, 20)
	check("a harder difficulty pays more",
		hard.reward_gold > easy.reward_gold
			or hard.kind != easy.kind,
		"%d vs %d" % [easy.reward_gold, hard.reward_gold])

	# Crystals are premium: they must be rare, not on every row.
	var crystal_rows: int = 0
	for i in range(300):
		if QuestS.offer(4, i, Campaign.tier_count() - 1, 80, 40)\
				.reward_crystals > 0:
			crystal_rows += 1
	check("spawn crystals are a rare reward, not a standing one",
		crystal_rows > 0 and crystal_rows < 150,
		"%d of 300 offers" % crystal_rows)

	# power() is the BEST champion, not the average — the whole reason it is
	# not derived from the roster size.
	var r := _roster()
	var names: PackedStringArray = r.owned_names()
	r.progress(names[0]).level = 40
	check("roster power is the best champion, not the average",
		r.power() == 40, "%d" % r.power())


# ---- the save file is not a scratchpad ---------------------------------------

func _the_scratch_account() -> void:
	print("\n=== a scratch account cannot touch the real save ===")
	# THIS IS NOT A QUEST TEST, it lives here because quests added the fifth
	# _account.save() call site in Play and that is what finally made the hole
	# visible: a harness that loads Play.tscn with no account got a bare
	# Roster, played a region, saved, and left user://roster.json with zero
	# owned champions. The next real launch then showed an empty campaign and
	# refused to start anything, which looks nothing like "a file was
	# overwritten".
	var scratch := Roster.new()
	scratch.ephemeral = true
	check("an ephemeral roster reports a successful save", scratch.save())

	# And actually check the disk, because "returns true" is exactly what a
	# broken version would also do.
	var real := Roster.create(HeroRig.animated_heroes(), 1234)
	check("a real roster writes", real.save() and FileAccess.file_exists(
		Roster.SAVE_PATH))
	var owned_before: int = real.owned.size()
	scratch.save()
	var back := Roster.load_or_create(HeroRig.animated_heroes())
	check("...and the scratch save did not replace it",
		back.owned.size() == owned_before and owned_before > 0,
		"%d owned, was %d" % [back.owned.size(), owned_before])

	# The one Play actually hands out must carry the flag, or the fix is a
	# flag nobody sets.
	var play: Node = load("res://scenes/Play.tscn").instantiate()
	var got = play.call("_resolve_roster")
	check("the account Play invents for itself is ephemeral",
		got is Roster and (got as Roster).ephemeral)
	play.queue_free()
