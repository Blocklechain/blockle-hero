extends SceneTree
# Where does the hero's body actually sit relative to the HeroRig origin, and
# does any clip move the root? The controller puts the HeroRig origin ON the
# terrain surface every frame, so feet must land at local y == 0.
#
# Measured by skinning the mesh by hand: for every vertex take the bone weights
# out of the glb, build the pose matrix at a given animation time, and transform
# the vertex. That is the only way to know where the visible silhouette is --
# MeshInstance3D.get_aabb() on a skinned mesh returns the BIND-POSE mesh AABB,
# which is also exactly what HeroRig._normalise_scale() uses.

const HEROES := ["aldous", "brom", "g001", "g070", "g169", "kaelen", "willow"]


func _init() -> void:
	for hero in HEROES:
		_one(hero)
	quit()


func _one(hero: String) -> void:
	var rig := HeroRig.new()
	root.add_child(rig)
	if not rig.load_hero(hero):
		print(hero, ": LOAD FAILED")
		return
	var model: Node3D = rig._model
	var ap: AnimationPlayer = rig._anim
	var mis: Array = model.find_children("*", "MeshInstance3D", true, false)
	var mi: MeshInstance3D = mis[0]
	var sk: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]

	print("== %s  rigged=%s  model.scale=%.4f  clips=%d" % [
		hero, str(rig.is_rigged), model.scale.y, ap.get_animation_list().size()])
	print("   bind-pose mesh aabb (what normalise uses): pos=%s size=%s" % [
		str(mi.get_aabb().position), str(mi.get_aabb().size)])
	print("   mesh global xform origin=%s  skeleton global origin=%s" % [
		str(mi.global_transform.origin), str(sk.global_transform.origin)])

	# Pull the skinning data off the mesh once.
	var arrays: Array = (mi.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var per: int = 0
	if verts.size() > 0 and bones.size() > 0:
		per = bones.size() / verts.size()
	if per == 0:
		print("   !! no skin weights on surface 0")
		rig.queue_free()
		return

	var skin_ref: SkinReference = mi.get_skin_reference()
	var skin: Skin = mi.skin
	# Skeleton bone index for each skin bind.
	var bind_to_bone: PackedInt32Array = PackedInt32Array()
	for b in range(skin.get_bind_count()):
		var nm: String = skin.get_bind_name(b)
		var idx: int = skin.get_bind_bone(b)
		if nm != "":
			idx = sk.find_bone(nm)
		bind_to_bone.append(idx)

	for clip in ap.get_animation_list():
		var a: Animation = ap.get_animation(clip)
		var ymin := INF
		var ymax := -INF
		var feet_y: Array = []
		var hip_pos: Array = []
		for step in range(9):
			var t: float = a.length * (float(step) / 8.0)
			ap.play(clip)
			ap.seek(t, true, true)
			# Pose is applied on seek with update=true in 4.x for the skeleton.
			var box: AABB = _skinned_aabb(model, sk, mi, skin, bind_to_bone,
				verts, bones, weights, per)
			feet_y.append(box.position.y)
			ymin = minf(ymin, box.position.y)
			ymax = maxf(ymax, box.position.y + box.size.y)
			hip_pos.append(_root_origin(model, sk))
		var tx := _spread(hip_pos, 0)
		var tz := _spread(hip_pos, 2)
		print("   %-11s len=%.2fs  body y=[%+.3f .. %+.3f] height=%.2fm  lowest-foot=%+.3f  root travel x=%.3f z=%.3f" % [
			clip, a.length, ymin, ymax, ymax - ymin, ymin, tx, tz])
	rig.queue_free()


func _spread(pts: Array, axis: int) -> float:
	var lo := INF
	var hi := -INF
	for p in pts:
		var v: float = (p as Vector3)[axis]
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return hi - lo


func _root_origin(model: Node3D, sk: Skeleton3D) -> Vector3:
	var b: int = 0
	for i in range(sk.get_bone_count()):
		if sk.get_bone_parent(i) == -1:
			b = i
			break
	# In the HeroRig's own local space (so the controller's own motion is out).
	return model.transform * (sk.transform * sk.get_bone_global_pose(b).origin)


func _skinned_aabb(model: Node3D, sk: Skeleton3D, mi: MeshInstance3D, skin: Skin,
		bind_to_bone: PackedInt32Array, verts: PackedVector3Array,
		bones: PackedInt32Array, weights: PackedFloat32Array, per: int) -> AABB:
	# Pose matrix per bind: skeleton_global_pose * bind_pose(inverse rest).
	var mats: Array[Transform3D] = []
	for b in range(skin.get_bind_count()):
		var bone: int = bind_to_bone[b]
		var gp: Transform3D = sk.get_bone_global_pose(bone) if bone >= 0 else Transform3D()
		mats.append(gp * skin.get_bind_pose(b))

	# Vertices are in mesh space; the skeleton pose is in skeleton space. The glb
	# parents the mesh to the skeleton, so mesh-local == skeleton-local here.
	var to_rig: Transform3D = model.transform * sk.transform
	var out := AABB()
	var first := true
	var n: int = verts.size()
	var stride: int = maxi(1, n / 4000)   # sample; 4k verts is plenty for a bbox
	var i: int = 0
	while i < n:
		var acc := Vector3.ZERO
		var wsum: float = 0.0
		for k in range(per):
			var w: float = weights[i * per + k]
			if w <= 0.0:
				continue
			var bi: int = bones[i * per + k]
			if bi < 0 or bi >= mats.size():
				continue
			acc += (mats[bi] * verts[i]) * w
			wsum += w
		if wsum > 0.0:
			var p: Vector3 = to_rig * (acc / wsum)
			if first:
				out = AABB(p, Vector3.ZERO)
				first = false
			else:
				out = out.expand(p)
		i += stride
	return out
