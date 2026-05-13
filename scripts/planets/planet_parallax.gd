# res://scripts/background/planet_parallax.gd
extends Node3D

@export_group("Parallax")
@export var target_path: NodePath

@export var horizontal_factor: float = 0.05
@export var vertical_factor: float = 0.03

@export_group("Idle Drift")
@export var enable_idle_drift: bool = true
@export var idle_speed: float = 0.05
@export var idle_amount: float = 2.0

@export_group("Follow")
@export var follow_height: bool = false

# ==================== INTERN ====================

var _target: Node3D
var _start_position: Vector3
var _time: float = 0.0
var _last_target_position: Vector3

# ────────────────────────────────────────────────
func _ready() -> void:

	_start_position = global_position

	_target = get_node_or_null(target_path)

	if not _target:
		push_warning("[PlanetParallax] Kein Target gefunden!")
		return

	_last_target_position = _target.global_position

# ────────────────────────────────────────────────
func _process(delta: float) -> void:

	if not _target:
		return

	_time += delta

	# ============================================
	# Bewegungsdelta des Ships
	# ============================================

	var current_pos := _target.global_position
	var movement := current_pos - _last_target_position
	_last_target_position = current_pos

	# ============================================
	# Parallax Offset
	# ============================================

	var offset := Vector3.ZERO

	# Ship bewegt sich nach rechts →
	# Planet bewegt sich minimal mit
	offset.x += movement.x * horizontal_factor

	# Ship bewegt sich vorwärts →
	# Planet driftet leicht
	offset.z += movement.z * vertical_factor

	# ============================================
	# Idle Drift
	# ============================================

	if enable_idle_drift:

		offset.x += sin(_time * idle_speed) * idle_amount * delta
		offset.z += cos(_time * idle_speed * 0.7) * idle_amount * 0.6 * delta

	# ============================================
	# Anwenden
	# ============================================

	global_position += offset

	# Optional:
	# Immer gleiche Höhe halten
	if not follow_height:
		global_position.y = _start_position.y
