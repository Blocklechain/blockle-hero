extends SceneTree
# Does an ARENA region actually build and populate at a REALISTIC size?
#
# MapShape wants to give some campaign maps the arena form. Before shipping
# that I need to know whether the arena path works end to end at the sizes a
# real map uses, or only ever worked in the tools that use it. Guessing from
# "the fallback function looks complete" is how a hundred empty maps ship.

const WorldBuilderS := preload("res://scripts/world/WorldBuilder.gd")

func _init() -> void:
	_run()


func _run() -> void:
	for probe in [
		{"kind": Terrain.Kind.LANE, "cells": 384, "nodes": 11, "tag": "lane 384"},
		{"kind": Terrain.Kind.ARENA, "cells": 304, "nodes": 16, "tag": "arena 304 warren"},
		{"kind": Terrain.Kind.ARENA, "cells": 352, "nodes": 7, "tag": "arena 352 hollow"},
		{"kind": Terrain.Kind.ARENA, "cells": 448, "nodes": 9, "tag": "arena 448 colosseum"},
		{"kind": Terrain.Kind.ARENA, "cells": 96, "nodes": 16, "tag": "arena 96 (harness size)"},
	]:
		await _probe(probe)
	quit(0)


func _probe(p: Dictionary) -> void:
	var b := WorldBuilderS.new()
	root.add_child(b)
	var done := [false]
	var got := [null, null]
	b.finished.connect(func(_r, t, plan):
		got[0] = t
		got[1] = plan
		done[0] = true)
	var ok: bool = b.build(1234, "greenwood", int(p["cells"]), 0.5,
		Layout.Sym.ASYMMETRIC, int(p["nodes"]), int(p["kind"]))
	if not ok:
		print("%-28s BUILD REFUSED" % p["tag"])
		b.queue_free()
		return

	var frames := 0
	while not done[0] and frames < 4000:
		await process_frame
		frames += 1

	if not done[0]:
		print("%-28s NEVER FINISHED (%d frames)" % [p["tag"], frames])
		b.queue_free()
		return

	var terrain = got[0]
	var plan = got[1]
	var pathing := Pathing.new(terrain)
	# is_walkable() takes WORLD metres, so sample the region in metres.
	var walk: int = 0
	var sampled: int = 0
	var span: float = float(terrain.size) * terrain.cell
	var half: float = span * 0.5
	var stride: float = span / 64.0
	var wy: float = -half
	while wy < half:
		var wx: float = -half
		while wx < half:
			sampled += 1
			if pathing.is_walkable(Vector2(wx, wy)):
				walk += 1
			wx += stride
		wy += stride

	# Where the player would start, as Play does it.
	var start: Vector2 = Vector2.ZERO
	if plan is Lane:
		start = pathing.nearest_walkable_centre((plan as Lane).position_at(0.0))
	elif plan != null:
		for n in plan.nodes:
			if String(n.get("kind", "")) == Layout.ENTRY:
				start = pathing.nearest_walkable_centre(
					Vector2(n["pos"].x, n["pos"].y))
				break

	var spawns: Array = Encounter.build(7, 0, 99,
		HeroRig.animated_heroes(), "", pathing, start, plan)
	var bosses: int = 0
	for s in spawns:
		if s.is_boss:
			bosses += 1

	print("%-28s walkable %4.1f%%  nodes %2d  spawns %2d (boss %d)  start %s"
		% [p["tag"], 100.0 * float(walk) / maxf(float(sampled), 1.0),
			(plan.nodes.size() if plan != null else 0),
			spawns.size(), bosses, str(start.round())])
	b.queue_free()
