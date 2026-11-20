shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, diffuse_burley, unshaded;

// ------------------------------------------------------------------------------
// Water.
//
// The first version was a flat transparent quad, which gives you a sheet of
// coloured glass lying on the landscape. Three things turn that into water, and
// none of them are expensive:
//
//   DEPTH      colour deepens with how much terrain sits beneath the surface,
//              read from the depth buffer. This alone does most of the work —
//              it is what makes a shoreline look shallow and a basin look deep.
//   FOAM       a bright band where that depth goes to zero, i.e. exactly where
//              water meets land. Free, given the depth read above.
//   MOTION     two normal maps scrolling in different directions at different
//              scales, so the surface never shows a repeating pattern.
//
// depth_draw_never because the water is transparent and must not occlude what
// is behind it in the depth pre-pass.
// ------------------------------------------------------------------------------

uniform sampler2D wave : filter_linear_mipmap, repeat_enable;

uniform vec3 shallow_colour : source_color = vec3(0.18, 0.48, 0.58);
uniform vec3 deep_colour : source_color = vec3(0.05, 0.16, 0.26);
uniform vec3 foam_colour : source_color = vec3(0.92, 0.96, 0.98);

uniform float depth_fade = 2.4;     // metres to reach full deep colour
uniform float foam_width = 0.22;    // metres of shoreline band
uniform float wave_scale = 0.35;
uniform float wave_speed = 0.035;
uniform float wave_strength = 0.30;
uniform float min_alpha = 0.42;
uniform float max_alpha = 0.95;

varying vec3 wpos;
varying float depth_at;


void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	depth_at = COLOR.r;
}


void fragment() {
	// --- how much water is under this pixel -------------------------------
	// Baked into the mesh by Mesher.build_water: red channel is depth in
	// metres scaled over 6 m. Read from geometry rather than from
	// DEPTH_TEXTURE, which the Forward Mobile renderer cannot reliably supply.
	float water_depth = depth_at * 6.0;
	float d = clamp(water_depth / depth_fade, 0.0, 1.0);

	// --- surface motion ----------------------------------------------------
	// Two layers at different scales and opposed directions. A single scrolling
	// layer reads as a sliding texture; two crossing layers read as water.
	vec2 uv1 = wpos.xz * wave_scale + vec2(TIME * wave_speed, TIME * wave_speed * 0.6);
	vec2 uv2 = wpos.xz * wave_scale * 1.9 - vec2(TIME * wave_speed * 0.8, TIME * wave_speed * 1.3);
	vec3 n1 = texture(wave, uv1).rgb * 2.0 - 1.0;
	vec3 n2 = texture(wave, uv2).rgb * 2.0 - 1.0;
	vec2 ripple = n1.xy * 0.65 + n2.xy * 0.35;

	vec3 nrm = normalize(vec3(ripple.x, 1.0, ripple.y) * vec3(wave_strength, 1.0, wave_strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(nrm, 0.0)).xyz);

	// --- colour ------------------------------------------------------------
	vec3 col = mix(shallow_colour, deep_colour, d);

	// Foam at the waterline, nudged by the ripples so the edge is not a clean
	// contour.
	float edge = 1.0 - smoothstep(0.0, foam_width, water_depth + ripple.x * 0.18);
	col = mix(col, foam_colour, edge * 0.80);

	ALBEDO = col;
	ROUGHNESS = mix(0.06, 0.22, d);
	METALLIC = 0.0;
	SPECULAR = 0.6;
	// Shallow water is see-through, deep water is not, and foam is opaque.
	ALPHA = clamp(mix(min_alpha, max_alpha, d) + edge * 0.5, 0.0, 1.0);
}
