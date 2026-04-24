# res://scripts/damage_dealer.gd
class_name DamageDealer
extends RefCounted
## Versucht, Schaden an einem getroffenen Node anzuwenden.
## Gibt zurück wieviel Schaden tatsächlich die Hülle getroffen hat (nach Schild).
## Gibt -1.0 zurück wenn kein gültiges Ziel gefunden wurde.
static func apply(hit_node: Node, damage: float,
				  impact_point: Vector3,
				  damage_type: String = "phaser",
				  beam_color: Color = Color(0.4, 0.8, 1.0)) -> float:
	if not hit_node or not is_instance_valid(hit_node):
		return -1.0
	var controller := _get_controller_from_metadata(hit_node)
	if not controller:
		controller = _find_ship_controller(hit_node)
	if not controller:
		return -1.0
	return controller.receive_damage(damage, impact_point, damage_type, beam_color)

## Wie apply(), gibt zusätzlich [hull_damage, shield_slot_index] zurück.
## Beam-Waffen nutzen shield_slot_index für update_beam_impact() jeden Frame.
## hint_slot: bestehender Slot-Index vom Beam – verhindert Timer-Reset bei Folge-Ticks.
static func apply_ex(hit_node: Node, damage: float,
					 impact_point: Vector3,
					 damage_type: String = "phaser",
					 beam_color: Color = Color(0.4, 0.8, 1.0),
					 hint_slot: int = -1) -> Array:
	if not hit_node or not is_instance_valid(hit_node):
		return [-1.0, -1]
	var controller := _get_controller_from_metadata(hit_node)
	if not controller:
		controller = _find_ship_controller(hit_node)
	if not controller:
		return [-1.0, -1]
	return controller.receive_damage_ex(damage, impact_point, damage_type, beam_color, hint_slot)

## Gibt true zurück wenn der Node zu einem Schiff gehört, das einen aktiven Schild hat.
static func has_active_shield(hit_node: Node) -> bool:
	if not hit_node or not is_instance_valid(hit_node):
		return false
	if hit_node.has_meta("shield_system"):
		var shield = hit_node.get_meta("shield_system") as ShieldSystem
		if shield and shield.is_active():
			return true
	var controller := _get_controller_from_metadata(hit_node)
	if not controller:
		controller = _find_ship_controller(hit_node)
	if controller:
		return controller.is_shield_active()
	return false

## Holt den ShipController direkt über Meta-Daten (sehr schnell)
static func _get_controller_from_metadata(node: Node) -> ShipController:
	if node.has_meta("ship_controller"):
		return node.get_meta("ship_controller") as ShipController
	if node.has_meta("ship_parent"):
		var parent = node.get_meta("ship_parent")
		if parent and parent.has_meta("ship_controller"):
			return parent.get_meta("ship_controller") as ShipController
	var current = node.get_parent()
	while current and is_instance_valid(current):
		if current.has_meta("ship_controller"):
			return current.get_meta("ship_controller") as ShipController
		if current.has_meta("ship_parent"):
			var ship_parent = current.get_meta("ship_parent")
			if ship_parent and ship_parent.has_meta("ship_controller"):
				return ship_parent.get_meta("ship_controller") as ShipController
		current = current.get_parent()
	return null

## Sucht den ShipController am Node oder seinen Eltern (Fallback-Methode)
static func _find_ship_controller(node: Node) -> ShipController:
	var current: Node = node
	while current and is_instance_valid(current):
		if current is ShipController:
			return current as ShipController
		for child in current.get_children():
			if child is ShipController:
				return child as ShipController
		current = current.get_parent()
	return null

## Gibt den ShipController zurück wenn vorhanden (für externe Abfragen).
static func get_ship_controller(node: Node) -> ShipController:
	var controller := _get_controller_from_metadata(node)
	if not controller:
		controller = _find_ship_controller(node)
	return controller
