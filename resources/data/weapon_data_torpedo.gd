# res://resources/data/weapon_data_torpedo.gd
@tool
class_name TorpedoData
extends Resource

# ─────────────────────────────────────────────────────────────────────────────
# TORPEDO-TYP  –  bestimmt welche Scene/VFX/SFX verwendet werden
# ─────────────────────────────────────────────────────────────────────────────

enum TorpedoType {
	PHOTON    = 0,  ## Standard. Gut vs. Hülle, gedämpft vs. Schilde.
	QUANTUM   = 1,  ## High-Value. Schildpenetration, hoher Hüllschaden, längerer Cooldown.
	PLASMA    = 2,  ## Hält Energie nach Einschlag – gut für anhaltenden Druck.
	TRANSPHASIC = 3, ## Ignoriert Schilde fast vollständig (sehr limitiert).
	TRICOBALT = 4,  ## Massenvernichtung, kanonisch verboten in Konfliktzonen.
}

@export_group("Allgemein")
@export var torpedo_name:   String       = "Photon Torpedo"
@export var torpedo_type:   TorpedoType  = TorpedoType.PHOTON
@export var damage:         float        = 120.0
@export var blast_radius:   float        = 5.0   # 0 = kein Splash

## Multiplikator wenn das Torpedo den Schild trifft.
## Photon:      0.7  (Torpedos werden von Schilden gut absorbiert)
## Quantum:     1.0  (durchdringt Schilde effizienter)
## Transphasic: 0.05 (ignoriert Schilde fast vollständig)
@export_range(0.0, 5.0, 0.05) var shield_damage_multiplier: float = 0.7

## Multiplikator wenn das Torpedo die Hülle trifft (Schild durchbrochen).
## Photon:  1.5  (hoher Sprengschaden direkt an der Hülle)
## Quantum: 2.0  (massiv)
@export_range(0.0, 5.0, 0.05) var hull_damage_multiplier: float = 1.5

@export_group("Firing")
## Wartezeit zwischen Einzelschüssen in Sekunden.
## Quantum: deutlich länger (taktische Waffe, nicht Spam-Waffe)
@export var cooldown: float = 0.5

@export_group("Magazine")
## Maximale Torpedo-Anzahl im Magazin.
## Quantum: deutlich weniger als Photon (Spezialmunition)
@export var max_ammo: int = 4

## Sekunden bis ein Torpedo nachgeladen ist.
## Quantum: länger – symbolisiert komplexeren Ladevorgang
@export var reload_time: float = 8.0

@export_group("Ressourcenkosten")
## Energiekosten pro Schuss (wird vom ShipController abgezogen).
## 0.0 = kein Energieverbrauch (Photon-Standard).
## Quantum: 25–50 (spürbar aber nicht prohibitiv).
@export var energy_cost: float = 0.0

## Wenn true: dieser Torpedo-Typ zählt als Spezialmunition.
## Bedeutet: reload_time gilt pro Torpedo (langsam), max_ammo ist der
## absolute Vorrat (kein weiterer Reload nach Erschöpfung bis Resupply).
## Photon: false (normales Magazin mit kontinuierlichem Reload)
## Quantum: true  (limitiertes Magazin, langsamer Einzelreload)
@export var is_special_ammo: bool = false

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

## Optionale alternative Scene für diesen Torpedo-Typ.
## Wenn gesetzt, überschreibt sie torpedo_scene im TorpedoMount3D.
## Quantum-Torpedo kann damit eine eigene .tscn mit anderen VFX haben.
@export var torpedo_scene_override: PackedScene = null

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
@export_range(0.0, 5.0, 0.05)   var impact_delay: float = 0.0
@export_range(0.0, 2.0, 0.05)   var impact_distance_attenuation_strength: float = 0.2
@export_range(100.0, 5000.0, 50.0) var impact_max_distance: float = 1800.0
@export var impact_no_distance_attenuation: bool = false
@export_range(0.0, 10.0, 0.05) var impact_sound_duration: float = 0.0

## Audio beim Abfeuern – kann typ-spezifisch sein.
## Wenn gesetzt, überschreibt launch_sound im TorpedoMount3D für diesen Typ.
@export_group("Audio – Launch Override")
@export var launch_sound_override: AudioStream = null
@export_range(-20.0, 20.0) var launch_volume_db_offset: float = 0.0


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Gibt den skalierten Schaden zurück.
## hit_shield = true  → shield_damage_multiplier
## hit_shield = false → hull_damage_multiplier
func get_damage(hit_shield: bool) -> float:
	if hit_shield:
		return damage * shield_damage_multiplier
	return damage * hull_damage_multiplier


## Gibt einen Kurzbezeichner für HUD-Anzeigen zurück.
## "PH" für Photon, "QT" für Quantum, etc.
func get_hud_abbreviation() -> String:
	match torpedo_type:
		TorpedoType.PHOTON:      return "PH"
		TorpedoType.QUANTUM:     return "QT"
		TorpedoType.PLASMA:      return "PL"
		TorpedoType.TRANSPHASIC: return "TP"
		TorpedoType.TRICOBALT:   return "TC"
	return "??"


## Farbe für HUD-Anzeige passend zum Torpedo-Typ.
func get_hud_color() -> Color:
	match torpedo_type:
		TorpedoType.PHOTON:      return Color(1.0, 0.85, 0.1)   # Gelb-Orange
		TorpedoType.QUANTUM:     return Color(0.2, 0.6,  1.0)   # Blau
		TorpedoType.PLASMA:      return Color(0.0, 1.0,  0.3)   # Grün
		TorpedoType.TRANSPHASIC: return Color(0.8, 0.0,  1.0)   # Violett
		TorpedoType.TRICOBALT:   return Color(1.0, 0.0,  0.0)   # Rot
	return Color.WHITE
