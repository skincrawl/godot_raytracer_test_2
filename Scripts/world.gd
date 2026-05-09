extends Node3D

class_name World


@onready var player_packed:PackedScene = preload("res://Scenes/player.tscn")

@onready var spawn_pos:Node3D = $spawn_pos
@onready var cube_static_body:StaticBody3D = $world/cube
@onready var floor_static_body:StaticBody3D = $world/floor


static var _instance:World

var player:Player


signal world_ready


static func get_instance() -> World:
	
	return _instance


func _init() -> void:
	
	_instance = self


func _ready() -> void:
	
	player = player_packed.instantiate()
	add_child(player)
	player.global_position = spawn_pos.global_position
