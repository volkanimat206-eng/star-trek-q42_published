# res://scripts/shield_system.gd
# Verwaltet Schild-HP, Kollisionslayer und Shader-Laufzeitwerte.
#
# ZUSTÄNDIGKEITEN dieses Scripts:
#   • Schild-HP (via ShieldData): Treffer, Overflow, Regeneration, Kollaps
#   • Schildradius: wird von BeamWeapon3D für Strahl-Kugel-Schnitt genutzt
#   • Shader-Laufzeitwerte: integrity, dissolve_progress, impact_point/time
#
# NICHT zuständig:
#   • Visuelle Shader-Parameter (shield_color, rim_power etc.) → im Inspector setzen
#   • ShaderMaterial erstellen → im Inspector auf ShieldMesh zuweisen
@tool
class_name ShieldSystem
extends Node3D

# ===== SIGNALS =====
signal shield_hit(impact_point: Vector3, damage: float, overflow: float)
signal shield_depleted()
signal shield_recharged()

# ===== EXPORTS =====
@export var data: ShieldData:
	set(value):
		if data and data.changed.is_connected(_on_data_changed):
			data.changed.disconnect(_on_data_changed)
		data = value
		if data and is_node_ready():
			if not data.changed.is_connected(_on_data_changed):
				data.changed.connect(_on_data_changed)
			_find_mesh_node()
			_apply_shield_data_visuals()

@export_group("Geometrie")
## Halbachsen des Schild-Ellipsoids in World Units (lokale Achsen des Schiffs).
## X = rechts/links, Y = oben/unten, Z = vorne/hinten (Längsachse).
## BeamWeapon3D benutzt diese für den Strahl-Ellipsoid-Schnitt – keine CollisionShape nötig.
@export var shield_radius_x: float = 12.0:
	set(v): shield_radius_x = v; _update_ellipsoid_shape()
@export var shield_radius_y: float = 6.0:
	set(v): shield_radius_y = v; _update_ellipsoid_shape()
@export var shield_radius_z: float = 20.0:
	set(v): shield_radius_z = v; _update_ellipsoid_shape()

## Pfad zum ShieldMesh – kann überall im Szenenbaum liegen (z.B. unter Model).
## Leer lassen = ShieldMesh als Kind dieses Nodes suchen (alter Standard).
## NodePath zum Haupt-Rumpf-Mesh für automatische Radiusberechnung.
## Wenn gesetzt: shield_radius_x/y/z werden automatisch aus der Mesh-AABB berechnet.
## Leer lassen = manuelle Werte verwenden.
@export var hull_mesh_path: NodePath = NodePath("")

## Padding-Faktor: Schild ist X% größer als das Rumpf-Mesh (1.08 = 8% größer)
@export_range(1.0, 2.0) var shield_margin_x: float = 1.08
@export_range(1.0, 2.0) var shield_margin_y: float = 1.08
@export_range(1.0, 2.0) var shield_margin_z: float = 1.08

@export var shield_mesh_path: NodePath = NodePath("")

@export_group("Impact-Slots")
## Wie viele gleichzeitige Treffer-Effekte das Schild anzeigen kann (1–8).
## Größere Schiffe können mehr Slots nutzen.
@export_range(1, 8) var max_impact_slots: int = 6:
	set(v):
		max_impact_slots = v
		if _mat:
			_mat.set_shader_parameter("impact_slot_count", v)

@export_group("Debug")
@export var show_debug: bool = false
## Shader Debug-Modus – live im Inspector ändern während das Spiel läuft.
## 0 = Normal (unsichtbar ohne Treffer)
## 1 = ROT    → rendert der Shader überhaupt?
## 2 = GRÜN/ROT → kommen Impact-Parameter an?
## 3 = Helligkeit = Impact-Stärke → wird der Ring berechnet?
## 4 = v_local_pos als RGB → ist das varying korrekt befüllt?
## 5 = Winkel zum Trefferpunkt → stimmt impact_point Position?
@export_range(0, 5) var shader_debug_mode: int = 0:
	set(v):
		shader_debug_mode = v
		if _mat:
			_mat.set_shader_parameter("debug_mode", v)
			print("[ShieldSystem] debug_mode → %d" % v)

# ===== NODE-REFERENZEN =====
var _mesh_instance: MeshInstance3D
var _mat:           ShaderMaterial
var _gizmo_mesh:    MeshInstance3D   # Editor-only Wireframe-Vorschau

# ===== STATE =====
var _recharge_timer:     float = 0.0
var _is_recharging:      bool  = false
var _reactivation_timer: float = 0.0
var _is_dissolved:       bool  = false
var _is_destroyed:       bool  = false
var _dissolve_tween:     Tween = null
var _impact_slot:        int   = 0

# Maximale Slot-Anzahl – muss mit dem Shader-Array übereinstimmen.
const MAX_IMPACT_SLOTS: int = 8

# Alter jedes Slots in Sekunden. 100.0 = inaktiv.
var _impact_ages: Array[float] = [
	100.0, 100.0, 100.0, 100.0,
	100.0, 100.0, 100.0, 100.0
]

var _impact_points: Array[Vector3] = [
	Vector3(0.0, -9999.0, 0.0), Vector3(0.0, -9999.0, 0.0),
	Vector3(0.0, -9999.0, 0.0), Vector3(0.0, -9999.0, 0.0),
	Vector3(0.0, -9999.0, 0.0), Vector3(0.0, -9999.0, 0.0),
	Vector3(0.0, -9999.0, 0.0), Vector3(0.0, -9999.0, 0.0)
]
var _impact_colors: Array[Color] = [
	Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE,
	Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE
]
# 0.0 = Phaser/Disruptor (keine Schockwelle), 1.0 = Torpedo (mit Schockwelle)
var _impact_types: Array[float] = [
	0.0, 0.0, 0.0, 0.0,
	0.0, 0.0, 0.0, 0.0
]


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	# FIX: Expliziter Typ + str() verhindert Variant-Inferenz (StringName vs String)
	var ship_name: String = str(get_parent().name) if get_parent() else "?"
	print("[ShieldSystem|%s] _ready() START" % ship_name)
	print("[ShieldSystem|%s]   hull_mesh_path='%s'" % [ship_name, hull_mesh_path])
	print("[ShieldSystem|%s]   shield_mesh_path='%s'" % [ship_name, shield_mesh_path])
	print("[ShieldSystem|%s]   data=%s" % [ship_name, data])
	_find_mesh_node()
	print("[ShieldSystem|%s]   _mesh_instance nach _find_mesh_node: %s" % [ship_name, _mesh_instance])
	print("[ShieldSystem|%s]   _mat nach _find_mesh_node: %s" % [ship_name, _mat])
	if not Engine.is_editor_hint() and not hull_mesh_path.is_empty():
		print("[ShieldSystem|%s]   → _auto_compute_radii_from_hull() aufrufen..." % ship_name)
		_auto_compute_radii_from_hull()
	else:
		print("[ShieldSystem|%s]   → hull_mesh_path leer oder Editor – manuelle Radien: (%.1f, %.1f, %.1f)" % [ship_name, shield_radius_x, shield_radius_y, shield_radius_z])
	print("[ShieldSystem|%s]   → _update_ellipsoid_shape() aufrufen..." % ship_name)
	_update_ellipsoid_shape()
	print("[ShieldSystem|%s]   ShieldMesh.scale nach update: %s" % [ship_name, _mesh_instance.scale if _mesh_instance else "NULL"])
	print("[ShieldSystem|%s]   ShieldMesh.visible: %s" % [ship_name, _mesh_instance.visible if _mesh_instance else "NULL"])
	print("[ShieldSystem|%s] _ready() END" % ship_name)

	if not data:
		if not Engine.is_editor_hint():
			push_warning("[ShieldSystem] Keine ShieldData zugewiesen.")
		return

	if not data.changed.is_connected(_on_data_changed):
		data.changed.connect(_on_data_changed)

	if Engine.is_editor_hint():
		return

	set_meta("ship_parent",   get_parent())
	set_meta("shield_system", self)
	get_parent().set_meta("shield_system", self)

	_dbg("✅ Bereit | %.0f HP" % data.max_strength)


# ─────────────────────────────────────────────────────────────────────────────
# AUTO-RADIUS – aus Hull-Mesh-AABB berechnen
# ─────────────────────────────────────────────────────────────────────────────

## Berechnet shield_radius_x/y/z automatisch aus der AABB des Rumpf-Meshs.
## WICHTIG: hull.get_aabb() statt hull.mesh.get_aabb() –
## MeshInstance3D.get_aabb() berücksichtigt den Node-Transform inkl. Scale,
## mesh.get_aabb() liefert nur rohe Mesh-Geometrie ohne Node-Skalierung.
func _auto_compute_radii_from_hull() -> void:
	# FIX: Expliziter Typ + str() verhindert Variant-Inferenz
	var ship_name: String = str(get_parent().name) if get_parent() else "?"
	var hull_node: Node = get_node_or_null(hull_mesh_path)
	print("[ShieldSystem|%s]   hull_mesh_path node: %s (type: %s)" % [
		ship_name, hull_node, hull_node.get_class() if hull_node else "NULL"])
	var hull := hull_node as MeshInstance3D
	if not hull or not hull.mesh:
		push_warning("[ShieldSystem] hull_mesh_path '%s' nicht gefunden – manuelle Radien werden verwendet." % hull_mesh_path)
		return

	# FIX: hull.get_aabb() statt hull.mesh.get_aabb()
	# hull.mesh.get_aabb() → Mesh-Geometrie in Mesh-lokalem Raum (ignoriert Node-Scale!)
	# hull.get_aabb()      → AABB in lokalem Raum des MeshInstance3D (inkl. Node-Scale)
	var aabb: AABB = hull.get_aabb()
	shield_radius_x = (aabb.size.x * 0.5) * shield_margin_x
	shield_radius_y = (aabb.size.y * 0.5) * shield_margin_y
	shield_radius_z = (aabb.size.z * 0.5) * shield_margin_z

	_dbg("Auto-Radius aus AABB | hull='%s' | aabb.size=%s → radii=(%.1f, %.1f, %.1f)" % [
		hull.name, aabb.size.snappedf(0.1),
		shield_radius_x, shield_radius_y, shield_radius_z])


# ─────────────────────────────────────────────────────────────────────────────
# ELLIPSOID – ShieldMesh skalieren + Editor-Gizmo
# ─────────────────────────────────────────────────────────────────────────────

func _update_ellipsoid_shape() -> void:
	if not is_node_ready():
		return
	var radii := Vector3(shield_radius_x, shield_radius_y, shield_radius_z)

	if _mesh_instance:
		_mesh_instance.scale = radii

	if Engine.is_editor_hint():
		_update_editor_gizmo(radii)


func _update_editor_gizmo(radii: Vector3) -> void:
	if _gizmo_mesh and is_instance_valid(_gizmo_mesh):
		_gizmo_mesh.queue_free()
		_gizmo_mesh = null

	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius          = 1.0
	sphere_mesh.height          = 2.0
	sphere_mesh.radial_segments = 24
	sphere_mesh.rings           = 12

	var mat := StandardMaterial3D.new()
	mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color  = Color(0.0, 0.8, 1.0, 0.25)
	mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	sphere_mesh.surface_set_material(0, mat)

	_gizmo_mesh       = MeshInstance3D.new()
	_gizmo_mesh.name  = "_ShieldGizmo"
	_gizmo_mesh.mesh  = sphere_mesh
	_gizmo_mesh.scale = radii
	add_child(_gizmo_mesh)


func _find_mesh_node() -> void:
	print("[FIND_MESH] aufgerufen | shield_mesh_path='%s' | is_ready=%s" % [
		str(shield_mesh_path), str(is_node_ready())])

	if shield_mesh_path and not shield_mesh_path.is_empty():
		_mesh_instance = get_node_or_null(shield_mesh_path) as MeshInstance3D
		if not _mesh_instance:
			push_error("[ShieldSystem] shield_mesh_path '%s' nicht gefunden!" % shield_mesh_path)
			return
	else:
		_mesh_instance = find_child("ShieldMesh", true, false) as MeshInstance3D

	print("[FIND_MESH] _mesh_instance=%s" % (
		_mesh_instance.name if _mesh_instance else "NULL"))

	if not _mesh_instance:
		push_error("[ShieldSystem] ShieldMesh nicht gefunden! NodePath setzen oder als Kind anlegen.")
		return

	var found_mat: ShaderMaterial = null
	found_mat = _mesh_instance.material_override as ShaderMaterial
	if not found_mat:
		found_mat = _mesh_instance.get_surface_override_material(0) as ShaderMaterial
	if not found_mat and _mesh_instance.mesh:
		found_mat = _mesh_instance.mesh.surface_get_material(0) as ShaderMaterial

	print("[FIND_MESH] material_override=%s | surface_0=%s | mesh.surface_0=%s | found=%s" % [
		_mesh_instance.material_override.get_class() if _mesh_instance.material_override else "NULL",
		_mesh_instance.get_surface_override_material(0).get_class() if _mesh_instance.get_surface_override_material(0) else "NULL",
		(_mesh_instance.mesh.surface_get_material(0).get_class() if _mesh_instance.mesh.surface_get_material(0) else "NULL") if _mesh_instance.mesh else "NO_MESH",
		found_mat.get_class() if found_mat else "NULL"
	])

	if not found_mat:
		push_error("[ShieldSystem] ShieldMesh hat kein ShaderMaterial! Im Inspector zuweisen.")
		return

	var is_first_init: bool = (_mat == null)

	if not Engine.is_editor_hint():
		if is_first_init:
			_mat = found_mat.duplicate() as ShaderMaterial
			_mesh_instance.material_override = _mat
			print("[FIND_MESH] ✅ Material dupliziert → material_override gesetzt | shader=%s" % (
				_mat.shader.resource_path if _mat.shader else "KEIN SHADER"))
		else:
			print("[FIND_MESH] ✅ Material bereits vorhanden – kein Reset")
	else:
		_mat = found_mat
		print("[FIND_MESH] ✅ Editor-Modus: Material direkt genutzt")

	if is_first_init:
		_mat.set_shader_parameter("impact_points",     _impact_points)
		_mat.set_shader_parameter("impact_ages",       _impact_ages)
		_mat.set_shader_parameter("impact_colors",     _impact_colors)
		_mat.set_shader_parameter("impact_types",      _impact_types)
		_mat.set_shader_parameter("impact_slot_count", max_impact_slots)
		_mat.set_shader_parameter("integrity",         1.0)
		_mat.set_shader_parameter("dissolve_progress", 0.0)
		_mat.set_shader_parameter("debug_mode",        shader_debug_mode)
		_mat.set_shader_parameter("dissolve_noise",    _create_dissolve_noise())
		_apply_shield_data_visuals()

	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.visible     = Engine.is_editor_hint() or (data != null and data.is_active())
	_dbg("✅ ShaderMaterial übernommen")


# ─────────────────────────────────────────────────────────────────────────────
# PHYSICS PROCESS – Regeneration + Impact-Alter
# ─────────────────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	# WICHTIG: Läuft auch bei _is_destroyed und _is_dissolved weiter!
	# Der Regen-Pfad in _handle_recharge() ist der einzige, der diese Flags
	# wieder zurücksetzt (via _activate_shield()). Wenn _physics_process bei
	# destroyed/dissolved früh returnt, deadlockt das Schild für immer:
	#   → _reactivation_timer wird nie runtergezählt
	#   → _is_recharging wird nie true
	#   → data.heal() wird nie aufgerufen
	#   → _activate_shield() wird nie aufgerufen
	#   → _is_destroyed bleibt für immer true
	# Visuelle Flags (_is_dissolved = Mesh hidden) blockieren die Regen-LOGIK
	# nicht – sie beeinflussen nur was im Shader passiert.
	if not data:
		return
	_handle_recharge(delta)
	_update_impact_ages(delta)


func _update_impact_ages(delta: float) -> void:
	if not _mat:
		return
	var dur: float = (data.hit_glow_duration if data else 2.0)
	var changed := false
	for i in range(MAX_IMPACT_SLOTS):
		if _impact_ages[i] >= 0.0 and _impact_ages[i] < dur:
			_impact_ages[i] += delta
			changed = true
	if changed:
		_mat.set_shader_parameter("impact_ages", _impact_ages)


func _handle_recharge(delta: float) -> void:
	if data.is_full():
		return

	if _reactivation_timer > 0.0:
		var before: float = _reactivation_timer
		_reactivation_timer -= delta
		# Einmalige Debug-Meldung beim Ablauf des Reaktivierungs-Fensters
		if before > 0.0 and _reactivation_timer <= 0.0:
			_dbg("⏰ Reaktivierungs-Fenster abgelaufen → Regen-Countdown startet")
		return

	if not _is_recharging:
		_recharge_timer -= delta
		if _recharge_timer <= 0.0:
			_is_recharging = true
			_dbg("♻️ Regeneration startet (HP: %.0f/%.0f)" % [
				data.current_strength, data.max_strength
			])

	if _is_recharging:
		var was_inactive := not data.is_active()
		data.heal(data.recharge_rate * delta)
		_update_integrity()
		_update_zone_integrities()
		if was_inactive and data.is_active():
			_activate_shield()
			shield_recharged.emit()
			_dbg("✅ Schild wieder aktiv")


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

func receive_hit(damage: float, impact_pos: Vector3,
				 beam_color: Color = Color(1.0, 0.5, 0.0),
				 damage_type: String = "phaser") -> float:
	var result := receive_hit_ex(damage, impact_pos, beam_color, -1, damage_type)
	return result[0]

func receive_hit_ex(damage: float, impact_pos: Vector3,
					beam_color: Color = Color(1.0, 0.5, 0.0),
					hint_slot: int = -1,
					damage_type: String = "phaser") -> Array:
	if not data or _is_destroyed:
		return [damage, -1]
	if data.current_strength <= 0.0:
		return [damage, -1]

	# ── VIER-ZONEN-SCHADENS-ROUTING ──────────────────────────────────────
	# 1. Zone aus Impact-Position bestimmen
	var ship_xform: Transform3D = _get_ship_transform()
	var ship_pos:   Vector3     = ship_xform.origin
	var invert_fwd: bool        = _get_invert_model_forward()
	var zone: int = ShieldZone.get_zone_for_impact(
		ship_xform, ship_pos, impact_pos, invert_fwd
	)

	# 2. Schaden auf die Zone anwenden, Overflow + Bleed zurückbekommen
	var result: Dictionary = data.take_damage_on_zone(zone, damage)
	var overflow: float = result["overflow"]
	var bleed:    float = result["bleed"]

	if show_debug:
		_dbg("🎯 Hit Zone %s | dmg=%.0f | zone_hp=%.0f/%.0f | overflow=%.0f | bleed=%.0f" % [
			ShieldZone.name_of(zone),
			damage,
			data.zone_hp(zone),
			data.zone_max(),
			overflow,
			bleed
		])

	# 3. Regen blockieren (shared pool – irgendein Hit blockt alle Zonen)
	_is_recharging  = false
	_recharge_timer = data.recharge_delay

	# 4. Signale & Shader
	# hull_damage = overflow (Zone ganz durch) + bleed (durchgeleckt)
	var hull_damage: float = overflow + bleed
	shield_hit.emit(impact_pos, damage - hull_damage, hull_damage)
	_update_integrity()
	_update_zone_integrities()

	# 5. Impact-Slot für Shader
	var slot_index: int = -1
	if data.current_strength <= 0.0:
		_destroy_shield()
	else:
		slot_index = begin_beam_impact(impact_pos, beam_color, hint_slot)
		if slot_index >= 0:
			_impact_types[slot_index] = 1.0 if damage_type == "torpedo" else 0.0
			_mat.set_shader_parameter("impact_types", _impact_types)

	# Return-Wert: Overflow + Bleed zusammen, damit ShipController das an die
	# Hülle weiterreicht. Entspricht der alten API-Semantik.
	return [hull_damage, slot_index]


## Holt das Schiff-Transform aus dem Parent (CharacterBody3D für Player,
## AIController für NPCs). Fallback: own global_transform.
func _get_ship_transform() -> Transform3D:
	var p: Node = get_parent()
	while is_instance_valid(p):
		if p is Node3D and (p as Node3D).is_in_group("ships"):
			return (p as Node3D).global_transform
		p = p.get_parent()
	return global_transform


## Liest invert_model_forward vom ShipController, falls vorhanden.
## Schiffe mit Blender-Import (Forward=+Z) brauchen das.
func _get_invert_model_forward() -> bool:
	var sc_meta: Variant = null
	var p: Node = get_parent()
	if p and p.has_meta("ship_controller"):
		sc_meta = p.get_meta("ship_controller")
	if sc_meta is ShipController:
		return (sc_meta as ShipController).invert_model_forward
	return false


## Schiebt die Zone-Integritäten in den Shader.
## Der Shader kann damit z.B. die getroffene Zone visuell hervorheben.
## Wenn der Shader das Uniform nicht kennt, ignoriert er es stillschweigend.
func _update_zone_integrities() -> void:
	if not _mat or not data:
		return
	_mat.set_shader_parameter("zone_integrity", data.zone_integrities())


func is_active() -> bool:
	return data != null and data.is_active() and not _is_destroyed

func get_integrity() -> float:
	return data.get_integrity() if data else 0.0

func get_shield_radii() -> Vector3:
	return Vector3(shield_radius_x, shield_radius_y, shield_radius_z)

func get_shield_global_transform() -> Transform3D:
	if _mesh_instance:
		return _mesh_instance.global_transform
	return global_transform


func _world_pos_to_shader_dir(world_pos: Vector3) -> Vector3:
	if not _mesh_instance:
		return Vector3.UP
	var local: Vector3 = _mesh_instance.global_transform.affine_inverse() * world_pos
	return local.normalized()


func reset() -> void:
	if not data:
		return
	data.reset()
	_is_recharging      = false
	_recharge_timer     = 0.0
	_reactivation_timer = 0.0
	_is_destroyed       = false
	_impact_ages.fill(100.0)
	_impact_points.fill(Vector3(0.0, -9999.0, 0.0))
	_impact_colors.fill(Color.WHITE)
	_impact_types.fill(0.0)
	if _mat:
		_mat.set_shader_parameter("impact_ages",   _impact_ages)
		_mat.set_shader_parameter("impact_points", _impact_points)
		_mat.set_shader_parameter("impact_colors", _impact_colors)
		_mat.set_shader_parameter("impact_types",  _impact_types)
	_activate_shield()
	_dbg("🔄 Zurückgesetzt")


# ─────────────────────────────────────────────────────────────────────────────
# SHIELD ACTIVATE / DESTROY
# ─────────────────────────────────────────────────────────────────────────────

func _activate_shield() -> void:
	_is_dissolved = false
	_is_destroyed = false
	if _mesh_instance:
		_mesh_instance.visible = true
	if _mat:
		_mat.set_shader_parameter("dissolve_progress", 0.0)
	_dbg("🛡️ Aktiviert")


func _destroy_shield() -> void:
	if _is_destroyed:
		return

	_is_destroyed       = true
	_is_recharging      = false
	_recharge_timer     = 0.0
	_reactivation_timer = data.reactivation_delay if data else 8.0
	shield_depleted.emit()

	_dbg("💀 Kollabiert | reactivation in %.1fs" % _reactivation_timer)
	_play_dissolution()


# ─────────────────────────────────────────────────────────────────────────────
# SHADER – nur Laufzeitwerte
# ─────────────────────────────────────────────────────────────────────────────

func _apply_shield_data_visuals() -> void:
	if not _mat:
		return
	if data:
		_mat.set_shader_parameter("shield_color",      data.shield_color)
		_mat.set_shader_parameter("rim_power",         data.rim_power)
		_mat.set_shader_parameter("hit_glow_duration", data.hit_glow_duration)
		_mat.set_shader_parameter("impact_radius",     data.impact_radius)
		print("[ShieldSystem] Visuals aus ShieldData → color=%s | rim=%.1f | dur=%.1fs" % [
			data.shield_color, data.rim_power, data.hit_glow_duration])


func _on_data_changed() -> void:
	_update_integrity()


func _update_integrity() -> void:
	if _mat and data:
		_mat.set_shader_parameter("integrity", data.get_integrity())


func begin_beam_impact(world_pos: Vector3, beam_color: Color, hint_slot: int = -1) -> int:
	if not _mat or not _mesh_instance:
		return -1

	if _impact_ages.size() < MAX_IMPACT_SLOTS or \
	   _impact_points.size() < MAX_IMPACT_SLOTS or \
	   _impact_colors.size() < MAX_IMPACT_SLOTS:
		push_error("[ShieldSystem] Impact-Arrays zu klein! ages=%d pts=%d cols=%d" % [
			_impact_ages.size(), _impact_points.size(), _impact_colors.size()])
		return -1

	var dur: float      = data.hit_glow_duration if data else 2.0
	var local_dir: Vector3 = _world_pos_to_shader_dir(world_pos)

	if hint_slot >= 0 and hint_slot < max_impact_slots:
		if _impact_ages[hint_slot] < dur:
			_impact_points[hint_slot] = local_dir
			_mat.set_shader_parameter("impact_points", _impact_points)
			_dbg("♻ Slot %d wiederverwendet | age=%.0fms" % [hint_slot, _impact_ages[hint_slot] * 1000.0])
			return hint_slot

	var next_slot: int = (_impact_slot + 1) % max_impact_slots
	if _impact_ages[next_slot] >= 0.15:
		_impact_slot = next_slot

	_impact_ages[_impact_slot]   = 0.0
	_impact_points[_impact_slot] = local_dir
	_impact_colors[_impact_slot] = beam_color

	_mat.set_shader_parameter("impact_points", _impact_points)
	_mat.set_shader_parameter("impact_ages",   _impact_ages)
	_mat.set_shader_parameter("impact_colors", _impact_colors)

	_dbg("🎯 begin_beam_impact slot=%d | dir=%s | dur=%.1fs" % [
		_impact_slot, local_dir.snappedf(0.001), dur])

	return _impact_slot


func update_beam_impact(slot_index: int, world_pos: Vector3) -> void:
	if not _mat or not _mesh_instance:
		return
	if slot_index < 0 or slot_index >= MAX_IMPACT_SLOTS:
		return
	_impact_points[slot_index] = _world_pos_to_shader_dir(world_pos)
	_mat.set_shader_parameter("impact_points", _impact_points)


func end_beam_impact(slot_index: int) -> void:
	if not _mat:
		return
	if slot_index < 0 or slot_index >= MAX_IMPACT_SLOTS:
		return
	_impact_ages[slot_index]   = 100.0
	_impact_points[slot_index] = Vector3(0.0, -9999.0, 0.0)
	_impact_types[slot_index]  = 0.0
	_mat.set_shader_parameter("impact_ages",   _impact_ages)
	_mat.set_shader_parameter("impact_points", _impact_points)
	_mat.set_shader_parameter("impact_types",  _impact_types)
	_dbg("🔕 end_beam_impact slot=%d" % slot_index)


# ─────────────────────────────────────────────────────────────────────────────
# DISSOLUTION
# ─────────────────────────────────────────────────────────────────────────────

func _create_dissolve_noise() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type                 = FastNoiseLite.TYPE_CELLULAR
	noise.frequency                  = 0.08
	noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	noise.cellular_return_type       = FastNoiseLite.RETURN_DISTANCE
	noise.fractal_type               = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves            = 3
	noise.seed                       = randi()
	var tex := NoiseTexture2D.new()
	tex.noise    = noise
	tex.width    = 256
	tex.height   = 256
	tex.seamless = true
	return tex


func _play_dissolution() -> void:
	if not _mat:
		_hide_mesh()
		return
	_is_dissolved = false
	if _dissolve_tween:
		_dissolve_tween.kill()
	_dissolve_tween = create_tween()
	_dissolve_tween.set_ease(Tween.EASE_IN_OUT)
	_dissolve_tween.set_trans(Tween.TRANS_SINE)
	_dissolve_tween.tween_method(_set_dissolve, 0.0, 1.0, 2.5)
	_dissolve_tween.tween_callback(_on_dissolution_complete)

func _set_dissolve(value: float) -> void:
	if _mat:
		_mat.set_shader_parameter("dissolve_progress", value)

func _on_dissolution_complete() -> void:
	_is_dissolved = true
	_hide_mesh()
	_dbg("✅ Dissolution abgeschlossen")

func _hide_mesh() -> void:
	if _mesh_instance:
		_mesh_instance.visible = false


# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────

func print_shader_state() -> void:
	print("\n[ShieldSystem|%s] ══════ SHADER DEBUG ══════" % (get_parent().name if get_parent() else "?"))
	print("  _mesh_instance : %s" % (_mesh_instance.name if _mesh_instance else "❌ NULL"))
	print("  _mat           : %s" % ("✅ ShaderMaterial" if _mat else "❌ NULL"))
	if _mesh_instance:
		print("  mesh.visible   : %s" % _mesh_instance.visible)
		print("  mesh.mat_override: %s" % (_mesh_instance.material_override != null))
	if data:
		print("  HP total       : %.1f / %.1f" % [data.current_strength, data.max_strength])
		print("  integrity      : %.2f" % data.get_integrity())
		print("  ── Zonen ──")
		for i in range(ShieldZone.COUNT):
			var bleed_mark: String = " ⚠BLEED" if data.zone_is_bleeding(i) else ""
			print("    %s: %.1f / %.1f (%.0f%%)%s" % [
				ShieldZone.name_of(i),
				data.zone_hp(i),
				data.zone_max(),
				data.zone_integrity(i) * 100.0,
				bleed_mark
			])
	print("  _is_destroyed  : %s" % _is_destroyed)
	print("  _is_dissolved  : %s" % _is_dissolved)
	print("  debug_mode     : %d" % shader_debug_mode)
	print("  impact_ages    : %s" % str(_impact_ages))
	print("  impact_counts  : ages=%d pts=%d cols=%d" % [
		_impact_ages.size(), _impact_points.size(), _impact_colors.size()])
	if _mat:
		print("  ── Shader params ──")
		print("  integrity      : %.2f" % (_mat.get_shader_parameter("integrity") if _mat.get_shader_parameter("integrity") else 0.0))
		print("  dissolve_prog  : %.2f" % (_mat.get_shader_parameter("dissolve_progress") if _mat.get_shader_parameter("dissolve_progress") else 0.0))
		var shader_obj = _mat.shader
		print("  shader         : %s" % (shader_obj.resource_path if shader_obj else "❌ NULL"))
	print("[ShieldSystem] ══════════════════════════════\n")


func _dbg(msg: String) -> void:
	if show_debug:
		print("[ShieldSystem|%s] %s" % [get_parent().name if get_parent() else "?", msg])
