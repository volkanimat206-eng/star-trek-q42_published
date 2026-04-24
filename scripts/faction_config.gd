# res://scripts/systems/faction_config.gd
#
# Container-Resource mit der kompletten Beziehungstabelle.
# Wird als .tres-Datei gespeichert (z.B. res://data/factions/default_relations.tres)
# und ist dort im Inspector editierbar.
#
# WORKFLOW:
#   1. Im Editor:  FileSystem-Dock → Rechtsklick → "New Resource..."
#      → "FactionConfig" wählen → speichern als default_relations.tres
#   2. Doppelklick auf die .tres → Inspector zeigt den Array
#   3. Mit [+]-Button neue FactionRelation-Einträge anlegen
#
# LOOKUP-VERHALTEN:
#   - Nicht aufgeführte Paare gelten als NEUTRAL (kein hostile).
#   - Expliziter Eintrag mit is_hostile=false überschreibt ggf. Legacy-Defaults.

extends Resource
class_name FactionConfig

## Alle Beziehungspaare. Nur aufführen was nicht neutral ist.
## Symmetrisch: (KLINGON, FEDERATION) deckt auch (FEDERATION, KLINGON) ab.
@export var relations: Array[FactionRelation] = []


# ─────────────────────────────────────────────────────────────────────────────
# LOOKUP-API – wird vom FactionSystem-Autoload aufgerufen
# ─────────────────────────────────────────────────────────────────────────────

## true wenn die Fraktionen (a, b) als HOSTILE konfiguriert sind.
## Gibt false zurück bei: keinem Treffer, gleicher Fraktion, oder expliziten
## neutral-Einträgen (is_hostile=false).
func is_faction_pair_hostile(a: int, b: int) -> bool:
	if a == b:
		return false
	for rel in relations:
		if rel and rel.matches(a, b):
			return rel.is_hostile
	return false


## Alle Beziehungen einer bestimmten Fraktion – für Debug-Panel-Matrix.
## Liefert Dict { other_faction_id: is_hostile_bool }
func get_relations_of(faction: int) -> Dictionary:
	var result: Dictionary = {}
	for rel in relations:
		if not rel:
			continue
		if rel.faction_a == faction:
			result[rel.faction_b] = rel.is_hostile
		elif rel.faction_b == faction:
			result[rel.faction_a] = rel.is_hostile
	return result


## Diagnose-Ausgabe für den Output-Tab beim Start.
func describe_all() -> String:
	if relations.is_empty():
		return "(keine Beziehungen definiert – alle Paare gelten als NEUTRAL)"
	var lines: Array[String] = []
	for rel in relations:
		if rel:
			lines.append("  " + rel.describe())
	return "\n".join(lines)


# ─────────────────────────────────────────────────────────────────────────────
# EDITOR-HELFER – Konsistenz-Prüfung
# ─────────────────────────────────────────────────────────────────────────────

## Meldet doppelte Einträge und Einträge mit faction_a == faction_b.
## Aufrufen z.B. aus FactionSystem._ready().
func validate() -> Array[String]:
	var warnings: Array[String] = []
	for i in range(relations.size()):
		var r := relations[i]
		if not r:
			warnings.append("Index %d: Eintrag ist NULL" % i)
			continue
		if r.faction_a == r.faction_b:
			warnings.append("Index %d: faction_a == faction_b (%s)" % [
				i, ShipData.Faction.keys()[r.faction_a]])
		# Duplikat-Check gegen alle vorherigen
		for j in range(i):
			var other := relations[j]
			if other and other.matches(r.faction_a, r.faction_b):
				warnings.append("Index %d dupliziert Index %d: %s" % [
					i, j, r.describe()])
				break
	return warnings
