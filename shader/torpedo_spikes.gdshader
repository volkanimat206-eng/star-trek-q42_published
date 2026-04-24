shader_type spatial;
render_mode
    unshaded,
    blend_add,
    depth_draw_never,
    cull_disabled,
    fog_disabled;

// === TEXTURE ===
uniform bool use_texture = false;
uniform sampler2D albedo_texture : source_color;

// === COLOR ===
uniform vec4 color : source_color = vec4(1.0, 0.6, 0.2, 1.0);

// === ROTATION ===
uniform float rotation_speed = 3.0;

// === SCALE ===
uniform float scale_start = 0.3;
uniform float scale_end = 1.5;

// === FADE ===
uniform float fade_in = 0.1;
uniform float fade_out = 0.3;

// === SOFT EDGE ===
uniform float edge_softness = 0.5;

// === RANDOMNESS ===
uniform float randomness = 2.0;

// === VARYINGS (wichtig!) ===
varying float v_life;
varying float v_phase;

void vertex() {
    float t = TIME;
    
    // Lebenszeit (0.0 → 1.0) – kommt von GPUParticles3D
    float life = INSTANCE_CUSTOM.y;
    if (life == 0.0) {
        life = fract(t); // Fallback
    }
    
    // Zufallsphase pro Partikel
    float phase = INSTANCE_CUSTOM.x * randomness;
    
    // Rotation
    float angle = t * rotation_speed + phase;
    mat2 rot = mat2(
        vec2(cos(angle), -sin(angle)),
        vec2(sin(angle), cos(angle))
    );
    
    // Skalierung
    float scale = mix(scale_start, scale_end, life);
    
    // Rotiertes + skaliertes Quad in XY
    vec2 rotated_xy = rot * VERTEX.xy * scale;
    
    // ── Billboard: Quad immer zur Kamera ausrichten ───────────────────────────
    // MODEL_MATRIX enthält Position + Rotation des Partikels in World Space.
    // Wir extrahieren nur die Skalierung und nullen die Rotation →
    // Quad schaut immer direkt zur Kamera.
    mat4 mv = VIEW_MATRIX * MODEL_MATRIX;
    float sx = length(mv[0].xyz);
    float sy = length(mv[1].xyz);
    // Rotation nullen, Scale beibehalten
    mv[0] = vec4(sx, 0.0, 0.0, mv[0].w);
    mv[1] = vec4(0.0, sy, 0.0, mv[1].w);
    mv[2] = vec4(0.0, 0.0, 1.0, mv[2].w);
    
    // POSITION statt VERTEX setzen (überspringt normale Transform-Pipeline)
    POSITION = PROJECTION_MATRIX * mv * vec4(rotated_xy, 0.0, 1.0);
    
    // Werte an fragment() weitergeben
    v_life = life;
    v_phase = phase;
}

void fragment() {
    vec4 tex = vec4(1.0);
    if (use_texture) {
        tex = texture(albedo_texture, UV);
    }
    
    vec4 final_color = color * tex;
    
    // Fade In / Out (jetzt über varying)
    float fadeInFactor  = smoothstep(0.0, fade_in, v_life);
    float fadeOutFactor = 1.0 - smoothstep(1.0 - fade_out, 1.0, v_life);
    
    float alpha = final_color.a * fadeInFactor * fadeOutFactor;
    
    // Soft Edge (radial)
    float dist = length(UV - vec2(0.5));
    float soft = smoothstep(0.5, 0.5 - edge_softness, dist);
    alpha *= soft;
    
    ALBEDO = final_color.rgb;
    ALPHA = alpha;
}