// res://shader/hull_impact.gdshader
// Schritt 1: Auftreffpunkt-Glow am Phaser-Trefferpunkt.
//
// Design-Entscheidungen:
//   • hit_position_local statt Weltkoordinate + inv_model_matrix:
//     GDScript rechnet mesh.to_local(world_pos) → nur ein vec3 nötig,
//     kein Matrix-Uniform, kein Frame-Update der Matrix.
//     VERTEX ist in Godot 4 bereits Objektraum → direkter Abstand.
//
//   • Optionale albedo_texture: Wenn zugewiesen wird sie gesampelt,
//     sonst greift albedo_color. Gleicher Shader für Sphere (kein Texture)
//     und Schiffsmodelle (Surface 0/1 Textur).

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ── Basis-Material ────────────────────────────────────────────────────────────
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform vec4      albedo_color   : source_color = vec4(0.2, 0.8, 0.2, 1.0);
uniform bool      use_texture    = false;

uniform float metallic           : hint_range(0.0, 1.0) = 0.3;
uniform float roughness          : hint_range(0.0, 1.0) = 0.6;

// ── Impact-Parameter ──────────────────────────────────────────────────────────
// Trefferpunkt im LOKALEN Objektraum des Meshs.
// Wird von HullImpactReceiver.gd via mesh_instance.to_local(world_pos) gesetzt.
// Da VERTEX ebenfalls Objektraum ist: direkter Abstandsvergleich, keine Matrix.
uniform vec3  hit_position_local   = vec3(0.0);
uniform float impact_radius        : hint_range(0.5, 30.0) = 6.0;
uniform float impact_intensity     : hint_range(0.0, 1.0)  = 0.0;
uniform vec4  impact_color         : source_color = vec4(1.0, 0.65, 0.2, 1.0);

// Relativer Anteil des dunklen Scorch-Kerns (0.35 = 35% des Radius)
uniform float scorch_radius_factor : hint_range(0.0, 0.6) = 0.35;
uniform vec4  scorch_color         : source_color = vec4(0.04, 0.02, 0.01, 1.0);
uniform float emission_strength    : hint_range(0.0, 3.0) = 0.5;

void fragment() {
	// ── Basis-Albedo: Textur oder Flachfarbe ──────────────────────────────
	vec4 base = use_texture ? texture(albedo_texture, UV) * albedo_color : albedo_color;

	// ── Abstand VERTEX → Trefferpunkt (beide in Objektraum) ──────────────
	float dist      = length(VERTEX - hit_position_local);
	float norm_dist = clamp(dist / impact_radius, 0.0, 1.0);

	// ── Masken ────────────────────────────────────────────────────────────
	float glow_mask   = (1.0 - smoothstep(0.5, 1.0, norm_dist)) * impact_intensity;
	float scorch_mask = (1.0 - smoothstep(0.0, scorch_radius_factor, norm_dist)) * impact_intensity;

	// ── Farben mischen: base → glow (außen) → scorch (innen) ─────────────
	vec3 result = mix(base.rgb, impact_color.rgb, glow_mask * 0.80);
	result      = mix(result,   scorch_color.rgb, scorch_mask);

	ALBEDO    = result;
	METALLIC  = metallic;
	ROUGHNESS = mix(roughness, 0.95, scorch_mask);
	EMISSION  = impact_color.rgb * glow_mask * emission_strength * impact_intensity;
	ALPHA     = base.a;
}
