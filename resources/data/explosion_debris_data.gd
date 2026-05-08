# res://scripts/effects/explosion_debris_data.gd
#
# Resource-basierte Debris-Konfiguration für ExplosionEffect.
# Analog zu ExplosionAudioData — eine .tres pro Schiffsklasse, mehrere
# Schiffe können sich dieselbe teilen.
#
# WICHTIG:
#   - debris_scene muss debris_3d.tscn sein (Root: Debris3D / RigidBody3D)
#   - count skaliert automatisch mit ship_size aus ExplosionEffect.initialize()
#     wenn scale_count_with_ship_size = true
@tool
class_name ExplosionDebrisData
extends Resource

@export_group("Spawn")
## PackedScene des Trümmerstücks. Leer lassen = kein Debris-Burst.
## Standard: res://scenes/effects/debris_3d.tscn
@export var debris_scene: PackedScene = null

## Anzahl Trümmer pro Burst (Basiswert vor Skalierung).
@export_range(1, 100, 1) var count: int = 15

## Sekunden nach Explosions-Start bis der Burst spawnt.
## Empfohlen ~0.3–0.5s — so wird der Burst erst nach dem Fireball-Peak
## sichtbar und nicht im Feuerball „versteckt".
@export_range(0.0, 3.0, 0.05) var spawn_delay: float = 0.4

## Wenn true: count wird mit dem ship_size-Faktor multipliziert.
## Großes Schiff (factor=2.0) → doppelt so viele Trümmer.
@export var scale_count_with_ship_size: bool = true

@export_group("Physics")
## Anfangsgeschwindigkeit Streuung.
@export_range(0.5, 50.0, 0.5) var min_force: float = 2.0
@export_range(0.5, 50.0, 0.5) var max_force: float = 10.0

## Drehimpuls Streuung.
@export_range(0.0, 20.0, 0.1) var min_torque: float = 1.0
@export_range(0.0, 20.0, 0.1) var max_torque: float = 5.0

@export_group("Force Scaling")
## Wenn true: min_force/max_force werden mit ship_size_factor multipliziert.
## Größere Schiffe schleudern Trümmer weiter raus — passt zum visuellen Maßstab.
@export var scale_force_with_ship_size: bool = true
