# res://scripts/shader_diagnostics.gd
extends Node

func _ready() -> void:
	# Warten bis alles initialisiert ist
	for _i in 5:
		await get_tree().process_frame
	
	run_diagnostics()


func run_diagnostics() -> void:
	print("\n╔══════════════════════════════════════════════╗")
	print("║    DAMAGE VISUALIZER SHADER DIAGNOSTICS      ║")
	print("╚══════════════════════════════════════════════╝\n")

	# ── 1. DamageVisualizer finden ─────────────────────────────
	var vis := _find_damage_visualizer()
	if not vis:
		print("[FAIL] Kein DamageVisualizer gefunden!")
		return
	
	print("[OK]   DamageVisualizer: ", vis.get_path())

	# ── 2. Hull Mesh holen ─────────────────────────────────────
	var hull := vis.get("_hull_mesh") as MeshInstance3D
	
	if not hull:
		print("[FAIL] _hull_mesh ist NULL!")
		print("       → _setup_material() wurde nicht korrekt ausgeführt")
		return

	print("[OK]   Hull Mesh gefunden: ", hull.get_path())
	print("       Name: ", hull.name)

	# ── 3. Material prüfen ─────────────────────────────────────
	print("\n── Material Check ─────────────────────────────")

	var mat_override = hull.material_override
	var surface_mat  = hull.get_surface_override_material(0)

	print("[INF]  material_override: ", mat_override)
	print("[INF]  surface_override: ", surface_mat)

	if surface_mat != null:
		print("[FAIL] surface_override_material aktiv → blockiert Shader!")
		print("       FIX: hull.set_surface_override_material(0, null)")
		return

	if mat_override == null:
		print("[FAIL] material_override ist NULL!")
		return

	if not (mat_override is ShaderMaterial):
		print("[FAIL] Kein ShaderMaterial!")
		return

	var mat := mat_override as ShaderMaterial

	if mat.shader == null:
		print("[FAIL] Shader fehlt!")
		return

	print("[OK]   Shader aktiv: ", mat.shader.resource_path)

	# ── 4. Array-Check ─────────────────────────────────────────
	print("\n── Array Check ────────────────────────────────")

	var pos_arr = mat.get_shader_parameter("impact_positions")
	var age_arr = mat.get_shader_parameter("impact_ages")

	print("[INF] impact_positions: ", typeof(pos_arr))
	print("[INF] impact_ages:      ", typeof(age_arr))

	if pos_arr == null or not (pos_arr is PackedVector3Array):
		print("[FAIL] impact_positions falsch oder NULL!")
		return

	if age_arr == null or not (age_arr is PackedFloat32Array):
		print("[FAIL] impact_ages falsch oder NULL!")
		return

	print("[OK] Arrays korrekt gesetzt")

	# ── 5. Koordinaten-Test ────────────────────────────────────
	print("\n── Coordinate Check ───────────────────────────")

	var test_world = hull.global_position + Vector3(10, 0, 0)
	var local_pos = hull.to_local(test_world)

	print("[INF] Welt: ", test_world)
	print("[INF] Lokal:", local_pos)

	# ── 6. TEST IMPACT (entscheidend) ─────────────────────────
	print("\n── TEST IMPACT ───────────────────────────────")

	var p_arr := PackedVector3Array()
	p_arr.resize(16)
	p_arr[0] = Vector3.ZERO

	var a_arr := PackedFloat32Array()
	a_arr.resize(16)
	a_arr[0] = 0.0
	for i in range(1, 16):
		a_arr[i] = 9999.0

	mat.set_shader_parameter("impact_positions", p_arr)
	mat.set_shader_parameter("impact_ages", a_arr)
	mat.set_shader_parameter("hull_integrity", 0.3)

	print("[TEST] Impact gesetzt bei LOCAL (0,0,0)")
	print("       → Erwartung: Fleck im Zentrum des Schiffs")

	print("\n╔══════════════════════════════════════════════╗")
	print("║    DIAGNOSTICS DONE                          ║")
	print("╚══════════════════════════════════════════════╝\n")


# ── Helper ─────────────────────────────────────

func _find_damage_visualizer() -> Node:
	var nodes = get_tree().current_scene.find_children("DamageVisualizer", "Node3D", true, false)
	if nodes.size() > 0:
		return nodes[0]
	return null
