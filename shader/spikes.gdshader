shader_type spatial;

render_mode unshaded, cull_disabled, blend_add;


// =====================
// 🎨 FARBEN
// =====================
uniform vec4 spike_color_1 : source_color = vec4(1.0, 0.4, 0.2, 1.0);
uniform vec4 spike_color_2 : source_color = vec4(1.0, 0.8, 0.3, 1.0);
uniform vec4 spike_color_3 : source_color = vec4(1.0, 0.2, 0.1, 1.0);


// =====================
// 🔄 ROTATION
// =====================
uniform float rotation_speed_1 = 4.0;
uniform float rotation_speed_2 = 2.5;
uniform float rotation_speed_3 = 1.5;

uniform bool clockwise_1 = true;
uniform bool clockwise_2 = false;
uniform bool clockwise_3 = true;


// =====================
// 🔺 COUNT
// =====================
uniform int spike_count_1 = 8;
uniform int spike_count_2 = 6;
uniform int spike_count_3 = 4;


// =====================
// 📏 BREITE (START = innen, END = außen)
// =====================
uniform float spike_width_start_1 = 0.05;
uniform float spike_width_end_1   = 0.25;
uniform float spike_width_start_2 = 0.08;
uniform float spike_width_end_2   = 0.35;
uniform float spike_width_start_3 = 0.10;
uniform float spike_width_end_3   = 0.45;

// Nichtlineare Form (1.0 = linear, >1.0 = außen dicker, <1.0 = innen dicker)
uniform float width_exponent_1 = 1.0;
uniform float width_exponent_2 = 1.0;
uniform float width_exponent_3 = 1.0;


// =====================
// 📐 LÄNGE (unabhängig von Breite)
// =====================
uniform float spike_length_min_1 = 0.6;
uniform float spike_length_max_1 = 1.4;

uniform float spike_length_min_2 = 0.4;
uniform float spike_length_max_2 = 1.0;

uniform float spike_length_min_3 = 0.3;
uniform float spike_length_max_3 = 0.8;

uniform float length_variation_speed = 2.0;


// =====================
// 🔁 INVERT
// =====================
uniform bool invert_spikes = false;


// =====================
// ✨ EMISSION
// =====================
uniform float emission_strength = 6.0;


// =====================
// 🌊 NOISE
// =====================
uniform float noise_strength = 0.2;


// =====================
// 🔧 NOISE FUNCTIONS
// =====================
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);

    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    vec2 u = f * f * (3.0 - 2.0 * f);

    return mix(a, b, u.x) +
           (c - a) * u.y * (1.0 - u.x) +
           (d - b) * u.x * u.y;
}


// =====================
// 📌 BILLBOARD
// =====================
void vertex() {
    vec3 scale = vec3(
        length(MODEL_MATRIX[0].xyz),
        length(MODEL_MATRIX[1].xyz),
        length(MODEL_MATRIX[2].xyz)
    );

    mat3 mv = mat3(MODELVIEW_MATRIX);

    vec3 right = normalize(vec3(mv[0][0], mv[1][0], mv[2][0]));
    vec3 up    = normalize(vec3(mv[0][1], mv[1][1], mv[2][1]));

    vec3 p = VERTEX;

    VERTEX = right * p.x * scale.x + up * p.y * scale.y;
}


// =====================
// 🔺 VERBESSERTE SPIKE FUNCTION
// =====================
float spike_layer_custom(vec2 uv, float time, int count, 
                         float width_start, float width_end, float width_exp,
                         float speed, bool clockwise,
                         float max_length) {
    float dir = clockwise ? -1.0 : 1.0;
    float angle = atan(uv.y, uv.x);
    angle += time * speed * dir;

    float dist = length(uv);
    
    // 🔹 Längen-Begrenzung (Spike verschwindet jenseits von max_length)
    if (dist > max_length) return 0.0;
    
    // Sektor identifizieren (0..count)
    float sector = (angle / (2.0 * PI)) * float(count);
    float local = fract(sector); // 0..1 innerhalb eines Sektors
    
    // Position im Sektor (-0.5 .. 0.5)
    float pos = local - 0.5;
    
    // 📐 Normalisierte Distanz für die Breiten-Interpolation (0 = innen, 1 = außen)
    float t = pow(dist / max_length, width_exp);
    
    // Breite linear interpolieren zwischen start (innen) und end (außen)
    float width = mix(width_start, width_end, t);
    
    // Spike-Profil: 1 in der Mitte, 0 an den Rändern
    float spike = 1.0 - smoothstep(0.0, width, abs(pos) / 0.5);
    
    return clamp(spike, 0.0, 1.0);
}


// =====================
// 🎨 FRAGMENT
// =====================
void fragment() {
    vec2 uv = UV * 2.0 - 1.0;
    float time = TIME;
    float dist = length(uv);

    // =====================
    // 📏 LÄNGEN-ANIMATION (unabhängig von Breite)
    // =====================
    float t1 = sin(time * length_variation_speed) * 0.5 + 0.5;
    float t2 = sin(time * length_variation_speed * 0.7 + 1.3) * 0.5 + 0.5;
    float t3 = sin(time * length_variation_speed * 0.5 + 2.1) * 0.5 + 0.5;

    float len1 = mix(spike_length_min_1, spike_length_max_1, t1);
    float len2 = mix(spike_length_min_2, spike_length_max_2, t2);
    float len3 = mix(spike_length_min_3, spike_length_max_3, t3);

    // =====================
    // 🔺 SPIKES (mit eigener Länge pro Layer)
    // =====================
    float s1 = spike_layer_custom(uv, time, spike_count_1,
                                  spike_width_start_1, spike_width_end_1, width_exponent_1,
                                  rotation_speed_1, clockwise_1, len1);
                                  
    float s2 = spike_layer_custom(uv, time, spike_count_2,
                                  spike_width_start_2, spike_width_end_2, width_exponent_2,
                                  rotation_speed_2, clockwise_2, len2);
                                  
    float s3 = spike_layer_custom(uv, time, spike_count_3,
                                  spike_width_start_3, spike_width_end_3, width_exponent_3,
                                  rotation_speed_3, clockwise_3, len3);

    // =====================
    // 🔁 INVERT (jetzt nur noch auf die Spike-Werte)
    // =====================
    if (invert_spikes) {
        s1 = 1.0 - s1;
        s2 = 1.0 - s2;
        s3 = 1.0 - s3;
    }

    // =====================
    // 🌊 NOISE (optional)
    // =====================
    float n = noise(uv * 4.0 + time);
    s1 += (n - 0.5) * noise_strength;
    s2 += (n - 0.5) * noise_strength;
    s3 += (n - 0.5) * noise_strength;

    s1 = clamp(s1, 0.0, 1.0);
    s2 = clamp(s2, 0.0, 1.0);
    s3 = clamp(s3, 0.0, 1.0);

    // =====================
    // 🎨 FINAL COLOR
    // =====================
    vec3 color =
        spike_color_1.rgb * s1 +
        spike_color_2.rgb * s2 +
        spike_color_3.rgb * s3;

    ALBEDO = color;
    EMISSION = color * emission_strength;
}