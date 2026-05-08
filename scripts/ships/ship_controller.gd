# res://scripts/ship_controller.gd
# Zentrale Steuerung eines Schiffes.
# Verwaltet Waffen, Schild, Schadenssystem und Targeting.
# Wird vom PlayerController (oder einer KI) über fire_phasers() etc. angesteuert.
extends Node3D
class_name ShipController

# ===== SIGNALS =====
signal weapons_fired(weapon_type: WeaponMount.WeaponType, count: int)
signal all_weapons_ready()
signal ship_speed_updated(current_speed: float, max_speed: float)
## damage = Gesamtschaden | hull_damage = Schaden der Hülle erreicht hat (nach Schild)
signal ship_damaged(damage: float, hull_damage: float, impact_point: Vector3)
signal ship_destroyed()

# ===== EXPORTS =====
@export var ship_data: ShipData

@export_group("Model Orientation (Blender Import)")
## Wenn true: Modell ist um 180° um Y gedreht (Blender-Standard: +Z vorwärts)
@export var invert_model_forward: bool = false:
	set(value):
		invert_model_forward = value
		_apply_model_rotation_if_needed()
		notify_property_list_changed()

@export_group("VFX")
## Explosions-Szene, die beim Schiffstod gespawnt wird.
@export var explosion_scene: PackedScene
## Verzögerung in Sekunden zwischen Zerstörung und queue_free().
@export var destruction_delay: float = 2.0
## Größe der Explosion – pro Schiff im Inspector einstellen.
@export var explosion_size: float = 10.0
## Marker3D in der Ship-Scene der den visuellen Mittelpunkt markiert.
## Wird als Spawn-Position der Explosion verwendet.
## Fallback: ShipController-Origin wenn nicht gesetzt.
@export var explosion_origin: Marker3D
## Verzögerung in Sekunden bevor die Shockwave ausgelöst wird.
## Nutze diese um die Welle mit dem Höhepunkt der WindUp-Animation zu synchronisieren.
@export var shockwave_delay: float = 0.0
## Trümmer-Konfiguration als Resource. Eine .tres pro Schiffsklasse oder
## Faction. Leer lassen = kein Debris-Burst.
@export var debris_data: ExplosionDebrisData = null
## Faction-Tint für die Trümmer (multiplikativ auf Material-Farbe).
## Color.WHITE = keine Tönung (Default).
@export var debris_color_tint: Color = Color.WHITE

@export_group("Hit Reaction")
## Unter diesem Hüll-Integritätswert (0.0–1.0) reagiert das Schiff auf Treffer.
## 0.3 = unter 30% HP aktiv. 0.0 = immer aktiv, 1.0 = von Beginn an aktiv.
@export_range(0.0, 1.0) var hit_reaction_threshold: float = 0.3
## Kippwinkel in Grad beim Treffer – Schiff rotiert um den eigenen Ursprung.
@export var hit_reaction_tilt: float = 8.0
## Sekunden bis das Schiff sich nach dem Treffer wieder aufrichtet.
@export var hit_reaction_recovery: float = 0.4

@export_group("Debug")
@export var show_debug: bool = true
## Wenn gesetzt, wird dieses Flag im DebugManager abgefragt (z.B. "ai.ship")
@export var debug_category: String = "ship.logic"

@export_group("Systeme")
## CloakComponent für dieses Schiff. Im Inspector zuweisen — Node unter ShipController.
## Nicht zugewiesen = Schiff kann nicht tarnen (kein Fehler, nur kein Cloak).
@export var cloak_component: CloakComponent

@export_group("Effects")
@export var thruster_vfx: Node3D

# ===== INTERN =====
var weapon_mounts: Array = [] # WeaponMount + WingDisruptorMount
var model:            Node3D
var targeting_system: TargetingSystem
var shield_system:    ShieldSystem
var movement_comp:    MovementComponent
## Optional: CloakComponent als Subsystem. NULL wenn das Schiff nicht
## tarnen kann (kein Node im Inspector zugewiesen).
# cloak_component ist jetzt @export — siehe oben unter "Systeme"
var _is_alive:        bool     = true
## Pro-Instanz-Kopie der HullData – verhindert shared-Resource-Bug
## wenn mehrere Schiffe desselben Typs in der Szene sind.
var _local_hull_data: HullData = null
## Einmalige Warning-Sperre für RelationshipResolver-Lookup
var _resolver_missing_warned: bool = false

# ===== SHORTCUTS =====
var ship_name: String:
	get: return ship_data.ship_name if ship_data else "UNKNOWN"
var registry: String:
	get: return ship_data.registry if ship_data else ""
var stats: ShipStats:
	get: return ship_data.stats if ship_data else null
var shield_data: ShieldData:
	get: return ship_data.shield if ship_data else null

## HullData immer über die lokale Kopie lesen (nie direkt ship_data.hull).
var hull_data: HullData:
	get: return _local_hull_data

## Kompatibilitäts-Shortcuts für externe Systeme (z.B. HullImpactReceiver).
var hull_hp: float:
	get: return _local_hull_data.current_hp if _local_hull_data else 0.0
var max_hull_hp: float:
	get: return _local_hull_data.max_hp if _local_hull_data else 0.0


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	if not ship_data:
		_dbg_error("Kein ship_data zugewiesen!")
		return

	_dbg("[SC-DIAG] node.name='%s' | ship_data=%s | script=%s" % [
		name, ship_data, get_script().resource_path if get_script() else "NULL"
	])

	_setup_metadata()
	_register_faction_group()

	model = _find_model()
	_dbg("  model: %s" % (model.name if model else "❌ NULL – kein Model-Node gefunden!"))
	targeting_system = find_child("TargetingSystem", true, false) as TargetingSystem
	movement_comp = find_child("MovementComponent", true, false) as MovementComponent
	if model and movement_comp:
		movement_comp.init_tilt(model)

	_setup_hull_hp()
	_setup_collision_layers()
	_find_weapon_mounts()
	_connect_targeting_signals()
	_connect_movement_signal()

	call_deferred("_setup_shield_deferred")


func _setup_shield_deferred() -> void:
	_setup_shield()
	_setup_cloak()

	_dbg("═══════════════════════════════════", true)  # force=true für wichtige Infos
	_dbg("  SHIP : %s | %s [%s]" % [ship_name, registry, ship_data.faction], true)
	_dbg("  Stats: max_speed=%.0f | shield=%.0f HP | hull=%.0f HP" % [
		stats.max_speed if stats else 0.0,
		shield_data.max_strength if shield_data else 0.0,
		max_hull_hp
	], true)
	_dbg("  Mounts: %d | Targeting: %s | Shield: %s | Movement: %s" % [
		weapon_mounts.size(),
		"✓" if targeting_system else "❌",
		"✓" if shield_system else "❌",
		"✓" if movement_comp else "❌"
	], true)
	_dbg("═══════════════════════════════════", true)

# ─────────────────────────────────────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────────────────────────────────────

func _setup_metadata() -> void:
	set_meta("ship_controller", self)
	set_meta("ship_root", self)
	_dbg("✅ Meta-Daten gesetzt")


## Sucht ShieldSystem in drei Ebenen:
## 1. Eigene Kinder  2. Geschwister-Nodes  3. Meta auf Parent
func _setup_shield() -> void:
	for child in find_children("*", "ShieldSystem", true, false):
		if child is ShieldSystem:
			shield_system = child
			break

	if not shield_system:
		var parent := get_parent()
		if parent:
			if parent.has_meta("shield_system"):
				var meta_ss: Variant = parent.get_meta("shield_system")
				if meta_ss is ShieldSystem:
					shield_system = meta_ss as ShieldSystem
					_dbg("🛡️ ShieldSystem via Parent-Meta gefunden")
			if not shield_system:
				for sibling in parent.find_children("*", "ShieldSystem", true, false):
					if sibling is ShieldSystem:
						shield_system = sibling
						break
				if shield_system:
					_dbg("🛡️ ShieldSystem als Geschwister-Node gefunden")

	if not shield_system:
		_dbg_warning("Kein ShieldSystem gefunden!")
		return

	if not ship_data.shield:
		_dbg("⚠️ ShieldSystem gefunden, aber ship_data.shield ist NULL!")
		return

	var local_shield_data: ShieldData = ship_data.shield.duplicate() as ShieldData
	local_shield_data.reset()

	shield_system.data = local_shield_data
	shield_system.show_debug = show_debug
	shield_system.set_meta("ship_controller", self)
	_connect_shield_signals()
	_dbg("✅ ShieldSystem bereit: %.0f HP (lokal dupliziert)" % local_shield_data.max_strength)


func _setup_hull_hp() -> void:
	if not ship_data or not ship_data.hull:
		push_warning("[ShipController|%s] Kein hull in ship_data! Lege HullData-Resource im Inspector an." % ship_name)
		return
	# FIX: Lokal duplizieren — NICHT zurück in ship_data schreiben!
	# ship_data ist eine shared Resource → alle Instanzen desselben Schiffstyps
	# würden sonst denselben current_hp-Wert teilen.
	_local_hull_data = ship_data.hull.duplicate() as HullData
	_local_hull_data.reset()
	_dbg("✅ Hull-HP: %.0f (lokal dupliziert)" % _local_hull_data.max_hp)


func _connect_movement_signal() -> void:
	if not movement_comp:
		_dbg("⚠️ Kein MovementComponent als Kind gefunden")
		return
	if not movement_comp.speed_updated.is_connected(_on_movement_speed_updated):
		movement_comp.speed_updated.connect(_on_movement_speed_updated)
	_dbg("✅ MovementComponent-Signal verbunden")


# ─────────────────────────────────────────────────────────────────────────────
# MODEL ORIENTATION (Blender vs Godot forward)
# ─────────────────────────────────────────────────────────────────────────────

var effective_forward: Vector3:
	get:
		var base_fwd = -global_transform.basis.z if not invert_model_forward \
			else global_transform.basis.z
		return base_fwd.normalized()

func get_effective_forward() -> Vector3:
	return effective_forward

func _apply_model_rotation_if_needed() -> void:
	if not model:
		return
	model.rotation_degrees.y = 180.0 if invert_model_forward else 0.0


# ─────────────────────────────────────────────────────────────────────────────
# SCHADENSSYSTEM
# ─────────────────────────────────────────────────────────────────────────────

func receive_damage(damage: float, impact_point: Vector3,
					damage_type: String = "phaser",
					beam_color: Color = Color(1.0, 0.5, 0.0)) -> float:
	return receive_damage_ex(damage, impact_point, damage_type, beam_color)[0]


func receive_damage_ex(damage: float, impact_point: Vector3,
					damage_type: String = "phaser",
					beam_color: Color = Color(1.0, 0.5, 0.0),
					hint_slot: int = -1) -> Array:
	if not _is_alive:
		return [0.0, -1]

	_dbg("📥 receive_damage: %.0f [%s]" % [damage, damage_type])

	# Cloak-Break: Treffer enttarnt das Schiff sofort (kanonisch + fair)
	if cloak_component and (cloak_component.is_cloaked() or cloak_component.is_transitioning()):
		_dbg("💥 Cloak durch Treffer gebrochen!")
		cloak_component.break_cloak("hit_received")

	var hull_damage: float = damage
	var slot_index:  int   = -1

	if shield_system and shield_system.is_active():
		var result: Array = shield_system.receive_hit_ex(damage, impact_point, beam_color, hint_slot, damage_type)
		hull_damage = result[0]
		slot_index  = result[1]
		_dbg("  → Schild absorbiert: %.0f | Overflow: %.0f" % [damage - hull_damage, hull_damage])
	else:
		_dbg("  → Kein Schild – voller Schaden an Hülle")

	if hull_damage > 0.0 and _local_hull_data:
		_local_hull_data.take_damage(hull_damage)
		_dbg("  → Hülle: %.0f / %.0f HP" % [_local_hull_data.current_hp, _local_hull_data.max_hp])
		# Hit Reaction: bei kritisch niedrigem Hüllschaden auf Treffer reagieren
		_apply_hit_reaction(hull_damage, impact_point)

	ship_damaged.emit(damage, hull_damage, impact_point)

	if _local_hull_data and not _local_hull_data.is_alive() and _is_alive:
		_on_ship_destroyed()

	return [hull_damage, slot_index]


## Kippt das Schiff bei kritischem Hüllzustand vom Einschlagspunkt weg.
## Nur Rotation um den eigenen Ursprung – kein Velocity-Push.
func _apply_hit_reaction(hull_damage: float, impact_point: Vector3) -> void:
	# Nur aktiv wenn Hüllintegrität unter dem Schwellwert liegt
	if get_hull_integrity() > hit_reaction_threshold:
		return
	# Kein MovementComponent → kein Effekt
	if not movement_comp:
		return
	# Kein nennenswerter Hüllschaden → ignorieren
	if hull_damage < 1.0:
		return

	# Richtung: weg vom Einschlagspunkt (nur für Tilt-Orientierung, kein Push)
	var push_dir: Vector3 = (global_position - impact_point)
	push_dir.y *= 0.2
	push_dir = push_dir.normalized()

	if push_dir == Vector3.ZERO:
		push_dir = global_transform.basis.x

	# Nur Tilt – das Schiff dreht sich kurz um den eigenen Ursprung, kein Versatz
	movement_comp.apply_shockwave_tilt(hit_reaction_tilt, hit_reaction_recovery, push_dir)


func get_hull_integrity() -> float:
	return _local_hull_data.get_integrity() if _local_hull_data else 0.0


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC SHIELD API
# ─────────────────────────────────────────────────────────────────────────────

func has_shield() -> bool:
	return shield_system != null

func is_shield_active() -> bool:
	return shield_system != null and shield_system.is_active()

func get_shield_system() -> ShieldSystem:
	return shield_system


# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS – INTERN
# ─────────────────────────────────────────────────────────────────────────────

func _connect_shield_signals() -> void:
	if not shield_system:
		return
	shield_system.shield_depleted.connect(_on_shield_depleted)
	shield_system.shield_recharged.connect(_on_shield_recharged)
	shield_system.shield_hit.connect(_on_shield_hit)

func _on_shield_hit(_impact_point: Vector3, damage: float, _overflow: float) -> void:
	_dbg("🛡️ Schild-Treffer: %.0f Schaden" % damage)

func _on_shield_depleted() -> void:
	_dbg("⚡ SCHILD ERSCHÖPFT!")

func _on_shield_recharged() -> void:
	_dbg("✅ Schild wieder aufgeladen")

func _on_movement_speed_updated(current: float, max_speed: float) -> void:
	var actual_max: float = stats.max_speed if stats else max_speed
	ship_speed_updated.emit(current, actual_max)


func _on_ship_destroyed() -> void:
	_is_alive = false
	_dbg("💥 SCHIFF ZERSTÖRT: %s" % ship_name)

	# 1. SHADER-VISUALISIERUNG (Zerfall des Schiffs-Modells)
	var visualizer: HullDamageVisualizer = null
	for child in find_children("*", "HullDamageVisualizer", true, false):
		visualizer = child as HullDamageVisualizer
		break

	if visualizer:
		_dbg("✅ HullDamageVisualizer gefunden: '%s'" % visualizer.name)
		visualizer.start_death_sequence()
	else:
		_dbg("⚠️ Kein HullDamageVisualizer gefunden — kein visueller Zerfall")

	# 3. AUFRÄUMEN & SIGNALE
	for group in get_groups():
		remove_from_group(group)

	ship_destroyed.emit()
	_destroy_sequence()
	_trigger_shockwave_delayed()


## Wartet shockwave_delay Sekunden, dann Shockwave – läuft parallel zur Explosion.
func _trigger_shockwave_delayed() -> void:
	if shockwave_delay > 0.0:
		_dbg("⏳ Shockwave in %.2fs" % shockwave_delay)
		await get_tree().create_timer(shockwave_delay).timeout
	if is_instance_valid(self):
		_trigger_shockwave()

func _trigger_shockwave() -> void:
	_dbg("══════ SHOCKWAVE TRIGGER (delay=%.2fs) ══════" % shockwave_delay, true)

	if not ship_data:
		_dbg("❌ ABBRUCH: ship_data ist null", true)
		return

	if not "shockwave_data" in ship_data:
		_dbg("❌ ABBRUCH: ShipData hat kein 'shockwave_data'-Feld (ShockwaveData.gd geladen?)", true)
		return

	var sw_data: ShockwaveData = ship_data.shockwave_data
	if not sw_data:
		_dbg("❌ ABBRUCH: shockwave_data ist NULL – im Inspector eine ShockwaveData-Resource anlegen!", true)
		return

	_dbg("✅ ShockwaveData geladen:", true)
	_dbg("  radius=%.0f | force=%.1f | tilt=%.1f° | recovery=%.2fs" % [
		sw_data.shockwave_radius, sw_data.shockwave_force,
		sw_data.shockwave_tilt_angle, sw_data.shockwave_recovery_time
	], true)

	var excluded: CharacterBody3D = get_parent() as CharacterBody3D
	_dbg("excluded node: %s" % (excluded.name if excluded else "NULL (kein CharacterBody3D-Parent!)"), true)

	var origin: Vector3 = global_position
	var ships: Array[Node] = get_tree().get_nodes_in_group("ships")
	_dbg("Schiffe in Gruppe 'ships': %d" % ships.size(), true)

	if ships.is_empty():
		_dbg("⚠️  Gruppe 'ships' ist leer – sind alle Schiffe per add_to_group('ships') registriert?", true)

	var hit_count: int = 0

	for node: Node in ships:
		if node == excluded or node == self:
			_dbg("  [SKIP] '%s' → eigenes Schiff" % node.name)
			continue

		if not node is CharacterBody3D:
			_dbg("  [SKIP] '%s' → kein CharacterBody3D (ist: %s)" % [node.name, node.get_class()])
			continue

		var body := node as CharacterBody3D
		var diff: Vector3 = body.global_position - origin
		var dist: float = diff.length()

		_dbg("  [CHECK] '%s' | dist=%.1f | radius=%.0f" % [body.name, dist, sw_data.shockwave_radius])

		if dist <= 0.0:
			_dbg("    → SKIP: dist=0 (Schiff sitzt exakt auf Origin?)")
			continue
		if dist > sw_data.shockwave_radius:
			_dbg("    → AUSSERHALB Radius – kein Effekt")
			continue

		var falloff: float = 1.0 - (dist / sw_data.shockwave_radius)
		var push_dir: Vector3 = diff.normalized()
		var push_force: float = sw_data.shockwave_force * falloff
		var tilt_deg: float = sw_data.shockwave_tilt_angle * falloff

		var mc: MovementComponent = _find_movement_component(body)
		if mc:
			mc.apply_shockwave_push(push_dir * push_force)
			mc.apply_shockwave_tilt(tilt_deg, sw_data.shockwave_recovery_time, push_dir)
			_dbg("    → falloff=%.2f | push=%.1f | tilt=%.1f° → via MovementComponent" % [falloff, push_force, tilt_deg])
		else:
			body.velocity += push_dir * push_force
			_dbg("    → falloff=%.2f | push=%.1f (Fallback: kein MC – Effekt nur 1 Frame!)" % [falloff, push_force])

		hit_count += 1

	_dbg("══ Ergebnis: %d Schiff(e) getroffen ══════\n" % hit_count, true)

func _destroy_sequence() -> void:
	_spawn_explosion()
	_dbg("⏳ Warte %.1f s bevor queue_free()" % destruction_delay)
	await get_tree().create_timer(destruction_delay).timeout
	if is_instance_valid(self):
		queue_free()

func _spawn_explosion() -> void:
	if not explosion_scene:
		return

	var e := explosion_scene.instantiate() as Node3D
	get_parent().add_child(e)

	# Spawn-Position: Marker3D wenn gesetzt, sonst ShipController-Origin
	if explosion_origin and is_instance_valid(explosion_origin):
		e.global_position = explosion_origin.global_position
		_dbg("🚀 Explosion an Marker3D-Position gespawnt")
	else:
		e.global_position = global_position

	# initialize() übernimmt Skalierung, Partikel-Scaling, Shockwave-Delay
	# und Debris-Burst — kein manuelles e.scale mehr nötig.
	if e.has_method("initialize"):
		e.initialize(explosion_size, shockwave_delay, debris_data, debris_color_tint)
		_dbg("🚀 Explosion.initialize(size=%.1f, sw_delay=%.2fs)" % [explosion_size, shockwave_delay])
	else:
		# Fallback: Explosion-Scene hat kein initialize() (altes Format)
		e.scale = Vector3.ONE * explosion_size
		push_warning("[ShipController|%s] ExplosionEffect hat kein initialize() — nur Node-Scale gesetzt." % ship_name)

	_start_explosion_animation(e)

func _start_explosion_animation(explosion: Node3D) -> void:
	var found_ap := false
	for child in explosion.find_children("*", "AnimationPlayer", true, false):
		var ap := child as AnimationPlayer
		if ap.is_playing():
			found_ap = true
			continue

		var anim: String = ""
		if ap.autoplay != "" and ap.autoplay != "RESET":
			anim = ap.autoplay
		else:
			for a in ap.get_animation_list():
				if a != "RESET":
					anim = a
					break

		if anim != "":
			ap.play(anim)
			found_ap = true
			_dbg("AnimationPlayer '%s' gestartet: '%s'" % [ap.name, anim])
		else:
			_dbg_warning("AnimationPlayer '%s' hat keine spielbare Animation!" % ap.name)

	if not found_ap:
		_dbg_warning("Kein AnimationPlayer in Explosion-Scene gefunden!")

# ─────────────────────────────────────────────────────────────────────────────
# TARGETING
# ─────────────────────────────────────────────────────────────────────────────

func _connect_targeting_signals() -> void:
	if not targeting_system:
		return
	targeting_system.target_locked.connect(_on_target_locked)
	targeting_system.target_lock_released.connect(_on_target_lock_released)
	targeting_system.targeting_mode_changed.connect(_on_targeting_mode_changed)
	_dbg("✅ Targeting-Signals verbunden")

func _on_target_locked(target: Node3D) -> void:
	_dbg("🔒 Target locked: %s" % target.name)

func _on_target_lock_released() -> void:
	_dbg("🔓 Target lock released")

func _on_targeting_mode_changed(mode: TargetingSystem.Mode) -> void:
	_dbg("Mode → %s" % TargetingSystem.Mode.keys()[mode])


# ─────────────────────────────────────────────────────────────────────────────
# WAFFENSTEUERUNG
# ─────────────────────────────────────────────────────────────────────────────

func fire_phasers(override_target: Node3D = null) -> int:
	var pos: Vector3 = _resolve_fire_position(override_target)
	var count: int   = _fire_weapons_of_type(WeaponMount.WeaponType.PHASER,    pos, override_target)
	count           += _fire_weapons_of_type(WeaponMount.WeaponType.DISRUPTOR, pos, override_target)
	return count

func fire_torpedos(override_target: Node3D = null) -> int:
	var pos: Vector3 = _resolve_fire_position(override_target)
	return _fire_weapons_of_type(WeaponMount.WeaponType.TORPEDO, pos, override_target)

func fire_phasers_at(target_pos: Vector3) -> int:
	return _fire_weapons_of_type(WeaponMount.WeaponType.PHASER, target_pos)

func fire_torpedos_at(target_pos: Vector3) -> int:
	return _fire_weapons_of_type(WeaponMount.WeaponType.TORPEDO, target_pos)

func fire_all_weapons(override_target: Node3D = null) -> Dictionary:
	return {"beams": fire_phasers(override_target), "torpedos": fire_torpedos(override_target)}


func _resolve_fire_position(override_target: Node3D) -> Vector3:
	if override_target and is_instance_valid(override_target):
		return override_target.global_position
	if targeting_system:
		return targeting_system.get_fire_position()
	push_warning("[ShipController|%s] Kein Ziel und kein TargetingSystem!" % ship_name)
	return global_position

func _fire_weapons_of_type(weapon_type: WeaponMount.WeaponType,
							target_pos: Vector3,
							override_tracking: Node3D = null) -> int:
	if weapon_mounts.is_empty():
		return 0

	var candidates: Array[Node3D] = []
	if override_tracking and is_instance_valid(override_tracking):
		candidates = [override_tracking]
	elif targeting_system:
		var multi := targeting_system.get_multi_targets()
		if multi.size() > 0:
			for t in multi:
				if is_instance_valid(t):
					candidates.append(t)
		elif targeting_system.get_mode() == TargetingSystem.Mode.TARGET_LOCK:
			var lt := targeting_system.get_locked_target()
			if is_instance_valid(lt):
				candidates = [lt]

	var fired_count: int = 0
	# Dedupliziert notify_attack-Aufrufe pro Feuer-Salve: wenn 3 Phaser-Mounts
	# auf dasselbe Ziel schießen, alarmieren wir die Allies trotzdem nur 1x.
	var notified_victims: Array[Node3D] = []

	for mount in weapon_mounts:
		# FIX: duck-typing statt fester WeaponMount-Typ
		if not mount.has_method("get_weapon_type"):
			continue
		if mount.get_weapon_type() != weapon_type:
			continue
		if not mount.is_ready_to_fire():
			continue

		if candidates.is_empty():
			if mount.fire_at(target_pos, INF, false, null):
				fired_count += 1
			continue

		var best_target: Node3D = _pick_best_target_for_mount(mount, candidates)
		if not best_target:
			continue

		if mount.fire_at(best_target.global_position, INF, false, best_target):
			fired_count += 1
			# ASSIST-MECHANIK: Resolver informieren, damit Allies des Opfers
			# Aggro auf uns bekommen (gleiche Fraktion + im Radius).
			if not notified_victims.has(best_target):
				notified_victims.append(best_target)
				_notify_attack_on(best_target)

	if fired_count > 0:
		weapons_fired.emit(weapon_type, fired_count)
	return fired_count


## Defensiver Aufruf von RelationshipResolver.notify_attack().
## Bleibt funktionsfähig auch wenn der Resolver-Autoload fehlt.
func _notify_attack_on(victim: Node3D) -> void:
	if not victim or not is_instance_valid(victim):
		return
	var resolver: Node = get_tree().root.get_node_or_null("RelationshipResolver")
	if not resolver:
		if not _resolver_missing_warned:
			_resolver_missing_warned = true
			_dbg_warning("RelationshipResolver-Autoload nicht gefunden – Assist-Mechanik inaktiv! Prüfe Project Settings → AutoLoad.")
		return
	if not resolver.has_method("notify_attack"):
		if not _resolver_missing_warned:
			_resolver_missing_warned = true
			_dbg_warning("RelationshipResolver kennt notify_attack() nicht – veraltete Version?")
		return

	var dm = get_tree().root.get_node_or_null("DebugManager")
	if dm and dm.has_method("get_flag") and dm.get_flag("ai.resolver"):
		_dbg("_notify_attack_on → Resolver.notify_attack(self, '%s')" % victim.name)

	resolver.notify_attack(self, victim)

func _pick_best_target_for_mount(mount: Node3D,  # FIX: Node3D statt WeaponMount
								candidates: Array[Node3D]) -> Node3D:
	var best:      Node3D = null
	var best_dist: float  = INF
	for target in candidates:
		if not is_instance_valid(target):
			continue
		# is_target_node_in_arc existiert auf beiden Mount-Typen
		if mount.has_method("is_target_node_in_arc") and \
		   not mount.is_target_node_in_arc(target):
			continue
		var d: float = mount.global_position.distance_to(target.global_position)
		if d < best_dist:
			best_dist = d
			best      = target
	return best

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS – INTERN
# ─────────────────────────────────────────────────────────────────────────────

## Sucht MovementComponent in direkten Kindern eines CharacterBody3D
## (wird für den Shockwave-Tilt auf fremden Schiffen gebraucht).
func _find_movement_component(body: CharacterBody3D) -> MovementComponent:
	for child: Node in body.get_children():
		if child is MovementComponent:
			return child as MovementComponent
		# ShipController ist Kind des CharacterBody3D → dort suchen
		if child is ShipController:
			var sc := child as ShipController
			if sc.movement_comp:
				return sc.movement_comp
	return null


func _find_model() -> Node3D:
	var m: Node3D = get_node_or_null("Model")
	if m:
		return m
	var parent := get_parent()
	if parent:
		m = parent.get_node_or_null("Model") as Node3D
		if m:
			return m
		for child in parent.get_children():
			if child is MeshInstance3D:
				return child
	for child in get_children():
		if child is MeshInstance3D:
			return child
	return null

func _find_weapon_mounts() -> void:
	weapon_mounts.clear()
	var search_root: Node = self
	var _parent := get_parent()
	if _parent and _parent != get_tree().current_scene and _parent != get_tree().root:
		search_root = _parent

	_dbg("_find_weapon_mounts() | search_root='%s'" % search_root.name)

	for child in search_root.find_children("*", "Node3D", true, false):
		if not child.has_method("get_weapon_type"):
			continue
		if not child.has_method("is_ready_to_fire"):
			continue
		if not child.has_method("fire_at"):
			continue

		if weapon_mounts.has(child):
			continue

		weapon_mounts.append(child)

		if child is WeaponMount:
			child.set_meta("ship_parent", self)

		_dbg("  ✓ Mount gefunden: '%s' [%s] | type=%s | ready=%s" % [
			child.name,
			child.get_class(),
			WeaponMount.WeaponType.keys()[child.get_weapon_type()],
			child.is_ready_to_fire()
		])

	_dbg("weapon_mounts gesamt: %d | davon Torpedos: %d" % [
		weapon_mounts.size(),
		weapon_mounts.filter(func(m): return m.get_weapon_type() == WeaponMount.WeaponType.TORPEDO).size()
	])

	if weapon_mounts.is_empty():
		_dbg_warning("Keine WeaponMounts gefunden!")
		return

	_apply_weapon_data_to_mounts()


# ─────────────────────────────────────────────────────────────────────────────
# WEAPON DATA SETUP (Override-Pattern)
# ─────────────────────────────────────────────────────────────────────────────

## Wendet Waffen-Daten auf alle Mounts an. Priorität:
##   1. mount.X_data_override     (im Inspector pro Mount gesetzt → Sonderfall)
##   2. ship_data.X_data          (zentral, gilt für alle Mounts dieses Typs)
## Mount-spezifische Felder (Position, Arc, Marker) bleiben pro Mount im Inspector.
##
## Dispatch nach WeaponType:
##   PHASER, PULSE_PHASER → BeamWeaponData
##   DISRUPTOR            → BoltWeaponData (WingDisruptorMount)
##                          oder BeamWeaponData (klassischer WeaponMount)
##   TORPEDO              → TorpedoData
func _apply_weapon_data_to_mounts() -> void:
	if not ship_data:
		return

	var bwd: BeamWeaponData = ship_data.beam_weapon_data
	var tpd: TorpedoData = ship_data.torpedo_data
	var bld: BoltWeaponData = ship_data.get("bolt_weapon_data") as BoltWeaponData \
		if "bolt_weapon_data" in ship_data else null

	_dbg("══════ WEAPON DATA RESOLVE ══════", true)
	_dbg("  ship_data path  : %s" % ship_data.resource_path, true)
	_dbg("  zentrale Quellen:", true)
	_dbg("    beam_weapon_data: %s" % (bwd.weapon_name if bwd else "❌ NULL"), true)
	_dbg("    bolt_weapon_data: %s" % (bld.weapon_name if bld else "— (kein WingDisruptor)"), true)
	_dbg("    torpedo_data    : %s" % (tpd.torpedo_name if tpd else "❌ NULL"), true)

	for mount in weapon_mounts:
		var wtype: WeaponMount.WeaponType = mount.get_weapon_type()
		match wtype:
			WeaponMount.WeaponType.PHASER, \
			WeaponMount.WeaponType.PULSE_PHASER:
				_resolve_beam_data(mount, bwd)

			WeaponMount.WeaponType.DISRUPTOR:
				if "bolt_weapon_data_override" in mount:
					_resolve_bolt_data(mount, bld)
				else:
					_resolve_beam_data(mount, bwd)

			WeaponMount.WeaponType.TORPEDO:
				_resolve_torpedo_data(mount, tpd)

	_dbg("══════════════════════════════════", true)

## Setzt mount.weapon_data – Override hat Priorität vor zentralem Wert.
func _resolve_beam_data(mount: Node, central: BeamWeaponData) -> void:
	if not "weapon_data_override" in mount:
		push_warning("[ShipController|%s] Mount '%s' kennt 'weapon_data_override' nicht – altes Skript?" % [ship_name, mount.name])
		return

	var override: BeamWeaponData = mount.weapon_data_override
	if override:
		mount.weapon_data = override
		print("  [%-24s] OVERRIDE → '%s'" % [mount.name, override.weapon_name])
	elif central:
		mount.weapon_data = central
		print("  [%-24s] zentral  → '%s'" % [mount.name, central.weapon_name])
	else:
		push_warning("[ShipController|%s] Mount '%s' hat weder Override noch zentrale BeamWeaponData!" \
			% [ship_name, mount.name])


## Setzt mount.bolt_weapon_data – Override hat Priorität vor zentralem Wert.
func _resolve_bolt_data(mount: Node, central: BoltWeaponData) -> void:
	if not "bolt_weapon_data_override" in mount:
		push_warning("[ShipController|%s] Mount '%s' kennt 'bolt_weapon_data_override' nicht – altes Skript?" % [ship_name, mount.name])
		return

	var override: BoltWeaponData = mount.bolt_weapon_data_override
	if override:
		mount.bolt_weapon_data = override
		print("  [%-24s] OVERRIDE → '%s' (shield×%.2f | hull×%.2f)" % [
			mount.name, override.weapon_name,
			override.shield_damage_multiplier, override.hull_damage_multiplier])
	elif central:
		mount.bolt_weapon_data = central
		print("  [%-24s] zentral  → '%s' (shield×%.2f | hull×%.2f)" % [
			mount.name, central.weapon_name,
			central.shield_damage_multiplier, central.hull_damage_multiplier])
	else:
		push_warning("[ShipController|%s] Mount '%s' hat weder Override noch zentrale BoltWeaponData!" \
			% [ship_name, mount.name])


## Setzt mount.torpedo_data – Override hat Priorität vor zentralem Wert.
func _resolve_torpedo_data(mount: Node, central: TorpedoData) -> void:
	if not "torpedo_data_override" in mount:
		push_warning("[ShipController|%s] Mount '%s' kennt 'torpedo_data_override' nicht – altes Skript?" % [ship_name, mount.name])
		return

	var override: TorpedoData = mount.torpedo_data_override
	if override:
		mount.torpedo_data = override
		print("  [%-24s] OVERRIDE → '%s'" % [mount.name, override.torpedo_name])
	elif central:
		mount.torpedo_data = central
		print("  [%-24s] zentral  → '%s'" % [mount.name, central.torpedo_name])
	else:
		push_warning("[ShipController|%s] Mount '%s' hat weder Override noch zentrale TorpedoData!" \
			% [ship_name, mount.name])


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

func get_current_target() -> Node3D:
	return targeting_system.get_active_target() if targeting_system else null

func has_target() -> bool:
	return targeting_system != null and targeting_system.has_target()

func release_target_lock() -> void:
	if targeting_system:
		targeting_system.force_release_lock()

func get_model() -> Node3D:
	if not model:
		push_warning("[ShipController|%s] get_model() → NULL!" % ship_name)
	return model

func get_ship_info() -> Dictionary:
	return {
		"name":       ship_name,
		"registry":   registry,
		"hull":       hull_hp,
		"max_hull":   max_hull_hp,
		"shield":     shield_data.current_strength if shield_data else 0.0,
		"max_shield": shield_data.max_strength     if shield_data else 0.0,
		"weapons":    get_weapons_status()
	}

func get_weapons_status() -> Dictionary:
	var status := {
		"beams":    {"ready": 0, "total": 0},
		"torpedos": {"ready": 0, "total": 0}
	}
	for mount in weapon_mounts:
		match mount.get_weapon_type():
			WeaponMount.WeaponType.PHASER, WeaponMount.WeaponType.DISRUPTOR, \
			WeaponMount.WeaponType.PULSE_PHASER:
				status["beams"]["total"] += 1
				if mount.is_ready_to_fire():
					status["beams"]["ready"] += 1
			WeaponMount.WeaponType.TORPEDO:
				status["torpedos"]["total"] += 1
				if mount.is_ready_to_fire():
					status["torpedos"]["ready"] += 1
	return status

func get_weapon_mounts_by_type(weapon_type: WeaponMount.WeaponType) -> Array[WeaponMount]:
	var result: Array[WeaponMount] = []
	for mount in weapon_mounts:
		if mount.get_weapon_type() == weapon_type:
			result.append(mount)
	return result

func are_weapons_ready(weapon_type: WeaponMount.WeaponType = -1) -> bool:
	for mount in weapon_mounts:
		if weapon_type != -1 and mount.get_weapon_type() != weapon_type:
			continue
		if mount.is_ready_to_fire():
			return true
	return false

func print_weapons_status() -> void:
	_dbg("\n═══ %s WEAPONS STATUS ═══" % ship_name, true)
	var status := get_weapons_status()
	_dbg("  Beams:    %d/%d" % [status["beams"]["ready"], status["beams"]["total"]], true)
	_dbg("  Torpedos: %d/%d" % [status["torpedos"]["ready"], status["torpedos"]["total"]], true)
	_dbg("  Hull:     %.0f / %.0f" % [hull_hp, max_hull_hp], true)
	if shield_data:
		_dbg("  Shield:   %.0f / %.0f" % [shield_data.current_strength, shield_data.max_strength], true)
	for mount in weapon_mounts:
		_dbg("    %-20s [%-10s] state=%-12s" % [
			mount.name,
			WeaponMount.MountPosition.keys()[mount.get_mount_position()],
			mount.get_weapon_state()
		], true)
	_dbg("═══════════════════════════════════\n", true)


func _setup_collision_layers() -> void:
	if not ship_data:
		return
	var hull_node := find_child("HullCollision", true, false)
	if hull_node is CollisionObject3D:
		hull_node.collision_layer = ship_data.hull_layer
		hull_node.collision_mask  = 0
		_dbg("HullCollision.layer → %d" % ship_data.hull_layer)
	else:
		push_warning("[ShipController|%s] HullCollision fehlt oder ist kein CollisionObject3D!" % ship_name)

func get_own_rids() -> Array[RID]:
	var rids: Array[RID] = []
	var hull_node := find_child("HullCollision", true, false)
	if hull_node is CollisionObject3D:
		rids.append((hull_node as CollisionObject3D).get_rid())
	return rids

func _register_faction_group() -> void:
	if not ship_data:
		return
	add_to_group("ships")
	add_to_group(FactionSystem.get_group_name(ship_data.faction))
	_dbg("Gruppen: ships + %s" % FactionSystem.get_group_name(ship_data.faction))

func _dbg(msg: String, force: bool = false) -> void:
	# Prüfe 1: Lokaler Export im Inspector
	var is_local_debug := show_debug
	
	# Prüfe 2: Globaler DebugManager (falls vorhanden)
	var is_global_debug := false
	var dm = get_tree().root.get_node_or_null("DebugManager")
	if dm and dm.has_method("get_flag"):
		is_global_debug = dm.get_flag(debug_category)
	
	# Ausgabe wenn einer der beiden aktiv ist ODER force=true
	if force or is_local_debug or is_global_debug:
		print("[ShipController|%s] %s" % [ship_name, msg])

func _dbg_error(msg: String) -> void:
	printerr("[ShipController|%s] ❌ %s" % [ship_name, msg])


func _dbg_warning(msg: String) -> void:
	push_warning("[ShipController|%s] ⚠️ %s" % [ship_name, msg])

# ─────────────────────────────────────────────────────────────────────────────
# CLOAK-SYSTEM API
# ─────────────────────────────────────────────────────────────────────────────

## Setzt den CloakComponent auf, wenn ship_data.can_cloak gesetzt ist.
## Wird aus _setup_shield_deferred() aufgerufen, also nach allen anderen
## Subsystemen damit der Cloak auf Schilde/Waffen zugreifen kann.

func _setup_cloak() -> void:
	# cloak_component ist per @export im Inspector zugewiesen — keine Suche nötig.
	if not is_instance_valid(cloak_component):
		_dbg_cloak("ℹ Kein CloakComponent zugewiesen → Schiff tarnt nicht")
		return

	# Berechtigungs-Check: can_cloak ODER Player-Bypass
	var can_cloak: bool = ship_data.can_cloak if ship_data else false
	var player_bypass: bool = has_meta("player_cloak_bypass") and get_meta("player_cloak_bypass") == true

	# Master-Gate: ohne Berechtigung → Component bleibt is_active=false (Default).
	# Damit lehnt toggle_cloak()/break_cloak() jeden Aufruf silent ab.
	if not can_cloak and not player_bypass:
		cloak_component.is_active = false
		_dbg_cloak("🚫 Cloak deaktiviert: can_cloak=false und kein Player-Bypass — Component is_active=false")
		return

	# Berechtigt → aktivieren und Setup durchführen
	cloak_component.is_active = true

	# Logging-Ursache für die Aktivierung — hilft beim Diagnostizieren,
	# warum dieses Schiff cloakt obwohl can_cloak im .tres vielleicht false ist.
	var reason: String = ""
	if can_cloak and player_bypass:
		reason = "can_cloak=true + Player-Bypass"
	elif can_cloak:
		reason = "can_cloak=true (NPC/Standard)"
	else:
		reason = "Player-Bypass (force_cloak_for_player)"

	# Konfiguration und Signal-Verbindungen
	cloak_component.show_debug = show_debug
	
	cloak_component.cloaking_started.connect(func(): _dbg_cloak("🌀 Cloak: tarnt sich..."))
	cloak_component.cloaked.connect(func(): _dbg_cloak("✅ Cloak: voll getarnt"))
	cloak_component.decloaked.connect(func(): _dbg_cloak("✅ Cloak: enttarnt"))
	
	cloak_component.cloak_broken.connect(func(reason_msg: String):
		_dbg_cloak("💥 Cloak gebrochen: %s" % reason_msg)
	)

	# Daten-Validierung für das Logging (verhindert "Invalid access"-Fehler)
	var det_range: float = 0.0
	var fade_in: float = 0.0
	if cloak_component.cloak_data:
		det_range = cloak_component.cloak_data.detection_range
		fade_in = cloak_component.cloak_data.fade_in_duration

	_dbg_cloak("✅ CloakComponent '%s' AKTIV [%s] (detection_range=%.0fm | fade_in=%.1fs)" % [
		cloak_component.name, reason, det_range, fade_in
	])

## Debug-Log speziell für Cloak-Events — über DebugManager-Flag "cloak.setup" steuerbar.
func _dbg_cloak(msg: String) -> void:
	var dm: Node = get_tree().root.get_node_or_null("DebugManager")
	var flag_active: bool = false
	if dm and dm.has_method("get_flag"):
		flag_active = dm.get_flag("cloak.setup")
	if show_debug or flag_active:
		print("[ShipController|Cloak|%s] %s" % [ship_name, msg])

## Toggle-Trigger für Player-Input und externe Quellen.
## Returns false wenn das Schiff nicht tarnen kann oder Toggle ignoriert wurde.
func toggle_cloak() -> bool:
	if not cloak_component:
		_dbg("⚠ toggle_cloak: kein CloakComponent vorhanden")
		return false
	return cloak_component.toggle_cloak()


## Sichtbarkeit des Schiffs für einen externen Beobachter.
## 0.0 = unsichtbar, 1.0 = voll sichtbar. Wird von TargetingSystem,
## AIController und allen anderen Visibility-Konsumenten genutzt.
##
## Schiffe ohne CloakComponent sind immer voll sichtbar (1.0).
func visibility_to(observer: Node3D) -> float:
	if not cloak_component:
		return 1.0
	return cloak_component.visibility_to(observer)


## Convenience: true wenn das Schiff für den Beobachter nutzbar/sichtbar
## genug ist um es als Target zu locken oder mit AI-Scan zu erkennen.
##
## Threshold: 0.1 — alles unter 10% Sichtbarkeit gilt als "unsichtbar".
## Damit nutzen wir die Shimmer-Zone (innerhalb detection_range) als
## "der Spieler kann das Schiff erahnen aber noch nicht voll tracken".
func is_visible_to(observer: Node3D) -> bool:
	return visibility_to(observer) >= 0.1


## true wenn das Schiff aktuell getarnt oder im Übergang ist.
## Quick-Check für UI/Debug ohne Detection-Range zu beachten.
func is_cloaked() -> bool:
	if not cloak_component:
		return false
	return cloak_component.is_cloaked() or cloak_component.is_transitioning()


## Wird vom CloakComponent aufgerufen um Waffen während Cloak zu sperren.
## Iteriert über alle Mounts und setzt deren is_cloak_locked-Flag.
func set_weapons_cloak_locked(locked: bool) -> void:
	for mount in weapon_mounts:
		if mount and mount.has_method("set_cloak_locked"):
			mount.set_cloak_locked(locked)
		elif mount:
			# Fallback: direkter Property-Set für Mounts ohne Methode
			if "is_cloak_locked" in mount:
				mount.is_cloak_locked = locked


## Wird vom CloakComponent aufgerufen um Schilde während Cloak offline zu nehmen.
## Beim Re-Aktivieren werden die Schilde mit Standard-Recharge-Delay neu starten.
func set_shields_cloak_offline(offline: bool) -> void:
	if not shield_system or not shield_system.data:
		return

	if offline:
		# Schilde sofort auf 0 bringen ohne den Destroy-Effect zu triggern
		# (das würde Dissolve-Tween starten was wir nicht wollen)
		for i in range(ShieldZone.COUNT):
			shield_system.data.zone_strengths[i] = 0.0
		shield_system.data._recompute_current_from_zones()
		shield_system._is_recharging = false
		shield_system._recharge_timer = 0.0
		# Mesh ausblenden
		if shield_system._mesh_instance:
			shield_system._mesh_instance.visible = false
		_dbg("🛡️ Schilde offline (Cloak)")
	else:
		# Schilde dürfen wieder regenerieren – starten bei 0 mit recharge_delay
		shield_system._recharge_timer = shield_system.data.recharge_delay
		shield_system._is_destroyed   = false
		shield_system._is_dissolved   = false
		if shield_system._mesh_instance:
			shield_system._mesh_instance.visible = true
		_dbg("🛡️ Schilde online (Cloak Ende, Regen-Delay aktiv)")
