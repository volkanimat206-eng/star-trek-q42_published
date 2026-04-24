# res://scripts/debug_overlay.gd
#
# Debug-Overlay – Player-Widget + dynamische Target-Liste (bis zu 4).
# Target-Widgets werden bei jedem Refresh neu gebaut wenn sich die Liste ändert.
#
# INSPECTOR:
#   player_path          → Player CharacterBody3D
#   player_widget_anchor → MarginContainer_Player
#   target_widget_anchor → MarginContainer_Player2  (VBoxContainer wird dort erzeugt)

extends CanvasLayer

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Referenzen")
@export var player_path: NodePath

@export_group("Scene Nodes")
@export var player_widget_anchor: Control
@export var target_widget_anchor: Control

@export_group("UI")
@export var widget_width: float = 340.0
@export var toggle_key: Key = KEY_F11

@export_group("Shield Zones")
## Zeigt eine kompakte 4-Zonen-Anzeige unter der Total-Shield-Bar.
## Jede Zone: [FWD|AFT|PRT|STB] mit Mini-Balken + HP-Prozent.
## Bleed-Zonen (< 20%) werden rot mit ⚠ markiert.
@export var show_shield_zones: bool = true

# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────

var _ship_controller: ShipController = null

# Player-Widget Refs
var _p_name_lbl:    Label       = null
var _p_faction_lbl: Label       = null
var _p_speed_lbl:   Label       = null
var _p_state_lbl:   Label       = null
var _p_target_lbl:  Label       = null
var _p_hull_bar:    ProgressBar = null
var _p_shld_bar:    ProgressBar = null

# Player Zone-Anzeige: 4 Einträge, jeder mit {label: Label, bar: ProgressBar}
var _p_zone_cells: Array = []

# Target-Liste: VBoxContainer der alle Target-Widgets hält
var _target_list_container: VBoxContainer = null

# Gecachte Target-Nodes zum Erkennen von Listenänderungen
var _last_targets: Array[Node3D] = []
var _overlay_visible: bool = true

const COL_COMBAT:   Color = Color(0.9, 0.5, 0.2)
const COL_PATROL:   Color = Color(0.4, 0.8, 0.4)
const COL_HULL:     Color = Color(0.85, 0.35, 0.1)
const COL_SHIELD:   Color = Color(0.2, 0.55, 0.9)
const COL_FACTION:  Color = Color(0.6, 0.6, 0.8)
const COL_SPEED:    Color = Color(0.6, 0.8, 0.6)
const COL_DIM:      Color = Color(0.5, 0.5, 0.5)
const COL_LOCKED:   Color = Color(1.0, 0.85, 0.2)   # Primärziel – Gold
const COL_BG:       Color = Color(0.10, 0.12, 0.17, 0.95)
const COL_BG_TGT:   Color = Color(0.14, 0.10, 0.10, 0.95)
const COL_BG_MULTI: Color = Color(0.12, 0.10, 0.14, 0.95)  # leicht lila für Multi-Targets

# Zone-spezifische Farben für die Shield-Zonen-Anzeige
const COL_ZONE_OK:    Color = Color(0.3, 0.7, 1.0)    # blau wie Shield-Bar, voll
const COL_ZONE_MID:   Color = Color(0.9, 0.8, 0.3)    # gelb, mittlere HP
const COL_ZONE_BLEED: Color = Color(1.0, 0.35, 0.35)  # rot, unter Bleed-Threshold
const COL_ZONE_LABEL: Color = Color(0.6, 0.7, 0.85)   # kühles Grau für Zone-Labels
const COL_ZONE_DOWN:  Color = Color(0.35, 0.12, 0.12) # Zone auf 0 HP, gedämpft

# Schwellwert ab dem die Zone-Farbe auf "mid" wechselt (0.5 = 50% HP)
const ZONE_MID_THRESHOLD: float = 0.5


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 99
	_find_ship_controller()
	_build_player_widget()
	_setup_target_list()


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS
# ─────────────────────────────────────────────────────────────────────────────

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == toggle_key:
			_overlay_visible = not _overlay_visible
			# Alle direkten Control-Kinder des CanvasLayer ein-/ausblenden
			for child in get_children():
				if child is Control:
					child.visible = _overlay_visible
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_instance_valid(_ship_controller):
		_find_ship_controller()
		return
	_refresh_player_widget()
	_refresh_target_list()


# ─────────────────────────────────────────────────────────────────────────────
# SHARED WIDGET BUILDER
# ─────────────────────────────────────────────────────────────────────────────

## Baut ein Ship-Info-Widget in den übergebenen Anchor.
## Gibt Array zurück: [name, faction, speed, state, extra, hull_bar, shld_bar, zone_cells]
## zone_cells: Array[Dictionary] mit {label: Label, bar: ProgressBar} pro Zone.
##             Leer wenn show_shield_zones=false.
func _build_ship_widget(anchor: Control, bg_color: Color) -> Array:
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(widget_width, 0)
	box.add_theme_stylebox_override("panel", _make_stylebox(bg_color))
	anchor.add_child(box)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	box.add_child(vbox)

	# Zeile 1: Name + Fraktion
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	vbox.add_child(top)

	var name_lbl := Label.new()
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_lbl)

	var faction_lbl := Label.new()
	faction_lbl.add_theme_font_size_override("font_size", 10)
	faction_lbl.add_theme_color_override("font_color", COL_FACTION)
	top.add_child(faction_lbl)

	# Zeile 2: Speed
	var speed_lbl := Label.new()
	speed_lbl.add_theme_font_size_override("font_size", 11)
	speed_lbl.add_theme_color_override("font_color", COL_SPEED)
	vbox.add_child(speed_lbl)

	# Zeile 3: State + Extra
	var bot := HBoxContainer.new()
	bot.add_theme_constant_override("separation", 6)
	vbox.add_child(bot)

	var state_lbl := Label.new()
	state_lbl.add_theme_font_size_override("font_size", 11)
	state_lbl.custom_minimum_size = Vector2(80, 0)
	bot.add_child(state_lbl)

	var extra_lbl := Label.new()
	extra_lbl.add_theme_font_size_override("font_size", 11)
	extra_lbl.add_theme_color_override("font_color", COL_DIM)
	extra_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot.add_child(extra_lbl)

	# Zeile 4: Hull + Shield Balken (Total)
	var bars := HBoxContainer.new()
	bars.add_theme_constant_override("separation", 4)
	vbox.add_child(bars)

	var hull_bar: ProgressBar
	var shld_bar: ProgressBar
	for cfg: Array in [["H", COL_HULL], ["S", COL_SHIELD]]:
		var lbl := Label.new()
		lbl.text = cfg[0]
		lbl.add_theme_font_size_override("font_size", 10)
		lbl.add_theme_color_override("font_color", cfg[1])
		lbl.custom_minimum_size = Vector2(12, 0)
		bars.add_child(lbl)

		var bar := ProgressBar.new()
		bar.min_value = 0.0; bar.max_value = 1.0; bar.value = 1.0
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.custom_minimum_size   = Vector2(0, 8)
		bar.show_percentage       = false
		var fill := StyleBoxFlat.new()
		fill.bg_color = cfg[1]
		bar.add_theme_stylebox_override("fill", fill)
		bars.add_child(bar)
		if cfg[0] == "H": hull_bar = bar
		else:             shld_bar = bar

	# Zeile 5: Zone-Reihe (optional, nur wenn show_shield_zones=true)
	# Layout: [FWD ▓▓▓░] [AFT ▓▓░░] [PRT ▓▓▓▓] [STB ▓▓░░]
	# Jede Zelle: vertikaler Mini-VBox mit Label oben, Mini-Bar darunter
	var zone_cells: Array = []
	if show_shield_zones:
		zone_cells = _build_zone_row(vbox)

	return [name_lbl, faction_lbl, speed_lbl, state_lbl, extra_lbl,
			hull_bar, shld_bar, zone_cells]


## Baut eine kompakte 4-Zonen-Reihe als Kind des übergebenen VBoxContainer.
## Liefert Array mit 4 Dictionaries: {label: Label, bar: ProgressBar}
## Reihenfolge entspricht ShieldZone.Zone: [FRONT, REAR, PORT, STAR]
func _build_zone_row(parent_vbox: VBoxContainer) -> Array:
	var cells: Array = []

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent_vbox.add_child(row)

	# Reihenfolge: FWD / AFT / PRT / STB entspricht ShieldZone.Zone Index 0..3
	for i: int in range(ShieldZone.COUNT):
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 1)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(cell)

		# Label (oben): z.B. "FWD 87"
		var lbl := Label.new()
		lbl.text = ShieldZone.label_of(i)
		lbl.add_theme_font_size_override("font_size", 9)
		lbl.add_theme_color_override("font_color", COL_ZONE_LABEL)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cell.add_child(lbl)

		# Mini-Bar (unten)
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.value     = 1.0
		bar.custom_minimum_size = Vector2(0, 5)
		bar.show_percentage     = false
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var fill := StyleBoxFlat.new()
		fill.bg_color = COL_ZONE_OK
		bar.add_theme_stylebox_override("fill", fill)
		cell.add_child(bar)

		cells.append({"label": lbl, "bar": bar})

	return cells


## Aktualisiert eine einzelne Zone-Cell basierend auf ShieldData und Zone-Index.
## Farbstufen:
##   > 50%       → blau  (OK)
##   20% - 50%   → gelb  (MID)
##   < 20% > 0%  → rot   (BLEED, mit ⚠-Marker)
##   = 0%        → dunkel (DOWN)
func _update_zone_cell(cell: Dictionary, shield_data: ShieldData, zone_index: int) -> void:
	var lbl: Label = cell.get("label")
	var bar: ProgressBar = cell.get("bar")
	if not lbl or not bar or not shield_data:
		return

	var integrity: float = shield_data.zone_integrity(zone_index)
	var is_bleed: bool   = shield_data.zone_is_bleeding(zone_index)
	var zone_name: String = ShieldZone.label_of(zone_index)

	# Label-Text: "FWD 87" (ohne Leerzeichen wird's zu eng auf schmalen Widgets)
	# Bei Bleed: "FWD 15⚠"
	var pct: int = int(round(integrity * 100.0))
	if integrity <= 0.0:
		lbl.text = "%s ✕" % zone_name
	elif is_bleed:
		lbl.text = "%s %d⚠" % [zone_name, pct]
	else:
		lbl.text = "%s %d" % [zone_name, pct]

	# Label-Farbe
	if integrity <= 0.0:
		lbl.add_theme_color_override("font_color", COL_ZONE_DOWN)
	elif is_bleed:
		lbl.add_theme_color_override("font_color", COL_ZONE_BLEED)
	else:
		lbl.add_theme_color_override("font_color", COL_ZONE_LABEL)

	# Bar-Wert + Farbe abgestuft
	bar.value = integrity
	var bar_color: Color
	if integrity <= 0.0:
		bar_color = COL_ZONE_DOWN
	elif is_bleed:
		bar_color = COL_ZONE_BLEED
	elif integrity < ZONE_MID_THRESHOLD:
		bar_color = COL_ZONE_MID
	else:
		bar_color = COL_ZONE_OK

	var fill: StyleBoxFlat = bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill:
		fill.bg_color = bar_color


## Aktualisiert alle 4 Zone-Zellen aus einem ShipController.
## Fallback: wenn kein ShieldSystem oder keine ShieldData, alle Zonen auf 0 setzen.
func _update_zone_cells(cells: Array, sc: ShipController) -> void:
	if cells.is_empty():
		return
	var sd: ShieldData = null
	if sc and sc.shield_system and sc.shield_system.data:
		sd = sc.shield_system.data

	if not sd:
		# Kein Shield-Data verfügbar – Zellen neutralisieren
		for c in cells:
			var lbl: Label = c.get("label")
			var bar: ProgressBar = c.get("bar")
			if lbl:
				lbl.text = "—"
				lbl.add_theme_color_override("font_color", COL_DIM)
			if bar:
				bar.value = 0.0
		return

	for i: int in range(ShieldZone.COUNT):
		if i >= cells.size():
			break
		_update_zone_cell(cells[i], sd, i)


# ─────────────────────────────────────────────────────────────────────────────
# PLAYER WIDGET
# ─────────────────────────────────────────────────────────────────────────────

func _build_player_widget() -> void:
	var anchor := player_widget_anchor
	if not anchor:
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_left", 12)
		m.add_theme_constant_override("margin_top",  12)
		m.set_anchors_preset(Control.PRESET_TOP_LEFT)
		add_child(m)
		anchor = m

	var refs := _build_ship_widget(anchor, COL_BG)
	_p_name_lbl    = refs[0]
	_p_faction_lbl = refs[1]
	_p_speed_lbl   = refs[2]
	_p_state_lbl   = refs[3]
	_p_target_lbl  = refs[4]
	_p_hull_bar    = refs[5]
	_p_shld_bar    = refs[6]
	_p_zone_cells  = refs[7] if refs.size() >= 8 else []


func _refresh_player_widget() -> void:
	var sc := _ship_controller

	if _p_name_lbl:
		_p_name_lbl.text = sc.ship_name if sc.ship_name else "Player"

	if _p_faction_lbl and sc.ship_data:
		_p_faction_lbl.text = "[%s]" % ShipData.Faction.keys()[sc.ship_data.faction]

	if _p_speed_lbl:
		var mc := sc.movement_comp
		_p_speed_lbl.text = "⚡ %.0f u/s" % absf(mc.current_speed) if mc else "⚡ —"

	var ts := sc.targeting_system
	var locked: Node3D = ts.locked_target if ts and is_instance_valid(ts) else null
	var multi: Array   = ts.multi_locked_targets if ts and is_instance_valid(ts) else []

	if _p_state_lbl:
		if locked and is_instance_valid(locked):
			_p_state_lbl.text = "● COMBAT"
			_p_state_lbl.add_theme_color_override("font_color", COL_COMBAT)
		else:
			_p_state_lbl.text = "● MANUAL"
			_p_state_lbl.add_theme_color_override("font_color", COL_PATROL)

	if _p_target_lbl:
		if multi.size() > 1:
			_p_target_lbl.text = "→ %d Targets" % multi.size()
		elif locked and is_instance_valid(locked):
			_p_target_lbl.text = "→ %s" % locked.name
		else:
			_p_target_lbl.text = "→ —"

	if _p_hull_bar: _p_hull_bar.value = sc.get_hull_integrity()
	if _p_shld_bar:
		var ss := sc.shield_system
		_p_shld_bar.value = ss.get_integrity() if ss else 0.0

	# Vier-Zonen-Anzeige aktualisieren (no-op wenn show_shield_zones=false)
	_update_zone_cells(_p_zone_cells, sc)


# ─────────────────────────────────────────────────────────────────────────────
# TARGET LISTE
# ─────────────────────────────────────────────────────────────────────────────

func _setup_target_list() -> void:
	if not target_widget_anchor:
		return
	# VBoxContainer als Halter für alle Target-Widgets
	_target_list_container = VBoxContainer.new()
	_target_list_container.add_theme_constant_override("separation", 4)
	target_widget_anchor.add_child(_target_list_container)


func _refresh_target_list() -> void:
	if not _target_list_container:
		return

	var ts := _ship_controller.targeting_system if _ship_controller else null
	if not ts or not is_instance_valid(ts):
		_clear_target_widgets()
		return

	# Aktuelle Target-Liste bestimmen:
	# Priorität: multi_locked_targets wenn > 1, sonst locked_target als Einzelelement
	var targets: Array[Node3D] = []
	if ts.multi_locked_targets.size() > 0:
		for t: Node3D in ts.multi_locked_targets:
			if is_instance_valid(t):
				targets.append(t)
	elif ts.locked_target and is_instance_valid(ts.locked_target):
		targets.append(ts.locked_target)

	# Liste geändert? → neu aufbauen
	if _targets_changed(targets):
		_clear_target_widgets()
		_last_targets = targets.duplicate()
		var primary: Node3D = ts.locked_target

		for i: int in targets.size():
			var target := targets[i]
			var is_primary: bool = (target == primary)
			var bg: Color = COL_BG_TGT if is_primary else COL_BG_MULTI
			_build_target_widget(target, is_primary, bg)
	else:
		# Nur Werte aktualisieren (keine Neu-Erstellung)
		_update_target_values(targets, ts.locked_target)


func _targets_changed(current: Array[Node3D]) -> bool:
	if current.size() != _last_targets.size():
		return true
	for i: int in current.size():
		if current[i] != _last_targets[i]:
			return true
	return false


func _clear_target_widgets() -> void:
	if not _target_list_container:
		return
	for child in _target_list_container.get_children():
		child.queue_free()


func _build_target_widget(target: Node3D, is_primary: bool, bg: Color) -> void:
	var wrapper := MarginContainer.new()
	wrapper.set_meta("target_node", target)
	_target_list_container.add_child(wrapper)

	var refs := _build_ship_widget(wrapper, bg)
	# Refs als Metadaten speichern → _update_target_values kann sie direkt abrufen
	wrapper.set_meta("name_lbl",    refs[0])
	wrapper.set_meta("faction_lbl", refs[1])
	wrapper.set_meta("speed_lbl",   refs[2])
	wrapper.set_meta("state_lbl",   refs[3])
	wrapper.set_meta("extra_lbl",   refs[4])
	wrapper.set_meta("hull_bar",    refs[5])
	wrapper.set_meta("shld_bar",    refs[6])
	wrapper.set_meta("zone_cells",  refs[7] if refs.size() >= 8 else [])

	var name_lbl: Label = refs[0]
	if is_primary and name_lbl:
		name_lbl.add_theme_color_override("font_color", COL_LOCKED)

	_fill_target_widget(target, is_primary, refs[0], refs[1],
		refs[2], refs[3], refs[4], refs[5], refs[6], refs[7] if refs.size() >= 8 else [])


func _update_target_values(targets: Array[Node3D], primary: Node3D) -> void:
	if not _target_list_container:
		return
	var children := _target_list_container.get_children()
	for i: int in min(children.size(), targets.size()):
		var wrapper    := children[i]
		var target     := targets[i]
		var is_primary := (target == primary)

		# Refs direkt aus Metadaten holen – kein fragiles Index-Navigieren
		var name_lbl:    Label       = wrapper.get_meta("name_lbl")    if wrapper.has_meta("name_lbl")    else null
		var faction_lbl: Label       = wrapper.get_meta("faction_lbl") if wrapper.has_meta("faction_lbl") else null
		var speed_lbl:   Label       = wrapper.get_meta("speed_lbl")   if wrapper.has_meta("speed_lbl")   else null
		var state_lbl:   Label       = wrapper.get_meta("state_lbl")   if wrapper.has_meta("state_lbl")   else null
		var extra_lbl:   Label       = wrapper.get_meta("extra_lbl")   if wrapper.has_meta("extra_lbl")   else null
		var hull_bar:    ProgressBar = wrapper.get_meta("hull_bar")    if wrapper.has_meta("hull_bar")    else null
		var shld_bar:    ProgressBar = wrapper.get_meta("shld_bar")    if wrapper.has_meta("shld_bar")    else null
		var zone_cells:  Array       = wrapper.get_meta("zone_cells")  if wrapper.has_meta("zone_cells")  else []

		if name_lbl:
			name_lbl.add_theme_color_override("font_color",
				COL_LOCKED if is_primary else Color.WHITE)

		_fill_target_widget(target, is_primary, name_lbl, faction_lbl,
			speed_lbl, state_lbl, extra_lbl, hull_bar, shld_bar, zone_cells)


func _fill_target_widget(target: Node3D, is_primary: bool,
		name_lbl: Label, faction_lbl: Label, speed_lbl: Label,
		state_lbl: Label, extra_lbl: Label,
		hull_bar: ProgressBar, shld_bar: ProgressBar,
		zone_cells: Array = []) -> void:

	# ShipController finden
	var tsc: ShipController = null
	for child in target.find_children("*", "ShipController", true, false):
		if child is ShipController:
			tsc = child
			break
	if not tsc:
		return

	if name_lbl:
		name_lbl.text = tsc.ship_name if tsc.ship_name else target.name

	if faction_lbl and tsc.ship_data:
		faction_lbl.text = "[%s]" % ShipData.Faction.keys()[tsc.ship_data.faction]

	if speed_lbl:
		var mc := tsc.movement_comp
		speed_lbl.text = "⚡ %.0f u/s" % absf(mc.current_speed) if mc else "⚡ —"

	# AIController State
	if state_lbl:
		var ai: AIController = null
		var p := target
		while p:
			if p is AIController: ai = p as AIController; break
			p = p.get_parent()
		if ai:
			var st: String = AIController.State.keys()[ai._state] as String
			state_lbl.text = "● %s" % st
			state_lbl.add_theme_color_override("font_color",
				COL_COMBAT if st == "COMBAT" else COL_PATROL)
		else:
			state_lbl.text = ""

	if extra_lbl:
		extra_lbl.text = "★ PRIMARY" if is_primary else ""
		extra_lbl.add_theme_color_override("font_color", COL_LOCKED)

	if hull_bar: hull_bar.value = tsc.get_hull_integrity()
	if shld_bar:
		var ss := tsc.shield_system
		shld_bar.value = ss.get_integrity() if ss else 0.0

	# Vier-Zonen-Anzeige des Targets (no-op wenn zone_cells leer)
	_update_zone_cells(zone_cells, tsc)


# ─────────────────────────────────────────────────────────────────────────────
# HELPER
# ─────────────────────────────────────────────────────────────────────────────

func _find_ship_controller() -> void:
	if player_path.is_empty(): return
	var player := get_node_or_null(player_path)
	if not player: return
	for child in player.find_children("*", "ShipController", true, false):
		if child is ShipController:
			_ship_controller = child
			return


func _make_stylebox(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left     = 5
	sb.corner_radius_top_right    = 5
	sb.corner_radius_bottom_left  = 5
	sb.corner_radius_bottom_right = 5
	sb.content_margin_left   = 8.0
	sb.content_margin_right  = 8.0
	sb.content_margin_top    = 6.0
	sb.content_margin_bottom = 6.0
	return sb
