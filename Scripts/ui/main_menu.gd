extends Control

const GAME_SCENE = "res://Scenes/Main.tscn"  # <-- putanja tvoje glavne scene
const FONT: Font = preload("res://Fonts/Freza.ttf")
const GOLD := Color(1.0, 0.82, 0.25)

var _name_input: LineEdit
var _error_label: Label
var _play_btn: Button

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_name_input.text = GameState.ime_igraca
	_name_input.grab_focus()
	_name_input.caret_column = _name_input.text.length()

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.04, 0.04)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(420, 0)
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)

	var title := Label.new()
	title.text = "MMORPG"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", FONT)
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", GOLD)
	box.add_child(title)

	box.add_child(_spacer(20))

	var lbl := Label.new()
	lbl.text = "Ime lika"
	lbl.add_theme_color_override("font_color", Color(0.75, 0.7, 0.6))
	box.add_child(lbl)

	_name_input = LineEdit.new()
	_name_input.placeholder_text = "npr. Spajko"
	_name_input.max_length = 16
	_name_input.custom_minimum_size = Vector2(0, 44)
	_name_input.add_theme_font_size_override("font_size", 20)
	_name_input.text_submitted.connect(func(_t): _on_play())
	_name_input.text_changed.connect(func(_t): _error_label.text = "")
	box.add_child(_name_input)

	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	_error_label.add_theme_font_size_override("font_size", 13)
	box.add_child(_error_label)

	_play_btn = Button.new()
	_play_btn.text = "Igraj"
	_play_btn.custom_minimum_size = Vector2(0, 48)
	_play_btn.add_theme_font_size_override("font_size", 20)
	_play_btn.pressed.connect(_on_play)
	box.add_child(_play_btn)

	var quit_btn := Button.new()
	quit_btn.text = "Izlaz"
	quit_btn.custom_minimum_size = Vector2(0, 40)
	quit_btn.pressed.connect(func(): get_tree().quit())
	box.add_child(quit_btn)

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _validno_ime(ime: String) -> String:
	if ime.length() < 3:
		return "Ime mora imati bar 3 znaka."
	var regex := RegEx.new()
	regex.compile("^[A-Za-z0-9_]+$")
	if regex.search(ime) == null:
		return "Dozvoljena su samo slova, brojevi i _."
	return ""

func _on_play() -> void:
	var ime := _name_input.text.strip_edges()
	var greska := _validno_ime(ime)
	if greska != "":
		_error_label.text = greska
		return
	_play_btn.disabled = true
	_play_btn.text = "Učitavam..."
	GameState.postavi_ime(ime)
	get_tree().change_scene_to_file(GAME_SCENE)