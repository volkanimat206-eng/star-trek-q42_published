# res://scripts/effects/ship_debris_params.gd
#
# Resource für alle Burn/Glow-Shader-Parameter des ShipDebrisBurst.
# Eine .tres pro Schiffsklasse oder Fraktion anlegen, z.B.:
#
#   res://resources/debris/params_federation.tres   → kühles Blau-Grau
#   res://resources/debris/params_klingon.tres       → heißes Rot-Orange
#   res://resources/debris/params_romulan.tres       → grünliches Glühen
#
# Wird in ExplosionDebrisData.debris_params eingetragen und von
# ShipDebrisBurst automatisch ausgelesen.
#
@tool
class_name ShipDebrisParams
extends Resource

@export_group("Burn Shader – Farben")

## Farbe des Glühens (Kanten + Burn-Ausbreitung).
## Klingonen: Color(1.0, 0.2, 0.05)  → tiefes Rot-Orange
## Föderation: Color(1.0, 0.55, 0.1) → heißes Orange (neutral)
## Romulaner:  Color(0.2, 1.0, 0.3)  → grünes Plasma-Glühen
@export var glow_color: Color = Color(1.0, 0.55, 0.1)

## Multiplikativer Tint auf die Albedo-Textur des Fragments.
## WHITE = kein Tint, Originalfarbe bleibt.
## Klingonen: Color(0.9, 0.6, 0.5) → leicht rötlich getönte Hülle
@export var albedo_tint_override: Color = Color.WHITE

@export_group("Burn Shader – Kantenglow")

## Peak-Intensität des Fresnel-Kantenglow direkt nach der Explosion.
## Niedrig (1.5) = dezent | Hoch (5.0) = dramatisch leuchtende Kanten
@export_range(0.5, 8.0, 0.25) var edge_glow_peak: float = 3.5

## Sekunden bis der Kantenglow seinen Peak erreicht.
@export_range(0.05, 2.0, 0.05) var peak_glow_time: float = 0.4

@export_group("Burn Shader – Ausbreitung")

## Intensität des Glühens während der Burn-Ausbreitung.
@export_range(0.0, 4.0, 0.25) var spread_glow_intensity: float = 1.2

## Sekunden bis der Burn sich über das gesamte Mesh ausgebreitet hat.
@export_range(0.5, 8.0, 0.25) var burn_spread_duration: float = 2.5

## Breite der glühenden Übergangszone (0.05 = schmaler Saum | 0.3 = breite Glut).
@export_range(0.02, 0.5, 0.01) var burn_edge_width: float = 0.15

## Skalierung der Vertex-Noise (höher = feinere Burn-Struktur).
@export_range(0.2, 5.0, 0.1) var burn_noise_scale: float = 1.5

@export_group("Lifetime")

## Sekunden nach Spawn bis der Alpha-Fade-Out beginnt.
@export_range(1.0, 30.0, 0.5) var fade_out_start: float = 5.0

## Dauer des Fade-Outs in Sekunden.
@export_range(0.5, 10.0, 0.25) var fade_out_duration: float = 2.0

@export_group("Physik")

## Explosionskraft – Minimum (weg vom Zentrum).
@export_range(1.0, 50.0, 0.5) var explosion_force_min: float = 5.0

## Explosionskraft – Maximum.
@export_range(1.0, 80.0, 0.5) var explosion_force_max: float = 18.0

## Zufälliger seitlicher Drift, überlagert den Explosions-Vektor.
@export_range(0.0, 20.0, 0.5) var random_drift_strength: float = 4.0

## Drehimpuls-Minimum (Tumbling).
@export_range(0.0, 10.0, 0.25) var torque_min: float = 0.5

## Drehimpuls-Maximum.
@export_range(0.0, 20.0, 0.25) var torque_max: float = 4.0

## Sekunden bis Collision deaktiviert wird. 0 = dauerhaft aktiv.
@export_range(0.0, 5.0, 0.1) var collision_disable_after: float = 1.0

# ── Intern (wird von ShipDebrisBurst.launch_at() gesetzt, nicht im Inspector) ──

## Weltposition des Schiffs zum Explosionszeitpunkt — Quelle der Impuls-Richtungen.
## Wird automatisch von effect_explosion_ship.gd befüllt. Nicht manuell setzen.
var ship_origin_ws:   Vector3 = Vector3.ZERO
var _ship_origin_set: bool    = false

## Setzt den Schiffsursprung für die Impulsberechnung.
func set_ship_origin(origin: Vector3) -> void:
	ship_origin_ws   = origin
	_ship_origin_set = true
