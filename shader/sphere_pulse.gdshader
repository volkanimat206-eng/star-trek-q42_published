shader_type spatial;

render_mode unshaded, cull_back;

// =====================
// 🎨 FARBEN
// =====================
uniform vec4 base_color : source_color = vec4(0.1, 0.4, 1.0, 1.0);
uniform vec4 pulse_color : source_color = vec4(1.0, 0.2, 0.6, 1.0);
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// =====================
// ⚙️ PULS
// =====================
uniform float pulse_speed : hint_range(0.1, 10.0) = 3.0;
uniform float pulse_strength : hint_range(0.0, 1.0) = 0.8;

// =====================
// 🌊 NOISE (organisch)
// =====================
uniform float noise_scale : hint_range(0.1, 10.0) = 3.0;
uniform float noise_strength : hint_range(0.0, 1.0) = 0.3;

// =====================
// 🔵 SKALIERUNG
// =====================
uniform float scale_amplitude : hint_range(0.0, 1.0) = 0.15;

// =====================
// ✨ EMISSION
// =====================
uniform float emission_strength : hint_range(0.0, 20.0) = 6.0;

// =====================
// 🌈 RIM GLOW
// =====================
uniform float rim_power : hint_range(0.5, 8.0) = 3.0;
uniform float rim_strength : hint_range(0.0, 5.0) = 2.0;

// =====================
// 💥 SHOCKWAVE
// =====================
uniform float shockwave_width : hint_range(0.01, 0.5) = 0.15;
uniform float shockwave_strength : hint_range(0.0, 3.0) = 1.5;

// =====================
// 🎛️ TOGGLES
// =====================
uniform bool use_scaling = true;
uniform bool use_noise = true;
uniform bool use_rim = true;
uniform bool use_shockwave = true;


// =====================
// 🔧 SIMPLE NOISE FUNC
// =====================
float hash(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float noise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);

    float n = mix(
        mix(mix(hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
            mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
        mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
            mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y),
        f.z
    );

    return n;
}


// =====================
// 🧩 VERTEX
// =====================
void vertex() {
    float pulse = sin(TIME * pulse_speed) * 0.5 + 0.5;

    if (use_noise) {
        float n = noise(VERTEX * noise_scale + TIME);
        pulse += (n - 0.5) * noise_strength;
    }

    if (use_scaling) {
        float scale = 1.0 + pulse * scale_amplitude;
        VERTEX *= scale;
    }
}


// =====================
// 🎨 FRAGMENT
// =====================
void fragment() {
    float pulse = sin(TIME * pulse_speed) * 0.5 + 0.5;

    // Noise Einfluss
    if (use_noise) {
        float n = noise(NORMAL * noise_scale + TIME);
        pulse += (n - 0.5) * noise_strength;
    }

    pulse = clamp(pulse, 0.0, 1.0);

    // =====================
    // 🎨 BASISFARBE
    // =====================
    vec3 color = mix(base_color.rgb, pulse_color.rgb, pulse * pulse_strength);

    // =====================
    // 🌈 RIM LIGHT
    // =====================
    if (use_rim) {
        float rim = pow(1.0 - dot(NORMAL, VIEW), rim_power);
        color += rim * rim_color.rgb * rim_strength;
    }

    // =====================
    // 💥 SHOCKWAVE RING
    // =====================
    if (use_shockwave) {
        float wave = abs(pulse - 0.9); // Peak bei ~0.9
        float ring = smoothstep(shockwave_width, 0.0, wave);
        color += ring * shockwave_strength;
    }

    ALBEDO = color;

    // =====================
    // ✨ EMISSION
    // =====================
    EMISSION = color * emission_strength * pulse;
}