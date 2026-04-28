# res://scripts/resources/cloak_audio_data.gd
class_name CloakAudioData
extends Resource

@export_group("Sounds")
@export var sound_cloak:   AudioStream = null
@export var sound_decloak: AudioStream = null

@export_group("Volume")
@export_range(-30.0, 200.0, 0.1) var cloak_volume_offset_db:   float = 0.0
@export_range(-30.0, 200.0, 0.1) var decloak_volume_offset_db:  float = 0.0

@export_group("Spatialization")
@export_range(0.0, 2.0, 0.05)    var distance_attenuation_strength: float = 0.25
@export_range(100.0, 5000.0, 50.0) var max_distance: float = 800.0
@export var no_distance_attenuation: bool = false
@export_range(1000.0, 20500.0, 100.0) var attenuation_filter_cutoff_hz: float = 12000.0

@export_group("Fade")
@export_range(0.0, 3.0, 0.1) var sound_fade_out_time: float = 0.8
