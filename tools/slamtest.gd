extends SceneTree
# ------------------------------------------------------------------------------
# THE BOSS SLAM MUST BE PHYSICALLY DODGEABLE.
#
# It shipped not being. The window was a hand-picked 1.15s, and because the
# slam is aimed at where the champion is STANDING, the player always starts at
# dead centre — so the worst case is the only case. Clearing a 6.5m radius at
# 6.2 m/s takes 1.05s of pure running, which left 0.1s to notice the ground
# light up and push a virtual joystick. The mechanic was unwinnable, and an
# unwinnable telegraph does not read as "I misplayed", it reads as "this boss
# just hits hard" — the lesson never lands.
#
# A number nobody can verify by eye is exactly the thing to put under a test.
# This one does the arithmetic the designer would have to do by hand, at every
# tier, so the radius, the run speed and the window can never drift back into
# impossibility without something going red.
# ------------------------------------------------------------------------------

# Play.gd is a scene script with no class_name, so it is preloaded rather than
# referenced globally — the constants and the pure slam_warn() are still
# reachable, which is the point of having made it static.
const Play := preload("res://scripts/game/Play.gd")

func _init() -> void:
	var fails: int = 0

	var radius: float = Play.SLAM_RADIUS
	var speed: float = HeroController.RUN_SPEED
	var travel: float = radius / speed

	print("slam radius %.2fm, run speed %.2f m/s -> %.3fs to clear"
		% [radius, speed, travel])

	# ---- every tier must leave real time to react AND to run ----------------
	for tier in range(Campaign.tier_count()):
		var warn: float = Play.slam_warn(tier)
		var spare: float = warn - travel
		print("  tier %d  warn %.3fs  spare after running %.3fs"
			% [tier, warn, spare])

		if warn <= travel:
			push_error("tier %d: warn %.3fs <= %.3fs needed just to run out "
				% [tier, warn, travel] + "— the slam cannot be dodged at all")
			fails += 1
			continue

		# Running out the instant it appears is not a mechanic either. The
		# player has to SEE it, decide, and move a thumb.
		if spare < 0.30:
			push_error("tier %d: only %.3fs to notice and react — a human on "
				% [tier, spare] + "glass needs about a third of a second")
			fails += 1

		# And it must not be so generous that it stops being a threat.
		if warn > 3.0:
			push_error("tier %d: %.2fs is long enough to walk away bored"
				% [tier, warn])
			fails += 1

	# ---- harder tiers are tighter, but never impossible ---------------------
	var easiest: float = Play.slam_warn(0)
	var hardest: float = Play.slam_warn(Campaign.tier_count() - 1)
	if hardest >= easiest:
		push_error("the hardest tier (%.3fs) gives no less warning than the "
			% hardest + "easiest (%.3fs) — difficulty does nothing here"
			% easiest)
		fails += 1
	if hardest <= travel:
		push_error("the hardest tier is undodgeable: %.3fs vs %.3fs"
			% [hardest, travel])
		fails += 1

	# ---- the OLD value must still be recognised as broken -------------------
	# Guards the test itself: if this arithmetic ever says 1.15s was fine,
	# the test has stopped measuring anything.
	if 1.15 > travel + 0.30:
		push_error("the pre-fix 1.15s window now reads as survivable — this "
			+ "test is no longer checking what it was written to check")
		fails += 1

	# ---- a slam must still be capped so it cannot one-shot ------------------
	if Play.SLAM_MAX_FRACTION >= 1.0:
		push_error("an unavoidable-looking hit that can kill from full teaches "
			+ "nothing")
		fails += 1

	if fails > 0:
		push_error("slamtest: %d failure(s)" % fails)
		quit(1)
		return
	print("slamtest OK")
	quit(0)
