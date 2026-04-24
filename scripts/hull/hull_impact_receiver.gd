# res://scripts/hull_impact_receiver.gd
# Overlay-Ansatz: erzeugt ein transparentes Kopie-Mesh über dem Original.
# Das Original-Material bleibt 100% unberührt.

extends Node
class_name HullImpactReceiver

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export_group("Meshes")
@export var mesh_instances: Array[MeshInstance3D] = []

@export_group("Active Glow – Zonen")
@export var glow_lifetime:             float = 4.0
@export var fade_duration:             float = 1.2
@export_range(0, 4)   var persistent_impact_count:      int   = 1
@export_range(0.0, 1.0) var persistent_min_intensity:   float = 0.4
@export var impact_radius_factor:      float = 1.0
@export var impact_radius:             float = 25.0
@export var scorch_ring_color:         Color = Color(0.0,  0.0,  0.0)
@export var ember_color:               Color = Color(0.9,  0.15, 0.02)
@export var ember_hot_color:           Color = Color(1.0,  0.55, 0.05)
@export var center_color:              Color = Color(1.0,  0.95, 0.6)

@export_group("Active Glow – Zonengrenzen")
@export_range(0.0, 1.0) var zone_scorch_end: float = 0.85
@export_range(0.0, 1.0) var zone_ember_end:  float = 0.65
@export_range(0.0, 1.0) var zone_hot_end:    float = 0.30
@export_range(0.0, 1.0) var zone_center_end: float = 0.10

@export_group("Active Glow – Emission")
@export var emission_ember:  float = 2.5
@export var emission_hot:    float = 5.0
@export var emission_center: float = 10.0

@export_group("Active Glow – Pulsieren")
@export var pulse_speed:                       float = 2.5
@export_range(0.0, 1.0) var pulse_intensity:   float = 0.35
@export var pulse_speed2:                      float = 5.7
@export_range(0.0, 0.5) var pulse_intensity2:  float = 0.15

@export_group("Cracks / Risse")
@export_range(0, 16) var crack_count_min:        int   = 3
@export_range(0, 16) var crack_count_max:        int   = 6
@export var crack_length_min:                    float = 0.8
@export var crack_length_max:                    float = 1.4
@export var crack_width:                         float = 0.06
@export_range(0.0, 1.0) var crack_irregularity:  float = 0.45
@export_range(0.0, 1.0) var crack_depth:         float = 0.85
@export var crack_glow_intensity:                float = 0.8
@export var crack_glow_color:                    Color = Color(1.0, 0.3, 0.05)

@export_group("Persistent Scorch")
@export var scorch_radius:                       float = 8.0
@export var scorch_build_rate:                   float = 0.4
@export var scorch_merge_radius:                 float = 6.0
@export_range(0.0, 1.0) var scorch_max_opacity:  float = 0.6
@export_range(0.0, 1.0) var scorch_edge_softness: float = 0.8
@export var scorch_color:                        Color = Color(0.0, 0.0, 0.0)

@export_group("Debug")
@export var debug_impacts: bool = false
@export var debug_decals:  bool = false

@export_group("Decals – Schadenszustand")
## Texturen in Reihenfolge der Schwellenwerte.
@export var decal_textures:         Array[Texture2D] = []
## HP-Schwellenwerte (0.0–1.0) absteigend. Beispiel: [0.8, 0.7, 0.6, 0.5]
@export var damage_thresholds:      Array[float]     = [0.8, 0.7, 0.6, 0.5, 0.4, 0.3]
## Anzahl Decals pro Schwellenwert.
@export var decal_counts:           Array[int]       = [1, 1, 1, 1, 1, 1]
## Min-Größenfaktor pro Gruppe (leer = globaler Fallback).
@export var decal_size_factors_min: Array[float]     = []
## Max-Größenfaktor pro Gruppe (leer = globaler Fallback).
@export var decal_size_factors_max: Array[float]     = []
## Globaler Min-Größenfaktor (Fallback wenn decal_size_factors_min leer).
@export var decal_size_factor_min:  float = 0.8
## Globaler Max-Größenfaktor (Fallback wenn decal_size_factors_max leer).
@export var decal_size_factor_max:  float = 2.0
## Projektionstiefe relativ zur Breite.
@export var decal_depth_factor:     float = 0.6
## Render-Layer des Schiffs-Meshes.
@export_flags_3d_render var decal_cull_mask: int = 1

@export_group("Decals – Pulsieren")
@export var decal_pulse_enabled:        bool  = true
@export var decal_pulse_speed:          float = 1.2
## Basis-Helligkeit (1.0 = normal). Alpha bleibt immer 1.0.
@export var decal_pulse_brightness_min: float = 1.0
## Overdrive-Helligkeit (>1.0 = leuchtet auf).
@export var decal_pulse_brightness_max: float = 2.2

@export_group("Feuer & Rauch – Schadenszustand")
## Name des Model-Nodes (Kind des ShipControllers).
## Feuer-Anchors hängen hier — folgen automatisch Rotation + Position.
@export var fire_model_node: String = "Model"
## Alle Feuer-Szenen (VFX_Fire_1 bis VFX_Fire_5).
## Pro Ereignis wird zufällig eine gewählt.
@export var fire_scenes:     Array[PackedScene] = []
## Eine Rauch-Szene — wird zu jedem Feuer-Anchor hinzugefügt.
@export var smoke_scene:     PackedScene
## HP-Schwellenwerte (0.0–1.0) absteigend bei denen Feuer spawnt.
@export var fire_thresholds: Array[float]       = [0.5, 0.4, 0.3, 0.2, 0.1]
## Anzahl Feuer+Rauch-Paare pro Schwellenwert.
@export var fire_counts:     Array[int]         = [1,   1,   1,   1,   1  ]
## Versatz entlang der inversen Normalen → drückt Feuer in die Hülle hinein.
## Faktor zu impact_radius. 0.5 = halber impact_radius nach innen.
@export_range(0.0, 3.0) var fire_inset:      float = 0.8
## Versatz entlang der lokalen Oben-Achse des Schiffs (nicht Welt-Y!).
## Schiebt alle Feuer-Effekte zur Schiffsoberseite hin.
## Faktor zu impact_radius. 0 = kein Versatz, 1.0 = ein impact_radius nach oben.
@export_range(0.0, 5.0) var fire_top_offset: float = 1.5
## Streuungsradius (Faktor zu impact_radius) für Feuer-Platzierung.
@export_range(0.0, 3.0) var fire_scatter:   float = 0.5
## Zufällige Skalierung der Fire-Anchors. 1.0 = Originalgrößee der Szene.
@export var fire_scale_min:  float = 0.8
@export var fire_scale_max:  float = 2.0
## Bias-Stärke zur Oberseite (0.0 = kein Bias, 1.0 = nur Oberseite).
## Die Normale wird mit (0,1,0) gemischt → Feuer bevorzugt die Oberseite des Schiffs.
@export_range(0.0, 1.0) var fire_top_bias: float = 0.6
## Debug: ausführliche Logs für Feuer-System.
@export var debug_fire: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# KONSTANTEN
# ─────────────────────────────────────────────────────────────────────────────
const SHADER_PATH       := "res://shader/hull_impact.gdshader"
const MAX_GLOW_SLOTS    := 4
const MAX_SCORCH_SLOTS  := 8
const HIT_BUFFER_SIZE   := 16
const HP_CHECK_INTERVAL := 0.2


# ─────────────────────────────────────────────────────────────────────────────
# RUNTIME VARIABLEN
# ─────────────────────────────────────────────────────────────────────────────
var _overlays:    Array[MeshInstance3D] = []
var _materials:   Array[ShaderMaterial] = []
var _glow_slots:  Array = []
var _scorch_slots: Array = []

# Trefferpositions-Buffer (Platzierungsgrundlage für Decals + Feuer)
# _hit_pos_buffer: nur Hüllen-Treffer mit valider Normale (für Decal-Ausrichtung)
var _hit_pos_buffer:  Array[Vector3] = []
var _hit_norm_buffer: Array[Vector3] = []
var _hit_buf_idx:     int            = 0
# _all_hit_buffer: ALLE Treffer inkl. Schild-Hits (für Positionierung wenn Normal fehlt)
var _all_hit_buffer:  Array[Vector3] = []
var _all_hit_idx:     int            = 0

# HP-Tracking
var _ship_controller: Node  = null
var _last_hull_ratio: float = 1.0
var _hp_check_timer:  float = 0.0

# Decal-System: _damage_decals[i] = Array[Decal]
var _damage_decals: Array  = []
var _decal_parent:  Node3D
var _pulse_time:    float  = 0.0

# Feuer-System: _fire_anchors[i] = Array[Node3D]
var _fire_anchors: Array  = []
var _fire_model:   Node3D = null


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	for i in MAX_GLOW_SLOTS:
		_glow_slots.append({"pos": Vector3.ZERO, "intensity": 0.0,
							"timer": 0.0, "fading": false, "age": 0.0})
	for i in MAX_SCORCH_SLOTS:
		_scorch_slots.append({"pos": Vector3.ZERO, "intensity": 0.0, "age": 0.0})

	if mesh_instances.is_empty():
		var node: Node = get_parent()
		while node:
			if node is MeshInstance3D:
				mesh_instances.append(node as MeshInstance3D)
				break
			node = node.get_parent()

	_create_overlays()
	_find_ship_controller()
	_init_decal_pool()
	_init_fire_system()


# ─────────────────────────────────────────────────────────────────────────────
# OVERLAY-MESH
# ─────────────────────────────────────────────────────────────────────────────
func _create_overlays() -> void:
	if mesh_instances.is_empty():
		push_error("[HIR '%s'] Keine MeshInstance3D zugewiesen!" % name)
		return
	var shader: Shader = load(SHADER_PATH)
	if not shader:
		push_error("[HIR] Shader nicht gefunden: %s" % SHADER_PATH)
		return

	for mi in mesh_instances:
		if not mi or not mi.mesh:
			continue
		var overlay := MeshInstance3D.new()
		overlay.name        = mi.name + "_ImpactOverlay"
		overlay.mesh        = mi.mesh
		overlay.skeleton    = mi.skeleton
		overlay.skin        = mi.skin
		overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.get_parent().add_child(overlay)
		overlay.global_transform = mi.global_transform

		var mat := ShaderMaterial.new()
		mat.shader          = shader
		mat.render_priority = 1
		_apply_params(mat)
		for i in mi.mesh.get_surface_count():
			overlay.set_surface_override_material(i, mat)

		_overlays.append(overlay)
		_materials.append(mat)
		print("[HIR '%s'] Overlay erstellt für '%s'" % [name, mi.name])

	if not mesh_instances.is_empty():
		var mesh_r    := _get_mesh_radius(mesh_instances[0])
		impact_radius  = mesh_r * 0.15 * impact_radius_factor
		scorch_radius  = impact_radius * 0.3
		for mat in _materials:
			mat.set_shader_parameter("impact_radius", impact_radius)
			mat.set_shader_parameter("scorch_radius", scorch_radius)
		print("[HIR '%s'] Auto-Radius: impact=%.1f scorch=%.1f (mesh_r=%.1f | factor=%.2f)" % [
			name, impact_radius, scorch_radius, mesh_r, impact_radius_factor])

	_flush_glows()
	_flush_scorch()
	print("[HIR '%s'] %d Overlay(s) bereit" % [name, _overlays.size()])


func _apply_params(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("impact_radius",        impact_radius)
	mat.set_shader_parameter("scorch_ring_color",    scorch_ring_color)
	mat.set_shader_parameter("ember_color",          ember_color)
	mat.set_shader_parameter("ember_hot_color",      ember_hot_color)
	mat.set_shader_parameter("center_color",         center_color)
	mat.set_shader_parameter("zone_scorch_end",      zone_scorch_end)
	mat.set_shader_parameter("zone_ember_end",       zone_ember_end)
	mat.set_shader_parameter("zone_hot_end",         zone_hot_end)
	mat.set_shader_parameter("zone_center_end",      zone_center_end)
	mat.set_shader_parameter("emission_ember",       emission_ember)
	mat.set_shader_parameter("emission_hot",         emission_hot)
	mat.set_shader_parameter("emission_center",      emission_center)
	mat.set_shader_parameter("pulse_speed",          pulse_speed)
	mat.set_shader_parameter("pulse_intensity",      pulse_intensity)
	mat.set_shader_parameter("pulse_speed2",         pulse_speed2)
	mat.set_shader_parameter("pulse_intensity2",     pulse_intensity2)
	mat.set_shader_parameter("crack_count_min",      crack_count_min)
	mat.set_shader_parameter("crack_count_max",      crack_count_max)
	mat.set_shader_parameter("crack_length_min",     crack_length_min)
	mat.set_shader_parameter("crack_length_max",     crack_length_max)
	mat.set_shader_parameter("crack_width",          crack_width)
	mat.set_shader_parameter("crack_irregularity",   crack_irregularity)
	mat.set_shader_parameter("crack_depth",          crack_depth)
	mat.set_shader_parameter("crack_glow_intensity", crack_glow_intensity)
	mat.set_shader_parameter("crack_glow_color",     crack_glow_color)
	mat.set_shader_parameter("scorch_radius",        scorch_radius)
	mat.set_shader_parameter("scorch_max_opacity",   scorch_max_opacity)
	mat.set_shader_parameter("scorch_edge_softness", scorch_edge_softness)
	mat.set_shader_parameter("scorch_color",         scorch_color)


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────
func register_impact(world_pos: Vector3, surface_normal: Vector3 = Vector3.ZERO) -> void:
	if _materials.is_empty():
		return
	var primary := mesh_instances[0] if not mesh_instances.is_empty() else null
	if not primary:
		return
	var local_pos := primary.to_local(world_pos)
	_add_glow(local_pos)
	_add_scorch(local_pos)

	# WICHTIG: Positionen im LOKALEN Raum des Meshes speichern!
	# World-Positionen werden veraltet wenn das Schiff sich bewegt →
	# Feuer/Decals würden an der alten Position im Weltraum spawnen.
	# Lokale Positionen bleiben immer relativ zum Schiff korrekt.
	if _all_hit_buffer.size() < HIT_BUFFER_SIZE:
		_all_hit_buffer.append(local_pos)
	else:
		_all_hit_buffer[_all_hit_idx] = local_pos
		_all_hit_idx = (_all_hit_idx + 1) % HIT_BUFFER_SIZE

	# Hüllen-Treffer: Normale in lokalem Raum transformieren
	if surface_normal.length_squared() > 0.01:
		var local_norm := primary.global_transform.basis.inverse() * surface_normal
		local_norm = local_norm.normalized()
		if _hit_pos_buffer.size() < HIT_BUFFER_SIZE:
			_hit_pos_buffer.append(local_pos)
			_hit_norm_buffer.append(local_norm)
		else:
			_hit_pos_buffer[_hit_buf_idx]  = local_pos
			_hit_norm_buffer[_hit_buf_idx] = local_norm
			_hit_buf_idx = (_hit_buf_idx + 1) % HIT_BUFFER_SIZE

	if debug_impacts:
		print("[HIR] Treffer | local=%s | normal=%s" % [
			local_pos.snappedf(0.2), surface_normal.snappedf(0.01)])


# ─────────────────────────────────────────────────────────────────────────────
# SHIP CONTROLLER
# ─────────────────────────────────────────────────────────────────────────────
func _find_ship_controller() -> void:
	var node: Node = get_parent()
	while node:
		if node.get("hull_hp") != null:
			_ship_controller = node
			return
		node = node.get_parent()


func _get_hull_ratio() -> float:
	if not is_instance_valid(_ship_controller):
		return 1.0
	var current = _ship_controller.get("hull_hp")
	var maximum = _ship_controller.get("max_hull_hp")
	if current == null or maximum == null or float(maximum) <= 0.0:
		return 1.0
	return clampf(float(current) / float(maximum), 0.0, 1.0)


# ─────────────────────────────────────────────────────────────────────────────
# DECAL-SYSTEM
# ─────────────────────────────────────────────────────────────────────────────
func _init_decal_pool() -> void:
	if decal_textures.is_empty():
		if debug_decals:
			push_warning("[HIR '%s'] decal_textures leer – keine Damage-Decals." % name)
		return

	# DecalPool muss unter einem Node3D hängen der GARANTIERT mit dem Schiff mitbewegt wird.
	#
	# PROBLEM mit mesh_instances[0].get_parent() (MeshModel):
	# Bei manchen Schiffsmodellen (z.B. Blender-Import mit verschachtelten Sub-Nodes)
	# kann MeshModel ein eigenes Transform-Verhalten haben (z.B. top_level=true oder
	# Import-Scale) das dazu führt, dass Kinder nicht korrekt dem CharacterBody3D folgen.
	#
	# LÖSUNG: Exakt denselben Anker-Node verwenden wie das Feuer-System (fire_model_node = "Model").
	# Dieser Node ist nachweislich korrekt mit dem Schiff verbunden (Feuer folgt dem Schiff).
	# Fallback: mesh_parent, dann ShipController-Parent.
	var decal_anchor: Node3D = null
	var anchor_name: String  = "?"

	# 1. Priorität: fire_model_node ("Model") – identisch mit Feuer-Anker
	if is_instance_valid(_ship_controller) and fire_model_node != "":
		var found := _ship_controller.find_child(fire_model_node, true, false)
		if found is Node3D:
			decal_anchor = found as Node3D
			anchor_name  = found.name
			if debug_decals:
				print("[DECAL] Anker via fire_model_node='%s' gefunden" % anchor_name)

	# 2. Fallback: ShipController-Parent (CharacterBody3D / Ship-Root)
	if not is_instance_valid(decal_anchor) and is_instance_valid(_ship_controller):
		var sc_parent := _ship_controller.get_parent()
		if sc_parent is Node3D:
			decal_anchor = sc_parent as Node3D
			anchor_name  = sc_parent.name
			if debug_decals:
				print("[DECAL] Anker via ShipController-Parent='%s' (Fallback)" % anchor_name)

	# 3. Letzter Fallback: mesh_parent (alter Ansatz, kann bei manchen Modellen driften)
	if not is_instance_valid(decal_anchor):
		if not mesh_instances.is_empty() and is_instance_valid(mesh_instances[0]):
			decal_anchor = mesh_instances[0].get_parent() as Node3D
			anchor_name  = decal_anchor.name if is_instance_valid(decal_anchor) else "?"
			if debug_decals:
				print("[DECAL] Anker via mesh_parent='%s' (letzter Fallback)" % anchor_name)

	if not is_instance_valid(decal_anchor):
		push_error("[HIR '%s'] Kein gültiger Node3D-Anker für DecalPool gefunden!" % name)
		return

	_decal_parent      = Node3D.new()
	_decal_parent.name = "DecalPool"
	decal_anchor.add_child(_decal_parent)

	print("[DECAL] Pool eingehängt | hir='%s' | anker='%s' (%s)" % [
		name, anchor_name, decal_anchor.get_class()])

	var count := mini(decal_textures.size(), damage_thresholds.size())
	for i in count:
		var n: int = maxi(decal_counts[i] if i < decal_counts.size() else 1, 1)
		var group: Array[Decal] = []
		for _j in n:
			var d := Decal.new()
			d.visible        = false
			d.upper_fade     = 0.2
			d.lower_fade     = 0.2
			d.albedo_mix     = 1.0
			d.cull_mask      = decal_cull_mask
			d.texture_albedo = decal_textures[i]
			_decal_parent.add_child(d)
			group.append(d)
		_damage_decals.append(group)

	var total: int = 0
	for g in _damage_decals:
		total += (g as Array).size()
	print("[HIR '%s'] DecalPool bereit | gruppen=%d | gesamt=%d Nodes | anker='%s'" % [
		name, _damage_decals.size(), total, anchor_name])


func _check_decal_thresholds(hull_ratio: float) -> void:
	for i in _damage_decals.size():
		var group: Array   = _damage_decals[i]
		if group.is_empty():
			continue
		var threshold: float   = damage_thresholds[i] if i < damage_thresholds.size() else 0.0
		var should_show: bool  = hull_ratio <= threshold
		var currently_on: bool = (group[0] as Decal).visible

		if debug_decals:
			print("[DECAL] Check i=%d | threshold=%.2f | hull=%.2f | should_show=%s | visible=%s" % [
				i, threshold, hull_ratio, should_show, currently_on])

		if should_show and not currently_on:
			for j in group.size():
				_place_damage_decal(group[j] as Decal, i)
		elif not should_show and currently_on:
			for d in group:
				(d as Decal).visible = false


## Gibt eine Platzierungsposition auf der Schiffsoberfläche zurück (World-Space).
## Buffers enthalten LOKALE Positionen → hier mit aktuellem Mesh-Transform in World-Space konvertieren.
## Das stellt sicher dass Feuer/Decals immer am aktuellen Schiffsort spawnen, auch wenn das Schiff bewegt hat.
func _get_placement_pos(top_bias: float = 0.0) -> Array:
	var primary: MeshInstance3D = mesh_instances[0] if not mesh_instances.is_empty() else null
	var ship_center: Vector3    = primary.global_position if primary \
		else (_ship_controller as Node3D).global_position if is_instance_valid(_ship_controller) \
		else Vector3.ZERO

	var pos:  Vector3
	var norm: Vector3

	# Beste Option: Hüllen-Treffer mit echter Normale (lokal → Welt)
	if _hit_pos_buffer.size() > 0 and primary:
		var idx    := randi() % _hit_pos_buffer.size()
		# Minimaler Jitter: max 15% des impact_radius → Feuer bleibt am Trefferpunkt
		var jitter := Vector3(randf_range(-1,1), randf_range(-1,1), randf_range(-1,1))
		jitter  = jitter.normalized() * impact_radius * randf_range(0.0, 0.15)
		pos     = primary.to_global(_hit_pos_buffer[idx]) + jitter
		norm    = (primary.global_transform.basis * _hit_norm_buffer[idx]).normalized()

	# Zweit-Option: Schild-Treffer (lokal → Welt), kein Jitter nötig
	elif _all_hit_buffer.size() > 0 and primary:
		var idx    := randi() % _all_hit_buffer.size()
		pos     = primary.to_global(_all_hit_buffer[idx])
		var to_pos := pos - ship_center
		norm    = to_pos.normalized() if to_pos.length_squared() > 0.01 else Vector3.UP

	# Fallback: zufälliger Punkt auf Schiffsoberfläche
	else:
		norm    = Vector3(randf_range(-1,1), randf_range(-0.3,1), randf_range(-1,1)).normalized()
		var mesh_r := impact_radius / 0.15
		pos     = ship_center + norm * mesh_r * 0.8

	# Top-Bias: Normale in Richtung Weltkoordinaten-Y kippen
	if top_bias > 0.0:
		norm = norm.lerp(Vector3.UP, top_bias).normalized()

	return [pos, norm]


func _place_damage_decal(d: Decal, index: int) -> void:
	if not is_instance_valid(_decal_parent):
		return

	var placement  := _get_placement_pos()
	var world_pos:      Vector3 = placement[0]
	var surface_normal: Vector3 = placement[1]

	var s_min: float = decal_size_factors_min[index] if index < decal_size_factors_min.size() \
		else decal_size_factor_min
	var s_max: float = decal_size_factors_max[index] if index < decal_size_factors_max.size() \
		else decal_size_factor_max
	var size: float       = randf_range(impact_radius * s_min, impact_radius * s_max)
	var half_depth: float = size * decal_depth_factor * 0.5

	d.size = Vector3(size, size * decal_depth_factor, size)

	# Zielpunkt in Weltkoordinaten
	var final_world_pos := world_pos + surface_normal * half_depth

	# Welt-Basis aufbauen: Y = Oberflächennormale (Projektionsrichtung des Decals)
	var y_axis := surface_normal.normalized()
	var z_ref  := Vector3.FORWARD if abs(y_axis.dot(Vector3.FORWARD)) < 0.99 else Vector3.RIGHT
	var z_axis := (z_ref - y_axis * z_ref.dot(y_axis)).normalized()
	var x_axis := y_axis.cross(z_axis)
	var world_basis := Basis(x_axis, y_axis, z_axis).rotated(y_axis, randf() * TAU)

	# FIX: Transform ATOMAR im lokalen Raum des DecalPools setzen.
	# Zweistufiges Setzen (global_position, dann global_basis) kann in Godot 4
	# einen inkonsistenten Zustand erzeugen: global_basis liest intern den gerade
	# gesetzten Transform erneut, was bei nicht-propagiertem Parent-Transform zu
	# einer falschen Ortsberechnung führt. Der Decal erhält dann eine Weltposition
	# und verlässt beim Schiffsbewegung seinen Ankerpunkt.
	# Lösung: lokale Position + lokale Basis in einem einzigen Schreibvorgang.
	var parent_gt  := _decal_parent.global_transform
	var local_pos  := parent_gt.affine_inverse() * final_world_pos
	var local_basis := parent_gt.basis.inverse() * world_basis
	d.transform    = Transform3D(local_basis, local_pos)

	d.modulate = Color(1.0, 1.0, 1.0, 1.0)
	d.visible  = true

	if debug_decals:
		print("[DECAL] Platziert | gruppe=%d | HP≤%.0f%% | size=%.1f | world=%s | local=%s | normal=%s | hull_buf=%d | all_buf=%d" % [
			index,
			damage_thresholds[index] * 100.0 if index < damage_thresholds.size() else 0.0,
			size,
			final_world_pos.snappedf(1.0),
			local_pos.snappedf(0.1),
			surface_normal.snappedf(0.01),
			_hit_pos_buffer.size(), _all_hit_buffer.size()])


func clear_damage_decals() -> void:
	for group in _damage_decals:
		for d in (group as Array):
			if is_instance_valid(d):
				(d as Decal).visible = false


# ─────────────────────────────────────────────────────────────────────────────
# FEUER & RAUCH
# ─────────────────────────────────────────────────────────────────────────────
func _init_fire_system() -> void:
	if fire_scenes.is_empty():
		if debug_fire:
			print("[FIRE '%s'] Keine fire_scenes zugewiesen – System deaktiviert." % name)
		return

	if is_instance_valid(_ship_controller):
		var found := _ship_controller.find_child(fire_model_node, true, false)
		if found is Node3D:
			_fire_model = found as Node3D

	if debug_fire:
		print("[FIRE '%s'] _ship_controller=%s | fire_model_node='%s' | _fire_model=%s" % [
			name,
			_ship_controller.name if is_instance_valid(_ship_controller) else "NULL",
			fire_model_node,
			_fire_model.name if is_instance_valid(_fire_model) else "NULL"])

	if not is_instance_valid(_fire_model):
		push_warning("[HIR '%s'] fire_model_node '%s' nicht gefunden – Feuer deaktiviert." % [
			name, fire_model_node])
		return

	var count := mini(fire_thresholds.size(), fire_counts.size())
	for _i in count:
		_fire_anchors.append([])

	print("[HIR '%s'] Fire-System bereit | model='%s' | gruppen=%d" % [
		name, _fire_model.name, count])


func _check_fire_thresholds(hull_ratio: float) -> void:
	if _fire_anchors.is_empty() or not is_instance_valid(_fire_model):
		return
	for i in _fire_anchors.size():
		var threshold: float  = fire_thresholds[i] if i < fire_thresholds.size() else 0.0
		var group: Array      = _fire_anchors[i]
		var should_show: bool = hull_ratio <= threshold

		if debug_fire:
			print("[FIRE] Check i=%d | threshold=%.2f | hull_ratio=%.2f | should_show=%s | group_size=%d" % [
				i, threshold, hull_ratio, should_show, group.size()])

		if should_show and group.is_empty():
			var n: int = fire_counts[i] if i < fire_counts.size() else 1
			for _j in n:
				_spawn_fire_anchor(i)
		elif not should_show and not group.is_empty():
			_clear_fire_group(i)


func _spawn_fire_anchor(group_idx: int) -> void:
	# fire_top_bias: Feuer bevorzugt die Oberseite des Schiffs
	var placement      := _get_placement_pos(fire_top_bias)
	var world_pos:      Vector3 = placement[0]
	var surface_normal: Vector3 = placement[1]

	# fire_scatter: optionaler Versatz entlang der Oberflächen-Normale (nicht zufällige Richtung!)
	# So bleibt das Feuer auf der Hülle aber mit etwas Abstand zum exakten Trefferpunkt.
	if fire_scatter > 0.0 and surface_normal.length_squared() > 0.01:
		var scatter_along := surface_normal * impact_radius * randf_range(0.0, fire_scatter)
		var scatter_tangent := Vector3(randf_range(-1,1), randf_range(-1,1), randf_range(-1,1))
		scatter_tangent = scatter_tangent.normalized()
		scatter_tangent = (scatter_tangent - surface_normal * scatter_tangent.dot(surface_normal)).normalized()
		world_pos += scatter_tangent * impact_radius * fire_scatter * 0.3

	var anchor  := Node3D.new()
	anchor.name  = "FireAnchor_%d_%d" % [group_idx, _fire_anchors[group_idx].size()]
	_fire_model.add_child(anchor)

	# Inset: Position entlang der inversen Normalen ins Schiff drücken.
	if fire_inset > 0.0 and surface_normal.length_squared() > 0.01:
		world_pos -= surface_normal.normalized() * impact_radius * fire_inset

	# Top-Offset: Position entlang der lokalen Oben-Achse des Schiffs verschieben.
	# Nutzt _fire_model.global_transform.basis.y = lokales "Oben" des Schiffs.
	# Dadurch landen Effekte auf der Schiffsoberseite unabhängig von Weltraumorientierung.
	if fire_top_offset > 0.0 and is_instance_valid(_fire_model):
		var ship_up := _fire_model.global_transform.basis.y.normalized()
		world_pos  += ship_up * impact_radius * fire_top_offset

	# Erst add_child(), dann global_* setzen
	anchor.global_position = world_pos

	# Orientierung: +Y zeigt von Hülle weg (mit Top-Bias bereits in surface_normal)
	if surface_normal.length_squared() > 0.01:
		var up    := surface_normal.normalized()
		var right := Vector3.FORWARD if abs(up.dot(Vector3.FORWARD)) < 0.99 else Vector3.RIGHT
		right = (right - up * right.dot(up)).normalized()
		anchor.global_basis = Basis(right, up, right.cross(up))

	# Zufällige Skalierung → Feuer-VFX wirken unterschiedlich groß
	var scale_val := randf_range(fire_scale_min, fire_scale_max)
	anchor.scale   = Vector3.ONE * scale_val

	if fire_scenes.size() > 0:
		var chosen_scene: PackedScene = fire_scenes[randi() % fire_scenes.size()]
		var fire_node := chosen_scene.instantiate()
		fire_node.name = "VFX_Fire"
		anchor.add_child(fire_node)
		if debug_fire:
			print("[FIRE] Gruppe %d | Szene: '%s'" % [group_idx, chosen_scene.resource_path.get_file()])

	if smoke_scene:
		var smoke_node := smoke_scene.instantiate()
		smoke_node.name = "VFX_Smoke"
		anchor.add_child(smoke_node)

	_fire_anchors[group_idx].append(anchor)

	if debug_fire:
		print("[FIRE] Anchor '%s' | world_pos=%s | local_pos=%s | normal=%s | kinder=%d | hull_buf=%d | all_buf=%d" % [
			anchor.name,
			world_pos.snappedf(1.0),
			anchor.position.snappedf(1.0),
			surface_normal.snappedf(0.01),
			anchor.get_child_count(),
			_hit_pos_buffer.size(), _all_hit_buffer.size()])


func _clear_fire_group(group_idx: int) -> void:
	for anchor in _fire_anchors[group_idx]:
		if is_instance_valid(anchor):
			(anchor as Node).queue_free()
	_fire_anchors[group_idx].clear()


## Alle Feuer/Rauch sofort stoppen (Emitter deaktivieren). Bei Schiffstod aufrufen.
func stop_all_fire() -> void:
	for group in _fire_anchors:
		for anchor in (group as Array):
			if is_instance_valid(anchor):
				_stop_particles_recursive(anchor as Node3D)


func _stop_particles_recursive(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = false
	elif node is CPUParticles3D:
		(node as CPUParticles3D).emitting = false
	for child in node.get_children():
		_stop_particles_recursive(child)


func _exit_tree() -> void:
	if is_instance_valid(_decal_parent):
		_decal_parent.queue_free()


# ─────────────────────────────────────────────────────────────────────────────
# GLOW
# ─────────────────────────────────────────────────────────────────────────────
func _add_glow(local_pos: Vector3) -> void:
	for i in MAX_GLOW_SLOTS:
		var s: Dictionary = _glow_slots[i]
		if s["intensity"] > 0.01 and s["pos"].distance_to(local_pos) < impact_radius * 0.4:
			s["intensity"] = 1.0
			s["timer"]     = 0.0
			s["fading"]    = false
			s["age"]       = 0.0
			_flush_glows()
			return

	for i in MAX_GLOW_SLOTS:
		if _glow_slots[i]["intensity"] < 0.001:
			_glow_slots[i] = {"pos": local_pos, "intensity": 1.0,
								"timer": 0.0, "fading": false, "age": 0.0}
			_flush_glows()
			return

	var oldest_idx := 0
	var oldest_age := -1.0
	for i in MAX_GLOW_SLOTS:
		var s: Dictionary = _glow_slots[i]
		if not s["fading"] and s["age"] > oldest_age:
			oldest_age = s["age"]
			oldest_idx = i

	_glow_slots[oldest_idx]["fading"] = true
	_glow_slots[oldest_idx]["timer"]  = 0.0

	var weakest_idx := oldest_idx
	var weakest_int := 2.0
	for i in MAX_GLOW_SLOTS:
		if _glow_slots[i]["fading"] and _glow_slots[i]["intensity"] < weakest_int:
			weakest_int = _glow_slots[i]["intensity"]
			weakest_idx = i
	_glow_slots[weakest_idx] = {"pos": local_pos, "intensity": 1.0,
								"timer": 0.0, "fading": false, "age": 0.0}
	_flush_glows()


func _flush_glows() -> void:
	var arr: Array[Plane] = []
	for i in MAX_GLOW_SLOTS:
		var s: Dictionary = _glow_slots[i]
		arr.append(Plane(s["pos"].x, s["pos"].y, s["pos"].z, s["intensity"]))
	for mat in _materials:
		mat.set_shader_parameter("active_glows", arr)


# ─────────────────────────────────────────────────────────────────────────────
# SCORCH
# ─────────────────────────────────────────────────────────────────────────────
func _add_scorch(local_pos: Vector3) -> void:
	for i in MAX_SCORCH_SLOTS:
		var s: Dictionary = _scorch_slots[i]
		if s["intensity"] > 0.01 and s["pos"].distance_to(local_pos) < scorch_merge_radius:
			s["intensity"] = minf(s["intensity"] + scorch_build_rate, 1.0)
			s["age"]       = 0.0
			_flush_scorch()
			return
	for i in MAX_SCORCH_SLOTS:
		if _scorch_slots[i]["intensity"] < 0.01:
			_scorch_slots[i] = {"pos": local_pos, "intensity": scorch_build_rate, "age": 0.0}
			_flush_scorch()
			return
	var oldest_idx := 0
	var oldest_age := -1.0
	for i in MAX_SCORCH_SLOTS:
		if _scorch_slots[i]["age"] > oldest_age:
			oldest_age = _scorch_slots[i]["age"]
			oldest_idx = i
	_scorch_slots[oldest_idx] = {"pos": local_pos, "intensity": scorch_build_rate, "age": 0.0}
	_flush_scorch()


func _flush_scorch() -> void:
	var arr: Array[Plane] = []
	for i in MAX_SCORCH_SLOTS:
		var s: Dictionary = _scorch_slots[i]
		arr.append(Plane(s["pos"].x, s["pos"].y, s["pos"].z, s["intensity"]))
	for mat in _materials:
		mat.set_shader_parameter("scorch_marks", arr)


func _get_mesh_radius(mi: MeshInstance3D) -> float:
	if not mi or not mi.mesh:
		return impact_radius
	var aabb: AABB = mi.mesh.get_aabb()
	var r := maxf(maxf(aabb.size.x, aabb.size.y), aabb.size.z) * 0.5
	return r if r > 0.1 else impact_radius


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS
# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _materials.is_empty():
		return

	# Scorch-Alter
	for i in MAX_SCORCH_SLOTS:
		if _scorch_slots[i]["intensity"] > 0.01:
			_scorch_slots[i]["age"] += delta

	# Glow-Slots: Alter + Auto-Fade
	for i in MAX_GLOW_SLOTS:
		var s: Dictionary = _glow_slots[i]
		if s["intensity"] > 0.001 and not s["fading"]:
			s["age"] = s.get("age", 0.0) + delta
			if glow_lifetime > 0.0 and s["age"] >= glow_lifetime:
				s["fading"] = true
				s["timer"]  = 0.0

	var any_changed := false
	for i in MAX_GLOW_SLOTS:
		var s: Dictionary = _glow_slots[i]
		if not s["fading"] or s["intensity"] <= 0.001:
			continue
		s["timer"] += delta
		var t: float = clamp(s["timer"] / fade_duration, 0.0, 1.0)
		s["intensity"] = 1.0 - (t * t)
		if s["intensity"] <= 0.001:
			s["intensity"] = 0.0
		any_changed = true
	if any_changed:
		_flush_glows()

	# HP-Schwellenwert-Check (throttled)
	var needs_check: bool = not _damage_decals.is_empty() or not _fire_anchors.is_empty()
	if needs_check:
		_hp_check_timer -= delta
		if _hp_check_timer <= 0.0:
			_hp_check_timer = HP_CHECK_INTERVAL
			var ratio := _get_hull_ratio()
			if abs(ratio - _last_hull_ratio) > 0.001:
				_last_hull_ratio = ratio
				_check_decal_thresholds(ratio)
				_check_fire_thresholds(ratio)

	# Decal-Pulsieren (RGB-Overdrive, Alpha bleibt 1.0)
	if decal_pulse_enabled and not _damage_decals.is_empty():
		_pulse_time += delta
		var t: float      = sin(_pulse_time * decal_pulse_speed) * 0.5 + 0.5
		var bright: float = lerpf(decal_pulse_brightness_min, decal_pulse_brightness_max, t)
		var pulse_color   := Color(bright, bright, bright, 1.0)
		for group in _damage_decals:
			for d in (group as Array):
				if is_instance_valid(d) and (d as Decal).visible:
					(d as Decal).modulate = pulse_color
