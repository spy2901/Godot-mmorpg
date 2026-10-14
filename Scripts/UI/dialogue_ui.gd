extends CanvasLayer

const GOLD := Color(1.0, 0.82, 0.25)
const TEXT := Color(0.95, 0.93, 0.88)
const DIM := Color(0.72, 0.68, 0.6)
const FONT: Font = preload("res://Fonts/Freza.ttf")
const FONT_SCALE := 1.2  # dodatno povećanje fontova

var S := 1.0  # skala po visini ekrana (1.0 = 1080p)

var _title_label: Label
var _text_label: Label
var _page_label: Label
var _hint_label: Label
var _sections: VBoxContainer

var _pages: Array = []
var _index: int = 0
var _active: bool = false
var _mode: String = "dialogue"  # dialogue | offer | turnin

var _pending_accept: Callable
var _pending_decline: Callable
var _pending_turnin: Callable

func _ready() -> void:
	layer = 100
	visible = false

func _fs(base: int) -> int:
	return int(round(base * S * FONT_SCALE))

# ---------------------------------------------------------------- FRAME

func _build_frame(title: String, portret: Texture2D) -> void:
	for c in get_children():
		c.queue_free()
	await get_tree().process_frame

	var vp := get_viewport().get_visible_rect()
	var W := vp.size.x
	var H := vp.size.y
	S = clamp(H / 1080.0, 1.0, 3.0)

	# Blago zatamnjenje celog ekrana
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.25)
	bg.size = Vector2(W, H)
	add_child(bg)

	var portrait_size := 130.0 * S
	var col_w := 480.0 * S
	var gap := 20.0 * S
	var block_w := portrait_size + gap + col_w
	var block_h := 420.0 * S
	var x0 := (W - block_w) / 2.0
	var y0 := (H - block_h) / 2.0
	var col_x := x0 + portrait_size + gap

	# Tamna vinjeta oko box-a
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0.85))
	grad.set_color(1, Color(0, 0, 0, 0.0))
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill = GradientTexture2D.FILL_SQUARE
	gtex.fill_from = Vector2(0.5, 0.5)
	gtex.fill_to = Vector2(1.0, 0.5)
	gtex.width = 512
	gtex.height = 512
	var vig := TextureRect.new()
	vig.texture = gtex
	var vig_w := block_w * 2.2
	var vig_h := block_h * 2.2
	vig.size = Vector2(vig_w, vig_h)
	vig.position = Vector2(x0 + block_w / 2.0 - vig_w / 2.0, y0 + block_h / 2.0 - vig_h / 2.0)
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(vig)

	# Portret
	var portrait := Panel.new()
	portrait.position = Vector2(x0, y0)
	portrait.size = Vector2(portrait_size, portrait_size)
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.05, 0.04, 0.03, 0.95)
	pstyle.border_color = GOLD
	pstyle.set_border_width_all(int(3 * S))
	pstyle.set_corner_radius_all(4)
	portrait.add_theme_stylebox_override("panel", pstyle)
	add_child(portrait)

	if portret != null:
		var tr := TextureRect.new()
		tr.texture = portret
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		var m := 3 * S
		tr.offset_left = m; tr.offset_top = m; tr.offset_right = -m; tr.offset_bottom = -m
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		portrait.add_child(tr)
	else:
		var emoji := Label.new()
		emoji.text = "🧙"
		emoji.set_anchors_preset(Control.PRESET_FULL_RECT)
		emoji.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		emoji.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		emoji.add_theme_font_size_override("font_size", int(64 * S))
		portrait.add_child(emoji)

	# Naslov
	_title_label = Label.new()
	_title_label.position = Vector2(col_x, y0 - 6 * S)
	_title_label.size = Vector2(col_w, 44 * S)
	_title_label.add_theme_font_override("font", FONT)
	_title_label.add_theme_color_override("font_color", GOLD)
	_title_label.add_theme_font_size_override("font_size", _fs(30))
	_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_title_label.add_theme_constant_override("shadow_offset_x", 2)
	_title_label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(_title_label)

	# Tekst
	_text_label = Label.new()
	_text_label.position = Vector2(col_x, y0 + 44 * S)
	_text_label.size = Vector2(col_w, 130 * S)
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.add_theme_color_override("font_color", TEXT)
	_text_label.add_theme_font_size_override("font_size", _fs(17))
	_text_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_text_label.add_theme_constant_override("shadow_offset_x", 1)
	_text_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_text_label)

	# Brojač strana
	_page_label = Label.new()
	_page_label.position = Vector2(col_x + col_w - 70 * S, y0 + 172 * S)
	_page_label.size = Vector2(70 * S, 24 * S)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_page_label.add_theme_color_override("font_color", DIM)
	_page_label.add_theme_font_size_override("font_size", _fs(14))
	add_child(_page_label)

	# Zatvori
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.position = Vector2(col_x + col_w + 12 * S, y0 - 4 * S)
	close_btn.size = Vector2(32 * S, 32 * S)
	close_btn.add_theme_font_size_override("font_size", _fs(14))
	close_btn.add_theme_color_override("font_color", Color(1, 0.35, 0.3))
	close_btn.pressed.connect(_on_close_pressed)
	add_child(close_btn)

	# Sekcije (ciljevi / nagrade / dugmad / hint)
	_sections = VBoxContainer.new()
	_sections.position = Vector2(x0, y0 + 205 * S)
	_sections.size = Vector2(block_w, H - (y0 + 205 * S) - 40 * S)
	_sections.add_theme_constant_override("separation", int(6 * S))
	add_child(_sections)

	_title_label.text = title

# ---------------------------------------------------------------- HELPERS

func _header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", FONT)
	l.add_theme_color_override("font_color", GOLD)
	l.add_theme_font_size_override("font_size", _fs(22))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l

func _body(text: String, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", _fs(15))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h * S)
	return c

func _fmt(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out

func _safe_str(v) -> String:
	if v == null:
		return ""
	return str(v)

func _objective_text(quest: Dictionary) -> String:
	var tip = quest.get("tip", "")
	var cilj = quest.get("cilj", "")
	var kolicina = int(quest.get("kolicina", 1))
	if tip == "kill":
		return "Ubij %s (%d)" % [cilj, kolicina]
	elif tip == "fetch":
		return "Donesi %s (%d)" % [cilj, kolicina]
	return ""

func _fill_quest_sections(quest: Dictionary, done: bool) -> void:
	_sections.add_child(_header("Ciljevi zadatka"))
	var obj := _objective_text(quest)
	if done:
		_sections.add_child(_body("✓ " + obj, Color(0.45, 1.0, 0.45)))
	else:
		_sections.add_child(_body(obj))
	_sections.add_child(_spacer(10))

	var item_id := _safe_str(quest.get("nagrada_item"))
	var gold := int(quest.get("nagrada_gold", 0))
	var xp := int(quest.get("nagrada_xp", 0))

	if item_id == "" and gold <= 0 and xp <= 0:
		return

	_sections.add_child(_header("Nagrade"))

	if item_id != "":
		var item: Dictionary = await ApiManager.get_item(item_id)
		if not item.is_empty() and not item.has("error"):
			var icon := _safe_str(item.get("ikonica"))
			if icon == "":
				icon = "🎁"
			var ime := _safe_str(item.get("ime"))
			if ime == "":
				ime = item_id

			var box := PanelContainer.new()
			var bstyle := StyleBoxFlat.new()
			bstyle.bg_color = Color(0.05, 0.04, 0.03, 0.9)
			bstyle.border_color = Color(0.6, 0.5, 0.3)
			bstyle.set_border_width_all(1)
			bstyle.set_corner_radius_all(4)
			bstyle.set_content_margin_all(int(8 * S))
			box.add_theme_stylebox_override("panel", bstyle)
			box.custom_minimum_size = Vector2(240 * S, 44 * S)
			box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			var bl := Label.new()
			bl.text = "%s  %s" % [icon, ime]
			bl.add_theme_color_override("font_color", TEXT)
			bl.add_theme_font_size_override("font_size", _fs(15))
			box.add_child(bl)
			_sections.add_child(box)

	if gold > 0:
		_sections.add_child(_body("Zlato:  %s 🪙" % _fmt(gold)))
	if xp > 0:
		_sections.add_child(_body("Iskustvo:  %s XP" % _fmt(xp)))

	_sections.add_child(_spacer(14))

func _add_buttons(labels: Array, callbacks: Array) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(12 * S))
	for i in labels.size():
		var b := Button.new()
		b.text = labels[i]
		b.custom_minimum_size = Vector2(130 * S, 36 * S)
		b.add_theme_font_size_override("font_size", _fs(15))
		b.pressed.connect(callbacks[i])
		row.add_child(b)
	_sections.add_child(row)

func _add_hint() -> void:
	_sections.add_child(_spacer(6))
	_hint_label = Label.new()
	_hint_label.add_theme_color_override("font_color", DIM)
	_hint_label.add_theme_font_size_override("font_size", _fs(14))
	_sections.add_child(_hint_label)

func _show_page() -> void:
	_text_label.text = str(_pages[_index])
	_page_label.text = "%d/%d" % [_index + 1, _pages.size()] if _pages.size() > 1 else ""
	_update_hint()

func _update_hint() -> void:
	if _index < _pages.size() - 1:
		_hint_label.text = "[F] dalje"
		return
	match _mode:
		"offer": _hint_label.text = "[F] Prihvati    [Esc] Odbij"
		"turnin": _hint_label.text = "[F] Predaj"
		_: _hint_label.text = "[F] zatvori"

# ---------------------------------------------------------------- OPEN

func open(npc_name: String, lines: Array, portret: Texture2D = null) -> void:
	if lines.is_empty():
		return
	_mode = "dialogue"
	_pages = lines
	_index = 0
	visible = true
	await _build_frame(npc_name, portret)
	_add_hint()
	_show_page()
	_active = true

func open_quest_offer(npc_name: String, quest: Dictionary, on_accept: Callable, on_decline: Callable, portret: Texture2D = null) -> void:
	_mode = "offer"
	_pending_accept = on_accept
	_pending_decline = on_decline
	_pages = []
	for p in _safe_str(quest.get("opis")).split("\n\n"):
		if p.strip_edges() != "":
			_pages.append(p.strip_edges())
	if _pages.is_empty():
		_pages = ["..."]
	_index = 0
	visible = true
	await _build_frame(_safe_str(quest.get("naziv", npc_name)), portret)
	await _fill_quest_sections(quest, false)
	_add_buttons(["Prihvati", "Odbij"], [_confirm_quest_accept, _confirm_quest_decline])
	_add_hint()
	_show_page()
	_active = true

func open_quest_turnin(npc_name: String, quest: Dictionary, on_turnin: Callable, portret: Texture2D = null) -> void:
	_mode = "turnin"
	_pending_turnin = on_turnin
	_pages = ["Odlično obavljeno! Evo tvoje nagrade."]
	_index = 0
	visible = true
	await _build_frame(_safe_str(quest.get("naziv", npc_name)), portret)
	await _fill_quest_sections(quest, true)
	_add_buttons(["Predaj"], [_confirm_quest_turnin])
	_add_hint()
	_show_page()
	_active = true

# ---------------------------------------------------------------- INPUT

func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event.is_action_pressed("interact"):
		get_viewport().set_input_as_handled()
		if _index < _pages.size() - 1:
			_index += 1
			_show_page()
			return
		match _mode:
			"offer": _confirm_quest_accept()
			"turnin": _confirm_quest_turnin()
			_: _close()
	elif event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_close_pressed()

func _on_close_pressed() -> void:
	if _mode == "offer":
		_confirm_quest_decline()
	else:
		_close()

func _confirm_quest_accept() -> void:
	var cb = _pending_accept
	_close()
	if cb.is_valid():
		cb.call()

func _confirm_quest_decline() -> void:
	var cb = _pending_decline
	_close()
	if cb.is_valid():
		cb.call()

func _confirm_quest_turnin() -> void:
	var cb = _pending_turnin
	_close()
	if cb.is_valid():
		cb.call()

func is_open() -> bool:
	return _active

func _close() -> void:
	_active = false
	_mode = "dialogue"
	visible = false