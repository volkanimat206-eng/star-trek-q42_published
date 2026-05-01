// res://shaders/damage_shader.gdshader
//
// Hüllen-Damage-Shader für romulanischen Warbird.
// Basiert auf dem auto-generierten Shader aus dem StandardMaterial3D
// (Convert to ShaderMaterial) — alle Original-Properties (Albedo, Emission,
// Roughness, Normal Map etc.) werden 1:1 übernommen.
//
// Bei damage_amount = 0.0  →  Schiff sieht IDENTISCH aus wie vorher.
// Bei damage_amount > 0.0  →  Verkohlte Bereiche, Heat-Glow, mattere Hülle.
//
// Original-Header vom Auto-Convert (für Nachvollziehbarkeit):
//   shader_type spatial;
//   render_mode blend_mix, depth_draw_opaque, cull_disabled, ...;

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx, depth_prepass_alpha;

// ─────────────────────────────────────────────────────────────────────────────
// ORIGINAL UNIFORMS (1:1 vom Auto-Converter übernommen)
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
// DAMAGE UNIFORMS (neu hinzugefügt)
// ─────────────────────────────────────────────────────────────────────────────
// Hauptregler: 0.0 = heile Hülle, 1.0 = maximal beschädigt.
// Wird vom ShipController jeden Frame gesetzt.
uniform float     damage_amount           : hint_range(0.0, 1.0) = 0.0;

// Wie früh Schaden anfängt sichtbar zu werden.
// Hoch (0.3) = sensible Hülle, früh sichtbar. Niedrig (0.05) = lange "ganz".
uniform float     damage_threshold        : hint_range(0.0, 1.0) = 0.15;

// Schärfe der Schadenskante. Klein = harte Kante, groß = weicher Übergang.
uniform float     damage_edge_softness    : hint_range(0.01, 0.5) = 0.20;

// Skalierung der prozeduralen Schadens-Maske auf der Hülle.
// Hoch = feine Detail-Strukturen, niedrig = großflächige Bereiche.
uniform float     damage_noise_scale      : hint_range(1.0, 50.0) = 12.0;

// Farben für die Schadenszonen
uniform vec3      burn_color_dark         : source_color = vec3(0.05, 0.02, 0.01);
uniform vec3      burn_color_glow         : source_color = vec3(1.0, 0.4, 0.1);
uniform float     burn_glow_energy        : hint_range(0.0, 8.0) = 2.0;

// Wieviel Roughness in Damage-Zonen draufkommt
uniform float     damage_roughness_boost  : hint_range(0.0, 1.0) = 0.6;

// Wieviel die Normal-Map in Damage-Zonen verzerrt wird (aufgerissen)
uniform float     damage_normal_disturb   : hint_range(0.0, 2.0) = 0.8;

// ─────────────────────────────────────────────────────────────────────────────
// HEAT-GLOW PULSATION
// ─────────────────────────────────────────────────────────────────────────────
// Pulsationsstärke. 0 = aus (statischer Glow), 1 = volle Modulation
// (Glow schwingt zwischen 0% und 100% der eingestellten Energie).
// Empfehlung: 0.4–0.7 für lebendigen Look ohne Stroboskop-Effekt.
uniform float     pulse_amplitude         : hint_range(0.0, 1.0) = 0.5;

// Pulsationsgeschwindigkeit in Hz (volle Pulse pro Sekunde).
// 0.5 Hz = ruhig brennend, 2 Hz = nervös flackernd, 5+ Hz = elektrisch zuckend.
uniform float     pulse_speed_hz          : hint_range(0.0, 10.0) = 1.5;

// Asynchrone Pulsation: 0 = alle Heat-Zonen pulsieren synchron (gleichmäßiger
// Atmen-Effekt), 1 = jede Zone pulsiert mit eigener Phase (chaotischer,
// wirkt wie viele unabhängige Brände). Mischwerte gehen weich ineinander über.
uniform float     pulse_async_amount      : hint_range(0.0, 1.0) = 0.7;

// Sekundär-Flicker: schneller, kleiner Zufalls-Wackler über dem Haupt-Puls.
// 0 = aus, 1 = volle Stärke. Macht den Glow „elektrisch" statt nur atmend.
uniform float     pulse_flicker_amount    : hint_range(0.0, 1.0) = 0.25;


// ─────────────────────────────────────────────────────────────────────────────
// HELPER: HASH-NOISE (kompakt, ohne externe Texture)
// ─────────────────────────────────────────────────────────────────────────────
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// 3D-Hash für Welt-Raum-Noise (verhindert Symmetrie durch UV-Mirroring)
float hash31(vec3 p) {
	p = fract(p * vec3(123.34, 456.21, 789.13));
	p += dot(p, p.yzx + 45.32);
	return fract(p.x * p.y * p.z);
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

// 3D-Value-Noise — interpoliert zwischen 8 Eckpunkten eines Würfels.
// Nötig, weil UV-Mapping bei Schiffen oft links/rechts gespiegelt ist
// und 2D-Noise dadurch zwingend symmetrisch wirkt. Im Welt-Raum gibt es
// diese Symmetrie nicht.
float value_noise_3d(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);

	float a = hash31(i + vec3(0.0, 0.0, 0.0));
	float b = hash31(i + vec3(1.0, 0.0, 0.0));
	float c = hash31(i + vec3(0.0, 1.0, 0.0));
	float d = hash31(i + vec3(1.0, 1.0, 0.0));
	float e = hash31(i + vec3(0.0, 0.0, 1.0));
	float f1 = hash31(i + vec3(1.0, 0.0, 1.0));
	float g = hash31(i + vec3(0.0, 1.0, 1.0));
	float h = hash31(i + vec3(1.0, 1.0, 1.0));

	return mix(
		mix(mix(a, b, u.x), mix(c, d, u.x), u.y),
		mix(mix(e, f1, u.x), mix(g, h, u.x), u.y),
		u.z
	);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * value_noise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

float fbm_3d(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * value_noise_3d(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}


// ─────────────────────────────────────────────────────────────────────────────
// VARYINGS — vom Vertex- in den Fragment-Shader
// ─────────────────────────────────────────────────────────────────────────────
// Modell-lokale Position. Für die Damage-Maske im 3D-Raum statt UV-Raum.
// Vorteile gegenüber UV-Sampling:
//   1) Keine Symmetrie durch UV-Mirroring (links/rechts unterschiedliche Flecken)
//   2) Konsistente Schadens-Skalierung über das ganze Schiff
//   3) Funktioniert auch auf Modellen ohne UVs
varying vec3 v_model_pos;


// ─────────────────────────────────────────────────────────────────────────────
// VERTEX (Original + Position-Passthrough)
// ─────────────────────────────────────────────────────────────────────────────
void vertex() {
	UV = UV * uv1_scale.xy + uv1_offset.xy;
	v_model_pos = VERTEX;  // Modell-Raum-Position für Damage-Maske
}


// ─────────────────────────────────────────────────────────────────────────────
// FRAGMENT (Original + Damage-Layer)
// ─────────────────────────────────────────────────────────────────────────────
void fragment() {
	vec2 base_uv = UV;

	// ── ORIGINAL: Basis-Materialdaten lesen ─────────────────────────────────
	vec4 albedo_tex = texture(texture_albedo, base_uv);
	vec3 base_albedo = albedo.rgb * albedo_tex.rgb;

	float metallic_tex = dot(texture(texture_metallic, base_uv), metallic_texture_channel);
	float base_metallic = metallic_tex * metallic;

	vec4 roughness_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
	float roughness_tex = dot(texture(texture_roughness, base_uv), roughness_texture_channel);
	float base_roughness = roughness_tex * roughness;

	vec3 base_normal_map = texture(texture_normal, base_uv).rgb;

	vec3 emission_tex = texture(texture_emission, base_uv).rgb;
	vec3 base_emission = (emission.rgb + emission_tex) * emission_energy;

	float base_alpha = albedo.a * albedo_tex.a;

	// ── DAMAGE-MASKE BAUEN (Welt-/Modell-Raum, nicht UV-Raum) ───────────────
	// Sampling im Modell-Raum verhindert UV-Mirroring-Symmetrie. Der Faktor
	// 0.05 skaliert von Modell-Einheiten (oft Meter) auf brauchbare Noise-
	// Frequenzen — größere Werte = feinere Patches.
	vec3 noise_pos = v_model_pos * damage_noise_scale * 0.05;

	// Zwei Schichten: groß-skalierte Schadensregionen + feines Detail
	float n_large = fbm_3d(noise_pos * 0.5);
	float n_small = fbm_3d(noise_pos * 2.0);
	float noise_combined = n_large * 0.7 + n_small * 0.3;

	// Cutoff-Mapping (FIX gegenüber vorheriger Version):
	//   damage_amount = 0.0 → cutoff sehr hoch → smoothstep liefert 0 (keine Schäden)
	//   damage_amount = 1.0 → cutoff niedrig    → smoothstep liefert 1 fast überall
	// noise_combined liegt typisch in [0.2 .. 0.8]. Wir wollen, dass damage_amount
	// linear durch diesen Wertebereich + Edge-Softness wandert.
	//
	// Der vorherige Bug: `mix(1.0 + edge, threshold, dmg)` ließ den Cutoff bei
	// dmg=0.7 unter den noise-Median fallen, was die smoothstep-Maske kippte.
	float low_end  = damage_threshold;                       // bei dmg=1.0 (sehr früh, fast alles)
	float high_end = 1.0 - damage_threshold + damage_edge_softness;  // bei dmg=0.0 (über dem Noise-Maximum)
	float cutoff   = mix(high_end, low_end, damage_amount);

	// Smoothstep: Pixel wird beschädigt, wenn noise > cutoff.
	float damage_mask = smoothstep(cutoff, cutoff + damage_edge_softness, noise_combined);

	// Sicherheit: bei damage_amount ≈ 0 muss die Maske exakt 0 sein
	damage_mask *= step(0.001, damage_amount);

	// Heat-Zonen: wo die Maske am stärksten ist, glüht es noch
	float heat_mask = smoothstep(0.6, 1.0, damage_mask) * damage_amount;

	// ── HEAT-GLOW PULSATION ─────────────────────────────────────────────────
	// TIME ist eine eingebaute Godot-Uniform: Sekunden seit Shader-Start.
	// Wir bauen einen Puls-Faktor zwischen (1.0 - amplitude) und 1.0:
	//   pulse_amplitude = 0   → factor immer 1.0 (statisch)
	//   pulse_amplitude = 1   → factor schwingt 0..1 (komplettes An/Aus)
	//
	// Synchroner Anteil: alle Pixel pulsieren mit derselben Phase
	float t          = TIME * pulse_speed_hz * TAU;  // TAU = 2π, ein voller Zyklus pro Sekunde-Hz
	float pulse_sync = (sin(t) + 1.0) * 0.5;         // [0..1] sinusförmig

	// Asynchroner Anteil: Phase wird durch die Modell-Position verschoben.
	// Damit pulsiert jede Stelle der Hülle leicht anders → wirkt wie viele
	// einzelne Brände statt eines synchronen Atmens.
	float phase_offset = dot(v_model_pos, vec3(0.13, 0.21, 0.17));
	float pulse_async  = (sin(t + phase_offset) + 1.0) * 0.5;

	// Synchron/Asynchron mischen
	float pulse_main = mix(pulse_sync, pulse_async, pulse_async_amount);

	// Sekundär-Flicker: schneller, kleinerer Zufalls-Wackler.
	// Macht aus „atmen" ein „elektrisch zucken" — gut für schwere Schäden.
	float flicker_t  = TIME * pulse_speed_hz * 8.0;  // 8x schneller
	float flicker    = value_noise_3d(v_model_pos * 5.0 + vec3(flicker_t, 0.0, 0.0));
	pulse_main       = mix(pulse_main, pulse_main * flicker, pulse_flicker_amount);

	// Final-Faktor: bei amplitude=0.5 schwingt es zwischen 0.5 und 1.0
	float pulse_factor = 1.0 - pulse_amplitude + pulse_amplitude * pulse_main;

	// Pulse auf die Heat-Maske anwenden — damit pulsieren ALBEDO-Glow und
	// EMISSION-Glow gemeinsam (sonst wirkt es disjoint).
	float heat_mask_pulsed = heat_mask * pulse_factor;

	// ── ALBEDO MODIFIZIEREN ─────────────────────────────────────────────────
	vec3 final_albedo = mix(base_albedo, burn_color_dark, damage_mask);
	final_albedo      = mix(final_albedo, burn_color_glow, heat_mask_pulsed);

	ALBEDO = final_albedo;

	// ── METALLIC (unverändert) ──────────────────────────────────────────────
	METALLIC = base_metallic;
	SPECULAR = specular;

	// ── ROUGHNESS — in Damage-Zonen mattter ─────────────────────────────────
	ROUGHNESS = clamp(base_roughness + damage_mask * damage_roughness_boost, 0.0, 1.0);

	// ── NORMAL — in Damage-Zonen leicht aufgerissen ─────────────────────────
	// Wir entpacken die Normal-Map (von [0..1] zu [-1..1]), addieren Noise-
	// Verzerrung in Damage-Zonen, packen wieder ein.
	// Wichtig: Disturb-Sampling AUCH im Modell-Raum, sonst würde die Verzerrung
	// die Spiegelsymmetrie wieder einführen.
	vec3 unpacked_normal = base_normal_map * 2.0 - 1.0;

	vec3 disturb_pos = v_model_pos * damage_noise_scale * 0.15;
	vec3 disturb_n   = vec3(
		value_noise_3d(disturb_pos) * 2.0 - 1.0,
		value_noise_3d(disturb_pos + vec3(13.7, 7.3, 21.1)) * 2.0 - 1.0,
		1.0
	);
	disturb_n = normalize(disturb_n);

	vec3 final_normal_unpacked = mix(
		unpacked_normal,
		unpacked_normal + disturb_n * damage_normal_disturb,
		damage_mask
	);
	final_normal_unpacked = normalize(final_normal_unpacked);

	NORMAL_MAP = final_normal_unpacked * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = normal_scale;

	// ── EMISSION — Original + additiv Heat-Glow (pulsierend) ───────────────
	// Romulanisches Grün (oder welche Original-Emission auch immer) bleibt
	// erhalten; Heat-Glow kommt ADDITIV dazu — überschreibt nicht.
	// heat_mask_pulsed sorgt dafür dass der Glow zeitlich pulsiert.
	vec3 heat_emission = burn_color_glow * burn_glow_energy * heat_mask_pulsed;
	EMISSION = base_emission + heat_emission;

	// ── ALPHA (unverändert) ─────────────────────────────────────────────────
	ALPHA *= base_alpha;
}
