# res://resources/torpedo_data.gd
@tool
class_name TorpedoData
extends Resource

@export_group("Allgemein")
@export var torpedo_name:   String = "Photon Torpedo"
@export var damage:         float  = 120.0
@export var blast_radius:   float  = 5.0   # 0 = kein Splash

## Multiplikator wenn das Torpedo den Schild trifft.
## Photon: 0.7 (Torpedos werden von Schilden gut absorbiert)
## Quantum: 1.0 (durchdringt Schilde effizienter)
@export_range(0.0, 5.0, 0.05) var shield_damage_multiplier: float = 0.7

## Multiplikator wenn das Torpedo die Hülle trifft (Schild durchbrochen).
## Photon: 1.5 (hoher Sprengschaden direkt an der Hülle)
## Quantum: 2.0 (massiv)
@export_range(0.0, 5.0, 0.05) var hull_damage_multiplier: float = 1.5

@export_group("Firing")
## Wartezeit zwischen Einzelschüssen in Sekunden.
@export var cooldown: float = 0.5

@export_group("Magazine")
## Maximale Torpedo-Anzahl im Magazin.
@export var max_ammo: int = 4
## Sekunden bis ein Torpedo nachgeladen ist.
@export var reload_time: float = 8.0

@export_group("Bewegung")
@export var speed:          float  = 200.0
@export var turn_rate_deg:  float  = 60.0
@export var max_range:      float  = 300.0
@export var lifetime:       float  = 8.0

@export_group("Visuell")
@export var torpedo_color:  Color  = Color(1.0, 0.85, 0.1)
@export var trail_color:    Color  = Color(1.0, 0.6,  0.0)
@export var glow_energy:    float  = 4.0
@export var bolt_length:    float  = 1.2
@export var bolt_radius:    float  = 0.15

@export_group("Kollision")
@export_flags_3d_physics var collision_mask: int = 6

@export_group("Pulsieren")
@export var pulse_energy_min: float = 2.0
@export var pulse_energy_max: float = 5.0

@export_group("Detonation")
@export var explosion_scene:  PackedScene
@export var proximity_radius: float = 3.0
@export_range(0.1, 100.0) var explosion_scale: float = 1.0

@export_group("Audio – Impact")
## Sound der beim Einschlag des Torpedos abgespielt wird.
## Wird vom Torpedo-Projektil selbst abgespielt – nicht vom Mount.
@export var impact_sound: AudioStream = null
@export_range(-30.0, 200.0, 0.1) var impact_volume_db: float = 0.0
@export_range(0.0, 5.0, 0.05)   var impact_delay: float = 0.0  # z.B. kurz nach Einschlag
@export_range(0.0, 2.0, 0.05)   var impact_distance_attenuation_strength: float = 0.2
@export_range(100.0, 5000.0, 50.0) var impact_max_distance: float = 1800.0
@export var impact_no_distance_attenuation: bool = false
## Maximale Abspieldauer des Impact-Sounds in Sekunden.
## 0.0 = vollständige Länge abspielen.
@export_range(0.0, 10.0, 0.05) var impact_sound_duration: float = 0.0

## Gibt den skalierten Schaden zurück.
## hit_shield = true  → shield_damage_multiplier
## hit_shield = false → hull_damage_multiplier
func get_damage(hit_shield: bool) -> float:
	if hit_shield:
		return damage * shield_damage_multiplier
	return damage * hull_damage_multiplier
