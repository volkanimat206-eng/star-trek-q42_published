# res://scripts/effects/effect_explosion_torpedo.gd
extends Node3D
class_name TorpedoExplosionEffect

@export var auto_destroy_time: float = 3.0
@export_range(0.0, 1.0) var size_range: float = 0.2

# Wir entfernen den statischen Export und machen es zu einer internen Variable,
# die sich beim Start (oder bei Bedarf) aus dem DebugManager füttert.
var debug_mode: bool = false

func _ready() -> void:
	# Synchronisation mit deinem globalen DebugManager
	debug_mode = DebugManager.get_flag("vfx.torpedo_explosion")
	
	if debug_mode:
		print("[TorpedoExplosion] _ready() | warte auf initialize()")
		
	get_tree().create_timer(auto_destroy_time).timeout.connect(
		func(): if is_instance_valid(self): queue_free()
	)

func initialize(explosion_size: float) -> void:
	# Erneuter Check, falls das Flag geändert wurde während der Torpedo noch fliegt/explodiert
	debug_mode = DebugManager.get_flag("vfx.torpedo_explosion")
	
	var variation: float = randf_range(1.0 - size_range, 1.0 + size_range)
	var factor: float    = maxf(explosion_size * variation, 0.1)
	
	if debug_mode:
		print("[TorpedoExplosion] initialize(%.2f) | variation=%.2f | factor=%.2f" % [
			explosion_size, variation, factor])
			
	_scale_particles(factor)
	_scale_lights(factor)
	_start_all_particles()
	
func _scale_particles(factor: float) -> void:
	for child in find_children("*", "GPUParticles3D", true, false):
		var gp := child as GPUParticles3D
		if not gp:
			continue
		if not gp.process_material is ParticleProcessMaterial:
			if debug_mode:
				print("[TorpedoExplosion]   '%s' hat kein ParticleProcessMaterial" % gp.name)
			continue

		# Material duplizieren – keine shared-Resource-Konflikte
		var mat := (gp.process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
		gp.process_material = mat

		mat.initial_velocity_min   *= factor
		mat.initial_velocity_max   *= factor
		mat.radial_accel_min       *= factor
		mat.radial_accel_max       *= factor
		mat.emission_sphere_radius *= factor
		mat.emission_box_extents   *= factor
		mat.scale_min              *= factor
		mat.scale_max              *= factor
		gp.lifetime                *= clampf(factor, 1.0, 2.5)

		if debug_mode:
			print("[TorpedoExplosion]   '%s' skaliert | vel=%.1f-%.1f | scale=%.2f-%.2f" % [
				gp.name,
				mat.initial_velocity_min,
				mat.initial_velocity_max,
				mat.scale_min,
				mat.scale_max
			])


func _scale_lights(factor: float) -> void:
	for child in find_children("*", "OmniLight3D", true, false):
		var light := child as OmniLight3D
		if light:
			light.omni_range *= factor
			if debug_mode:
				print("[TorpedoExplosion]   OmniLight '%s' range=%.1f" % [light.name, light.omni_range])


func _start_all_particles() -> void:
	for child in find_children("*", "GPUParticles3D", true, false):
		var gp := child as GPUParticles3D
		if not gp:
			continue
		gp.emitting = true
		if gp.one_shot:
			gp.restart()

	for child in find_children("*", "AnimationPlayer", true, false):
		var ap := child as AnimationPlayer
		if not ap:
			continue
		var anims := ap.get_animation_list()
		var anim_to_play: String = ""
		if "play" in anims:
			anim_to_play = "play"
		else:
			for a in anims:
				if a != "RESET":
					anim_to_play = a
					break
		if anim_to_play != "":
			ap.play(anim_to_play)
			if debug_mode:
				print("[TorpedoExplosion]   AnimationPlayer '%s' → play('%s')" % [ap.name, anim_to_play])
		break
