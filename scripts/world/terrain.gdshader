shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

// ------------------------------------------------------------------------------
// Terrain surface.
//
// The mesh supplies the LARGE scale — landform in the vertices, palette and baked
// ambient occlusion in the vertex colour. Everything below roughly one metre is
// produced here, per pixel, and that division is the whole trick: geometry
// resolution is expensive and bounded by what a phone can push, while shader
// detail is nearly free and bounded only by screen resolution. Perceived
// sharpness comes from the second one.
//
// It is also what made generation fast enough to be usable. Computing fine
// mottle per-vertex meant four fbm evaluations for every one of 147k vertices
// (~11 s a region). Those octaves now live in a texture lookup instead.
//
// COLOR.rgb = albedo x baked AO.  COLOR.a  = rockiness, 0 soft ground .. 1 stone.
// ------------------------------------------------------------------------------

// Grain: the fine, close-up break-up of the surface.
uniform sampler2D grain : filter_linear_mipmap, repeat_enable;
// Mottle: broad patchiness, so the ground varies across tens of metres.
uniform sampler2D mottle : filter_linear_mipmap, repeat_enable;
// Surface relief as a normal map, which is what actually reads as "detailed".
uniform sampler2D relief : filter_linear_mipmap, repeat_enable;

uniform float grain_scale = 1.10;    // cycles per metre
uniform float mottle_scale = 0.045;
uniform float relief_scale = 0.60;
uniform float relief_scale_far = 0.11;
uniform float grain_strength = 0.26;
uniform float mottle_strength = 0.16;
uniform float bump = 0.85;

varying vec3 wpos;
varying vec3 wnrm;
varying float rocky;


void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	rocky = COLOR.a;
}


// Triplanar sample. Needed for albedo because cliff faces are near-vertical and
// a flat XZ projection smears into vertical streaks on them.
float tri(sampler2D t, vec3 p, vec3 w, float s) {
	return texture(t, p.xz * s).r * w.y
		 + texture(t, p.zy * s).r * w.x
		 + texture(t, p.xy * s).r * w.z;
}


void fragment() {
	// Blend weights, sharpened so the transition between projections is tight
	// rather than a wide mushy band.
	vec3 w = pow(abs(wnrm), vec3(6.0));
	w /= (w.x + w.y + w.z);

	float g = tri(grain, wpos, w, grain_scale);
	float m = tri(mottle, wpos, w, mottle_scale);

	vec3 base = COLOR.rgb;
	// Rock takes grain harder than soft ground — stone is a higher-contrast
	// material than grass, and matching that sells the difference.
	float gs = grain_strength * mix(0.75, 1.5, rocky);
	base *= mix(1.0 - gs, 1.0 + gs, g);
	base *= mix(1.0 - mottle_strength, 1.0 + mottle_strength, m);

	ALBEDO = base;
	ROUGHNESS = mix(1.0, 0.82, rocky);

	// --- surface relief -----------------------------------------------------
	// Two octaves of normal map, projected flat on XZ. Planar rather than
	// triplanar on purpose: this is three samples cheaper, and the terrain is
	// mostly horizontal where relief matters most. Near-vertical faces already
	// carry their form in the mesh.
	vec3 n1 = texture(relief, wpos.xz * relief_scale).rgb * 2.0 - 1.0;
	vec3 n2 = texture(relief, wpos.xz * relief_scale_far).rgb * 2.0 - 1.0;
	vec2 d = n1.xy * 0.72 + n2.xy * 0.45;

	// Flatter ground shows relief most; steep faces keep their mesh normal so
	// cliffs do not dissolve into noise.
	float flat_w = clamp(wnrm.y, 0.0, 1.0);
	vec3 pn = normalize(wnrm + vec3(d.x, 0.0, d.y) * bump * flat_w);

	NORMAL = normalize((VIEW_MATRIX * vec4(pn, 0.0)).xyz);
}
