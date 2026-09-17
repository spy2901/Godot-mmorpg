extends Node3D

# @export var neprijatelj_scena : PackedScene
@export var goblin_scena : PackedScene
@export var skeleton_scena : PackedScene
@export var troll_scena : PackedScene
var spawn_vreme = 5.0  # Novi neprijatelj svakih 5 sekundi
var max_neprijatelja = 5  # Maksimalno 5 neprijatelja odjednom

func _ready():
	spawn_neprijatelja()

func spawn_neprijatelja():
	var trenutno = get_tree().get_nodes_in_group("neprijatelj").size()
	if trenutno < max_neprijatelja:
		# Random odaberi tip
		var scene_lista = [goblin_scena, skeleton_scena, troll_scena]
		var random_scena = scene_lista[randi() % scene_lista.size()]
        
		var novi = random_scena.instantiate()
		novi.position = Vector3(
            randf_range(-10, 10),
            0.5,
            randf_range(-10, 10)
    	)
		add_child(novi)
    
	await get_tree().create_timer(spawn_vreme).timeout
	spawn_neprijatelja()
