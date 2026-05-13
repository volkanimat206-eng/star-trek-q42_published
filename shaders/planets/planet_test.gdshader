shader_type spatial;
render_mode blend_mix, depth_draw_opaque;

// Farben
uniform vec4 atmosphere_color : source_color = vec4(0.3, 0.6, 1.0, 1.0);
uniform vec4 cloud_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// Texturen
uniform sampler2D cloud_noise_tex : source_color, repeat_enable;
uniform sampler2D distortion_noise_tex : repeat_enable;

// Steuerungsparameter
uniform bool show_clouds = true;
uniform float cloud_density : hint_range(0.0, 1.0) = 0.5;

// NEU: Rotations-Parameter
uniform float rotation_speed : hint_range(-2.0, 2.0) = -0.1; // Negativ für Gegendrehung

// Verformung
uniform float distortion_strength : hint_range(0.0, 0.2) = 0.05;
uniform float distortion_speed : hint_range(0.0, 0.5) = 0.1;

// Corona / Glow
uniform float corona_intensity : hint_range(0.0, 5.0) = 2.0;
uniform float corona_width : hint_range(0.1, 10.0) = 4.0;

// Hilfsfunktion zur Rotation der UVs
vec2 rotate_uv(vec2 uv, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    // UVs zum Zentrum verschieben (0.5, 0.5)
    uv -= 0.5;
    // Rotationsmatrix anwenden
    vec2 rotated = vec2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);
    // Zurückschieben
    return rotated + 0.5;
}

void fragment() {
	// 1. Fresnel für die Corona
	float fresnel = pow(1.0 - dot(NORMAL, VIEW), corona_width);
	vec3 final_color = atmosphere_color.rgb;
	float alpha_base = fresnel * atmosphere_color.a;

	float current_cloud_alpha = 0.0;

	if (show_clouds) {
		// --- ROTATION ANWENDEN ---
		float angle = TIME * rotation_speed;
		vec2 base_rotated_uv = rotate_uv(UV, angle);
		
		// UV-Verzerrung für die innere Bewegung (ebenfalls rotiert)
		vec2 dist_uv = base_rotated_uv + vec2(TIME * distortion_speed * 0.5, TIME * distortion_speed);
		vec2 distortion = texture(distortion_noise_tex, dist_uv).rg * 2.0 - 1.0;
		
		// Die Wolken nutzen die rotierte und verzerrte UV
		vec2 final_cloud_uv = base_rotated_uv + distortion * distortion_strength;
		
		float cloud_mask = texture(cloud_noise_tex, final_cloud_uv).r;
		cloud_mask = smoothstep(1.0 - cloud_density, 1.1 - cloud_density, cloud_mask);
		
		if (cloud_mask > 0.0) {
			final_color = mix(final_color, cloud_color.rgb, cloud_mask);
			current_cloud_alpha = cloud_mask * cloud_color.a;
		}
	}

	ALBEDO = final_color;
	ALPHA = clamp(alpha_base + current_cloud_alpha, 0.0, 1.0);
	EMISSION = atmosphere_color.rgb * fresnel * corona_intensity;
}