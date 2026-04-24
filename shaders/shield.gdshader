shader_type spatial;
render_mode blend_add, depth_draw_never, cull_back, unshaded;

// ── Basis-Parameter ───────────────────────────────────────────────────────────
uniform vec4  shield_color       : source_color = vec4(0.0, 0.8, 1.0, 0.35);
uniform float integrity          : hint_range(0.0, 1.0) = 1.0;
uniform float rim_power          : hint_range(1.0, 10.0) = 3.0;
uniform float hit_glow_duration  : hint_range(0.0, 5.0) = 2.0;
uniform float impact_radius      : hint_range(0.05, 1.5) = 0.5;

// ── Schockwelle ───────────────────────────────────────────────────────────────
// Expandierender Ring der sich vom Einschlagpunkt nach außen bewegt.
uniform float shockwave_speed      : hint_range(0.5, 8.0)  = 3.0;
uniform float shockwave_width      : hint_range(0.01, 0.3)  = 0.06;
uniform float shockwave_intensity  : hint_range(0.0, 3.0)   = 1.8;
uniform float shockwave_distortion : hint_range(0.0, 0.05)  = 0.012;

// ── Impact-Slots ──────────────────────────────────────────────────────────────
uniform int   impact_slot_count = 2;
uniform vec3  impact_points[8];
uniform float impact_ages[8];
uniform vec4  impact_colors[8];
// 0.0 = Phaser/Disruptor (kein Schockwelle), 1.0 = Torpedo (mit Schockwelle)
uniform float impact_types[8];

// ── Dissolve ──────────────────────────────────────────────────────────────────
uniform float     dissolve_progress : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D dissolve_noise    : hint_default_white;

// ── Muster-Parameter (im Inspector per Schiff einstellbar) ────────────────────
// 0=None  1=Hexagon  2=Grid  3=Rhombus  4=Rings  5=Triangles
uniform int   pattern_type      : hint_enum("None,Hexagon,Grid,Rhombus,Rings,Triangles") = 1;
uniform float pattern_scale     : hint_range(5.0, 200.0) = 60.0;
uniform float pattern_line_width: hint_range(0.01, 0.3)  = 0.05;
uniform float pattern_intensity : hint_range(0.0, 5.0)   = 1.5;

// ── Debug ─────────────────────────────────────────────────────────────────────
uniform int   debug_mode = 0;

varying vec3 v_local_pos;

// =============================================================================
//  VERTEX
// =============================================================================
void vertex() {
	v_local_pos = VERTEX;
}

// =============================================================================
//  IMPACT-HELPER
// =============================================================================
// Gibt vec3 zurück: x=glow_strength, y=color_t, z=shockwave_strength
// impact_type: 0.0=kein Schockwelle (Phaser), 1.0=Schockwelle (Torpedo)
vec3 eval_impact(vec3 frag_dir, vec3 hit_dir, float age, float impact_type) {
	if (age < 0.0 || age >= hit_glow_duration)
		return vec3(0.0, 1.0, 0.0);

	float cos_a   = clamp(dot(frag_dir, hit_dir), -1.0, 1.0);
	float angle   = acos(cos_a);
	float spatial = smoothstep(impact_radius, 0.0, angle);

	float center_dip = 1.0 - smoothstep(0.0, impact_radius * 0.35, angle);
	float ring_shape = spatial * (1.0 - center_dip * 0.55);

	float progress   = age / hit_glow_duration;
	float fade_in    = smoothstep(0.0, 0.1, progress);
	float fade_out   = 1.0 - smoothstep(0.1, 1.0, progress);
	float time_shape = fade_in * fade_out * (1.0 / 0.9);
	float color_t    = smoothstep(0.0, 0.4, progress);

	// ── Expandierende Schockwelle ─────────────────────────────────────────────
	// Ring-Radius wächst mit der Zeit: beginnt am Einschlag, expandiert nach außen
	float wave_radius   = progress * shockwave_speed * impact_radius;
	float wave_dist     = abs(angle - wave_radius);
	// Ring-Form: glatter Peak um wave_radius herum
	float wave_shape    = smoothstep(shockwave_width, 0.0, wave_dist);
	// Schockwelle verblasst während sie expandiert (schnell am Anfang, dann weg)
	float wave_fade     = (1.0 - smoothstep(0.0, 0.7, progress)) * fade_in;
	// Stopp wenn die Welle den Schildrand erreicht
	float wave_in_range = step(wave_radius, impact_radius * shockwave_speed * 0.95);
	// Schockwelle nur für Torpedo-Treffer (impact_type == 1.0)
	float shockwave     = wave_shape * wave_fade * wave_in_range * shockwave_intensity * impact_type;

	return vec3(ring_shape * time_shape, color_t, shockwave);
}

// =============================================================================
//  MUSTER-FUNKTIONEN
// =============================================================================

// ── 1 · Hexagon  (Federation / Standard) ─────────────────────────────────────
vec2 _hex_coord(vec2 uv) {
	uv.x *= 1.1547;
	uv.y += mod(floor(uv.x), 2.0) * 0.5;
	return uv;
}
float pat_hexagon(vec2 uv) {
	uv *= pattern_scale;
	vec2 gv = fract(_hex_coord(uv)) - 0.5;
	return smoothstep(0.5, 0.5 - pattern_line_width, length(gv));
}

// ── 2 · Grid / Raster  (Borg, Tech) ──────────────────────────────────────────
float pat_grid(vec2 uv) {
	uv *= pattern_scale;
	vec2 gv = abs(fract(uv) - 0.5);
	return max(
		smoothstep(0.5, 0.5 - pattern_line_width, gv.x),
		smoothstep(0.5, 0.5 - pattern_line_width, gv.y)
	);
}

// ── 3 · Rhombus / Raute  (Klingon) ───────────────────────────────────────────
float pat_rhombus(vec2 uv) {
	uv *= pattern_scale * 0.7;
	// 45°-Rotation → Quadrat wird zur Raute
	vec2 rot = vec2(uv.x + uv.y, uv.x - uv.y) * 0.7071;
	vec2 gv  = abs(fract(rot) - 0.5);
	float d  = gv.x + gv.y; // Manhattan-Distanz → Rautenkontur
	return smoothstep(0.5, 0.5 - pattern_line_width * 1.5, d);
}

// ── 4 · Konzentrische Ringe  (Romulan / Alien) ────────────────────────────────
float pat_rings(vec2 uv) {
	float dist  = length(uv - 0.5) * pattern_scale * 0.5;
	float rings = abs(sin(dist * TAU));
	return smoothstep(1.0 - pattern_line_width * 4.0, 1.0, rings);
}

// ── 5 · Dreiecks-Mesh  (Vulkan / Alien) ──────────────────────────────────────
float pat_triangles(vec2 uv) {
	uv *= pattern_scale;
	uv.x += uv.y * 0.5;
	vec2 gv  = fract(uv) - 0.5;
	float tri = abs(gv.x) + abs(gv.y);
	return smoothstep(0.5, 0.5 - pattern_line_width, tri);
}

// ── Dispatcher ────────────────────────────────────────────────────────────────
float eval_pattern(vec2 uv) {
	if (pattern_type == 1) return pat_hexagon(uv);
	if (pattern_type == 2) return pat_grid(uv);
	if (pattern_type == 3) return pat_rhombus(uv);
	if (pattern_type == 4) return pat_rings(uv);
	if (pattern_type == 5) return pat_triangles(uv);
	return 0.0; // 0 = None
}

// =============================================================================
//  FRAGMENT
// =============================================================================
void fragment() {
	// ── Dissolve-Discard ──────────────────────────────────────────────────────
	float noise_val = texture(dissolve_noise, UV * 2.0).r;
	if (noise_val < dissolve_progress) discard;

	vec3 frag_dir = normalize(v_local_pos);

	// ── Alle aktiven Impact-Slots aufsummieren ────────────────────────────────
	vec3  glow_col     = vec3(0.0);
	float glow_str     = 0.0;
	float last_hit_age = 9999.0;
	int   active_count = 0;

	float shockwave_total = 0.0;
	vec3  shockwave_col   = vec3(0.0);

	int count = clamp(impact_slot_count, 0, 8);
	for (int i = 0; i < count; i++) {
		float age = impact_ages[i];
		if (age < 0.0 || age >= hit_glow_duration) continue;
		vec3 imp = eval_impact(frag_dir, normalize(impact_points[i]), age, impact_types[i]);
		if (imp.x <= 0.0 && imp.z <= 0.0) continue;

		// Glow-Beitrag
		if (imp.x > 0.0) {
			glow_col    += mix(impact_colors[i].rgb, shield_color.rgb, imp.y) * imp.x;
			glow_str     = max(glow_str, imp.x);
			last_hit_age = min(last_hit_age, age);
			active_count++;
		}

		// Schockwellen-Beitrag
		if (imp.z > 0.0) {
			// Schockwelle leuchtet in Einschlagsfarbe → Schild-Farbe
			vec3 wave_color   = mix(impact_colors[i].rgb, shield_color.rgb * 1.8, 0.4);
			shockwave_col    += wave_color * imp.z;
			shockwave_total   = max(shockwave_total, imp.z);
		}
	}
	if (active_count > 1 && glow_str > 0.0)
		glow_col /= float(active_count);
	if (active_count > 1 && shockwave_total > 0.0)
		shockwave_col /= float(active_count);

	// ── Muster über den Impact legen ──────────────────────────────────────────
	if (pattern_type > 0 && glow_str > 0.01)
		glow_col += shield_color.rgb * pattern_intensity * eval_pattern(UV) * glow_str;

	// ── Rim-Glow ──────────────────────────────────────────────────────────────
	float rim_fade = (last_hit_age < 9999.0)
		? clamp(1.0 - last_hit_age / hit_glow_duration, 0.0, 1.0) : 0.0;
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), rim_power)
				* rim_fade * shield_color.a * glow_str;

	// ── Low-Integrity-Warnung ─────────────────────────────────────────────────
	float warn_alpha = 0.0;
	if (integrity < 0.25) {
		float warn = step(0.5, sin(TIME * 6.0)) * (1.0 - integrity * 4.0);
		glow_col   = mix(glow_col, vec3(1.0, 0.1, 0.0), warn * max(glow_str, 0.01));
		warn_alpha = warn * 0.15;
	}

	// ── Dissolve-Rand ─────────────────────────────────────────────────────────
	float edge_d   = smoothstep(dissolve_progress, dissolve_progress + 0.06, noise_val);
	// Dissolve-Rand in Schildfarbe – aufgehellt damit der Rand sichtbar bleibt.
	// mix(..., 1.4) boosted die Schildfarbe Richtung Weiß für den Glüh-Effekt.
	vec3  dissolve_edge_color = clamp(shield_color.rgb * 1.8, 0.0, 1.0);
	vec3  edge_col = dissolve_edge_color * (1.0 - edge_d) * dissolve_progress * 3.0;

	// ── Debug-Modi ────────────────────────────────────────────────────────────
	if (debug_mode == 1) {
		ALBEDO   = vec3(1.0, 0.0, 0.0);
		ALPHA    = 0.9;
		EMISSION = vec3(2.0, 0.0, 0.0);

	} else if (debug_mode == 2) {
		vec3 c = (active_count > 0) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		ALBEDO   = c;
		ALPHA    = 0.9;
		EMISSION = c * 3.0;

	} else if (debug_mode == 3) {
		ALBEDO   = vec3(glow_str);
		ALPHA    = max(glow_str * 0.95, 0.15);
		EMISSION = vec3(glow_str * 5.0);

	} else if (debug_mode == 4) {
		ALBEDO   = abs(frag_dir);
		ALPHA    = 0.8;
		EMISSION = abs(frag_dir) * 2.0;

	} else if (debug_mode == 5) {
		float min_angle = 3.14159;
		for (int i = 0; i < count; i++) {
			if (impact_ages[i] >= 0.0 && impact_ages[i] < hit_glow_duration)
				min_angle = min(min_angle,
					acos(clamp(dot(frag_dir, normalize(impact_points[i])), -1.0, 1.0)));
		}
		vec3 c = (active_count > 0)
			? mix(vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0),
				  clamp(min_angle / impact_radius, 0.0, 1.0))
			: vec3(0.0, 0.0, 0.5);
		ALBEDO   = c;
		ALPHA    = 0.85;
		EMISSION = c * 3.0;

	} else {
		// ── Normales Rendering ────────────────────────────────────────────────
		// Schockwelle addiert sich zum Glow — heller weißlicher Ring
		vec3  combined_glow = glow_col + shockwave_col;
		float combined_str  = max(glow_str, shockwave_total * 0.6);

		ALBEDO   = combined_glow + edge_col;
		ALPHA    = clamp(combined_str * 0.95 + warn_alpha + dissolve_progress * 0.5, 0.0, 0.95)
				   * (1.0 - dissolve_progress);
		EMISSION = clamp(combined_glow * combined_str * 1.5, 0.0, 0.85)
				   + rim * shield_color.rgb * 1.2
				   + edge_col
				   // Schockwelle hat eigenes Emission-Boost damit sie durch Bloom leuchtet
				   + shockwave_col * shockwave_total * 2.5;
	}
}
