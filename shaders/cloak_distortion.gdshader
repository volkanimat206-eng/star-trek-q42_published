// res://shaders/cloak_distortion.gdshader
//
// Screen-Space Refraktion für Cloaking.
// Nutzt Godot's eingebauten refraction-Mechanismus.
//
// FUNKTIONSWEISE:
//   - Das Mesh ist komplett transparent (ALPHA ~ 0)
//   - REFRACTION verschiebt die Pixel hinter dem Mesh via Godot's internen
//     Screen-Buffer — kein manuelles SCREEN_TEXTURE-Sampling nötig
//   - distortion_strength: 0.0 = kein Effekt, 1.0 = maximale Verzerrung
//   - Rim-Effekt zeichnet einen schwachen Leuchtkranz an Silhouettenkanten

shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

uniform float distortion_strength : hint_range(0.0, 1.0) = 0.0;
uniform float refraction_scale    : hint_range(0.001, 0.2) = 0.05;
uniform sampler2D noise_texture   : hint_default_white, repeat_enable;
uniform float flow_speed          : hint_range(0.0, 3.0) = 0.4;
uniform float noise_scale         : hint_range(0.5, 8.0) = 2.5;
uniform float rim_strength        : hint_range(0.0, 1.0) = 0.3;
uniform vec4  rim_color           : source_color = vec4(0.4, 0.75, 1.0, 1.0);
uniform float rim_power           : hint_range(1.0, 8.0) = 4.0;

void fragment() {
	if (distortion_strength <= 0.001) {
		ALPHA = 0.0;
		return;
	}

	// Zwei überlagerte Noise-Samples = organische, nicht-repetitive Verzerrung
	vec2 uv_a   = UV * noise_scale + vec2(TIME * flow_speed * 0.6,  TIME * flow_speed * 0.3);
	vec2 uv_b   = UV * noise_scale + vec2(-TIME * flow_speed * 0.2, TIME * flow_speed * 0.5);
	vec2 noise_a = texture(noise_texture, uv_a).rg * 2.0 - 1.0;
	vec2 noise_b = texture(noise_texture, uv_b).rg * 2.0 - 1.0;
	vec2 distortion_vec = (noise_a * 0.65 + noise_b * 0.35) * distortion_strength;

	// Godot's eingebaute REFRACTION — verschiebt Screen-Buffer hinter dem Mesh
	REFRACTION = distortion_vec * refraction_scale;

	// Fresnel / Rim an Silhouettenkanten
	float fresnel = pow(1.0 - abs(dot(NORMAL, VIEW)), rim_power);
	float rim     = fresnel * rim_strength * distortion_strength;

	ALBEDO   = rim_color.rgb;
	EMISSION = rim_color.rgb * rim * 0.9;
	ALPHA    = rim * 0.7;
}
