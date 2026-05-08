# res://scripts/thruster_glow.gd
#
# Thruster-Glow + Audio das auf Schiffsgeschwindigkeit reagiert.
# Hängt am MeshInstance3D des Thrusters und liest dessen Material direkt.
#
# WICHTIG: Material-Lookup pro Update, NICHT gecached!
# Andere Systeme können das surface_override_material zur Laufzeit austauschen
# (z.B. CloakComponent dupliziert es zur Material-Isolation, Damage-Effects
# könnten ähnliches tun). Wenn wir hier eine Material-Reference cachen,
# zeigen wir nach so einem Tausch ins Leere — sichtbarer Bug: Glow bleibt
# nach Decloak aus.
#
# Die Performance-Kosten von get_active_material() pro Speed-Update sind
# vernachlässigbar (es ist ein einfacher Property-Lookup, kein Deep-Search).
extends MeshInstance3D

@export_group("Slot Settings")
@export var impulse_slot: int  = 0

@export_group("Glow Intensity")
@export var idle_glow: float  = 0.0
@export var max_glow: float   = 20.0

@export_group("Sound Settings")
@export var audio_player: AudioStreamPlayer3D
@export var min_volume_db: float = -20.0  # Inspector einstellbar
@export var max_volume_db: float = 0.0    # Inspector einstellbar
@export var min_pitch: float = 0.8        # Inspector einstellbar
@export var max_pitch: float = 1.2        # Inspector einstellbar
@export var use_pitch: bool = true        # optional ausschalten

## Aktuelle Glow-Energie — nur fürs Debug-Inspect, nicht extern lesen.
var current_glow_display: float = 0.0

## Markierung damit wir andere Systeme erkennen lassen können dass dieses
## Material vom ThrusterGlow verwaltet wird. Aktuell nur informativ; falls
## CloakComponent später eine "respect external owners"-Liste bekommt,
## könnte er hierauf prüfen.
const META_OWNED_BY: String = "thruster_glow_owner"


func _ready() -> void:
	# Initiales Material setzen: Original duplizieren und als Override eintragen.
	# Das ist nur die Erst-Initialisierung — danach lesen wir IMMER live aus
	# dem Mesh, weil andere Systeme den Override tauschen könnten.
	var original := get_active_material(impulse_slot)
	if original is StandardMaterial3D:
		var initial: StandardMaterial3D = (original as StandardMaterial3D).duplicate()
		initial.set_meta(META_OWNED_BY, get_path())
		set_surface_override_material(impulse_slot, initial)
	else:
		push_warning("[ThrusterGlow] Kein StandardMaterial3D auf Slot %d!" % impulse_slot)
		return

	await get_tree().process_frame
	_connect_to_ship()

	# Audio vorbereiten
	if audio_player:
		audio_player.volume_db = min_volume_db
		if not audio_player.playing:
			audio_player.play()


func _connect_to_ship() -> void:
	var sc: ShipController = _find_ship_controller()
	if sc:
		sc.ship_speed_updated.connect(_on_speed_updated)
		print("[ThrusterGlow] '%s' verbunden mit ShipController '%s'" % [name, sc.ship_name])
	else:
		push_warning("[ThrusterGlow] Kein ShipController gefunden für '%s'!" % name)


func _find_ship_controller() -> ShipController:
	var current: Node = get_parent()
	while current:
		if current is ShipController:
			return current as ShipController
		current = current.get_parent()

	var ancestor: Node = get_parent()
	while ancestor:
		var found := ancestor.find_children("*", "ShipController", false, false)
		if found.size() > 0:
			return found[0] as ShipController
		ancestor = ancestor.get_parent()

	return null


## Holt das aktuell aktive Material aus dem Slot. Wird pro Speed-Update
## aufgerufen, damit wir gegen Material-Tausch durch andere Systeme robust
## bleiben (CloakComponent, Damage-Effects, etc.).
##
## Falls das Material vom Cloak-System dupliziert wurde, hat es trotzdem
## emission_enabled=true und alle anderen Properties unverändert — wir können
## also einfach drauf schreiben. Was wir verlieren ist die META_OWNED_BY-
## Markierung; das ist okay, der Glow funktioniert trotzdem.
func _get_live_material() -> StandardMaterial3D:
	var mat: Material = get_active_material(impulse_slot)
	if mat is StandardMaterial3D:
		return mat as StandardMaterial3D
	return null


func _on_speed_updated(current_speed: float, max_speed: float) -> void:
	# IMMER frisch holen — kein Cache! Andere Systeme könnten den
	# Override seit dem letzten Frame ausgetauscht haben.
	var mat: StandardMaterial3D = _get_live_material()
	if not mat:
		return

	# --- Glow Update ---
	var ratio: float = clamp(absf(current_speed) / max_speed, 0.0, 1.0)
	var eased_ratio: float = ratio * ratio
	var energy: float = lerp(idle_glow, max_glow, eased_ratio)
	mat.emission_energy_multiplier = energy
	current_glow_display = energy

	# --- Sound Update ---
	if audio_player:
		audio_player.volume_db = lerp(min_volume_db, max_volume_db, eased_ratio)
		if use_pitch:
			audio_player.pitch_scale = lerp(min_pitch, max_pitch, eased_ratio)
