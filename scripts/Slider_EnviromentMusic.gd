extends HSlider

@export var bus_name: String = "Music"

func _ready():
	# 1. Prüfen, ob der Bus überhaupt existiert
	var bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		print("!!! FEHLER: Bus '", bus_name, "' wurde nicht gefunden!")
		return
	
	# 2. Aktuellen Wert vom Server holen und Slider einstellen
	var current_db = AudioServer.get_bus_volume_db(bus_idx)
	value = db_to_linear(current_db)
	
	print("Slider bereit für Bus: ", bus_name, " (Index: ", bus_idx, ")")
	print("Aktuelle Lautstärke am Start: ", current_db, " dB")

	# Signal verbinden
	value_changed.connect(_on_value_changed)

func _on_value_changed(new_value: float):
	var bus_idx = AudioServer.get_bus_index(bus_name)
	var new_db = linear_to_db(new_value)
	
	# Hier passiert die Magie
	AudioServer.set_bus_volume_db(bus_idx, new_db)
	
	# Debug-Zeile für die Konsole
	print("Slider bewegt! Neuer Wert: ", new_value, " -> entspricht ", new_db, " dB")
	
	# Sicherheits-Mute, wenn der Slider ganz links ist
	if new_value <= 0.01:
		AudioServer.set_bus_mute(bus_idx, true)
		print("Bus wurde KOMPLETT STUMM geschaltet (Mute).")
	else:
		AudioServer.set_bus_mute(bus_idx, false)
