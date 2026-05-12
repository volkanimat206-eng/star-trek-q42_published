# res://resources/cloak_data.gd
#
# Konfiguration des Cloaking-Systems pro Schiff. Eine .tres-Datei pro
# Schiffstyp anlegen (z.B. cloakdata_birdofprey.tres).
#
# Default-Werte sind balanciert für mittlere Schiffsklassen — anpassen für
# spezielle Lore-Touches (Romulan-Warbird = schneller Cloak-Cycle, Klingon
# = langsamer aber robuster, etc.).
#
# VISUAL-OVERRIDES (rim_color, displacement_strength):
#   Lass die Override-Felder leer (Sentinel-Werte) und das Schiff bekommt
#   automatisch die Farben aus FactionSystem.get_cloak_visuals() — also
#   kanonische Klingon/Romulan/Federation-Looks. Setze sie nur wenn ein
#   einzelnes Schiff abweichen soll (z.B. ein erbeuteter Romulan-Warbird
#   in klingonischer Hand → Romulan-Hülle aber Klingon-Cloak-Look).

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

# ── Faction Visibility ────────────────────────────────────────────────────────
@export_group("Faction Visibility")
## Sichtbarkeit für Verbündete der gleichen Fraktion (IFF-System).
## 0.0 = auch Kameraden sehen das Schiff nicht.
## 0.35 = leicht sichtbarer Rim-Schimmer (empfohlen — realistisch für IFF).
## 1.0 = Verbündete sehen das Schiff voll sichtbar.
@export_range(0.0, 1.0, 0.05) var ally_visibility: float = 0.35

# ── Visual Overrides (per-Schiff Sonderfälle) ─────────────────────────────────
@export_group("Visual Overrides (Optional)")
## Override für die Rim-Farbe des Cloak-Shaders. Sentinel: alpha=0.0 bedeutet
## "nicht gesetzt" → FactionSystem-Default wird genutzt. Setzen NUR wenn
## dieses Schiff eine andere Cloak-Farbe als seine Faction haben soll
## (z.B. erbeutete fremde Cloaking-Tech).
@export var rim_color_override: Color = Color(0.0, 0.0, 0.0, 0.0)

## Override für die Vertex-Displacement-Stärke während der Cloak-Transition.
## -1.0 = nicht gesetzt → FactionSystem-Default wird genutzt.
## 0.03–0.05 = Predator-subtil. >0.1 = sichtbares "Geist-Mesh".
@export var displacement_strength_override: float = -1.0
