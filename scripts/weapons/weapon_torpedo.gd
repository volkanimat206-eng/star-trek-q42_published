# res://scripts/weapons/torpedo_3d.gd
extends Node3D
class_name Torpedo3D

# ===== KONFIGURATION =====
var torpedo_data:   TorpedoData = null
var target_node:    Node3D      = null
var owner_ship:     Node3D      = null
var exclude_rids:   Array[RID]  = []

# ===== EXPORTS =====
@export var proximity_detonate_radius: float = 3.0
@export var debug_colors: bool = false
@export var debug_explosion: bool = false
@export var velocity_decay_time: float = 2.5

# ===== PREDICTIVE AIMING EXPORTS =====
## Aktiviert Predictive Aiming (deaktiviert = Pure Pursuit, aktiviert = Vorhalt)
@export var use_predictive_aiming: bool = true
## Vorhalt-Faktor (0.0 = kein Vorhalt, 1.0 = voller Vorhalt)
## Niedriger Wert reduziert Überschießen bei schnellen, kleinen Targets
@export var prediction_factor: float = 0.6
## Minimaler Abstand für Predictive Aiming (näher dran = Pure Pursuit)
@export var predictive_min_distance: float = 35.0
## Maximaler Vorhalt in Sekunden (verhindert absurde Vorhersagen)
@export var max_prediction_time: float = 1.5

# ===== NODE REFERENZEN =====
var _core_mesh:      MeshInstance3D = null
var _core_light:     OmniLight3D    = null
var _beam_light:     SpotLight3D    = null
var _timer:          Timer          = null
var _light_spikes:   Node3D         = null
var _spike_pivot:    Node3D         = null
var _spike_material: ShaderMaterial = null
var _trail:          GPUParticles3D  = null

# ===== INTERN =====
var _traveled:        float   = 0.0
var _lifetime:        float   = 0.0
var _armed:           bool    = false
var _arm_distance:    float   = 20.0
var _spike_rotation:  float   = 0.0
var _despawning:      bool    = false
var _space:           PhysicsDirectSpaceState3D
var _launch_direction: Vector3 = Vector3.FORWARD

# Velocity Boost
var _initial_boost:  Vector3 = Vector3.ZERO
var _boost_elapsed:  float   = 0.0

# Pulse
var _target_core_energy: float = 3.0
var _target_beam_energy: float = 6.0

# Predictive Aiming State
var _last_target_pos: Vector3 = Vector3.ZERO
var _last_target_vel: Vector3 = Vector3.ZERO
var _target_vel_smooth: Vector3 = Vector3.ZERO


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_core_mesh    = get_node_or_null("CoreMesh")
	_core_light   = get_node_or_null("CoreLight")
	_beam_light   = get_node_or_null("BeamLight")
	_timer        = get_node_or_null("Timer")
	_light_spikes = get_node_or_null("LightSpikes")
	_spike_pivot  = get_node_or_null("SpikePivot")
	_trail        = get_node_or_null("TorpedoTrail")

	var billboard := get_node_or_null("LightSpikes/SpikeBillboard")
	if billboard and billboard is MeshInstance3D:
		var mat := (billboard as MeshInstance3D).get_active_material(0)
		if mat is ShaderMaterial:
			_spike_material = mat as ShaderMaterial

	_space = get_world_3d().direct_space_state

	if _timer:
		_timer.timeout.connect(_on_pulse_tick)

	_apply_visuals()


# ─────────────────────────────────────────────────────────────────────────────
# INITIALIZE
# ─────────────────────────────────────────────────────────────────────────────

func initialize(data: TorpedoData, target: Node3D,
				owner: Node3D, rids: Array[RID],
				ship_velocity: Vector3 = Vector3.ZERO,
				decay_time: float = 2.5,
				arm_distance: float = 20.0) -> void:
	torpedo_data      = data
	target_node       = target
	owner_ship        = owner
	exclude_rids      = rids

	_launch_direction = -global_transform.basis.z
	_arm_distance     = arm_distance
	_armed            = false

	_initial_boost      = ship_velocity
	_boost_elapsed      = 0.0
	velocity_decay_time = decay_time

	# Predictive Aiming initialisieren
	if is_instance_valid(target_node):
		_last_target_pos = target_node.global_position
		_last_target_vel = Vector3.ZERO
		_target_vel_smooth = Vector3.ZERO

	if _initial_boost.length() > 0.5:
		print("[Torpedo3D] Velocity Boost: %.1f u/s | decay=%.1fs | arm_dist=%.0f | predictive=%s" % [
			_initial_boost.length(), velocity_decay_time, _arm_distance, use_predictive_aiming])

	_apply_visuals()


# ─────────────────────────────────────────────────────────────────────────────
# TIMER
# ─────────────────────────────────────────────────────────────────────────────

func _on_pulse_tick() -> void:
	if not torpedo_data:
		return
	_target_core_energy = randf_range(
		torpedo_data.pulse_energy_min,
		torpedo_data.pulse_energy_max)
	_target_beam_energy = _target_core_energy * 2.0


# ─────────────────────────────────────────────────────────────────────────────
# PREDICTIVE AIMING KERNLOGIK
# ─────────────────────────────────────────────────────────────────────────────

## Berechnet die Zielrichtung mit Vorhalt (Predictive Aiming) oder Pure Pursuit
## Gibt den normalisierten Zielrichtungsvektor zurück
func _calculate_aim_direction(target: Node3D, current_pos: Vector3, 
							   torpedo_speed: float, delta: float) -> Vector3:
	var to_target: Vector3 = target.global_position - current_pos
	var dist_to_target: float = to_target.length()
	
	# Wenn kein Target mehr gültig → geradeaus
	if not is_instance_valid(target):
		return -global_transform.basis.z
	
	# Proximity Detonation check
	if dist_to_target <= proximity_detonate_radius:
		_on_hit_target(target)
		return Vector3.ZERO  # Signalisiert Abbruch
	
	# Direkter Treffer bei sehr kleinen Distanzen
	if dist_to_target < predictive_min_distance * 0.5:
		return to_target.normalized()
	
	# ── Pure Pursuit (kein Vorhalt) ──────────────────────────────────────────
	if not use_predictive_aiming:
		return to_target.normalized()
	
	# ── Geschwindigkeit des Ziels berechnen ──────────────────────────────────
	var target_velocity: Vector3 = Vector3.ZERO
	
	# Methode 1: Direkte velocity-Property (CharacterBody3D, RigidBody3D)
	if "velocity" in target:
		target_velocity = target.velocity
	
	# Methode 2: Positionsdifferenz (für alle Node3D)
	var current_target_pos: Vector3 = target.global_position
	if _last_target_pos != Vector3.ZERO:
		var frame_velocity: Vector3 = (current_target_pos - _last_target_pos) / max(delta, 0.016)
		# Smoothing mit Exponential Moving Average (EMA)
		_target_vel_smooth = _target_vel_smooth.lerp(frame_velocity, 0.3)
		target_velocity = _target_vel_smooth
	
	_last_target_pos = current_target_pos
	
	# Keine relevante Bewegung → Pure Pursuit
	if target_velocity.length() < 1.0:
		return to_target.normalized()
	
	# ── Dynamische Vorhalt-Zeit berechnen ────────────────────────────────────
	# Basis: Distanz / Torpedo-Geschwindigkeit
	var base_prediction_time: float = dist_to_target / max(torpedo_speed, 1.0)
	
	# Begrenzung auf max_prediction_time (verhindert absurde Vorhersagen)
	var prediction_time: float = min(base_prediction_time, max_prediction_time)
	
	# Dynamische Anpassung basierend auf:
	# - Distanz zum Ziel (näher = weniger Vorhalt)
	# - Relativgeschwindigkeit (schneller = weniger Vorhalt)
	var distance_factor: float = clamp(dist_to_target / predictive_min_distance, 0.3, 1.0)
	var relative_speed: float = target_velocity.length() / max(torpedo_speed, 1.0)
	var speed_factor: float = clamp(1.0 - relative_speed * 0.5, 0.4, 1.0)
	
	# Finaler Vorhalt-Faktor (Export-Variable * dynamische Faktoren)
	var final_factor: float = prediction_factor * distance_factor * speed_factor
	prediction_time *= final_factor
	
	# ── Vorhersage der Zielposition ──────────────────────────────────────────
	var predicted_pos: Vector3 = target.global_position + target_velocity * prediction_time
	
	# Sicherheitscheck: Vorhersage nicht zu weit weg
	var predicted_dist: float = (predicted_pos - current_pos).length()
	if predicted_dist > torpedo_data.max_range * 1.2:
		return to_target.normalized()
	
	# ── Zielrichtung berechnen ───────────────────────────────────────────────
	var aim_dir: Vector3 = (predicted_pos - current_pos).normalized()
	
	# Debug-Ausgabe
	if debug_colors and Engine.is_editor_hint() == false:
		print("[AIM] dist=%.1f | pred_time=%.2f | factor=%.2f | vel=%.1f | dir=%s" % [
			dist_to_target, prediction_time, final_factor, 
			target_velocity.length(), aim_dir.snappedf(0.1)])
	
	return aim_dir


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS
# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not torpedo_data or _despawning:
		return

	# ── Licht pulsieren ───────────────────────────────────────────────────────
	if _core_light:
		_core_light.light_energy = lerpf(
			_core_light.light_energy, _target_core_energy, delta * 12.0)
	if _beam_light:
		_beam_light.light_energy = lerpf(
			_beam_light.light_energy, _target_beam_energy, delta * 10.0)
		_beam_light.spot_angle = lerpf(
			_beam_light.spot_angle, randf_range(22.0, 28.0), delta * 8.0)

	# ── Spikes rotieren ───────────────────────────────────────────────────────
	if _light_spikes:
		_light_spikes.rotate_z(deg_to_rad(90.0) * delta)
	if _spike_pivot:
		_spike_pivot.rotate_z(deg_to_rad(180.0) * delta)
	if _spike_material:
		_spike_rotation += delta * 1.5
		_spike_material.set_shader_parameter("rotation", _spike_rotation)
		if _core_light and torpedo_data:
			var norm: float = _core_light.light_energy / max(torpedo_data.pulse_energy_max, 0.01)
			_spike_material.set_shader_parameter("intensity", lerpf(0.4, 1.0, norm))

	# ── Lifetime ──────────────────────────────────────────────────────────────
	_lifetime += delta
	if _lifetime >= torpedo_data.lifetime:
		_on_lifetime_expired()
		return

	# ── Arm-Distanz + Homing ──────────────────────────────────────────────────
	if not _armed:
		if _traveled >= _arm_distance:
			_armed = true
		# Während Arm-Phase: Richtung beibehalten, kein Homing

	elif is_instance_valid(target_node) and torpedo_data.turn_rate_deg > 0.0:

		# FIX: Zerstörtes Target sofort loslassen
		var target_sc := _find_ship_controller(target_node)
		if target_sc and target_sc.get_hull_integrity() <= 0.0:
			target_node = null
			return

		var current_fwd: Vector3 = -global_transform.basis.z
		var dist_to_target: float = global_position.distance_to(target_node.global_position)
		
		# Proximity Detonation
		if dist_to_target <= proximity_detonate_radius:
			_on_hit_target(target_node)
			return
		
		# ── NEU: Predictive Aiming ───────────────────────────────────────────
		var aim_dir: Vector3 = _calculate_aim_direction(target_node, global_position, 
														 torpedo_data.speed, delta)
		
		# Wenn aim_dir Null ist (Proximity Detonation hat getriggert), abbrechen
		if aim_dir == Vector3.ZERO:
			return
		
		# ── Dynamische Turn-Rate ─────────────────────────────────────────────
		var angle_error: float = rad_to_deg(current_fwd.angle_to(aim_dir))
		
		# Intelligenter Angle Boost:
		# - Großer Fehler (>45°) → starke Erhöhung (bis 5x)
		# - Kleiner Fehler (<10°) → normale Turn-Rate
		var angle_boost: float = clamp(angle_error / 20.0, 1.0, 5.0)
		
		# Distanz-Boost: Je näher am Ziel, desto aggressiver
		var dist_boost: float = clamp(
			1.0 + (1.0 - dist_to_target / max(torpedo_data.max_range, 1.0)) * 3.0, 
			1.0, 4.0)
		
		var effective_turn: float = torpedo_data.turn_rate_deg * angle_boost * dist_boost
		var turn_rad: float = deg_to_rad(effective_turn) * delta
		
		# Sanfte Rotation mit SLERP
		var new_fwd: Vector3 = current_fwd.slerp(aim_dir, clamp(turn_rad, 0.0, 1.0))
		if new_fwd.length_squared() > 0.001:
			global_transform.basis = Basis.looking_at(new_fwd.normalized(), Vector3.UP)

	# ── Velocity Boost: lineares Abklingen ────────────────────────────────────
	var boost: Vector3 = Vector3.ZERO
	if _initial_boost.length_squared() > 0.001 and velocity_decay_time > 0.0:
		_boost_elapsed += delta
		var decay_ratio: float = clamp(_boost_elapsed / velocity_decay_time, 0.0, 1.0)
		boost = _initial_boost * (1.0 - decay_ratio)

	# ── Schild-Ellipsoid-Check (vor Raycast) ────────────────────────────────
	if is_instance_valid(target_node):
		var sc_check := _find_ship_controller(target_node)
		if sc_check and sc_check != _find_ship_controller(owner_ship):
			var ss: ShieldSystem = sc_check.shield_system if "shield_system" in sc_check else null
			if ss and ss.is_active():
				var radii: Vector3 = ss.get_shield_radii()
				var local: Vector3 = ss.global_transform.affine_inverse() * global_position
				var ex: float = (local.x / max(radii.x, 0.01))
				var ey: float = (local.y / max(radii.y, 0.01))
				var ez: float = (local.z / max(radii.z, 0.01))
				if ex * ex + ey * ey + ez * ez <= 1.0:
					var hull_sc := _find_ship_controller(target_node)
					if hull_sc:
						hull_sc.receive_damage(torpedo_data.damage, global_position,
							"torpedo", torpedo_data.torpedo_color)
					_stop_particles_immediately()
					_spawn_explosion(target_node)
					_despawn()
					return

	# ── Bewegung ──────────────────────────────────────────────────────────────
	var move_dir: Vector3       = -global_transform.basis.z
	var total_velocity: Vector3 = move_dir * torpedo_data.speed + boost
	var to_pos: Vector3         = global_position + total_velocity * delta

	# Raycast mit Backstep (Penetrations-Fix)
	var step_size: float  = total_velocity.length() * delta
	var back_dist: float  = min(step_size * 0.5, 3.0)
	var from_pos: Vector3 = global_position - move_dir * back_dist

	var query := PhysicsRayQueryParameters3D.create(
		from_pos, to_pos, torpedo_data.collision_mask)
	query.exclude             = exclude_rids
	query.collide_with_areas  = true
	query.collide_with_bodies = true
	query.hit_back_faces      = true

	var result: Dictionary = _space.intersect_ray(query)
	if not result.is_empty():
		_on_hit(result)
		return

	global_position = to_pos
	_traveled      += total_velocity.length() * delta


# ─────────────────────────────────────────────────────────────────────────────
# REST DES CODES (unverändert ab hier)
# ─────────────────────────────────────────────────────────────────────────────

# ... [Der gesamte restliche Code bleibt exakt gleich] ...
# _on_hit, _on_hit_target, _on_lifetime_expired, _spawn_explosion,
# _stop_particles_immediately, _despawn, _apply_visuals, _apply_particle_colors,
# _find_shield_system, _find_ship_controller

func _on_hit(result: Dictionary) -> void:
	if _despawning:
		return
	var collider: Object  = result.get("collider")
	var hit_pos:  Vector3 = result.get("position", global_position)
	var hit_norm: Vector3 = result.get("normal",   Vector3.UP)

	if not collider:
		_despawn()
		return

	# Shield-Treffer – kein HIR, Particles sofort stoppen
	if collider is Area3D and collider.has_meta("shield_system"):
		var sc := _find_ship_controller(collider)
		if sc and sc != _find_ship_controller(owner_ship):
			sc.receive_damage(torpedo_data.damage, hit_pos,
				"torpedo", torpedo_data.torpedo_color)
		_stop_particles_immediately()
		_spawn_explosion(collider as Node)
		_despawn()
		return

	# Fallback Shield-Check über Parent-Baum
	var shield_sys := _find_shield_system(collider)
	if shield_sys and shield_sys.is_active():
		var sc := _find_ship_controller(collider)
		if sc and sc != _find_ship_controller(owner_ship):
			sc.receive_damage(torpedo_data.damage, hit_pos,
				"torpedo", torpedo_data.torpedo_color)
		_stop_particles_immediately()
		_spawn_explosion(collider as Node)
		_despawn()
		return

	# Hülle
	var sc := _find_ship_controller(collider)
	if sc and sc != _find_ship_controller(owner_ship):
		var hull_damage: float = sc.receive_damage(torpedo_data.damage, hit_pos,
			"torpedo", torpedo_data.torpedo_color)
		if hull_damage > 0.0:
			var hir := sc.find_child("HullImpactReceiver", true, false)
			if hir and hir.has_method("register_impact"):
				hir.register_impact(hit_pos, hit_norm)

	_spawn_explosion(collider as Node)
	_despawn()


func _on_hit_target(target: Node3D) -> void:
	if _despawning:
		return
	var hit_pos: Vector3 = target.global_position
	var sc := _find_ship_controller(target)
	if sc and sc != _find_ship_controller(owner_ship):
		var hull_damage: float = sc.receive_damage(torpedo_data.damage, hit_pos,
			"torpedo", torpedo_data.torpedo_color)
		if hull_damage > 0.0:
			var hir := sc.find_child("HullImpactReceiver", true, false)
			if hir and hir.has_method("register_impact"):
				hir.register_impact(hit_pos, Vector3.UP)
	_spawn_explosion(target)
	_despawn()


func _on_lifetime_expired() -> void:
	if _despawning:
		return
	_spawn_explosion()
	_despawn()


func _spawn_explosion(hit_target: Node = null) -> void:
	if not torpedo_data:
		if debug_explosion: print("[Torpedo|EXPLOSION] ❌ torpedo_data NULL")
		return
	if not torpedo_data.explosion_scene:
		if debug_explosion: print("[Torpedo|EXPLOSION] ❌ explosion_scene nicht gesetzt")
		return

	var explosion: Node3D = torpedo_data.explosion_scene.instantiate() as Node3D
	if not explosion:
		if debug_explosion: print("[Torpedo|EXPLOSION] ❌ instantiate() fehlgeschlagen")
		return

	var exp_scale: float = torpedo_data.explosion_scale if "explosion_scale" in torpedo_data else 1.0
	var hit_pos: Vector3  = global_position
	var parent_node: Node = get_tree().current_scene

	var target_to_use: Node = hit_target if is_instance_valid(hit_target) else target_node
	if is_instance_valid(target_to_use):
		var sc := _find_ship_controller(target_to_use)
		if sc and is_instance_valid(sc):
			parent_node = sc.get_parent()

	explosion.scale = Vector3.ONE * clampf(exp_scale, 0.1, 10.0)

	if debug_explosion and "debug_mode" in explosion:
		explosion.set("debug_mode", true)

	parent_node.add_child(explosion)
	explosion.global_position = hit_pos

	if explosion.has_method("initialize"):
		explosion.initialize(exp_scale)

	if debug_explosion:
		print("[Torpedo|EXPLOSION] ══════════════════════")
		print("  explosion_scale : %.2f" % exp_scale)
		print("  explosion.scale : %s" % explosion.scale)
		print("  parent_node     : %s" % parent_node.name)
		print("  global_pos      : %s" % hit_pos.snappedf(1.0))
		print("  has initialize(): %s" % explosion.has_method("initialize"))
		print("  script          : %s" % (explosion.get_script().resource_path if explosion.get_script() else "kein Script"))
		print("[Torpedo|EXPLOSION] ══════════════════════")


func _stop_particles_immediately() -> void:
	visible = false
	if _trail and is_instance_valid(_trail):
		_trail.emitting = false


func _despawn() -> void:
	if _despawning:
		return
	_despawning = true

	if _timer:
		_timer.stop()

	_stop_particles_immediately()

	await get_tree().create_timer(0.1).timeout
	if is_instance_valid(self):
		queue_free()


func _apply_visuals() -> void:
	if not torpedo_data:
		return
	var col: Color = torpedo_data.torpedo_color

	if _core_mesh:
		var mat := StandardMaterial3D.new()
		mat.shading_mode             = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color             = col
		_core_mesh.material_override = mat

	if _core_light:
		_core_light.light_color  = col
		_core_light.light_energy = torpedo_data.pulse_energy_min

	if _beam_light:
		_beam_light.light_color  = col
		_beam_light.light_energy = torpedo_data.pulse_energy_min * 2.0

	_target_core_energy = torpedo_data.pulse_energy_max
	_target_beam_energy = torpedo_data.pulse_energy_max * 2.0

	if _spike_material:
		_spike_material.set_shader_parameter("spike_color",
			Vector4(col.r, col.g, col.b, 1.0))

	if torpedo_data:
		var pcol: Color = torpedo_data.trail_color \
			if "trail_color" in torpedo_data else torpedo_data.torpedo_color
		_apply_particle_colors(pcol)


func _apply_particle_colors(col: Color) -> void:
	var all_particles := find_children("*", "GPUParticles3D", true, false)

	if debug_colors:
		print("[Torpedo|COLOR] Farbe setzen: %s | Particles: %d" % [col, all_particles.size()])

	for child in all_particles:
		var particles := child as GPUParticles3D
		if not particles:
			continue

		if particles.material_override:
			if particles.material_override is ShaderMaterial:
				var new_mat: ShaderMaterial = particles.material_override.duplicate() as ShaderMaterial
				new_mat.set_shader_parameter("color", col)
				particles.material_override = new_mat
				if debug_colors:
					print("[Torpedo|COLOR]   '%s' → material_override ShaderMaterial ✓" % particles.name)
			elif particles.material_override is StandardMaterial3D:
				var new_mat: StandardMaterial3D = particles.material_override.duplicate() as StandardMaterial3D
				new_mat.albedo_color = col
				new_mat.emission     = col
				particles.material_override = new_mat
				if debug_colors:
					print("[Torpedo|COLOR]   '%s' → material_override StandardMaterial3D ✓" % particles.name)
		else:
			if debug_colors:
				print("[Torpedo|COLOR]   '%s' → kein material_override!" % particles.name)


func _find_shield_system(node: Object) -> ShieldSystem:
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


func _find_ship_controller(node: Variant) -> ShipController:
	if not is_instance_valid(node):
		return null
	var current: Node = node as Node
	while current and is_instance_valid(current):
		if current is ShipController:
			return current as ShipController
		if current.has_meta("ship_controller"):
			return current.get_meta("ship_controller") as ShipController
		current = current.get_parent()
	return null
