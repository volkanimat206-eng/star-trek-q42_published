@tool
extends EditorScript
#RMT auf Script im FileSystem -> Run
func _run() -> void:
	var selection = get_editor_interface().get_selection().get_selected_nodes()
	if selection.is_empty():
		print("❌ Kein Node ausgewählt!")
		return
	
	for node in selection:
		if not node is Node3D:
			print("⚠️  Übersprungen (kein Node3D): ", node.name)
			continue
			
		reset_rotation_bake(node)
		print("✅ Rotation zurückgesetzt + Children angepasst: ", node.name)


func reset_rotation_bake(node: Node3D) -> void:
	if node.rotation == Vector3.ZERO:
		print("   → Rotation war bereits null bei ", node.name)
		return
	
	var old_rotation = node.rotation
	var old_basis = node.transform.basis
	
	# Alle direkten Children speichern und ihre globale Transform sichern
	var children_transforms: Array[Transform3D] = []
	var children: Array[Node] = []
	
	for child in node.get_children():
		if child is Node3D:
			children.append(child)
			children_transforms.append(child.global_transform)
	
	# Node-Rotation auf null setzen
	node.rotation = Vector3.ZERO
	
	# Children wieder auf ihre alte globale Position/Rotation bringen
	for i in children.size():
		children[i].global_transform = children_transforms[i]
	
	print("   → Rotation von %s auf (0,0,0) gesetzt | %d Children angepasst" % [node.name, children.size()])
