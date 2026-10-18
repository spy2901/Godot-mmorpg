extends CharacterBody3D

# ENEMY BASE CLASS

@export var ime = "Enemy"
@export var max_hp = 100
@export var nivo = 1  # po instanci (spawn tačka); statistike iz scene su za nivo 1 i rastu sa nivoom (_skaliraj)
@export var brzina = 2.0
@export var napad_damage = 10
@export var aggro_range = 10.0
@export var napad_range = 2.0
var xp_nagrada = 0  # iz nivoa (xp_za_nivo), ne iz scene
@export var napad_cooldown = 2.0
@export var loot_tabela = [
	{"id": "goblin_ear", "sansa": 100},
	{"id": "iron_ore", "sansa": 50},
	{"id": "bronze_coin", "sansa": 75},
	{"id": "rusty_sword", "sansa": 10}
]
@export var moze_napasti = true

var hp = 100:
	set(value):
		hp = value
		if is_instance_valid(hp_label):
			_osvezi_hp_label()

@onready var ime_label = $ImeLabel
@onready var hp_label = $HpLabel

var player: Node3D = null  # server: trenutna meta (igrač sa najvećom pretnjom)
var napadaci: Array = []  # peer ID-jevi koji su naneli damage (dobijaju XP)
var _mrtav := false

# AI (samo server): stanja i tabela pretnje. Sve konstante AI-ja su ovde.
enum Stanje { MIROVANJE, JURENJE, POVRATAK }
const POCETNA_PRETNJA := 1.0      # igrač uđe u aggro_range
const PRAG_PROMENE_META := 1.1    # nova meta tek kad drugi pređe 110% pretnje trenutne (da meta ne treperi)
const LEASH_OD_POCETKA := 25.0    # m: neprijatelj dalje od početne tačke -> POVRATAK
const LEASH_OD_META := 15.0       # m: meta dalje -> POVRATAK; ostali igrači dalje -> brišu se iz tabele
const REGEN_POSLE_POVRATKA := 10.0 # HP/s u MIROVANJU posle povratka, do punog
const STIGAO_NA_POCETAK := 0.5    # m (horizontalno)

var stanje: Stanje = Stanje.MIROVANJE
var pretnja := {}       # peer_id -> pretnja
var _meta_id := 0       # peer_id mete, 0 = nema
var _pocetak := Vector3.ZERO
var _regen := false
var _regen_akum := 0.0

# Nivo: HP +15% i šteta +10% po nivou iznad 1. XP tako da protiv neprijatelja svog nivoa nivo traje ~15 ubistava
# (XP do sledećeg nivoa = 25*n^2 + 75*n, kao backend napredak.py), pa prema razlici nivoa (xp_mnozilac).
const HP_PO_NIVOU := 0.15
const STETA_PO_NIVOU := 0.10
const UBISTAVA_PO_NIVOU := 15.0

static func xp_za_nivo(n: int) -> int:
	return maxi(1, roundi((25 * n * n + 75 * n) / UBISTAVA_PO_NIVOU))

# razlika = nivo neprijatelja - nivo igrača; najmanje 10%, nikad 0
static func xp_mnozilac(razlika: int) -> float:
	if razlika >= 3: return 1.2
	if razlika >= -2: return 1.0
	if razlika >= -4: return 0.5
	if razlika >= -6: return 0.2
	return 0.1

static func xp_za_razliku(xp: int, razlika: int) -> int:
	return maxi(1, roundi(xp * xp_mnozilac(razlika)))

func _skaliraj() -> void:
	max_hp = roundi(max_hp * (1.0 + HP_PO_NIVOU * (nivo - 1)))
	napad_damage = roundi(napad_damage * (1.0 + STETA_PO_NIVOU * (nivo - 1)))
	xp_nagrada = xp_za_nivo(nivo)

func _ready():
	add_to_group("neprijatelj")
	_skaliraj()
	hp = max_hp
	ime_label.text = tr(ime)
	ime_label.position = Vector3(0, 2.2, 0)
	ime_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hp_label.position = Vector3(0, 2.0, 0)
	hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_osvezi_hp_label()
	_pocetak = global_position

func _je_multiplayer_aktivan() -> bool:
	return multiplayer.multiplayer_peer != null

func _ja_sam_autoritet() -> bool:
	if not _je_multiplayer_aktivan():
		return true
	return multiplayer.is_server()

func _nadji_igraca_po_id(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p.get_multiplayer_authority() == peer_id:
			return p
	return null

func _osvezi_hp_label() -> void:
	if hp_label:
		hp_label.text = str(hp) + "/" + str(max_hp)

func _physics_process(delta):
	if not _ja_sam_autoritet():
		return
	velocity.x = 0
	velocity.z = 0
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	match stanje:
		Stanje.MIROVANJE: _mirovanje(delta)
		Stanje.JURENJE: _jurenje()
		Stanje.POVRATAK: _povratak()
	move_and_slide()

# Stoji na početnoj tački; posle povratka regeneriše HP do punog. Igrač u aggro_range -> JURENJE.
func _mirovanje(delta: float) -> void:
	if _regen:
		_regen_akum += REGEN_POSLE_POVRATKA * delta
		var n := int(_regen_akum)
		_regen_akum -= n
		hp = mini(hp + n, max_hp)
		_regen = hp < max_hp
	_dodaj_aggro()
	if not pretnja.is_empty():
		_promeni_stanje(Stanje.JURENJE)

# Juri igrača sa najvećom pretnjom i napada ga u dometu.
func _jurenje() -> void:
	var meta := _nadji_igraca_po_id(_meta_id)
	if (meta and global_position.distance_to(meta.global_position) > LEASH_OD_META) \
			or _xz_daljina(global_position, _pocetak) > LEASH_OD_POCETKA:
		_promeni_stanje(Stanje.POVRATAK)
		return
	_ocisti_pretnju()
	_dodaj_aggro()
	meta = _izaberi_metu()
	if meta == null:
		_promeni_stanje(Stanje.POVRATAK)
		return
	player = meta
	var distanca = global_position.distance_to(meta.global_position)
	if distanca > napad_range:
		var smer = (meta.global_position - global_position).normalized()
		velocity.x = smer.x * brzina
		velocity.z = smer.z * brzina
	elif moze_napasti:
		napadni_igraca()

# Ide na početnu tačku; ne napada i ne reaguje na aggro ni štetu dok ne stigne.
func _povratak() -> void:
	if _xz_daljina(global_position, _pocetak) <= STIGAO_NA_POCETAK:
		_promeni_stanje(Stanje.MIROVANJE)
		return
	var smer := _pocetak - global_position
	smer.y = 0
	smer = smer.normalized()
	velocity.x = smer.x * brzina
	velocity.z = smer.z * brzina

func _promeni_stanje(novo: Stanje) -> void:
	if novo != Stanje.JURENJE:
		pretnja.clear()
		_meta_id = 0
		player = null
	_regen = novo == Stanje.MIROVANJE and stanje == Stanje.POVRATAK
	_regen_akum = 0.0
	print("[AI] %s %s -> %s" % [get_parent().name, Stanje.keys()[stanje], Stanje.keys()[novo]])
	stanje = novo

# Živi igrači u aggro_range koji još nisu u tabeli dobiju početnu pretnju.
func _dodaj_aggro() -> void:
	for p in get_tree().get_nodes_in_group("player"):
		var id: int = p.get_multiplayer_authority()
		if not p.mrtav and not pretnja.has(id) and global_position.distance_to(p.global_position) <= aggro_range:
			pretnja[id] = POCETNA_PRETNJA

# Mrtav, odjavljen (nije više u grupi player) ili dalji od leash-a -> van tabele.
func _ocisti_pretnju() -> void:
	for id in pretnja.keys():
		var p := _nadji_igraca_po_id(id)
		if p == null or p.mrtav or global_position.distance_to(p.global_position) > LEASH_OD_META:
			pretnja.erase(id)

# Najveća pretnja; trenutna meta ostaje dok je drugi ne pređe za PRAG_PROMENE_META.
func _izaberi_metu() -> Node:
	var naj := 0
	for id in pretnja:
		if naj == 0 or pretnja[id] > pretnja[naj]:
			naj = id
	if pretnja.has(_meta_id) and pretnja[naj] <= pretnja[_meta_id] * PRAG_PROMENE_META:
		naj = _meta_id
	_meta_id = naj
	return _nadji_igraca_po_id(naj) if naj != 0 else null

# Server, za traku pretnje vlasnika: pretnja igrača kao % pretnje trenutne mete; -1 = nema pretnje (ili nema mete).
func pretnja_procenat(peer_id: int) -> int:
	if stanje != Stanje.JURENJE or not pretnja.has(peer_id) or not pretnja.has(_meta_id):
		return -1
	return roundi(100.0 * pretnja[peer_id] / pretnja[_meta_id])

func _xz_daljina(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))

func primi_damage(kolicina, napadac_id: int = 0):
	if not _ja_sam_autoritet() or _mrtav:
		return
	if napadac_id != 0 and kolicina > 0 and not napadaci.has(napadac_id): # samo stvarna šteta: loot, XP i kill
		napadaci.append(napadac_id)
	if napadac_id != 0 and stanje != Stanje.POVRATAK: # šteta = pretnja 1:1; u povratku se ne računa
		pretnja[napadac_id] = pretnja.get(napadac_id, 0.0) + kolicina
		if stanje == Stanje.MIROVANJE:
			_promeni_stanje(Stanje.JURENJE)
	hp -= kolicina
	hp = max(hp, 0)
	print("[HIT] ", ime, " -", kolicina, " -> hp ", hp)
	if hp == 0:
		_mrtav = true
		pretnja.clear()
		_meta_id = 0
		print("[DEATH] ", ime)
		if _je_multiplayer_aktivan():
			_isplati_personal_loot()
			_isplati_kill()
			var goblin_root = get_parent()  # Node3D wrapper
			var world = goblin_root.get_parent() if goblin_root else null
			if world and world.has_method("despawn_goblin_svima"):
				world.despawn_goblin_svima(goblin_root.name)
			elif goblin_root:
				goblin_root.queue_free()
		else:
			_drop_fizicki_loot()
			var hud = get_tree().get_first_node_in_group("hud")
			if hud:
				hud.dodaj_xp(xp_nagrada)
			QuestManager.azuriraj_progres_kill(ime.to_lower())
			queue_free()

@rpc("call_local", "reliable")
func _obavesti_smrt() -> void:
	pass  # samo "reliable" okidač da se despawn sigurno propagira i pre nego što queue_free stigne

# Kockice za jednog igrača. Stavka sa "min_nivo" pada samo od instance bar tog nivoa (najbolja oprema: trol nivoa 10).
func baci_loot() -> Array:
	var dobijeno: Array = []
	for loot in loot_tabela:
		if nivo >= int(loot.get("min_nivo", 0)) and randf() * 100.0 < float(loot["sansa"]):
			dobijeno.append(loot["id"])
	return dobijeno

func _drop_fizicki_loot() -> void:
	for id in baci_loot():
		var item_scena = load("res://Scenes/Items/item.tscn")
		var item = item_scena.instantiate()
		item.ime_itema = id
		get_tree().root.add_child(item)
		item.global_position = global_position + Vector3(
			randf_range(-1.0, 1.0),
			0.5,
			randf_range(-1.0, 1.0)
		)

func _isplati_personal_loot() -> void:
	if not multiplayer.is_server():
		return
	print("[LOOT] ", ime, " umro, napadači: ", napadaci)
	for peer_id in napadaci: # loot samo onima koji su naneli štetu (i host kad igra sam)
		var igrac = _nadji_igraca_po_id(peer_id)
		if igrac == null or not igrac.has_method("server_isplati_loot"):
			print("[LOOT] Nema igrača za peer ", peer_id)
			continue
		if igrac.mrtav:
			continue  # mrtav igrač ne dobija loot
		# bacanje kockica je sinhrono, a upis u bazu preuzima igrač
		var dobijeno := baci_loot()
		if not dobijeno.is_empty():
			igrac.server_isplati_loot(dobijeno)

# XP + kill progres za sve koji su naneli damage; XP posebno za svakog prema njegovom nivou (server)
func _isplati_kill() -> void:
	for peer_id in napadaci:
		var igrac = _nadji_igraca_po_id(peer_id)
		if igrac == null:
			continue
		var xp := xp_za_razliku(xp_nagrada, int(nivo) - int(igrac.nivo_lika))
		igrac.server_zabelezi_kill(ime.to_lower())
		igrac.server_isplati_xp(xp, "kill:" + ime.to_lower())
		if peer_id == multiplayer.get_unique_id():
			igrac.primi_kill(ime.to_lower(), xp)
		else:
			igrac.primi_kill.rpc_id(peer_id, ime.to_lower(), xp)

# Samo na serveru: šteta ide direktno na Player node mete (oklop se računa u igraču)
func napadni_igraca():
	if player == null or not is_instance_valid(player) or player.mrtav:
		return
	# server proverava domet (mala tolerancija zbog kretanja između frejmova)
	if global_position.distance_to(player.global_position) > napad_range + 0.5:
		return
	moze_napasti = false
	player.server_primi_damage(napad_damage)

	await get_tree().create_timer(napad_cooldown).timeout
	moze_napasti = true
