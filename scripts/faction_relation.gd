# res://scripts/systems/faction_relation.gd
#
# Einzelner Beziehungs-Eintrag zwischen zwei Fraktionen.
# Wird als Array-Element in FactionConfig.relations verwendet.
#
# Im Inspector:
#   Faction A      [Dropdown: FEDERATION / KLINGON / ROMULAN / ...]
#   Faction B      [Dropdown: FEDERATION / KLINGON / ROMULAN / ...]
#   Is Hostile     [✓]  ← true = feindlich, false = explizit neutral
#
# Beziehungen sind symmetrisch: wer (A, B) als hostile definiert,
# definiert implizit auch (B, A) als hostile.

extends Resource
class_name FactionRelation

## Die beiden beteiligten Fraktionen – Reihenfolge egal, Beziehung ist symmetrisch.
@export var faction_a: ShipData.Faction = ShipData.Faction.FEDERATION
@export var faction_b: ShipData.Faction = ShipData.Faction.KLINGON

## true  → diese beiden Fraktionen sind baseline HOSTILE.
## false → explizit NEUTRAL (überschreibt z.B. einen Default-hostile-Zustand).
## Tipp: In 90 % der Fälle willst du hier true. Das Feld existiert damit du
## Waffenstillstands-Szenarien deklarieren kannst ohne Paare zu löschen.
@export var is_hostile: bool = true

## Optionale Notiz – rein für Lesbarkeit im Inspector.
@export_multiline var note: String = ""


## true wenn dieses Paar die Fraktionen (a, b) in IRGENDEINER Reihenfolge abdeckt.
func matches(a: int, b: int) -> bool:
	return (faction_a == a and faction_b == b) \
		or (faction_a == b and faction_b == a)


func describe() -> String:
	var sym: String = "↔ HOSTILE" if is_hostile else "↔ neutral"
	return "%s %s %s" % [
		ShipData.Faction.keys()[faction_a],
		sym,
		ShipData.Faction.keys()[faction_b]
	]
