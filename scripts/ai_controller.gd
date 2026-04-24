# res://scripts/ai_controller.gd
@tool
extends CharacterBody3D
class_name AIController

# ─────────────────────────────────────────────────────────────────────────────
# ENUMS & KONSTANTEN
# ─────────────────────────────────────────────────────────────────────────────

enum State { PATROL, COMBAT }
enum CombatPhase { APPROACH, ORBIT, REPOSITION }

const COMBAT_SCAN_INTERVAL: float = 2.0

signal debug_log_generated(ship_name: String, message: String)

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Schiff")
@export var ship_data: ShipData

@export_group("Patrouille")
@export var patrol_radius_x:  float   = 80.0
@export var patrol_radius_z:  float   = 40.0
@export var patrol_height:    float   = 15.0
@export var patrol_speed:     float   = 0.3
@export var max_patrol_speed: float   = 60.0
@export var patrol_center:    Vector3 = Vector3.ZERO

@export_group("Lenkung")
@export var steer_gain:         float = 1.0
@export var throttle_cut_angle: float = 30.0

@export_group("Kampf")
@export var auto_fire:         bool  = true
@export var detection_radius:  float = 300.0
@export var fire_range:        float = 150.0
@export var disengage_timeout: float = 5.0
@export var chase_distance_multiplier: float = 3.0

@export_group("Kampf – Fallback")
@export var orbit_radius:                          float = 0.0
@export_range(0.5, 4.0, 0.1) var orbit_radius_scale: float = 1.0
@export var orbit_speed_deg:      float = 22.0
@export var combat_height_range:  float = 18.0
@export var reposition_interval:  float = 8.0

@export_group("Kollisionsvermeidung")
@export var player_avoidance_radius:  float = 22.0
@export var npc_avoidance_radius:     float = 18.0
@export var player_avoidance_y_speed: float = 40.0
@export var npc_separation_strength:  float = 60.0

@export_group("Radar")
@export_flags_3d_physics var radar_collision_mask: int = 1 << 5  # Layer 6 (32)

@onready var _radar: Area3D = $Radar
@onready var _scan_timer: Timer = $ScanTimer

@export_group("Debug")
@export var show_debug: bool = false:
	set(value):
		show_debug = value
		if is_node_ready() and is_instance_valid(_radar_visualizer):
			_radar_visualizer.visible = value


@onready var _radar_visualizer: MeshInstance3D = $RadarVisualizer

# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────

var ship_controller: ShipController
var _initialized: bool = false
var _state: State = State.PATROL
var _target: Node3D = null
var _pulse_tween: Tween

var debug_hostile:    bool = false
var debug_reputation: bool = false

var _curve_t:          float = 0.0
var _disengage_timer:  float = 0.0
var _combat_phase: CombatPhase = CombatPhase.APPROACH
var _orbit_angle:      float = 0.0
var _orbit_dir:        float = 1.0
var _orbit_height_t:   float = 0.0
var _reposition_timer: float = 0.0
var _reposition_dir: Vector3 = Vector3.FORWARD

var _orbit_radius_mul:  float = 1.0
var _orbit_height_mul:  float = 1.0
var _orbit_speed_mul:   float = 1.0
var _orbit_height_freq: float = 0.4
var _approach_delay:    float = 0.0

var _torpedo_fire_timer:  float = 0.0
var _combat_scan_timer:   float = 0.0
var _avoidance_y_dir: float = 0.0

# Flag für PATROL→COMBAT-Sofort-Scan wenn Ruf gerade auf HOSTILE kippt
var _reputation_became_hostile: bool = false

# ─────────────────────────────────────────────────────────────────────────────
# READY & SETUP
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	if not ship_data:
		push_error("[AIController] Kein ship_data!")
		return

	add_to_group("ships")
	add_to_group(FactionSystem.get_group_name(ship_data.faction))

	# Mehr Delay für Physics-Server
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	_setup_radar()
	_connect_signals()
	ReputationSystem.disposition_changed.connect(_on_reputation_disposition_changed)

	_instantiate_ship()

	_initialized = true
	_dbg("AIController fully initialized (3 physics frames)")

## Radar-Radius auf detection_radius synchronisieren.
## So passt sich die Area3D automatisch an den Inspector-Wert an.

func _setup_radar() -> void:
	if not is_instance_valid(_radar):
		return

	var col := _radar.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is SphereShape3D:
		col.shape.radius = detection_radius

	_radar.collision_mask = radar_collision_mask
	_radar.monitoring = true
	_radar.collision_layer = 0

	_dbg("Radar eingerichtet → Radius: %.0f | Mask: %d" % [detection_radius, radar_collision_mask])

	if is_instance_valid(_radar_visualizer):
		_radar_visualizer.scale = Vector3(detection_radius * 2, 1.0, detection_radius * 2)
		_radar_visualizer.visible = show_debug
		# FIX: Material pro Instanz duplizieren, sonst teilen sich alle NPCs
		# dieselbe StandardMaterial3D-Ressource → wenn ein NPC in Combat geht,
		# wird der Radar-Ring ALLER Sovereigns/NPCs rot. Das ist der Grund warum
		# die Sovereign "rot leuchtet" obwohl sie gar nicht in Combat ist.
		_duplicate_radar_material()


## Dupliziert das Radar-Material so dass Farbänderungen nur diese Instanz
## betreffen. Ohne diesen Fix werden Material-Overrides zwischen allen
## Schiffen gleichen Typs geshared.
func _duplicate_radar_material() -> void:
	if not is_instance_valid(_radar_visualizer):
		return
	var shared_mat: Material = _radar_visualizer.get_active_material(0)
	if not shared_mat:
		return
	# duplicate() statt direkter Zuweisung – erzeugt echte Instanz-Kopie
	_radar_visualizer.material_override = shared_mat.duplicate()

func _connect_signals() -> void:
	if is_instance_valid(_radar):
		if not _radar.body_entered.is_connected(_on_radar_body_entered):
			_radar.body_entered.connect(_on_radar_body_entered)
		if not _radar.body_exited.is_connected(_on_radar_body_exited):
			_radar.body_exited.connect(_on_radar_body_exited)

	if is_instance_valid(_scan_timer):
		if not _scan_timer.timeout.is_connected(_on_scan_timeout):
			_scan_timer.timeout.connect(_on_scan_timeout)
		if _scan_timer.is_stopped():
			_scan_timer.start()

func _update_radar_color() -> void:
	if not is_instance_valid(_radar_visualizer):
		return

	var mat = _radar_visualizer.get_active_material(0) as StandardMaterial3D
	if not mat:
		return

	if _state == State.COMBAT and is_instance_valid(_target):
		mat.albedo_color = Color(1.0, 0.15, 0.15, 0.4)
	else:
		mat.albedo_color = Color(0.1, 1.0, 0.2, 0.3)

func _instantiate_ship() -> void:
	if ship_data.ship_scene_path.is_empty(): return

	var packed := load(ship_data.ship_scene_path) as PackedScene
	if not packed: return

	var instance := packed.instantiate()
	var sc := _find_ship_controller_in(instance)
	if not sc:
		instance.queue_free()
		return

	sc.ship_data = ship_data
	add_child(instance)
	ship_controller = sc
	ship_controller.ship_destroyed.connect(_on_ship_destroyed)

	if is_instance_valid(ship_controller) and ship_controller.targeting_system:
		ship_controller.targeting_system.setup_as_npc()

	if patrol_center == Vector3.ZERO:
		patrol_center = global_position

	_curve_t    = _find_nearest_curve_t()
	_initialized = true

# ─────────────────────────────────────────────────────────────────────────────
# RADAR – SIGNAL-HANDLER
# ─────────────────────────────────────────────────────────────────────────────

func _on_radar_body_entered(body: Node3D) -> void:
	if not _initialized: return
	if _state == State.PATROL and _is_hostile_to_me(body):
		_dbg("📡 Radar body_entered: '%s' → COMBAT" % body.name)
		_enter_combat(body)


func _on_radar_body_exited(body: Node3D) -> void:
	if body == _target:
		_dbg("Radar: Ziel '%s' verlassen → Disengage-Timer gestartet" % body.name)


# ─────────────────────────────────────────────────────────────────────────────
# SCAN-TIMER – SIGNAL-HANDLER
# ─────────────────────────────────────────────────────────────────────────────

func _on_scan_timeout() -> void:
	if not _initialized or _state != State.PATROL:
		return

	var found := _find_nearest_hostile()
	if found:
		_dbg("Scan gefunden: %s → Enter Combat" % found.name)
		_enter_combat(found)

# ─────────────────────────────────────────────────────────────────────────────
# PHYSICS & LOGIC
# ─────────────────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	# Shutdown-Schutz: Beim Spiel-Quit kann _physics_process noch einen Tick
	# feuern, während Autoloads bereits abgebaut werden. is_inside_tree()
	# ist dann false und wir brechen sauber ab, bevor irgendein Zugriff
	# auf Autoloads oder get_tree() knallt.
	if not is_inside_tree():
		return

	# DebugManager-Zugriff defensiv: Autoload-Reihenfolge beim Free kann
	# je nach Godot-Version variieren.
	if is_instance_valid(DebugManager):
		var global_debug = DebugManager.get_flag("ai.debug")
		if global_debug != show_debug:
			show_debug = global_debug

	if not _initialized or not is_instance_valid(ship_controller): return

	var stats: ShipStats = ship_controller.stats
	if not stats: return

	# Wenn der Ruf gerade auf HOSTILE gekippt ist → sofort scannen (statt
	# auf den nächsten ScanTimer-Tick zu warten).
	if _reputation_became_hostile and _state == State.PATROL:
		_reputation_became_hostile = false
		var found := _find_nearest_hostile()
		if found: _enter_combat(found)

	match _state:
		State.PATROL: _tick_patrol(delta, stats)
		State.COMBAT: _tick_combat(delta, stats)


func _tick_patrol(delta: float, stats: ShipStats) -> void:
	_curve_t += delta * patrol_speed
	var desired_dir := _curve_tangent(_curve_t)
	_apply_steering(desired_dir, max_patrol_speed, stats, delta)


func _tick_combat(delta: float, stats: ShipStats) -> void:
	# === Re-Check: Ziel noch gültig UND noch feindlich? ===
	# Ohne diesen Check bleibt ein bereits gelocktes Schiff aggressiv,
	# selbst wenn der Ruf zwischendurch auf NEUTRAL/FRIENDLY wechselt.
	if not is_instance_valid(_target) or _is_target_dead():
		_enter_patrol()
		return

	if not _is_hostile_to_me(_target):
		_dbg("Ziel '%s' ist nicht mehr feindlich → PATROL" % _target.name)
		_enter_patrol()
		return

	var to_target := _target.global_position - global_position
	var dist := to_target.length()

	var max_chase_dist := detection_radius * chase_distance_multiplier

	if dist > max_chase_dist:
		_disengage_timer += delta
		if _disengage_timer >= disengage_timeout:
			_dbg("Disengage Timeout → zurück zu PATROL")
			_enter_patrol()
			return
	else:
		_disengage_timer = 0.0

	_update_combat_phase(dist, delta)

	match _combat_phase:
		CombatPhase.APPROACH:    _move_approach(to_target, dist, stats, delta)
		CombatPhase.ORBIT:       _move_orbit(dist, stats, delta)
		CombatPhase.REPOSITION:  _move_reposition(stats, delta)

	if auto_fire:
		_handle_weapons(to_target, dist, delta)


func _update_combat_phase(dist: float, delta: float) -> void:
	var effective_orbit := _get_orbit_radius()

	match _combat_phase:
		CombatPhase.APPROACH:
			if dist <= effective_orbit * 1.1:
				_combat_phase    = CombatPhase.ORBIT
				_reposition_timer = _random_reposition_time()
				_orbit_dir        = 1.0 if randf() > 0.5 else -1.0

		CombatPhase.ORBIT:
			_reposition_timer -= delta
			if _reposition_timer <= 0.0:
				_combat_phase    = CombatPhase.REPOSITION
				_reposition_timer = randf_range(2.0, 4.0)
				_reposition_dir   = (global_transform.basis.x * _orbit_dir
									 + global_transform.basis.z * 0.5).normalized()

		CombatPhase.REPOSITION:
			_reposition_timer -= delta
			if _reposition_timer <= 0.0:
				_combat_phase = CombatPhase.APPROACH


func _handle_weapons(to_target: Vector3, dist: float, delta: float) -> void:
	if dist <= fire_range:
		var forward := -global_transform.basis.z
		if forward.dot(to_target.normalized()) > 0.5:
			ship_controller.fire_phasers(_target)

	_torpedo_fire_timer -= delta
	if _torpedo_fire_timer <= 0.0 and dist <= fire_range * 1.8:
		if ship_controller.fire_torpedos(_target) > 0:
			_torpedo_fire_timer = randf_range(5.0, 9.0)


# ─────────────────────────────────────────────────────────────────────────────
# STEERING & PHYSICS CORE
# ─────────────────────────────────────────────────────────────────────────────

func _apply_steering(desired_dir: Vector3, speed_limit: float, stats: ShipStats, delta: float, y_velocity: float = 0.0) -> void:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	desired_dir.y = 0.0

	var dot:           float = clamp(forward.dot(desired_dir.normalized()), -1.0, 1.0)
	var angle_deg:     float = rad_to_deg(acos(dot))
	var cross:         float = forward.cross(desired_dir.normalized()).y
	var rotation_input: float = clamp(-sign(cross) * (angle_deg / 90.0) * steer_gain, -1.0, 1.0)
	var thrust:        float = lerp(1.0, 0.2, clamp(angle_deg / throttle_cut_angle, 0.0, 1.0))

	var original_max  := stats.max_speed
	stats.max_speed    = speed_limit if speed_limit > 0 else original_max
	velocity           = ship_controller.movement_comp.calculate_movement(self, thrust, rotation_input, stats, delta)
	stats.max_speed    = original_max

	if _state == State.PATROL:
		var target_y := patrol_center.y + _curve_y(_curve_t)
		velocity.y    = (target_y - global_position.y) * 2.0
	else:
		velocity.y = move_toward(velocity.y, y_velocity, stats.max_speed * delta)

	_apply_avoidance(stats)
	move_and_slide()
	ship_controller.movement_comp.update_tilt(rotation_input, stats, delta)


# ─────────────────────────────────────────────────────────────────────────────
# FEIND-ERKENNUNG
# ─────────────────────────────────────────────────────────────────────────────

func _find_nearest_hostile() -> Node3D:
	var space := get_world_3d().direct_space_state
	if not space or not _initialized:
		return null

	var sphere := SphereShape3D.new()
	sphere.radius = detection_radius

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = sphere
	params.transform = global_transform
	params.collision_mask = radar_collision_mask
	params.collide_with_bodies = true
	params.collide_with_areas = false

	var hits := space.intersect_shape(params, 64)

	_dbg("Physics Query | Hits raw: %d | Radius: %.0f" % [hits.size(), detection_radius])

	var best_node: Node3D = null
	var best_dist_sq: float = INF

	for hit in hits:
		var body := hit.get("collider") as Node3D
		if not body or body == self:
			continue
		# Zusätzlicher Schutz: HullCollision & Co. sind Child-Nodes von self.
		# Falls deren Layer auch auf der radar_collision_mask liegen, würde
		# body == self nicht greifen und wir würden uns selbst als Ziel sehen.
		if is_ancestor_of(body):
			continue
		if not body.is_in_group("ships"):
			continue

		if _is_hostile_to_me(body):
			var d_sq := global_position.distance_squared_to(body.global_position)
			if d_sq < best_dist_sq:
				best_dist_sq = d_sq
				best_node = body

	# === Fallback: Brute-Force Gruppen-Scan ===
	if best_node == null:
		_dbg("Query gab 0 Hits → Fallback auf Gruppen-Scan")
		var all_ships = get_tree().get_nodes_in_group("ships")
		for ship in all_ships:
			if ship == self or not is_instance_valid(ship):
				continue
			# Falls ein Child-Node von uns in der "ships"-Gruppe landen würde
			if is_ancestor_of(ship):
				continue
			if not _is_hostile_to_me(ship):
				continue

			var dist := global_position.distance_to(ship.global_position)
			if dist > detection_radius:
				continue

			if dist * dist < best_dist_sq:
				best_dist_sq = dist * dist
				best_node = ship

	if best_node:
		_dbg("✅ FEIND GEFUNDEN: %s (%.1fm)" % [best_node.name, sqrt(best_dist_sq)])
		return best_node
	else:
		_dbg("❌ Immer noch kein Feind gefunden")
		return null

# ─────────────────────────────────────────────────────────────────────────────
# HILFSFUNKTIONEN
# ─────────────────────────────────────────────────────────────────────────────

func _on_ship_destroyed() -> void:
	for grp in get_groups():
		remove_from_group(grp)
	_state  = State.PATROL
	_target = null
	_set_radar_pulsing(false)
	if is_instance_valid(_radar_visualizer):
		_radar_visualizer.hide()


## Zentrale Feindschafts-Prüfung.
##
## NEU: Die Autorität ist RelationshipResolver. Er kombiniert drei Ebenen:
##   1. Aggro-Override         → wer mich/meinen Ally angriff ist HOSTILE
##   2. Reputation-Override    → Ruf ≥ +50 FRIENDLY, ≤ -50 HOSTILE (nur bei Player)
##   3. Baseline (FactionSystem.is_faction_pair_hostile)
## Plus: same-faction = nicht feindlich, Self-Check, Invalid-Guards.
##
## Damit der Sovereign-NPC seinen Schwester-Sovereign nicht mehr fälschlicherweise
## als Player erkennt (alter Bug: Player-ShipController-Child hatte ship_name
## "Sovereign" und landete im Scan-Log). Der Resolver prüft stattdessen die
## Gruppe "player" am Root-Node der Hierarchie – kein Ambiguity-Problem mehr.
##
## Fallback-Logik bleibt als Sicherheitsnetz falls der Resolver-Autoload fehlt.
func _is_hostile_to_me(node: Node) -> bool:
	if not node or not ship_data:
		return false

	# ── PRIMÄR: RelationshipResolver ──────────────────────────────────────
	var resolver: Node = get_tree().root.get_node_or_null("RelationshipResolver")
	if resolver and resolver.has_method("are_hostile"):
		var result: bool = resolver.are_hostile(self, node)
		if show_debug:
			var other_f_int: int = _get_faction_of_node(node)
			var my_f_str: String = ShipData.Faction.keys()[ship_data.faction]
			var other_f_str: String = ShipData.Faction.keys()[other_f_int] if other_f_int >= 0 else "?"
			_dbg("    → Resolver: %s vs %s (target='%s') → %s" % [
				my_f_str, other_f_str, node.name,
				"HOSTILE" if result else "friedlich"
			])
		return result

	# ── FALLBACK: alte Zwei-Kanal-Logik (Resolver-Autoload fehlt) ────────
	var other_faction_int: int = _get_faction_of_node(node)
	if other_faction_int < 0:
		return false

	var my_f:    ShipData.Faction = ship_data.faction
	var other_f: ShipData.Faction = other_faction_int as ShipData.Faction

	if _belongs_to_player(node):
		var player_disp: ReputationSystem.Disposition = ReputationSystem.get_disposition(my_f)
		var hostile: bool = (player_disp == ReputationSystem.Disposition.HOSTILE)
		_dbg("    → [FALLBACK] Player-Check: Ruf(%s)=%s → %s (target='%s')" % [
			ShipData.Faction.keys()[my_f],
			ReputationSystem.Disposition.keys()[player_disp],
			"HOSTILE" if hostile else "friedlich",
			node.name
		])
		return hostile

	if FactionSystem.is_hostile(my_f, other_f):
		_dbg("    → [FALLBACK] NPC-Check: HOSTILE (%s vs %s) [target='%s']" % [
			ShipData.Faction.keys()[my_f],
			ShipData.Faction.keys()[other_f],
			node.name
		])
		return true

	return false


## Prüft ob der Node selbst oder einer seiner Vorfahren zum Spieler gehört.
## Der Player-Root ist in Gruppe "player", aber Child-Nodes wie ShipController
## oder HullCollision nicht – deshalb läuft die Prüfung die Hierarchie hoch.
func _belongs_to_player(node: Node) -> bool:
	var current: Node = node
	while is_instance_valid(current):
		if current.is_in_group("player"):
			return true
		current = current.get_parent()
	return false


func _get_faction_of_node(node: Node) -> int:
	if node.has_method("get_faction"): return node.get_faction()
	if "ship_data" in node and node.ship_data: return node.ship_data.faction
	return -1


func _find_ship_controller_in(node: Node) -> ShipController:
	if node is ShipController: return node
	for child in node.get_children():
		var found := _find_ship_controller_in(child)
		if found: return found
	return null


func _curve_pos(t: float) -> Vector3:
	return patrol_center + Vector3(
		sin(t) * patrol_radius_x,
		sin(t * 2.0) * patrol_height,
		cos(t) * patrol_radius_z
	)

func _curve_y(t: float) -> float:
	return sin(t * 2.0) * patrol_height

func _curve_tangent(t: float) -> Vector3:
	return (_curve_pos(t + 0.1) - _curve_pos(t)).normalized()

func _find_nearest_curve_t() -> float:
	return 0.0


func _is_target_dead() -> bool:
	if not is_instance_valid(_target): return true
	return not _target.is_in_group("ships")


func _enter_patrol() -> void:
	if _state == State.PATROL:
		return

	_state  = State.PATROL
	_target = null
	_disengage_timer = 0.0
	_combat_phase = CombatPhase.APPROACH

	if is_instance_valid(ship_controller) and ship_controller.targeting_system:
		ship_controller.targeting_system.force_release()

	_set_radar_pulsing(true)
	_update_radar_color()

	_dbg("→ PATROL Modus | Radar wieder grün + pulsierend")


## Öffentliche API für Debug-Tools oder externe Systeme.
## Setzt den NPC hart in den PATROL-Modus zurück und startet den Scan-Timer neu.
## Anders als _enter_patrol() hat das auch Wirkung wenn der NPC bereits in
## PATROL ist (z.B. um einen hängenden Scan neu zu triggern).
func force_patrol() -> void:
	# Internen State zurücksetzen (auch wenn schon PATROL – harter Reset).
	_state = State.PATROL
	_target = null
	_disengage_timer = 0.0
	_combat_phase = CombatPhase.APPROACH
	_reputation_became_hostile = false

	if is_instance_valid(ship_controller) and ship_controller.targeting_system:
		ship_controller.targeting_system.force_release()

	_set_radar_pulsing(true)
	_update_radar_color()

	# Scan-Timer neu starten, damit das nächste PATROL→COMBAT-Scan-Fenster
	# direkt beginnt (nicht erst wenn der alte Timer abgelaufen wäre).
	if is_instance_valid(_scan_timer):
		_scan_timer.stop()
		_scan_timer.start()

	_dbg("→ force_patrol() | State hart zurückgesetzt")


func _get_orbit_radius() -> float:
	if orbit_radius > 0: return orbit_radius * orbit_radius_scale
	return fire_range * 0.7 * orbit_radius_scale


func _random_reposition_time() -> float:
	return reposition_interval * randf_range(0.8, 1.2)


## Reagiert auf Änderungen im ReputationSystem.
## Reputation betrifft nur die Beziehung Spieler↔Fraktion, also ist für
## diesen NPC nur seine EIGENE Fraktion interessant:
##   • HOSTILE → Spieler ist neues Ziel, Sofort-Scan im nächsten Tick
##   • NEUTRAL/FRIENDLY → falls gerade der Spieler angegriffen wird: abbrechen
func _on_reputation_disposition_changed(
		faction,
		old_disp,
		new_disp) -> void:

	if faction != ship_data.faction:
		return

	match new_disp:
		ReputationSystem.Disposition.HOSTILE:
			if old_disp != ReputationSystem.Disposition.HOSTILE and _state == State.PATROL:
				_reputation_became_hostile = true
				_dbg("⚠ Ruf → HOSTILE | starte Kampf-Scan")

		ReputationSystem.Disposition.NEUTRAL, ReputationSystem.Disposition.FRIENDLY:
			# Nur relevant wenn gerade der Spieler angegriffen wird –
			# NPC-Ziele sind von Reputationsänderungen nicht betroffen.
			if _state == State.COMBAT and is_instance_valid(_target) and _target.is_in_group("player"):
				_dbg("✅ Ruf → %s | breche Kampf gegen Spieler ab" % ReputationSystem.Disposition.keys()[new_disp])
				_enter_patrol()


func _apply_avoidance(_stats: ShipStats) -> void:
	pass


func _dbg(msg: String) -> void:
	if show_debug:
		print("[AI:%s] %s" % [name, msg])
		debug_log_generated.emit(name, msg)


func _move_approach(to_target: Vector3, _dist: float, stats: ShipStats, delta: float) -> void:
	_apply_steering(to_target.normalized(), stats.max_speed, stats, delta, to_target.y * 0.5)


func _move_orbit(_dist: float, stats: ShipStats, delta: float) -> void:
	var tangent := global_transform.basis.x * _orbit_dir
	var desired := (tangent + (_target.global_position - global_position).normalized() * 0.2).normalized()
	_apply_steering(desired, stats.max_speed * 0.8, stats, delta, (_target.global_position.y - global_position.y))


func _move_reposition(stats: ShipStats, delta: float) -> void:
	_apply_steering(_reposition_dir, stats.max_speed, stats, delta)


func on_hit_by_player(damage: float) -> void:
	ReputationSystem.on_player_attacked_ship(ship_data.faction)
	var player := _find_player_node()
	if player and _state == State.PATROL:
		_enter_combat(player)

	if player:
		var my_group := FactionSystem.get_group_name(ship_data.faction)
		for ally in get_tree().get_nodes_in_group(my_group):
			if ally == self: continue
			if not ally.has_method("alert_external_target"): continue
			var ally_n3d := ally as Node3D
			if ally_n3d == null: continue
			if global_position.distance_to(ally_n3d.global_position) < detection_radius * 2.0:
				ally.call("alert_external_target", player)


## Wird von Verbündeten aufgerufen wenn diese angegriffen werden.
func alert_external_target(target: Node3D) -> void:
	if not _initialized: return
	if _state == State.PATROL:
		_dbg("🚨 Alarm von Verbündetem – greife an: %s" % target.name)
		_enter_combat(target)


func on_killed_by_player() -> void:
	ReputationSystem.on_player_killed_ship(ship_data.faction)


func _find_player_node() -> Node3D:
	var players := get_tree().get_nodes_in_group("player")
	return players[0] if players.size() > 0 else null

# ─────────────────────────────────────────────────────────────────────────────
# RADAR VISUALIZER STEUERUNG
# ─────────────────────────────────────────────────────────────────────────────

func _set_radar_visual_scale() -> void:
	if not is_instance_valid(_radar_visualizer):
		return

	var target_scale := Vector3(detection_radius * 2.0, 1.0, detection_radius * 2.0)
	_radar_visualizer.scale = target_scale


func _set_radar_pulsing(active: bool) -> void:
	if _pulse_tween:
		_pulse_tween.kill()
		_pulse_tween = null

	if not is_instance_valid(_radar_visualizer):
		return

	_set_radar_visual_scale()

	if not active:
		_update_radar_color()
		return

	_pulse_tween = create_tween().set_loops()
	var base := Vector3(detection_radius * 2.0, 1.0, detection_radius * 2.0)

	_pulse_tween.tween_property(_radar_visualizer, "scale", base * 1.04, 1.4)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulse_tween.tween_property(_radar_visualizer, "scale", base * 0.96, 1.4)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


# ─────────────────────────────────────────────────────────────────────────────
# STATE WECHSEL
# ─────────────────────────────────────────────────────────────────────────────

func _enter_combat(target: Node3D) -> void:
	# TEMPORÄRER DIAGNOSE-LOG (unabhängig von show_debug).
	# Zeigt welcher Pfad den Kampf tatsächlich startet – mit Stack-Trace.
	# Nach Debug-Phase wieder entfernen oder hinter ein Debug-Flag setzen.
	var target_name: String = String(target.name) if is_instance_valid(target) else "NULL"
	var my_faction: String  = ShipData.Faction.keys()[ship_data.faction] if ship_data else "?"
	print("[AI-COMBAT-ENTRY] '%s' [%s] → COMBAT gegen '%s' | Stack:" % [
		name, my_faction, target_name
	])
	for frame in get_stack():
		print("    @ %s:%d in %s()" % [frame.get("source", "?"), frame.get("line", 0), frame.get("function", "?")])

	_state = State.COMBAT
	_target = target
	_torpedo_fire_timer = randf_range(2.0, 4.0)
	_combat_phase = CombatPhase.APPROACH
	_orbit_dir = 1.0 if randf() > 0.5 else -1.0
	_reposition_timer = _random_reposition_time()

	if is_instance_valid(ship_controller):
		ship_controller.targeting_system.force_lock(target)

	_set_radar_pulsing(false)
	_update_radar_color()
	_dbg("→ COMBAT | Ziel: %s | Radar rot + statisch" % target.name) 
