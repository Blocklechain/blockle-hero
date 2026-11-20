shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

// ------------------------------------------------------------------------------
// Props: trees, rocks, crystals, ruins.
//
// Same division of labour as the terrain — the mesh carries silhouette, the
// shader carries surface. A low-poly rock with per-pixel grain and a little
// relief reads as stone; the same rock flat-shaded reads as a grey polyhedron,
// which is exactly how the props looked beside the detailed ground.
//
// VERTEX COLOUR ALPHA IS EMISSION, not opacity. It lets one mesh mix dull and
// glowing material — a lava rock with a hot seam, a brazier with a lit bowl, a
// crystal that glows at the tip — without a second material or a second draw
// call, which matters because every prop type is drawn as a MultiMesh.
// ------------------------------------------------------------------------------

uniform sampler2D grain : filter_linear_mipmap, repeat_enable;
uniform sampler2D relief : filter_linear_mipmap, repeat_enable;

uniform float grain_scale = 1.6;
uniform float relief_scale = 1.1;
uniform float grain_strength = 0.20;
uniform float bump = 0.45;
uniform float emission_energy = 2.6;

varying vec3 wpos;
varying vec3 wnrm;
varying float emit;
varying vec3 tint;


void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	emit = COLOR.a;
	// Per-instance tint from the MultiMesh custom-data channel. Instance COLOR
	// would have been the obvious place, but Godot multiplies that straight
	// into vertex COLOR — including the alpha, which here means emission — so a
	// tint would silently relight every glowing prop. Custom data leaves COLOR
	// untouched.
	tint = INSTANCE_CUSTOM.rgb;
}


float tri(sampler2D t, vec3 p, vec3 w, float s) {
	return texture(t, p.xz * s).r * w.y
		 + texture(t, p.zy * s).r * w.x
		 + texture(t, p.xy * s).r * w.z;
}


void fragment() {
	vec3 w = pow(abs(wnrm), vec3(4.0));
	w /= (w.x + w.y + w.z);

	// World-space projection, so neighbouring instances of the same mesh get
	// different grain instead of every tree wearing an identical texture.
	float g = tri(grain, wpos, w, grain_scale);

	vec3 base = COLOR.rgb * tint;
	base *= mix(1.0 - grain_strength, 1.0 + grain_strength, g);

	ALBEDO = base;
	ROUGHNESS = 0.95;

	// Relief, projected on whichever plane faces the surface most. Props have
	// steep sides far more often than the ground does, so unlike the terrain
	// shader this one is worth sampling triplanar.
	float r1 = tri(relief, wpos, w, relief_scale);
	float r2 = tri(relief, wpos, w, relief_scale * 2.7);
	float h = (r1 - 0.5) * 0.7 + (r2 - 0.5) * 0.3;

	// Perturb across the surface rather than along its normal.
	vec3 tangent = normalize(cross(wnrm, vec3(0.0, 1.0, 0.001)));
	vec3 bitan = normalize(cross(wnrm, tangent));
	vec3 pn = normalize(wnrm + (tangent + bitan) * h * bump);
	NORMAL = normalize((VIEW_MATRIX * vec4(pn, 0.0)).xyz);

	EMISSION = base * emit * emission_energy;
}
