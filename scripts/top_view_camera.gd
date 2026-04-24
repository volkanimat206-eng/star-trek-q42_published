# res://scripts/top_view_camera.gd
extends Camera3D

@export_group("Tracking")
@export var target_path: NodePath

@export_group("Zoom Settings")
@export var start_height: float = 400.0
@export var min_height: float = 80.0
@export var max_height: float = 1200.0
@export var zoom_speed: float = 100.0
@export var smooth_speed: float = 5.0

@export_group("Dynamic FOV")
@export var base_fov: float = 70.0
@export var max_fov_add: float = 15.0

@export_group("Space Drift")
@export var enable_space_drift: bool = true
@export var horizontal_drift_strength: float = 0.0010   # Links/Rechts (X)
@export var vertical_drift_strength: float = 0.0006    # Vor/Zurück (Z) → vertikal im Sky
@export var idle_drift_speed: float = 0.015
@export var idle_drift_amount: float = 0.00015

# ==================== INTERN ====================
var _target: CharacterBody3D
var _movement_comp: MovementComponent
var _ship_stats: ShipStats

var _target_height: float = 0.0
var _current_height: float = 0.0

var _sky_material: Material = null
var _sky_offset: Vector2 = Vector2.ZERO
var _time: float = 0.0

# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_target_height = start_height
	_current_height = max_height
	
	_target = get_node_or_null(target_path) as CharacterBody3D
	if not _target: 
		push_warning("[TopViewCamera] Kein Target gefunden!")
		return
	
	global_position = _target.global_position + Vector3(0, _current_height, 0)
	await get_tree().process_frame
	_find_ship_components()
	_find_sky_material()
	
# ─────────────────────────────────────────────────────────────────────────────
func _find_ship_components() -> void:
	var ship_controller := _target.find_child("*", true, false) as ShipController
	if not ship_controller:
		for child in _target.find_children("*", "ShipController", true, false):
			if child is ShipController:
				ship_controller = child
				break
	
	if not ship_controller:
		push_warning("[TopViewCamera] Kein ShipController gefunden!")
		return
	
	_movement_comp = ship_controller.movement_comp
	_ship_stats = ship_controller.stats

# ─────────────────────────────────────────────────────────────────────────────
func _find_sky_material() -> void:
	var world_env := get_viewport().get_world_3d().environment
	if not world_env:
		push_warning("[TopViewCamera] Kein WorldEnvironment gefunden!")
		return
	
	if world_env.sky and world_env.sky.sky_material:
		_sky_material = world_env.sky.sky_material
	else:
		push_warning("[TopViewCamera] Kein SkyMaterial gefunden!")

# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not _target: return
	
	# Zoom & Position
	if Input.is_action_just_pressed("zoom_in"):
		_target_height = clamp(_target_height - zoom_speed, min_height, max_height)
	if Input.is_action_just_pressed("zoom_out"):
		_target_height = clamp(_target_height + zoom_speed, min_height, max_height)
	
	_current_height = lerp(_current_height, _target_height, smooth_speed * delta)
	global_position = _target.global_position + Vector3(0, _current_height, 0)
	look_at(_target.global_position, Vector3.FORWARD)
	
	_update_dynamic_fov(delta)
	
	if enable_space_drift:
		_update_space_drift(delta)

# ─────────────────────────────────────────────────────────────────────────────
func _update_dynamic_fov(delta: float) -> void:
	if not _movement_comp or not _ship_stats: return
	var speed_percent := absf(_movement_comp.current_speed) / _ship_stats.max_speed
	fov = lerp(fov, base_fov + speed_percent * max_fov_add, delta * 2.0)

# ─────────────────────────────────────────────────────────────────────────────
# NEUE DRIFT LOGIK
# ─────────────────────────────────────────────────────────────────────────────
func _update_space_drift(delta: float) -> void:
	if not _sky_material: return
	
	_time += delta
	var move_offset := Vector2.ZERO
	
	if _movement_comp:
		var vel := Vector3.ZERO
		if "velocity" in _movement_comp:
			vel = _movement_comp.velocity
		elif _movement_comp.has_method("get_velocity"):
			vel = _movement_comp.get_velocity()
		
		# WICHTIG: Mapping auf Sky
		# vel.x = seitliche Bewegung → horizontales Driften im Himmel
		# vel.z = vor/zurück → vertikales Driften im Himmel
		move_offset.x = vel.x * horizontal_drift_strength
		move_offset.y = vel.z * vertical_drift_strength   # y im UV = vertikal im Sky
	
	# Leichter Idle-Drift (sanftes Schweben)
	var idle := Vector2(
		sin(_time * idle_drift_speed) * idle_drift_amount,
		cos(_time * idle_drift_speed * 0.7) * idle_drift_amount * 0.6
	)
	
	_sky_offset += (move_offset + idle) * delta
	
	# Shader updaten
	if _sky_material is ShaderMaterial:
		_sky_material.set_shader_parameter("uv_offset", _sky_offset)
		
