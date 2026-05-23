extends Object

class_name BVHNode


var aabb:AABB
var start:int				# Leaf-only. Where in the triangle array does this node's triangles begin? An index into the triangle array
var count:int				# Leaf-only. How many triangles belong to this node?
var left:BVHNode			# Node-only. Branches of this node
var right:BVHNode
var is_leaf:bool = false
