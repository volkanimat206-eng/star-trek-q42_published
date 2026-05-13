# res://scripts/vfx/ship_debris_burst.gd
#
# Spawnt die echten Schiffs-Meshes aus einer Fragment-Szene als physikalische
# RigidBody3D-Fragmente mit Burn/Glow-Shader.
#
# ABLAUF:
#   1. fragment_scene (z.B. galaxy_debris.tscn) wird instanziert
#   2. Alle direkten MeshInstance3D-Kinder werden als eigenständige
#      RigidBody3D-Fragmente in die Welt eingefügt
#   3. Jedes Fragment bekommt:
#      • kombinierten Physik-Impuls (Explosion vom Zentrum + Drift + Tumbling)
#      • Burn-ShaderMaterial mit zwei Phasen:
#          Phase 1 – Fresnel-Kantenglow (0 → Peak in peak_glow_time)
#          Phase 2 – Noise-Burn breitet sich aus + Glow verblasst
#      • Alpha-Fade-Out → queue_free()
#
# ANFORDERUNGEN AN DIE FRAGMENT-SZENE (galaxy_debris.tscn etc.):
#   Root:   Node3D  (KEIN RigidBody — wir bauen die Bodies selbst)
#   Kinder: MeshInstance3D (direkte Kinder, beliebig viele)
#           Materialien werden automatisch übernommen
#
# INTEGRATION — wird aus ExplosionDebrisData via ExplosionEffect aufgerufen.
# Direkter Aufruf auch möglich:
#
#   ShipDebrisBurst.launch_at(
#       galaxy_debris_packed_scene,   # PackedScene
#       get_tree().current_scene,     # Parent-Node
#       global_position,              # Weltposition
#       my_debris_config,             # ShipDebrisConfig Resource
#       faction_tint                  # Color (multiplikativ)
#   )
#
class_name ShipDebrisBurst
extends Node3D


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────

var _cfg: ShipDebrisConfig = null      # aktive Konfiguration
var _faction_tint: Color = Color.WHITE # Faction-Farbe vom ShipController
var _origin: Vector3 = Vector3.ZERO    # Explosionszentrum


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Haupteinstieg — instanziert und explodiert alle Meshes aus fragment_scene.
##
## fragment_scene : PackedScene  (galaxy_debris.tscn, klingon_debris.tscn …)
## origin         : Weltposition des Explosionszentrums
## config         : ShipDebrisConfig Resource — alle Shader/Physik-Parameter
##                  Wenn null: Fallback auf eingebaute Defaults
## faction_tint   : Multiplikativer Color-Tint (debris_color_tint aus ShipController)
func launch(
	fragment_scene: PackedScene,
	origin: Vector3,
	config: ShipDebrisConfig = null,
	faction_tint: Color = Color.WHITE
) -> void:
	_origin       = origin
	_faction_tint = faction_tint
	_cfg          = config if config else ShipDebrisConfig.new()

	if not fragment_scene:
		push_warning("[ShipDebrisBurst] fragment_scene ist null — kein Debris!")
		return

	var template_root := fragment_scene.instantiate() as Node3D
	if not template_root:
		push_warning("[ShipDebrisBurst] Root der fragment_scene ist kein Node3D!")
		return

	# Kurz in den Tree einhängen damit MeshInstance3D-Kinder global_position haben
	add_child(template_root)
	template_root.global_position = origin

	for child in template_root.get_children():
		if child is MeshInstance3D:
			_spawn_fragment(child as MeshInstance3D)

	template_root.queue_free()


## Statische Convenience — kein separates Szene-Objekt nötig.
## Gibt den erzeugten ShipDebrisBurst-Node zurück (falls du ihn brauchst).
static func launch_at(
	fragment_scene: PackedScene,
	world: Node,
	origin: Vector3,
	config: ShipDebrisConfig = null,
	faction_tint: Color = Color.WHITE
) -> ShipDebrisBurst:
	if not world:
		push_warning("[ShipDebrisBurst] launch_at: world ist null!")
		return null

	var burst := ShipDebrisBurst.new()
	world.add_child(burst)
	burst.global_position = origin
	burst.launch(fragment_scene, origin, config, faction_tint)
	return burst


# ─────────────────────────────────────────────────────────────────────────────
# FRAGMENT-ERZEUGUNG
# ─────────────────────────────────────────────────────────────────────────────

func _spawn_fragment(mesh_inst: MeshInstance3D) -> void:
	# ── RigidBody3D Container ────────────────────────────────────────────────
	var body := RigidBody3D.new()
	body.gravity_scale = _cfg.gravity_scale
	body.linear_damp   = _cfg.linear_damp
	body.angular_damp  = _cfg.angular_damp

	# CollisionShape aus Mesh-AABB
	var col   := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	if mesh_inst.mesh:
		var aabb := mesh_inst.mesh.get_aabb()
		shape.size = aabb.size.clamp(
			Vector3(0.1, 0.1, 0.1),
			Vector3(25.0, 25.0, 25.0)
		)
	else:
		shape.size = Vector3(1.0, 1.0, 1.0)
	col.shape = shape

	# ── MeshInstance klonen ──────────────────────────────────────────────────
	var mesh_copy := MeshInstance3D.new()
	mesh_copy.mesh = mesh_inst.mesh
	mesh_copy.material_override = _build_burn_material(mesh_inst)

	# ── Szene zusammenbauen ──────────────────────────────────────────────────
	body.add_child(col)
	body.add_child(mesh_copy)

	# Debris-Layer: kein Friendly Fire zwischen Fragmenten
	body.collision_layer = 0b0000_0000_0000_1000  # Layer 4
	body.collision_mask  = 0b0000_0000_0000_0000

	var world_parent: Node = get_parent() if get_parent() else get_tree().current_scene
	world_parent.add_child(body)
	body.global_position = mesh_inst.global_position

	# ── Physik ───────────────────────────────────────────────────────────────
	_apply_impulses(body)

	# ── Collision nach Delay deaktivieren ────────────────────────────────────
	if _cfg.collision_disable_after > 0.0:
		get_tree().create_timer(_cfg.collision_disable_after).timeout.connect(
			func():
				if is_instance_valid(body):
					body.collision_layer = 0
					body.collision_mask  = 0
					col.disabled         = true
		)

	# ── Burn-Sequenz + Lifetime ───────────────────────────────────────────────
	_run_burn_sequence(mesh_copy, mesh_copy.material_override as ShaderMaterial)
	_run_lifetime(body)


func _apply_impulses(body: RigidBody3D) -> void:
	# Richtung: weg vom Explosionszentrum
	var dir := (body.global_position - _origin)
	if dir.length_squared() < 0.001:
		dir = Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-0.5, 0.5),
			randf_range(-1.0, 1.0)
		)
	dir = dir.normalized()

	# Zufälliger Drift überlagert Explosionsvektor
	var drift := Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	).normalized() * _cfg.random_drift_strength

	body.apply_impulse(dir * randf_range(_cfg.explosion_force_min, _cfg.explosion_force_max) + drift)

	# Tumbling
	var torque_dir := Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	)
	if torque_dir.length_squared() < 0.001:
		torque_dir = Vector3.UP
	body.apply_torque_impulse(
		torque_dir.normalized() * randf_range(_cfg.torque_min, _cfg.torque_max)
	)


# ─────────────────────────────────────────────────────────────────────────────
# SHADER / MATERIAL
# ─────────────────────────────────────────────────────────────────────────────

func _build_burn_material(source: MeshInstance3D) -> ShaderMaterial:
	var shader_code := """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ── Albedo ────────────────────────────────────────────────────────────────
uniform sampler2D texture_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);

// ── Burn-Farbe & Intensitäten ─────────────────────────────────────────────
// Wird aus ShipDebrisConfig gesetzt — pro Fraktion/Schiffsklasse unterschiedlich
uniform vec4  burn_color          : source_color = vec4(1.0, 0.55, 0.1, 1.0);
uniform float edge_glow_peak      : hint_range(0.0, 12.0) = 3.5;
uniform float spread_glow_intensity : hint_range(0.0, 6.0) = 1.2;
uniform float burn_albedo_mix     : hint_range(0.0, 1.0)  = 0.85;
uniform float hot_edge_brightness : hint_range(0.0, 8.0)  = 2.5;
uniform float burn_noise_scale    : hint_range(0.1, 8.0)  = 1.5;

// ── Animierte Werte (per Tween gesetzt) ──────────────────────────────────
uniform float burn_progress   : hint_range(0.0, 1.0) = 0.0;
uniform float edge_intensity  : hint_range(0.0, 12.0) = 0.0;
uniform float alpha           : hint_range(0.0, 1.0)  = 1.0;

// ── Noise-Funktion (Vertex-Ebene, kein Sampler nötig) ────────────────────
float hash3(vec3 p) {
	p = fract(p * vec3(443.8975, 397.2973, 491.1871));
	p += dot(p.zxy, p.yxz + 19.19);
	return fract(p.x * p.y * p.z);
}

void fragment() {
	vec4 tex = texture(texture_albedo, UV) * albedo_tint;

	// Fresnel: leuchtet an Kanten die vom Betrachter wegzeigen
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);

	// Burn-Ausbreitung: Noise-Schwelle wird von burn_progress angetrieben
	float noise = hash3(VERTEX * burn_noise_scale);
	float burned = step(noise, burn_progress);

	// Heisse Übergangs-Kante zwischen verbrannt/unverbrannt
	float hot_edge = smoothstep(burn_progress - 0.12, burn_progress, noise)
	               * (1.0 - burned);

	// Finales Albedo
	vec3 col = mix(tex.rgb, burn_color.rgb, burned * burn_albedo_mix);
	col += burn_color.rgb * hot_edge * hot_edge_brightness;

	// Emission: Kantenglow + Burn-Ausbreitung
	vec3 emission = burn_color.rgb * (
		fresnel * edge_intensity +
		hot_edge * spread_glow_intensity * 1.8 +
		burned   * spread_glow_intensity * 0.3
	);

	ALBEDO    = col;
	EMISSION  = emission;
	ALPHA     = tex.a * alpha * (1.0 - burned * 0.55);
	METALLIC  = 0.55;
	ROUGHNESS = 0.38 + burned * 0.45;
}
"""

	var shader := Shader.new()
	shader.code = shader_code

	var mat := ShaderMaterial.new()
	mat.shader = shader

	# ── Textur + Tint vom Original-Material übernehmen ───────────────────────
	var source_tex:  Texture2D = null
	var source_tint: Color     = Color.WHITE

	var orig_mat: Material = null
	if source.material_override:
		orig_mat = source.material_override
	elif source.mesh and source.mesh.get_surface_count() > 0:
		orig_mat = source.mesh.surface_get_material(0)

	if orig_mat is StandardMaterial3D:
		var sm := orig_mat as StandardMaterial3D
		source_tex  = sm.albedo_texture
		source_tint = sm.albedo_color

	if source_tex:
		mat.set_shader_parameter("texture_albedo", source_tex)

	# Faction-Tint multiplikativ auf Albedo-Tint
	mat.set_shader_parameter("albedo_tint", Color(
		source_tint.r * _faction_tint.r,
		source_tint.g * _faction_tint.g,
		source_tint.b * _faction_tint.b,
		source_tint.a
	))

	# ── Alle Shader-Parameter aus ShipDebrisConfig ────────────────────────────
	mat.set_shader_parameter("burn_color",           _cfg.glow_color * _faction_tint)
	mat.set_shader_parameter("edge_glow_peak",       _cfg.edge_glow_peak)
	mat.set_shader_parameter("spread_glow_intensity", _cfg.spread_glow_intensity)
	mat.set_shader_parameter("burn_albedo_mix",      _cfg.burn_albedo_mix)
	mat.set_shader_parameter("hot_edge_brightness",  _cfg.hot_edge_brightness)
	mat.set_shader_parameter("burn_noise_scale",     _cfg.burn_noise_scale)

	# Animierte Startwerte
	mat.set_shader_parameter("burn_progress",  0.0)
	mat.set_shader_parameter("edge_intensity", 0.0)
	mat.set_shader_parameter("alpha",          1.0)

	return mat


# ─────────────────────────────────────────────────────────────────────────────
# TWEEN-SEQUENZ
# ─────────────────────────────────────────────────────────────────────────────

func _run_burn_sequence(mesh_copy: MeshInstance3D, mat: ShaderMaterial) -> void:
	if not mat:
		return

	# Leichte Zufallsverzögerung → Fragmente glühen nicht alle synchron auf
	var delay := randf_range(0.0, _cfg.fragment_delay_variance)

	var tw := mesh_copy.create_tween()
	tw.set_parallel(false)

	if delay > 0.0:
		tw.tween_interval(delay)

	# Phase 1 — Kantenglow aufblenden (0 → peak)
	tw.tween_method(
		func(v: float): mat.set_shader_parameter("edge_intensity", v),
		0.0, _cfg.edge_glow_peak, _cfg.peak_glow_time
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# Phase 2 — Burn ausbreiten + Kantenglow verblasst gleichzeitig
	tw.set_parallel(true)

	tw.tween_method(
		func(v: float): mat.set_shader_parameter("burn_progress", v),
		0.0, 1.0, _cfg.burn_spread_duration
	).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)

	tw.tween_method(
		func(v: float): mat.set_shader_parameter("edge_intensity", v),
		_cfg.edge_glow_peak, _cfg.spread_glow_intensity, _cfg.burn_spread_duration * 0.6
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	tw.set_parallel(false)

	# Warten bis fade_out_start erreicht ist
	var wait := maxf(0.05,
		_cfg.fade_out_start - _cfg.peak_glow_time - _cfg.burn_spread_duration - delay
	)
	tw.tween_interval(wait)

	# Phase 3 — Fade-Out
	tw.tween_method(
		func(v: float): mat.set_shader_parameter("alpha", v),
		1.0, 0.0, _cfg.fade_out_duration
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)


func _run_lifetime(body: RigidBody3D) -> void:
	var total := _cfg.fade_out_start + _cfg.fade_out_duration + randf_range(0.0, 0.5)
	get_tree().create_timer(total).timeout.connect(
		func():
			if is_instance_valid(body):
				body.queue_free()
	)
