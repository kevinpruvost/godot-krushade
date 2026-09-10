extends CompositorEffect

# Test-only GPU readback. Never attach this effect to gameplay or benchmarks.
var mutex := Mutex.new()
var request := {}
var results: Array[Dictionary] = []
var callbacks := 0
var capture_vectors := true

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_motion_vectors = true

func take(request_data: Dictionary) -> void:
	mutex.lock()
	request = request_data.duplicate(true)
	mutex.unlock()

func snapshot() -> Array[Dictionary]:
	mutex.lock()
	var copy := results.duplicate(true)
	mutex.unlock()
	return copy

func _render_callback(type: int, data: RenderData) -> void:
	if type != effect_callback_type:
		return
	mutex.lock()
	callbacks += 1
	if request.is_empty():
		mutex.unlock()
		return
	var record := request
	request = {}
	var buffers := data.get_render_scene_buffers() as RenderSceneBuffersRD
	var texture := buffers.get_velocity_texture()
	record.available = texture.is_valid()
	record.owned = buffers.has_texture(&"mobile_compositor_velocity", &"velocity")
	record.separate_depth = buffers.has_texture(&"mobile_compositor_velocity", &"depth")
	record.rid = texture.get_id()
	record.size = [buffers.get_internal_size().x, buffers.get_internal_size().y]
	if record.available and record.owned:
		var rd := RenderingServer.get_rendering_device()
		var size := buffers.get_internal_size()
		var bytes := rd.texture_get_data(texture, 0)
		var pixels := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBAH, bytes)
		var p: Array = record.pixel
		var sample := pixels.get_pixel(clampi(p[0], 0, size.x-1), clampi(p[1], 0, size.y-1))
		record.measured = [sample.r, sample.g, sample.b, sample.a]
		var empty := pixels.get_pixel(2, 2)
		record.background = [empty.r, empty.g, empty.b, empty.a]
	results.append(record)
	mutex.unlock()
