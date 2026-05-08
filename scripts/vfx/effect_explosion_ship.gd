# res://scripts/effects/explosion_effect.gd
extends Node3D
class_name ExplosionEffect

const BASE_SIZE: float = 1.0

@export_range(0.0, 1.0) var size_range:          float  = 0.2
@export var shockwave_node_name: String = "Shockwave"
@export var windup_node_name:    String = "Windup2"

@export_group("Audio")
## Alle Explosions-Sounds als Resource.
## Leer lassen = keine Audio-Ausgabe.
@export var audio_data: ExplosionAudioData = null

var _shockwave: GPUParticles3D = null
var _factor:    float          = 1.0


# ─────────────────────────────────────────────────────────────────────────────
# INITIALIZE
# ─────────────────────────────────────────────────────────────────────────────

## Wird vom ShipController nach add_child() aufgerufen.
##
## ship_size:       Größenfaktor des Schiffs (1.0 = Standard, BoP klein, Sovereign groß)
## shockwave_delay: Verzögerung des Shockwave-Bursts in Sekunden
## debris_data:     Optional — Trümmer-Konfiguration (Resource).
##                  null = kein Debris-Burst.
## debris_color:    Optional — Faction-Tint für die Trümmer.
##                  Color.WHITE = neutral grau (Default).
##
## Beide Debris-Parameter werden vom ShipController durchgereicht. So können
## verschiedene Schiffe dieselbe Explosions-Scene nutzen aber eigene Trümmer
## bekommen (z.B. rotglühende Klingonen-Hülle vs. graue Föderation).
func initialize(ship_size: float,
				shockwave_delay: float = 0.0,
				debris_data: ExplosionDebrisData = null,
				debris_color: Color = Color.WHITE) -> void:
	var variation: float = randf_range(1.0 - size_range, 1.0 + size_range)
	_factor = clampf((ship_size / BASE_SIZE) * variation, 0.5, 20.0)
	scale   = Vector3.ONE * _factor

	_shockwave = _extract_shockwave()
	_scale_particles(_factor)
	_start_shockwave_delayed(shockwave_delay)

	if audio_data:
		_play_sound_delayed(audio_data.explosion_sound,       audio_data.explosion_volume_db,    audio_data.explosion_delay)
		_play_sound_delayed(audio_data.explosion_sound_layer2, audio_data.layer2_volume_db,      audio_data.layer2_delay)
		_play_sound_delayed(audio_data.shockwave_sound,       audio_data.shockwave_volume_db,    audio_data.shockwave_sound_delay)

	# Debris-Burst — nur wenn Resource gesetzt UND scene drin
	if debris_data and debris_data.debris_scene:
		_spawn_debris_delayed(debris_data, debris_color)


# ─────────────────────────────────────────────────────────────────────────────
# AUDIO
# ─────────────────────────────────────────────────────────────────────────────

func _play_sound(stream: AudioStream, volume_db: float) -> void:
	if not stream:
		return

	var player := AudioStreamPlayer3D.new()
	player.stream    = stream
	player.volume_db = volume_db
	player.bus       = "Weapons"   # oder eigenen "Explosions"-Bus anlegen
	add_child(player)

	_apply_spatialization(player)
	player.play()

	# Aufräumen wenn Clip fertig – kein queue_free auf den Node selbst,
	# da ExplosionEffect von außen (ShipController) zerstört wird.
	player.finished.connect(func():
		if is_instance_valid(player):
			player.queue_free()
	)


func _play_sound_delayed(stream: AudioStream, volume_db: float, delay: float) -> void:
	if not stream or delay <= 0.0:
		_play_sound(stream, volume_db)
		return

	# Direkt als Coroutine – kein separater await-Kontext nötig
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
		player.max_distance      = audio_data.max_distance * _factor  # größeres Schiff = weiter hörbar
		player.unit_size         = 1.0 / max(0.1, audio_data.distance_attenuation_strength)

	player.attenuation_filter_cutoff_hz = audio_data.attenuation_filter_cutoff_hz


# ─────────────────────────────────────────────────────────────────────────────
# DEBRIS
# ─────────────────────────────────────────────────────────────────────────────

func _spawn_debris_delayed(debris_data: ExplosionDebrisData, debris_color: Color) -> void:
	# Delay: Debris kommt erst nach dem Fireball-Peak raus, nicht im Feuerball
	# „versteckt".
	if debris_data.spawn_delay > 0.0:
		await get_tree().create_timer(debris_data.spawn_delay).timeout

	# Self könnte schon weg sein wenn der ShipController die Explosion gefreed
	# hat bevor der Delay abgelaufen ist.
	if not is_instance_valid(self) or not is_inside_tree():
		return

	# Skalierung mit Schiffsgröße
	var count: int = debris_data.count
	if debris_data.scale_count_with_ship_size:
		count = int(ceilf(float(debris_data.count) * _factor))

	var min_force: float = debris_data.min_force
	var max_force: float = debris_data.max_force
	if debris_data.scale_force_with_ship_size:
		# Force linear mit factor — größeres Schiff = mehr Wumms
		min_force *= _factor
		max_force *= _factor

	# WICHTIG: world = current_scene, NICHT self!
	# Der ExplosionEffect wird vom ShipController gefreed wenn die Animation
	# durch ist (~6s). Debris haben aber eigenes lifetime (~5s) und müssen
	# unabhängig leben. Deshalb landen sie direkt unter current_scene.
	var world: Node = get_tree().current_scene
	if not world:
		return

	Debris3D.spawn_burst(
		debris_data.debris_scene,
		world,
		global_position,
		count,
		debris_color,
		min_force,
		max_force,
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
