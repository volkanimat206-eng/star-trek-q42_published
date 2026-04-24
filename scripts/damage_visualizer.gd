# res://scripts/damage_visualizer.gd
# Script dem DamageVisualizer Node zuweisen
extends Node3D
class_name DamageVisualizer

@export var hull_mesh: MeshInstance3D
@export var debug_impact_sphere: PackedScene   # kleine Sphere für Debug

var hull_material: ShaderMaterial

var impact_positions := PackedVector3Array()
var impact_ages := PackedFloat32Array()
var impact_count := 0

const MAX_IMPACTS := 16
const IMPACT_FADE := 8.0
const IMPACT_RADIUS := 200.0

# Debug Nodes
var debug_spheres := []

func _ready() -> void:
	hull_mesh = get_node_or_null("HullMesh")  # oder der tatsächliche Pfad zum Mesh    
	if not hull_mesh:
		push_warning("[DamageVisualizer] HullMesh Node nicht gefunden!")
		return

	if hull_mesh.material_override and hull_mesh.material_override is ShaderMaterial:
		hull_material = hull_mesh.material_override as ShaderMaterial
	else:
		push_error("Hull Mesh hat kein ShaderMaterial!")
		return

	impact_positions.resize(MAX_IMPACTS)
	impact_ages.resize(MAX_IMPACTS)
	for i in range(MAX_IMPACTS):
		impact_positions[i] = Vector3.ZERO
		impact_ages[i] = 9999.0

	hull_material.set_shader_parameter("impact_positions", impact_positions)
	hull_material.set_shader_parameter("impact_ages", impact_ages)
	hull_material.set_shader_parameter("impact_count", impact_count)
	hull_material.set_shader_parameter("impact_radius", IMPACT_RADIUS)
	hull_material.set_shader_parameter("impact_fade_duration", IMPACT_FADE)


func register_impact(hit_point: Vector3) -> void:
	if not hull_mesh:
		push_warning("[DamageVisualizer] hull_mesh ist null – Impact kann nicht registriert werden")
		return

	var local_hit = hull_mesh.to_local(hit_point)
	
	# Debug Sphere anzeigen
	if debug_impact_sphere:
		var sphere_instance = debug_impact_sphere.instantiate()
		hull_mesh.add_child(sphere_instance)
		sphere_instance.global_position = hit_point
		debug_spheres.append(sphere_instance)
		sphere_instance.call_deferred("queue_free")

	# Array auf max 16 Impacts schieben (FIFO)
	if impact_count < MAX_IMPACTS:
		impact_positions[impact_count] = local_hit
		impact_ages[impact_count] = 0.0
		impact_count += 1
	else:
		for i in range(1, MAX_IMPACTS):
			impact_positions[i-1] = impact_positions[i]
			impact_ages[i-1] = impact_ages[i]
		impact_positions[MAX_IMPACTS-1] = local_hit
		impact_ages[MAX_IMPACTS-1] = 0.0

	hull_material.set_shader_parameter("impact_positions", impact_positions)
	hull_material.set_shader_parameter("impact_ages", impact_ages)
	hull_material.set_shader_parameter("impact_count", impact_count)


func _process(delta: float) -> void:
	if impact_count == 0:
		return

	var changed := false
	for i in range(impact_count):
		if impact_ages[i] < IMPACT_FADE:
			impact_ages[i] += delta
			changed = true

	if changed:
		hull_material.set_shader_parameter("impact_ages", impact_ages)
