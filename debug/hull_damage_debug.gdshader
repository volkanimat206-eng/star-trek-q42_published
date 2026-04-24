// res://shaders/hull_damage_debug.gdshader
//
// ISOLATIONS-SHADER zum schrittweisen Debuggen.
// Jede Phase mit debug_mode aktivieren:
//
//   debug_mode=0  Nur ALPHA-Test (halbtransparenter Überzug)
//   debug_mode=1  Alpha mit hull_integrity-Schwellwert
//   debug_mode=2  Lokale Vertex-Position als Farbe (prüft VERTEX-Koordinatensystem)
//   debug_mode=3  Single Impact als Farbkreis (prüft lokale Koordinaten + Array-Uniform)
//   debug_mode=4  Vollständiger Effekt (Crack + Impact)
//
// Vorgehen:
//   Phase 1 (mode=0): Overlay sichtbar? Alpha korrekt?
//   Phase 2 (mode=1): integrity_parameter kommt an?
//   Phase 3 (mode=2): VERTEX-Koordinaten plausibel?
//   Phase 4 (mode=3): Impact klebt am Schiff?
//   Phase 5 (mode=4): Vollbetrieb

shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, unshaded;

// ── Basis ──────────────────────────────────────────────────────────────────
uniform float hull_integrity : hint_range(0.0, 1.0) = 1.0;
uniform int   debug_mode = 0;

// ── Impact-Test ────────────────────────────────────────────────────────────
uniform vec3  impact_positions[16];
uniform float impact_ages[16];
uniform int   impact_count = 0;
uniform float impact_radius        : hint_range(1.0, 50.0) = 12.0;
uniform float impact_fade_duration : hint_range(1.0, 30.0) = 8.0;

// ── Crack-Noise (optional) ─────────────────────────────────────────────────
uniform sampler2D noise_cracks : hint_default_white, repeat_enable;
uniform float crack_scale      : hint_range(0.5, 20.0) = 4.0;
uniform float ship_size        : hint_range(1.0, 200.0) = 25.0;

// ─────────────────────────────────────────────────────────────────────────
varying vec3 local_pos;
varying vec3 world_pos;

void vertex() {
	local_pos = VERTEX;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// ── Prozedurales Noise ─────────────────────────────────────────────────────
float hash21(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}
float vnoise(vec2 uv) {
	vec2 i = floor(uv); vec2 f = fract(uv);
	vec2 s = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i+vec2(1,0)), s.x),
	           mix(hash21(i+vec2(0,1)), hash21(i+vec2(1,1)), s.x), s.y);
}
float fbm4(vec2 uv) {
	float v=0.0; float a=0.5;
	for(int i=0;i<4;i++){v+=a*vnoise(uv);uv*=2.1;a*=0.5;}
	return v;
}

void fragment() {
	vec3 out_color = vec3(0.0);
	float out_alpha = 0.0;

	if (debug_mode == 0) {
		// ── Phase 1: Reiner Alpha-Test ──────────────────────────────────────
		// Erwartung: halbtransparenter ROTER Überzug über dem ganzen Schiff
		// FAIL: ganzes Schiff undurchsichtig rot → render_mode/Material-Slot Bug
		// FAIL: nichts sichtbar → Overlay-Mesh nicht korrekt erzeugt
		out_color = vec3(1.0, 0.0, 0.0);
		out_alpha = 0.4;

	} else if (debug_mode == 1) {
		// ── Phase 2: hull_integrity ankommen? ──────────────────────────────
		// integrity=1.0 → unsichtbar | integrity=0.0 → voll sichtbar rot
		// FAIL: immer sichtbar → set_shader_parameter greift nicht
		float damage = 1.0 - hull_integrity;
		out_color = vec3(1.0, 0.3, 0.0);
		out_alpha = damage;

	} else if (debug_mode == 2) {
		// ── Phase 3: VERTEX-Koordinatensystem visualisieren ─────────────────
		// Zeigt x/y/z als rgb – Schiff sollte bunt eingefärbt sein
		// nicht als solide Farbe (dann stimmen Koordinaten nicht)
		// Normalisiert auf ship_size damit Farben plausibel verteilt sind
		vec3 norm_pos = (local_pos / ship_size) * 0.5 + 0.5;
		out_color = abs(norm_pos);
		out_alpha = 0.8;

	} else if (debug_mode == 3) {
		// ── Phase 4: Single Impact klebt am Schiff? ─────────────────────────
		// Prüft ob impact_positions[0] im lokalen Raum korrekt ist
		// Erwartung: orangefarbener Kreis der sich mit dem Schiff mitbewegt
		// FAIL: Kreis bleibt fix in der Welt → to_local() falsch
		// FAIL: kein Kreis → Array-Uniform kommt nicht an
		vec3 imp_w0 = (MODEL_MATRIX * vec4(impact_positions[0], 1.0)).xyz;
		float d = distance(world_pos, imp_w0);
		float circle = 1.0 - smoothstep(impact_radius * 0.5, impact_radius, d);
		float age    = impact_ages[0];
		float fade   = 1.0 - clamp(age / impact_fade_duration, 0.0, 1.0);
		out_color = vec3(1.0, 0.5, 0.0);
		out_alpha = circle * fade;

	} else {
		// ── Phase 5: Vollständiger Effekt ───────────────────────────────────
		float damage      = 1.0 - hull_integrity;
		vec2  uv_crack    = vec2(local_pos.x, local_pos.z) / ship_size * crack_scale; // local_pos = am Mesh fixiert
		float crack_n     = texture(noise_cracks, uv_crack).r;
		float crack_t     = clamp(damage * 2.0, 0.0, 0.6);
		float cracks      = 1.0 - smoothstep(0.0, crack_t, crack_n);

		float total_impact = 0.0;
		for (int i = 0; i < 16; i++) {
			if (i >= impact_count) break;
			float age  = impact_ages[i];
			float fade = 1.0 - clamp(age / impact_fade_duration, 0.0, 1.0);
			vec3 imp_w = (MODEL_MATRIX * vec4(impact_positions[i], 1.0)).xyz;
			float d    = distance(world_pos, imp_w);
			total_impact = max(total_impact,
				(1.0 - smoothstep(0.0, impact_radius, d)) * fade);
		}

		float combined = clamp(cracks + total_impact, 0.0, 1.0);
		out_color = mix(vec3(0.3, 0.1, 0.05), vec3(0.06, 0.05, 0.05), cracks);
		out_alpha = combined;
	}

	ALBEDO = out_color;
	ALPHA  = out_alpha;
}
