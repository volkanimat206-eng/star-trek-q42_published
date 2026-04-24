extends Resource
class_name ShipStats

@export_group("Movement")
## Versatz des Drehpunkts relativ zum Schiffs-Ursprung (Local Space).
## Z-Achse: positiv = Drehpunkt nach hinten, negativ = nach vorne.
## Sovereign z.B. 0.0, BirdOfPrey z.B. -2.0 wenn Cockpit vorne lastig.
@export var pivot_offset: Vector3 = Vector3.ZERO
@export var max_speed: float = 25.0
@export var acceleration: float = 15.0
@export var friction: float = 10.0 

@export_group("Handling")
# Diese beiden Zeilen fehlen vermutlich oder sind falsch geschrieben:
@export var rotation_speed_base: float = 2.0
@export var rotation_speed_min: float = 0.5

@export_group("Visuals")
@export var tilt_amount: float = 0.5
@export var tilt_speed: float = 4.0
## Achse um die das Schiff beim Kurven kippt (Local Space des Model-Nodes).
## Sovereign: (0, 0, 1) | BirdOfPrey: ausprobieren bis es stimmt
@export var tilt_axis: Vector3 = Vector3(0.0, 0.0, 1.0)
## Kipprichtung: 1.0 = normal, -1.0 = umgekehrt
@export var tilt_direction: float = 1.0
