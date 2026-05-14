# res://scripts/effects/debris_launch_params.gd
#
# Konfigurationsresource für ShipDebrisBurst.launch_at().
# Lege eine .tres-Datei pro Schiffsklasse an (oder nutze den Default).
#
# NEU: ship_origin_ws (World-Space) wird von launch_at() automatisch gesetzt —
# nicht manuell befüllen. Es ist ein internes Feld für die Impulsberechnung.
# ─────────────────────────────────────────────────────────────────────────────

class_name DebrisLaunchParams
extends Resource

# ── Physik ───────────────────────────────────────────────────────────────────

## Minimale Explosionskraft pro Fragment (in Newton, sofort als Impuls).
@export_range(0.0, 5000.0) var min_force:     float = 80.0
## Maximale Explosionskraft pro Fragment.
@export_range(0.0, 5000.0) var max_force:     float = 200.0

## Minimales Rotationsmoment (Tumble) pro Fragment.
@export_range(0.0, 500.0)  var min_torque:    float = 5.0
## Maximales Rotationsmoment.
@export_range(0.0, 500.0)  var max_torque:    float = 30.0

## Schwerkraft-Skalierung. 0.0 = schwerelos (Weltraum-Standard).
@export_range(0.0, 1.0)    var gravity_scale: float = 0.0

## Lineares Dämpfung (bremst Translation im Vakuum sanft ab).
@export_range(0.0, 5.0)    var linear_damp:   float = 0.05

## Angulare Dämpfung (bremst Rotation im Vakuum sanft ab).
@export_range(0.0, 5.0)    var angular_damp:  float = 0.05

# ── Kollision ────────────────────────────────────────────────────────────────

## Wenn true: ConvexHull-Kollision aus Mesh-Geometrie generieren.
## Kostet etwas Performance beim Spawn – für kleine Szenen OK.
@export var add_collision: bool = false

# ── Lebenszeit / Fade ────────────────────────────────────────────────────────

## Sekunden bis ein Fragment automatisch entfernt wird. 0 = kein Auto-Remove.
@export_range(0.0, 60.0)   var lifetime:      float = 8.0

## Sekunden des Fade-outs am Ende der Lifetime. 0 = sofortiges Entfernen.
@export_range(0.0, 10.0)   var fade_duration: float = 2.0

# ── Internes Feld (wird von launch_at() befüllt, nicht im Inspector) ─────────

## Weltposition des explodierenden Schiffs — Quelle der Impulse.
## Wird automatisch von ShipDebrisBurst.launch_at() gesetzt.
## Nicht manuell im Inspector setzen.
var ship_origin_ws:  Vector3 = Vector3.ZERO
var _ship_origin_set: bool   = false


## Setzt den Schiffsursprung für die Impulsberechnung.
## Wird intern von ShipDebrisBurst.launch_at() aufgerufen.
func set_ship_origin(origin: Vector3) -> void:
	ship_origin_ws   = origin
	_ship_origin_set = true
