# res://scripts/hull_impact.gd
# Hull-Impact-VFX für Strahlwaffen (Phaser, Disruptor, …).
#
# WICHTIG zur Anti-Stutter-Architektur:
#   • Position wird AUSSCHLIESSLICH von außen gesetzt – durch BeamWeapon3D
#     in dessen _physics_process(). Dieses Skript hat KEIN _process /
#     _physics_process für Position-Updates. Damit gibt es keinen Frame-
#     Versatz zwischen Schiff (bewegt in _physics_process), Beam-Endpunkt
#     (gesetzt in _physics_process) und Impact-VFX (gesetzt im selben Tick).
#
#   • Alle Partikel (Sparks, Burn1-3) laufen im WELT-Raum (local_coords = false).
#     Wird der Emitter mit dem Treffer mitbewegt, bleiben bereits emittierte
#     Partikel physikalisch korrekt im Raum stehen — kein Mitschleifen.
#
#   • Visuelle Lebendigkeit kommt aus Tween-basierten Loops (Eigenrotation
#     + Pulsation der Burn-Nodes). Das kaschiert Sub-Pixel-Versatz und
#     macht den Effekt dynamischer ohne AnimationPlayer-Resource (wartungsarm,
#     versionsfreundlich, kein Inspector-Klickbedarf).
extends Node3D

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export var debug_hull_impact: bool = false

@export_group("Skalierung")
@export var effect_scale:  float = 1.0
@export var spark_scale:   float = 1.0
@export var burn_scale:    float = 1.0
@export var scorch_scale:  float = 1.0

@export_group("Funken")
@export var spark_amount:        int   = 40
@export var spark_velocity_min:  float = 3.0
@export var spark_velocity_max:  float = 8.0

@export_group("Lifetime")
## Standard-Lebenszeit. Wird durch `linked_duration` überschrieben sobald das
## BeamWeapon3D nach Spawn `linked_duration` zuweist (= fire_duration + trail_fade).
@export var lifetime: float = 3.0

@export_group("Animation (optisches Glätten, Punkt 4)")
## Eigen-Rotation der Effekt-Wurzel um die lokale Z-Achse (= Beam-Achse, da
## das BeamWeapon3D den Effekt per look_at orientiert). 0 = aus.
## Kaschiert Sub-Pixel-Stutter und lenkt das Auge von kleinen Position-
## Unstimmigkeiten ab.
@export var spin_speed_deg_per_sec: float = 90.0
## Pulsations-Frequenz für die Burn-Nodes (Hz, also volle Pulse pro Sekunde).
@export var pulse_frequency_hz: float = 2.0
## Stärke der Scale-Schwingung beim Pulsieren (0.15 = ±15 %).
@export_range(0.0, 0.5) var pulse_amplitude: float = 0.12

# ─────────────────────────────────────────────────────────────────────────────
# RUNTIME-PARAMETER (vom BeamWeapon3D gesetzt, kein @export)
# ─────────────────────────────────────────────────────────────────────────────
## Wenn > 0, überschreibt sie `lifetime`. BeamWeapon3D setzt das beim Spawn auf
## `weapon_data.fire_duration + weapon_data.trail_fade_out_time`, damit der
## Effekt exakt mit dem Strahl ausläuft.
var linked_duration: float = -1.0

# ─────────────────────────────────────────────────────────────────────────────
# PRIVATE
# ─────────────────────────────────────────────────────────────────────────────
var _sparks: GPUParticles3D            = null
var _decal:  Decal                     = null
var _burn_nodes:       Array[GPUParticles3D] = []  # Punkt 5: Array für konsistente Steuerung
var _burn_base_scales: Array[Vector3]        = []  # Basis-Scale je Burn (für Pulse-Tween)


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_find_child_nodes()
	_force_world_space_particles()    # Punkt 3
	_apply_scale()                    # Punkt 5
	_start_animation()                # Punkt 4

	var actual_lifetime: float = linked_duration if linked_duration > 0.0 else lifetime
	get_tree().create_timer(actual_lifetime).timeout.connect(_on_lifetime_expired)

	if debug_hull_impact:
		print("[HullImpact] gestartet | lifetime=%.2fs | sparks=%s | burns=%d | decal=%s" % [
			actual_lifetime,
			"✓" if _sparks else "✗",
			_burn_nodes.size(),
			"✓" if _decal else "✗"
		])


# ─────────────────────────────────────────────────────────────────────────────
# NODE-SUCHE  (feste Namen laut Szenenstruktur:
#              Sparks / ScorchDecal / Burn1 / Burn2 / Burn3)
# ─────────────────────────────────────────────────────────────────────────────
func _find_child_nodes() -> void:
	_sparks = get_node_or_null("Sparks") as GPUParticles3D
	_decal  = get_node_or_null("ScorchDecal") as Decal

	_burn_nodes.clear()
	_burn_base_scales.clear()
	for i in range(1, 4):
		var b := get_node_or_null("Burn" + str(i)) as GPUParticles3D
		if b:
			_burn_nodes.append(b)
			_burn_base_scales.append(b.scale)

	if not _sparks:
		push_warning("[HullImpact] 'Sparks' nicht gefunden.")
	if _burn_nodes.is_empty():
		push_warning("[HullImpact] Keine Burn-Nodes (Burn1/2/3) gefunden.")


# ─────────────────────────────────────────────────────────────────────────────
# PARTIKEL ENTKOPPELN  (Punkt 3)
# ─────────────────────────────────────────────────────────────────────────────
## Setzt local_coords = false defensiv im Code, damit eine versehentliche
## Inspector-Änderung der Szenen-Datei das Verhalten nicht still kippen kann.
## false = WELT-Raum: Partikel verbleiben dort wo sie emittiert wurden.
func _force_world_space_particles() -> void:
	if _sparks:
		_sparks.local_coords = false
	for burn in _burn_nodes:
		burn.local_coords = false


# ─────────────────────────────────────────────────────────────────────────────
# SKALIERUNG  (Punkt 5: konsistent über Array)
# ─────────────────────────────────────────────────────────────────────────────
func _apply_scale() -> void:
	# Funken
	if _sparks:
		_sparks.amount = spark_amount
		var s_mat := _sparks.process_material as ParticleProcessMaterial
		if s_mat:
			s_mat.initial_velocity_min = spark_velocity_min * effect_scale
			s_mat.initial_velocity_max = spark_velocity_max * effect_scale
			s_mat.scale_min            = 0.05 * effect_scale * spark_scale
			s_mat.scale_max            = 0.12 * effect_scale * spark_scale

	# Burn-Nodes (Rauch + Glut) konsistent über Array
	for i in _burn_nodes.size():
		var burn: GPUParticles3D = _burn_nodes[i]
		var b_mat := burn.process_material as ParticleProcessMaterial
		if b_mat:
			b_mat.initial_velocity_min = 0.3 * effect_scale
			b_mat.initial_velocity_max = 1.0 * effect_scale
			b_mat.scale_min            = 0.3 * effect_scale * burn_scale
			b_mat.scale_max            = 1.2 * effect_scale * burn_scale
		# Basis-Scale erneut einlesen, falls effect_scale die Node-Skalierung
		# später beeinflussen sollte. Pulse-Tween schwingt um diesen Wert.
		_burn_base_scales[i] = burn.scale

	# Scorch-Decal
	if _decal:
		_decal.size = Vector3(0.8, 1.0, 0.8) * effect_scale * scorch_scale


# ─────────────────────────────────────────────────────────────────────────────
# ANIMATION  (Punkt 4 — Tween-basiert, wartungsarm, versionsfreundlich)
# ─────────────────────────────────────────────────────────────────────────────
## Startet zwei Loop-Tweens:
##   1) Eigenrotation der Wurzel um Z (= Beam-Achse). Lenkt das Auge ab,
##      kaschiert minimales Zittern.
##   2) Scale-Pulsation der Burn-Nodes mit Phasenversatz, damit sie nicht
##      synchron atmen.
##
## WICHTIG: Beide Tweens laufen im PHYSICS-Tick (TWEEN_PROCESS_PHYSICS),
##          damit sie synchron zur Position-Aktualisierung durch BeamWeapon3D
##          angewendet werden. Sonst würde Tween in _process laufen während
##          die Position in _physics_process gesetzt wird → 1-Frame-Versatz
##          zwischen Rotation und Position.
func _start_animation() -> void:
	# 1) Eigen-Rotation der Wurzel
	if spin_speed_deg_per_sec > 0.0:
		var period: float = 360.0 / spin_speed_deg_per_sec
		var spin_tween := create_tween() \
			.set_loops() \
			.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
		spin_tween.tween_property(self, "rotation:z", TAU, period).from(0.0)

	# 2) Pulsation der Burn-Nodes (Scale-Schwingung mit Phasenversatz)
	if pulse_frequency_hz > 0.0 and pulse_amplitude > 0.0:
		var pulse_period: float = 1.0 / pulse_frequency_hz
		for i in _burn_nodes.size():
			var burn: GPUParticles3D = _burn_nodes[i]
			var base: Vector3        = _burn_base_scales[i]
			var peak: Vector3        = base * (1.0 + pulse_amplitude)

			var t := create_tween() \
				.set_loops() \
				.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS) \
				.set_trans(Tween.TRANS_SINE) \
				.set_ease(Tween.EASE_IN_OUT)
			# Phasenversatz pro Burn (0.0s, 0.05s, 0.10s) – gibt dem Effekt Volumen
			if i > 0:
				t.tween_interval(0.05 * float(i))
			t.tween_property(burn, "scale", peak, pulse_period * 0.5)
			t.tween_property(burn, "scale", base, pulse_period * 0.5)


# ─────────────────────────────────────────────────────────────────────────────
# LIFETIME
# ─────────────────────────────────────────────────────────────────────────────
func _on_lifetime_expired() -> void:
	queue_free()
