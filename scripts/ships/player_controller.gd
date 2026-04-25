# res://scripts/player_controller.gd
# Steuert den Spieler-Avatar.
# Verantwortlich für:
#   - Schiff instanziieren (aus ShipData)
#   - Input weiterleiten (InputComponent → ShipController)
#   - Bewegung delegieren (InputComponent → ShipController.movement_comp)
#
# Eigene Kinder:
#   - InputComponent   (bleibt hier – liest nur Spielereingaben)
#
# NICHT mehr hier:
#   - MovementComponent → liegt jetzt direkt unter dem Schiff (ShipController)
extends CharacterBody3D

# ===== EXPORTS =====
## Weise hier die .tres-Datei des Spielerschiffs zu (z.B. ship_sovereign.tres).
@export var ship_data: ShipData

@export_group("Auto-Fire")
@export var auto_fire_action: String = "auto_fire"

@export_group("Debug")
@export var show_debug: bool = true

# ===== NODE REFERENZEN =====
@onready var input_comp: InputComponent = $InputComponent

# ===== INTERN =====
var ship_controller: ShipController
var current_model:   Node3D
var auto_fire:       bool = false

## Debounce für Auto-Fire-Hinweis (verhindert Log-Flut wenn Ziel nicht feindlich).
var _last_auto_fire_block_log: float = 0.0


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	# ── WICHTIG ── diese beiden Zeilen MÜSSEN da sein!
	add_to_group("ships")
	add_to_group(FactionSystem.get_group_name(ship_data.faction))

	print("[PLAYER DEBUG] Gruppen: ", get_groups())
	print("[PLAYER DEBUG] ship_data vorhanden? ", ship_data != null)
	if ship_data:
		print("[PLAYER DEBUG] Meine Fraktion: ", ShipData.Faction.keys()[ship_data.faction])

	_dbg("=== PLAYER CONTROLLER READY ===")
	_dbg("  ship_data  : %s" % ("SET → " + ship_data.ship_name if ship_data else "❌ NULL"))
	_dbg("  input_comp : %s" % (input_comp != null))

	if not ship_data:
		push_error("[PlayerController] Kein ship_data zugewiesen!")
		return

	if ship_data.ship_scene_path.is_empty():
		push_error("[PlayerController] ship_data.ship_scene_path ist leer!")
		return

	if not ship_data.stats:
		push_warning("[PlayerController] ship_data.stats ist NULL – Bewegung funktioniert nicht!")

	_instantiate_ship()

	if input_comp:
		input_comp.phaser_pressed.connect(_on_phaser_pressed)
		_dbg("  phaser_pressed verbunden ✓")
	else:
		push_warning("[PlayerController] Kein InputComponent gefunden!")


# ─────────────────────────────────────────────────────────────────────────────
# SCHIFF INSTANZIIEREN
# ─────────────────────────────────────────────────────────────────────────────

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
		push_error("[PlayerController] Kein ShipController in '%s' gefunden!" \
			% ship_data.ship_scene_path)
		instance.queue_free()
		return

	sc.ship_data = ship_data
	_dbg("  ship_data gesetzt ✓ (vor add_child)")

	add_child(instance)

	ship_controller = sc
	current_model   = ship_controller.get_model()

	# ── TargetingSystem als Spieler konfigurieren ─────────────────────────
	var ts := ship_controller.targeting_system
	if ts:
		ts.setup_as_player()
		_dbg("  TargetingSystem: setup_as_player() aufgerufen")
	else:
		push_warning("[PlayerController] Kein TargetingSystem im Schiff – kein Reticle!")

	_dbg("  current_model : %s" % (current_model.name if current_model else "NULL"))
	_dbg("  ShipController '%s' bereit" % ship_controller.ship_name)
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
			print("[PlayerController] Mouse Button: %d | action fire_torpedo=%s" % [
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
		print("[PlayerController] fire_torpedo Input erkannt!")
		_on_torpedo_pressed()
		
	# Cloak toggeln mit Taste C (Action: "toggle_cloak" in Project Settings anlegen)
	if event.is_action_pressed("toggle_cloak"):
		if ship_controller and ship_controller.has_method("toggle_cloak"):
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
	if not ship_controller:
		return

	var ts := ship_controller.targeting_system
	if not ts or ts.get_locked_target() == null:
		_dbg("⚠️ Kein Target - Phaser blockiert")
		return

	# Hinweis im Log wenn manuell auf Nicht-Feind gefeuert wird –
	# kein Block, nur Transparenz für Debug-Sessions.
	if not ts.is_current_target_hostile():
		_dbg("⚠️ MANUAL FIRE auf Nicht-Feind '%s' – Ruf-Konsequenz!" % \
			ts.get_locked_target().name)

	var fired: int = ship_controller.fire_phasers()
	if fired == 0:
		_dbg("⚠️ Nichts gefeuert (Arc-Check / Waffe nicht bereit)")


func _on_torpedo_pressed() -> void:
	if not ship_controller:
		return

	var ts := ship_controller.targeting_system
	if not ts or ts.get_locked_target() == null:
		_dbg("⚠️ Kein Target gesetzt – Torpedo blockiert")
		return

	if not ts.is_current_target_hostile():
		_dbg("⚠️ MANUAL TORPEDO auf Nicht-Feind '%s' – Ruf-Konsequenz!" % \
			ts.get_locked_target().name)

	var fired: int = ship_controller.fire_torpedos()
	if fired > 0:
		_dbg("🚀 Torpedo abgefeuert (%d)" % fired)
	else:
		_dbg("⚠️ Torpedo nicht bereit (Cooldown / Ammo leer)")


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
