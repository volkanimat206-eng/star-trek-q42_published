# res://scripts/weapons/wing_disruptor_mount.gd
# Klingonischer Doppel-Wing-Disruptor: zwei Marker3D an den Flügelspitzen,
# feuern gleichzeitig symmetrische Energiebolzen nach vorne.
# Gleiche Public API wie WeaponMount – ShipController braucht keine Änderungen.
@tool
extends Node3D
class_name WingDisruptorMount

# ===== EXPORTS =====
@export_group("Marker")
@export var left_marker:  Marker3D:
	set(v): left_marker  = v; _update_visual_gizmo()
@export var right_marker: Marker3D:
	set(v): right_marker = v; _update_visual_gizmo()

@export_group("Bolt Settings")
@export var bolt_scene: PackedScene

## Alle Bolt-Parameter (Schaden, Multiplier, Speed, Range, Farbe, Cooldown)
## zentral in einer BoltWeaponData-Resource – im Inspector zuweisen.
@export var bolt_weapon_data: BoltWeaponData

## Kollisionsmaske – überschreibt bolt_weapon_data.collision_mask wenn gesetzt (> 0).
## Leer lassen (0) um den Wert aus bolt_weapon_data zu nutzen.
@export_flags_3d_physics var collision_mask_override: int = 0

@export_group("Audio")
## Feuer-Sound für die Wing-Disruptoren.
@export var fire_sound: AudioStream = null

## Lautstärke-Offset in dB (+ = lauter, - = leiser).
@export_range(-30.0, 30.0, 0.1) var fire_volume_offset_db: float = 0.0

## Wie stark die Distanz-/Zoom-Abschwächung wirkt (0.0 = fast keine Abschwächung).
@export_range(0.0, 2.0, 0.05) var distance_attenuation_strength: float = 0.30

## Maximale Distanz, bis zu der der Sound gut hörbar bleibt.
@export_range(100.0, 2000.0, 50.0) var max_distance: float = 900.0

## Wenn true: Attenuation komplett deaktivieren → Sound immer gleich laut (ideal für Player).
@export var no_distance_attenuation: bool = false

## Low-pass Filter Cutoff (höher = weniger dumpf bei Zoom/Distanz).
@export_range(1000.0, 20500.0, 100.0) var attenuation_filter_cutoff_hz: float = 11500.0

## Fade-out Dauer nach dem Abspielen (0.0 = kein Fade).
@export_range(0.0, 2.0, 0.1) var sound_fade_out_time: float = 0.4

@export_group("Arc Settings")
@export_range(10.0, 90.0) var arc_half_angle: float = 45.0:
	set(v): arc_half_angle = v; _update_visual_gizmo()
@export var fire_range: float = 150.0:
	set(v): fire_range = v; _update_visual_gizmo()

@export_group("Visuals")
@export var show_gizmo: bool = true:
	set(v):
		show_gizmo = v
		if _gizmo_left  and is_instance_valid(_gizmo_left):  _gizmo_left.visible  = v
		if _gizmo_right and is_instance_valid(_gizmo_right): _gizmo_right.visible = v

@export_group("Debug")
@export var show_debug: bool = false

# ===== INTERN =====
var _cooldown_remaining: float          = 0.0
var _ship_controller:    ShipController = null
var _exclude_rids:       Array[RID]     = []
var _audio_player:       AudioStreamPlayer3D = null
var _is_player_ship:     bool           = false

var _salvo_remaining:  int     = 0
var _salvo_timer:      float   = 0.0
var _salvo_target_pos: Vector3 = Vector3.ZERO
var _salvo_tracking:   Node3D  = null

var _gizmo_left:  MeshInstance3D = null
var _gizmo_right: MeshInstance3D = null


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	if Engine.is_editor_hint():
		_setup_gizmos()
		return

	if not bolt_weapon_data:
		push_warning("[WingDisruptorMount|%s] bolt_weapon_data nicht gesetzt – Standardwerte!" % name)

	_ship_controller = _find_ship_controller()
	call_deferred("_build_exclude_rids")
	_setup_audio()

	var data_name: String = bolt_weapon_data.weapon_name if bolt_weapon_data else "???"
	print("[WingDisruptorMount|%s] bereit | left=%s | right=%s | data='%s'" % [
		name,
		left_marker.name  if left_marker  else "❌",
		right_marker.name if right_marker else "❌",
		data_name,
	])


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if _cooldown_remaining > 0.0:
		_cooldown_remaining -= delta

	if _salvo_remaining > 0:
		_salvo_timer -= delta
		if _salvo_timer <= 0.0:
			_fire_from_marker(left_marker,  _salvo_target_pos, _salvo_tracking)
			_fire_from_marker(right_marker, _salvo_target_pos, _salvo_tracking)
			_play_fire_sound()
			_salvo_remaining -= 1

			if show_debug:
				print("[WingDisruptorMount] Salve-Schuss | noch %d ausstehend" % _salvo_remaining)

			if _salvo_remaining > 0:
				_salvo_timer = _get_salvo_interval()
			else:
				_cooldown_remaining = _get_cooldown()
				if show_debug:
					print("[WingDisruptorMount] Salve abgeschlossen | cooldown=%.2fs" % _cooldown_remaining)


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

func get_weapon_type() -> WeaponMount.WeaponType:
	return WeaponMount.WeaponType.DISRUPTOR

func get_mount_position() -> WeaponMount.MountPosition:
	return WeaponMount.MountPosition.FULL

func is_ready_to_fire() -> bool:
	return _cooldown_remaining <= 0.0 and _salvo_remaining <= 0

func get_weapon_state() -> String:
	if _salvo_remaining > 0:
		return "FIRING"
	return "IDLE" if is_ready_to_fire() else "COOLDOWN"


func is_target_node_in_arc(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	var dist: float = global_position.distance_to(target.global_position)
	if dist > fire_range:
		return false
	var forward   := -global_transform.basis.z
	forward.y      = 0.0
	var to_target  := target.global_position - global_position
	to_target.y    = 0.0
	if forward.length_squared() < 0.001 or to_target.length_squared() < 0.001:
		return true
	var angle: float = rad_to_deg(forward.normalized().angle_to(to_target.normalized()))
	return angle <= arc_half_angle


func fire_at(target_pos: Vector3, _weapon_range: float = INF,
			_freeze: bool = false, tracking_node: Node3D = null) -> bool:
	if not is_ready_to_fire():
		return false
	if not bolt_scene:
		push_warning("[WingDisruptorMount] Keine bolt_scene gesetzt!")
		return false
	if tracking_node and is_instance_valid(tracking_node):
		if not is_target_node_in_arc(tracking_node):
			return false

	_fire_from_marker(left_marker,  target_pos, tracking_node)
	_fire_from_marker(right_marker, target_pos, tracking_node)
	_play_fire_sound()

	var salvo: int = _get_salvo_count()
	if salvo > 1:
		_salvo_remaining  = salvo - 1
		_salvo_timer      = _get_salvo_interval()
		_salvo_target_pos = target_pos
		_salvo_tracking   = tracking_node
		if show_debug:
			print("[WingDisruptorMount] Salve gestartet | %d weitere | interval=%.2fs" % [
				_salvo_remaining, _salvo_timer])
	else:
		_cooldown_remaining = _get_cooldown()

	return true


# ─────────────────────────────────────────────────────────────────────────────
# BOLT SPAWNING
# ─────────────────────────────────────────────────────────────────────────────

func _fire_from_marker(marker: Marker3D, target_pos: Vector3,
					tracking_node: Node3D) -> void:
	if not marker or not is_instance_valid(marker):
		return

	var bolt: Node3D = bolt_scene.instantiate() as Node3D
	if not bolt:
		return

	var world: Node = get_tree().current_scene
	world.add_child(bolt)

	var aim_pos: Vector3 = tracking_node.global_position \
		if tracking_node and is_instance_valid(tracking_node) \
		else target_pos

	var dir: Vector3 = (aim_pos - marker.global_position).normalized()
	if dir.length_squared() > 0.001:
		bolt.global_transform = Transform3D(Basis.looking_at(dir, Vector3.UP), marker.global_position)
	else:
		bolt.global_transform = marker.global_transform

	if bolt.has_method("initialize"):
		bolt.initialize(_ship_controller, _exclude_rids)

	# ── Parameter aus BoltWeaponData übergeben ────────────────────────────────
	if bolt_weapon_data:
		# weapon_data auf dem Bolt setzen – der Bolt liest shield/hull_multiplier
		# selbst aus bolt_weapon_data.get_damage(hit_shield) wenn er etwas trifft.
		if "weapon_data" in bolt:
			bolt.weapon_data = bolt_weapon_data
		# Fallback-Parameter für Bolts die noch kein weapon_data-Feld haben
		if "speed"          in bolt: bolt.speed         = bolt_weapon_data.speed
		if "max_range"      in bolt: bolt.max_range      = bolt_weapon_data.max_range
		if "damage"         in bolt: bolt.damage         = bolt_weapon_data.damage
		if "bolt_color"     in bolt: bolt.bolt_color     = bolt_weapon_data.bolt_color
		if "collision_mask" in bolt:
			var mask: int = collision_mask_override if collision_mask_override > 0 \
							else bolt_weapon_data.collision_mask
			bolt.collision_mask = mask
	else:
		# Kein weapon_data → nichts setzen, Bolt-Defaults greifen
		push_warning("[WingDisruptorMount] bolt_weapon_data fehlt – Bolt-Defaults aktiv")

	if show_debug:
		var dmg_s: float = bolt_weapon_data.get_damage(true)  if bolt_weapon_data else 0.0
		var dmg_h: float = bolt_weapon_data.get_damage(false) if bolt_weapon_data else 0.0
		print("[WingDisruptorMount] Bolt abgefeuert | dmg_shield=%.1f | dmg_hull=%.1f" % [dmg_s, dmg_h])


# ─────────────────────────────────────────────────────────────────────────────
# HELPER – liest Werte aus BoltWeaponData oder Fallback
# ─────────────────────────────────────────────────────────────────────────────

func _get_cooldown() -> float:
	return bolt_weapon_data.cooldown if bolt_weapon_data else 1.2

func _get_salvo_count() -> int:
	return bolt_weapon_data.salvo_count if bolt_weapon_data else 1

func _get_salvo_interval() -> float:
	return bolt_weapon_data.salvo_interval if bolt_weapon_data else 0.15

# ─────────────────────────────────────────────────────────────────────────────
# AUDIO (konsistent mit CloakComponent & WeaponMount)
# ─────────────────────────────────────────────────────────────────────────────

func _setup_audio() -> void:
	if not fire_sound:
		return

	# Player vs NPC erkennen
	var node: Node = get_parent()
	_is_player_ship = true
	while node:
		if node.get_script() and node.get_script().get_global_name() == "AIController":
			_is_player_ship = false
			break
		node = node.get_parent()

	# AudioPlayer nur einmal erstellen
	if not _audio_player or not is_instance_valid(_audio_player):
		_audio_player = AudioStreamPlayer3D.new()
		_audio_player.name = "WingDisruptorAudio"
		_audio_player.stream = fire_sound
		_audio_player.bus = "Weapons"
		add_child(_audio_player)

	print("[WingDisruptorMount|%s] 🔊 Audio-Setup: fire_sound=%s | player=%s" % [
		name, fire_sound.resource_path if fire_sound else "null", _is_player_ship
	])


func _play_fire_sound() -> void:
	if not _audio_player or not fire_sound:
		return

	# Position bei jedem Schuss aktualisieren
	if is_instance_valid(_ship_controller) and _ship_controller is Node3D:
		_audio_player.global_position = _ship_controller.global_position
	elif is_instance_valid(get_parent()) and get_parent() is Node3D:
		_audio_player.global_position = get_parent().global_position

	# Lautstärke setzen
	_audio_player.volume_db = fire_volume_offset_db

	# Zoom- / Distanz-Steuerung
	if no_distance_attenuation or _is_player_ship:
		_audio_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		_audio_player.max_distance = 2000.0
		_audio_player.unit_size = 10000.0
	else:
		_audio_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		_audio_player.max_distance = max_distance
		_audio_player.unit_size = 1.0 / max(0.1, distance_attenuation_strength)

	_audio_player.attenuation_filter_cutoff_hz = attenuation_filter_cutoff_hz

	_audio_player.play()

	# Optional: kurzer Fade-Out (bei Salven meist nicht nötig, aber möglich)
	if sound_fade_out_time > 0.0:
		var tween := create_tween()
		tween.tween_property(_audio_player, "volume_db", -80.0, sound_fade_out_time)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tween.tween_callback(func():
			if is_instance_valid(_audio_player):
				_audio_player.volume_db = fire_volume_offset_db  # für nächsten Schuss zurücksetzen
		)

# ─────────────────────────────────────────────────────────────────────────────
# GIZMO
# ─────────────────────────────────────────────────────────────────────────────

func _setup_gizmos() -> void:
	if not _gizmo_left:
		_gizmo_left      = MeshInstance3D.new()
		_gizmo_left.name = "ArcVisualizer_Left"
		add_child(_gizmo_left)
	if not _gizmo_right:
		_gizmo_right      = MeshInstance3D.new()
		_gizmo_right.name = "ArcVisualizer_Right"
		add_child(_gizmo_right)
	_update_visual_gizmo()


func _update_visual_gizmo() -> void:
	if not Engine.is_editor_hint():
		return
	if not _gizmo_left:
		_setup_gizmos()
		return
	var klingon_green := Color(0.0, 0.9, 0.2, 0.30)
	_build_arc_gizmo(_gizmo_left,  _get_marker_local_offset(left_marker),  klingon_green)
	_build_arc_gizmo(_gizmo_right, _get_marker_local_offset(right_marker), klingon_green)


func _get_marker_local_offset(marker: Marker3D) -> Vector3:
	if not marker or not is_instance_valid(marker):
		return Vector3.ZERO
	return marker.position


func _build_arc_gizmo(gizmo: MeshInstance3D, origin_offset: Vector3, color: Color) -> void:
	if not gizmo:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_draw_arc_sector(st, color, origin_offset)
	var mat := StandardMaterial3D.new()
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	gizmo.mesh              = st.commit()
	gizmo.material_override = mat
	gizmo.visible           = show_gizmo


func _draw_arc_sector(st: SurfaceTool, color: Color, offset: Vector3) -> void:
	var half_rad := deg_to_rad(arc_half_angle)
	var steps    := 32
	var origin   := offset
	for i in range(steps):
		var t0: float = float(i)     / float(steps)
		var t1: float = float(i + 1) / float(steps)
		var a0: float = -half_rad + t0 * half_rad * 2.0
		var a1: float = -half_rad + t1 * half_rad * 2.0
		var p0 := offset + Vector3(sin(a0), 0.0, -cos(a0)) * fire_range
		var p1 := offset + Vector3(sin(a1), 0.0, -cos(a1)) * fire_range
		st.set_color(color)
		st.add_vertex(origin)
		st.add_vertex(p0)
		st.add_vertex(p1)
	var edge_color := Color(color.r, color.g, color.b, 0.8)
	var left_end   := offset + Vector3(sin(-half_rad), 0.0, -cos(-half_rad)) * fire_range
	var right_end  := offset + Vector3(sin( half_rad), 0.0, -cos( half_rad)) * fire_range
	_draw_edge_line(st, origin, left_end,  edge_color, 0.15)
	_draw_edge_line(st, origin, right_end, edge_color, 0.15)


func _draw_edge_line(st: SurfaceTool, from: Vector3, to: Vector3,
					color: Color, thickness: float) -> void:
	var dir  := (to - from).normalized()
	var perp := dir.cross(Vector3.UP).normalized() * thickness
	st.set_color(color)
	st.add_vertex(from - perp); st.add_vertex(from + perp); st.add_vertex(to + perp)
	st.set_color(color)
	st.add_vertex(from - perp); st.add_vertex(to + perp);   st.add_vertex(to - perp)


# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────

func _build_exclude_rids() -> void:
	_exclude_rids.clear()
	var root: Node = _ship_controller if _ship_controller else get_parent()
	_collect_rids(root)
	if show_debug:
		print("[WingDisruptorMount] Exclude RIDs: %d" % _exclude_rids.size())


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
