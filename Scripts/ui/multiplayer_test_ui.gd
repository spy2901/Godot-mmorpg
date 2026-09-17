extends Control

var _ip_input: LineEdit
var _status_label: Label
var _peers_label: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	NetworkManager.server_started.connect(_osvezi)
	NetworkManager.connected_to_server.connect(_osvezi)
	NetworkManager.connection_failed.connect(func(): _status_label.text = "Konekcija neuspešna.")
	NetworkManager.peer_connected.connect(func(_id): _osvezi())
	NetworkManager.peer_disconnected.connect(func(_id): _osvezi())

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.04, 0.04)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

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

	var host_btn := Button.new()
	host_btn.text = "Hostuj (port 7777)"
	host_btn.custom_minimum_size = Vector2(0, 44)
	host_btn.pressed.connect(func(): NetworkManager.hostuj())
	box.add_child(host_btn)

	var lbl := Label.new()
	lbl.text = "IP servera"
	box.add_child(lbl)

	_ip_input = LineEdit.new()
	_ip_input.text = "127.0.0.1"
	_ip_input.custom_minimum_size = Vector2(0, 40)
	box.add_child(_ip_input)

	var join_btn := Button.new()
	join_btn.text = "Pridruži se"
	join_btn.custom_minimum_size = Vector2(0, 44)
	join_btn.pressed.connect(func(): NetworkManager.pridruzi_se(_ip_input.text))
	box.add_child(join_btn)

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