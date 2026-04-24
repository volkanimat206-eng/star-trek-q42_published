# res://scripts/beam_weapon_3d.gd
# Universeller Strahl-Waffen-Controller: Ladeanimation, Strahl-Visual, Raycast und Schaden.
# Funktioniert für alle Strahl-Waffen (Phaser, Disruptor, Plasmakanone, etc.).
# Alle typspezifischen Parameter kommen aus BeamWeaponData.
# Wird von WeaponMount instanziiert und über start_charging() ausgelöst.
extends Node3D
class_name BeamWeapon3D

# ===== AUDIO SIGNALS =====
signal charging_started(is_charge_type: bool, charge_snd: AudioStream, charge_vol_offset: float)
signal fired(fire_snd: AudioStream, charge_fade_time: float, charge_curve: Curve, fire_vol_offset: float)
signal beam_stopped(fire_fade_time: float, fire_curve: Curve)

# ===== SOUNDS + FADE (werden von WeaponMount gesetzt) =====
var charge_sound:             AudioStream = null
var fire_sound:               AudioStream = null
var charge_fade_out_time:     float       = 0.3
var fire_fade_out_time:       float       = 0.2
var charge_fade_curve:        Curve       = null
var fire_fade_curve:          Curve       = null
var charge_volume_offset_db:  float       = 0.0
var fire_volume_offset_db:    float       = 0.0
var no_distance_attenuation:  bool        = false

# ===== ENUMS =====
enum AnimationState { IDLE, MOVING, TRACKING, FIRING, FADING, COOLDOWN }

## Treffertyp – bestimmt welcher Impact-Effekt gespawnt wird.
## AUTO = wird anhand eines aktiven ShieldSystems am Ziel-Node erkannt.
enum ImpactType { AUTO, HULL, SHIELD }

# ===== WAFFEN-RESOURCE =====
## Alle typspezifischen Parameter. Wird von WeaponMount vor _ready() gesetzt.
var weapon_data: BeamWeaponData

# ===== TRAIL SYSTEM =====
var _trail_timer:    float         = 0.0
var _active_impacts: Array[Node3D] = []
var _is_fading_out:  bool          = false
var _fade_out_timer: float         = 0.0

# ===== IMPACT EFFECTS =====
@export_group("Impact Effects")
@export var impact_hull_scene:   PackedScene
@export var impact_shield_scene: PackedScene

@export_group("Target Surface")
@export var surface_ray_overshoot: float = 10.0
## Streuung über die CollisionShape-Oberfläche des Ziels.
## 0.0 = immer Zentrum (altes Verhalten), 1.0 = voller Rand.
## Empfohlen: 0.65–0.80
@export_range(0.0, 1.0) var surface_scatter_factor: float = 0.75
## Wenn true: Scatter auch auf Schild-Ellipsoid anwenden (empfohlen).
@export var scatter_on_shields: bool = true

@export_group("Debug")
@export var debug_surface_raycast: bool = false
@export var debug_damage:          bool = false

# ===== NODE REFERENZEN =====
var path:                Path3D
var follow_a:            PathFollow3D
var follow_b:            PathFollow3D
var light_a:             OmniLight3D
var light_b:             OmniLight3D
var marker_a:            Marker3D
var marker_b:            Marker3D
var mesh_a:              MeshInstance3D
var mesh_b:              MeshInstance3D
var convergence_marker:  Marker3D
var local_target_marker: Marker3D
var local_target_height: float = 2.0
var use_local_target:    bool  = false

# BEAM NODES
var beam_container: Node3D
var beam_core:      MeshInstance3D
var beam_glow:      MeshInstance3D
var impact_flash:   OmniLight3D

var core_material: Material
var glow_material: Material

# ===== ZUSTANDSVARIABLEN =====
var current_state:            AnimationState = AnimationState.IDLE
var _cooldown_timer:          float          = 0.0
var animation_timer:          float          = 0.0
var current_target_ratio:     float          = 0.5
var target_target_ratio:      float          = 0.5
var current_target_world_pos: Vector3        = Vector3.ZERO
var freeze_beam_end:          bool           = false
var tracking_target:          Node3D         = null
var start_ratio_a:            float          = 0.0
var start_ratio_b:            float          = 1.0
var beam_lifetime:            float          = 0.0

var camera:        Camera3D
var viewport:      Viewport
var baked_points:  PackedVector3Array = []
var baked_lengths: PackedFloat32Array = []
var _exclude_rids: Array[RID]         = []
var _impact_type_override: ImpactType = ImpactType.AUTO

# ===== SCHADEN – INTERN =====
var _damage_timer:           float = 0.0
var _last_hit_collider:      Node  = null
var _total_damage_this_shot: float = 0.0
var _shield_slot_index:      int   = -1   # aktiver Impact-Slot im ShieldSystem des Ziels

# ── Scatter-Cache: Auftreffpunkt einmalig berechnen, danach festhalten ────────
# Im lokalen Raum des Targets gespeichert → folgt Bewegung + Rotation automatisch.
var _scatter_hit_cached:       bool    = false
var _scatter_hit_local:        Vector3 = Vector3.ZERO
# Getrennte Variable für Cache-Typ – unabhängig von _impact_type_override,
# der von _update_target_from_mouse() jeden Frame auf AUTO zurückgesetzt wird.
var _cache_was_for_shield:     bool    = false

# ── Zuletzt gemessene Aufprall-Normale (aus LOS-Raycast) ─────────────────────
# Wird jeden Schaden-Tick aus _update_surface_beam_and_damage() befüllt.
# HullImpactReceiver nutzt sie für korrekte Decal-Ausrichtung.
var _last_hit_normal: Vector3 = Vector3.ZERO

# ── LOS (Line-of-Sight) State ─────────────────────────────────────────────────
# Wird jeden Frame in _update_surface_beam_and_damage() neu berechnet.
# Getrennt vom Scatter-Cache: Cache bestimmt WO auf dem Ziel getroffen wird,
# LOS bestimmt OB der Weg dorthin frei ist und WAS ggf. dazwischen liegt.
#
# _los_actual_target: Das Objekt das den Strahl tatsächlich trifft.
#   = tracking_target  → normaler Treffer
#   = anderes Schiff   → Strahl wird durch ein zwischenstehendes Schiff blockiert
#   = null             → Strahl trifft nichts (freier Raum, keine Kollision)
#
# _los_blocked: true wenn ein ANDERES Objekt als tracking_target im Weg ist.
var _los_actual_target: Node3D = null
var _los_blocked:       bool   = false

# ── Reputation-Tracking ───────────────────────────────────────────────────────
# Wird einmalig in _ready() gesetzt – ändert sich nie während der Laufzeit.
var _owner_is_player: bool          = false
# Verhindert dass on_killed_by_player() mehrfach pro Schuss aufgerufen wird.
var _kill_reported:   bool          = false

# ===== CACHE =====
var _space_state:     PhysicsDirectSpaceState3D
var _path_transform:  Transform3D
var _convergence_pos: Vector3


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_initialize_nodes()
	viewport     = get_viewport()
	camera       = viewport.get_camera_3d()
	_space_state = get_world_3d().direct_space_state
	_precompute_baked_points()
	set_visuals_active(false)
	beam_container.visible = false
	use_local_target = (local_target_marker != null)
	_build_exclude_rids()

	# Prüfen ob diese Waffe zum Spieler gehört – einmalig cachen.
	# Spieler-Schiff hat KEINEN AIController im Elternbaum.
	_owner_is_player = not _has_ai_controller_parent()

	if debug_damage:
		var wname: String = weapon_data.weapon_name if weapon_data else "???"
		var dps: float = weapon_data.damage_per_second if weapon_data else 0.0
		var mask: int = weapon_data.get_target_mask() if weapon_data else 0
		print("✓ BeamWeapon3D '%s' bereit | %.0f DPS | Mask: %d | owner_is_player=%s" % [
			wname, dps, mask, _owner_is_player])
		if not weapon_data:
			push_warning("[BeamWeapon3D] Kein BeamWeaponData zugewiesen!")

	# Audio-Pool verbinden falls Autoload vorhanden
	_connect_audio_pool()


## Verbindet diese Waffe mit dem PhaserAudioPool-Autoload falls vorhanden.
## Kein Fehler wenn nicht gesetzt – Audio ist vollständig optional.
func _connect_audio_pool() -> void:
	var pool := get_node_or_null("/root/PhaserAudioPool")
	if not pool:
		return
	charging_started.connect(pool._on_charging_started.bind(self))
	fired.connect(pool._on_fired.bind(self))
	beam_stopped.connect(pool._on_beam_stopped.bind(self))
	# Einmalig registrieren damit Pool den richtigen Pool-Typ wählt
	if pool.has_method("register_weapon"):
		pool.register_weapon(get_instance_id(), _owner_is_player)


# ─────────────────────────────────────────────────────────────────────────────
# VISUALS
# ─────────────────────────────────────────────────────────────────────────────
func set_visuals_active(is_active: bool) -> void:
	if mesh_a: mesh_a.visible = is_active
	if mesh_b: mesh_b.visible = is_active
	if light_a:
		light_a.visible = is_active
		if not is_active: light_a.light_energy = 0.0
	if light_b:
		light_b.visible = is_active
		if not is_active: light_b.light_energy = 0.0


# ─────────────────────────────────────────────────────────────────────────────
# EXCLUDE RIDS – eigenes Schiff aus Raycast ausschließen
# ─────────────────────────────────────────────────────────────────────────────
func _build_exclude_rids() -> void:
	_exclude_rids.clear()
	var my_ship := _find_ship_root(self)
	_collect_rids_recursive(my_ship)
	if debug_surface_raycast:
		print("[BeamWeapon|EXCL] Root: '%s' | RIDs: %d" % [
			my_ship.name if my_ship else "NULL", _exclude_rids.size()])


## Sucht den ShipController im Elternbaum – funktioniert für jedes Schiff.
func _find_ship_root(node: Node) -> Node:
	var temp := node.get_parent()
	while temp:
		if temp is ShipController:
			return temp
		temp = temp.get_parent()
	return get_tree().current_scene


func _collect_rids_recursive(node: Node) -> void:
	if node is CollisionObject3D:
		_exclude_rids.append(node.get_rid())
	for child in node.get_children():
		_collect_rids_recursive(child)


# ─────────────────────────────────────────────────────────────────────────────
# NODE INIT
# ─────────────────────────────────────────────────────────────────────────────
func _initialize_nodes() -> void:
	convergence_marker = get_node_or_null("ConvergenceMarker")
	if not convergence_marker:
		convergence_marker      = Marker3D.new()
		convergence_marker.name = "ConvergenceMarker"
		add_child(convergence_marker)

	local_target_marker = get_node_or_null("LocalTargetMarker")
	if not local_target_marker:
		local_target_marker      = Marker3D.new()
		local_target_marker.name = "LocalTargetMarker"
		add_child(local_target_marker)

	beam_container = get_node_or_null("BeamContainer")
	if not beam_container:
		beam_container      = Node3D.new()
		beam_container.name = "BeamContainer"
		add_child(beam_container)

	beam_core    = beam_container.get_node_or_null("BeamCore")
	beam_glow    = beam_container.get_node_or_null("BeamGlow")
	impact_flash = beam_container.get_node_or_null("ImpactFlash")

	# Beam-Meshes auf Render-Layer 2 setzen.
	# Decals auf dem HIR projizieren nur auf Layer 1 (Schiffshülle) →
	# Beam-Geometrie wird dadurch von Decal-Projektion ausgeschlossen.
	if beam_core:  beam_core.layers  = 2
	if beam_glow:  beam_glow.layers  = 2

	if not path:
		return

	_precompute_baked_points()
	follow_a = path.get_node_or_null("PathFollow3D_A")
	follow_b = path.get_node_or_null("PathFollow3D_B")
	if not follow_a or not follow_b:
		push_error("[BeamWeapon3D] PathFollow3D_A/B fehlt unter '%s'!" % path.name)
		return

	marker_a = follow_a.get_node_or_null("Marker3D_A")
	light_a  = follow_a.get_node_or_null("OmniLight3D_A")
	mesh_a   = follow_a.get_node_or_null("MeshInstance3D_A")
	marker_b = follow_b.get_node_or_null("Marker3D_B")
	light_b  = follow_b.get_node_or_null("OmniLight3D_B")
	mesh_b   = follow_b.get_node_or_null("MeshInstance3D_B")

	# Ladepartikel-Meshes ebenfalls auf Layer 2 → kein Decal-Overlap
	if mesh_a: mesh_a.layers = 2
	if mesh_b: mesh_b.layers = 2

	set_visuals_active(false)



func _precompute_baked_points() -> void:
	if not path or not path.curve:
		return
	baked_points = path.curve.get_baked_points()
	baked_lengths.resize(baked_points.size())
	var total_length: float = 0.0
	baked_lengths[0] = 0.0
	for i in range(1, baked_points.size()):
		var seg: float   = baked_points[i].distance_to(baked_points[i - 1])
		total_length    += seg
		baked_lengths[i] = total_length
	_path_transform = path.global_transform


# ─────────────────────────────────────────────────────────────────────────────
# MAIN PROCESS
# ─────────────────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	_convergence_pos = convergence_marker.global_position \
		if convergence_marker else global_position

	if use_local_target:
		_update_local_target_marker()

	match current_state:
		AnimationState.MOVING:
			_update_charge_animation(delta)
			_update_light_pulse(delta)
			_update_convergence_marker()

		AnimationState.TRACKING:
			_update_target_from_mouse()
			_update_tracking(delta)
			_update_light_pulse(delta)
			_update_convergence_marker()
			animation_timer += delta
			# Mit Path: kurz warten bis Partikel konvergiert sind (0.1s reicht)
			# Ohne Path (Klingon-Stil): charge_duration als Lade-Timer
			var fire_threshold: float = 0.1 if path else \
				(weapon_data.charge_duration if weapon_data else 0.5)
			if animation_timer >= fire_threshold:
				_trigger_fire()

		AnimationState.FIRING:
			_update_target_from_mouse()
			_update_tracking(delta)
			_update_convergence_marker()
			_update_surface_beam_and_damage(delta)
			beam_lifetime += delta
			var fire_dur: float = weapon_data.fire_duration if weapon_data else 0.3
			if beam_lifetime >= fire_dur:
				_start_fade_out()

		AnimationState.FADING:
			_update_fade_out(delta)
		AnimationState.COOLDOWN:
			_cooldown_timer -= delta
			if _cooldown_timer <= 0.0:
				current_state = AnimationState.IDLE


# ─────────────────────────────────────────────────────────────────────────────
# SCHADEN
# ─────────────────────────────────────────────────────────────────────────────

# Ersetze die _update_surface_beam_and_damage Funktion mit dieser Version
func _update_surface_beam_and_damage(delta: float) -> void:
	if not _is_target_valid():
		_last_hit_collider = null
		return

	# ── Schritt 0: Prüfe ob der Cache noch gültig ist (bei Bewegung) ─────────
	# WICHTIG: Der Cache speichert den Trefferpunkt im lokalen Raum des Ziels.
	# Aber wenn sich das Ziel relativ zur Waffe bewegt hat, kann der Punkt
	# jetzt auf der falschen Seite des Schiffs liegen.
	# Lösung: Jeden Frame prüfen ob der gecachte Punkt noch sichtbar ist.
	if _scatter_hit_cached:
		var cached_world_pos := tracking_target.to_global(_scatter_hit_local)
		var dir_to_cached := (cached_world_pos - _convergence_pos).normalized()
		
		# Kurzer Raycast zum gecachten Punkt – wenn blockiert, Cache ungültig
		var quick_check := PhysicsRayQueryParameters3D.create(
			_convergence_pos, 
			cached_world_pos
		)
		quick_check.collision_mask = weapon_data.get_target_mask() if weapon_data else 0xFFFFFF
		quick_check.exclude = _exclude_rids
		quick_check.collide_with_areas = true
		quick_check.collide_with_bodies = true
		
		var check_result := _space_state.intersect_ray(quick_check)
		
		# Cache ungültig wenn:
		# 1. Nichts getroffen (Ziel weg) ODER
		# 2. Getroffener Node != tracking_target (anderes Schiff im Weg) ODER
		# 3. Distanz stark abweicht (Ziel hat sich gedreht)
		if not check_result.is_empty():
			var hit_node := _find_damageable_node(check_result.collider as Node3D)
			var hit_dist := _convergence_pos.distance_to(check_result.position)
			var cached_dist := _convergence_pos.distance_to(cached_world_pos)
			
			if hit_node != tracking_target or abs(hit_dist - cached_dist) > 3.0:
				if debug_surface_raycast:
					print("[BeamWeapon|CACHE] Bewegung erkannt – Cache ungültig | hit=%s dist_diff=%.1f" % [
						hit_node.name if hit_node else "null", 
						abs(hit_dist - cached_dist)
					])
				_scatter_hit_cached = false
				_scatter_hit_local = Vector3.ZERO
				_cache_was_for_shield = false

	# ── Schritt 1: intended_pos – korrekte Trefferposition auf dem Ziel ──────
	var intended_pos := _get_nearest_surface_pos(_convergence_pos, tracking_target)

	# ── Schritt 2: LOS-Check ────────────────────────────────────────────────
	var los_result  := _check_line_of_sight(_convergence_pos, intended_pos)
	var los_pos:    Vector3 = los_result[0]
	var los_node:   Node3D  = los_result[1]
	var los_normal: Vector3 = los_result[2]
	_last_hit_normal = los_normal

	var tgt_sc := DamageDealer.get_ship_controller(tracking_target)

	# ── Cache-Validierung für Schild-Modus ───────────────────────────────────
	# In _update_surface_beam_and_damage(), ersetze die Cache-Validierung:
	if _cache_was_for_shield:
		# Nur Schild-Cache validieren
		var shield_still_active := _get_target_shield_system(tracking_target) != null
		if not shield_still_active:
			if debug_surface_raycast:
				print("[BeamWeapon|CACHE] Schild kollabiert → Cache reset → Hull-Modus")
			_scatter_hit_cached = false
			_scatter_hit_local = Vector3.ZERO
			_cache_was_for_shield = false
			intended_pos = _get_nearest_surface_pos(_convergence_pos, tracking_target)
	else:
		# Bei Hull: KEINE Cache-Validierung, weil es keinen Cache gibt!
		# _get_nearest_surface_pos() berechnet jeden Frame neu.
		pass  # Nichts tun

	# ── Blocker-Erkennung ──────────────────────────────────────────────────
	var blocker: Node3D = null
	if los_node != null:
		var los_sc := DamageDealer.get_ship_controller(los_node)
		if los_sc != null and los_sc != tgt_sc:
			blocker = los_node

	_los_blocked       = (blocker != null)
	_los_actual_target = blocker if blocker else tracking_target

	# Tatsächliche Strahl-Endposition
	var damage_pos:  Vector3 = los_pos    if blocker else intended_pos
	var damage_node: Node3D  = blocker    if blocker else tracking_target

	current_target_world_pos = damage_pos
	_last_hit_collider       = damage_node

	if debug_surface_raycast and _los_blocked:
		print("[BeamWeapon|LOS] Blockiert durch '%s'" % blocker.name)

	# ── Shield-Impact aktualisieren ─────────────────────────────────────────
	if _shield_slot_index >= 0 and not _los_blocked:
		var shield_sys := _get_target_shield_system(tracking_target)
		if shield_sys:
			shield_sys.update_beam_impact(_shield_slot_index, damage_pos)
		else:
			_shield_slot_index = -1

	if not beam_container.visible:
		beam_container.visible = true

	_update_beam_geometry()

	# Trail
	_trail_timer += delta
	var spawn_iv: float = weapon_data.trail_spawn_interval if weapon_data else 0.05
	if _trail_timer >= spawn_iv:
		_trail_timer = 0.0
		_spawn_trail_impact(damage_pos, _convergence_pos)

	# Schaden
	_damage_timer -= delta
	var dmg_iv: float = weapon_data.damage_interval if weapon_data else 0.08
	if _damage_timer <= 0.0:
		_damage_timer = dmg_iv
		_apply_damage_tick(damage_pos, damage_node)


# UND ersetze _get_nearest_surface_pos mit dieser optimierten Version:

func _get_nearest_surface_pos(from: Vector3, target_node: Node3D) -> Vector3:
	if not _space_state or not is_instance_valid(target_node):
		return target_node.global_position

	# ── Cache-Treffer: bereits berechnet → mitbewegen ───────────────────────
	if _scatter_hit_cached:
		return target_node.to_global(_scatter_hit_local)

	# ── Erstmalige Berechnung des Auftreffpunkts ───────────────────────────
	var target_origin  := target_node.global_position
	var direction      := target_origin - from
	var dist_to_center := direction.length()

	if direction.length_squared() < 0.0001:
		_scatter_hit_cached = true
		_scatter_hit_local  = Vector3.ZERO
		_cache_was_for_shield = false
		return target_origin

	var dir_norm := direction.normalized()

	# ── Schild aktiv? ──────────────────────────────────────────────────────
	var shield_sys := _get_target_shield_system(target_node)
	if shield_sys:
		_cache_was_for_shield = true
		_impact_type_override = ImpactType.SHIELD
		
		var effective_dir: Vector3 = dir_norm
		if scatter_on_shields and surface_scatter_factor > 0.0:
			var aim_point  := _get_scattered_aim_point(from, target_node)
			effective_dir   = (aim_point - from).normalized()
		
		var shield_pos := _get_ellipsoid_impact_pos(from, effective_dir, shield_sys)
		_scatter_hit_local   = target_node.to_local(shield_pos)
		_scatter_hit_cached  = true
		
		if debug_surface_raycast:
			print("[BeamWeapon|RAY] Schild (gecached): %s" % shield_pos.snappedf(0.1))
		return shield_pos

	# ── Kein Schild → Hull-Raycast OHNE Scatter-Cache! ─────────────────────
	# WICHTIG: Bei Hull-Treffern darf kein Cache verwendet werden, weil sich
	# das Ziel relativ zur Waffe bewegt. Stattdessen: Jeden Frame neu berechnen.
	_cache_was_for_shield = false
	_impact_type_override = ImpactType.HULL
	
	# WICHTIG: Bei Hull-Treffern KEIN Scatter mehr!
	# Scatter wurde bereits in _get_scattered_aim_point() für den ersten Treffer
	# verwendet. Jeder weitere Frame soll präzise auf EXAKT dieselbe Stelle zielen.
	# Aber weil die Hülle dünner ist als der Schild, müssen wir direkt auf die
	# CollisionShape zielen, nicht durch Overshoot.
	
	# Direkter Raycast auf das Ziel (kein Overshoot, kein Scatter mehr)
	var surface_mask: int = weapon_data.get_target_mask() if weapon_data else 0xFFFFFF
	var query := PhysicsRayQueryParameters3D.create(from, target_origin)
	query.collision_mask      = surface_mask
	query.exclude             = _exclude_rids
	query.hit_back_faces      = false
	query.collide_with_areas  = false
	query.collide_with_bodies = true

	var result := _space_state.intersect_ray(query)
	
	var hit_pos: Vector3
	if result.is_empty():
		# Fallback: Immer noch kein Treffer? Dann Overshoot versuchen
		var overshoot_target = target_origin + dir_norm * surface_ray_overshoot
		var query2 := PhysicsRayQueryParameters3D.create(from, overshoot_target)
		query2.collision_mask = surface_mask
		query2.exclude = _exclude_rids
		query2.hit_back_faces = false
		query2.collide_with_areas = false
		query2.collide_with_bodies = true
		
		var result2 := _space_state.intersect_ray(query2)
		if result2.is_empty():
			if debug_surface_raycast:
				print("[BeamWeapon|RAY] Kein Treffer → Fallback auf Zielmitte")
			hit_pos = target_origin
		else:
			hit_pos = result2.position
			if debug_surface_raycast:
				print("[BeamWeapon|RAY] Overshoot-Treffer: %s" % hit_pos.snappedf(0.1))
	else:
		hit_pos = result.position
		if debug_surface_raycast:
			var col_name: String = (result.collider as Node).name if result.get("collider") else "?"
			print("[BeamWeapon|RAY] Hull-Treffer '%s': %s" % [col_name, hit_pos.snappedf(0.1)])

	# KEIN CACHE für Hull-Treffer! Jeder Frame neu berechnen.
	# Der Cache würde nur Probleme machen, weil sich das Ziel bewegt.
	# Stattdessen: _scatter_hit_cached bleibt FALSE für Hull.
	# Die Variable wird nur für Schild-Treffer verwendet.
	
	return hit_pos

func _is_target_valid() -> bool:
	return tracking_target != null and is_instance_valid(tracking_target)


## LOS-Raycast (Line of Sight): prueft jeden Frame ob der Weg von der Waffe
## zum geplanten Zielpunkt frei ist.
##
## Rueckgabe: [hit_position: Vector3, hit_node: Node3D]
##   hit_node == tracking_target  → normaler Treffer, nichts im Weg
##   hit_node == anderer Node3D   → Strahl durch zwischenstehendes Schiff blockiert
##                                   → Schaden geht an dieses Schiff
##   hit_node == null             → Strahl trifft nur leeren Raum (kein Kollisions-Koerper
##                                   an intended_pos, z.B. nach Zerstoerung)
##
## Wichtig: _exclude_rids schliesst das eigene Schiff aus, sodass der Strahl
## nicht durch die eigene Geometrie geblockt wird.
func _check_line_of_sight(from: Vector3, intended_pos: Vector3) -> Array:
	if not _space_state:
		return [intended_pos, tracking_target]

	# Overshoot damit der Raycast nicht haarscharf an der Oberflaeche stoppt
	var dir      := (intended_pos - from)
	var shoot_to := intended_pos + dir.normalized() * 0.5

	var surface_mask: int = weapon_data.get_target_mask() if weapon_data else 0xFFFFFF

	# WICHTIG: collide_with_areas = true damit Schild-Area3D erkannt wird.
	# Ohne das wuerde der Raycast durch den Schild hindurchgehen und direkt
	# die Huelle treffen → keine Schild-Effekte, kein Schild-Schaden.
	var query := PhysicsRayQueryParameters3D.create(from, shoot_to)
	query.collision_mask      = surface_mask
	query.exclude             = _exclude_rids
	query.hit_back_faces      = false
	query.collide_with_areas  = true
	query.collide_with_bodies = true

	var result := _space_state.intersect_ray(query)

	if result.is_empty():
		# Nichts getroffen – Strahl endet an intended_pos
		return [intended_pos, null, Vector3.ZERO]

	var hit_pos:    Vector3 = result.position
	var hit_normal: Vector3 = result.normal
	var hit_body:   Node3D  = result.collider as Node3D

	# ShipController des getroffenen Objekts finden.
	# Funktioniert fuer Bodies (HullCollision) und Areas (ShieldArea).
	var hit_node: Node3D = _find_damageable_node(hit_body)

	return [hit_pos, hit_node, hit_normal]


## Sucht den ShipController eines getroffenen Kollisions-Nodes.
## Geht den Baum nach oben – funktioniert fuer HullCollision (RigidBody/StaticBody)
## und ShieldArea (Area3D), da beide irgendwo unter einem ShipController liegen.
func _find_damageable_node(hit_body: Node3D) -> Node3D:
	if not hit_body:
		return null
	var node: Node = hit_body
	while node:
		if node is ShipController:
			return node as Node3D
		node = node.get_parent()
	# Kein ShipController gefunden – Body direkt zurueckgeben
	return hit_body


func _apply_damage_tick(hit_pos: Vector3, hit_node: Node3D) -> void:
	var dps:     float  = weapon_data.damage_per_second if weapon_data else 80.0
	var dmg_iv:  float  = weapon_data.damage_interval   if weapon_data else 0.08
	var d_type:  String = weapon_data.damage_type        if weapon_data else "phaser"
	var b_color: Color  = weapon_data.beam_color         if weapon_data else Color(0.4, 0.8, 1.0)
	var tick_dmg := dps * dmg_iv

	var result      := DamageDealer.apply_ex(hit_node, tick_dmg, hit_pos, d_type, b_color, _shield_slot_index)
	var hull_damage := result[0] as float
	var slot        := result[1] as int

	if hull_damage < 0.0:
		if debug_damage:
			print("[BeamWeapon] Treffer auf '%s' → kein ShipController" % hit_node.name)
		return

	if slot >= 0:
		_shield_slot_index = slot

	_total_damage_this_shot += tick_dmg

	# ── HullImpactReceiver: Auftreffpunkt-Glow jeden Schaden-Tick melden ────
	# WICHTIG: Suche strikt auf den ShipController des getroffenen Schiffs begrenzen.
	# get_parent() wuerde den gemeinsamen World-Node liefern → find_child() findet
	# dann den ersten HIR in der gesamten Szene, nicht den des getroffenen Schiffs.
	#
	# Korrekte Hierarchie-Suche:
	#   1. ShipController selbst (HIR direkt darunter)
	#   2. ShipController.get_parent() = Ship-Root-Node (z.B. "SphereTest")
	#      → aber NUR bis max. 2 Ebenen nach oben, nicht bis World
	var sc_impact := DamageDealer.get_ship_controller(hit_node)
	if sc_impact:
		var hull_receiver: HullImpactReceiver = null
		# Zuerst direkt unter ShipController suchen
		hull_receiver = sc_impact.find_child("HullImpactReceiver", true, false) as HullImpactReceiver
		# Falls nicht gefunden: eine Ebene hoch zum Ship-Root-Node
		if not hull_receiver:
			var ship_root: Node = sc_impact.get_parent()
			# Sicherheitscheck: Ship-Root darf nicht die Szene-Root sein
			if ship_root and ship_root != get_tree().current_scene:
				hull_receiver = ship_root.find_child("HullImpactReceiver", true, false) as HullImpactReceiver
		if hull_receiver:
			hull_receiver.register_impact(hit_pos, _last_hit_normal)
		elif debug_damage:
			print("[BeamWeapon] HullImpactReceiver nicht gefunden unter ShipController '%s'" % sc_impact.name)

	# ── Reputation: Spieler trifft NPC ───────────────────────────────────────
	# Nur melden wenn DIESE Waffe dem Spieler gehört und das Ziel ein NPC ist.
	# ReputationSystem throttled intern – kein Spam bei Beam-Waffen.
	if _owner_is_player:
		var ai := _find_target_ai(hit_node)
		if ai:
			ai.on_hit_by_player(tick_dmg)
			# Kill-Check: ShipController HP auf 0?
			if not _kill_reported and _is_target_ship_dead(hit_node):
				_kill_reported = true
				ai.on_killed_by_player()

	if debug_damage:
		print("[BeamWeapon|%s] Tick: %.1f | Hülle: %.1f | Gesamt: %.0f" % [
			weapon_data.weapon_name if weapon_data else "?",
			tick_dmg, hull_damage, _total_damage_this_shot
		])


# ─────────────────────────────────────────────────────────────────────────────
# RAYCAST – OBERFLÄCHEN-ERKENNUNG MIT SCATTER UND OVERSHOOT
# ─────────────────────────────────────────────────────────────────────────────

## Liest den approximierten Radius der ersten CollisionShape3D des Targets.
## Unterstützt: Sphere, Box, Capsule, Cylinder, ConvexPolygon.
## Fallback: 5.0 Einheiten wenn keine Shape gefunden.
func _get_target_collision_radius(target_node: Node3D) -> float:
	for child in target_node.get_children():
		if child is CollisionShape3D:
			var shape := (child as CollisionShape3D).shape
			if not shape:
				continue
			if shape is SphereShape3D:
				return (shape as SphereShape3D).radius
			elif shape is BoxShape3D:
				var s: Vector3 = (shape as BoxShape3D).size
				return max(s.x, s.z) * 0.5
			elif shape is CapsuleShape3D:
				return (shape as CapsuleShape3D).radius
			elif shape is CylinderShape3D:
				return (shape as CylinderShape3D).radius
			elif shape is ConvexPolygonShape3D:
				var max_r := 0.0
				for pt: Vector3 in (shape as ConvexPolygonShape3D).points:
					max_r = max(max_r, Vector2(pt.x, pt.z).length())
				return max_r
	# Fallback: Kind-Nodes rekursiv nach CollisionShape3D durchsuchen
	for child in target_node.get_children():
		var r := _get_target_collision_radius(child as Node3D) if child is Node3D else 0.0
		if r > 0.0:
			return r
	return 5.0


## ── NEU: Gibt den dem Schützen nächstgelegenen Punkt auf der approximierten
## CollisionShape-Oberfläche zurück (Weltkoordinaten).
##
## Geometrisches Prinzip (Kugel-Approximation mit _get_target_collision_radius):
##   nearest = target_origin + normalize(from → target) umgekehrt * radius
##   → also der Rand der Form der dem Schützen am nächsten liegt.
##
## Zweck: Ermöglicht Range- und Arc-Checks gegen die *Oberfläche* statt
## gegen den Ursprungspunkt – relevant bei großen Schiffen (Galaxy-Klasse,
## Bird-of-Prey von der Seite), deren Zentrum außerhalb von Range/Arc liegt,
## deren Rumpf aber bereits im Feuersektor ist.
func _get_nearest_collision_surface_point(from: Vector3, target_node: Node3D) -> Vector3:
	var target_pos := target_node.global_position
	var to_shooter := from - target_pos
	var dist       := to_shooter.length()
	if dist < 0.0001:
		return target_pos  # Schütze steckt im Ziel – Fallback
	var radius := _get_target_collision_radius(target_node)
	return target_pos + (to_shooter / dist) * radius


## ── NEU (Public API für WeaponMount): Effektive Distanz vom Konvergenzpunkt
## zum nächsten Punkt der CollisionShape des Ziels.
##
## Verwendung in WeaponMount:
##   if beam_weapon.get_effective_distance_to(target) <= arc_radius: ...
##
## Fällt auf global_position zurück wenn convergence_marker fehlt.
func get_effective_distance_to(target_node: Node3D) -> float:
	if not is_instance_valid(target_node):
		return INF
	var origin := convergence_marker.global_position \
		if convergence_marker else global_position
	var nearest := _get_nearest_collision_surface_point(origin, target_node)
	return origin.distance_to(nearest)


## ── NEU (Public API für WeaponMount): Arc-Check mit Winkelausdehnung
## der CollisionShape (Angular Extent).
##
## Prüft ob die zugewandte Seite der Kollisionsform im Feuersektor liegt –
## nicht nur ob der Mittelpunkt drin ist.
##
## Parameter:
##   target_node        – das Zielschiff (Node3D)
##   arc_half_angle_deg – halber Öffnungswinkel des Arcs in Grad (z.B. 45 für 90°-Arc)
##   forward_dir        – Vorwärtsrichtung des WeaponMounts in Weltkoordinaten
##                        (üblicherweise -global_transform.basis.z)
##
## Mathematik:
##   angle_to_center  = Winkel zwischen forward_dir und Richtung zum Zielzentrum
##   angular_radius   = arcsin(collision_radius / dist_to_center)
##   In Arc wenn: (angle_to_center - effective_radius) ≤ arc_half_angle_deg
##
## WICHTIG – Begrenzung der Formenausdehnung:
##   Ohne Cap würde der angular_radius den effektiven Arc bei nahen Zielen
##   massiv aufblähen. Beispiel: Sovereign (r=34m) auf 150m Distanz ergibt
##   angular_radius=13° → bei 35° Halbwinkel käme effektiv 48° raus (fast doppelt).
##   Die 2.5D-Isometrie verstärkt das noch, weil Schiffe oft <200m auseinander sind.
##
##   Lösung: angular_radius wird auf ARC_SHAPE_EXTENT_CAP_DEG begrenzt.
##   Default 5° entspricht ca. 9% Arc-Erweiterung bei 60°-Arc — ein spürbarer
##   "das Schiff ist breit"-Bonus ohne den Arc zu sprengen.
##
## Beispiel: Ziel ist 48° von der Mittellinie entfernt, erscheint aber 3°
## groß (nach Cap) → Rand liegt bei 45° → bei 45°-Arc wird gefeuert.

## Maximum um das die Rand-Berechnung den Arc erweitern darf.
## Verhindert dass nahe/große Ziele den Arc quasi verdoppeln.
const ARC_SHAPE_EXTENT_CAP_DEG: float = 5.0

func is_target_in_arc(
		target_node:        Node3D,
		arc_half_angle_deg: float,
		forward_dir:        Vector3) -> bool:

	if not is_instance_valid(target_node):
		return false

	var origin    := convergence_marker.global_position \
		if convergence_marker else global_position
	var to_target := target_node.global_position - origin
	var dist      := to_target.length()
	if dist < 0.0001:
		return true  # Mount steckt im Ziel

	# Winkel zwischen Vorwärtsrichtung und Zielzentrum (3D)
	var angle_to_center := rad_to_deg(
		forward_dir.normalized().angle_to(to_target.normalized()))

	# Winkelausdehnung der Kollisionsform (wie groß erscheint das Schiff)
	var radius            := _get_target_collision_radius(target_node)
	var angular_radius    := rad_to_deg(asin(clamp(radius / dist, 0.0, 1.0)))
	# Cap: verhindert dass große/nahe Ziele den Arc aufblähen
	var effective_radius  := minf(angular_radius, ARC_SHAPE_EXTENT_CAP_DEG)

	var in_arc: bool = (angle_to_center - effective_radius) <= arc_half_angle_deg

	# Debug-Output über DebugManager-Flag "weapons.arc_check"
	if _has_debug_flag("weapons.arc_check"):
		print("[BeamArc|%s] center=%.1f° | radius=%.1f° (capped=%.1f°) | half=%.1f° | dist=%.0f → %s" % [
			target_node.name, angle_to_center,
			angular_radius, effective_radius,
			arc_half_angle_deg, dist,
			"✓" if in_arc else "✗"
		])

	# Feuer wenn der *Rand* der Form den Arc berührt
	return in_arc


## Defensiver Check ob ein DebugManager-Flag aktiv ist.
## Gibt false zurück wenn DebugManager-Autoload nicht existiert.
func _has_debug_flag(flag_name: String) -> bool:
	var dm: Node = get_tree().root.get_node_or_null("DebugManager")
	if not dm or not dm.has_method("get_flag"):
		return false
	return dm.get_flag(flag_name)


## Berechnet einen zufälligen Zielpunkt auf der dem Schützen zugewandten
## Seite der CollisionShape (dem "Face toward shooter").
##
## Prinzip:
##   dir_norm   = Richtung Schütze → Zielzentrum (normalisiert)
##   face_plane = Ebene senkrecht zu dir_norm durch target_origin
##   right/up   = zwei Basisvektoren dieser Ebene
##   Zufälls-Offset liegt gleichmäßig in einer Scheibe auf dieser Ebene.
##   Radius der Scheibe = collision_radius × surface_scatter_factor
##
## Ergebnis: Weltposition des zufälligen Zielpunkts (in der Mitte des Targets,
## nicht auf der Oberfläche – der anschließende Raycast trifft dann die Oberfläche).
func _get_scattered_aim_point(from: Vector3, target_node: Node3D) -> Vector3:
	var target_origin := target_node.global_position
	var to_shooter    := from - target_origin
	var dist          := to_shooter.length()

	# Kein Scatter bei degenerierten Faellen oder factor = 0
	if dist < 0.0001 or surface_scatter_factor <= 0.0:
		return target_origin

	var collision_radius := _get_target_collision_radius(target_node)

	# KERN DER KORREKTUR:
	# Scatter-Scheibe auf dem dem Schuetzen ZUGEWANDTEN Rand der CollisionShape.
	# Vorher: Scheibe lag im Zentrum -> Raycast zielte immer auf Schiffsmitte.
	# Jetzt:  Scheibe liegt auf der Schiffsseite die dem Schuetzen zugewandt ist
	#         -> Scatter streut ueber diese Flaeche -> naeheste Bereiche werden getroffen.
	var nearest_surface := target_origin + (to_shooter / dist) * collision_radius

	# Schussrichtung (Schuetze -> Ziel) als Basis fuer die Senkrecht-Vektoren
	var dir_norm := -to_shooter.normalized()
	var up_ref:  Vector3 = Vector3.UP if abs(dir_norm.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var right:   Vector3 = dir_norm.cross(up_ref).normalized()
	var up_perp: Vector3 = dir_norm.cross(right).normalized()

	# Gleichmaessige Zufallsverteilung in der Scheibe (sqrt fuer uniform density)
	var angle:          float = randf() * TAU
	var scatter_radius: float = sqrt(randf()) * collision_radius * surface_scatter_factor

	var offset: Vector3 = (cos(angle) * right + sin(angle) * up_perp) * scatter_radius
	return nearest_surface + offset


## Findet den CharacterBody3D oder Ship-Root-Node des Ziels.
## ShipController ist ein Geschwister-Node zur Schiff-Scene, nicht der Root.
## Für korrekte Radius-Berechnung und Scatter müssen wir eine Ebene höher.
func _find_physics_root(node: Node3D) -> Node3D:
	# Aufwärts bis CharacterBody3D gehen (= AIController für NPCs, Player für Spieler)
	var n: Node = node
	while n:
		if n is CharacterBody3D:
			return n as Node3D
		n = n.get_parent()
	# Fallback: ein Level über ShipController (= BirdOfPrey / Sovereign-Root)
	var parent := node.get_parent()
	if parent is Node3D:
		return parent as Node3D
	return node


## Scatter-Zielpunkt mit explizit gegebenem Root-Node und dessen Position.
func _get_scattered_aim_point_from(from: Vector3, root_node: Node3D, root_origin: Vector3) -> Vector3:
	var to_shooter := from - root_origin
	var dist       := to_shooter.length()

	if dist < 0.0001 or surface_scatter_factor <= 0.0:
		return root_origin

	var collision_radius := _get_target_collision_radius(root_node)

	var nearest_surface := root_origin + (to_shooter / dist) * collision_radius

	var dir_norm := -to_shooter.normalized()
	var up_ref:  Vector3 = Vector3.UP if abs(dir_norm.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var right:   Vector3 = dir_norm.cross(up_ref).normalized()
	var up_perp: Vector3 = dir_norm.cross(right).normalized()

	var angle:          float = randf() * TAU
	var scatter_radius: float = sqrt(randf()) * collision_radius * surface_scatter_factor

	return nearest_surface + (cos(angle) * right + sin(angle) * up_perp) * scatter_radius


## Gibt ShieldSystem zurück wenn Ziel einen aktiven Schild hat.
func _get_target_shield_system(target: Node3D) -> ShieldSystem:
	var sc := DamageDealer.get_ship_controller(target)
	if sc and sc.shield_system and sc.shield_system.is_active():
		return sc.shield_system
	return null


## Strahl-Ellipsoid-Schnitt: gibt den ersten Trefferpunkt auf dem Schild-Ellipsoid zurück.
##
## Schlüsselprinzip: Rotation R und Skalierung S werden EXPLIZIT getrennt.
## Das vermeidet jede Zweideutigkeit darüber, ob shield_xform.basis die Skalierung
## schon enthält oder nicht.
##
## Forward:  Weltkoordinaten → lokaler Rotationsraum (R⁻¹) → Einheitskugel (* inv_r)
## Backward: Einheitskugel (* radii) → lokaler Rotationsraum → Welt (R)
## → R kommt von shield_xform.basis.orthonormalized() (reine Rotation, kein Scale)
## → radii kommt von shield_sys.get_shield_radii() (explizit)
func _get_ellipsoid_impact_pos(from: Vector3, dir: Vector3, shield_sys: ShieldSystem) -> Vector3:
	var shield_xform: Transform3D = shield_sys.get_shield_global_transform()
	var center: Vector3 = shield_xform.origin

	# Rotation explizit extrahieren – orthonormalized() entfernt jegliche Skalierung
	var R:     Basis   = shield_xform.basis.orthonormalized()
	var R_inv: Basis   = R.inverse()   # = R.transposed() bei Orthonormalbasis
	var radii: Vector3 = shield_sys.get_shield_radii()
	var inv_r: Vector3 = Vector3(1.0 / radii.x, 1.0 / radii.y, 1.0 / radii.z)

	# 1. Strahl in lokalen Rotationsraum bringen
	var local_from: Vector3 = R_inv * (from - center)
	var local_dir:  Vector3 = (R_inv * dir).normalized()

	# 2. In Einheitskugel-Raum skalieren (Ellipsoid → Kugel mit Radius 1)
	var s_from: Vector3 = local_from * inv_r
	var s_dir:  Vector3 = (local_dir * inv_r).normalized()

	# 3. Kugel-Schnitt lösen (a = 1.0 weil s_dir normalisiert)
	var b:    float = 2.0 * s_from.dot(s_dir)
	var c:    float = s_from.dot(s_from) - 1.0
	var disc: float = b * b - 4.0 * c

	# Fallback: Punkt auf der Schildoberfläche dem Schützen am nächsten
	if disc < 0.0:
		return R * (s_from.normalized() * radii) + center

	var t: float = (-b - sqrt(disc)) / 2.0   # erster Schnittpunkt (Eintritt)
	if t < 0.0:
		t = (-b + sqrt(disc)) / 2.0           # from im Ellipsoid → Austrittspunkt
	if t < 0.0:
		return R * (s_from.normalized() * radii) + center

	var s_hit: Vector3 = s_from + t * s_dir   # Punkt auf der Einheitskugel

	# 4. Zurücktransformieren: undo scale → undo rotation
	# R × (s_hit * radii): erst Ellipsoid-Scale, dann Rotation – NICHT shield_sys.global_basis!
	return R * (s_hit * radii) + center


# ─────────────────────────────────────────────────────────────────────────────
# TRAIL / IMPACT EFFECTS
# ─────────────────────────────────────────────────────────────────────────────
func _spawn_trail_impact(position: Vector3, from: Vector3) -> void:
	if _is_fading_out:
		return

	var impact_type := _resolve_impact_type()
	var scene: PackedScene = impact_hull_scene \
		if impact_type == ImpactType.HULL else impact_shield_scene

	if not scene:
		return

	var instance := scene.instantiate() as Node3D
	if not instance:
		return

	var fire_dur: float = weapon_data.fire_duration if weapon_data else 0.3
	var trail_fade: float = weapon_data.trail_fade_out_time if weapon_data else 0.3
	if "linked_duration" in instance:
		instance.linked_duration = fire_dur + trail_fade

	get_tree().current_scene.add_child(instance)
	instance.global_position = position

	if position.distance_squared_to(from) > 0.0001:
		instance.look_at(position + (position - from).normalized())

	_active_impacts.append(instance)


func _resolve_impact_type() -> ImpactType:
	if _impact_type_override != ImpactType.AUTO:
		return _impact_type_override
	if _is_target_valid() and DamageDealer.has_active_shield(tracking_target):
		return ImpactType.SHIELD
	return ImpactType.HULL


# ─────────────────────────────────────────────────────────────────────────────
# FADE OUT
# ─────────────────────────────────────────────────────────────────────────────
func _start_fade_out() -> void:
	current_state          = AnimationState.FADING
	_fade_out_timer        = 0.0
	_is_fading_out         = true
	beam_container.visible = false
	beam_stopped.emit(fire_fade_out_time, fire_fade_curve)
	for impact in _active_impacts:
		if impact and is_instance_valid(impact):
			_fade_out_impact_with_tween(impact)


func _fade_out_impact_with_tween(impact: Node3D) -> void:
	for p in impact.find_children("*", "GPUParticles3D", true, false):
		(p as GPUParticles3D).emitting = false
	var trail_fade: float = weapon_data.trail_fade_out_time if weapon_data else 0.3
	for l in impact.find_children("*", "OmniLight3D", true, false):
		var tween := create_tween()
		tween.tween_property(l, "light_energy", 0.0, trail_fade)


func _update_fade_out(delta: float) -> void:
	_fade_out_timer += delta
	var trail_fade: float = weapon_data.trail_fade_out_time if weapon_data else 0.3
	if _fade_out_timer >= trail_fade:
		_cleanup_after_fire()


func _cleanup_after_fire() -> void:
	if debug_damage and _total_damage_this_shot > 0.0:
		print("[BeamWeapon] Schuss beendet | Gesamt-Schaden: %.0f" % _total_damage_this_shot)
	for impact in _active_impacts:
		if impact and is_instance_valid(impact):
			impact.queue_free()
	_active_impacts.clear()
	_is_fading_out          = false
	_total_damage_this_shot = 0.0
	_last_hit_collider      = null
	_kill_reported          = false
	_scatter_hit_cached     = false
	_scatter_hit_local      = Vector3.ZERO
	_cache_was_for_shield   = false
	_los_actual_target      = null
	_los_blocked            = false
	_end_shield_impact()
	# Nachladezeit starten statt sofort IDLE
	_cooldown_timer         = weapon_data.cooldown_duration if weapon_data else 0.0
	if _cooldown_timer > 0.0:
		current_state       = AnimationState.COOLDOWN
	else:
		current_state       = AnimationState.IDLE
	tracking_target         = null
	_impact_type_override   = ImpactType.AUTO
	set_visuals_active(false)


# ─────────────────────────────────────────────────────────────────────────────
# ANIMATION
# ─────────────────────────────────────────────────────────────────────────────
func _end_shield_impact() -> void:
	if _shield_slot_index < 0:
		return
	if _is_target_valid():
		var shield_sys := _get_target_shield_system(tracking_target)
		if shield_sys:
			shield_sys.end_beam_impact(_shield_slot_index)
	_shield_slot_index = -1


func _update_charge_animation(delta: float) -> void:
	if not follow_a or not follow_b:
		return
	animation_timer  += delta
	var charge_dur: float = weapon_data.charge_duration if weapon_data else 0.8
	var progress:   float = clamp(animation_timer / charge_dur, 0.0, 1.0)
	follow_a.progress_ratio = lerp(start_ratio_a, current_target_ratio, progress)
	follow_b.progress_ratio = lerp(start_ratio_b, current_target_ratio, progress)
	if progress >= 1.0:
		current_state   = AnimationState.TRACKING
		animation_timer = 0.0


func _update_tracking(delta: float) -> void:
	if not follow_a or not follow_b:
		return
	var t_speed: float = weapon_data.tracking_speed if weapon_data else 8.0
	current_target_ratio    = lerp(current_target_ratio, target_target_ratio, t_speed * delta)
	follow_a.progress_ratio = current_target_ratio
	follow_b.progress_ratio = current_target_ratio


func _update_convergence_marker() -> void:
	if convergence_marker and follow_a:
		convergence_marker.global_position = follow_a.global_position


func _update_local_target_marker() -> void:
	if not camera or not viewport or not local_target_marker:
		return
	var mouse_pos  := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)
	var plane      := Plane(Vector3.UP, global_position.y + local_target_height)
	var isect: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if isect:
		local_target_marker.global_position = isect
	else:
		var far_pt: Vector3 = ray_origin + ray_dir * 1000.0
		far_pt.y = global_position.y + local_target_height
		local_target_marker.global_position = far_pt


func _update_light_pulse(delta: float) -> void:
	if not light_a or not light_b:
		return
	var max_e: float = weapon_data.max_light_energy if weapon_data else 3.0
	match current_state:
		AnimationState.MOVING:
			var pulse  := (sin(Time.get_ticks_msec() * 0.015) * 0.5 + 0.5) * 2.0
			var target := max_e * 0.7 + pulse
			light_a.light_energy = move_toward(light_a.light_energy, target, delta * 15)
			light_b.light_energy = light_a.light_energy
		AnimationState.TRACKING:
			var pulse  := (sin(Time.get_ticks_msec() * 0.01) * 0.5 + 0.5) * 1.5
			var target := max_e * pulse
			light_a.light_energy = move_toward(light_a.light_energy, target, delta * 8)
			light_b.light_energy = light_a.light_energy


func _update_beam_geometry() -> void:
	if not beam_container or not convergence_marker:
		return
	var start   := _convergence_pos
	var end_pos := current_target_world_pos

	if start.distance_to(end_pos) < 0.01:
		return

	beam_container.global_position = start
	beam_container.global_rotation = Vector3.ZERO
	beam_container.look_at(end_pos, Vector3.UP)

	var distance := start.distance_to(end_pos)
	var c_width: float = weapon_data.beam_core_width if weapon_data else 0.1
	var g_width: float = weapon_data.beam_glow_width if weapon_data else 0.3

	if beam_core:
		beam_core.scale    = Vector3(c_width, c_width, distance)
		beam_core.position = Vector3(0, 0, -distance * 0.5)
	if beam_glow:
		beam_glow.scale    = Vector3(g_width, g_width, distance)
		beam_glow.position = Vector3(0, 0, -distance * 0.5)
	if impact_flash:
		impact_flash.position     = Vector3(0, 0, -distance)
		impact_flash.light_energy = 5.0


func _update_target_from_mouse() -> void:
	_impact_type_override = ImpactType.AUTO
	if not path or baked_points.is_empty():
		return
	if not _path_transform:
		_path_transform = path.global_transform

	var plane := Plane(_path_transform.basis.y.normalized(), _path_transform.origin)

	if _is_target_valid():
		var surface_pos          := _get_nearest_surface_pos(_convergence_pos, tracking_target)
		current_target_world_pos  = surface_pos
		var projected := plane.project(tracking_target.global_position)
		var closest   := find_closest_point_on_curve_global(projected)
		target_target_ratio = calculate_target_ratio(path.to_local(closest))
	else:
		if not camera or not viewport:
			return
		var mouse_pos  := viewport.get_mouse_position()
		var ray_origin := camera.project_ray_origin(mouse_pos)
		var ray_dir    := camera.project_ray_normal(mouse_pos)
		var isect: Variant = plane.intersects_ray(ray_origin, ray_dir)
		if isect:
			target_target_ratio = calculate_target_ratio(
				path.to_local(find_closest_point_on_curve_global(isect)))
		if not freeze_beam_end and local_target_marker:
			current_target_world_pos = local_target_marker.global_position


# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────
func find_closest_point_on_curve_global(world_point: Vector3) -> Vector3:
	if baked_points.is_empty() or not path:
		return global_position
	var closest_local := Vector3.ZERO
	var closest_dist:  float = INF
	for pt_local in baked_points:
		var dist: float = path.to_global(pt_local).distance_squared_to(world_point)
		if dist < closest_dist:
			closest_dist  = dist
			closest_local = pt_local
	return path.to_global(closest_local)


func calculate_target_ratio(local_pos: Vector3) -> float:
	if not path or not path.curve or baked_points.is_empty():
		return 0.5
	var closest    := path.curve.get_closest_point(local_pos)
	var offset:    float = path.curve.get_closest_offset(closest)
	var total_len: float = path.curve.get_baked_length()
	return clamp(offset / total_len, 0.0, 1.0) if total_len > 0.0 else 0.5


func _apply_fade(mat: Material, fade_value: float, base_intensity: float) -> void:
	if not mat:
		return
	if mat is ShaderMaterial:
		mat.set_shader_parameter("intensity", base_intensity * fade_value)
	elif mat is StandardMaterial3D:
		mat.emission_energy_multiplier = base_intensity * fade_value
		mat.albedo_color.a             = fade_value


func _trigger_fire() -> void:
	if current_state != AnimationState.TRACKING:
		return
	_update_beam_geometry()
	_apply_fade(core_material, 1.0, 5.0)
	_apply_fade(glow_material, 1.0, 3.0)
	beam_container.visible = true
	beam_lifetime          = 0.0
	current_state          = AnimationState.FIRING
	_damage_timer          = 0.0
	fired.emit(fire_sound, charge_fade_out_time, charge_fade_curve, fire_volume_offset_db)


# ─────────────────────────────────────────────────────────────────────────────
# STATE MACHINE – PUBLIC
# ─────────────────────────────────────────────────────────────────────────────
func start_charging(target_pos: Vector3, freeze_beam: bool = false,
					tracking_node: Node3D = null,
					impact_type: ImpactType = ImpactType.AUTO) -> void:
	if current_state != AnimationState.IDLE:
		return

	freeze_beam_end         = freeze_beam
	tracking_target         = tracking_node
	_impact_type_override   = impact_type
	_damage_timer           = 0.0
	_total_damage_this_shot = 0.0
	_last_hit_collider      = null
	_shield_slot_index      = -1
	_kill_reported          = false
	animation_timer         = 0.0
	_scatter_hit_cached     = false
	_scatter_hit_local      = Vector3.ZERO
	_cache_was_for_shield   = false
	_last_hit_normal        = Vector3.ZERO
	_los_actual_target      = null
	_los_blocked            = false

	if _is_target_valid() and convergence_marker:
		current_target_world_pos = _get_nearest_surface_pos(
			convergence_marker.global_position, tracking_node)
	else:
		current_target_world_pos = target_pos

	if path and path.curve:
		# Federation-Stil: Partikel laufen entlang Path3D zusammen
		var world_pos_on_curve := find_closest_point_on_curve_global(target_pos)
		target_target_ratio    = calculate_target_ratio(path.to_local(world_pos_on_curve))
		current_target_ratio   = target_target_ratio
		start_ratio_a          = 0.0
		start_ratio_b          = 1.0
		if follow_a: follow_a.progress_ratio = start_ratio_a
		if follow_b: follow_b.progress_ratio = start_ratio_b
		set_visuals_active(true)
		current_state = AnimationState.MOVING
		charging_started.emit(true, charge_sound, charge_volume_offset_db)
	else:
		# Klingon-Stil: kein Path → direkt in TRACKING (charge_duration als Lade-Timer)
		current_state = AnimationState.TRACKING
		charging_started.emit(false, null, 0.0)


func stop_charging() -> void:
	if current_state != AnimationState.IDLE:
		current_state          = AnimationState.IDLE
		beam_container.visible = false
		set_visuals_active(false)
		beam_stopped.emit(fire_fade_out_time, fire_fade_curve)


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────
func get_current_state() -> String:
	return AnimationState.keys()[current_state]

func is_ready_to_fire() -> bool:
	return current_state == AnimationState.IDLE

func set_shared_mouse_target(marker: Marker3D) -> void:
	local_target_marker = marker
	use_local_target    = true

func update_target_height_preview(height: float) -> void:
	local_target_height = height


# ─────────────────────────────────────────────────────────────────────────────
# REPUTATION HELPER
# ─────────────────────────────────────────────────────────────────────────────

## Gibt true zurück wenn diese Waffe im Elternbaum einen AIController hat.
## Spieler-Schiffe haben keinen AIController → _owner_is_player = true.
func _has_ai_controller_parent() -> bool:
	var node: Node = get_parent()
	while node:
		if node is AIController:
			return true
		node = node.get_parent()
	return false


## Sucht den AIController zu einem getroffenen Node.
## Geht den Baum nach oben und nach unten – funktioniert für jede Szenenhierarchie.
func _find_target_ai(hit_node: Node) -> AIController:
	# Weg nach oben: hit_node ist Kind eines AIControllers
	var node: Node = hit_node
	while node:
		if node is AIController:
			return node as AIController
		node = node.get_parent()
	# Weg nach oben bis Root, dann nach unten: AIController als Kind des Ship-Roots
	var root: Node = _find_ship_root(hit_node)
	if root and root != get_tree().current_scene:
		var parent: Node = root.get_parent()
		if parent and parent is AIController:
			return parent as AIController
	return null


## Prüft ob das Ziel-Schiff zerstört ist (kein ShipController-HP mehr).
## Anpassen wenn ein eigenes Hull-HP-System existiert.
func _is_target_ship_dead(hit_node: Node3D) -> bool:
	var sc := DamageDealer.get_ship_controller(hit_node)
	if not sc:
		return false
	# ShieldSystem kollabiert = Schiff als vernichtet werten
	# (erweitern wenn Hull-HP separat existiert)
	if sc.shield_system and not sc.shield_system.is_active():
		return true
	return false
