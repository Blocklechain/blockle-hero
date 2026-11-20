class_name Mesher
extends RefCounted
# ------------------------------------------------------------------------------
# Heightfield -> chunked ArrayMesh.
#
# Work is split by scale. The MESH carries landform in its vertices and the
# biome palette plus baked ambient occlusion in its vertex colours; everything
# below about a metre is produced per-pixel by terrain.gdshader from noise
# generated at load time. Nothing is authored, so no image assets ship.
#
# That split is what buys apparent resolution cheaply: geometry density is
# bounded by what a phone can push, while shader detail is bounded only by the
# screen. It also keeps the art honest — every colour still descends from the
# biome table, so a region cannot drift away from its own palette.
#
# The material is LIT, not unshaded. An unshaded surface cannot receive a
# shadow, and without shadows under the props the world reads as pressed flat.
# ------------------------------------------------------------------------------


# How many cells across one chunk. The whole region as a single mesh cannot be
# culled or streamed: at 0.5 m cells that is 147k vertices drawn in full even
# when nine tenths of it sits behind the camera. 48 cells gives chunks big
# enough that the draw-call count stays trivial and small enough that frustum
# culling actually discards most of them.
const CHUNK: int = 48


# Build the ground as a grid of chunk meshes. Returns an array of ArrayMesh in
# row-major order; the caller parents each to its own MeshInstance3D so Godot
# can cull them independently.
#
# `step` decimates within a chunk: 1 is full resolution, 2 every other cell.
# Distant chunks can be rebuilt at a higher step for LOD.
static func build_chunks(t: Terrain, step: int = 1) -> Array:
	step = maxi(step, 1)
	var out: Array = []
	var chunks: int = int(ceil(float(t.size - 1) / float(CHUNK)))
	for cy in range(chunks):
		for cx in range(chunks):
			var m: ArrayMesh = _chunk(t, cx * CHUNK, cy * CHUNK, step)
			if m != null:
				out.append(m)
	return out


static func _chunk(t: Terrain, ox: int, oy: int, step: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var norms := PackedVector3Array()
	var idxs := PackedInt32Array()

	# +1 so neighbouring chunks share an edge row and leave no seam.
	var span: int = CHUNK / step + 1
	var wrote: int = 0
	var half: float = float(t.size) * t.cell * 0.5

	for gy in range(span):
		for gx in range(span):
			var x: int = mini(ox + gx * step, t.size - 1)
			var y: int = mini(oy + gy * step, t.size - 1)
			# Colour and normal are read from Terrain, baked once per cell by
			# Shade.bake(). Computing them here per vertex meant two Biome
			# dictionary lookups and a pile of Color temporaries for each of
			# 153k vertices — a third of all generation time.
			var i: int = y * t.size + x
			verts.append(Vector3(float(x) * t.cell - half,
				t.h[i], float(y) * t.cell - half))
			norms.append(t.vnrm[i])
			cols.append(t.vcol[i])
			wrote += 1

	if wrote == 0:
		return null

	for gy in range(span - 1):
		for gx in range(span - 1):
			var a: int = gy * span + gx
			var b: int = a + 1
			var cc: int = a + span
			var d: int = cc + 1
			idxs.append_array([a, cc, b, b, cc, d])

	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idxs

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


# ------------------------------------------------------------------------------
# Detail noise, generated at load time. No image assets ship with the game.
# ------------------------------------------------------------------------------

static func _noise_tex(seed: int, freq: float, octaves: int, size: int,
		as_normal: bool, bump: float = 1.0) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.seed = seed
	n.frequency = freq
	n.fractal_octaves = octaves

	var tex := NoiseTexture2D.new()
	tex.noise = n
	tex.width = size
	tex.height = size
	# Seamless, or every tile boundary shows as a visible grid line across the
	# ground — which at this tiling rate would be about every metre.
	tex.seamless = true
	tex.as_normal_map = as_normal
	tex.bump_strength = bump
	tex.generate_mipmaps = true
	return tex


static func ground_material() -> ShaderMaterial:
	var sh: Shader = load("res://scripts/world/terrain.gdshader")
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("grain", _noise_tex(1101, 0.021, 4, 512, false))
	m.set_shader_parameter("mottle", _noise_tex(2203, 0.008, 3, 256, false))
	m.set_shader_parameter("relief", _noise_tex(3307, 0.016, 4, 512, true, 2.4))
	return m


# ------------------------------------------------------------------------------
# Water
# ------------------------------------------------------------------------------

# Water is built as a GRID that exists only where the terrain is actually
# submerged, with the depth under each vertex baked into its vertex colour.
#
# The first version was a single quad across the whole region plus a shader that
# read DEPTH_TEXTURE. That was wrong twice over: the Forward Mobile renderer has
# no reliable depth texture to sample (there is no depth prepass to read), and a
# full-region quad puts a water plane over dry land and relies on transparency
# to hide it. Baking the depth is cheaper, exact, and works on any renderer —
# and we already know the terrain height, so reading it back off the GPU was
# always a roundabout way to learn something we had in hand.
static func build_water(t: Terrain) -> ArrayMesh:
	if t.water_h <= -99999.0:
		return null

	const STEP: int = 2          # water needs less resolution than ground
	# Carry the mesh a little way up the bank so the foam band has somewhere to
	# sit; without it the shoreline is clipped off at exactly zero depth.
	const BANK: float = 0.6

	var n: int = (t.size - 1) / STEP + 1
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var norms := PackedVector3Array()
	var submerged := PackedByteArray()
	submerged.resize(n * n)

	for gy in range(n):
		for gx in range(n):
			var x: int = mini(gx * STEP, t.size - 1)
			var y: int = mini(gy * STEP, t.size - 1)
			var p: Vector2 = t.pos_of(x, y)
			var depth: float = t.water_h - t.h[t.idx(x, y)]
			verts.append(Vector3(p.x, t.water_h, p.y))
			norms.append(Vector3.UP)
			# RED CHANNEL IS DEPTH IN METRES, scaled into 0..1 over 6 m. Not a
			# colour — the water shader reads it as geometry data.
			cols.append(Color(clampf(depth / 6.0, 0.0, 1.0), 0.0, 0.0, 1.0))
			submerged[gy * n + gx] = 1 if depth > -BANK else 0

	var idxs := PackedInt32Array()
	for gy in range(n - 1):
		for gx in range(n - 1):
			var a: int = gy * n + gx
			var b: int = a + 1
			var c: int = a + n
			var d: int = c + 1
			# Emit the quad if any corner is under water, so the mesh stops at
			# the bank instead of tiling across the whole region.
			if submerged[a] + submerged[b] + submerged[c] + submerged[d] == 0:
				continue
			idxs.append_array([a, c, b, b, c, d])

	if idxs.is_empty():
		return null

	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func water_material(biome_id: String) -> Material:
	var b: Dictionary = Biome.get_biome(biome_id)

	# Molten runs its "water" as lava: opaque, emissive, and it must NOT get the
	# depth-shaded shoreline foam treatment, which would put white surf on a
	# lava lake.
	# base_id, not the raw id: a campaign biome arrives dread-tagged
	# ("molten~72"), and an == against the bare name would silently hand a lava
	# lake the depth-shaded shoreline foam shader.
	if Biome.base_id(biome_id) == "molten":
		var lava := StandardMaterial3D.new()
		lava.albedo_color = b["water"]
		lava.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		lava.emission_enabled = true
		lava.emission = b["water"]
		lava.emission_energy_multiplier = 2.4
		lava.roughness = 0.6
		return lava

	var m := ShaderMaterial.new()
	m.shader = load("res://scripts/world/water.gdshader")
	m.set_shader_parameter("wave", _noise_tex(5501, 0.030, 3, 512, true, 1.6))
	var sh: Color = b["water"]
	var dp: Color = b["water_deep"]
	m.set_shader_parameter("shallow_colour", Vector3(sh.r, sh.g, sh.b))
	m.set_shader_parameter("deep_colour", Vector3(dp.r, dp.g, dp.b))
	# Foam picks up the biome's sky so a cold sea does not foam warm white.
	var fo: Color = (b["sky_horizon"] as Color).lerp(Color.WHITE, 0.55)
	m.set_shader_parameter("foam_colour", Vector3(fo.r, fo.g, fo.b))
	return m


# ------------------------------------------------------------------------------
# Environment — sky, fog and the key light, all read from the biome table
# ------------------------------------------------------------------------------

static func build_environment(biome_id: String) -> Environment:
	var b: Dictionary = Biome.get_biome(biome_id)
	var env := Environment.new()

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = b["sky_top"]
	sky_mat.sky_horizon_color = b["sky_horizon"]
	sky_mat.ground_bottom_color = b["fog"]
	sky_mat.ground_horizon_color = b["sky_horizon"]
	sky_mat.sun_angle_max = 30.0

	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky

	# Ambient comes from the sky but at reduced energy — the terrain's own
	# vertex colour is already carrying the ambient term, so letting the sky
	# light it again would wash the whole scene out.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	# Ambient carries the shadowed side, but only just. At 0.70 it overwhelmed
	# the key light and every shadow washed out to nothing — the scene read as
	# uniformly flat and dark. A strong key against a modest fill is what gives
	# the ground form.
	#
	#
	# AND IT IS NOT WHERE DREAD DARKENS THE FILL, because it cannot be: with
	# ambient_light_sky_contribution at 1.0 this energy does nothing. Measured —
	# the same frame rendered at 0.42 and at 2.10 came out identical to within
	# 1%. The fill in this renderer IS the sky colour, which Biome's dread shift
	# darkens directly; see the LUM_SKY_* note there. Multiplying here as well
	# would be a second, invisible, uncontrolled darkening.
	env.ambient_light_energy = 0.42

	env.fog_enabled = true
	env.fog_light_color = b["fog"]
	# A QUARTER of the biome's fog density. Shade.gd already bakes aerial haze
	# into the terrain's vertex colour, so applying the full value again here
	# fogged the scene twice and washed the whole world to a flat pastel.
	env.fog_density = float(b["fog_density"]) * 0.25
	env.fog_sky_affect = 0.25

	# LINEAR, not ACES. Shade.gd produces final display-referred colour, so a
	# filmic tonemapper re-grades an already-finished image — it was crushing
	# the midtones and turning grass into mud.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR

	# A gentle global grade. Small numbers on purpose — the palette is already
	# art-directed per biome, so this is a final polish that ties the frame
	# together, not a correction. Anything stronger starts fighting the biome
	# table and the two disagree.
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.02
	env.adjustment_contrast = 1.09
	env.adjustment_saturation = 1.12 * float(b.get("sat_grade", 1.0))

	# Glow, so the emissive props (crystal tips, lava seams, brazier fire) bleed
	# light instead of being merely bright pixels. Threshold sits above 1.0 so
	# only genuinely over-bright surfaces bloom and the ordinary terrain does
	# not turn hazy.
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.12
	env.glow_hdr_threshold = 1.05
	env.glow_hdr_scale = 2.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	return env


static func build_sun(biome_id: String) -> DirectionalLight3D:
	var b: Dictionary = Biome.get_biome(biome_id)
	var sun := DirectionalLight3D.new()
	sun.light_color = b["sun"]
	sun.light_energy = 1.75 * float(b.get("key_mult", 1.0))
	# Orientation set as an explicit basis, NOT via look_at_from_position().
	# look_at operates on the global transform and silently does nothing unless
	# the node is already inside the scene tree — and this light is oriented
	# before it is parented, so the sun was pointing wherever it liked and the
	# scene was lit by ambient alone.
	#
	# A DirectionalLight3D emits along its local -Z, so -Z must point the way
	# the light travels: away from the sun, i.e. -SUN_DIR.
	sun.transform = Transform3D(
		Basis.looking_at(-Shade.SUN_DIR.normalized(), Vector3.UP), Vector3.ZERO)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = \
		DirectionalLight3D.SHADOW_ORTHOGONAL      # cheapest; fine for a fixed camera
	sun.shadow_bias = 0.03
	sun.directional_shadow_max_distance = 110.0
	# Softens the terminator so low-poly foliage does not shadow in hard slabs.
	sun.light_angular_distance = 0.6
	return sun
