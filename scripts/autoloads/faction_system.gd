# res://scripts/faction_system.gd
#
# Autoload-Singleton (SCENE-Autoload!): Zentrale Anlaufstelle für alle
# Fraktions-Logik.
#
# ─────────────────────────────────────────────────────────────────────────────
# WICHTIG: Als SCENE-Autoload registrieren, nicht als Script-Autoload!
#
# WARUM:
#   @export-Felder sind nur in Scene-Autoloads im Inspector editierbar.
#   Bei reinen Script-Autoloads gibt es keine Inspector-Ansicht.
#
# SETUP (einmalig):
#   1. Scene erstellen: res://scripts/faction_system.tscn
#        Root-Node: Node → Script anhängen: dieses (faction_system.gd)
#        Im Inspector: "Configuration" → config-Slot → Drag & Drop der
#        FactionConfig-Resource (.tres).
#   2. Project Settings → AutoLoad:
#        Alten Script-Autoload "FactionSystem" entfernen.
#        Neuen Eintrag anlegen: Name="FactionSystem",
#        Path=res://scripts/faction_system.tscn
#
# AUTOLOAD-REIHENFOLGE:
#   1. ReputationSystem        ← MUSS zuerst kommen
#   2. FactionSystem           ← referenziert ReputationSystem
#   3. RelationshipResolver    ← referenziert FactionSystem
#   4. DebugManager
# ─────────────────────────────────────────────────────────────────────────────
#
# ARCHITEKTUR (AAA-Refactor):
#   FactionSystem         = DATENSCHICHT + simple Lookups
#                           → hält FactionConfig (@export)
#                           → is_faction_pair_hostile(), get_group_name()
#                           → Live-Persistenz via set_faction_pair_hostile()
#                           → get_cloak_visuals(faction) für Cloak-Shader
#
#   RelationshipResolver  = POLICY-SCHICHT (Zwei-Ebenen-Logik)
#                           → are_hostile(nodes) mit Rep-Override + Aggro
#
# Alt-API (are_hostile(nodes) mit Zwei-Kanal-Logik) bleibt byte-identisch.
# ─────────────────────────────────────────────────────────────────────────────

extends Node

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

## Wird gefeuert wenn eine Fraktions-Beziehung zur Laufzeit geändert wird
## (z.B. über das Debug-Panel). Hörer: Resolver-Cache, Panel-Refresh.
signal faction_relation_changed(faction_a: int, faction_b: int, is_hostile: bool)


# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS (im Inspector editierbar – nur sichtbar bei Scene-Autoload!)
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Configuration")

## Beziehungstabelle zwischen Fraktionen.
## Im Inspector eine FactionConfig-Resource (.tres) zuweisen.
## Wenn nichts zugewiesen: In-Memory-Fallback aus _HOSTILE_PAIRS_SEED (keine
## Persistenz möglich – für Produktiv-Setup eine .tres anlegen und zuweisen).
@export var config: FactionConfig


# ─────────────────────────────────────────────────────────────────────────────
# DEBUG
# ─────────────────────────────────────────────────────────────────────────────

var debug_hostile: bool = false   ## "ai.faction_hostile"
var debug_faction: bool = false   ## "ai.faction_lookup"
## Einmalige Warning-Sperre für RelationshipResolver-Lookup
var _resolver_missing_warned: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# KONSTANTEN
# ─────────────────────────────────────────────────────────────────────────────

const GROUP_PREFIX: String = "faction_"
const GROUP_SHIPS:  String = "ships"
const GROUP_PLAYER: String = "player"

## Seed-Daten für den In-Memory-Fallback wenn keine Config zugewiesen ist.
## Identisch zu den ursprünglichen hardcoded _HOSTILE_PAIRS.
## Sobald du eine FactionConfig zuweist, wird dieser Array ignoriert.
const _HOSTILE_PAIRS_SEED: Array[Array] = [
	[ShipData.Faction.KLINGON,   ShipData.Faction.FEDERATION],
	[ShipData.Faction.ROMULAN,   ShipData.Faction.FEDERATION],
	[ShipData.Faction.KLINGON,   ShipData.Faction.ROMULAN],
]

const PLAYER_FACTIONS: Array[int] = [
	ShipData.Faction.FEDERATION as int,
]


# ─────────────────────────────────────────────────────────────────────────────
# CLOAK-VISUAL-DEFAULTS (per-Faction)
# ─────────────────────────────────────────────────────────────────────────────
# Predator-Style subtile Defaults. Werden vom CloakComponent über
# get_cloak_visuals() abgefragt. CloakData.tres kann pro Schiff überschreiben.
#
# Tuning-Hinweise:
#   rim_color    — Farbe des Silhouetten-Schimmers. Subtil halten,
#                  zu intensive Farben wirken in 2.5D-Iso comicartig.
#   displacement_strength — Vertex-Versatz in Welt-Units. 0.03–0.05 ist
#                  Predator-Bereich; alles über 0.08 wirkt zu sehr nach
#                  "Geist-Mesh".
#
# Erweiterbar: weitere Fraktionen einfach als neuen Eintrag hinzufügen.
# Unbekannte Fraktion → _CLOAK_VISUALS_DEFAULT (icy blue, neutral).
const _CLOAK_VISUALS: Dictionary = {
	ShipData.Faction.KLINGON: {
		"rim_color":             Color(0.50, 0.65, 0.95),  # kühles Blau-Violett
		"displacement_strength": 0.05,                      # härter, marginal stärker
	},
	ShipData.Faction.ROMULAN: {
		"rim_color":             Color(0.45, 0.85, 0.75),  # türkis-grün (canon)
		"displacement_strength": 0.04,                      # weicher als Klingon
	},
	ShipData.Faction.FEDERATION: {
		"rim_color":             Color(0.85, 0.75, 0.50),  # bernstein-amber
		"displacement_strength": 0.05,
	},
}

const _CLOAK_VISUALS_DEFAULT: Dictionary = {
	"rim_color":             Color(0.4, 0.75, 1.0),         # icy blue (Shader-Default)
	"displacement_strength": 0.04,
}


# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_ensure_config()

	if Engine.has_singleton("DebugManager"):
		DebugManager.register(self, "ai.faction_hostile", "debug_hostile")
		DebugManager.register(self, "ai.faction_lookup", "debug_faction")


# ─────────────────────────────────────────────────────────────────────────────
# CONFIG – LOAD / SAVE / RELOAD
# ─────────────────────────────────────────────────────────────────────────────

func _ensure_config() -> void:
	if config:
		var warnings: Array[String] = config.validate()
		for w in warnings:
			push_warning("[FactionSystem] Config-Warnung: %s" % w)
		var path_str: String = config.resource_path if not config.resource_path.is_empty() else "<in-memory, nicht gespeichert>"
		print("[FactionSystem] ✓ Config zugewiesen: %s" % path_str)
		if not config.relations.is_empty():
			print("[FactionSystem] Beziehungen:\n%s" % config.describe_all())
		return

	# Kein Config im Inspector → In-Memory-Fallback aus Seed
	push_warning("[FactionSystem] ⚠ Kein 'config' im Inspector zugewiesen. Läuft mit In-Memory-Seed (keine Persistenz). Für Produktiv-Setup: FactionConfig-.tres anlegen und im Inspector zuweisen.")
	config = FactionConfig.new()
	for pair in _HOSTILE_PAIRS_SEED:
		var rel := FactionRelation.new()
		rel.faction_a  = pair[0]
		rel.faction_b  = pair[1]
		rel.is_hostile = true
		config.relations.append(rel)
	print("[FactionSystem] In-Memory-Seed erzeugt:\n%s" % config.describe_all())


## Schreibt die aktuelle Config zurück auf Disk.
## Voraussetzung: config wurde im Inspector aus einer .tres zugewiesen
## (damit resource_path gesetzt ist).
func save_config() -> bool:
	if not config:
		push_warning("[FactionSystem] save_config: keine Config")
		return false
	if config.resource_path.is_empty():
		push_warning("[FactionSystem] save_config: Config hat keinen resource_path (In-Memory-Fallback oder unsaved). Lege eine .tres an und weise sie im Inspector zu.")
		return false
	var err: int = ResourceSaver.save(config, config.resource_path)
	if err == OK:
		if debug_faction:
			print("[FactionSystem] ✓ Config persistiert: %s" % config.resource_path)
		return true
	push_warning("[FactionSystem] ResourceSaver.save failed: err=%d (%s)" % [err, config.resource_path])
	return false


## Lädt die Config neu von Disk (verwirft ungesaveste In-Memory-Änderungen).
func reload_config() -> void:
	if not config or config.resource_path.is_empty():
		push_warning("[FactionSystem] reload_config: keine .tres-gebundene Config vorhanden")
		return
	var path: String = config.resource_path
	var fresh: FactionConfig = load(path) as FactionConfig
	if fresh:
		config = fresh
		print("[FactionSystem] ↻ Config neu geladen: %s" % path)
	else:
		push_warning("[FactionSystem] reload_config: load() failed für %s" % path)


func get_config() -> FactionConfig:
	return config


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – Gruppen-Namen (unverändert)
# ─────────────────────────────────────────────────────────────────────────────

func get_group_name(faction: ShipData.Faction) -> String:
	return GROUP_PREFIX + ShipData.Faction.keys()[faction]


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – Cloak-Visuals (Default-Look pro Faction)
# ─────────────────────────────────────────────────────────────────────────────

## Liefert die Cloak-Visual-Defaults für eine Fraktion. Vom CloakComponent
## während _initialize_distortion() aufgerufen, danach mit CloakData-Overrides
## gemergt und an den Shader weitergereicht.
##
## Returns Dictionary mit Keys:
##   "rim_color"             : Color    — Silhouetten-Schimmer
##   "displacement_strength" : float    — Vertex-Versatz (Welt-Units)
##
## Unbekannte Fraktion → neutraler Default (icy blue).
## Returns IMMER eine Kopie — Aufrufer dürfen sie modifizieren ohne die
## Const-Konstante zu beeinflussen.
func get_cloak_visuals(faction: int) -> Dictionary:
	if faction in _CLOAK_VISUALS:
		return (_CLOAK_VISUALS[faction] as Dictionary).duplicate()
	return _CLOAK_VISUALS_DEFAULT.duplicate()


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – Statische Paar-Prüfung
# ─────────────────────────────────────────────────────────────────────────────

## Statische Paar-Prüfung auf Fraktions-Enum-Ebene.
## Ohne Reputation, ohne Player-Sonderbehandlung. Baseline-Wahrheit für die Welt.
func is_faction_pair_hostile(a: int, b: int) -> bool:
	if a == b:
		return false

	if config:
		return config.is_faction_pair_hostile(a, b)

	# Notfall-Fallback (_ensure_config hätte das bereits behandelt)
	for pair in _HOSTILE_PAIRS_SEED:
		if (pair[0] == a and pair[1] == b) or (pair[0] == b and pair[1] == a):
			return true
	return false


## Alt-Name – bleibt als Alias für Rückwärtskompatibilität.
func is_hostile(faction_a: ShipData.Faction, faction_b: ShipData.Faction) -> bool:
	return is_faction_pair_hostile(int(faction_a), int(faction_b))


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – Paar-Beziehung SETZEN (für Debug-Live-Editor)
# ─────────────────────────────────────────────────────────────────────────────

## Setzt eine Fraktionsbeziehung und persistiert die Config auf Disk.
## Wirkt sofort im Speicher, ResourceSaver-Failure bricht In-Memory-Teil NICHT ab.
## Feuert faction_relation_changed-Signal zum Cache-Invalidieren.
func set_faction_pair_hostile(faction_a: int, faction_b: int, hostile: bool) -> void:
	if faction_a == faction_b:
		push_warning("[FactionSystem] set_faction_pair_hostile: faction_a == faction_b – ignoriert")
		return
	if not config:
		push_warning("[FactionSystem] set_faction_pair_hostile: keine Config geladen")
		return

	# Vorhandenen Eintrag updaten
	var found: bool = false
	for rel in config.relations:
		if rel and rel.matches(faction_a, faction_b):
			if rel.is_hostile == hostile:
				return   # kein Change → kein Signal
			rel.is_hostile = hostile
			found = true
			break

	# Oder neu anlegen
	if not found:
		var new_rel := FactionRelation.new()
		new_rel.faction_a  = faction_a as ShipData.Faction
		new_rel.faction_b  = faction_b as ShipData.Faction
		new_rel.is_hostile = hostile
		config.relations.append(new_rel)

	# Persistieren (Fehlschlag nicht kritisch im Runtime)
	save_config()

	faction_relation_changed.emit(faction_a, faction_b, hostile)
	if debug_hostile:
		print("[FactionSystem] %s ↔ %s → %s" % [
			ShipData.Faction.keys()[faction_a],
			ShipData.Faction.keys()[faction_b],
			"HOSTILE" if hostile else "neutral"
		])


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – Player-Spezifische Prüfung (Zwei-Kanal-Logik) – UNVERÄNDERT
# ─────────────────────────────────────────────────────────────────────────────

## Ist die gegebene Fraktion dem Spieler gegenüber feindlich?
## Rein über ReputationSystem – statische Pairs werden IGNORIERT.
func is_hostile_to_player(faction: ShipData.Faction) -> bool:
	if int(faction) in PLAYER_FACTIONS:
		return false
	var disp: ReputationSystem.Disposition = ReputationSystem.get_disposition(faction)
	return disp == ReputationSystem.Disposition.HOSTILE


## HAUPT-Feindprüfung (Alt-API, byte-identisch zur Vorversion).
## ⚠ Neu migrierte Call-Sites sollten RelationshipResolver.are_hostile() nutzen.
func are_hostile(node_a: Node, node_b: Node) -> bool:
	var fa: int = get_faction_of(node_a)
	var fb: int = get_faction_of(node_b)

	var name_a: String = String(node_a.name) if is_instance_valid(node_a) else "NULL"
	var name_b: String = String(node_b.name) if is_instance_valid(node_b) else "NULL"

	if debug_hostile:
		var fa_str: String = ShipData.Faction.keys()[fa] if fa >= 0 and fa < ShipData.Faction.size() else str(fa)
		var fb_str: String = ShipData.Faction.keys()[fb] if fb >= 0 and fb < ShipData.Faction.size() else str(fb)
		print("[FactionSystem] are_hostile('%s'[%s], '%s'[%s])" % [name_a, fa_str, name_b, fb_str])

	if fa < 0 or fb < 0:
		if debug_hostile: print("[FactionSystem]   → FALSE: unbekannte Fraktion")
		return false
	if fa == fb:
		if debug_hostile: print("[FactionSystem]   → FALSE: gleiche Fraktion")
		return false

	# ─── AGGRO-OVERRIDE – vor allen anderen Checks ───
	# Wenn ein Schiff Aggro auf ein anderes hat (z.B. weil es angegriffen wurde
	# oder weil sein Ally angegriffen wurde), ist die Beziehung HOSTILE –
	# unabhängig von statischen Pairs oder Reputation.
	if _resolver_has_aggro(node_a, node_b):
		if debug_hostile: print("[FactionSystem]   → TRUE: Aggro-Override")
		return true

	# ─── KANAL A: Einer der beiden ist der SPIELER ───
	var a_is_player: bool = _is_player_node(node_a)
	var b_is_player: bool = _is_player_node(node_b)

	if a_is_player or b_is_player:
		# WICHTIG: Symmetrische Prüfung — beide Fraktionen werden berücksichtigt.
		# Frühere Version ignorierte die Spieler-Fraktion und nahm immer
		# Federation-Regeln an. Jetzt: is_faction_pair_hostile(fa, fb) prüft
		# die tatsächliche Konstellation, egal ob der Spieler Klingone spielt.
		var hostile: bool = is_faction_pair_hostile(fa, fb)

		if debug_hostile:
			var player_faction: int = fa if a_is_player else fb
			var npc_faction_dbg: int = fb if a_is_player else fa
			print("[FactionSystem]   → Player-Kanal: Spieler=%s vs NPC=%s → hostile=%s" % [
				ShipData.Faction.keys()[player_faction] if player_faction >= 0 else "?",
				ShipData.Faction.keys()[npc_faction_dbg] if npc_faction_dbg >= 0 else "?",
				hostile
			])
		return hostile

	# ─── KANAL B: Beide sind NPCs ───
	var static_result: bool = is_faction_pair_hostile(fa, fb)
	if debug_hostile:
		print("[FactionSystem]   → NPC-Kanal (static pair) → hostile=%s" % static_result)
	return static_result


## Prüft ob ein Node zum Spieler gehört. Läuft die Hierarchie hoch.
func _is_player_node(node: Node) -> bool:
	if not is_instance_valid(node):
		return false

	var current: Node = node
	while is_instance_valid(current):
		if current.is_in_group(GROUP_PLAYER):
			return true
		current = current.get_parent()

	if node is AIController:
		return false
	var f: int = get_faction_of(node)
	return f >= 0 and f in PLAYER_FACTIONS


## Defensiver Zugriff auf RelationshipResolver.has_aggro_between().
## Bleibt auch dann funktionsfähig wenn der Resolver (noch) nicht registriert ist.
func _resolver_has_aggro(a: Node, b: Node) -> bool:
	var resolver: Node = get_tree().root.get_node_or_null("RelationshipResolver")
	if not resolver:
		if not _resolver_missing_warned:
			_resolver_missing_warned = true
			push_warning("[FactionSystem] ⚠ RelationshipResolver-Autoload nicht gefunden – Aggro-System inaktiv. Prüfe Project Settings → AutoLoad.")
		return false
	if not resolver.has_method("has_aggro_between"):
		if not _resolver_missing_warned:
			_resolver_missing_warned = true
			push_warning("[FactionSystem] ⚠ RelationshipResolver kennt has_aggro_between() nicht – veraltete Version?")
		return false
	return resolver.has_aggro_between(a, b)


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC – Fraktion eines Nodes ermitteln (UNVERÄNDERT)
# ─────────────────────────────────────────────────────────────────────────────

func get_faction_of(node: Node) -> int:
	if not is_instance_valid(node):
		if debug_faction: print("[FactionSystem] get_faction_of(INVALID) → -1")
		return -1

	if node is AIController:
		var ai: AIController = node as AIController
		var result_ai: int = int(ai.ship_data.faction) if ai.ship_data else -1
		if debug_faction: print("[FactionSystem] get_faction_of('%s') → AI path: %d" % [node.name, result_ai])
		return result_ai

	var sc: ShipController = null
	if node is ShipController:
		sc = node as ShipController
	elif node.has_meta("ship_controller"):
		sc = node.get_meta("ship_controller") as ShipController
	else:
		for child in node.find_children("*", "ShipController", true, false):
			if child is ShipController:
				sc = child as ShipController
				break

	if sc and sc.ship_data:
		var result_sc: int = int(sc.ship_data.faction)
		if debug_faction: print("[FactionSystem] get_faction_of('%s') → SC path: %d" % [node.name, result_sc])
		return result_sc

	if debug_faction: print("[FactionSystem] get_faction_of('%s') → NOT FOUND" % node.name)
	return -1
