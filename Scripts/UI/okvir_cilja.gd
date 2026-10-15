# Okvir cilja (vrh ekrana): ime, nivo i HP traka neprijatelja koji je cilj, plus prsten na samom neprijatelju.
# Cilj drži server (igrač.cilj_id, signal cilj_promenjen); HP je postojeći replicirani hp neprijatelja
# (njegov MultiplayerSynchronizer), bez posebnog kanala. Izgled je samo u okvir_cilja_stil.gd.
extends Control

const STIL := preload("res://Scripts/UI/okvir_cilja_stil.gd")

var _igrac: Node
var _cilj: Node = null  # CharacterBody3D neprijatelja
var _prsten: MeshInstance3D = null
var okvir: PanelContainer
var ime: Label
var traka: ProgressBar
var hp_tekst: Label
var pretnja: ProgressBar  # moja pretnja kod cilja (igrač.cilj_pretnja sa servera), sakrivena kad je nemam

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		return
	_igrac = get_parent()
	while _igrac and not _igrac.has_method("izaberi_cilj"):
		_igrac = _igrac.get_parent()
	_napravi()
	if _igrac:
		_igrac.cilj_promenjen.connect(_na_cilj)
	_osvezi()

func _napravi() -> void:
	okvir = PanelContainer.new()
	okvir.mouse_filter = Control.MOUSE_FILTER_STOP # klik preko okvira ne ide u svet
	var sb := StyleBoxFlat.new()
	sb.bg_color = STIL.BOJA_OKVIR
	sb.set_border_width_all(STIL.IVICA)
	sb.border_color = STIL.BOJA_IVICA
	sb.set_content_margin_all(STIL.PADDING)
	okvir.add_theme_stylebox_override("panel", sb)
	var kolona := VBoxContainer.new()
	kolona.add_theme_constant_override("separation", STIL.RAZMAK)
	kolona.mouse_filter = Control.MOUSE_FILTER_IGNORE
	okvir.add_child(kolona)
	ime = _label(STIL.FONT_IME)
	kolona.add_child(ime)
	traka = _traka(STIL.VISINA_TRAKE, STIL.BOJA_TRAKA, STIL.BOJA_TRAKA_POZADINA)
	kolona.add_child(traka)
	hp_tekst = _label(STIL.FONT_HP)
	hp_tekst.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_tekst.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_tekst.set_anchors_preset(Control.PRESET_FULL_RECT)
	traka.add_child(hp_tekst)
	pretnja = _traka(STIL.VISINA_PRETNJE, STIL.BOJA_PRETNJA, STIL.BOJA_PRETNJA_POZADINA)
	pretnja.max_value = STIL.PRETNJA_MAX
	kolona.add_child(pretnja)
	add_child(okvir)
	# vrh ekrana, sredina
	okvir.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE)
	okvir.grow_horizontal = Control.GROW_DIRECTION_BOTH
	okvir.position.y += STIL.MARGINA_VRH

func _traka(visina: int, boja: Color, pozadina: Color) -> ProgressBar:
	var t := ProgressBar.new()
	t.show_percentage = false
	t.custom_minimum_size = Vector2(STIL.SIRINA, visina)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var puna := StyleBoxFlat.new()
	puna.bg_color = boja
	var prazna := StyleBoxFlat.new()
	prazna.bg_color = pozadina
	t.add_theme_stylebox_override("fill", puna)
	t.add_theme_stylebox_override("background", prazna)
	return t

func _label(velicina: int) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", velicina)
	l.add_theme_color_override("font_color", STIL.BOJA_TEKST)
	l.add_theme_color_override("font_outline_color", STIL.BOJA_OUTLINE)
	l.add_theme_constant_override("outline_size", STIL.OUTLINE)
	if STIL.FONT:
		l.add_theme_font_override("font", STIL.FONT)
	return l

func _na_cilj() -> void:
	if is_instance_valid(_prsten):
		_prsten.queue_free()
	_cilj = _igrac.neprijatelj_po_id(_igrac.cilj_id) if _igrac.cilj_id != "" else null
	if _cilj:
		_prsten = _napravi_prsten()
		_cilj.add_child(_prsten)
	_osvezi()

func _napravi_prsten() -> MeshInstance3D:
	var m := TorusMesh.new()
	m.inner_radius = STIL.PRSTEN_UNUTRA
	m.outer_radius = STIL.PRSTEN_SPOLJA
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = STIL.BOJA_PRSTEN
	m.material = mat
	var p := MeshInstance3D.new()
	p.name = "CiljPrsten"
	p.mesh = m
	p.position.y = STIL.PRSTEN_Y
	return p

func _process(_d: float) -> void:
	_osvezi()

# HP prati replicirani hp cilja; cilj koji je nestao (despawn) sakriva okvir i pre nego što server javi
func _osvezi() -> void:
	var ima := is_instance_valid(_cilj)
	okvir.visible = ima
	if not ima:
		return
	ime.text = tr("%s  Lv.%d") % [tr(_cilj.ime), _cilj.nivo]
	traka.max_value = _cilj.max_hp
	traka.value = _cilj.hp
	hp_tekst.text = "%d / %d" % [_cilj.hp, _cilj.max_hp]
	pretnja.visible = _igrac.cilj_pretnja >= 0
	pretnja.value = _igrac.cilj_pretnja
