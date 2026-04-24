# res://scripts/debug/physics_layer_watcher.gd
#
# Debug-Node der alle 5 Sekunden alle PhysicsBody3D und Area3D
# in der Szene auflistet mit ihren Collision Layer/Mask-Werten.
#
# Einbinden: Node (dieses Script) irgendwo in die World-Scene einhängen.
# Läuft zur Laufzeit → zeigt auch nach dem Spawn neue Schiffe.

extends Node

const INTERVAL: float = 5.0
var _timer: float = 0.0

# Nur diese Node-Typen werden angezeigt
const WATCH_TYPES := ["CharacterBody3D", "RigidBody3D", "StaticBody3D", "Area3D"]

# Nur Nodes mit einem dieser Namensteile werden angezeigt (leer = alle)
@export var filter_names: Array[String] = ["Player", "AiController", "Radar", "Sovereign", "BirdOfPrey", "Warbird"]

@export var show_all: bool = false  # true = alle Physics-Nodes ohne Filter


func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = INTERVAL
	_print_layers()


func _print_layers() -> void:
	var scene := get_tree().current_scene
	if not scene:
		return

	var nodes: Array[Node] = []
	_collect(scene, nodes)

	print("\n══════════════════════════════════════════════════════════")
	print("[LayerWatcher] Physics-Layer-Snapshot | %d Nodes | %.1fs" % [nodes.size(), Time.get_ticks_msec() / 1000.0])
	print("%-32s %-18s %-12s %-12s %s" % ["Node (Pfad)", "Typ", "Layer(Bits)", "Mask(Bits)", "Gruppen"])
	print("──────────────────────────────────────────────────────────")

	for node in nodes:
		if not is_instance_valid(node): continue
		var co := node as CollisionObject3D
		if not co: continue

		var layer_bits := _to_bits(co.collision_layer)
		var mask_bits  := _to_bits(co.collision_mask)
		var groups     := node.get_groups().filter(func(g: String) -> bool: return not g.begins_with("_"))
		var path       := str(node.get_path()).right(-1)  # führenden / entfernen
		if path.length() > 32: path = "…" + path.right(31)

		print("%-32s %-18s L:%-10s M:%-10s %s" % [
			path,
			node.get_class(),
			layer_bits,
			mask_bits,
			", ".join(groups) if not groups.is_empty() else "—"
		])

		# Warnungen direkt darunter
		if co is Area3D:
			var area := co as Area3D
			if not area.monitoring:
				print("   ⚠  monitoring=false → detektiert NICHTS")
			if co.collision_mask == 0:
				print("   ❌ Mask=0 → diese Area3D ist blind")
		if co.collision_layer == 0 and not (co is Area3D):
			print("   ⚠  Layer=0 → für niemanden sichtbar")

	print("──────────────────────────────────────────────────────────")

	# Radar↔Player Kompatibilität
	_check_radar_vs_player(nodes)
	print("══════════════════════════════════════════════════════════\n")


func _check_radar_vs_player(nodes: Array[Node]) -> void:
	var radars:  Array[Area3D]          = []
	var players: Array[CharacterBody3D] = []
	var ais:     Array[CharacterBody3D] = []

	for node in nodes:
		if not is_instance_valid(node): continue
		if node is Area3D and node.name == "Radar":
			radars.append(node as Area3D)
		elif node is CharacterBody3D:
			if node.is_in_group("player"):
				players.append(node as CharacterBody3D)
			elif node.is_in_group("ships"):
				ais.append(node as CharacterBody3D)

	if radars.is_empty():
		print("[LayerWatcher] ℹ Kein Radar-Node gefunden")
		return

	print("[LayerWatcher] 🎯 Radar ↔ Schiff Kompatibilität:")
	for radar in radars:
		var parent_name: String = radar.get_parent().name if radar.get_parent() else "?"
		print("  Radar unter '%s' | Mask=%s [%d] | monitoring=%s" % [
			parent_name, _to_bits(radar.collision_mask), radar.collision_mask, radar.monitoring])

		for p in players:
			var overlap := radar.collision_mask & p.collision_layer
			var icon := "✅" if overlap != 0 else "❌"
			print("    %s Player '%s' Layer=%s[%d]  Überlappung=%d" % [
				icon, p.name, _to_bits(p.collision_layer), p.collision_layer, overlap])
			if overlap == 0:
				print("       → Radar kann Player NICHT sehen! Radar-Mask oder Player-Layer anpassen.")

		for ai in ais:
			var overlap := radar.collision_mask & ai.collision_layer
			var icon := "✅" if overlap != 0 else "❌"
			print("    %s AI   '%s' Layer=%s[%d]  Überlappung=%d" % [
				icon, ai.name, _to_bits(ai.collision_layer), ai.collision_layer, overlap])


func _collect(node: Node, result: Array[Node]) -> void:
	if node is CollisionObject3D:
		if show_all or _passes_filter(node):
			result.append(node)
	for child in node.get_children():
		_collect(child, result)


func _passes_filter(node: Node) -> bool:
	if filter_names.is_empty():
		return true
	for f in filter_names:
		if node.name.containsn(f):
			return true
	return false


func _to_bits(mask: int) -> String:
	if mask == 0: return "—"
	var active: PackedStringArray = []
	for i in range(32):
		if mask & (1 << i):
			active.append(str(i + 1))
	return ",".join(active)
