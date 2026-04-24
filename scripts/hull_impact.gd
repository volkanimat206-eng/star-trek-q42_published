# res://scripts/hull_impact.gd
extends Node3D

# ─────────────────────────────────────────────────────────────
# DEBUG (zentral gesteuert)
# ─────────────────────────────────────────────────────────────
@export var debug_hull_impact: bool = false


# ─────────────────────────────────────────────────────────────
# SIZE
# ─────────────────────────────────────────────────────────────
@export_group("Size")
@export var effect_scale: float = 1.0
@export var spark_scale: float = 1.0
@export var smoke_scale: float = 1.0
@export var scorch_scale: float = 1.0


# ─────────────────────────────────────────────────────────────
# FLASH
# ─────────────────────────────────────────────────────────────
@export_group("Flash")
@export var flash_energy: float = 8.0
@export var flash_range: float = 3.0


# ─────────────────────────────────────────────────────────────
# SPARKS
# ─────────────────────────────────────────────────────────────
@export_group("Sparks")
@export var spark_amount: int = 40
@export var spark_velocity_min: float = 3.0
@export var spark_velocity_max: float = 8.0


# ─────────────────────────────────────────────────────────────
# LIFETIME
# ─────────────────────────────────────────────────────────────
@export_group("Lifetime")
@export var lifetime: float = 3.0


# ─────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────
func _ready():
	# 🔗 DebugManager Registrierung (zentral steuerbar)
	if Engine.has_singleton("DebugManager"):
		DebugManager.register(self, "vfx.hull_impact", "debug_hull_impact")

	_apply_scale()

	if debug_hull_impact:
		print("[HullImpact] Spawned:", name)

	get_tree().create_timer(lifetime).timeout.connect(
		func():
			if is_instance_valid(self):
				if debug_hull_impact:
					print("[HullImpact] Freed:", name)
				queue_free()
	)


# ─────────────────────────────────────────────────────────────
# ATTACH TO SHIP
# ─────────────────────────────────────────────────────────────
## Verankert den Effekt am Schiff sodass er mit ihm mitbewegt wird.
func attach_to(ship_node: Node3D, hit_world_pos: Vector3) -> void:
	var current_parent := get_parent()

	if current_parent and current_parent != ship_node:
		var saved_global := global_transform
		current_parent.remove_child(self)
		ship_node.add_child(self)
		global_transform = saved_global

	elif not current_parent:
		ship_node.add_child(self)

	position = ship_node.to_local(hit_world_pos)

	if debug_hull_impact:
		print("[HullImpact] Attached to:", ship_node.name, "| local_pos:", position)


# ─────────────────────────────────────────────────────────────
# SCALE SETUP
# ─────────────────────────────────────────────────────────────
func _apply_scale():

	# ───────── FLASH ─────────
	var flash := $FlashLight as OmniLight3D
	if flash:
		flash.light_energy = flash_energy
		flash.omni_range   = flash_range * effect_scale

	# ───────── SPARKS ─────────
	var sparks := $Sparks as GPUParticles3D
	if sparks:
		sparks.amount = spark_amount

		var mat := sparks.process_material as ParticleProcessMaterial
		if mat:
			mat.initial_velocity_min = spark_velocity_min * effect_scale
			mat.initial_velocity_max = spark_velocity_max * effect_scale
			mat.scale_min            = 0.05 * effect_scale * spark_scale
			mat.scale_max            = 0.12 * effect_scale * spark_scale

	# ───────── SMOKE ─────────
	var smoke := $ScorchSmoke as GPUParticles3D
	if smoke:
		var mat := smoke.process_material as ParticleProcessMaterial
		if mat:
			mat.initial_velocity_min = 0.3 * effect_scale
			mat.initial_velocity_max = 1.0 * effect_scale
			mat.scale_min            = 0.3  * effect_scale * smoke_scale
			mat.scale_max            = 1.2  * effect_scale * smoke_scale

	# ───────── DECAL (optional / legacy) ─────────
	var decal := $ScorchDecal as Decal
	if decal:
		decal.size = Vector3(0.8, 1.0, 0.8) * effect_scale * scorch_scale

		if debug_hull_impact:
			print("[HullImpact] Decal size set:", decal.size)
