# res://resources/combat_behavior.gd
# Fraktionsspezifisches Kampfverhalten als Resource.
# Eine .tres-Datei pro Fraktion/Schiffsklasse anlegen.
#
# SETUP:
#   1. Rechtsklick im FileSystem → New Resource → CombatBehavior
#   2. In ShipData.combat_behavior zuweisen
#   3. Parameter im Inspector tweaken – kein Code nötig
#
# VORGEFERTIGTE EMPFEHLUNGEN:
#   Klingon     → prefer_head_on=true,  aggression=0.9, orbit_speed_deg=35, reposition_interval=4
#   Romulan     → aggressive_vertical=true, aggression=0.6, orbit_speed_deg=20, reposition_interval=5
#   Borg        → long_approach=true,   aggression=1.0, orbit_speed_deg=8,  reposition_interval=20
#   Ferengi     → aggression=0.2,       orbit_speed_deg=40, reposition_interval=3  (feige, weicht aus)
#   Federation  → ausgewogen,           aggression=0.5, orbit_speed_deg=22, reposition_interval=8

@tool
class_name CombatBehavior
extends Resource

@export_group("Identifikation")
## Anzeigename – erscheint im Debug-Overlay
@export var behavior_name: String = "Standard"

@export_group("Orbit & Manöver")
## Grad pro Sekunde auf der Kreisbahn. Höher = aggressiver/wendiger.
@export_range(5.0, 80.0) var orbit_speed_deg:     float = 22.0
## Orbit-Radius als Faktor × fire_range (0.5 = dicht dran, 1.2 = auf Distanz)
@export_range(0.3, 1.5)  var orbit_radius_factor:  float = 0.8
## Höhenamplitude im Orbit in Units. 0 = flach, 30 = sehr dynamisch.
@export_range(0.0, 50.0) var combat_height_range:  float = 18.0
## Basiszeit zwischen Reposition-Manövern in Sekunden (± 50% Zufall)
@export_range(2.0, 30.0) var reposition_interval:  float = 8.0

@export_group("Aggression & Verhalten")
## 0 = feige (hält maximalen Abstand), 1 = Berserker (so nah wie möglich)
## Beeinflusst orbit_radius_factor zur Laufzeit
@export_range(0.0, 1.0)  var aggression:            float = 0.5
## Klingon-Stil: bevorzugt Frontalangriff, wechselt selten in ORBIT
@export var prefer_head_on:        bool = false
## Romulan-Stil: wechselt Y-Höhe sehr aggressiv, schwer zu verfolgen
@export var aggressive_vertical:   bool = false
## Borg-Stil: sehr langer APPROACH, analysiert erst (kein Orbit in den ersten Sekunden)
@export var long_approach:         bool = false
## Ferengi-Stil: bei niedrigen Schilden sofort REPOSITION (Fluchtreflex)
@export var cowardly_retreat:      bool = false

@export_group("Aggro (Zielwechsel)")
## Wie viel Schaden der Spieler anrichten muss damit dieser NPC sein aktuelles
## Ziel wechselt. Niedriger = leicht zu pullen. 0 = immer nächstes Ziel wählen.
@export_range(0.0, 5000.0) var aggro_pull_threshold: float = 200.0
## Faktor mit dem eigener Schaden auf die Threat-Liste gewichtet wird.
## 1.0 = normal, 2.0 = doppelt so leicht zu pullen
@export_range(0.5, 5.0)    var aggro_damage_factor:  float = 1.0
## Sekunden in denen der NPC das neue (Spieler-)Ziel mindestens behält,
## bevor er zurückwechseln darf (verhindert Ziel-Ping-Pong)
@export_range(1.0, 30.0)   var aggro_lock_duration:  float = 5.0
