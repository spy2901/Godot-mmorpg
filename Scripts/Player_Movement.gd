extends CharacterBody3D

#MOVEMNT
var brzina = 5.0
var gravitacija = -9.8
var mouse_sensitivity = 0.3
var rotacija_misa = false

#ATTACK
var napad_damage = 25
var napad_cooldown = 1.0
var moze_napasti = true

#CAMERA
var zum_brzina = 1.0
var min_zum = 0.0
var max_zum = 2.0


@onready var kamera = $Camera3D

func _ready():
	add_to_group("player")
	if not is_multiplayer_authority():
		set_process_unhandled_input(false)
		set_physics_process(false)
		kamera.current = false
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	kamera.current = true

func napadni():
	moze_napasti = false
	print("Napadaš za ", napad_damage, " damage!")

	var neprijatelji = get_tree().get_nodes_in_group("neprijatelj")
	for neprijatelj in neprijatelji:
		var distanca = global_position.distance_to(neprijatelj.global_position)
		if distanca < 3.0:
			if multiplayer.multiplayer_peer != null:
				if multiplayer.is_server():
					neprijatelj.primi_damage(napad_damage)
				else:
					neprijatelj.zahtevaj_napad.rpc_id(1, napad_damage)
			else:
				neprijatelj.primi_damage(napad_damage)

	await get_tree().create_timer(napad_cooldown).timeout
	moze_napasti = true

func _input(event):
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			rotacija_misa = event.pressed
			if rotacija_misa:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			kamera.position.z = max(kamera.position.z - zum_brzina, min_zum)
			if kamera.position.z <= 0.1:
				$CharacterMain.visible = false

		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			kamera.position.z = min(kamera.position.z + zum_brzina, max_zum)
			if kamera.position.z > 0.1:
				$CharacterMain.visible = true

		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if moze_napasti:
				napadni()

	if event is InputEventMouseMotion and rotacija_misa:
		rotate_y(deg_to_rad(-event.relative.x * mouse_sensitivity))
		kamera.rotate_x(deg_to_rad(-event.relative.y * mouse_sensitivity))
		kamera.rotation.x = clamp(kamera.rotation.x, deg_to_rad(-60), deg_to_rad(60))

func _physics_process(delta):
	if not is_multiplayer_authority():
		return
	if not is_on_floor():
		velocity.y += gravitacija * delta
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = 5.0
	var smer = Vector3.ZERO

	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		smer -= transform.basis.z
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		smer += transform.basis.z
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		smer -= transform.basis.x
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		smer += transform.basis.x

	smer = smer.normalized()
	velocity.x = smer.x * brzina
	velocity.z = smer.z * brzina

	move_and_slide()

@rpc("any_peer")
func primi_loot(item_id: String, kolicina: int = 1) -> void:
	var inv = get_node_or_null("ui/InventoryUI")
	if inv:
		inv.dodaj_item_u_slot(item_id, kolicina)
	else:
		print("[LOOT] Ne mogu da nađem InventoryUI za item: ", item_id)