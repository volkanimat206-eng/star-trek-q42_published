# res://scripts/effects/explosion_effect.gd
extends Node3D
class_name ExplosionEffect

## Basisgröße für die die Explosion designed wurde (in Godot-Units).
## Passe diesen Wert an deine aktuelle Explosionsgröße an.
const BASE_SIZE: float = 1.0

## Zufällige Größenvariation: Faktor wird innerhalb ±size_range variiert.
## 0.0 = keine Variation, 0.3 = ±30% Zufallsbereich
@export_range(0.0, 1.0) var size_range: float = 0.2

## Name des Shockwave-GPUParticles3D-Nodes in der Scene.
@export var shockwave_node_name: String = "Shockwave"

## Name des Windup-GPUParticles3D-Nodes in der Scene.
@export var windup_node_name: String = "Windup2"

# Interne Referenzen
var _shockwave: GPUParticles3D = null
var _factor:    float          = 1.0


func initialize(ship_size: float, shockwave_delay: float = 0.0) -> void:
	var variation: float = randf_range(1.0 - size_range, 1.0 + size_range)
	_factor = clampf((ship_size / BASE_SIZE) * variation, 0.5, 20.0)
	scale   = Vector3.ONE * _factor

	# Shockwave-Node vor dem Skalieren herausnehmen – er bekommt
	# seinen eigenen Skalierungs- und Timing-Pfad.
	_shockwave = _extract_shockwave()

	_scale_particles(_factor)

	# Shockwave nach Delay starten (0.0 = sofort)
	_start_shockwave_delayed(shockwave_delay)


## Trennt den Shockwave-Node aus dem allgemeinen Skalierungsloop heraus
## und gibt ihn zurück (oder null wenn nicht gefunden).
func _extract_shockwave() -> GPUParticles3D:
	var node := find_child(shockwave_node_name, true, false)
	if node is GPUParticles3D:
		return node as GPUParticles3D
	push_warning("[ExplosionEffect] Kein '%s'-Node gefunden!" % shockwave_node_name)
	return null


## Startet den Shockwave nach shockwave_delay Sekunden.
## Läuft parallel zur restlichen Explosion (kein await in initialize).
func _start_shockwave_delayed(delay: float) -> void:
	if _shockwave == null:
		return

	# Shockwave startet disabled – er wird zum richtigen Zeitpunkt gezündet.
	_shockwave.emitting = false

	if delay > 0.0:
		await get_tree().create_timer(delay).timeout

	if not is_instance_valid(_shockwave):
		return

	# Skalierung des Shockwave-Materials auf Schiffsgröße anpassen
	_scale_shockwave_material(_shockwave, _factor)

	_shockwave.emitting = true


## Skaliert das ParticleProcessMaterial des Shockwave-Nodes gezielt.
## Der Ring-Radius skaliert mit dem Schiff, Velocity und Accel bleiben stark.
func _scale_shockwave_material(gp: GPUParticles3D, factor: float) -> void:
	if not gp.process_material is ParticleProcessMaterial:
		return

	var mat := (gp.process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
	gp.process_material = mat

	# Ring-Emitter skalieren damit er zur Schiffsgröße passt
	mat.emission_ring_radius       *= factor
	mat.emission_ring_inner_radius *= factor
	mat.emission_ring_height       *= factor

	# Radiale Beschleunigung skaliert mit der Größe → große Schiffe = breitere Welle
	mat.radial_accel_min *= factor
	mat.radial_accel_max *= factor

	# Partikelgröße skaliert leicht mit
	mat.scale_min *= clampf(factor, 0.5, 2.0)
	mat.scale_max *= clampf(factor, 0.5, 2.0)


func _scale_particles(factor: float) -> void:
	for node in find_children("*", "GPUParticles3D", true, false):
		var gp := node as GPUParticles3D

		# Shockwave wird separat über _scale_shockwave_material() behandelt
		if gp == _shockwave:
			continue

		if not gp.process_material is ParticleProcessMaterial:
			continue

		# FIX: Material duplizieren damit jede Instanz ihre eigene Kopie hat
		var mat := (gp.process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
		gp.process_material = mat

		mat.initial_velocity_min     *= factor
		mat.initial_velocity_max     *= factor
		mat.radial_accel_min         *= factor
		mat.radial_accel_max         *= factor
		mat.emission_box_extents     *= factor
		mat.emission_sphere_radius   *= factor
		mat.scale_min                *= factor
		mat.scale_max                *= factor
		gp.lifetime                  *= clampf(factor, 1.0, 2.5)
