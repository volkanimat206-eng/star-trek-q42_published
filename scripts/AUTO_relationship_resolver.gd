# res://scripts/systems/relationship_resolver.gd
#
# SINGLE SOURCE OF TRUTH für "sind a und b feindlich?"
#
# Als Autoload registrieren:
#   Project Settings → AutoLoad → Name: "RelationshipResolver"
#   Path: res://scripts/systems/relationship_resolver.gd
#
# ─────────────────────────────────────────────────────────────────────────────
# TRENNUNG DER VERANTWORTLICHKEITEN
#
#   FactionSystem        statische Weltregeln  (KLINGON vs FEDERATION = HOSTILE)
#   ReputationSystem     dynamische Spieler-Ebene (-100..+100 pro Fraktion)
#   RelationshipResolver kombiniert beides und bietet DIE einzige API die der
#                        Rest des Spiels aufrufen sollte.
#
# Alle Call-Sites die bisher FactionSystem.are_hostile() nutzen sollen
# schrittweise auf RelationshipResolver.are_hostile() migrieren.
#
# REGELN
#   NPC vs NPC       → FactionSystem (statisch)
#   Player vs X      → baseline + Rep-Override + Aggro
#       rep ≥ +50    → FRIENDLY erzwungen (baseline überschrieben)
#       rep ≤ -50    → HOSTILE  erzwungen (baseline überschrieben)
#       sonst        → baseline aus FactionSystem
#       Aggro > 0    → IMMER HOSTILE (persönlicher Groll, läuft aus)
#
# ─────────────────────────────────────────────────────────────────────────────
extends Node

# ===== SIGNALS =====
## Wird gefeuert wenn sich eine Relation ÄNDERT (a und b sind jetzt feindlich
## wo sie eben noch nicht waren, oder umgekehrt). Nützlich für TargetingSystem
## um Multi-Locks live zu prunen ohne Polling.
signal relation_changed(a: Node3D, b: Node3D, is_hostile: bool)

# ===== KONSTANTEN =====
## Schwelle ab der Reputation die Baseline überschreibt (±).
const REP_OVERRIDE_THRESHOLD: float = 50.0

## Lebensdauer eines Aggro-Eintrags in Sekunden.
const AGGRO_DEFAULT_DURATION: float = 30.0

# ===== INTERN =====
## key: "observer_id->target_id"   value: expire_time_sec (msec/1000)
var _aggro_table: Dictionary = {}

## Cache-Invalidierung: gesetzte Relationen pro Frame mit Schlüssel id_a:id_b.
## Verhindert Signal-Spam bei häufigen Abfragen im selben Frame.
var _last_hostile_state: Dictionary = {}


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	# DebugManager-Flag registrieren falls noch nicht bekannt
	if Engine.has_singleton("DebugManager") or _has_debug_manager():
		if not DebugManager.get_all_flags().has("ai.resolver"):
			DebugManager.set_flag("ai.resolver", false)

	# Ruf-Änderungen → ggf. Relation-Change-Signal feuern
	if ReputationSystem.has_signal("standing_changed"):
		if not ReputationSystem.standing_changed.is_connected(_on_standing_changed):
			ReputationSystem.standing_changed.connect(_on_standing_changed)

	# Config-Änderungen (z.B. aus Debug-Panel-Live-Editor) → Cache invalidieren
	if FactionSystem.has_signal("faction_relation_changed"):
		if not FactionSystem.faction_relation_changed.is_connected(_on_faction_relation_changed):
			FactionSystem.faction_relation_changed.connect(_on_faction_relation_changed)

	_dbg("RelationshipResolver bereit · REP_OVERRIDE_THRESHOLD=%.0f · AGGRO_DURATION=%.0fs" \
		% [REP_OVERRIDE_THRESHOLD, AGGRO_DEFAULT_DURATION])


# ─────────────────────────────────────────────────────────────────────────────
# HAUPT-API – are_hostile(a, b)
# ─────────────────────────────────────────────────────────────────────────────

## Zentrale Entscheidungsfunktion. Symmetrisch: are_hostile(a, b) == are_hostile(b, a).
func are_hostile(a: Node3D, b: Node3D) -> bool:
	if not is_instance_valid(a) or not is_instance_valid(b):
		return false
	if a == b:
		return false

	var result: bool = _compute_hostile(a, b)

	# Relation-Change nur bei echter Änderung publizieren
	var key: String = _pair_key(a, b)
	var prev: Variant = _last_hostile_state.get(key)
	if prev == null or prev != result:
		_last_hostile_state[key] = result
		if prev != null:   # erste Abfrage nicht als "Änderung" werten
			relation_changed.emit(a, b, result)

	return result


func _compute_hostile(a: Node3D, b: Node3D) -> bool:
	var a_is_player: bool = _is_player(a)
	var b_is_player: bool = _is_player(b)

	# ── Aggro überschreibt alles andere (in BEIDE Richtungen prüfen) ────────
	if _has_aggro(a, b) or _has_aggro(b, a):
		_dbg("AGGRO → HOSTILE: %s ↔ %s" % [a.name, b.name])
		return true

	# ── NPC vs NPC: rein statisch aus FactionSystem ─────────────────────────
	if not a_is_player and not b_is_player:
		return _baseline_hostile(a, b)

	# ── Player involviert: baseline + Rep-Override ──────────────────────────
	var npc: Node3D = b if a_is_player else a
	var npc_faction_val: Variant = _get_faction(npc)
	if npc_faction_val == null:
		# Fallback: keine Fraktion bekannt → nur baseline
		return _baseline_hostile(a, b)

	var base: bool  = _baseline_hostile(a, b)
	var rep: float  = ReputationSystem.get_standing(npc_faction_val)

	if rep >= REP_OVERRIDE_THRESHOLD:
		_dbg("REP %.0f ≥ +%.0f → FRIENDLY override: player ↔ %s" \
			% [rep, REP_OVERRIDE_THRESHOLD, npc.name])
		return false
	if rep <= -REP_OVERRIDE_THRESHOLD:
		_dbg("REP %.0f ≤ -%.0f → HOSTILE override: player ↔ %s" \
			% [rep, REP_OVERRIDE_THRESHOLD, npc.name])
		return true

	# Neutrales Rep-Band: baseline gilt
	return base


# ─────────────────────────────────────────────────────────────────────────────
# FACTION-PAIR-API (für Debug-Panel, statische Matrix)
# ─────────────────────────────────────────────────────────────────────────────

## Prüft rein auf Fraktions-Enum-Ebene ob zwei Fraktionen baseline-feindlich sind.
## Delegiert defensiv an FactionSystem – so kompatibel wie möglich zur
## bestehenden API.
func is_faction_pair_hostile(faction_a: int, faction_b: int) -> bool:
	if faction_a == faction_b:
		return false

	# Variante 1: FactionSystem bietet eine passende Method
	if FactionSystem.has_method("is_faction_pair_hostile"):
		return FactionSystem.is_faction_pair_hostile(faction_a, faction_b)
	if FactionSystem.has_method("are_factions_hostile"):
		return FactionSystem.are_factions_hostile(faction_a, faction_b)

	# Variante 2: _HOSTILE_PAIRS direkt lesen
	if "_HOSTILE_PAIRS" in FactionSystem:
		var pairs: Array = FactionSystem._HOSTILE_PAIRS
		for pair in pairs:
			if pair is Array and pair.size() >= 2:
				var pa: int = int(pair[0])
				var pb: int = int(pair[1])
				if (pa == faction_a and pb == faction_b) \
						or (pa == faction_b and pb == faction_a):
					return true
		return false

	push_warning("[RelationshipResolver] FactionSystem kennt weder is_faction_pair_hostile() noch _HOSTILE_PAIRS → alle Paare als NEUTRAL gewertet.")
	return false


## Gibt ein Label für die Matrix-Ansicht zurück.
func faction_pair_label(faction_a: int, faction_b: int) -> String:
	if faction_a == faction_b:
		return "—"
	return "HOSTILE" if is_faction_pair_hostile(faction_a, faction_b) else "neutral"


# ─────────────────────────────────────────────────────────────────────────────
# AGGRO-LAYER
# ─────────────────────────────────────────────────────────────────────────────

## Setzt einen Aggro-Eintrag: observer betrachtet target als feindlich
## für die nächsten `duration` Sekunden, unabhängig von Reputation und Baseline.
## Anwendung: AIController.on_hit_by() → add_aggro(self, attacker).
func add_aggro(observer: Node, target: Node,
		duration: float = AGGRO_DEFAULT_DURATION) -> void:
	if not is_instance_valid(observer) or not is_instance_valid(target):
		return
	var key: String = _aggro_key(observer, target)
	var expire: float = (Time.get_ticks_msec() / 1000.0) + duration
	_aggro_table[key] = expire
	_dbg("ADD_AGGRO: '%s' → '%s' für %.1fs" % [observer.name, target.name, duration])


## Entfernt einen Aggro-Eintrag (z.B. wenn target stirbt oder observer resettet).
func clear_aggro(observer: Node, target: Node) -> void:
	if not is_instance_valid(observer) or not is_instance_valid(target):
		return
	var key: String = _aggro_key(observer, target)
	if _aggro_table.erase(key):
		_dbg("CLEAR_AGGRO: '%s' → '%s'" % [observer.name, target.name])


## Komplett-Reset (für Debug-Panel-Reset-Button).
func clear_all_aggro() -> void:
	var count: int = _aggro_table.size()
	_aggro_table.clear()
	_dbg("CLEAR_ALL_AGGRO: %d Einträge entfernt" % count)


func _has_aggro(observer: Node, target: Node) -> bool:
	if not is_instance_valid(observer) or not is_instance_valid(target):
		return false
	var key: String = _aggro_key(observer, target)
	if not _aggro_table.has(key):
		return false
	var now: float = Time.get_ticks_msec() / 1000.0
	if _aggro_table[key] <= now:
		_aggro_table.erase(key)      # ausgelaufen → raus
		return false
	return true


func _aggro_key(observer: Node, target: Node) -> String:
	return "%d->%d" % [observer.get_instance_id(), target.get_instance_id()]


# ─────────────────────────────────────────────────────────────────────────────
# ASSIST-MECHANIK (Ally-Support)
#
# Wenn ein Schiff angegriffen wird: alle Allies (gleiche Fraktion) innerhalb
# eines Radius werden alarmiert und bekommen Aggro auf den Angreifer.
# Das ist der AAA-Standard-Mechanismus für "Verbündete verteidigen sich
# gegenseitig" – ohne statische Fraktions-Hostility ändern zu müssen.
#
# Call-Site: ShipController._fire_weapons_of_type() nach erfolgreichem Schuss.
# ─────────────────────────────────────────────────────────────────────────────

## Default-Radius für Ally-Alert. Pro Aufruf überschreibbar.
## Wert passt zu max_lock_range des TargetingSystems (200m) × 2.5 – Allies
## die deutlich weiter weg sind reagieren nicht, weil sie in Radar-Realität
## nichts mitbekommen hätten.
const ALLY_ALERT_RADIUS_DEFAULT: float = 500.0

## Public: true wenn observer → target oder target → observer Aggro vorliegt.
## Wird von FactionSystem.are_hostile() genutzt um Aggro zu respektieren.
func has_aggro_between(observer: Node, target: Node) -> bool:
	if not is_instance_valid(observer) or not is_instance_valid(target):
		return false
	# Auf Ship-Root normalisieren – Aggro wird auf Root-Ebene gespeichert
	var obs_root: Node3D = _resolve_ship_root(observer)
	var tgt_root: Node3D = _resolve_ship_root(target)
	if not obs_root or not tgt_root:
		return false
	return _has_aggro(obs_root, tgt_root) or _has_aggro(tgt_root, obs_root)


## Benachrichtigt das System über einen Angriff.
## Setzt Aggro: victim → attacker (Direkt-Rache) und alarmiert alle Allies
## (gleiche Fraktion, im Radius) des Opfers mit Aggro auf den Angreifer.
##
## Call-Site: ShipController._fire_weapons_of_type() nach mount.fire_at() == true.
func notify_attack(attacker: Node, victim: Node,
		ally_radius: float = ALLY_ALERT_RADIUS_DEFAULT) -> void:
	var dbg: bool = _has_debug_manager() and DebugManager.get_flag("ai.resolver")

	if dbg:
		print("[RelationshipResolver] ═══ notify_attack() ═══")
		print("  attacker: '%s' (%s)" % [
			attacker.name if is_instance_valid(attacker) else "INVALID",
			attacker.get_class() if is_instance_valid(attacker) else "?"
		])
		print("  victim:   '%s' (%s)" % [
			victim.name if is_instance_valid(victim) else "INVALID",
			victim.get_class() if is_instance_valid(victim) else "?"
		])
		print("  radius:   %.0f m" % ally_radius)

	var attacker_root: Node3D = _resolve_ship_root(attacker)
	var victim_root:   Node3D = _resolve_ship_root(victim)

	if dbg:
		print("  attacker_root: %s" % (attacker_root.name if attacker_root else "❌ NULL (kein 'ships'-Ahne!)"))
		print("  victim_root:   %s" % (victim_root.name if victim_root else "❌ NULL (kein 'ships'-Ahne!)"))

	if not is_instance_valid(attacker_root) or not is_instance_valid(victim_root):
		if dbg: print("  → ABBRUCH: attacker_root oder victim_root ungültig")
		return
	if attacker_root == victim_root:
		if dbg: print("  → ABBRUCH: attacker == victim (Selbstschuss?)")
		return

	# 1. Direkte Rache: Victim bekommt Aggro auf Attacker
	add_aggro(victim_root, attacker_root)

	# 2. Allies alarmieren
	var victim_faction: Variant = _get_faction(victim_root)
	if victim_faction == null:
		if dbg: print("  → ABBRUCH: victim_root '%s' hat keine bekannte Fraktion" % victim_root.name)
		return

	if dbg:
		print("  victim_faction: %s" % ShipData.Faction.keys()[int(victim_faction)])

	var all_ships: Array = get_tree().get_nodes_in_group("ships")
	if dbg: print("  scanning 'ships' group: %d Einträge" % all_ships.size())

	var victim_pos:  Vector3    = victim_root.global_position
	var radius_sq:   float      = ally_radius * ally_radius
	var alert_count: int        = 0
	var seen:        Dictionary = {}

	for node in all_ships:
		if not is_instance_valid(node) or not (node is Node3D):
			continue

		var ally_root: Node3D = _resolve_ship_root(node)
		if not ally_root:
			if dbg: print("    SKIP '%s': kein ship-root" % node.name)
			continue

		if seen.has(ally_root):
			continue   # Duplikate (ShipController-Child + Parent) stillschweigend
		seen[ally_root] = true

		if ally_root == victim_root:
			if dbg: print("    SKIP '%s': ist das Opfer" % ally_root.name)
			continue
		if ally_root == attacker_root:
			if dbg: print("    SKIP '%s': ist der Angreifer" % ally_root.name)
			continue

		var ally_faction: Variant = _get_faction(ally_root)
		if ally_faction == null:
			if dbg: print("    SKIP '%s': keine Fraktion" % ally_root.name)
			continue
		if ally_faction != victim_faction:
			if dbg:
				print("    SKIP '%s': andere Fraktion (%s ≠ %s)" % [
					ally_root.name,
					ShipData.Faction.keys()[int(ally_faction)],
					ShipData.Faction.keys()[int(victim_faction)]
				])
			continue

		var dist_sq: float = ally_root.global_position.distance_squared_to(victim_pos)
		if dist_sq > radius_sq:
			if dbg:
				print("    SKIP '%s': zu weit (%.0fm > %.0fm)" % [
					ally_root.name, sqrt(dist_sq), ally_radius
				])
			continue

		# Ally alarmieren
		add_aggro(ally_root, attacker_root)
		alert_count += 1
		if dbg:
			print("    ✓ ALERT '%s' (dist=%.0fm) → Aggro auf '%s' gesetzt" % [
				ally_root.name, sqrt(dist_sq), attacker_root.name
			])

	if dbg:
		print("  ═══ RESULT: %d Ally(s) alarmiert ═══" % alert_count)
	elif alert_count > 0:
		_dbg("NOTIFY_ATTACK: '%s' ↦ '%s' · %d Allies alarmiert (radius=%.0f)" % [
			attacker_root.name, victim_root.name, alert_count, ally_radius])


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

func _is_player(node: Node) -> bool:
	# Läuft die Hierarchie hoch – findet auch Child-Nodes eines Player-Roots
	# (z.B. ShipController unter dem Player-CharacterBody3D).
	if not is_instance_valid(node):
		return false
	var current: Node = node
	while is_instance_valid(current):
		if current is Node3D and (current as Node3D).is_in_group("player"):
			return true
		current = current.get_parent()
	return false


## Normalisiert einen beliebigen Node auf den äußersten "ships"-Gruppen-Ahnen.
## Warum "äußerst": sowohl CharacterBody3D (Player/AIController) als auch der
## ShipController-Child sind in der "ships"-Gruppe. Wir wollen den CharacterBody3D
## damit Player-Detection via is_in_group("player") zuverlässig funktioniert.
func _resolve_ship_root(node: Node) -> Node3D:
	if not is_instance_valid(node):
		return null
	var result: Node3D = null
	var current: Node = node
	while is_instance_valid(current):
		if current is Node3D and (current as Node3D).is_in_group("ships"):
			result = current as Node3D
		current = current.get_parent()
	return result


## Liest ship_data.faction über den ShipController (direkt als Meta, oder
## als Kind-Node bei AIController). Gibt null zurück wenn nichts gefunden.
func _get_faction(node: Node3D) -> Variant:
	var sc: ShipController = _find_ship_controller_of(node)
	if not sc:
		# Fallback: über den Ship-Root suchen (wenn node ein Sub-Child ist)
		var root: Node3D = _resolve_ship_root(node)
		if root and root != node:
			sc = _find_ship_controller_of(root)
	if not sc:
		return null
	if not sc.ship_data:
		return null
	return sc.ship_data.faction


func _find_ship_controller_of(node: Node3D) -> ShipController:
	if node == null or not is_instance_valid(node):
		return null
	if node.has_meta("ship_controller"):
		var sc: Variant = node.get_meta("ship_controller")
		if sc is ShipController:
			return sc as ShipController
	for child in node.find_children("*", "ShipController", true, false):
		if child is ShipController:
			return child as ShipController
	return null


func _baseline_hostile(a: Node3D, b: Node3D) -> bool:
	# Reine Baseline: geht direkt auf Fraktions-Paar-Ebene, KEINE Rep-Logik hier.
	# (Die Rep-Override-Logik sitzt im Resolver selbst und soll nicht doppelt
	# ausgeführt werden, falls FactionSystem.are_hostile(nodes) selbst schon
	# eine Zwei-Kanal-Policy implementiert hätte.)
	var fa: Variant = _get_faction(a)
	var fb: Variant = _get_faction(b)
	if fa == null or fb == null:
		return false
	return is_faction_pair_hostile(int(fa), int(fb))


func _pair_key(a: Node, b: Node) -> String:
	var ia: int = a.get_instance_id()
	var ib: int = b.get_instance_id()
	# Symmetrischer Key: kleinere ID zuerst
	if ia < ib:
		return "%d:%d" % [ia, ib]
	return "%d:%d" % [ib, ia]


func _on_standing_changed(_faction: int, _old_val: float, _new_val: float) -> void:
	# Rep-Wechsel kann Relationen kippen → Cache invalidieren
	# (Next are_hostile() wird Relation-Change-Signals feuern wenn nötig)
	_last_hostile_state.clear()


func _on_faction_relation_changed(_a: int, _b: int, _is_hostile: bool) -> void:
	# Statische Baseline hat sich geändert (Live-Editor) → Cache invalidieren
	_last_hostile_state.clear()


func _has_debug_manager() -> bool:
	return get_tree().root.has_node("DebugManager")


func _dbg(msg: String) -> void:
	# Integriert ins DebugManager-Flag-System, Flag: "ai.resolver"
	if _has_debug_manager() and DebugManager.get_flag("ai.resolver"):
		print("[RelationshipResolver] %s" % msg)


# ─────────────────────────────────────────────────────────────────────────────
# DIAGNOSE – manueller Zustands-Dump (für Debug-Panel-Button)
# ─────────────────────────────────────────────────────────────────────────────

## Dumpt alle aktiven Aggro-Einträge und alle "ships"-Gruppen-Roots auf den
## Output. Wird vom Debug-Panel-Button "🔍 Dump Resolver" aufgerufen.
func debug_dump_state() -> void:
	print("\n[RelationshipResolver] ═══ STATE DUMP ═══")

	# 1. Aktive Aggro-Einträge
	var now: float = Time.get_ticks_msec() / 1000.0
	var active: Array = []
	for key in _aggro_table:
		var expire: float = _aggro_table[key]
		if expire > now:
			active.append({"key": key, "remaining": expire - now})

	print("  Aktive Aggro-Einträge: %d" % active.size())
	for entry in active:
		var key_str: String = entry["key"]
		var parts: PackedStringArray = key_str.split("->")
		var observer_id: int = int(parts[0]) if parts.size() >= 1 else 0
		var target_id:   int = int(parts[1]) if parts.size() >= 2 else 0
		var observer:    Node = instance_from_id(observer_id) if observer_id else null
		var target:      Node = instance_from_id(target_id)   if target_id   else null
		var obs_name: String = observer.name if is_instance_valid(observer) else "<gone>"
		var tgt_name: String = target.name   if is_instance_valid(target)   else "<gone>"
		print("    '%s'(%d) → '%s'(%d)  (noch %.1fs)" % [
			obs_name, observer_id, tgt_name, target_id, entry["remaining"]
		])

	# 2. Alle Schiffs-Roots
	var ships_group: Array = get_tree().get_nodes_in_group("ships")
	print("  Nodes in 'ships'-Gruppe: %d (inkl. Duplikate ShipController↔Parent)" % ships_group.size())

	var seen_roots: Dictionary = {}
	var unique_count: int = 0
	for n in ships_group:
		if not is_instance_valid(n) or not (n is Node3D):
			continue
		var root: Node3D = _resolve_ship_root(n)
		if not root or seen_roots.has(root):
			continue
		seen_roots[root] = true
		unique_count += 1

		var f: Variant = _get_faction(root)
		var f_name: String = ShipData.Faction.keys()[int(f)] if f != null else "?"
		var pos: Vector3 = root.global_position
		var player_flag: String = " [PLAYER]" if _is_player(root) else ""
		print("    %s: '%s' (%s) @ (%.0f, %.0f, %.0f)%s" % [
			root.get_class(), root.name, f_name,
			pos.x, pos.y, pos.z, player_flag
		])

	print("  → %d unique ship roots" % unique_count)

	# 3. Autoload-Check
	print("  Autoload-Check:")
	print("    FactionSystem      : %s" % ("✓" if get_tree().root.has_node("FactionSystem") else "❌"))
	print("    ReputationSystem   : %s" % ("✓" if get_tree().root.has_node("ReputationSystem") else "❌"))
	print("    DebugManager       : %s" % ("✓" if _has_debug_manager() else "❌"))

	print("[RelationshipResolver] ═══ END DUMP ═══\n")
