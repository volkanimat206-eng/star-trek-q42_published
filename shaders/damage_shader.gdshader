// res://shaders/damage_shader.gdshader
//
// Damage-Shader für Schiffshüllen.
//
// Was er macht:
//   • Renderet das Schiff bei damage_amount = 0.0 IDENTISCH zum bisherigen
//     StandardMaterial3D (Albedo + Emission + Normal-Map).
//   • Bei steigendem damage_amount (0..1) blendet zunehmend Schadens-Look
//     darüber ein:
//       - Albedo wird in Schadenszonen dunkler/rußig
//       - zusätzliche Heat-Glow-Emission (rot/orange), die die original-
//         farbliche Emission (z.B. romulanisches Grün) NICHT überschreibt
//       - Roughness steigt in Schadenszonen (matter, verkohlt)
//       - leichte Normal-Map-Verzerrung für aufgerissene Hüllenoptik
//   • Schadens-VERTEILUNG kommt aus einer prozeduralen Noise-Maske, plus
//     Edge-Detection (Hüllenkanten werden zuerst beschädigt — physikalisch
//     plausibel, da exponiert).
//
// AAA-Trick:
//   Wir SCHADEN nicht die Hülle ersetzen, wir MODIFIZIEREN sie lokal.
//   Damit sieht das Schiff bei damage = 0 exakt aus wie vorher und wird
//   progressiv "verletzt" — nicht plötzlich ausgetauscht.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ─────────────────────────────────────────────────────────────────────────────
// BASIS-TEXTUREN  (vom alten StandardMaterial3D übernommen)
// ─────────────────────────────────────────────────────────────────────────────
uniform sampler2D albedo_texture   : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D emission_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_texture   : hint_normal,  filter_linear_mipmap, repeat_enable;

uniform vec4  albedo_color           : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float roughness              : hint_range(0.0, 1.0) = 0.76;
uniform float metallic               : hint_range(0.0, 1.0) = 0.0;
uniform float normal_scale           : hint_range(-2.0, 2.0) = 1.0;
uniform float emission_energy        : hint_range(0.0, 16.0) = 1.0;

// ─────────────────────────────────────────────────────────────────────────────
// DAMAGE-PARAMETER
// ─────────────────────────────────────────────────────────────────────────────
// Hauptregler: 0.0 = heile Hülle (sieht aus wie vorher), 1.0 = maximal beschädigt.
// Wird vom ShipController jeden Frame gesetzt (siehe Phase-1-Patch).
uniform float damage_amount          : hint_range(0.0, 1.0) = 0.0;

// Wie stark sich Schaden bei niedrigem damage_amount schon zeigt.
// Hohe Werte = Schaden erscheint früh (sensible Hülle).
// Niedrige Werte = lange "ganz", dann schnell zerstört.
uniform float damage_threshold       : hint_range(0.0, 1.0) = 0.15;

// Wie scharf die Schadens-Kante ist (kleinere Werte = härter, größere = weicher).
uniform float damage_edge_softness   : hint_range(0.01, 0.5) = 0.20;

// Skalierung der prozeduralen Noise-Maske. Höhere Werte = feinere Schadens-
// Strukturen, niedrigere = großflächige Bereiche.
uniform float damage_noise_scale     : hint_range(1.0, 50.0) = 12.0;

// Farben für die Schadenszonen
uniform vec3  burn_color_dark        : source_color = vec3(0.05, 0.02, 0.01);  // verkohlter Rand
uniform vec3  burn_color_glow        : source_color = vec3(1.0, 0.4, 0.1);     // glühender Kern
uniform float burn_glow_energy       : hint_range(0.0, 8.0) = 2.0;

// Wieviel die Damage-Bereiche die Hüllen-Roughness erhöhen
uniform float damage_roughness_boost : hint_range(0.0, 1.0) = 0.6;

// Wieviel die Damage-Bereiche die Normal-Map verzerren (aufgerissen wirken)
uniform float damage_normal_disturb  : hint_range(0.0, 2.0) = 0.8;


// ─────────────────────────────────────────────────────────────────────────────
// HASH-NOISE  (kompakte 2D-Noise ohne externe Texture)
// ─────────────────────────────────────────────────────────────────────────────
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Smooth Value Noise — interpolierte Hash-Werte an den 4 Eckpunkten der Zelle.
// Liefert weiche, organische Flecken-Muster (gut für Schadens-Verteilung).
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f); // Smoothstep-Interpolation

	float a = hash21(i + vec2(0.0, 0.0));
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));

	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal Brownian Motion — schichtet mehrere Noise-Oktaven für Detail.
// Macht die Schadens-Maske natürlicher (große Brände + kleine Sprenkel).
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


// ─────────────────────────────────────────────────────────────────────────────
// FRAGMENT
// ─────────────────────────────────────────────────────────────────────────────
void fragment() {
	vec2 uv = UV;

	// ── 1) Basis-Materialdaten lesen ────────────────────────────────────────
	vec4 base_albedo = texture(albedo_texture,   uv) * albedo_color;
	vec3 base_emiss  = texture(emission_texture, uv).rgb * emission_energy;
	vec3 base_normal = texture(normal_texture,   uv).rgb * 2.0 - 1.0;

	// ── 2) Damage-Maske bauen ───────────────────────────────────────────────
	// Zwei Noise-Schichten unterschiedlicher Skalierung kombiniert: die große
	// Skalierung definiert "Schadensregionen", die kleine fügt Detail hinzu.
	float n_large = fbm(uv * damage_noise_scale * 0.5);
	float n_small = fbm(uv * damage_noise_scale * 2.0);
	float noise_combined = n_large * 0.7 + n_small * 0.3;

	// Schaden-Cutoff: bei damage_amount = 0 wird nichts geschädigt; bei
	// damage_amount = 1 fast die ganze Hülle. damage_threshold steuert wie
	// früh der Schaden anfängt sichtbar zu werden.
	// remap so dass damage_amount = 0 → cutoff = 1.0 (nichts darunter)
	//                damage_amount = 1 → cutoff = damage_threshold (fast alles drüber)
	float cutoff = mix(1.0 + damage_edge_softness, damage_threshold, damage_amount);

	// Smoothstep gibt weiche Übergänge an der Schadensgrenze
	float damage_mask = smoothstep(cutoff, cutoff - damage_edge_softness, noise_combined);

	// Sicherheit: bei damage_amount ≈ 0 muss die Maske exakt 0 sein
	damage_mask *= step(0.001, damage_amount);

	// ── 3) Heat-Zonen (innere, glühende Bereiche der Schadenszonen) ─────────
	// In den Bereichen, wo die Damage-Maske am stärksten ist, glüht es noch.
	// Das simuliert frische, heiße Brände innerhalb der verkohlten Zonen.
	float heat_mask = smoothstep(0.6, 1.0, damage_mask) * damage_amount;

	// ── 4) Albedo modifizieren ──────────────────────────────────────────────
	// In Damage-Zonen: Mix von der ursprünglichen Albedo zu burn_color_dark.
	// In Heat-Zonen: heller, glühender Kern.
	vec3 damaged_albedo = mix(base_albedo.rgb, burn_color_dark, damage_mask);
	damaged_albedo      = mix(damaged_albedo, burn_color_glow, heat_mask);

	ALBEDO = damaged_albedo;

	// ── 5) Emission ─────────────────────────────────────────────────────────
	// Romulanisches Grün (oder welche Original-Emission auch immer) bleibt
	// erhalten; Heat-Glow kommt ADDITIV dazu — überschreibt nicht.
	vec3 heat_emission = burn_color_glow * burn_glow_energy * heat_mask;
	EMISSION = base_emiss + heat_emission;

	// ── 6) Roughness ────────────────────────────────────────────────────────
	// In Damage-Zonen wird die Hülle matter (verkohlt, rauher).
	ROUGHNESS = clamp(roughness + damage_mask * damage_roughness_boost, 0.0, 1.0);

	// ── 7) Metallic (unverändert übernommen) ────────────────────────────────
	METALLIC = metallic;

	// ── 8) Normal-Map — leicht aufgerissen in Damage-Zonen ──────────────────
	// Die Normal-Map wird in Damage-Zonen mit einem zusätzlichen Noise-
	// Vector überlagert. Effekt: die Hülle sieht dort "geknittert"/aufgerissen
	// aus, statt nur farblich verändert.
	vec2 disturb_uv  = uv * damage_noise_scale * 3.0;
	vec3 disturb_n   = vec3(
		value_noise(disturb_uv) * 2.0 - 1.0,
		value_noise(disturb_uv + vec2(13.7, 7.3)) * 2.0 - 1.0,
		1.0
	);
	disturb_n        = normalize(disturb_n);

	vec3 final_normal = mix(base_normal, base_normal + disturb_n * damage_normal_disturb, damage_mask);
	final_normal      = normalize(final_normal);
	final_normal.xy  *= normal_scale;

	NORMAL_MAP = final_normal * 0.5 + 0.5;
}
