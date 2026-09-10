extends SceneTree

const PROBE = preload("res://vector_probe.gd")
var camera: Camera3D
var mesh: MeshInstance3D
var skeleton: Skeleton3D
var effect: CompositorEffect
var view: SubViewport
var frame := 0
var previous_screen := Vector2.ZERO
var previous_depth := 0.0
var previous_jitter := Vector2.ZERO
var phases := ["stationary", "rigid_xy", "camera_xy", "bone_xy", "bone_stopped", "rigid_depth", "jitter_only", "request_off", "request_on", "resize"]

func _initialize() -> void:
	root.size = Vector2i(320, 192)
	root.unfocusable = true
	view = SubViewport.new()
	view.size = Vector2i(320, 192)
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	view.msaa_3d = Viewport.MSAA_DISABLED
	view.msaa_2d = Viewport.MSAA_DISABLED
	view.use_taa = false
	var world := Node3D.new()
	view.add_child(world)
	skeleton = Skeleton3D.new()
	skeleton.name = "GenericSkeleton"
	skeleton.add_bone("root")
	skeleton.set_bone_rest(0, Transform3D.IDENTITY)
	world.add_child(skeleton)
	mesh = MeshInstance3D.new()
	mesh.mesh = _skinned_quad()
	mesh.skeleton = NodePath("../GenericSkeleton")
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.8, 0.3, 0.1)
	mesh.material_override = material
	world.add_child(mesh)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.position.z = 4.0
	camera.current = true
	effect = PROBE.new()
	var compositor := Compositor.new()
	compositor.compositor_effects = [effect]
	camera.compositor = compositor
	RenderingServer.frame_pre_draw.connect(_step)

func _skinned_quad() -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-0.6,-0.6,0), Vector3(0.6,-0.6,0), Vector3(0.6,0.6,0), Vector3(-0.6,0.6,0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.FORWARD,Vector3.FORWARD,Vector3.FORWARD,Vector3.FORWARD])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,1,2,0,2,3])
	arrays[Mesh.ARRAY_BONES] = PackedInt32Array([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0])
	arrays[Mesh.ARRAY_WEIGHTS] = PackedFloat32Array([1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0])
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result

func _step() -> void:
	var phase_index := frame / 20
	var tick := frame % 20
	if phase_index >= phases.size():
		RenderingServer.frame_pre_draw.disconnect(_step)
		_finish.call_deferred()
		return
	var phase: String = phases[phase_index]
	if tick == 0:
		mesh.position = Vector3.ZERO
		skeleton.set_bone_pose_position(0, Vector3.ZERO)
		camera.position = Vector3(0,0,4)
		RenderingServer.camera_set_perspective(camera.get_camera_rid(), camera.fov, camera.near, camera.far)
		effect.needs_motion_vectors = phase != "request_off"
		if phase == "resize":
			view.size = Vector2i(384, 224)
	match phase:
		"rigid_xy": mesh.position = Vector3(tick * 0.025, tick * 0.015, 0)
		"camera_xy": camera.position = Vector3(tick * 0.02, tick * -0.01, 4)
		"bone_xy": skeleton.set_bone_pose_position(0, Vector3(tick * 0.025, tick * 0.015, 0))
		"rigid_depth": mesh.position = Vector3(0,0,tick * 0.025)
	mesh.force_update_transform()
	camera.force_update_transform()
	var jitter := Vector2.ZERO
	if phase == "jitter_only":
		var samples := [Vector2(-0.375,-0.125),Vector2(0.125,-0.375),Vector2(0.375,0.125),Vector2(-0.125,0.375)]
		jitter = samples[tick % 4] * 0.5
		var p := camera.get_camera_projection()
		var extents := Vector2(2.0 * camera.near / p.x.x, 2.0 * camera.near / p.y.y)
		RenderingServer.camera_set_frustum(camera.get_camera_rid(), extents.y, jitter * extents / Vector2(view.size), camera.near, camera.far)
	var centre := mesh.global_position + skeleton.get_bone_pose_position(0)
	var screen := camera.unproject_position(centre)
	var correction := Projection.create_depth_correction(true)
	var local := camera.global_transform.affine_inverse() * centre
	var clip := correction * camera.get_camera_projection() * Vector4(local.x, local.y, local.z, 1)
	var depth := clip.z / clip.w
	if tick in [10, 12, 14, 16]:
		var delta := (screen - previous_screen) / Vector2(view.size) * 2.0
		if phase == "rigid_depth":
			# The sampled fragment is at pixel centre, not the projected origin.
			var ndc := (Vector2(int(screen.x),int(screen.y)) + Vector2(0.5,0.5)) / Vector2(view.size) * 2.0 - Vector2.ONE
			delta = ndc * (1.0 - (4.0 - tick * 0.025) / (4.0 - (tick-1) * 0.025))
		var jitter_delta := -(jitter - previous_jitter) / Vector2(view.size) * 2.0
		delta += jitter_delta * Vector2(1,-1)
		effect.take({"phase":phase,"tick":tick,"pixel":[int(screen.x),int(screen.y)],"expected":[delta.x,-delta.y,depth-previous_depth,1.0]})
	previous_screen = screen
	previous_depth = depth
	previous_jitter = jitter
	frame += 1

func _finish() -> void:
	var result := {"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"renderer":RenderingServer.get_current_rendering_method(),"records":effect.snapshot()}
	var args := OS.get_cmdline_user_args()
	var output := args[0] if not args.is_empty() else "user://motion_vector_fixture.json"
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"  "))
	file.close()
	print("MOTION_VECTOR_PIXELS " + JSON.stringify(result))
	# Individual records survive Android logcat's per-line size limit.
	for record in result.records:
		print("MV_PIXEL_RECORD " + JSON.stringify(record))
	result.erase("records")
	print("MV_PIXEL_DONE " + JSON.stringify(result))
	quit()
