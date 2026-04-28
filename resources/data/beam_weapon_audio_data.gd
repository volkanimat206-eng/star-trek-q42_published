# res://scripts/resources/beam_weapon_audio_data.gd
# Alle Audio-Parameter für Beam-Waffen (Phaser, Disruptor-Strahl).
# Im Inspector zuweisen – ersetzt alle Audio-Exports im WeaponMount.
class_name BeamWeaponAudioData
extends Resource

@export_group("Sounds")
@export var charge_sound: AudioStream = null
@export var fire_sound:   AudioStream = null

@export_group("Volume")
@export_range(-30.0, 30.0, 0.1) var charge_volume_offset_db: float = 0.0
@export_range(-30.0, 30.0, 0.1) var fire_volume_offset_db:   float = 0.0

@export_group("Spatialization")
@export_range(0.0, 2.0, 0.05)   var distance_attenuation_strength: float = 0.35
@export_range(100.0, 5000.0, 50.0) var max_distance: float = 1500.0
@export var no_distance_attenuation: bool = false
@export_range(1000.0, 20500.0, 100.0) var attenuation_filter_cutoff_hz: float = 11000.0

@export_group("Fade")
@export_range(0.0, 2.0) var charge_fade_out_time: float = 0.3
@export_range(0.0, 2.0) var fire_fade_out_time:   float = 0.2
@export var charge_fade_curve: Curve = null
@export var fire_fade_curve:   Curve = null
