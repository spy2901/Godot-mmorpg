extends Control

var _menu: Control
var _ip_input: LineEdit
var _status_label: Label
var _peers_label: Label
var _host_btn: Button
var _join_btn: Button

const LOGIN_SCENE = "res://Scenes/UI/MainMenu.tscn"

func _ready() -> void:
	# Bez tokena nema povezivanja: klijent se vraća na login (server nema login)
	if not OS.has_feature("dedicated_server") and GameState.token == "":
		get_tree().change_scene_to_file.call_deferred(LOGIN_SCENE)
		return
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	NetworkManager.server_started.connect(_osvezi)
	NetworkManager.server_started.connect(_sakrij_meni)
	NetworkManager.connected_to_server.connect(_osvezi)
	NetworkManager.connected_to_server.connect(_sakrij_meni)
	NetworkManager.connection_failed.connect(_on_konekcija_neuspesna)
	NetworkManager.peer_connected.connect(func(_id): _osvezi())
	NetworkManager.peer_disconnected.connect(func(_id): _osvezi())

	if OS.has_feature("dedicated_server"):
		_auto_host()

func _auto_host() -> void:
	print("[SERVER] Dedicated server build detektovan — auto-hostujem...")
	_host_btn.disabled = true
	_join_btn.disabled = true
	if NetworkManager.hostuj():
		print("[SERVER] Sluša na portu ", NetworkManager.DEFAULT_PORT)
		$World.pokreni_spawn_tacke()
	else:
		print("[SERVER] Hostovanje nije uspelo!")

func _sakrij_meni() -> void:
	_menu.visible = false

func _on_konekcija_neuspesna() -> void:
	_status_label.text = "Konekcija neuspešna."
	_host_btn.disabled = false
	_join_btn.disabled = false
	_menu.visible = true

# F1 pokazuje/sakriva meni (npr. za dugme "Spawnuj goblina" na hostu)
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F1:
		_menu.visible = not _menu.visible

func _build() -> void:
	_menu = Control.new()
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_menu)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.04, 0.04)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 12)
	center.add_child(box)

	var title := Label.new()
	title.text = "Multiplayer Test"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1.0, 0.82, 0.25))
	box.add_child(title)

	_host_btn = Button.new()
	_host_btn.text = "Hostuj (port 7777)"
	_host_btn.custom_minimum_size = Vector2(0, 44)
	_host_btn.pressed.connect(func():
		_host_btn.disabled = true
		_join_btn.disabled = true
		NetworkManager.hostuj()
		$World.pokreni_spawn_za_mene()
		$World.pokreni_spawn_tacke()
	)
	box.add_child(_host_btn)

	var lbl := Label.new()
	lbl.text = "IP servera"
	box.add_child(lbl)

	_ip_input = LineEdit.new()
	_ip_input.text = "100.79.170.67"
	_ip_input.custom_minimum_size = Vector2(0, 40)
	box.add_child(_ip_input)

	_join_btn = Button.new()
	_join_btn.text = "Pridruži se"
	_join_btn.custom_minimum_size = Vector2(0, 44)
	_join_btn.pressed.connect(func():
		_host_btn.disabled = true
		_join_btn.disabled = true
		NetworkManager.pridruzi_se(_ip_input.text)
	)
	box.add_child(_join_btn)

	var goblin_btn := Button.new()
	goblin_btn.text = "Spawnuj goblina (samo server)"
	goblin_btn.custom_minimum_size = Vector2(0, 40)
	goblin_btn.pressed.connect(func(): $World.spawn_goblin())
	box.add_child(goblin_btn)

	var odjava_btn := Button.new()
	odjava_btn.text = "Odjava"
	odjava_btn.custom_minimum_size = Vector2(0, 40)
	odjava_btn.pressed.connect(_odjava)
	box.add_child(odjava_btn)

	_status_label = Label.new()
	_status_label.text = "Nepovezan."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status_label)

	_peers_label = Label.new()
	_peers_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_peers_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_peers_label)

func _osvezi() -> void:
	var moj_id = multiplayer.get_unique_id()
	var uloga = "SERVER" if NetworkManager.je_server() else "KLIJENT"
	_status_label.text = "Povezan kao %s (ID %d)" % [uloga, moj_id]
	_peers_label.text = "Peers: %s" % str(multiplayer.get_peers())

func _odjava() -> void:
	var hud = get_tree().get_first_node_in_group("hud")
	if hud:
		await hud.sacuvaj_pre_izlaska()
	GameState.odjava()
	NetworkManager.prekini()
	get_tree().change_scene_to_file(LOGIN_SCENE)
