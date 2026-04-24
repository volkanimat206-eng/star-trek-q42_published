extends Node

# Erzeugt ein Feld im Inspektor, in das du jede Audio-Node ziehen kannst
@export var music_player_node: AudioStreamPlayer

func _ready():
	# Wir setzen den Music-Bus (Index 1 laut deiner tres) manuell auf -80db (stumm)
	AudioServer.set_bus_volume_db(1, 0.0)
	music_player_node.play()
	
	# 1. Sicherheitscheck: Wurde im Inspektor etwas zugewiesen?
	if music_player_node == null:
		push_warning("Achtung: Du hast im Inspektor keine Musik-Node zugewiesen!")
		return

	# 2. Bus-Zuweisung erzwingen (Sicher ist sicher)
	music_player_node.bus = "Music"
	
	# 3. Musik starten
	music_player_node.play()
	
	print("Musik-System bereit. Nutzt Bus: ", music_player_node.bus)
