# res://scripts/resources/shockwave_data.gd
class_name ShockwaveData
extends Resource

@export_group("Shockwave")
## Maximale Reichweite der Explosionswelle in Welteinheiten.
@export var shockwave_radius: float = 30.0
## Maximale Stoßkraft die auf velocity addiert wird (bei Distanz 0).
@export var shockwave_force: float = 20.0
## Maximaler Kippwinkel in Grad (Z-Achse, wird links/rechts je nach Richtung gespiegelt).
@export var shockwave_tilt_angle: float = 15.0
## Sekunden bis das Schiff sich nach dem Kipp-Impuls wieder aufrichtet.
@export var shockwave_recovery_time: float = 1.5
