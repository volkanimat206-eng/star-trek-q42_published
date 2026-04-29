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
## Die MeshInstance3D-Nodes die beim Cloaken transparent werden.
## Direkt im Inspector zuweisen — verhindert dass das falsche Mesh erwischt wird.
## Mehrere Meshes können zugewiesen werden (z.B. Hülle, Brücke, Triebwerke).
## Leer lassen = automatische Suche vom Root-Node (Fallback, weniger sicher).
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

	# WICHTIG: Originalfarben SOFORT in _ready() snapshotten — bevor irgendein
	# Code (auch von anderen Systemen) die geteilten Base-Materials anfasst.
	# Kein duplicate(), kein Override — nur lesen. Absolut sicher in _ready().
	_snapshot_original_colors()

	_dbg("✅ CloakComponent bereit | root='%s' | sc='%s' | mode=%s | min_alpha=%.2f | detection_range=%.0fm | fade_in=%.1fs" % [
		_ship_root.name if _ship_root else "NULL",
		_ship_controller.name if _ship_controller else "NULL",
		"PLAYER" if _is_player_ship else "NPC",
		_effective_min_alpha,
		cloak_data.detection_range, cloak_data.fade_in_duration
	])


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
	if _state != State.CLOAKED and _state != State.CLOAKING:
		return
	_dbg("💥 Cloak gebrochen: %s" % reason)
	cloak_broken.emit(reason)
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
	# Im IDLE: voll sichtbar
	if _state == State.IDLE:
		return 1.0

	# Im Übergang: linear interpoliert mit _cloak_alpha
	if _state == State.CLOAKING or _state == State.DECLOAKING:
		return _cloak_alpha

	# Im COOLDOWN: voll sichtbar (war ja gerade enttarnt)
	if _state == State.COOLDOWN:
		return 1.0

	# CLOAKED: hängt von Distanz zum Observer ab
	if not is_instance_valid(observer):
		return 0.0
	if not _ship_root:
		return 0.0

	var dist: float = _ship_root.global_position.distance_to(observer.global_position)
	if dist >= cloak_data.detection_range:
		return 0.0

	# Linear interpoliert: bei dist=0 → shimmer_max_alpha, bei dist=detection_range → 0
	var t: float = 1.0 - (dist / cloak_data.detection_range)
	return t * cloak_data.shimmer_max_alpha


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

	# Mesh-Fade auf _effective_min_alpha (0.0 = komplett unsichtbar, >0 = leicht sichtbar)
	_fade_to(_effective_min_alpha, cloak_data.fade_in_duration, _on_cloak_complete)
	_dbg("  → Ziel-Alpha: %.2f" % _effective_min_alpha)
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

	# Mesh-Fade zurück auf 1.0
	_fade_to(1.0, duration, _on_decloak_complete.bind(emergency))
	return true


func _on_cloak_complete() -> void:
	_state = State.CLOAKED
	_set_collision_active(false)

	# NPC-Modus mit min_alpha=0: Mesh komplett ausblenden für sauberen Look
	# (sonst können Restartefakte vom transparenten Material sichtbar bleiben).
	# Player-Modus mit min_alpha>0: Mesh bleibt sichtbar.
	if _effective_min_alpha <= 0.0:
		_set_original_meshes_visible(false)
		_dbg("✅ CLOAKED (komplett unsichtbar)")
	else:
		_dbg("✅ CLOAKED (leicht sichtbar, alpha=%.2f)" % _effective_min_alpha)

	cloaked.emit()


func _on_decloak_complete(emergency: bool) -> void:
	# Mesh wieder sichtbar wenn es im Cloak versteckt wurde (NPC-Modus)
	if _effective_min_alpha <= 0.0:
		_set_original_meshes_visible(true)

	_set_collision_active(true)
	_set_shields_offline(false)
	_set_weapons_locked(false)

	if emergency:
		_state = State.COOLDOWN
		_cooldown_timer = cloak_data.emergency_cooldown
		_dbg("⏰ COOLDOWN aktiv (%.1fs)" % _cooldown_timer)
	else:
		_state = State.IDLE
		_dbg("✅ DECLOAKED (voll sichtbar)")

	decloaked.emit()


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

	var mesh_instances: Array[MeshInstance3D] = []
	if target_meshes.size() > 0:
		for m in target_meshes:
			if is_instance_valid(m):
				mesh_instances.append(m)
	elif _ship_root:
		mesh_instances = _find_all_mesh_instances(_ship_root)

	for mesh in mesh_instances:
		if mesh.name == "ShieldMesh":
			continue
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
			else:
				# Nicht-Standard Material (ShaderMaterial etc.) — wir können die
				# Farbe nicht zuverlässig auslesen, behalten weißen Default als Marker.
				_original_colors.append(Color.WHITE)

	_dbg("📷 Originalfarben gesichert: %d Einträge" % _original_colors.size())


## Dupliziert alle relevanten Mesh-Materials per-Instanz (Material-Isolation).
## Wird LAZY beim ersten Cloak-Versuch aufgerufen — nicht in _ready(),
## damit Schiffe die nie cloaken keinen unnötigen Material-Speicher belegen.
##
## ⚠ KRITISCH: IMMER duplicate(true) (Deep-Copy) und IMMER neu setzen, auch
## wenn surface_override_material schon existiert. Sonst teilen sich zwei
## Schiffe desselben Typs die Material-Reference und cloaken zusammen.
func _initialize_materials() -> void:
	if _materials_initialized:
		return

	# EXPLIZIT: target_meshes aus dem Inspector nutzen wenn gesetzt.
	# FALLBACK: automatische Suche vom Root-Node (weniger sicher).
	var mesh_instances: Array[MeshInstance3D] = []
	if target_meshes.size() > 0:
		for m in target_meshes:
			if is_instance_valid(m):
				mesh_instances.append(m)
		_dbg("🎯 Nutze %d explizit zugewiesene Meshes aus dem Inspector" % mesh_instances.size())
	elif _ship_root:
		mesh_instances = _find_all_mesh_instances(_ship_root)
		_dbg("🔍 Fallback: %d Meshes per Auto-Suche gefunden" % mesh_instances.size())
	else:
		_dbg("⚠ _initialize_materials: kein _ship_root und keine target_meshes!")
		return

	# Separater Index für die Snapshot-Farben — wir überspringen Surfaces ohne
	# Material, daher kann der Surface-Index abweichen.
	var color_idx: int = 0

	for mesh in mesh_instances:
		if mesh.name == "ShieldMesh":
			continue

		var surface_count: int = mesh.mesh.get_surface_count() if mesh.mesh else 0

		for i in range(surface_count):
			# Quelle: Override falls vorhanden, sonst Base. Beide sind potenziell
			# zwischen Schiffsinstanzen geteilt — wir MÜSSEN duplizieren.
			var override_mat: Material = mesh.get_surface_override_material(i)
			var source_mat: Material = override_mat if override_mat else mesh.mesh.surface_get_material(i)
			if not source_mat:
				continue

			# DEEP-COPY: duplicate(true) kopiert auch verschachtelte Sub-Resources
			# wie Texture-Refs, Sub-Materials etc. Ohne true gehen Texturen
			# verloren → Schiff erscheint farblos.
			var new_mat: Material = source_mat.duplicate(true)
			mesh.set_surface_override_material(i, new_mat)
			_cached_materials.append(new_mat)

			# Snapshot-Farbe explizit zurückschreiben — Versicherung falls
			# duplicate(true) doch was verschluckt hat.
			if color_idx < _original_colors.size() and new_mat is StandardMaterial3D:
				(new_mat as StandardMaterial3D).albedo_color = _original_colors[color_idx]
			color_idx += 1

	_materials_initialized = true
	_dbg("✅ Materials dupliziert: %d (deep-copy + Farb-Snapshot zurückgeschrieben)" % _cached_materials.size())

	if _cached_materials.is_empty():
		_dbg("⚠ KEINE Materials gefunden! Mögliche Ursachen:")
		_dbg("  1. target_meshes leer UND _ship_root falsch")
		_dbg("  2. Mesh hat keine Surfaces (mesh.get_surface_count() = 0)")
		_dbg("  3. Surfaces haben weder Base-Material noch Override")


## Tween-basierter Alpha-Fade von _cloak_alpha → target_alpha.
func _fade_to(target_alpha: float, duration: float, on_complete: Callable) -> void:
	_initialize_materials()

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()

	if _cached_materials.is_empty():
		_cloak_alpha = target_alpha
		on_complete.call()
		return

	# Transparency aktivieren bevor der Fade startet (nur StandardMaterial3D)
	for mat in _cached_materials:
		if mat is StandardMaterial3D:
			(mat as StandardMaterial3D).transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var start_alpha: float = _cloak_alpha
	_active_tween = create_tween()
	_active_tween.tween_method(
		func(progress: float) -> void:
			var current_alpha: float = lerp(start_alpha, target_alpha, progress)
			_apply_alpha_to_materials(current_alpha),
		0.0, 1.0,
		duration
	)
	_active_tween.tween_callback(func() -> void:
		_cloak_alpha = target_alpha
		# Beim Decloak (target=1.0): Originalfarbe + Transparency aus.
		# Beim Cloak (target=min_alpha): Transparency bleibt aktiv.
		if target_alpha >= 1.0:
			for i in range(_cached_materials.size()):
				var mat: Material = _cached_materials[i]
				if mat is StandardMaterial3D:
					var sm: StandardMaterial3D = mat as StandardMaterial3D
					if i < _original_colors.size():
						sm.albedo_color = _original_colors[i]
					sm.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		on_complete.call()
	)


## Wird von tween_method pro Frame aufgerufen — setzt alpha auf allen Materials.
## Behält Original-RGB bei und setzt nur den Alpha-Kanal — kein Farbverlust.
func _apply_alpha_to_materials(alpha: float) -> void:
	_cloak_alpha = alpha
	for i in range(_cached_materials.size()):
		var mat: Material = _cached_materials[i]
		if not mat is StandardMaterial3D:
			continue
		var sm: StandardMaterial3D = mat as StandardMaterial3D
		# Original-RGB aus Snapshot, nur Alpha aus dem aktuellen Fade-Wert
		var base: Color = _original_colors[i] if i < _original_colors.size() else sm.albedo_color
		sm.albedo_color = Color(base.r, base.g, base.b, alpha)

	# Debug bei markanten Alpha-Werten
	if show_debug:
		if alpha <= 0.01:
			_dbg("🎨 Alpha=0.0 erreicht | %d Materials" % _cached_materials.size())
		elif alpha >= 0.99:
			_dbg("🎨 Alpha=1.0 erreicht | %d Materials" % _cached_materials.size())


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

	# ── Zoom/Distanz-Steuerung – Werte aus audio_data ─────────────────
	var no_atten:  bool  = audio_data.no_distance_attenuation      if audio_data else false
	var max_dist:  float = audio_data.max_distance                  if audio_data else 800.0
	var atten_str: float = audio_data.distance_attenuation_strength if audio_data else 0.25
	var cutoff:    float = audio_data.attenuation_filter_cutoff_hz  if audio_data else 12000.0
	var fade_time: float = audio_data.sound_fade_out_time           if audio_data else 0.8

	if no_atten:
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		player.max_distance      = 2000.0
	else:
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		player.max_distance      = max_dist
		player.unit_size         = 1.0 / max(0.1, atten_str)

	player.attenuation_filter_cutoff_hz = cutoff

	add_child(player)
	player.play()

	if fade_time > 0.0:
		var tween := create_tween()
		tween.tween_property(player, "volume_db", -80.0, fade_time)\
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tween.tween_callback(func():
			if is_instance_valid(player): player.queue_free()
		)
	else:
		player.finished.connect(func():
			if is_instance_valid(player): player.queue_free()
		)


func _find_all_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_find_all_mesh_instances(child))
	return result


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


## Liefert die relevanten Meshes — aus Inspector oder Auto-Suche.
func _get_target_meshes() -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if target_meshes.size() > 0:
		for m in target_meshes:
			if is_instance_valid(m) and m.name != "ShieldMesh":
				result.append(m)
	elif _ship_root:
		for m in _find_all_mesh_instances(_ship_root):
			if m.name != "ShieldMesh":
				result.append(m)
	return result


## Blendet Original-Meshes komplett aus/ein (für NPC-Modus mit min_alpha=0).
func _set_original_meshes_visible(visible: bool) -> void:
	for mesh in _get_target_meshes():
		mesh.visible = visible
	_dbg("👁 Meshes visible=%s" % visible)


func _dbg(msg: String) -> void:
	if not show_debug:
		# Auch ohne show_debug-Flag das DebugManager-Flag respektieren
		var dm: Node = get_tree().root.get_node_or_null("DebugManager")
		if not dm or not dm.has_method("get_flag"):
			return
		if not dm.get_flag("cloak.events"):
			return
	var ship_name: String = _ship_controller.name if _ship_controller else "?"
	print("[Cloak|%s] %s" % [ship_name, msg])
