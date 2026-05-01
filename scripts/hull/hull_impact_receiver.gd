# res://scripts/hull_impact_receiver.gd
#
# DUALES SYSTEM — koexistiert mit Phaser-Treffer-Effekten:
# ─────────────────────────────────────────────────────────
#   1) Hit-Effekte (klein, kurzlebig):  werden vom hull_impact.tscn (Sparks +
#      ScorchDecal + Burn1-3) direkt am Treffer-Punkt gespawnt — getriggert
#      vom BeamWeapon3D. Dieser Receiver ist daran NICHT beteiligt.
#
#   2) Damage-State-Decals (groß, langlebig):  spawnen schleichend an
#      ZUFÄLLIGEN Stellen der Hülle, gesteuert über `damage_level` (0-1).
#      Visualisieren den Gesamt-Schadenszustand des Schiffes — unabhängig
#      von einzelnen Treffern. Genau das macht dieses Skript.
#
# `register_impact(pos, normal)` bleibt als API-Kompatibilität für
# weapon_beam.gd erhalten; sie beschleunigt nur den nächsten Spawn-Tick
# leicht (kausales Spielgefühl), spawnt aber nicht direkt am Treffer.
extends Node
class_name HullImpactReceiver

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export_group("Ship Reference")
## Haupt-Mesh, dessen AABB für das Surface-Sampling verwendet wird (Saucer, Hull etc.).
@export var mesh_instance: MeshInstance3D
## Optional: weitere Meshes (z.B. Stardrive bei Sovereign). Surface-Sampling pickt
## bei jedem Spawn zufällig eines davon — gibt visuell verteilten Schaden über
## das ganze Schiff statt nur einer Region.
@export var additional_meshes: Array[MeshInstance3D] = []
## Wo Decals als Kind angehängt werden. Default: Parent von mesh_instance.
## Wichtig: Decals MÜSSEN unter dem bewegten Schiff hängen, sonst kleben sie
## im Weltraum während sich das Schiff weiterbewegt.
@export var decal_parent_path: NodePath
## Optional: ShipController-Referenz für automatisches HP-Polling. Wenn gesetzt
## und der Controller `hull_hp` + `hull_hp_max` als Properties hat, wird
## damage_level jeden Frame automatisch aus der HP-Quote berechnet.
@export var ship_controller_path: NodePath

@export_group("Decal Scene")
@export var damage_decal_scenes: Array[PackedScene] = []
#@export var damage_decal_scene: PackedScene

@export_group("Performance")
@export var max_decals: int = 20

@export_group("Decal VFX")
## Verfügbare Partikel-Effekte (Funken, kleine Flammen, Rauch, Embers)
@export var vfx_scenes: Array[PackedScene] = []

@export_subgroup("VFX Settings")
@export_range(0.0, 1.0) var vfx_spawn_chance_base: float = 0.35     # Basis-Chance
@export_range(0.0, 1.0) var vfx_spawn_chance_max: float = 0.85      # bei 100% Schaden
@export var vfx_max_per_decal: int = 2

@export_group("Spawn Behavior")
## Sekunden zwischen Spawn-Versuchen bei MINIMALEM Schaden (1%).
@export var slow_spawn_interval: float = 4.0
## Sekunden zwischen Spawn-Versuchen bei MAXIMALEM Schaden (100%).
@export var fast_spawn_interval: float = 0.4
## Lebensdauer eines einzelnen Damage-Decals (Sekunden). Inkl. Fade-Out.
@export var decal_lifetime: float = 10.0
## Fade-Out-Dauer am Ende der Lebenszeit (Teil von decal_lifetime).
@export var decal_fade_out_time: float = 1.5
## Wenn true, bleiben die Decals dauerhaft bis das Schiff repariert oder zerstört wird.
@export var decals_permanent: bool = false
## 0.0 = jede Surface-Normale erlaubt; 0.5 = nur Oberseiten;
## 1.0 = nur exakt obere Flächen. Verhindert Decals an Unterseiten/Innenwänden.
@export_range(0.0, 1.0) var surface_normal_threshold: float = 0.3

@export_group("Damage Scaling")
@export var min_decal_size:    float = 0.6   ## bei damage_level ≈ 0.1
@export var max_decal_size:    float = 2.2   ## bei damage_level ≈ 1.0
@export var decal_thickness:   float = 1.0   ## Decal-Projektionstiefe (Y-Achse)
@export var min_emission:      float = 0.5
@export var max_emission:      float = 3.0

@export_group("Pulse Animation")
@export var min_pulse_speed:   float = 0.8
@export var max_pulse_speed:   float = 2.5
@export_range(0.0, 1.0) var pulse_amplitude: float = 0.4

@export_group("Debug")
@export var debug_spawn: bool = false

# ─────────────────────────────────────────────────────────────────────────────
# RUNTIME-STATE
# ─────────────────────────────────────────────────────────────────────────────
## 0.0 = heile Hülle | 1.0 = Totalschaden. Steuert Spawn-Rate, Größe, Emission.
## Quellen (in Reihenfolge):
##   1) Auto-Polling vom ShipController falls ship_controller_path gesetzt
##   2) Manueller Aufruf apply_damage(amount) oder set_damage_level(level)
var damage_level: float = 0.0

var _spawn_timer:    float           = 0.0
var _active_decals:  Array[Decal]    = []   # FIFO für max_decals-Limit
var _decal_parent:   Node3D          = null
var _ship_ctrl:      Node            = null
var _ship_root:      Node            = null   # gemeinsamer Schiffs-Container
var _meshes:         Array[MeshInstance3D] = []   # mesh_instance + additional_meshes
var _space_state:    PhysicsDirectSpaceState3D = null

# Diagnose-Flag: ein einziges Mal pro Schiff dürfen wir laut sein, falls
# Surface-Sampling 12-mal scheitert. Verhindert Log-Flut.
var _diag_first_fail_logged: bool = false

# HP-Polling: gefundene Quelle wird gecacht (einmalige Diagnose).
# Bevorzugte Quelle ist die Methode `get_hull_integrity() -> float` (Wert 0..1,
# 1 = heil, 0 = zerstört). Fallback: Property-Paar aus _HP_PROP_CANDIDATES.
var _use_integrity_method: bool       = false
var _hp_prop:              StringName = &""
var _hp_max_prop:          StringName = &""
var _hp_diag_done:         bool       = false
var _last_logged_dmg:      float      = -1.0   # für gedrosseltes Damage-Level-Logging

# Häufige Property-Namen-Varianten in ShipController-Implementierungen.
# Werden in dieser Reihenfolge probiert, das erste passende Paar gewinnt.
const _HP_PROP_CANDIDATES: Array = [
	["hull_hp",           "max_hull_hp"],   # Volkan-Konvention (ship_controller.gd)
	["hull_hp",           "hull_hp_max"],
	["current_hull_hp",   "max_hull_hp"],
	["hull_current",      "hull_max"],
	["hull_health",       "hull_health_max"],
	["hull",              "hull_max"],
	["hp",                "hp_max"],
	["current_hp",        "max_hp"],
]


# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	# ── Validierung ─────────────────────────────────────────────────────────
	if not mesh_instance:
		push_error("[HIR] mesh_instance nicht zugewiesen – Damage-State-System aus.")
		set_process(false)
		return
	if not damage_decal_scenes:
		push_error("[HIR] damage_decal_scene nicht zugewiesen – kein Spawning möglich.")
		set_process(false)
		return

	# ── Mesh-Liste konsolidieren ────────────────────────────────────────────
	_meshes.clear()
	_meshes.append(mesh_instance)
	for m in additional_meshes:
		if m and m != mesh_instance:
			_meshes.append(m)

	# ── Decal-Parent auflösen ───────────────────────────────────────────────
	# Wichtig: muss ein Node3D sein, damit Decals dem Schiff bei Bewegung folgen.
	if not decal_parent_path.is_empty():
		_decal_parent = get_node_or_null(decal_parent_path) as Node3D
	if not _decal_parent:
		_decal_parent = mesh_instance.get_parent() as Node3D
	if not _decal_parent:
		push_warning("[HIR] Decal-Parent unbestimmt – fallback auf current_scene (Decals folgen Schiff NICHT!).")
		_decal_parent = get_tree().current_scene as Node3D

	# ── Optional: ShipController auflösen ───────────────────────────────────
	if not ship_controller_path.is_empty():
		_ship_ctrl = get_node_or_null(ship_controller_path)

	# ── Schiffs-Root für Hit-Validierung bestimmen ──────────────────────────
	# Anker, gegen den wir prüfen, ob ein Raycast UNSER Schiff getroffen hat.
	# Strategie (in Reihenfolge):
	#   1) ShipController.get_parent() — typisch der CharacterBody3D / AiController,
	#      unter dem ALLE Schiff-Subknoten (Model, Hull-Collider, ...) hängen.
	#   2) Erster CharacterBody3D auf dem Weg von mesh_instance nach oben.
	#   3) Fallback: _decal_parent (ergibt das alte, zu strikte Verhalten).
	_ship_root = _resolve_ship_root()

	# ── Initialer Spawn-Timer (etwas Vorlauf, damit nicht sofort spawnt) ────
	_spawn_timer = slow_spawn_interval * 0.5

	if debug_spawn:
		print("[HIR] ready | meshes=%d | decal_parent=%s | ship_root=%s | ship_ctrl=%s" % [
			_meshes.size(),
			_decal_parent.name if _decal_parent else "?",
			_ship_root.name if _ship_root else "?",
			_ship_ctrl.name if _ship_ctrl else "—"
		])


func _process(delta: float) -> void:
	# Space-State erst beim ersten Frame greifen (get_world_3d darf in _ready
	# noch null liefern, je nach Szenenaufbau-Reihenfolge).
	if not _space_state:
		var w := get_viewport().world_3d if get_viewport() else null
		if w:
			_space_state = w.direct_space_state

	_poll_ship_hp_if_available()
	_pulse_active_decals()

	if damage_level <= 0.001:
		return

	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		# Lerp zwischen langsamer (geringer Schaden) und schneller (hoher Schaden) Rate.
		_spawn_timer = lerp(slow_spawn_interval, fast_spawn_interval, damage_level)
		# Wahrscheinlichkeit steigt auch mit Schaden — gibt natürliche Lücken bei
		# mittlerem Schaden statt mechanisch gleichmäßiger Spawns.
		if randf() < damage_level:
			_spawn_damage_decal()


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────
## Erhöht den Schadensgrad. Wird vom ShipController gerufen, wenn HP-Verlust.
## `amount` ist relativ (z.B. 0.05 = +5 % Schaden).
func apply_damage(amount: float) -> void:
	damage_level = clamp(damage_level + amount, 0.0, 1.0)
	if debug_spawn:
		print("[HIR] damage_level → %.2f" % damage_level)


## Direkter Setter, falls der HP-Wert von außen schon als Quote vorliegt.
func set_damage_level(level: float) -> void:
	damage_level = clamp(level, 0.0, 1.0)


## Reparatur: setzt Schaden zurück und entfernt alle aktiven Decals.
func repair_full() -> void:
	damage_level = 0.0
	_clear_all_decals()


## API-Kompatibilität für weapon_beam.gd. Spawnt KEINEN Decal direkt am
## Treffer — das macht weiterhin hull_impact.tscn (mit ScorchDecal). Hier nur
## ein leichter Spawn-Boost, damit es sich kausal anfühlt: „Schiff wird gerade
## getroffen" → in den nächsten 1-2 Sek erscheinen die nächsten Damage-Decals
## etwas zeitnaher.
func register_impact(_pos: Vector3, _normal: Vector3) -> void:
	# 30 % schnellerer nächster Spawn (gedeckelt bei 0).
	_spawn_timer = max(_spawn_timer * 0.7, 0.0)


# ─────────────────────────────────────────────────────────────────────────────
# CORE: SPAWN
# ─────────────────────────────────────────────────────────────────────────────

func _spawn_damage_decal() -> void:
	var hit := _get_random_surface_point()
	if hit.is_empty():
		if debug_spawn:
			print("[HIR] Kein Surface-Point gefunden.")
		return

	var pos: Vector3 = hit["position"]
	var normal: Vector3 = hit["normal"]

	# Permanent-Modus: Limit erreicht → nichts mehr spawnen
	if decals_permanent and _active_decals.size() >= max_decals:
		if debug_spawn:
			print("[HIR] Permanent-Modus: Max Decals (%d) erreicht → kein neuer Spawn" % max_decals)
		return

	# FIFO nur im temporären Modus
	if not decals_permanent:
		if _active_decals.size() >= max_decals:
			var oldest: Decal = _active_decals.pop_front()
			if is_instance_valid(oldest):
				oldest.queue_free()

	# ── Zufällige Decal-Szene auswählen ─────────────────────────────────────
	if damage_decal_scenes.is_empty():
		push_warning("[HIR] Keine damage_decal_scenes zugewiesen!")
		return

	var chosen_scene: PackedScene = damage_decal_scenes[randi() % damage_decal_scenes.size()]
	var instance = chosen_scene.instantiate()
	var decal: Decal = instance as Decal

	if not decal:
		push_error("[HIR] Instanziierte Szene ist kein Decal! Pfad: %s" % chosen_scene.resource_path)
		if instance:
			instance.queue_free()
		return

	_decal_parent.add_child(decal)

	# ── Positionierung & Sichtbarkeit ─────────────────────────────────────
	var offset_distance := 0.65
	decal.global_position = pos + normal * offset_distance
	decal.global_basis = _basis_from_normal(normal)

	var size_factor: float = lerp(min_decal_size, max_decal_size, damage_level)
	decal.size = Vector3(size_factor, decal_thickness, size_factor)

	decal.sorting_offset = 2.0
	decal.cull_mask = 1
	decal.distance_fade_enabled = false
	decal.albedo_mix = 1.0
	decal.modulate = Color(1.25, 1.12, 0.95, 1.0)

	# ── VFX spawnen ───────────────────────────────────────────────────────
	_spawn_decal_vfx(decal, damage_level)

	# ── Lifetime Handling ─────────────────────────────────────────────────
	if decal.has_method("initialize"):
		var em: float = lerp(min_emission, max_emission, damage_level) * 1.5
		
		if decals_permanent:
			decal.initialize(damage_level, em, 999999999.0, 0.0)
		else:
			decal.initialize(damage_level, em, decal_lifetime, decal_fade_out_time)

	_active_decals.append(decal)

	if debug_spawn:
		var mode = "PERMANENT" if decals_permanent else "temporary"
		print("[HIR] %s Decal Spawn | Type=%s | size=%.1f" % [mode, chosen_scene.resource_path.get_file(), size_factor])
		
		

func _spawn_decal_vfx(decal: Decal, damage_level: float) -> void:
	if vfx_scenes.is_empty() or not is_instance_valid(decal):
		return

	var spawn_chance: float = lerp(vfx_spawn_chance_base, vfx_spawn_chance_max, damage_level)
	if randf() > spawn_chance:
		return

	var num_effects: int = 1
	if damage_level > 0.65:
		num_effects = randi_range(1, min(vfx_max_per_decal, 2))

	for i in range(num_effects):
		var vfx_scene: PackedScene = vfx_scenes[randi() % vfx_scenes.size()]
		var vfx_instance: Node3D = vfx_scene.instantiate()

		var anchor: Node3D = Node3D.new()
		anchor.name = "VFX_Anchor"
		decal.add_child(anchor)

		anchor.position = Vector3(
			randf_range(-0.4, 0.4),
			randf_range(0.05, 0.7),
			randf_range(-0.4, 0.4)
		)

		var scale_factor: float = lerp(0.8, 1.6, damage_level)
		anchor.scale = Vector3.ONE * scale_factor

		anchor.add_child(vfx_instance)

# ─────────────────────────────────────────────────────────────────────────────
# CORE: RANDOM SURFACE SAMPLING
# ─────────────────────────────────────────────────────────────────────────────
## Bounding-Box-Raycast-Methode aus dem Guide, mit folgenden Robustheits-Fixes:
##   • Mehrere Meshes werden zufällig gewählt (Saucer, Stardrive, …).
##   • Collider-Vergleich erfolgt über Hierarchie-Aufstieg (nicht über
##     `result.collider == mesh_instance` — das ist immer false, weil der
##     Raycast den CollisionShape-Body trifft, nicht das MeshInstance).
##   • Normal-Filter rechnet gegen die LOKALE Y-Achse des Schiffs (global_basis.y),
##     nicht gegen Welt-UP — funktioniert auch bei rollenden/kippenden Schiffen.
func _get_random_surface_point() -> Dictionary:
	if _meshes.is_empty() or not _space_state:
		return {}

	# Diagnose-Sammler: wird nur befüllt beim allerersten Komplett-Fehlschlag,
	# damit wir beim Debugging genau sehen, warum jeder Versuch scheitert.
	var diag: Array = []
	var collect_diag: bool = debug_spawn and not _diag_first_fail_logged

	for attempt in 12:
		var target_mesh: MeshInstance3D = _meshes[randi() % _meshes.size()]
		if not target_mesh or not target_mesh.mesh:
			continue

		var aabb: AABB = target_mesh.mesh.get_aabb()

		# Zufallspunkt im LOKALEN AABB-Volumen
		var random_local := Vector3(
			randf_range(aabb.position.x, aabb.position.x + aabb.size.x),
			randf_range(aabb.position.y, aabb.position.y + aabb.size.y),
			randf_range(aabb.position.z, aabb.position.z + aabb.size.z)
		)

		# Ray entlang LOKALER Y-Achse (von oben nach unten); to_global rechnet
		# Rotation/Skalierung des Schiffs korrekt mit ein.
		var pad: float       = aabb.size.y * 0.8 + 1.0
		var from_local       := random_local + Vector3.UP * pad
		var to_local         := random_local - Vector3.UP * pad
		var from: Vector3    = target_mesh.to_global(from_local)
		var to:   Vector3    = target_mesh.to_global(to_local)

		var params := PhysicsRayQueryParameters3D.create(from, to)
		params.collide_with_areas  = false
		params.collide_with_bodies = true

		var result := _space_state.intersect_ray(params)
		if result.is_empty():
			if collect_diag:
				diag.append("  attempt %d: kein Treffer (Ray %s → %s)" % [attempt, from, to])
			continue

		# Trifft der Ray auch wirklich UNSER Schiff?
		if not _hit_belongs_to_our_ship(result.collider):
			if collect_diag:
				var col_name: String = (result.collider as Node).name if result.collider else "?"
				diag.append("  attempt %d: Treffer auf '%s' — gehört NICHT zum Schiffs-Root '%s'" % [
					attempt, col_name, _ship_root.name if _ship_root else "—"])
			continue

		# Normal-Filter: gegen LOKALE Up-Achse, nicht Welt-UP
		var local_up: Vector3 = target_mesh.global_basis.y.normalized()
		var dot_value: float  = result.normal.dot(local_up)
		if dot_value < surface_normal_threshold:
			if collect_diag:
				var col_name: String = (result.collider as Node).name if result.collider else "?"
				diag.append("  attempt %d: Treffer auf '%s' OK, aber Normal-Filter verworfen (dot=%.2f < %.2f)" % [
					attempt, col_name, dot_value, surface_normal_threshold])
			continue

		return {
			"position": result.position as Vector3,
			"normal":   result.normal as Vector3
		}

	# ── Alle 12 Versuche fehlgeschlagen — einmalige Diagnose ────────────────
	if collect_diag:
		_diag_first_fail_logged = true
		print("[HIR] ⚠️  Surface-Sampling FEHLGESCHLAGEN — Diagnose der 12 Versuche:")
		for d in diag:
			print(d)
		print("  → _ship_root      = %s" % (_ship_root.name if _ship_root else "—"))
		print("  → _decal_parent   = %s" % (_decal_parent.name if _decal_parent else "—"))
		print("  → mesh_instance   = %s" % mesh_instance.name)
		print("  Tipp: Wenn überall 'gehört NICHT zum Schiffs-Root' → ship_controller_path setzen,")
		print("        damit _ship_root korrekt aufgelöst wird.")
		print("        Wenn überall 'Normal-Filter verworfen' → surface_normal_threshold senken.")
		print("        Wenn überall 'kein Treffer' → fehlt eine HullCollision am Schiff?")

	return {}


## Geht den Hierarchie-Baum vom getroffenen Collider nach oben und prüft, ob
## er irgendwo unter unserem Schiffs-Root sitzt. Damit fallen Treffer auf
## andere Schiffe oder Asteroiden raus.
##
## WICHTIG: Wir vergleichen gegen `_ship_root`, NICHT gegen `_decal_parent`.
## decal_parent ist nur der Hänge-Punkt für die Decals (typischerweise unter
## Model/MeshModel) — der HullCollision-Collider liegt aber meistens als
## Geschwister woanders im Schiff-Baum. Mit _ship_root als Anker (= dem
## gemeinsamen Container über beidem, üblicherweise CharacterBody3D /
## AiController) finden wir alle Schiff-Subknoten.
func _hit_belongs_to_our_ship(hit_collider: Object) -> bool:
	if not hit_collider or not _ship_root:
		return false
	var n: Node = hit_collider as Node
	while n:
		if n == _ship_root:
			return true
		n = n.get_parent()
	return false


## Schiffs-Root bestimmen (siehe _ready für Strategie-Beschreibung).
func _resolve_ship_root() -> Node:
	# 1) ShipController.get_parent() — der typische gemeinsame Container
	if _ship_ctrl and _ship_ctrl.get_parent():
		return _ship_ctrl.get_parent()
	# 2) Aufwärts vom mesh_instance suchen bis zum ersten CharacterBody3D
	var n: Node = mesh_instance
	while n:
		if n is CharacterBody3D:
			return n
		n = n.get_parent()
	# 3) Fallback: decal_parent (nicht ideal, aber besser als nichts)
	return _decal_parent


# ─────────────────────────────────────────────────────────────────────────────
# DECAL-ORIENTIERUNG (Gram-Schmidt)
# ─────────────────────────────────────────────────────────────────────────────
## Konstruiert eine Orthonormalbasis, deren lokale +Y-Achse mit der Hit-Normal
## ausgerichtet ist. Das ist die Projektions-Achse von Godot-Decals (sie
## projizieren entlang lokaler -Y nach unten, also lokales +Y „blickt nach außen").
##
## Zusätzlich: zufälliger Yaw-Anteil um die Y-Achse, damit gleichartige Surface-
## Normalen nicht alle exakt gleich rotierte Decals bekommen.
func _basis_from_normal(normal: Vector3) -> Basis:
	var y_axis := normal.normalized()

	# Referenzvektor wählen, der nicht parallel zu y_axis ist
	var x_ref: Vector3 = Vector3.RIGHT
	if abs(y_axis.dot(Vector3.RIGHT)) > 0.9:
		x_ref = Vector3.FORWARD

	var z_axis := y_axis.cross(x_ref).normalized()
	var x_axis := z_axis.cross(y_axis).normalized()

	var b := Basis(x_axis, y_axis, z_axis)
	# Zufalls-Yaw um y_axis (lokale Y), in lokaler Basis multiplizieren
	b = b * Basis(Vector3.UP, randf() * TAU)
	return b


# ─────────────────────────────────────────────────────────────────────────────
# DECAL LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────
## Pulst alle aktiven Decals mit unterschiedlicher Phase (Index-basiert), damit
## sie nicht synchron blinken.
func _pulse_active_decals() -> void:
	if _active_decals.is_empty():
		return
	var pulse_speed: float = lerp(min_pulse_speed, max_pulse_speed, damage_level)
	var t:           float = Time.get_ticks_msec() * 0.001
	# Rückwärts iterieren, damit Listen-Bereinigung mid-loop sicher ist
	for i in range(_active_decals.size() - 1, -1, -1):
		var d: Decal = _active_decals[i]
		if not is_instance_valid(d):
			_active_decals.remove_at(i)
			continue
		# Phasenversatz pro Decal-Index → entkoppelte Pulsation
		var phase: float = float(i) * 0.7
		var pulse: float = (sin((t + phase) * pulse_speed * TAU * 0.5) + 1.0) * 0.5
		if d.has_method("set_pulse"):
			d.set_pulse(pulse)


func _clear_all_decals() -> void:
	for d in _active_decals:
		if is_instance_valid(d):
			d.queue_free()
	_active_decals.clear()
	
	if debug_spawn:
		print("[HIR] Alle Decals entfernt (repair_full / Schiff zerstört)")


# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL: SHIP-CONTROLLER HP-POLLING
# ─────────────────────────────────────────────────────────────────────────────
## Probiert mehrere häufige Property-Namen-Varianten am ShipController durch
## (siehe _HP_PROP_CANDIDATES). Gefundene Namen werden gecacht — die Suche
## läuft nur einmal beim ersten Frame.
##
## Bei `debug_spawn = true` wird beim ersten Frame eine Diagnose ausgegeben:
##   ✓ welches Property-Paar gefunden wurde
##   ✗ wenn keines passt — dann brauchst du einen manuellen apply_damage()-Aufruf
##     ODER musst die Property-Namen in _HP_PROP_CANDIDATES ergänzen.
##
## Außerdem: bei jeder spürbaren damage_level-Änderung (>5 % Sprung) wird ein
## Debug-Print erzeugt — hilft beim Verifizieren, dass HP korrekt einläuft.
func _poll_ship_hp_if_available() -> void:
	if not _ship_ctrl:
		return

	# ── Einmalige Diagnose + Quellen-Suche ──────────────────────────────────
	if not _hp_diag_done:
		_hp_diag_done = true

		# Bevorzugt: get_hull_integrity() -> float  (Volkan-Konvention)
		if _ship_ctrl.has_method("get_hull_integrity"):
			_use_integrity_method = true
			if debug_spawn:
				var initial_integrity: float = float(_ship_ctrl.get_hull_integrity())
				print("[HIR] HP-Polling aktiv via get_hull_integrity()  (Wert: %.2f)" % initial_integrity)
		else:
			# Fallback: Property-Paar aus _HP_PROP_CANDIDATES
			for pair in _HP_PROP_CANDIDATES:
				var p_cur: StringName = pair[0]
				var p_max: StringName = pair[1]
				if (p_cur in _ship_ctrl) and (p_max in _ship_ctrl):
					_hp_prop     = p_cur
					_hp_max_prop = p_max
					if debug_spawn:
						print("[HIR] HP-Polling aktiv via '%s' / '%s' (Wert: %s / %s)" % [
							p_cur, p_max, _ship_ctrl.get(p_cur), _ship_ctrl.get(p_max)])
					break
			if _hp_prop == &"" and debug_spawn:
				# Keine Quelle gefunden – HP-ähnliche Properties auflisten
				var props: Array = []
				for pi in _ship_ctrl.get_property_list():
					var n: String = pi["name"]
					if n.to_lower().contains("hull") or n.to_lower().contains("hp") or n.to_lower().contains("health"):
						props.append("%s (%s)" % [n, _ship_ctrl.get(n)])
				push_warning("[HIR] ⚠️  Auto-Polling FEHLGESCHLAGEN: weder get_hull_integrity() noch bekannte HP-Properties an '%s'." % _ship_ctrl.name)
				print("[HIR] HP-ähnliche Properties am ShipController '%s': %s" % [
					_ship_ctrl.name,
					props if not props.is_empty() else "— keine —"])
				print("[HIR] → Lösung: apply_damage()/set_damage_level() manuell rufen, oder Namen in _HP_PROP_CANDIDATES ergänzen.")

	# ── Wert lesen ──────────────────────────────────────────────────────────
	var new_level: float = damage_level
	if _use_integrity_method:
		var integrity: float = float(_ship_ctrl.get_hull_integrity())
		new_level = clamp(1.0 - integrity, 0.0, 1.0)
	elif _hp_prop != &"":
		var hp_max: float = float(_ship_ctrl.get(_hp_max_prop))
		if hp_max <= 0.0:
			return
		var hp: float = float(_ship_ctrl.get(_hp_prop))
		new_level = clamp(1.0 - hp / hp_max, 0.0, 1.0)
	else:
		return  # keine Quelle aktiv

	# Logging-Drossel: nur bei spürbaren Sprüngen, nicht jeden Frame
	if debug_spawn and abs(new_level - _last_logged_dmg) > 0.05:
		print("[HIR] damage_level → %.2f" % new_level)
		_last_logged_dmg = new_level

	damage_level = new_level
