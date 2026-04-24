# res://scripts/components/input_component.gd
extends Node
class_name InputComponent

signal phaser_pressed()

func get_movement_input() -> Vector2:
	var rotation: float = Input.get_action_strength("move_right") \
		- Input.get_action_strength("move_left")
	var thrust: float   = Input.get_action_strength("move_forward") \
		- Input.get_action_strength("move_backward")
	return Vector2(rotation, thrust)

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("fire_phaser"):
		phaser_pressed.emit()

func get_mouse_3d_world_position() -> Vector3:
	var viewport := get_viewport()
	var camera   := viewport.get_camera_3d()
	if not camera:
		return Vector3.ZERO

	var mouse_pos  := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir    := camera.project_ray_normal(mouse_pos)
	var plane      := Plane(Vector3.UP, 0.0)

	var intersection: Variant = plane.intersects_ray(ray_origin, ray_dir)
	if intersection:
		return intersection
	return Vector3.ZERO
