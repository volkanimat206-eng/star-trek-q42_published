# res://tools/create_death_animation.gd
#
# EditorScript - NICHT im Spiel-Baum verwenden.
#
# VERWENDUNG:
#   1. Datei im Editor oeffnen
#   2. Im Script-Editor oben rechts: "Run" (Pfeil) klicken
#   3. Die .tres wird unter OUTPUT_PATH gespeichert
#
# PRO SCHIFFSKLASSE:
#   Skript duplizieren, OUTPUT_PATH + MESH_SURFACES anpassen,
#   dann Werte in den Sektionen unten anpassen.
#
# MESH_SURFACES erklaert:
#   Key   = Name des MeshInstance3D-Nodes (direkt unter MeshModel)
#   Value = Array der Surface-Indizes die den Damage-Shader tragen
#
#   Sovereign:  { "Saucer": [0],    "Body": [0]    }  -> je 1 Surface
#   Galaxy:     { "Body":   [0, 1]  }                 -> 2 Surfaces auf einem Mesh
#   Beliebig:   { "Hull":   [0, 1, 2], "Nacelle": [0] }

@tool
extends EditorScript

# =============================================================================
# KONFIGURATION -- hier pro Schiffsklasse anpassen
# =============================================================================

## Ausgabepfad der fertigen Animation-Resource.
const OUTPUT_PATH := "res://resources/animations/death_dderidex.tres"

## Gesamtdauer der Todessequenz in Sekunden.
const ANIM_LENGTH := 2.0

## Mesh-Node-Namen -> Surface-Indizes mit Damage-Shader.
## Jede Kombination aus (Node, Surface) bekommt eigene Tracks.
##
## Sovereign:
##   const MESH_SURFACES := { "Saucer": [0], "Body": [0] }
##
## Galaxy (ein Mesh, zwei Surfaces):
##   const MESH_SURFACES := { "Body": [0, 1] }

## #"Hull":   [0,1,2],
##
const MESH_SURFACES := {
	"Body":   [0,1],
	
}

# -- Damage-Kurve --------------------------------------------------------------
# DAMAGE_START = -1.0 -> kein Keyframe bei t=0.
#   Godot startet die Animation nahtlos vom aktuellen Shader-Wert.
#   Empfohlen: kein Sprung wenn das Schiff z.B. bei 40% HP stirbt.
# DAMAGE_START >= 0.0 -> expliziter Startwert ueberschreibt den aktuellen Wert.
const DAMAGE_START := -1.0
const DAMAGE_END   := 1.0
const DAMAGE_MID_T := 0.6
const DAMAGE_MID_V := 0.75

# -- Cracks --------------------------------------------------------------------
const CRACK_START        := 0.6
const CRACK_END          := 1.0
const CRACK_GLOW_START   := 3.0
const CRACK_GLOW_END     := 8.0

# -- Burn Energie --------------------------------------------------------------
const BURN_GLOW_START    := 4.0
const BURN_GLOW_END      := 14.0
const BURN_MOLTEN_START  := 12.0
const BURN_MOLTEN_END    := 30.0

# -- Heat Pulse ----------------------------------------------------------------
#const PULSE_SPEED_START   := 1.2
#const PULSE_SPEED_END     := 5.0
#const PULSE_AMP_START     := 0.45
#const PULSE_AMP_END       := 0.95
#const PULSE_FLICKER_START := 0.35
#const PULSE_FLICKER_END   := 0.85


# =============================================================================
# EINSTIEGSPUNKT
# =============================================================================
func _run() -> void:
	var anim := Animation.new()
	anim.length = ANIM_LENGTH
	anim.loop_mode = Animation.LOOP_NONE

	for mesh_name in MESH_SURFACES.keys():
		var surfaces: Array = MESH_SURFACES[mesh_name]
		for surface_idx in surfaces:
			_add_tracks_for_surface(anim, mesh_name, surface_idx)

	var err := ResourceSaver.save(anim, OUTPUT_PATH)
	if err == OK:
		print("[DeathAnimGen] Gespeichert: %s" % OUTPUT_PATH)
		print("[DeathAnimGen] Laenge: %.2fs | Tracks: %d" % [ANIM_LENGTH, anim.get_track_count()])
		for mesh_name in MESH_SURFACES.keys():
			print("  %s -> surfaces %s" % [mesh_name, str(MESH_SURFACES[mesh_name])])
	else:
		push_error("[DeathAnimGen] Fehler beim Speichern (Code %d): %s" % [err, OUTPUT_PATH])


# =============================================================================
# TRACKS FUER EINE (MESH, SURFACE)-KOMBINATION
# =============================================================================

func _add_tracks_for_surface(anim: Animation, mesh_name: String, surface_idx: int) -> void:
	_add_float_track(anim, mesh_name, surface_idx, "damage_amount",        _build_damage_keys())
	_add_float_track(anim, mesh_name, surface_idx, "crack_amount",         [[0.0, CRACK_START],       [ANIM_LENGTH, CRACK_END]])
	_add_float_track(anim, mesh_name, surface_idx, "crack_glow_intensity", [[0.0, CRACK_GLOW_START],  [ANIM_LENGTH, CRACK_GLOW_END]])
	_add_float_track(anim, mesh_name, surface_idx, "burn_glow_energy",     [[0.0, BURN_GLOW_START],   [ANIM_LENGTH, BURN_GLOW_END]])
	_add_float_track(anim, mesh_name, surface_idx, "burn_molten_energy",   [[0.0, BURN_MOLTEN_START], [ANIM_LENGTH, BURN_MOLTEN_END]])
	#_add_float_track(anim, mesh_name, surface_idx, "pulse_speed_hz",       [[0.0, PULSE_SPEED_START], [ANIM_LENGTH, PULSE_SPEED_END]])
	#_add_float_track(anim, mesh_name, surface_idx, "pulse_amplitude",      [[0.0, PULSE_AMP_START],   [ANIM_LENGTH, PULSE_AMP_END]])
	#_add_float_track(anim, mesh_name, surface_idx, "pulse_flicker_amount", [[0.0, PULSE_FLICKER_START],[ANIM_LENGTH, PULSE_FLICKER_END]])


# =============================================================================
# HILFSFUNKTIONEN
# =============================================================================

func _build_damage_keys() -> Array:
	var keys := []
	if DAMAGE_START >= 0.0:
		keys.append([0.0, DAMAGE_START])
	keys.append([ANIM_LENGTH * DAMAGE_MID_T, DAMAGE_MID_V])
	keys.append([ANIM_LENGTH, DAMAGE_END])
	return keys


## Fuegt einen VALUE-Track fuer einen Shader-Parameter hinzu.
## Track-Pfad: "MeshName:surface_material_override/SURFACE_IDX:shader_parameter/param"
## Beispiele:
##   "Body:surface_material_override/0:shader_parameter/damage_amount"
##   "Body:surface_material_override/1:shader_parameter/damage_amount"
func _add_float_track(anim: Animation, mesh_name: String, surface_idx: int,
		param_name: String, keys: Array) -> void:
	if keys.is_empty():
		return

	var path := "%s:surface_material_override/%d:shader_parameter/%s" % [
		mesh_name, surface_idx, param_name
	]

	var idx: int = anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(idx, path)
	anim.value_track_set_update_mode(idx, Animation.UPDATE_CONTINUOUS)
	anim.track_set_interpolation_type(idx, Animation.INTERPOLATION_CUBIC)

	for kv in keys:
		anim.track_insert_key(idx, float(kv[0]), float(kv[1]))
