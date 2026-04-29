// res://shaders/cloak_distortion.gdshader

shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;


// ── Screen Texture (FIX für Godot 4) ──────────────────────────────────────────
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;


// ── Bestehende Uniforms ───────────────────────────────────────────────────────
uniform float distortion_strength : hint_range(0.0, 1.0) = 0.0;
uniform float refraction_scale    : hint_range(0.001, 0.2) = 0.05;
uniform sampler2D noise_texture   : hint_default_white, repeat_enable;
uniform float flow_speed          : hint_range(0.0, 3.0) = 0.4;
uniform float noise_scale         : hint_range(0.5, 8.0) = 2.5;

uniform float rim_strength        : hint_range(0.0, 1.0) = 0.3;
uniform vec4  rim_color           : source_color = vec4(0.4, 0.75, 1.0, 1.0);
uniform float rim_power           : hint_range(1.0, 8.0) = 4.0;


// ── Predator Transition ───────────────────────────────────────────────────────
uniform float transition_amount     : hint_range(0.0, 1.0) = 0.0;
uniform float displacement_strength : hint_range(0.0, 0.2) = 0.04;


// ── Buildup Wave ──────────────────────────────────────────────────────────────
uniform float buildup_amount : hint_range(0.0, 1.0) = 0.0;
uniform float buildup_radius : hint_range(0.0, 10.0) = 2.0;
uniform float buildup_width  : hint_range(0.01, 2.0) = 0.3;

uniform float buildup_emission_strength : hint_range(0.0, 5.0) = 2.0;
uniform float buildup_displacement      : hint_range(0.0, 0.2) = 0.06;

uniform vec3 buildup_origin = vec3(0.0, 0.0, 0.0);


// ─────────────────────────────────────────────────────────────────────────────
// VERTEX
// ─────────────────────────────────────────────────────────────────────────────
void vertex() {

	// Predator
	if (transition_amount > 0.001) {
		vec2 noise_uv = VERTEX.xz * 0.3
			+ vec2(TIME * flow_speed * 0.25, TIME * flow_speed * 0.15);

		float n = texture(noise_texture, noise_uv).r * 2.0 - 1.0;
		VERTEX += NORMAL * n * displacement_strength * transition_amount;
	}

	// Buildup
	if (buildup_amount > 0.001) {

		float dist = distance(VERTEX, buildup_origin);
		float wave_front = (1.0 - buildup_amount) * buildup_radius;

		float wave =
			smoothstep(wave_front - buildup_width, wave_front, dist)
		  - smoothstep(wave_front, wave_front + buildup_width, dist);

		vec3 dir = normalize(VERTEX - buildup_origin);
		VERTEX += dir * wave * buildup_displacement;
	}
}


// ─────────────────────────────────────────────────────────────────────────────
// FRAGMENT
// ─────────────────────────────────────────────────────────────────────────────
void fragment() {

	float effective_strength = max(distortion_strength, transition_amount * 0.7);

	if (effective_strength <= 0.001 && buildup_amount <= 0.001) {
		ALPHA = 0.0;
	} else {

		// Noise
		vec2 uv_a = UV * noise_scale
			+ vec2(TIME * flow_speed * 0.6, TIME * flow_speed * 0.3);

		vec2 uv_b = UV * noise_scale
			+ vec2(-TIME * flow_speed * 0.2, TIME * flow_speed * 0.5);

		vec2 noise_a = texture(noise_texture, uv_a).rg * 2.0 - 1.0;
		vec2 noise_b = texture(noise_texture, uv_b).rg * 2.0 - 1.0;

		vec2 distortion_vec =
			(noise_a * 0.65 + noise_b * 0.35) * effective_strength;

		// ── Screen Refraction (Godot 4 korrekt) ──
		vec2 screen_uv = SCREEN_UV + distortion_vec * refraction_scale;
		vec3 refracted = texture(SCREEN_TEXTURE, screen_uv).rgb;


		// Rim
		float fresnel = pow(1.0 - abs(dot(NORMAL, VIEW)), rim_power);
		float rim = fresnel * rim_strength * effective_strength;


		// Buildup Wave
		float buildup_wave = 0.0;

		if (buildup_amount > 0.001) {
			float dist = length(VERTEX - buildup_origin);
			float wave_front = (1.0 - buildup_amount) * buildup_radius;

			buildup_wave =
				smoothstep(wave_front - buildup_width, wave_front, dist)
			  - smoothstep(wave_front, wave_front + buildup_width, dist);

			float mask = smoothstep(0.3, 0.0, transition_amount);
			buildup_wave *= mask;
		}


		// Lighting
		rim += buildup_wave * 1.2;

		vec3 emission = rim_color.rgb * rim * 0.9;
		emission += rim_color.rgb * buildup_wave * buildup_emission_strength;


		// Output
		ALBEDO   = refracted;
		EMISSION = emission;
		ALPHA    = max(rim * 0.7, buildup_wave);
	}
}