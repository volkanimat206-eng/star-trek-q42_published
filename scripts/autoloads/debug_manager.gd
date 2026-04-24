# res://autoload/debug_manager.gd
extends Node

# category -> bool
var _flags: Dictionary = {}

# category -> Array[{node, property}]
var _bindings: Dictionary = {}

signal debug_flag_changed(category: String, value: bool)

# ─────────────────────────────────────────────────────────────
# PHYSICS LAYER SCANNER
# ─────────────────────────────────────────────────────────────

## Scan-Intervall in Sekunden (auch neue Schiffe werden erfasst)
const LAYER_SCAN_INTERVAL: float = 2.0
var _layer_scan_timer: float = 0.0
var _layer_scan_active: bool = false

## Zuletzt geloggter Zustand – verhindert Log-Spam wenn sich nichts ändert
var _last_layer_snapshot: Dictionary = {}


func _process(delta: float) -> void:
	if not _layer_scan_active:
		return
	_layer_scan_timer -= delta
	if _layer_scan_timer <= 0.0:
		_layer_scan_timer = LAYER_SCAN_INTERVAL
		_scan_physics_layers()


## Startet den Live-Layer-Scanner (z.B. aus dem DebugPanel per Button).
func start_layer_scan() -> void:
	_layer_scan_active = true
	_layer_scan_timer  = 0.0  # sofort beim nächsten Frame
	print("[DebugManager|LAYER] 🔍 Layer-Scanner gestartet (Intervall: %.1fs)" % LAYER_SCAN_INTERVAL)


## Stoppt den Scanner wieder.
func stop_layer_scan() -> void:
	_layer_scan_active = false
	_last_layer_snapshot.clear()
	print("[DebugManager|LAYER] ⏹ Layer-Scanner gestoppt")


## Einmaliger manueller Scan (auch ohne laufenden Timer aufrufbar).
func scan_physics_layers_once() -> void:
	_scan_physics_layers()


func _scan_physics_layers() -> void:
	var scene := get_tree().current_scene
	if not scene:
		return

	# Alle relevanten Nodes sammeln
	var nodes_to_check: Array[Node] = []
	_collect_physics_nodes(scene, nodes_to_check)

	var snapshot: Dictionary = {}

	print("─────────────────────────────────────────────────────")
	print("[DebugManager|LAYER] Physics-Layer-Scan | %d Nodes" % nodes_to_check.size())
	print("%-30s %-20s %-10s %-10s" % ["Node", "Klasse", "Layer", "Mask"])
	print("─────────────────────────────────────────────────────")

	for node in nodes_to_check:
		if not is_instance_valid(node):
			continue

		var col_obj := node as CollisionObject3D
		if not col_obj:
			continue

		var layer: int = col_obj.collision_layer
		var mask:  int = col_obj.collision_mask

		# Gruppen als Kontext-Info
		var groups := node.get_groups().filter(func(g: String) -> bool:
			return not g.begins_with("_"))

		var key: String = node.get_path()
		snapshot[key] = "%d|%d" % [layer, mask]

		# Nur ausgeben wenn sich was geändert hat (oder erstes Mal)
		var changed: bool = not _last_layer_snapshot.has(key) \
			or _last_layer_snapshot[key] != snapshot[key]

		var change_marker: String = "🆕" if not _last_layer_snapshot.has(key) \
			else ("🔄" if changed else "  ")

		var layer_bits := _bits_to_string(layer)
		var mask_bits  := _bits_to_string(mask)

		print("%s %-28s %-20s L:%-8s M:%-8s | Gruppen: %s" % [
			change_marker,
			node.name.left(28),
			node.get_class().left(20),
			layer_bits,
			mask_bits,
			", ".join(groups) if not groups.is_empty() else "—"
		])

		# Warnungen
		if layer == 0:
			print("   ⚠ Layer=0: dieser Node ist für niemanden sichtbar!")
		if mask == 0 and node is Area3D:
			print("   ⚠ Mask=0: diese Area3D kann nichts detektieren!")
		if node is Area3D and layer == 0 and mask == 0:
			print("   ❌ Area3D hat WEDER Layer noch Mask → komplett blind!")

	print("─────────────────────────────────────────────────────")

	# Radar-spezifische Prüfung: Überlappen Player-Layer und Radar-Mask?
	_check_radar_player_compatibility(nodes_to_check)

	_last_layer_snapshot = snapshot


## Prüft ob Radar-Mask und Player-Layer kompatibel sind.
func _check_radar_player_compatibility(nodes: Array[Node]) -> void:
	var radar_areas:   Array[Area3D]           = []
	var player_bodies: Array[CharacterBody3D]  = []
	var ai_bodies:     Array[CharacterBody3D]  = []

	for node in nodes:
		if not is_instance_valid(node): continue
		if node is Area3D and node.name == "Radar":
			radar_areas.append(node as Area3D)
		elif node is CharacterBody3D:
			if node.is_in_group("player"):
				player_bodies.append(node as CharacterBody3D)
			elif node.is_in_group("ships"):
				ai_bodies.append(node as CharacterBody3D)

	if radar_areas.is_empty():
		print("[DebugManager|LAYER] ℹ Kein Radar-Node gefunden")
		return

	print("[DebugManager|LAYER] 🎯 Radar-Kompatibilitätsprüfung:")
	for radar in radar_areas:
		var radar_mask: int = radar.collision_mask
		var parent_name: String = radar.get_parent().name if radar.get_parent() else "?"
		print("  Radar (unter '%s') Mask=%s [%d]" % [
			parent_name, _bits_to_string(radar_mask), radar_mask])

		for player in player_bodies:
			var player_layer: int = player.collision_layer
			var overlap: int = radar_mask & player_layer
			var ok: String = "✅" if overlap != 0 else "❌"
			print("    %s Player '%s' Layer=%s [%d] → Überlappung: %d" % [
				ok, player.name, _bits_to_string(player_layer), player_layer, overlap])
			if overlap == 0:
				print("       → FIX: Player-Layer oder Radar-Mask anpassen!")

		for ai in ai_bodies:
			var ai_layer: int = ai.collision_layer
			var overlap: int = radar_mask & ai_layer
			var ok: String = "✅" if overlap != 0 else "❌"
			print("    %s AI '%s' Layer=%s [%d] → Überlappung: %d" % [
				ok, ai.name, _bits_to_string(ai_layer), ai_layer, overlap])


func _collect_physics_nodes(node: Node, result: Array[Node]) -> void:
	if node is CollisionObject3D:
		result.append(node)
	for child in node.get_children():
		_collect_physics_nodes(child, result)


## Wandelt eine Bitmaske in lesbaren Layer-String um (z.B. "1,3,6")
func _bits_to_string(mask: int) -> String:
	if mask == 0:
		return "—"
	var active: Array[String] = []
	for i in range(32):
		if mask & (1 << i):
			active.append(str(i + 1))
	return ",".join(active)


# ─────────────────────────────────────────────────────────────
# REGISTER
# ─────────────────────────────────────────────────────────────
func register(node: Object, category: String, property: String):
	if not _bindings.has(category):
		_bindings[category] = []
		_flags[category] = false

	_bindings[category].append({
		"node": node,
		"property": property
	})

	# initial sync
	node.set(property, _flags[category])

# ─────────────────────────────────────────────────────────────
# SET FLAG
# ─────────────────────────────────────────────────────────────
func set_flag(category: String, value: bool):
	_flags[category] = value

	if _bindings.has(category):
		for entry in _bindings[category]:
			var node = entry.node
			if is_instance_valid(node):
				node.set(entry.property, value)

	emit_signal("debug_flag_changed", category, value)

# ─────────────────────────────────────────────────────────────
# GET FLAG
# ─────────────────────────────────────────────────────────────
func get_flag(category: String) -> bool:
	return _flags.get(category, false)

# ─────────────────────────────────────────────────────────────
# TOGGLE
# ─────────────────────────────────────────────────────────────
func toggle(category: String):
	set_flag(category, not get_flag(category))

# ─────────────────────────────────────────────────────────────
# ALL FLAGS (für UI)
# ─────────────────────────────────────────────────────────────
func get_all_flags() -> Dictionary:
	return _flags


# Reset
func reset_all_flags() -> void:
	for category in _flags.keys():
		set_flag(category, false)
	print("[DebugManager] Alle Flags auf FALSE zurückgesetzt.")
