# res://scripts/weapons/weapon_disruptor_bolt.gd
# Klingonischer Disruptor-Energiebolzen.
# Bewegt sich als Projektil durch den Raum, erkennt Shield vs. Hull korrekt.
extends Node3D
class_name DisruptorBolt3D

# ===== EXPORTS =====
@export var speed:          float = 400.0
@export var max_range:      float = 150.0
## Basis-Schaden – wird von weapon_data überschrieben wenn gesetzt.
## Fallback wenn kein weapon_data zugewiesen ist (Abwärtskompatibilität).
@export var damage:         float = 35.0
@export var bolt_color:     Color = Color(0.0, 1.0, 0.2)
@export var pulse_speed:    float = 8.0
@export var pulse_min:      float = 0.6
@export var pulse_max:      float = 1.4

## Waffen-Resource mit Schadens-Multiplikatoren für Schild und Hülle.
## Wird von WingDisruptorMount automatisch gesetzt – kein manuelles Zuweisen nötig.
## Wenn null: damage-Export wird ohne Multiplikator verwendet (Fallback).
var weapon_data: BoltWeaponData = null

## Impact-Effekt-Scene die bei Hüllentreffern gespawnt wird (z.B. hull_impact.tscn).
## Im Inspector der BirdOfPrey-Scene oder WingDisruptorMount zuweisen.
@export var impact_hull_scene: PackedScene

@export_flags_3d_physics var collision_mask: int = 6

@export_group("Debug")
@export var debug_hit: bool = false

# ===== INTERN =====
var _traveled:     float         = 0.0
var _owner_ship:   Node3D        = null
var _exclude_rids: Array[RID]    = []
var _pulse_t:      float         = 0.0
var _space:        PhysicsDirectSpaceState3D

var _mesh:  MeshInstance3D
var _light: OmniLight3D
var _trail: GPUParticles3D


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_mesh  = get_node_or_null("BoltMesh")
	_light = get_node_or_null("BoltLight")
	_trail = get_node_or_null("BoltTrail")
	_space = get_world_3d().direct_space_state
	_apply_color()

	if debug_hit:
		print("[DisruptorBolt] Spawn | mask=%d | speed=%.0f | range=%.0f" % [
			collision_mask, speed, max_range])
		print("[DisruptorBolt] Bits aktiv: %s" % _mask_to_layers(collision_mask))
		if weapon_data:
			print("[DisruptorBolt] weapon_data='%s' | shield_mult=%.2f | hull_mult=%.2f" % [
				weapon_data.weapon_name,
				weapon_data.shield_damage_multiplier,
				weapon_data.hull_damage_multiplier
			])


func initialize(owner_ship: Node3D, exclude_rids: Array[RID]) -> void:
	_owner_ship   = owner_ship
	_exclude_rids = exclude_rids

	if debug_hit:
		print("[DisruptorBolt] initialize | owner=%s | exclude_rids=%d" % [
			owner_ship.name if owner_ship else "NULL",
			exclude_rids.size()
		])


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS
# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_pulse_t += delta * pulse_speed
	var pulse: float = lerpf(pulse_min, pulse_max, sin(_pulse_t) * 0.5 + 0.5)
	if _light:
		_light.light_energy = pulse * 3.0

	var step:     float   = speed * delta
	var from_pos: Vector3 = global_position
	var to_pos:   Vector3 = global_position + (-global_transform.basis.z * step)

	var query := PhysicsRayQueryParameters3D.create(from_pos, to_pos, collision_mask)
	query.exclude             = _exclude_rids
	query.collide_with_areas  = true
	query.collide_with_bodies = true
	query.hit_back_faces      = false

	if debug_hit and Engine.get_process_frames() % 30 == 0:
		print("[DisruptorBolt] Raycast | from=%s | to=%s | mask=%d" % [
			from_pos.snappedf(1.0), to_pos.snappedf(1.0), collision_mask])

	var result: Dictionary = _space.intersect_ray(query)

	if not result.is_empty():
		_on_hit(result)
		return

	global_position  = to_pos
	_traveled       += step

	if _traveled >= max_range:
		_despawn()


# ─────────────────────────────────────────────────────────────────────────────
# SCHADENS-HELPER
# ─────────────────────────────────────────────────────────────────────────────

## Gibt den effektiven Schaden zurück – mit Multiplikator aus weapon_data.
## hit_shield = true  → shield_damage_multiplier
## hit_shield = false → hull_damage_multiplier
## Fallback auf damage-Export wenn kein weapon_data gesetzt ist.
func _get_effective_damage(hit_shield: bool) -> float:
	if weapon_data:
		return weapon_data.get_damage(hit_shield)
	return damage


# ─────────────────────────────────────────────────────────────────────────────
# TREFFER-LOGIK
# ─────────────────────────────────────────────────────────────────────────────

func _on_hit(result: Dictionary) -> void:
	var collider: Object = result.get("collider")
	var hit_pos:  Vector3 = result.get("position",  global_position)
	var hit_norm: Vector3 = result.get("normal",    Vector3.UP)

	if debug_hit:
		var col_name:  String = collider.name  if collider else "NULL"
		var col_class: String = collider.get_class() if collider else "NULL"
		var col_layer: int    = collider.collision_layer if collider and "collision_layer" in collider else -1
		print("[DisruptorBolt] ── TREFFER ──────────────────────────")
		print("  collider : '%s' [%s]" % [col_name, col_class])
		print("  layer    : %d (%s)" % [col_layer, _mask_to_layers(col_layer)])
		print("  has_meta shield_system : %s" % (collider.has_meta("shield_system") if collider else false))
		print("  is Area3D : %s" % (collider is Area3D if collider else false))
		print("────────────────────────────────────────────────────")

	if not collider:
		_despawn()
		return

	if collider is Area3D and collider.has_meta("shield_system"):
		_handle_shield_hit(collider, hit_pos, hit_norm)
		return

	var shield_sys := _find_shield_system_from(collider)
	if shield_sys and shield_sys.is_active():
		_handle_shield_hit_direct(shield_sys, hit_pos, hit_norm)
		return

	_handle_hull_hit(collider, hit_pos, hit_norm)


func _handle_shield_hit(shield_area: Area3D, hit_pos: Vector3, hit_norm: Vector3) -> void:
	var shield_sys: ShieldSystem = shield_area.get_meta("shield_system") as ShieldSystem
	if not shield_sys:
		_handle_hull_hit(shield_area, hit_pos, hit_norm)
		return

	# Schild-Multiplikator anwenden
	var effective: float = _get_effective_damage(true)

	if debug_hit:
		print("[DisruptorBolt] → SCHILD getroffen | base=%.0f | mult=%.2f | effective=%.0f | HP=%.0f" % [
			damage,
			weapon_data.shield_damage_multiplier if weapon_data else 1.0,
			effective,
			shield_sys.get_integrity()
		])

	var sc := _find_ship_controller_from(shield_area)
	if sc:
		sc.receive_damage(effective, hit_pos, "disruptor", bolt_color)
	else:
		shield_sys.receive_hit(effective, hit_pos, bolt_color)

	_despawn()


func _handle_shield_hit_direct(shield_sys: ShieldSystem,
								hit_pos: Vector3, _hit_norm: Vector3) -> void:
	var effective: float = _get_effective_damage(true)

	if debug_hit:
		print("[DisruptorBolt] → SCHILD (direkt) getroffen | effective=%.0f" % effective)

	var sc := _find_ship_controller_from(shield_sys)
	if sc:
		sc.receive_damage(effective, hit_pos, "disruptor", bolt_color)
	else:
		shield_sys.receive_hit(effective, hit_pos, bolt_color)
	_despawn()


func _handle_hull_hit(collider: Object, hit_pos: Vector3, hit_norm: Vector3) -> void:
	# Hüll-Multiplikator anwenden
	var effective: float = _get_effective_damage(false)

	if debug_hit:
		print("[DisruptorBolt] → HÜLLE getroffen | base=%.0f | mult=%.2f | effective=%.0f" % [
			damage,
			weapon_data.hull_damage_multiplier if weapon_data else 1.0,
			effective
		])

	var sc := _find_ship_controller_from(collider)
	if sc and sc != _find_ship_controller_from(_owner_ship):
		sc.receive_damage(effective, hit_pos, "disruptor", bolt_color)

		var hull_receiver: HullImpactReceiver = null
		hull_receiver = sc.find_child("HullImpactReceiver", true, false) as HullImpactReceiver
		if not hull_receiver:
			var ship_root: Node = sc.get_parent()
			if ship_root and ship_root != get_tree().current_scene:
				hull_receiver = ship_root.find_child("HullImpactReceiver", true, false) as HullImpactReceiver
		if hull_receiver:
			hull_receiver.register_impact(hit_pos, hit_norm)
		elif debug_hit:
			print("[DisruptorBolt] HullImpactReceiver nicht gefunden unter '%s'" % sc.name)

		# Impact-Effekt am Schiff verankern (folgt Bewegung)
		if impact_hull_scene:
			var instance := impact_hull_scene.instantiate() as Node3D
			if instance:
				# Schiffsmodell-Node als Anker (Model-Node bewegt sich mit dem Schiff)
				var anchor: Node3D = sc.find_child("Model", true, false) as Node3D
				if not is_instance_valid(anchor):
					anchor = sc.get_parent() as Node3D
				if instance.has_method("attach_to") and is_instance_valid(anchor):
					instance.attach_to(anchor, hit_pos)
				else:
					get_tree().current_scene.add_child(instance)
					instance.global_position = hit_pos
				# Ausrichten: Effekt zeigt von der Hülle weg (entlang Normalen)
				if hit_norm.length_squared() > 0.01:
					instance.look_at(hit_pos + hit_norm)

		if debug_hit:
			print("[DisruptorBolt] Schaden %.0f an '%s'" % [effective, sc.ship_name])
	elif debug_hit:
		print("[DisruptorBolt] ⚠ Kein ShipController gefunden oder eigenes Schiff!")

	_despawn()


# ─────────────────────────────────────────────────────────────────────────────
# DESPAWN
# ─────────────────────────────────────────────────────────────────────────────

func _despawn() -> void:
	if _trail:
		_trail.emitting = false
	if _mesh:
		_mesh.visible = false
	if _light:
		_light.visible = false
	await get_tree().create_timer(0.5).timeout
	if is_instance_valid(self):
		queue_free()


# ─────────────────────────────────────────────────────────────────────────────
# VISUALS
# ─────────────────────────────────────────────────────────────────────────────

func _apply_color() -> void:
	if _mesh:
		var mat := StandardMaterial3D.new()
		mat.albedo_color               = bolt_color
		mat.emission_enabled           = true
		mat.emission                   = bolt_color
		mat.emission_energy_multiplier = 3.0
		mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mesh.material_override        = mat
	if _light:
		_light.light_color = bolt_color


# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────

func _find_shield_system_from(node: Object) -> ShieldSystem:
	if not node:
		return null
	var current: Node = node as Node
	while current:
		if current is ShieldSystem:
			return current as ShieldSystem
		if current.has_meta("shield_system"):
			var ss: Variant = current.get_meta("shield_system")
			if ss is ShieldSystem:
				return ss as ShieldSystem
		current = current.get_parent()
	return null


func _find_ship_controller_from(node: Object) -> ShipController:
	if not node:
		return null
	var current: Node = node as Node
	while current:
		if current is ShipController:
			return current as ShipController
		if current.has_meta("ship_controller"):
			var sc: Variant = current.get_meta("ship_controller")
			if sc is ShipController:
				return sc as ShipController
		current = current.get_parent()
	return null


func _mask_to_layers(mask: int) -> String:
	if mask < 0:
		return "?"
	var layers: Array = []
	for i in 32:
		if mask & (1 << i):
			layers.append("Layer %d" % (i + 1))
	return ", ".join(layers) if layers.size() > 0 else "keine"
