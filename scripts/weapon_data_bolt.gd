# res://resources/weapon_data_bolt.gd
# Resource für Energiebolzen-Waffen (Disruptor-Bolzen, Puls-Phaser, etc.)
# Ersetzt die einzelnen float-Exports in WingDisruptorMount – alle Bolt-Parameter
# zentral in einer .tres-Datei, austauschbar per Inspector.
#
# .tres-Dateien anlegen:
#   weapon_bolt_disruptor_klingon.tres  → Klingon Wing-Disruptor
#   weapon_bolt_pulse_federation.tres   → Federation Pulse-Phaser

@tool
class_name BoltWeaponData
extends Resource

# ── Identität ─────────────────────────────────────────────────────────────────
@export_group("Identität")
@export var weapon_name:  String = "Disruptor Bolt"
## Schadenstyp: "disruptor", "phaser_pulse", "plasma", "polaron"
@export var damage_type:  String = "disruptor"

# ── Schaden ───────────────────────────────────────────────────────────────────
@export_group("Schaden")
## Grundschaden pro Treffer.
@export var damage: float = 35.0

## Multiplikator auf den Schaden wenn der Schild getroffen wird.
## < 1.0 = Schild schwächt Bolzen  (z.B. 0.8 = 20% weniger Schaden am Schild)
## > 1.0 = Bolzen ist besonders schildbrechend (z.B. 1.3 = 30% mehr)
## = 1.0 = kein Unterschied (Standard)
@export_range(0.0, 5.0, 0.05) var shield_damage_multiplier: float = 1.0

## Multiplikator auf den Schaden wenn die Hülle (direkt) getroffen wird.
## < 1.0 = Hülle widersteht dem Bolzen besser
## > 1.0 = Bolzen verursacht beim Hüllentreffer mehr Schaden (z.B. Hohlladung)
@export_range(0.0, 5.0, 0.05) var hull_damage_multiplier: float = 1.0

# ── Bewegung ──────────────────────────────────────────────────────────────────
@export_group("Bewegung")
@export var speed:     float = 400.0
@export var max_range: float = 150.0

# ── Visuell ───────────────────────────────────────────────────────────────────
@export_group("Visuell")
@export var bolt_color:  Color = Color(0.0, 1.0, 0.2)   # Klingon: grün
@export var bolt_length: float = 1.0
@export var bolt_radius: float = 0.12

# ── Kollision ─────────────────────────────────────────────────────────────────
@export_group("Kollision")
## Muss Shield-Layer UND Hull-Layer abdecken.
@export_flags_3d_physics var collision_mask: int = 6

# ── Cooldown / Salve ─────────────────────────────────────────────────────────
@export_group("Cooldown & Salve")
@export var cooldown:        float = 1.2
@export_range(1, 10) var salvo_count:    int   = 1
@export_range(0.05, 1.0) var salvo_interval: float = 0.15


## Gibt den skalierten Schaden zurück – Shield oder Hull abhängig vom Treffertyp.
## hit_shield = true  → shield_damage_multiplier anwenden
## hit_shield = false → hull_damage_multiplier anwenden
func get_damage(hit_shield: bool) -> float:
	if hit_shield:
		return damage * shield_damage_multiplier
	return damage * hull_damage_multiplier
