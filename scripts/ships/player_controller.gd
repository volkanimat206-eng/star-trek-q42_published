# res://scripts/player_controller.gd
# Steuert den Spieler-Avatar.
extends CharacterBody3D

#signal ship_destroyed

# ===== EXPORTS =====
@export var ship_data: ShipData:
	set(value):
		ship_data = value
		if is_inside_tree():
			_update_faction_groups()
			_instantiate_ship()

@export_group("Auto-Fire")
@export var auto_fire_action: String = "auto_fire"

@export_group("Cloak")
@export var force_cloak_for_player: bool = true

@export_group("Debug")
@export var show_debug: bool = false

# ===== NODE REFERENZEN =====
@onready var input_comp: InputComponent = $InputComponent

# ===== INTERN =====
var ship_controller: ShipController
var current_model:   Node3D
var auto_fire:       bool = false
var _cloak_component: CloakComponent = null

var _last_auto_fire_block_log: float = 0.0


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_update_faction_groups()

	_dbg("[PLAYER DEBUG] Gruppen: " + str(get_groups()))
	if ship_data:
		_dbg("[PLAYER DEBUG] Meine Fraktion: " + str(ShipData.Faction.keys()[ship_data.faction]))

	_dbg("=== PLAYER CONTROLLER READY ===")
	_dbg("  ship_data            : %s" % ("SET → " + ship_data.ship_name if ship_data else "❌ NULL"))
	_dbg("  input_comp           : %s" % (input_comp != null))
	_dbg("  force_cloak_for_player: %s" % force_cloak_for_player)

	if not ship_data:
		push_error("[PlayerController] Kein ship_data zugewiesen!")
		return

	if ship_data.ship_scene_path.is_empty():
		push_error("[PlayerController] ship_data.ship_scene_path ist leer!")
		return

	_instantiate_ship()

	# CloakComponent cachen
	if is_instance_valid(ship_controller):
		_cloak_component = ship_controller.get_node_or_null("CloakComponent") as CloakComponent

	# === INPUT VERBINDUNGEN ===
	if input_comp:
		input_comp.phaser_pressed.connect(_on_phaser_pressed)
		input_comp.torpedo_pressed.connect(_on_torpedo_pressed)   # RMB / Torpedo feuern
		
		# NEU: Q-Taste für Torpedo-Typ Wechsel
		if input_comp.has_signal("cycle_torpedo_pressed"):
			input_comp.cycle_torpedo_pressed.connect(_on_cycle_torpedo_requested)
			_dbg("  cycle_torpedo_pressed Signal verbunden ✓")
		else:
			push_warning("[PlayerController] Signal 'cycle_torpedo_pressed' existiert nicht im InputComponent!")

		_dbg("  Input-Verbindungen hergestellt")
	else:
		push_warning("[PlayerController] Kein InputComponent gefunden!")


# ─────────────────────────────────────────────────────────────────────────────
# SCHIFF INSTANZIIEREN
# ─────────────────────────────────────────────────────────────────────────────

func _update_faction_groups() -> void:
	for g in get_groups():
		if g.begins_with("faction_"):
			remove_from_group(g)
	add_to_group("ships")
	add_to_group("player")
	if ship_data:
		add_to_group(FactionSystem.get_group_name(ship_data.faction))
	_dbg("Gruppen aktualisiert: %s" % str(get_groups()))


func _instantiate_ship() -> void:
	_dbg("_instantiate_ship() → %s" % ship_data.ship_scene_path)

	var packed: PackedScene = load(ship_data.ship_scene_path) as PackedScene
	if not packed:
		push_error("[PlayerController] Szene konnte nicht geladen werden: %s" \
			% ship_data.ship_scene_path)
		return

	var instance: Node = packed.instantiate()

	var sc := _find_ship_controller_in(instance)
	if not sc:
		push_error("[PlayerController] Kein ShipController gefunden!")
		instance.queue_free()
		return

	sc.ship_data = ship_data

	if force_cloak_for_player:
		sc.set_meta("player_cloak_bypass", true)

	add_child(instance)

	ship_controller = sc
	current_model = ship_controller.get_model()

	var ts := ship_controller.targeting_system
	if ts:
		ts.setup_as_player()

	_dbg("ShipController '%s' bereit" % ship_controller.ship_name)
	ship_controller.print_weapons_status()


func _find_ship_controller_in(instance: Node) -> ShipController:
	if instance is ShipController:
		return instance as ShipController
	for child in instance.get_children():
		if child is ShipController:
			return child as ShipController
	return null


# ─────────────────────────────────────────────────────────────────────────────
# INPUT
# ─────────────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_dbg("Mouse Button: %d | action fire_torpedo=%s" % [
				mb.button_index,
				event.is_action_pressed("fire_torpedo")
			])

	if event.is_action_pressed(auto_fire_action):
		auto_fire = not auto_fire
		_dbg("Auto-Fire: %s" % ("AN 🔥" if auto_fire else "AUS"))

	if event.is_action_pressed("target_cancel"):
		if ship_controller and ship_controller.targeting_system:
			ship_controller.targeting_system.release_target()
			auto_fire = false

	if event.is_action_pressed("fire_torpedo"):
		_on_torpedo_pressed()

	if event.is_action_pressed("toggle_cloak"):
		if is_instance_valid(_cloak_component):
			_cloak_component.toggle_cloak()
		elif ship_controller and ship_controller.has_method("toggle_cloak"):
			ship_controller.toggle_cloak()


# ─────────────────────────────────────────────────────────────────────────────
# PHYSICS
# ─────────────────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if not ship_controller or not ship_controller.movement_comp or not input_comp:
		return

	var stats: ShipStats = ship_controller.stats if ship_controller else null
	if not stats:
		return

	var m_input := input_comp.get_movement_input()

	velocity = ship_controller.movement_comp.calculate_movement(
		self, m_input.y, m_input.x, stats, delta
	)
	move_and_slide()

	if stats:
		ship_controller.movement_comp.update_tilt(m_input.x, stats, delta)

	# ── Auto-Fire mit Friendly-Fire-Sicherung ─────────────────────────────
	# REGEL: Auto-Fire feuert NUR auf feindliche Ziele.
	# Single-Lock auf Freund/Neutral = Scan-Modus → kein Schuss (silent).
	# Multi-Locks sind per TargetingSystem-Invariante immer feindlich.
	if auto_fire and ship_controller.targeting_system:
		var ts := ship_controller.targeting_system
		if ts.get_locked_target() != null:
			if ts.is_current_target_hostile():
				ship_controller.fire_phasers()
			else:
				# Silent skip – aber einmal pro Sekunde Log zur Diagnose
				var now: float = Time.get_ticks_msec() / 1000.0
				if now - _last_auto_fire_block_log > 1.0:
					_last_auto_fire_block_log = now
					_dbg("🛡 Auto-Fire HOLD: Ziel '%s' nicht feindlich" % \
						ts.get_locked_target().name)


# ─────────────────────────────────────────────────────────────────────────────
# WAFFEN-INPUT
# ─────────────────────────────────────────────────────────────────────────────

## Manual-Fire: ungefiltert – der Spieler darf bewusst auf jedes gelockte Ziel
## schießen. Wer auf einen Freund feuert, zahlt mit Ruf (wird über
## ReputationSystem / ship_damaged-Signal geregelt, nicht hier).
func _on_phaser_pressed() -> void:
	if not ship_controller: return
	var ts := ship_controller.targeting_system
	if not ts or ts.get_locked_target() == null:
		_dbg("⚠️ Kein Target - Phaser blockiert")
		return

	if not ts.is_current_target_hostile():
		_dbg("⚠️ MANUAL FIRE auf Nicht-Feind – Ruf-Konsequenz!")

	ship_controller.fire_phasers()

func _on_torpedo_pressed() -> void:
	if not ship_controller: return
	var ts := ship_controller.targeting_system
	if not ts or ts.get_locked_target() == null:
		_dbg("⚠️ Kein Target gesetzt – Torpedo blockiert")
		return

	if not ts.is_current_target_hostile():
		_dbg("⚠️ MANUAL TORPEDO auf Nicht-Feind – Ruf-Konsequenz!")

	ship_controller.fire_torpedos()

# ─────────────────────────────────────────────────────────────────────────────
# TORPEDO TYP WECHSEL (Q-Taste)
# ─────────────────────────────────────────────────────────────────────────────

func _on_cycle_torpedo_requested() -> void:
	if not ship_controller:
		_dbg("⚠️ Kein ShipController für Torpedo-Wechsel")
		return

	if ship_controller.ship_data and ship_controller.ship_data.torpedo_loadout:
		var loadout = ship_controller.ship_data.torpedo_loadout
		var new_data = loadout.cycle_next()
		
		if new_data:
			_dbg("🔄 Torpedo-Typ gewechselt → %s" % new_data.torpedo_name)
			# Optional: kurze visuelle/haptische Rückmeldung
			# z.B. Audio-Trigger, HUD-Update etc.
		else:
			_dbg("⚠️ cycle_next() hat nichts zurückgegeben")
	else:
		_dbg("⚠️ Kein TorpedoLoadout vorhanden – Wechsel nicht möglich")

# ─────────────────────────────────────────────────────────────────────────────
# DEBUG
# ─────────────────────────────────────────────────────────────────────────────

func print_debug_info() -> void:
	_dbg("=== DEBUG INFO ===")
	_dbg("  ship_data       : %s | %s" % [
		ship_data.ship_name if ship_data else "NULL",
		ship_data.registry  if ship_data else ""
	])
	_dbg("  ship_controller : %s" % (ship_controller.ship_name if ship_controller else "NULL"))
	_dbg("  current_model   : %s" % (current_model.name if current_model else "NULL"))
	if ship_controller:
		ship_controller.print_weapons_status()


func _dbg(msg: String) -> void:
	if show_debug:
		print("[PlayerController] %s" % msg)
