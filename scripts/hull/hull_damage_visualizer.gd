# res://scripts/hull_damage_visualizer.gd
#
# Aufgabe (Single Responsibility):
#   Liest jeden Frame den Hüllen-Schaden vom ShipController und setzt die
#   passenden Shader-Parameter am Hüllen-Material des Schiffs.
#
# Was es NICHT macht (bewusst):
#   • Spawnt KEINE Decals  → das macht HullImpactReceiver
#   • Spawnt KEINE Partikel → kommt in Phase 2 (separates Skript)
#   • Berührt KEINE anderen Schiff-Systeme
#
# Anhängen an: den MeshInstance3D mit dem Damage-Shader-Material.
# Bei Mehrfach-Surfaces (z.B. Hülle + Fenster): nur einmal an den Knoten
# hängen — das Skript adressiert intern Surface 0 (= Hülle).
#
# Architektur-Notiz: das Skript dupliziert das Material EINMAL in _ready().
# Damit hat jedes Schiff eine eigene Material-Instanz und Schaden auf Schiff A
# beeinflusst nicht Schiff B (klassische "Material Sharing"-Falle bei
# instanzierten .tscn-Szenen).

extends MeshInstance3D
class_name HullDamageVisualizer

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export_group("Ship Reference")
## ShipController-Referenz für HP-Polling. Wenn leer, wird automatisch im
## Eltern-Baum gesucht (geht durch Vorfahren bis ein "ShipController"-class_name
## gefunden wird oder ein Knoten mit get_hull_integrity()-Methode).
@export var ship_controller_path: NodePath

@export_group("Damage Mapping")
## Maximaler damage_amount-Wert, der je auf den Shader gesetzt wird.
## Bei voller Hüllen-Zerstörung ist das der "Maximum-Look".
## Empfehlung: 0.65 — höher wirkt visuell überfrachtet (zu großflächig).
@export_range(0.0, 1.0, 0.01) var damage_visual_cap: float = 0.6

## Beschleunigungs-Exponent der Damage-Kurve.
##   1.0 = linear (HP-Verlust direkt proportional zum visuellen Schaden)
##   2.5 = beschleunigend (lange wenig sichtbar, dann schnell schlimmer) [DEFAULT]
##   4.0 = stark beschleunigend (fast nichts bis 80%, dann brutal)
## Höhere Werte = dramatischere Endphase, weniger frühe Schäden.
@export_range(1.0, 6.0, 0.1) var damage_curve_exponent: float = 2.5

@export_group("Dynamic Pulse Scaling")
## Wenn aktiv: Pulse-Geschwindigkeit, Flicker und Amplitude wachsen mit dem
## Schaden. Bei wenig Schaden ruhig brennend, bei kritisch nervös zuckend.
## Wenn aus: die Pulse-Werte aus dem Inspector des ShaderMaterials werden
## nicht überschrieben (statisch).
@export var enable_dynamic_pulse: bool = true

## Pulse-Geschwindigkeit bei minimalem Schaden (Hz).
@export_range(0.0, 10.0, 0.1) var pulse_speed_min: float = 0.8
## Pulse-Geschwindigkeit bei maximalem Schaden (Hz).
@export_range(0.0, 10.0, 0.1) var pulse_speed_max: float = 3.5

## Flicker-Stärke bei minimalem Schaden (0..1).
@export_range(0.0, 1.0, 0.01) var pulse_flicker_min: float = 0.0
## Flicker-Stärke bei maximalem Schaden.
@export_range(0.0, 1.0, 0.01) var pulse_flicker_max: float = 0.6

## Pulse-Amplitude bei minimalem Schaden.
@export_range(0.0, 1.0, 0.01) var pulse_amplitude_min: float = 0.3
## Pulse-Amplitude bei maximalem Schaden.
@export_range(0.0, 1.0, 0.01) var pulse_amplitude_max: float = 0.7

@export_group("Performance")
## Update-Intervall in Sekunden. Default 0 = jeden Frame.
## Höhere Werte (z.B. 0.1) sparen ggf. Performance bei vielen Schiffen,
## machen Pulse-Übergänge aber etwas hakeliger. 0.05 ist ein guter Kompromiss
## bei sehr vielen Schiffen gleichzeitig.
@export_range(0.0, 0.5, 0.01) var update_interval: float = 0.0

@export_group("Debug")
@export var debug_visualizer: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────
var _ship_ctrl:        Node           = null
var _hull_materials: Array[ShaderMaterial] = []
var _accum_time:       float          = 0.0
var _last_damage_log:  float          = -1.0   # Drossel für Debug-Logs


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────


func _ready() -> void:
	_resolve_ship_controller()
	_resolve_and_clone_material()

	if debug_visualizer:
		# Wir prüfen, ob das Array nicht leer ist
		var has_mat = _hull_materials.size() > 0
		print("[HDV|%s] ready | ship_ctrl=%s | materials_found=%d" % [
			name,
			_ship_ctrl.name if _ship_ctrl else "—",
			_hull_materials.size()
		])

func _process(delta: float) -> void:
	# Prüfung auf das Array statt auf die Einzelvariable
	if _hull_materials.is_empty() or not _ship_ctrl:
		return

	# Optional: Wir prüfen den Wert der ersten Oberfläche für das Log
	var current_dmg = _hull_materials[0].get_shader_parameter("damage_amount")
	var integrity = _ship_ctrl.get_hull_integrity()
	
	if current_dmg > 0.1 and integrity > 0.99:
		print("[HDV-ALERT|%s] FEHLER: Damage ist %.2f trotz 100%% HP!" % [name, current_dmg])

	if update_interval > 0.0:
		_accum_time += delta
		if _accum_time < update_interval:
			return
		_accum_time = 0.0

	_update_shader_parameters()


# ─────────────────────────────────────────────────────────────────────────────
# SHIP-CONTROLLER AUFLÖSUNG
# ─────────────────────────────────────────────────────────────────────────────
## Sucht den ShipController in dieser Reihenfolge:
##   1) Explizit gesetzter ship_controller_path
##   2) Vorfahren-Suche: gehe Eltern-Baum nach oben, nimm ersten Knoten mit
##      get_hull_integrity()-Methode
## Damit das Skript ohne Inspector-Setup funktioniert, solange es irgendwo
## unter einem ShipController hängt.
func _resolve_ship_controller() -> void:
	if not ship_controller_path.is_empty():
		_ship_ctrl = get_node_or_null(ship_controller_path)
		if _ship_ctrl:
			return

	var n: Node = get_parent()
	while n:
		if n.has_method("get_hull_integrity"):
			_ship_ctrl = n
			return
		n = n.get_parent()

	push_warning("[HDV|%s] Kein ShipController mit get_hull_integrity() gefunden → Visualizer inaktiv." % name)


# ─────────────────────────────────────────────────────────────────────────────
# MATERIAL-KLONEN (Anti-Sharing)
# ─────────────────────────────────────────────────────────────────────────────
## Adressiert Surface 0 und dupliziert das ShaderMaterial. Damit hat jedes
## Schiff eine eigene Instanz — Schaden an Schiff A färbt Schiff B nicht mit.
##
## Wir nutzen `set_surface_override_material()` statt das Mesh-Material direkt
## zu ändern; sonst würde die Änderung in der Mesh-Resource landen und ALLE
## Schiffe mit demselben Mesh wären betroffen.
#
#func _resolve_and_clone_material() -> void:
	#var src_mat: Material = get_active_material(0)
	#if not src_mat:
		#push_warning("[HDV|%s] Surface 0 hat kein Material — Visualizer inaktiv." % name)
		#return
#
	#if not (src_mat is ShaderMaterial):
		#push_warning("[HDV|%s] Surface-0-Material ist KEIN ShaderMaterial (sondern %s) — Damage-Shader vermutlich nicht zugewiesen." % [
			#name, src_mat.get_class()])
		#return
#
	## Duplizieren → eigene Instanz pro Schiff
	#var cloned := (src_mat as ShaderMaterial).duplicate() as ShaderMaterial
	#set_surface_override_material(0, cloned)
	#_hull_material = cloned
#
	## damage_amount IMMER auf 0 forcen nach dem Klonen.
	## Verhindert dass ein im Inspector gespeicherter Testwert (z.B. 0.6)
	## beim Spawn sichtbar ist — passiert weil .duplicate() den Resource-
	## Zustand 1:1 kopiert, inklusive Test-Werten.
	#cloned.set_shader_parameter("damage_amount", 0.0)

func _resolve_and_clone_material() -> void:
	_hull_materials.clear()
	
	# Wir loopen durch ALLE Oberflächen des Meshes
	var surface_count = get_surface_override_material_count()
	if surface_count == 0:
		# Falls es ein MeshInstance3D ist, nutzen wir die Mesh-Daten
		surface_count = mesh.get_surface_count()

	for i in range(surface_count):
		var src_mat = get_active_material(i)
		if src_mat is ShaderMaterial:
			# Wir klonen für jede Oberfläche einzeln
			var cloned = src_mat.duplicate() as ShaderMaterial
			set_surface_override_material(i, cloned)
			_hull_materials.append(cloned)
			
			# Initialer Reset für diese Oberfläche
			cloned.set_shader_parameter("damage_amount", 0.0)
			print("[HDV-DEBUG|%s] Surface %d resettet." % [name, i])


# ─────────────────────────────────────────────────────────────────────────────
# CORE-LOGIK: HP → SHADER-PARAMETER
# ─────────────────────────────────────────────────────────────────────────────
## Berechnet den damage_amount aus der Hüllen-Quote und setzt alle Shader-
## Parameter. Wird jeden Frame (oder per Intervall) aufgerufen.
##
## Mapping-Kurve: pow(hp_loss, exponent) * cap
##   hp_loss = 1.0 - get_hull_integrity()
##
## Kurven-Beispiele bei exponent = 2.5 und cap = 0.65:
##   30 % HP-Verlust → 0.03 (kaum sichtbar)
##   50 % HP-Verlust → 0.09
##   75 % HP-Verlust → 0.32
##   90 % HP-Verlust → 0.50
##  100 % HP-Verlust → 0.65 (Maximum)

func _update_shader_parameters() -> void:
	# 1. Berechnung der Werte (einmalig für alle Oberflächen)
	var integrity: float = float(_ship_ctrl.get_hull_integrity())
	var hp_loss:   float = clamp(1.0 - integrity, 0.0, 1.0)

	# Deine bestehende Logik für die Schadenskurve
	var damage_curve: float = pow(hp_loss, damage_curve_exponent)
	var damage_amt:   float = damage_curve * damage_visual_cap

	# 2. Werte auf ALLE Materialien anwenden
	for mat in _hull_materials:
		mat.set_shader_parameter("damage_amount", damage_amt)

		if enable_dynamic_pulse:
			var pulse_norm: float = damage_amt / max(damage_visual_cap, 0.001)

			var p_speed:     float = lerp(pulse_speed_min,     pulse_speed_max,     pulse_norm)
			var p_flicker:   float = lerp(pulse_flicker_min,   pulse_flicker_max,   pulse_norm)
			var p_amplitude: float = lerp(pulse_amplitude_min, pulse_amplitude_max, pulse_norm)

			mat.set_shader_parameter("pulse_speed_hz",       p_speed)
			mat.set_shader_parameter("pulse_flicker_amount", p_flicker)
			mat.set_shader_parameter("pulse_amplitude",      p_amplitude)

	# 3. Debug-Logging (nur einmal pro Update-Zyklus)
	if debug_visualizer and abs(damage_amt - _last_damage_log) > 0.05:
		print("[HDV|%s] hp_loss=%.2f → damage_amount=%.2f (Surfaces: %d)" % [
			name, hp_loss, damage_amt, _hull_materials.size()
		])
		_last_damage_log = damage_amt

# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL PUBLIC API
# ─────────────────────────────────────────────────────────────────────────────
## Erzwingt einen sofortigen Update (ignoriert update_interval). Nützlich für
## Debug-Panels oder manuelle Tests, ohne auf den nächsten Frame zu warten.
func force_update() -> void:
	_accum_time = 999.0  # ensures _update_shader_parameters runs next frame
	# Prüfung auf das Array statt Einzelvariable
	if not _hull_materials.is_empty() and _ship_ctrl:
		_update_shader_parameters()


## Setzt damage_amount manuell (überschreibt HP-basierte Berechnung für 1 Frame).
## Für Debug-Tools nützlich, die einen bestimmten Schadens-Look testen wollen
## ohne das Schiff tatsächlich zu beschießen.
func set_damage_amount_override(value: float) -> void:
	if _hull_materials.is_empty():
		return
	
	# Wir setzen den Wert für jede einzelne Oberfläche
	for mat in _hull_materials:
		mat.set_shader_parameter("damage_amount", clamp(value, 0.0, damage_visual_cap))


## Setzt den Schaden komplett zurück (Reparatur). Macht aus dem Schiff
## visuell wieder eine heile Hülle, unabhängig vom HP-Wert.
func reset_visual() -> void:
	if _hull_materials.is_empty():
		return
		
	for mat in _hull_materials:
		mat.set_shader_parameter("damage_amount", 0.0)
