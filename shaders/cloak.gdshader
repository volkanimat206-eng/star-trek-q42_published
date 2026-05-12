shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, unshaded;

uniform float cloak_progress : hint_range(0.0, 1.0) = 0.0;
uniform float cloak_visibility : hint_range(0.0, 1.0) = 1.0;
uniform vec3 rim_color : source_color = vec3(0.4, 0.75, 1.0);
uniform float displacement_strength : hint_range(0.0, 0.2) = 0.04;

uniform float fresnel_power : hint_range(1.0, 8.0) = 3.5;
uniform float rim_intensity : hint_range(0.0, 2.0) = 0.85;
uniform float shimmer_speed : hint_range(0.0, 8.0) = 2.8;
uniform float shimmer_intensity : hint_range(0.0, 1.0) = 0.6;

// ─────────────────────────────────────────────────────────────────────────────
void vertex() {
    float transition = smoothstep(0.0, 0.25, cloak_progress) * 
                      (1.0 - smoothstep(0.75, 1.0, cloak_progress));

    if (displacement_strength > 0.001 && transition > 0.001) {
        float time = TIME * shimmer_speed;
        
        // More organic, multi-layered noise-like displacement
        float n1 = sin(VERTEX.x * 12.0 + time * 3.7) * cos(VERTEX.z * 9.0 + time * 2.9);
        float n2 = sin(VERTEX.y * 11.0 + time * 4.1) * cos(VERTEX.x * 8.0 + time * 3.3);
        float n3 = sin(VERTEX.z * 10.0 + time * 2.6) * cos(VERTEX.y * 13.0 + time * 4.4);
        
        vec3 displacement = NORMAL * (n1 * 0.5 + n2 * 0.35 + n3 * 0.25) 
                          * displacement_strength * transition * 1.15;
        
        VERTEX += displacement;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
void fragment() {
    float ndotv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
    float fresnel = pow(1.0 - ndotv, fresnel_power);

    float time = TIME * 1.8;
    float pulse = 1.0 + 0.12 * sin(time * 2.3) * cloak_progress;

    // Rim visibility
    float rim = fresnel * rim_intensity * pulse * cloak_visibility;
    
    // Extra subtle shimmer on the rim during transition + full cloak (for allies)
    float shimmer = sin(time * 7.0 + VERTEX.x * 25.0) * 0.5 + 0.5;
    shimmer = shimmer * shimmer_intensity * cloak_progress * cloak_visibility;
    
    float final_rim = rim + shimmer * 0.6;

    // Ship base visibility
    float ship_alpha = (1.0 - cloak_progress) * cloak_visibility;

    ALBEDO = rim_color * final_rim;
    ALPHA = max(ship_alpha, final_rim * 0.95);

    EMISSION = rim_color * final_rim * 1.6 * cloak_visibility;
}