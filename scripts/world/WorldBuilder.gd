class_name WorldBuilder
extends Node
# ------------------------------------------------------------------------------
# Builds a region on a background thread and hands the finished nodes back to the
# main thread.
#
# This does NOT make generation faster — it takes the same ~4 s of CPU it always
# did. What it does is stop that 4 s from being 240 dropped frames. The player
# sees a loading transition that animates, not a frozen app that iOS may decide
# is hung.
#
# ONE thread, deliberately. Splitting the work across the worker pool was tried
# and measured: 0.74x at four threads, 0.57x at eight, with byte-identical
# output. GDScript's copy-on-write PackedArrays put an atomic refcount in the
# path of every element access, so several threads sharing a heightfield lose to
# one thread that owns it. Full numbers in docs/THREADING.md.
#
# GODOT 4 THREAD RULES OBSERVED HERE:
#   * Resources (ArrayMesh, MultiMesh, ShaderMaterial) may be CREATED off-thread.
#   * Nodes may be CONSTRUCTED off-thread but must enter the scene tree on the
#     main thread — hence `call_deferred`. Adding from a worker is the classic
#     source of intermittent, unreproducible crashes.
#   * The thread must be joined, or quitting mid-build leaves it detached.
# ------------------------------------------------------------------------------

## Emitted on the MAIN thread once the region is built and parented.
signal finished(root: Node3D, terrain: Terrain, plan: Layout)

## Emitted on the main thread as the build moves between stages, for a progress bar.
signal progress(stage: String, fraction: float)

const STAGES: PackedStringArray = [
	"Surveying the ground", "Raising the land", "Cutting the paths",
	"Sowing the wild", "Shaping the world", "Carving the stone",
]

var _thread: Thread = null
var _busy: bool = false
var _req: Dictionary = {}


func is_busy() -> bool:
	return _busy


# Kick off a build. Returns false if one is already running — regions are built
# one at a time on purpose, since a second thread would contend for exactly the
# shared arrays that made the parallel attempt slower.
func build(world_seed: int, biome_id: String, cells: int = 384,
		cell_size: float = 0.5, symmetry: int = Layout.Sym.ASYMMETRIC,
		node_count: int = 11, kind: int = Terrain.Kind.ARENA,
		form_id: String = "") -> bool:
	if _busy:
		return false
	_busy = true
	# `kind` picks the layout GENERATOR — Kind.ARENA for Layout's graph (and its
	# rotational PvP mode), Kind.LANE for the campaign's spine. It is last and
	# defaults to ARENA so existing callers keep the map they already build.
	# `symmetry` and `node_count` are ARENA's parameters; a lane takes neither,
	# which is why Terrain.plan_for() — not this function — owns the mapping.
	_req = {
		"seed": world_seed, "biome": biome_id, "cells": cells,
		"cell": cell_size, "sym": symmetry, "nodes": node_count,
		"kind": kind, "form": form_id,
	}
	_thread = Thread.new()
	_thread.start(_run)
	return true


# ------------------------------------------------------------------------------
# Background thread
# ------------------------------------------------------------------------------

func _run() -> void:
	var world_seed: int = int(_req["seed"])
	var biome_id: String = String(_req["biome"])
	var cells: int = int(_req["cells"])
	var cell_size: float = float(_req["cell"])
	var extent: float = float(cells) * cell_size

	_stage(0)
	var plan: Layout = Terrain.plan_for(int(_req.get("kind", Terrain.Kind.ARENA)),
		world_seed, Vector2(extent, extent), int(_req["sym"]),
		int(_req["nodes"]))

	_stage(1)
	var ter := Terrain.generate(world_seed, biome_id, cells, cell_size, plan)

	_stage(2)
	# The map's FORM reaches the scatter here, which is what makes a warren
	# cluttered and a hollow bare rather than the same field at two sizes.
	var scat := Scatter.generate(ter, plan, world_seed,
		String(_req.get("form", "")))
	scat.apply_blocking(ter)

	_stage(3)
	# Everything below constructs nodes WITHOUT parenting them. They are inert
	# until the main thread adopts them.
	var root := Node3D.new()
	root.name = "Region_" + biome_id

	_stage(4)
	var gmat: ShaderMaterial = Mesher.ground_material()
	for chunk in Mesher.build_chunks(ter, 1):
		var mi := MeshInstance3D.new()
		mi.mesh = chunk
		mi.material_override = gmat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		root.add_child(mi)

	var wm: ArrayMesh = Mesher.build_water(ter)
	if wm != null:
		var wi := MeshInstance3D.new()
		wi.mesh = wm
		wi.material_override = Mesher.water_material(biome_id)
		root.add_child(wi)

	_stage(5)
	var pmat: ShaderMaterial = Props.material()
	_emit_props(root, scat.buckets(), biome_id, pmat, true)
	_emit_props(root, scat.cover_buckets(), biome_id, pmat, false)

	# Hand over. `call_deferred` marshals this onto the main thread, which is
	# the only place a node may be added to the tree.
	_deliver.call_deferred(root, ter, plan)


func _emit_props(root: Node3D, buckets: Dictionary, biome_id: String,
		mat: ShaderMaterial, shadows: bool) -> void:
	for key in buckets.keys():
		var group: Array = buckets[key]
		var parts: PackedStringArray = String(key).split("#")
		var mesh: ArrayMesh = Props.build(parts[0], biome_id, int(parts[1]))
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = mesh
		mm.instance_count = group.size()
		for i in range(group.size()):
			var it: Dictionary = group[i]
			var tr := Transform3D()
			tr = tr.scaled(Vector3.ONE * float(it["scale"]))
			tr = tr.rotated(Vector3.UP, float(it["yaw"]))
			tr.origin = it["pos"]
			mm.set_instance_transform(i, tr)
			var pos: Vector3 = it["pos"]
			var hx: int = int(pos.x * 7.0)
			var hz: int = int(pos.z * 7.0)
			var v: float = Rng.unit2(991, hx, hz)
			var w: float = Rng.unit2(4441, hx, hz)
			mm.set_instance_custom_data(i, Color(
				0.86 + v * 0.26, 0.88 + w * 0.22, 0.84 + (1.0 - v) * 0.24, 1.0))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON \
			if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)


func _stage(i: int) -> void:
	_emit_progress.call_deferred(STAGES[i], float(i) / float(STAGES.size()))


# ------------------------------------------------------------------------------
# Main thread
# ------------------------------------------------------------------------------

func _emit_progress(stage: String, fraction: float) -> void:
	progress.emit(stage, fraction)


func _deliver(root: Node3D, ter: Terrain, plan: Layout) -> void:
	# Join before signalling: the thread is finished with its work by the time
	# this deferred call runs, so this returns immediately, but it releases the
	# handle properly rather than leaving it dangling.
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_busy = false
	progress.emit("Ready", 1.0)
	finished.emit(root, ter, plan)


func _exit_tree() -> void:
	# Without this, quitting mid-build leaves a detached thread and Godot
	# complains loudly (or crashes) on shutdown.
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
