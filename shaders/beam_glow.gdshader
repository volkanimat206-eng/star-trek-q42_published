shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded;

uniform vec4  glow_color     : source_color = vec4(1.0, 0.4, 0.1, 1.0);
uniform float glow_intensity : hint_range(0.0, 5.0) = 1.5;
uniform float glow_falloff   : hint_range(1.0, 5.0) = 3.0;

// Wie weit die Fade-Zone an jedem Ende reicht (0.0–0.5)
// 0.15 = die äußersten 15% auf jeder Seite laufen aus
uniform float fade_length    : hint_range(0.0, 0.5) = 0.15;

void fragment() {
    // ── Quer-Gradient (Breite) ────────────────────────────────────────────────
    float dist = abs(UV.x - 0.5) * 2.0;
    float glow = 1.0 - pow(dist, glow_falloff);

    // ── Längs-Fade (Anfang und Ende) ──────────────────────────────────────────
    // smoothstep: 0 → 1 über die fade_length-Zone an jedem Ende
    float fade = smoothstep(0.0, fade_length, UV.y)
               * smoothstep(1.0, 1.0 - fade_length, UV.y);

    float alpha = glow * fade * 0.5;

    ALBEDO   = glow_color.rgb * glow_intensity;
    ALPHA    = alpha;
    EMISSION = glow_color.rgb * glow_intensity * glow * fade;
}

