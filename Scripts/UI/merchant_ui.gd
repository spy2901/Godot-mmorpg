extends CanvasLayer

var _panel: PanelContainer
var _list: VBoxContainer
var _title: Label
var _active: bool = false
var _feedback_label: Label
var _kupovina_u_toku: bool = false

func _ready() -> void:
	layer = 50
	_build_ui()
	visible = false

func _build_ui() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(520, 480)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.04, 0.97)
	style.border_color = Color(0.8, 0.65, 0.25)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)

	_title = Label.new()
	_title.text = tr("Shop")
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_title.add_theme_font_size_override("font_size", 22)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)

	var close_btn := Button.new()
	close_btn.text = "X"
	close_btn.pressed.connect(_close)
	header.add_child(close_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 380)
	vbox.add_child(scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	_feedback_label = Label.new()
	_feedback_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback_label.add_theme_font_size_override("font_size", 14)
	_feedback_label.visible = false
	vbox.add_child(_feedback_label)

func open(npc_name: String) -> void:
	_active = true
	_title.text = tr("%s — Shop") % tr(npc_name)
	_clear_list()
	var loading := Label.new()
	loading.text = tr("Loading...")
	loading.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_list.add_child(loading)
	visible = true

	# Koristi postojeći ApiManager (async)
	var items: Array = await ApiManager.get_all_items()

	# Ako je igrač u međuvremenu zatvorio prozor, prekini
	if not _active:
		return

	_clear_list()
	if items.is_empty():
		_show_error(tr("No items available (or the server is down)"))
		return
	for item in items:
		_add_item_row(item)

func _add_item_row(item: Dictionary) -> void:
	# quest itemi i itemi bez cene se ne prodaju
	if int(item.get("quest_item", 0)) == 1 or int(item.get("vrednost", 0)) <= 0:
		return
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var name_label := Label.new()
	var icon := str(item.get("ikonica", ""))
	var item_name := str(item.get("ime", "Nepoznato"))
	name_label.text = ("%s %s" % [icon, item_name]).strip_edges()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_color_override("font_color", Color(0.92, 0.9, 0.85))
	row.add_child(name_label)

	var price := int(item.get("vrednost", item.get("vrednost", 0)))
	var price_label := Label.new()
	price_label.text = "%d 🪙" % price
	price_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	row.add_child(price_label)

	var buy_btn := Button.new()
	buy_btn.text = tr("Buy")
	buy_btn.pressed.connect(_on_buy.bind(item))
	row.add_child(buy_btn)

	_list.add_child(row)

func _on_buy(item: Dictionary) -> void:
	var item_id = str(item.get("id", ""))
	if item_id == "":
		return

	var cijena = int(item.get("vrednost", 0))
	var hud = get_tree().get_first_node_in_group("hud")
	if hud == null:
		return

	# Online: server proverava zlato i upisuje kupovinu u bazu
	if multiplayer.multiplayer_peer != null:
		if _kupovina_u_toku:
			return
		var player = hud.get_parent().get_parent()
		if player == null or not player.has_method("kupi_na_serveru"):
			return
		_kupovina_u_toku = true
		var o: Dictionary = await player.kupi_na_serveru(item_id)
		_kupovina_u_toku = false
		if o.get("ok", false):
			hud.postavi_gold(int(o.get("gold", hud.gold)))
			hud.inventory_ui.dodaj_item_u_slot(item_id)
			_pokazi_feedback(tr("Bought: %s") % item.get("ime", item_id), true)
		else:
			_pokazi_feedback(tr(str(o.get("poruka", "Purchase failed."))), false)
		return

	# Offline: lokalno
	if not hud.potrosi_gold(cijena):
		_pokazi_feedback(tr("Not enough gold! Need: %d 🪙") % cijena, false)
		return
	hud.inventory_ui.dodaj_item_u_slot(item_id)
	_pokazi_feedback(tr("Bought: %s") % item.get("ime", item_id), true)

func _pokazi_feedback(tekst: String, uspjeh: bool) -> void:
	_feedback_label.text = tekst
	if uspjeh:
		_feedback_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	else:
		_feedback_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	_feedback_label.visible = true
	# Sakrij nakon 2 sekunde
	await get_tree().create_timer(2.0).timeout
	if is_instance_valid(_feedback_label):
		_feedback_label.visible = false
func _clear_list() -> void:
	for c in _list.get_children():
		c.queue_free()

func _show_error(msg: String) -> void:
	var err := Label.new()
	err.text = msg
	err.add_theme_color_override("font_color", Color(0.9, 0.4, 0.4))
	_list.add_child(err)
func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled() # Esc zatvara samo prodavnicu (ne skida i cilj)
		_close()

func _close() -> void:
	_active = false
	visible = false