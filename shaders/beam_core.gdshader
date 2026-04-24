shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

uniform vec4  beam_color  : source_color = vec4(1.0, 0.3, 0.0, 1.0);
uniform float intensity   : hint_range(0.0, 10.0) = 3.0;
uniform float pulse_speed : hint_range(0.0, 10.0) = 5.0;
uniform float noise_scale : hint_range(0.0,  5.0) = 2.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
    vec2 uv = UV;

    // Zentraler Gradient
    float edge = 1.0 - abs(uv.x - 0.5) * 2.0;
    edge = pow(edge, 2.0);

    // Pulsation
    float pulse = sin(uv.y * 3.0 - TIME * pulse_speed) * 0.3 + 0.7;

    // Noise
    float n = noise(uv * noise_scale + vec2(TIME * 0.5, 0.0));

    float alpha = edge * pulse * (0.7 + n * 0.3);

    ALBEDO   = beam_color.rgb * intensity;
    ALPHA    = alpha;
    EMISSION = beam_color.rgb * intensity;
}
