extends Object

class_name BVHNode


var box_min:Vector3
var box_max:Vector3
var start				# Leaf-only. Where in the triangle array does this node's triangles begin?
var count				# Leaf-only. How many triangles belong to this node?
var left = -1			# Node-only. Left and right are indices into the bvh node array
var right = -1			
var is_leaf = false
