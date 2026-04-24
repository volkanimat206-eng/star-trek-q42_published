# res://resources/ship_data.gd
# Master-Resource für ein Schiff – fasst alle schiffsspezifischen Daten zusammen.
# Eine .tres-Datei pro Schiffsklasse anlegen (z.B. ship_sovereign.tres).
#
# LAYER-SYSTEM (universell – fraktionsunabhängig):
#   Layer 1  ship_hull    → CollisionLayer JEDER Schiffshülle
#   Layer 2  ship_shield  → CollisionLayer JEDES Schildes
#   Layer 3  projectile   → Torpedos, Minen
#   Layer 4  environment  → Asteroiden, Stationen, Trümmer
#   Layer 5  trigger_zone → Sensor-Bereiche, Spawn-Trigger
#
#   weapon_target_mask = ship_hull (1) | ship_shield (2) = 3  → für ALLE Schiffe gleich
#
# FRIENDLY FIRE & SELF-HIT werden NICHT durch Layer verhindert, sondern durch:
#   1. Self-Hit:    RID-Exclusion im Raycast (ShipController.get_own_rids())
#   2. Friendly Fire: FactionSystem.is_hostile() Check nach dem Raycast-Treffer
@tool
class_name ShipData
extends Resource

enum Faction {
	FEDERATION,   # Vereinte Föderation der Planeten
	KLINGON,      # Klingonisches Imperium
	ROMULAN,      # Romulanisches Sternenimperium
	CARDASSIAN,   # Cardassianische Union
	DOMINION,     # Dominion
	BORG,         # Borg-Kollektiv
	FERENGI,      # Ferengi-Allianz
	MAQUIS,       # Maquis
	NEUTRAL,      # Neutral / Unbekannt
}

@export_group("Schiff")
@export var ship_name: String  = "USS Unknown"
@export var registry:  String  = "NCC-00000"
@export var faction:   Faction = Faction.FEDERATION

## ─── Kollisions-Layer ────────────────────────────────────────────────────────
## ALLE Schiffe verwenden dieselben Layer (fraktionsunabhängig).
## Friendly Fire wird per FactionSystem im Code verhindert, nicht per Layer.
##
## hull_layer   = 1  (ship_hull)   – für ALLE Schiffe gleich, nie ändern
## shield_layer = 2  (ship_shield) – für ALLE Schiffe gleich, nie ändern
## weapon_target_mask = 3 (ship_hull | ship_shield) – für ALLE Schiffe gleich
@export_flags_3d_physics var hull_layer:         int = 1   # ship_hull
@export_flags_3d_physics var shield_layer:       int = 2   # ship_shield
@export_flags_3d_physics var weapon_target_mask: int = 3   # ship_hull | ship_shield

@export_group("Stats & Bewegung")
## Schiffsspezifische Bewegungs- und Handlingwerte.
@export var stats: ShipStats
@export var shockwave_data: ShockwaveData

@export_group("Schild")
## Alle Schildwerte inkl. Shader-Parameter. ShieldData ist die einzige Quelle.
@export var shield: ShieldData

@export_group("Hülle")
@export var hull: HullData

@export_group("Kampfverhalten")
## Fraktionsspezifisches KI-Verhalten. Leer lassen = AIController-Defaults verwenden.
## Ressource anlegen: Rechtsklick FileSystem → New Resource → CombatBehavior
@export var combat_behavior: CombatBehavior

@export_group("Waffen")
## BeamWeaponData für alle Phaser/Disruptor-Mounts dieses Schiffes.
## Leer lassen = Mount-eigene weapon_data behalten.
@export var beam_weapon_data: BeamWeaponData
## TorpedoData für alle TorpedoMount3D-Nodes dieses Schiffes.
## Leer lassen = Mount-eigene torpedo_data behalten.
@export var torpedo_data: TorpedoData

@export_group("Visuell")
## Das eigentliche 3D-Scene-File des Schiffs (wird vom PlayerController instanziiert).
@export_file("*.tscn") var ship_scene_path: String = ""
