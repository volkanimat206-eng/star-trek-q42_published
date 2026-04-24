# res://resources/shield_data.gd
# Einzige Datenquelle für alle Schildeigenschaften eines Schiffstyps.
# Eine .tres-Datei pro Schiffsklasse anlegen (z.B. shield_sovereign.tres).
# Alle Shader-Feldnamen entsprechen exakt den Uniform-Namen in shield.gdshader.
#
# ─────────────────────────────────────────────────────────────────────────────
# VIER-ZONEN-SCHILD (AAA-Pattern):
#
# max_strength ist die GESAMT-HP Kapazität. Intern wird in 4 gleiche Zonen
# aufgeteilt (25% je Zone) → Balance bleibt identisch zu Vor-Zonen-Logik,
# nur räumlich verteilt.
#
# current_strength (alt) bleibt als Legacy-Feld erhalten für Save-Games und
# ist immer der SUMMIERTE Wert aller Zonen. Pro-Zone-Werte liegen in
# zone_strengths[0..3].
#
# Bleed-Through: ab BLEED_THRESHOLD % einer Zone leckt BLEED_FACTOR % des
# Schadens direkt an die Hülle durch – auch wenn die Zone noch Punkte hat.
# ─────────────────────────────────────────────────────────────────────────────
@tool
class_name ShieldData
extends Resource

# ── Stärke ────────────────────────────────────────────────────────────────────
@export_group("Stärke")
## GESAMT-Kapazität über alle 4 Zonen. Pro Zone = max_strength / 4.
@export var max_strength:     float = 500.0
## Legacy-Feld: aktuelle Gesamt-HP (Summe aller Zonen). Wird automatisch
## aus zone_strengths summiert. Bei Edit im Inspector/Save-Load: gleichmäßig
## auf alle Zonen verteilt. ACHTUNG: Interne Updates aus
## _recompute_current_from_zones() dürfen NICHT die Verteilung auslösen,
## sonst werden gezielte Zone-Treffer gleichmäßig auf alle Zonen verteilt.
@export var current_strength: float = 500.0:
	set(value):
		current_strength = clampf(value, 0.0, max_strength)
		# Nur extern ausgelöste Änderungen (Inspector, Save-Load, direkte
		# Code-Zuweisung) verteilen neu. Interne Summations-Updates skippen.
		if not _updating_from_zones:
			_distribute_current_to_zones()

# ── Regeneration ──────────────────────────────────────────────────────────────
@export_group("Regeneration")
## HP pro Sekunde die regeneriert werden. Wird auf alle Zonen gleichmäßig
## verteilt (recharge_rate / 4 pro Zone und Sekunde).
@export var recharge_rate:  float = 15.0
## Sekunden nach einem Treffer bis die Regeneration einsetzt.
## Blockiert ALLE Zonen (shared pool – einfachste Logik).
@export var recharge_delay: float =  3.0
## Sekunden nach einem vollständigen Schildkollaps bis der Schild
## überhaupt wieder hochfahren darf.
@export var reactivation_delay: float = 8.0

# ── Bleed-Through ─────────────────────────────────────────────────────────────
@export_group("Bleed-Through")
## Wenn eine Zone unter diesen Prozentwert fällt (0.0–1.0), leckt ein Teil
## des Schadens direkt an die Hülle durch. Klassischer AAA-Wert: 0.2 (=20%).
@export_range(0.0, 1.0, 0.05) var bleed_threshold: float = 0.2
## Prozentualer Anteil des Schadens der bei aktivem Bleed durchleckt.
## Klassischer AAA-Wert: 0.2 (=20% des Schadens geht an die Hülle).
@export_range(0.0, 1.0, 0.05) var bleed_factor: float = 0.2

# ── Visuell – Farben ──────────────────────────────────────────────────────────
@export_group("Visuell - Farben")
@export var shield_color: Color = Color(0.0, 0.752, 0.18, 0.35)
@export var impact_color: Color = Color(1.0, 0.55, 0.0, 1.0)

# ── Visuell – Shader ──────────────────────────────────────────────────────────
@export_group("Visuell - Shader")
@export var rim_power:         float = 3.0
@export var hit_glow_duration: float = 2.0
@export var impact_radius:     float = 0.45
@export var impact_ring_width: float = 0.15
@export var impact_fade_time:  float = 1.2


# ─────────────────────────────────────────────────────────────────────────────
# INTERN – Zonen-State
# ─────────────────────────────────────────────────────────────────────────────

## Pro-Zone-HP. Index entspricht ShieldZone.Zone (FRONT/REAR/PORT/STAR).
## NICHT @export – wird zur Laufzeit aus max_strength initialisiert und
## läuft im Instance-lokalen Duplikat der ShieldData (siehe ShipController).
var zone_strengths: Array[float] = [0.0, 0.0, 0.0, 0.0]

## Rekursions-Guard: verhindert dass der current_strength-Setter die Zonen
## neu verteilt, wenn wir selbst gerade current_strength aus den Zonen
## berechnen. OHNE DIESES FLAG: jeder Zone-Schaden würde über den Setter
## wieder gleichmäßig auf alle 4 Zonen verteilt – Bug wo alle Zonen
## synchron sinken statt nur die getroffene.
var _updating_from_zones: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# INIT
# ─────────────────────────────────────────────────────────────────────────────

func _init() -> void:
	# Zones initial auf Vollstärke setzen. _distribute_current_to_zones()
	# würde das bei der Reihenfolge des Property-Setzens zu früh aufrufen,
	# daher expliziter Reset hier.
	_reset_zones_full()


## Verteilt den Gesamt-current_strength gleichmäßig auf alle Zonen.
## Aufgerufen vom current_strength-Setter (Inspector-Edits, Save-Load).
func _distribute_current_to_zones() -> void:
	if zone_strengths.size() != ShieldZone.COUNT:
		zone_strengths.resize(ShieldZone.COUNT)
	var per_zone: float = current_strength / float(ShieldZone.COUNT)
	for i in range(ShieldZone.COUNT):
		zone_strengths[i] = clampf(per_zone, 0.0, zone_max())


func _reset_zones_full() -> void:
	if zone_strengths.size() != ShieldZone.COUNT:
		zone_strengths.resize(ShieldZone.COUNT)
	var per_zone: float = zone_max()
	for i in range(ShieldZone.COUNT):
		zone_strengths[i] = per_zone
	_recompute_current_from_zones()


func _recompute_current_from_zones() -> void:
	var sum: float = 0.0
	for hp in zone_strengths:
		sum += hp
	# Guard aktivieren damit der Setter NICHT zurück _distribute_current_to_zones()
	# aufruft – das würde den soeben gezielten Zone-Schaden wieder auf alle
	# Zonen gleichmäßig verteilen (die "alle Zonen sinken synchron"-Bug).
	_updating_from_zones = true
	current_strength = sum
	_updating_from_zones = false


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API – Zonen
# ─────────────────────────────────────────────────────────────────────────────

## Maximale HP pro Zone (= max_strength / 4).
func zone_max() -> float:
	return max_strength / float(ShieldZone.COUNT)


## HP einer bestimmten Zone (0..3).
func zone_hp(zone: int) -> float:
	if zone < 0 or zone >= ShieldZone.COUNT:
		return 0.0
	return zone_strengths[zone]


## Integrität einer Zone (0.0 bis 1.0).
func zone_integrity(zone: int) -> float:
	var zmax: float = zone_max()
	if zmax <= 0.0 or zone < 0 or zone >= ShieldZone.COUNT:
		return 0.0
	return clampf(zone_strengths[zone] / zmax, 0.0, 1.0)


## true wenn die Zone unter dem Bleed-Schwellwert ist.
func zone_is_bleeding(zone: int) -> bool:
	return zone_integrity(zone) < bleed_threshold and zone_strengths[zone] > 0.0


## Schaden auf eine spezifische Zone. Gibt Overflow zurück (geht an Hülle).
## Berücksichtigt Bleed-Through: wenn Zone unter Schwelle ist, geht
## bleed_factor × damage zusätzlich an die Hülle.
##
## Return: {overflow: float, bleed: float}
##   overflow = Schaden der über die Zone hinausgeht (Zone wird 0)
##   bleed    = Schaden der durch Bleed-Through durchleckt (Zone hat noch HP)
func take_damage_on_zone(zone: int, amount: float) -> Dictionary:
	if zone < 0 or zone >= ShieldZone.COUNT:
		return {"overflow": amount, "bleed": 0.0}

	var hp_before: float = zone_strengths[zone]

	# Bleed-Through wird VOR dem Schaden berechnet, basierend auf aktuellem HP-Stand.
	# So trifft der Bleed-Factor auch den allerersten Schuss der eine Zone
	# unter die Schwelle drückt.
	var bleed: float = 0.0
	if zone_is_bleeding(zone):
		bleed = amount * bleed_factor

	# Schaden auf die Zone anwenden
	var new_hp: float = hp_before - amount
	var overflow: float = 0.0
	if new_hp < 0.0:
		overflow = absf(new_hp)
		new_hp = 0.0
	zone_strengths[zone] = new_hp
	_recompute_current_from_zones()

	return {"overflow": overflow, "bleed": bleed}


## Heilt eine Zone um amount HP (bis zone_max).
func heal_zone(zone: int, amount: float) -> void:
	if zone < 0 or zone >= ShieldZone.COUNT:
		return
	zone_strengths[zone] = minf(zone_strengths[zone] + amount, zone_max())
	_recompute_current_from_zones()


## Heilt alle Zonen gleichmäßig. Wird vom ShieldSystem im Regen-Loop aufgerufen.
## amount = Gesamt-Heal für alle Zonen zusammen (wird durch 4 geteilt).
func heal_all_zones(amount: float) -> void:
	var per_zone: float = amount / float(ShieldZone.COUNT)
	for i in range(ShieldZone.COUNT):
		zone_strengths[i] = minf(zone_strengths[i] + per_zone, zone_max())
	_recompute_current_from_zones()


## Index der Zone mit niedrigstem HP-Anteil (für Redistribute/AI-Taktik).
func weakest_zone() -> int:
	var worst_idx: int = 0
	var worst_integrity: float = INF
	for i in range(ShieldZone.COUNT):
		var integ: float = zone_integrity(i)
		if integ < worst_integrity:
			worst_integrity = integ
			worst_idx = i
	return worst_idx


## Integrität aller Zonen als Array (für Shader-Uniform).
func zone_integrities() -> Array[float]:
	var result: Array[float] = [0.0, 0.0, 0.0, 0.0]
	for i in range(ShieldZone.COUNT):
		result[i] = zone_integrity(i)
	return result


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API – Legacy (bleibt rückwärtskompatibel)
# ─────────────────────────────────────────────────────────────────────────────

## Gibt die Schildintegrität (gemittelt über alle Zonen) zurück.
## Entspricht der alten API und wird weiter für die HUD-Gesamtanzeige genutzt.
func get_integrity() -> float:
	if max_strength <= 0.0:
		return 0.0
	return clampf(current_strength / max_strength, 0.0, 1.0)


## Legacy: zieht Schaden gleichmäßig von allen Zonen ab (keine Zone-Info).
## ShieldSystem.receive_hit_ex sollte take_damage_on_zone() nutzen.
## Bleibt für Aufrufer erhalten die keinen impact_point haben.
func take_damage(amount: float) -> float:
	var per_zone: float = amount / float(ShieldZone.COUNT)
	var total_overflow: float = 0.0
	for i in range(ShieldZone.COUNT):
		var r: Dictionary = take_damage_on_zone(i, per_zone)
		total_overflow += r["overflow"]
	return total_overflow


## Heilt alle Zonen – Alias für heal_all_zones für Rückwärtskompatibilität.
func heal(amount: float) -> void:
	heal_all_zones(amount)


## Setzt alle Zonen auf Maximalstärke zurück.
func reset() -> void:
	_reset_zones_full()


func is_active() -> bool:
	return current_strength > 0.0


func is_full() -> bool:
	return current_strength >= max_strength - 0.01   # Float-Toleranz
