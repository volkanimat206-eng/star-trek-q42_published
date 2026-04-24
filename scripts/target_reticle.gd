# res://scripts/ui/target_reticle.gd
extends Control
class_name TargetReticle

# ─────────────────────────────────────────────────────────────────────────────
# ENUMS
# ─────────────────────────────────────────────────────────────────────────────

enum State { HIDDEN, TRACKING, LOCKED }

## NEU: Disposition des gelockten Ziels – bestimmt die Farbe des Reticles
## wenn State == LOCKED. Wird pro Frame vom TargetingSystem aktualisiert,
## damit Ruf-Änderungen sofort sichtbar werden.
enum Disposition { HOSTILE, NEUTRAL, FRIENDLY }


# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────

@export_group("Größe")
@export var reticle_size: float = 44.0
@export var bracket_len:  float = 13.0

@export_group("Farben")
## Farbe beim Hovern (MANUAL-Mode, noch nicht gelockt).
@export var color_tracking: Color = Color(0.7, 0.9, 1.0, 0.9)

## LOCKED-Farbe für feindliche Ziele (rot).
## Name bleibt "color_locked" zwecks Rückwärtskompatibilität mit vorhandenen
## .tres/.tscn-Dateien – semantisch = HOSTILE.
@export var color_locked:   Color = Color(1.0, 0.22, 0.22, 1.0)

## NEU: LOCKED-Farbe für neutrale Ziele (gelb).
@export var color_neutral:  Color = Color(1.0, 0.85, 0.20, 1.0)

## NEU: LOCKED-Farbe für befreundete Ziele / gleiche Fraktion (grün).
@export var color_friendly: Color = Color(0.35, 1.0, 0.50, 1.0)


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────

var _state:        State       = State.HIDDEN
var _disposition:  Disposition = Disposition.HOSTILE   # NEU
var _spread:       float       = 3.0   # 1.0 = Zielgröße, >1 = aufgespreizt
var _spin:         float       = 0.0   # Extra-Winkeloffset für Spin (rad)
var _spin_vel:     float       = 0.0   # Winkelgeschwindigkeit
var _alpha:        float       = 0.0
var _pulse_time:   float       = 0.0
var _flash:        float       = 0.0


func _ready() -> void:
	clip_contents       = false
	mouse_filter        = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(1.0, 1.0)


# ─────────────────────────────────────────────────────────────────────────────
# API
# ─────────────────────────────────────────────────────────────────────────────

func set_state(new_state: State) -> void:
	# TRACKING immer neu triggern – auch beim Target-Wechsel
	if new_state == State.TRACKING:
		_trigger_tracking_anim()
		_state = new_state
		return

	if new_state == _state:
		return
	_state = new_state

	match new_state:
		State.LOCKED:
			_flash      = 1.0
			_spin_vel   = 0.0
			_pulse_time = 0.0
		State.HIDDEN:
			_spin_vel   = 0.0

	queue_redraw()


## NEU: Disposition setzen – ändert die LOCKED-Farbe.
## Darf pro Frame aufgerufen werden (kein Flash, kein State-Reset).
func set_disposition(d: Disposition) -> void:
	if _disposition == d:
		return
	_disposition = d
	queue_redraw()


func get_disposition() -> Disposition:
	return _disposition


func _trigger_tracking_anim() -> void:
	# Ecken starten aufgespreizt + mit Drall
	_spread   = 2.8
	_spin     = deg_to_rad(50.0)    # Startversatz
	_spin_vel = -6.0                # Dreht sich auf 0 ein
	_alpha    = 0.0
	_flash    = 0.0


func set_screen_pos(pos: Vector2) -> void:
	position = pos
	queue_redraw()


# ─────────────────────────────────────────────────────────────────────────────
# PROCESS
# ─────────────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _state == State.HIDDEN:
		if _alpha > 0.001:
			_alpha = move_toward(_alpha, 0.0, delta * 7.0)
			queue_redraw()
		return

	var dirty := false
	_flash = move_toward(_flash, 0.0, delta * 5.0)

	match _state:
		State.TRACKING:
			_alpha    = move_toward(_alpha, 1.0, delta * 10.0)
			_spread   = lerp(_spread, 1.0, delta * 6.0)
			_spin_vel = lerp(_spin_vel, 0.0, delta * 7.0)
			_spin    += _spin_vel * delta
			_spin     = lerp(_spin, 0.0, delta * 8.0)
			dirty     = true

		State.LOCKED:
			_alpha      = move_toward(_alpha, 1.0, delta * 20.0)
			_spread     = lerp(_spread, 1.0, delta * 22.0)
			_spin       = lerp(_spin,   0.0, delta * 22.0)
			_pulse_time += delta
			dirty       = true

	if dirty:
		queue_redraw()


# ─────────────────────────────────────────────────────────────────────────────
# DRAW – Brackets immer achsenausgerichtet, nur Ecken-POSITION dreht sich
# ─────────────────────────────────────────────────────────────────────────────

func _draw() -> void:
	if _alpha < 0.01 and _flash < 0.01:
		return

	var pulse := 0.0
	if _state == State.LOCKED:
		pulse = sin(_pulse_time * TAU * 1.8) * 2.5

	var s: float = (reticle_size + pulse) * _spread
	var b: float = bracket_len
	var w: float = 2.0

	# NEU: Farbwahl abhängig von State + Disposition
	var base_col: Color = _resolve_color()
	if _flash > 0.001:
		base_col = base_col.lerp(Color.WHITE, _flash)
	base_col.a *= _alpha

	# Spin dreht nur die POSITION der Ecken (nicht die Arm-Richtungen)
	# → Brackets bleiben immer als saubere L-Form erhalten
	var corners: Array = [
		Vector2(-s, -s),  # oben-links
		Vector2( s, -s),  # oben-rechts
		Vector2( s,  s),  # unten-rechts
		Vector2(-s,  s),  # unten-links
	]
	var arms_h: Array = [
		Vector2( b,  0),   # oben-links:  nach rechts
		Vector2(-b,  0),   # oben-rechts: nach links
		Vector2(-b,  0),   # unten-rechts: nach links
		Vector2( b,  0),   # unten-links:  nach rechts
	]
	var arms_v: Array = [
		Vector2( 0,  b),   # oben-links:  nach unten
		Vector2( 0,  b),   # oben-rechts: nach unten
		Vector2( 0, -b),   # unten-rechts: nach oben
		Vector2( 0, -b),   # unten-links:  nach oben
	]

	for i in 4:
		var c: Vector2 = (corners[i] as Vector2).rotated(_spin)
		draw_line(c, c + (arms_h[i] as Vector2), base_col, w, true)
		draw_line(c, c + (arms_v[i] as Vector2), base_col, w, true)

	# Zentrum-Kreuz beim Lock – nutzt dieselbe Disposition-Farbe
	if _state == State.LOCKED and _flash < 0.7:
		var cx_col: Color = _resolve_color()
		cx_col.a         *= _alpha * 0.55
		var cx: float     = 4.0
		draw_line(Vector2(-cx, 0), Vector2(cx, 0), cx_col, 1.5, true)
		draw_line(Vector2(0, -cx), Vector2(0, cx), cx_col, 1.5, true)


# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

## Bestimmt die aktuelle Zeichenfarbe:
## - State != LOCKED          → tracking-Farbe (Hover)
## - State == LOCKED + HOSTILE  → rot   (Feind)
## - State == LOCKED + NEUTRAL  → gelb  (neutral / unbekannt)
## - State == LOCKED + FRIENDLY → grün  (Freund / gleiche Fraktion)
func _resolve_color() -> Color:
	if _state != State.LOCKED:
		return color_tracking
	match _disposition:
		Disposition.HOSTILE:  return color_locked
		Disposition.NEUTRAL:  return color_neutral
		Disposition.FRIENDLY: return color_friendly
	return color_locked
