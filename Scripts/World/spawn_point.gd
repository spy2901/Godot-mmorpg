extends Marker3D

@export_enum("goblin", "skeleton", "troll") var vrsta: String = "goblin"
@export_range(1, 20) var nivo := 1 # nivo neprijatelja sa ove tačke (statistike i XP rastu sa nivoom, Enemy.gd)

func _ready() -> void:
	add_to_group("spawn_tacka")