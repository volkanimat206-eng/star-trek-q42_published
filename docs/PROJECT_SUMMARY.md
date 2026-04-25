# Projekt-Status

Lebendes Dokument. Nach jedem größeren Meilenstein aktualisieren.

**Letzte Aktualisierung:** 25.04.2026
**Phase:** Mechaniken-Phase, Vorbereitung auf finales HUD und Story-Layer

---

## Was funktioniert

### Combat
- ✅ Beam-Waffen (Phaser, Disruptor) mit Multi-Mount-Konvergenz
- ✅ Bolt-Waffen (Wing-Disruptor BoP) mit Wing-Tip-Convergence
- ✅ Photonentorpedos mit Velocity-Inheritance, Predictive-Targeting, Arming-Distance
- ✅ Firing-Arcs (DORSAL/VENTRAL/FULL) mit shape-aware Arc-Berechnung und Cap-Limit gegen Arc-Aufblähung bei nahen Zielen
- ✅ Manual-Fire und Auto-Fire mit Friendly-Fire-Filter

### Schilde (Vier-Zonen-System)
- ✅ ShieldZone-Helper für Impact-Position → Zone-Mapping
- ✅ ShieldData mit `zone_strengths[4]`, 25%-Aufteilung, Bleed-Through 20%/20%
- ✅ Shared-Pool-Regen mit recharge_delay nach Treffer
- ✅ Reaktivierungs-Phase nach Komplett-Kollaps
- ✅ Pro-Instanz-Duplizierung (analog zu HullData)
- ✅ Shader-Uniform `zone_integrity[4]` wird gefüllt (Shader-Code nutzt es noch nicht — siehe Offen)

### Hülle
- ✅ Decal-basiertes Hull-Damage-System mit DecalPool
- ✅ Procedural Damage-Texturen (Burn, Impact, Glow-Crack)
- ✅ Feuer-VFX und Rauch ab HP-Schwellen
- ✅ Glow-Auto-Fade nach Treffer
- ✅ Zerstörungs-Explosion mit FBM-Shader, Shockwave, Sub-Explosionen, faktions-getöntem Licht

### Faktion / Reputation / AI
- ✅ Three-Layer-Resolver: Aggro → Reputation → Baseline
- ✅ FactionSystem als Scene-Autoload mit FactionConfig-Resource und Live-Editor-Persistenz
- ✅ Aggro-Layer mit 30s Lifetime
- ✅ Assist-Mechanik: Allies werden alarmiert wenn Verbündete angegriffen werden (500m Radius)
- ✅ AIController delegiert Hostility-Check an Resolver, mit Fallback-Logik

### Targeting
- ✅ Single-Lock auf alle Schiffe (auch Freunde, für Information)
- ✅ Multi-Lock nur auf Feinde, Live-Re-Evaluation
- ✅ Reticle-Farben reagieren live auf Disposition
- ✅ Auto-Fire-Friendly-Fire-Filter, Manual bewusst ungefiltert

### Debug-Tools
- ✅ Debug-Overlay (F11): Player + Target-Widgets mit Vier-Zonen-Anzeige, Bleed-Markierung
- ✅ Debug-Control-Panel (F12): Spawner, Faction-Matrix-Editor, Reputation-Slider, Resolver-Dump
- ✅ DebugManager-Flag-System: granulares Console-Logging pro Subsystem
- ✅ Layer-Watcher: Physics-Layer-Snapshot-Diagnose

---

## Was offen ist

### Aufgabe 1: Cloaking-System
**Status:** Geplant, noch nicht begonnen.

Klingonen- und Romulaner-typisches Feature mit Gameplay-Auswirkung auf Targeting, Radar-Erkennung und taktisches Verhalten.

**Design-Fragen die geklärt werden müssen:**
- Wer kann cloaken? (Nur bestimmte Schiffsklassen pro Fraktion?)
- Energiekosten und Cooldown? Drain via MovementComponent oder eigener `EnergyComponent`?
- Detection-Mechanik: Distanz-basiert? Bewegung-basiert? Aktive Scans?
- Visualisierung: Shader-Ripple/Distortion vs. Transparenz mit Edge-Detection?
- AI-Verhalten cloakender Gegner: Hit-and-Run vs Stealth-Approach?

**Vorgeschlagene Architektur:** Neuer `CloakSystem` als ShipController-Subsystem analog zu ShieldSystem. Eigene Cloak-Resource für Stats. Targeting-System bekommt `is_visible_to(observer)`-Check.

### Aufgabe 2: Schilde – Visualisierung & AI-Nutzung
**Status:** Datenbasis komplett, visuelle Schicht und AI-Anbindung offen.

- 🔧 **Shader-Erweiterung:** Zone-Integritäten visualisieren. Uniform `zone_integrity[4]` wird gefüllt, Shader-Code nutzt es noch nicht. Mögliche Effekte: Schwache Zone pulsiert rot, getroffene Zone glüht stärker, Zonen-Übergang als Fresnel-Linie.
- 🔧 **AI-Taktik:** AIController nutzt `data.weakest_zone()` für taktisches Manövrieren ("Circle to rear shield"). API ist da.
- 🔧 **Per-Schiff-Konfiguration:** Lore-Touch — Sovereign-Klasse hat stärkere Front-Schilde, BoP-Klasse symmetrisch. Würde `front_share`-Parameter in ShieldData brauchen.

### Aufgabe 3: Aufbau-UI (finales Spieler-HUD)
**Status:** Geplant nach den Schild-Visualisierungs-Aufgaben.

Eigentliches Spieler-HUD jenseits des Debug-Overlays. Zu zeigen:
- Hull/Shield-Anzeige des Player-Schiffs (groß, links unten)
- Vier-Zonen-Anzeige als Kreuz-Layout statt kompakter Reihe
- Weapon-Status mit Cooldown-Balken pro Mount
- Target-Info-Panel (Name/Fraktion/HP/Distanz) sobald gelockt
- Multi-Lock-Liste als Miniatur-Reticles
- Reputation-Anzeige kompakt (nur die relevanten Fraktionen)
- Aggro-/Combat-State-Indikator

**Architektur-Frage offen:** `HudController`-Autoload-Scene oder inline im PlayerController? Datenfluss via existierende Signals oder Polling pro Frame?

**Empfehlung:** Nach Schild-Visualisierung beginnen, weil dann das HUD darauf aufbauen kann.

---

## Jüngste Bug-Fixes (Chronologisch, neueste zuerst)

### Arc-Aufblähung bei nahen Zielen (April 2026)
**Symptom:** Bei 60° konfiguriertem Arc-Halbwinkel feuerten Phaser auf Ziele bis ~75° vom Forward — der Arc wirkte fast doppelt so breit wie eingestellt.

**Ursache:** `BeamWeapon3D.is_target_in_arc()` zog die volle `angular_radius` vom Center-Winkel ab. Bei Sovereign-Ziel (r=34m) auf 150m Distanz: `asin(34/150) ≈ 13°` zusätzliche Arc-Breite pro Seite.

**Fix:** Cap auf `ARC_SHAPE_EXTENT_CAP_DEG = 5°`. Berücksichtigt Ziel-Breite, ohne den Arc grotesk aufzublähen.

### Zone-Synchronisations-Bug (April 2026)
**Symptom:** Treffer auf eine Zone reduzierten alle vier Zonen gleichmäßig um ein Viertel des Schadens.

**Ursache:** `_recompute_current_from_zones()` setzte `current_strength = sum`, was den Setter triggerte, der `_distribute_current_to_zones()` aufrief — das verteilte den (ohnehin schon korrekt summierten) Wert wieder gleichmäßig auf alle Zonen.

**Fix:** Rekursions-Guard `_updating_from_zones` im ShieldData-Setter. Externe Zuweisungen (Inspector, Save-Load) verteilen weiter, interne Updates werden geskippt.

### Shield-Regen-Deadlock (April 2026)
**Symptom:** NPC-Schilde regenerierten nach Kollaps nicht.

**Ursache:** `_physics_process` returnte bei `_is_destroyed = true`, aber `_handle_recharge()` war der einzige Pfad der das Flag wieder auf false setzen konnte. Schild blieb für immer tot.

**Fix:** `_physics_process` läuft jetzt unkonditional solange `data` existiert. Visuelle Flags blockieren nur Shader, nicht die Logik.

### Sovereign-NPC ignoriert Player-Angriffe (April 2026)
**Symptom:** Verbündeter Sovereign reagierte nicht auf BoP-Angriffe gegen Player, auch wenn Aggro korrekt gesetzt war.

**Ursache:** `AIController._is_hostile_to_me()` hatte eine eigene Hostile-Prüfung mit direktem Reputation-Check, der den Resolver und damit den Aggro-Layer komplett umging. Zusätzlich Self-Targeting-Bug bei Schwester-Sovereigns durch ambivalenten `_belongs_to_player()`.

**Fix:** Komplette Delegation an `RelationshipResolver.are_hostile(self, node)`. Alte Zwei-Kanal-Logik bleibt als Fallback wenn Resolver-Autoload fehlt.

**Bonus-Fix:** Radar-Material wird pro Instanz dupliziert. Vorher teilten sich alle NPCs ein Material → eine Farbänderung propagierte global.

### Shared-Resource-Bug bei ShieldData (April 2026)
**Symptom:** Beim Spawn mehrerer Schiffe gleichen Typs teilten alle Instanzen `current_strength`.

**Ursache:** ShipController setzte `shield_system.data = ship_data.shield` direkt. Die Resource ist by-reference geteilt zwischen allen Instanzen.

**Fix:** `ship_data.shield.duplicate()` analog zum bereits existierenden HullData-Pattern.

---

## Frühere Meilensteine

### Hull-Damage-Visualisierung (Q1 2026)
Decal-System mit HP-Threshold-Persistenz. Procedurale Texturen via Python/Pillow generiert. Feuer/Rauch-VFX im Local-Space mit konfigurierbaren Offsets. Gram-Schmidt-Orthogonalisierung für Decal-Projection-Math.

### Faction/Reputation-Foundation (Q1 2026)
Aufbau des grundlegenden Faction-Systems vor dem Resolver-Refactor. ReputationSystem mit Disposition-Schwellen. Erste Multi-Phase-Combat-AI.

### Shield-Foundation (Q4 2025)
Erstes Schildsystem mit Area3D-Collision. Später ersetzt durch geometrische Ray-Ellipsoid-Intersection (performance, präziser).

### NPC-Sovereign Integration (Q4 2025)
Erstmal funktionierende Sovereign als NPC mit korrektem Mount-Setup, ShieldData-Override, Audio-Pool-Integration.

### Beam-Waffen-System (Q3 2025)
Phaser-Bank mit Path2D/PathFollow2D-Charging-Animation, später auf 3D-Beams umgebaut. Konvergenz-Marker für Multi-Mount-Bündelung.

### Initiale 2D-Phase (Q2-Q3 2025)
Top-Down 2D-Prototyp mit Galaxy-Class und Romulan-Warbird. Faction-AI mit State-Machine. Modulare Schiff-Architektur als Grundlage für 3D-Übergang.

---

## Bekannte Probleme (offen)

- **Output-Overflow im Log:** Bei intensiven Multi-Schiff-Gefechten zeigt Godot „output overflow" und drosselt Console-Output. Lösung: weniger granulare Debug-Flags pro Frame, oder Throttling der Print-Statements.
- **AI-Targeting bei Multi-NPC-Gruppen:** Mehrere AIs beschießen oft denselben Player → Aggro-Layer macht das schon fair, aber visuell etwas chaotisch. Idee: Loose AI-Coordination wo NPCs Roles assumen ("Du tankst, ich flankiere").
- **Y-Drift bei AI-Bewegung:** Sporadisch driften AI-Schiffe in Y-Richtung. Vermutlich Movement-Component-Bug, niedrige Priorität (macht Spielfeel nicht merklich kaputt).

---

## Code-Statistiken (Stand 25.04.2026)

- **Scripts:** 50+ GDScript-Dateien
- **Scenes:** 25+ .tscn-Dateien
- **Resource-Klassen:** 9 (`*Data` + `Faction*`)
- **Resource-Instanzen:** ~12 .tres-Dateien
- **Autoloads:** 6 (ReputationSystem, FactionSystem, RelationshipResolver, DebugManager, AudioManager, PhaserAudioPool)
- **Repository:** Privat auf GitHub, seit April 2026

---

## Nächste konkrete Schritte (Priorität)

1. **Repository aufräumen:** Ordnerstruktur nach Domänen, Naming-Konsistenz, Git-History-Setup
2. **Shield-Shader erweitern:** Zone-Integritäten visualisieren (verbindet abgeschlossene Datenbasis mit visueller Erfahrung)
3. **AI-Taktik:** Manövrieren auf weakest_zone (kleines, isoliertes Feature, gut testbar)
4. **Aufbau-UI:** Final-Spieler-HUD als nächste große Phase
5. **Cloaking:** Komplexes Feature, am besten nach HUD wenn Visualisierung steht
