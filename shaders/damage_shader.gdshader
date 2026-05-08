// res://shaders/damage_shader_v3_hybrid.gdshader
//
// V3 - HYBRID EDITION (Brandspuren + Pulsierende Hüllbrüche)
//
// ÄNDERUNGEN:
// - Entkoppelung von Albedo-Schaden (Brand) und Emission (Glut).
// - Brandspuren erscheinen jetzt früher und subtiler im Albedo.
// - Emission (Hüllbrüche) reagiert extrem auf die Pulse-Logik.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx, depth_prepass_alpha;

// ─────────────────────────────────────────────────────────────────────────────
// ORIGINAL UNIFORMS
// ─────────────────────────────────────────────────────────────────────────────
uniform vec4      albedo                  : source_color;
uniform sampler2D texture_albedo          : source_color, filter_linear_mipmap, repeat_enable;
uniform ivec2     albedo_texture_size;
uniform float     point_size              : hint_range(0.1, 128.0, 0.1);
uniform float     roughness               : hint_range(0.0, 1.0);
uniform sampler2D texture_metallic        : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4      metallic_texture_channel;
uniform sampler2D texture_roughness       : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform float     specular                : hint_range(0.0, 1.0, 0.01);
uniform float     metallic                : hint_range(0.0, 1.0, 0.01);
uniform sampler2D texture_emission        : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec4      emission                : source_color;
uniform float     emission_energy         : hint_range(0.0, 100.0, 0.01);
uniform sampler2D texture_normal          : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float     normal_scale            : hint_range(-16.0, 16.0);
uniform vec3      uv1_scale;
uniform vec3      uv1_offset;
uniform vec3      uv2_scale;
uniform vec3      uv2_offset;

// ─────────────────────────────────────────────────────────────────────────────
// DAMAGE UNIFORMS
// ─────────────────────────────────────────────────────────────────────────────
uniform float     damage_amount           : hint_range(0.0, 1.0) = 0.0;
uniform float     cloak_alpha             : hint_range(0.0, 1.0) = 1.0;
uniform float     damage_threshold        : hint_range(0.0, 1.0) = 0.15;
uniform float     damage_edge_softness    : hint_range(0.01, 0.5) = 0.20;
uniform float     damage_noise_scale      : hint_range(1.0, 50.0) = 12.0;

// Schadenszonen-Farben — mehrschichtig
uniform vec3      burn_color_dark         : source_color = vec3(0.04, 0.02, 0.01);   // Verkohlter Kern
uniform vec3      burn_color_char         : source_color = vec3(0.12, 0.06, 0.02);   // Grauer Schutt
uniform vec3      burn_color_glow         : source_color = vec3(1.0, 0.45, 0.05);    // Orange Glut
uniform float     burn_soot_intensity     : hint_range(0.0, 1.0) = 0.8;                // Wie schwarz wird der Ruß? (NEU)

// ── ZWEIFARBIGER MOLTEN-KERN ─────────────────────────────────────────────────
uniform vec3      burn_color_molten       : source_color = vec3(1.0, 0.35, 0.05);    // Außen: Rot-Orange
uniform vec3      burn_color_molten_core  : source_color = vec3(1.0, 0.92, 0.55);    // Innen: Weiß-Gelb
uniform float     molten_core_falloff     : hint_range(0.5, 6.0) = 2.5;              // Schärfe des Innen-Außen-Übergangs

uniform float     burn_glow_energy        : hint_range(0.0, 16.0) = 4.0;
uniform float     burn_molten_energy      : hint_range(0.0, 32.0) = 12.0;

uniform float     damage_roughness_boost  : hint_range(0.0, 1.0) = 0.75;
uniform float     damage_normal_disturb   : hint_range(0.0, 4.0) = 1.8;

// ─────────────────────────────────────────────────────────────────────────────
// CRACK / RISS-SYSTEM
// ─────────────────────────────────────────────────────────────────────────────
uniform float     crack_amount            : hint_range(0.0, 1.0) = 0.6;
uniform float     crack_scale             : hint_range(1.0, 40.0) = 8.0;
uniform float     crack_width             : hint_range(0.01, 0.3) = 0.06;
uniform float     crack_glow_intensity    : hint_range(0.0, 8.0) = 3.0;
uniform float     crack_drift_amount      : hint_range(0.0, 1.0) = 0.0;

// ─────────────────────────────────────────────────────────────────────────────
// STREAK-SYSTEM
// ─────────────────────────────────────────────────────────────────────────────
uniform float     streak_amount           : hint_range(0.0, 1.0) = 0.4;
uniform vec3      streak_direction        = vec3(0.0, 0.0, 1.0);
uniform float     streak_stretch          : hint_range(1.0, 16.0) = 6.0;
uniform float     streak_scale            : hint_range(1.0, 40.0) = 7.0;
uniform float     streak_threshold        : hint_range(0.0, 1.0) = 0.15;

// ─────────────────────────────────────────────────────────────────────────────
// CRATER-RIM HIGHLIGHT
// ─────────────────────────────────────────────────────────────────────────────
uniform float     rim_width               : hint_range(0.0, 0.5) = 0.15;
uniform float     rim_glow_energy         : hint_range(0.0, 8.0) = 2.5;

// ─────────────────────────────────────────────────────────────────────────────
// HEAT-GLOW PULSATION
// ─────────────────────────────────────────────────────────────────────────────
uniform float     pulse_amplitude         : hint_range(0.0, 1.0) = 0.45;
uniform float     pulse_speed_hz          : hint_range(0.0, 10.0) = 1.2;
uniform float     pulse_async_amount      : hint_range(0.0, 1.0) = 0.7;
uniform float     pulse_flicker_amount    : hint_range(0.0, 1.0) = 0.35;

// ─────────────────────────────────────────────────────────────────────────────
// INNER HULL — PIPES
// ─────────────────────────────────────────────────────────────────────────────
uniform float     inner_hull_amount       : hint_range(0.0, 1.0) = 1.0;
uniform float     inner_hull_threshold    : hint_range(0.1, 0.9) = 0.55;
uniform float     inner_hull_darkness     : hint_range(0.0, 1.0) = 0.15;
uniform float     inner_grid_scale        : hint_range(1.0, 80.0) = 25.0;
uniform float     inner_pipe_thickness    : hint_range(0.02, 0.5) = 0.12;
uniform float     inner_pipe_orientation  : hint_range(0.0, 1.0) = 0.3;
uniform vec3      inner_pipe_color        : source_color = vec3(0.4, 0.25, 0.10);
uniform vec3      inner_pipe_glow_color   : source_color = vec3(1.0, 0.5, 0.2);
uniform float     inner_pipe_glow_energy  : hint_range(0.0, 8.0) = 1.5;
uniform float     inner_parallax_depth    : hint_range(0.0, 0.3) = 0.05;
uniform float     inner_grid_flicker_independence : hint_range(0.0, 1.0) = 0.4;


// ─────────────────────────────────────────────────────────────────────────────
// HELPER FUNCTIONS
// ─────────────────────────────────────────────────────────────────────────────
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float hash31(vec3 p) {
	p = fract(p * vec3(123.34, 456.21, 789.13));
	p += dot(p, p.yzx + 45.32);
	return fract(p.x * p.y * p.z);
}

vec3 hash33(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash21(i + vec2(0.0, 0.0));
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float value_noise_3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);

	float a  = hash31(i + vec3(0.0, 0.0, 0.0));
	float b  = hash31(i + vec3(1.0, 0.0, 0.0));
	float c  = hash31(i + vec3(0.0, 1.0, 0.0));
	float d  = hash31(i + vec3(1.0, 1.0, 0.0));
	float e  = hash31(i + vec3(0.0, 0.0, 1.0));
	float f1 = hash31(i + vec3(1.0, 0.0, 1.0));
	float g  = hash31(i + vec3(0.0, 1.0, 1.0));
	float h  = hash31(i + vec3(1.0, 1.0, 1.0));

	return mix(
		mix(mix(a, b, u.x), mix(c, d, u.x), u.y),
		mix(mix(e, f1, u.x), mix(g, h, u.x), u.y),
		u.z
	);
}

float fbm_3d(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * value_noise_3d(p);
		p *= 2.1;
		a *= 0.5;
	}
	return v;
}

float fbm_3d_warped(vec3 p) {
	vec3 warp = vec3(
		fbm_3d(p + vec3(0.0, 0.0, 0.0)),
		fbm_3d(p + vec3(5.2, 1.3, 2.8)),
		fbm_3d(p + vec3(1.7, 9.2, 4.1))
	);
	return fbm_3d(p + warp * 0.8);
}

vec2 voronoi_3d(vec3 p, float drift) {
	vec3 i = floor(p);
	vec3 f = fract(p);

	float min_dist1 = 10.0;
	float min_dist2 = 10.0;

	for (int z = -1; z <= 1; z++) {
		for (int y = -1; y <= 1; y++) {
			for (int x = -1; x <= 1; x++) {
				vec3 neighbor = vec3(float(x), float(y), float(z));
				vec3 point    = hash33(i + neighbor);

				vec3 static_offset = 0.5 + 0.4 * (point * 2.0 - 1.0);

				vec3 drifted = static_offset
					+ drift * 0.15 * sin(TIME * 0.3 + TAU * point);

				vec3 diff  = neighbor + drifted - f;
				float dist = dot(diff, diff);

				if (dist < min_dist1) {
					min_dist2 = min_dist1;
					min_dist1 = dist;
				} else if (dist < min_dist2) {
					min_dist2 = dist;
				}
			}
		}
	}

	return vec2(sqrt(min_dist1), sqrt(min_dist2));
}

float crack_mask(vec3 p, float width, float drift) {
	vec2 v = voronoi_3d(p, drift);
	float edge_dist = v.y - v.x;
	return 1.0 - smoothstep(0.0, width, edge_dist);
}

float streak_noise(vec3 model_pos, vec3 dir, float stretch, float scale) {
	vec3 d = normalize(dir + vec3(1e-6));

	float along = dot(model_pos, d);
	vec3  cross = model_pos - along * d;

	vec3 sample_pos = (cross + along / stretch * d) * scale * 0.05;

	return fbm_3d_warped(sample_pos);
}


// ─────────────────────────────────────────────────────────────────────────────
// VARYINGS
// ─────────────────────────────────────────────────────────────────────────────
varying vec3 v_model_pos;


// ─────────────────────────────────────────────────────────────────────────────
// VERTEX
// ─────────────────────────────────────────────────────────────────────────────
void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	v_model_pos = VERTEX;
}


// ─────────────────────────────────────────────────────────────────────────────
// FRAGMENT
// ─────────────────────────────────────────────────────────────────────────────
void fragment() {
	vec2 base_uv = UV;

	// ── ORIGINAL MATERIAL DATEN ─────────────────────────────────────────────
	vec4 albedo_tex   = texture(texture_albedo, base_uv);
	vec3 base_albedo  = albedo.rgb * albedo_tex.rgb;

	float metallic_tex  = dot(texture(texture_metallic, base_uv), metallic_texture_channel);
	float base_metallic = metallic_tex * metallic;

	vec4 roughness_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
	float roughness_tex = dot(texture(texture_roughness, base_uv), roughness_texture_channel);
	float base_roughness = roughness_tex * roughness;

	vec3 base_normal_map = texture(texture_normal, base_uv).rgb;

	vec3 emission_tex  = texture(texture_emission, base_uv).rgb;
	vec3 base_emission = (emission.rgb + emission_tex) * emission_energy;

	float base_alpha = albedo.a * albedo_tex.a;

	// ── DAMAGE-MASKE LOGIK ──────────────────────────────────────────────────
	vec3 noise_pos = v_model_pos * damage_noise_scale * 0.05;

	float n_large   = fbm_3d_warped(noise_pos * 0.5);
	float n_small   = fbm_3d(noise_pos * 2.5);
	float noise_fbm = n_large * 0.65 + n_small * 0.35;

	// Streaks
	float n_streak = streak_noise(v_model_pos, streak_direction, streak_stretch, streak_scale);
	float streak_gate = smoothstep(streak_threshold, streak_threshold + 0.2, damage_amount);
	float streak_contribution = n_streak * streak_amount * streak_gate;

	// Cracks
	vec3  crack_pos    = v_model_pos * crack_scale * 0.05;
	float cracks       = crack_mask(crack_pos, crack_width, crack_drift_amount);
	float crack_base   = cracks * smoothstep(0.1, 0.6, damage_amount);

	// Kombinierter Noise-Wert
	float noise_with_streaks = noise_fbm + streak_contribution * 0.7;
	float noise_combined     = mix(noise_with_streaks,
		max(noise_with_streaks, crack_base * 0.9), crack_amount);

	// ── MASKEN-TRENNUNG (Der wichtige Teil!) ────────────────────────────────
	// Brand-Maske: Erscheint sehr früh (niedriger Threshold)
	float brand_mask = smoothstep(damage_threshold * 0.5, 1.0, noise_combined * (damage_amount * 1.5));
	
	// Glow-Maske: Erscheint erst später und ist schärfer
	float low_end = damage_threshold;
	float high_end = 1.0 - damage_threshold + damage_edge_softness;
	float cutoff = mix(high_end, low_end, damage_amount);
	float damage_mask = smoothstep(cutoff, cutoff + damage_edge_softness, noise_combined);
	damage_mask *= step(0.001, damage_amount);

	// ── PULSATION ───────────────────────────────────────────────────────────
	float t = TIME * pulse_speed_hz * TAU;
	float phase_offset = dot(v_model_pos, vec3(0.13, 0.21, 0.17));
	float pulse_main = mix((sin(t) + 1.0) * 0.5, (sin(t + phase_offset) + 1.0) * 0.5, pulse_async_amount);
	float pulse_factor = 1.0 - pulse_amplitude + pulse_amplitude * pulse_main;

	// ── ALBEDO: BRANDSPUREN (Ruß-Ebene) ─────────────────────────────────────
	// Mische erst den Ruß (Brandspuren) - das passiert unabhängig vom Glühen!
	vec3 soot_albedo = mix(base_albedo, burn_color_dark, brand_mask * burn_soot_intensity);
	
	// Dann Krater/Schutt-Logik
	vec3 final_albedo = mix(soot_albedo, burn_color_char, damage_mask * 1.2);
	
	// Schwache Glut-Andeutung im Albedo für Tiefe
	final_albedo = mix(final_albedo, burn_color_glow * 0.2, damage_mask * pulse_factor * 0.3);

	// Inner-Hull-Loch mit Pipes (wie Original)
	float inner_mask = smoothstep(inner_hull_threshold, 1.0, damage_mask) * inner_hull_amount;
	vec2 parallax_offset = VIEW.xy * inner_parallax_depth;
	vec3 pipes_pos = v_model_pos + vec3(parallax_offset.x, parallax_offset.y, 0.0);
	float pipe_thick_half = inner_pipe_thickness * 0.5;
	float pipe_aa = 0.02;
	float h_cell = fract(pipes_pos.y * inner_grid_scale * 0.05);
	float h_dist = abs(h_cell - 0.5);
	float h_pipe = 1.0 - smoothstep(pipe_thick_half, pipe_thick_half + pipe_aa, h_dist);
	float v_cell = fract(pipes_pos.z * inner_grid_scale * 0.05);
	float v_dist = abs(v_cell - 0.5);
	float v_pipe = 1.0 - smoothstep(pipe_thick_half, pipe_thick_half + pipe_aa, v_dist);
	float pipes_pattern = mix(h_pipe, v_pipe, inner_pipe_orientation);
	pipes_pattern = mix(pipes_pattern, max(h_pipe, v_pipe),
	                step(0.49, inner_pipe_orientation) * step(inner_pipe_orientation, 0.51));
	float pipes_async_phase = dot(v_model_pos, vec3(0.41, 0.13, 0.27)) * 2.7;
	float pipes_async_pulse = (sin(t * 1.3 + pipes_async_phase) + 1.0) * 0.5;
	float pipes_pulse_value = mix(pulse_main, pipes_async_pulse, inner_grid_flicker_independence);
	float pipes_visibility = 0.7 + 0.3 * pipes_pulse_value;
	vec3 inner_dark_color = final_albedo * inner_hull_darkness;
	vec3 inner_with_pipes = mix(inner_dark_color, inner_pipe_color, pipes_pattern * pipes_visibility);
	final_albedo = mix(final_albedo, inner_with_pipes, inner_mask);

	ALBEDO = final_albedo;

	// ── EMISSION: DIE HÜLLBRÜCHE ───────────────────────────────────────────
	// Hier nutzen wir jetzt NUR die damage_mask für die Emission!
	
	// Heat-Glow (pulsierend)
	float heat_mask = smoothstep(0.55, 1.0, damage_mask) * damage_amount;
	float heat_mask_pulsed = heat_mask * pulse_factor;
	vec3 heat_emission = burn_color_glow * burn_glow_energy * heat_mask_pulsed;
	
	// Molten Core (Lava im Inneren)
	float molten_mask = smoothstep(0.80, 1.0, damage_mask) * damage_amount;
	molten_mask = pow(molten_mask, 1.5);
	float molten_core_t = pow(smoothstep(0.0, 1.0, molten_mask), molten_core_falloff);
	vec3 molten_blend = mix(burn_color_molten, burn_color_molten_core, molten_core_t);
	vec3 molten_emission = molten_blend * burn_molten_energy * molten_mask * (pulse_factor * 0.7 + 0.3);

	// Risse (Cracks)
	float crack_glow_mask = crack_mask(crack_pos, crack_width * 0.4, crack_drift_amount) 
	                        * damage_mask 
	                        * smoothstep(0.3, 0.7, damage_amount);
	vec3 crack_emission = mix(burn_color_glow, burn_color_molten, 0.6) 
	                       * crack_glow_intensity * crack_glow_mask * pulse_factor;

	// Crater-Rim
	float rim_mask = smoothstep(0.0, rim_width, damage_mask)
	               * (1.0 - smoothstep(rim_width, rim_width * 2.5, damage_mask))
	               * damage_amount;
	vec3 rim_emission = burn_color_glow * rim_glow_energy * rim_mask * pulse_factor;

	// Pipe-Glow
	vec3 pipe_emission = inner_pipe_glow_color * inner_pipe_glow_energy
	                       * pipes_pattern * pipes_visibility * inner_mask;

	EMISSION = base_emission + heat_emission + molten_emission + crack_emission + rim_emission + pipe_emission;

	// ── METALLIC ────────────────────────────────────────────────────────────
	METALLIC = mix(base_metallic, 0.0, damage_mask * 0.8);
	SPECULAR = mix(specular, 0.0, damage_mask * 0.6);

	// ── ROUGHNESS ───────────────────────────────────────────────────────────
	ROUGHNESS = clamp(base_roughness + damage_mask * damage_roughness_boost, 0.0, 1.0);

	// ── NORMAL MAP ──────────────────────────────────────────────────────────
	vec3 unpacked_normal = base_normal_map * 2.0 - 1.0;

	vec3 disturb_pos = v_model_pos * damage_noise_scale * 0.12;
	vec3 disturb_n = vec3(
		fbm_3d(disturb_pos) * 2.0 - 1.0,
		fbm_3d(disturb_pos + vec3(13.7, 7.3, 21.1)) * 2.0 - 1.0,
		1.0
	);
	vec3 crack_disturb = vec3(
		crack_mask(crack_pos + vec3(0.1, 0.0, 0.0), crack_width * 2.0, crack_drift_amount) * 2.0 - 1.0,
		crack_mask(crack_pos + vec3(0.0, 0.1, 0.0), crack_width * 2.0, crack_drift_amount) * 2.0 - 1.0,
		0.5
	);
	disturb_n = normalize(disturb_n + crack_disturb * crack_amount * 0.5);

	vec3 final_normal = mix(
		unpacked_normal,
		normalize(unpacked_normal + disturb_n * damage_normal_disturb),
		damage_mask
	);
	NORMAL_MAP       = final_normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_scale;

	// ── ALPHA ────────────────────────────────────────────────────────────────
	ALPHA *= base_alpha * cloak_alpha;
}