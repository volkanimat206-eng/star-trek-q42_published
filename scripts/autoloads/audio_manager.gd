# res://scripts/autoload/audio_manager.gd
# Autoload-Singleton: Project Settings → Autoload → audio_manager.gd → "AudioManager"
#
# Zentrale Steuerung aller Audio-Kategorien über Godot Audio Buses.
# Jede Kategorie entspricht einem Bus im Audio-Editor (Project → Audio).
#
# Einstellungen werden automatisch in user://audio_settings.cfg gespeichert
# und beim nächsten Start geladen.
#
# VERWENDUNG VON AUSSEN:
#   AudioManager.set_volume("music", 0.7)       # 0.0 – 1.0
#   AudioManager.set_muted("weapons", true)
#   AudioManager.get_volume("sfx")              # → float
#   AudioManager.is_muted("ui")                 # → bool
extends Node

# ─────────────────────────────────────────────────────────────────────────────
# KONFIGURATION – Bus-Namen müssen exakt mit dem Audio-Editor übereinstimmen
# ─────────────────────────────────────────────────────────────────────────────

## Alle Audio-Kategorien.
## key       = interner Name (wird in Save-Datei und API verwendet)
## bus       = Name des Godot-Audio-Buses (muss im Audio-Editor angelegt sein)
## volume    = Standardlautstärke 0.0–1.0
## muted     = Standard-Mute-Status
const CATEGORIES: Dictionary = {
	"master":     {"bus": "Master",     "volume": 1.0,  "muted": false},
	"music":      {"bus": "Music",      "volume": 0.8,  "muted": false},
	"sfx":        {"bus": "SFX",        "volume": 1.0,  "muted": false},
	"weapons":    {"bus": "Weapons",    "volume": 1.0,  "muted": false},
	"explosions": {"bus": "Explosions", "volume": 1.0,  "muted": false},
	"ui":         {"bus": "UI",         "volume": 0.9,  "muted": false},
}

const SAVE_PATH: String = "user://audio_settings.cfg"

# Laufende Werte – werden beim Start aus Datei geladen oder auf CATEGORIES-Defaults gesetzt
var _volumes: Dictionary = {}
var _muted:   Dictionary = {}


# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Defaults aus CATEGORIES laden
	for key in CATEGORIES:
		_volumes[key] = CATEGORIES[key]["volume"]
		_muted[key]   = CATEGORIES[key]["muted"]

	# Gespeicherte Einstellungen laden (überschreibt Defaults)
	_load_settings()

	# Alle Buses auf die geladenen Werte setzen
	_apply_all()

	print("[AudioManager] Bereit | Kategorien: %s" % str(CATEGORIES.keys()))


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Setzt die Lautstärke einer Kategorie (0.0 = still, 1.0 = voll).
func set_volume(category: String, value: float) -> void:
	if not _volumes.has(category):
		push_warning("[AudioManager] Unbekannte Kategorie: '%s'" % category)
		return
	_volumes[category] = clampf(value, 0.0, 1.0)
	_apply_bus(category)
	_save_settings()


## Gibt die aktuelle Lautstärke einer Kategorie zurück (0.0–1.0).
func get_volume(category: String) -> float:
	return _volumes.get(category, 1.0)


## Setzt den Mute-Status einer Kategorie.
func set_muted(category: String, muted: bool) -> void:
	if not _muted.has(category):
		push_warning("[AudioManager] Unbekannte Kategorie: '%s'" % category)
		return
	_muted[category] = muted
	_apply_bus(category)
	_save_settings()


## Gibt zurück ob eine Kategorie gemutet ist.
func is_muted(category: String) -> bool:
	return _muted.get(category, false)


## Schaltet den Mute-Status einer Kategorie um.
func toggle_muted(category: String) -> void:
	set_muted(category, not is_muted(category))


## Alle Einstellungen auf Defaults zurücksetzen.
func reset_to_defaults() -> void:
	for key in CATEGORIES:
		_volumes[key] = CATEGORIES[key]["volume"]
		_muted[key]   = CATEGORIES[key]["muted"]
	_apply_all()
	_save_settings()
	print("[AudioManager] Einstellungen zurückgesetzt")


## Gibt alle Kategorien-Namen zurück (für UI-Aufbau).
func get_categories() -> Array:
	return CATEGORIES.keys()


# ─────────────────────────────────────────────────────────────────────────────
# BUS-STEUERUNG
# ─────────────────────────────────────────────────────────────────────────────

func _apply_all() -> void:
	for key in CATEGORIES:
		_apply_bus(key)


func _apply_bus(category: String) -> void:
	var bus_name: String = CATEGORIES[category]["bus"]
	var bus_idx:  int    = AudioServer.get_bus_index(bus_name)

	if bus_idx < 0:
		push_warning("[AudioManager] Bus '%s' nicht gefunden! Im Audio-Editor anlegen." % bus_name)
		return

	# Lautstärke: 0.0 → -80 dB (praktisch still), 1.0 → 0 dB (voll)
	var volume_db: float = linear_to_db(_volumes[category])
	AudioServer.set_bus_volume_db(bus_idx, volume_db)
	AudioServer.set_bus_mute(bus_idx, _muted[category])


# ─────────────────────────────────────────────────────────────────────────────
# SAVE / LOAD
# ─────────────────────────────────────────────────────────────────────────────

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in CATEGORIES:
		cfg.set_value("volume", key, _volumes[key])
		cfg.set_value("muted",  key, _muted[key])
	var err: int = cfg.save(SAVE_PATH)
	if err != OK:
		push_warning("[AudioManager] Speichern fehlgeschlagen: %d" % err)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	var err: int = cfg.load(SAVE_PATH)
	if err != OK:
		print("[AudioManager] Keine gespeicherten Einstellungen gefunden – Defaults werden verwendet")
		return

	for key in CATEGORIES:
		if cfg.has_section_key("volume", key):
			_volumes[key] = cfg.get_value("volume", key, _volumes[key])
		if cfg.has_section_key("muted", key):
			_muted[key]   = cfg.get_value("muted",  key, _muted[key])

	print("[AudioManager] Einstellungen geladen aus: %s" % SAVE_PATH)
