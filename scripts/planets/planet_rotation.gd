@tool
extends MeshInstance3D

# Positive Werte = Rechtsdrehung, Negative Werte = Linksdrehung
@export var rotation_speed: float = 0.2

func _process(delta):
	# Wir nutzen rotate_y für die klassische Planetenrotation
	# Wenn du das Skript auf der Atmosphäre hast, gib dort einfach 
	# einen negativen Wert ein (z.B. -0.1)
	rotate_y(rotation_speed * delta)
