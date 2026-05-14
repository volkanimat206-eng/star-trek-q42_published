# res://scripts/effects/explosion_effect.gd
extends Node3D
class_name ExplosionEffect

const BASE_SIZE: float = 1.0

@export_range(0.0, 1.0) var size_range:          float  = 0.2
@export var shockwave_node_name: String = "Shockwave"
@export var windup_node_name:    String = "Windup2"

@export_group("Audio")
@export var audio_data: ExplosionAudioData = null

var _shockwave: GPUParticles3D = null
var _factor:    float          = 1.0

## Wird vom ShipController nach add_child() aufgerufen.
##
## ship_size:       Größenfaktor des Schiffs (1.0 = Standard)
## shockwave_delay: Verzögerung des Shockwave-Bursts in Sekunden
## debris_data:     Optional — Trümmer-Konfiguration (Resource).
##                  null = kein Debris-Burst.
## debris_color:    Optional — Faction-Tint für die Trümmer.
## ship_transform:  Vollständige globale Transform des Schiffs zum
##                  Explosionszeitpunkt (Position + Rotation + Scale).
# ─────────────────────────────────────────────────────────────────────────────
# INITIALIZE
# ─────────────────────────────────────────────────────────────────────────────

func initialize(
	ship_size: float,
	shockwave_delay: float = 0.0,
	debris_data: ExplosionDebrisData = null,
	debris_color: Color = Color.WHITE,
	ship_transform: Transform3D = Transform3D.IDENTITY
) -> void:
	
	var variation: float = randf_range(1.0 - size_range, 1.0 + size_range)
	_factor = clampf((ship_size / BASE_SIZE) * variation, 0.5, 20.0)
	
	scale = Vector3.ONE * _factor
	
	_shockwave = _extract_shockwave()
	_scale_particles(_factor)
	
	_start_shockwave_delayed(shockwave_delay)
	
	# Audio
	if audio_data:
		_play_sound_delayed(audio_data.explosion_sound, audio_data.explosion_volume_db, audio_data.explosion_delay)
		_play_sound_delayed(audio_data.explosion_sound_layer2, audio_data.layer2_volume_db, audio_data.layer2_delay)
		_play_sound_delayed(audio_data.shockwave_sound, audio_data.shockwave_volume_db, audio_data.shockwave_sound_delay)
	
	# Debris Burst
	if debris_data:
		_spawn_debris_logic_integrated(debris_data, debris_color, ship_transform)


# ─────────────────────────────────────────────────────────────────────────────
# AUDIO
# ─────────────────────────────────────────────────────────────────────────────

func _play_sound(stream: AudioStream, volume_db: float) -> void:
	if not stream:
		return

	var player := AudioStreamPlayer3D.new()
	player.stream    = stream
	player.volume_db = volume_db
	player.bus       = "Weapons"
	add_child(player)

	_apply_spatialization(player)
	player.play()

	player.finished.connect(func():
		if is_instance_valid(player):
			player.queue_free()
	)


func _play_sound_delayed(stream: AudioStream, volume_db: float, delay: float) -> void:
	if not stream or delay <= 0.0:
		_play_sound(stream, volume_db)
		return

	get_tree().create_timer(delay).timeout.connect(func():
		if is_instance_valid(self):
			_play_sound(stream, volume_db)
	, CONNECT_ONE_SHOT)


func _apply_spatialization(player: AudioStreamPlayer3D) -> void:
	if not audio_data:
		return

	if audio_data.no_distance_attenuation:
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		player.max_distance      = 5000.0
	else:
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.max_distance      = audio_data.max_distance * _factor
		player.unit_size         = 1.0 / max(0.1, audio_data.distance_attenuation_strength)

	player.attenuation_filter_cutoff_hz = audio_data.attenuation_filter_cutoff_hz


# ─────────────────────────────────────────────────────────────────────────────
# DEBRIS
# ─────────────────────────────────────────────────────────────────────────────

func _spawn_debris_logic_integrated(
	debris_data: ExplosionDebrisData,
	color_tint: Color,
	ship_transform: Transform3D = Transform3D.IDENTITY
) -> void:
	var delay: float = debris_data.spawn_delay
	
	# Pfad 1: Schiffs-Fragmente mit Burn-Shader (ShipDebrisBurst)
	if debris_data.fragment_scene:
		if delay > 0.0:
			await get_tree().create_timer(delay).timeout
		if not is_instance_valid(self) or not is_inside_tree():
			return
		
		# Schiffsursprung in die Params schreiben damit ShipDebrisBurst
		# die Impulse korrekt vom Schiffszentrum aus berechnen kann.
		var params: ShipDebrisParams = debris_data.debris_params
		if params:
			params = params.duplicate() as ShipDebrisParams  # nicht die Resource-Asset mutieren
		else:
			params = ShipDebrisParams.new()
		params.set_ship_origin(ship_transform.origin)
		
		# KEIN global_position mehr — nur ship_transform wird übergeben.
		# ShipDebrisBurst berechnet intern:
		#   fragment_global_transform = ship_transform * fragment_local_transform
		ShipDebrisBurst.launch_at(
			debris_data.fragment_scene,
			get_tree().current_scene,
			ship_transform,          # ← Position + Rotation in einem Schritt
			color_tint,
			params
		)
	
	# Pfad 2: Altes Debris-System (Debris3D, unverändert)
	elif debris_data.debris_scene:
		if delay > 0.0:
			await get_tree().create_timer(delay).timeout
		if not is_instance_valid(self) or not is_inside_tree():
			return
			
		var actual_count: int = debris_data.count
		var actual_min_force: float = debris_data.min_force
		var actual_max_force: float = debris_data.max_force
		
		if debris_data.scale_count_with_ship_size:
			actual_count = int(ceilf(float(debris_data.count) * _factor))
			actual_count = clampi(actual_count, 1, 200)
		
		if debris_data.scale_force_with_ship_size:
			actual_min_force *= _factor
			actual_max_force *= _factor
			
		Debris3D.spawn_burst(
			debris_data.debris_scene,
			get_tree().current_scene,
			ship_transform.origin,   # Debris3D kennt nur Position → origin reicht
			actual_count,
			color_tint,
			actual_min_force,
			actual_max_force,
			debris_data.min_torque,
			debris_data.max_torque
		)


# ─────────────────────────────────────────────────────────────────────────────
# PARTIKEL (unverändert)
# ─────────────────────────────────────────────────────────────────────────────

func _extract_shockwave() -> GPUParticles3D:
	var node := find_child(shockwave_node_name, true, false)
	if node is GPUParticles3D:
		return node as GPUParticles3D
	push_warning("[ExplosionEffect] Kein '%s'-Node gefunden!" % shockwave_node_name)
	return null


func _start_shockwave_delayed(delay: float) -> void:
	if _shockwave == null:
		return
	_shockwave.emitting = false
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
	if not is_instance_valid(_shockwave):
		return
	_scale_shockwave_material(_shockwave, _factor)
	_shockwave.emitting = true


func _scale_shockwave_material(gp: GPUParticles3D, factor: float) -> void:
	if not gp.process_material is ParticleProcessMaterial:
		return
	var mat := (gp.process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
	gp.process_material = mat
	mat.emission_ring_radius       *= factor
	mat.emission_ring_inner_radius *= factor
	mat.emission_ring_height       *= factor
	mat.radial_accel_min           *= factor
	mat.radial_accel_max           *= factor
	mat.scale_min                  *= clampf(factor, 0.5, 2.0)
	mat.scale_max                  *= clampf(factor, 0.5, 2.0)


func _scale_particles(factor: float) -> void:
	for node in find_children("*", "GPUParticles3D", true, false):
		var gp := node as GPUParticles3D
		if gp == _shockwave:
			continue
		if not gp.process_material is ParticleProcessMaterial:
			continue
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
