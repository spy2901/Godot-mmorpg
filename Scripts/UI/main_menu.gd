extends Control

const GAME_SCENE = "res://Scenes/UI/MultiplayerTest.tscn"
const FONT: Font = preload("res://Fonts/Freza.ttf")
const GOLD := Color(1.0, 0.82, 0.25)

var _name_input: LineEdit
var _pass_input: LineEdit
var _error_label: Label
var _login_btn: Button
var _register_btn: Button
var _quit_btn: Button

func _ready() -> void:
	# Dedicated server nema login, odmah ide na scenu koja auto-hostuje
	if OS.has_feature("dedicated_server"):
		get_tree().change_scene_to_file.call_deferred(GAME_SCENE)
		return
	get_tree().auto_accept_quit = true  # TopBar ga gasi u igri
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_name_input.text = GameState.korisnicko_ime
	_error_label.text = GameState.poruka_logina
	GameState.poruka_logina = ""
	if _name_input.text == "":
		_name_input.grab_focus()
	else:
		_pass_input.grab_focus()

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

	box.add_child(_label("Korisničko ime"))
	_name_input = _polje("npr. Spajko")
	_name_input.max_length = 16
	_name_input.text_submitted.connect(func(_t): _pass_input.grab_focus())
	box.add_child(_name_input)

	box.add_child(_label("Lozinka"))
	_pass_input = _polje("najmanje 8 znakova")
	_pass_input.secret = true
	_pass_input.text_submitted.connect(func(_t): _on_login())
	box.add_child(_pass_input)

	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	_error_label.add_theme_font_size_override("font_size", 13)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_error_label)

	_login_btn = Button.new()
	_login_btn.text = "Prijava"
	_login_btn.custom_minimum_size = Vector2(0, 48)
	_login_btn.add_theme_font_size_override("font_size", 20)
	_login_btn.pressed.connect(_on_login)
	box.add_child(_login_btn)

	_register_btn = Button.new()
	_register_btn.text = "Registracija"
	_register_btn.custom_minimum_size = Vector2(0, 40)
	_register_btn.pressed.connect(_on_register)
	box.add_child(_register_btn)

	_quit_btn = Button.new()
	_quit_btn.text = "Izlaz"
	_quit_btn.custom_minimum_size = Vector2(0, 40)
	_quit_btn.pressed.connect(func(): get_tree().quit())
	box.add_child(_quit_btn)

func _label(tekst: String) -> Label:
	var lbl := Label.new()
	lbl.text = tekst
	lbl.add_theme_color_override("font_color", Color(0.75, 0.7, 0.6))
	return lbl

func _polje(placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.custom_minimum_size = Vector2(0, 44)
	e.add_theme_font_size_override("font_size", 20)
	e.text_changed.connect(func(_t): _error_label.text = "")
	return e

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _validacija(ime: String, lozinka: String) -> String:
	if ime.length() < 3 or ime.length() > 16:
		return "Korisničko ime mora imati 3-16 znakova."
	var regex := RegEx.new()
	regex.compile("^[A-Za-z0-9_]+$")
	if regex.search(ime) == null:
		return "Dozvoljena su samo slova, brojevi i _."
	if lozinka.length() < 8:
		return "Lozinka mora imati bar 8 znakova."
	return ""

func _zauzet(da: bool) -> void:
	_login_btn.disabled = da
	_register_btn.disabled = da
	_quit_btn.disabled = da

func _on_login() -> void:
	await _posalji(false)

func _on_register() -> void:
	await _posalji(true)

func _posalji(registracija: bool) -> void:
	if _login_btn.disabled:
		return
	var ime := _name_input.text.strip_edges()
	var lozinka := _pass_input.text
	var greska := _validacija(ime, lozinka)
	if greska != "":
		_error_label.text = greska
		return
	_error_label.text = ""
	_zauzet(true)
	if registracija:
		var reg: Dictionary = await ApiManager.register(ime, lozinka)
		if reg.get("status", "") != "ok":
			_error_label.text = str(reg.get("error", "Registracija nije uspela."))
			_zauzet(false)
			return
	var r: Dictionary = await ApiManager.login(ime, lozinka)
	if r.get("status", "") != "ok" or str(r.get("token", "")) == "":
		_error_label.text = str(r.get("error", "Prijava nije uspela."))
		_zauzet(false)
		return
	GameState.prijavi(r)
	_login_btn.text = "Učitavam..."
	get_tree().change_scene_to_file(GAME_SCENE)
