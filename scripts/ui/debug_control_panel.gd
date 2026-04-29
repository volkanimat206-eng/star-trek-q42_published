# res://scripts/debug/debug_control_panel.gd
#
# Debug-Kontrollpanel – HYBRID: Szene im Editor, Logik im Script.
#
# SZENENSTRUKTUR (DebugControlPanel.tscn):
#
#   CanvasLayer                       ← Root, dieses Script zuweisen
#     PanelContainer    "Panel"       → @export panel
#       VBoxContainer
#         PanelContainer "TitleBar"  → @export title_bar   (Drag-Fläche)
#           HBoxContainer
#             Label      "TitleLabel" → @export title_label
#             Button     "CloseBtn"   → @export close_button
#         TabContainer   "Tabs"
#           MarginContainer "⚡ Spawner"
#             VBoxContainer
#               ScrollContainer
#                 VBoxContainer "ShipList"    → @export ship_list_container
#               HBoxContainer
#                 Button "SpawnBtn"           → @export spawn_button
#                 Button "DespawnBtn"         → @export despawn_button
#               Label   "SpawnCount"          → @export spawn_count_label
#           MarginContainer "⭐ Ruf"
#             VBoxContainer
#               ScrollContainer
#                 VBoxContainer "FactionList" → @export faction_list_container
#               Button "RepResetBtn"          → @export rep_reset_button
#           MarginContainer "🤖 KI-Control"
#             VBoxContainer
#               HBoxContainer
#                 Button "PatrolBtn"          → @export ki_patrol_button
#                 Button "AttackBtn"          → @export ki_attack_button
#               ScrollContainer
#                 VBoxContainer "NpcList"     → @export ki_list_container
#
# BEDIENUNG:
#   F12  → Panel ein-/ausblenden
#   Drag → Panel verschieben (Titelleiste anklicken)

extends CanvasLayer
class_name DebugControlPanel

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS – Spiellogik
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Spawner")
@export var spawn_ship_datas: Array[ShipData] = []
@export var spawn_offset_radius: float = 80.0
## Pfad zur AIController-Szene (.tscn) – muss Radar + ScanTimer enthalten.
@export var ai_controller_scene: PackedScene


@export_group("UI")
@export var toggle_key: Key = KEY_F12
@export var debug_flags_node: Control
@export var panel:        Control    # Geändert von PanelContainer auf Control
# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS – Szenen-Nodes (alle im Editor per Drag zuweisen)
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Scene Nodes – Panel")
@export var title_bar:    Control
@export var close_button: Button

@export_group("Scene Nodes – Spawner Tab")
@export var ship_list_container: VBoxContainer
@export var spawn_button:        Button
@export var despawn_button:      Button
@export var spawn_count_label:   Label

@export_group("Scene Nodes – Faction Tab")
@export var faction_list_container: VBoxContainer
@export var rep_reset_button:       Button

@export_group("Scene Nodes – Reputation Section")
## Kopf-Label der Reputation-Sektion (z.B. zeigt "⭐ Reputation" oder eine Zusammenfassung)
@export var reputation_label: Label
## VBoxContainer in dem die Ruf-Zeilen pro Fraktion erzeugt werden
@export var reputation_list: VBoxContainer
## Reset-Button für die neue Sektion (kann derselbe sein wie rep_reset_button,
## oder ein separater – beide werden korrekt verdrahtet wenn gesetzt)
@export var reputation_reset_button: Button

@export_group("Scene Nodes – KI Tab")
@export var ki_patrol_button:  Button
@export var ki_attack_button:  Button
@export var ki_list_container: VBoxContainer

@export_group("Scene Nodes – Debug Flags")
@export var flags_list: VBoxContainer
@export var reset_flags_button: Button

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS – Collapsible Sections
#
# Jede Sektion besteht aus einem Header (*Bar) und einem Content-Node
# (MarginContainer_*). Das Script hängt automatisch einen ▶/▼-Toggle-Button
# rechts an die Bar und schaltet den Content ein/aus.
#
# Wenn ein Feld leer bleibt, wird die entsprechende Sektion einfach nicht
# umgebaut – Abwärtskompatibel mit Szenen die nicht alle Bars haben.
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Scene Nodes – Collapsible Sections")
@export var spawn_bar:              Control
@export var spawn_content:          Control
@export var npc_bar:                Control
@export var npc_content:            Control
@export var faction_bar:            Control
@export var faction_content:        Control
@export var reputation_bar:         Control
@export var reputation_content:     Control
@export var sound_bar:              Control
@export var sound_content:          Control

@export var debug_flag_names: Array[String] = [
	"vfx.hull_impact", "vfx.torpedo_explosion", "vfx.fire",
	"ai.faction_hostile", "ai.faction_lookup", "ai.resolver",
	"weapons.projectile_path"
]

# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────

var player_node:         Node3D  = null  # wird automatisch via Gruppe "player" gefunden
var _is_visible:         bool    = false
var _dragging:           bool    = false
var _drag_offset:        Vector2 = Vector2.ZERO
var _selected_ship_data: ShipData = null
var _ship_buttons:       Array[Button] = []

# Cache für die Reputation-Sektion (die einzige Edit-Sektion für Player-Standing).
# Die alten _rep_labels / _rep_bars wurden entfernt – die Faction-Sektion zeigt
# jetzt eine statische Relations-Matrix (read-only, keine Rep-Edits).
var _rep2_labels: Dictionary = {}
var _rep2_bars:   Dictionary = {}

var _ki_refresh_timer:   float = 0.0
# Interner Speicher für die Zustände
var _active_flags: Dictionary = {}

# Collapsible-Sections-Registry
# key: String (interner Sektions-Name)
# value: Dictionary mit {bar, content, toggle_button, is_open}
var _collapsible_sections: Dictionary = {}


const KI_REFRESH_INTERVAL: float = 0.5
const COL_HOSTILE:  Color = Color(1.0, 0.25, 0.25)
const COL_NEUTRAL:  Color = Color(0.9, 0.85, 0.4)
const COL_FRIENDLY: Color = Color(0.3, 0.9, 0.4)
const COL_ACCENT:   Color = Color(0.25, 0.55, 1.0)

# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 100
	
	_find_player()

	if close_button:   close_button.pressed.connect(_toggle_panel)
	if spawn_button:   spawn_button.pressed.connect(_on_spawn_pressed)
	if despawn_button: despawn_button.pressed.connect(_on_despawn_all_pressed)
	if rep_reset_button: rep_reset_button.pressed.connect(_on_rep_reset_pressed)
	if reputation_reset_button and reputation_reset_button != rep_reset_button:
		reputation_reset_button.pressed.connect(_on_rep_reset_pressed)
	if ki_patrol_button: ki_patrol_button.pressed.connect(_on_all_patrol_pressed)
	if ki_attack_button: ki_attack_button.pressed.connect(_on_all_attack_pressed)
	if title_bar: title_bar.gui_input.connect(_on_titlebar_input)

	_populate_ship_list()
	_populate_faction_list()
	_populate_reputation_section()   # neue Sektion
	_setup_debug_flags()

	# Externe Ruf-Änderungen (z.B. NPC wird beschossen → modify_standing)
	# live in die UI spiegeln. Signal heißt "standing_changed" im ReputationSystem.
	if ReputationSystem.has_signal("standing_changed"):
		if not ReputationSystem.standing_changed.is_connected(_on_reputation_externally_changed):
			ReputationSystem.standing_changed.connect(_on_reputation_externally_changed)

	# Externe Faction-Relation-Änderungen (z.B. wenn Code selbst die Config
	# ändert, nicht nur über das Debug-Panel) → Matrix auto-refreshen.
	if FactionSystem.has_signal("faction_relation_changed"):
		if not FactionSystem.faction_relation_changed.is_connected(_on_faction_relation_externally_changed):
			FactionSystem.faction_relation_changed.connect(_on_faction_relation_externally_changed)
	
	if panel: panel.visible = true

	if reset_flags_button:
		reset_flags_button.pressed.connect(_on_reset_flags_pressed)

	# Collapsible Sections aufbauen (nach allen populate-Calls, damit der
	# Content bereits seine Endgröße hat bevor wir ihn ein-/ausblenden)
	_setup_collapsible_sections()
	# INITIALER STATUS-FIX:
	_is_visible = false
	if panel: 
		panel.visible = false
	if debug_flags_node: 
		debug_flags_node.visible = false

# ─────────────────────────────────────────────────────────────────────────────
# COLLAPSIBLE SECTIONS
# ─────────────────────────────────────────────────────────────────────────────

## Registriert alle Bar/Content-Paare, hängt Toggle-Buttons an die Bars und
## setzt die Anfangszustände. Nur Spawn ist initial offen.
func _setup_collapsible_sections() -> void:
	# (Sektions-Key, Bar-Node, Content-Node, initial_offen)
	var sections: Array = [
		["spawn",      spawn_bar,      spawn_content,      true],
		["npc",        npc_bar,        npc_content,        false],
		["faction",    faction_bar,    faction_content,    false],
		["reputation", reputation_bar, reputation_content, true],
		["sound",      sound_bar,      sound_content,      false],
	]

	for entry in sections:
		var key:     String  = entry[0]
		var bar:     Control = entry[1]
		var content: Control = entry[2]
		var start_open: bool = entry[3]

		# Sektion überspringen wenn Nodes nicht verdrahtet sind
		if not is_instance_valid(bar) or not is_instance_valid(content):
			continue

		_register_collapsible(key, bar, content, start_open)


## Baut eine einzelne Collapsible-Section auf.
## Fügt einen ▶/▼-Button rechts an die Bar und verdrahtet den Toggle.
func _register_collapsible(key: String, bar: Control, content: Control, start_open: bool) -> void:
	# Sicherheit: Wenn die Bar keinen Container als Kind hat, erzeugen wir einen
	# Fallback-HBox. Dein Szenenbaum zeigt aber dass Bars bereits einen
	# HBoxContainer enthalten – den nutzen wir wenn vorhanden.
	var host: Node = _find_first_hbox_in(bar)
	if host == null:
		host = bar   # Letzter Fallback: direkt an die Bar hängen

	# Toggle-Button erzeugen
	var toggle := Button.new()
	toggle.flat = true
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.custom_minimum_size = Vector2(24, 20)
	toggle.add_theme_font_size_override("font_size", 12)
	toggle.size_flags_horizontal = Control.SIZE_SHRINK_END | Control.SIZE_EXPAND
	toggle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	host.add_child(toggle)
	# An das Ende verschieben (rechte Seite der Bar)
	host.move_child(toggle, host.get_child_count() - 1)

	# State registrieren
	_collapsible_sections[key] = {
		"bar": bar,
		"content": content,
		"toggle_button": toggle,
		"is_open": start_open,
	}

	# Klick-Handler mit Capture des Keys
	var cap_key := key
	toggle.pressed.connect(func() -> void:
		_toggle_collapsible(cap_key)
	)

	# Anfangszustand anwenden (Content + Pfeil)
	_apply_collapsible_state(key)


func _toggle_collapsible(key: String) -> void:
	if not _collapsible_sections.has(key):
		return
	var section: Dictionary = _collapsible_sections[key]
	section["is_open"] = not section["is_open"]
	_apply_collapsible_state(key)


## Wendet den aktuellen is_open-State auf Content-Sichtbarkeit und Pfeil-Icon an.
func _apply_collapsible_state(key: String) -> void:
	if not _collapsible_sections.has(key):
		return
	var section: Dictionary = _collapsible_sections[key]
	var content: Control = section["content"]
	var toggle:  Button  = section["toggle_button"]
	var is_open: bool    = section["is_open"]

	if is_instance_valid(content):
		content.visible = is_open
	if is_instance_valid(toggle):
		toggle.text = "▼" if is_open else "▶"


## Sucht rekursiv nach dem ersten HBoxContainer als Kind der Bar.
## Dein Szenenbaum hat in der Regel Bar → HBoxContainer → Inhalt,
## wir wollen den Toggle-Button in diesen HBoxContainer einhängen.
func _find_first_hbox_in(node: Node) -> HBoxContainer:
	for child in node.get_children():
		if child is HBoxContainer:
			return child as HBoxContainer
	# Fallback: tiefere Suche (eine Ebene)
	for child in node.get_children():
		for grandchild in child.get_children():
			if grandchild is HBoxContainer:
				return grandchild as HBoxContainer
	return null


func _on_reset_flags_pressed() -> void:
	# 1. Alle Flags im Manager auf false setzen
	DebugManager.reset_all_flags()
	
	# 2. Die UI-Elemente (Checkboxen) aktualisieren
	# Wir bauen die Liste einfach neu auf, damit alle Häkchen verschwinden
	_setup_debug_flags()
	
	_show_status("🧹 Alle Debug-Flags deaktiviert.")

# ─────────────────────────────────────────────────────────────────────────────
# INPUT / PROCESS
# ─────────────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == toggle_key:
			_toggle_panel()
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _is_visible:
		return
	_ki_refresh_timer += delta
	if _ki_refresh_timer >= KI_REFRESH_INTERVAL:
		_ki_refresh_timer = 0.0
		_refresh_ki_list()
	if _dragging and panel:
		panel.position = get_viewport().get_mouse_position() + _drag_offset


# ─────────────────────────────────────────────────────────────────────────────
# BEFÜLLEN – Spawner (einmalig, statische Schiffsliste)
# ─────────────────────────────────────────────────────────────────────────────

func _find_player() -> void:
	var players := get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		player_node = players[0] as Node3D
		print("[DebugPanel] Player gefunden: %s" % player_node.name)
	else:
		push_warning("[DebugPanel] Kein Node in Gruppe 'player' gefunden!")


func _populate_ship_list() -> void:
	if not ship_list_container: return

	if spawn_ship_datas.is_empty():
		var warn := Label.new()
		warn.text = "⚠ Keine ShipData im Inspector zugewiesen!"
		warn.add_theme_color_override("font_color", COL_NEUTRAL)
		ship_list_container.add_child(warn)
		return

	for sd: ShipData in spawn_ship_datas:
		var btn := Button.new()
		btn.text      = "%-22s  [%s]" % [sd.ship_name, ShipData.Faction.keys()[sd.faction]]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.toggle_mode = true
		btn.add_theme_font_size_override("font_size", 12)
		
		# FIX 1: Verhindert, dass der Button die TAB-Taste für das Spiel schluckt
		btn.focus_mode = Control.FOCUS_NONE
		
		var captured := sd
		btn.pressed.connect(func() -> void: _select_ship(captured, btn))
		ship_list_container.add_child(btn)
		_ship_buttons.append(btn)

	_update_spawn_count_label()


# ─────────────────────────────────────────────────────────────────────────────
# BEFÜLLEN – Faction-Matrix (READ-ONLY, zeigt FactionSystem-Regeln)
#
# AAA-Trennung:
#   FACTION CONTROL     → statische Weltregeln aus FactionSystem (hier)
#   REPUTATION CONTROL  → dynamisches Player-Standing mit Edit-Buttons (unten)
#
# Keine ±-Buttons in dieser Sektion – die Matrix ist read-only. Die Daten
# ändern sich zur Laufzeit nicht (Hostile-Pairs sind fest).
# ─────────────────────────────────────────────────────────────────────────────

func _populate_faction_list() -> void:
	if not faction_list_container:
		return

	# Alte Kinder wegräumen (falls Hot-Reload)
	for child in faction_list_container.get_children():
		child.queue_free()

	# NEUTRAL auslassen – ist kein "Mitspieler"
	var relevant: Array[int] = []
	for f: int in ShipData.Faction.values():
		if f != ShipData.Faction.NEUTRAL:
			relevant.append(f)

	# Header-Zeile mit Hint und Reload-Button
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)

	var hint := Label.new()
	hint.text = "Klick auf Status zum Togglen · wird live in .tres gespeichert"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(hint)

	var reload_btn := Button.new()
	reload_btn.text = "↻ Reload"
	reload_btn.focus_mode = Control.FOCUS_NONE
	reload_btn.add_theme_font_size_override("font_size", 10)
	reload_btn.custom_minimum_size = Vector2(70, 20)
	reload_btn.tooltip_text = "Lädt die .tres neu (verwirft ungespeicherte Änderungen)"
	reload_btn.pressed.connect(func() -> void:
		FactionSystem.reload_config()
		_populate_faction_list()
		_show_status("↻ FactionConfig aus .tres neu geladen")
	)
	header_row.add_child(reload_btn)

	faction_list_container.add_child(header_row)

	# Pro Fraktion einen Block: "[KLINGON]" + Zeilen "→ FEDERATION   HOSTILE"
	for faction_val: int in relevant:
		faction_list_container.add_child(_build_faction_matrix_block(faction_val, relevant))


func _build_faction_matrix_block(faction_val: int, all_factions: Array[int]) -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 1)

	# Fraktions-Header
	var header := Label.new()
	header.text = "[%s]" % ShipData.Faction.keys()[faction_val]
	header.add_theme_font_size_override("font_size", 12)
	header.add_theme_color_override("font_color", COL_ACCENT)
	block.add_child(header)

	# Zeile pro anderer Fraktion
	for other_val: int in all_factions:
		if other_val == faction_val:
			continue
		block.add_child(_build_faction_matrix_row(faction_val, other_val))

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	block.add_child(spacer)

	return block


func _build_faction_matrix_row(faction_a: int, faction_b: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var arrow := Label.new()
	arrow.text = "  →"
	arrow.add_theme_font_size_override("font_size", 11)
	arrow.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	arrow.custom_minimum_size = Vector2(20, 0)
	row.add_child(arrow)

	var name_lbl := Label.new()
	name_lbl.text = ShipData.Faction.keys()[faction_b]
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.custom_minimum_size = Vector2(100, 0)
	row.add_child(name_lbl)

	# Klickbarer Status-Button – Live-Editor:
	# Klick toggled HOSTILE ↔ neutral in der FactionConfig und persistiert die .tres.
	var hostile: bool = RelationshipResolver.is_faction_pair_hostile(faction_a, faction_b)
	var btn := Button.new()
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(110, 20)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_size_override("font_size", 11)
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.tooltip_text = "Klicken um HOSTILE ↔ neutral zu togglen"
	_style_faction_relation_button(btn, hostile)

	var cap_a: int = faction_a
	var cap_b: int = faction_b
	btn.pressed.connect(func() -> void:
		_toggle_faction_relation(cap_a, cap_b)
	)
	row.add_child(btn)

	return row


func _style_faction_relation_button(btn: Button, hostile: bool) -> void:
	if hostile:
		btn.text = "❌ HOSTILE"
		btn.add_theme_color_override("font_color", COL_HOSTILE)
	else:
		btn.text = "· neutral"
		btn.add_theme_color_override("font_color", Color(0.5, 0.55, 0.6))


## Live-Editor: toggled die statische Beziehung zwischen zwei Fraktionen.
## Schreibt in-memory sofort, persistiert die .tres via FactionSystem.
func _toggle_faction_relation(a: int, b: int) -> void:
	if not FactionSystem.has_method("set_faction_pair_hostile"):
		_show_status("⚠ FactionSystem kennt set_faction_pair_hostile() nicht – upgrade nötig.")
		return

	var current: bool = RelationshipResolver.is_faction_pair_hostile(a, b)
	var new_val: bool = not current
	FactionSystem.set_faction_pair_hostile(a, b, new_val)

	# Matrix neu aufbauen, damit alle Zeilen den neuen Stand zeigen.
	# (Die Relation ist symmetrisch – Zeile A→B und Zeile B→A müssen beide
	# aktualisiert werden.)
	_populate_faction_list()

	var sym: String = "❌ HOSTILE" if new_val else "· neutral"
	_show_status("%s ↔ %s → %s  (gespeichert)" % [
		ShipData.Faction.keys()[a],
		ShipData.Faction.keys()[b],
		sym
	])


# ─────────────────────────────────────────────────────────────────────────────
# BEFÜLLEN & REFRESH – NEUE Reputation-Sektion (ReputationBar / ReputationList)
#
# Läuft parallel zur alten faction_list_container-Logik, damit beide Sektionen
# (alter Ruf-Tab und neue Reputation-Sektion) unabhängig koexistieren können.
# Struktur pro Zeile identisch: Name | Standing-Label farbig | ±25/±10-Buttons | Bar
# ─────────────────────────────────────────────────────────────────────────────

func _populate_reputation_section() -> void:
	# ── DIAGNOSE: sofort im Log erkennen ob die .tscn-Verdrahtung stimmt ────
	print("[DebugPanel|REP] ══════ Reputation-Sektion Setup ══════")
	print("  reputation_label   : %s" % ("✓ %s" % reputation_label.get_path() if reputation_label else "❌ NULL (im Inspector zuweisen!)"))
	print("  reputation_list    : %s" % ("✓ %s" % reputation_list.get_path()  if reputation_list  else "❌ NULL (im Inspector zuweisen!)"))
	print("  reputation_bar     : %s" % ("✓ %s" % reputation_bar.get_path()   if reputation_bar   else "❌ NULL"))
	print("  reputation_content : %s" % ("✓ %s" % reputation_content.get_path() if reputation_content else "❌ NULL"))

	if not reputation_list:
		push_warning("[DebugControlPanel] reputation_list ist nicht verdrahtet – Reputation-Sektion bleibt leer.")
		return

	# Alte Zeilen raus (falls das Script mal neu geladen wird)
	for child in reputation_list.get_children():
		child.queue_free()
	_rep2_labels.clear()
	_rep2_bars.clear()

	# FEDERATION und NEUTRAL auslassen – Spielerfraktion und "nicht anwendbar"
	var skip := [ShipData.Faction.FEDERATION, ShipData.Faction.NEUTRAL]
	var created_count := 0
	for f: int in ShipData.Faction.values():
		var faction := f as ShipData.Faction
		if faction in skip:
			continue
		reputation_list.add_child(_build_reputation_row(faction))
		created_count += 1

	if created_count == 0:
		push_warning("[DebugControlPanel] Keine Fraktionen in ShipData.Faction gefunden (außer skip).")

	# Debug-Button: Resolver-Zustand dumpen (Aggro + Ships in Gruppe)
	var dump_row := HBoxContainer.new()
	dump_row.add_theme_constant_override("separation", 6)

	var dump_btn := Button.new()
	dump_btn.text = "🔍 Dump Resolver State"
	dump_btn.focus_mode = Control.FOCUS_NONE
	dump_btn.add_theme_font_size_override("font_size", 11)
	dump_btn.tooltip_text = "Gibt alle aktiven Aggro-Einträge und Schiffs-Roots auf den Output aus"
	dump_btn.pressed.connect(_on_dump_resolver_pressed)
	dump_row.add_child(dump_btn)

	var clear_btn := Button.new()
	clear_btn.text = "🧹 Clear Aggro"
	clear_btn.focus_mode = Control.FOCUS_NONE
	clear_btn.add_theme_font_size_override("font_size", 11)
	clear_btn.tooltip_text = "Löscht alle aktiven Aggro-Einträge (Reputation bleibt)"
	clear_btn.pressed.connect(_on_clear_aggro_pressed)
	dump_row.add_child(clear_btn)

	reputation_list.add_child(dump_row)

	_refresh_reputation_header()


func _build_reputation_row(faction: ShipData.Faction) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 6)
	container.add_child(top_row)

	# Fraktions-Name
	var name_lbl := Label.new()
	name_lbl.text = "%-12s" % ShipData.Faction.keys()[faction]
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.custom_minimum_size = Vector2(100, 0)
	top_row.add_child(name_lbl)

	# Standing-Wert (farbig, wird im Refresh gesetzt)
	var standing_lbl := Label.new()
	standing_lbl.custom_minimum_size = Vector2(55, 0)
	standing_lbl.add_theme_font_size_override("font_size", 12)
	top_row.add_child(standing_lbl)
	_rep2_labels[faction] = standing_lbl

	# ±-Buttons mit Capture der aktuellen Fraktion und Delta
	for delta_val: int in [-25, -10, 10, 25]:
		var btn := Button.new()
		btn.text = ("%+d" % delta_val)
		btn.custom_minimum_size = Vector2(36, 22)
		btn.add_theme_font_size_override("font_size", 11)
		var cap_f := faction
		var cap_d := float(delta_val)
		btn.pressed.connect(func() -> void:
			ReputationSystem.modify_standing(cap_f, cap_d)
			_refresh_reputation_section()
		)
		top_row.add_child(btn)

	# Farbige Balken-Anzeige
	var bar := ProgressBar.new()
	bar.min_value = -100.0
	bar.max_value = 100.0
	bar.custom_minimum_size = Vector2(0, 8)
	bar.show_percentage = false
	container.add_child(bar)
	_rep2_bars[faction] = bar

	_refresh_reputation_row(faction)
	return container


func _refresh_reputation_section() -> void:
	if not reputation_list:
		return
	var skip := [ShipData.Faction.FEDERATION, ShipData.Faction.NEUTRAL]
	for f: int in ShipData.Faction.values():
		var faction := f as ShipData.Faction
		if faction in skip:
			continue
		_refresh_reputation_row(faction)
	_refresh_reputation_header()


func _refresh_reputation_row(faction: ShipData.Faction) -> void:
	var standing: float = ReputationSystem.get_standing(faction)
	var disp            = ReputationSystem.get_disposition(faction)
	var col: Color
	match disp:
		ReputationSystem.Disposition.HOSTILE:  col = COL_HOSTILE
		ReputationSystem.Disposition.NEUTRAL:  col = COL_NEUTRAL
		ReputationSystem.Disposition.FRIENDLY: col = COL_FRIENDLY
		_:                                     col = Color.WHITE

	if _rep2_labels.has(faction):
		var lbl := _rep2_labels[faction] as Label
		lbl.text = "%+.0f" % standing
		lbl.add_theme_color_override("font_color", col)

	if _rep2_bars.has(faction):
		var bar := _rep2_bars[faction] as ProgressBar
		bar.value = standing
		var fill := StyleBoxFlat.new()
		fill.bg_color = col
		bar.add_theme_stylebox_override("fill", fill)


## Header-Label zeigt nur den Titel "⭐ Reputation".
## Die eigentlichen Werte erscheinen als Rows im reputation_list-Container
## darunter. Früher enthielt das Label eine Inline-Summary ("— KLI -60 | ..."),
## die optisch wie eine Liste neben dem Label aussah – das hat verwirrt.
func _refresh_reputation_header() -> void:
	if not reputation_label:
		return
	reputation_label.text = "⭐ Reputation"


## Reagiert wenn irgendwo anders (z.B. AIController.on_hit_by_player) der Ruf
## geändert wird. Hält beide Sektionen synchron, ohne dass das Panel manuell
## neu geöffnet werden muss.
## Signal-Signatur: standing_changed(faction, old_val, new_val)
func _on_reputation_externally_changed(_faction, _old_val, _new_val) -> void:
	_refresh_reputation_section()


func _on_faction_relation_externally_changed(_a: int, _b: int, _is_hostile: bool) -> void:
	# Matrix neu aufbauen. Nur wenn Panel sichtbar, sonst reicht es beim
	# nächsten _toggle_panel-Öffnen.
	if _is_visible:
		_populate_faction_list()


# ─────────────────────────────────────────────────────────────────────────────
# REFRESH – KI-Liste (periodisch)
# ─────────────────────────────────────────────────────────────────────────────

func _refresh_ki_list() -> void:
	if not ki_list_container: return
	for child in ki_list_container.get_children():
		child.queue_free()

	var npcs := _get_all_ai_controllers()
	if npcs.is_empty():
		var lbl := Label.new()
		lbl.text = "Keine aktiven NPC-Schiffe."
		lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		ki_list_container.add_child(lbl)
		return

	for ai: AIController in npcs:
		ki_list_container.add_child(_build_ki_row(ai))


func _build_ki_row(ai: AIController) -> Control:
	var box := PanelContainer.new()
	var sb  := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.18)
	sb.corner_radius_top_left    = 4
	sb.corner_radius_top_right   = 4
	sb.corner_radius_bottom_left  = 4
	sb.corner_radius_bottom_right = 4
	box.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	box.add_child(vbox)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	vbox.add_child(top)

	var name_lbl := Label.new()
	name_lbl.text = ai.ship_data.ship_name if ai.ship_data else ai.name
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_lbl)

	var faction_lbl := Label.new()
	faction_lbl.text = "[%s]" % (ShipData.Faction.keys()[ai.ship_data.faction] if ai.ship_data else "?")
	faction_lbl.add_theme_font_size_override("font_size", 10)
	faction_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.8))
	top.add_child(faction_lbl)

	var bot := HBoxContainer.new()
	bot.add_theme_constant_override("separation", 4)
	vbox.add_child(bot)

	var state_str: String = AIController.State.keys()[ai._state] as String
	var state_col: Color = Color(0.9, 0.5, 0.2) if state_str == "COMBAT" else Color(0.4, 0.8, 0.4)

	var state_lbl := Label.new()
	state_lbl.text = "● %s" % state_str
	state_lbl.add_theme_font_size_override("font_size", 11)
	state_lbl.add_theme_color_override("font_color", state_col)
	state_lbl.custom_minimum_size = Vector2(90, 0)
	bot.add_child(state_lbl)

	var target_lbl := Label.new()
	target_lbl.text = "→ %s" % (ai._target.name if ai._target and is_instance_valid(ai._target) else "—")
	target_lbl.add_theme_font_size_override("font_size", 11)
	target_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	target_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot.add_child(target_lbl)

	var p_btn := Button.new()
	p_btn.text = "PATROL"
	p_btn.focus_mode = Control.FOCUS_NONE # WICHTIG
	p_btn.pressed.connect(func() -> void: _force_ai_patrol(ai))

	var a_btn := Button.new()
	a_btn.text = "ATTACK"
	a_btn.focus_mode = Control.FOCUS_NONE # WICHTIG
	a_btn.pressed.connect(func() -> void: _force_ai_attack(ai))

	# Hull + Schild Balken
	var bars_row := HBoxContainer.new()
	bars_row.add_theme_constant_override("separation", 4)
	vbox.add_child(bars_row)

	var hull_val: float = ai.ship_controller.get_hull_integrity() if ai.ship_controller else 0.0
	var shld_val: float = ai.ship_controller.shield_system.get_integrity() \
		if ai.ship_controller and ai.ship_controller.shield_system else 0.0

	for cfg in [["H", Color(0.9,0.5,0.2), Color(0.85,0.35,0.1), hull_val],
				["S", Color(0.3,0.7,1.0),  Color(0.2,0.55,0.9),  shld_val]]:
		var lbl := Label.new()
		lbl.text = cfg[0]; lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", cfg[1])
		lbl.custom_minimum_size = Vector2(12, 0)
		bars_row.add_child(lbl)
		var bar := ProgressBar.new()
		bar.min_value = 0.0; bar.max_value = 1.0; bar.value = cfg[3]
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.custom_minimum_size = Vector2(0, 7); bar.show_percentage = false
		var fill := StyleBoxFlat.new(); fill.bg_color = cfg[2]
		bar.add_theme_stylebox_override("fill", fill)
		bars_row.add_child(bar)

	return box


# ─────────────────────────────────────────────────────────────────────────────
# BUTTON-HANDLER
# ─────────────────────────────────────────────────────────────────────────────

func _select_ship(sd: ShipData, pressed_btn: Button) -> void:
	_selected_ship_data = sd
	for btn: Button in _ship_buttons:
		if btn != pressed_btn: btn.button_pressed = false


func _on_spawn_pressed() -> void:
	if not _selected_ship_data:
		_show_status("⚠ Kein Schiff ausgewählt!"); return
	if _selected_ship_data.ship_scene_path.is_empty():
		_show_status("⚠ ShipData hat keine ship_scene_path!"); return

	var origin: Vector3 = player_node.global_position if player_node and is_instance_valid(player_node) else Vector3.ZERO
	var angle:  float   = randf() * TAU
	var spawn_pos := origin + Vector3(cos(angle) * spawn_offset_radius, 20.0, sin(angle) * spawn_offset_radius)

	if not ai_controller_scene:
		_show_status("⚠ Keine AIController-Scene zugewiesen! (Inspector → Spawner → Ai Controller Scene)")
		return
	var ai := ai_controller_scene.instantiate() as AIController
	if not ai:
		_show_status("⚠ AIController-Scene konnte nicht instanziiert werden!")
		return
	ai.ship_data = _selected_ship_data
	ai.patrol_center = spawn_pos
	get_tree().current_scene.add_child(ai)
	ai.global_position = spawn_pos
	_show_status("✓ %s gespawnt bei (%.0f, %.0f, %.0f)" % [_selected_ship_data.ship_name, spawn_pos.x, spawn_pos.y, spawn_pos.z])
	_update_spawn_count_label()
	_refresh_ki_list()


func _on_despawn_all_pressed() -> void:
	var npcs := _get_all_ai_controllers()
	for ai: AIController in npcs:
		for group in ai.get_groups(): ai.remove_from_group(group)
		ai.queue_free()
	_show_status("🗑 %d NPC(s) entfernt." % npcs.size())
	call_deferred("_update_spawn_count_label")
	call_deferred("_refresh_ki_list")


func _on_rep_reset_pressed() -> void:
	ReputationSystem.reset()
	RelationshipResolver.clear_all_aggro()
	_refresh_reputation_section()
	_show_status("↺ Reputation + Aggro zurückgesetzt.")


func _on_dump_resolver_pressed() -> void:
	var resolver: Node = get_tree().root.get_node_or_null("RelationshipResolver")
	if not resolver:
		_show_status("❌ RelationshipResolver-Autoload nicht gefunden!")
		push_warning("[DebugPanel] RelationshipResolver nicht als Autoload registriert.")
		return
	if not resolver.has_method("debug_dump_state"):
		_show_status("❌ Resolver kennt debug_dump_state() nicht – veraltete Version?")
		return
	resolver.debug_dump_state()
	_show_status("🔍 Resolver-State auf Output gedumpt (siehe Debug-Konsole)")


func _on_clear_aggro_pressed() -> void:
	if not RelationshipResolver.has_method("clear_all_aggro"):
		_show_status("❌ Resolver kennt clear_all_aggro() nicht")
		return
	RelationshipResolver.clear_all_aggro()
	_show_status("🧹 Alle Aggro-Einträge gelöscht")


func _on_all_patrol_pressed() -> void:
	var npcs := _get_all_ai_controllers()
	for ai: AIController in npcs: _force_ai_patrol(ai)
	_show_status("🔄 %d NPC(s) → PATROL" % npcs.size())


func _on_all_attack_pressed() -> void:
	if not player_node or not is_instance_valid(player_node):
		_show_status("⚠ Kein Player-Node gesetzt!"); return
	var npcs := _get_all_ai_controllers()
	for ai: AIController in npcs: _force_ai_attack(ai)
	_show_status("⚔ %d NPC(s) → COMBAT (Player)" % npcs.size())


func _force_ai_patrol(ai: AIController) -> void:
	if not is_instance_valid(ai): return
	# Nutzt die öffentliche API – kein Gefummel mehr an internen Feldern.
	# force_patrol() setzt State, Target, Radar-Visualizer und Scan-Timer
	# zentral zurück.
	ai.force_patrol()


func _force_ai_attack(ai: AIController) -> void:
	if not is_instance_valid(ai) or not player_node or not is_instance_valid(player_node): return
	ai._enter_combat(player_node)


# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────

func _get_all_ai_controllers() -> Array[AIController]:
	var result: Array[AIController] = []
	# Die "ships"-Gruppe enthält ShipController-Nodes (und den Player-CharacterBody3D),
	# NICHT die AIController selbst – die registrieren sich nicht in dieser Gruppe.
	# Deshalb für jeden Eintrag prüfen: ist es direkt ein AIController, oder ist
	# ein AIController in der Parent-Chain? Beide Fälle abdecken.
	for node in get_tree().get_nodes_in_group("ships"):
		if not is_instance_valid(node):
			continue
		# Direkt ein AIController?
		if node is AIController:
			if not result.has(node):
				result.append(node as AIController)
			continue
		# ShipController (oder sonstiger Child-Node) → AIController als Ahnen suchen
		var ancestor: Node = node.get_parent()
		while is_instance_valid(ancestor):
			if ancestor is AIController:
				if not result.has(ancestor):
					result.append(ancestor as AIController)
				break
			ancestor = ancestor.get_parent()
	return result

func _toggle_panel() -> void:
	_is_visible = not _is_visible
	
	# Umschalten des Haupt-Panels (Debug_Control)
	if panel: 
		panel.visible = _is_visible
		panel.mouse_filter = Control.MOUSE_FILTER_PASS if _is_visible else Control.MOUSE_FILTER_IGNORE
	
	# NEU: Umschalten der Debug_Flags
	if debug_flags_node:
		debug_flags_node.visible = _is_visible
		debug_flags_node.mouse_filter = Control.MOUSE_FILTER_PASS if _is_visible else Control.MOUSE_FILTER_IGNORE
	
	if _is_visible:
		_refresh_reputation_section()
		_refresh_ki_list()
		_update_spawn_count_label()

func _update_spawn_count_label() -> void:
	if spawn_count_label:
		spawn_count_label.text = "Aktive NPCs in Szene: %d" % _get_all_ai_controllers().size()


func _show_status(msg: String) -> void:
	print("[DebugPanel] %s" % msg)


func _on_titlebar_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed and panel:
				_drag_offset = panel.position - get_viewport().get_mouse_position()
	elif event is InputEventMouseMotion and _dragging and panel:
		panel.position = get_viewport().get_mouse_position() + _drag_offset

func _setup_debug_flags() -> void:
	if not flags_list: return
	
	# 1. Alle gewünschten Flags im Manager vor-registrieren
	for full_name in debug_flag_names:
		if not DebugManager.get_all_flags().has(full_name):
			DebugManager.set_flag(full_name, false)

	# 2. UI aufräumen
	for child in flags_list.get_children():
		child.queue_free()
		
	var groups = {}
	var all_flags = DebugManager.get_all_flags()

	# 3. Flags sortieren (vfx.* -> VFX)
	for full_name in all_flags.keys():
		var parts = full_name.split(".")
		var group_name = parts[0].to_upper() if parts.size() > 1 else "GENERAL"
		var display_name = parts[1] if parts.size() > 1 else parts[0]
		
		if not groups.has(group_name): groups[group_name] = []
		groups[group_name].append({"full": full_name, "display": display_name})

	# 4. UI bauen
	for group in groups:
		var head = Label.new()
		head.text = "\n[%s]" % group
		head.add_theme_color_override("font_color", COL_ACCENT)
		flags_list.add_child(head)
		
		for flag in groups[group]:
			var check = CheckBox.new()
			check.text = flag["display"].replace("_", " ")
			check.button_pressed = DebugManager.get_flag(flag["full"])
			
			# FIX 3: Checkbox darf keinen Fokus stehlen
			check.focus_mode = Control.FOCUS_NONE
			
			check.toggled.connect(func(is_pressed): 
				DebugManager.set_flag(flag["full"], is_pressed)
			)
			flags_list.add_child(check)
