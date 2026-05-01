# res://scripts/hull_damage_vfx.gd
#
# Persistente Damage-VFX-Verwaltung für ein Schiff.
#
# Konzept (sauber getrennt von HullImpactReceiver und HullDamageVisualizer):
#   • Liest jeden Frame damage_amount aus dem ShipController (wie der Visualizer)
#   • Berechnet wieviele VFX-Spots aktiv sein SOLLEN (Random-aber-gedeckelt)
#   • Spawnt fehlende oder despawnt überzählige VFX
#   • VFX leben PERSISTENT, solange das Schiff Schaden hat — kein Cycling
#   • Bei Reparatur (damage_amount → 0): sanfter Fade-Out aller VFX
#
# Spot-Anzahl-Logik (Random-aber-gedeckelt):
#   • Ziel-Anzahl = floor(damage_amount * max_simultaneous_spots) + Random-Offset
#   • Random-Offset: -1, 0, +1 (zufällig pro Re-Evaluation)
#   • Hard-Cap durch max_simultaneous_spots
#   • Damit pulsiert die Anzahl leicht um den Erwartungswert
#
# Spawn-Locations (Mix-Strategie):
#   • Primär: Nodes in Group "damage_vfx_anchors" (manuell platziert im Schiff-TSCN)
#   • Fallback: Random-Surface-Sampling auf MeshInstance3D-AABB (wie HullImpactReceiver)
#
# VFX-Auswahl:
#   • Random aus vfx_scenes: Array[PackedScene]
#   • Skript erkennt automatisch ob die VFX-Wurzel set_intensity() exponiert
#     und ruft sie ggf. mit dem aktuellen damage_amount auf
extends Node3D
class_name HullDamageVfx

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
const ANCHOR_GROUP_NAME: StringName = &"damage_vfx_anchors"


# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export_group("Ship Reference")
## ShipController-Referenz. Wenn leer, wird automatisch im Eltern-Baum gesucht.
@export var ship_controller_path: NodePath

## Mesh für Random-Sampling-Fallback (wenn keine Anker existieren).
## Kann leer bleiben wenn nur manuelle Anker verwendet werden.
@export var mesh_instance: MeshInstance3D

## Wo VFX als Kind angehängt werden. Wenn leer: Eltern dieses Knotens.
## Wichtig: muss ein Node3D sein, damit VFX dem Schiff bei Bewegung folgen.
@export var vfx_parent_path: NodePath

@export_group("VFX Scenes")
## Library aus VFX-Szenen. Bei jedem Spawn wird zufällig eine ausgewählt.
## Mehr Variation in dieser Liste = lebendiger wirkende Schäden.
@export var vfx_scenes: Array[PackedScene] = []

@export_group("Spot Count")
## Maximale Anzahl gleichzeitig aktiver VFX-Spots.
## Bei sehr großen Schiffen kann das hochgesetzt werden, kleinere Schiffe
## sehen mit 4-6 schon "in Flammen" aus.
@export_range(1, 20) var max_simultaneous_spots: int = 6

## Schwellwert: unter diesem damage_amount-Wert werden 0 VFX gespawnt.
## Default 0.05 = bei sehr leichtem Schaden gibt's noch keine Plumes.
@export_range(0.0, 1.0, 0.01) var min_damage_for_vfx: float = 0.05

## Wie oft die Ziel-Anzahl neu gewürfelt wird (Sekunden).
## Niedriger Wert = nervöses Rauf-Runter, hoher Wert = stabile Anzahl.
@export_range(0.5, 10.0, 0.5) var spot_count_reroll_interval: float = 3.0

@export_group("VFX Lifecycle")
## Fade-Out-Dauer für VFX bei Reparatur oder beim Despawn überzähliger VFX.
## Während Fade ruft das Skript stop_emitting() (falls vorhanden), wartet
## und despawnt dann den VFX-Knoten.
@export_range(0.5, 10.0) var vfx_fade_out_time: float = 3.0

@export_group("Anchor Filter")
## 0.0 = jede Anker-Position akzeptiert; 1.0 = nur Anker auf "obersten" Stellen.
## Bei niedrigem Schaden (wenige aktive Spots) bevorzugen wir manchmal
## sichtbare Stellen — das wird über diesen Wert gemacht.
@export_range(0.0, 1.0) var anchor_visibility_bias: float = 0.0

@export_group("Random Sampling Fallback")
## Wird nur verwendet wenn keine Anker in Group "damage_vfx_anchors" gefunden
## werden. Identisch zum HullImpactReceiver-Mechanismus.
@export_range(0.0, 1.0) var surface_normal_threshold: float = 0.3

@export_group("Debug")
@export var debug_vfx: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────
var _ship_ctrl:        Node             = null
var _vfx_parent:       Node3D           = null
var _ship_root:        Node             = null
var _space_state:      PhysicsDirectSpaceState3D = null

# Aktive VFX-Liste mit Anker-Tracking, damit wir nicht zweimal den selben Anker
# besetzen.
var _active_spots:     Array[Dictionary] = []   # [{ "vfx": Node3D, "anchor": Node3D|null }, ...]

# Cached Anker-Liste (nur Knoten unter unserem Ship-Root, die in der Group sind)
var _anchor_pool:      Array[Node3D]    = []
var _anchor_pool_dirty: bool             = true   # neu scannen wenn nötig

# Ziel-Anzahl-Verwaltung
var _target_spot_count: int             = 0
var _reroll_timer:      float           = 0.0

# Damage-Tracking
var _last_damage_amount: float          = 0.0
var _is_repairing:       bool           = false


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_resolve_ship_controller()
	_resolve_vfx_parent()
	_resolve_ship_root()

	if vfx_scenes.is_empty():
		push_warning("[HDVfx|%s] vfx_scenes-Array leer — keine VFX werden gespawnt." % name)
		set_process(false)
		return

	if not _ship_ctrl:
		push_warning("[HDVfx|%s] Kein ShipController gefunden — VFX-System inaktiv." % name)
		set_process(false)
		return

	# Anker einmalig scannen (kann später per refresh_anchors() neu)
	_rebuild_anchor_pool()

	if debug_vfx:
		print("[HDVfx|%s] ready | ship_ctrl=%s | anchors=%d | vfx_scenes=%d | mesh_fallback=%s" % [
			name,
			_ship_ctrl.name,
			_anchor_pool.size(),
			vfx_scenes.size(),
			"✓" if mesh_instance else "✗"
		])


func _process(delta: float) -> void:
	# Space-State erst greifen wenn verfügbar
	if not _space_state and get_viewport():
		var w := get_viewport().world_3d
		if w:
			_space_state = w.direct_space_state

	var damage: float = float(_ship_ctrl.get_hull_integrity())
	damage = clamp(1.0 - damage, 0.0, 1.0)

	# Bei Reparatur: alle VFX ausfaden
	if damage < min_damage_for_vfx:
		if not _active_spots.is_empty() and not _is_repairing:
			_is_repairing = true
			_fade_out_all_spots()
		_last_damage_amount = damage
		return

	if _is_repairing:
		_is_repairing = false  # Damage wieder über Schwelle, Reparatur abgebrochen

	# Reroll-Timer
	_reroll_timer += delta
	if _reroll_timer >= spot_count_reroll_interval:
		_reroll_timer = 0.0
		_target_spot_count = _compute_target_spot_count(damage)

	# Initial-Reroll falls noch keiner gemacht wurde
	if _target_spot_count == 0 and damage >= min_damage_for_vfx:
		_target_spot_count = _compute_target_spot_count(damage)

	# Aktive Liste aufräumen (despawnte VFX entfernen)
	_prune_invalid_spots()

	# Spawn / Despawn nach Bedarf
	var current: int = _active_spots.size()
	if current < _target_spot_count:
		_spawn_one_spot(damage)
	elif current > _target_spot_count:
		_fade_out_one_spot()

	# Optional: Intensität an aktuelle damage-Stärke anpassen
	_update_intensity_on_active(damage)

	_last_damage_amount = damage


# ─────────────────────────────────────────────────────────────────────────────
# SPOT-COUNT BERECHNUNG (Random-aber-gedeckelt)
# ─────────────────────────────────────────────────────────────────────────────
## Berechnet die ANGESTREBTE Anzahl Spots für gegebenen damage-Level.
## Random-Offset von -1/0/+1 macht das Verhalten lebendiger als rein lineares
## Mapping. Hard-Cap durch max_simultaneous_spots.
func _compute_target_spot_count(damage: float) -> int:
	# Basiswert: linear gemappt von 0..max_simultaneous_spots
	var base_target: float = damage * float(max_simultaneous_spots)

	# Random-Offset (jitter) — gibt natürliches Wackeln in der Spot-Anzahl
	var jitter: int = randi_range(-1, 1)

	var target: int = int(round(base_target)) + jitter
	target = clamp(target, 0, max_simultaneous_spots)

	if debug_vfx:
		print("[HDVfx|%s] reroll: damage=%.2f → base=%.1f, jitter=%d, target=%d" % [
			name, damage, base_target, jitter, target])

	return target


# ─────────────────────────────────────────────────────────────────────────────
# SPAWN
# ─────────────────────────────────────────────────────────────────────────────
## Spawnt EINEN VFX-Spot.
## Strategie:
##   1) Wenn Anker verfügbar (und noch nicht alle besetzt): nutze Anker
##   2) Sonst: Random-Surface-Sampling auf mesh_instance
##   3) Wenn beides scheitert: stillschweigend abbrechen
func _spawn_one_spot(damage: float) -> void:
	if vfx_scenes.is_empty():
		return

	# Position bestimmen
	var spawn_pos:    Vector3 = Vector3.ZERO
	var spawn_normal: Vector3 = Vector3.UP
	var anchor_used:  Node3D  = null

	var available_anchors := _get_available_anchors()
	if not available_anchors.is_empty():
		anchor_used  = available_anchors[randi() % available_anchors.size()]
		spawn_pos    = anchor_used.global_position
		# Anker können optional eine global_basis.y exponieren als Normale,
		# sonst nehmen wir Welt-UP des Schiff-Roots
		spawn_normal = anchor_used.global_basis.y if anchor_used else Vector3.UP
	else:
		# Random-Sampling-Fallback
		var hit := _sample_random_surface_point()
		if hit.is_empty():
			if debug_vfx:
				print("[HDVfx|%s] Spawn fehlgeschlagen — kein Anker, kein Surface-Hit." % name)
			return
		spawn_pos    = hit["position"]
		spawn_normal = hit["normal"]

	# Random VFX-Szene aus Library wählen
	var scene: PackedScene = vfx_scenes[randi() % vfx_scenes.size()]
	if not scene:
		return
	var inst := scene.instantiate() as Node3D
	if not inst:
		push_warning("[HDVfx|%s] VFX-Szene konnte nicht instanziiert werden." % name)
		return

	_vfx_parent.add_child(inst)
	inst.global_position = spawn_pos

	# Orientierung: VFX zeigt entlang der Hüllen-Normalen nach außen.
	# Falls die VFX-Szene eine eigene Up-Achse erwartet, kann sie das via
	# eigener Logik überschreiben.
	if spawn_normal.length_squared() > 0.001:
		var look_pt: Vector3 = spawn_pos + spawn_normal
		# look_at mit Up-Vektor der nicht parallel zur Schaurichtung ist
		var up_ref: Vector3 = Vector3.RIGHT if abs(spawn_normal.dot(Vector3.UP)) > 0.95 else Vector3.UP
		inst.look_at(look_pt, up_ref)

	# Initiale Intensität setzen (falls VFX-Szene das unterstützt)
	if inst.has_method("set_intensity"):
		inst.set_intensity(damage)

	_active_spots.append({"vfx": inst, "anchor": anchor_used})

	if debug_vfx:
		print("[HDVfx|%s] Spawn @ %s | anchor=%s | aktiv: %d/%d" % [
			name, spawn_pos,
			anchor_used.name if anchor_used else "RANDOM",
			_active_spots.size(), _target_spot_count
		])


# ─────────────────────────────────────────────────────────────────────────────
# DESPAWN / FADE
# ─────────────────────────────────────────────────────────────────────────────
## Faded EINEN aktiven Spot aus (zufällig gewählt).
## Wird genutzt wenn target_spot_count gesunken ist.
func _fade_out_one_spot() -> void:
	if _active_spots.is_empty():
		return
	var idx: int = randi() % _active_spots.size()
	var entry: Dictionary = _active_spots[idx]
	_active_spots.remove_at(idx)
	_fade_out_vfx(entry["vfx"])


## Faded ALLE aktiven Spots aus (bei Reparatur).
func _fade_out_all_spots() -> void:
	if debug_vfx:
		print("[HDVfx|%s] Reparatur erkannt — fade out aller %d Spots." % [name, _active_spots.size()])
	for entry in _active_spots:
		_fade_out_vfx(entry["vfx"])
	_active_spots.clear()


## Faded einen einzelnen VFX-Knoten aus.
## Strategie:
##   1) Wenn der Knoten stop_emitting() hat → aufrufen (Partikel hören auf zu emittieren)
##   2) Wenn der Knoten emitting auf false setzbar hat → setzen
##   3) Nach vfx_fade_out_time: queue_free()
func _fade_out_vfx(vfx: Node3D) -> void:
	if not is_instance_valid(vfx):
		return

	# Stop-Emitting versuchen (drei Fallbacks für unterschiedliche Setups)
	if vfx.has_method("stop_emitting"):
		vfx.stop_emitting()
	else:
		# Auf alle GPUParticles3D-Kinder zugreifen, emitting = false
		for child in vfx.find_children("*", "GPUParticles3D", true):
			if child is GPUParticles3D:
				(child as GPUParticles3D).emitting = false

	# Despawn nach Fade-Out-Zeit
	get_tree().create_timer(vfx_fade_out_time).timeout.connect(
		func():
			if is_instance_valid(vfx):
				vfx.queue_free()
	)


## Räumt _active_spots auf — entfernt Einträge, deren VFX queue_free()d sind.
func _prune_invalid_spots() -> void:
	for i in range(_active_spots.size() - 1, -1, -1):
		if not is_instance_valid(_active_spots[i]["vfx"]):
			_active_spots.remove_at(i)


# ─────────────────────────────────────────────────────────────────────────────
# INTENSITÄT JEDEN FRAME (optional, wenn VFX set_intensity() exponiert)
# ─────────────────────────────────────────────────────────────────────────────
## Wenn die VFX-Szene set_intensity(value: float) hat, ruft das Skript es
## jeden Frame mit dem aktuellen damage_amount. Damit kann eine VFX-Szene
## ihre Partikel-Anzahl, Helligkeit, Geschwindigkeit etc. dynamisch anpassen.
## Optional: VFX-Szenen ohne set_intensity bleiben statisch — auch ok.
func _update_intensity_on_active(damage: float) -> void:
	for entry in _active_spots:
		var vfx: Node3D = entry["vfx"]
		if is_instance_valid(vfx) and vfx.has_method("set_intensity"):
			vfx.set_intensity(damage)


# ─────────────────────────────────────────────────────────────────────────────
# ANKER-VERWALTUNG (Group-basiert: "damage_vfx_anchors")
# ─────────────────────────────────────────────────────────────────────────────
## Scannt die Group damage_vfx_anchors und filtert auf Knoten, die zu UNSEREM
## Schiff gehören (Ancestor-Vergleich gegen _ship_root). Damit Anker eines
## anderen Schiffs ignoriert werden.
func _rebuild_anchor_pool() -> void:
	_anchor_pool.clear()
	if not _ship_root:
		return
	var nodes: Array = get_tree().get_nodes_in_group(ANCHOR_GROUP_NAME)
	for n in nodes:
		if not (n is Node3D):
			continue
		if _is_descendant_of_ship(n):
			_anchor_pool.append(n as Node3D)
	_anchor_pool_dirty = false


## Gibt Anker zurück, die noch NICHT von einem aktiven Spot besetzt sind.
## Damit verteilen sich VFX über mehrere Anker statt sich zu stapeln.
func _get_available_anchors() -> Array:
	if _anchor_pool_dirty:
		_rebuild_anchor_pool()

	var available: Array = []
	for anchor in _anchor_pool:
		var occupied := false
		for entry in _active_spots:
			if entry["anchor"] == anchor:
				occupied = true
				break
		if not occupied:
			available.append(anchor)
	return available


## Geht den Hierarchie-Baum vom Knoten nach oben und prüft, ob er unter
## unserem Ship-Root sitzt.
func _is_descendant_of_ship(node: Node) -> bool:
	if not _ship_root:
		return false
	var n: Node = node
	while n:
		if n == _ship_root:
			return true
		n = n.get_parent()
	return false


## Optional public API — kann von außen gerufen werden falls Anker dynamisch
## hinzugefügt/entfernt werden.
func refresh_anchors() -> void:
	_anchor_pool_dirty = true


# ─────────────────────────────────────────────────────────────────────────────
# RANDOM SURFACE SAMPLING (Fallback wenn keine Anker)
# ─────────────────────────────────────────────────────────────────────────────
## Vereinfachte Version vom HullImpactReceiver-Sampling.
func _sample_random_surface_point() -> Dictionary:
	if not mesh_instance or not mesh_instance.mesh or not _space_state:
		return {}

	for attempt in 10:
		var aabb: AABB = mesh_instance.mesh.get_aabb()
		var random_local := Vector3(
			randf_range(aabb.position.x, aabb.position.x + aabb.size.x),
			randf_range(aabb.position.y, aabb.position.y + aabb.size.y),
			randf_range(aabb.position.z, aabb.position.z + aabb.size.z)
		)
		var pad: float    = aabb.size.y * 0.8 + 1.0
		var from: Vector3 = mesh_instance.to_global(random_local + Vector3.UP * pad)
		var to:   Vector3 = mesh_instance.to_global(random_local - Vector3.UP * pad)

		var params := PhysicsRayQueryParameters3D.create(from, to)
		params.collide_with_bodies = true
		params.collide_with_areas  = false
		var result := _space_state.intersect_ray(params)
		if result.is_empty():
			continue
		if not _is_descendant_of_ship(result.collider as Node):
			continue
		var local_up: Vector3 = mesh_instance.global_basis.y.normalized()
		if result.normal.dot(local_up) < surface_normal_threshold:
			continue

		return {"position": result.position as Vector3, "normal": result.normal as Vector3}

	return {}


# ─────────────────────────────────────────────────────────────────────────────
# RESOLVERS
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
			return
		n = n.get_parent()


func _resolve_vfx_parent() -> void:
	if not vfx_parent_path.is_empty():
		_vfx_parent = get_node_or_null(vfx_parent_path) as Node3D
	if not _vfx_parent:
		_vfx_parent = get_parent() as Node3D
	if not _vfx_parent:
		_vfx_parent = self  # absoluter Fallback


func _resolve_ship_root() -> void:
	if _ship_ctrl and _ship_ctrl.get_parent():
		_ship_root = _ship_ctrl.get_parent()
		return
	# Fallback: aufwärts vom self bis zum ersten CharacterBody3D
	var n: Node = self
	while n:
		if n is CharacterBody3D:
			_ship_root = n
			return
		n = n.get_parent()
	_ship_root = _vfx_parent
