# res://scripts/combat/cloak_component.gd
#
# Cloaking-System als ShipController-Subsystem. Analog zu ShieldSystem aufgebaut.
#
# LEBENSZYKLUS:
#   IDLE → CLOAKING (fade-in) → CLOAKED → DECLOAKING (fade-out) → IDLE
#                                ↓ break_cloak()
#                                EMERGENCY_DECLOAK → COOLDOWN → IDLE
#
# WAFFEN/SCHILDE:
#   - CLOAKING startet:    weapons_offline + shields_offline + immer noch Mesh sichtbar
#   - CLOAKED:             alles aus, Mesh transparent, Layer aus
#   - DECLOAKING startet:  Mesh wird wieder sichtbar
#   - DECLOAKING fertig:   weapons_online + shields_online (mit recharge_delay)
#
# SICHTBARKEIT:
#   Externe Systeme (TargetingSystem, AIController, etc.) fragen die Sichtbarkeit
#   NICHT direkt am Component ab, sondern über ShipController.is_visible_to(observer).
#   Der ShipController delegiert dann an den CloakComponent — das hält die API
#   einheitlich auch für Schiffe ohne Cloak.

class_name CloakComponent
extends Node

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

@export_group("Cloak – Timing")
## Dauer des Eintar-Fades in Sekunden.
@export_range(0.2, 5.0, 0.1) var fade_in_duration:     float = 1.5
## Dauer des Enttarn-Fades in Sekunden.
@export_range(0.2, 5.0, 0.1) var fade_out_duration:    float = 1.0
## Cooldown nach erzwungenem Enttarnen (Waffe, Treffer) in Sekunden.
@export_range(1.0, 30.0, 0.5) var emergency_cooldown:  float = 8.0

@export_group("Cloak – Detection")
## Radius in Metern innerhalb dem ein Observer das Schiff als Distortion sehen kann.
## Außerhalb: komplett unsichtbar. Innerhalb: Raumverzerrungseffekt.
@export_range(10.0, 500.0, 5.0) var detection_range:   float = 100.0
## Maximaler Alpha-Shimmer bei altem Proximity-System (Legacy, nicht mehr genutzt).
## Wird für die Distortion-Stärken-Kurve weiterverwendet (0.1–0.5 empfohlen).
@export_range(0.0, 1.0, 0.05) var shimmer_max_alpha:   float = 0.15

@export_group("Cloak – Meshes")
## Die MeshInstance3D-Nodes die beim Cloaken transparent werden.
## Direkt im Inspector zuweisen — verhindert dass das falsche Mesh erwischt wird.
## Mehrere Meshes können zugewiesen werden (z.B. Hülle, Brücke, Triebwerke).
## Leer lassen = automatische Suche vom Root-Node (Fallback, weniger sicher).
@export var target_meshes: Array[MeshInstance3D] = []

@export_group("Cloak – Audio")
## AudioStreamPlayer3D für den Cloak-Aktivierungs-Sound. Im Inspector zuweisen.
@export var audio_player: AudioStreamPlayer3D = null
## Sound beim Aktivieren der Tarnung.
@export var sound_cloak:   AudioStream = null
## Sound beim Deaktivieren der Tarnung.
@export var sound_decloak: AudioStream = null

@export_group("Cloak – Distortion Shader")
## Pfad zum Distortion-Shader im Projekt.
@export_file("*.gdshader") var distortion_shader_path: String = "res://shaders/cloak_distortion.gdshader"
## Maximale Pixel-Verschiebung des Refraktionseffekts bei minimaler Distanz.
@export_range(4.0, 64.0, 1.0) var distortion_max_pixels: float = 18.0
## Stärke des bläulichen Rim-Leuchtens an Silhouettenkanten. 0 = aus.
@export_range(0.0, 1.0, 0.05) var distortion_rim_strength: float = 0.25
## Geschwindigkeit des Noise-Flows im Distortion-Shader.
@export_range(0.0, 3.0, 0.1) var distortion_flow_speed: float = 0.4
## Skalierung des Noise-Musters (kleiner = gröbere Wellen).
@export_range(0.5, 8.0, 0.1) var distortion_noise_scale: float = 2.5

@export_group("Debug")
## Debug-Logs aktivieren (wird auch vom ShipController propagiert).
@export var show_debug: bool = false

# ─────────────────────────────────────────────────────────────────────────────
# INTERNE VARIABLEN
# ─────────────────────────────────────────────────────────────────────────────

var _ship_controller: Node = null  ## ShipController-Parent (direkte Eltern-Node)
var _ship_root: Node3D = null      ## Root-Node des Schiffes (Parent von ShipController) — hier hängen die Meshes
var _cloak_alpha: float    = 1.0   ## 0.0 = voll getarnt, 1.0 = voll sichtbar
var _cooldown_timer: float = 0.0
var _active_tween: Tween   = null

## Distortion-System: ein separater MeshInstance3D-Klon mit dem Refraktions-Shader
## der die Raumverzerrung erzeugt. Völlig unabhängig von den Schiff-Materialien.
var _distortion_meshes: Array[MeshInstance3D] = []
var _distortion_material: ShaderMaterial = null
var _distortion_initialized: bool = false

## Materials die wir im Cloak modifizieren. Werden beim Setup gefunden und
## gecached. Pro Mesh-Surface eine Override-Material-Kopie damit andere
## Instanzen desselben Schiffstyps nicht mit-cloaken.
var _cached_materials: Array[StandardMaterial3D] = []
var _original_colors: Array[Color] = []   ## Originale albedo_color vor dem ersten Cloak
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

	_dbg("✅ CloakComponent bereit | root='%s' | sc='%s' | detection_range=%.0fm | fade_in=%.1fs" % [
		_ship_root.name if _ship_root else "NULL",
		_ship_controller.name if _ship_controller else "NULL",
		detection_range, fade_in_duration
	])

func _process(delta: float) -> void:
	if _state == State.COOLDOWN:
		_cooldown_timer -= delta
		if _cooldown_timer <= 0.0:
			_state = State.IDLE
			_dbg("✅ Cooldown beendet, kann erneut tarnen")
		return

	# Distortion-Stärke basierend auf Distanz zum nächsten Observer anpassen.
	# Nur im aktiven Cloak-Zustand — in IDLE/COOLDOWN ist _distortion_strength = 0.
	if _state == State.CLOAKED:
		_update_distortion_strength()


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
## Diese Funktion ist die Wahrheits-Quelle für externe Visibility-Checks.
## ShipController.is_visible_to(observer) nutzt diese.
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
	if dist >= detection_range:
		return 0.0

	# Linear interpoliert: bei dist=0 → shimmer_max_alpha, bei dist=detection_range → 0
	var t: float = 1.0 - (dist / detection_range)
	return t * shimmer_max_alpha


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – State-Übergänge
# ─────────────────────────────────────────────────────────────────────────────

func _begin_cloak() -> bool:
	if not _ship_controller:
		return false

	_dbg("🌀 CLOAKING gestartet (fade=%.1fs)" % fade_in_duration)
	_state = State.CLOAKING
	cloaking_started.emit()

	_play_sound(sound_cloak)

	# Schilde und Waffen offline schalten
	_set_weapons_locked(true)
	_set_shields_offline(true)

	# Mesh-Fade auf 0
	_fade_to(0.0, fade_in_duration, _on_cloak_complete)
	return true


func _begin_decloak(emergency: bool = false) -> bool:
	if not _ship_controller:
		return false

	var duration: float = fade_out_duration
	if emergency:
		duration = 0.3   # Schneller Blitz beim erzwungenen Enttarnen

	_dbg("🌀 DECLOAKING gestartet (fade=%.2fs, emergency=%s)" % [duration, emergency])
	_state = State.DECLOAKING
	decloaking_started.emit()

	_play_sound(sound_decloak)

	# Mesh-Fade zurück auf 1.0
	_fade_to(1.0, duration, _on_decloak_complete.bind(emergency))
	return true


func _on_cloak_complete() -> void:
	_state = State.CLOAKED
	_set_collision_active(false)

	# Distortion: nur aktivieren wenn Shader gefunden wurde UND Klone existieren.
	# Wenn _distortion_initialized false ist (Shader fehlt etc.), einfach
	# die Original-Meshes komplett verstecken statt grau zu werden.
	if _distortion_initialized and _distortion_meshes.size() > 0:
		_set_distortion_meshes_visible(true)
		_dbg("✅ CLOAKED (Distortion aktiv, %d Klon-Meshes)" % _distortion_meshes.size())
	else:
		# Fallback: Meshes komplett unsichtbar schalten (kein Distortion-Effekt,
		# aber auch kein Grau-Bug). Sicherer als ein fehlerhafter Shader.
		_set_original_meshes_visible(false)
		_dbg("✅ CLOAKED (kein Distortion-Shader → Meshes versteckt)")

	cloaked.emit()


func _on_decloak_complete(emergency: bool) -> void:
	# Meshes wieder sichtbar — egal welcher Modus aktiv war
	if _distortion_initialized and _distortion_meshes.size() > 0:
		_set_distortion_meshes_visible(false)
		if _distortion_material:
			_distortion_material.set_shader_parameter("distortion_strength", 0.0)
	else:
		_set_original_meshes_visible(true)

	_set_collision_active(true)
	_set_shields_offline(false)
	_set_weapons_locked(false)

	if emergency:
		_state = State.COOLDOWN
		_cooldown_timer = emergency_cooldown
		_dbg("⏰ COOLDOWN aktiv (%.1fs bis IDLE)" % _cooldown_timer)
	else:
		_state = State.IDLE
		_dbg("✅ DECLOAKED (Schiff sichtbar)")

	decloaked.emit()


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Mesh-Fade
# ─────────────────────────────────────────────────────────────────────────────

## Cached alle MeshInstance3D Override-Materials für schnelles Tweening.
## Wird beim ersten Cloak-Versuch aufgerufen, danach ist alles vorbereitet.
##
## WICHTIG: Wir DUPLIZIEREN die Materials, sonst würde ein cloakedes Schiff
## auch alle anderen Instanzen desselben Typs durchscheinen lassen.

func _initialize_materials() -> void:
	if _materials_initialized:
		return

	# EXPLIZIT: target_meshes aus dem Inspector nutzen wenn gesetzt.
	# Das ist der zuverlässige Weg — kein Raten welches Mesh gemeint ist.
	# FALLBACK: automatische Suche vom Root-Node (weniger sicher, aber kompatibel).
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

	for mesh in mesh_instances:
		if mesh.name == "ShieldMesh":
			continue

		var surface_count: int = mesh.mesh.get_surface_count() if mesh.mesh else 0

		# Alle Surfaces des Meshes durchgehen — nicht nur Index 0!
		# Schiffe haben oft mehrere Materials (Hülle, Fenster, Triebwerke etc.)
		for i in range(surface_count):
			var mat_override: Material = mesh.get_surface_override_material(i)
			if not mat_override:
				var base_mat: Material = mesh.mesh.surface_get_material(i)
				if base_mat:
					# DUPLIZIEREN — damit andere Instanzen desselben Schiffstyps
					# nicht mitmachen wenn ein Schiff cloakt.
					mat_override = base_mat.duplicate()
					mesh.set_surface_override_material(i, mat_override)

			if mat_override is StandardMaterial3D:
				var sm: StandardMaterial3D = mat_override
				_original_colors.append(sm.albedo_color)
				# Transparency erst beim Cloak aktivieren (nicht schon jetzt) —
				# verhindert Render-Artefakte im normalen Zustand
				_cached_materials.append(sm)

	_materials_initialized = true
	_dbg("🎨 %d Materials für Cloak-Fade vorbereitet | Meshes: %d" % [
		_cached_materials.size(), mesh_instances.size()
	])
	if _cached_materials.is_empty():
		_dbg("⚠ KEINE Materials gefunden! Mögliche Ursachen:")
		_dbg("  1. target_meshes leer UND _ship_root falsch")
		_dbg("  2. Meshes nutzen ShaderMaterial statt StandardMaterial3D")
		_dbg("  3. Mesh hat keine Surfaces (mesh.get_surface_count() = 0)")
		for mesh in mesh_instances:
			var sc: int = mesh.mesh.get_surface_count() if mesh.mesh else -1
			_dbg("  Mesh '%s': surface_count=%d | material_type=%s" % [
				mesh.name, sc,
				mesh.get_surface_override_material(0).get_class() if sc > 0 and mesh.get_surface_override_material(0) else
				(mesh.mesh.surface_get_material(0).get_class() if sc > 0 and mesh.mesh.surface_get_material(0) else "NULL")
			])

func _fade_to(target_alpha: float, duration: float, on_complete: Callable) -> void:
	_initialize_materials()

	if _active_tween and _active_tween.is_valid():
		_active_tween.kill()

	if _cached_materials.is_empty():
		_cloak_alpha = target_alpha
		on_complete.call()
		return

	# Transparency aktivieren bevor der Fade startet
	for mat in _cached_materials:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# tween_method: Ein einziger Tween steuert _cloak_alpha, _apply_alpha_to_materials
	# wird pro Frame aufgerufen — performanter als N parallele tween_property calls
	# und einfacher zu debuggen.
	_active_tween = create_tween()
	_active_tween.tween_method(
		_apply_alpha_to_materials,
		_cloak_alpha,      # von aktuellem Alpha
		target_alpha,      # zum Ziel-Alpha
		duration
	)
	_active_tween.tween_callback(func() -> void:
		_cloak_alpha = target_alpha
		# Decloak fertig: transparency zurücksetzen + Originalfarbe exakt restaurieren
		if target_alpha >= 1.0:
			for i in range(_cached_materials.size()):
				var mat: StandardMaterial3D = _cached_materials[i]
				if i < _original_colors.size():
					mat.albedo_color = _original_colors[i]
				mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		on_complete.call()
	)


## Wird von tween_method pro Frame aufgerufen — setzt alpha auf allen Materials.
func _apply_alpha_to_materials(alpha: float) -> void:
	_cloak_alpha = alpha
	for i in range(_cached_materials.size()):
		var mat: StandardMaterial3D = _cached_materials[i]
		var base: Color = _original_colors[i] if i < _original_colors.size() else mat.albedo_color
		mat.albedo_color = Color(base.r, base.g, base.b, alpha)

	# Debug bei markanten Alpha-Werten
	if show_debug:
		if alpha <= 0.01:
			_dbg("🎨 Alpha=0.0 erreicht | %d Materials | transparency=%s" % [
				_cached_materials.size(),
				BaseMaterial3D.TRANSPARENCY_ALPHA if _cached_materials.size() > 0
				else "n/a"
			])
		elif alpha >= 0.99:
			_dbg("🎨 Alpha=1.0 erreicht | %d Materials" % _cached_materials.size())


## Sound über den zugewiesenen AudioStreamPlayer3D abspielen.
## Macht nichts wenn audio_player oder der Stream nicht gesetzt sind.
func _play_sound(stream: AudioStream) -> void:
	if not is_instance_valid(audio_player) or not stream:
		return
	audio_player.stream = stream
	audio_player.play()


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


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Distortion-System (Screen-Space Refraktion)
# ─────────────────────────────────────────────────────────────────────────────

## Erstellt für jedes Schiff-Mesh einen transparenten Klon mit dem Distortion-
## Shader. Die Klone werden als Siblings des Meshes unter dem Model-Node gehängt.
## Alle Klone teilen dasselbe ShaderMaterial → ein set_shader_parameter reicht.
func _initialize_distortion() -> void:
	if _distortion_initialized:
		return
	if not _ship_root:
		_dbg("⚠ _initialize_distortion: kein _ship_root!")
		return

	var shader_res: Shader = load(distortion_shader_path) as Shader
	if not shader_res:
		_dbg("⚠ Distortion-Shader nicht gefunden: '%s' — Fallback: Meshes werden komplett versteckt" % distortion_shader_path)
		_distortion_initialized = false
		return

	_distortion_material = ShaderMaterial.new()
	_distortion_material.shader = shader_res
	_distortion_material.set_shader_parameter("distortion_strength",  0.0)
	_distortion_material.set_shader_parameter("max_pixel_offset",     distortion_max_pixels)
	_distortion_material.set_shader_parameter("rim_strength",         distortion_rim_strength)
	_distortion_material.set_shader_parameter("flow_speed",           distortion_flow_speed)
	_distortion_material.set_shader_parameter("noise_scale",          distortion_noise_scale)

	var noise_tex: NoiseTexture2D = NoiseTexture2D.new()
	var fn: FastNoiseLite = FastNoiseLite.new()
	fn.noise_type      = FastNoiseLite.TYPE_PERLIN
	fn.frequency       = 0.025
	fn.fractal_octaves = 4
	noise_tex.width    = 256
	noise_tex.height   = 256
	noise_tex.noise    = fn
	_distortion_material.set_shader_parameter("noise_texture", noise_tex)

	var source_meshes: Array[MeshInstance3D] = []
	if target_meshes.size() > 0:
		for m in target_meshes:
			if is_instance_valid(m) and m.name != "ShieldMesh":
				source_meshes.append(m)
		_dbg("🌊 Distortion: nutze %d Inspector-Meshes als Basis" % source_meshes.size())
	elif _ship_root:
		source_meshes = _find_all_mesh_instances(_ship_root)
		_dbg("🌊 Distortion: %d Meshes per Auto-Suche" % source_meshes.size())

	var created: int = 0
	for src in source_meshes:
		if not src.mesh:
			_dbg("  ⚠ Übersprungen '%s': kein mesh" % src.name)
			continue

		var clone := MeshInstance3D.new()
		clone.name         = src.name + "_Distortion"
		clone.mesh         = src.mesh
		clone.visible      = false
		clone.cast_shadow  = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		clone.material_override = _distortion_material

		# KRITISCH: Transform des Klons muss im globalen Raum stimmen.
		# src.transform ist LOKAL zum Parent — den Klon unter denselben Parent
		# hängen und denselben lokalen Transform geben ist korrekt.
		# ABER: wir nutzen global_transform → in World-Space umrechnen damit
		# der Klon auch nach Rotations/Scale-Änderungen am richtigen Ort sitzt.
		var parent_node: Node3D = src.get_parent() as Node3D
		if parent_node:
			src.get_parent().add_child(clone)
			# Globalen Transform übernehmen NACHDEM der Clone im Tree ist
			clone.global_transform = src.global_transform
			_dbg("  ✅ Klon '%s' unter '%s' | global_pos=%s" % [
				clone.name, parent_node.name,
				str(clone.global_position.snapped(Vector3.ONE))
			])
		else:
			_dbg("  ⚠ Kein Node3D-Parent für '%s' — Klon übersprungen" % src.name)
			clone.queue_free()
			continue

		_distortion_meshes.append(clone)
		created += 1

	_distortion_initialized = true
	_dbg("🌊 Distortion-System: %d Klon-Meshes erstellt (von %d Quell-Meshes)" % [
		created, source_meshes.size()
	])


func _set_distortion_meshes_visible(visible: bool) -> void:
	if not _distortion_initialized:
		_initialize_distortion()
	for mesh in _distortion_meshes:
		if is_instance_valid(mesh):
			mesh.visible = visible


## Fallback wenn kein Distortion-Shader verfügbar: Original-Meshes direkt
## ein-/ausblenden. Kein visueller Effekt, aber auch kein Grau-Bug.
func _set_original_meshes_visible(visible: bool) -> void:
	var meshes: Array[MeshInstance3D] = []
	if target_meshes.size() > 0:
		for m in target_meshes:
			if is_instance_valid(m):
				meshes.append(m)
	elif _ship_root:
		meshes = _find_all_mesh_instances(_ship_root)

	for mesh in meshes:
		if mesh.name == "ShieldMesh":
			continue
		mesh.visible = visible
	_dbg("👁 Original-Meshes visible=%s (%d Meshes)" % [visible, meshes.size()])


## Berechnet die Distortion-Stärke basierend auf dem nächsten Observer-Schiff.
## Außerhalb detection_range → 0.0 (unsichtbar).
## Innerhalb → linear von 0.0 bis 1.0 (bei Distanz 0).
func _update_distortion_strength() -> void:
	if not _distortion_material:
		return
	if not _ship_root:
		return

	var my_pos: Vector3 = _ship_root.global_position
	var nearest_dist: float = INF

	for ship in get_tree().get_nodes_in_group("ships"):
		if ship == _ship_root or ship == _ship_controller or not ship is Node3D:
			continue
		var d: float = (ship as Node3D).global_position.distance_to(my_pos)
		if d < nearest_dist:
			nearest_dist = d

	var strength: float = 0.0
	if nearest_dist < detection_range:
		strength = 1.0 - (nearest_dist / detection_range)
		strength = pow(strength, 0.6)

	_distortion_material.set_shader_parameter("distortion_strength", strength)


# ─────────────────────────────────────────────────────────────────────────────
# DEBUG
# ─────────────────────────────────────────────────────────────────────────────

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
