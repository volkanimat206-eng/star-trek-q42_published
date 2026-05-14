# res://resources/damage_parameters.gd
class_name DamageParameters
extends Resource

@export_category("Damage Core")
@export var damage_amount : float = 0.0
@export var cloak_alpha : float = 1.0
@export var damage_threshold : float = 0.15
@export var damage_edge_softness : float = 0.20
@export var damage_noise_scale : float = 12.0

@export_category("Burn Colors")
@export var burn_color_dark : Color = Color(0.04, 0.02, 0.01)
@export var burn_color_char : Color = Color(0.12, 0.06, 0.02)
@export var burn_color_glow : Color = Color(1.0, 0.45, 0.05)
@export var burn_color_molten : Color = Color(1.0, 0.35, 0.05)
@export var burn_color_molten_core : Color = Color(1.0, 0.92, 0.55)

@export_category("Molten & Effects")
@export var molten_core_falloff : float = 2.5
@export var burn_glow_energy : float = 4.0
@export var burn_molten_energy : float = 12.0
@export var damage_roughness_boost : float = 0.75
@export var damage_normal_disturb : float = 1.8

@export_category("Cracks")
@export var crack_amount : float = 0.6
@export var crack_scale : float = 8.0
@export var crack_width : float = 0.06
@export var crack_glow_intensity : float = 3.0
@export var crack_drift_amount : float = 0.0

@export_category("Streaks")
@export var streak_amount : float = 0.4
@export var streak_direction : Vector3 = Vector3(0.0, 0.0, 1.0)
@export var streak_stretch : float = 6.0
@export var streak_scale : float = 7.0
@export var streak_threshold : float = 0.15

@export_category("Crater Rim")
@export var rim_width : float = 0.15
@export var rim_glow_energy : float = 2.5

@export_category("Heat Pulse")
@export var pulse_amplitude : float = 0.45
@export var pulse_speed_hz : float = 1.2
@export var pulse_async_amount : float = 0.7
@export var pulse_flicker_amount : float = 0.35

@export_category("Inner Hull Pipes")
@export var inner_hull_amount : float = 1.0
@export var inner_hull_threshold : float = 0.55
@export var inner_hull_darkness : float = 0.15
@export var inner_grid_scale : float = 25.0
@export var inner_pipe_thickness : float = 0.12
@export var inner_pipe_orientation : float = 0.3
@export var inner_pipe_color : Color = Color(0.4, 0.25, 0.10)
@export var inner_pipe_glow_color : Color = Color(1.0, 0.5, 0.2)
@export var inner_pipe_glow_energy : float = 1.5
@export var inner_parallax_depth : float = 0.05
@export var inner_grid_flicker_independence : float = 0.4
