extends Node3D

class_name Raytracer


@onready var screen_texture:TextureRect = $screen_texture
@onready var camera:Camera3D = $Camera3D


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


func _ready() -> void:
	
	var viewport_size:Vector2i = get_viewport().get_visible_rect().size
	WIDTH = viewport_size.x
	HEIGHT = viewport_size.y
	
	var skybox_image:Image = Image.load_from_file("res://Assets/egypt_skybox.png")
	# skybox_image.generate_mipmaps()
	skybox_image.convert(Image.FORMAT_RGBA8)
	
	# 1. Create rendering device
	rd = RenderingServer.create_local_rendering_device()
	
	# 2. Load shader SPIR-V
	var shader_file:RDShaderFile = load("res://Resources/Shaders/raytracer_2.glsl")
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


func _setup_scene() -> void:
	
	# Materials
	var floor_material:TriangleMaterial = TriangleMaterial.new()
	floor_material.color = Color(0.8, 0.8, 0.8, 1.0);
	var cube_material:TriangleMaterial  = TriangleMaterial.new()
	cube_material.color = Color(0.8, 0.2, 0.4, 1.0)
	
	# Floor quad made of two triangles
	var floor_tri_0 = Triangle.new()
	
	floor_tri_0.v0 = Vector3( 4.0,  2.0, 10.0)
	floor_tri_0.v1 = Vector3(-4.0,  2.0, 2.0)
	floor_tri_0.v2 = Vector3(-4.0,  2.0, 10.0)
	floor_tri_0.material = floor_material
	
	var floor_tri_1:Triangle = Triangle.new()
	floor_tri_1.v0 = Vector3( 4.0,  2.0, 10.0)
	floor_tri_1.v1 = Vector3( 4.0,  2.0, 2.0)
	floor_tri_1.v2 = Vector3(-4.0,  2.0, 2.0)
	floor_tri_1.material = floor_material
	
	tris.append_array([floor_tri_0, floor_tri_1])
	
	
	# Cube made of twelve triangles
	
	# Vertices
	
	# Bottom
	var lbf:Vector3 = Vector3(-0.5, 2.0, 3.5);       # Left,  bottom, front
	var lbb:Vector3 = Vector3(-0.5, 2.0, 4.5);       # Left,  bottom, back
	var rbb:Vector3 = Vector3( 0.5, 2.0, 4.5);       # Right, bottom, back
	var rbf:Vector3 = Vector3( 0.5, 2.0, 3.5);       # Right, bottom, front
	
	# Top
	var rtb:Vector3 = Vector3( 0.5, 1.0, 4.5);       # Right, top, back
	var ltb:Vector3 = Vector3(-0.5, 1.0, 4.5);       # Left,  top, back
	var ltf:Vector3 = Vector3(-0.5, 1.0, 3.5);       # Left,  top, front
	var rtf:Vector3 = Vector3( 0.5, 1.0, 3.5);       # Right, top, front
	
	
	# Bottom
	var bottom_1:Triangle = Triangle.new()
	bottom_1.v0 = lbf
	bottom_1.v1 = lbb
	bottom_1.v2 = rbb
	bottom_1.material = cube_material
	
	tris.append(bottom_1)
	
	var bottom_2:Triangle = Triangle.new()
	bottom_2.v0 = lbf
	bottom_2.v1 = rbb
	bottom_2.v2 = rbf
	bottom_2.material = cube_material
	
	tris.append(bottom_2)
	
	
	# Back
	var back_1:Triangle = Triangle.new()
	back_1.v0 = rbb
	back_1.v1 = lbb
	back_1.v2 = ltb
	back_1.material = cube_material
	
	tris.append(bottom_1)
	
	var back_2:Triangle = Triangle.new()
	back_2.v0 = rbb
	back_2.v1 = ltb
	back_2.v2 = rtb
	back_2.material = cube_material
	
	tris.append(bottom_2)

	# Left
	var left_1:Triangle = Triangle.new()
	left_1.v0 = ltf
	left_1.v1 = ltb
	left_1.v2 = lbb
	left_1.material = cube_material
	
	tris.append(left_1)
	
	var left_2:Triangle = Triangle.new()
	left_2.v0 = lbf
	left_2.v1 = lbb
	left_2.v2 = lbf
	left_2.material = cube_material
	
	tris.append(left_2)

	# Right
	var right_1:Triangle = Triangle.new()
	right_1.v0 = rtb
	right_1.v1 = rtf
	right_1.v2 = rbf
	right_1.material = cube_material
	
	tris.append(right_1)
	
	var right_2:Triangle = Triangle.new()
	right_2.v0 = rtb
	right_2.v1 = rbf
	right_2.v2 = rbb
	right_2.material = cube_material
	
	tris.append(right_2)

	# Front
	var front_1:Triangle = Triangle.new()
	front_1.v0 = rtf
	front_1.v1 = ltf
	front_1.v2 = lbf
	front_1.material = cube_material
	
	tris.append(front_1)
	
	var front_2:Triangle = Triangle.new()
	front_2.v0 = rtf
	front_2.v1 = lbf
	front_2.v2 = rbf
	front_2.material = cube_material
	
	tris.append(front_2)

	# Top
	var top_1:Triangle = Triangle.new()
	top_1.v0 = rtb
	top_1.v1 = ltb
	top_1.v2 = ltf
	top_1.material = cube_material
	
	tris.append(top_1)
	
	var top_2:Triangle = Triangle.new()
	top_2.v0 = rtb
	top_2.v1 = ltf
	top_2.v2 = rtf
	top_2.material = cube_material
	
	tris.append(top_2)
	
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
	var forward:Vector3 = t.basis.z
	
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
	
	var texture:ImageTexture = ImageTexture.create_from_image(image)
	
	screen_texture.texture = texture
