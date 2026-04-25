# Architektur

Diese Datei beschreibt die Architektur und das Zusammenspiel der Systeme. Sie ist primär für die Wartung und Erweiterung gedacht — wenn du in sechs Monaten zurückkommst, oder wenn jemand (oder Claude) den Code verstehen will.

## Engine-Setup

- **Godot:** 4.5 stable, Forward+/Vulkan
- **GDScript:** strict typing aktiv, alle Variablen explizit typisiert
- **Perspektive:** 2.5D isometrisch, Top-Down-Camera mit fester Y-Höhe
- **Koordinaten:** Godot-Standard, -Z = Forward (manche Models haben Blender-Import-Rotation, kompensiert via `invert_model_forward`)

## Globale Schichten (Autoloads)

Die Reihenfolge der Autoloads in `project.godot` ist verbindlich:

```
ReputationSystem      → Speichert Player-Standing zu Fraktionen
FactionSystem         → Statische Fraktions-Pair-Hostility (KLI↔FED etc.)
RelationshipResolver  → Three-Layer-Policy: Aggro + Reputation + Baseline
DebugManager          → Flag-basiertes Debug-Output-Routing
AudioManager          → Bus-Konfiguration, Settings-Persistenz
PhaserAudioPool       → Polyphone Audio-Wiedergabe für Beam-Waffen
```

**Warum diese Reihenfolge:** Der Resolver fragt FactionSystem für die Baseline ab, FactionSystem ruft den Resolver für Aggro-Override. Beide sind voneinander abhängig — die Reihenfolge stellt sicher dass beide existieren bevor jemand sie nutzt.

## Domänen-Architektur

```
                                 Player Input
                                      │
                                      ▼
                              PlayerController ─────► InputComponent
                                      │
                                      ▼
                          ╔═══════════════════════╗
                          ║   ShipController      ║◄─── ShipData (.tres)
                          ║                       ║
                          ║  movement_comp ──────►║──► MovementComponent
                          ║  shield_system ──────►║──► ShieldSystem ──► ShieldData
                          ║  weapon_mounts[] ────►║──► WeaponMount[] ─► BeamWeapon3D
                          ║  targeting_system ───►║──► TargetingSystem
                          ║  hull_data           ║
                          ╚═══════════════════════╝
                                      ▲
                                      │
                              AIController (für NPCs)
                                      │
                                      ▼
                         RelationshipResolver.are_hostile()
                                      │
                            ┌─────────┴─────────┐
                            ▼                   ▼
                    Aggro-Layer (30s)    FactionSystem.is_faction_pair_hostile()
                    + Ally-Propagation
                            ▲
                            │
                ShipController._fire_weapons_of_type()
                  │  notify_attack(self, victim)
                  ▼
              Resolver setzt Aggro:
                victim → attacker
                allies(victim) → attacker
```

## Schiff-Architektur

Ein Schiff ist eine Komposition aus austauschbaren Subsystemen. Der `ShipController` ist die Spinne im Netz und hält Referenzen auf alle anderen Systeme.

**Hierarchie einer Schiffs-Scene:**

```
CharacterBody3D (Player oder AIController)
└── ShipController          # Coordinator, hält ship_data + Subsystem-Refs
    ├── Model               # Visueller Mesh-Tree
    │   ├── Hull-Meshes
    │   ├── ShieldMesh      # Eigenes Mesh, eigener Shader
    │   └── Bones / Bones-Anim
    ├── HullCollision       # StaticBody3D auf Layer 1
    ├── HullImpactReceiver  # Decal-Pool für Impact-Effekte
    ├── MovementComponent   # Speed/Acceleration/Drift-Logik
    ├── ShieldSystem        # Vier-Zonen, Regen, Shader-Steuerung
    ├── TargetingSystem     # Lock/Multi-Lock, Mode-Switching
    ├── WeaponMount[]       # Pro Mount-Position ein Node
    └── DamageVisualizer    # Hüllen-Schadens-Decals
```

Bei NPCs wird zusätzlich oben ein `AIController` als Wrapper drüber gesetzt, der das gleiche `CharacterBody3D` ist und einen `Radar`-Area3D-Child hat.

## Daten-Architektur

Resource-basiert. Jede Schiffsklasse hat eine `.tres`-Datei die alle Stats und Sub-Resources zusammenhält.

**Beispiel `shipdata_sovereign.tres`:**
```
ShipData
├── faction: ShipData.Faction.FEDERATION
├── ship_name: "Sovereign"
├── max_speed: 400
├── hull: HullData (.tres referenziert)
│   └── max_hp, current_hp
├── shield: ShieldData (.tres referenziert)
│   ├── max_strength, recharge_rate, recharge_delay
│   ├── reactivation_delay
│   ├── bleed_threshold, bleed_factor
│   └── Visuals: shield_color, impact_color, rim_power, ...
├── beam_weapon_data: WeaponBeamData (.tres)
└── torpedo_data: WeaponTorpedoData (.tres)
```

**Wichtig:** ShieldData und HullData werden beim Spawn dupliziert (`ship_data.shield.duplicate()`). Andernfalls würden alle Instanzen desselben Schiffstyps sich dieselben Strength-Felder teilen — klassischer shared-Resource-Bug.

## Schildsystem im Detail

**Zonen-Modell:** 4× 25% Aufteilung. `max_strength = 20000` heißt 5000 HP pro Zone. Die Trennung passiert in `shield_data.gd` über `zone_strengths: Array[float]` mit Index 0–3 nach `ShieldZone.Zone` Enum.

**Treffer-Routing:**
1. `BeamWeapon3D` raycastet, trifft `ShieldMesh` (Layer 2)
2. `ShipController.receive_damage()` → `ShieldSystem.receive_hit_ex(damage, impact_pos, ...)`
3. `ShieldZone.get_zone_for_impact()` berechnet Zone aus Schiff-Transform und Impact-Position
4. `ShieldData.take_damage_on_zone()` zieht Schaden ab, prüft Bleed-Threshold
5. Overflow + Bleed → an Hülle zurückgegeben

**Bleed-Through:** Wenn Zone-HP unter `bleed_threshold` (Default 20%) fällt, leckt `bleed_factor × damage` (Default 20%) zur Hülle durch — auch wenn die Zone noch HP hat.

**Regeneration:** Shared Pool. Jeder Treffer setzt `_recharge_timer` zurück; nach `recharge_delay` Sekunden ohne Treffer regeneriert `recharge_rate` HP/s gleichmäßig auf alle vier Zonen. Bei Komplett-Kollaps zusätzlich `reactivation_delay` als Sperre.

**Rekursions-Guard:** `current_strength` ist als Legacy-Feld erhalten und summiert sich aus den Zonen. Der Setter prüft `_updating_from_zones`-Flag um zu verhindern dass Zone-Updates über die Summe wieder als gleichmäßige Verteilung zurückfallen.

## Combat-Resolution-Pipeline

Wenn jemand schießt, läuft folgende Kette ab:

```
WeaponMount.fire_at(target_pos, target_node)
   │
   ├── _check_firing_constraints(target)
   │     ├── Range-Check (arc_radius)
   │     ├── Vertical-Check (DORSAL/VENTRAL)
   │     └── BeamWeapon3D.is_target_in_arc()  ← Shape-aware Arc-Check
   │
   └── BeamWeapon3D fire / Raycast
          │
          ├── Hit Shield → ShieldSystem.receive_hit_ex()
          │      └── Zone-Routing + Bleed
          └── Hit Hull → HullImpactReceiver.add_decal()
                    └── DamageVisualizer (Feuer/Rauch ab Hull-%)

ShipController._fire_weapons_of_type() (parallel):
   └── RelationshipResolver.notify_attack(self, victim)
          ├── add_aggro(victim → attacker)         (30s)
          └── Ally-Scan (gleiche Fraktion, 500m)
                └── add_aggro(ally → attacker) für jeden gefundenen
```

## Reputation/Faction-Resolver-Logik

`RelationshipResolver.are_hostile(observer, target)` ist die einzige Entscheidungsfunktion. Drei Ebenen, in dieser Reihenfolge:

```
1. AGGRO-OVERRIDE
   Hat observer aktive Aggro auf target (oder umgekehrt)?
   → JA: HOSTILE  (Schluss)

2. REPUTATION (nur wenn Player beteiligt)
   Hat Player Reputation ≤ -50 zur target-Fraktion (target ist Player)?
   Hat Player Reputation ≤ -50 zur observer-Fraktion (observer ist Player)?
   → JA: HOSTILE  (Schluss)
   Hat Player Reputation ≥ +50?
   → JA: FRIENDLY  (überschreibt Baseline)  (Schluss)

3. BASELINE
   FactionSystem.is_faction_pair_hostile(observer.faction, target.faction)
   → JA / NEIN
```

Das `FactionSystem.are_hostile()` ist die Legacy-API, die unter der Haube den Resolver aufruft. So bleiben alte Call-Sites kompatibel.

## AI-Architektur

Der `AIController` ist ein periodischer Scanner mit State-Machine.

**States:**
- `PATROL` — Random-Movement um Spawnpunkt, scannt nach Feinden
- `COMBAT` — Verfolgt und beschießt ein Target

**Scan-Logik (alle ~2 Sekunden):**
1. Physics-Query auf Radar-Area3D-Body-List
2. Fallback: Group-Scan über alle "ships"-Mitglieder im Detection-Radius
3. Pro Kandidat: `_is_hostile_to_me()` → delegiert an `RelationshipResolver.are_hostile(self, candidate)`
4. Wenn HOSTILE und im Radius → `_enter_combat(candidate)`

**Bug-Historie:** Vor dem Resolver-Refactor hatte der AIController eine eigene Hostile-Prüfung mit Reputation-Logik die den Aggro-Layer komplett umging. Das wurde gefixt durch komplette Delegation an den Resolver, mit Fallback auf alte Logik nur wenn Resolver-Autoload fehlt.

## Targeting-System

Folgt dem AAA-Pattern „Information frei, Aktionen verantwortungsvoll":

**Single-Lock:** Funktioniert auf jedes Schiff in Reichweite, egal ob feindlich. Du kannst Freunde anvisieren um ihren Status zu sehen.

**Multi-Lock:** Wird nur mit feindlichen Targets initiiert. Live-Re-Evaluation prunet die Liste — wenn ein Multi-Lock-Target durch Reputation-Änderung neutral wird, fliegt es raus.

**Auto-Fire:** Filtert Nicht-Feinde silent raus. Manueller Schuss bleibt ungefiltert — bewusste Ruf-Konsequenzen sind ein Feature, kein Bug.

**Reticle-Farben:** Reagieren live auf `RelationshipResolver.are_hostile()` — HOSTILE rot, FRIENDLY grün, NEUTRAL gelb.

## Debug-Tooling

Drei Schichten, alle gleichzeitig nutzbar:

**1. DebugManager-Flags** (granulares Console-Logging):

| Flag | Zeigt |
|---|---|
| `ai.resolver` | Resolver-Entscheidungen, Aggro-Adds, Notify-Attack |
| `ai.faction_hostile` | FactionSystem.are_hostile-Aufrufe |
| `ai.faction_lookup` | Faction-of-Node-Lookups |
| `weapons.arc_check` | Shape-aware Arc-Berechnung pro Frame |
| `weapons.projectile_path` | Torpedo-Flugbahn |
| `vfx.*` | Diverse VFX-Sub-Flags |

**2. Debug-Overlay (F11):**
- Player-Widget: Schiff, Fraktion, Speed, State, Hull/Shield-Total, Vier-Zonen-Anzeige
- Target-Widgets: gleiche Info pro gelocktem Ziel, Primary-Highlight
- Bleed-Zonen werden rot mit ⚠ markiert

**3. Debug-Control-Panel (F12):**
- NPC-Spawner mit Position-Override
- Faction-Matrix (klickbar, persistiert)
- Reputation-Slider (-100/-25/-10/+10/+25/Reset)
- Resolver-Dump-Button (zeigt alle aktiven Aggro-Einträge)
- Clear-Aggro-Button

## Bekannte Konventionen / Gotchas

**Material-Sharing:** Material-Overrides müssen pro Instanz dupliziert werden. Sonst teilen sich alle Schiffe gleichen Typs ein Material → eine Farbänderung propagiert global. Gilt für Shield-Mesh, Radar-Visualizer, und alles andere mit `material_override`.

**Resource-Sharing:** Gleicher Bug auf Resource-Ebene. `HullData` und `ShieldData` werden beim Spawn dupliziert. Wenn du neue stateful Resources hinzufügst (z.B. später `CloakData`), folge demselben Pattern.

**Forward-Vektor-Konvention:** Godot ist -Z forward. Manche Blender-Imports sind +Z forward → `ShipController.invert_model_forward = true` setzen. Wird vom ShieldSystem für Zone-Berechnung und vom WeaponMount für Arc-Check ausgewertet.

**Scene-Autoload vs Script-Autoload:** Wenn ein Autoload Inspector-Felder (`@export`) braucht, muss es Scene-Autoload sein (eine `.tscn` mit Script + Node-Root). Script-only-Autoloads können keine Inspector-Werte haben. Beispiel: FactionSystem ist Scene-Autoload für die `config: FactionConfig`-Resource.

**Class-Name-Reload:** Bei Änderung von `class_name`-Definitionen muss Godot komplett neu gestartet werden (nicht nur F5). Hot-Reload erfasst das nicht zuverlässig.

## Erweiterungen die geplant sind

Siehe `PROJECT_SUMMARY.md` für aktuellen Status. Architektur-Vorbereitung ist da für:

- **Cloaking:** Neuer `CloakSystem` als ShipController-Subsystem analog zu ShieldSystem. Energie-Drain via MovementComponent oder eigener `EnergyComponent`.
- **HUD (final):** Eigene `HudController`-Autoload-Scene oder Inline im PlayerController. Datenfluss via existierende Signale (`shield_hit`, `weapons_fired`, etc.).
- **AI-Taktik:** AIController nutzt `ship.shield_system.data.weakest_zone()` für Manövrieren ("Circle to rear shield"). Weakest-Zone-API ist schon da.
