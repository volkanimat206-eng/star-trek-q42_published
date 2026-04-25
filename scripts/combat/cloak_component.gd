# res://scripts/combat/cloak_component.gd
#
# Cloaking-System als ShipController-Subsystem. Analog zu ShieldSystem aufgebaut.
#
# LEBENSZYKLUS:
#   IDLE → CLOAKING (fade-in) → CLOAKED → DECLOAKING (fade-out) → IDLE
#                                ↓ break_cloak()
#                                EMERGENCY_DECLOAK → COOLDOWN → IDLE
#
# WAFFEN/SCHILDE:
#   - CLOAKING startet:    weapons_offline + shields_offline + immer noch Mesh sichtbar
#   - CLOAKED:             alles aus, Mesh transparent, Layer aus
#   - DECLOAKING startet:  Mesh wird wieder sichtbar
#   - DECLOAKING fertig:   weapons_online + shields_online (mit recharge_delay)
#
# SICHTBARKEIT:
#   Externe Systeme (TargetingSystem, AIController, etc.) fragen die Sichtbarkeit
#   NICHT direkt am Component ab, sondern über ShipController.is_visible_to(observer).
#   Der ShipController delegiert dann an den CloakComponent — das hält die API
#   einheitlich auch für Schiffe ohne Cloak.

class_name CloakComponent
extends Node

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

## Tarnung beginnt (Fade-In hat gestartet)
signal cloaking_started

## Tarnung vollständig aktiv (Fade abgeschlossen, voll unsichtbar)
signal cloaked

## Enttarnung beginnt (Fade-Out hat gestartet)
signal decloaking_started

## Enttarnung abgeschlossen (Mesh voll sichtbar, Waffen+Schilde wieder online)
signal decloaked

## Tarnung wurde erzwungen unterbrochen (Waffen-Feuer, externe Quelle)
signal cloak_broken(reason: String)

# ─────────────────────────────────────────────────────────────────────────────
# STATES
# ─────────────────────────────────────────────────────────────────────────────

enum State {
	IDLE,           ## Sichtbar, alles normal
	CLOAKING,       ## Fade-In läuft
	CLOAKED,        ## Voll getarnt
	DECLOAKING,     ## Fade-Out läuft
	COOLDOWN        ## Nach erzwungener Enttarnung, kann nicht erneut tarnen
}

var _state: State = State.IDLE

# ─────────────────────────────────────────────────────────────────────────────
# REFS
# ─────────────────────────────────────────────────────────────────────────────

## CloakData mit Tuning-Parametern. Wenn null, werden Defaults verwendet.
var data: CloakData = null

## Debug-Flag, propagiert vom ShipController.
var show_debug: bool = false

var _ship_controller: Node = null  ## ShipController-Parent
var _cloak_alpha: float    = 1.0   ## 0.0 = voll getarnt, 1.0 = voll sichtbar
var _cooldown_timer: float = 0.0
var _active_tween: Tween   = null

## Materials die wir im Cloak modifizieren. Werden beim Setup gefunden und
## gecached. Pro Mesh-Surface eine Override-Material-Kopie damit andere
## Instanzen desselben Schiffstyps nicht mit-cloaken.
var _cached_materials: Array[StandardMaterial3D] = []
var _materials_initialized: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_ship_controller = get_parent()
	# Defensive Defaults wenn kein CloakData gesetzt
	if not data:
		data = CloakData.new()

func _process(delta: float) -> void:
	if _state == State.COOLDOWN:
		_cooldown_timer -= delta
		if _cooldown_timer <= 0.0:
			_state = State.IDLE
			_dbg("✅ Cooldown beendet, kann erneut tarnen")
		return

	# Sichtbarkeits-Update für andere Schiffe in der Nähe (nur wenn cloaked
	# oder am Übergang). Pro Frame wäre teuer, daher nur in den relevanten
	# Phasen.
	if _state == State.CLOAKED or _state == State.CLOAKING or _state == State.DECLOAKING:
		_update_proximity_shimmer()


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Toggle für Player-Input und externe Trigger.
## Returns: true wenn der Toggle akzeptiert wurde, false wenn ignoriert.
func toggle_cloak() -> bool:
	match _state:
		State.IDLE:
			return _begin_cloak()
		State.CLOAKED:
			return _begin_decloak()
		_:
			# CLOAKING, DECLOAKING, COOLDOWN → ignorieren
			_dbg("⚠ toggle_cloak ignoriert (State: %s)" % State.keys()[_state])
			return false


## Erzwungene Enttarnung von außen — z.B. wenn der ShipController feuert
## während getarnt. Springt sofort in DECLOAKING und triggered Cooldown.
func break_cloak(reason: String = "external") -> void:
	if _state != State.CLOAKED and _state != State.CLOAKING:
		return
	_dbg("💥 Cloak gebrochen: %s" % reason)
	cloak_broken.emit(reason)
	_begin_decloak(true)  # emergency = true → Cooldown nach Decloak


## true wenn das Schiff aktuell für andere unsichtbar ist (komplett oder
## teilweise). Wird von ShipController.is_visible_to() konsultiert.
func is_cloaked() -> bool:
	return _state == State.CLOAKED


## true wenn das Schiff gerade im Übergang ist (Cloak nicht voll, aber
## auch nicht voll sichtbar). Im Übergang sollte Targeting/AI das Schiff
## noch normal behandeln, weil es theoretisch noch zu sehen ist.
func is_transitioning() -> bool:
	return _state == State.CLOAKING or _state == State.DECLOAKING


## Sichtbarkeit für einen bestimmten Beobachter (0.0 = unsichtbar, 1.0 = voll
## sichtbar). Berücksichtigt Detection-Range bei aktivem Cloak.
##
## Diese Funktion ist die Wahrheits-Quelle für externe Visibility-Checks.
## ShipController.is_visible_to(observer) nutzt diese.
func visibility_to(observer: Node3D) -> float:
	# Im IDLE: voll sichtbar
	if _state == State.IDLE:
		return 1.0

	# Im Übergang: linear interpoliert mit _cloak_alpha
	if _state == State.CLOAKING or _state == State.DECLOAKING:
		return _cloak_alpha

	# Im COOLDOWN: voll sichtbar (war ja gerade enttarnt)
	if _state == State.COOLDOWN:
		return 1.0

	# CLOAKED: hängt von Distanz zum Observer ab
	if not is_instance_valid(observer):
		return 0.0
	if not _ship_controller or not _ship_controller is Node3D:
		return 0.0

	var dist: float = (_ship_controller as Node3D).global_position.distance_to(observer.global_position)
	if dist >= data.detection_range:
		return 0.0

	# Linear interpoliert: bei dist=0 → shimmer_max_alpha, bei dist=detection_range → 0
	var t: float = 1.0 - (dist / data.detection_range)
	return t * data.shimmer_max_alpha


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – State-Übergänge
# ─────────────────────────────────────────────────────────────────────────────

func _begin_cloak() -> bool:
	if not _ship_controller:
		return false

	_dbg("🌀 CLOAKING gestartet (fade=%.1fs)" % data.fade_in_duration)
	_state = State.CLOAKING
	cloaking_started.emit()

	# Schilde und Waffen offline schalten
	_set_weapons_locked(true)
	_set_shields_offline(true)

	# Mesh-Fade auf 0
	_fade_to(0.0, data.fade_in_duration, _on_cloak_complete)
	return true


func _begin_decloak(emergency: bool = false) -> bool:
	if not _ship_controller:
		return false

	var duration: float = data.fade_out_duration
	if emergency:
		duration = 0.3   # Schneller Blitz beim erzwungenen Enttarnen

	_dbg("🌀 DECLOAKING gestartet (fade=%.2fs, emergency=%s)" % [duration, emergency])
	_state = State.DECLOAKING
	decloaking_started.emit()

	# Mesh-Fade zurück auf 1.0
	_fade_to(1.0, duration, _on_decloak_complete.bind(emergency))
	return true


func _on_cloak_complete() -> void:
	_state = State.CLOAKED
	# Physics-Layers ausschalten — cloakede Schiffe können nicht getroffen werden
	_set_collision_active(false)
	_dbg("✅ CLOAKED (voll unsichtbar)")
	cloaked.emit()


func _on_decloak_complete(emergency: bool) -> void:
	# Physics-Layers reaktivieren
	_set_collision_active(true)
	# Schilde und Waffen wieder online (mit recharge_delay-Pause)
	_set_shields_offline(false)
	_set_weapons_locked(false)

	if emergency:
		_state = State.COOLDOWN
		_cooldown_timer = data.emergency_cooldown
		_dbg("⏰ COOLDOWN aktiv (%.1fs bis IDLE)" % _cooldown_timer)
	else:
		_state = State.IDLE
		_dbg("✅ DECLOAKED (Schiff sichtbar)")

	decloaked.emit()


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Mesh-Fade
# ─────────────────────────────────────────────────────────────────────────────

## Cached alle MeshInstance3D Override-Materials für schnelles Tweening.
## Wird beim ersten Cloak-Versuch aufgerufen, danach ist alles vorbereitet.
##
## WICHTIG: Wir DUPLIZIEREN die Materials, sonst würde ein cloakedes Schiff
## auch alle anderen Instanzen desselben Typs durchscheinen lassen.
func _initialize_materials() -> void:
	if _materials_initialized:
		return
	if not _ship_controller:
		return

	var mesh_instances: Array[MeshInstance3D] = _find_all_mesh_instances(_ship_controller)
	for mesh in mesh_instances:
		# ShieldMesh überspringen — der hat sein eigenes Shader-System
		if mesh.name == "ShieldMesh":
			continue

		var surface_count: int = 0
		if mesh.mesh:
			surface_count = mesh.mesh.get_surface_count()

		for i in range(surface_count):
			# Override holen oder duplizieren falls noch nicht vorhanden
			var mat_override: Material = mesh.get_surface_override_material(i)
			if not mat_override:
				var base_mat: Material = mesh.mesh.surface_get_material(i)
				if base_mat:
					mat_override = base_mat.duplicate()
					mesh.set_surface_override_material(i, mat_override)

			# Nur StandardMaterial3D unterstützt; andere (ShaderMaterial) skippen
			if mat_override is StandardMaterial3D:
				var sm: StandardMaterial3D = mat_override
				# Transparency aktivieren damit Alpha funktioniert
				sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				_cached_materials.append(sm)

	_materials_initialized = true
	_dbg("🎨 %d Materials für Cloak-Fade vorbereitet" % _cached_materials.size())


func _fade_to(target_alpha: float, duration: float, on_complete: Callable) -> void:
	_initialize_materials()

	# Bestehenden Tween abbrechen falls einer läuft
	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()

	if _cached_materials.is_empty():
		# Kein Mesh gefunden — direkt fertig
		_cloak_alpha = target_alpha
		on_complete.call()
		return

	_active_tween = create_tween().set_parallel(true)
	# Internen Alpha-Wert tweenen
	_active_tween.tween_property(self, "_cloak_alpha", target_alpha, duration)
	# Pro Material die albedo_color.a tweenen, Aufruf on _process
	for mat in _cached_materials:
		var current_color: Color = mat.albedo_color
		var target_color: Color = current_color
		target_color.a = target_alpha
		_active_tween.tween_property(mat, "albedo_color", target_color, duration)

	# Callback nach Tween-Ende (chain damit es nicht parallel feuert)
	_active_tween.chain().tween_callback(on_complete)


func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_all_mesh_instances(child))
	return result


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Subsystem-Hooks
# ─────────────────────────────────────────────────────────────────────────────

## Schaltet Waffen-Mounts in den Cloak-Lock-State.
## Nutzt eine neue Methode set_cloak_locked() am WeaponMount, die die
## fire_at-Calls silent skippt.
func _set_weapons_locked(locked: bool) -> void:
	if not _ship_controller or not _ship_controller.has_method("set_weapons_cloak_locked"):
		return
	_ship_controller.set_weapons_cloak_locked(locked)
	_dbg("🔫 Waffen %s" % ("LOCKED" if locked else "ENTSPERRT"))


## Schaltet Schilde offline (kollabiert sie sanft) bzw. wieder online.
## Nutzt ShieldSystem über ShipController-API.
func _set_shields_offline(offline: bool) -> void:
	if not _ship_controller or not _ship_controller.has_method("set_shields_cloak_offline"):
		return
	_ship_controller.set_shields_cloak_offline(offline)
	_dbg("🛡️ Schilde %s" % ("OFFLINE" if offline else "ONLINE"))


## Schaltet die Hull-Collision aus, damit cloakede Schiffe nicht von
## Beam-Raycasts oder Torpedos getroffen werden.
##
## Hull-Collision liegt auf einem Child-Node (HullCollision/StaticBody3D),
## nicht am ShipController-Root. Daher müssen wir den Child finden.
func _set_collision_active(active: bool) -> void:
	if not _ship_controller:
		return

	var hull: Node = _ship_controller.find_child("HullCollision", true, false)
	if hull and hull is CollisionObject3D:
		var co: CollisionObject3D = hull
		if active:
			co.set_collision_layer_value(1, true)   # Hull-Layer
		else:
			co.set_collision_layer_value(1, false)
		_dbg("⚛️ HullCollision Layer-1 = %s" % active)


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Proximity-Shimmer
# ─────────────────────────────────────────────────────────────────────────────

## Sucht den nächsten Beobachter und passt den Shimmer-Alpha entsprechend an.
## Pro Frame teuer, daher nur im aktiven Cloak-State (siehe _process Guard).
func _update_proximity_shimmer() -> void:
	if _state != State.CLOAKED:
		return  # nur im voll-cloakten Zustand

	if not _ship_controller or not _ship_controller is Node3D:
		return

	var nearest_dist: float = INF
	var my_pos: Vector3 = (_ship_controller as Node3D).global_position

	for ship in get_tree().get_nodes_in_group("ships"):
		if ship == _ship_controller:
			continue
		if not ship is Node3D:
			continue
		var d: float = (ship as Node3D).global_position.distance_to(my_pos)
		if d < nearest_dist:
			nearest_dist = d

	# Shimmer-Alpha berechnen
	var shimmer: float = 0.0
	if nearest_dist < data.detection_range:
		var t: float = 1.0 - (nearest_dist / data.detection_range)
		shimmer = t * data.shimmer_max_alpha

	# Auf alle gecachten Materials anwenden
	for mat in _cached_materials:
		if not mat:
			continue
		var c: Color = mat.albedo_color
		c.a = shimmer
		mat.albedo_color = c


# ─────────────────────────────────────────────────────────────────────────────
# DEBUG
# ─────────────────────────────────────────────────────────────────────────────

func _dbg(msg: String) -> void:
	if not show_debug:
		# Auch ohne show_debug-Flag das DebugManager-Flag respektieren
		var dm: Node = get_tree().root.get_node_or_null("DebugManager")
		if not dm or not dm.has_method("get_flag"):
			return
		if not dm.get_flag("cloak.events"):
			return
	var ship_name: String = _ship_controller.name if _ship_controller else "?"
	print("[Cloak|%s] %s" % [ship_name, msg])
