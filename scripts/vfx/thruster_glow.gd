# res://scripts/thruster_glow.gd
extends Node
class_name ThrusterGlow

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export_group("Thruster Nodes")
@export var thruster_nodes: Array[Node3D] = []

@export_group("Emission")
@export var speed_threshold: float = 0.1
@export_range(0.0, 1.0) var min_amount_ratio: float = 0.05

@export_group("Initial Velocity Kopplung")
## Wenn true: initial_velocity des ParticleProcessMaterial wird proportional
## zur Schiffsgeschwindigkeit gesetzt. Bei local_coords=true sorgt das dafür,
## dass der Schweif bei hoher Geschwindigkeit länger wirkt — die Partikel
## fliegen schneller vom Triebwerk weg und überbrücken die Distanz besser.
@export var auto_velocity: bool = true

## Maximale Schiffsgeschwindigkeit (entspricht max_speed im ShipController).
## Bei dieser Geschwindigkeit wird velocity_at_max_speed erreicht.
@export var ship_max_speed: float = 400.0

## Initial-Velocity der Partikel bei Stillstand (min_ratio des Schiffs).
## Entspricht dem Ruheglow direkt am Triebwerk.
@export var velocity_at_rest: float = 2.0

## Initial-Velocity der Partikel bei Maximalgeschwindigkeit.
## Höher = Partikel fliegen weiter weg = längerer Schweif.
@export var velocity_at_max_speed: float = 40.0

## Multiplikator für velocity_max (leichte Spreizung um den Schweif natürlicher wirken zu lassen).
## 1.0 = kein Spread, 1.5 = velocity_max ist 50% höher als velocity_min
@export_range(1.0, 3.0) var velocity_spread: float = 1.3

@export_group("Smooth")
@export var smooth_enabled: bool = true
@export var smooth_speed: float  = 4.0

@export_group("Referenz")
@export var ship_controller_path: NodePath = NodePath("")

@export_group("Debug")
@export var debug_thruster: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────
var _ship_ctrl:       Node  = null
var _target_ratio:    float = 0.0
var _current_ratio:   float = 0.0
var _target_emitting: bool  = false
var _last_velocity:   float = -1.0


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_resolve_ship_controller()

	if not _ship_ctrl:
		push_warning("[ThrusterGlow] Kein ShipController gefunden — System inaktiv.")
		return
	if not _ship_ctrl.has_signal("ship_speed_updated"):
		push_warning("[ThrusterGlow] ShipController hat kein 'ship_speed_updated'-Signal.")
		return

	_ship_ctrl.ship_speed_updated.connect(_on_speed_updated)
	_set_emitting(false)
	_apply_ratio(0.0)

	if debug_thruster:
		print("[ThrusterGlow] '%s' verbunden mit ShipController '%s'" % [
			name, _ship_ctrl.name])


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS — Smooth ratio
# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not smooth_enabled:
		return
	var prev: float = _current_ratio
	_current_ratio = move_toward(_current_ratio, _target_ratio, smooth_speed * delta)

	if _target_emitting and _current_ratio > 0.001:
		_set_emitting(true)
	elif not _target_emitting and _current_ratio < 0.001:
		_set_emitting(false)

	if absf(_current_ratio - prev) > 0.001:
		_apply_ratio(_current_ratio)


# ─────────────────────────────────────────────────────────────────────────────
# SIGNAL-HANDLER
# ─────────────────────────────────────────────────────────────────────────────
func _on_speed_updated(current_speed: float, max_speed: float) -> void:
	var effective_max: float = ship_max_speed if ship_max_speed > 0.0 else maxf(max_speed, 1.0)
	var is_moving: bool = current_speed > speed_threshold
	var speed_ratio: float = clampf(current_speed / effective_max, 0.0, 1.0)

	# amount_ratio
	var ratio: float
	if not is_moving:
		ratio = 0.0
	else:
		ratio = lerpf(min_amount_ratio, 1.0, speed_ratio)

	_target_emitting = is_moving
	_target_ratio    = ratio

	# Initial Velocity proportional zur Geschwindigkeit
	if auto_velocity:
		var vel_min: float = lerpf(velocity_at_rest, velocity_at_max_speed, speed_ratio)
		var vel_max: float = vel_min * velocity_spread
		# Nur setzen wenn sich der Wert merklich geändert hat
		if absf(vel_min - _last_velocity) > 0.1:
			_apply_velocity(vel_min, vel_max)
			_last_velocity = vel_min

	if not smooth_enabled:
		_set_emitting(is_moving)
		_apply_ratio(ratio)
		_current_ratio = ratio

	if debug_thruster:
		print("[ThrusterGlow] speed=%.1f | ratio=%.2f | vel=%.1f | emitting=%s" % [
			current_speed, ratio, _last_velocity, is_moving])


# ─────────────────────────────────────────────────────────────────────────────
# NODE-STEUERUNG
# ─────────────────────────────────────────────────────────────────────────────
func _set_emitting(state: bool) -> void:
	for node in thruster_nodes:
		if not is_instance_valid(node):
			continue
		if node is GPUParticles3D:
			(node as GPUParticles3D).emitting = state
		elif node is CPUParticles3D:
			(node as CPUParticles3D).emitting = state


func _apply_ratio(ratio: float) -> void:
	for node in thruster_nodes:
		if not is_instance_valid(node):
			continue
		if node is GPUParticles3D:
			(node as GPUParticles3D).amount_ratio = ratio
		elif node is CPUParticles3D:
			(node as CPUParticles3D).speed_scale = lerpf(0.1, 1.0, ratio)


## Setzt initial_velocity_min/_max auf dem ParticleProcessMaterial.
## Funktioniert nur wenn das process_material ein ParticleProcessMaterial ist —
## bei einem ShaderMaterial wird eine Warning ausgegeben.
func _apply_velocity(vel_min: float, vel_max: float) -> void:
	for node in thruster_nodes:
		if not is_instance_valid(node):
			continue

		var mat: Material = null
		if node is GPUParticles3D:
			mat = (node as GPUParticles3D).process_material
		elif node is CPUParticles3D:
			# CPUParticles3D hat keine process_material Property —
			# initial_velocity direkt setzen
			var cpu := node as CPUParticles3D
			cpu.initial_velocity_min = vel_min
			cpu.initial_velocity_max = vel_max
			continue

		if mat is ParticleProcessMaterial:
			var pmat := mat as ParticleProcessMaterial
			pmat.initial_velocity_min = vel_min
			pmat.initial_velocity_max = vel_max
		elif mat != null:
			push_warning("[ThrusterGlow] Node '%s' hat kein ParticleProcessMaterial — velocity_kopplung nicht möglich." % node.name)


# ─────────────────────────────────────────────────────────────────────────────
# SHIP-CONTROLLER SUCHE
# ─────────────────────────────────────────────────────────────────────────────
func _resolve_ship_controller() -> void:
	if not ship_controller_path.is_empty():
		var found := get_node_or_null(ship_controller_path)
		if found and found.has_signal("ship_speed_updated"):
			_ship_ctrl = found
			return
		push_warning("[ThrusterGlow] ship_controller_path '%s' ungültig." % ship_controller_path)

	var node: Node = get_parent()
	while node:
		if node.has_signal("ship_speed_updated"):
			_ship_ctrl = node
			return
		node = node.get_parent()
