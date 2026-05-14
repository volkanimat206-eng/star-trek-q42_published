# res://scripts/navigation_light.gd
# Lässt ein MeshInstance3D-Licht in einem konfigurierbaren Intervall blinken.
# An einen Node3D mit MeshInstance3D- und Timer-Kind hängen.
extends Node3D
class_name NavigationLight

# ===== EXPORTS =====
@export var blink_interval:    float  = 1.0   # Sekunden zwischen Blinks
@export var blink_on_duration: float  = 0.1   # Wie lange das Licht AN ist
@export var initial_delay:     float  = 0.0   # Verzögerung vor dem ersten Blink (für Staffelung)
@export_enum("Red", "Green", "White") var light_color: String = "Red"
@export var intensity_multiplier: float = 2.0

# ===== INTERN =====
var _mesh:         MeshInstance3D
var _timer:        Timer
var _material:     StandardMaterial3D
var _emission_color: Color
var _is_on:        bool = false

# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_mesh  = get_node_or_null("MeshInstance3D")
	_timer = get_node_or_null("Timer")

	if not _mesh:
		push_error("[NavigationLight] MeshInstance3D nicht gefunden!")
		return
	if not _timer:
		push_error("[NavigationLight] Timer nicht gefunden!")
		return

	_setup_material()

	_timer.wait_time = blink_interval
	_timer.timeout.connect(_on_timer_timeout)
	_set_light(false)

	if initial_delay > 0.0:
		await get_tree().create_timer(initial_delay).timeout

	_timer.start()


# ─────────────────────────────────────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────────────────────────────────────
func _setup_material() -> void:
	match light_color:
		"Red":   _emission_color = Color(1.0, 0.0, 0.0)
		"Green": _emission_color = Color(0.0, 1.0, 0.0)
		"White": _emission_color = Color(1.0, 1.0, 1.0)
		_:       _emission_color = Color(1.0, 0.0, 0.0)

	var existing := _mesh.get_surface_override_material(0)
	if existing is StandardMaterial3D:
		_material = existing.duplicate() as StandardMaterial3D
	else:
		_material = StandardMaterial3D.new()

	_material.emission_enabled          = true
	_material.emission                  = _emission_color
	_material.emission_energy_multiplier = 0.0
	_material.albedo_color              = _emission_color * 0.3

	_mesh.set_surface_override_material(0, _material)


# ─────────────────────────────────────────────────────────────────────────────
# BLINK
# ─────────────────────────────────────────────────────────────────────────────
func _on_timer_timeout() -> void:
	_set_light(true)
	await get_tree().create_timer(blink_on_duration).timeout
	_set_light(false)


func _set_light(on: bool) -> void:
	_is_on = on
	if not _material:
		return
	_material.emission_energy_multiplier = intensity_multiplier if on else 0.0


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────
func start_blinking() -> void:
	if _timer: _timer.start()

func stop_blinking() -> void:
	if _timer: _timer.stop()
	_set_light(false)

func set_blink_rate(new_interval: float) -> void:
	blink_interval = new_interval
	if _timer: _timer.wait_time = blink_interval

func set_color(color_name: String) -> void:
	light_color = color_name
	_setup_material()
	_set_light(_is_on)
