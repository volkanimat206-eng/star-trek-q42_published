# Star Trek Space Combat

Ein isometrisches 2.5D-Space-Combat-Spiel in Godot 4.5, inspiriert von klassischem Star Trek. Federation-, Klingon- und Romulan-Schiffe kämpfen mit Phasern, Disruptoren und Photonentorpedos in dynamischen Multi-Schiff-Gefechten.

## Status

🚧 In aktiver Entwicklung — Mechaniken-Phase. Spielbarer Prototyp mit Combat-Loop, fehlt noch finales HUD und Story-Layer.

## Features

**Combat:**
- Vier-Zonen-Schildsystem (Front/Heck/Backbord/Steuerbord) mit Bleed-Through ab 20%
- Hülle mit Decal-basierten Impact-Schäden, Feuer-VFX und faktions-getöntem Zerstörungs-Effekt
- Beam-Waffen (Phaser, Disruptor) mit Firing-Arcs und Multi-Mount-Konvergenz
- Bolt-Waffen mit Wing-Tip-Convergence
- Photonentorpedos mit Velocity-Inheritance und Predictive Targeting

**AI & Politik:**
- Reputation-System mit Player-Disposition (-100 bis +100)
- Faction-System mit editierbaren Beziehungen, persistiert via .tres
- Three-Layer Hostility-Resolver (Aggro-Override → Reputation → Baseline)
- Assist-Mechanik: Verbündete eilen zur Hilfe wenn Allys angegriffen werden
- AI mit Patrol/Combat-Modi, Multi-Phase-Combat-Behaviour

**Tools:**
- F11 Debug-Overlay mit Live-Schiffsstatus, Zonen-HP, Zielinformationen
- F12 Debug-Control-Panel mit Spawner, Faction-Editor, Reputation-Slider, Resolver-Dump

## Setup

- **Godot:** 4.5 stable, Forward+/Vulkan
- **OS:** Windows (primär getestet), sollte auf Linux/Mac laufen
- **Plattform:** Desktop, Maus + Tastatur

```bash
git clone https://github.com/<your-user>/star-trek-space-combat.git
cd star-trek-space-combat
# Mit Godot 4.5 öffnen → World.tscn ausführen
```

## Steuerung

| Eingabe | Aktion |
|---|---|
| WASD / Pfeiltasten | Schiff bewegen |
| Mausrad | Zoom |
| Linksklick | Phaser feuern (manueller Modus) |
| Rechtsklick | Photonentorpedo |
| F1 | Auto-Fire toggle |
| Tab | Nächstes Ziel |
| Shift+Tab | Multi-Lock toggle |
| F11 | Debug-Overlay |
| F12 | Debug-Control-Panel |

## Repository-Struktur

```
res://
├── scripts/        # GDScript nach Domäne (ships, weapons, combat, ui, ...)
├── resources/      # Resource-Klassen-Definitionen (.gd mit class_name *Data)
├── data/           # Resource-Instanzen (.tres) – Schiffsdaten, Waffen-Stats
├── scenes/         # .tscn nach Domäne
├── shaders/        # .gdshader Dateien
├── assets/         # Audio, Models, Texturen
└── docs/           # ARCHITECTURE.md, PROJECT_SUMMARY.md
```

Vollständige Architektur und Designentscheidungen: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
Aktueller Projektstand und offene Aufgaben: [`docs/PROJECT_SUMMARY.md`](docs/PROJECT_SUMMARY.md)

## Lizenz

Privates Projekt, keine offene Lizenz.

## Credits

Entwicklung: Volkan
Engine: Godot 4.5 (godotengine.org)
Inspiriert von: Star Trek (CBS/Paramount). Nicht-kommerzielles Fan-Projekt.
