extends CharacterBody3D

class_name Player


'''
In this version we read in the mesh data from mesh instance nodes and feed the triangles to the GPU / shader.
'''

@onready var screen_texture:TextureRect = $screen_texture
@onready var camera:Camera3D = $camera

@onready var cube_sb:StaticBody3D
@onready var floor_sb:StaticBody3D
@onready var suzanne_rb:RigidBody3D


var mouse_sensitivity:float = 0.001

var speed:float = 2.0

var WIDTH:int = 512
var HEIGHT:int = 512

var rd:RenderingDevice
var shader:RID
var pipeline:RID
var texture:RID
var tri_buffer:RID
var camera_buffer:RID
var skybox_texture:RID
var uniform_set:RID

var byte_data:PackedByteArray

var tris:Array[Triangle] = []
var flattened_tris:Array[Triangle] = []
var bvh:BVHNode
var flattened_bvh:Array[FlatBVHNode]
var triangle_float_data:PackedFloat32Array = PackedFloat32Array()

var previous_pos:Vector3 = Vector3.ZERO
var mouse_motion:Vector2 = Vector2.ZERO # Used to know if we need to redraw the screen
var redraw_needed:bool = false


func _ready() -> void:
	
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	previous_pos = global_position
	
	floor_sb = World.get_instance().floor_sb
	cube_sb = World.get_instance().cube_sb
	suzanne_rb = World.get_instance().suzanne_rb
	
	var viewport_size:Vector2i = get_viewport().get_visible_rect().size
	WIDTH = viewport_size.x
	HEIGHT = viewport_size.y
	
	var skybox_image:Image = Image.new()
	skybox_image.load("res://Assets/egypt_skybox.png")
	# skybox_image.generate_mipmaps()
	skybox_image.convert(Image.FORMAT_RGBA8)
	
	# 1. Create rendering device
	rd = RenderingServer.create_local_rendering_device()
	
	# 2. Load shader SPIR-V
	var shader_file:RDShaderFile = load("res://Resources/Shaders/raytracer_3.glsl")
	var spirv:RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	
	# 3. Create pipeline
	pipeline = rd.compute_pipeline_create(shader)
	
	# 4. Create output texture
	var tex_format:RDTextureFormat = RDTextureFormat.new()
	tex_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.width = viewport_size.x
	tex_format.height = viewport_size.y
	tex_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	
	texture = rd.texture_create(tex_format, RDTextureView.new(), [])
	
	# 5. Bind resources (uniforms)
	
	# Triangles
	_setup_scene()
	
	byte_data = triangle_float_data.to_byte_array()
	tri_buffer = rd.storage_buffer_create(byte_data.size(), byte_data)
	
	var tri_uniform:RDUniform = RDUniform.new()
	tri_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	tri_uniform.binding = 0
	tri_uniform.add_id(tri_buffer)
	
	# Output image
	var image_uniform:RDUniform = RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 1
	image_uniform.add_id(texture)
	
	var buffer_size:int = (
		16 +		# vec3 cam pos
		4 +			# camera FOV
		48			# mat3 cam_basis
	)
	
	# Camera
	camera_buffer = rd.uniform_buffer_create(buffer_size)
	
	var camera_uniform:RDUniform = RDUniform.new()
	camera_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	camera_uniform.binding = 2
	camera_uniform.add_id(camera_buffer)
	
	# Skybox texture
	var skybox_tex_format:RDTextureFormat = RDTextureFormat.new()
	skybox_tex_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	skybox_tex_format.width = skybox_image.get_width()
	skybox_tex_format.height = skybox_image.get_height()
	skybox_tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	skybox_tex_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	
	var skybox_tex_view:RDTextureView = RDTextureView.new()
	var skybox_rid:RID = rd.texture_create(skybox_tex_format, skybox_tex_view, [skybox_image.get_data()])
	var sampler:RID = rd.sampler_create(RDSamplerState.new())
	
	var skybox_uniform:RDUniform = RDUniform.new()
	skybox_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	skybox_uniform.binding = 3
	skybox_uniform.add_id(sampler)
	skybox_uniform.add_id(skybox_rid)
	
	uniform_set = rd.uniform_set_create([tri_uniform, image_uniform, camera_uniform, skybox_uniform], shader, 0)
	
	_setup_camera_buffer()
	
	# 6. Dispatch compute shader
	# _run_compute()
	
	# 7. Read back texture from GPU to CPU
	# _get_texture_from_gpu()


func _input(_event:InputEvent) -> void:
	
	if _event.is_action_pressed("jump") and is_on_floor():
		velocity.y = 5.0
	
	if not _event is InputEventMouseMotion:
		return
	
	var mouse_event:InputEventMouseMotion = _event
	mouse_motion = mouse_event.screen_relative
	
	# print("screen velocity: ", screen_velo)
	
	var camera_basis:Basis = camera.basis
	camera.global_rotate(	 Vector3.UP, -mouse_event.screen_relative.x * mouse_sensitivity)
	camera.global_rotate(camera_basis.x, -mouse_event.screen_relative.y * mouse_sensitivity)


func _process(_delta:float) -> void:
	
	# velocity = Vector3.ZERO
	# print("delta: ", _delta)
	var old_y:float = velocity.y
	var input_dir:Vector2 = Input.get_vector("walk_left", "walk_right", "walk_back", "walk_forward")
	input_dir.y *= -1.0
	if input_dir.length() > 0.01:
		velocity = camera.basis * Vector3(input_dir.x, 0.0, input_dir.y).normalized() * speed
		velocity.y = old_y
	else:
		
		velocity.x = lerp(velocity.x, 0.0, 0.2)
		velocity.z = lerp(velocity.z, 0.0, 0.2)
	
	# print("gravity: ", get_gravity())
	if not is_on_floor():
		velocity += get_gravity() * _delta
	
	# print("velocity: ", velocity)
	move_and_slide()
	
	if not previous_pos.is_equal_approx(global_position):
		redraw_needed = true
	
	previous_pos = global_position
	
	if not mouse_motion.is_zero_approx():
		redraw_needed = true
	
	if not redraw_needed:
		return
	
	_setup_camera_buffer()
	# _run_compute()
	# _get_texture_from_gpu()
	
	redraw_needed = false
	mouse_motion = Vector2.ZERO


func _setup_scene() -> void:
	
	# Materials
	var floor_material:TriangleMaterial = TriangleMaterial.new()
	floor_material.color = Color(0.8, 0.8, 0.8, 1.0);
	var cube_material:TriangleMaterial  = TriangleMaterial.new()
	cube_material.color = Color(0.8, 0.2, 0.4, 1.0)
	var emerald_material:TriangleMaterial = TriangleMaterial.new()
	emerald_material.color = Color("#298627FF")
	
	# Floor mesh
	
	_send_floor_mesh()
	
	# Cube mesh
	
	if cube_sb.visible:
		_send_cube_mesh()
	
	# Suzanne mesh
	
	if suzanne_rb.visible:
		_send_suzanne_mesh()
	
	bvh = build_bvh(tris, 0, 0, 0)
	flatten_bvh(bvh, flattened_bvh)
	
	# Converting triangle data to floats
	for triangle in tris:
		triangle_float_data.append_array([
		# v0
		triangle.v0.x, triangle.v0.y, triangle.v0.z, 0.0,
		# v1
		triangle.v1.x, triangle.v1.y, triangle.v1.z, 0.0,
		# v2
		triangle.v2.x, triangle.v2.y, triangle.v2.z, 0.0,
		# color
		triangle.material.color.r,
		triangle.material.color.g,
		triangle.material.color.b,
		0.0
	])


func _send_floor_mesh() -> void:
	
	var floor_global_transform:Transform3D = floor_sb.global_transform
	var floor_mesh:MeshInstance3D = floor_sb.get_node("floor_mesh")
	var temp_tris:Array = floor_mesh.mesh.get_faces()
	
	var tri_i:int = 0
	while tri_i <= temp_tris.size() - 3:
		var v0:Vector3 = temp_tris[tri_i]
		var v1:Vector3 = temp_tris[tri_i + 1]
		var v2:Vector3 = temp_tris[tri_i + 2]
		var triangle:Triangle = Triangle.new()
		triangle.v0 = floor_global_transform * v0
		triangle.v1 = floor_global_transform * v1
		triangle.v2 = floor_global_transform * v2
		# triangle.v0 = v0
		# triangle.v1 = v1
		# triangle.v2 = v2
		triangle.material = TriangleMaterial.new()
		triangle.material.color = floor_mesh.get_active_material(0).albedo_color
		tris.append(triangle)
		tri_i += 3


func _send_cube_mesh() -> void:
	
	var cube_global_transform:Transform3D = cube_sb.global_transform
	var cube_mesh:MeshInstance3D = cube_sb.get_node("cube_mesh")
	var temp_tris:Array = cube_mesh.mesh.get_faces()
	
	var tri_i:int = 0
	while tri_i <= temp_tris.size() - 3:
		var v0:Vector3 = temp_tris[tri_i]
		var v1:Vector3 = temp_tris[tri_i + 1]
		var v2:Vector3 = temp_tris[tri_i + 2]
		var triangle:Triangle = Triangle.new()
		triangle.v0 = cube_global_transform * v0
		triangle.v1 = cube_global_transform * v1
		triangle.v2 = cube_global_transform * v2
		# triangle.v0 = v0
		# triangle.v1 = v1
		# triangle.v2 = v2
		triangle.material = TriangleMaterial.new()
		triangle.material.color = cube_mesh.get_active_material(0).albedo_color
		tris.append(triangle)
		tri_i += 3


func _send_suzanne_mesh() -> void:
	
	var suzanne_global_transform:Transform3D = suzanne_rb.global_transform
	var suzanne_mesh:MeshInstance3D = suzanne_rb.get_node("suzanne/Suzanne")
	var temp_tris:Array = suzanne_mesh.mesh.get_faces()
	
	# print("tris: ", temp_tris.size())
	
	var tri_i:int = 0
	while tri_i <= temp_tris.size() - 3:
		var v0:Vector3 = temp_tris[tri_i]
		var v1:Vector3 = temp_tris[tri_i + 1]
		var v2:Vector3 = temp_tris[tri_i + 2]
		var triangle:Triangle = Triangle.new()
		triangle.v0 = suzanne_global_transform * v0
		triangle.v1 = suzanne_global_transform * v1
		triangle.v2 = suzanne_global_transform * v2
		# triangle.v0 = v0
		# triangle.v1 = v1
		# triangle.v2 = v2
		triangle.material = TriangleMaterial.new()
		triangle.material.color = suzanne_mesh.get_active_material(0).albedo_color
		tris.append(triangle)
		tri_i += 3


func _run_compute() -> void:
	
	# print("drawing")
	
	var compute_list:int = rd.compute_list_begin()
	
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Triangle count
	
	var triangle_count:int = byte_data.size()
	
	var push_constants := PackedByteArray()
	push_constants.resize(16)
	push_constants.encode_s32(0, triangle_count)
	
	rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())
	
	rd.compute_list_dispatch(
		compute_list,
		(WIDTH + 7) / 8,
		(HEIGHT + 7) / 8,
		1
	)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()


func _setup_camera_buffer() -> void:
	
	var t:Transform3D = camera.global_transform
	t.basis = t.basis.orthonormalized()
	var right:Vector3 = t.basis.x
	var up:Vector3 = t.basis.y
	var forward:Vector3 = -t.basis.z
	
	var fov_rad:float = deg_to_rad(camera.fov)
	
	var data:PackedFloat32Array = PackedFloat32Array()
	
	# cam_pos_fov (vec4)
	data.append(t.origin.x)
	data.append(t.origin.y)
	data.append(t.origin.z)
	data.append(fov_rad)
	
	# cam_basis (column-major, GLSL-style)
	
	# right (vec3 + padding)
	data.append(right.x)
	data.append(right.y)
	data.append(right.z)
	data.append(0.0)
	
	# up (vec3 + padding)
	data.append(up.x)
	data.append(up.y)
	data.append(up.z)
	data.append(0.0)
	
	# forward (vec3 + padding)
	data.append(forward.x)
	data.append(forward.y)
	data.append(forward.z)
	data.append(0.0)
	
	var buffer_size:int = 64
	rd.buffer_update(camera_buffer, 0, buffer_size, data.to_byte_array())


func _get_texture_from_gpu() -> void:
	
	var bytes:PackedByteArray = rd.texture_get_data(texture, 0)
	
	var image:Image = Image.create_from_data(
		WIDTH,
		HEIGHT,
		false,
		Image.FORMAT_RGBAF,
		bytes
	)
	
	var new_texture:ImageTexture = ImageTexture.create_from_image(image)
	
	screen_texture.texture = new_texture


func build_bvh(_tris:Array, _start:int, _count:int, _depth:int) -> BVHNode:
	
	var node:BVHNode = BVHNode.new()
	
	# print("node tris range: " + str(_tris[0].centroid().distance_to(_tris[_tris.size() - 1].centroid())))
	
	# 1. Compute node bounds
	node.aabb = _tris[0].aabb()
	
	for t in _tris:
		node.aabb = node.aabb.merge(t.aabb())
	
	# Draw aabb
	var max_depth:int = 8
	var depth_ratio:float = float(_depth) / float(max_depth)
	# var color:Color = Color(0.2 + _depth * 0.1, 1.0 - _depth * 0.05, 1.0)
	# var color:Color = Color(depth_ratio, 1.0 - depth_ratio, 1.0)
	var color:Color = Color(depth_ratio, 1.0 - depth_ratio, 1.0)
	# print("depth ratio: ", depth_ratio)
	draw_aabb(node.aabb, color)
	
	# 2. Stop condition (make leaf)
	var leaf_tris:int = 4
	
	if _tris.size() <= leaf_tris:
		node.is_leaf = true
		node.start = flattened_tris.size()
		node.count = _tris.size()
		
		# print("leaf tri count: ", node.count)
		# print("depth: ", _depth)
		# print("aabb: ", node.aabb)
		for t in _tris:
			flattened_tris.append(t)
		return node
	
	# 3. Choose split axis (longest axis)
	var axis = node.aabb.get_longest_axis_index()
	
	# 4. Sort by centroid along axis
	_tris.sort_custom(func(a, b): return a.centroid()[axis] < b.centroid()[axis])
	
	# 5. Split in half
	var mid:int = int(_tris.size() / 2.0)
	var left_tris:Array = _tris.slice(0, mid)
	var right_tris:Array = _tris.slice(mid)
	
	# 6. Recurse
	node.left = build_bvh(left_tris, -1, left_tris.size(), _depth + 1)
	node.right = build_bvh(right_tris, -1, right_tris.size(), _depth + 1)
	
	return node


func flatten_bvh(_node:BVHNode, out:Array) -> int:
	
	var index:int = out.size()
	
	# Placeholder
	out.append(null)
	
	var flat = FlatBVHNode.new()
	
	flat.aabb_min = _node.aabb.position
	flat.aabb_max = _node.aabb.end
	
	flat.start = _node.start
	flat.count = _node.count
	flat.is_leaf = int(_node.is_leaf)
	
	if _node.is_leaf:
		flat.left = -1
		flat.right = -1
	else:
		flat.left = flatten_bvh(_node.left, out)
		flat.right = flatten_bvh(_node.right, out)
	
	out[index] = flat
	
	return index


func draw_aabb(_aabb:AABB, _color:Color = Color.WHITE) -> void:
	
	var im := ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.top_level = true
	mesh_instance.mesh = im
	
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	add_child(mesh_instance)
	
	var min:Vector3 = _aabb.position
	var max:Vector3 = _aabb.end
	
	var p000 = Vector3(min.x, min.y, min.z)
	var p001 = Vector3(min.x, min.y, max.z)
	var p010 = Vector3(min.x, max.y, min.z)
	var p011 = Vector3(min.x, max.y, max.z)
	
	var p100 = Vector3(max.x, min.y, min.z)
	var p101 = Vector3(max.x, min.y, max.z)
	var p110 = Vector3(max.x, max.y, min.z)
	var p111 = Vector3(max.x, max.y, max.z)
	
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	
	im.surface_set_color(_color)
	im.surface_add_vertex(p000)
	im.surface_add_vertex(p001)
	im.surface_set_color(_color)
	im.surface_add_vertex(p000)
	im.surface_add_vertex(p010)
	im.surface_set_color(_color)
	im.surface_add_vertex(p000)
	im.surface_add_vertex(p100)
	
	im.surface_set_color(_color)
	im.surface_add_vertex(p111)
	im.surface_add_vertex(p110)
	im.surface_set_color(_color)
	im.surface_add_vertex(p111)
	im.surface_add_vertex(p101)
	im.surface_set_color(_color)
	im.surface_add_vertex(p111)
	im.surface_add_vertex(p011)
	
	im.surface_set_color(_color)
	im.surface_add_vertex(p001)
	im.surface_add_vertex(p101)
	im.surface_set_color(_color)
	im.surface_add_vertex(p010)
	im.surface_add_vertex(p011)
	im.surface_set_color(_color)
	im.surface_add_vertex(p100)
	im.surface_add_vertex(p110)
	
	im.surface_set_color(_color)
	im.surface_add_vertex(p001)
	im.surface_add_vertex(p011)
	im.surface_set_color(_color)
	im.surface_add_vertex(p010)
	im.surface_add_vertex(p110)
	im.surface_set_color(_color)
	im.surface_add_vertex(p100)
	im.surface_add_vertex(p101)
	
	im.surface_end()
	
	mesh_instance.set_surface_override_material(0, mat)
