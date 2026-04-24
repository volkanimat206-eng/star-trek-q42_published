# res://scripts/thruster_glow.gd
extends MeshInstance3D

@export_group("Slot Settings")
@export var impulse_slot: int  = 0

@export_group("Glow Intensity")
@export var idle_glow: float  = 0.0
@export var max_glow: float   = 20.0

@export_group("Sound Settings")
@export var audio_player: AudioStreamPlayer3D
@export var min_volume_db: float = -20.0  # Inspector einstellbar
@export var max_volume_db: float = 0.0    # Inspector einstellbar
@export var min_pitch: float = 0.8        # Inspector einstellbar
@export var max_pitch: float = 1.2        # Inspector einstellbar
@export var use_pitch: bool = true        # optional ausschalten

var _material: StandardMaterial3D
var current_glow_display: float = 0.0

func _ready() -> void:
	# Material vorbereiten
	var original := get_active_material(impulse_slot)
	if original is StandardMaterial3D:
		_material = original.duplicate() as StandardMaterial3D
		set_surface_override_material(impulse_slot, _material)
	else:
		push_warning("[ThrusterGlow] Kein StandardMaterial3D auf Slot %d!" % impulse_slot)
		return

	await get_tree().process_frame
	_connect_to_ship()

	# Audio vorbereiten
	if audio_player:
		audio_player.volume_db = min_volume_db
		if not audio_player.playing:
			audio_player.play()


func _connect_to_ship() -> void:
	var sc: ShipController = _find_ship_controller()
	if sc:
		sc.ship_speed_updated.connect(_on_speed_updated)
		print("[ThrusterGlow] '%s' verbunden mit ShipController '%s'" % [name, sc.ship_name])
	else:
		push_warning("[ThrusterGlow] Kein ShipController gefunden für '%s'!" % name)


func _find_ship_controller() -> ShipController:
	var current: Node = get_parent()
	while current:
		if current is ShipController:
			return current as ShipController
		current = current.get_parent()

	var ancestor: Node = get_parent()
	while ancestor:
		var found := ancestor.find_children("*", "ShipController", false, false)
		if found.size() > 0:
			return found[0] as ShipController
		ancestor = ancestor.get_parent()

	return null


func _on_speed_updated(current_speed: float, max_speed: float) -> void:
	if not _material:
		return

	# --- Glow Update ---
	var ratio: float = clamp(absf(current_speed) / max_speed, 0.0, 1.0)
	var eased_ratio: float = ratio * ratio
	var energy: float = lerp(idle_glow, max_glow, eased_ratio)
	_material.emission_energy_multiplier = energy
	current_glow_display = energy

	# --- Sound Update ---
	if audio_player:
		audio_player.volume_db = lerp(min_volume_db, max_volume_db, eased_ratio)
		if use_pitch:
			audio_player.pitch_scale = lerp(min_pitch, max_pitch, eased_ratio)
