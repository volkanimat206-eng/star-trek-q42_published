# res://resources/hull_data.gd
@tool
class_name HullData
extends Resource

@export_group("Stärke")
@export var max_hp:     float = 1000.0
@export var current_hp: float = 1000.0

# ── PUBLIC API ─────────────────────────────────────────────────────────────────

func get_integrity() -> float:
	if max_hp <= 0.0:
		return 0.0
	return clampf(current_hp / max_hp, 0.0, 1.0)

func take_damage(amount: float) -> float:
	current_hp -= amount
	if current_hp < 0.0:
		var overflow: float = absf(current_hp)
		current_hp = 0.0
		return overflow
	return 0.0

func heal(amount: float) -> void:
	current_hp = minf(current_hp + amount, max_hp)

func reset() -> void:
	current_hp = max_hp

func is_alive() -> bool:
	return current_hp > 0.0
