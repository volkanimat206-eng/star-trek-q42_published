# ParallaxStarfield.gd
extends GPUParticles3D

@export_group("Layer Settings")
@export var layer_depth: float = 1.0
@export var particle_count: int = 2000
@export var update_interval: float = 0.1

@export_group("Visual Settings")
@export var star_size_min: float = 0.05
@export var star_size_max: float = 0.15
@export var star_color: Color = Color(0.9, 0.95, 1.0)
@export var alpha: float = 0.8

@export_group("Dynamic Zoom Relation")
@export var start_height: float = 400.0
@export var zoom_scale_factor: float = 0.5
@export var base_box_size: float = 2000.0

@export_group("Parallax Tuning")
@export var parallax_offset_y: float = -50.0

var player: Node3D
var camera: Camera3D
var particle_material: ParticleProcessMaterial
var update_timer: float = 0.0
var current_box_size: float = base_box_size
var last_player_pos: Vector3
var is_teleporting: bool = false

func _ready():
	player = get_parent()
	camera = get_viewport().get_camera_3d()
	last_player_pos = player.global_position
	
	setup_particle_system()
	create_star_material()
	create_star_mesh()
	
	# Wichtige Einstellungen für unendliches Starfield
	extra_cull_margin = 10000.0
	emitting = true
	
	# Initiale Box-Größe setzen
	update_box_size(base_box_size)
	
	# Partikel einmalig generieren
	restart_particles()

func setup_particle_system():
	local_coords = false  # Sterne in Weltkoordinaten
	amount = particle_count
	
	# Längere Lebensdauer für unendliches Gefühl
	lifetime = 120.0
	
	# Preprocess für initiale Verteilung
	preprocess = 60.0
	
	draw_order = DRAW_ORDER_VIEW_DEPTH

func create_star_material():
	particle_material = ParticleProcessMaterial.new()
	particle_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	particle_material.emission_box_extents = Vector3(base_box_size, 1.0, base_box_size)
	
	particle_material.gravity = Vector3.ZERO
	particle_material.initial_velocity_min = 0.0
	particle_material.initial_velocity_max = 0.0
	
	# Partikel-Größen initial setzen
	var initial_scale = star_size_min * (1.0 / layer_depth)
	particle_material.scale_min = initial_scale
	particle_material.scale_max = initial_scale * 2.0
	
	process_material = particle_material

func create_star_mesh():
	var star_mesh = QuadMesh.new()
	star_mesh.size = Vector2(1.0, 1.0)
	var shader_material = ShaderMaterial.new()
	shader_material.shader = create_star_shader()
	shader_material.set_shader_parameter("star_color", Color(star_color.r, star_color.g, star_color.b, alpha))
	star_mesh.material = shader_material
	draw_pass_1 = star_mesh

func create_star_shader() -> Shader:
	var shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_add, depth_draw_never, unshaded, cull_disabled;

uniform vec4 star_color : source_color;

void vertex() {
	// Billboard mit Größenanpassung basierend auf Entfernung
	mat4 world_matrix = mat4(
		normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]),
		normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]
	);
	
	// Skalierung der Billboard-Größe
	float scale_factor = 1.0;
	world_matrix = world_matrix * mat4(
		vec4(length(MODEL_MATRIX[0].xyz) * scale_factor, 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz) * scale_factor, 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0)
	);
	
	MODELVIEW_MATRIX = VIEW_MATRIX * world_matrix;
}

void fragment() {
	// Runde Sterne mit weichem Rand
	vec2 uv_centered = UV * 2.0 - 1.0;
	float dist = length(uv_centered);
	float mask = 1.0 - smoothstep(0.0, 1.0, dist);
	
	// Optional: Leichtes Twinkling
	float twinkle = 0.8 + 0.4 * sin(TIME * 3.0 + FRAGCOORD.x * 2.0);
	
	ALBEDO = star_color.rgb;
	ALPHA = mask * star_color.a * twinkle;
}
"""
	return shader

func _process(delta):
	update_timer += delta
	if update_timer >= update_interval:
		update_timer = 0.0
		update_parallax_position()
		update_visuals()

func update_parallax_position():
	if not player:
		return
	
	# Parallax-Effekt: Emitter folgt mit reduzierter Geschwindigkeit
	var parallax_factor = 1.0 / layer_depth
	
	# Berechne Zielposition basierend auf Spielerbewegung
	var target_x = player.global_position.x * parallax_factor
	var target_z = player.global_position.z * parallax_factor
	var target_y = parallax_offset_y * layer_depth
	
	var target_pos = Vector3(target_x, target_y, target_z)
	
	# Sanftes Folgen für flüssigen Parallax
	global_position = global_position.lerp(target_pos, 0.1)
	
	# Teleportiere Partikel, wenn Spieler zu weit vom Emitter entfernt ist
	var player_offset = player.global_position - global_position
	if not is_teleporting and (abs(player_offset.x) > current_box_size * 0.8 or abs(player_offset.z) > current_box_size * 0.8):
		teleport_particles()

func teleport_particles():
	if is_teleporting:
		return
	
	is_teleporting = true
	
	# Methode 1: Partikelpositionen direkt verschieben (effizienter)
	var particles_data = _get_particle_positions()
	if particles_data.size() > 0:
		# Verschiebe alle existierenden Partikel relativ zum Emitter
		var offset = player.global_position - global_position
		for i in range(particles_data.size()):
			particles_data[i] -= offset
	
	# Methode 2: System kurz zurücksetzen (Fallback)
	emitting = false
	# Kurze Pause für Godot's Partikelsystem
	await get_tree().process_frame
	emitting = true
	
	is_teleporting = false

func _get_particle_positions() -> Array:
	# Versuche, Partikelpositionen zu lesen (funktioniert nur wenn sichtbar)
	var positions = []
	# Hinweis: In Godot 4.x gibt es keine direkte API für Partikelpositionen
	# Daher verwenden wir nur Methode 2
	return positions

func update_visuals():
	if not camera:
		return
	
	var cam_height = abs(camera.global_position.y)
	
	# Dynamische Box-Größe basierend auf Kamerahöhe
	var target_box_size = max(base_box_size, cam_height * 2.5)
	target_box_size = min(target_box_size, base_box_size * 3.0)  # Begrenzung für Performance
	
	if abs(target_box_size - current_box_size) > 10.0:
		current_box_size = target_box_size
		update_box_size(current_box_size)
	
	# Zoom-Kompensation für Partikelgrößen
	var zoom_ratio = cam_height / start_height
	var growth_multiplier = 1.0 + (max(0.0, zoom_ratio - 1.0) * zoom_scale_factor)
	
	# Basisgröße mit Parallax-Faktor und Zoom kombinieren
	var parallax_size_factor = 1.0 / max(0.1, layer_depth)
	var final_size_min = star_size_min * parallax_size_factor * growth_multiplier
	var final_size_max = star_size_max * parallax_size_factor * growth_multiplier
	
	# Begrenze extreme Größen
	if particle_material:
		particle_material.scale_min = clamp(final_size_min, 0.01, 2.0)
		particle_material.scale_max = clamp(final_size_max, 0.02, 4.0)

func update_box_size(size: float):
	if not particle_material:
		return
	
	# Box-Extents aktualisieren
	particle_material.emission_box_extents = Vector3(size, 1.0, size)
	
	# Visibility AABB dynamisch aktualisieren
	var margin = size * 1.2
	visibility_aabb = AABB(Vector3(-margin, -10.0, -margin), Vector3(margin * 2.0, 20.0, margin * 2.0))
	
	# Extra Cull Margin für große Entfernungen
	extra_cull_margin = margin * 1.5

func restart_particles():
	# Partikelsystem komplett zurücksetzen (ohne Rekursion)
	emitting = false
	preprocess = lifetime  # Stelle sicher, dass beim Restart alle Partikel generiert werden
	await get_tree().process_frame
	emitting = true
