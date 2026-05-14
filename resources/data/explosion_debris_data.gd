# res://scripts/effects/explosion_debris_data.gd
#
# Resource-basierte Debris-Konfiguration für ExplosionEffect.
# Analog zu ExplosionAudioData — eine .tres pro Schiffsklasse, mehrere
# Schiffe können sich dieselbe teilen.
#
# NEU: fragment_scene + debris_params für ShipDebrisBurst.
#   Wenn fragment_scene gesetzt ist, wird ShipDebrisBurst statt Debris3D
#   verwendet. debris_scene wird dann ignoriert.
#
# WICHTIG:
#   - debris_scene muss debris_3d.tscn sein (Root: Debris3D / RigidBody3D)
#   - fragment_scene muss eine Node3D-Root mit MeshInstance3D-Kindern sein
#     (z.B. galaxy_debris.tscn)
#   - count skaliert automatisch mit ship_size aus ExplosionEffect.initialize()
#     wenn scale_count_with_ship_size = true
@tool
class_name ExplosionDebrisData
extends Resource

@export_group("Modus")
## Wenn eine fragment_scene gesetzt ist, wird ShipDebrisBurst verwendet
## (echte Schiffs-Meshes, Burn-Shader). debris_scene wird dann ignoriert.
## Leer lassen = klassischer Debris3D-Modus mit Standardgeometrie.
@export var fragment_scene: PackedScene = null

## Shader/Physik-Parameter für den ShipDebrisBurst.
## Nur relevant wenn fragment_scene gesetzt ist.
## Leer lassen = ShipDebrisParams-Defaults werden verwendet.
@export var debris_params: ShipDebrisParams = null

@export_group("Spawn (Debris3D – klassisch)")
## PackedScene des Trümmerstücks. Leer lassen = kein klassischer Debris-Burst.
## Standard: res://scenes/effects/debris_3d.tscn
## Wird ignoriert wenn fragment_scene gesetzt ist.
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

@export_group("Physics (Debris3D – klassisch)")
## Anfangsgeschwindigkeit Streuung.
@export_range(0.5, 50.0, 0.5) var min_force: float = 2.0
@export_range(0.5, 50.0, 0.5) var max_force: float = 10.0

## Drehimpuls Streuung.
@export_range(0.0, 20.0, 0.1) var min_torque: float = 1.0
@export_range(0.0, 20.0, 0.1) var max_torque: float = 5.0

@export_group("Force Scaling (Debris3D – klassisch)")
## Wenn true: min_force/max_force werden mit ship_size_factor multipliziert.
## Größere Schiffe schleudern Trümmer weiter raus — passt zum visuellen Maßstab.
@export var scale_force_with_ship_size: bool = true
