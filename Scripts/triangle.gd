extends Node

class_name Triangle


var v0:Vector3
var v1:Vector3
var v2:Vector3
var material:TriangleMaterial


func centroid() -> Vector3:
	
	return (1.0 / 3.0) * (v0 + v1 + v2)


func aabb() -> AABB:
	
	var min_aabb := Vector3(
							min(v0.x, v1.x, v2.x),
							min(v0.y, v1.y, v2.y),
							min(v0.z, v1.z, v2.z)
					)
	
	var max_aabb := Vector3(
							max(v0.x, v1.x, v2.x),
							max(v0.y, v1.y, v2.y),
							max(v0.z, v1.z, v2.z)
					)
	
	return AABB(min_aabb, max_aabb - min_aabb)
