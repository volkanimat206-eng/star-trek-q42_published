# res://resources/cloak_data.gd
#
# Konfiguration des Cloaking-Systems pro Schiff. Eine .tres-Datei pro
# Schiffstyp anlegen (z.B. cloakdata_birdofprey.tres).
#
# Default-Werte sind balanciert für mittlere Schiffsklassen — anpassen für
# spezielle Lore-Touches (Romulan-Warbird = schneller Cloak-Cycle, Klingon
# = langsamer aber robuster, etc.).

@tool
class_name CloakData
extends Resource

# ── Timing ────────────────────────────────────────────────────────────────────
@export_group("Timing")
## Sekunden fürs Eintauchen in die Tarnung (Mesh-Fade-Out + Layer-Off).
@export var fade_in_duration:  float = 1.5
## Sekunden für Auftauchen aus der Tarnung (etwas schneller als Eintauchen).
@export var fade_out_duration: float = 0.8
## Cooldown nach erzwungener Enttarnung (z.B. durch Waffen-Trigger). Während
## des Cooldowns kann nicht erneut getarnt werden — verhindert Cloak-Spam.
@export var emergency_cooldown: float = 5.0

# ── Detection ─────────────────────────────────────────────────────────────────
@export_group("Detection")
## Distanz in Welt-Units, ab der ein cloakedes Schiff für andere als
## Schimmer sichtbar wird. Star-Trek-typisch: subtile Verzerrung, kein
## klares Bild. Default 100m gibt dem Player ~2 Sekunden Reaktion bei
## anrückendem Klingon-BoP (max_speed 400 u/s).
@export_range(0.0, 500.0, 10.0) var detection_range: float = 100.0

# ── Visuell ───────────────────────────────────────────────────────────────────
@export_group("Visuell")
## Maximale Sichtbarkeit (Alpha) bei Detection-Range — innerhalb dieser
## Distanz wird zwischen 0.0 (komplett unsichtbar) und diesem Wert
## interpoliert. 0.25 = 25% Sichtbarkeit am Detection-Edge.
@export_range(0.0, 1.0, 0.05) var shimmer_max_alpha: float = 0.25
## Farbe des Schimmer-Effekts. Klassisch romulanisch grün-blau, klingonisch
## könnte rötlicher sein.
@export var shimmer_tint: Color = Color(0.4, 0.7, 1.0, 1.0)
