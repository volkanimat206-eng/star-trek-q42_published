# res://scripts/hull_damage_visualizer.gd
#
# ARCHITEKTUR:
#   Hängt am MeshModel-Knoten. Findet rekursiv alle MeshInstance3D-Kinder
#   mit Damage-Shader und klont ihre Materials.
#   HP-Polling via _process(), Todessequenz via AnimationPlayer.

@tool
extends Node
class_name HullDamageVisualizer

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export_group("Damage Configuration")
@export var damage_parameters: DamageParameters

@export_group("Ship Reference")
@export var ship_controller_path: NodePath

@export_group("Mesh Discovery")
@export var damage_shader: Shader = null

@export_group("Damage Mapping")
@export_range(0.5, 1.0, 0.01) var damage_visual_cap: float = 0.65
@export_range(0.0, 6.0, 0.1)  var damage_curve_exponent: float = 2.5
## Ab wie viel Prozent Hüllenschaden soll die Anzeige beginnen? (0.5 = 50%)
@export_range(0.0, 1.0, 0.05) var damage_start_threshold: float = 0.5
## Welcher damage_amount soll beim Erreichen des Schwellenwerts sofort angezeigt werden?
@export_range(0.0, 1.0, 0.05) var damage_min_visual: float = 0.3


@export_group("Dynamic Pulse Scaling")
@export var enable_dynamic_pulse: bool = true
@export_range(0.0, 10.0, 0.1)  var pulse_speed_min: float = 0.8
@export_range(0.0, 10.0, 0.1)  var pulse_speed_max: float = 3.5
@export_range(0.0, 1.0,  0.01) var pulse_flicker_min: float = 0.0
@export_range(0.0, 1.0,  0.01) var pulse_flicker_max: float = 0.6
@export_range(0.0, 1.0,  0.01) var pulse_amplitude_min: float = 0.3
@export_range(0.0, 1.0,  0.01) var pulse_amplitude_max: float = 0.7

@export_group("Death Sequence")
## Animation-Resource (.tres) für die Todessequenz. Pro Schiffsklasse eine eigene zuweisen.
@export var death_animation: Animation = null
## Pfad zum AnimationPlayer (relativ zu diesem Node, also Geschwister unter MeshModel).
@export var animation_player_path: NodePath = NodePath("../AnimationPlayer")
## Name unter dem die Animation im AnimationPlayer registriert wird.
@export var death_animation_name: String = "death_sequence"

@export_group("Performance")
@export_range(0.0, 0.5, 0.01) var update_interval: float = 0.0

@export_group("Debug")
@export var debug_visualizer: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# SIGNAL
# ─────────────────────────────────────────────────────────────────────────────
signal death_sequence_finished


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────
var _ship_ctrl: Node = null
var _anim_player: AnimationPlayer = null
var _death_active: bool = false

class _MaterialEntry:
	var mesh_instance: MeshInstance3D
	var surface_index: int
	var material: ShaderMaterial

var _entries: Array[_MaterialEntry] = []
var _accum_time: float = 0.0
var _last_damage_log: float = -1.0
var _initialized: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if debug_visualizer:
		print("[HDV|%s] _ready()" % name)
	_resolve_ship_controller()
	_resolve_animation_player()
	call_deferred("_initialize")


func _initialize() -> void:
	if _initialized:
		return
	_initialized = true

	_discover_meshes_recursive(self)
	_register_death_animation()

	if debug_visualizer:
		var sname: String = _ship_ctrl.name if _ship_ctrl else "—"
		print("[HDV|%s] ready | ship='%s' | entries=%d | anim=%s" % [
			name, sname, _entries.size(),
			_anim_player.name if _anim_player else "—"
		])
		for e in _entries:
			print("  • '%s' surface_%d → mat_id=%d" % [
				e.mesh_instance.name, e.surface_index, e.material.get_instance_id()
			])

	## Signal-Verbindung zum ShipController (falls noch nicht verbunden)
	#if _ship_ctrl and _ship_ctrl.has_signal("ship_destroyed"):
		#if not _ship_ctrl.ship_destroyed.is_connected(_on_ship_destroyed):
			#_ship_ctrl.ship_destroyed.connect(_on_ship_destroyed)


func _on_ship_destroyed() -> void:
	start_death_sequence()


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS
# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	# Editor-Vorschau
	if Engine.is_editor_hint():
		if damage_parameters:
			if _entries.is_empty():
				_initialize()
			_update_shader_parameters()
		return

	# Während der Todessequenz übernimmt der AnimationPlayer
	if _death_active:
		return

	if _entries.is_empty() or not _ship_ctrl:
		return

	if update_interval > 0.0:
		_accum_time += delta
		if _accum_time < update_interval:
			return
		_accum_time = 0.0

	_update_shader_parameters()


# ─────────────────────────────────────────────────────────────────────────────
# AUFLÖSUNGEN
# ─────────────────────────────────────────────────────────────────────────────
func _resolve_ship_controller() -> void:
	if not ship_controller_path.is_empty():
		_ship_ctrl = get_node_or_null(ship_controller_path)
		if _ship_ctrl:
			return

	var n: Node = get_parent()
	while n:
		if n.has_method("get_hull_integrity"):
			_ship_ctrl = n
			if debug_visualizer:
				print("[HDV|%s] ship_ctrl: '%s'" % [name, n.name])
			return
		n = n.get_parent()

	push_warning("[HDV|%s] Kein ShipController mit get_hull_integrity() gefunden." % name)


func _resolve_animation_player() -> void:
	if not animation_player_path.is_empty():
		var node := get_node_or_null(animation_player_path)
		if node is AnimationPlayer:
			_anim_player = node as AnimationPlayer
			if debug_visualizer:
				print("[HDV|%s] AnimationPlayer: '%s'" % [name, _anim_player.name])
			return

	# Fallback: Geschwister suchen
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child is AnimationPlayer:
				_anim_player = child as AnimationPlayer
				if debug_visualizer:
					print("[HDV|%s] AnimationPlayer (fallback): '%s'" % [name, _anim_player.name])
				return

	push_warning("[HDV|%s] Kein AnimationPlayer gefunden." % name)


func _register_death_animation() -> void:
	if not _anim_player or not death_animation:
		return

	var lib: AnimationLibrary
	if _anim_player.has_animation_library(""):
		lib = _anim_player.get_animation_library("")
	else:
		lib = AnimationLibrary.new()
		_anim_player.add_animation_library("", lib)

	if lib.has_animation(death_animation_name):
		lib.remove_animation(death_animation_name)
	lib.add_animation(death_animation_name, death_animation)


# ─────────────────────────────────────────────────────────────────────────────
# MESH-DISCOVERY
# ─────────────────────────────────────────────────────────────────────────────
func _discover_meshes_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		_process_mesh_instance(node as MeshInstance3D)
	for child in node.get_children():
		_discover_meshes_recursive(child)


func _process_mesh_instance(mi: MeshInstance3D) -> void:
	if not mi.mesh:
		return

	for i in range(mi.mesh.get_surface_count()):
		var src_mat: Material = _get_surface_material_robust(mi, i)
		if not src_mat or not src_mat is ShaderMaterial:
			continue

		var sm: ShaderMaterial = src_mat as ShaderMaterial

		if damage_shader and sm.shader != damage_shader:
			continue

		if not _has_damage_parameter(sm):
			continue

		var cloned: ShaderMaterial = sm.duplicate() as ShaderMaterial
		mi.set_surface_override_material(i, cloned)
		cloned.set_shader_parameter("damage_amount", 0.0)

		var entry := _MaterialEntry.new()
		entry.mesh_instance = mi
		entry.surface_index = i
		entry.material = cloned
		_entries.append(entry)

		if debug_visualizer:
			print("[HDV|%s]   ✓ '%s' surface_%d cloned" % [name, mi.name, i])


func _get_surface_material_robust(mi: MeshInstance3D, idx: int) -> Material:
	var m: Material = mi.get_surface_override_material(idx)
	if m:
		return m
	if mi.mesh and idx < mi.mesh.get_surface_count():
		m = mi.mesh.surface_get_material(idx)
		if m:
			return m
	return mi.material_override


func _has_damage_parameter(sm: ShaderMaterial) -> bool:
	if not sm.shader:
		return false
	for u in sm.shader.get_shader_uniform_list():
		if u.name == "damage_amount":
			return true
	return false


# ─────────────────────────────────────────────────────────────────────────────
# CORE-LOGIK: HP + RESOURCE → SHADER
# ─────────────────────────────────────────────────────────────────────────────
func _update_shader_parameters() -> void:
	if _death_active:
		return

	if not damage_parameters:
		return

	# 1. Schadenswert aus HP berechnen
	var final_damage_amount: float = 0.0
	if Engine.is_editor_hint():
		final_damage_amount = damage_parameters.damage_amount
	else:
		if _ship_ctrl:
			# Aktueller Hüllenzustand (1.0 = gesund, 0.0 = zerstört)
			var integrity: float = float(_ship_ctrl.get_hull_integrity())
			# Umrechnen in Schaden (0.0 = gesund, 1.0 = zerstört)
			var hull_damage_ratio: float = clamp(1.0 - integrity, 0.0, 1.0)
			
			# Prüfung: Ist der Schaden über dem Schwellenwert (z.B. 0.5)?
			if hull_damage_ratio >= damage_start_threshold:
				# Berechne den Fortschritt innerhalb des aktiven Bereichs (z.B. von 0.5 bis 1.0)
				var range_width = 1.0 - damage_start_threshold
				var local_ratio = (hull_damage_ratio - damage_start_threshold) / max(range_width, 0.001)
				
				# Kurve anwenden (Exponential für dramatischeren Schaden am Ende)
				var curved_ratio = pow(local_ratio, damage_curve_exponent)
				
				# Mappen auf [damage_min_visual bis damage_visual_cap]
				final_damage_amount = lerp(damage_min_visual, damage_visual_cap, curved_ratio)
			else:
				# Schiff ist noch zu gesund -> kein sichtbarer Schaden
				final_damage_amount = 0.0

	# 2. Dynamisches Pulse-Scaling
	var dyn_pulse_speed: float = damage_parameters.pulse_speed_hz
	var dyn_flicker: float     = damage_parameters.pulse_flicker_amount
	var dyn_amplitude: float   = damage_parameters.pulse_amplitude

	if enable_dynamic_pulse:
		var t: float = clamp(final_damage_amount / max(damage_visual_cap, 0.001), 0.0, 1.0)
		dyn_pulse_speed = lerp(pulse_speed_min, pulse_speed_max, t)
		dyn_flicker     = lerp(pulse_flicker_min, pulse_flicker_max, t)
		dyn_amplitude   = lerp(pulse_amplitude_min, pulse_amplitude_max, t)

	# 3. Parameter auf alle gefundenen Materialien schreiben
	for entry in _entries:
		var mat: ShaderMaterial = entry.material
		if not is_instance_valid(mat):
			continue

		# Core
		mat.set_shader_parameter("damage_amount",        final_damage_amount)
		mat.set_shader_parameter("cloak_alpha",          damage_parameters.cloak_alpha)
		mat.set_shader_parameter("damage_threshold",     damage_parameters.damage_threshold)
		mat.set_shader_parameter("damage_edge_softness", damage_parameters.damage_edge_softness)
		mat.set_shader_parameter("damage_noise_scale",   damage_parameters.damage_noise_scale)

		# Burn Colors
		mat.set_shader_parameter("burn_color_dark",         damage_parameters.burn_color_dark)
		mat.set_shader_parameter("burn_color_char",         damage_parameters.burn_color_char)
		mat.set_shader_parameter("burn_color_glow",         damage_parameters.burn_color_glow)
		mat.set_shader_parameter("burn_color_molten_outer", damage_parameters.burn_color_molten)
		mat.set_shader_parameter("burn_color_molten_inner", damage_parameters.burn_color_molten_core)

		# Molten & Effects
		mat.set_shader_parameter("burn_glow_energy",       damage_parameters.burn_glow_energy)
		mat.set_shader_parameter("burn_molten_energy",     damage_parameters.burn_molten_energy)
		mat.set_shader_parameter("damage_roughness_boost", damage_parameters.damage_roughness_boost)
		mat.set_shader_parameter("damage_normal_disturb",  damage_parameters.damage_normal_disturb)

		# Cracks
		mat.set_shader_parameter("crack_amount",         damage_parameters.crack_amount)
		mat.set_shader_parameter("crack_scale",          damage_parameters.crack_scale)
		mat.set_shader_parameter("crack_width",          damage_parameters.crack_width)
		mat.set_shader_parameter("crack_glow_intensity", damage_parameters.crack_glow_intensity)

		# Phaser-Schneise
		mat.set_shader_parameter("phaser_amount",        damage_parameters.streak_amount)
		mat.set_shader_parameter("phaser_direction",     damage_parameters.streak_direction)
		mat.set_shader_parameter("phaser_length",        damage_parameters.streak_stretch)
		mat.set_shader_parameter("phaser_width",         damage_parameters.streak_scale * 0.05)
		mat.set_shader_parameter("phaser_edge_softness", damage_parameters.streak_threshold)

		# Crater Rim
		mat.set_shader_parameter("rim_width",       damage_parameters.rim_width)
		mat.set_shader_parameter("rim_glow_energy", damage_parameters.rim_glow_energy)

		# Heat Pulse (dynamisch)
		mat.set_shader_parameter("pulse_amplitude",      dyn_amplitude)
		mat.set_shader_parameter("pulse_speed_hz",       dyn_pulse_speed)
		mat.set_shader_parameter("pulse_async_amount",   damage_parameters.pulse_async_amount)
		mat.set_shader_parameter("pulse_flicker_amount", dyn_flicker)

		# Inner Hull Pipes
		mat.set_shader_parameter("inner_hull_amount",               damage_parameters.inner_hull_amount)
		mat.set_shader_parameter("inner_hull_threshold",            damage_parameters.inner_hull_threshold)
		mat.set_shader_parameter("inner_hull_darkness",             damage_parameters.inner_hull_darkness)
		mat.set_shader_parameter("inner_grid_scale",                damage_parameters.inner_grid_scale)
		mat.set_shader_parameter("inner_pipe_thickness",            damage_parameters.inner_pipe_thickness)
		mat.set_shader_parameter("inner_pipe_orientation",          damage_parameters.inner_pipe_orientation)
		mat.set_shader_parameter("inner_pipe_color",                damage_parameters.inner_pipe_color)
		mat.set_shader_parameter("inner_pipe_glow_color",           damage_parameters.inner_pipe_glow_color)
		mat.set_shader_parameter("inner_pipe_glow_energy",          damage_parameters.inner_pipe_glow_energy)
		mat.set_shader_parameter("inner_parallax_depth",            damage_parameters.inner_parallax_depth)
		mat.set_shader_parameter("inner_grid_flicker_independence",
								 damage_parameters.inner_grid_flicker_independence)

	if not Engine.is_editor_hint() and debug_visualizer \
			and abs(final_damage_amount - _last_damage_log) > 0.05:
		_last_damage_log = final_damage_amount
		print("[HDV|%s] damage_amount=%.3f" % [name, final_damage_amount])


# ─────────────────────────────────────────────────────────────────────────────
# DEATH SEQUENCE
# ─────────────────────────────────────────────────────────────────────────────

func start_death_sequence() -> void:
	if _death_active:
		return

	# Sofort einfrieren — kein weiterer _process()-Frame schreibt mehr in den Shader
	_death_active = true
	set_process(false)

	if debug_visualizer:
		print("[HDV|%s] start_death_sequence() | anim=%s | has_anim=%s" % [
			name,
			_anim_player.name if _anim_player else "—",
			str(death_animation != null)
		])

	if not _anim_player or not death_animation:
		if debug_visualizer:
			print("[HDV|%s] Kein AnimationPlayer oder keine Animation — Sequenz ohne Anim." % name)
		death_sequence_finished.emit()
		return

	if not _anim_player.animation_finished.is_connected(_on_death_animation_finished):
		_anim_player.animation_finished.connect(_on_death_animation_finished, CONNECT_ONE_SHOT)

	_anim_player.play(death_animation_name)


func _on_death_animation_finished(anim_name: String) -> void:
	if anim_name != death_animation_name:
		return
	if debug_visualizer:
		print("[HDV|%s] Todesanimation beendet." % name)
	death_sequence_finished.emit()


# ─────────────────────────────────────────────────────────────────────────────
# ÖFFENTLICHE API
# ─────────────────────────────────────────────────────────────────────────────
func force_update() -> void:
	_accum_time = 999.0
	if not _entries.is_empty() and _ship_ctrl:
		_update_shader_parameters()


func set_damage_amount_override(value: float) -> void:
	for entry in _entries:
		if is_instance_valid(entry.material):
			entry.material.set_shader_parameter("damage_amount",
												clamp(value, 0.0, damage_visual_cap))


func reset_visual() -> void:
	_death_active = false
	set_process(true)
	for entry in _entries:
		if is_instance_valid(entry.material):
			entry.material.set_shader_parameter("damage_amount", 0.0)


func force_rebuild() -> void:
	_entries.clear()
	_initialized = false
	_initialize()
