# Pod: jedna kolizija (CollisionShape3D u sceni; ne dira se, ista je na serveru i klijentu i od nje zavisi predikcija) i
# po jedan vizuelni mesh za svaku zonu iz zone.gd, u boji zone. Mesh nema koliziju; granica je oštra (ivica do ivice).
@tool
extends StaticBody3D

const ZONE := preload("res://Scripts/World/zone.gd").ZONE
const DEBLJINA := 1.0 # m, centar na visini Pod-a (kao stari mesh)

func _ready() -> void:
	for z in ZONE:
		var o: Rect2 = z.oblast
		var mat := StandardMaterial3D.new()
		mat.albedo_color = z.boja
		var kutija := BoxMesh.new()
		kutija.size = Vector3(o.size.x, DEBLJINA, o.size.y)
		kutija.material = mat
		var m := MeshInstance3D.new()
		m.name = "Zona_" + z.ime
		m.mesh = kutija
		add_child(m)
		m.global_position = Vector3(o.get_center().x, global_position.y, o.get_center().y)
