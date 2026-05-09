extends CharacterBody3D

class_name Player


'''
In this version we read in the mesh data from mesh instance nodes and feed the triangles to the GPU / shader.
'''

@onready var screen_texture:TextureRect = $screen_texture
@onready var camera:Camera3D = $camera

@onready var cube_static_body:StaticBody3D
@onready var floor_static_body:StaticBody3D


var mouse_sensitivity:float = 0.001

var speed:float = 1.0

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

var tris:Array = []
var triangle_float_data:PackedFloat32Array = PackedFloat32Array()

var previous_pos:Vector3 = Vector3.ZERO
var mouse_motion:Vector2 = Vector2.ZERO # Used to know if we need to redraw the screen
var redraw_needed:bool = false


func _ready() -> void:
	
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	
	previous_pos = global_position
	
	floor_static_body = World.get_instance().floor_static_body
	cube_static_body = World.get_instance().cube_static_body
	
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
	
	var byte_data:PackedByteArray = triangle_float_data.to_byte_array()
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
	_run_compute()
	
	# 7. Read back texture from GPU to CPU
	_get_texture_from_gpu()


func _input(_event:InputEvent) -> void:
	
	if not _event is InputEventMouseMotion:
		return
	
	var mouse_event:InputEventMouseMotion = _event
	mouse_motion = mouse_event.screen_relative
	
	# print("screen velocity: ", screen_velo)
	
	var camera_basis:Basis = camera.basis
	camera.global_rotate(Vector3.UP, -mouse_event.screen_relative.x * mouse_sensitivity)
	camera.global_rotate( camera_basis.x, -mouse_event.screen_relative.y * mouse_sensitivity)


func _process(_delta:float) -> void:
	
	velocity = Vector3.ZERO
	var input_dir:Vector2 = Input.get_vector("walk_left", "walk_right", "walk_back", "walk_forward")
	if input_dir.length() > 0.01:
		velocity += transform * Vector3(input_dir.x, 0.0, input_dir.y).normalized() * speed
	
	velocity += get_gravity()
	move_and_slide()
	
	if not previous_pos.is_equal_approx(global_position):
		redraw_needed = true
	
	previous_pos = global_position
	
	if not mouse_motion.is_zero_approx():
		redraw_needed = true
	
	if not redraw_needed:
		return
	
	_setup_camera_buffer()
	_run_compute()
	_get_texture_from_gpu()
	
	redraw_needed = false
	mouse_motion = Vector2.ZERO


func _setup_scene() -> void:
	
	# Materials
	var floor_material:TriangleMaterial = TriangleMaterial.new()
	floor_material.color = Color(0.8, 0.8, 0.8, 1.0);
	var cube_material:TriangleMaterial  = TriangleMaterial.new()
	cube_material.color = Color(0.8, 0.2, 0.4, 1.0)
	
	# Floor quad made of two triangles
	
	var floor_global_transform:Transform3D = floor_static_body.global_transform
	var floor_mesh:MeshInstance3D = floor_static_body.get_node("floor_mesh")
	var triangle_array:Array = floor_mesh.mesh.get_faces()
	
	var tri_i:int = 0
	while tri_i <= triangle_array.size() - 3:
		var v0:Vector3 = triangle_array[tri_i]
		var v1:Vector3 = triangle_array[tri_i + 1]
		var v2:Vector3 = triangle_array[tri_i + 2]
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
	
	# Cube made of twelve triangles
	
	# Vertices
	
	var cube_global_transform:Transform3D = cube_static_body.global_transform
	var cube_mesh:MeshInstance3D = cube_static_body.get_node("cube_mesh")
	triangle_array = cube_mesh.mesh.get_faces()
	
	tri_i = 0
	while tri_i <= triangle_array.size() - 3:
		var v0:Vector3 = triangle_array[tri_i]
		var v1:Vector3 = triangle_array[tri_i + 1]
		var v2:Vector3 = triangle_array[tri_i + 2]
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


func _run_compute() -> void:
	
	# print("drawing")
	
	var compute_list:int = rd.compute_list_begin()
	
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
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
