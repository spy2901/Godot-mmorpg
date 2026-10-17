extends SceneTree
# Drajver za test-pi: dva prava klijenta (agent_test nalozi) protiv game servera na Pi-ju.
#   godot [--headless] --path . --script res://.claude/skills/test-pi/driver.gd -- igrac1|igrac2 dir=/abs/out \
#         host=spajko port=7777 [shot=/abs/slika.png] [registruj=1] --server-url=http://spajko:8001
# Kredencijali stižu SAMO kroz env (TEST_USER_n / TEST_PASS_n iz .env.test), nikad kroz argumente ni log.
# Uloge se usklađuju preko fajlova u dir/ (stanje, pomeranje, kraj), ne po satu. Ispisuje PASS/FAIL linije.

var uloga := ""
var dir := ""
var host := ""
var port := 7777
var shot := ""
var registruj := false
var t := 0.0
var _krenuo := false
var _kraj := false
const MAX_T := 120.0
const GRESKA_WARN_M := 1.0 # najveća greška predikcije iznad ovoga = WARN

func _initialize():
	var args := OS.get_cmdline_user_args()
	uloga = args[0] if args.size() > 0 else ""
	for a in args:
		if a.begins_with("dir="): dir = a.substr(4)
		if a.begins_with("host="): host = a.substr(5)
		if a.begins_with("port="): port = int(a.substr(5))
		if a.begins_with("shot="): shot = a.substr(5)
		if a == "registruj=1": registruj = true

func _process(d):
	t += d
	if not _krenuo and root.has_node("GameState"): # autoload-ovi nisu u stablu u _initialize
		_krenuo = true
		_scenario()
	if t > MAX_T and not _kraj:
		_provera("zavrseno_na_vreme", false, "prekoračeno %d s" % MAX_T)
		return true
	return _kraj

func _provera(ime: String, ok: bool, detalj: String) -> void:
	print("%s %s:%s  %s" % ["PASS" if ok else "FAIL", uloga, ime, detalj])

func _cekaj(uslov: Callable, sek: float) -> bool:
	var kraj := Time.get_ticks_msec() + int(sek * 1000)
	while not uslov.call():
		if Time.get_ticks_msec() > kraj: return false
		await process_frame
	return true

func _pritisni(k: Key) -> void:
	for dole in [true, false]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = dole
		Input.parse_input_event(e)

func _snimi(sufiks: String) -> void:
	if shot == "":
		return
	for i in 3: # da se poslednja promena UI-ja iscrta
		await process_frame
	var putanja := shot.get_basename() + sufiks + ".png"
	root.get_viewport().get_texture().get_image().save_png(putanja)
	print("[igrac1] screenshot -> ", putanja)

# Taster 1 = small_health_potion (reset_stanje.py: 3 komada u bazi, HP 60). Prvi pritisak: HP 88-100, slot 2.
# Drugi odmah po potvrdi prvog iz stanja servera (količina 2 i cooldown): "Još nije spremno" + overlay sa sekundama.
# Količinu u BAZI (3 -> 2) proverava run.sh posle klijenata (klijent nema server key).
func _action_bar(p, hud) -> void:
	var bar = p.get_node_or_null("ui/ActionBar")
	var ima: bool = bar != null and bar.has_method("koristi_slot")
	var spreman: bool = ima and await _cekaj(func(): return bar.slotovi.size() > 0 and bar.slotovi[0] == "small_health_potion" \
		and bar.kolicina(0) == 3 and bar._prikaz[0].oznaka.text != "", 10.0)
	await _snimi("_bar")
	var odg := []
	var hvataj := func(d): odg.append(d)
	p.item_odgovor.connect(hvataj)
	var hp0: int = hud.hp
	_pritisni(KEY_1)
	# potvrda iz stanja: odgovor stigao, server javio količinu 2 i cooldown, klijentski zahtev završen
	var potvrda: bool = await _cekaj(func(): return odg.size() >= 1 and ima and bar.kolicina(0) == 2 and bar.preostalo_ms(0) > 0 \
		and not p._zahtevi_u_toku.has("item"), 5.0)
	_pritisni(KEY_1)
	_pisi("igrac1_bar", "1")
	await _cekaj(func(): return odg.size() >= 2, 5.0)
	p.item_odgovor.disconnect(hvataj)
	for i in 2: await process_frame
	var cd_txt: String = bar._prikaz[0].cd.text if ima else ""
	var overlay: bool = ima and bar._prikaz[0].overlay.visible
	_provera("action_bar_napitak", spreman and potvrda and odg[0].get("ok", false) and hud.hp >= 88 and hud.hp <= 100 \
		and bar.kolicina(0) == 2 and bar._prikaz[0].kolicina.text == "2",
		"bar=%s slot1 '%s' x%s, hp %d->%d, odgovor=%s" % [ima, bar._prikaz[0].oznaka.text if ima else "-", bar._prikaz[0].kolicina.text if ima else "-", hp0, hud.hp, odg[0] if odg.size() > 0 else "-"])
	_provera("action_bar_cooldown", odg.size() == 2 and odg[1].get("poruka") == "Not ready yet" and overlay and cd_txt.is_valid_int() and int(cd_txt) > 0,
		"odgovor=%s overlay=%s sekundi='%s'" % [odg[1] if odg.size() > 1 else "-", overlay, cd_txt])
	await _snimi("_cooldown")

# Statistike lika iz prave baze, samo čitanje (bez opremanja): server ih pošalje posle učitavanja. agent_test
# likovi nemaju opremu, pa je attack = osnovni napad iz baze, armor 0, max HP = maksimum iz baze. igrac1 snimi
# inventar sa sažetkom statistika (pa ga zatvori).
func _statistike(p, hud) -> void:
	var inv = p.get_node("ui/InventoryUI")
	var stigle: bool = await _cekaj(func(): return p.stat_max_hp > 0, 10.0)
	var bez_opreme: bool = inv.equipped_items.values().all(func(x): return x.is_empty())
	var ocek := "Attack: %d   Armor: %d   Max HP: %d" % [p.napad_damage, 0, hud.max_hp]
	_provera("statistike_na_pravom_serveru", stigle and bez_opreme and p.stat_attack == p.napad_damage and p.stat_armor == 0
		and p.stat_max_hp == hud.max_hp and inv.stat_label.text == ocek,
		"attack %d (osnovni %d), armor %d, max HP %d (HUD %d), oprema prazna=%s, sažetak '%s'" % [p.stat_attack, p.napad_damage, p.stat_armor, p.stat_max_hp, hud.max_hp, bez_opreme, inv.stat_label.text])
	# napredak (migracija 008 + novi backend): statistike učitanog lika odgovaraju njegovom nivou po odobrenoj krivi
	# (bez opreme: max HP = osnovni). Samo čitanje, nema ubistava ni XP-a.
	var L: int = hud.level
	var ocek_np := [0 if L == 20 else 25 * L * L + 75 * L, 100 + 15 * (L - 1), 100 + 10 * (L - 1), 10 + 2 * (L - 1)]
	var xp_lbl = hud.xp_bar.get_node_or_null("XPLabel")
	var ocek_xp := "XP: MAX  |  Lv.20" if L == 20 else "XP: %d / %d  |  Lv.%d" % [hud.xp, ocek_np[0], L]
	_provera("napredak_na_pravom_serveru", stigle and bez_opreme and L >= 1 and L <= 20 and hud.xp >= 0
		and (hud.xp < hud.max_xp or (L == 20 and hud.xp == 0)) and [hud.max_xp, hud.max_hp, hud.max_mana, p.napad_damage] == ocek_np
		and p.stat_attack == p.napad_damage and xp_lbl != null and xp_lbl.text == ocek_xp,
		"Lv.%d xp %d: max_xp/max HP/max mana/napad %s (za nivo %s), traka '%s' (očekivano '%s')" % [L, hud.xp,
		[hud.max_xp, hud.max_hp, hud.max_mana, p.napad_damage], ocek_np, xp_lbl.text if xp_lbl else "-", ocek_xp])
	if shot != "" and uloga == "igrac1":
		inv.visible = true
		await _snimi("_inventar")
		inv.visible = false

func _cilj(p) -> void:
	var e = null
	for n in get_nodes_in_group("neprijatelj"):
		var d: float = n.global_position.distance_to(p.server_poz)
		if not n._mrtav and d < p.MAX_DOMET_CILJA - 5.0 and (e == null or d < e.global_position.distance_to(p.server_poz)):
			e = n
	if e == null:
		_provera("cilj_na_pravom_serveru", false, "nema živog neprijatelja bliže od %.0f m" % (p.MAX_DOMET_CILJA - 5.0))
		return
	var id := str(e.get_parent().name)
	var poz0: Vector3 = e.global_position
	var t0 := Time.get_ticks_msec()
	var kraj := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < kraj and is_instance_valid(e): # okreni se ka njemu (kamera je iza lika)
		var dv: Vector3 = e.global_position - p.global_position
		p.rotation.y = atan2(-dv.x, -dv.z)
		await process_frame
	if not is_instance_valid(e):
		_provera("cilj_na_pravom_serveru", false, "%s nestao pre klika" % id)
		return
	var poz: Vector2 = p.kamera.unproject_position(e.global_position)
	for dole in [true, false]:
		var k := InputEventMouseButton.new()
		k.button_index = MOUSE_BUTTON_LEFT
		k.pressed = dole
		k.position = poz
		k.global_position = poz
		Input.parse_input_event(k)
	var okvir = p.get_node("ui/OkvirCilja")
	var izabran: bool = await _cekaj(func(): return p.cilj_id == id and okvir.okvir.visible, 5.0)
	var hp_ok: bool = is_instance_valid(e) and okvir.hp_tekst.text == "%d / %d" % [e.hp, e.max_hp]
	await _snimi("_cilj")
	var tekst: String = okvir.ime.text + " " + okvir.hp_tekst.text
	_provera("traka_pretnje_sakrivena_na_pravom_serveru", izabran and p.cilj_pretnja == -1 and not okvir.pretnja.visible,
		"%s izabran=%s, moja pretnja %d, traka vidljiva=%s (screenshot _cilj)" % [id, izabran, p.cilj_pretnja, okvir.pretnja.visible])
	_miruje_na_pocetku(e, poz0, t0)
	await _napad_predaleko(p, e, izabran)
	_pritisni(KEY_ESCAPE)
	var skinut: bool = await _cekaj(func(): return p.cilj_id == "" and not okvir.okvir.visible, 5.0)
	_provera("cilj_na_pravom_serveru", izabran and hp_ok and skinut,
		"%s na %.1f m: izabran=%s okvir '%s' (hp ok=%s), Esc skinuo=%s" % [id, e.global_position.distance_to(p.server_poz) if is_instance_valid(e) else -1.0, izabran, tekst, hp_ok, skinut])

# Neprijatelj daleko od svih likova (van aggro_range) stoji na svojoj spawn tački i ne pomera se (replicirana pozicija).
func _miruje_na_pocetku(e, poz0: Vector3, t0: int) -> void:
	if not is_instance_valid(e):
		_provera("neprijatelj_miruje_na_pocetku", false, "neprijatelj nestao")
		return
	var tacka = null
	for tk in get_nodes_in_group("spawn_tacka"):
		if tk.vrsta == str(e.get_parent().name).get_slice("_", 0) and (tacka == null or _xz(tk.global_position, e.global_position) < _xz(tacka.global_position, e.global_position)):
			tacka = tk
	var od_tacke: float = _xz(tacka.global_position, e.global_position) if tacka else -1.0
	var najblizi := INF
	for pl in get_nodes_in_group("player"):
		najblizi = minf(najblizi, pl.global_position.distance_to(e.global_position))
	var pomeraj := _xz(poz0, e.global_position)
	_provera("neprijatelj_miruje_na_pocetku", tacka != null and od_tacke < 1.0 and pomeraj < 0.05 and najblizi > e.aggro_range,
		"%s %.1f m od spawn tačke, pomeraj %.2f m za %.1f s, najbliži lik %.1f m (aggro %.0f m)" % [e.get_parent().name, od_tacke, pomeraj, (Time.get_ticks_msec() - t0) / 1000.0, najblizi, e.aggro_range])

func _xz(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))

# Jedan napad (R) na izabran cilj van dometa napada: server odbija sa "Predaleko", bez štete. Ne ubija neprijatelje
# (XP i loot test naloga su u pravoj bazi), pa se R ne pritiska ako je cilj blizu.
func _napad_predaleko(p, e, izabran: bool) -> void:
	var d: float = e.global_position.distance_to(p.server_poz) if is_instance_valid(e) else -1.0
	if not izabran or d < p.DOMET_NAPADA + 2.0:
		_provera("napad_predaleko_na_pravom_serveru", false, "cilj izabran=%s na %.1f m (treba > %.1f m), R nije pritisnut" % [izabran, d, p.DOMET_NAPADA + 2.0])
		return
	var odg := []
	p.napad_odgovor.connect(func(o): odg.append(o))
	var hp0: int = e.hp
	_pritisni(KEY_R)
	await _cekaj(func(): return odg.size() >= 1, 5.0)
	await create_timer(0.5).timeout # da bi se video eventualni drugi odgovor ili šteta
	await _snimi("_napad")
	var hp1: int = e.hp if is_instance_valid(e) else -1
	_provera("napad_predaleko_na_pravom_serveru", odg.size() == 1 and odg[0].get("poruka") == "Too far" and hp1 == hp0,
		"cilj na %.1f m, odgovor %s, hp %d->%d" % [d, odg[0] if odg.size() > 0 else "-", hp0, hp1])

func _pisi(ime: String, s: String) -> void:
	var f := FileAccess.open(dir + "/" + ime, FileAccess.WRITE)
	f.store_string(s)
	f.close()

func _citaj(ime: String) -> String:
	return FileAccess.get_file_as_string(dir + "/" + ime) if FileAccess.file_exists(dir + "/" + ime) else ""

func _drugi_uloga() -> String:
	return "igrac2" if uloga == "igrac1" else "igrac1"

func _world(): return current_scene.get_node_or_null("World") if current_scene else null
func _moj():
	if _world() == null or not get_multiplayer().has_multiplayer_peer(): return null
	return _world().get_node_or_null(str(get_multiplayer().get_unique_id()))
func _lik_po_imenu(ime: String):
	if _world() == null: return null
	for p in _world().get_children():
		if p.is_in_group("player") and p != _moj() and p.ime_sync == ime: return p
	return null

func _zavrsi() -> void:
	_pisi(uloga + "_gotov", "1")
	await _cekaj(func(): return _citaj(_drugi_uloga() + "_gotov") != "", 30.0) # drugi još meri nas
	var gs = root.get_node("GameState")
	if gs.token != "":
		await root.get_node("ApiManager").logout(gs.token) # oslobodi sesiju na backendu
	_kraj = true

# ---------------------------------------------------------------- SCENARIO

func _scenario() -> void:
	var api = root.get_node("ApiManager")
	var gs = root.get_node("GameState")
	var n := "1" if uloga == "igrac1" else "2"
	var korisnik := OS.get_environment("TEST_USER_" + n)
	var lozinka := OS.get_environment("TEST_PASS_" + n)
	if not korisnik.begins_with("agent_test"):
		_provera("nalog", false, "TEST_USER_%s mora počinjati sa agent_test" % n)
		_kraj = true
		return

	# 1. pravi /auth tok (login; registracija samo ako nalog ne postoji i registruj=1)
	var r: Dictionary = await api.login(korisnik, lozinka)
	var registrovan := false
	if not r.has("token") and registruj:
		var reg: Dictionary = await api.register(korisnik, lozinka)
		if not reg.has("error"):
			registrovan = true
			r = await api.login(korisnik, lozinka)
		else:
			r = {"error": "login: %s / registracija: %s" % [r.get("error", "?"), reg.error]}
	var ime := str(r.get("ime_lika", ""))
	_provera("prijava", r.has("token") and ime != "", "lik=%s%s%s" % [ime, " (nalog upravo registrovan)" if registrovan else "", "" if r.has("token") else " greška: " + str(r.get("error", "?"))])
	if not r.has("token"):
		_kraj = true
		return
	# direktno (ne GameState.prijavi): ne prepisujemo zapamćeno korisničko ime u user://settings.cfg
	gs.token = str(r.token)
	gs.ime_igraca = ime

	# 2. konekcija na Pi game server
	change_scene_to_file("res://Scenes/UI/MultiplayerTest.tscn")
	await create_timer(1.0).timeout
	var ip := IP.resolve_hostname(host, IP.TYPE_IPV4)
	var spojen: bool = ip != "" and root.get_node("NetworkManager").pridruzi_se(ip, port)
	spojen = spojen and await _cekaj(func(): return _moj() != null, 20.0)
	_provera("konekcija", spojen, "%s (%s):%d" % [host, ip, port])
	if not spojen:
		await _zavrsi()
		return
	var p = _moj()
	var hud = p.get_node("ui/Control")

	# 3. lik iz prave baze: server ga učita (token -> /auth/verify -> /players) i pošalje primi_lik
	var ucitan: bool = await _cekaj(func(): return hud._ucitano and p._inicijalizovan, 20.0)
	# pozicija iz baze stiže kao reset 2 (reset 1 = spawn); bez ovoga merenja počinju sa spawn tačke
	var reset_baze: bool = await _cekaj(func(): return p._reset_id_prim >= 2, 10.0)
	_provera("lik_ucitan_iz_baze", ucitan and reset_baze and hud.ime_igraca == ime, "lv=%d hp=%d/%d mana=%d/%d gold=%d poz=%s reset_id=%d" % [hud.level, hud.hp, hud.max_hp, hud.mana, hud.max_mana, hud.gold, p.server_poz, p._reset_id_prim])
	await _statistike(p, hud)
	if not ucitan:
		await _zavrsi()
		return
	_provera("hp_mana", hud.max_hp > 0 and hud.hp > 0 and hud.hp <= hud.max_hp and hud.mana >= 0 and hud.mana <= hud.max_mana and not hud.je_mrtav,
		"hp=%d/%d mana=%d/%d mrtav=%s" % [hud.hp, hud.max_hp, hud.mana, hud.max_mana, hud.je_mrtav])
	# 3b. action bar na pravom serveru (igrac1), odmah posle učitavanja: HP 60 iz reset_stanje.py, regen +2/s
	if uloga == "igrac1":
		await _action_bar(p, hud)
	_pisi(uloga + "_ime", ime)

	# 4. drugi igrač: nameplate sa njegovim imenom i HP-om koji server šalje (poredi se sa njegovim HUD-om)
	await _cekaj(func():
		var ime2 := _citaj(_drugi_uloga() + "_ime")
		return ime2 != "" and _lik_po_imenu(ime2) != null, 30.0)
	var drugo_ime := _citaj(_drugi_uloga() + "_ime")
	var o = _lik_po_imenu(drugo_ime)
	if o == null:
		_provera("nameplate_drugog", false, "ne vidim drugog igrača (ime='%s')" % drugo_ime)
		await _zavrsi()
		return
	_pisi(uloga + "_hp", str(hud.hp))
	var hp_ok: bool = await _cekaj(func():
		_pisi(uloga + "_hp", str(hud.hp))
		return o.hp_sync == int(_citaj(_drugi_uloga() + "_hp")), 5.0)
	var np = o.get_node_or_null("Nameplate")
	var daljina: float = o.global_position.distance_to(p.global_position)
	var vidljiv: bool = np != null and (np.visible or daljina > o.MAX_PRIKAZ_DALJINA)
	_provera("nameplate_drugog", np != null and vidljiv and o.ime_sync == drugo_ime and hp_ok and not p.has_node("Nameplate"),
		"ime=%s hp_sync=%d/%d (njegov HUD %s) vidljiv=%s daljina=%.1f m" % [o.ime_sync, o.hp_sync, o.max_hp_sync, _citaj(_drugi_uloga() + "_hp"), np.visible if np else false, daljina])

	# 5. kretanje: igrac1 hoda 1 s (server authority + predikcija), igrac2 gleda
	# igrac2 uzima početnu poziciju tuđeg lika tek kad je igrac1 primenio reset iz baze, igrac1 hoda tek posle toga
	if uloga == "igrac1":
		_pisi("igrac1_spreman", "1")
		await _cekaj(func(): return _citaj("igrac2_start") != "", 15.0)
		# ka centru mape: pozicija se čuva u bazi, uvek isti smer bi lik svakim pokretanjem gurao ka ivici
		p.rotation.y = atan2(p.global_position.x, p.global_position.z) # napred je -basis.z
		await create_timer(0.5).timeout
		var pre: Vector3 = p.server_poz
		Input.action_press("ui_up")
		await create_timer(1.0).timeout
		Input.action_release("ui_up")
		# čekaj da server potvrdi poslednji unos sa W (seq u stanju >= seq pri puštanju), ne fiksno vreme:
		# pri RTT od par stotina ms unosi još nisu obrađeni posle 0,7 s
		var poslednji: int = p._seq
		var t_pusten := Time.get_ticks_msec()
		var potvrdjen: bool = await _cekaj(func(): return p._buffer.is_empty() or p._buffer[0][0] > poslednji, 10.0)
		await create_timer(0.1).timeout # stanje posle potvrde primenjeno u physics tick-u
		var hod: float = p.server_poz.distance_to(pre)
		var razlika: float = p.global_position.distance_to(p.server_poz)
		_provera("kretanje_server_authority", potvrdjen and hod > 3.0 and hod < 7.0 and razlika < 0.1,
			"server pomeren %.2f m za 1 s (očekivano ~5), predikcija-server %.3f m, korekcije %d/%d, greška max %.3f m, potvrda poslednjeg unosa posle %s ms" % [hod, razlika, p.korekcije_glatke, p.korekcije_snap, p.greska_max, str(Time.get_ticks_msec() - t_pusten) if potvrdjen else "nije stigla (10 s)"])
		_pisi("igrac1_pomeren", "%f" % hod)
	else:
		await _cekaj(func(): return _citaj("igrac1_spreman") != "", 30.0)
		await create_timer(0.5).timeout # INTERP_DELAY + rezerva: tuđi lik je stigao na poziciju iz baze
		var start: Vector3 = o.global_position
		_pisi("igrac2_start", "1")
		var dosao: bool = await _cekaj(func(): return _citaj("igrac1_pomeren") != "", 30.0)
		await create_timer(0.5).timeout # INTERP_DELAY + rezerva
		var vidi: float = o.global_position.distance_to(start)
		var server_hod := float(_citaj("igrac1_pomeren"))
		_provera("drugi_vidi_kretanje", dosao and absf(vidi - server_hod) < 0.3, "vidim %.2f m, server %.2f m" % [vidi, server_hod])

	# 6. screenshot (igrac1 u prozoru): okreni se ka drugom igraču pa snimi
	if shot != "" and uloga == "igrac1":
		var kraj := Time.get_ticks_msec() + 1500
		while Time.get_ticks_msec() < kraj:
			var dv: Vector3 = o.global_position - p.global_position
			p.rotation.y = atan2(-dv.x, -dv.z) # napred je -basis.z
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(shot)
		print("[%s] screenshot -> %s (drugi igrač na %.1f m)" % [uloga, shot, o.global_position.distance_to(p.global_position)])
	# 6b. ciljanje na pravom serveru (igrac1 u prozoru): najbliži živ neprijatelj u dometu, klik, okvir, screenshot, Esc
	if shot != "" and uloga == "igrac1":
		await _cilj(p)
	# greška predikcije sopstvenog lika (npr. snap pri prijavi kad se izgubi reset): WARN, ne FAIL
	if p.greska_max > GRESKA_WARN_M:
		print("WARN %s:greska_predikcije  najveća %.3f m > %.1f m (korekcije glatke %d, snap %d)" % [uloga, p.greska_max, GRESKA_WARN_M, p.korekcije_glatke, p.korekcije_snap])
	await _zavrsi()
