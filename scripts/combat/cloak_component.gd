# res://scripts/combat/cloak_component.gd
#
# Cloaking-System als ShipController-Subsystem. Analog zu ShieldSystem aufgebaut.
#
# DESIGN: Reine Alpha-Transparenz als visuelle Tarnung. Keine Shader, keine
# Refraktion, keine Faction-Farben, keine Vertex-Displacements. Das Schiff
# verschwindet einfach durch sukzessive Reduktion der Material-Albedo-Alpha.
#
# LEBENSZYKLUS:
#   IDLE → CLOAKING (fade-in) → CLOAKED → DECLOAKING (fade-out) → IDLE
#                                ↓ break_cloak()
#                                EMERGENCY_DECLOAK → COOLDOWN → IDLE
#
# WAFFEN/SCHILDE:
#   - CLOAKING startet:    weapons_offline + shields_offline + immer noch Mesh sichtbar
#   - CLOAKED:             alles aus, Mesh transparent (oder voll unsichtbar bei NPC)
#   - DECLOAKING startet:  Mesh wird wieder sichtbar
#   - DECLOAKING fertig:   weapons_online + shields_online (mit recharge_delay)
#
# SICHTBARKEIT:
#   Externe Systeme (TargetingSystem, AIController, etc.) fragen die Sichtbarkeit
#   NICHT direkt am Component ab, sondern über ShipController.is_visible_to(observer).
#   Der ShipController delegiert dann an den CloakComponent — das hält die API
#   einheitlich auch für Schiffe ohne Cloak.
#
# PLAYER-AUTO-DETECT:
#   Schiffe in der "player"-Group bekommen automatisch _PLAYER_MIN_ALPHA = 0.15
#   (immer leicht sichtbar). Sonst sieht der Spieler nicht mehr was er steuert.
#   NPC-Schiffe nutzen den Inspector-Wert (typischerweise 0.0 = voll unsichtbar).
#
# MATERIAL-ISOLATION (kritisch!):
#   Zwei Schiffe vom selben Typ teilen sich per Default die gleiche Material-
#   Resource (auch surface_override_material!). Cloakt eines, würde das andere
#   mitfaden. Wir duplizieren daher IMMER (egal ob schon ein Override existiert)
#   und IMMER mit duplicate(true) (Deep-Copy inkl. Texturen).
#
#   Zusätzlich: VOR dem Duplizieren snapshotten wir die Original-Albedo-Farben
#   aus den geteilten Base-Materials. Damit überleben wir auch den Fall, dass
#   duplicate(true) bestimmte Sub-Resources nicht 1:1 mitschleppt.

class_name CloakComponent
extends Node

# ─────────────────────────────────────────────────────────────────────────────
# CONST
# ─────────────────────────────────────────────────────────────────────────────

## Im Player-Modus erzwungener Min-Alpha (überschreibt Inspector).
## Player-Schiffe MÜSSEN sichtbar bleiben (auch wenn nur leicht), sonst sieht
## der Spieler nicht mehr was er steuert. NPC-Modus darf voll unsichtbar werden.
const _PLAYER_MIN_ALPHA: float = 0.15

## Gruppen-Name für Player-Erkennung (muss zu FactionSystem.GROUP_PLAYER passen).
const _PLAYER_GROUP: String = "player"

# ─────────────────────────────────────────────────────────────────────────────
# SIGNALS
# ─────────────────────────────────────────────────────────────────────────────

## Tarnung beginnt (Fade-In hat gestartet)
signal cloaking_started

## Tarnung vollständig aktiv (Fade abgeschlossen, voll unsichtbar)
signal cloaked

## Enttarnung beginnt (Fade-Out hat gestartet)
signal decloaking_started

## Enttarnung abgeschlossen (Mesh voll sichtbar, Waffen+Schilde wieder online)
signal decloaked

## Tarnung wurde erzwungen unterbrochen (Waffen-Feuer, externe Quelle)
signal cloak_broken(reason: String)

# ─────────────────────────────────────────────────────────────────────────────
# STATES
# ─────────────────────────────────────────────────────────────────────────────

enum State {
	IDLE,           ## Sichtbar, alles normal
	CLOAKING,       ## Fade-In läuft
	CLOAKED,        ## Voll getarnt
	DECLOAKING,     ## Fade-Out läuft
	COOLDOWN        ## Nach erzwungener Enttarnung, kann nicht erneut tarnen
}

var _state: State = State.IDLE

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS — direkt im Inspector pro Schiff konfigurierbar
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Cloak – Configuration")
## Die zentrale Konfiguration für dieses Schiff
@export var cloak_data: CloakData

@export_group("Cloak – Meshes")
## Wurzel-Node unter dem ALLE MeshInstance3D rekursiv gesammelt werden.
## Typischerweise der "Model"-Node des Schiffs (direktes Kind des Ship-Roots).
## Leer lassen → automatische Suche ab _ship_root (funktioniert immer als Fallback).
## Vorteil gegenüber target_meshes: neue Meshes im Model werden automatisch erfasst,
## ohne den Inspector anpassen zu müssen.
@export var mesh_root: Node3D = null

## Meshes die NICHT getarnt werden sollen (z.B. ShieldMesh ist bereits hartcodiert
## ausgeschlossen, aber hier können weitere Ausnahmen definiert werden).
## Leer lassen = nur ShieldMesh wird ausgeschlossen.
@export var exclude_meshes: Array[MeshInstance3D] = []

## [DEPRECATED] Wird ignoriert wenn mesh_root gesetzt ist.
## Nur noch vorhanden für Rückwärtskompatibilität mit alten Szenen.
@export var target_meshes: Array[MeshInstance3D] = []

## Minimaler Alpha-Wert wenn das Schiff voll getarnt ist.
## 0.0 = komplett unsichtbar, 0.15 = leicht sichtbar (empfohlen für Player),
## 0.05 = kaum sichtbar (empfohlen für NPC).
## Dieser Wert ist die "Untergrenze" des Fade — das Schiff wird nie transparenter.
##
## ⚠ BEI PLAYER-SCHIFFEN ÜBERSCHRIEBEN: Schiffe in der "player"-Group bekommen
## automatisch _PLAYER_MIN_ALPHA (0.15), egal was hier steht.
@export_range(0.0, 1.0, 0.01) var cloaked_min_alpha: float = 0.0

@export_group("Cloak – Audio")
## Alle Tarnung-Sounds als Resource – z.B. res://resources/audio/cloak/audio_cloak_romulan.tres
@export var audio_data: CloakAudioData = null

@export_group("Debug")
## Debug-Logs aktivieren (wird auch vom ShipController propagiert).
@export var show_debug: bool = false

# ─────────────────────────────────────────────────────────────────────────────
# INTERNE VARIABLEN
# ─────────────────────────────────────────────────────────────────────────────

var _ship_controller: Node = null
var _ship_root: Node3D     = null
var _cloak_alpha: float    = 1.0
var _cooldown_timer: float = 0.0
var _active_tween: Tween   = null
var is_active: bool
var _cloak_visibility_to_player: float = 1.0
var _faction_check_done: bool = false

## Wird in _ready() einmal anhand der "player"-Group ermittelt und cached.
var _is_player_ship: bool = false

## Effektiver Min-Alpha (entweder aus Inspector oder Player-Override).
## Wird in _ready() initialisiert und NUR dieser Wert wird zur Laufzeit benutzt.
var _effective_min_alpha: float = 0.0

## Per-Instanz duplizierte Materials für Alpha-Fade.
## Garantiert isoliert: ein Cloak betrifft nie andere Schiffe.
var _cached_materials: Array[Material] = []
## Original-Albedo-Farben (Snapshot VOR der Duplizierung gesichert).
## Reihenfolge entspricht 1:1 _cached_materials.
var _original_colors:  Array[Color]    = []
var _materials_initialized: bool = false

## Basis-Materialien (dupliziert) mit Mesh-Referenz für Alpha-Steuerung.
## Jeder Eintrag: { "mesh": MeshInstance3D, "surface": int, "mat": Material, "type": String }
## type = "standard" → albedo_color.a steuern
## type = "shader"   → MeshInstance3D.transparency steuern (per-Instance-Property)
var _base_material_entries: Array = []


# ─────────────────────────────────────────────────────────────────────────────
# LIFECYCLE
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	# CloakComponent → ShipController → Root (AIController / Player / CharacterBody3D)
	_ship_controller = get_parent()
	_ship_root       = _ship_controller.get_parent() as Node3D if _ship_controller else null

	if not _ship_controller is Node3D:
		push_warning("[CloakComponent] Parent '%s' ist kein Node3D / ShipController!" \
			% (_ship_controller.name if _ship_controller else "null"))

	if not _ship_root:
		push_warning("[CloakComponent] Kein Root-Node gefunden – Meshes können nicht gesucht werden!")

	# Player-Auto-Detect: einmalig in _ready() — die Group-Mitgliedschaft ändert
	# sich während des Spiels normalerweise nicht (Player-Schiff bleibt Player).
	_resolve_player_mode()
	_update_cloak_visibility_to_player()

	_dbg("✅ CloakComponent bereit | root='%s' | sc='%s' | mode=%s | min_alpha=%.2f | detection_range=%.0fm | fade_in=%.1fs" % [
		_ship_root.name if _ship_root else "NULL",
		_ship_controller.name if _ship_controller else "NULL",
		"PLAYER" if _is_player_ship else "NPC",
		_effective_min_alpha,
		cloak_data.detection_range, cloak_data.fade_in_duration
	])

	# Shader-Warmup: Cloak-Shader einmalig in _ready() laden damit der erste
	# Cloak-Aufruf keinen Compile-Stutter verursacht. Godot cached den Shader
	# nach dem ersten load() — alle weiteren Aufrufe sind instantan.
	# Kein set_shader_parameter nötig — nur das Laden reicht für den Pre-Compile.
	var _warmup_shader: Shader = load("res://shaders/cloak.gdshader")
	if not _warmup_shader:
		push_warning("[CloakComponent] Warmup: cloak.gdshader nicht gefunden!")


## Prüft ob das Schiff zum Spieler gehört und setzt den effektiven Min-Alpha.
##
## Player-Schiffe (in der "player"-Group):
##   _effective_min_alpha = 0.15  (immer leicht sichtbar)
## NPC-Schiffe:
##   Wert aus Inspector wird 1:1 übernommen.
func _resolve_player_mode() -> void:
	_is_player_ship = false

	# Hierarchie hoch laufen: CloakComponent → ShipController → Root → ...
	var node: Node = self
	while is_instance_valid(node):
		if node.is_in_group(_PLAYER_GROUP):
			_is_player_ship = true
			break
		node = node.get_parent()

	if _is_player_ship:
		_effective_min_alpha = _PLAYER_MIN_ALPHA
		# Logs zeigen prominent dass Inspector-Wert überschrieben wurde
		if cloaked_min_alpha != _PLAYER_MIN_ALPHA:
			_dbg("🎮 Player-Modus: Inspector-Wert überschrieben (min_alpha=%.2f→%.2f)" % [
				cloaked_min_alpha, _PLAYER_MIN_ALPHA
			])
	else:
		_effective_min_alpha = cloaked_min_alpha


func _process(delta: float) -> void:
	if _state == State.COOLDOWN:
		_cooldown_timer -= delta
		if _cooldown_timer <= 0.0:
			_state = State.IDLE
			_dbg("✅ Cooldown beendet, kann erneut tarnen")
		return


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────

## Toggle für Player-Input und externe Trigger.
## Returns: true wenn der Toggle akzeptiert wurde, false wenn ignoriert.
func toggle_cloak() -> bool:
	if not is_active:
		_dbg("⚠ toggle_cloak abgelehnt: Component nicht aktiviert (can_cloak=false und kein Player-Bypass)")
		return false

	match _state:
		State.IDLE:
			return _begin_cloak()
		State.CLOAKED:
			return _begin_decloak()
		_:
			# CLOAKING, DECLOAKING, COOLDOWN → ignorieren
			_dbg("⚠ toggle_cloak ignoriert (State: %s)" % State.keys()[_state])
			return false


## Erzwungene Enttarnung von außen — z.B. wenn der ShipController feuert
## während getarnt. Springt sofort in DECLOAKING und triggered Cooldown.
func break_cloak(reason: String = "external") -> void:
	# Sicherheitscheck: Wenn die Komponente deaktiviert ist, ignorieren
	if not is_active:
		_dbg("⚠ break_cloak abgelehnt: Component nicht aktiviert")
		return

	# Nur abbrechen, wenn das Schiff gerade getarnt ist oder sich im Prozess befindet
	if _state != State.CLOAKED and _state != State.CLOAKING:
		return

	_dbg("💥 Cloak gebrochen: %s" % reason)
	
	# Signal an andere Systeme senden (z.B. für UI-Effekte oder Sound)
	cloak_broken.emit(reason)
	
	# Not-Enttarnung einleiten (true setzt den Cooldown aktiv)
	_begin_decloak(true)  # emergency = true → Cooldown nach Decloak


## true wenn das Schiff aktuell für andere unsichtbar ist (komplett oder
## teilweise). Wird von ShipController.is_visible_to() konsultiert.
func is_cloaked() -> bool:
	return _state == State.CLOAKED


## true wenn das Schiff gerade im Übergang ist (Cloak nicht voll, aber
## auch nicht voll sichtbar). Im Übergang sollte Targeting/AI das Schiff
## noch normal behandeln, weil es theoretisch noch zu sehen ist.
func is_transitioning() -> bool:
	return _state == State.CLOAKING or _state == State.DECLOAKING


## Sichtbarkeit für einen bestimmten Beobachter (0.0 = unsichtbar, 1.0 = voll
## sichtbar). Berücksichtigt Detection-Range bei aktivem Cloak.
##
## Diese Funktion ist die Wahrheits-Quelle für externe Visibility-Checks
## (TargetingSystem, AIController). ShipController.is_visible_to(observer)
## delegiert hierhin.

func visibility_to(observer: Node3D) -> float:
	if _state == State.IDLE:
		return 1.0

	if _state == State.CLOAKING or _state == State.DECLOAKING:
		return _cloak_alpha

	if _state == State.COOLDOWN:
		return 1.0

	if not is_instance_valid(observer):
		return 0.0
	if not _ship_root:
		return 0.0

	var same_faction: bool = false
	if Engine.has_singleton("FactionSystem"):
		var my_faction: int = FactionSystem.get_faction_of(_ship_root)
		var obs_faction: int = FactionSystem.get_faction_of(observer)
		same_faction = (my_faction >= 0 and my_faction == obs_faction)

	if same_faction:
		var ally_vis: float = cloak_data.ally_visibility if cloak_data else 0.35
		return ally_vis

	# Feinde und Neutrale sehen nichts.
	return 0.0


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – State-Übergänge
# ─────────────────────────────────────────────────────────────────────────────

func _begin_cloak() -> bool:
	if not _ship_controller:
		return false

	_dbg("🌀 CLOAKING gestartet (fade=%.1fs, mode=%s)" % [
		cloak_data.fade_in_duration,
		"PLAYER" if _is_player_ship else "NPC"
	])
	_state = State.CLOAKING
	cloaking_started.emit()

	if audio_data:
		_play_sound(audio_data.sound_cloak, audio_data.cloak_volume_offset_db)

	# Schilde und Waffen offline schalten
	_set_weapons_locked(true)
	_set_shields_offline(true)

	# cloak_progress → 1.0 = voll getarnt. Rim-Sichtbarkeit für Player/Verbündete
	# regelt der Shader selbst über rim_intensity (kein Alpha-Limit mehr nötig).
	_update_cloak_visibility_to_player()
	_fade_to(1.0, cloak_data.fade_in_duration, _on_cloak_complete)
	_dbg("  → cloak_progress Ziel: 1.0")
	return true


func _begin_decloak(emergency: bool = false) -> bool:
	if not _ship_controller:
		return false

	var duration: float = cloak_data.fade_out_duration
	if emergency:
		duration = 0.3   # Schneller Blitz beim erzwungenen Enttarnen

	_dbg("🌀 DECLOAKING gestartet (fade=%.2fs, emergency=%s)" % [duration, emergency])
	_state = State.DECLOAKING
	decloaking_started.emit()

	if audio_data:
		_play_sound(audio_data.sound_decloak, audio_data.cloak_volume_offset_db)

	# cloak_progress → 0.0 = voll sichtbar
	_fade_to(0.0, duration, _on_decloak_complete.bind(emergency))
	return true


func _on_cloak_complete() -> void:
	_state = State.CLOAKED
	_set_collision_active(false)
	
	_update_cloak_visibility_to_player(true)  # force check
	_apply_cloak_progress(1.0)                # force final shader update
	
	_dbg("✅ CLOAKED")
	cloaked.emit()


func _on_decloak_complete(emergency: bool) -> void:
	_set_collision_active(true)
	_set_shields_offline(false)
	_set_weapons_locked(false)

	# Materials aufräumen: next_pass entfernen, Alpha/transparency zurücksetzen
	_cleanup_materials()

	if emergency:
		_state = State.COOLDOWN
		_cooldown_timer = cloak_data.emergency_cooldown
		_dbg("⏰ COOLDOWN aktiv (%.1fs)" % _cooldown_timer)
	else:
		_state = State.IDLE
		_dbg("✅ DECLOAKED (voll sichtbar)")

	decloaked.emit()

## Updates the visibility this ship should have for the player.
## Called in _ready() and when cloak completes.
func _update_cloak_visibility_to_player(force: bool = false) -> void:
	if _is_player_ship:
		_cloak_visibility_to_player = 1.0
		return

	if not _ship_root:
		_cloak_visibility_to_player = 1.0
		return

	# Direct Autoload access (no Engine.has_singleton)
	if not FactionSystem:
		_cloak_visibility_to_player = 1.0
		_dbg("⚠ FactionSystem autoload not found")
		return

	var my_faction: int = FactionSystem.get_faction_of(_ship_root)
	
	# NEW: Correct way to get player faction
	var player_faction: int = -1
	var player_node = get_tree().get_first_node_in_group("player")
	if player_node:
		player_faction = FactionSystem.get_faction_of(player_node)

	if my_faction < 0 or player_faction < 0:
		_cloak_visibility_to_player = 1.0
		return

	if FactionSystem.is_faction_pair_hostile(my_faction, player_faction):
		_cloak_visibility_to_player = 0.0
		_dbg("🛡️ HOSTILE ship detected (faction %d vs player %d) → cloak_visibility = 0.0" % [my_faction, player_faction])
	else:
		_cloak_visibility_to_player = 1.0
		_dbg("👥 Ally/Neutral → cloak_visibility = 1.0")

## Räumt alle Cloak-Effekte an den Materialien auf:
##   1. next_pass (Rim-Glow-Shader) vom Basis-Material entfernen
##   2. StandardMaterial3D: albedo_color.a und transparency-Mode wiederherstellen
##   3. ShaderMaterial: mesh.transparency auf Original zurücksetzen
##   4. Interne Listen leeren + _materials_initialized zurücksetzen
func _cleanup_materials() -> void:
	# Basis-Materialien wiederherstellen
	for entry in _base_material_entries:
		var mesh: MeshInstance3D = entry.get("mesh")
		if not is_instance_valid(mesh):
			continue
		var mat: Material = entry.get("mat")
		match entry.get("type", ""):
			"standard":
				var sm3d := mat as StandardMaterial3D
				if sm3d:
					# Albedo-Alpha zurücksetzen
					var orig_a: float = sm3d.get_meta("_cloak_orig_albedo_a", 1.0)
					var col: Color = sm3d.albedo_color
					col.a = orig_a
					sm3d.albedo_color = col
					sm3d.remove_meta("_cloak_orig_albedo_a")
					# Transparency-Mode zurücksetzen
					if sm3d.has_meta("_cloak_orig_transparency"):
						sm3d.transparency = sm3d.get_meta("_cloak_orig_transparency") as int
						sm3d.remove_meta("_cloak_orig_transparency")
					# next_pass entfernen
					sm3d.next_pass = null
			"shader":
				# mesh.transparency zurücksetzen
				var surface_idx: int = entry.get("surface", 0)
				var meta_key: String = "_cloak_orig_mesh_transparency_%d" % surface_idx
				if mesh.has_meta(meta_key):
					mesh.transparency = mesh.get_meta(meta_key) as float
					mesh.remove_meta(meta_key)
				else:
					mesh.transparency = 0.0
				# next_pass am Material entfernen
				if mat:
					mat.next_pass = null

	_base_material_entries.clear()
	_cached_materials.clear()
	_materials_initialized = false
	_dbg("🧹 Materials bereinigt (next_pass entfernt, alpha/transparency wiederhergestellt)")


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Mesh-Fade
# ─────────────────────────────────────────────────────────────────────────────

## Snapshot der Original-Albedo-Farben aus den (noch geteilten) Base-Materials.
## Wird in _ready() aufgerufen, BEVOR irgendein duplicate() oder Override passiert.
##
## WARUM: Wenn beim Duplizieren der Materials später irgendeine Sub-Resource
## verloren geht (selten, aber möglich bei komplexen Material-Setups), haben
## wir hier die echte Originalfarbe gesichert. Beim Decloak schreiben wir
## diese zurück → Schiff erscheint garantiert in der Originalfarbe.
##
## Reihenfolge: gleiche Iterationsreihenfolge wie _initialize_materials() —
## damit color_idx später 1:1 passt.
func _snapshot_original_colors() -> void:
	_original_colors.clear()

	# _collect_meshes() liefert bereits gefilterte Liste (ShieldMesh + exclude_meshes raus)
	var mesh_instances: Array[MeshInstance3D] = _collect_meshes()

	for mesh in mesh_instances:
		var surface_count: int = mesh.mesh.get_surface_count() if mesh.mesh else 0
		for i in range(surface_count):
			var base_mat: Material = mesh.mesh.surface_get_material(i)
			# Falls schon ein Override existiert, nutzen wir DESSEN Farbe als
			# "original" — z.B. wenn das Schiff im Editor bereits eine eigene
			# Albedo gesetzt bekommen hat.
			var override_mat: Material = mesh.get_surface_override_material(i)
			var source_mat: Material = override_mat if override_mat else base_mat
			if not source_mat:
				continue
			if source_mat is StandardMaterial3D:
				_original_colors.append((source_mat as StandardMaterial3D).albedo_color)
			elif source_mat is ShaderMaterial:
				# ShaderMaterial hat keine albedo_color — Color.WHITE als Platzhalter.
				# _apply_alpha_to_materials erkennt ShaderMaterial und nutzt
				# cloak_alpha statt albedo_color, der Platzhalter wird nie genutzt.
				_original_colors.append(Color.WHITE)
			else:
				# Unbekannter Typ — Platzhalter damit color_idx synchron bleibt.
				_original_colors.append(Color.WHITE)

	_dbg("📷 Originalfarben gesichert: %d Einträge" % _original_colors.size())


## Hängt den Cloak-Shader als next_pass ans Ende der Material-Chain jeder Surface.
## Wird LAZY beim ersten Cloak-Versuch aufgerufen.
##
## WARUM next_pass statt Override:
##   Alle Schiffe haben bereits einen damage_shader als surface_override_material.
##   Ein zweiter Override würde diesen ersetzen. next_pass legt sich additiv
##   ÜBER den bestehenden Pass — beide Shader laufen parallel.
##
## MATERIALIEN werden NICHT mehr dupliziert: der Cloak-Shader-Pass ist per
## Instanz neu erstellt (ShaderMaterial.new()) → keine Isolation-Probleme,
## kein transparency-Toggle nötig, kein Decloak-Sprung.
func _initialize_materials() -> void:
	if _materials_initialized:
		_dbg_setup("_initialize_materials: bereits initialisiert → skip")
		return

	_dbg_setup("══ _initialize_materials START ══")
	_dbg_setup("  _ship_root  : %s" % (_ship_root.name if _ship_root else "NULL"))
	_dbg_setup("  mesh_root   : %s" % (mesh_root.name if is_instance_valid(mesh_root) else "nicht gesetzt"))
	_dbg_setup("  target_meshes: %d Einträge" % target_meshes.size())

	var mesh_instances: Array[MeshInstance3D] = _collect_meshes()
	if mesh_instances.is_empty():
		_dbg_setup("⚠ _collect_meshes() lieferte 0 Meshes → ABBRUCH")
		_dbg_setup("  Mögliche Ursachen:")
		_dbg_setup("  1. mesh_root nicht gesetzt UND target_meshes leer")
		_dbg_setup("  2. target_meshes enthält ungültige Nodes")
		_dbg_setup("  3. Alle gefundenen Meshes wurden durch exclude_meshes gefiltert")
		return

	_dbg_setup("  %d MeshInstance3D(s) gefunden:" % mesh_instances.size())
	for m in mesh_instances:
		_dbg_setup("    • '%s' | surfaces=%d | visible=%s" % [
			m.name,
			m.mesh.get_surface_count() if m.mesh else 0,
			m.visible
		])

	# Fraktionsfarbe + Displacement aus FactionSystem holen.
	var faction_visuals: Dictionary = {}
	if _ship_root and Engine.has_singleton("FactionSystem"):
		var faction: int = FactionSystem.get_faction_of(_ship_root)
		faction_visuals = FactionSystem.get_cloak_visuals(faction)
		_dbg_setup("  Fraktion: %d | visuals: %s" % [faction, faction_visuals])
	else:
		_dbg_setup("  ⚠ FactionSystem nicht erreichbar → Default-Visuals")

	var rim_col:  Color = Color(0.4, 0.75, 1.0)
	var disp_str: float = 0.04

	if not faction_visuals.is_empty():
		rim_col  = faction_visuals.get("rim_color",             rim_col)
		disp_str = faction_visuals.get("displacement_strength", disp_str)

	# CloakData-Override hat höchste Priorität
	if cloak_data:
		if cloak_data.rim_color_override.a > 0.01:
			_dbg_setup("  CloakData rim_color_override aktiv: %s" % cloak_data.rim_color_override)
			rim_col = cloak_data.rim_color_override
		if cloak_data.displacement_strength_override >= 0.0:
			_dbg_setup("  CloakData displacement_override aktiv: %.3f" % cloak_data.displacement_strength_override)
			disp_str = cloak_data.displacement_strength_override

	_dbg_setup("  Finale Visuals | rim=%s | displacement=%.3f" % [rim_col, disp_str])

	var cloak_shader: Shader = load("res://shaders/cloak.gdshader") as Shader
	if not cloak_shader:
		_dbg_setup("⚠ FEHLER: cloak.gdshader nicht gefunden!")
		_dbg_setup("  Erwartet unter: res://shaders/cloak.gdshader")
		_dbg_setup("  Vorhandene Pfade prüfen: FileSystem-Dock → shaders/")
		return
	_dbg_setup("  cloak.gdshader geladen ✅")

	var surface_count_total: int = 0

	for mesh in mesh_instances:
		if not mesh.mesh:
			_dbg_setup("  '%s': mesh=NULL → skip" % mesh.name)
			continue
		var surface_count: int = mesh.mesh.get_surface_count()
		_dbg_setup("  Mesh '%s': %d Surface(s)" % [mesh.name, surface_count])

		for i in range(surface_count):
			# ── SCHRITT 1: Top-Material ermitteln ──────────────────────────────
			var existing_override: Material = mesh.get_surface_override_material(i)
			var base_mat:          Material = mesh.mesh.surface_get_material(i)
			var source_mat:        Material = existing_override if existing_override else base_mat

			_dbg_setup("    Surface %d:" % i)
			_dbg_setup("      override : %s" % (existing_override.get_class() if existing_override else "NULL"))
			_dbg_setup("      base_mat : %s" % (base_mat.get_class() if base_mat else "NULL"))
			_dbg_setup("      source   : %s" % (source_mat.get_class() if source_mat else "NULL"))

			if not source_mat:
				_dbg_setup("      → kein Material → skip")
				continue

			if source_mat is ShaderMaterial:
				var sm := source_mat as ShaderMaterial
				_dbg_setup("      shader   : %s" % (sm.shader.resource_path if sm.shader else "NULL"))

			# ── SCHRITT 2: IMMER duplizieren ────────────────────────────────────
			# KRITISCH: next_pass auf ein geteiltes Material setzen würde alle
			# Instanzen desselben Typs gleichzeitig beeinflussen.
			# duplicate(true) = Deep-Copy inkl. Texturen und Sub-Resources.
			var instance_mat: Material = source_mat.duplicate(true)
			mesh.set_surface_override_material(i, instance_mat)
			_dbg_setup("      duplicate(true) → neue Material-ID: %d" % instance_mat.get_instance_id())

			# ── SCHRITT 3: Basis-Material auf Transparent setzen + tracken ─────
			# StandardMaterial3D: albedo_color.a direkt animieren.
			# ShaderMaterial (damage_shader): MeshInstance3D.transparency nutzen —
			# das ist eine per-Instance-Property in Godot 4 die KEINEN Shader-
			# Rebuild verursacht und render_mode="opaque"-Shader transparent macht.
			if instance_mat is StandardMaterial3D:
				var sm3d := instance_mat as StandardMaterial3D
				# Original-Transparency-Mode + Original-Albedo-Alpha merken
				sm3d.set_meta("_cloak_orig_transparency", sm3d.transparency)
				sm3d.set_meta("_cloak_orig_albedo_a", sm3d.albedo_color.a)
				sm3d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				_base_material_entries.append({
					"mesh": mesh, "surface": i, "mat": sm3d, "type": "standard"
				})
				_dbg_setup("      StandardMaterial3D: transparency → ALPHA, albedo_a tracked")
			elif instance_mat is ShaderMaterial:
				# MeshInstance3D.transparency steuert den opaken damage_shader per-Instanz.
				# Original-Wert sichern (normalerweise 0.0 = voll opak).
				mesh.set_meta("_cloak_orig_mesh_transparency_%d" % i, mesh.transparency)
				_base_material_entries.append({
					"mesh": mesh, "surface": i, "mat": instance_mat, "type": "shader"
				})
				_dbg_setup("      ShaderMaterial: mesh.transparency per-Instance getrackt")

			# ── SCHRITT 4: Cloak-Pass (Rim-Glow) als next_pass ──────────────────
			# blend_add: additive Überlagerung → Rim leuchtet über dem (transparenten)
			# Basis-Material. Bei cloak_progress=0: ALPHA=0 → kein Overlay sichtbar.
			var cloak_mat := ShaderMaterial.new()
			cloak_mat.shader = cloak_shader
			cloak_mat.set_shader_parameter("cloak_progress",        0.0)
			cloak_mat.set_shader_parameter("rim_color",             rim_col)
			cloak_mat.set_shader_parameter("displacement_strength", disp_str)

			instance_mat.next_pass = cloak_mat
			_cached_materials.append(cloak_mat)
			surface_count_total += 1
			_dbg_setup("      → next_pass: cloak_shader eingehängt ✅")

	_materials_initialized = true
	_dbg_setup("══ _initialize_materials FERTIG ══")
	_dbg_setup("  Gesamt: %d Cloak-Material(s) in _cached_materials" % _cached_materials.size())

	if _cached_materials.is_empty():
		_dbg_setup("⚠ ACHTUNG: _cached_materials leer nach Init!")
		_dbg_setup("  → Cloak wird visuell KEINEN Effekt haben")


## Tween-basierter Fade: animiert cloak_progress 0→1 (Cloak) oder 1→0 (Decloak).
##
## Der Cloak-Shader empfängt cloak_progress als einzigen Steuer-Parameter.
## Kein transparency-Toggle am Basis-Material mehr → kein Decloak-Sprung.
## Kein albedo_color-Schreiben mehr → Originalfarbe bleibt immer erhalten.
func _fade_to(target_progress: float, duration: float, on_complete: Callable) -> void:
	_initialize_materials()

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()

	if _cached_materials.is_empty():
		_cloak_alpha = 1.0 - target_progress
		on_complete.call()
		return

	var start_progress: float = 1.0 - _cloak_alpha   # _cloak_alpha=1 → progress=0
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_active_tween.tween_method(
		func(progress: float) -> void:
			_apply_cloak_progress(progress),
		start_progress,
		target_progress,
		duration
	)
	_active_tween.tween_callback(func() -> void:
		_apply_cloak_progress(target_progress)
		_cloak_alpha = 1.0 - target_progress
		on_complete.call()
	)
	

## Setzt cloak_progress auf allen gecachten Cloak-Shader-Materials UND
## steuert den Alpha der Basis-Materialien für echte Transparenz.
## Wird pro Tween-Frame aufgerufen.
func _apply_cloak_progress(progress: float) -> void:
	_cloak_alpha = 1.0 - progress

	# Update visibility (especially important during transition)
	_update_cloak_visibility_to_player()

	for mat in _cached_materials:
		if mat is ShaderMaterial:
			var sm := mat as ShaderMaterial
			sm.set_shader_parameter("cloak_progress", progress)
			sm.set_shader_parameter("cloak_visibility", _cloak_visibility_to_player)

	# ── Basis Material Alpha (unchanged) ───────────────────────────────
	var target_alpha: float = lerp(1.0, _effective_min_alpha, progress)
	for entry in _base_material_entries:
		var mesh: MeshInstance3D = entry.get("mesh")
		if not is_instance_valid(mesh):
			continue
		match entry.get("type"):
			"standard":
				var sm3d := entry["mat"] as StandardMaterial3D
				if sm3d:
					var orig_a: float = sm3d.get_meta("_cloak_orig_albedo_a", 1.0)
					var col: Color = sm3d.albedo_color
					col.a = orig_a * target_alpha
					sm3d.albedo_color = col
			"shader":
				mesh.transparency = 1.0 - target_alpha
								
## Returns how visible this ship should be TO THE PLAYER (for the shader).
func _get_cloak_visibility_for_player() -> float:
	if _is_player_ship:
		return 1.0  # Player must always see their own ship

	if not Engine.has_singleton("FactionSystem") or not _ship_root:
		return 1.0

	var my_faction = FactionSystem.get_faction_of(_ship_root)
	var player_faction = FactionSystem.get_faction_of_player()  # Make sure this method exists

	# Hostile = completely invisible (no rim, no shimmer)
	if FactionSystem.is_hostile(my_faction, player_faction):
		return 0.0

	# Ally or neutral → show rim
	return 1.0


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Audio (nach dem Vorbild von WeaponMount)
# ─────────────────────────────────────────────────────────────────────────────

func _play_sound(stream: AudioStream, volume_offset_db: float = 0.0) -> void:
	if not stream:
		return

	var player := AudioStreamPlayer3D.new()
	player.stream = stream

	if is_instance_valid(_ship_root):
		player.global_position = _ship_root.global_position
	elif is_instance_valid(_ship_controller) and _ship_controller is Node3D:
		player.global_position = _ship_controller.global_position

	player.volume_db = volume_offset_db

	# ── Zoom/Distanz-Steuerung – Werte aus audio_data ─────────────────────
	var no_atten: bool  = audio_data.no_distance_attenuation       if audio_data else false
	var max_dist: float = audio_data.max_distance                 if audio_data else 800.0
	var atten_str: float = audio_data.distance_attenuation_strength if audio_data else 0.25
	var cutoff: float   = audio_data.attenuation_filter_cutoff_hz if audio_data else 12000.0
	var fade_time: float = audio_data.sound_fade_out_time         if audio_data else 0.8

	if no_atten:
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		player.max_distance = 2000.0
	else:
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.max_distance = max_dist
		player.unit_size = 1.0 / max(0.1, atten_str)

	player.attenuation_filter_cutoff_hz = cutoff

	add_child(player)
	player.play()

	# ── Phase A: Wartezeit bis Fade-Out beginnt ───────────────────────────
	# Sentinel 0.0 = "spiele den ganzen Sound" → stream.get_length() nutzen.
	# Achtung: get_length() liefert 0.0 wenn der Stream kein verlässliches
	# Längen-Reporting hat (z.B. manche generierte Streams).
	# In dem Fall fallen wir auf 2.0s zurück damit überhaupt etwas hörbar ist.
	var play_duration: float = audio_data.sound_play_duration if audio_data else 0.0

	if play_duration <= 0.0:
		play_duration = stream.get_length()
		if play_duration <= 0.0:
			play_duration = 2.0  # Notfall-Fallback bei unbekannter Länge

	# ── Phase B: Fade-Out + Cleanup ───────────────────────────────────────
	if fade_time > 0.0:
		# Tween wartet erst play_duration ab, DANN startet der Fade.
		# Während der Wartezeit bleibt volume_db = volume_offset_db (voll).
		var tween := create_tween()
		tween.tween_interval(play_duration)
		tween.tween_property(player, "volume_db", -80.0, fade_time) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tween.tween_callback(func():
			if is_instance_valid(player):
				player.queue_free()
		)
	else:
		# Kein Fade gewünscht → harter Stop nach play_duration
		var tween := create_tween()
		tween.tween_interval(play_duration)
		tween.tween_callback(func():
			if is_instance_valid(player):
				player.stop()
				player.queue_free()
		)

func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_all_mesh_instances(child))
	return result

func _debug_cloak_visibility() -> void:
	if not show_debug: return
	var vis = _get_cloak_visibility_for_player()
	print("[Cloak|%s] DEBUG Visibility to Player = %.3f | Faction=%s | is_player=%s" % [
		_ship_controller.name if _ship_controller else "?", 
		vis, 
		FactionSystem.get_faction_of(_ship_root) if Engine.has_singleton("FactionSystem") else "N/A",
		_is_player_ship
	])

# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Subsystem-Hooks
# ─────────────────────────────────────────────────────────────────────────────

## Schaltet Waffen-Mounts in den Cloak-Lock-State.
## Nutzt eine neue Methode set_cloak_locked() am WeaponMount, die die
## fire_at-Calls silent skippt.
func _set_weapons_locked(locked: bool) -> void:
	if not _ship_controller or not _ship_controller.has_method("set_weapons_cloak_locked"):
		return
	_ship_controller.set_weapons_cloak_locked(locked)
	_dbg("🔫 Waffen %s" % ("LOCKED" if locked else "ENTSPERRT"))


## Schaltet Schilde offline (kollabiert sie sanft) bzw. wieder online.
## Nutzt ShieldSystem über ShipController-API.
func _set_shields_offline(offline: bool) -> void:
	if not _ship_controller or not _ship_controller.has_method("set_shields_cloak_offline"):
		return
	_ship_controller.set_shields_cloak_offline(offline)
	_dbg("🛡️ Schilde %s" % ("OFFLINE" if offline else "ONLINE"))


## Schaltet die Hull-Collision aus, damit cloakede Schiffe nicht von
## Beam-Raycasts oder Torpedos getroffen werden.
##
## Hull-Collision liegt auf einem Child-Node (HullCollision/StaticBody3D),
## nicht am ShipController-Root. Daher müssen wir den Child finden.
func _set_collision_active(active: bool) -> void:
	# HullCollision liegt unter dem Root-Node, nicht unter ShipController
	var search_root: Node = _ship_root if _ship_root else _ship_controller
	if not search_root:
		return

	var hull: Node = search_root.find_child("HullCollision", true, false)
	if hull and hull is CollisionObject3D:
		var co: CollisionObject3D = hull
		co.set_collision_layer_value(1, active)
		_dbg("⚛️ HullCollision Layer-1 = %s" % active)


## Zentrale Mesh-Sammlung — wird von _snapshot_original_colors UND
## _initialize_materials genutzt. Einheitliche Iterationsreihenfolge ist
## KRITISCH damit color_idx in beiden Funktionen synchron bleibt.
##
## Priorität:
##   1. mesh_root gesetzt → alle MeshInstance3D rekursiv darunter
##   2. target_meshes gesetzt (legacy) → diese Liste direkt
##   3. Fallback → _ship_root rekursiv durchsuchen
##
## ShieldMesh und exclude_meshes werden immer herausgefiltert.
func _collect_meshes() -> Array[MeshInstance3D]:
	var candidates: Array[MeshInstance3D] = []

	_dbg_setup("  _collect_meshes:")
	_dbg_setup("    mesh_root     : %s (valid=%s)" % [
		mesh_root.name if is_instance_valid(mesh_root) else "—",
		is_instance_valid(mesh_root)
	])
	_dbg_setup("    target_meshes : %d Einträge" % target_meshes.size())
	for i in range(target_meshes.size()):
		var tm := target_meshes[i]
		_dbg_setup("      [%d] %s (%s) valid=%s" % [
			i,
			tm.name if is_instance_valid(tm) else "NULL",
			tm.get_class() if is_instance_valid(tm) else "—",
			is_instance_valid(tm)
		])

	if is_instance_valid(mesh_root):
		candidates = _find_all_mesh_instances(mesh_root)
		_dbg_setup("    → Pfad: mesh_root | %d Kandidaten" % candidates.size())
	elif target_meshes.size() > 0:
		for m in target_meshes:
			if not is_instance_valid(m):
				_dbg_setup("    ⚠ target_meshes-Eintrag ungültig → skip")
				continue
			if m is MeshInstance3D:
				candidates.append(m as MeshInstance3D)
				_dbg_setup("    → '%s' direkt als MeshInstance3D übernommen" % m.name)
			else:
				var found := _find_all_mesh_instances(m)
				_dbg_setup("    → '%s' ist %s → rekursiv gesucht → %d MeshInstance3D gefunden" % [
					m.name, m.get_class(), found.size()
				])
				for f in found:
					_dbg_setup("       • '%s'" % f.name)
				candidates.append_array(found)
		_dbg_setup("    → Pfad: target_meshes | %d Kandidaten gesamt" % candidates.size())
	elif _ship_root:
		candidates = _find_all_mesh_instances(_ship_root)
		_dbg_setup("    → Pfad: Fallback _ship_root | %d Kandidaten" % candidates.size())
	else:
		_dbg_setup("    ⚠ KEIN Suchpfad! mesh_root=NULL, target_meshes=leer, _ship_root=NULL")
		return []

	# Ausschluss-Filter
	var result: Array[MeshInstance3D] = []
	for m in candidates:
		if m.name == "ShieldMesh":
			_dbg_setup("    ⛔ '%s' → ShieldMesh-Filter" % m.name)
			continue
		if _is_excluded(m):
			_dbg_setup("    ⛔ '%s' → exclude_meshes-Filter" % m.name)
			continue
		result.append(m)

	_dbg_setup("    → Nach Filter: %d Mesh(es)" % result.size())
	return result


## Prüft ob ein Mesh in der exclude_meshes-Liste ist.
func _is_excluded(mesh: MeshInstance3D) -> bool:
	for excl in exclude_meshes:
		if is_instance_valid(excl) and excl == mesh:
			return true
	return false


## [COMPAT] Liefert dieselben Meshes wie _collect_meshes — wird von
## _set_original_meshes_visible genutzt.
func _get_target_meshes() -> Array[MeshInstance3D]:
	return _collect_meshes()


## Blendet Original-Meshes komplett aus/ein (für NPC-Modus mit min_alpha=0).
func _set_original_meshes_visible(visible: bool) -> void:
	for mesh in _get_target_meshes():
		mesh.visible = visible
	_dbg("👁 Meshes visible=%s" % visible)


## Allgemeines Cloak-Log (Events: Tarnen/Enttarnen/Zustandsänderungen).
## Aktiv wenn: show_debug=true ODER DebugManager-Flag "cloak.events"=true.
func _dbg(msg: String) -> void:
	if not show_debug:
		var dm: Node = get_tree().root.get_node_or_null("DebugManager")
		if not dm or not dm.has_method("get_flag"):
			return
		if not dm.get_flag("cloak.events"):
			return
	var ship_name: String = _ship_controller.name if _ship_controller else "?"
	print("[Cloak|%s] %s" % [ship_name, msg])


## Setup-spezifisches Cloak-Log (Material-Init, Mesh-Suche, Shader-Setup).
## Aktiv wenn: show_debug=true ODER DebugManager-Flag "cloak.setup"=true.
## Separat von _dbg damit man Material-Spam nicht immer zusammen mit Events sieht.
func _dbg_setup(msg: String) -> void:
	if not show_debug:
		var dm: Node = get_tree().root.get_node_or_null("DebugManager")
		if not dm or not dm.has_method("get_flag"):
			return
		if not dm.get_flag("cloak.setup"):
			return
	var ship_name: String = _ship_controller.name if _ship_controller else "?"
	print("[Cloak.Setup|%s] %s" % [ship_name, msg])
