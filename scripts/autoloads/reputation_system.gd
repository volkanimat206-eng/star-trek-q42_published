# res://autoloads/reputation_system.gd
# Singleton (Autoload) – Ruf des Spielers bei jeder Fraktion.
# In Project Settings → Autoload als "ReputationSystem" eintragen.
#
# VERWENDUNG:
#   ReputationSystem.get_standing(ShipData.Faction.KLINGON)         → -40.0
#   ReputationSystem.get_disposition(ShipData.Faction.KLINGON)      → Disposition.HOSTILE
#   ReputationSystem.is_hostile_to_player(ShipData.Faction.KLINGON) → true
#   ReputationSystem.on_player_attacked_ship(faction, damage)        → Ruf senken
#   ReputationSystem.on_player_killed_ship(faction)                  → Ruf stark senken
#
# ABLAUF neutrales Schiff:
#   1. Spieler feuert auf neutrales Schiff
#   2. Waffe ruft on_player_attacked_ship(faction, damage) auf
#   3. Ruf sinkt → ggf. Disposition → HOSTILE
#   4. AIController scannt periodisch und findet Spieler jetzt als feindlich
#   5. Kampf beginnt

extends Node

# ─────────────────────────────────────────────────────────────────────────────
# ENUMS
# ─────────────────────────────────────────────────────────────────────────────

enum Disposition {
	FRIENDLY,  ## Ruf > FRIENDLY_THRESHOLD  → keine Feindseligkeit
	NEUTRAL,   ## Ruf zwischen den Schwellen → kein Angriff, aber auch keine Hilfe
	HOSTILE,   ## Ruf < HOSTILE_THRESHOLD   → Fraktion greift Spieler aktiv an
}

# ─────────────────────────────────────────────────────────────────────────────
# KONSTANTEN
# ─────────────────────────────────────────────────────────────────────────────

## Unter diesem Wert gilt die Fraktion als feindlich gegenüber dem Spieler.
const HOSTILE_THRESHOLD:  float = -25.0
## Über diesem Wert gilt die Fraktion als freundlich.
const FRIENDLY_THRESHOLD: float =  25.0

const STANDING_MIN: float = -100.0
const STANDING_MAX: float =  100.0

## Rufverlust pro Treffer-Event (nicht pro Schadenspunkt – sonst Beamwaffen OP).
const PENALTY_ATTACK_EVENT: float = -8.0
## Rufverlust wenn ein Schiff vernichtet wird.
const PENALTY_KILL:         float = -35.0
## Rufgewinn durch positive Aktionen (Hilfe, Handel, Quests).
const BONUS_ASSIST:         float =  10.0

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

## Feuert bei jeder Rufänderung – auch kleinen.
signal standing_changed(faction: ShipData.Faction, old_val: float, new_val: float)
## Feuert NUR wenn sich NEUTRAL↔HOSTILE↔FRIENDLY ändert – ideal für UI/KI-Reaktion.
signal disposition_changed(faction: ShipData.Faction, old_disp: Disposition, new_disp: Disposition)

# ─────────────────────────────────────────────────────────────────────────────
# STATE
# ─────────────────────────────────────────────────────────────────────────────

# Internes Dict: ShipData.Faction (int) → float
# Nicht typisiert weil GDScript Enum-Keys in Dicts als int behandelt.
var _standings: Dictionary = {}

# Throttle: verhindert dass Beam-Waffen dutzende Events/Sekunde senden.
# Pro Fraktion: Sekunden bis zum nächsten erlaubten Penalty-Event.
var _attack_cooldowns: Dictionary = {}
const ATTACK_COOLDOWN_SEC: float = 0.5


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_init_standings()


func _process(delta: float) -> void:
	# Cooldown-Timer herunterzählen
	for key in _attack_cooldowns.keys():
		_attack_cooldowns[key] = max(0.0, _attack_cooldowns[key] - delta)


func _init_standings() -> void:
	# Alle Fraktionen auf 0 (neutral) initialisieren
	for f: int in ShipData.Faction.values():
		_standings[f]         = 0.0
		_attack_cooldowns[f]  = 0.0

	# Startwerte: Föderationsverbündete positiv, Kriegsgegner bereits negativ
	_standings[ShipData.Faction.FEDERATION] =  75.0   # Spieler IST Federation
	_standings[ShipData.Faction.KLINGON]    = -60.0   # Krieg
	_standings[ShipData.Faction.ROMULAN]    = -50.0   # Krieg
	_standings[ShipData.Faction.CARDASSIAN] = -40.0   # Krieg
	_standings[ShipData.Faction.DOMINION]   = -80.0   # Krieg
	_standings[ShipData.Faction.BORG]       = -100.0  # absolut feindlich
	_standings[ShipData.Faction.MAQUIS]     = -30.0   # Krieg
	_standings[ShipData.Faction.FERENGI]    =  5.0    # neutral, leicht positiv


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – ABFRAGEN
# ─────────────────────────────────────────────────────────────────────────────

func get_standing(faction: ShipData.Faction) -> float:
	return _standings.get(int(faction), 0.0)


func get_disposition(faction: ShipData.Faction) -> Disposition:
	var s: float = get_standing(faction)
	if s <= HOSTILE_THRESHOLD:
		return Disposition.HOSTILE
	if s >= FRIENDLY_THRESHOLD:
		return Disposition.FRIENDLY
	return Disposition.NEUTRAL

# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – FEINDSCHAFT ZWISCHEN ZWEI FRAKTIONEN
# ─────────────────────────────────────────────────────────────────────────────

## Gibt die Disposition von faction_a gegenüber faction_b zurück.
## faction_a = "wer schaut" (die aktive Partei)
## faction_b = "wen schaut man an" (die Ziel-Partei)
##
## Beispiel: get_disposition_between(KLINGON, FEDERATION)
##   → Wie sieht der KLINGON die FÖDERATION? (HOSTILE)
##
## Verwendung in AIController: 
##   get_disposition_between(meine_fraktion, andere_fraktion)
##
## WICHTIG: Ruf ist NICHT symmetrisch!
##   - Föderation sieht Ferengi als FREUNDLICH (+5)
##   - Ferengi sehen Föderation als NEUTRAL (0) weil sie anders rechnen
func get_disposition_between(faction_a: ShipData.Faction, faction_b: ShipData.Faction) -> Disposition:
	# Fallback: Bei gleicher Fraktion immer FRIENDLY
	if faction_a == faction_b:
		return Disposition.FRIENDLY
	
	var standing := get_standing_between(faction_a, faction_b)
	
	if standing <= HOSTILE_THRESHOLD:
		return Disposition.HOSTILE
	if standing >= FRIENDLY_THRESHOLD:
		return Disposition.FRIENDLY
	return Disposition.NEUTRAL


## Gibt den numerischen Ruf-Wert von faction_a gegenüber faction_b zurück.
## faction_a = "wer schaut" (die aktive Partei)
## faction_b = "wen schaut man an" (die Ziel-Partei)
##
## Standard-Implementierung: Der Ruf ist SYMMETRISCH (faction_a sieht faction_b
## genauso wie faction_b sieht faction_a).
## Falls du asymmetrische Rufsysteme brauchst (z.B. Cardassianer hassen Bajoraner
## mehr als umgekehrt), überschreibe diese Funktion.
func get_standing_between(faction_a: ShipData.Faction, faction_b: ShipData.Faction) -> float:
	# Standard: Ruf ist symmetrisch – wir verwenden den Ruf von faction_b
	# (weil der Spieler-Ruf die Basis ist)
	#
	# Logik: faction_a sieht faction_b genauso wie faction_b sich gegenüber
	# dem Spieler verhält? Nicht ganz korrekt, aber für 99% der Fälle ausreichend.
	#
	# Für perfekte Asymmetrie müsstest du ein 2D-Array führen:
	# _standings_between[faction_a][faction_b]
	
	# Vereinfachung: Verwende den Ruf-Wert der ZIEL-Fraktion (faction_b)
	# Das bedeutet: Wie faction_b vom Spieler gesehen wird = wie alle anderen
	# faction_b sehen.
	return get_standing(faction_b)


## Prüft ob faction_a faction_b als feindlich betrachtet.
## Das ist die Funktion die AIController braucht!
func is_hostile_between(faction_a: ShipData.Faction, faction_b: ShipData.Faction) -> bool:
	return get_disposition_between(faction_a, faction_b) == Disposition.HOSTILE


## Prüft ob faction_a faction_b als freundlich betrachtet.
func is_friendly_between(faction_a: ShipData.Faction, faction_b: ShipData.Faction) -> bool:
	return get_disposition_between(faction_a, faction_b) == Disposition.FRIENDLY


## Prüft ob faction_a faction_b als neutral betrachtet.
func is_neutral_between(faction_a: ShipData.Faction, faction_b: ShipData.Faction) -> bool:
	return get_disposition_between(faction_a, faction_b) == Disposition.NEUTRAL

## Gibt true zurück wenn diese Fraktion den Spieler aktiv bekämpft.
## Wird von FactionSystem und AIController aufgerufen.
func is_hostile_to_player(faction: ShipData.Faction) -> bool:
	return get_disposition(faction) == Disposition.HOSTILE


func is_neutral_to_player(faction: ShipData.Faction) -> bool:
	return get_disposition(faction) == Disposition.NEUTRAL


func is_friendly_to_player(faction: ShipData.Faction) -> bool:
	return get_disposition(faction) == Disposition.FRIENDLY


## Gibt alle Fraktionen zurück die gerade feindlich sind.
func get_all_hostile_factions() -> Array[ShipData.Faction]:
	var result: Array[ShipData.Faction] = []
	for f: int in _standings.keys():
		if is_hostile_to_player(f as ShipData.Faction):
			result.append(f as ShipData.Faction)
	return result


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – EREIGNISSE (werden von Waffen/Schiffen aufgerufen)
# ─────────────────────────────────────────────────────────────────────────────

## Spieler hat ein Schiff der Fraktion getroffen.
## Throttled – mehrfache Aufrufe pro Frame werden ignoriert.
func on_player_attacked_ship(faction: ShipData.Faction) -> void:
	if _attack_cooldowns.get(int(faction), 0.0) > 0.0:
		return
	_attack_cooldowns[int(faction)] = ATTACK_COOLDOWN_SEC
	modify_standing(faction, PENALTY_ATTACK_EVENT)


## Spieler hat ein Schiff der Fraktion zerstört.
func on_player_killed_ship(faction: ShipData.Faction) -> void:
	modify_standing(faction, PENALTY_KILL)


## Spieler hat einer Fraktion geholfen (Quest, Begleitung, Handel).
func on_player_helped_faction(faction: ShipData.Faction, bonus: float = BONUS_ASSIST) -> void:
	modify_standing(faction, bonus)


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – DIREKTE MANIPULATION
# ─────────────────────────────────────────────────────────────────────────────

## Ruf direkt verändern – für Quests, Events, Cheat-Konsole.
func modify_standing(faction: ShipData.Faction, delta: float) -> void:
	var old_val:  float       = get_standing(faction)
	var old_disp: Disposition = get_disposition(faction)

	_standings[int(faction)] = clamp(old_val + delta, STANDING_MIN, STANDING_MAX)

	var new_val:  float       = get_standing(faction)
	var new_disp: Disposition = get_disposition(faction)

	if not is_equal_approx(old_val, new_val):
		standing_changed.emit(faction, old_val, new_val)

	if old_disp != new_disp:
		disposition_changed.emit(faction, old_disp, new_disp)
		_log("⚠ Disposition geändert: %s → %s → %s" % [
			ShipData.Faction.keys()[faction],
			Disposition.keys()[old_disp],
			Disposition.keys()[new_disp]
		])


## Ruf direkt setzen (z.B. beim Laden eines Spielstands).
func set_standing(faction: ShipData.Faction, value: float) -> void:
	var old_disp: Disposition = get_disposition(faction)
	_standings[int(faction)]  = clamp(value, STANDING_MIN, STANDING_MAX)
	var new_disp: Disposition = get_disposition(faction)
	if old_disp != new_disp:
		disposition_changed.emit(faction, old_disp, new_disp)


## Alle Rufwerte zurücksetzen (Spielstart / Neustart).
func reset() -> void:
	_init_standings()
	_log("🔄 Rufwerte zurückgesetzt")


# ─────────────────────────────────────────────────────────────────────────────
# DEBUG
# ─────────────────────────────────────────────────────────────────────────────

func print_all_standings() -> void:
	print("\n[ReputationSystem] ══════ RUFWERTE ══════")
	for f: int in _standings.keys():
		var faction := f as ShipData.Faction
		print("  %-12s : %+6.1f  [%s]" % [
			ShipData.Faction.keys()[faction],
			get_standing(faction),
			Disposition.keys()[get_disposition(faction)]
		])
	print("[ReputationSystem] ════════════════════════\n")


func _log(msg: String) -> void:
	print("[ReputationSystem] %s" % msg)
