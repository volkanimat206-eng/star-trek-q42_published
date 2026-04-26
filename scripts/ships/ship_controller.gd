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

@export_group("Systeme")
## CloakComponent für dieses Schiff. Im Inspector zuweisen — Node unter ShipController.
## Nicht zugewiesen = Schiff kann nicht tarnen (kein Fehler, nur kein Cloak).
@export var cloak_component: CloakComponent

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
		push_error("[ShipController] Kein ship_data zugewiesen!")
		return

	print("[SC-DIAG] node.name='%s' | ship_data=%s | script=%s" % [
		name, ship_data, get_script().resource_path if get_script() else "NULL"
	])

	_setup_metadata()
	_register_faction_group()

	model            = _find_model()
	_dbg("  model: %s" % (model.name if model else "❌ NULL – kein Model-Node gefunden!"))
	targeting_system = find_child("TargetingSystem", true, false) as TargetingSystem
	movement_comp    = find_child("MovementComponent", true, false) as MovementComponent
	if model and movement_comp:
		movement_comp.init_tilt(model)

	_setup_hull_hp()
	_setup_collision_layers()
	_find_weapon_mounts()
	_connect_targeting_signals()
	_connect_movement_signal()

	# FIX: Shield-Setup per call_deferred – stellt sicher dass ALLE _ready()-Aufrufe
	# im Szenenbaum abgeschlossen sind bevor ShieldSystem gesucht wird.
	call_deferred("_setup_shield_deferred")


func _setup_shield_deferred() -> void:
	_setup_shield()
	_setup_cloak()

	print("═══════════════════════════════════")
	print("  SHIP : %s | %s [%s]" % [ship_name, registry, ship_data.faction])
	print("  Stats: max_speed=%.0f | shield=%.0f HP | hull=%.0f HP" % [
		stats.max_speed          if stats       else 0.0,
		shield_data.max_strength if shield_data else 0.0,
		max_hull_hp
	])
	print("  Mounts: %d | Targeting: %s | Shield: %s | Movement: %s" % [
		weapon_mounts.size(),
		"✓" if targeting_system else "❌",
		"✓" if shield_system    else "❌",
		"✓" if movement_comp    else "❌"
	])
	print("═══════════════════════════════════")


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
		push_warning("[ShipController|%s] Kein ShieldSystem gefunden!" % ship_name)
		return

	if not ship_data.shield:
		_dbg("⚠️ ShieldSystem gefunden, aber ship_data.shield ist NULL!")
		return

	# FIX: ShieldData lokal duplizieren — sonst teilen sich alle Instanzen desselben
	# Schiffstyps dieselbe current_strength (klassischer shared-Resource-Bug).
	# Gleiches Pattern wie bei _local_hull_data in _setup_hull_hp().
	# Ohne diesen Fix regenerieren/verlieren zwei BoPs gleichzeitig dieselben HP.
	var local_shield_data: ShieldData = ship_data.shield.duplicate() as ShieldData
	local_shield_data.reset()   # current_strength = max_strength

	shield_system.data       = local_shield_data
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

	# FIX: Sofort aus ALLEN Gruppen entfernen damit Targeting-Scans das Schiff
	# während des destruction_delay nicht mehr finden ("enemy", "ships", Fraktions-Gruppe etc.)
	for group in get_groups():
		remove_from_group(group)

	ship_destroyed.emit()

	# Explosion startet sofort – unabhängig vom shockwave_delay.
	_destroy_sequence()

	# Shockwave läuft PARALLEL zur Explosion.
	# _trigger_shockwave_delayed() ist async, blockiert _destroy_sequence() nicht.
	_trigger_shockwave_delayed()


## Wartet shockwave_delay Sekunden, dann Shockwave – läuft parallel zur Explosion.
func _trigger_shockwave_delayed() -> void:
	if shockwave_delay > 0.0:
		_dbg("⏳ Shockwave in %.2fs" % shockwave_delay)
		await get_tree().create_timer(shockwave_delay).timeout
	if is_instance_valid(self):
		_trigger_shockwave()


func _trigger_shockwave() -> void:
	print("\n[SHOCKWAVE|%s] ══════ SHOCKWAVE TRIGGER (delay=%.2fs) ══════" % [ship_name, shockwave_delay])

	if not ship_data:
		print("[SHOCKWAVE|%s] ❌ ABBRUCH: ship_data ist null" % ship_name)
		return

	# ShipData.shockwave_data prüfen – @export muss im Inspector gesetzt sein
	if not "shockwave_data" in ship_data:
		print("[SHOCKWAVE|%s] ❌ ABBRUCH: ShipData hat kein 'shockwave_data'-Feld (ShockwaveData.gd geladen?)" % ship_name)
		return

	var sw_data: ShockwaveData = ship_data.shockwave_data
	if not sw_data:
		print("[SHOCKWAVE|%s] ❌ ABBRUCH: shockwave_data ist NULL – im Inspector eine ShockwaveData-Resource anlegen!" % ship_name)
		return

	print("[SHOCKWAVE|%s] ✅ ShockwaveData geladen:" % ship_name)
	print("  radius=%.0f | force=%.1f | tilt=%.1f° | recovery=%.2fs" % [
		sw_data.shockwave_radius, sw_data.shockwave_force,
		sw_data.shockwave_tilt_angle, sw_data.shockwave_recovery_time])

	# excluded: CharacterBody3D-Parent dieses ShipControllers
	var excluded: CharacterBody3D = get_parent() as CharacterBody3D
	print("[SHOCKWAVE|%s] excluded node: %s" % [ship_name, excluded.name if excluded else "NULL (kein CharacterBody3D-Parent!)"])

	var origin: Vector3       = global_position
	var ships: Array[Node]    = get_tree().get_nodes_in_group("ships")
	print("[SHOCKWAVE|%s] Schiffe in Gruppe 'ships': %d" % [ship_name, ships.size()])

	if ships.is_empty():
		print("[SHOCKWAVE|%s] ⚠️  Gruppe 'ships' ist leer – sind alle Schiffe per add_to_group('ships') registriert?" % ship_name)

	var hit_count: int = 0

	for node: Node in ships:
		# Eigenes Schiff überspringen
		if node == excluded or node == self:
			print("  [SKIP] '%s' → eigenes Schiff" % node.name)
			continue

		if not node is CharacterBody3D:
			print("  [SKIP] '%s' → kein CharacterBody3D (ist: %s)" % [node.name, node.get_class()])
			continue

		var body    := node as CharacterBody3D
		var diff    : Vector3 = body.global_position - origin
		var dist    : float   = diff.length()

		print("  [CHECK] '%s' | dist=%.1f | radius=%.0f" % [body.name, dist, sw_data.shockwave_radius])

		if dist <= 0.0:
			print("    → SKIP: dist=0 (Schiff sitzt exakt auf Origin?)")
			continue
		if dist > sw_data.shockwave_radius:
			print("    → AUSSERHALB Radius – kein Effekt")
			continue

		# Linearer Falloff: nah=1.0, Rand=0.0
		var falloff   : float   = 1.0 - (dist / sw_data.shockwave_radius)
		var push_dir  : Vector3 = diff.normalized()
		var push_force: float   = sw_data.shockwave_force * falloff
		var tilt_deg  : float   = sw_data.shockwave_tilt_angle * falloff

		# Tilt + Push via MovementComponent – NUR dort, damit der Impuls
		# nicht sofort im nächsten _physics_process()-Frame überschrieben wird.
		var mc: MovementComponent = _find_movement_component(body)
		if mc:
			mc.apply_shockwave_push(push_dir * push_force)
			mc.apply_shockwave_tilt(tilt_deg, sw_data.shockwave_recovery_time, push_dir)
			print("    → falloff=%.2f | push=%.1f | tilt=%.1f° → via MovementComponent" % [falloff, push_force, tilt_deg])
		else:
			# Fallback: body.velocity direkt (kein MC gefunden – Impuls nur 1 Frame sichtbar)
			body.velocity += push_dir * push_force
			print("    → falloff=%.2f | push=%.1f (Fallback: kein MC – Effekt nur 1 Frame!)" % [falloff, push_force])

		hit_count += 1

	print("[SHOCKWAVE|%s] ══ Ergebnis: %d Schiff(e) getroffen ══════\n" % [ship_name, hit_count])


func _destroy_sequence() -> void:
	_spawn_explosion()
	_dbg("⏳ Warte %.1f s bevor queue_free()" % destruction_delay)
	await get_tree().create_timer(destruction_delay).timeout
	if is_instance_valid(self):
		queue_free()


func _spawn_explosion() -> Node3D:
	if not explosion_scene:
		push_warning("[ShipController|%s] ❌ Keine explosion_scene zugewiesen!" % ship_name)
		return null

	var explosion: Node3D = explosion_scene.instantiate() as Node3D
	if not explosion:
		push_error("[ShipController|%s] ❌ instantiate() fehlgeschlagen!" % ship_name)
		return null

	# Position: Marker3D bevorzugen, Fallback auf ShipController-Origin
	var spawn_pos: Vector3 = explosion_origin.global_position \
		if explosion_origin and is_instance_valid(explosion_origin) \
		else global_position

	var spawn_parent: Node = get_parent() if get_parent() else get_tree().current_scene
	spawn_parent.add_child(explosion)
	explosion.global_position = spawn_pos

	_dbg("Explosion bei %s | Size: %.2f" % [
		("Marker '%s'" % explosion_origin.name) if explosion_origin else "Origin-Fallback",
		explosion_size
	])

	if explosion.has_method("initialize"):
		explosion.initialize(explosion_size, shockwave_delay)

	_start_explosion_animation(explosion)
	return explosion


func _start_explosion_animation(explosion: Node3D) -> void:
	# Nur AnimationPlayer starten — der steuert alle Partikel per Keyframe.
	# NICHT manuell emitting = true setzen, das würde die Sequenzierung zerstören.
	var found_ap := false
	for child in explosion.find_children("*", "AnimationPlayer", true, false):
		var ap := child as AnimationPlayer
		if ap.is_playing():
			found_ap = true
			continue

		var anim: String = ""
		# RESET ist Godots interne Referenz-Animation → überspringen
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
			push_warning("[ShipController|%s] AnimationPlayer '%s' hat keine spielbare Animation!" % [
				ship_name, ap.name])

	if not found_ap:
		push_warning("[ShipController|%s] Kein AnimationPlayer in Explosion-Scene gefunden!" % ship_name)


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
			push_warning("[ShipController|%s] ⚠ RelationshipResolver-Autoload nicht gefunden – Assist-Mechanik inaktiv! Prüfe Project Settings → AutoLoad." % ship_name)
		return
	if not resolver.has_method("notify_attack"):
		if not _resolver_missing_warned:
			_resolver_missing_warned = true
			push_warning("[ShipController|%s] ⚠ RelationshipResolver kennt notify_attack() nicht – veraltete Version?" % ship_name)
		return

	# Debug-Ausgabe direkt vor dem Call – zeigt dass die Assist-Kette startet
	if get_tree().root.has_node("DebugManager") and DebugManager.get_flag("ai.resolver"):
		print("[ShipController|%s] _notify_attack_on → Resolver.notify_attack(self, '%s')" % [
			ship_name, victim.name
		])

	# 'self' ist der ShipController; der Resolver normalisiert ihn intern
	# auf den äußersten "ships"-Gruppen-Ahnen (Player-CharacterBody3D bzw.
	# AIController) und startet von dort die Ally-Propagation.
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
	# FIX: search_root NUR im eigenen Schiff-Subtree begrenzen.
	# get_parent() gibt bei AIController-NPCs die World-Scene zurück →
	# würde Mounts ALLER Schiffe einsammeln und deren Data überschreiben.
	var search_root: Node = self
	var _parent := get_parent()
	if _parent and _parent != get_tree().current_scene 	and _parent != get_tree().root:
		search_root = _parent

	print("[SC|%s] _find_weapon_mounts() | search_root='%s'" % [ship_name, search_root.name])

	# Alle Nodes einsammeln die die WeaponMount-API haben (duck-typing)
	# → funktioniert unabhängig von class_name-Registrierung
	for child in search_root.find_children("*", "Node3D", true, false):
		if not child.has_method("get_weapon_type"):
			continue
		if not child.has_method("is_ready_to_fire"):
			continue
		if not child.has_method("fire_at"):
			continue

		# Bereits in der Liste?
		if weapon_mounts.has(child):
			continue

		weapon_mounts.append(child)

		# Meta setzen wenn es ein echter WeaponMount ist
		if child is WeaponMount:
			child.set_meta("ship_parent", self)

		print("[SC|%s]   ✓ Mount gefunden: '%s' [%s] | type=%s | ready=%s" % [
			ship_name,
			child.name,
			child.get_class(),
			WeaponMount.WeaponType.keys()[child.get_weapon_type()],
			child.is_ready_to_fire()
		])

	print("[SC|%s] weapon_mounts gesamt: %d | davon Torpedos: %d" % [
		ship_name,
		weapon_mounts.size(),
		weapon_mounts.filter(func(m): return m.get_weapon_type() == WeaponMount.WeaponType.TORPEDO).size()
	])

	if weapon_mounts.is_empty():
		push_warning("[ShipController] Keine WeaponMounts gefunden!")
		return

	# Weapon-Data aus ShipController-Inspector auf Mounts anwenden
	_apply_weapon_data_to_mounts()

# ─────────────────────────────────────────────────────────────────────────────
# WEAPON DATA SETUP
# ─────────────────────────────────────────────────────────────────────────────

## Wendet beam_weapon_data und torpedo_data aus dem Inspector auf alle
## gefundenen Mounts an. Überschreibt nur wenn der Export gesetzt ist.
## Wendet beam_weapon_data, bolt_weapon_data und torpedo_data aus dem Inspector
## auf alle gefundenen Mounts an. Überschreibt nur wenn der Export gesetzt ist.
##
## Priorität bei DISRUPTOR-Mounts:
##   WingDisruptorMount (bolt_weapon_data) → BoltWeaponData   (Bolzen + Schadens-Multiplikatoren)
##   WeaponMount        (weapon_data)      → BeamWeaponData   (Strahl-Disruptor)
func _apply_weapon_data_to_mounts() -> void:
	if not ship_data:
		return

	var bwd: BeamWeaponData = ship_data.beam_weapon_data
	var tpd: TorpedoData    = ship_data.torpedo_data
	# BoltWeaponData ist optional – nur Schiffe mit WingDisruptorMount brauchen es.
	# duck-typing via get() damit ShipData-Ressourcen ohne das Feld keinen Fehler werfen.
	var bld: BoltWeaponData = ship_data.get("bolt_weapon_data") as BoltWeaponData \
		if "bolt_weapon_data" in ship_data else null

	print("\n[SC|%s] ══════ WEAPON DATA DEBUG ══════" % ship_name)
	print("  ship_data path  : %s" % ship_data.resource_path)
	print("  beam_weapon_data: %s" % (bwd.resource_path if bwd else "❌ NULL"))
	print("  bolt_weapon_data: %s" % (bld.resource_path if bld else "❌ NULL (nur für WingDisruptorMount)"))
	print("  torpedo_data    : %s" % (tpd.resource_path if tpd else "❌ NULL"))
	if bwd:
		print("    beam name     : %s" % (bwd.get("weapon_name") if "weapon_name" in bwd else "?"))
		print("    beam damage   : %s" % (bwd.get("damage_per_second") if "damage_per_second" in bwd else "?"))
	if bld:
		print("    bolt name     : %s" % bld.weapon_name)
		print("    bolt damage   : %.0f | shield×%.2f | hull×%.2f" % [
			bld.damage, bld.shield_damage_multiplier, bld.hull_damage_multiplier])
	if tpd:
		print("    torpedo name  : %s" % (tpd.get("torpedo_name") if "torpedo_name" in tpd else "?"))
		print("    torpedo damage: %s" % (tpd.get("damage") if "damage" in tpd else "?"))
	print("  Mounts (%d):" % weapon_mounts.size())

	for mount in weapon_mounts:
		var wtype: WeaponMount.WeaponType = mount.get_weapon_type()
		var current_data_path: String = ""

		if "bolt_weapon_data" in mount and mount.bolt_weapon_data:
			current_data_path = mount.bolt_weapon_data.resource_path
		elif "weapon_data" in mount and mount.weapon_data:
			current_data_path = mount.weapon_data.resource_path
		elif "torpedo_data" in mount and mount.torpedo_data:
			current_data_path = mount.torpedo_data.resource_path

		print("    [%s] '%s' | data vorher: %s" % [
			WeaponMount.WeaponType.keys()[wtype],
			mount.name,
			current_data_path if current_data_path else "NULL"
		])

		match wtype:
			WeaponMount.WeaponType.PHASER, \
			WeaponMount.WeaponType.PULSE_PHASER:
				if bwd and "weapon_data" in mount:
					mount.weapon_data = bwd
					print("      → beam_weapon_data gesetzt ✓")
				else:
					print("      → beam_weapon_data: NICHT gesetzt (bwd=%s, hat weapon_data=%s)" % [
						bwd != null, "weapon_data" in mount])

			WeaponMount.WeaponType.DISRUPTOR:
				# WingDisruptorMount hat bolt_weapon_data → BoltWeaponData verwenden
				if "bolt_weapon_data" in mount:
					if bld:
						mount.bolt_weapon_data = bld
						print("      → bolt_weapon_data gesetzt ✓ (shield×%.2f | hull×%.2f)" % [
							bld.shield_damage_multiplier, bld.hull_damage_multiplier])
					else:
						print("      → bolt_weapon_data: NICHT gesetzt")
						print("         → 'bolt_weapon_data: BoltWeaponData' in ShipData anlegen!")
				# WeaponMount (Strahl-Disruptor) hat weapon_data → BeamWeaponData
				elif "weapon_data" in mount:
					if bwd:
						mount.weapon_data = bwd
						print("      → beam_weapon_data gesetzt ✓ (Strahl-Disruptor)")
					else:
						print("      → beam_weapon_data: NICHT gesetzt (bwd=null)")
				else:
					print("      → ⚠ Kein bekanntes data-Feld!")

			WeaponMount.WeaponType.TORPEDO:
				if tpd and "torpedo_data" in mount:
					mount.torpedo_data = tpd
					print("      → torpedo_data gesetzt ✓")
				else:
					print("      → torpedo_data: NICHT gesetzt (tpd=%s, hat torpedo_data=%s)" % [
						tpd != null, "torpedo_data" in mount])

	print("[SC|%s] ══════════════════════════════\n" % ship_name)


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
	print("\n═══ %s WEAPONS STATUS ═══" % ship_name)
	var status := get_weapons_status()
	print("  Beams:    %d/%d" % [status["beams"]["ready"],   status["beams"]["total"]])
	print("  Torpedos: %d/%d" % [status["torpedos"]["ready"], status["torpedos"]["total"]])
	print("  Hull:     %.0f / %.0f" % [hull_hp, max_hull_hp])
	if shield_data:
		print("  Shield:   %.0f / %.0f" % [shield_data.current_strength, shield_data.max_strength])
	for mount in weapon_mounts:
		print("    %-20s [%-10s] state=%-12s" % [
			mount.name,
			WeaponMount.MountPosition.keys()[mount.get_mount_position()],
			mount.get_weapon_state()
		])
	print("═══════════════════════════════════\n")

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

func _dbg(msg: String) -> void:
	if show_debug:
		print("[ShipController|%s] %s" % [ship_name, msg])


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

	cloak_component.show_debug = show_debug

	cloak_component.cloaking_started.connect(func(): _dbg_cloak("🌀 Cloak: tarnt sich..."))
	cloak_component.cloaked.connect(func(): _dbg_cloak("✅ Cloak: voll getarnt"))
	cloak_component.decloaked.connect(func(): _dbg_cloak("✅ Cloak: enttarnt"))
	cloak_component.cloak_broken.connect(func(reason: String):
		_dbg_cloak("💥 Cloak gebrochen: %s" % reason))

	_dbg_cloak("✅ CloakComponent '%s' bereit (detection_range=%.0fm | fade_in=%.1fs)" % [
		cloak_component.name, cloak_component.detection_range, cloak_component.fade_in_duration
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
