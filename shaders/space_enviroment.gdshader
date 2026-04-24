shader_type sky;

// ===== TEXTURE =====
uniform sampler2D sky_texture : source_color, filter_linear, repeat_enable;

// ===== DRIFT (horizontal + vertical) =====
uniform vec2 uv_offset = vec2(0.0);

// ===== INTENSITY =====
uniform float exposure = 1.0;

// ─────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────
void sky() {
    vec3 dir = EYEDIR;

    // Equirectangular Mapping
    float u = atan(dir.x, dir.z) / (2.0 * PI) + 0.5;   // Horizontal
    float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;     // Vertical
    
    vec2 uv = vec2(u, v) + uv_offset;

    vec3 col = texture(sky_texture, uv).rgb;
    
    col *= exposure;
    col = pow(col, vec3(0.85));   // leichte Kontrastverbesserung

    COLOR = col;
}