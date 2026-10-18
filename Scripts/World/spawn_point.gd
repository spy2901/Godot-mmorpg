@tool
extends Marker3D

# Jedina lista vrsta neprijatelja: spawner (world_spawner.gd) instancira odavde, a izbor vrste u editoru se gradi iz
# ključeva (_validate_property). Nova vrsta = red ovde + scena + ime u teksti.csv.
const VRSTE := {
	"goblin": preload("res://Scenes/Enemies/goblin.tscn"),
	"skeleton": preload("res://Scenes/Enemies/skeleton.tscn"),
	"troll": preload("res://Scenes/Enemies/troll.tscn"),
}

@export var vrsta: String = "goblin"
@export_range(1, 20) var nivo := 1 # nivo neprijatelja sa ove tačke (statistike i XP rastu sa nivoom, Enemy.gd)

func _validate_property(property: Dictionary) -> void:
	if property.name == "vrsta":
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(VRSTE.keys())

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	add_to_group("spawn_tacka")
