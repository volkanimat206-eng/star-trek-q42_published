# res://scripts/resources/explosion_audio_data.gd
class_name ExplosionAudioData
extends Resource

@export_group("Layer 1 – Haupt-Explosion")
@export var explosion_sound: AudioStream = null
@export_range(-30.0, 200.0, 0.1) var explosion_volume_db: float = 0.0
## Verzögerung vor dem ersten Boom (0.0 = sofort mit initialize())
@export_range(0.0, 5.0, 0.05) var explosion_delay: float = 0.0

@export_group("Layer 2 – Rumble")
@export var explosion_sound_layer2: AudioStream = null
@export_range(-30.0, 200.0, 0.1) var layer2_volume_db: float = -6.0
@export_range(0.0, 5.0, 0.05) var layer2_delay: float = 0.3

@export_group("Layer 3 – Shockwave")
@export var shockwave_sound: AudioStream = null
@export_range(-30.0, 200.0, 0.1) var shockwave_volume_db: float = -4.0
## Unabhängig vom shockwave_delay-Parameter in initialize() –
## steuert nur den Audio-Einsatz, nicht den Partikel-Zeitpunkt.
@export_range(0.0, 5.0, 0.05) var shockwave_sound_delay: float = 0.0

@export_group("Spatialization")
@export_range(0.0, 2.0, 0.05)       var distance_attenuation_strength: float = 0.2
@export_range(100.0, 5000.0, 50.0)  var max_distance: float = 2000.0
@export var no_distance_attenuation: bool = false
@export_range(1000.0, 20500.0, 100.0) var attenuation_filter_cutoff_hz: float = 10000.0
