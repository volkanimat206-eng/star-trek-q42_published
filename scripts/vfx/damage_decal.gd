# damage_decal.gd
# MINIMAL-VERSION: nur Textur 1:1 auf der Hülle, keine Animation, keine Fades.
# Sobald das visuell sauber ist, bauen wir Pulsieren / Fade-Out / Lifecycle
# schrittweise wieder ein.
#
# Wenn keine texture_albedo zugewiesen ist, wird eine prozedurale Burn-Textur
# generiert — VOLLFLÄCHIG OPAK (kein Alpha-Gradient mehr), damit kein
# Schiffstextur-Durchscheinen mehr passiert.
extends Decal
class_name DamageDecal

# ─────────────────────────────────────────────────────────────────────────────
# FALLBACK-TEXTUR (geteilt zwischen allen Decal-Instanzen)
# ─────────────────────────────────────────────────────────────────────────────
static var _fallback_texture: ImageTexture = null
static var _fallback_warned:  bool         = false


func _ready() -> void:
	_ensure_textures()
	_apply_hard_decal_settings()


# ─────────────────────────────────────────────────────────────────────────────
# DECAL-EINSTELLUNGEN: 1:1 Textur, kein Mischen mit der Hülle
# ─────────────────────────────────────────────────────────────────────────────
## Setzt alle Properties hart auf Werte, die "Schiff scheint durch" verhindern.
## Wird im Code gesetzt, damit eine versehentliche Inspector-Änderung an der
## TSCN das Verhalten nicht still kippt.
##
## EMISSION KOMPLETT AUS:
##   Decals mit Emission verhalten sich wie Punktlichter — sie strahlen ihre
##   Umgebung an, was bei mehreren aktiven Decals die Schiffstextur global
##   tönt und "Kugel-Lichtblitze" produziert (Emission, die ins Leere strahlt).
##   Für die reine "Brand-Fleck"-Optik wollen wir nur die Albedo-Projektion,
##   keine Lichtemission. Emission kommt später als gezielter Pulse-Effekt
##   wieder rein, kontrolliert dosiert.
func _apply_hard_decal_settings() -> void:
	albedo_mix       = 1.0                       # Decal-Albedo voll, kein Blend mit Hülle
	upper_fade       = 0.0                       # kein Tiefen-Fade nach oben
	lower_fade       = 0.0                       # kein Tiefen-Fade nach unten
	normal_fade      = 0.0                       # kein Winkel-Fade
	modulate         = Color(1.0, 1.0, 1.0, 1.0) # voll sichtbar, kein Farbstich
	emission_energy  = 0.0                       # KEINE Lichtemission
	texture_emission = null                      # explizit keine Emission-Textur
	# Distance-Fade abschalten — der frisst Decals bei größerer Cam-Distance
	distance_fade_enabled = false


# ─────────────────────────────────────────────────────────────────────────────
# FALLBACK-TEXTUR
# ─────────────────────────────────────────────────────────────────────────────
func _ensure_textures() -> void:
	if texture_albedo:
		return  # User-Textur hat Vorrang

	if _fallback_texture == null:
		_fallback_texture = _build_fallback_burn_texture()
		if not _fallback_warned:
			_fallback_warned = true
			push_warning("[DamageDecal] Keine texture_albedo zugewiesen → Procedural-Fallback aktiv.")

	texture_albedo = _fallback_texture
	# texture_emission bewusst NICHT setzen — siehe _apply_hard_decal_settings.


## OPAKER Burn-Klecks: voller Alpha 1.0 im KOMPLETTEN sichtbaren Bereich,
## hartes Cutoff am Rand. Kein weicher Auslauf — sonst scheint die Hülle
## durch die Ränder.
##
## Form: Kreis, harte Kante, innen heller Glow, außen verbrannt-dunkel.
## Kanten-AA: 1-Pixel-Ramp, damit der Kreis nicht treppig aussieht — aber
## NICHT als großzügiger Alpha-Gradient.
static func _build_fallback_burn_texture() -> ImageTexture:
	const TEX_SIZE: int = 128
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var center := Vector2(TEX_SIZE * 0.5, TEX_SIZE * 0.5)
	var r_max:  float = float(TEX_SIZE) * 0.48
	var aa_band: float = 1.5  # Pixel-Breite der Anti-Alias-Kante (sehr schmal)

	var col_core := Color(1.0, 0.55, 0.15)   # heller Glow im Kern
	var col_edge := Color(0.08, 0.03, 0.01)  # dunkler verbrannter Rand

	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var dist_px: float = Vector2(x, y).distance_to(center)
			if dist_px >= r_max:
				continue

			var d:    float = dist_px / r_max          # 0..1 normalisiert
			var heat: float = pow(1.0 - d, 0.8)        # innen heißer
			var col := col_edge.lerp(col_core, heat)

			# Alpha = 1.0 bis kurz vor r_max, dann lineare Anti-Alias-Kante
			var alpha: float = 1.0
			if dist_px > r_max - aa_band:
				alpha = (r_max - dist_px) / aa_band

			img.set_pixel(x, y, Color(col.r, col.g, col.b, alpha))

	return ImageTexture.create_from_image(img)


# ─────────────────────────────────────────────────────────────────────────────
# STUBS — Kompatibilität zu HullImpactReceiver
# ─────────────────────────────────────────────────────────────────────────────
## Vom Receiver gerufen, aber in dieser Minimal-Version ignoriert.
## Sobald die Optik passt, kommt hier wieder Pulse/Fade-Out-Logik rein.
func initialize(_a = null, _b = null, _c = null, _d = null) -> void:
	pass


func set_pulse(_value: float) -> void:
	pass


func start_fade_out_external(_duration: float = 1.0) -> void:
	pass
