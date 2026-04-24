# res://scripts/weapons/torpedo_mount_3d.gd
@tool
extends Node3D
class_name TorpedoMount3D

# ===== EXPORTS =====
@export_group("Setup")
@export var torpedo_scene:  PackedScene
@export var torpedo_data:   TorpedoData
## Optional: Marker3D als Abschussposition. Fallback = dieser Node.
@export var launch_marker: Marker3D:
	set(v): launch_marker = v; _update_visual_gizmo()
## Distanz die der Torpedo geradeaus in -Z Richtung des Schiffes fliegt
## bevor das Homing zum Ziel aktiviert wird.
@export var launch_straight_distance: float = 20.0

@export_group("Cooldown")
@export var cooldown: float = 0.5  # Wartezeit zwischen Einzelschüssen

@export_group("Ammo")
## Maximale Torpedo-Anzahl im Magazin
@export var max_ammo: int = 4
## Sekunden bis ein Torpedo nachgeladen ist
@export var reload_time: float = 8.0

@export_group("Arc")
@export_range(10.0, 180.0) var arc_half_angle: float = 60.0:
	set(v): arc_half_angle = v; _update_visual_gizmo()
## Nur für Gizmo-Visualisierung im Editor.
## Die echte Reichweite kommt aus torpedo_data.max_range.
@export var fire_range: float = 300.0:
	set(v): fire_range = v; _update_visual_gizmo()

@export_group("Visuals")
@export var show_gizmo: bool = true:
	set(v):
		show_gizmo = v
		if _gizmo and is_instance_valid(_gizmo): _gizmo.visible = v

@export_group("Velocity")
## Sekunden bis Torpedo von Schiff-Boost auf Eigengeschwindigkeit zurückfällt.
## Wird an torpedo_3d.gd weitergegeben.
@export var velocity_decay_time: float = 2.5

@export_group("Audio")
## Sound der beim Abfeuern eines Torpedos abgespielt wird.
@export var launch_sound: AudioStream
## Lautstärke-Offset in dB (addiert zum Basis-Wert -6 dB).
@export_range(-20.0, 20.0) var launch_volume_db: float = 0.0
## Panning-Stärke für Spieler-Torpedos (0.0 = kein Zoom-Einfluss).
## Wird automatisch auf 1.0 gesetzt wenn NPC das Schiff steuert.
@export_range(0.0, 1.0) var player_panning_strength: float = 0.0

@export_group("Debug")
@export var show_debug: bool = false

# ===== INTERN =====
var _cooldown_remaining: float           = 0.0
var _current_ammo:       int             = 4
var _reload_timer:       float           = 0.0
var _ship_controller:    ShipController  = null
var _ship_body:          CharacterBody3D = null
var _exclude_rids:       Array[RID]      = []
var _gizmo:              MeshInstance3D  = null
var _audio_player:       AudioStreamPlayer3D = null
var _is_player_ship:     bool            = false


# ─────────────────────────────────────────────────────────────────────────────
# READY / PROCESS
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	if Engine.is_editor_hint():
		_setup_gizmo()
		return
	_ship_controller = _find_ship_controller()
	_ship_body       = _find_character_body()
	_current_ammo    = max_ammo
	_reload_timer    = 0.0
	call_deferred("_build_exclude_rids")
	_setup_audio()
	print("[TorpedoMount3D|%s] bereit | data=%s | ammo=%d/%d | ship_body=%s" % [
		name,
		torpedo_data.torpedo_name if torpedo_data else "❌",
		max_ammo, max_ammo,
		_ship_body.name if _ship_body else "❌ NULL – keine Geschwindigkeitsvererbung!"
	])


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta
	# Ammo nachladen: ein Torpedo pro reload_time Sekunden
	if _current_ammo < max_ammo:
		_reload_timer += delta
		if _reload_timer >= reload_time:
			_current_ammo += 1
			_reload_timer  = 0.0
			if show_debug:
				print("[TorpedoMount] 🔄 Torpedo nachgeladen | %d/%d" % [_current_ammo, max_ammo])


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API – kompatibel mit WeaponMount
# ─────────────────────────────────────────────────────────────────────────────

func get_weapon_type() -> WeaponMount.WeaponType:
	return WeaponMount.WeaponType.TORPEDO

func get_mount_position() -> WeaponMount.MountPosition:
	return WeaponMount.MountPosition.FULL

func is_ready_to_fire() -> bool:
	return _cooldown_remaining <= 0.0 and _current_ammo > 0

func get_weapon_state() -> String:
	if _current_ammo <= 0:
		return "NO_AMMO"
	return "IDLE" if is_ready_to_fire() else "COOLDOWN"


func is_target_node_in_arc(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false

	# Reichweite aus TorpedoData — fire_range ist nur für den Gizmo
	var effective_range: float = torpedo_data.max_range if torpedo_data else fire_range
	var dist: float = global_position.distance_to(target.global_position)

	if dist > effective_range:
		if show_debug:
			print("[TorpedoMount] RANGE FAIL: dist=%.0f > max_range=%.0f" % [
				dist, effective_range])
		return false

	var forward   := -global_transform.basis.z
	var to_target := target.global_position - global_position
	forward.y    = 0.0
	to_target.y  = 0.0

	if forward.length_squared() < 0.001 or to_target.length_squared() < 0.001:
		return true

	var angle: float = rad_to_deg(forward.normalized().angle_to(to_target.normalized()))

	if show_debug:
		print("[TorpedoMount] ARC: dist=%.0f | angle=%.1f° | max=%.1f° | %s" % [
			dist, angle, arc_half_angle,
			"✓" if angle <= arc_half_angle else "✗"
		])

	return angle <= arc_half_angle


func fire_at(target_pos: Vector3, _range: float = INF,
			_freeze: bool = false, tracking_node: Node3D = null) -> bool:
	if not is_ready_to_fire() or not torpedo_scene or not torpedo_data:
		return false

	# Arc + Range Check
	if tracking_node and is_instance_valid(tracking_node):
		if not is_target_node_in_arc(tracking_node):
			return false
	else:
		var effective_range: float = torpedo_data.max_range
		if global_position.distance_to(target_pos) > effective_range:
			if show_debug:
				print("[TorpedoMount] RANGE FAIL (pos)")
			return false

	var torpedo: Node3D = torpedo_scene.instantiate() as Node3D
	if not torpedo:
		return false

	# Abschussposition
	var launch_pos: Vector3 = launch_marker.global_position \
		if launch_marker and is_instance_valid(launch_marker) \
		else global_position

	get_tree().current_scene.add_child(torpedo)
	torpedo.global_position = launch_pos

	# Startrichtung: -Z Achse des MOUNTS (nicht des Schiffes!).
	# Dadurch feuert ein nach hinten gedrehter Mount korrekt nach hinten,
	# ein seitlicher Mount nach der Seite, etc.
	# Der Torpedo fliegt launch_straight_distance Units in diese Richtung,
	# dann dreht er zum Ziel (Homing).
	var launch_dir: Vector3 = -global_transform.basis.z

	# Fallback falls Richtung degeneriert
	if launch_dir.length_squared() < 0.001:
		launch_dir = -_ship_body.global_transform.basis.z if _ship_body else Vector3.FORWARD

	torpedo.global_transform.basis = Basis.looking_at(
		launch_dir.normalized(), Vector3.UP)

	# Schiffsgeschwindigkeit für Vererbung
	var ship_velocity: Vector3 = Vector3.ZERO
	if _ship_body:
		ship_velocity = _ship_body.velocity

	if torpedo.has_method("initialize"):
		torpedo.initialize(torpedo_data, tracking_node,
			_ship_controller, _exclude_rids,
			ship_velocity, velocity_decay_time, launch_straight_distance)

	_cooldown_remaining = cooldown
	_current_ammo      -= 1
	_play_launch_sound()

	if show_debug:
		var aim: Vector3 = tracking_node.global_position 			if tracking_node and is_instance_valid(tracking_node) else target_pos
		print("[TorpedoMount3D] 🚀 Torpedo → %s | ammo=%d/%d | vel=%.1f" % [
			aim.snappedf(1.0), _current_ammo, max_ammo, ship_velocity.length()])

	return true


# ─────────────────────────────────────────────────────────────────────────────
# GIZMO
# ─────────────────────────────────────────────────────────────────────────────

func _setup_gizmo() -> void:
	if not _gizmo:
		_gizmo      = MeshInstance3D.new()
		_gizmo.name = "ArcVisualizer"
		add_child(_gizmo)
	_update_visual_gizmo()


func _update_visual_gizmo() -> void:
	if not Engine.is_editor_hint():
		return
	if not _gizmo:
		_setup_gizmo()
		return

	var orange := Color(1.0, 0.5, 0.0, 0.30)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_draw_arc_sector(st, orange)

	var mat := StandardMaterial3D.new()
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	_gizmo.mesh              = st.commit()
	_gizmo.material_override = mat
	_gizmo.visible           = show_gizmo


func _draw_arc_sector(st: SurfaceTool, color: Color) -> void:
	var half_rad := deg_to_rad(arc_half_angle)
	var steps    := 32
	var origin   := Vector3.ZERO
	for i in range(steps):
		var t0: float = float(i)     / float(steps)
		var t1: float = float(i + 1) / float(steps)
		var a0: float = -half_rad + t0 * half_rad * 2.0
		var a1: float = -half_rad + t1 * half_rad * 2.0
		var p0 := Vector3(sin(a0), 0.0, -cos(a0)) * fire_range
		var p1 := Vector3(sin(a1), 0.0, -cos(a1)) * fire_range
		st.set_color(color)
		st.add_vertex(origin)
		st.add_vertex(p0)
		st.add_vertex(p1)

	var edge  := Color(color.r, color.g, color.b, 0.8)
	var left  := Vector3(sin(-half_rad), 0.0, -cos(-half_rad)) * fire_range
	var right := Vector3(sin( half_rad), 0.0, -cos( half_rad)) * fire_range
	var t     := 0.15
	for pair in [[origin, left], [origin, right]]:
		var f: Vector3  = pair[0]
		var to: Vector3 = pair[1]
		var d := (to - f).normalized()
		var p := d.cross(Vector3.UP).normalized() * t
		st.set_color(edge)
		st.add_vertex(f - p);  st.add_vertex(f + p);  st.add_vertex(to + p)
		st.add_vertex(f - p);  st.add_vertex(to + p); st.add_vertex(to - p)


# ─────────────────────────────────────────────────────────────────────────────
# AUDIO
# ─────────────────────────────────────────────────────────────────────────────

func _setup_audio() -> void:
	# Prüfen ob dieses Schiff dem Spieler gehört (kein AIController im Baum)
	var node: Node = get_parent()
	_is_player_ship = true
	while node:
		if node.get_script() and node.get_script().get_global_name() == "AIController":
			_is_player_ship = false
			break
		node = node.get_parent()

	if not launch_sound:
		return

	_audio_player                 = AudioStreamPlayer3D.new()
	_audio_player.name            = "TorpedoLaunchAudio"
	_audio_player.stream          = launch_sound
	_audio_player.bus             = "Weapons"
	_audio_player.max_distance    = 800.0
	_audio_player.max_polyphony   = 4   # mehrere schnelle Schüsse möglich

	if _is_player_ship:
		_audio_player.panning_strength = player_panning_strength
		_audio_player.unit_size        = 10000.0
	else:
		_audio_player.panning_strength = 1.0
		_audio_player.unit_size        = 1.0

	add_child(_audio_player)


func _play_launch_sound() -> void:
	if not _audio_player or not launch_sound:
		return
	_audio_player.volume_db = -6.0 + launch_volume_db
	_audio_player.play()


# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────

func _build_exclude_rids() -> void:
	_exclude_rids.clear()
	var root: Node = _ship_controller if _ship_controller else get_parent()
	_collect_rids(root)


func _collect_rids(node: Node) -> void:
	if node is CollisionObject3D:
		_exclude_rids.append((node as CollisionObject3D).get_rid())
	for child in node.get_children():
		_collect_rids(child)


func _find_ship_controller() -> ShipController:
	var node: Node = get_parent()
	while node:
		if node is ShipController:
			return node as ShipController
		if node.has_meta("ship_controller"):
			return node.get_meta("ship_controller") as ShipController
		node = node.get_parent()
	return null


func _find_character_body() -> CharacterBody3D:
	var node: Node = get_parent()
	while node:
		if node is CharacterBody3D:
			return node as CharacterBody3D
		node = node.get_parent()
	return null
