extends MeshInstance3D

# Einstellungen, die du im Inspektor anpassen kannst
@export var warp_material_slot: int = 1   # Welcher Slot ist der Warp-Bereich? (0 oder 1)
@export var pulse_speed: float = 1.5      # Wie schnell soll es pulsieren?
@export var base_brightness: float = 10  # Minimale Helligkeit
@export var max_brightness: float = 15.0   # Maximale Helligkeit beim Pulsieren

var material: StandardMaterial3D

func _ready():
	# Wir holen uns das Material vom gewählten Slot
	var mat = get_active_material(warp_material_slot)
	
	if mat is StandardMaterial3D:
		material = mat
	else:
		push_error("Fehler: Material im Slot ist kein StandardMaterial3D!")

func _process(delta):
	if material:
		# Erzeugt eine sanfte Welle (Sinus) zwischen 0 und 1
		var time = Time.get_ticks_msec() / 1000.0
		var wave = (sin(time * pulse_speed) + 1.0) / 2.0
		
		# Berechnet die neue Energie
		var current_energy = lerp(base_brightness, max_brightness, wave)
		
		# Wendet sie auf das Material an
		material.emission_energy_multiplier = current_energy
