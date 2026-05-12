# res://resources/torpedo_loadout.gd
# Hält mehrere TorpedoData-Einträge (Photon, Quantum, Plasma …)
# und verwaltet welcher Typ aktuell aktiv ist.
#
# Wird in ShipData anstelle von `torpedo_data: TorpedoData` genutzt:
#   @export var torpedo_loadout: TorpedoLoadout
#
# Der ShipController liest immer torpedo_loadout.active_data und übergibt
# ihn an alle TorpedoMount3D-Instanzen, wenn der Spieler den Typ wechselt.
@tool
class_name TorpedoLoadout
extends Resource

## Signal: wird gesendet wenn der aktive Torpedo-Typ wechselt.
## Empfänger: ShipController (updated Mounts), HUD (updated Anzeige)
signal active_type_changed(new_data: TorpedoData)

@export_group("Typen")
## Liste aller verfügbaren Torpedo-Typen für dieses Schiff.
## Reihenfolge = Wechselreihenfolge mit Cycle-Taste.
## Sovereign Class: [PhotonTorpedoData, QuantumTorpedoData]
@export var entries: Array[TorpedoData] = []

@export_group("Start")
## Index in `entries` der beim Spielstart aktiv ist (0 = erster Eintrag).
@export_range(0, 15) var default_index: int = 0

# ─────────────────────────────────────────────────────────────────────────────
# LAUFZEITSTATUS  (nicht persistiert – wird in _ready() initialisiert)
# ─────────────────────────────────────────────────────────────────────────────

## Aktuell aktiver Index. Wird von ShipController / PlayerController gelesen.
var _active_index: int = 0


func _init() -> void:
	_active_index = default_index


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Gibt die aktuell aktive TorpedoData zurück.
## Gibt null zurück wenn `entries` leer ist (kein Crash).
func active_data() -> TorpedoData:
	if entries.is_empty():
		return null
	_active_index = clampi(_active_index, 0, entries.size() - 1)
	return entries[_active_index]


## Gibt den Index des aktuell aktiven Typs zurück.
func active_index() -> int:
	return _active_index


## Gibt die Anzahl verfügbarer Typen zurück.
func type_count() -> int:
	return entries.size()


## Wechselt zyklisch zum nächsten Torpedo-Typ.
## Sendet active_type_changed – der ShipController verbindet sich damit.
## Gibt die neue TorpedoData zurück (oder null wenn leer).
func cycle_next() -> TorpedoData:
	if entries.size() <= 1:
		return active_data()
	_active_index = (_active_index + 1) % entries.size()
	var nd: TorpedoData = entries[_active_index]
	active_type_changed.emit(nd)
	return nd


## Wechselt direkt zu einem bestimmten Index.
## Sendet active_type_changed nur wenn sich der Index tatsächlich ändert.
func set_active_index(idx: int) -> TorpedoData:
	if entries.is_empty():
		return null
	var clamped: int = clampi(idx, 0, entries.size() - 1)
	if clamped == _active_index:
		return active_data()
	_active_index = clamped
	var nd: TorpedoData = entries[_active_index]
	active_type_changed.emit(nd)
	return nd


## Gibt alle TorpedoData-Namen als String-Array zurück.
## Nützlich für HUD-Anzeigen und Debug-Logs.
func get_type_names() -> Array[String]:
	var names: Array[String] = []
	for td in entries:
		names.append(td.torpedo_name if td else "???")
	return names


## Gibt true zurück wenn ein bestimmter Typ im Loadout enthalten ist.
func has_type(torpedo_name: String) -> bool:
	for td in entries:
		if td and td.torpedo_name == torpedo_name:
			return true
	return false


## Reset auf Default-Typ (z. B. bei Schiff-Respawn).
func reset() -> void:
	_active_index = default_index
