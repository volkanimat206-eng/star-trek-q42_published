shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform sampler2D stern_textur : source_color, filter_linear_mipmap, repeat_disable;

uniform vec4 stern_farbe : source_color = vec4(1.0);
uniform float emissions_staerke : hint_range(0.0, 100.0, 0.1) = 35.0;
uniform float base_brightness : hint_range(0.0, 2.0) = 0.3;

uniform float twinkle_speed : hint_range(0.0, 15.0) = 4.0;
uniform float twinkle_amount : hint_range(0.0, 1.0) = 0.8;

varying float twinkle_phase;

void vertex() {
    vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    twinkle_phase = dot(world_pos, vec3(12.9898, 78.233, 37.719)) * 5.0;
}

void fragment() {
    vec4 tex = texture(stern_textur, UV);
    
    ALBEDO = tex.rgb * stern_farbe.rgb * base_brightness;
    ALPHA = tex.a;
    
    float twinkle = sin(TIME * twinkle_speed + twinkle_phase) * 0.5 + 0.5;
    twinkle = mix(1.0, twinkle, twinkle_amount);
    
    EMISSION = tex.rgb * stern_farbe.rgb * emissions_staerke * twinkle;
}