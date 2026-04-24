# res://scripts/components/movement_component.gd
extends Node
class_name MovementComponent

# ===== SIGNALS =====
signal speed_updated(current_speed: float, max_speed: float)

var current_speed: float = 0.0
var current_stats: ShipStats

# ── Tilt-State (gilt für Player UND KI) ───────────────────────────────────────
var _tilt_angle:      float = 0.0
var _model_base_basis: Basis = Basis.IDENTITY
var _model_node:      Node3D

# ── Shockwave-Tilt-State ──────────────────────────────────────────────────────
## Aktueller Kipp-Offset in Radiant durch eine Shockwave.
## Wird von update_tilt() bei jeder Basis-Berechnung addiert – kein Tween-Konflikt.
var _shockwave_z_rad:  float = 0.0
var _shockwave_tween:  Tween = null

# ── Shockwave-Velocity-Impuls ─────────────────────────────────────────────────
## Separater Impuls-Vektor der graduell ausklingt und in calculate_movement()
## zum normalen Bewegungsvektor addiert wird.
## NICHT direkt body.velocity setzen – das wird jedes Frame überschrieben!
var _shockwave_velocity: Vector3 = Vector3.ZERO
## Dämpfung als Vielfaches von max_speed pro Sekunde.
## 0.15 = bei max_speed 400 → 60 u/s² Dämpfung, Impuls klingt in ~3-5s aus.
@export var shockwave_decay_factor: float = 0.15


func init_tilt(model: Node3D) -> void:
	_model_node         = model
	_model_base_basis   = model.basis if model else Basis.IDENTITY
	_tilt_angle         = 0.0
	_shockwave_z_rad    = 0.0
	_shockwave_velocity = Vector3.ZERO


func calculate_movement(owner_node: CharacterBody3D, thrust_value: float, rotation_value: float, stats: ShipStats, delta: float) -> Vector3:
	current_stats = stats

	# 1. Speed
	var multiplier: float    = 1.0 if thrust_value >= 0.0 else 0.4
	var target_speed: float  = thrust_value * (stats.max_speed * multiplier)

	if thrust_value != 0.0:
		current_speed = move_toward(current_speed, target_speed, stats.acceleration * delta)
	else:
		current_speed = move_toward(current_speed, 0.0, stats.friction * delta)

	# 2. Rotation mit optionalem Pivot-Offset
	if rotation_value != 0.0:
		var angle: float = -rotation_value * _dynamic_rotation_speed(stats) * delta
		if stats.pivot_offset != Vector3.ZERO:
			var world_pivot: Vector3 = owner_node.global_transform * stats.pivot_offset
			var t := owner_node.global_transform
			t.origin -= world_pivot
			t = t.rotated(Vector3.UP, angle)
			t.origin += world_pivot
			owner_node.global_transform = t
		else:
			owner_node.rotate_y(angle)

	# 3. Signal
	speed_updated.emit(current_speed, stats.max_speed)

	# 4. Shockwave-Impuls dämpfen
	if _shockwave_velocity.length_squared() > 0.01:
		var decay: float = shockwave_decay_factor * stats.max_speed * delta
		_shockwave_velocity = _shockwave_velocity.move_toward(Vector3.ZERO, decay)
	else:
		_shockwave_velocity = Vector3.ZERO

	# 5. Bewegungsvektor: normaler Antrieb + ausklingender Shockwave-Impuls
	return (-owner_node.global_transform.basis.z * current_speed) + _shockwave_velocity


func update_tilt(rotation_value: float, stats: ShipStats, delta: float) -> void:
	if not _model_node or not is_instance_valid(_model_node):
		return

	# Normaler Fahrt-Tilt (unverändert)
	var target_tilt: float = rotation_value * -stats.tilt_amount
	_tilt_angle = lerp(_tilt_angle, target_tilt, delta * stats.tilt_speed)

	# Basis aus normalem Tilt berechnen
	var axis: Vector3 = stats.tilt_axis.normalized()
	if axis == Vector3.ZERO:
		axis = Vector3(0.0, 0.0, 1.0)
	var tilt_basis: Basis = _model_base_basis.rotated(axis, _tilt_angle * stats.tilt_direction)

	# Shockwave-Z-Offset obendrauf – läuft unabhängig, kein Conflict mit dem Tween
	if absf(_shockwave_z_rad) > 0.0001:
		tilt_basis = tilt_basis.rotated(Vector3(0.0, 0.0, 1.0), _shockwave_z_rad)

	_model_node.basis = tilt_basis


## Addiert einen einmaligen Geschwindigkeitsimpuls durch eine Shockwave.
## Der Impuls klingt über mehrere Frames graduell aus (decay_factor).
## Muss über diese Methode gesetzt werden – NICHT direkt body.velocity!
func apply_shockwave_push(force: Vector3) -> void:
	_shockwave_velocity += force


## Löst einen kurzen Kipp-Impuls durch eine Explosions-Shockwave aus.
## push_dir: normalisierte Richtung vom Explosionszentrum weg (Weltkoordinaten).
## Der Kippwinkel wird links/rechts gespiegelt je nach lateralem Anteil der push_dir.
func apply_shockwave_tilt(angle_deg: float, recovery_time: float, push_dir: Vector3) -> void:
	if not _model_node or not is_instance_valid(_model_node):
		return

	# Kipprichtung aus dem lateralen Anteil der push_dir im lokalen Schiffs-Raum ableiten.
	# get_parent() = ShipController (Node3D), dessen parent = CharacterBody3D.
	# Wir holen den globalen Transform des Model-Nodes selbst für die Projektion.
	var local_push: Vector3 = _model_node.global_transform.basis.inverse() * push_dir
	var sign_x: float = signf(local_push.x) if absf(local_push.x) > 0.1 else 1.0
	var target_rad: float = deg_to_rad(angle_deg * sign_x)

	# Laufenden Tween abbrechen
	if _shockwave_tween != null and _shockwave_tween.is_valid():
		_shockwave_tween.kill()

	_shockwave_tween = create_tween()
	_shockwave_tween.set_ease(Tween.EASE_OUT)
	_shockwave_tween.set_trans(Tween.TRANS_SPRING)
	# Phase 1: schnell auf Kipp-Winkel
	_shockwave_tween.tween_property(self, "_shockwave_z_rad", target_rad, 0.12)
	# Phase 2: zurück auf 0 (Spring federt organisch zurück)
	_shockwave_tween.tween_property(self, "_shockwave_z_rad", 0.0, recovery_time)


# ── Private Helfer ────────────────────────────────────────────────────────────

func _dynamic_rotation_speed(stats: ShipStats) -> float:
	var speed_percent: float = abs(current_speed) / stats.max_speed if stats.max_speed > 0.0 else 0.0
	return lerp(stats.rotation_speed_base, stats.rotation_speed_min, speed_percent)
