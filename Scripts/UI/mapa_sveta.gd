# Mapa sveta (M): pravougaonici zona iz zone.gd (ime, "Lv. 1-10", boja), zona u kojoj je igrač istaknuta, strelica igrača.
# Skalira se na granice svih zona (bez ručnih koordinata), pa se nova zona iz zone.gd vidi bez izmene ovog koda.
# M otvara i zatvara, Esc zatvara samo mapu (cilj ostaje); M ne radi dok je otvoren dijalog ili prodavnica ni dok se kuca.
# Klik preko mape ne ide u svet; kretanje (Input) i napad (R, Player._unhandled_input) rade. M zatvara inventar, I mapu
# (TopBar). Izgled je samo u mapa_stil.gd.
extends CanvasLayer

const STIL := preload("res://Scripts/UI/mapa_stil.gd")
const Z := preload("res://Scripts/World/zone.gd")
const MINIMAPA := preload("res://Scripts/UI/minimapa.gd")

var _igrac: Node
var _platno: Control

func _ready() -> void:
	layer = STIL.SLOJ
	visible = false
	if not is_multiplayer_authority():
		set_process(false)
		set_process_input(false)
		set_process_unhandled_input(false)
		return
	_igrac = get_parent()
	add_to_group("mapa_sveta")
	_platno = Control.new()
	_platno.set_anchors_preset(Control.PRESET_FULL_RECT)
	_platno.mouse_filter = Control.MOUSE_FILTER_STOP # klik preko mape ne ide u svet (ne menja cilj)
	_platno.draw.connect(_crtaj)
	add_child(_platno)

func otvori() -> void:
	var inv := _igrac.get_node_or_null("ui/InventoryUI")
	if inv and inv.visible:
		inv.toggle()
	visible = true

func zatvori() -> void:
	visible = false

func _process(_d: float) -> void:
	if visible:
		_platno.queue_redraw() # strelica prati lika

# M; ne dok je otvoren dijalog ili prodavnica, ni dok se kuca u polje za tekst
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("mapa") or event.is_echo() or DialogueUI._active or MerchantUI._active:
		return
	var fokus := get_viewport().gui_get_focus_owner()
	if fokus is LineEdit or fokus is TextEdit:
		return
	if visible:
		zatvori()
	else:
		otvori()
	get_viewport().set_input_as_handled()

# Esc zatvara samo mapu: _input stiže pre Player._unhandled_input (koji bi skinuo cilj). Otvoren dijalog ili prodavnica
# ima svoj Esc.
func _input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel") and not DialogueUI._active and not MerchantUI._active:
		get_viewport().set_input_as_handled()
		zatvori()

# Raspored u pikselima (za crtanje i testove): granice svih zona skalirane na ekran sa marginom, razmera ista po x i z
func raspored() -> Dictionary:
	var granice: Rect2 = Z.ZONE[0].oblast
	for z in Z.ZONE:
		granice = granice.merge(z.oblast)
	var prostor := Rect2(Vector2.ZERO, _platno.size).grow(-STIL.MARGINA)
	var k := minf(prostor.size.x / granice.size.x, prostor.size.y / granice.size.y)
	var pomeraj := prostor.get_center() - granice.get_center() * k
	var moja := Z.zona_na(_igrac.global_position.x, _igrac.global_position.z)
	var zone := []
	for i in Z.ZONE.size():
		var z: Dictionary = Z.ZONE[i]
		zone.append({"ime": tr(z.ime), "nivoi": tr("Lv. %d-%d") % [z.nivoi.x, z.nivoi.y], "boja": z.boja,
			"rect": Rect2(pomeraj + z.oblast.position * k, z.oblast.size * k), "istaknuta": i == moja})
	return {"zone": zone, "igrac": pomeraj + Vector2(_igrac.global_position.x, _igrac.global_position.z) * k}

func _crtaj() -> void:
	var r := raspored()
	var font: Font = STIL.FONT if STIL.FONT else _platno.get_theme_default_font()
	_platno.draw_rect(Rect2(Vector2.ZERO, _platno.size), STIL.BOJA_ZATAMNJENJE)
	for z in r.zone:
		_platno.draw_rect(z.rect, z.boja)
	for z in r.zone: # ivice posle svih površina, istaknuta poslednja (sused je ne prekrije)
		if not z.istaknuta:
			_platno.draw_rect(z.rect, STIL.BOJA_IVICA_ZONE, false, STIL.IVICA_ZONE)
	for z in r.zone:
		if z.istaknuta:
			_platno.draw_rect(z.rect, STIL.BOJA_ISTAKNUTA, false, STIL.IVICA_ISTAKNUTA)
	for z in r.zone: # ime iznad sredine, nivoi ispod
		var c: Vector2 = z.rect.get_center()
		_tekst(font, z.ime, Vector2(z.rect.position.x, c.y - STIL.RAZMAK_TEKSTA / 2.0 - font.get_descent(STIL.FONT_IME)),
			z.rect.size.x, STIL.FONT_IME, STIL.BOJA_TEKST)
		_tekst(font, z.nivoi, Vector2(z.rect.position.x, c.y + STIL.RAZMAK_TEKSTA / 2.0 + font.get_ascent(STIL.FONT_NIVO)),
			z.rect.size.x, STIL.FONT_NIVO, STIL.BOJA_NIVO)
	var s := MINIMAPA.strelica(r.igrac, _igrac.rotation.y, STIL.STRELICA_DUZINA, STIL.STRELICA_SIRINA)
	_platno.draw_colored_polygon(s, STIL.BOJA_STRELICA)
	_platno.draw_polyline(s + PackedVector2Array([s[0]]), STIL.BOJA_STRELICA_IVICA, 1.5)

func _tekst(font: Font, tekst: String, poz: Vector2, sirina: float, velicina: int, boja: Color) -> void:
	_platno.draw_string_outline(font, poz, tekst, HORIZONTAL_ALIGNMENT_CENTER, sirina, velicina, STIL.OUTLINE, STIL.BOJA_OUTLINE)
	_platno.draw_string(font, poz, tekst, HORIZONTAL_ALIGNMENT_CENTER, sirina, velicina, boja)
