shader_type spatial;

render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// ─────────────────────────────
// FARBE
// ─────────────────────────────
uniform vec4 color : source_color = vec4(0.6, 0.8, 1.0, 1.0);

// ─────────────────────────────
// RING FORM
// ─────────────────────────────
uniform float thickness = 0.12;
uniform float softness  = 0.15;

// ─────────────────────────────
// NOISE CONTROL
// ─────────────────────────────
uniform bool use_noise = true;
uniform sampler2D noise_tex : source_color;

uniform float noise_strength = 0.8;
uniform float noise_scale    = 6.0;
uniform float noise_speed    = 2.0;

// 0 = entlang Ring
// 1 = um Rohr (Walzen-Effekt)
uniform int noise_mode = 1;

// Richtung (1 oder -1)
uniform float noise_direction = 1.0;

// ─────────────────────────────
// OPTIONAL: globale Zeit-Skalierung
// ─────────────────────────────
uniform float time_scale = 1.0;


// ─────────────────────────────
// FRAGMENT
// ─────────────────────────────
void fragment() {

    vec2 uv = UV;

    // ── Distanz zum Ring-Zentrum ──
    float dist = abs(uv.y - 0.5);

    // ─────────────────────────────
    // DYNAMISCHE DICKE (wird am Ende breiter)
    // ─────────────────────────────
    float life = COLOR.a; // vom Particle-System!
    float dynamic_thickness = mix(thickness, thickness * 2.5, 1.0 - life);

    float ring = smoothstep(dynamic_thickness, dynamic_thickness - softness, dist);

    // ─────────────────────────────
    // NOISE UV (Walzen-Effekt möglich)
    // ─────────────────────────────
    float t = TIME * noise_speed * noise_direction * time_scale;

    vec2 noise_uv;

    if (noise_mode == 0) {
        // entlang Ring
        noise_uv = vec2(uv.x * noise_scale + t, uv.y);
    } else {
        // um Rohr (Walze!)
        noise_uv = vec2(uv.x, uv.y * noise_scale + t);
    }

    float noise_val = texture(noise_tex, noise_uv).r;

    // ─────────────────────────────
    // NOISE EINFLUSS
    // ─────────────────────────────
    float noise_mask = mix(1.0, noise_val, use_noise ? noise_strength : 0.0);

    // ─────────────────────────────
    // BREAKUP AM ENDE (zerfallender Ring)
    // ─────────────────────────────
    float breakup = mix(1.0, noise_val, 1.0 - life);

    float final_mask = ring * noise_mask * breakup;

    // ─────────────────────────────
    // ALPHA (FIX für Particle Curve + Cine Fade)
    // ─────────────────────────────
    float life_fade = pow(life, 2.5); // starkes End-Fade

    ALPHA = final_mask * color.a * life_fade;

    // ─────────────────────────────
    // EMISSION
    // ─────────────────────────────
    EMISSION = color.rgb * final_mask * 2.5;

    ALBEDO = color.rgb;
}