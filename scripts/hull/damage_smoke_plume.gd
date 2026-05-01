# res://scripts/damage_smoke_plume.gd
#
# Beispiel-VFX-Szene für persistente Damage-VFX.
# Wird vom HullDamageVfx-System gespawnt (oder du hängst sie manuell an).
#
# Features:
#   • Smoke + Embers via GPUParticles3D
#   • Procedural-Fallback-Textur (kein Asset-Aufwand)
#   • set_intensity(value: float) für dynamische Anpassung an Damage-Level
#   • stop_emitting() für sanften Fade-Out
#
# Architektur-Idee:
#   Diese Szene ist eine Vorlage. Du kannst sie kopieren, anpassen, andere
#   Texturen reinhängen — solange die public-API-Methoden (set_intensity,
#   stop_emitting) erhalten bleiben, ist sie kompatibel zum HullDamageVfx-System.
extends Node3D
class_name DamageSmokePlume

# ─────────────────────────────────────────────────────────────────────────────
# EXPORTS
# ─────────────────────────────────────────────────────────────────────────────
@export_group("Smoke")
@export var smoke_amount_min:        int   = 8
@export var smoke_amount_max:        int   = 40
@export var smoke_lifetime:          float = 3.5
@export var smoke_velocity_min:      float = 1.5
@export var smoke_velocity_max:      float = 4.0
@export var smoke_color_dark:        Color = Color(0.15, 0.10, 0.08, 0.9)
@export var smoke_color_bright:      Color = Color(0.6, 0.3, 0.15, 0.7)

@export_group("Embers")
@export var enable_embers:           bool  = true
@export var ember_amount_min:        int   = 4
@export var ember_amount_max:        int   = 24
@export var ember_lifetime:          float = 1.5
@export var ember_color:             Color = Color(1.0, 0.55, 0.15, 1.0)


# ─────────────────────────────────────────────────────────────────────────────
# INTERN
# ─────────────────────────────────────────────────────────────────────────────
static var _fallback_smoke_tex: ImageTexture = null
static var _fallback_ember_tex: ImageTexture = null

var _smoke: GPUParticles3D = null
var _embers: GPUParticles3D = null
var _is_stopping: bool = false


# ─────────────────────────────────────────────────────────────────────────────
# READY
# ─────────────────────────────────────────────────────────────────────────────
func _ready() -> void:
	_build_smoke()
	if enable_embers:
		_build_embers()


# ─────────────────────────────────────────────────────────────────────────────
# PUBLIC API (vom HullDamageVfx-System gerufen)
# ─────────────────────────────────────────────────────────────────────────────
## Wird (optional) jeden Frame gerufen, um die VFX an aktuellen damage_level
## anzupassen.
##   value = 0.0 → minimaler Effekt (ruhig brennend)
##   value = 1.0 → maximaler Effekt (massiver Rauch + viel Funken)
func set_intensity(value: float) -> void:
	if _is_stopping:
		return
	value = clamp(value, 0.0, 1.0)

	if _smoke:
		_smoke.amount = int(round(lerp(float(smoke_amount_min), float(smoke_amount_max), value)))
	if _embers:
		_embers.amount = int(round(lerp(float(ember_amount_min), float(ember_amount_max), value)))


## Stoppt die Emission — bestehende Partikel laufen aus, neue werden nicht
## mehr emittiert. Das HullDamageVfx-System ruft das vor dem Despawn,
## damit der Plume sanft ausläuft statt abrupt zu verschwinden.
func stop_emitting() -> void:
	_is_stopping = true
	if _smoke:
		_smoke.emitting = false
	if _embers:
		_embers.emitting = false


# ─────────────────────────────────────────────────────────────────────────────
# SMOKE-SETUP
# ─────────────────────────────────────────────────────────────────────────────
func _build_smoke() -> void:
	_smoke = GPUParticles3D.new()
	add_child(_smoke)

	_smoke.amount       = int(round((smoke_amount_min + smoke_amount_max) * 0.5))
	_smoke.lifetime     = smoke_lifetime
	_smoke.local_coords = false   # WELT-Raum, damit Rauch realistisch wegzieht
	_smoke.preprocess   = 0.5     # damit beim Spawn schon etwas Rauch da ist

	# Process-Material
	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0.0, 1.5, 0.0)  # leichtes Aufsteigen
	pm.initial_velocity_min = smoke_velocity_min
	pm.initial_velocity_max = smoke_velocity_max
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 25.0
	pm.angular_velocity_min = -30.0
	pm.angular_velocity_max =  30.0
	pm.scale_min = 0.4
	pm.scale_max = 1.2
	# Größenwachstum über Lebenszeit (Rauch breitet sich aus)
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 0.4))
	scale_curve.add_point(Vector2(0.5, 1.0))
	scale_curve.add_point(Vector2(1.0, 1.6))
	var scale_curve_tex := CurveTexture.new()
	scale_curve_tex.curve = scale_curve
	pm.scale_curve = scale_curve_tex
	# Farbverlauf: dunkel beim Spawn, heller in der Mitte, ausgeblichen am Ende
	var color_grad := Gradient.new()
	color_grad.add_point(0.0, smoke_color_bright)
	color_grad.add_point(0.4, smoke_color_dark)
	color_grad.add_point(1.0, Color(smoke_color_dark.r, smoke_color_dark.g, smoke_color_dark.b, 0.0))
	var color_grad_tex := GradientTexture1D.new()
	color_grad_tex.gradient = color_grad
	pm.color_ramp = color_grad_tex

	_smoke.process_material = pm

	# Draw-Mesh
	var qm := QuadMesh.new()
	qm.size = Vector2(1.0, 1.0)
	_smoke.draw_pass_1 = qm

	# Material mit Smoke-Texture
	var mat := StandardMaterial3D.new()
	mat.albedo_texture          = _get_or_build_smoke_texture()
	mat.transparency            = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode            = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode          = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.particles_anim_h_frames = 1
	mat.particles_anim_v_frames = 1
	mat.particles_anim_loop     = false
	mat.vertex_color_use_as_albedo = true
	_smoke.material_override = mat


# ─────────────────────────────────────────────────────────────────────────────
# EMBERS-SETUP
# ─────────────────────────────────────────────────────────────────────────────
func _build_embers() -> void:
	_embers = GPUParticles3D.new()
	add_child(_embers)

	_embers.amount       = int(round((ember_amount_min + ember_amount_max) * 0.5))
	_embers.lifetime     = ember_lifetime
	_embers.local_coords = false

	var pm := ParticleProcessMaterial.new()
	pm.gravity = Vector3(0.0, 0.5, 0.0)  # Embers steigen leicht
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.0
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 35.0
	pm.scale_min = 0.05
	pm.scale_max = 0.15
	# Embers werden zum Ende kleiner und ausgeblichen
	var scale_curve := Curve.new()
	scale_curve.add_point(Vector2(0.0, 1.0))
	scale_curve.add_point(Vector2(1.0, 0.2))
	var scale_curve_tex := CurveTexture.new()
	scale_curve_tex.curve = scale_curve
	pm.scale_curve = scale_curve_tex
	# Farbverlauf: heiß orange → dunkel rot → schwarz
	var color_grad := Gradient.new()
	color_grad.add_point(0.0, ember_color)
	color_grad.add_point(0.6, Color(0.6, 0.15, 0.05, 1.0))
	color_grad.add_point(1.0, Color(0.1, 0.05, 0.02, 0.0))
	var color_grad_tex := GradientTexture1D.new()
	color_grad_tex.gradient = color_grad
	pm.color_ramp = color_grad_tex

	_embers.process_material = pm

	var qm := QuadMesh.new()
	qm.size = Vector2(0.3, 0.3)
	_embers.draw_pass_1 = qm

	var mat := StandardMaterial3D.new()
	mat.albedo_texture             = _get_or_build_ember_texture()
	mat.transparency               = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode               = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode             = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	# Additive Blending — Embers leuchten sich gegenseitig auf
	mat.blend_mode                 = BaseMaterial3D.BLEND_MODE_ADD
	_embers.material_override = mat


# ─────────────────────────────────────────────────────────────────────────────
# PROCEDURAL FALLBACK TEXTURES
# ─────────────────────────────────────────────────────────────────────────────
## 64×64 weicher radialer Smoke-Klecks. Geteilt zwischen allen Plume-Instanzen.
static func _get_or_build_smoke_texture() -> ImageTexture:
	if _fallback_smoke_tex != null:
		return _fallback_smoke_tex

	const TEX_SIZE: int = 64
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var center := Vector2(TEX_SIZE * 0.5, TEX_SIZE * 0.5)
	var r_max:  float = float(TEX_SIZE) * 0.5

	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var d: float = Vector2(x, y).distance_to(center) / r_max
			if d >= 1.0:
				continue
			# Smooth, weicher Auslauf — typische Smoke-Sprite-Optik
			var alpha: float = pow(1.0 - d, 1.8)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))

	_fallback_smoke_tex = ImageTexture.create_from_image(img)
	return _fallback_smoke_tex


## 16×16 kleiner Funken-Punkt mit harter Mitte, weichem Rand.
static func _get_or_build_ember_texture() -> ImageTexture:
	if _fallback_ember_tex != null:
		return _fallback_ember_tex

	const TEX_SIZE: int = 16
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var center := Vector2(TEX_SIZE * 0.5, TEX_SIZE * 0.5)
	var r_max:  float = float(TEX_SIZE) * 0.5

	for y in TEX_SIZE:
		for x in TEX_SIZE:
			var d: float = Vector2(x, y).distance_to(center) / r_max
			if d >= 1.0:
				continue
			# Heller Kern, weicher Auslauf — wie ein glühender Punkt
			var alpha: float = pow(1.0 - d, 1.2)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))

	_fallback_ember_tex = ImageTexture.create_from_image(img)
	return _fallback_ember_tex
