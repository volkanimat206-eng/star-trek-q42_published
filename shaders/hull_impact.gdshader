// Transparentes Overlay – rendert NUR die Impact-Effekte.
// Das Original-Material der Hülle bleibt völlig unberührt.
// render_mode blend_add: Emission addiert sich zum Original (Leuchteffekt)
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_back, unshaded;

// ── Aktive Glows ──────────────────────────────────────────────────────────────
uniform vec4  active_glows[4];
uniform float impact_radius         : hint_range(0.5, 500.0) = 25.0;

uniform vec4  scorch_ring_color     : source_color = vec4(0.0,  0.0,  0.0,  1.0);
uniform vec4  ember_color           : source_color = vec4(0.9,  0.15, 0.02, 1.0);
uniform vec4  ember_hot_color       : source_color = vec4(1.0,  0.55, 0.05, 1.0);
uniform vec4  center_color          : source_color = vec4(1.0,  0.95, 0.6,  1.0);

uniform float zone_scorch_end       : hint_range(0.0, 1.0) = 0.85;
uniform float zone_ember_end        : hint_range(0.0, 1.0) = 0.65;
uniform float zone_hot_end          : hint_range(0.0, 1.0) = 0.30;
uniform float zone_center_end       : hint_range(0.0, 1.0) = 0.10;

uniform float emission_ember        : hint_range(0.0, 8.0)  = 2.5;
uniform float emission_hot          : hint_range(0.0, 8.0)  = 5.0;
uniform float emission_center       : hint_range(0.0, 15.0) = 10.0;

uniform float pulse_speed           : hint_range(0.0, 10.0) = 2.5;
uniform float pulse_intensity       : hint_range(0.0, 1.0)  = 0.35;
uniform float pulse_speed2          : hint_range(0.0, 10.0) = 5.7;
uniform float pulse_intensity2      : hint_range(0.0, 0.5)  = 0.15;

// ── Risse ─────────────────────────────────────────────────────────────────────
uniform int   crack_count_min       : hint_range(0, 16) = 3;
uniform int   crack_count_max       : hint_range(0, 16) = 6;
uniform float crack_length_min      : hint_range(0.0, 2.0) = 0.8;
uniform float crack_length_max      : hint_range(0.0, 2.0) = 1.4;
uniform float crack_width           : hint_range(0.001, 0.3) = 0.06;
uniform float crack_irregularity    : hint_range(0.0, 1.0)   = 0.45;
uniform float crack_depth           : hint_range(0.0, 1.0)   = 0.85;
uniform float crack_glow_intensity  : hint_range(0.0, 3.0)   = 0.8;
uniform vec4  crack_glow_color      : source_color = vec4(1.0, 0.3, 0.05, 1.0);

// ── Persistente Brandspuren ───────────────────────────────────────────────────
uniform vec4  scorch_marks[8];
uniform float scorch_radius         : hint_range(0.5, 500.0) = 8.0;
uniform vec4  scorch_color          : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float scorch_max_opacity    : hint_range(0.0, 1.0) = 0.6;
uniform float scorch_edge_softness  : hint_range(0.0, 1.0) = 0.8;

varying vec3 vertex_object_pos;

void vertex() {
	vertex_object_pos = VERTEX;
	// Minimal nach außen versetzen um Z-Fighting zu vermeiden
	VERTEX += NORMAL * 0.02;
}

float hash3(vec3 p) {
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}

float compute_crack(vec3 center, vec3 frag_pos, float seed, float intensity) {
	if (crack_count_max < 1) { return 0.0; }
	int   count    = crack_count_min + int(hash3(vec3(seed * 0.1, seed * 0.7, 1.3))
					  * float(crack_count_max - crack_count_min + 1));
	count          = clamp(count, crack_count_min, crack_count_max);
	float length_f = crack_length_min + hash3(vec3(seed * 0.5, seed * 1.1, 2.7))
					  * (crack_length_max - crack_length_min);

	vec3  delta    = frag_pos - center;
	float dist     = length(delta);
	float max_dist = impact_radius * length_f;
	if (dist > max_dist || dist < 0.001) { return 0.0; }

	float frag_angle   = atan(delta.z, delta.x);
	float crack_result = 0.0;
	float base_step    = 6.28318 / float(count);

	for (int c = 0; c < 16; c++) {
		if (c >= count) { break; }
		float base_angle    = float(c) * base_step;
		float random_offset = (hash3(vec3(seed + float(c) * 0.37, seed * 1.3, float(c))) - 0.5)
							  * base_step * crack_irregularity;
		float crack_angle   = base_angle + random_offset;
		float angle_diff    = frag_angle - crack_angle;
		angle_diff          = angle_diff - round(angle_diff / 6.28318) * 6.28318;

		float norm_dist     = dist / max(max_dist, 0.001);
		float width_at_dist = crack_width * (1.0 - norm_dist * 0.7);
		float angular_width = width_at_dist / max(dist / impact_radius, 0.1);
		angular_width       = clamp(angular_width, 0.005, 0.5);
		float in_crack      = (1.0 - smoothstep(0.0, angular_width, abs(angle_diff)))
							  * (1.0 - smoothstep(0.7, 1.0, norm_dist)) * intensity;
		crack_result        = max(crack_result, in_crack);
	}
	return crack_result;
}

void fragment() {
	vec3  out_color = vec3(0.0);
	float alpha     = 0.0;

	// ── Persistente Brandspuren (dunkel, subtil) ──────────────────────────
	float total_scorch = 0.0;
	for (int i = 0; i < 8; i++) {
		float si = scorch_marks[i].w;
		if (si < 0.001) { continue; }
		float d        = length(vertex_object_pos - scorch_marks[i].xyz);
		float n        = clamp(d / max(scorch_radius, 0.001), 0.0, 1.0);
		float edge_end = mix(0.3, 1.0, scorch_edge_softness);
		total_scorch  += (1.0 - smoothstep(0.0, edge_end, n)) * si;
	}
	total_scorch = clamp(total_scorch, 0.0, 1.0);
	// Scorch als dunkles Overlay (negative Emission geht nicht in blend_add)
	// → Scorch als subtile dunkle Färbung, primär durch Scorch-Mesh sichtbar
	alpha = max(alpha, total_scorch * scorch_max_opacity * 0.3);

	// ── Aktive Glows ──────────────────────────────────────────────────────
	for (int i = 0; i < 4; i++) {
		float raw_w          = active_glows[i].w;
		float glow_intensity = abs(raw_w);
		bool  is_persistent  = (raw_w < -0.001);
		if (glow_intensity < 0.001) { continue; }

		vec3  impact_center = active_glows[i].xyz;
		float d             = length(vertex_object_pos - impact_center);
		float norm_dist     = clamp(d / max(impact_radius, 0.001), 0.0, 1.0);
		float max_crack_d   = impact_radius * crack_length_max;
		if (d > max_crack_d + 0.5) { continue; }

		float hash_val  = hash3(vertex_object_pos * 0.3);
		float spd_mult  = is_persistent ? 0.5 : 1.0;
		float pulse = 1.0
			- pulse_intensity  * (0.5 + 0.5 * sin(TIME * pulse_speed  * spd_mult + hash_val * 6.283))
			- pulse_intensity2 * (0.5 + 0.5 * sin(TIME * pulse_speed2 * spd_mult + hash_val * 12.56 + 1.5));
		pulse = clamp(pulse, 0.0, 1.0) * glow_intensity;

		// Risse
		float crack_seed = hash3(impact_center * 7.3 + 0.5) * 100.0;
		float crack_mask = compute_crack(impact_center, vertex_object_pos, crack_seed, glow_intensity);
		if (crack_mask > 0.001) {
			out_color += crack_glow_color.rgb * crack_mask * crack_glow_intensity * pulse;
			alpha      = max(alpha, crack_mask * crack_glow_intensity * pulse * 0.8);
		}

		// Ember-Zonen
		if (norm_dist <= 1.0) {
			float scorch_ring = smoothstep(zone_scorch_end, 1.0, norm_dist)
							  * (1.0 - smoothstep(0.97, 1.0, norm_dist)) * glow_intensity;
			float ember_mask  = smoothstep(zone_ember_end, zone_scorch_end, norm_dist)
							  * (1.0 - smoothstep(zone_scorch_end - 0.05, zone_scorch_end, norm_dist));
			float hot_mask    = smoothstep(zone_hot_end, zone_ember_end, norm_dist)
							  * (1.0 - smoothstep(zone_ember_end - 0.05, zone_ember_end, norm_dist));
			float center_mask = 1.0 - smoothstep(zone_center_end, zone_hot_end, norm_dist);

			vec3 ember_final = mix(ember_color.rgb, ember_hot_color.rgb,
								   smoothstep(zone_ember_end, zone_hot_end, norm_dist));

			out_color += ember_final        * ember_mask  * pulse * emission_ember;
			out_color += ember_hot_color.rgb * hot_mask   * pulse * emission_hot;
			out_color += center_color.rgb   * center_mask * glow_intensity * emission_center;

			float zone_coverage = ember_mask + hot_mask + center_mask + scorch_ring;
			alpha = max(alpha, zone_coverage * glow_intensity);
		}
	}

	ALBEDO  = out_color;
	ALPHA   = clamp(alpha, 0.0, 1.0);
}
