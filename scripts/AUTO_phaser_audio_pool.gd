# res://scripts/autoload/phaser_audio_pool.gd
# Autoload-Singleton: Project Settings → Autoload → phaser_audio_pool.tscn → "PhaserAudioPool"
#
# Einheitlicher Pool mit AudioStreamPlayer3D für alle Waffen.
# Spieler-Waffen: panning_strength=0.0 + unit_size sehr groß → kein Zoom-Einfluss
# NPC-Waffen:     panning_strength=1.0 + normale unit_size   → räumlich, mit Distanz leiser
extends Node

# ===== POOL-EINSTELLUNGEN =====
@export var pool_size: int = 8
@export var audio_bus: String = "Weapons"

@export_group("Volume")
@export_range(-40.0, 6.0) var charge_volume_db: float = -6.0
@export_range(-40.0, 6.0) var fire_volume_db:   float =  0.0

@export_group("Pitch")
@export_range(0.0, 0.3) var pitch_variation: float = 0.05

@export_group("Spatialization")
## Maximale Hördistanz für NPC-Waffen. Spieler-Waffen ignorieren diesen Wert.
@export var max_distance: float = 800.0
## unit_size für NPC-Waffen – bestimmt wie schnell der Sound mit Distanz leiser wird.
## Größer = bei Distanz besser hörbar. Empfehlung: 50–150 für typische Kampfdistanzen.
@export_range(1.0, 500.0) var npc_unit_size: float = 80.0
## panning_strength für Spieler-Waffen (0.0 = kein 3D-Effekt, 1.0 = voll räumlich).
## 0.0 empfohlen damit eigene Phasersounds immer gleich laut sind.
## 0.1–0.2 für minimales Richtungsgefühl je nach Mount-Position.
@export_range(0.0, 1.0) var player_panning_strength: float = 0.0

# ===== INTERN =====
var _charge_pool:      Array[AudioStreamPlayer3D] = []
var _fire_pool:        Array[AudioStreamPlayer3D] = []
var _active_charge:    Dictionary = {}
var _active_fire:      Dictionary = {}
var _charge_tweens:    Dictionary = {}
var _fire_tweens:      Dictionary = {}
## Speichert pro Waffen-ID ob es eine Spieler-Waffe ist.
var _is_player_weapon: Dictionary = {}


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	for i: int in pool_size:
		_charge_pool.append(_make_player("Charge_%d" % i))
		_fire_pool.append(_make_player("Fire_%d" % i))


func _make_player(player_name: String) -> AudioStreamPlayer3D:
	var p          := AudioStreamPlayer3D.new()
	p.name          = player_name
	p.bus           = audio_bus
	p.max_distance  = max_distance
	p.max_polyphony = 1
	add_child(p)
	return p


# ─────────────────────────────────────────────────────────────────────────────
# REGISTRIERUNG
# ─────────────────────────────────────────────────────────────────────────────

## Registriert eine Waffe beim Pool.
## is_player = true  → Spieler-Modus: kein Zoom-Einfluss
## is_player = false → NPC-Modus: räumlich, mit Distanz leiser
## Wird einmalig von BeamWeapon3D._connect_audio_pool() aufgerufen.
func register_weapon(weapon_id: int, is_player: bool) -> void:
	_is_player_weapon[weapon_id] = is_player


# ─────────────────────────────────────────────────────────────────────────────
# SPATIAL SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

## Setzt die räumlichen Eigenschaften des Players je nach Waffen-Typ.
## Spieler: panning_strength niedrig + unit_size extrem groß = kein Zoom-Einfluss
## NPC:     panning_strength 1.0 + normale unit_size = voller 3D-Effekt
func _apply_spatial_settings(player: AudioStreamPlayer3D, weapon_id: int) -> void:
	if _is_player_weapon.get(weapon_id, false):
		player.panning_strength = player_panning_strength
		player.unit_size        = 10000.0   # Dämpfungskurve praktisch flach
		player.max_distance     = max_distance
	else:
		player.panning_strength = 1.0
		player.unit_size        = npc_unit_size
		player.max_distance     = max_distance


# ─────────────────────────────────────────────────────────────────────────────
# SIGNAL-HANDLER
# ─────────────────────────────────────────────────────────────────────────────

func _on_charging_started(is_charge_type: bool, charge_snd: AudioStream,
		charge_vol_offset: float, weapon: BeamWeapon3D) -> void:
	if not is_charge_type or not charge_snd:
		return
	var id := weapon.get_instance_id()
	_kill_fade(_charge_tweens, id)
	_stop_player(_active_charge, id)

	var player := _get_free_player(_charge_pool)
	if not player:
		return
	_active_charge[id]     = player
	player.global_position = weapon.global_position
	player.stream          = charge_snd
	player.volume_db       = charge_volume_db + charge_vol_offset
	player.pitch_scale     = 1.0 + randf_range(-pitch_variation, pitch_variation)
	_apply_spatial_settings(player, id)
	player.play()


func _on_fired(fire_snd: AudioStream, charge_fade_time: float, charge_curve: Curve,
		fire_vol_offset: float, weapon: BeamWeapon3D) -> void:
	var id := weapon.get_instance_id()
	_fade_out_player(_active_charge, _charge_tweens, id,
		charge_fade_time, charge_volume_db, charge_curve)

	if not fire_snd:
		return
	_kill_fade(_fire_tweens, id)
	_stop_player(_active_fire, id)

	var player := _get_free_player(_fire_pool)
	if not player:
		return
	_active_fire[id]       = player
	player.global_position = weapon.global_position
	player.stream          = fire_snd
	player.volume_db       = fire_volume_db + fire_vol_offset
	player.pitch_scale     = 1.0 + randf_range(-pitch_variation, pitch_variation)
	_apply_spatial_settings(player, id)
	player.play()


func _on_beam_stopped(fire_fade_time: float, fire_curve: Curve,
		weapon: BeamWeapon3D) -> void:
	var id := weapon.get_instance_id()
	_kill_fade(_charge_tweens, id)
	_stop_player(_active_charge, id)
	_fade_out_player(_active_fire, _fire_tweens, id,
		fire_fade_time, fire_volume_db, fire_curve)


# ─────────────────────────────────────────────────────────────────────────────
# FADE HELPER
# ─────────────────────────────────────────────────────────────────────────────

func _fade_out_player(active_dict: Dictionary, tween_dict: Dictionary,
		weapon_id: int, fade_time: float, start_volume: float,
		curve: Curve) -> void:
	if not active_dict.has(weapon_id):
		return
	var player: AudioStreamPlayer3D = active_dict[weapon_id]
	if not is_instance_valid(player) or not player.playing:
		active_dict.erase(weapon_id)
		return

	if fade_time <= 0.0:
		player.stop()
		active_dict.erase(weapon_id)
		return

	_kill_fade(tween_dict, weapon_id)
	var tween := create_tween()
	tween_dict[weapon_id] = tween

	if curve:
		var steps: int = 20
		for i: int in range(1, steps + 1):
			var t: float         = float(i) / float(steps)
			var curve_val: float = curve.sample(t)
			var target_db: float = lerp(-80.0, start_volume, curve_val)
			tween.tween_property(player, "volume_db", target_db,
				fade_time / float(steps))
	else:
		tween.tween_property(player, "volume_db", -80.0, fade_time)

	tween.tween_callback(func():
		if is_instance_valid(player):
			player.stop()
			player.volume_db = start_volume
		active_dict.erase(weapon_id)
		tween_dict.erase(weapon_id)
	)


func _kill_fade(tween_dict: Dictionary, weapon_id: int) -> void:
	if tween_dict.has(weapon_id):
		var t: Tween = tween_dict[weapon_id]
		if is_instance_valid(t):
			t.kill()
		tween_dict.erase(weapon_id)


# ─────────────────────────────────────────────────────────────────────────────
# POOL HELPER
# ─────────────────────────────────────────────────────────────────────────────

func _get_free_player(pool: Array[AudioStreamPlayer3D]) -> AudioStreamPlayer3D:
	for p: AudioStreamPlayer3D in pool:
		if not p.playing:
			return p
	if pool.size() > 0:
		pool[0].stop()
		return pool[0]
	return null


func _stop_player(active_dict: Dictionary, weapon_id: int) -> void:
	if active_dict.has(weapon_id):
		var p: AudioStreamPlayer3D = active_dict[weapon_id]
		if is_instance_valid(p):
			p.stop()
		active_dict.erase(weapon_id)
