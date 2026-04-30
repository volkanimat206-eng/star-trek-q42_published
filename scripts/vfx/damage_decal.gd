# res://scripts/damage_decal.gd
#
# Skript für eine einzelne Damage-Decal-Instanz auf der Schiffshülle.
# Wird vom HullImpactReceiver gespawnt und über `initialize()` konfiguriert.
#
# Architektur:
#   • Fade-In am Spawn      → Tween auf modulate.a + emission_energy
#   • Pulsation während Lebenszeit → set_pulse(value) vom Receiver pro Frame
#   • Auto-Fade-Out vor Ende → Timer + Tween auf modulate.a + emission_energy
#   • Auto-Cleanup (queue_free) am Ende
#   • Procedural-Fallback-Textur, falls keine texture_albedo zugewiesen ist
#     (sonst wäre der Decal komplett unsichtbar — Godot-Decals brauchen eine
#     Textur, sie modulieren nur, sie generieren nichts).
#
# WARUM kein Custom-Shader:
#   Godot-4-`Decal`-Nodes haben keine ShaderMaterial-Slot. Pulsation und Fade
#   laufen über die nativen Properties — sauber, GPU-effizient, ohne Tricks.
extends Decal

# ─────────────────────────────────────────────────────────────────────────────
# RUNTIME-PARAMETER (vom Receiver per initialize() gesetzt)
# ─────────────────────────────────────────────────────────────────────────────
var _base_emission: float = 1.5     # Spitzenwert beim Pulsieren
var _is_fading_out: bool  = false

# ─────────────────────────────────────────────────────────────────────────────
# FALLBACK-TEXTUR (geteilt zwischen allen Decal-Instanzen)
# ─────────────────────────────────────────────────────────────────────────────
## Wird einmalig prozedural erzeugt und für alle Decal-Instanzen geteilt, die
## keine eigene texture_albedo zugewiesen haben. Ohne diese Texture wäre der
## Decal komplett unsichtbar — Decals projizieren Texturen, sie generieren
## keine eigenen.
static var _fallback_texture: ImageTexture = null
static var _fallback_warned:   bool         = false


# ─────────────────────────────────────────────────────────────────────────────
# READY: kurzer Fade-In, damit Decal nicht „pop"-artig erscheint
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_ensure_textures()

	# Start unsichtbar, dann sanfter Fade-In über 0.4 s
	modulate.a       = 0.0
	emission_energy  = 0.0
	
	# Falls es ein permanentes Decal ist, kann der Fade-In etwas länger sein
	var fade_in_time := 0.6 if get_parent() and "decals_permanent" in get_parent().get_parent() else 0.4
	
	var t := create_tween().set_parallel(true)
	t.tween_property(self, "modulate:a",     1.0,             0.4)
	t.tween_property(self, "emission_energy", _base_emission,  0.4)


# ─────────────────────────────────────────────────────────────────────────────
# TEXTUR-ABSICHERUNG
# ─────────────────────────────────────────────────────────────────────────────
## Wenn der User keine texture_albedo zugewiesen hat, wird hier eine
## prozedurale Fallback-Textur gesetzt. Das ist NICHT die optimale Optik —
## der Hinweis (push_warning) erscheint einmalig pro Spielsitzung, damit
## der User weiß, dass er später bessere Texturen einbauen sollte.
func _ensure_textures() -> void:
	if texture_albedo:
		return  # User-Textur hat Vorrang

	if _fallback_texture == null:
		_fallback_texture = _build_fallback_burn_texture()
		if not _fallback_warned:
			_fallback_warned = true
			push_warning("[DamageDecal] Keine texture_albedo in damage_decal.tscn zugewiesen → Procedural-Fallback aktiv. Für bessere Optik im Inspector eine Burn/Scorch-Textur (z.B. die procedural via Pillow erzeugte) zuweisen.")

	texture_albedo = _fallback_texture
	# Emission auf gleiche Textur, damit der Pulse-Glow auch im Fallback sichtbar ist
	if not texture_emission:
		texture_emission = _fallback_texture


## Baut eine 128×128 RGBA-Textur mit radialem Burn-Pattern:
##   Zentrum: heller orange-glühender Kern (alpha 1.0)
##   Mitte:   dunkleres Rotbraun
##   Rand:    weicher Auslauf (alpha → 0)
## Wird statisch gehalten — eine Textur für alle Decal-Instanzen.
static func _build_fallback_burn_texture() -> ImageTexture:
	const TEX_SIZE: int = 128
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var center := Vector2(TEX_SIZE * 0.5, TEX_SIZE * 0.5)
	var r_max:  float = float(TEX_SIZE) * 0.48

	# Zwei Farbpunkte für den Verlauf
	var col_core := Color(1.0, 0.55, 0.15)   # heller Glow im Kern
	var col_edge := Color(0.08, 0.03, 0.01)  # dunkler verbrannter Rand

	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var d:    float = Vector2(x, y).distance_to(center) / r_max
			if d >= 1.0:
				continue
			# Heat-Curve (innen heißer, aussen dunkler)
			var heat:  float = pow(1.0 - d, 0.8)
			# Alpha-Curve (weicher Auslauf zum Rand)
			var alpha: float = pow(1.0 - d, 1.6)
			var col := col_edge.lerp(col_core, heat)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, alpha))

	return ImageTexture.create_from_image(img)


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API — wird vom HullImpactReceiver gerufen
# ─────────────────────────────────────────────────────────────────────────────
## Wird unmittelbar nach Spawn vom Receiver aufgerufen.
##   damage_level    – aktueller Schadensgrad (0..1) → kann z.B. modulate.r
##                     (Rotanteil = mehr Glühen) beeinflussen
##   peak_emission   – Spitzenwert für den Pulse (Receiver berechnet aus min/max)
##   total_lifetime  – Gesamt-Lebensdauer in Sekunden (inkl. Fade-Out)
##   fade_out_time   – Wie lange am Ende der Fade läuft

func initialize(
		damage_level: float,
		peak_emission: float,
		total_lifetime: float,
		fade_out_time: float) -> void:

	_base_emission = peak_emission

	# Mehr Schaden → leichter Rotstich
	var redshift: float = clamp(damage_level, 0.0, 1.0)
	modulate = Color(
		1.0,
		1.0 - redshift * 0.55,
		1.0 - redshift * 0.75,
		modulate.a
	)

	# ── Zufällige Variation pro Decal (macht es viel lebendiger) ─────────────
	var variation := randf_range(0.92, 1.08)        # leichte Größen-/Intensitätsvariation
	var color_variation := randf_range(0.94, 1.06)

	# Emission etwas variieren
	_base_emission *= variation

	# Leichte Farbvariation (etwas mehr Orange oder Rot)
	modulate.r *= color_variation
	modulate.g *= randf_range(0.97, 1.03)

	# ── PERMANENT MODUS ─────────────────────────────────────────────────────
	if total_lifetime > 10000.0:          # Als "unendlich" behandeln
		print("[DamageDecal] Permanent Decal initialisiert (kein Auto-Fade)")
		return

	# ── Normale zeitliche Begrenzung ────────────────────────────────────────
	var alive_time: float = max(total_lifetime - fade_out_time, 0.1)
	var timer := get_tree().create_timer(alive_time)
	timer.timeout.connect(_start_fade_out.bind(fade_out_time))

	print("[DamageDecal] Temporary Decal initialisiert (Lifetime = %.1fs)" % total_lifetime)
	
## Wird jeden Frame vom HullImpactReceiver gerufen, um den Pulse zu aktualisieren.
## `value` liegt zwischen 0.0 (Ruhe) und 1.0 (Spitze). Während Fade-Out wird der
## Pulse ignoriert — sonst überschreibt er den Fade-Tween.
func set_pulse(value: float) -> void:
	if _is_fading_out:
		return
	# Sanftes Pulsieren: nie ganz aus (50 % Sockel), bis 100 % Spitze.
	emission_energy = _base_emission * (0.5 + 0.5 * value)


## Manuell auslösbar (z.B. bei Reparatur einzelner Sektoren).
func start_fade_out_external(duration: float = 1.0) -> void:
	_start_fade_out(duration)


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────
func _start_fade_out(duration: float) -> void:
	if _is_fading_out:
		return
	_is_fading_out = true

	var t := create_tween().set_parallel(true)
	t.tween_property(self, "modulate:a",     0.0, duration)
	t.tween_property(self, "emission_energy", 0.0, duration)
	# queue_free erst NACH dem Fade-Out
	t.chain().tween_callback(queue_free)
