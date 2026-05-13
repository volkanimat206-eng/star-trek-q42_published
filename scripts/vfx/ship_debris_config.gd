# res://scripts/effects/ship_debris_config.gd
#
# Resource für alle visuellen und physikalischen Parameter des
# ShipDebrisBurst-Systems. Eine .tres pro Schiffsklasse oder Fraktion.
#
# BEISPIELE:
#   galaxy_debris_config.tres   → blau-graues Glühen, Federation
#   klingon_debris_config.tres  → rotes/oranges Glühen, aggressiv
#   romulan_debris_config.tres  → grünliches Plasma-Glühen
#
# VERWENDUNG:
#   In ExplosionDebrisData das Feld "debris_config" auf diese Resource zeigen.
#   ShipDebrisBurst liest alle Parameter automatisch daraus.
#
@tool
class_name ShipDebrisConfig
extends Resource

# ─────────────────────────────────────────────────────────────────────────────
# SHADER / BURN
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Burn Shader – Farben")

## Glühfarbe der Kanten und des Burn-Effekts.
## Federation: Color(0.4, 0.7, 1.0) – bläuliches Plasma
## Klingonen:  Color(1.0, 0.25, 0.05) – tiefes Rot-Orange
## Romulaner:  Color(0.2, 1.0, 0.3) – grünes Plasma
@export var glow_color: Color = Color(1.0, 0.55, 0.1)

## Intensität des Fresnel-Kantenglow auf dem Peak (kurz nach Explosion).
## Höher = dramatischerer erster Aufblitz.
@export_range(0.5, 12.0, 0.25) var edge_glow_peak: float = 3.5

## Intensität des Glow wenn der Burn sich ausbreitet (Phase 2).
@export_range(0.0, 6.0, 0.25) var spread_glow_intensity: float = 1.2

## Wie stark der Burn das Original-Albedo überdeckt (0=gar nicht, 1=komplett).
@export_range(0.0, 1.0, 0.05) var burn_albedo_mix: float = 0.85

## Helligkeit der heißen Übergangs-Kante zwischen verbrannt/unverbrannt.
@export_range(0.5, 6.0, 0.25) var hot_edge_brightness: float = 2.5

## Größe der Rausch-Strukturen beim Ausbreiten des Burns.
## Klein = feines Muster, Groß = grobe Feuerflecken.
@export_range(0.2, 5.0, 0.1) var burn_noise_scale: float = 1.5

@export_group("Burn Shader – Timing")

## Sekunden bis der Kantenglow seinen Peak erreicht.
@export_range(0.05, 3.0, 0.05) var peak_glow_time: float = 0.4

## Sekunden für die Ausbreitung des Burns über das Mesh.
@export_range(0.5, 8.0, 0.1) var burn_spread_duration: float = 2.5

## Sekunden nach Spawn bis der Fade-Out beginnt.
@export_range(1.0, 30.0, 0.5) var fade_out_start: float = 5.0

## Sekunden für den Fade-Out auf alpha=0.
@export_range(0.2, 8.0, 0.25) var fade_out_duration: float = 2.0

## Maximale zufällige Verzögerung zwischen den Fragmenten (verhindert Synchronität).
@export_range(0.0, 1.0, 0.05) var fragment_delay_variance: float = 0.3

# ─────────────────────────────────────────────────────────────────────────────
# PHYSIK
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Physik – Kräfte")

## Explosionskraft vom Zentrum weg (min/max).
@export_range(0.5, 80.0, 0.5) var explosion_force_min: float = 5.0
@export_range(0.5, 120.0, 0.5) var explosion_force_max: float = 18.0

## Zusätzlicher zufälliger Drift überlagert den Explosionsvektor.
@export_range(0.0, 30.0, 0.5) var random_drift_strength: float = 4.0

## Drehimpuls (Tumbling) der Fragmente.
@export_range(0.0, 10.0, 0.25) var torque_min: float = 0.5
@export_range(0.0, 20.0, 0.25) var torque_max: float = 4.0

## Gravitationsskalierung. 0 = Weltraum (empfohlen).
@export var gravity_scale: float = 0.0

## Linear-Dämpfung (Drift verlangsamt sich leicht).
@export_range(0.0, 1.0, 0.01) var linear_damp: float = 0.05

## Angular-Dämpfung (Tumbling verlangsamt sich leicht).
@export_range(0.0, 1.0, 0.01) var angular_damp: float = 0.08

@export_group("Physik – Collision")

## Sekunden nach Spawn bis Collision deaktiviert wird. 0 = dauerhaft aktiv.
@export_range(0.0, 5.0, 0.1) var collision_disable_after: float = 1.0
