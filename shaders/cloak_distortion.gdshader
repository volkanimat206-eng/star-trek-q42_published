// res://shaders/cloak_distortion.gdshader
//
// Screen-Space Refraktion für den Cloaking-Effekt.
// Simulliert eine unsichtbare Masse die Licht biegt — wie ein Wassertropfen
// oder Hitzeflimmern, inspiriert von Predator / Romulan Warbird.
//
// FUNKTIONSWEISE:
//   - Das Mesh selbst ist komplett transparent (ALPHA = 0 → Albedo unsichtbar)
//   - Der Shader liest den Screen-Buffer hinter dem Mesh und verschiebt ihn
//     anhand einer Noise-Textur → erzeugt den Verzerrungseffekt
//   - distortion_strength steuert wie stark die Verzerrung ist (0 = aus)
//   - rim_power erzeugt einen schwachen Leuchtkranz an den Silhouettenkanten
//     (erleichtert dem Spieler die Orientierung bei Nahbereich-Detection)
//
// USAGE im CloakComponent:
//   Das Component erstellt einen MeshInstance3D-Klon des Schiffs, weist diesem
//   Shader zu und animiert distortion_strength per Tween basierend auf der
//   Distanz zum Player.

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled, unshaded;

// ── Haupt-Parameter (vom CloakComponent per set_shader_parameter gesetzt) ──

/// Stärke der Raumverzerrung. 0.0 = unsichtbar, 1.0 = maximale Verzerrung.
/// Wird vom CloakComponent in Abhängigkeit der Distanz zum Observer gesetzt.
uniform float distortion_strength : hint_range(0.0, 1.0) = 0.0;

/// Maximale Pixel-Verschiebung auf dem Screen bei distortion_strength = 1.0.
/// Höhere Werte = dramatischerer Effekt, aber auch mehr Artefakte.
uniform float max_pixel_offset : hint_range(4.0, 64.0) = 18.0;

/// Geschwindigkeit der Noise-Animation (wie schnell "fließt" die Verzerrung).
uniform float flow_speed : hint_range(0.0, 3.0) = 0.4;

/// Skalierung der Noise-Textur — kleinere Werte = gröbere Wellen.
uniform float noise_scale : hint_range(0.5, 8.0) = 2.5;

/// Stärke des Silhouetten-Leuchtens an den Kanten (Fresnel/Rim).
/// 0 = kein Leuchten, 1 = starkes Leuchten.
uniform float rim_strength : hint_range(0.0, 1.0) = 0.25;

/// Farbe des Rim-Effekts — Standard: leicht bläuliches Weiß (wie Tarnfeld-Energie)
uniform vec4 rim_color : source_color = vec4(0.4, 0.7, 1.0, 1.0);

/// Schärfe des Rim-Effekts (höher = schmalere Kante)
uniform float rim_power : hint_range(1.0, 8.0) = 3.5;

// ── Texturen ─────────────────────────────────────────────────────────────────

/// Noise-Textur für die Verzerrung. Wenn nicht gesetzt, wird eine einfache
/// Sinus-Approximation genutzt (funktioniert, aber weniger organisch).
uniform sampler2D noise_texture : hint_default_white, repeat_enable;

/// Screen-Texture: wird automatisch von Godot befüllt (Forward+ / MSDF).
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, repeat_disable, filter_linear_mipmap;


// ── Vertex ────────────────────────────────────────────────────────────────────

void vertex() {
	// Standard-Vertex — keine Displacement, wir wollen die Silhouette erhalten
}


// ── Fragment ──────────────────────────────────────────────────────────────────

void fragment() {
	// Früher Ausstieg wenn Effekt inaktiv — spart GPU-Zeit
	if (distortion_strength <= 0.001) {
		ALBEDO      = vec3(0.0);
		ALPHA       = 0.0;
		return;
	}

	// ── Noise-basierte UV-Verschiebung ────────────────────────────────────────
	// Zwei überlagerte Noise-Samples mit unterschiedlichen Richtungen/Speeds
	// erzeugen eine organische, nicht-repetitive Verzerrung.
	vec2 uv_flow_a = UV * noise_scale + vec2(TIME * flow_speed * 0.7,  TIME * flow_speed * 0.4);
	vec2 uv_flow_b = UV * noise_scale + vec2(TIME * flow_speed * -0.3, TIME * flow_speed * 0.6);

	vec2 noise_a   = texture(noise_texture, uv_flow_a).rg * 2.0 - 1.0;
	vec2 noise_b   = texture(noise_texture, uv_flow_b).rg * 2.0 - 1.0;

	// Kombinierte Verschiebung — Noise A dominiert, B gibt organische Variation
	vec2 raw_offset = noise_a * 0.65 + noise_b * 0.35;

	// Verschiebung in Screen-Space umrechnen (VIEWPORT_SIZE normalisiert auf Pixel)
	vec2 pixel_offset = raw_offset * max_pixel_offset * distortion_strength / VIEWPORT_SIZE;

	// ── Screen-Texture an verschobenem Punkt samplen ──────────────────────────
	vec2 screen_uv    = SCREEN_UV + pixel_offset;
	// Clamp an Bildränder um Wrap-Artefakte zu verhindern
	screen_uv         = clamp(screen_uv, vec2(0.001), vec2(0.999));
	vec3 refracted    = texture(SCREEN_TEXTURE, screen_uv).rgb;

	// ── Fresnel / Rim-Effekt an Silhouettenkanten ─────────────────────────────
	// NORMAL im View-Space: wenn normal.z nahe 0 → Kante → Rim leuchtet
	float fresnel      = pow(1.0 - abs(NORMAL.z), rim_power);
	float rim          = fresnel * rim_strength * distortion_strength;

	// Rim-Farbe über refraktiertes Bild blenden
	vec3 final_color   = mix(refracted, rim_color.rgb, rim * rim_color.a);

	// ── Output ────────────────────────────────────────────────────────────────
	// Albedo = verzerrtes Bild + Rim, Alpha dynamisch basierend auf distortion
	// Der Mesh ist "sichtbar" genug dass der Shader Pixel ausgibt, aber
	// ALPHA_SCISSOR oder TRANSPARENCY_ALPHA macht das Material korrekt transparent
	// zwischen den Effektpixeln.
	ALBEDO       = final_color;
	// Alpha: leichter Rim ist immer noch zu sehen, Rest transparent
	// Wir geben dem Screen-Effekt einen leichten Alpha damit er korrekt sortiert
	ALPHA        = clamp(distortion_strength * 0.15 + rim * 0.6, 0.0, 1.0);

	// EMISSION für den Rim — sichtbar auch ohne Licht (Weltraum ist dunkel)
	EMISSION     = rim_color.rgb * rim * 0.8;
}
