// res://shaders/cloak.gdshader
//
// Cloak-Shader für alle Schiffe. Wird von CloakComponent dynamisch als
// next_pass ans Ende der Material-Chain gehängt — läuft parallel zum
// damage_shader ohne diesen zu ersetzen.
//
// DESIGN: Kein eigenes Albedo/Textur-Sampling. Dieser Pass arbeitet
// AUSSCHLIESSLICH auf dem bereits gerenderten Fragment (additive Überlagerung).
// Damit ist er Material-agnostisch: egal ob das Basis-Material ein
// StandardMaterial3D, ein ShaderMaterial oder ein damage_shader ist —
// dieser Pass legt sich sauber drüber.
//
// UNIFORMS (werden von CloakComponent.gd per set_shader_parameter gesetzt):
//   cloak_progress  – 0.0 = voll sichtbar (IDLE), 1.0 = voll getarnt (CLOAKED)
//   rim_color       – Fraktionsfarbe des Cloak-Schimmers (aus FactionSystem)
//   displacement_strength – Vertex-Shimmer-Stärke während Transition
//
// ALPHA-LOGIK:
//   Das Fragment wird nicht einfach auf alpha=0 gezogen. Stattdessen:
//   - ALPHA_SCISSOR_THRESHOLD bleibt aus (kein harter Cut).
//   - fragment.ALPHA = (1.0 - cloak_progress) * base_alpha + fresnel_rim
//   Damit: bei cloak_progress=1.0 → ALPHA=0 (unsichtbar), kein Material-Rebuild.
//   Der Sprung-Bug bei Decloak entfällt komplett weil TRANSPARENCY_ALPHA
//   nie mehr am Basis-Material getoggled wird.

shader_type spatial;

// Kein eigenes Culling — der Basis-Pass übernimmt das.
// next_pass braucht BLEND_MIX + depth_draw_never damit er nicht
// mit dem Basis-Pass konkurriert.
render_mode blend_mix, depth_draw_never, cull_back, unshaded;

// ── Haupt-Uniform: Fortschritt der Tarnung ──────────────────────────────────
// 0.0 = Schiff voll sichtbar (dieser Pass tut nichts außer rim bei Transition)
// 1.0 = Schiff voll getarnt  (ALPHA → 0, nur Fresnel-Rim noch sichtbar)
uniform float cloak_progress : hint_range(0.0, 1.0) = 0.0;

// ── Fraktions-Farbgebung ────────────────────────────────────────────────────
// Wird von CloakComponent aus FactionSystem.get_cloak_visuals() geholt.
// Default: icy blue (neutral / unbekannte Fraktion).
uniform vec3 rim_color : source_color = vec3(0.4, 0.75, 1.0);

// ── Vertex Displacement – klassischer Trek-Shimmer ──────────────────────────
// Nur während der Transition aktiv (cloak_progress zwischen 0.05 und 0.95).
// 0.0 = kein Displacement. 0.03–0.05 = subtil (Predator-Stil).
uniform float displacement_strength : hint_range(0.0, 0.2) = 0.04;

// ── Fresnel-Tuning ──────────────────────────────────────────────────────────
// Wie scharf der Rim-Ring ist. 2.0 = weich, 5.0 = scharf.
uniform float fresnel_power : hint_range(1.0, 8.0) = 3.5;
// Maximale Helligkeit des Rim-Glows bei voller Tarnung.
uniform float rim_intensity : hint_range(0.0, 2.0) = 0.8;

// ── Time für animierten Shimmer ─────────────────────────────────────────────
// TIME kommt automatisch von Godot, kein set_shader_parameter nötig.


// ─────────────────────────────────────────────────────────────────────────────
// VERTEX – Displacement während Transition
// ─────────────────────────────────────────────────────────────────────────────

void vertex() {
	// Displacement nur in der Transition-Phase (0.05 – 0.95).
	// Bei voll gecloaket oder voll sichtbar: kein Wobble.
	float in_transition = smoothstep(0.0, 0.15, cloak_progress)
		* (1.0 - smoothstep(0.85, 1.0, cloak_progress));

	if (displacement_strength > 0.001 && in_transition > 0.001) {
		// Animierter Noise über Position + Zeit → jedes Vertex bewegt sich anders.
		// Kein Textur-Sample nötig: sin/cos-Komposition ist billig und sieht gut aus.
		float wave_x = sin(VERTEX.y * 8.0 + TIME * 6.0) * cos(VERTEX.z * 5.0 + TIME * 4.3);
		float wave_y = cos(VERTEX.x * 7.0 + TIME * 5.5) * sin(VERTEX.z * 6.0 + TIME * 3.7);
		float wave_z = sin(VERTEX.x * 6.0 + TIME * 4.8) * cos(VERTEX.y * 9.0 + TIME * 5.1);

		// Normal-Richtung verstärkt den Effekt (Oberfläche "atmet" nach außen).
		vec3 displacement = NORMAL * (wave_x * 0.5 + wave_y * 0.3 + wave_z * 0.2)
			* displacement_strength * in_transition;

		VERTEX += displacement;
	}
}


// ─────────────────────────────────────────────────────────────────────────────
// FRAGMENT – Alpha + Rim-Glow
// ─────────────────────────────────────────────────────────────────────────────

void fragment() {
	// ── Fresnel-Term ──────────────────────────────────────────────────────────
	// VIEW in Godot 4 Forward+ ist der normalisierte Vektor vom Fragment zur Kamera.
	// dot(NORMAL, VIEW) → 1.0 = Fläche zeigt direkt zur Kamera (Mitte des Schiffs)
	//                   → 0.0 = Silhouetten-Kante
	// Fresnel-Rim leuchtet an den Kanten, nicht in der Mitte → 1 - dot(...)
	float ndotv   = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = pow(1.0 - ndotv, fresnel_power);

	// ── Rim-Helligkeit ────────────────────────────────────────────────────────
	// Bei cloak_progress=0 (sichtbar): kein Rim.
	// Bei cloak_progress=1 (getarnt): maximaler Rim (damit man Verbündete noch sieht).
	// Während der Transition: Rim fährt hoch und bleibt am Ende.
	// Kleiner Pulse-Effekt im CLOAKED-Zustand (subtiles Atmen).
	float pulse = 1.0 + 0.08 * sin(TIME * 2.1);   // ±8% Helligkeit, ~2 Hz
	float rim_alpha = fresnel * cloak_progress * rim_intensity * pulse;

	// ── Schiff-Alpha (Basis-Sichtbarkeit) ────────────────────────────────────
	// cloak_progress=0 → ship_alpha=1 (voll sichtbar)
	// cloak_progress=1 → ship_alpha=0 (unsichtbar) — nur Rim bleibt
	float ship_alpha = 1.0 - cloak_progress;

	// ── Finales Fragment ──────────────────────────────────────────────────────
	// ALBEDO bleibt transparent (kein eigenes Textur-Sampling).
	// Der Basis-Pass hat bereits Textur+Farbe gerendert — wir modulieren nur.
	// Rim-Farbe wird additiv eingemischt.
	ALBEDO = rim_color * rim_alpha;

	// ALPHA kombiniert: Schiff-Transparenz ODER Rim-Sichtbarkeit.
	// max() stellt sicher: selbst bei cloak_progress=1 leuchtet der Rim.
	ALPHA = max(ship_alpha, rim_alpha);

	// Emission für den Rim-Glow (damit er auch bei Low-Light sichtbar ist).
	EMISSION = rim_color * rim_alpha * 1.5;
}
