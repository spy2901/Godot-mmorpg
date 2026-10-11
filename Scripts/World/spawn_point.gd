extends Marker3D

@export_enum("goblin", "skeleton", "troll") var vrsta: String = "goblin"

func _ready() -> void:
	add_to_group("spawn_tacka")