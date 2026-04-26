# res://scripts/targeting_system.gd
extends Node3D
class_name TargetingSystem

# ─────────────────────────────────────────────────────────────────────────────
# DESIGN – "Information frei, Aktionen verantwortungsvoll."
#   • Single-Lock (TAB) ist IMMER möglich – auf jedes Schiff (Freund/Neutral/Feind).
#   • Multi-Lock (SHIFT+TAB) wird nur freigeschaltet wenn das aktuelle Lock
#     feindlich ist. Weitere Multi-Einträge müssen selbst feindlich sein.
#   • Multi-Liste wird live re-evaluiert: wird ein Ziel pazifistisch,
#     fliegt es automatisch raus. Single-Lock bleibt als Scan-Lock bestehen.
#   • Auto-Fire-Filter liegt im PlayerController (is_current_target_hostile).
# ─────────────────────────────────────────────────────────────────────────────

# ===== SIGNALS =====
signal target_locked(target: Node3D)
signal target_lock_released()
signal targeting_mode_changed(mode: Mode)
signal multi_target_added(target: Node3D)
signal multi_target_removed(target: Node3D)

# ===== ENUMS =====
enum Mode { MANUAL, TARGET_LOCK }

# ===== EXPORTS =====
@export_group("Manual Mode")
@export var manual_empty_space_height: float = 2.0
@export_flags_3d_physics var target_layer: int = 2

@export_group("Target Lock")
@export var lock_key:         String = "target_lock"
## SHIFT + lock_key fügt ein Ziel zur Multi-Target-Liste hinzu.
## Input-Map Eintrag anlegen: "target_lock_add" → Shift+Tab
@export var lock_add_key:     String = "target_lock_add"
@export var max_lock_range:   float  = 200.0
## Maximale Anzahl gleichzeitiger Multi-Targets (inkl. Primärziel)
@export_range(1, 8) var max_multi_targets: int = 4

@export_group("Reticle")
## NUR beim Spieler auf true setzen!
## Doppelschutz: Reticle wird NUR erzeugt wenn BEIDE Flags true sind.
@export var is_player_controlled: bool = false
## NUR beim Spieler aktivieren – bei KI-Schiffen IMMER false lassen!
@export var show_reticle:  bool        = false
@export var reticle_scene: PackedScene

@export_group("Debug")
@export var show_debug: bool = false

# ===== INTERN =====
var current_mode:   Mode   = Mode.MANUAL
var locked_target:  Node3D = null
var hovered_target: Node3D = null

## Multi-Target-Liste: alle aktiv gelockten Ziele (inkl. primary)
## INVARIANTE: enthält NUR feindliche, lebende, valide Schiffe.
## INVARIANTE: multi_locked_targets[0] == locked_target (wenn size >= 1).
var multi_locked_targets: Array[Node3D] = []

var _camera:   Camera3D
var _viewport: Viewport
var _space:    PhysicsDirectSpaceState3D

var _reticle:         Node        = null
var _reticle_layer:   CanvasLayer = null
## Sekundäre Reticles für Multi-Targets (index 1..n)
var _multi_reticles:  Array       = []

## Cache: eigener Ship-Root-Node (= "ships"-Gruppen-Vorfahr) für Self-Exclusion
var _own_ship: Node3D = null


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_camera   = get_viewport().get_camera_3d()
	_viewport = get_viewport()

	# Aufwärts laufen bis zur "ships"-Gruppe – findet Player (CharacterBody3D)
	# bzw. AIController, nicht ShipController (Node3D).
	var node: Node = self
	while node:
		if node is Node3D and (node as Node3D).is_in_group("ships"):
			_own_ship = node as Node3D
			break
		node = node.get_parent()

	if not _own_ship:
		push_error("[TargetingSystem] FEHLER: Kein 'ships'-Node in Hierarchie gefunden!")

	# Reticle NICHT in _ready() initialisieren –
	# is_player_controlled wird erst nach _ready() per Code gesetzt.
	# PlayerController ruft setup_as_player() nach add_child() auf.
	_dbg("=== TARGETING SYSTEM READY ===")
	_dbg("  target_layer  : %d" % target_layer)
	_dbg("  max_lock_range: %.1f" % max_lock_range)
	_dbg("  max_multi     : %d" % max_multi_targets)
	_dbg("  show_reticle  : %s" % show_reticle)
	_dbg("  is_player     : %s" % is_player_controlled)
	_dbg("  camera found  : %s" % (_camera != null))
	_dbg("  own_ship      : %s" % (_own_ship.name if _own_ship else "null"))

	# Debug: potenzielle Ziele beim Start (inkl. Freunde / Neutrale)
	var targets := _get_all_targets_sorted()
	_dbg("  Potenzielle Ziele beim Start: %d (alle Dispositionen)" % targets.size())
	for t in targets:
		_dbg("    → %s pos=%s hostile=%s" % [
			t.name, str(t.global_position), _is_hostile(t)
		])


# ─────────────────────────────────────────────────────────────────────────────
# SETUP – muss nach add_child() aufgerufen werden
# ─────────────────────────────────────────────────────────────────────────────

## PlayerController ruft dies nach add_child() auf.
func setup_as_player() -> void:
	is_player_controlled = true
	show_reticle         = true
	_init_reticle()
	_dbg("setup_as_player() → Reticle initialisiert")


## AIController ruft dies nach add_child() auf.
## Stellt explizit sicher dass kein Reticle erzeugt wird.
func setup_as_npc() -> void:
	is_player_controlled = false
	show_reticle         = false
	_dbg("setup_as_npc() → kein Reticle")


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS
# ─────────────────────────────────────────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	_space = get_world_3d().direct_space_state
	match current_mode:
		Mode.MANUAL:      _update_manual_raycast()
		Mode.TARGET_LOCK: _validate_lock()
	_update_all_reticles()
	_prune_invalid_multi_targets()


func _unhandled_input(event: InputEvent) -> void:
	# SHIFT + lock_key → Multi-Target hinzufügen (nur wenn hostile-Kontext)
	if event.is_action_pressed(lock_add_key):
		_dbg("lock_add_key '%s' gedrückt → _add_to_multi_lock()" % lock_add_key)
		_add_to_multi_lock()
		return

	# lock_key allein → Single-Lock (durchschaltet ALLE Schiffe)
	if event.is_action_pressed(lock_key):
		_dbg("lock_key '%s' gedrückt → _cycle_lock()" % lock_key)
		_cycle_lock()


# ─────────────────────────────────────────────────────────────────────────────
# MANUAL RAYCAST
# ─────────────────────────────────────────────────────────────────────────────

func _update_manual_raycast() -> void:
	if not _camera or not _viewport or not _space:
		return

	var mouse_pos:  Vector2 = _viewport.get_mouse_position()
	var ray_origin: Vector3 = _camera.project_ray_origin(mouse_pos)
	var ray_end:    Vector3 = ray_origin + _camera.project_ray_normal(mouse_pos) * 2000.0

	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_end, target_layer)
	query.hit_back_faces = false
	query.exclude        = _collect_own_rids()

	var result: Dictionary = _space.intersect_ray(query)

	if result.is_empty():
		if hovered_target != null:
			_dbg("MANUAL: kein Treffer → hovered_target geleert")
			hovered_target = null
		return

	var hit_node:    Node3D = result["collider"]
	var target_root: Node3D = _get_target_root(hit_node)

	if target_root == null:
		if hovered_target != null:
			_dbg("MANUAL: Treffer '%s' aber kein gültiges Schiff → hovered geleert" % hit_node.name)
			hovered_target = null
		return

	if target_root != hovered_target:
		hovered_target = target_root
		_dbg("MANUAL: Treffer '%s' → root='%s' hostile=%s" % [
			hit_node.name, target_root.name, _is_hostile(target_root)
		])


## Sammelt RIDs aller CollisionObject3D im eigenen Schiff-Sub-Tree
func _collect_own_rids() -> Array[RID]:
	var rids: Array[RID] = []
	if not _own_ship:
		return rids
	for child in _own_ship.find_children("*", "CollisionObject3D", true, false):
		rids.append((child as CollisionObject3D).get_rid())
	return rids


## ÄNDERUNG: gibt JEDES Schiff in der "ships"-Gruppe zurück (nicht mehr nur Feinde).
## Der Spieler darf alle Schiffe sehen und scannen – Feuer-Filter liegt woanders.
func _get_target_root(node: Node3D) -> Node3D:
	var current: Node = node
	while current:
		if current is Node3D:
			var n3d := current as Node3D
			if n3d == _own_ship:
				return null
			if n3d.is_in_group("ships"):
				return n3d
		current = current.get_parent()
	return null


# ─────────────────────────────────────────────────────────────────────────────
# SINGLE TARGET LOCK (TAB) – jedes Schiff ist erlaubt
# ─────────────────────────────────────────────────────────────────────────────

func _cycle_lock() -> void:
	# Beim Single-Lock: Multi-Target-Liste leeren (klare Trennung)
	_clear_multi_locks_silent()

	if current_mode == Mode.TARGET_LOCK:
		var next: Node3D = _find_next_target(locked_target)
		if next:
			_dbg("LOCK: Wechsel → '%s' (hostile=%s)" % [next.name, _is_hostile(next)])
			_set_lock(next)
		else:
			_dbg("LOCK: Kein weiteres Ziel → release")
			_release_lock()
	else:
		var nearest: Node3D = _find_next_target(null)
		if nearest:
			_dbg("LOCK: Aktiviert → '%s' (hostile=%s)" % [nearest.name, _is_hostile(nearest)])
			_set_lock(nearest)
		else:
			_dbg("LOCK: ❌ Keine Ziele innerhalb %.0fm" % max_lock_range)


func _set_lock(target: Node3D) -> void:
	locked_target  = target
	current_mode   = Mode.TARGET_LOCK
	hovered_target = null
	targeting_mode_changed.emit(current_mode)
	target_locked.emit(target)
	_set_reticle_state(TargetReticle.State.LOCKED)
	# Disposition direkt setzen – Farbe aktualisiert sich sofort
	_set_reticle_disposition(target)
	_dbg("LOCK gesetzt → '%s'" % target.name)


func _release_lock() -> void:
	locked_target  = null
	hovered_target = null
	current_mode   = Mode.MANUAL
	targeting_mode_changed.emit(current_mode)
	target_lock_released.emit()
	_set_reticle_state(TargetReticle.State.HIDDEN)
	_dbg("LOCK: Aufgehoben → Mode=MANUAL")


func _validate_lock() -> void:
	if not is_instance_valid(locked_target):
		_dbg("LOCK VALIDATE: Ziel ungültig → release")
		_release_lock()
		return

	var sc := _find_ship_controller_of(locked_target)
	if sc and sc.get_hull_integrity() <= 0.0:
		_dbg("LOCK VALIDATE: Ziel zerstört → release")
		_release_lock()
		return

	# CLOAK-VALIDATE: Wenn sich das Target getarnt hat und außer Detection-
	# Range ist, brechen wir den Lock. Innerhalb der Schimmer-Range bleibt
	# der Lock bestehen — der Spieler kann Cloakede Schiffe noch tracken
	# solange sie nah genug sind.
	# AUSNAHME: Schiffe im DECLOAKING-Übergang behalten den Lock immer —
	# sie tauchen gerade auf, der Lock soll nicht wegen temporär niedrigem
	# Alpha verloren gehen.
	if sc and sc.has_method("is_visible_to"):
		var cloak_comp: CloakComponent = sc.get_node_or_null("CloakComponent") as CloakComponent
		var is_decloaking: bool = cloak_comp != null and cloak_comp._state == CloakComponent.State.DECLOAKING
		if not is_decloaking and not sc.is_visible_to(_own_ship):
			_dbg("LOCK VALIDATE: Ziel getarnt + außer Detection-Range → release")
			_release_lock()
			return

	var dist: float = global_position.distance_to(locked_target.global_position)
	if dist > max_lock_range:
		_dbg("LOCK VALIDATE: Außer Reichweite (%.0f > %.0f) → release" % [dist, max_lock_range])
		_release_lock()


# ─────────────────────────────────────────────────────────────────────────────
# MULTI TARGET LOCK (SHIFT + TAB) – nur feindliche Schiffe
# ─────────────────────────────────────────────────────────────────────────────

func _add_to_multi_lock() -> void:
	# ── Gate: Multi-Target braucht einen feindlichen Einstieg ───────────────
	# Ohne aktuelles Lock ODER wenn das Lock nicht feindlich ist,
	# wird kein Multi-Target freigeschaltet. Silent-Reject.
	if current_mode != Mode.TARGET_LOCK or not is_instance_valid(locked_target):
		_dbg("MULTI: ❌ Kein aktives Lock → SHIFT+TAB ignoriert (silent)")
		return

	if not _is_hostile(locked_target):
		_dbg("MULTI: ❌ Aktuelles Lock '%s' nicht feindlich → SHIFT+TAB ignoriert (silent)" % locked_target.name)
		return

	# ── locked_target (hostile, garantiert) an Index 0 einfügen ────────────
	if not multi_locked_targets.has(locked_target):
		multi_locked_targets.insert(0, locked_target)
		multi_target_added.emit(locked_target)
		_dbg("MULTI: locked_target '%s' an Index 0 eingefügt" % locked_target.name)

	# ── Kandidaten suchen: NUR feindliche, nicht bereits in der Liste ──────
	var candidate: Node3D = null

	if hovered_target and is_instance_valid(hovered_target) \
			and not multi_locked_targets.has(hovered_target) \
			and _is_hostile(hovered_target):
		candidate = hovered_target
	else:
		var hostiles := _get_hostile_targets_sorted()
		for t: Node3D in hostiles:
			if not multi_locked_targets.has(t):
				candidate = t
				break

	if not candidate:
		_dbg("MULTI: Kein weiteres feindliches Ziel verfügbar")
		_rebuild_multi_reticles()
		return

	# FIFO: ältestes Ziel ab Index 1 entfernen wenn Liste voll.
	# Index 0 (= locked_target) wird nie entfernt.
	if multi_locked_targets.size() >= max_multi_targets:
		var remove_idx: int   = 1 if multi_locked_targets.size() > 1 else 0
		var removed:    Node3D = multi_locked_targets[remove_idx]
		multi_locked_targets.remove_at(remove_idx)
		multi_target_removed.emit(removed)
		_dbg("MULTI: Liste voll – '%s' entfernt" % removed.name)

	multi_locked_targets.append(candidate)
	multi_target_added.emit(candidate)
	_dbg("MULTI: '%s' hinzugefügt (%d/%d)" % [
		candidate.name, multi_locked_targets.size(), max_multi_targets
	])

	# Synchronisation locked_target ↔ multi[0]
	if locked_target != multi_locked_targets[0]:
		locked_target = multi_locked_targets[0]

	_rebuild_multi_reticles()


func _clear_multi_locks_silent() -> void:
	for t: Node3D in multi_locked_targets:
		multi_target_removed.emit(t)
	multi_locked_targets.clear()
	_rebuild_multi_reticles()


## Live-Re-Evaluation: prunet die Multi-Liste jeden Physics-Frame.
## Entfernt Ziele die
##   (a) nicht mehr valid sind,
##   (b) zerstört sind (integrity <= 0),
##   (c) nicht mehr feindlich sind (Disposition-Wechsel).
##
## Single-Lock (locked_target) bleibt beim Disposition-Wechsel bestehen –
## der Spieler behält den Scan-Lock. Auto-Fire stoppt automatisch weil
## is_current_target_hostile() dann false liefert.
func _prune_invalid_multi_targets() -> void:
	var changed := false

	for i: int in range(multi_locked_targets.size() - 1, -1, -1):
		var t: Node3D = multi_locked_targets[i]
		var remove   := false

		if not is_instance_valid(t):
			remove = true
		else:
			var sc := _find_ship_controller_of(t)
			if sc and sc.get_hull_integrity() <= 0.0:
				remove = true
			elif sc and sc.has_method("is_visible_to") and not sc.is_visible_to(_own_ship):
				# Cloak: Target ist getarnt UND außer Detection-Range → raus
				# AUSNAHME: DECLOAKING-Phase → behalten
				var cloak_comp: CloakComponent = sc.get_node_or_null("CloakComponent") as CloakComponent
				var is_decloaking: bool = cloak_comp != null and cloak_comp._state == CloakComponent.State.DECLOAKING
				if not is_decloaking:
					remove = true
					_dbg("MULTI: '%s' getarnt → raus" % t.name)
			elif not _is_hostile(t):
				# Disposition-Wechsel → raus aus Multi-Lock
				remove = true
				_dbg("MULTI: '%s' nicht mehr feindlich → raus" % t.name)

		if remove:
			multi_target_removed.emit(t)
			multi_locked_targets.remove_at(i)
			changed = true

	if not changed:
		return

	if multi_locked_targets.is_empty():
		# Multi leer: locked_target bleibt als Single-Scan-Lock bestehen.
		# Nur releasen wenn das Ziel ungültig/zerstört/außer-Reichweite ist.
		if not _is_target_alive(locked_target):
			_release_lock()
	elif not multi_locked_targets.has(locked_target):
		# Primary wurde entfernt (z.B. wurde friedlich) – nächstes Hostile übernimmt
		_set_lock(multi_locked_targets[0])

	_rebuild_multi_reticles()


## Alias-Bewahrer für externe Aufrufer die die alte Methode nutzen.
func _cleanup_dead_multi_targets() -> void:
	_prune_invalid_multi_targets()


# ─────────────────────────────────────────────────────────────────────────────
# ZIEL-SUCHE
# ─────────────────────────────────────────────────────────────────────────────

## Findet das nächste Ziel nach `after` in der vollständigen Schiffsliste.
## Cycled durch ALLE Dispositionen (Single-Lock darf jedes Schiff targeten).
func _find_next_target(after: Node3D) -> Node3D:
	var all_targets := _get_all_targets_sorted()
	_dbg("_find_next_target: %d Ziele in Reichweite (alle Dispositionen)" % all_targets.size())
	if all_targets.is_empty():
		return null
	if after == null:
		return all_targets[0]
	var idx: int = all_targets.find(after)
	if idx == -1 or idx >= all_targets.size() - 1:
		return all_targets[0]
	return all_targets[idx + 1]


## Alle Schiffe in der "ships"-Gruppe, sortiert nach Distanz.
## KEIN Fraktions-Filter – Single-Lock darf Freund/Neutral/Feind targeten.
func _get_all_targets_sorted() -> Array[Node3D]:
	var result: Array[Node3D] = []
	var all_ships: Array      = get_tree().get_nodes_in_group("ships")

	if show_debug:
		print("[TargetingSystem] Scan 'ships': %d Nodes" % all_ships.size())

	for node in all_ships:
		if not (node is Node3D) or not is_instance_valid(node):
			continue
		var n3d := node as Node3D

		if n3d == _own_ship:
			continue

		# Nur Root-Schiffe – Duplikate durch AIController + ShipController-Child vermeiden
		var ancestor: Node = n3d.get_parent()
		var has_ship_ancestor: bool = false
		while ancestor:
			if ancestor is Node3D and (ancestor as Node3D).is_in_group("ships"):
				has_ship_ancestor = true
				break
			ancestor = ancestor.get_parent()
		if has_ship_ancestor:
			continue

		# Zerstörte Schiffe überspringen
		var sc := _find_ship_controller_of(n3d)
		if sc and sc.get_hull_integrity() <= 0.0:
			if show_debug:
				print("[TargetingSystem]   → SKIP (zerstört): '%s'" % n3d.name)
			continue

		# CLOAK-FILTER: Cloakede Ships sind nicht targetbar.
		# AUSNAHME: Schiffe im DECLOAKING-Übergang sind immer targetbar —
		# sie haben den Cloak schon gebrochen und tauchen gerade auf.
		# Ohne diese Ausnahme würde der Lock sofort released wenn der NPC
		# aus dem Cloak heraus angreift (Alpha noch nahe 0 am Anfang des Fades).
		if sc and sc.has_method("is_visible_to"):
			var cloak_comp: CloakComponent = sc.get_node_or_null("CloakComponent") as CloakComponent
			var is_decloaking: bool = cloak_comp != null and cloak_comp._state == CloakComponent.State.DECLOAKING
			if not is_decloaking and not sc.is_visible_to(_own_ship):
				if show_debug:
					print("[TargetingSystem]   → SKIP (cloaked): '%s'" % n3d.name)
				continue

		var dist: float = global_position.distance_to(n3d.global_position)
		if dist <= max_lock_range:
			result.append(n3d)

	result.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return global_position.distance_to(a.global_position) \
			< global_position.distance_to(b.global_position)
	)
	return result


## NEU: Gefilterte Variante – nur feindliche Schiffe, sortiert nach Distanz.
## Wird von _add_to_multi_lock() genutzt.
func _get_hostile_targets_sorted() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for t: Node3D in _get_all_targets_sorted():
		if _is_hostile(t):
			result.append(t)
	return result


# ─────────────────────────────────────────────────────────────────────────────
# HAUPT-OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

## Primäres Feuerziel (Single-Lock oder erstes Multi-Target)
func get_fire_position() -> Vector3:
	match current_mode:
		Mode.TARGET_LOCK:
			if is_instance_valid(locked_target):
				return locked_target.global_position
			_release_lock()
			return _get_manual_position()
		_:
			return _get_manual_position()


func _get_manual_position() -> Vector3:
	if hovered_target != null and is_instance_valid(hovered_target):
		return hovered_target.global_position
	return _get_mouse_world_position(global_position.y + manual_empty_space_height)


func _get_mouse_world_position(plane_y: float) -> Vector3:
	if not _camera or not _viewport:
		return global_position + Vector3(0, manual_empty_space_height, 0)

	var mouse_pos:  Vector2 = _viewport.get_mouse_position()
	var ray_origin: Vector3 = _camera.project_ray_origin(mouse_pos)
	var ray_dir:    Vector3 = _camera.project_ray_normal(mouse_pos)

	var hit: Variant = Plane(Vector3.UP, plane_y).intersects_ray(ray_origin, ray_dir)
	if hit:
		return hit
	var fallback: Vector3 = ray_origin + ray_dir * 1000.0
	fallback.y            = plane_y
	return fallback


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

func get_mode()           -> Mode:   return current_mode
func get_locked_target()  -> Node3D: return locked_target
func get_hovered_target() -> Node3D: return hovered_target

func get_active_target() -> Node3D:
	if current_mode == Mode.TARGET_LOCK:
		return locked_target
	return hovered_target

func has_target() -> bool:
	return get_active_target() != null

func get_multi_targets() -> Array[Node3D]:
	return multi_locked_targets

func has_multi_targets() -> bool:
	return multi_locked_targets.size() > 1

## NEU: Auto-Fire-Friendly-Fire-Sicherung.
## true wenn das aktuelle primäre Ziel feindlich ist.
## Multi-Locks sind per Invariante IMMER feindlich – einzig der Single-Lock
## kann non-hostile sein (Scan-Lock auf Freund/Neutral).
func is_current_target_hostile() -> bool:
	var t := get_active_target()
	return _is_hostile(t)

## NEU: Disposition des aktuellen Ziels für HUD / externe Nutzung.
func get_current_disposition() -> TargetReticle.Disposition:
	return _get_disposition_for(get_active_target())

func release_target() -> void:
	if current_mode == Mode.TARGET_LOCK:
		_release_lock()
	_clear_multi_locks_silent()

func force_release_lock() -> void:
	release_target()

## KI-API: Ziel von außen setzen (kein Reticle da show_reticle=false bei NPCs)
func force_lock(target: Node3D) -> void:
	if not is_instance_valid(target):
		push_warning("[TargetingSystem] force_lock: ungültiges Ziel")
		return
	_set_lock(target)
	_dbg("force_lock → '%s'" % target.name)

func force_release() -> void:
	_release_lock()
	_dbg("force_release")


# ─────────────────────────────────────────────────────────────────────────────
# DISPOSITION / FRAKTIONS-HELPERS
# ─────────────────────────────────────────────────────────────────────────────

## Hostile-Check mit Null-Safety.
func _is_hostile(target: Node3D) -> bool:
	if not is_instance_valid(target) or not _own_ship:
		return false
	return FactionSystem.are_hostile(_own_ship, target)


## Lebend-Check: valid + integrity > 0.
func _is_target_alive(target: Node3D) -> bool:
	if not is_instance_valid(target):
		return false
	var sc := _find_ship_controller_of(target)
	if sc and sc.get_hull_integrity() <= 0.0:
		return false
	return true


## Disposition eines Ziels:
##   HOSTILE  → FactionSystem.are_hostile() == true
##   FRIENDLY → gleiche Fraktion wie _own_ship
##   NEUTRAL  → alles andere (unbekannt / nicht feindlich / nicht gleich)
func _get_disposition_for(target: Node3D) -> TargetReticle.Disposition:
	if not is_instance_valid(target) or not _own_ship:
		return TargetReticle.Disposition.NEUTRAL
	if FactionSystem.are_hostile(_own_ship, target):
		return TargetReticle.Disposition.HOSTILE
	if _is_same_faction(_own_ship, target):
		return TargetReticle.Disposition.FRIENDLY
	return TargetReticle.Disposition.NEUTRAL


## Gleiche Fraktion = gleicher ShipData.faction-Wert.
func _is_same_faction(a: Node3D, b: Node3D) -> bool:
	var sc_a := _find_ship_controller_of(a)
	var sc_b := _find_ship_controller_of(b)
	if not sc_a or not sc_b:
		return false
	if not sc_a.ship_data or not sc_b.ship_data:
		return false
	return sc_a.ship_data.faction == sc_b.ship_data.faction


# ─────────────────────────────────────────────────────────────────────────────
# RETICLE
# ─────────────────────────────────────────────────────────────────────────────

func _exit_tree() -> void:
	if _reticle_layer and is_instance_valid(_reticle_layer):
		_reticle_layer.queue_free()
		_reticle_layer = null
		_reticle       = null
	for r in _multi_reticles:
		if r and is_instance_valid(r):
			r.queue_free()
	_multi_reticles.clear()


func _init_reticle() -> void:
	if not show_reticle or not is_player_controlled:
		if show_reticle and not is_player_controlled:
			push_warning("[TargetingSystem] '%s': show_reticle=true aber is_player_controlled=false → kein Reticle erzeugt! Bitte is_player_controlled im Inspector aktivieren oder show_reticle deaktivieren." % (get_parent().name if get_parent() else "?"))
		return

	_reticle_layer       = CanvasLayer.new()
	_reticle_layer.layer = 10
	add_child(_reticle_layer)

	if reticle_scene:
		_reticle = reticle_scene.instantiate()
	else:
		_reticle = TargetReticle.new()

	_reticle_layer.add_child(_reticle)
	_set_reticle_state(TargetReticle.State.HIDDEN)
	print("[TargetingSystem] Reticle initialisiert: %s" % _reticle.get_class())


func _rebuild_multi_reticles() -> void:
	if not show_reticle or not is_player_controlled or not _reticle_layer:
		return

	for r in _multi_reticles:
		if r and is_instance_valid(r):
			r.queue_free()
	_multi_reticles.clear()

	# Multi-Reticles ab Index 1 – Index 0 ist das primäre Reticle
	for i: int in range(1, multi_locked_targets.size()):
		var r: Node
		if reticle_scene:
			r = reticle_scene.instantiate()
		else:
			r = TargetReticle.new()
		_reticle_layer.add_child(r)
		if r.has_method("set_state"):
			r.set_state(TargetReticle.State.LOCKED)
		# Multi-Locks sind per Invariante IMMER hostile → rote Farbe
		if r.has_method("set_disposition"):
			r.set_disposition(TargetReticle.Disposition.HOSTILE)
		if r is Control:
			(r as Control).scale = Vector2(0.75, 0.75)
		_multi_reticles.append(r)


func _update_all_reticles() -> void:
	if not show_reticle or not is_player_controlled or not _camera:
		return

	# ── Primäres Reticle ──────────────────────────────────────────────────
	var primary: Node3D
	if multi_locked_targets.size() > 0 and is_instance_valid(multi_locked_targets[0]):
		primary = multi_locked_targets[0]
	else:
		primary = get_active_target()

	if primary and current_mode == Mode.MANUAL:
		_set_reticle_state(TargetReticle.State.TRACKING)
	elif not primary and current_mode == Mode.MANUAL:
		_set_reticle_state(TargetReticle.State.HIDDEN)

	if primary and _reticle:
		var screen_pos: Vector2 = _camera.unproject_position(primary.global_position)
		_set_reticle_pos(screen_pos)
		# Disposition jeden Frame aktualisieren (reagiert auf Ruf-Änderungen)
		if current_mode == Mode.TARGET_LOCK:
			_set_reticle_disposition(primary)

	# ── Sekundäre Multi-Target-Reticles (Index 1..n) ──────────────────────
	for i: int in range(_multi_reticles.size()):
		var idx: int  = i + 1
		if idx >= multi_locked_targets.size():
			break
		var t: Node3D = multi_locked_targets[idx]
		var r: Node   = _multi_reticles[i]
		if not r or not is_instance_valid(r) or not is_instance_valid(t):
			continue
		var sp: Vector2 = _camera.unproject_position(t.global_position)
		if r.has_method("set_screen_pos"):
			r.set_screen_pos(sp)


func _set_reticle_state(state: TargetReticle.State) -> void:
	if _reticle and _reticle.has_method("set_state"):
		_reticle.set_state(state)


## NEU: Disposition auf Primär-Reticle setzen – Farbwechsel live.
func _set_reticle_disposition(target: Node3D) -> void:
	if not _reticle or not _reticle.has_method("set_disposition"):
		return
	_reticle.set_disposition(_get_disposition_for(target))


func _set_reticle_pos(pos: Vector2) -> void:
	if _reticle and _reticle.has_method("set_screen_pos"):
		_reticle.set_screen_pos(pos)


## Sucht ShipController: direkt via Meta ODER als Kind-Node (AIController-Fall).
func _find_ship_controller_of(node: Node3D) -> ShipController:
	if node == null or not is_instance_valid(node):
		return null
	if node.has_meta("ship_controller"):
		var sc: Variant = node.get_meta("ship_controller")
		if sc is ShipController:
			return sc as ShipController
	for child in node.find_children("*", "ShipController", true, false):
		if child is ShipController:
			return child as ShipController
	return null


func _dbg(msg: String) -> void:
	if show_debug:
		print("[TargetingSystem] %s" % msg)
