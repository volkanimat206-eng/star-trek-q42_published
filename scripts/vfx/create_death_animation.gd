# res://tools/create_death_animation.gd
#
# EditorScript — NICHT im Spiel-Baum verwenden.
#
# VERWENDUNG:
#   1. Datei im Editor öffnen
#   2. Im Script-Editor oben rechts: "Run" (▶) klicken
#   3. Die .tres wird unter OUTPUT_PATH gespeichert
#
# PRO SCHIFFSKLASSE:
#   Skript duplizieren, OUTPUT_PATH + MESH_NAMES anpassen,
#   dann Werte in den Sektionen unten anpassen.

@tool
extends EditorScript

# ─────────────────────────────────────────────────────────────────────────────
# KONFIGURATION — hier pro Schiffsklasse anpassen
# ─────────────────────────────────────────────────────────────────────────────

## Ausgabepfad der fertigen Animation-Resource.
const OUTPUT_PATH := "res://resources/animations/death_sovereign.tres"

## Gesamtdauer der Todessequenz in Sekunden.
const ANIM_LENGTH := 3.5

## Surface-Index der Damage-Materialien (fast immer 0).
const SURFACE_INDEX := 0

## Namen der MeshInstance3D-Nodes unter MeshModel die den Damage-Shader tragen.
## AnimationPlayer.root_node = ".." (= MeshModel) → direkte Kindnamen verwenden.
const MESH_NAMES := ["Saucer", "Body"]

# ── Damage-Kurve ──────────────────────────────────────────────────────────────
# DAMAGE_START = -1.0 → kein Keyframe bei t=0.
#   Der AnimationPlayer startet nahtlos vom aktuellen Shader-Wert.
#   Empfohlen, damit kein visueller Sprung entsteht wenn das Schiff
#   z.B. erst bei 30% HP stirbt (damage_amount ≈ 0.35).
# DAMAGE_START >= 0.0 → expliziter Startwert, überschreibt den aktuellen Wert.
const DAMAGE_START  := -1.0   # -1 = kein Keyframe bei t=0
const DAMAGE_END    := 1.0
const DAMAGE_MID_T  := 0.6    # Zeitpunkt des Beschleunigungsknicks (0.0–1.0)
const DAMAGE_MID_V  := 0.75   # damage_amount bei DAMAGE_MID_T

# ── Cracks ────────────────────────────────────────────────────────────────────
const CRACK_START        := 0.6
const CRACK_END          := 1.0
const CRACK_GLOW_START   := 3.0
const CRACK_GLOW_END     := 8.0

# ── Burn Energie ──────────────────────────────────────────────────────────────
const BURN_GLOW_START    := 4.0
const BURN_GLOW_END      := 14.0
const BURN_MOLTEN_START  := 12.0
const BURN_MOLTEN_END    := 30.0

# ── Heat Pulse ────────────────────────────────────────────────────────────────
const PULSE_SPEED_START   := 1.2
const PULSE_SPEED_END     := 5.0
const PULSE_AMP_START     := 0.45
const PULSE_AMP_END       := 0.95
const PULSE_FLICKER_START := 0.35
const PULSE_FLICKER_END   := 0.85


# ─────────────────────────────────────────────────────────────────────────────
# EINSTIEGSPUNKT
# ─────────────────────────────────────────────────────────────────────────────
func _run() -> void:
	var anim := Animation.new()
	anim.length = ANIM_LENGTH
	anim.loop_mode = Animation.LOOP_NONE

	for mesh_name in MESH_NAMES:
		_add_float_track(anim, mesh_name, "damage_amount",        _build_damage_keys())
		_add_float_track(anim, mesh_name, "crack_amount",         [[0.0, CRACK_START],       [ANIM_LENGTH, CRACK_END]])
		_add_float_track(anim, mesh_name, "crack_glow_intensity", [[0.0, CRACK_GLOW_START],  [ANIM_LENGTH, CRACK_GLOW_END]])
		_add_float_track(anim, mesh_name, "burn_glow_energy",     [[0.0, BURN_GLOW_START],   [ANIM_LENGTH, BURN_GLOW_END]])
		_add_float_track(anim, mesh_name, "burn_molten_energy",   [[0.0, BURN_MOLTEN_START], [ANIM_LENGTH, BURN_MOLTEN_END]])
		_add_float_track(anim, mesh_name, "pulse_speed_hz",       [[0.0, PULSE_SPEED_START], [ANIM_LENGTH, PULSE_SPEED_END]])
		_add_float_track(anim, mesh_name, "pulse_amplitude",      [[0.0, PULSE_AMP_START],   [ANIM_LENGTH, PULSE_AMP_END]])
		_add_float_track(anim, mesh_name, "pulse_flicker_amount", [[0.0, PULSE_FLICKER_START],[ANIM_LENGTH, PULSE_FLICKER_END]])

	var err := ResourceSaver.save(anim, OUTPUT_PATH)
	if err == OK:
		print("[DeathAnimGen] Gespeichert: %s" % OUTPUT_PATH)
		print("[DeathAnimGen] Laenge: %.2fs | Tracks: %d | Meshes: %s" % [
			ANIM_LENGTH, anim.get_track_count(), str(MESH_NAMES)
		])
	else:
		push_error("[DeathAnimGen] Fehler beim Speichern (Code %d): %s" % [err, OUTPUT_PATH])


# ─────────────────────────────────────────────────────────────────────────────
# HILFSFUNKTIONEN
# ─────────────────────────────────────────────────────────────────────────────

func _build_damage_keys() -> Array:
	var keys := []
	if DAMAGE_START >= 0.0:
		keys.append([0.0, DAMAGE_START])
	keys.append([ANIM_LENGTH * DAMAGE_MID_T, DAMAGE_MID_V])
	keys.append([ANIM_LENGTH, DAMAGE_END])
	return keys


## Fügt einen VALUE-Track für einen Shader-Parameter aller MESH_NAMES hinzu.
## Track-Pfad: "MeshName:surface_material_override/0:shader_parameter/param"
## keys: Array von [time: float, value: float]
func _add_float_track(anim: Animation, mesh_name: String,
		param_name: String, keys: Array) -> void:
	if keys.is_empty():
		return

	var path := "%s:surface_material_override/%d:shader_parameter/%s" % [
		mesh_name, SURFACE_INDEX, param_name
	]

	var idx: int = anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(idx, path)
	anim.value_track_set_update_mode(idx, Animation.UPDATE_CONTINUOUS)
	anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_CUBIC)

	for kv in keys:
		anim.track_insert_key(idx, float(kv[0]), float(kv[1]))
