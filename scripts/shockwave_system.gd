class_name ShockwaveSystem
extends RefCounted

## Löst eine Explosions-Shockwave aus.
## Aufruf: ShockwaveSystem.trigger(get_tree(), global_position, ship_data.shockwave_data, self)
static func trigger(
	tree: SceneTree,
	origin: Vector3,
	data: ShockwaveData,
	excluded: CharacterBody3D
) -> void:
	if data == null:
		push_warning("ShockwaveSystem: ShockwaveData ist null, kein Effekt.")
		return

	var ships: Array[Node] = tree.get_nodes_in_group("ships")

	for node: Node in ships:
		if node == excluded:
			continue
		if not node is CharacterBody3D:
			continue

		var body := node as CharacterBody3D
		var diff: Vector3 = body.global_position - origin
		var dist: float = diff.length()

		if dist <= 0.0 or dist > data.shockwave_radius:
			continue

		# Kraft: linear falloff vom Zentrum nach außen
		var falloff: float = 1.0 - (dist / data.shockwave_radius)
		var force: float = data.shockwave_force * falloff
		var push_dir: Vector3 = diff.normalized()

		body.velocity += push_dir * force

		# Tilt via MovementComponent falls vorhanden
		var movement: MovementComponent = _get_movement_component(body)
		if movement != null:
			movement.apply_shockwave_tilt(data.shockwave_tilt_angle, data.shockwave_recovery_time, push_dir)
		else:
			# Fallback: direkt auf dem Node (sucht "Model"-Child)
			var model: Node3D = body.get_node_or_null("Model") as Node3D
			if model != null:
				_tween_tilt(body, model, data.shockwave_tilt_angle, data.shockwave_recovery_time)


static func _get_movement_component(body: CharacterBody3D) -> MovementComponent:
	for child: Node in body.get_children():
		if child is MovementComponent:
			return child as MovementComponent
	return null


static func _tween_tilt(owner: Node, model: Node3D, angle_deg: float, recovery_time: float) -> void:
	var tween: Tween = owner.create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_SPRING)

	var start_rot: Vector3 = model.rotation_degrees
	var tilt_rot: Vector3 = Vector3(start_rot.x, start_rot.y, start_rot.z + angle_deg)
	var recover_rot: Vector3 = start_rot

	tween.tween_property(model, "rotation_degrees", tilt_rot, 0.15)
	tween.tween_property(model, "rotation_degrees", recover_rot, recovery_time)
