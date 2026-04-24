# res://resources/beam_weapon_data.gd
# Universelle Resource für alle Strahl-Waffen (Phaser, Disruptor, Plasmakanone, etc.).
# Eine .tres-Datei pro Waffentyp anlegen:
#   beam_phaser_federation.tres   → Typ-X Phaser  (Federation)
#   beam_disruptor_klingon.tres   → Disruptor      (Klingon)
#   beam_plasma_romulan.tres      → Plasmakanone   (Romulan)
@tool
class_name BeamWeaponData
extends Resource

# ── Identität ─────────────────────────────────────────────────────────────────
@export_group("Identität")
@export var weapon_name: String = "Beam Weapon"
## Schadenstyp: "phaser", "disruptor", "plasma", "polaron"
@export var damage_type: String = "phaser"

# ── Schaden ───────────────────────────────────────────────────────────────────
@export_group("Schaden")
@export var damage_per_second: float = 80.0
@export var damage_interval:   float = 0.08

## Multiplikator wenn der Strahl den Schild trifft.
## Phaser: 1.0 (neutral vs Schild)
## Disruptor: 0.7 (schwächer gegen Schild, dafür stärker gegen Hülle)
@export_range(0.0, 5.0, 0.05) var shield_damage_multiplier: float = 1.0

## Multiplikator wenn der Strahl die Hülle trifft.
## Phaser: 0.5 (schlechter gegen Hülle als gegen Schild)
## Disruptor: 1.4 (typischer Hüllen-Zersetzer)
@export_range(0.0, 5.0, 0.05) var hull_damage_multiplier: float = 1.0

# ── Timing ────────────────────────────────────────────────────────────────────
@export_group("Timing")
@export var charge_duration:      float = 0.8
@export var fire_duration:        float = 0.3
@export var cooldown_duration:    float = 1.5
@export var fade_out_time:        float = 0.1
@export var trail_spawn_interval: float = 0.05
@export var trail_fade_out_time:  float = 0.3

# ── Farbe ─────────────────────────────────────────────────────────────────────
@export_group("Farbe")
@export var beam_color: Color = Color(0.4, 0.8, 1.0)   # Phaser-Standard: hellblau

# ── Beam Geometrie ────────────────────────────────────────────────────────────
@export_group("Beam - Geometrie")
@export var beam_core_width: float = 0.1
@export var beam_glow_width: float = 0.3

# ── Licht ─────────────────────────────────────────────────────────────────────
@export_group("Licht")
@export var max_light_energy: float = 3.0
@export var tracking_speed:   float = 8.0

# ── Kollisions-Layer ──────────────────────────────────────────────────────────
@export_group("Kollisions-Layer")
@export_flags_3d_physics var hull_layer:   int = 2
@export_flags_3d_physics var shield_layer: int = 64

func get_target_mask() -> int:
	return hull_layer | shield_layer


## Gibt den skalierten Schadens-Tick zurück.
## hit_shield = true  → shield_damage_multiplier auf damage_per_second anwenden
## hit_shield = false → hull_damage_multiplier
func get_damage_per_second(hit_shield: bool) -> float:
	if hit_shield:
		return damage_per_second * shield_damage_multiplier
	return damage_per_second * hull_damage_multiplier
