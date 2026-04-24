# res://scripts/shield_zone.gd
#
# Enum und Helper für das Vier-Zonen-Schildsystem.
#
# KOORDINATENSYSTEM:
#   Godot: -Z = forward (Schiffs-Front)
#   Das Schiff blickt in -Z seines eigenen global_basis.
#
# ZONEN-ZUORDNUNG (Treffer aus Sicht des getroffenen Schiffs):
#   FRONT  = Treffer aus dem vorderen Kegel (dot(forward, to_impact) > 0.5)
#   REAR   = Treffer aus dem hinteren Kegel (dot(forward, to_impact) < -0.5)
#   PORT   = Treffer aus links  (seitlich, side_dot < 0)
#   STAR   = Treffer aus rechts (seitlich, side_dot > 0)
#
# Der 0.5-Threshold entspricht 60° Öffnungswinkel (cos(60°) ≈ 0.5)
# für FRONT/REAR. Der Rest (120° links + 120° rechts) teilt sich auf PORT/STAR.

class_name ShieldZone
extends RefCounted


enum Zone {
	FRONT = 0,
	REAR  = 1,
	PORT  = 2,   # links
	STAR  = 3    # rechts (starboard)
}

## Anzahl Zonen – nicht hardcoden, über diese Konstante iterieren.
const COUNT: int = 4

## Schwellwert für die Front/Rear-Kegel. 0.5 = 60° Halböffnung.
## Größere Werte = schmalerer Front-/Rear-Kegel, breitere Seiten.
## Kleinere Werte = breitere Front/Rear, schmalere Seiten.
const FRONT_REAR_THRESHOLD: float = 0.5


## Zone-Namen für Debug-Output und UI.
static func name_of(zone: int) -> String:
	match zone:
		Zone.FRONT: return "FRONT"
		Zone.REAR:  return "REAR"
		Zone.PORT:  return "PORT"
		Zone.STAR:  return "STAR"
	return "?"


## Kurz-Label für HUD (3 Zeichen).
static func label_of(zone: int) -> String:
	match zone:
		Zone.FRONT: return "FWD"
		Zone.REAR:  return "AFT"
		Zone.PORT:  return "PRT"
		Zone.STAR:  return "STB"
	return "?"


## Kernfunktion: bestimmt die getroffene Zone aus Schiff-Transform und
## Weltraum-Impact-Position.
##
## ship_xform: global_transform des Schiffs (für Orientierung).
## ship_pos:   global_position des Schiffs (Ausgangspunkt der Richtung).
## impact_pos: Weltraum-Koordinate des Einschlags.
## invert_forward: bei Schiffen mit Blender-Import-Rotation (siehe
##   ShipController.invert_model_forward) ist die Schiffs-Front in +Z
##   statt -Z. Der Wert stammt aus ShipController.effective_forward.
static func get_zone_for_impact(
		ship_xform: Transform3D,
		ship_pos: Vector3,
		impact_pos: Vector3,
		invert_forward: bool = false
	) -> int:
	# Richtung Schiff → Einschlag, normalisiert
	var to_impact: Vector3 = (impact_pos - ship_pos)
	if to_impact.length_squared() < 0.0001:
		return Zone.FRONT   # degenerierter Fall: Impact exakt im Schiff
	to_impact = to_impact.normalized()

	# Schiffs-Vektoren
	var forward: Vector3 = -ship_xform.basis.z
	if invert_forward:
		forward = ship_xform.basis.z
	var right: Vector3   = ship_xform.basis.x
	forward = forward.normalized()
	right   = right.normalized()

	# Front/Rear-Kegel via Dot-Produkt mit Forward
	var fwd_dot: float = forward.dot(to_impact)
	if fwd_dot > FRONT_REAR_THRESHOLD:
		return Zone.FRONT
	if fwd_dot < -FRONT_REAR_THRESHOLD:
		return Zone.REAR

	# Seitliche Treffer: Port vs Starboard via Dot mit Right
	var side_dot: float = right.dot(to_impact)
	if side_dot > 0.0:
		return Zone.STAR
	return Zone.PORT


## Für den Shader: Gibt die Zone-Richtung in LOKALEN Schiff-Koordinaten.
## Wird genutzt um Zone-Overlays auf dem Shield-Mesh zu zeichnen.
static func local_direction_of(zone: int) -> Vector3:
	match zone:
		Zone.FRONT: return Vector3(0, 0, -1)
		Zone.REAR:  return Vector3(0, 0,  1)
		Zone.PORT:  return Vector3(-1, 0, 0)
		Zone.STAR:  return Vector3( 1, 0, 0)
	return Vector3.ZERO
