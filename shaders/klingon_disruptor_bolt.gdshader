shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;

uniform vec4 core_color : source_color = vec4(0.1, 1.0, 0.2, 1.0);
uniform vec4 glow_color : source_color = vec4(0.0, 1.0, 0.3, 1.0);

uniform float pulse_speed : hint_range(0.0, 20.0) = 6.0;
uniform float pulse_strength : hint_range(0.0, 5.0) = 1.5;

uniform float edge_softness : hint_range(0.1, 5.0) = 1.5;
uniform float intensity : hint_range(0.0, 10.0) = 3.0;

uniform float uv_scale : hint_range(0.1, 10.0) = 1.0;
uniform float scroll_speed : hint_range(0.0, 10.0) = 2.0;

void fragment()
{
    vec2 uv = UV * uv_scale;

    float center_dist = abs(uv.x - 0.5) * 2.0;
    float radial = pow(1.0 - center_dist, edge_softness);

    float pulse = sin(TIME * pulse_speed + uv.y * 10.0);
    pulse = (pulse * 0.5 + 0.5) * pulse_strength;

    float scroll = fract(uv.y + TIME * scroll_speed);

    float beam_shape = radial * smoothstep(0.0, 0.2, scroll) * smoothstep(1.0, 0.8, scroll);

    vec3 col = mix(core_color.rgb, glow_color.rgb, 1.0 - radial);

    float final_intensity = (beam_shape + pulse) * intensity;

    ALBEDO = col;
    EMISSION = col * final_intensity;
    ALPHA = clamp(final_intensity, 0.0, 1.0);
}