# res://scripts/effects/debris_3d.gd
#
# Trümmerstück mit Physik, Lifetime und sauberem Fade-Out.
# Hängt an der Root von debris_3d.tscn (RigidBody3D).
#
# DESIGN-ENTSCHEIDUNGEN:
#   - gravity_scale = 0  →  Weltraum, keine Schwerkraft
#   - linear_damp/angular_damp  →  Trümmer kommen nicht hart zum Stehen, fadern
#     stattdessen sanft aus (typisches "Drift"-Gefühl)
#   - Collision wird nach kurzer Zeit deaktiviert  →  Performance + verhindert
#     dass viele Trümmer aneinander hängen bleiben oder durch andere Schiffe
#     unkontrolliert getriggert werden
#   - Material wird beim Spawn dupliziert  →  Alpha-Fade eines Stücks ändert
#     nicht alle anderen Debris die dasselbe Material teilen
#   - Faction-Color-Tint im configure()  →  rotglühende Klingonen-Hülle vs.
#     graue Föderations-Trümmer ohne separate Materials pro Fraktion
#
# INTEGRATION MIT ShipExplosion:
#
#   const DEBRIS_SCENE: PackedScene = preload("res://scenes/effects/debris_3d.tscn")
#
#   func _trigger_debris() -> void:
#       Debris3D.spawn_burst(
#           DEBRIS_SCENE,
#           get_tree().current_scene,
#           global_position,
#           20,                  # Anzahl
#           faction_color,       # z.B. Color(1.0, 0.4, 0.3) für Klingonen
#       )
#
# 2.5D-MODUS:
#   Falls du Trümmer auf der Spielebene halten willst (kein Drift in Y/Höhe),
#   restrict_to_xz_plane=true setzen. Standard ist false weil ein Star Trek
#   Space-Combat 3D-Trümmer interessanter aussehen.
class_name Debris3D
extends RigidBody3D

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Lifetime")
## Sekunden bis der Fade-Out beginnt.
@export_range(0.5, 30.0, 0.1) var lifetime: float = 4.0

## Sekunden für den Fade-Out auf alpha=0.
@export_range(0.1, 5.0, 0.05) var fade_time: float = 1.0

@export_group("Collision")
## Sekunden nach Spawn bis Collision abgeschaltet wird.
## 0 = bleibt dauerhaft aktiv. Empfohlen: 0.5–1.5s
@export_range(0.0, 5.0, 0.1) var collision_disable_after: float = 1.0

@export_group("Plane Lock")
## Wenn true: Bewegung wird auf die XZ-Ebene beschränkt (Y eingefroren).
## Für freie 3D-Bewegung (Star-Trek-typisch) false lassen.
@export var restrict_to_xz_plane: bool = false

@export_group("Mesh Variation")
## Wenn gesetzt: beim Spawn wird ein zufälliges Mesh aus dieser Liste gewählt.
## Leer lassen, um das Default-Mesh aus der Szene zu nutzen.
@export var mesh_variants: Array[Mesh] = []

@export_group("Visual")
## Glühende Trümmer direkt nach Explosion?
## emission_energy_multiplier fadet automatisch über lifetime aus.
@export var glowing_initial: bool = false

# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────

var _time_alive: float = 0.0
var _fading: bool = false
var _collision_disabled: bool = false
var _mesh_instance: MeshInstance3D = null
var _collision_shape: CollisionShape3D = null
var _color_tint: Color = Color.WHITE


# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	gravity_scale = 0.0

	_mesh_instance = _find_child_of_type(self, "MeshInstance3D") as MeshInstance3D
	_collision_shape = _find_child_of_type(self, "CollisionShape3D") as CollisionShape3D

	if restrict_to_xz_plane:
		# Y-Achse fixieren (vertikale Drift unterdrücken)
		axis_lock_linear_y = true
		# Rotation nur um Y zulassen (kein Tumbling aus der Ebene)
		axis_lock_angular_x = true
		axis_lock_angular_z = true

	# Mesh-Variation
	if mesh_variants.size() > 0 and _mesh_instance:
		_mesh_instance.mesh = mesh_variants.pick_random()

	_prepare_material()


func _physics_process(delta: float) -> void:
	if _fading:
		return
	_time_alive += delta

	# Collision rechtzeitig deaktivieren
	if collision_disable_after > 0.0 \
	and not _collision_disabled \
	and _time_alive >= collision_disable_after:
		_disable_collision()

	# Lifetime erreicht → Fade-Out
	if _time_alive >= lifetime:
		_start_fade_out()


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API — Setup beim Spawn
# ─────────────────────────────────────────────────────────────────────────────

## Wird vom Spawner direkt nach instantiate() aufgerufen.
## Setzt Faction-Tint und zufällige Skalierung.
##
## WICHTIG: configure() muss aufgerufen werden BEVOR der Node der Scene
## hinzugefügt wird, oder _prepare_material() im _ready() läuft mit dem
## Default-Tint (Weiß). Der Spawner setzt configure() vor add_child() —
## siehe spawn_burst() unten.
func configure(color_tint: Color = Color.WHITE, scale_factor: float = 1.0) -> void:
	_color_tint = color_tint
	if scale_factor != 1.0:
		scale = Vector3.ONE * scale_factor


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────

func _find_child_of_type(node: Node, type_name: String) -> Node:
	for child in node.get_children():
		if child.is_class(type_name):
			return child
	return null


func _prepare_material() -> void:
	if not _mesh_instance:
		return

	var mat: StandardMaterial3D = null

	# Eigenes Material erzeugen — sonst wirkt der Alpha-Fade auf alle Debris
	# die sich dieses Material teilen (Z.B. weil sie aus derselben Scene kommen).
	if _mesh_instance.material_override is StandardMaterial3D:
		mat = (_mesh_instance.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
	elif _mesh_instance.mesh \
	and _mesh_instance.mesh.get_surface_count() > 0 \
	and _mesh_instance.mesh.surface_get_material(0) is StandardMaterial3D:
		mat = (_mesh_instance.mesh.surface_get_material(0) as StandardMaterial3D).duplicate() as StandardMaterial3D

	# Fallback falls keins der beiden zugewiesen war
	if not mat:
		mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.45, 0.45, 0.5)
		mat.metallic = 0.7
		mat.roughness = 0.5

	# Transparency vorbereiten — Alpha-Fade braucht das.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Faction-Color-Tint multiplikativ anwenden
	if _color_tint != Color.WHITE:
		var base: Color = mat.albedo_color
		mat.albedo_color = Color(
			base.r * _color_tint.r,
			base.g * _color_tint.g,
			base.b * _color_tint.b,
			base.a
		)

	# Glühende Trümmer (heißes Metall direkt nach Explosion)
	if glowing_initial:
		mat.emission_enabled = true
		mat.emission = mat.albedo_color * 2.0
		mat.emission_energy_multiplier = 1.5
		# Glow fadet automatisch über 70% der lifetime aus
		var glow_tween: Tween = create_tween()
		glow_tween.tween_property(mat, "emission_energy_multiplier", 0.0, lifetime * 0.7)

	_mesh_instance.material_override = mat


func _start_fade_out() -> void:
	if _fading:
		return
	_fading = true

	var tween: Tween = create_tween()

	if _mesh_instance and _mesh_instance.material_override is StandardMaterial3D:
		var mat: StandardMaterial3D = _mesh_instance.material_override
		tween.tween_property(mat, "albedo_color:a", 0.0, fade_time)
	else:
		# Kein fade-fähiges Material → einfach warten bis lifetime+fade_time vorbei
		tween.tween_interval(fade_time)

	tween.tween_callback(queue_free)


func _disable_collision() -> void:
	_collision_disabled = true
	if _collision_shape:
		_collision_shape.disabled = true
	# Layers/Mask auf 0 → Physics-Engine ignoriert das Stück komplett
	collision_layer = 0
	collision_mask = 0


# ─────────────────────────────────────────────────────────────────────────────
# STATIC HELPER — Burst-Spawn aus jedem Spawner-Code aufrufbar
# ─────────────────────────────────────────────────────────────────────────────

## Spawnt einen Trümmer-Burst an einer Weltposition.
##
## Parameter:
##   scene:        PackedScene (debris_3d.tscn)
##   world:        Parent-Node — meist get_tree().current_scene
##   origin:       Weltposition des Bursts (typischerweise Schiffsmitte)
##   count:        Anzahl Trümmer
##   color_tint:   Faction-Farbe — Color.WHITE = neutral grau
##   min_force/max_force:    Anfangsgeschwindigkeit Streuung
##   min_torque/max_torque:  Drehimpuls Streuung
##
## Aufrufbeispiel aus ShipExplosion:
##   Debris3D.spawn_burst(DEBRIS_SCENE, get_tree().current_scene,
##       global_position, 20, faction_color)
static func spawn_burst(
	scene: PackedScene,
	world: Node,
	origin: Vector3,
	count: int = 15,
	color_tint: Color = Color.WHITE,
	min_force: float = 2.0,
	max_force: float = 10.0,
	min_torque: float = 1.0,
	max_torque: float = 5.0
) -> void:
	if not scene:
		push_warning("[Debris3D] spawn_burst: scene ist null!")
		return
	if not world:
		push_warning("[Debris3D] spawn_burst: world ist null!")
		return

	for i in range(count):
		var instance: Node = scene.instantiate()
		if not (instance is Debris3D):
			push_warning("[Debris3D] spawn_burst: Scene-Root ist kein Debris3D!")
			instance.queue_free()
			return

		var d: Debris3D = instance as Debris3D

		# Konfigurieren BEVOR add_child() — sonst läuft _ready() mit
		# Default-Werten und der Tint kommt zu spät an.
		d.configure(color_tint, randf_range(0.6, 1.3))
		world.add_child(d)
		d.global_transform.origin = origin

		# Zufällige Richtung in vollem 3D (oder XZ-Ebene wenn gelockt)
		var dir: Vector3 = Vector3(
			randf_range(-1.0, 1.0),
			0.0 if d.restrict_to_xz_plane else randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)
		)
		if dir.length_squared() < 0.001:
			dir = Vector3.RIGHT
		dir = dir.normalized()

		var force: float = randf_range(min_force, max_force)
		d.apply_impulse(dir * force)

		# Random Drehimpuls (immer voll 3D — sieht beim Tumbling besser aus)
		var torque_dir: Vector3 = Vector3(
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0),
			randf_range(-1.0, 1.0)
		)
		if torque_dir.length_squared() < 0.001:
			torque_dir = Vector3.UP
		var torque: Vector3 = torque_dir.normalized() * randf_range(min_torque, max_torque)
		d.apply_torque_impulse(torque)
