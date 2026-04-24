# weapon_mount.gd
@tool
extends Node3D
class_name WeaponMount

# ===== ENUMS =====
## DORSAL  = nur nach oben feuern  (Saucer-Oberseite Sovereign)
## VENTRAL = nur nach unten feuern (Saucer-Unterseite Sovereign)
## FULL    = beide Hemisphären     (BirdOfPrey, einfache Schiffe)
enum MountPosition { DORSAL, VENTRAL, FULL }
enum WeaponType    { PHASER, DISRUPTOR, TORPEDO, PULSE_PHASER }

# ===== EXPORTS =====
@export_group("Weapon Settings")
@export var weapon_type:    WeaponType    = WeaponType.PHASER
@export var mount_position: MountPosition = MountPosition.DORSAL:
	set(v): mount_position = v; _update_visual_gizmo()

# PhaserBeam3D.tscn – wird zur Laufzeit instanziiert
@export var weapon_scene: PackedScene
## Waffen-Parameter (Schaden, Timing, Geometrie) – z.B. weapon_data_phaser.tres
@export var weapon_data: BeamWeaponData
# Wo die Instanz eingefügt wird – muss unter Model liegen damit sie mit dem Schiff kippt
# z.B. ../Model/PhaserBank_Path
@export var weapon_attach_path: NodePath
# Bestehender Path3D in der Szene dessen Kurve genutzt wird
# z.B. ../Model/PhaserBank_Path/PhaserBank_Top
@export var curve_source_path: NodePath

@export var mouse_target_height: float = 2.0:
	set(v):
		mouse_target_height = v
		if weapon_instance and weapon_instance.has_method("update_target_height_preview"):
			weapon_instance.update_target_height_preview(v)

@export_group("Audio")
## Lade-Sound für Auflade-Phaser (Federation-Stil mit Path3D).
@export var charge_sound: AudioStream
## Feuer-Sound – wird bei jedem Schuss einmal abgespielt.
@export var fire_sound:   AudioStream
## Lautstärke-Offset für den Charge-Sound in dB (addiert zum Pool-Basiswert).
@export_range(-20.0, 20.0) var charge_volume_offset_db: float = 0.0
## Lautstärke-Offset für den Fire-Sound in dB.
@export_range(-20.0, 20.0) var fire_volume_offset_db:   float = 0.0
## Wenn true: Kamera-Zoom hat keinen Einfluss auf die Lautstärke.
## Für Waffen des eigenen Schiffs empfohlen – feindliche Waffen auf false lassen.
@export var no_distance_attenuation: bool = false
## Fade-out Dauer des Charge-Sounds wenn der Strahl feuert (Sekunden).
## 0.0 = sofort stoppen.
@export_range(0.0, 2.0) var charge_fade_out_time: float = 0.3
## Fade-out Dauer des Feuer-Sounds wenn der Strahl endet (Sekunden).
@export_range(0.0, 2.0) var fire_fade_out_time:   float = 0.2
## Optionale Curve für den Charge-Fade (X=Zeit 0→1, Y=Lautstärke 1→0).
## Leer = linearer Fade.
@export var charge_fade_curve: Curve
## Optionale Curve für den Fire-Fade.
@export var fire_fade_curve:   Curve

@export_group("Arc Settings")
@export_range(0.0, 180.0) var arc_half_angle_deg: float = 90.0:
	set(v): arc_half_angle_deg = v; _update_visual_gizmo()
@export var arc_radius: float = 50.0:
	set(v): arc_radius = v; _update_visual_gizmo()
@export var vertical_threshold: float = 0.5:
	set(v): vertical_threshold = v; _update_visual_gizmo()

@export_group("Visuals")
@export var show_gizmo: bool = true:
	set(v): show_gizmo = v; if gizmo_node: gizmo_node.visible = v

@export_group("Debug")
@export var debug_arc: bool = false  # ← HIER: Standard auf false setzen!

# ===== INTERN =====
var weapon_instance: Node3D
var gizmo_node:      MeshInstance3D
var is_weapon_ready: bool = false

# ===== CORE =====
func _ready():
	if Engine.is_editor_hint():
		_setup_gizmo()
		return

	# Debug-Status zu Beginn ausgeben
	if debug_arc:
		_dbg("=== MOUNT READY: %s ===" % name)
		_dbg("  mount_position : %s" % MountPosition.keys()[mount_position])
		_dbg("  weapon_type    : %s" % WeaponType.keys()[weapon_type])
		_dbg("  arc_radius     : %.1f" % arc_radius)
		_dbg("  arc_half_angle : %.1f°" % arc_half_angle_deg)
		_dbg("  vert_threshold : %.2f (nur DORSAL/VENTRAL)" % vertical_threshold)
		_dbg("  debug_arc      : %s" % debug_arc)
	else:
		# Kurze Initialisierungsmeldung ohne Details
		print("[WeaponMount:%s] Initialisiert (debug_arc=aus)" % name)

	call_deferred("_connect_weapon_node")

func _process(_delta):
	if not Engine.is_editor_hint():
		_check_firing_constraints()

# ===== WAFFE INSTANZIIEREN =====
func _connect_weapon_node():
	if not weapon_scene:
		push_error("[WeaponMount] %s: weapon_scene nicht gesetzt!" % name)
		return

	var attach_parent := get_node_or_null(weapon_attach_path)
	if not attach_parent:
		push_error("[WeaponMount] %s: weapon_attach_path nicht gefunden!" % name)
		return

	var curve_source := get_node_or_null(curve_source_path) as Path3D
	# curve_source_path ist OPTIONAL.
	# Federation-Stil (Phaser): Path3D nötig → Partikel laufen entlang der Kurve zusammen.
	# Klingon/Romulan-Stil (Disruptor): kein Path → BeamWeapon3D springt direkt in TRACKING.
	# Wenn nicht gesetzt → weapon_instance.path bleibt null, was BeamWeapon3D korrekt behandelt.
	if not curve_source and not curve_source_path.is_empty():
		if debug_arc:
			push_warning("[WeaponMount] %s: curve_source_path '%s' nicht gefunden – kein Path-Effekt." % [
				name, curve_source_path])

	weapon_instance = weapon_scene.instantiate()
	attach_parent.add_child(weapon_instance)
	
	if debug_arc:
		_dbg("  → '%s' instanziiert unter '%s'" % [weapon_instance.name, attach_parent.name])

	# Path nur setzen wenn vorhanden – nil = kein Lade-Animations-Effekt (Klingon-Stil)
	weapon_instance.path = curve_source
	if debug_arc:
		if curve_source:
			_dbg("  → path = '%s' ✓" % curve_source.name)
		else:
			_dbg("  → path = null (kein Kurven-Effekt – Direkt-Feuer-Stil)")

	if weapon_data:
		weapon_instance.weapon_data = weapon_data
		if debug_arc:
			_dbg("  → weapon_data = '%s' ✓" % weapon_data.weapon_name)
	else:
		push_warning("[WeaponMount] %s: weapon_data nicht gesetzt – Standard-Werte!" % name)

	weapon_instance._initialize_nodes()
	weapon_instance.local_target_height = mouse_target_height

	# Sounds + Fade-Einstellungen vom Mount auf die Waffen-Instanz übertragen
	if "charge_sound" in weapon_instance:
		weapon_instance.charge_sound = charge_sound
	if "fire_sound" in weapon_instance:
		weapon_instance.fire_sound = fire_sound
	if "charge_volume_offset_db" in weapon_instance:
		weapon_instance.charge_volume_offset_db = charge_volume_offset_db
	if "fire_volume_offset_db" in weapon_instance:
		weapon_instance.fire_volume_offset_db = fire_volume_offset_db
	if "no_distance_attenuation" in weapon_instance:
		weapon_instance.no_distance_attenuation = no_distance_attenuation
	if "charge_fade_out_time" in weapon_instance:
		weapon_instance.charge_fade_out_time = charge_fade_out_time
	if "fire_fade_out_time" in weapon_instance:
		weapon_instance.fire_fade_out_time = fire_fade_out_time
	if "charge_fade_curve" in weapon_instance:
		weapon_instance.charge_fade_curve = charge_fade_curve
	if "fire_fade_curve" in weapon_instance:
		weapon_instance.fire_fade_curve = fire_fade_curve

	# ── Audio-Debug ───────────────────────────────────────────────────────────
	print("[WeaponMount:%s] 🔊 Audio-Setup:" % name)
	print("  charge_sound : %s" % ("✅ " + charge_sound.resource_path if charge_sound else "❌ nicht gesetzt"))
	print("  fire_sound   : %s" % ("✅ " + fire_sound.resource_path   if fire_sound   else "❌ nicht gesetzt"))
	var pool := get_node_or_null("/root/PhaserAudioPool")
	print("  PhaserAudioPool: %s" % ("✅ gefunden" if pool else "❌ NICHT gefunden – Autoload aktiv?"))
	if pool:
		var charge_ok: bool = weapon_instance.charging_started.is_connected(pool._on_charging_started)
		var fired_ok:  bool = weapon_instance.fired.is_connected(pool._on_fired)
		var stop_ok:   bool = weapon_instance.beam_stopped.is_connected(pool._on_beam_stopped)
		print("  Signal charging_started → Pool: %s" % ("✅" if charge_ok else "❌ nicht verbunden"))
		print("  Signal fired            → Pool: %s" % ("✅" if fired_ok  else "❌ nicht verbunden"))
		print("  Signal beam_stopped     → Pool: %s" % ("✅" if stop_ok   else "❌ nicht verbunden"))

	is_weapon_ready = true
	if debug_arc:
		_dbg("  is_weapon_ready = true ✓")

# ===== ARC CHECK =====

## ── SHAPE-AWARE (Primärpfad) ──────────────────────────────────────────────────
## Prüft ob ein Ziel-Node in Range UND im Feuersektor liegt.
## Berücksichtigt die Winkelausdehnung der CollisionShape (angular extent):
##   → Ein großes Schiff gilt als "im Arc" sobald sein Rumpfrand den Sektor berührt,
##     auch wenn der Ursprung noch außerhalb liegt.
## Delegiert Range- und Winkel-Check an BeamWeapon3D wenn die Waffe bereit ist,
## fällt sonst auf die positions-basierte Methode zurück.
func is_target_node_in_arc(target_node: Node3D) -> bool:
	if not is_instance_valid(target_node):
		return false
	var target_pos := target_node.global_position

	# 1. Vertikal-Check (DORSAL/VENTRAL) – shape-aware mit Kollisionsradius
	#
	# Problem des naiven Checks: Er vergleicht nur das Zentrum des Ziels mit dem
	# vertical_threshold. Stehen beide Schiffe auf derselben Hoehe (delta_y ~ 0),
	# schlaegt der DORSAL-Check fehl obwohl die obere Haelfte des Zielschiffs klar
	# im DORSAL-Bereich liegt.
	#
	# Loesung: Kollisionsradius addieren/subtrahieren.
	#   DORSAL: Oberkante des Ziels = center.y + radius → muss > mount.y + threshold
	#   VENTRAL: Unterkante des Ziels = center.y - radius → muss < mount.y - threshold
	var target_radius: float = 0.0
	if weapon_instance and is_instance_valid(weapon_instance) and is_weapon_ready and weapon_instance.has_method("_get_target_collision_radius"):
		target_radius = weapon_instance._get_target_collision_radius(target_node)

	match mount_position:
		MountPosition.DORSAL:
			if not _check_vertical_with_extent(target_pos, true, target_radius):
				if debug_arc:
					_dbg("NODE ARC [DORSAL] Δy=%.2f radius=%.1f threshold=%.2f → false" \
						% [target_pos.y - global_position.y, target_radius, vertical_threshold])
				return false
		MountPosition.VENTRAL:
			if not _check_vertical_with_extent(target_pos, false, target_radius):
				if debug_arc:
					_dbg("NODE ARC [VENTRAL] Δy=%.2f radius=%.1f threshold=%.2f → false" \
						% [target_pos.y - global_position.y, target_radius, vertical_threshold])
				return false

	# 2. Horizontaler Range + Arc-Check — shape-aware wenn Waffe bereit
	if weapon_instance and is_instance_valid(weapon_instance) and is_weapon_ready \
	and weapon_instance.has_method("get_effective_distance_to") \
	and weapon_instance.has_method("is_target_in_arc"):
		# Effektive Distanz = Abstand zur Oberfläche der CollisionShape
		var eff_dist: float = weapon_instance.get_effective_distance_to(target_node)
		if eff_dist > arc_radius:
			if debug_arc:
				_dbg("NODE ARC: Oberfläche außerhalb Reichweite (%.1f > %.1f)" \
					% [eff_dist, arc_radius])
			return false
		# Angular-extent Arc-Check: auch Rumpfrand außerhalb Mittellinie gilt
		var fwd := -global_transform.basis.z   # Vorwärts in Weltkoordinaten
		var in_arc: bool = weapon_instance.is_target_in_arc(
			target_node, arc_half_angle_deg, fwd)
		if debug_arc:
			_dbg("NODE ARC [%s] eff_dist=%.1f | arc=%s" \
				% [MountPosition.keys()[mount_position], eff_dist, in_arc])
		return in_arc

	# Fallback: Waffe noch nicht bereit → positions-basierter Check
	return _check_horizontal_arc(target_pos)


## Shape-aware Gesamtvalidierung (Range + Arc) für einen Node3D.
## Kurzform für externe Aufrufer (z.B. AIController, ShipController).
func is_target_node_valid(target_node: Node3D) -> bool:
	return is_instance_valid(target_node) and is_target_node_in_arc(target_node)


## ── POSITIONS-BASIERT (Fallback / Maus-Targeting) ────────────────────────────
## Klassischer Check gegen eine Weltposition (kein Node, keine Shape).
## Wird verwendet für: Maus-Targeting, Fälle ohne tracking_node.
func is_target_in_arc(target_world_pos: Vector3) -> bool:
	var delta_y := target_world_pos.y - global_position.y

	match mount_position:
		MountPosition.DORSAL:
			var v := _check_vertical(target_world_pos, true)
			var h := _check_horizontal_arc(target_world_pos)
			if debug_arc:
				_dbg("ARC [DORSAL] Δy=%.2f (threshold=%.2f) → Y:%s | XZ:%s" \
					% [delta_y, vertical_threshold, v, h])
			return v and h

		MountPosition.VENTRAL:
			var v := _check_vertical(target_world_pos, false)
			var h := _check_horizontal_arc(target_world_pos)
			if debug_arc:
				_dbg("ARC [VENTRAL] Δy=%.2f (threshold=%.2f) → Y:%s | XZ:%s" \
					% [delta_y, vertical_threshold, v, h])
			return v and h

		MountPosition.FULL:
			var h := _check_horizontal_arc(target_world_pos)
			if debug_arc:
				_dbg("ARC [FULL] Δy=%.2f → XZ:%s (kein Y-Check)" % [delta_y, h])
			return h

	return true


## Klassischer Vertikal-Check ohne Radius – fuer positions-basierten Pfad (Maus-Targeting).
func _check_vertical(target_world_pos: Vector3, want_above: bool) -> bool:
	var delta_y := target_world_pos.y - global_position.y
	return delta_y > vertical_threshold if want_above else delta_y < -vertical_threshold


## Shape-aware Vertikal-Check: beruecksichtigt den Kollisionsradius des Ziels.
##
## DORSAL  (want_above=true):
##   Oberkante des Ziels = center.y + radius
##   → In Arc wenn: (delta_y + radius) > vertical_threshold
##   Beispiel: delta_y=0, radius=8, threshold=0.5 → 8 > 0.5 → true ✓
##
## VENTRAL (want_above=false):
##   Unterkante des Ziels = center.y - radius
##   → In Arc wenn: (delta_y - radius) < -vertical_threshold
##   Beispiel: delta_y=0, radius=8, threshold=0.5 → -8 < -0.5 → true ✓
func _check_vertical_with_extent(target_world_pos: Vector3, want_above: bool, radius: float) -> bool:
	var delta_y := target_world_pos.y - global_position.y
	if want_above:
		return (delta_y + radius) > vertical_threshold
	else:
		return (delta_y - radius) < -vertical_threshold


func _check_horizontal_arc(target_world_pos: Vector3) -> bool:
	var to_target := Vector2(
		target_world_pos.x - global_position.x,
		target_world_pos.z - global_position.z
	)
	var dist := to_target.length()
	if dist > arc_radius:
		if debug_arc:
			_dbg("  → außerhalb Reichweite (%.1f > %.1f)" % [dist, arc_radius])
		return false

	to_target = to_target.normalized()
	var fwd := Vector2(-global_transform.basis.z.x, -global_transform.basis.z.z).normalized()
	var angle_deg := rad_to_deg(fwd.angle_to(to_target))

	if debug_arc:
		_dbg("  → Winkel=%.1f° | half_angle=%.1f° | Dist=%.1f" % [angle_deg, arc_half_angle_deg, dist])

	return abs(angle_deg) <= arc_half_angle_deg


## Positions-basierte Gesamtvalidierung (Legacy – bleibt für externe Aufrufer).
func is_target_valid(target_pos: Vector3, weapon_range: float) -> bool:
	return global_position.distance_to(target_pos) <= weapon_range and is_target_in_arc(target_pos)


# ===== FIRING CONSTRAINTS =====
func _check_firing_constraints():
	if not weapon_instance or not is_instance_valid(weapon_instance):
		return

	var state: String = weapon_instance.get_current_state() \
						if weapon_instance.has_method("get_current_state") else ""

	if state not in ["TRACKING", "FIRING"]:
		return

	# Live Arc-Check: immer die aktuelle Zielposition prüfen.
	#
	# Priorität 1 – tracking_target ist ein live Node3D:
	#   Shape-aware Check (is_target_node_in_arc) berücksichtigt die
	#   Winkelausdehnung der CollisionShape → kein vorzeitiger Abbruch
	#   wenn der Ursprung gerade den Arc verlässt, der Rumpf aber noch drin ist.
	#
	# Priorität 2 – kein tracking_target (Maus-Targeting):
	#   Klassischer positions-basierter Check wie bisher.
	#
	# Jeder WeaponMount hat seinen eigenen Check – ein DORSAL-Phaser bricht
	# ab, während ein VENTRAL-Phaser weiter feuert.
	var tracking_target = weapon_instance.get("tracking_target")
	if tracking_target and is_instance_valid(tracking_target):
		if not is_target_node_in_arc(tracking_target as Node3D):
			if debug_arc:
				_dbg("Constraint LIVE [shape-aware]: Ziel außerhalb Arc → stop_charging()")
			weapon_instance.stop_charging()
	else:
		var live_pos: Vector3 = weapon_instance.get("current_target_world_pos")
		if not is_target_in_arc(live_pos):
			if debug_arc:
				_dbg("Constraint LIVE [pos]: Ziel außerhalb Arc → stop_charging()")
			weapon_instance.stop_charging()


# ===== GIZMO =====
func _setup_gizmo():
	if not gizmo_node:
		gizmo_node = MeshInstance3D.new()
		gizmo_node.name = "ArcVisualizer"
		add_child(gizmo_node)
	_update_visual_gizmo()


func _update_visual_gizmo():
	if not gizmo_node:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match mount_position:
		MountPosition.DORSAL:
			_draw_arc_sector(st, Color(0.2, 0.8, 0.2, 0.25))   # grün = oben
		MountPosition.VENTRAL:
			_draw_arc_sector(st, Color(0.8, 0.5, 0.1, 0.25))   # orange = unten
		MountPosition.FULL:
			_draw_arc_sector(st, Color(0.2, 0.6, 1.0, 0.25))   # blau = beides

	var mat := StandardMaterial3D.new()
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode                  = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	gizmo_node.mesh              = st.commit()
	gizmo_node.material_override = mat
	gizmo_node.visible           = show_gizmo


func _draw_arc_sector(st: SurfaceTool, color: Color):
	var half_rad     := deg_to_rad(arc_half_angle_deg)
	var steps        := 32
	var origin       := Vector3.ZERO
	var center_angle := 0.0   # alle Modi zeigen nach vorne
	for i in range(steps):
		var t0 := float(i)     / float(steps)
		var t1 := float(i + 1) / float(steps)
		var a0 := center_angle - half_rad + t0 * half_rad * 2.0
		var a1 := center_angle - half_rad + t1 * half_rad * 2.0
		var p0 := Vector3(sin(a0), 0.0, -cos(a0)) * arc_radius
		var p1 := Vector3(sin(a1), 0.0, -cos(a1)) * arc_radius
		st.set_color(color)
		st.add_vertex(origin)
		st.add_vertex(p0)
		st.add_vertex(p1)


# ===== PUBLIC API =====
func fire_at(target_pos: Vector3, weapon_range: float = INF, freeze_beam: bool = false, tracking_node: Node3D = null) -> bool:
	if not is_weapon_ready:
		return false
	if not weapon_instance or not is_instance_valid(weapon_instance):
		return false

	var state: String = weapon_instance.get_current_state() \
						if weapon_instance.has_method("get_current_state") else ""

	# ── Arc + Range Validierung ────────────────────────────────────────────────
	# Priorität 1 – tracking_node vorhanden → shape-aware Check.
	#   is_target_node_in_arc() prüft Range über effective_distance_to (Oberfläche)
	#   und Arc über angular extent (Winkelausdehnung der CollisionShape).
	# Priorität 2 – nur Positions-Check (Maus-Targeting / Fallback).
	var in_arc: bool
	if tracking_node and is_instance_valid(tracking_node):
		in_arc = is_target_node_in_arc(tracking_node)
	elif weapon_range != INF:
		in_arc = is_target_valid(target_pos, weapon_range)
	else:
		in_arc = is_target_in_arc(target_pos)

	if not in_arc:
		return false

	# Ab hier: Arc OK + Waffe bereit → nur jetzt loggen (wenn debug_arc aktiv)
	if debug_arc:
		_dbg("fire_at() | state=%s | arc=✓ | pos=%s" % [state, target_pos])

	# Arc-Check bestanden → Waffe laden.
	# Der live Arc-Check in _check_firing_constraints() übernimmt ab jetzt
	# die laufende Überwachung und bricht den Schuss ab falls nötig.
	weapon_instance.start_charging(target_pos, freeze_beam, tracking_node)

	# ── Audio Fire-Debug ──────────────────────────────────────────────────────
	var fs: AudioStream = weapon_instance.get("fire_sound")
	var cs: AudioStream = weapon_instance.get("charge_sound")
	print("[WeaponMount:%s] 🔫 fire_at() | charge_sound=%s | fire_sound=%s" % [
		name,
		cs.resource_path if cs else "NULL",
		fs.resource_path if fs else "NULL"
	])

	# ── Hit-Debug: Raycast manuell simulieren um zu sehen was getroffen wird ──
	if debug_arc:
		_debug_raycast_hit(target_pos)

	return true


func get_weapon_type()    -> WeaponType:    return weapon_type
func get_mount_position() -> MountPosition: return mount_position
func get_target_height()  -> float:         return mouse_target_height

func is_ready_to_fire() -> bool:
	if not weapon_instance or not is_instance_valid(weapon_instance):
		return false
	if weapon_instance.has_method("get_current_state"):
		return weapon_instance.get_current_state() in ["IDLE", ""]
	return is_weapon_ready

func get_weapon_state() -> String:
	if not weapon_instance or not is_instance_valid(weapon_instance):
		return "NO_WEAPON"
	if weapon_instance.has_method("get_current_state"):
		return weapon_instance.get_current_state()
	return "READY" if is_weapon_ready else "NOT_READY"

# ===== HELPER =====
func _debug_raycast_hit(target_pos: Vector3) -> void:
	# Nur ausführen wenn debug_arc aktiv
	if not debug_arc:
		return
		
	var space := get_world_3d().direct_space_state
	if not space:
		return

	# ── Eigene Mask aus ShipData lesen ────────────────────────────────────────
	var mask: int       = 0
	var ship_data_node  = null
	var temp: Node      = get_parent()
	while temp:
		if temp.has_meta("ship_controller") and temp.get("ship_data") != null:
			ship_data_node = temp.get("ship_data")
			mask           = ship_data_node.weapon_target_mask
			break
		temp = temp.get_parent()

	print("[WeaponMount:%s] ══════ RAY DEBUG ══════" % name)
	print("  Waffe pos     : %s" % global_position)
	print("  Ziel pos      : %s" % target_pos)
	print("  weapon_mask   : %d  (aktive Bits: %s)" % [mask, _bits_to_layers(mask)])
	if ship_data_node:
		print("  ship hull_lay : %d  (Bit: Layer %d)" % [
			ship_data_node.hull_layer,   _first_layer(ship_data_node.hull_layer)])
		print("  ship shld_lay : %d  (Bit: Layer %d)" % [
			ship_data_node.shield_layer, _first_layer(ship_data_node.shield_layer)])

	# ── Ziel-Schiff: Layer der Collision-Nodes ausgeben ───────────────────────
	var target_sc: Node = _find_ship_controller_at(target_pos)
	if target_sc:
		print("  ── Ziel-Schiff: '%s' ──" % target_sc.get("ship_data").ship_name \
			if target_sc.get("ship_data") else "  ── Ziel-Schiff gefunden ──")
		var hull := target_sc.find_child("HullCollision", true, false)
		if hull and hull is CollisionObject3D:
			print("    HullCollision.layer : %d  (Bits: %s)" % [
				hull.collision_layer, _bits_to_layers(hull.collision_layer)])
		var shield_sys = target_sc.get("shield_system")
		if shield_sys:
			var shield_area: Node = shield_sys.find_child("ShieldArea", true, false)
			if shield_area and shield_area is CollisionObject3D:
				var sa := shield_area as CollisionObject3D
				var sc_node: Node = shield_area.find_child("ShieldCollision", true, false)
				var enabled_str: String = "?"
				if sc_node and sc_node is CollisionShape3D:
					enabled_str = str(not (sc_node as CollisionShape3D).disabled)
				print("    ShieldArea.layer    : %d  (Bits: %s) | enabled=%s" % [
					sa.collision_layer,
					_bits_to_layers(sa.collision_layer),
					enabled_str
				])
			else:
				print("    ShieldArea          : ❌ nicht gefunden")
	else:
		print("  Ziel-ShipController : ❌ nicht gefunden")

	# ── Raycast Ergebnis ──────────────────────────────────────────────────────
	var query := PhysicsRayQueryParameters3D.create(global_position, target_pos)
	query.collision_mask      = mask
	query.collide_with_areas  = true
	query.collide_with_bodies = true
	var result := space.intersect_ray(query)

	if result.is_empty():
		print("  🔍 TREFFER       : ❌ KEIN TREFFER")
		print("    → mask (%d) trifft keinen aktiven Layer!" % mask)
	else:
		var hit_obj          = result.get("collider", null)
		var hit_name: String = hit_obj.name if hit_obj else "?"
		var hit_cls:  String = hit_obj.get_class() if hit_obj else "?"
		var hit_lay:  int    = hit_obj.collision_layer if hit_obj else -1
		var is_shield: bool  = hit_obj.has_meta("shield_system") if hit_obj else false
		print("  🔍 TREFFER       : '%s' [%s]" % [hit_name, hit_cls])
		print("    hit layer=%d  (Bits: %s)" % [hit_lay, _bits_to_layers(hit_lay)])
		print("    is_shield=%s" % is_shield)
		# Warnung wenn Hülle getroffen obwohl Schild aktiv
		if not is_shield and target_sc:
			var ssys = target_sc.get("shield_system")
			if ssys and ssys.get("_is_destroyed") == false:
				print("    ⚠️  Hülle getroffen obwohl Schild aktiv! Layer-Mismatch?")
	print("[WeaponMount:%s] ══════════════════════" % name)


## Hilfsfunktion: Bitmask → lesbarer Layer-String z.B. "1,3,4"
func _bits_to_layers(mask: int) -> String:
	var layers: Array = []
	for i in 32:
		if mask & (1 << i):
			layers.append(str(i + 1))
	return ",".join(layers) if layers.size() > 0 else "keine"


## Hilfsfunktion: ersten aktiven Layer einer Mask finden
func _first_layer(mask: int) -> int:
	for i in 32:
		if mask & (1 << i):
			return i + 1
	return 0


## Sucht ShipController in der Nähe des Zielpunkts über Gruppen
func _find_ship_controller_at(target_pos: Vector3) -> Node:
	var best_dist: float = 50.0  # Suchradius
	var best_node: Node  = null
	# Alle Schiffe über die universelle "ships"-Gruppe durchsuchen
	for node in get_tree().get_nodes_in_group("ships"):
		if not node is Node3D:
			continue
		var dist: float = (node as Node3D).global_position.distance_to(target_pos)
		if dist < best_dist:
			best_dist = dist
			best_node = node if node is ShipController else \
				(node.get_meta("ship_controller") if node.has_meta("ship_controller") else null)
	return best_node


func _dbg(msg: String):
	# Nur ausgeben wenn debug_arc aktiv
	if debug_arc:
		print("[WeaponMount:%s] %s" % [name, msg])
