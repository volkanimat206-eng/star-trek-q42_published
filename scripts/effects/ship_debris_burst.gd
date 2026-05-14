# res://scripts/effects/ship_debris_burst.gd
#
# Spawnt Fragment-Meshes aus einer Debris-Szene mit korrekter Schiffs-Rotation.
#
# KERNPRINZIP:
#   Jedes Fragment bekommt:
#     fragment_global_transform = ship_transform * fragment_local_transform
#
#   Damit übernehmen alle Fragmente automatisch Position UND Rotation des
#   Schiffs zum Zeitpunkt der Explosion. Kein separater "origin"-Parameter,
#   kein manuelles global_position-Setzen (das würde die Rotation zerstören).
#
# DEBRIS-SZENE AUFBAU (z.B. galaxy_debris.tscn):
#   Node3D  (Root, Transform = Identity)
#   ├── MeshInstance3D  "Hull_Front"   (lokal um den Ursprung platziert)
#   ├── MeshInstance3D  "Hull_Mid"
#   └── MeshInstance3D  "Hull_Rear"
#
#   Die Meshes liegen relativ zum Szenen-Ursprung. Rotation ist "gebaked"
#   (alle lokalen Rotationen = 0,0,0 nach dem Bake-Schritt).
#
# VERWENDUNG (aus effect_explosion_ship.gd):
#   ShipDebrisBurst.launch_at(
#       debris_data.fragment_scene,
#       get_tree().current_scene,
#       ship_transform,          # ← komplette Transform3D des Schiffs
#       color_tint,
#       debris_data.debris_params
#   )
# ─────────────────────────────────────────────────────────────────────────────

class_name ShipDebrisBurst
extends RefCounted


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Haupteinstiegspunkt. Lädt die Fragment-Szene, iteriert über alle
## MeshInstance3D-Kinder und spawnt sie einzeln in der Weltszene.
##
## fragment_scene  – PackedScene mit MeshInstance3D-Kindern (galaxy_debris.tscn)
## world           – Elternknoten in dem die Fragmente landen (current_scene)
## ship_transform  – Globale Transform3D des Schiffs zum Explosionszeitpunkt
## color_tint      – Multiplikativer Farbton auf das Fragment-Material
## params          – ShipDebrisParams-Resource (Kraft, Torque, Lifetime, …)
static func launch_at(
		fragment_scene:  PackedScene,
		world:           Node,
		ship_transform:  Transform3D,
		color_tint:      Color            = Color.WHITE,
		params:          ShipDebrisParams = null
) -> void:

	if not fragment_scene or not is_instance_valid(world):
		push_warning("[ShipDebrisBurst] fragment_scene oder world ungültig – Abbruch.")
		return

	# Standardwerte wenn keine Params-Resource übergeben wurde
	var p := params if params else ShipDebrisParams.new()

	# Szene einmalig instanziieren um die Kinder-Struktur zu lesen
	var template: Node3D = fragment_scene.instantiate() as Node3D
	if not template:
		push_warning("[ShipDebrisBurst] fragment_scene ist kein Node3D!")
		return

	# Alle MeshInstance3D-Kinder einsammeln
	# (depth=false → nur direkte Kinder; bei verschachtelten Szenen auf true setzen)
	var meshes: Array[Node] = template.find_children("*", "MeshInstance3D", true, false)

	if meshes.is_empty():
		push_warning("[ShipDebrisBurst] Keine MeshInstance3D in fragment_scene gefunden!")
		template.queue_free()
		return

	for mesh_node: Node in meshes:
		var mesh := mesh_node as MeshInstance3D
		if not mesh:
			continue

		# ── TRANSFORM-BERECHNUNG ──────────────────────────────────────────────
		# fragment_local_transform: Position/Rotation des Meshes relativ zum
		# Szenen-Root (= wie das Fragment "im Schiff" liegt).
		var fragment_local: Transform3D = mesh.global_transform

		# Wenn das Template noch nicht im Szenentree ist, liefert global_transform
		# nur die lokale Transform. Das ist korrekt: relative Lage zum Szenen-Root.
		# ship_transform überführt diesen lokalen Raum in den Weltraum:
		#   welt = schiff * lokal
		var world_transform: Transform3D = ship_transform * fragment_local

		# ── FRAGMENT SPAWNEN ─────────────────────────────────────────────────
		_spawn_fragment(mesh, world, world_transform, color_tint, p)

	# Template verwerfen – wir haben alle Daten extrahiert
	template.queue_free()


# ─────────────────────────────────────────────────────────────────────────────
# PRIVAT
# ─────────────────────────────────────────────────────────────────────────────

## Erstellt einen einzelnen Debris-RigidBody3D und fügt ihn der Welt hinzu.
static func _spawn_fragment(
		source_mesh:     MeshInstance3D,
		world:           Node,
		world_transform: Transform3D,
		color_tint:      Color,
		p:               ShipDebrisParams
) -> void:

	# ── RigidBody3D als Container ────────────────────────────────────────────
	var body := RigidBody3D.new()
	body.gravity_scale = 0.0   # Weltraum: schwerelos
	body.linear_damp   = 0.05
	body.angular_damp  = 0.05

	# ── Mesh klonen ──────────────────────────────────────────────────────────
	var frag := source_mesh.duplicate() as MeshInstance3D
	frag.visible = true

	# Farbton anwenden (multiplikativ) — nur wenn kein reines Weiß
	if color_tint != Color.WHITE:
		_apply_color_tint(frag, color_tint)

	body.add_child(frag)

	# Optionale Kollision: wenn collision_disable_after > 0, kurzzeitig aktiv
	# (ConvexHull aus Mesh-Geometrie — etwas teurer beim Spawn)
	if p.collision_disable_after > 0.0 and source_mesh.mesh:
		var col := source_mesh.mesh.create_convex_shape(true, true)
		if col:
			var coll := CollisionShape3D.new()
			coll.shape = col
			body.add_child(coll)

	world.add_child(body)

	# ── TRANSFORM ANWENDEN ───────────────────────────────────────────────────
	# WICHTIG: global_transform NACH add_child() setzen, damit der Node
	# im Szenentree ist und global_transform korrekt funktioniert.
	# NIEMALS global_position separat setzen – das überschreibt die Rotation!
	body.global_transform = world_transform

	# ── IMPULS ───────────────────────────────────────────────────────────────
	# Richtung: vom Schiffsursprung (gesetzt via params.set_ship_origin()) zum Fragment.
	# Fallback: zufällige Richtung wenn kein Ursprung bekannt.
	var impulse_dir: Vector3
	if p._ship_origin_set:
		var to_fragment: Vector3 = world_transform.origin - p.ship_origin_ws
		impulse_dir = to_fragment.normalized() if to_fragment.length_squared() > 0.0001 else _random_dir()
	else:
		# Kein Schiffsursprung bekannt → zufällige Richtung mit leichtem
		# Aufwärts-Bias (simuliert Explosionsdruck)
		impulse_dir = _random_dir()

	var force: float  = randf_range(p.explosion_force_min, p.explosion_force_max)
	var torque: float = randf_range(p.torque_min, p.torque_max)

	# Seitlicher Drift überlagert den radialen Vektor (simuliert ungleichmäßige Explosion)
	var drift: Vector3 = _random_dir() * p.random_drift_strength
	body.apply_central_impulse(impulse_dir * force + drift)
	body.apply_torque_impulse(_random_dir() * torque)

	# ── LIFETIME / FADE ──────────────────────────────────────────────────────
	var total_lifetime: float = p.fade_out_start + p.fade_out_duration
	if total_lifetime > 0.0:
		_schedule_cleanup(body, frag, total_lifetime, p.fade_out_duration)
	
	# Kollision nach collision_disable_after Sekunden deaktivieren
	if p.collision_disable_after > 0.0:
		_schedule_collision_disable(body, p.collision_disable_after)


## Zufällige Einheitsrichtung (gleichmäßig über Kugeloberfläche verteilt).
static func _random_dir() -> Vector3:
	return Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	).normalized()


## Farbton auf alle Materials des Meshes anwenden (duplicate() um shared
## Resources nicht zu verändern).
static func _apply_color_tint(mesh: MeshInstance3D, tint: Color) -> void:
	for i in range(mesh.get_surface_override_material_count()):
		var mat: Material = mesh.get_active_material(i)
		if not mat:
			continue
		var dup: Material = mat.duplicate()
		mesh.set_surface_override_material(i, dup)
		if dup is StandardMaterial3D:
			(dup as StandardMaterial3D).albedo_color *= tint
		elif dup is ORMMaterial3D:
			(dup as ORMMaterial3D).albedo_color *= tint


## Plant automatisches Entfernen und optionales Fade-out des Fragments.
static func _schedule_cleanup(body: RigidBody3D, mesh: MeshInstance3D,
		lifetime: float, fade_duration: float) -> void:
	var cleaner := _DebrisCleaner.new()
	cleaner.target_body   = body
	cleaner.target_mesh   = mesh
	cleaner.lifetime      = lifetime
	cleaner.fade_duration = fade_duration
	body.add_child(cleaner)


## Deaktiviert die Kollision des Bodys nach `delay` Sekunden (via _DebrisCleaner-Mechanismus).
static func _schedule_collision_disable(body: RigidBody3D, delay: float) -> void:
	var timer := _CollisionDisabler.new()
	timer.target_body = body
	timer.delay       = delay
	body.add_child(timer)


# ─────────────────────────────────────────────────────────────────────────────
# INNER CLASS: Lifetime-Manager
# ─────────────────────────────────────────────────────────────────────────────

## Leichtgewichtiger Node der sich selbst und den Parent-Body nach `lifetime`
## Sekunden entfernt. Optional mit Fade-out.
class _DebrisCleaner extends Node:
	var target_body:   RigidBody3D
	var target_mesh:   MeshInstance3D
	var lifetime:      float = 5.0
	var fade_duration: float = 1.0
	var _elapsed:      float = 0.0
	var _fading:       bool  = false
	var _fade_elapsed: float = 0.0
	var _start_alpha:  float = 1.0

	func _process(delta: float) -> void:
		_elapsed += delta

		var fade_start: float = max(0.0, lifetime - fade_duration)

		# Fade-Phase starten
		if not _fading and fade_duration > 0.0 and _elapsed >= fade_start:
			_fading = true
			_fade_elapsed = _elapsed - fade_start
			_cache_start_alpha()

		# Fade durchführen
		if _fading and is_instance_valid(target_mesh):
			_fade_elapsed += delta
			var t: float = clampf(_fade_elapsed / max(fade_duration, 0.001), 0.0, 1.0)
			_set_mesh_alpha(_start_alpha * (1.0 - t))

		# Aufräumen
		if _elapsed >= lifetime:
			if is_instance_valid(target_body):
				target_body.queue_free()
			queue_free()

	func _cache_start_alpha() -> void:
		if not is_instance_valid(target_mesh):
			return
		var mat: Material = target_mesh.get_active_material(0)
		if mat is StandardMaterial3D:
			_start_alpha = (mat as StandardMaterial3D).albedo_color.a
		elif mat is ORMMaterial3D:
			_start_alpha = (mat as ORMMaterial3D).albedo_color.a

	func _set_mesh_alpha(alpha: float) -> void:
		if not is_instance_valid(target_mesh):
			return
		for i in range(target_mesh.get_surface_override_material_count()):
			var mat: Material = target_mesh.get_active_material(i)
			if mat is StandardMaterial3D:
				var sm := mat as StandardMaterial3D
				sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				var c := sm.albedo_color
				c.a = alpha
				sm.albedo_color = c
			elif mat is ORMMaterial3D:
				var om := mat as ORMMaterial3D
				om.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				var c := om.albedo_color
				c.a = alpha
				om.albedo_color = c


# ─────────────────────────────────────────────────────────────────────────────
# INNER CLASS: Kollisions-Deaktivierung
# ─────────────────────────────────────────────────────────────────────────────

## Deaktiviert nach `delay` Sekunden die Kollision des Debris-Bodys.
## Verhindert dass lang fliegende Trümmer andere Schiffe oder Projektile
## beeinflussen.
class _CollisionDisabler extends Node:
	var target_body: RigidBody3D
	var delay:       float = 1.0
	var _elapsed:    float = 0.0

	func _process(delta: float) -> void:
		_elapsed += delta
		if _elapsed >= delay:
			if is_instance_valid(target_body):
				target_body.collision_layer = 0
				target_body.collision_mask  = 0
			queue_free()
