extends SceneTree
# Drajver za mmorpg: jedan Godot proces = jedna uloga.
#   godot --headless --path . --script res://.claude/skills/run-mmorpg/driver.gd -- server
#   godot --headless --path . --script res://.claude/skills/run-mmorpg/driver.gd -- observer
#   godot            --path . --script res://.claude/skills/run-mmorpg/driver.gd -- observer dir=/abs/out shot=/abs/out/nameplate
#   server prima i stop=/abs/fajl: gasi se kad fajl postoji (run.sh ga pravi kad mover ispiše CEKAM_GASENJE)
# Pokreće se preko run.sh (server -> observer -> mover). Ispisuje PASS/FAIL linije.
# Backend nije potreban: klijent bez imena lika ne šalje token, pa ga server ne izbacuje.

var uloga := ""
var shot := ""
var stop := ""
var dir := ""           # zajednički direktorijum: mover upisuje fazu u dir/faza, server je čita
var _cpp := {}          # mover: checkpoint -> predviđena (lokalna) pozicija
var _kor := {}          # mover: checkpoint -> [glatke, snap]
var _faza_rupe := {}    # server: faza -> preskočeni seq-ovi
var _teleportovano := false
var _visi_sklonjen := false
const VISI_PARKING := Vector3(14, 1.16, -14) # van putanje movera (x -9..6, z -12..16), daleko od ostalih likova
var _poslednja_faza := ""
var _faza_vreme := {}   # server: faza -> [od, do] (unix s), za zastoj u toku faze
# test rafala: mover zadrži ~24 unosa (0.4 s) pa ih pošalje odjednom; red mora da ih primi i isprazni.
# Višak od ~14 preko kofe se prazni brzinom 1.2*60 - 60 = 12/s -> ~1.2 s; granica sa rezervom:
const RAFAL_PRAZNJENJE_MAX_MS := 2500
var _rafal_vrh := 0
var _rafal_ms := -1
var _rafal_pre := []    # red_zaostatak na ulasku u fazu rafal
var _reset_od := -1.0
var _resetovan := false
var _mover_red_max := 0
var _mover_odbijeno := 0
var _red_max_dozvoljen := 0
var _obs_pre = null     # observer: pozicija tuđeg lika u prošlom frame-u
var _obs_od := -1.0
var _obs_kraci := 0     # koraka većih od brzina*dt*2 (a manjih od PRAG_SNAP)
var _obs_snap := 0
var _obs_max := 0.0     # najveći korak / (brzina*dt)
var _obs_d := 0.0       # delta prethodnog frame-a
var _potion_krenuo := false
var _potion_kraj := false
var _cmd_izvrsena := ""  # server: poslednja izvršena komanda iz dir/potion_cmd
var _server_hp_upisan := ""
var _nameplate_na_serveru := false
# observer: nameplate provere (tuđi lik TestLik)
var _spreman := false
var _sync_poklapanja := 0
var _server_hp_pre := ""
var _cekana_steta := -1     # hp posle poslednje štete na serveru, čeka se u hp_sync
var _steta_ms := 0
var _stete := 0
var _max_kasnjenje_ms := 0
var _samo_tudji := false
var _video_mrtvog := false
var _video_respawn := false
var _snimljeno := {}        # kategorija -> boja/stanje ok
var _snimak_frame := -1
# zastoj klijenta (za seq_bez_rupa_bez_gubitka): meri se tek kad mover upiše fazu, bez prve sekunde faze
const ZASTOJ_PRAG := 0.1    # s: duži frame je zastoj
const ZASTOJ_WARMUP := 1.0  # s od početka faze
const ZASTOJ_PROZOR := 0.5  # s: rupa je opravdana samo zastojem istog procesa u +-0.5 s
var _max_delta := 0.0
var _faza_merenja := ""
var _faza_od := 0.0
var _zastoji: PackedStringArray = [] # "t_kraj delta" (unix s)
var _rupe_po_igracu := {}   # server: peer -> poslednji rupe_seq
var _rupe_dogadjaji := []   # server: [t, peer, broj, faza]
var _ceka_gasenje := -1.0
var _menu_t := -1.0       # mover: kad je MainMenu postao aktivan # mover: t kad je počeo da čeka gašenje servera
var t := 0.0
var _faza := ""
var _log_t := 0.0
var _cp := {}          # mover: checkpoint -> pozicija
var _slikano := false
var _video_yaw := false # observer: video tuđi yaw_sync ~ PI/2
var _yaw_t := -1.0      # observer: kad je prvi put video yaw
var _video_drugog := false
var _paket_vel := {} # mover: kategorija -> [zbir bajtova, broj, max]
var _t0 := -1.0         # mover: početak vremenske ose (lik stao na pod)
var _spawn = null       # mover: [vreme, pozicija] pojave lika (za ispis kad na_podu padne)
const PODLOGA_TIMEOUT := 5.0
const MAX_T := 120.0    # zaštita od zaglavljivanja
# s: rok za drugi proces iste provere (PosmatracLik, DrugiLik, Oprema2Lik, Buff2Lik). Server prima MAX_PLAYERS (8) peer-a, pa
# klijenti čekaju mesto, a redosled ulaska nije određen (PosmatracLik ume da uđe posle QuestLik-a i 20 drugih prijava).
# Rok je gornja granica: čeka se uslov. Uloga koja čeka partnera živi 2 * MAX_T.
const PARTNER_ROK := MAX_T
const PORUKA_SLEDECA := 2.3 # s: duže od TopBar.PORUKA_TRAJANJE
var _max_t := 3 * MAX_T # server: duže od uloga (2 * MAX_T od svog starta); repro_login.sh zadaje svoj (maxt=)
var _aktivnost := false # prijava: reliable zahtevi za predmet dok traje sesija
var _izgubi_reset := false # prijava: klijent odbaci reset posle prijave (test hook)
var _korak := 0           # raspored: 1 = menja raspored i odjavi se, 2 = ponovna prijava (novi proces)

func _initialize():
	var args := OS.get_cmdline_user_args()
	uloga = args[0] if args.size() > 0 else ""
	for a in args:
		if a.begins_with("shot="):
			shot = a.substr(5)
		if a.begins_with("stop="):
			stop = a.substr(5)
		if a.begins_with("dir="):
			dir = a.substr(4)
		if a.begins_with("maxt="):
			_max_t = float(a.substr(5))
		if a == "aktivnost=1":
			_aktivnost = true
		if a == "izgubi_reset=1":
			_izgubi_reset = true
		if a.begins_with("korak="):
			_korak = int(a.substr(6))

func _nm(): return root.get_node("NetworkManager")

# Server prima najviše NetworkManager.MAX_PLAYERS (8) peer-a, a run.sh pokreće ~15 klijenata: klijent koji se javi dok
# su sva mesta zauzeta dobije connection_failed. Ponovo se povezuje kad se mesto oslobodi (rok POVEZIVANJE_ROK s).
const POVEZIVANJE_ROK := 60.0
var _pokusaji_veze := 0
func _ponovi_povezivanje() -> void:
	_pokusaji_veze += 1
	if t > POVEZIVANJE_ROK:
		print("[T] konekcija neuspešna, rok od %.0f s istekao posle %d pokušaja" % [POVEZIVANJE_ROK, _pokusaji_veze])
		return
	print("[T] konekcija neuspešna (server pun?), pokušaj %d za 1 s" % (_pokusaji_veze + 1))
	_nm().prekini()
	await create_timer(1.0).timeout
	_nm().pridruzi_se("127.0.0.1")
func _world(): return current_scene.get_node_or_null("World") if current_scene else null
func _id() -> String:
	return str(get_multiplayer().get_unique_id()) if get_multiplayer().has_multiplayer_peer() else ""
func _moj():
	return _world().get_node_or_null(_id()) if _world() else null
# observer gleda movera: njegov peer_id je u dir/faza (mover ga upisuje od prve faze)
func _drugi():
	if _world() == null: return null
	var f := FileAccess.get_file_as_string(dir + "/faza").split(" ") if dir != "" else PackedStringArray()
	if f.size() == 2: return _world().get_node_or_null(f[1])
	return null
func _fmt(p) -> String:
	var g: Vector3 = p.global_position
	return "pos=(%.2f, %.2f, %.2f) rot.y=%.2f yaw_sync=%.2f" % [g.x, g.y, g.z, p.rotation.y, p.yaw_sync]
func _provera(ime: String, ok: bool, detalj: String) -> void:
	print("%s %s  %s" % ["PASS" if ok else "FAIL", ime, detalj])

func _process(d):
	t += d
	# Autoload-ovi nisu u stablu u _initialize; čekamo prvi frame
	if _faza == "":
		if root.has_node("GameState"):
			root.get_node("GameState").token = "x" # bez tokena MultiplayerTest vraća na login
			if uloga == "potion" or uloga == "prijava": # pravi login preko stub API-ja (token -> TestLik)
				root.get_node("GameState").token = "potion-token"
				root.get_node("GameState").ime_igraca = "TestLik"
			elif uloga == "visi": # verify ovog tokena u stub-u visi: server mora da ga izbaci posle UCITAVANJE_TIMEOUT
				root.get_node("GameState").token = "visi-token"
				root.get_node("GameState").ime_igraca = "VisiLik"
			elif uloga == "cilj":
				root.size = Vector2i(1280, 720) # headless prozor je 64x64: action bar bi pokrio ceo ekran i progutao klikove
				root.get_node("GameState").token = "cilj-token"
				root.get_node("GameState").ime_igraca = "CiljLik"
			elif uloga == "drugi":
				root.size = Vector2i(1280, 720) # kao cilj: u 64x64 bi action bar progutao klik
				root.get_node("GameState").token = "drugi-token"
				root.get_node("GameState").ime_igraca = "DrugiLik"
			elif uloga == "oprema": # korak=1 i 2 OpremaLik (2 = ponovna prijava), korak=3 Oprema2Lik (drugi igrač)
				var ime := "Oprema2Lik" if _korak == 3 else "OpremaLik"
				root.get_node("GameState").token = "oprema2-token" if _korak == 3 else "oprema-token"
				root.get_node("GameState").ime_igraca = ime
			elif uloga == "ai": # korak=1 AiLik, korak=2 Ai2Lik
				var ime := "AiLik" if _korak == 1 else "Ai2Lik"
				root.get_node("GameState").token = ime.to_lower() + "-token"
				root.get_node("GameState").ime_igraca = ime
			elif uloga == "napredak": # korak=1 ubistva i level-up, korak=2 ponovna prijava
				root.get_node("GameState").token = "napredak-token"
				root.get_node("GameState").ime_igraca = "NapredakLik"
			elif uloga == "quest": # korak=1 QuestLik (klikće NPC-a), korak=2 PosmatracLik (ne napada)
				root.get_node("GameState").token = ["", "quest-token", "posmatrac-token", "lovac-token"][_korak]
				root.get_node("GameState").ime_igraca = ["", "QuestLik", "PosmatracLik", "LovacLik"][_korak]
				root.size = Vector2i(1280, 720)
			elif uloga == "buff": # korak=1 BuffLik (eliksiri), korak=2 Buff2Lik (napadač bez buff-a)
				root.size = Vector2i(1280, 720) # tooltip i HUD kao u prozoru
				root.get_node("GameState").token = "buff-token" if _korak == 1 else "buff2-token"
				root.get_node("GameState").ime_igraca = "BuffLik" if _korak == 1 else "Buff2Lik"
			elif uloga == "brzina": # korak=1 BrzinaLik (buff brzine pod veštačkim RTT-om), korak=2 ponovna prijava
				root.get_node("GameState").token = "brzina-token"
				root.get_node("GameState").ime_igraca = "BrzinaLik"
			elif uloga == "efekti": # korak=1 EfektiLik (napici efekata, otrov), korak=2 Efekti2Lik (druga meta, posmatrač)
				root.size = Vector2i(1280, 720) # tooltip i HUD kao u prozoru
				root.get_node("GameState").token = "efekti-token" if _korak == 1 else "efekti2-token"
				root.get_node("GameState").ime_igraca = "EfektiLik" if _korak == 1 else "Efekti2Lik"
			elif uloga == "raspored":
				root.get_node("GameState").token = "raspored-token"
				root.size = Vector2i(1280, 720) # headless je 64x64: traka bi virila van prozora, a okvir cilja ležao preko nje
				root.get_node("GameState").ime_igraca = "RasporedLik"
			elif uloga == "mover" or uloga == "observer": # server objavljuje lika ostalima tek posle učitavanja
				root.get_node("GameState").token = uloga + "-token"
				root.get_node("GameState").ime_igraca = "MoverLik" if uloga == "mover" else "ObserverLik"
			change_scene_to_file("res://Scenes/UI/MultiplayerTest.tscn")
			_faza = "scena"
		return false
	if _faza == "scena":
		if t < 1.0: return false
		_faza = "mreza"
		if uloga == "server": _nm().hostuj()
		else:
			_nm().connection_failed.connect(_ponovi_povezivanje)
			_nm().pridruzi_se("127.0.0.1")
	_log_t += d
	_meri_zastoj(d)
	var log := _log_t >= 0.5
	if log: _log_t = 0.0
	match uloga:
		"server": return _server(log)
		"observer": return _observer(log, d)
		"mover": return _mover(log)
		"potion": return _potion()
		"prijava": return _prijava()
		"visi": return _visi()
		"raspored": return _raspored()
		"cilj": return _cilj()
		"drugi": return _uloga_drugi()
		"ai": return _uloga_ai()
		"oprema": return _uloga_oprema()
		"napredak": return _uloga_napredak()
		"quest": return _uloga_quest()
		"buff": return _uloga_buff()
		"brzina": return _uloga_brzina()
		"efekti": return _uloga_efekti()
	push_error("uloga mora biti server|observer|mover")
	return true

func _server(log: bool) -> bool:
	# test stabilnost: neprijatelji ne jure test likove (troll na (0,0,15) je ~3 m od putanje movera i ume da
	# ga zaustavi); borba se testira komandama servera nad TestLik-om, ne preko neprijatelja
	# Pored aggro-a i brzina 0 i bez napada: neprijatelj koga igrač udari (napad tests) ulazi u jurenje po pretnji, a ne
	# sme da se pomeri ni da udari. Izuzetak je test goblin AI scenarija (meta "ai_test").
	for e in get_nodes_in_group("neprijatelj"):
		if not e.has_meta("ai_test") and (e.aggro_range != 0.0 or e.brzina != 0.0):
			e.aggro_range = 0.0
			e.brzina = 0.0
			e.moze_napasti = false
			e.player = null
	if log and _world():
		for p in _world().get_children():
			if p.is_in_group("player"):
				print("[S t=%.1f] %s %s on_floor=%s" % [t, p.name, _fmt(p), p.is_on_floor()])
	# faza od movera: "ime peer_id"; rupe u seq obradi se broje po fazi
	var f := FileAccess.get_file_as_string(dir + "/faza").split(" ") if dir != "" else PackedStringArray()
	var faza := f[0] if f.size() == 2 else "normal"
	if faza != _poslednja_faza: # za analizu rafala (vreme u ms kao [SEQ] linije)
		var sad := Time.get_unix_time_from_system()
		if _faza_vreme.has(_poslednja_faza): _faza_vreme[_poslednja_faza][1] = sad
		_faza_vreme[faza] = [sad, INF]
		_poslednja_faza = faza
		print("[S-FAZA] t=%d %s" % [Time.get_ticks_msec(), faza])
	# rupe po igraču (lik koji se odjavio ne sme da "vrati" svoje rupe iz zbira)
	if _world():
		for p in _world().get_children():
			if p.is_in_group("player") and p.rupe_seq > _rupe_po_igracu.get(p.name, 0):
				var n: int = p.rupe_seq - _rupe_po_igracu.get(p.name, 0)
				_rupe_po_igracu[p.name] = p.rupe_seq
				_rupe_dogadjaji.append([Time.get_unix_time_from_system(), str(p.name), n, faza]) # vreme = kad je server primeti
				_faza_rupe[faza] = _faza_rupe.get(faza, 0) + n
				if faza == "normal" or faza == "teleport":
					print("[S t=%.2f] rupa %d u fazi %s, peer %s" % [t, n, faza, p.name])
	if f.size() == 2 and _world() and _world().has_node(f[1]):
		var m = _world().get_node(f[1])
		# zaostatak = red posle obrade u tick-u; Player pamti [vrh, ms] poslednjeg ispražnjenog.
		# Računa se samo zaostatak ispražnjen TOKOM faze rafal (ne ostatak speed-hack-a od ranije).
		if faza == "rafal":
			if _rafal_pre.is_empty(): _rafal_pre = m.red_zaostatak.duplicate()
			if m.red_zaostatak != _rafal_pre and m.red_zaostatak[0] > _rafal_vrh:
				_rafal_vrh = m.red_zaostatak[0]
				_rafal_ms = m.red_zaostatak[1]
		_mover_red_max = m.red_max
		_mover_odbijeno = m.odbijeno_red_pun
		_red_max_dozvoljen = m.UNOS_RED_MAX
	if faza == "reset" and _reset_od < 0: _reset_od = t
	if faza == "reset" and not _resetovan and t - _reset_od > 0.3 and _world() and _world().has_node(f[1]):
		_resetovan = true
		var mr = _world().get_node(f[1])
		mr.server_postavi_poziciju(mr.global_position, true)
		print("[S] reset ", f[1], " (test redundanse posle reset-a)")
	# visi se nikad ne učita iz baze, pa bi ~12 s stajao na nasumičnom spawn-u (±2 oko 0,0) na putanji movera
	var visi_id := FileAccess.get_file_as_string(dir + "/visi_id") if dir != "" else ""
	if visi_id != "" and not _visi_sklonjen and _world() and _world().has_node(visi_id):
		_visi_sklonjen = true
		_world().get_node(visi_id).server_postavi_poziciju(VISI_PARKING, true)
		print("[S] visi ", visi_id, " sklonjen na ", VISI_PARKING)
	if faza == "teleport" and not _teleportovano and _world() and _world().has_node(f[1]):
		_teleportovano = true
		var m = _world().get_node(f[1])
		m.server_postavi_poziciju(m.global_position + Vector3(3, 0, 0), false) # bez reset-a: odlučuje PRAG_SNAP
		print("[S] teleport ", f[1], " +3 x")
	if _world():
		for p in _world().get_children():
			if not p.is_in_group("player"): continue
			if p.has_node("Nameplate"): _nameplate_na_serveru = true
			if p.ime_lika == "TestLik" and dir != "":
				var st := "%d %d %s" % [p.hp, p.max_hp, p.mrtav]
				if st != _server_hp_upisan:
					_server_hp_upisan = st
					_pisi("server_hp", st)
	_server_cilj()
	_server_raspored()
	_server_ai()
	_server_oprema()
	_server_napredak()
	_server_quest()
	_server_buff()
	_server_brzina()
	_server_efekti()
	# komande od potion klijenta: "br steta N" / "br ubij"
	var cmd := FileAccess.get_file_as_string(dir + "/potion_cmd") if dir != "" else ""
	if cmd != "" and cmd != _cmd_izvrsena and _world():
		for p in _world().get_children():
			if p.is_in_group("player") and p.ime_lika == "TestLik":
				_cmd_izvrsena = cmd
				var c := cmd.split(" ")
				p.server_primi_damage(int(c[2]) if c[1] == "steta" else 100000)
				print("[S] potion komanda: ", cmd)
	# gasi se na okidač (dok su klijenti živi): quit() zatvara ENet i klijenti odmah dobiju server_disconnected
	if stop != "" and FileAccess.file_exists(stop):
		var bez: int = _faza_rupe.get("normal", 0) + _faza_rupe.get("teleport", 0)
		_proveri_rupe()
		_provera("nameplate_nema_na_serveru", not _nameplate_na_serveru, "")
		_provera_rupa_faze("rafal_bez_rupa", "rafal", _rafal_vrh > 10 and _rafal_ms >= 0,
			"rupe=%d, vrh reda %d, ispražnjen za %d ms (dozvoljeno %d)" % [_faza_rupe.get("rafal", 0), _rafal_vrh, _rafal_ms, RAFAL_PRAZNJENJE_MAX_MS],
			_rafal_ms <= RAFAL_PRAZNJENJE_MAX_MS)
		for n in [8, 20]:
			var izg := ""
			for fajl in DirAccess.get_files_at(dir):
				if fajl.begins_with("izgubljeno_%d_" % n): izg = fajl.get_slice("_", 2)
			_provera_rupa_faze("gubitak_%d_paketa_bez_rupa" % n, "gubitak%d" % n, izg == str(n),
				"izgubljeno uzastopno %s paketa, rupe u fazi %d" % [izg if izg != "" else "-", _faza_rupe.get("gubitak%d" % n, 0)])
		_provera_rupa_faze("reset_bez_rupa", "reset", _resetovan, "reset izveden=%s, rupe u fazi reset=%d" % [_resetovan, _faza_rupe.get("reset", 0)])
		_provera("red_pun_odbacuje", _mover_odbijeno > 0 and _mover_red_max <= _red_max_dozvoljen,
			"odbačeno (pun red) %d, najduži red %d / %d" % [_mover_odbijeno, _mover_red_max, _red_max_dozvoljen])
		print("[S] gasim server (okidač)")
		return true
	return t > _max_t

# Pop-in: gde je observer PRVI PUT video svaki tuđi lik (čvor vidljiv u stablu). TestLik se iz baze učita na
# TESTLIK_DB_POZ, pa ne sme da se pojavi na spawn tački; MoverLik je nov (0,0,0) i mora da se pojavi.
const TESTLIK_DB_POZ := Vector3(9, 1, -7) # = stub_api PLAYERS["TestLik"]
const POJAVA_TOLERANCIJA := 0.5
var _prva_pojava := {} # ime čvora -> [pozicija pri prvom prikazu, poz_sync tada, ime_sync]
func _prati_pojavu() -> void:
	for n in get_nodes_in_group("player"):
		if n.name == _id() or not n.is_inside_tree():
			continue
		var k := str(n.name)
		if not _prva_pojava.has(k):
			if n.is_visible_in_tree():
				_prva_pojava[k] = [n.global_position, n.poz_sync, n.ime_sync]
		elif _prva_pojava[k][2] == "":
			_prva_pojava[k][2] = n.ime_sync
func _pojava(ime: String) -> Array:
	for v in _prva_pojava.values():
		if v[2] == ime: return v
	return []

func _observer(log: bool, d: float) -> bool:
	_prati_pojavu()
	if not _spreman and _moj():
		_spreman = true
		print("OBSERVER_SPREMAN") # run.sh tek tada pokreće movera i potion klijenta
	_observer_nameplate()
	_observer_cilj()
	var o = _drugi()
	if o:
		_video_drugog = true
		if _obs_od < 0: _obs_od = t
		# korak tuđeg lika po frame-u (posle 1 s, kad stignu prvi snimci). SceneTree _process ide pre
		# _process čvora, pa je izmereni korak napravljen sa delta-om PRETHODNOG frame-a.
		if _obs_pre != null and t - _obs_od > 1.0 and _obs_d > 0:
			var korak: float = o.global_position.distance_to(_obs_pre)
			var v_max: float = o.get_script().get_script_constant_map().get("BRZINA_MAX", o.brzina) # prikaz: 2x najveća moguća brzina
			if korak > o.PRAG_SNAP: _obs_snap += 1
			else:
				_obs_max = maxf(_obs_max, korak / (v_max * _obs_d))
				if korak > v_max * _obs_d * 2 * 1.001: _obs_kraci += 1
		_obs_d = d
		_obs_pre = o.global_position
		if absf(o.yaw_sync - PI / 2) < 0.05 and absf(o.rotation.y - o.yaw_sync) < 0.01:
			_video_yaw = true
			if _yaw_t < 0: _yaw_t = t
		# 1.5-3.5 s posle yaw faze mover miruje: šalji unos za TUĐI lik, server mora da ga ignoriše
		if _yaw_t > 0 and t > _yaw_t + 1.5 and t < _yaw_t + 3.5:
			o.posalji_unos.rpc_id(1, o._kodiraj([[1 << 40, Vector2(1, 0), true, 0.0, o._reset_id_prim]]))
		if log: print("[O t=%.1f] tudji %s %s" % [t, o.name, _fmt(o)])
	if (_video_drugog and o == null) or t > MAX_T:
		_provera("observer_vidi_yaw", _video_yaw, "rotation.y = yaw_sync = PI/2 na tuđem liku")
		_provera("nameplate_sync_poklapa", _sync_poklapanja > 0, "frame-ova sa ime/hp/max/mrtav = server: %d" % _sync_poklapanja)
		_provera("hp_sync_prati_stetu", _stete >= 2 and _max_kasnjenje_ms <= 250, "šteta=%d, najveće kašnjenje %d ms" % [_stete, _max_kasnjenje_ms])
		_provera("nameplate_samo_tudji", _samo_tudji, "tuđi ima vidljiv Nameplate, sopstveni nema")
		_provera("mrtav_sync_i_respawn", _video_mrtvog and _video_respawn, "mrtav=%s respawn=%s" % [_video_mrtvog, _video_respawn])
		_provera("nameplate_boje", _snimljeno.size() == 4 and not _snimljeno.values().has(false), "%s" % _snimljeno)
		var tl := _pojava("TestLik")
		var tl_razlika: float = tl[0].distance_to(TESTLIK_DB_POZ) if not tl.is_empty() else INF
		_provera("prva_pojava_na_poziciji_iz_baze", tl_razlika < POJAVA_TOLERANCIJA,
			"TestLik prvi put viđen na %s, baza %s, razlika %.2f m" % [tl[0] if not tl.is_empty() else "-", TESTLIK_DB_POZ, tl_razlika])
		var visi_id := FileAccess.get_file_as_string(dir + "/visi_id")
		_provera("neucitan_lik_nevidljiv", visi_id != "" and not _prva_pojava.has(visi_id),
			"lik %s (verify visi) %s" % [visi_id if visi_id != "" else "-", "viđen" if _prva_pojava.has(visi_id) else "nikad viđen"])
		var ml := _pojava("MoverLik")
		_provera("novi_lik_000_se_pojavljuje", not ml.is_empty() and ml[0].distance_to(ml[1]) < POJAVA_TOLERANCIJA,
			"MoverLik (bez pozicije u bazi) prvi put viđen na %s, server %s" % [ml[0] if not ml.is_empty() else "-", ml[1] if not ml.is_empty() else "-"])
		_provera("drugi_ne_vidi_cilj", _cilj_obs_ok, _cilj_obs_detalj if _cilj_obs_detalj != "" else "CiljLik nije javio cilj (dir/cilj_postavljen)")
		_provera("observer_korak_max_2x", _obs_kraci == 0, "prekoracenja=%d, max korak=%.2f x BRZINA_MAX*dt, snap-ova=%d" % [_obs_kraci, _obs_max, _obs_snap])
		return true
	return false

func _mover(log: bool) -> bool:
	if _ceka_gasenje >= 0:
		return _mover_ceka_gasenje()
	var p = _moj()
	if p == null:
		return t > MAX_T
	if _spawn == null: _spawn = [t, p.global_position]
	if _t0 < 0:
		if not p.is_on_floor() and t - _spawn[0] < PODLOGA_TIMEOUT: return false
		_t0 = t
	var t := t - _t0 + 3.0  # vremenska osa od dodira poda (ranije: pojava + ~1 s pada)
	var w := (t > 4.0 and t < 6.0) or (t > 7.0 and t < 8.0) or (t > 14.0 and t < 18.0) \
		or (t > 18.5 and t < 20.5) or (t > 24.0 and t < 27.0) or (t > 28.0 and t < 30.0) or (t > 40.6 and t < 41.6)
	if w: Input.action_press("ui_up")
	else: Input.action_release("ui_up")
	if t > 4.0 and t < 6.0: p.rotation.y = PI  # ka +z: na -z (0, _, -10) stoji NPC i blokira put
	if t > 7.0 and t < 8.0: p.rotation.y = PI / 2
	if t > 18.5 and t < 20.5: p.rotation.y = -PI / 2 # ka +x, nazad
	if t > 24.0 and t < 27.0: p.rotation.y = 0.0 # ka -z
	if t > 28.0 and t < 30.0: p.rotation.y = PI
	# Jednokratni okidači (_cp), ne prozor [od, do): frame duži od prozora (pod opterećenjem > 100 ms) bi ga preskočio
	if t > 12.5 and not _cp.has("los_paket"): # neispravni paketi: prekratak, pogrešna dužina za broj unosa, stari format (Array sa NaN)
		_cp["los_paket"] = true
		var los: PackedByteArray = p._kodiraj([[p._seq + 1000, Vector2(1, 0), false, 0.0, p._reset_id_prim]])
		p.posalji_unos.rpc_id(1, los.slice(0, 10))
		los.encode_u8(12, 32)
		p.posalji_unos.rpc_id(1, los)
		p.posalji_unos.rpc_id(1, [[p._seq + 1000, Vector2(NAN, 1), false, INF, p._reset_id_prim]])
	p.set_physics_process(not (t > 15.0 and t < 18.0)) # 15-18 s: prestaje da šalje unos dok "drži" W
	p.test_ubrzanje = 3 if t > 24.0 and t < 27.0 else 1 # speed-hack: 3 unosa po tick-u
	p.test_gubitak = 0.3 if t > 27.5 and t < 33.0 else 0.0
	if t > 34.0 and not _cp.has("zadrzi_od"): _cp["zadrzi_od"] = t
	p.test_zadrzi = _cp.has("zadrzi_od") and t < _cp["zadrzi_od"] + 0.4 # ~24 unosa pa rafal: red mora da ih primi bez rupa
	# paket na putu u trenutku reset-a se izgubi. Hook se pali u frame-u u kom se upiše faza reset (ispod), a server
	# resetuje tek 0.3 s pošto vidi fazu: ranije prozor 38.6-38.7 s, preskočen frame-om > 100 ms (reset_paket_izgubljen i
	# zakasneli_reset_ignorisan "ubačen=false")
	if t > 38.5 and not _cp.has("reset_hook"):
		_cp["reset_hook"] = true
		p.test_izgubi_posle_reseta = true
		p.test_zakasni_reset = true # i sačuvaj kopiju reset stanja: ubacuje se ponovo pošto lik prohoda
	if t > 41.9 and not _cp.has("zakasneli"): # duplikat reset-a pošto je lik hodao 40.6-41.6 s
		_cp["zakasneli"] = [p.global_position, p.korekcije_glatke + p.korekcije_snap, p.test_ubaci_zakasneli_reset(), p._test_reset_kopija]
	# uzastopni gubitak paketa unosa (8 pa 20): sa potvrđenom redundansom server ne sme da ima rupa
	for g in [[43.3, 8], [44.5, 20]]:
		var kljuc := "izgubi%d" % g[1]
		if t > g[0] and not _cp.has(kljuc):
			_cp[kljuc] = p.test_izgubljeno_paketa
			p.test_izgubi_paketa = g[1]
		elif _cp.has(kljuc) and not _cp.has(kljuc + "_gotovo") and p.test_izgubi_paketa == 0:
			_cp[kljuc + "_gotovo"] = true
			_marker("izgubljeno_%d_%d" % [g[1], p.test_izgubljeno_paketa - _cp[kljuc]])
	if t > 42.5 and not _cp.has("zakasneli_posle"):
		_cp["zakasneli_posle"] = [p.global_position, p.korekcije_glatke + p.korekcije_snap]
	var faza := "normal"
	if t > 22.0 and t < 23.5: faza = "teleport"
	elif t > 23.5 and t < 27.5: faza = "speedhack"
	elif t > 27.5 and t < 33.5: faza = "gubitak"
	elif t > 33.8 and t < 38.0: faza = "rafal"
	elif t > 38.5 and t < 40.5: faza = "reset"
	elif t > 43.0 and t < 44.2: faza = "gubitak8"
	elif t > 44.2 and t < 46.0: faza = "gubitak20"
	_upisi_fazu(faza, p.name)
	if shot != "" and not _slikano and t > 6.7: # u mirovanju: snimanje koči frame
		_slikano = true
		root.get_viewport().get_texture().get_image().save_png(shot)
		print("[M] screenshot -> ", shot)
	for k in [3.5, 6.5, 8.5, 12.0, 13.5, 15.0, 16.5, 17.5, 18.5, 21.5, 22.0, 23.3, 24.5, 26.5, 28.0, 33.0]:
		if t >= k and not _cp.has(k):
			_cp[k] = p.server_poz  # pozicija koju javlja server
			_cpp[k] = p.global_position  # predviđena
			_kor[k] = p.korekcije_glatke + p.korekcije_snap
			if k == 3.5: # udaljenost do ostalih likova: < 1 m = spawn kolizija (stoji na drugom liku)
				var d := []
				for o in get_nodes_in_group("player"):
					if o != p: d.append("%s %.2f m" % [o.ime_sync if o.ime_sync != "" else str(o.name), o.global_position.distance_to(p.global_position)])
				_cp["podloga"] = [p.is_on_floor(), d]
	if log: print("[M t=%.1f] moj %s server=%s kor=%d/%d" % [t, _fmt(p), p.server_poz, p.korekcije_glatke, p.korekcije_snap])
	var kat := "gubitak" if faza.begins_with("gubitak") else ("normal" if faza == "normal" else "")
	if kat != "" and p.paket_bajtova > 0: # veličina paketa unosa po kategoriji: [zbir, broj, max]
		var v: Array = _paket_vel.get(kat, [0, 0, 0])
		_paket_vel[kat] = [v[0] + p.paket_bajtova, v[1] + 1, maxi(v[2], p.paket_bajtova)]
	if t > 47.0:
		for k in _paket_vel:
			print("[M] paket unosa (%s): prosek %d B, max %d B, uzoraka %d" % [k, _paket_vel[k][0] / _paket_vel[k][1], _paket_vel[k][2], _paket_vel[k][1]])
		var z: Array = _cp["zakasneli"]
		var zp: Array = _cp["zakasneli_posle"]
		var kopija = z[3]
		_provera("zakasneli_reset_ignorisan", z[2] and zp[0].distance_to(z[0]) < 0.3 and zp[1] == z[1],
			"ubačen=%s, pomeraj posle ubacivanja %.3f m (reset poz %s), korekcija posle %d" % [z[2], zp[0].distance_to(z[0]), kopija[1] if kopija != null else "-", zp[1] - z[1]])
		_provera("reset_paket_izgubljen", p.test_izgubljen_paket, "hook je izgubio paket koji je bio na putu kad je stigao reset")
		var c := _cp
		var w1: Vector3 = c[6.5] - c[3.5]
		var w2: Vector3 = c[8.5] - c[6.5]
		var pod: Array = c["podloga"]
		var kolizija := false
		for x in pod[1]: kolizija = kolizija or float(x.split(" ")[-2]) < 1.0
		_provera("na_podu", absf(c[3.5].y - 1.16) < 0.1, "y=%.2f, spawn %s, is_on_floor=%s, ostali likovi %s%s, čekanje poda %.2f s" % [c[3.5].y, _spawn[1], pod[0], pod[1], " -> SPAWN KOLIZIJA" if kolizija else "", _t0 - _spawn[0]])
		_provera("W_2s_napred", w1.z > 8.5 and w1.z < 11.5 and absf(w1.x) < 1.5, "delta=%s" % w1)
		_provera("yaw_PI/2_ide_-x", w2.x < -4.0 and absf(w2.z) < 1.5, "delta=%s" % w2)
		_provera("tudji_unos_ignorisan", c[12.0].distance_to(c[8.5]) < 0.05, "delta=%s" % (c[12.0] - c[8.5]))
		_provera("neispravan_paket_odbacen", c[13.5].distance_to(c[12.0]) < 0.05, "delta=%s" % (c[13.5] - c[12.0]))
		var posle: float = c[16.5].distance_to(c[15.0])
		_provera("istek_unosa_0.5s", posle < 4.5 and c[17.5].distance_to(c[16.5]) < 0.05, "posle prekida %.2f, zatim %.2f" % [posle, c[17.5].distance_to(c[16.5])])
		var hod: float = c[21.5].distance_to(c[18.5])
		_provera("mirno_0_korekcija", _kor[21.5] == _kor[18.5] and hod > 8.0 and _cpp[21.5].distance_to(c[21.5]) < 0.05,
			"korekcija=%d hod=%.2f razlika posle zaustavljanja=%.3f" % [_kor[21.5] - _kor[18.5], hod, _cpp[21.5].distance_to(c[21.5])])
		_provera("teleport_snap", _kor[23.3] > _kor[22.0] and c[23.3].distance_to(c[22.0]) > 2.5 and _cpp[23.3].distance_to(c[23.3]) < 0.05,
			"server pomeren %.2f, korekcija=%d, razlika=%.3f" % [c[23.3].distance_to(c[22.0]), _kor[23.3] - _kor[22.0], _cpp[23.3].distance_to(c[23.3])])
		var hack: float = c[26.5].distance_to(c[24.5]) / (2.0 * p.brzina)
		_provera("speedhack_max_1.2x", hack > 0.5 and hack < 1.25, "server brzina %.2fx normalne" % hack)
		_provera("gubitak_30%_konvergira", c[33.0].distance_to(c[28.0]) > 7.0 and _cpp[33.0].distance_to(c[33.0]) < 0.05,
			"hod=%.2f razlika=%.3f" % [c[33.0].distance_to(c[28.0]), _cpp[33.0].distance_to(c[33.0])])
		print("[M] korekcije glatke=%d snap=%d, greska predikcije prosek=%.4f max=%.3f m (n=%d)" % [p.korekcije_glatke, p.korekcije_snap, p.greska_suma / maxi(p.greska_n, 1), p.greska_max, p.greska_n])
		Input.action_release("ui_up")
		_upisi_fazu("kraj", p.name)
		_ceka_gasenje = self.t  # globalno vreme (lokalni t je pomeren)
		print("CEKAM_GASENJE")
	return false

var _upisana_faza := ""
func _upisi_fazu(faza: String, id: String) -> void:
	if dir == "" or faza == _upisana_faza: return
	_upisana_faza = faza
	_pisi("faza", faza + " " + id)

# Server se gasi dok je klijent živ: klijent mora da se vrati na login sa porukom
func _mover_ceka_gasenje() -> bool:
	var scena := current_scene.scene_file_path if current_scene else ""
	var poruka: String = root.get_node("GameState").poruka_logina
	# MainMenu prikaže poruku i obriše je iz GameState; zato se gleda tekst greške na ekranu
	if scena == "res://Scenes/UI/MainMenu.tscn" and _menu_t < 0:
		_menu_t = t
	# još 1 s u meniju, da se u logu vidi ima li grešaka posle prekida
	if _menu_t >= 0 and t - _menu_t > 1.0:
		var ok: bool = current_scene.get("_error_label") != null and current_scene._error_label.text == "Lost connection to the server"
		_provera("server_prekid_vraca_na_login", ok, "scena=%s poruka='%s' token='%s'" % [scena, current_scene._error_label.text, root.get_node("GameState").token])
		return true
	if t - _ceka_gasenje >= 250.0: # run.sh čeka ostale uloge do 240 s pre gašenja servera
		_provera("server_prekid_vraca_na_login", false, "nema promene scene za 250 s (scena=%s poruka='%s')" % [scena, poruka])
		return true
	return false

# ---------------------------------------------------------------- POTION (napitci preko stub API-ja)

# visi: lik čije učitavanje (verify) nikad ne završi. Server ga posle UCITAVANJE_TIMEOUT izbaci (MainMenu sa
# porukom o isteku); bez te zaštite ostaje povezan i nevidljiv do isteka ApiManager pokušaja (~25 s).
var _visi_od := -1.0
func _visi() -> bool:
	var scena = current_scene
	if _visi_od >= 0 and scena and scena.scene_file_path == "res://Scenes/UI/MainMenu.tscn":
		var poruka: String = scena._error_label.text # main_menu prebaci GameState.poruka_logina u labelu i obriše je
		var rok: float = 10.0 + 2.0 # Player_Movement.UCITAVANJE_TIMEOUT + slanje registracije i izbacivanje (0,2 s)
		_provera("ucitavanje_istek_izbacuje", "timed out" in poruka and t - _visi_od < rok,
			"izbačen posle %.1f s (rok %.0f s), poruka '%s'" % [t - _visi_od, rok, poruka])
		return true
	if _visi_od < 0 and _moj():
		_visi_od = t
		var f := FileAccess.open(dir + "/visi_id", FileAccess.WRITE)
		f.store_string(_id())
		f.close()
	if (_visi_od >= 0 and t - _visi_od > 20.0) or t > MAX_T:
		_provera("ucitavanje_istek_izbacuje", false, "nije izbačen ni posle %.1f s" % (t - _visi_od))
		return true
	return false

func _potion() -> bool:
	if _moj() and not _moj().test_reset_izgubljen and not _potion_krenuo:
		_moj().test_izgubi_reset_prijave = true # odbaci reset posle prijave (učitavanje iz baze)
	if not _potion_krenuo and _moj() and _moj().has_node("ui/Control"):
		_potion_krenuo = true
		_potion_scenario()
	return _potion_kraj or t > MAX_T

func _cekaj(uslov: Callable, sek := 10.0) -> bool:
	var kraj := Time.get_ticks_msec() + int(sek * 1000)
	while not uslov.call():
		if Time.get_ticks_msec() > kraj: return false
		await process_frame
	return true

# količina u "bazi" (stub)
func _baza(item_id: String) -> int:
	var pl: Dictionary = await root.get_node("ApiManager").get_player("TestLik")
	var n := 0
	for e in pl.get("inventory", []):
		if e.id == item_id: n += int(e.kolicina)
	return n

var _cmd_br := 0
func _komanda(c: String) -> void:
	_cmd_br += 1
	var f := FileAccess.open(dir + "/potion_cmd", FileAccess.WRITE)
	f.store_string("%d %s" % [_cmd_br, c])
	f.close()

func _potion_scenario() -> void:
	var p = _moj()
	var hud = p.get_node("ui/Control")
	var inv = p.get_node("ui/InventoryUI")
	var api = root.get_node("ApiManager")
	var ucitan: bool = await _cekaj(func(): return hud.hp == 50 and inv.prebroj_item("small_health_potion") == 3)
	await _cekaj(func(): return p.test_reset_izgubljen and p._reset_id_prim >= 2, 3.0)
	_provera("reset_prijave_bez_snapa", p.test_reset_izgubljen and p._reset_id_prim >= 2 and p.korekcije_snap == 0 and p.greska_max < 1.0,
		"reset odbačen=%s, primenjen reset_id=%d, snap=%d, najveća greška %.3f m, server_poz=%s" % [p.test_reset_izgubljen, p._reset_id_prim, p.korekcije_snap, p.greska_max, p.server_poz])
	_provera("potion_lik_ucitan", ucitan, "hp=%d small=%d" % [hud.hp, inv.prebroj_item("small_health_potion")])
	if not ucitan:
		_potion_kraj = true
		return

	# 1. ispod punog: +30, količina -1 (UI gest = isti klik kao za opremu -> _koristi_item).
	# HP regeneriše +2/s, pa se efekat proverava kao razlika uz malu toleranciju.
	var hp0: int = hud.hp
	await inv._koristi_item("small_health_potion")
	await _cekaj(func(): return hud.hp >= hp0 + 30, 3.0)
	var b: int = await _baza("small_health_potion")
	_provera("napitak_leci", hud.hp - hp0 >= 30 and hud.hp - hp0 <= 34 and b == 2 and inv.prebroj_item("small_health_potion") == 2 and hud._poruka_label.text == "+30 HP",
		"hp %d->%d baza=%d ui=%d poruka='%s'" % [hp0, hud.hp, b, inv.prebroj_item("small_health_potion"), hud._poruka_label.text])

	# cooldown: drugi pokušaj odmah po potvrdi prvog (HP nije pun, pa je jedini razlog cooldown)
	var r: Dictionary = await p.koristi_item_na_serveru("small_health_potion")
	b = await _baza("small_health_potion")
	_provera("cooldown_odbija", hud.hp < hud.max_hp and r.get("poruka") == "Not ready yet" and b == 2, "hp=%d r=%s baza=%d" % [hud.hp, r, b])

	# 2. +150 na 80/100 -> clamp na 100
	r = await p.koristi_item_na_serveru("large_health_potion")
	await _cekaj(func(): return hud.hp == 100, 3.0)
	b = await _baza("large_health_potion")
	_provera("napitak_clamp_max", r.get("ok", false) and hud.hp == 100 and b == 0, "r=%s hp=%d baza=%d" % [r, hud.hp, b])

	# 3. pun HP: odbijeno, ne troši
	r = await p.koristi_item_na_serveru("medium_health_potion")
	b = await _baza("medium_health_potion")
	_provera("pun_hp_odbija", not r.get("ok", true) and r.get("poruka") == "Already at full health" and b == 3, "r=%s baza=%d" % [r, b])

	# 4. šteta: HP ispod maksimuma za test dva istovremena zahteva
	_komanda("steta 40")
	await _cekaj(func(): return hud.hp <= 64, 3.0)

	# 4b. action bar: taster 1 (small HP), taster 0 (prazan slot), količina/cooldown iz servera
	await _action_bar_provere(p, hud)
	_komanda("steta 40") # da HP ne bude pun za dva istovremena zahteva (regen +2/s za vreme provera bara)
	await _cekaj(func(): return hud.hp <= 70, 3.0)

	# 5. predmet koji nema; 6. nepotrošni
	r = await p.koristi_item_na_serveru("mana_potion")
	_provera("nema_predmet_odbija", r.get("poruka") == "You don't have that item", "r=%s" % r)
	r = await p.koristi_item_na_serveru("iron_sword")
	b = await _baza("iron_sword")
	_provera("nepotrosni_odbija", r.get("poruka") == "This item can't be used" and b == 1, "r=%s baza=%d" % [r, b])

	# 7. dva istovremena zahteva (direktni RPC, mimo klijentske zaštite) -> jedan komad
	var pre: Dictionary = await api.get_player("TestLik")
	var odgovori := []
	var hvataj := func(d): odgovori.append(d)
	p.item_odgovor.connect(hvataj)
	p.zatrazi_koriscenje_itema.rpc_id(1, "medium_health_potion")
	p.zatrazi_koriscenje_itema.rpc_id(1, "medium_health_potion")
	await _cekaj(func(): return odgovori.size() == 2, 5.0)
	p.item_odgovor.disconnect(hvataj)
	await _cekaj(func(): return hud.hp == 100, 3.0)
	var posle: Dictionary = await api.get_player("TestLik")
	b = await _baza("medium_health_potion")
	var okova := odgovori.filter(func(d): return d.get("ok", false)).size()
	_provera("dva_istovremena_jedan_komad", odgovori.size() == 2 and okova == 1 and b == 2 and int(posle.get("item_use_br", 0)) - int(pre.get("item_use_br", 0)) == 1 and hud.hp == 100,
		"odgovori=%s baza=%d backend_trosenja=%d hp=%d" % [odgovori, b, int(posle.get("item_use_br", 0)) - int(pre.get("item_use_br", 0)), hud.hp])

	# nameplate stanja (observer snima): pun -> 40% -> <25%
	await _snimak("zeleno")
	_komanda("steta 60")
	await _cekaj(func(): return hud.hp <= 50 and hud.hp >= 25, 3.0)
	await _snimak("zuto")
	_komanda("steta 25")
	await _cekaj(func(): return hud.hp < 25, 3.0)
	await _snimak("crveno")

	# 8. mrtav ne može
	_komanda("ubij")
	await _cekaj(func(): return hud.je_mrtav, 3.0)
	r = await p.koristi_item_na_serveru("apple")
	b = await _baza("apple")
	_provera("mrtav_ne_moze", hud.je_mrtav and r.get("poruka") == "You are dead" and b == 2, "mrtav=%s r=%s baza=%d" % [hud.je_mrtav, r, b])
	await _snimak("mrtav")
	# respawn (server, 3 s) pa sačekaj da ga observer vidi pre odjave
	await _cekaj(func(): return not hud.je_mrtav, 6.0)
	await _cekaj(func(): return FileAccess.file_exists(dir + "/observer_respawn"), 5.0)
	_potion_kraj = true

# ---------------------------------------------------------------- ACTION BAR (potion klijent)

func _pritisni(k: Key) -> void:
	for dole in [true, false]:
		var e := InputEventKey.new()
		e.keycode = k
		e.physical_keycode = k
		e.pressed = dole
		Input.parse_input_event(e)

# Bar se popunjava iz servera: slot 1 small, 2 large (već potrošen drugim putem), 3 medium, 4 apple, 10 prazan.
func _action_bar_provere(p, hud) -> void:
	var bar = p.get_node_or_null("ui/ActionBar")
	var ima: bool = bar != null and bar.has_method("koristi_slot")
	if ima:
		await _cekaj(func(): return bar.slotovi.size() == 10 and bar.slotovi[0] == "small_health_potion" and bar.slotovi[1] == "large_health_potion", 5.0)
		await _cekaj(func(): return bar.preostalo_ms(0) == 0, 7.0) # cooldown prve upotrebe (po serveru) istekao
	_komanda("steta 30") # HP dovoljno nizak da +30 ne udari u maksimum (regen +2/s dok se čeka cooldown)
	await _cekaj(func(): return hud.hp <= 50, 3.0)
	var odgovori := []
	var hvataj := func(d): odgovori.append(d)
	p.item_odgovor.connect(hvataj)

	# slot koristi potion: +30, količina -1 (baza i slot)
	var hp0: int = hud.hp
	var b0: int = await _baza("small_health_potion")
	_pritisni(KEY_1)
	await _cekaj(func(): return odgovori.size() >= 1, 5.0)
	await _cekaj(func(): return hud.hp >= hp0 + 30, 3.0)
	var b1: int = await _baza("small_health_potion")
	_provera("action_slot_koristi_napitak", ima and odgovori.size() == 1 and odgovori[0].get("ok", false) and hud.hp - hp0 >= 30 and hud.hp - hp0 <= 34 and b1 == b0 - 1,
		"bar=%s hp %d->%d baza %d->%d odgovor=%s" % [ima, hp0, hud.hp, b0, b1, odgovori[0] if odgovori.size() > 0 else "-"])

	# cooldown odbija drugi pokušaj; overlay pokazuje preostale sekunde
	var hp1: int = hud.hp
	_pritisni(KEY_1)
	await _cekaj(func(): return odgovori.size() >= 2, 5.0)
	var b2: int = await _baza("small_health_potion")
	var cd_txt: String = bar._prikaz[0].cd.text if ima else ""
	var overlay: bool = ima and bar._prikaz[0].overlay.visible
	_provera("action_cooldown_odbija", ima and odgovori.size() == 2 and odgovori[1].get("poruka") == "Not ready yet" and b2 == b1 and overlay and cd_txt.is_valid_int() and int(cd_txt) > 0 and hud.hp <= hp1 + 4,
		"odgovor=%s baza=%d overlay=%s sekundi='%s' hp %d->%d" % [odgovori[1] if odgovori.size() > 1 else "-", b2, overlay, cd_txt, hp1, hud.hp])

	# prazan slot (taster 0): bez zahteva serveru
	_pritisni(KEY_0)
	await create_timer(1.0).timeout
	var b3: int = await _baza("small_health_potion")
	_provera("action_prazan_slot_nista", ima and bar.slotovi[9] == "" and odgovori.size() == 2 and b3 == b1,
		"slot 10='%s' novih odgovora=%d baza=%d" % [bar.slotovi[9] if ima else "-", odgovori.size() - 2, b3])
	p.item_odgovor.disconnect(hvataj)

	# UI prati količinu iz servera: slot 1 = baza, slot 2 (large, potrošen mimo bara) = 0
	var bl: int = await _baza("large_health_potion")
	_provera("action_kolicina_iz_servera", ima and bar.kolicina(0) == b3 and bar._prikaz[0].kolicina.text == str(b3) and bar.kolicina(1) == bl and bar._prikaz[1].kolicina.text == str(bl) and bl == 0,
		"slot1 %s (baza %d), slot2 %s (baza %d)" % [bar._prikaz[0].kolicina.text if ima else "-", b3, bar._prikaz[1].kolicina.text if ima else "-", bl])

# ---------------------------------------------------------------- NAMEPLATE (observer gleda TestLik-a)

func _testlik():
	if _world() == null: return null
	for p in _world().get_children():
		if p.is_in_group("player") and p.name != _id() and p.ime_sync == "TestLik": return p
	return null

func _kategorija(p) -> String:
	if p.mrtav_sync: return "mrtav"
	var deo := float(p.hp_sync) / maxi(p.max_hp_sync, 1)
	return "zeleno" if deo > 0.5 else ("zuto" if deo >= 0.25 else "crveno")

func _observer_nameplate() -> void:
	var p = _testlik()
	if p == null or dir == "": return
	var np = p.get_node_or_null("Nameplate")
	if np and np.visible and not _moj().has_node("Nameplate"): _samo_tudji = true
	# poređenje sa serverom (server upisuje "hp max mrtav" u dir/server_hp)
	var st := FileAccess.get_file_as_string(dir + "/server_hp")
	var f := st.split(" ")
	if f.size() == 3:
		if st != _server_hp_pre:
			var pre := _server_hp_pre.split(" ")
			if pre.size() == 3 and int(f[0]) < int(pre[0]):
				_cekana_steta = int(f[0])
				_steta_ms = Time.get_ticks_msec()
			elif _cekana_steta >= 0 and int(f[0]) != _cekana_steta:
				_cekana_steta = -1 # regen/lečenje pre nego što je šteta stigla: ne meri se
			_server_hp_pre = st
		if p.hp_sync == int(f[0]) and p.max_hp_sync == int(f[1]) and str(p.mrtav_sync) == f[2]:
			_sync_poklapanja += 1
			if _cekana_steta >= 0:
				_stete += 1
				_max_kasnjenje_ms = maxi(_max_kasnjenje_ms, Time.get_ticks_msec() - _steta_ms)
				_cekana_steta = -1
	var traka: Node3D = np.get_node("HpTraka") if np else null
	if p.mrtav_sync and traka and not traka.visible and np.get_node("Pozadina").visible == false \
			and p._ime_label.modulate == p.BOJA_IME_MRTAV:
		_video_mrtvog = true
	if _video_mrtvog and not p.mrtav_sync and p.hp_sync == p.max_hp_sync and traka and traka.visible:
		if not _video_respawn: _marker("observer_respawn")
		_video_respawn = true
	# snimak: potion traži kategoriju u dir/snimi; snima se kad je stanje tu, posle 10 frame-ova (render)
	var trazi := FileAccess.get_file_as_string(dir + "/snimi")
	if trazi == "" or _snimljeno.has(trazi) or _kategorija(p) != trazi:
		_snimak_frame = -1
		return
	if _snimak_frame < 0: _snimak_frame = 0
	_snimak_frame += 1
	if _snimak_frame < 10: return
	var ok: bool
	if trazi == "mrtav":
		ok = not traka.visible and p._ime_label.modulate == p.BOJA_IME_MRTAV
	else:
		var ocekivana: Color = {"zeleno": p.BOJA_HP_VISOK, "zuto": p.BOJA_HP_SREDNJI, "crveno": p.BOJA_HP_NIZAK}[trazi]
		ok = traka.mesh.material.albedo_color == ocekivana and traka.visible
	_snimljeno[trazi] = ok
	if shot != "":
		var putanja := "%s_%s.png" % [shot, trazi]
		root.get_viewport().get_texture().get_image().save_png(putanja)
		print("[O] screenshot %s hp=%d/%d -> %s" % [trazi, p.hp_sync, p.max_hp_sync, putanja])
	_marker("snimljeno_" + trazi)

func _marker(ime: String) -> void:
	var f := FileAccess.open(dir + "/" + ime, FileAccess.WRITE)
	f.close()

# potion: traži snimak kategorije i čeka da ga observer napravi (stanje, ne sat)
func _snimak(kat: String) -> bool:
	var f := FileAccess.open(dir + "/snimi", FileAccess.WRITE)
	f.store_string(kat)
	f.close()
	return await _cekaj(func(): return FileAccess.file_exists(dir + "/snimljeno_" + kat), 20.0)

# ---------------------------------------------------------------- ZASTOJ (za seq_bez_rupa_bez_gubitka)
# Rupa u seq obradi nekog lika je opravdana (WARN) samo ako je proces koji šalje inpute za TAJ lik
# imao frame > ZASTOJ_PRAG u prozoru +-ZASTOJ_PROZOR oko trenutka rupe (posle zastoja Godot nadoknađuje
# tick-ove brže od 1.2x i token bucket ih odbaci), ili ako je u tom prozoru zastao sam server: tada rupe dobiju svi
# povezani likovi u istom trenutku (pod opterećenjem mašine: server frame 134 ms, rupe 9-10 kod četiri peer-a u t=12.23).
# Inače FAIL.
var _server_zastoji := [] # server: [t_kraj, delta] (unix s)

var _svi_zastoji := [] # svaka uloga: [t_kraj, delta] (unix s) svakog frame-a > ZASTOJ_PRAG, za provere koje mere vreme

func _meri_zastoj(d: float) -> void:
	if d > ZASTOJ_PRAG:
		_svi_zastoji.append([Time.get_unix_time_from_system(), d])
	if uloga == "server" and d > ZASTOJ_PRAG:
		_server_zastoji.append([Time.get_unix_time_from_system(), d])
		if dir != "": # klijenti čitaju zastoje servera (_zastoj_izmedju)
			_pisi("srv_zastoji", "\n".join(_server_zastoji.slice(-300).map(func(z): return "%f %f" % z)))
	if dir == "" or uloga == "server" or _moj() == null:
		return
	var f := FileAccess.get_file_as_string(dir + "/faza").split(" ")
	if f.size() != 2:
		return # mover još nije upisao fazu
	var sad := Time.get_unix_time_from_system()
	if f[0] != _faza_merenja:
		_faza_merenja = f[0]
		_faza_od = sad
	# seq (normal, teleport): bez prve sekunde faze. Ostale faze (rafal, reset, gubitak8/20): svaki zastoj, treća kolona 0
	var seq_faza := (f[0] == "normal" or f[0] == "teleport") and sad - _faza_od >= ZASTOJ_WARMUP
	var promena := (seq_faza and d > _max_delta) or d > ZASTOJ_PRAG
	if seq_faza: _max_delta = maxf(_max_delta, d)
	if d > ZASTOJ_PRAG:
		_zastoji.append("%f %f %d" % [sad, d, int(seq_faza)])
	if promena: # fajl po peer-u: uloga, najduži frame, pa zastoji
		_pisi("zastoj_" + _id(), "%s\n%f\n%s" % [uloga, _max_delta, "\n".join(_zastoji)])

# najduži zastoj ovog procesa ili servera koji seče [od, do_] (unix s), npr. "brzina 180 ms"; "" ako ga nije bilo
func _zastoj_izmedju(od: float, do_: float) -> String:
	var srv := []
	for l in FileAccess.get_file_as_string(dir + "/srv_zastoji").split("\n", false):
		srv.append([float(l.get_slice(" ", 0)), float(l.get_slice(" ", 1))])
	var naj := ""
	var naj_d := 0.0
	for x in [[uloga, _svi_zastoji], ["server", srv]]:
		for st in x[1]:
			if st[0] - st[1] <= do_ and st[0] >= od and st[1] > naj_d:
				naj_d = st[1]
				naj = "%s %d ms" % [x[0], int(st[1] * 1000)]
	return naj

# [uloga, najduži frame, [[t_kraj, delta], ...]] za peer; [] ako proces nije merio. sve=false: samo zastoji seq faza
func _zastoj_peer(peer: String, sve := false) -> Array:
	var s := FileAccess.get_file_as_string(dir + "/zastoj_" + peer)
	if s == "": return []
	var l := s.split("\n", false)
	var z := []
	for k in range(2, l.size()):
		var v := l[k].split(" ")
		if sve or v[2] == "1": z.append([float(v[0]), float(v[1])])
	return [l[0], float(l[1]), z]

# Rupe likova u fazama `faze`: opravdane zastojem procesa koji šalje unose za taj lik ili servera (zastoj seče
# [t - ZASTOJ_PROZOR, t + ZASTOJ_PROZOR]). sve_faze: i zastoji van seq faza (rafal, reset, gubitak).
func _opravdaj_rupe(faze: Array, sve_faze: bool) -> Dictionary:
	var r := {"opravdane": 0, "od_servera": 0, "neopravdane": []}
	for e in _rupe_dogadjaji:
		if not e[3] in faze: continue
		var z := _zastoj_peer(e[1], sve_faze)
		var ok := false
		for st in (z[2] if z.size() == 3 else []) + _server_zastoji: # zastoj [t_kraj - d, t_kraj] seče [t - P, t + P]
			var sece: bool = st[0] - st[1] <= e[0] + ZASTOJ_PROZOR and st[0] >= e[0] - ZASTOJ_PROZOR
			ok = ok or sece
			if sece and st in _server_zastoji: r.od_servera += e[2]
		if ok: r.opravdane += e[2]
		else: r.neopravdane.append("%d (%s)" % [e[2], z[0] if z.size() == 3 else "peer " + e[1]])
	return r

# Provera rupa u fazi testa reda (rafal, reset, gubitak8/20): rupa bez zastoja = FAIL; ako su sve rupe opravdane
# zastojem i ostali uslovi važe, WARN (neodlučno), kao seq_bez_rupa_bez_gubitka. vreme_ok (merenje vremena, npr. pražnjenje
# reda) sme da ne važi samo uz zastoj movera ili servera u toku faze (WARN); bez zastoja FAIL.
func _provera_rupa_faze(ime: String, faza: String, ostalo_ok: bool, detalj: String, vreme_ok := true) -> void:
	var rupe: int = _faza_rupe.get(faza, 0)
	var r := _opravdaj_rupe([faza], true)
	var zastoj_faze := _zastoj_u_fazi(faza)
	var opis := "%s; opravdane zastojem %d (servera %d), bez zastoja %s; zastoj u fazi: %s" % [detalj, r.opravdane, r.od_servera,
		r.neopravdane, zastoj_faze if zastoj_faze != "" else "-"]
	if not ostalo_ok or not r.neopravdane.is_empty() or (not vreme_ok and zastoj_faze == ""):
		_provera(ime, false, opis)
	elif rupe == 0 and vreme_ok:
		_provera(ime, true, detalj)
	else:
		print("WARN %s  neodlučno (zastoj klijenta ili servera): %s" % [ime, opis])

# najduži zastoj movera (svi zastoji, i van seq faza) ili servera u toku faze; "" ako ga nije bilo
func _zastoj_u_fazi(faza: String) -> String:
	var v: Array = _faza_vreme.get(faza, [])
	if v.is_empty(): return ""
	var f := FileAccess.get_file_as_string(dir + "/faza").split(" ")
	var z := _zastoj_peer(f[1], true) if f.size() == 2 else []
	var naj := ""
	var naj_d := 0.0
	for x in [["mover", z[2] if z.size() == 3 else []], ["server", _server_zastoji]]:
		for st in x[1]:
			if st[0] - st[1] <= v[1] and st[0] >= v[0] and st[1] > naj_d:
				naj_d = st[1]
				naj = "%s %d ms" % [x[0], int(st[1] * 1000)]
	return naj

func _proveri_rupe() -> void:
	var naj := [0.0, "-"]
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("zastoj_") and not f.ends_with(".tmp"):
			var z := _zastoj_peer(f.substr(7))
			if z.size() == 3 and z[1] > naj[0]: naj = [z[1], z[0]]
	var r := _opravdaj_rupe(["normal", "teleport"], false)
	var opravdane: int = r.opravdane
	var od_servera: int = r.od_servera
	var neopravdane: Array = r.neopravdane
	var opis := "rupe po fazi %s, opravdane zastojem %d (u prozoru zastoja servera %d), bez zastoja %s; najduži frame %.0f ms (%s), zastoja servera %d" % [
		_faza_rupe, opravdane, od_servera, neopravdane, naj[0] * 1000, naj[1], _server_zastoji.size()]
	if not neopravdane.is_empty() or opravdane == 0:
		_provera("seq_bez_rupa_bez_gubitka", neopravdane.is_empty(), opis)
	else:
		print("WARN seq_bez_rupa_bez_gubitka  neodlučno (zastoj klijenta): ", opis)

# ---------------------------------------------------------------- PRIJAVA (repro_login.sh: jedna kratka sesija)

var _prijava_t := -1.0
var _akt_t := 0.0
func _prijava() -> bool:
	var p = _moj()
	if p and _izgubi_reset and not p.test_izgubi_reset_prijave and not p.test_reset_izgubljen:
		p.test_izgubi_reset_prijave = true
	if _prijava_t < 0 and p and p.get_node("ui/Control")._ucitano:
		_prijava_t = t
		print("PRIJAVA_UCITAN t=%.2f" % t)
	if _aktivnost and _prijava_t >= 0 and t - _akt_t >= 0.2:
		_akt_t = t
		p.zatrazi_koriscenje_itema.rpc_id(1, "mana_potion") # reliable, ne menja stanje ("Nemaš taj predmet")
	if _prijava_t >= 0 and t - _prijava_t > 5.0:
		print("PRIJAVA_KRAJ snap=%d glatke=%d greska_max=%.3f reset_izgubljen=%s server_poz=%s" % [p.korekcije_snap, p.korekcije_glatke, p.greska_max, p.test_reset_izgubljen, p.server_poz])
		return true
	return t > 30.0

# ---------------------------------------------------------------- RASPORED ACTION BARA (RasporedLik, dva procesa)
# Stub: small x2, mač, apple x1, mana x1, bez sačuvanog rasporeda. Korak 1: početni raspored iz inventara upisan u bazu,
# mana premeštena u slot 7, nevažeći zahtevi odbijeni, apple potrošen (slot ostaje), kupljen medium (prvi prazan = 3).
# Zatim prevlačenje mišem (pravi događaji pritisak/pomeranje/otpuštanje): slot -> prazan, zamena, Esc i van prozora
# otkazuju, slot -> van trake, inventar -> slot; server odbija nepotrošni i predmet koji lik nema; klik koristi napitak.
# Korak 2 (novi proces = ponovna prijava): isti raspored iz baze, apple i dalje u slotu 2 sa 0.

const RASPORED_POCETNI := ["small_health_potion", "apple", "mana_potion", "", "", "", "", "", "", ""]
const RASPORED_POMEREN := ["small_health_potion", "apple", "", "", "", "", "mana_potion", "", "", ""]
const RASPORED_KUPLJEN := ["small_health_potion", "apple", "medium_health_potion", "", "", "", "mana_potion", "", "", ""]
const RASPORED_PREMESTEN := ["small_health_potion", "apple", "medium_health_potion", "", "mana_potion", "", "", "", "", ""]
const RASPORED_ZAMENJEN := ["medium_health_potion", "apple", "small_health_potion", "", "mana_potion", "", "", "", "", ""]
const RASPORED_UKLONJEN := ["medium_health_potion", "apple", "small_health_potion", "", "", "", "", "", "", ""]
const RASPORED_KRAJ := ["medium_health_potion", "apple", "small_health_potion", "mana_potion", "", "", "", "", "", ""]
var _raspored_krenuo := false
var _raspored_kraj := false

func _raspored() -> bool:
	var p = _moj()
	if not _raspored_krenuo and p and p.has_node("ui/ActionBar") and p.get_node("ui/Control")._ucitano:
		_raspored_krenuo = true
		_raspored_scenario(p, p.get_node("ui/ActionBar"))
	return _raspored_kraj or t > MAX_T

# raspored u stub "bazi" (null -> ""); [] = nema sačuvan raspored
func _raspored_baza() -> Array:
	var ab = (await root.get_node("ApiManager").get_player("RasporedLik")).get("action_bar")
	return ab.map(func(x): return "" if x == null else x) if ab is Array else []

func _cekaj_bazu(ocekivano: Array, sek := 5.0) -> Array:
	var kraj := Time.get_ticks_msec() + int(sek * 1000)
	var ab: Array = await _raspored_baza()
	while ab != ocekivano and Time.get_ticks_msec() < kraj:
		await create_timer(0.2).timeout
		ab = await _raspored_baza()
	return ab

func _raspored_scenario(p, bar) -> void:
	var ima: bool = p.has_method("promeni_action_slot")
	var prijema := [0] # koliko puta je server poslao raspored (i kad odbije zahtev)
	if p.has_signal("action_bar_promenjen"):
		p.action_bar_promenjen.connect(func(): prijema[0] += 1)
	if _korak == 2:
		await _cekaj(func(): return bar.slotovi == RASPORED_KRAJ, 5.0)
		await create_timer(0.5).timeout # količine stižu posle rasporeda
		_provera("raspored_prezivi_prijavu", bar.slotovi == RASPORED_KRAJ, "bar=%s" % [bar.slotovi])
		_provera("potroseni_ne_pomera_slotove", bar.slotovi[1] == "apple" and bar.kolicina(1) == 0 and bar._prikaz[1].kolicina.text == "0" \
			and bar.slotovi[0] == "medium_health_potion" and bar.slotovi[3] == "mana_potion",
			"slot2 '%s' x%s, slot1 '%s', slot4 '%s'" % [bar.slotovi[1], bar._prikaz[1].kolicina.text, bar.slotovi[0], bar.slotovi[3]])
		_raspored_kraj = true
		return

	await _cekaj(func(): return bar.slotovi == RASPORED_POCETNI, 5.0)
	var b: Array = await _cekaj_bazu(RASPORED_POCETNI)
	_provera("pocetni_raspored_upisan", bar.slotovi == RASPORED_POCETNI and b == RASPORED_POCETNI, "bar=%s baza=%s" % [bar.slotovi, b])

	# premeštanje: mana u slot 7 (stari slot 3 se prazni)
	if ima: p.promeni_action_slot(7, "mana_potion")
	await _cekaj(func(): return bar.slotovi == RASPORED_POMEREN, 5.0)
	b = await _cekaj_bazu(RASPORED_POMEREN)
	# nevažeći zahtevi: server odgovori rasporedom, ništa se ne menja
	var n0: int = prijema[0]
	if ima:
		p.promeni_action_slot(0, "apple")
		p.promeni_action_slot(11, "apple")
		p.promeni_action_slot(5, "nepostoji")
	await _cekaj(func(): return prijema[0] >= n0 + 3, 5.0)
	await create_timer(0.5).timeout
	var b2: Array = await _raspored_baza()
	_provera("nevazeci_slot_item_odbijen", ima and prijema[0] == n0 + 3 and b == RASPORED_POMEREN and bar.slotovi == RASPORED_POMEREN and b2 == RASPORED_POMEREN,
		"odgovora %d/3, bar=%s, baza pre=%s posle=%s" % [prijema[0] - n0, bar.slotovi, b, b2])

	# apple potrošen (HP 50/100): slot 2 ostaje rezervisan sa 0
	var r: Dictionary = await p.koristi_item_na_serveru("apple")
	await _cekaj(func(): return bar.kolicina(1) == 0, 3.0)
	# novi predmet ide u prvi prazan slot (3, ispražnjen premeštanjem)
	var k: Dictionary = await p.kupi_na_serveru("medium_health_potion")
	await _cekaj(func(): return bar.slotovi[2] != "" or bar.slotovi[3] != "", 5.0)
	b = await _cekaj_bazu(RASPORED_KUPLJEN)
	_provera("novi_predmet_prvi_prazan", bar.slotovi == RASPORED_KUPLJEN and b == RASPORED_KUPLJEN and bar.kolicina(1) == 0,
		"apple=%s kupovina=%s bar=%s baza=%s" % [r.get("ok"), k.get("ok"), bar.slotovi, b])
	await _prevlacenje_scenario(p, bar, prijema)
	_raspored_kraj = true

# ---------------------------------------------------------------- PREVLAČENJE (RasporedLik, korak 1, od RASPORED_KUPLJEN)

# Server: sopstveni cilj za "Esc tokom prevlačenja ne skida cilj", 8 m od RasporedLik-a i daleko od ostalih likova
# (goblini scenarija cilj su njegovi; driver ga smiri kao i ostale)
var _raspored_goblin := false
func _server_raspored() -> void:
	if _raspored_goblin or _world() == null: return
	_raspored_goblin = true
	_world().goblin_spawner.spawn({"vrsta": "goblin", "id": RASPORED_CILJ_ID, "pos": Vector3(-14, 2, 3)})

const RASPORED_CILJ_ID := 960

func _mis_taster(poz: Vector2, dole: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = dole
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if dole else 0
	e.position = poz
	e.global_position = poz
	Input.parse_input_event(e)

func _mis_pomeri(poz: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	e.position = poz
	e.global_position = poz
	Input.parse_input_event(e)

# pritisak na od, pomeranje u 4 koraka do kraj (frame između), pre_otpustanja (npr. Esc), otpuštanje na kraj
func _prevuci(od: Vector2, kraj: Vector2, pre_otpustanja := Callable()) -> void:
	_mis_taster(od, true)
	await process_frame
	for k in range(1, 5):
		_mis_pomeri(od.lerp(kraj, k / 4.0))
		await process_frame
	if pre_otpustanja.is_valid():
		await pre_otpustanja.call()
	_mis_taster(kraj, false)
	await process_frame

func _slot_bara(bar, i: int) -> Vector2: # i od 0
	return bar._prikaz[i].panel.get_global_rect().get_center()

func _kolicine(p) -> Array:
	return ["small_health_potion", "medium_health_potion", "mana_potion"].map(func(id): return int(p.kolicine.get(id, -1)))

func _inv_raspored(inv) -> Array:
	return inv.inventory_data.map(func(d): return "%s x%s" % [d.get("id", ""), d.get("kolicina", "")] if d is Dictionary else "")

# server poslao raspored: ceka ocekivano, pa jos 0.5 s da stigne i eventualno međustanje/višak
func _cekaj_raspored(bar, ocekivano: Array) -> void:
	await _cekaj(func(): return bar.slotovi == ocekivano, 5.0)
	await create_timer(0.5).timeout

func _prevlacenje_scenario(p, bar, prijema: Array) -> void:
	var rasporedi := [] # svaki raspored koji je server poslao
	if p.has_signal("action_bar_promenjen"):
		p.action_bar_promenjen.connect(func(): rasporedi.append(p.action_bar.duplicate()))
	var kol0 := _kolicine(p) # [2, 1, 1]

	# slot 7 (mana) -> prazan slot 5: premeštanje, napitak se ne koristi
	await _prevuci(_slot_bara(bar, 6), _slot_bara(bar, 4))
	await _cekaj_raspored(bar, RASPORED_PREMESTEN)
	_provera("prevlacenje_slot_na_prazan", bar.slotovi == RASPORED_PREMESTEN and _kolicine(p) == kol0,
		"bar=%s kolicine %s -> %s" % [bar.slotovi, kol0, _kolicine(p)])

	# slot 1 (small) -> zauzet slot 3 (medium): zamena jednim zahtevom, tačno jedan raspored od servera (bez međustanja)
	rasporedi.clear()
	await _prevuci(_slot_bara(bar, 0), _slot_bara(bar, 2))
	await _cekaj_raspored(bar, RASPORED_ZAMENJEN)
	_provera("prevlacenje_zamena_atomska", bar.slotovi == RASPORED_ZAMENJEN and rasporedi == [RASPORED_ZAMENJEN] and _kolicine(p) == kol0,
		"bar=%s rasporedi od servera=%s kolicine %s -> %s" % [bar.slotovi, rasporedi, kol0, _kolicine(p)])

	# Esc tokom prevlačenja (slot 5 -> slot 8): otkazano, ništa ne ide serveru, cilj ostaje; taster 1 (medium) tokom
	# prevlačenja se ignoriše
	var cilj := "goblin_%d" % RASPORED_CILJ_ID
	p.izaberi_cilj(cilj) # priprema (nije ono što se testira)
	await _cekaj(func(): return p.cilj_id == cilj, 3.0)
	var cilj_pre: String = p.cilj_id
	var n0: int = prijema[0]
	var duh := [false]
	await _prevuci(_slot_bara(bar, 4), _slot_bara(bar, 7), func():
		duh[0] = bar.get("_duh") != null
		_pritisni(KEY_1)
		_pritisni(KEY_ESCAPE)
		await process_frame)
	await create_timer(0.8).timeout
	_provera("esc_otkazuje_prevlacenje_ne_skida_cilj", duh[0] and cilj_pre != "" and p.cilj_id == cilj_pre
		and bar.slotovi == RASPORED_ZAMENJEN and prijema[0] == n0,
		"prevlacenje pocelo=%s cilj '%s' -> '%s', bar=%s, rasporeda od servera %d" % [duh[0], cilj_pre, p.cilj_id, bar.slotovi, prijema[0] - n0])
	_provera("tasteri_tokom_prevlacenja_ignorisani", duh[0] and _kolicine(p) == kol0,
		"prevlacenje pocelo=%s kolicine %s -> %s" % [duh[0], kol0, _kolicine(p)])

	# otpuštanje van prozora (slot 5 -> slot 8 -> van): otkazano, ništa ne ide serveru
	n0 = prijema[0]
	duh[0] = false
	var van := Vector2(-50, -50)
	_mis_taster(_slot_bara(bar, 4), true)
	await process_frame
	_mis_pomeri(_slot_bara(bar, 7))
	await process_frame
	_mis_pomeri(van)
	await process_frame
	duh[0] = bar.get("_duh") != null
	_mis_taster(van, false)
	await create_timer(0.8).timeout
	_provera("otpustanje_van_prozora_otkazuje", duh[0] and bar.slotovi == RASPORED_ZAMENJEN and prijema[0] == n0,
		"prevlacenje pocelo=%s bar=%s rasporeda od servera %d" % [duh[0], bar.slotovi, prijema[0] - n0])

	# slot 5 (mana) -> van trake (sredina ekrana): slot se prazni, predmet ostaje u inventaru
	var inv = p.get_node("ui/InventoryUI")
	var inv0 := _inv_raspored(inv)
	await _prevuci(_slot_bara(bar, 4), root.get_visible_rect().size / 2)
	await _cekaj_raspored(bar, RASPORED_UKLONJEN)
	_provera("prevlacenje_van_trake_prazni_slot", bar.slotovi == RASPORED_UKLONJEN and _inv_raspored(inv) == inv0
		and inv.prebroj_item("mana_potion") == 1 and _kolicine(p) == kol0,
		"bar=%s mana u inventaru %d, inventar isti=%s" % [bar.slotovi, inv.prebroj_item("mana_potion"), _inv_raspored(inv) == inv0])

	# inventar -> slot 4 (mana) i inventar (mač, nije potrošni) -> slot 6: raspored inventara se ne menja
	inv.toggle()
	await process_frame
	await process_frame
	# Esc tokom prevlačenja iz inventara na slot 6: otkazano, ništa ne ide serveru, cilj ostaje
	n0 = prijema[0]
	cilj_pre = p.cilj_id
	duh[0] = false
	await _prevuci(inv.slots[_inv_index(inv, "mana_potion")].get_global_rect().get_center(), _slot_bara(bar, 5), func():
		duh[0] = inv.is_dragging
		_pritisni(KEY_ESCAPE)
		await process_frame)
	await create_timer(0.8).timeout
	_provera("esc_otkazuje_prevlacenje_iz_inventara", duh[0] and cilj_pre != "" and p.cilj_id == cilj_pre
		and bar.slotovi == RASPORED_UKLONJEN and prijema[0] == n0 and _inv_raspored(inv) == inv0,
		"prevlacenje pocelo=%s cilj '%s' -> '%s', bar=%s, rasporeda od servera %d" % [duh[0], cilj_pre, p.cilj_id, bar.slotovi, prijema[0] - n0])
	n0 = prijema[0]
	await _prevuci(inv.slots[_inv_index(inv, "mana_potion")].get_global_rect().get_center(), _slot_bara(bar, 3))
	await _cekaj_raspored(bar, RASPORED_KRAJ)
	var posle_mane: int = prijema[0] - n0
	await _prevuci(inv.slots[_inv_index(inv, "iron_sword")].get_global_rect().get_center(), _slot_bara(bar, 5))
	await create_timer(0.8).timeout
	_provera("inventar_na_traku_raspored_inventara_isti", bar.slotovi == RASPORED_KRAJ and _inv_raspored(inv) == inv0
		and posle_mane == 1 and prijema[0] - n0 == 1,
		"bar=%s, rasporeda od servera %d (mana) / %d (+mac), inventar isti=%s" % [bar.slotovi, posle_mane, prijema[0] - n0, _inv_raspored(inv) == inv0])
	inv.toggle()

	# server odbija predmet koji nije potrošni (mač, lik ga ima) i potrošni koji lik nema i nije na traci; zahtev ide
	# direktno jer ga klijent mišem ne šalje
	n0 = prijema[0]
	if p.has_method("promeni_action_slot"):
		p.promeni_action_slot(6, "iron_sword")
		p.promeni_action_slot(6, "large_health_potion")
	await _cekaj(func(): return prijema[0] >= n0 + 2, 5.0)
	await create_timer(0.5).timeout
	var b: Array = await _raspored_baza()
	_provera("server_odbija_nepotrosni_i_tudji", prijema[0] == n0 + 2 and bar.slotovi == RASPORED_KRAJ and b == RASPORED_KRAJ,
		"odgovora %d/2, bar=%s baza=%s" % [prijema[0] - n0, bar.slotovi, b])

	# klik (bez pomeranja) na slot 3 (small x2) koristi napitak
	_mis_taster(_slot_bara(bar, 2), true)
	await process_frame
	_mis_taster(_slot_bara(bar, 2), false)
	await _cekaj(func(): return bar.kolicina(2) == 1, 3.0)
	_provera("klik_na_slot_koristi_napitak", bar.slotovi[2] == "small_health_potion" and bar.kolicina(2) == 1,
		"slot3 '%s' x%d" % [bar.slotovi[2], bar.kolicina(2)])
	await _cekaj_bazu(RASPORED_KRAJ)

# ---------------------------------------------------------------- CILJ (CiljLik na (-20, -20), gleda ka +z)
# Server drajver izvršava komande iz dir/cilj_cmd ("br komanda ime [x z | n]") nad test neprijateljima
# (goblin_9xx, max_hp 50) i upisuje cilj CiljLik-a po serveru i HP tog neprijatelja u dir/cilj_server ("id hp").

var _cilj_srv_cmd := ""
var _cilj_srv_upisan := ""
func _server_cilj() -> void:
	if dir == "" or _world() == null: return
	var cmd := FileAccess.get_file_as_string(dir + "/cilj_cmd")
	if cmd != "" and cmd != _cilj_srv_cmd:
		_cilj_srv_cmd = cmd
		var c := cmd.split(" ")
		var e = null
		for n in get_nodes_in_group("neprijatelj"):
			if str(n.get_parent().name) == c[2]: e = n
		if e == null and c[1] in ["pomeri", "steta", "mrtav", "ubij"]:
			print("[S] cilj komanda bez neprijatelja: ", cmd) # npr. već ubijen (stari kod bez cilja)
			c[1] = "-"
		match c[1]:
			"spawn": _world().goblin_spawner.spawn({"vrsta": "goblin", "id": int(c[2].get_slice("_", 1)), "pos": Vector3(float(c[3]), 2, float(c[4]))})
			"pomeri": e.global_position = Vector3(float(c[3]), e.global_position.y, float(c[4]))
			"steta": e.primi_damage(int(c[3]))
			"mrtav": e._mrtav = true # živ čvor sa oznakom smrti (između smrti i despawn-a)
			"ubij": e.primi_damage(100000)
			"ubij_lik":
				for p in _world().get_children():
					if p.is_in_group("player") and p.ime_lika == c[2]: p.server_primi_damage(100000)
		print("[S] cilj komanda: ", cmd)
		_pisi("cilj_cmd_ok", c[0])
	for p in _world().get_children():
		if p.is_in_group("player") and p.ime_lika == "CiljLik":
			var id := str(p.get("_cilj_srv")) if "_cilj_srv" in p else "-"
			var hp := -1
			for n in get_nodes_in_group("neprijatelj"):
				if str(n.get_parent().name) == id: hp = n.hp
			var st := "%s %d" % [id if id != "" else "_", hp]
			if st != _cilj_srv_upisan:
				_cilj_srv_upisan = st
				_pisi("cilj_server", st)

# Atomski upis: drugi proces pročita ili staro ili novo stanje, nikad prazan fajl (WRITE prvo isprazni fajl, pa bi
# čitanje u tom trenutku vratilo "" i sva polja prazna; pod opterećenjem se to dešavalo kod fajlova koji se pišu
# svaki frame, npr. ai_klijent_*). rename na istom disku je atomski i zamenjuje postojeći fajl.
func _pisi(ime: String, s: String) -> void:
	var f := FileAccess.open(dir + "/" + ime + ".tmp", FileAccess.WRITE)
	f.store_string(s)
	f.close()
	DirAccess.rename_absolute(dir + "/" + ime + ".tmp", dir + "/" + ime)

# observer: dok CiljLik ima cilj (dir/cilj_postavljen), niko drugi ga ne vidi
var _cilj_obs_ok := false
var _cilj_obs_detalj := ""
func _observer_cilj() -> void:
	if _cilj_obs_detalj != "" or dir == "" or not FileAccess.file_exists(dir + "/cilj_postavljen") or _world() == null: return
	var id := FileAccess.get_file_as_string(dir + "/cilj_postavljen")
	var cl = null
	for p in _world().get_children():
		if p.is_in_group("player") and p.get("ime_sync") == "CiljLik": cl = p
	var ja = _moj()
	var okvir = ja.get_node_or_null("ui/OkvirCilja") if ja else null
	var e = null
	for n in get_nodes_in_group("neprijatelj"):
		if str(n.get_parent().name) == id: e = n
	var tudji: String = str(cl.get("cilj_id")) if cl and "cilj_id" in cl else "?"
	var moj: String = str(ja.get("cilj_id")) if ja and "cilj_id" in ja else "?"
	var okvir_vidljiv: bool = okvir == null or okvir.okvir.visible
	var srv: String = _cilj_srv()[0] # cilj CiljLik-a po serveru u tom trenutku
	_cilj_obs_ok = srv == id and cl != null and tudji == "" and moj == "" and not okvir_vidljiv and e != null and not e.has_node("CiljPrsten")
	_cilj_obs_detalj = "server: CiljLik cilj '%s'; kod observera CiljLik.cilj_id '%s', moj '%s', okvir vidljiv=%s, prsten na %s=%s" % [srv, tudji, moj, okvir_vidljiv, id, e.has_node("CiljPrsten") if e else "-"]
	_pisi("cilj_proveren", "1")

var _cilj_krenuo := false
var _cilj_kraj := false
var _cilj_br := 0

func _cilj() -> bool:
	var p = _moj()
	if not _cilj_krenuo and p and p.get_node("ui/Control")._ucitano:
		_cilj_krenuo = true
		_cilj_scenario(p)
	# čeka DrugiLik-a do PARTNER_ROK; izlaz i kad server ode (nema mog lika)
	return _cilj_kraj or t > 2 * MAX_T or (_cilj_krenuo and p == null)

func _cilj_komanda(c: String) -> void:
	_cilj_br += 1
	_pisi("cilj_cmd", "%d %s" % [_cilj_br, c])
	await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/cilj_cmd_ok") == str(_cilj_br), 5.0)

func _cilj_srv() -> PackedStringArray: # [id ("" = nema), hp]
	var f := FileAccess.get_file_as_string(dir + "/cilj_server").split(" ")
	if f.size() != 2: return PackedStringArray(["?", "-1"])
	return PackedStringArray(["" if f[0] == "_" else f[0], f[1]])

func _nep(id: String):
	for n in get_nodes_in_group("neprijatelj"):
		if str(n.get_parent().name) == id: return n
	return null

func _klik(poz: Vector2) -> void:
	for dole in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = dole
		e.position = poz
		e.global_position = poz
		Input.parse_input_event(e)

func _klikni_neprijatelja(p, id: String) -> void:
	var e = _nep(id)
	if e: _klik(p.kamera.unproject_position(e.global_position))

func _cilj_scenario(p) -> void:
	var ima: bool = "cilj_id" in p
	var okvir = p.get_node_or_null("ui/OkvirCilja")
	var prijema := [0] # odgovori servera (i na odbijen zahtev)
	if p.has_signal("cilj_promenjen"): p.cilj_promenjen.connect(func(): prijema[0] += 1)
	var cilj := func() -> String: return str(p.cilj_id) if ima else "?"
	var okvir_vidljiv := func() -> bool: return okvir != null and okvir.okvir.visible
	p.rotation.y = PI # gleda ka +z (yaw ide serveru sa unosima)
	await _cilj_komanda("spawn goblin_901 -20 -12")  # 8 m ispred
	await _cilj_komanda("spawn goblin_902 -20 15")   # 35 m: van dometa
	await _cilj_komanda("spawn goblin_903 -15 -12")  # u dometu, kasnije označen kao mrtav
	await _cekaj(func(): return _nep("goblin_901") != null and _nep("goblin_903") != null, 5.0)
	await create_timer(2.0).timeout # padnu na pod, pozicija stigne klijentu

	# 1. klik bira neprijatelja, server beleži cilj, okvir i prsten
	_klikni_neprijatelja(p, "goblin_901")
	await _cekaj(func(): return cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901", 3.0)
	var e = _nep("goblin_901")
	_provera("cilj_klik_bira", cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901" and okvir_vidljiv.call() \
		and okvir.ime.text == "Goblin  Lv.1" and e != null and e.has_node("CiljPrsten"),
		"klijent '%s', server '%s', okvir=%s '%s', prsten=%s" % [cilj.call(), _cilj_srv()[0], okvir_vidljiv.call(), okvir.ime.text if okvir else "-", e.has_node("CiljPrsten") if e else "-"])
	# drugi igrač (observer) proverava dok je cilj postavljen
	_pisi("cilj_postavljen", "goblin_901")
	await _cekaj(func(): return FileAccess.file_exists(dir + "/cilj_proveren"), 10.0)

	# 2. okvir prati HP iz servera
	await _cilj_komanda("steta goblin_901 20")
	await _cekaj(func(): return okvir != null and okvir.hp_tekst.text == "30 / 50", 3.0)
	var shp := int(_cilj_srv()[1])
	_provera("okvir_prati_hp", okvir != null and shp == 30 and okvir.hp_tekst.text == "%d / 50" % shp and int(okvir.traka.value) == shp and okvir.traka.max_value == 50,
		"server hp %d, okvir '%s' traka %s/%s" % [shp, okvir.hp_tekst.text if okvir else "-", okvir.traka.value if okvir else "-", okvir.traka.max_value if okvir else "-"])

	# 3. van dometa (35 m): odbijeno, ostaje stari cilj
	var n0: int = prijema[0]
	if ima: p.izaberi_cilj("goblin_902")
	await _cekaj(func(): return prijema[0] > n0, 3.0)
	_provera("cilj_van_dometa_odbijen", ima and prijema[0] == n0 + 1 and cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901",
		"odgovora %d, klijent '%s', server '%s'" % [prijema[0] - n0, cilj.call(), _cilj_srv()[0]])

	# 4. nepostojeći ID i mrtav neprijatelj: odbijeno
	await _cilj_komanda("mrtav goblin_903")
	n0 = prijema[0]
	if ima:
		p.izaberi_cilj("nema_99")
		p.izaberi_cilj("goblin_903")
	await _cekaj(func(): return prijema[0] >= n0 + 2, 3.0)
	_provera("cilj_nepostojeci_i_mrtav_odbijen", ima and prijema[0] == n0 + 2 and cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901",
		"odgovora %d/2, klijent '%s', server '%s'" % [prijema[0] - n0, cilj.call(), _cilj_srv()[0]])

	# 5. klik preko action bara (ispod je pod: bez UI-ja bi skinuo cilj): ništa se ne šalje
	var bar = p.get_node("ui/ActionBar")
	n0 = prijema[0]
	_klik(bar.get_child(0).get_global_rect().get_center())
	await create_timer(1.0).timeout
	_provera("klik_preko_ui_ne_menja", ima and prijema[0] == n0 and cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901",
		"novih odgovora %d, klijent '%s', server '%s'" % [prijema[0] - n0, cilj.call(), _cilj_srv()[0]])

	# 6. klik na prazno (pod): skida cilj
	var pre_prazno: String = _cilj_srv()[0]
	_klik(p.kamera.unproject_position(Vector3(-23, 1.1, -14)))
	await _cekaj(func(): return cilj.call() == "" and _cilj_srv()[0] == "", 3.0)
	_provera("klik_na_prazno_brise", ima and pre_prazno == "goblin_901" and cilj.call() == "" and _cilj_srv()[0] == "" and not okvir_vidljiv.call() and e != null and not e.has_node("CiljPrsten"),
		"pre '%s', posle klijent '%s', server '%s', okvir=%s" % [pre_prazno, cilj.call(), _cilj_srv()[0], okvir_vidljiv.call()])

	# 7. Esc skida cilj
	_klikni_neprijatelja(p, "goblin_901")
	await _cekaj(func(): return cilj.call() == "goblin_901", 3.0)
	var pre_esc: String = cilj.call()
	_pritisni(KEY_ESCAPE)
	await _cekaj(func(): return cilj.call() == "" and _cilj_srv()[0] == "", 3.0)
	_provera("esc_brise_cilj", pre_esc == "goblin_901" and cilj.call() == "" and _cilj_srv()[0] == "", "pre '%s', posle klijent '%s' server '%s'" % [pre_esc, cilj.call(), _cilj_srv()[0]])

	# 7b. Esc sa otvorenim dijalogom pa trgovcem: zatvara samo prozor, cilj ostaje (bez prozora: esc_brise_cilj)
	_klikni_neprijatelja(p, "goblin_901")
	await _cekaj(func(): return cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901", 3.0)
	var dijalog = root.get_node("DialogueUI")
	var trgovac = root.get_node("MerchantUI")
	dijalog.open("Test NPC", ["Test"])
	await process_frame
	var dijalog_otvoren: bool = dijalog.is_open()
	_pritisni(KEY_ESCAPE)
	await create_timer(0.5).timeout
	var posle_dijaloga := [dijalog.is_open(), cilj.call(), _cilj_srv()[0]]
	trgovac.open("Test Trgovac")
	await process_frame
	var trgovac_otvoren: bool = trgovac.visible
	_pritisni(KEY_ESCAPE)
	await create_timer(0.5).timeout
	_provera("esc_zatvara_prozor_ne_cilj", dijalog_otvoren and not posle_dijaloga[0] and posle_dijaloga[1] == "goblin_901" and posle_dijaloga[2] == "goblin_901" \
		and trgovac_otvoren and not trgovac.visible and cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901",
		"dijalog %s->%s cilj '%s'/'%s'; trgovac %s->%s cilj '%s'/'%s' (klijent/server)" % [dijalog_otvoren, posle_dijaloga[0], posle_dijaloga[1], posle_dijaloga[2], trgovac_otvoren, trgovac.visible, cilj.call(), _cilj_srv()[0]])

	# 8. udaljavanje: 31 m ostaje (histereza), 33 m skida
	_klikni_neprijatelja(p, "goblin_901")
	await _cekaj(func(): return cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901", 3.0)
	var pre_udalj: String = _cilj_srv()[0]
	await _cilj_komanda("pomeri goblin_901 -20 11")
	await create_timer(1.0).timeout
	var na_31: String = _cilj_srv()[0]
	await _cilj_komanda("pomeri goblin_901 -20 13")
	await _cekaj(func(): return cilj.call() == "" and _cilj_srv()[0] == "", 3.0)
	_provera("udaljavanje_brise_cilj", ima and pre_udalj == "goblin_901" and na_31 == "goblin_901" and cilj.call() == "" and _cilj_srv()[0] == "",
		"pre '%s', na 31 m '%s', na 33 m klijent '%s' server '%s'" % [pre_udalj, na_31, cilj.call(), _cilj_srv()[0]])

	# 9. smrt cilja skida cilj
	await _cilj_komanda("pomeri goblin_901 -20 -12")
	await create_timer(1.0).timeout
	_klikni_neprijatelja(p, "goblin_901")
	await _cekaj(func(): return cilj.call() == "goblin_901" and _cilj_srv()[0] == "goblin_901", 3.0)
	var pre_smrti: String = _cilj_srv()[0]
	await _cilj_komanda("ubij goblin_901")
	await _cekaj(func(): return cilj.call() == "" and _cilj_srv()[0] == "", 3.0)
	_provera("smrt_cilja_brise", ima and pre_smrti == "goblin_901" and cilj.call() == "" and _cilj_srv()[0] == "" and not okvir_vidljiv.call(),
		"pre '%s', posle klijent '%s' server '%s' okvir=%s" % [pre_smrti, cilj.call(), _cilj_srv()[0], okvir_vidljiv.call()])

	# 10. NAPAD NA CILJ (taster R; stari napad je bio levi klik, pa ga test šalje gde treba da ne šteti)
	# goblin_904 2.7 m ispred-desno, goblin_905 2.5 m ispred-levo: oba u dometu napada (3 m + 0.5)
	var bar_poz: Vector2 = bar.get_child(0).get_global_rect().get_center()
	await _cilj_komanda("spawn goblin_904 -19 -17.5")
	await _cilj_komanda("spawn goblin_905 -21.5 -18")
	await _cekaj(func(): return _nep("goblin_904") != null and _nep("goblin_905") != null, 5.0)
	await create_timer(2.0).timeout # pad na pod
	var g4 = _nep("goblin_904")
	var g5 = _nep("goblin_905")
	var hp := func(g) -> int: return g.hp if is_instance_valid(g) else 0 # 0 = ubijen (despawn)
	var odg := [] # odgovori servera na napad
	if p.has_signal("napad_odgovor"): p.napad_odgovor.connect(func(d): odg.append(d))
	var poruka := func(i: int) -> String: return str(odg[i].get("poruka", "")) if odg.size() > i else "-"

	# a) bez cilja (smrt goblin_901 ga je skinula): "Nema cilja", bez štete
	_pritisni(KEY_R)
	await _cekaj(func(): return odg.size() >= 1, 3.0)
	await create_timer(0.5).timeout
	_provera("napad_bez_cilja", cilj.call() == "" and poruka.call(0) == "No target" and hp.call(g4) == 50 and hp.call(g5) == 50,
		"cilj '%s', odgovor '%s', hp 904=%d 905=%d" % [cilj.call(), poruka.call(0), hp.call(g4), hp.call(g5)])

	# b) klik na neprijatelja bira cilj, ali ne šteti
	_klikni_neprijatelja(p, "goblin_904")
	await _cekaj(func(): return cilj.call() == "goblin_904" and _cilj_srv()[0] == "goblin_904", 3.0)
	await create_timer(1.5).timeout
	_provera("klik_bira_ne_steti", cilj.call() == "goblin_904" and _cilj_srv()[0] == "goblin_904" and hp.call(g4) == 50 and hp.call(g5) == 50,
		"cilj '%s'/'%s', hp 904=%d 905=%d" % [cilj.call(), _cilj_srv()[0], hp.call(g4), hp.call(g5)])

	# c) klik preko UI-ja ne napada (i ne menja cilj)
	n0 = odg.size()
	_klik(bar_poz)
	await create_timer(1.5).timeout
	_provera("klik_preko_ui_ne_napada", odg.size() == n0 and cilj.call() == "goblin_904" and hp.call(g4) == 50 and hp.call(g5) == 50,
		"novih odgovora %d, cilj '%s', hp 904=%d 905=%d" % [odg.size() - n0, cilj.call(), hp.call(g4), hp.call(g5)])

	# d) napad pogađa samo cilj; e) drugi odmah posle: cooldown
	n0 = odg.size()
	_pritisni(KEY_R)
	await _cekaj(func(): return odg.size() > n0, 3.0)
	await _cekaj(func(): return hp.call(g4) < 50, 2.0)
	await create_timer(0.3).timeout
	var ok_d: bool = odg.size() > n0 and odg[n0].get("ok", false)
	_provera("napad_samo_cilj", ok_d and hp.call(g4) == 25 and hp.call(g5) == 50,
		"odgovor %s, hp 904 (cilj)=%d 905=%d" % [odg[n0] if odg.size() > n0 else "-", hp.call(g4), hp.call(g5)])
	n0 = odg.size()
	_pritisni(KEY_R)
	await _cekaj(func(): return odg.size() > n0, 3.0)
	await create_timer(0.3).timeout
	_provera("napad_cooldown", poruka.call(n0) == "Not ready yet" and hp.call(g4) == 25,
		"odgovor '%s', hp 904=%d" % [poruka.call(n0), hp.call(g4)])

	# g) drugi igrač (DrugiLik 2.5 m od goblin_904, bez cilja): klik + R ne štete tuđem cilju
	_pisi("drugi_kreni", "1")
	await _cekaj(func(): return FileAccess.file_exists(dir + "/drugi_gotov"), PARTNER_ROK)

	# f) cilj van dometa napada (6 m, ali u dometu cilja): "Predaleko"
	await _cilj_komanda("pomeri goblin_904 -19 -14")
	await create_timer(1.2).timeout # i cooldown istekne
	n0 = odg.size()
	var hp_pre: int = hp.call(g4)
	_pritisni(KEY_R)
	await _cekaj(func(): return odg.size() > n0, 3.0)
	await create_timer(0.3).timeout
	_provera("napad_predaleko", poruka.call(n0) == "Too far" and cilj.call() == "goblin_904" and hp.call(g4) == hp_pre,
		"odgovor '%s', cilj '%s', hp 904 %d->%d" % [poruka.call(n0), cilj.call(), hp_pre, hp.call(g4)])

	# h) smrt cilja skida cilj, naredni napad: "Nema cilja"
	await _cilj_komanda("ubij goblin_904")
	await _cekaj(func(): return cilj.call() == "" and _cilj_srv()[0] == "", 3.0)
	n0 = odg.size()
	_pritisni(KEY_R)
	await _cekaj(func(): return odg.size() > n0, 3.0)
	await create_timer(0.3).timeout
	_provera("smrt_cilja_pa_nema_cilja", cilj.call() == "" and poruka.call(n0) == "No target" and hp.call(g5) == 50,
		"cilj '%s', odgovor '%s', hp 905=%d" % [cilj.call(), poruka.call(n0), hp.call(g5)])

	# i) mrtav igrač ne napada (cilj goblin_905 u dometu)
	_klikni_neprijatelja(p, "goblin_905")
	await _cekaj(func(): return cilj.call() == "goblin_905", 3.0)
	await create_timer(1.2).timeout
	var hud = p.get_node("ui/Control")
	await _cilj_komanda("ubij_lik CiljLik")
	await _cekaj(func(): return hud.je_mrtav, 3.0)
	n0 = odg.size()
	_pritisni(KEY_R)
	_klik(p.kamera.unproject_position(g5.global_position) if is_instance_valid(g5) else bar_poz) # stari napad
	await _cekaj(func(): return odg.size() > n0, 3.0)
	await create_timer(0.5).timeout
	_provera("mrtav_ne_napada", hud.je_mrtav and poruka.call(n0) == "You are dead" and hp.call(g5) == 50,
		"mrtav=%s cilj '%s', odgovor '%s', hp 905=%d" % [hud.je_mrtav, cilj.call(), poruka.call(n0), hp.call(g5)])
	_cilj_kraj = true

# ---------------------------------------------------------------- DRUGI (DrugiLik 2.5 m od CiljLik-ovog cilja goblin_904)
# Kad CiljLik javi (dir/drugi_kreni): levi klik u nebo (nijedan neprijatelj pod mišem = bez sopstvenog cilja) i R.
# Ni jedno ni drugo ne sme da ošteti tuđi cilj; server odgovara "Nema cilja".
var _drugi_krenuo := false
var _drugi_kraj := false

func _uloga_drugi() -> bool:
	var p = _moj()
	if not _drugi_krenuo and p and p.get_node("ui/Control")._ucitano:
		_drugi_krenuo = true
		_drugi_scenario(p)
	# cilj stigne do napada tek posle ostalih faza (pod opterećenjem > 90 s); izlaz i kad server ode (nema mog lika)
	return _drugi_kraj or t > 2 * MAX_T or (_drugi_krenuo and p == null)

func _drugi_scenario(p) -> void:
	await _cekaj(func(): return FileAccess.file_exists(dir + "/drugi_kreni"), 2 * MAX_T)
	var e = _nep("goblin_904")
	var hp0: int = e.hp if e else -1
	var odg := []
	if p.has_signal("napad_odgovor"): p.napad_odgovor.connect(func(d): odg.append(d))
	_klik(Vector2(640, 5))
	await create_timer(0.3).timeout
	_pritisni(KEY_R)
	await _cekaj(func(): return odg.size() >= 1, 3.0)
	await create_timer(1.5).timeout
	var hp1: int = e.hp if is_instance_valid(e) else 0
	_provera("drugi_ne_napada_tudji_cilj", e != null and hp0 == 25 and hp1 == hp0 and odg.size() == 1 and str(odg[0].get("poruka", "")) == "No target",
		"goblin_904 (cilj CiljLik-a) hp %d->%d, odgovor %s, moj cilj '%s'" % [hp0, hp1, odg[0] if odg.size() > 0 else "-", p.get("cilj_id")])
	_pisi("drugi_gotov", "1")
	_drugi_kraj = true

# ---------------------------------------------------------------- AI NEPRIJATELJA
# Server vodi scenario nad test goblinom goblin_950 (početak AI_POCETAK, aggro 5 m, brzina 2 da povratak traje dovoljno
# dugo za provere). AiLik i Ai2Lik (uloga ai, korak=1/2) samo slušaju komande (dir/ai_cmd_<ime>: cilj, kraj) i
# svaki frame upisuju šta vide (dir/ai_klijent_<ime>: cilj|pretnja|ja_meta|okvir vidljiv|traka vidljiva|vrednost trake).
const AI_POCETAK := Vector3(20, 2, 20)
const AI_ID := "goblin_950"
const AI_STANJA := ["MIROVANJE", "JURENJE", "POVRATAK"]
var _ai_krenuo := false
var _ai_cmd_br := 0
var _ai_cmd_izvrsen := ""
var _ai_ucitan := false

func _uloga_ai() -> bool:
	var p = _moj()
	if p == null or not p.get_node("ui/Control")._ucitano:
		return (_ai_ucitan and p == null) or t > 3 * MAX_T # server otišao ili zaglavljen
	_ai_ucitan = true
	var ime: String = root.get_node("GameState").ime_igraca
	var cmd := FileAccess.get_file_as_string(dir + "/ai_cmd_" + ime)
	if cmd != "" and cmd != _ai_cmd_izvrsen:
		_ai_cmd_izvrsen = cmd
		var c := cmd.split(" ")
		print("[AI-K] ", ime, " komanda: ", cmd)
		if c[1] == "kraj":
			return true # odjava (proces izlazi, server dobije peer_disconnected)
		if c[1] == "cilj":
			p.izaberi_cilj(c[2] if c[2] != "-" else "")
	var o = p.get_node("ui/OkvirCilja")
	var tr = o.get("pretnja")
	var pr = p.get("cilj_pretnja")
	_pisi("ai_klijent_" + ime, "%s|%s|%s|%s|%s|%d" % [p.cilj_id, str(pr) if pr != null else "-1", str(p.get("cilj_ja_meta")),
		o.okvir.is_visible_in_tree(), tr != null and tr.is_visible_in_tree(), int(tr.value) if tr != null else -1])
	return t > 3 * MAX_T

func _ai_kl(ime: String) -> PackedStringArray:
	var s := FileAccess.get_file_as_string(dir + "/ai_klijent_" + ime).split("|")
	while s.size() < 6: s.append("")
	return s

func _ai_cmd(ime: String, cmd: String) -> void:
	_ai_cmd_br += 1
	_pisi("ai_cmd_" + ime, "%d %s" % [_ai_cmd_br, cmd])

func _ai_lik(ime: String):
	if _world() == null: return null
	for p in _world().get_children():
		if p.is_in_group("player") and p.ime_lika == ime: return p
	return null

func _telo(w):
	for n in w.get_children():
		if n.is_in_group("neprijatelj"): return n
	return null

func _st(e) -> String:
	var s = e.get("stanje")
	return AI_STANJA[s] if s is int else "-"

func _tab(e) -> Dictionary:
	var t_ = e.get("pretnja")
	return t_ if t_ is Dictionary else {}

func _pr(e, p) -> float:
	return float(_tab(e).get(p.get_multiplayer_authority(), -1.0))

func _meta(e) -> int:
	var m = e.get("_meta_id")
	return m if m is int else -1

func _xz(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))

func _server_ai() -> void:
	if _ai_krenuo or dir == "": return
	var a1 = _ai_lik("AiLik")
	var a2 = _ai_lik("Ai2Lik")
	if a1 and a2:
		_ai_krenuo = true
		_ai_scenario(a1, a2)

func _ai_scenario(a1, a2) -> void:
	var id1: int = a1.get_multiplayer_authority()
	var id2: int = a2.get_multiplayer_authority()
	await _cekaj(func(): return _ai_kl("AiLik")[0] != "" or _ai_kl("AiLik")[3] != "", 20.0) # klijenti učitani
	await _cekaj(func(): return _ai_kl("Ai2Lik")[3] != "", 20.0)
	# respawn: test server ne pali spawn tačke scene (troll na (0, 15) bi stajao na putanji movera), pa se pali samo
	# sopstvena tačka u uglu (20, -20); neprijatelja sa nje drajver smiri kao i ostale
	for tk in get_nodes_in_group("spawn_tacka"):
		tk.remove_from_group("spawn_tacka")
	var tacka := Marker3D.new()
	tacka.set_script(load("res://Scripts/World/spawn_point.gd"))
	tacka.position = Vector3(20, 2, -20)
	_world().add_child(tacka)
	_world()._aktivno = true
	var w = _world().goblin_spawner.spawn({"vrsta": "goblin", "id": 950, "pos": AI_POCETAK})
	var e = _telo(w)
	e.set_meta("ai_test", true)
	e.brzina = 2.0
	print("[S-AI] start, AiLik=%d Ai2Lik=%d, %s aggro %.1f" % [id1, id2, AI_ID, e.aggro_range])
	await create_timer(0.5).timeout
	_ai_cmd("AiLik", "cilj " + AI_ID)
	_ai_cmd("Ai2Lik", "cilj " + AI_ID)
	await _cekaj(func(): return _ai_kl("AiLik")[0] == AI_ID and _ai_kl("Ai2Lik")[0] == AI_ID, 5.0)
	var hp1: int = a1.hp
	var hp2: int = a2.hp
	await create_timer(2.0).timeout
	var d1 := _xz(a1.global_position, e.global_position)
	var d2 := _xz(a2.global_position, e.global_position)
	_provera("ai_mirovanje_ne_napada", _st(e) == "MIROVANJE" and _tab(e).is_empty() and _xz(e.global_position, AI_POCETAK) < 0.3
		and a1.hp == hp1 and a2.hp == hp2 and d1 > e.aggro_range and d2 > e.aggro_range,
		"stanje %s, pretnja %s, od početka %.2f m, igrači na %.1f / %.1f m, hp %d->%d / %d->%d" % [_st(e), _tab(e), _xz(e.global_position, AI_POCETAK), d1, d2, hp1, a1.hp, hp2, a2.hp])
	# cilj izabran, pretnje nema: traka sakrivena. Čeka se zapis klijenta sa tim ciljem i nacrtanim okvirom (rok 2 s),
	# pa se proverava traka (okvir i traka se osvežavaju u _process okvira, posle zapisa u istom frame-u)
	await _cekaj(func(): return _ai_kl("AiLik")[0] == AI_ID and _ai_kl("AiLik")[3] == "true", 2.0)
	var k_bez := _ai_kl("AiLik")

	# u aggro dometu: JURENJE sa početnom pretnjom, pa napad
	a1.server_postavi_poziciju(Vector3(20, 1.16, 17), true)
	var jur: bool = await _cekaj(func(): return _st(e) == "JURENJE", 2.0)
	var pr0 := _pr(e, a1)
	var napao: bool = await _cekaj(func(): return a1.hp < hp1, 6.0)
	_provera("ai_jurenje_u_dometu_napada", jur and is_equal_approx(pr0, 1.0) and _meta(e) == id1 and napao,
		"jurenje=%s, početna pretnja %.1f, meta %d (AiLik %d), napao=%s (hp %d->%d)" % [jur, pr0, _meta(e), id1, napao, hp1, a1.hp])

	# šteta 1:1; Ai2Lik (cilj isti, bez pretnje) ne vidi tuđu pretnju
	e.primi_damage(20, id1)
	_provera("ai_steta_pretnja_1_1", is_equal_approx(_pr(e, a1), 21.0), "pretnja AiLik %.1f (1 + 20)" % _pr(e, a1))
	await _cekaj(func(): return _ai_kl("AiLik")[1] == "100", 2.0)
	await create_timer(0.3).timeout
	var k1 := _ai_kl("AiLik")
	var k2 := _ai_kl("Ai2Lik")
	_provera("ai_posmatrac_ne_vidi_pretnju", k1[1] == "100" and k2[0] == AI_ID and k2[1] == "-1" and k2[4] == "false",
		"AiLik vidi %s%%, Ai2Lik (isti cilj '%s', bez pretnje) vidi %s, traka vidljiva=%s" % [k1[1], k2[0], k2[1], k2[4]])

	# promena mete tek preko 110%: 23 nije > 21*1.1 = 23.1, 24 jeste
	var ep: Vector3 = e.global_position
	a2.server_postavi_poziciju(Vector3(ep.x + 2.0, 1.16, ep.z), true)
	await _cekaj(func(): return is_equal_approx(_pr(e, a2), 1.0), 2.0)
	e.primi_damage(22, id2)
	await create_timer(0.5).timeout
	var ostao := _meta(e) == id1 and is_equal_approx(_pr(e, a2), 23.0)
	var meta_pre := _meta(e)
	await _cekaj(func(): return _ai_kl("Ai2Lik")[1] == "110", 2.0)
	var pre := [_ai_kl("AiLik"), _ai_kl("Ai2Lik")]
	e.primi_damage(1, id2)
	var promenjen: bool = await _cekaj(func(): return _meta(e) == id2, 1.0)
	_provera("ai_meta_tek_preko_110", ostao and promenjen,
		"pretnja AiLik %.1f, Ai2Lik 23: meta %d (AiLik %d); Ai2Lik 24: promenjena=%s" % [_pr(e, a1), meta_pre, id1, promenjen])
	await _cekaj(func(): return _ai_kl("AiLik")[1] == "88" and _ai_kl("Ai2Lik")[1] == "100", 2.0)
	var posle := [_ai_kl("AiLik"), _ai_kl("Ai2Lik")]
	var ok_pre: bool = pre[0][1] == "100" and pre[0][2] == "true" and pre[0][4] == "true" and pre[0][5] == "100" \
		and pre[1][1] == "110" and pre[1][2] == "false" and pre[1][4] == "true" and pre[1][5] == "110"
	var ok_posle: bool = posle[0][1] == "88" and posle[0][2] == "false" and posle[0][4] == "true" and posle[0][5] == "88" \
		and posle[1][1] == "100" and posle[1][2] == "true" and posle[1][5] == "100"
	_provera("ai_traka_pretnje_sa_servera", ok_pre and ok_posle,
		"meta AiLik: AiLik %s, Ai2Lik %s; meta Ai2Lik: AiLik %s, Ai2Lik %s (pretnja|meta|traka|vrednost)" % ["|".join(pre[0].slice(1)), "|".join(pre[1].slice(1)), "|".join(posle[0].slice(1)), "|".join(posle[1].slice(1))])
	_ai_cmd("AiLik", "cilj -")
	# bez cilja: čeka se da klijent javi da je cilj skinut i okvir sakriven (isti frame kao zapis ne mora da ga sakrije)
	await _cekaj(func(): return _ai_kl("AiLik")[0] == "" and _ai_kl("AiLik")[3] == "false", 2.0)
	var k_nema := _ai_kl("AiLik")
	_ai_cmd("AiLik", "cilj " + AI_ID)
	_provera("ai_traka_pretnje_sakrivena", pre[0][4] == "true" and k_bez[0] == AI_ID and k_bez[4] == "false" and k_nema[0] == "" and k_nema[4] == "false",
		"bez pretnje (cilj '%s'): traka=%s; bez cilja: traka=%s; sa pretnjom: traka=%s" % [k_bez[0], k_bez[4], k_nema[4], pre[0][4]])

	# smrt igrača briše njegovu pretnju (Ai2Lik se odmah odjavi, pre respawn-a na spawn tački)
	a2.server_primi_damage(100000)
	var obrisan: bool = await _cekaj(func(): return _pr(e, a2) < 0 and _meta(e) == id1, 1.0)
	_ai_cmd("Ai2Lik", "kraj")
	_provera("ai_smrt_brise_pretnju", a2.mrtav and obrisan and _pr(e, a1) > 0,
		"Ai2Lik mrtav=%s, pretnja %s, meta %d (AiLik %d)" % [a2.mrtav, _tab(e), _meta(e), id1])

	# leash: odvuci goblina od početka (~10 m), pa AiLik pobegne 17 m od njega
	a1.server_postavi_poziciju(Vector3(20, 1.16, 8), true)
	await _cekaj(func(): return e.global_position.z < 11.0, 8.0)
	ep = e.global_position
	a1.server_postavi_poziciju(Vector3(ep.x, 1.16, ep.z - 17.0), true)
	var pov: bool = await _cekaj(func(): return _st(e) == "POVRATAK", 1.0)
	var tab_pov := _tab(e).duplicate()
	var hp_l: int = a1.hp
	await create_timer(1.0).timeout
	_provera("ai_leash_povratak_ne_napada", pov and tab_pov.is_empty() and a1.hp == hp_l and _xz(e.global_position, AI_POCETAK) < _xz(ep, AI_POCETAK) - 0.5,
		"goblin %.1f m od početka, AiLik 17 m: povratak=%s, pretnja %s, hp AiLik %d->%d, od početka %.1f -> %.1f m" % [_xz(ep, AI_POCETAK), pov, tab_pov, hp_l, a1.hp, _xz(ep, AI_POCETAK), _xz(e.global_position, AI_POCETAK)])

	# povratak: ni aggro (AiLik 1.5 m od njega) ni šteta ne vraćaju u JURENJE
	ep = e.global_position
	a1.server_postavi_poziciju(Vector3(ep.x + 1.5, 1.16, ep.z), true)
	await create_timer(0.3).timeout
	e.primi_damage(1, id1)
	var hp_p: int = a1.hp
	await create_timer(0.7).timeout
	_provera("ai_povratak_ne_jurenje", _st(e) == "POVRATAK" and _tab(e).is_empty() and a1.hp == hp_p,
		"AiLik 1.5 m + šteta 1: stanje %s, pretnja %s, hp AiLik %d->%d" % [_st(e), _tab(e), hp_p, a1.hp])
	a1.server_postavi_poziciju(Vector3(14, 1.16, 22), true) # van aggro-a početne tačke (6.3 m)

	# stiže na početak i regeneriše do punog
	var stigao: bool = await _cekaj(func(): return _st(e) == "MIROVANJE", 12.0)
	var d_poc := _xz(e.global_position, AI_POCETAK)
	var hp_e: int = e.hp
	var pun: bool = await _cekaj(func(): return e.hp == e.max_hp, 10.0)
	_provera("ai_povratak_stize_regen", stigao and d_poc < 0.6 and hp_e < e.max_hp and pun,
		"mirovanje=%s na %.2f m od početka, hp %d -> %d/%d" % [stigao, d_poc, hp_e, e.hp, e.max_hp])

	# napadnut van aggro dometa: JURENJE, pretnja = šteta
	var d_van := _xz(a1.global_position, e.global_position)
	e.primi_damage(1, id1)
	var jur2: bool = await _cekaj(func(): return _st(e) == "JURENJE", 1.0)
	_provera("ai_napadnut_van_dometa_jurenje", jur2 and d_van > e.aggro_range and is_equal_approx(_pr(e, a1), 1.0),
		"AiLik na %.1f m (aggro %.1f): jurenje=%s, pretnja %.1f" % [d_van, e.aggro_range, jur2, _pr(e, a1)])

	# respawn sa spawn tačke: nov neprijatelj u MIROVANJU, prazna tabela
	var gw = _world()._zivi.get(tacka)
	var g = _telo(gw) if is_instance_valid(gw) else null
	var imao := false
	var staro := ""
	if g:
		staro = str(gw.name)
		g.primi_damage(1, id1)
		imao = not _tab(g).is_empty()
		g.primi_damage(100000, id1)
	var nov: bool = await _cekaj(func(): var n = _world()._zivi.get(tacka); return is_instance_valid(n) and str(n.name) != staro, 10.0)
	var ng = _telo(_world()._zivi.get(tacka)) if nov else null
	_provera("ai_respawn_mirovanje", imao and ng != null and _st(ng) == "MIROVANJE" and _tab(ng).is_empty() and ng.get("stanje") != null,
		"%s pretnja pre smrti=%s, respawn %s: stanje %s, pretnja %s" % [staro, imao, _world()._zivi.get(tacka).name if nov else "-", _st(ng) if ng else "-", _tab(ng) if ng else {}])

	# odjava briše pretnju
	var pr_pre := _pr(e, a1)
	_ai_cmd("AiLik", "kraj")
	var ob: bool = await _cekaj(func(): return _tab(e).is_empty() and _st(e) != "JURENJE", 5.0)
	_provera("ai_odjava_brise_pretnju", pr_pre > 0 and ob, "pretnja AiLik pre odjave %.1f, posle: %s, stanje %s" % [pr_pre, _tab(e), _st(e)])
	_pisi("ai_gotov", "1")

# ---------------------------------------------------------------- OPREMA I STATISTIKE
# Server: svaki frame upisuje statistike OpremaLik-a po serveru u dir/oprema_server (JSON) i izvršava komande iz
# dir/oprema_cmd ("N steta X" -> dir/oprema_steta "N hp_pre hp_posle", isti frame; "N hp X" = postavi HP).
# Klijent OpremaLik (korak 1) oprema kroz inventar (klik na predmet / na slot opreme) i šalje zahteve direktno;
# korak 2 je ponovna prijava; Oprema2Lik (korak 3) pokušava da opremi tuđi predmet.
var _opr_cmd := ""
var _opr_upisano := ""
var _opr_krenuo := false
var _opr_kraj := false
var _opr_cmd_br := 0
var _opr_ucitan_peer := ""

func _server_oprema() -> void:
	if dir == "" or _world() == null: return
	var p = _ai_lik("OpremaLik")
	if p == null: return
	var cmd := FileAccess.get_file_as_string(dir + "/oprema_cmd")
	if cmd != "" and cmd != _opr_cmd:
		_opr_cmd = cmd
		var c := cmd.split(" ")
		if c[1] == "steta":
			var pre: int = p.hp
			if c.size() > 3: p.server_primi_damage(int(c[2]), int(c[3])) # nivo napadača
			else: p.server_primi_damage(int(c[2]))
			_pisi("oprema_steta", "%s %d %d" % [c[0], pre, p.hp])
		elif c[1] == "hp":
			p.hp = int(c[2])
			p._posalji_hp()
		print("[S] oprema komanda: ", cmd)
	if p.get("_stanje_ucitano") and str(p.name) != _opr_ucitan_peer: # prvi frame posle učitavanja: HP pre regeneracije
		_opr_ucitan_peer = str(p.name)
		_pisi("oprema_ucitan", "%s %d" % [p.name, p.hp])
	var st := JSON.stringify({"attack": p.izracunaj_damage(), "armor": p.get("armor"), "max_hp": p.max_hp, "hp": p.hp,
		"oprema": p.get("oprema")})
	if st != _opr_upisano:
		_opr_upisano = st
		_pisi("oprema_server", st)

func _opr_srv() -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir + "/oprema_server"))
	return d if d is Dictionary else {}

func _opr_srv_oprema() -> Dictionary:
	var o = _opr_srv().get("oprema")
	return o if o is Dictionary else {}

func _opr_srv_ok(attack: int, armor: int, max_hp: int) -> bool:
	var d := _opr_srv()
	return int(d.get("attack", -1)) == attack and int(d.get("armor", -1) if d.get("armor") != null else -1) == armor \
		and int(d.get("max_hp", -1)) == max_hp

func _opr_cmd_posalji(cmd: String) -> void:
	_opr_cmd_br += 1
	_pisi("oprema_cmd", "%d %s" % [_opr_cmd_br, cmd])

func _opr_srv_opis() -> String:
	var d := _opr_srv()
	return "server attack %s armor %s max %s hp %s oprema %s" % [d.get("attack"), d.get("armor"), d.get("max_hp"), d.get("hp"), d.get("oprema")]

func _uloga_oprema() -> bool:
	var p = _moj()
	if p == null or not p.get_node("ui/Control")._ucitano:
		return (_opr_krenuo and p == null) or t > 2 * MAX_T
	if not _opr_krenuo:
		_opr_krenuo = true
		match _korak:
			1: _oprema_scenario(p, p.get_node("ui/InventoryUI"))
			2: _oprema_prijava(p, p.get_node("ui/InventoryUI"))
			3: _oprema_tudji(p)
	return _opr_kraj or t > 2 * MAX_T

func _inv_index(inv, id: String) -> int:
	for i in inv.inventory_data.size():
		if not inv.inventory_data[i].is_empty() and str(inv.inventory_data[i].get("id", "")) == id:
			return i
	return -1

func _opremljeno(inv) -> Dictionary:
	var eq := {}
	for k in inv.equipped_items:
		if not inv.equipped_items[k].is_empty():
			eq[k] = str(inv.equipped_items[k].get("id", ""))
	return eq

func _klijent_stat(p) -> String:
	return "%s/%s/%s" % [p.get("stat_attack"), p.get("stat_armor"), p.get("stat_max_hp")]

const OPREMA_ROK := 10.0 # s: opremanje/skidanje kroz UI (zahtev serveru, odgovor, raspored inventara)
func _oprema_scenario(p, inv) -> void:
	var odg := []
	if p.has_signal("oprema_odgovor"): p.oprema_odgovor.connect(func(d): odg.append(d))
	var zahtev := func(slot: String, id: String) -> Dictionary: # direktan zahtev serveru, čeka odgovor
		var n := odg.size()
		if p.has_method("zatrazi_opremanje"): p.zatrazi_opremanje.rpc_id(1, slot, id)
		await _cekaj(func(): return odg.size() > n, 3.0)
		return odg[n] if odg.size() > n else {}
	# klik na predmet u inventaru (UI). Čeka se uslov: predmet opremljen na serveru i u UI-ju (rok OPREMA_ROK). Sledeći klik
	# pre toga bi pogodio stari raspored inventara ili zahtev u toku (pod opterećenjem: čizme nisu opremljene, oklop 62).
	# opremi=false (rukavice): fiksni prozor posmatranja, proverava se da zahtev NIJE poslat.
	var klik := func(id: String, opremi := true) -> void:
		var i := _inv_index(inv, id)
		if i >= 0: inv._on_slot_klik(i)
		if opremi: await _cekaj(func(): return _opr_srv_oprema().values().has(id) and _opremljeno(inv).values().has(id), OPREMA_ROK)
		else: await create_timer(0.6).timeout
	var lbl = inv.get("stat_label")

	# neopremljen: osnovne vrednosti na serveru, kod klijenta i u sažetku inventara
	await _cekaj(func(): return _opr_srv_ok(25, 0, 100) and _klijent_stat(p) == "25/0/100", 5.0)
	_provera("oprema_osnovne_vrednosti", _opr_srv_ok(25, 0, 100) and _klijent_stat(p) == "25/0/100"
		and lbl != null and lbl.text == "Attack: 25   Armor: 0   Max HP: 100",
		"%s; klijent %s, sažetak '%s'" % [_opr_srv_opis(), _klijent_stat(p), lbl.text if lbl else "-"])

	# oružje: iron_sword +25
	await klik.call("iron_sword")
	await _cekaj(func(): return _opr_srv_ok(50, 0, 100) and _klijent_stat(p) == "50/0/100", 3.0)
	_provera("oruzje_povecava_stetu", _opr_srv_ok(50, 0, 100) and _klijent_stat(p) == "50/0/100" and _opremljeno(inv).get("weapon") == "iron_sword",
		"%s; klijent %s, UI oprema %s" % [_opr_srv_opis(), _klijent_stat(p), _opremljeno(inv)])

	# oklop 68 (kaciga 10 + grudi 20 + noge 12 + čizme 6 + štit 20): 25 štete -> 14
	for id in ["iron_helmet", "iron_chestplate", "iron_leggings", "iron_boots", "steel_shield"]:
		await klik.call(id)
	await _cekaj(func(): return _opr_srv_ok(50, 68, 110), 3.0)
	var oklop_ok := _opr_srv_ok(50, 68, 110)
	_opr_cmd_posalji("steta 25")
	await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/oprema_steta").begins_with(str(_opr_cmd_br) + " "), 3.0)
	var st := FileAccess.get_file_as_string(dir + "/oprema_steta").split(" ")
	var primljeno: int = int(st[1]) - int(st[2]) if st.size() == 3 else -1
	_provera("oklop_68_smanjuje_stetu_25_na_14", oklop_ok and primljeno == 14,
		"%s; 25 štete -> primljeno %d" % [_opr_srv_opis(), primljeno])
	# K = 100 + 10*(nivo napadača - 1): isti oklop protiv napadača nivoa 10 (K 190) i 20 (K 290)
	var po_nivou := []
	for x in [[10, 18], [20, 20]]:
		_opr_cmd_posalji("steta 25 %d" % x[0])
		await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/oprema_steta").begins_with(str(_opr_cmd_br) + " "), 3.0)
		st = FileAccess.get_file_as_string(dir + "/oprema_steta").split(" ")
		po_nivou.append(int(st[1]) - int(st[2]) if st.size() == 3 and st[0] == str(_opr_cmd_br) else -1)
	_provera("oklop_prema_nivou_napadaca_10_i_20", oklop_ok and po_nivou == [18, 20],
		"oklop 68, 25 štete: napadač nivoa 10 -> %d (očekivano 18), nivoa 20 -> %d (očekivano 20)" % po_nivou)

	# max_hp predmet: grudi iron_chestplate -> dragon_scale_armor (+50 max HP, armor 68 - 20 + 35 = 83)
	await klik.call("dragon_scale_armor")
	await _cekaj(func(): return _opr_srv_ok(50, 83, 160) and _klijent_stat(p) == "50/83/160", 3.0)
	_provera("max_hp_predmet_podize_maksimum", _opr_srv_ok(50, 83, 160) and _klijent_stat(p) == "50/83/160"
		and _opremljeno(inv).get("chest") == "dragon_scale_armor" and _inv_index(inv, "iron_chestplate") >= 0,
		"%s; klijent %s, UI oprema %s" % [_opr_srv_opis(), _klijent_stat(p), _opremljeno(inv)])

	# skidanje max_hp predmeta ograničava HP: HP 160 -> skini grudi -> max 110, HP 110
	_opr_cmd_posalji("hp 160")
	await _cekaj(func(): return int(_opr_srv().get("hp", 0)) == 160, 3.0)
	inv._skini_opremu("chest")
	await _cekaj(func(): return _opr_srv_ok(50, 48, 110), 3.0)
	await create_timer(0.3).timeout
	var d := _opr_srv()
	_provera("skidanje_max_hp_ogranicava_hp", _opr_srv_ok(50, 48, 110) and int(d.get("hp", -1)) == 110,
		"%s (pre skidanja HP 160)" % _opr_srv_opis())

	# odbijanja (direktni zahtevi): nije u inventaru, pogrešan slot, isti predmet dvaput, rukavice bez slota
	var pre_eq := _opremljeno(inv)
	var pre_srv = _opr_srv().get("oprema")
	var r1: Dictionary = await zahtev.call("weapon", "golden_sword")
	_provera("odbija_predmet_koji_nije_u_inventaru", r1.get("ok", true) == false and _opr_srv().get("oprema") == pre_srv,
		"golden_sword (nije u inventaru): %s; %s" % [r1, _opr_srv_opis()])
	inv._skini_opremu("head")
	await _cekaj(func(): return _opr_srv_ok(50, 38, 110), 3.0)
	var r2: Dictionary = await zahtev.call("boots", "iron_helmet")
	_provera("odbija_pogresan_slot", r2.get("ok", true) == false and _opr_srv_ok(50, 38, 110) and str(_opr_srv().get("oprema", {}).get("boots")) == "iron_boots",
		"iron_helmet u boots: %s; %s" % [r2, _opr_srv_opis()])
	await klik.call("iron_helmet")
	await _cekaj(func(): return _opr_srv_ok(50, 48, 110), 3.0)
	var r3: Dictionary = await zahtev.call("head", "iron_helmet")
	_provera("odbija_isti_predmet_dvaput", _opr_srv_ok(50, 48, 110) and r3.get("ok", true) == false,
		"iron_helmet već opremljen, ponovo u head: %s; %s" % [r3, _opr_srv_opis()])
	var n_odg := odg.size()
	var gi := _inv_index(inv, "iron_gloves")
	await klik.call("iron_gloves", false)
	if gi >= 0: inv._on_slot_hover(gi)
	var tooltip: String = inv.tooltip_label.text
	var r4: Dictionary = await zahtev.call("head", "iron_gloves")
	_provera("iron_gloves_se_ne_oprema", gi >= 0 and odg.size() == n_odg + 1 and _inv_index(inv, "iron_gloves") == gi
		and _opremljeno(inv).get("head") == "iron_helmet" and "Can't be equipped" in tooltip and r4.get("ok", true) == false and _opr_srv_ok(50, 48, 110),
		"klik bez zahteva=%s, ostao u slotu %d=%s, tooltip ima 'Can't be equipped'=%s, zahtev: %s; %s" % [odg.size() == n_odg + 1, gi, _inv_index(inv, "iron_gloves") == gi, "Can't be equipped" in tooltip, r4, _opr_srv_opis()])

	# skidanje vraća osnovne vrednosti i sve predmete u inventar
	for slot in ["weapon", "head", "legs", "boots", "shield"]:
		inv._skini_opremu(slot)
		await _cekaj(func(): return not _opr_srv_oprema().has(slot) and not _opremljeno(inv).has(slot), OPREMA_ROK)
	await _cekaj(func(): return _opr_srv_ok(25, 0, 100) and _klijent_stat(p) == "25/0/100", 3.0)
	var svi := ["iron_sword", "iron_helmet", "iron_chestplate", "iron_leggings", "iron_boots", "steel_shield", "dragon_scale_armor", "iron_gloves"]
	var u_inv := svi.filter(func(x): return _inv_index(inv, x) >= 0).size()
	_provera("skidanje_vraca_stare_vrednosti", _opr_srv_ok(25, 0, 100) and _klijent_stat(p) == "25/0/100" and _opremljeno(inv).is_empty() and u_inv == 8
		and lbl != null and lbl.text == "Attack: 25   Armor: 0   Max HP: 100",
		"%s; klijent %s, UI oprema %s, u inventaru %d/8" % [_opr_srv_opis(), _klijent_stat(p), _opremljeno(inv), u_inv])

	# drugi igrač šalje zahtev za MOJ lik (moj iron_sword u weapon): server ga ignoriše
	_pisi("oprema_tudji_kreni", str(p.get_multiplayer_authority()))
	await _cekaj(func(): return FileAccess.file_exists(dir + "/oprema_tudji_poslato"), PARTNER_ROK)
	await create_timer(1.0).timeout
	_provera("drugi_igrac_ne_oprema_tudji_predmet", FileAccess.file_exists(dir + "/oprema_tudji_poslato") and _opr_srv_ok(25, 0, 100)
		and _opr_srv().get("oprema") is Dictionary and _opr_srv().get("oprema").is_empty(),
		"Oprema2Lik poslao weapon/iron_sword za OpremaLik: %s" % _opr_srv_opis())

	# za ponovnu prijavu: iron_sword + dragon_scale_armor, HP 150 (iznad osnovnog 100), pa odjava (server snima).
	# HP je na maksimumu, pa ga regeneracija ne menja: HP pri odjavi je tačan broj.
	await klik.call("iron_sword")
	await klik.call("dragon_scale_armor")
	await _cekaj(func(): return _opr_srv_ok(50, 35, 150), 3.0)
	_opr_cmd_posalji("hp 150")
	await _cekaj(func(): return int(_opr_srv().get("hp", 0)) == 150, 3.0)
	await create_timer(1.0).timeout # klijent pošalje raspored (posalji_stanje) posle poslednje promene
	_pisi("oprema_korak1", JSON.stringify(_opr_srv()))
	print("[OPREMA] korak 1 gotov: ", _opr_srv_opis())
	_opr_kraj = true

func _oprema_prijava(p, inv) -> void:
	await _cekaj(func(): return _opr_srv_ok(50, 35, 150) and _klijent_stat(p) == "50/35/150" and _opremljeno(inv).size() == 2, 8.0)
	var d := _opr_srv()
	_provera("statistike_prezive_prijavu", _opr_srv_ok(50, 35, 150) and _klijent_stat(p) == "50/35/150"
		and _opremljeno(inv) == {"weapon": "iron_sword", "chest": "dragon_scale_armor"},
		"%s; klijent %s, UI oprema %s" % [_opr_srv_opis(), _klijent_stat(p), _opremljeno(inv)])
	# HP pri odjavi (korak 1) = HP koji je stub snimio = HP na serveru u prvom frame-u posle učitavanja (pre regeneracije)
	var k1 = JSON.parse_string(FileAccess.get_file_as_string(dir + "/oprema_korak1"))
	var hp_odjava: int = int(k1.get("hp", -1)) if k1 is Dictionary else -1
	var hp_stub: int = int((await root.get_node("ApiManager").get_player("OpremaLik")).get("hp", -1))
	await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/oprema_ucitan").begins_with(_id() + " "), 5.0)
	var uc := FileAccess.get_file_as_string(dir + "/oprema_ucitan").split(" ")
	var hp_ucitan: int = int(uc[1]) if uc.size() == 2 and uc[0] == _id() else -1
	_provera("hp_iznad_osnovnog_prezivi_prijavu", hp_odjava > 100 and hp_odjava == hp_stub and hp_stub == hp_ucitan and int(d.get("max_hp", -1)) == 150,
		"HP pri odjavi %d, snimljen u stub-u %d, na serveru posle učitavanja %d (max %s, osnovni 100)" % [hp_odjava, hp_stub, hp_ucitan, d.get("max_hp")])
	await _kamera_fp_pa_nazad(p)
	_opr_kraj = true

func _oprema_tudji(p) -> void:
	await _cekaj(func(): return FileAccess.file_exists(dir + "/oprema_tudji_kreni"), 2 * MAX_T)
	var tudji = _world().get_node_or_null(FileAccess.get_file_as_string(dir + "/oprema_tudji_kreni"))
	if tudji and tudji.has_method("zatrazi_opremanje"):
		tudji.zatrazi_opremanje.rpc_id(1, "weapon", "iron_sword")
	elif tudji and tudji.has_method("postavi_oruzje"):
		tudji.postavi_oruzje.rpc_id(1, "iron_sword") # stari put opremanja oružja
	await create_timer(0.3).timeout
	_pisi("oprema_tudji_poslato", "1")
	_opr_kraj = true

# Kamera: zum do first person-a, pogled gore/dole do granice i nazad istim pokretom, odzum. Posle toga kamera mora biti
# kao pre ulaska (pitch, yaw/roll, offset i model vidljiv); kretanje miša bez granice je i ranije bilo reverzibilno.
func _kamera_fp_pa_nazad(p) -> void:
	var k: Camera3D = p.kamera
	var model: Node3D = p.get_node("CharacterMain")
	var pre_rot := k.rotation
	var pre_off: Vector3 = p._kamera_poz
	var dogadjaj := func(e: InputEvent) -> void:
		Input.parse_input_event(e)
		await process_frame
		await process_frame
	var tocak := func(gore: bool) -> void:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_WHEEL_UP if gore else MOUSE_BUTTON_WHEEL_DOWN
		e.pressed = true
		await dogadjaj.call(e)
	var desni := func(dole: bool) -> void:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_RIGHT
		e.pressed = dole
		await dogadjaj.call(e)
	var mis := func(dy: float) -> void:
		var e := InputEventMouseMotion.new()
		e.relative = Vector2(0, dy)
		await dogadjaj.call(e)
	for i in 4: await tocak.call(true) # do kraja: first person
	var fp: bool = not model.visible and p._kamera_poz.z <= 0.1
	await desni.call(true)
	for i in 20: await mis.call(-40) # gore preko granice
	var gore_ok := absf(rad_to_deg(k.rotation.x) - 60.0) < 0.5
	for i in 40: await mis.call(40)  # dole preko granice
	var dole_ok := absf(rad_to_deg(k.rotation.x) + 60.0) < 0.5
	# sa donje granice (-60°) nazad tačno do početnog pitch-a (jedan pokret, bez granice)
	await mis.call(-(rad_to_deg(pre_rot.x) + 60.0) / p.mouse_sensitivity)
	await desni.call(false)
	var posle_fp_pogleda := k.rotation
	while model.visible == false or p._kamera_poz.z < pre_off.z - 0.001: # odzum dok se ne vrati na početni offset (ili do kraja)
		var z: float = p._kamera_poz.z
		await tocak.call(false)
		if p._kamera_poz.z == z:
			break
	var razlika := (k.rotation - pre_rot) * 180.0 / PI
	var u_opsegu := absf(rad_to_deg(k.rotation.x)) <= 60.0
	_provera("kamera_fp_pa_nazad_isti_ugao_i_offset", fp and gore_ok and dole_ok and razlika.length() < 0.05 and u_opsegu
		and p._kamera_poz.is_equal_approx(pre_off) and model.visible,
		"first person=%s, granice gore/dole=%s/%s, rot pre %s posle %s (razlika %s stepeni), offset pre %s posle %s, model=%s" % [
			fp, gore_ok, dole_ok, (pre_rot * 180.0 / PI).snapped(Vector3.ONE * 0.01), (k.rotation * 180.0 / PI).snapped(Vector3.ONE * 0.01),
			razlika.snapped(Vector3.ONE * 0.01), pre_off.snapped(Vector3.ONE * 0.001), p._kamera_poz.snapped(Vector3.ONE * 0.001), model.visible])

# ---------------------------------------------------------------- NAPREDAK LIKA
# NapredakLik (uloga napredak, korak 1) traži od servera ubistva test goblina sa zadatim XP-om (dir/napredak_cmd
# "br ubij XP" / "br hp HP MANA"): goblin umire pravim putem (Enemy.primi_damage -> _isplati_kill -> server_isplati_xp ->
# stub /xp/change sa krivom iz napredak.py). Server upisuje svoje statistike lika u dir/napredak_server.
# Korak 2 je ponovna prijava. Kriva: 100 XP za nivo 2, 250 za 3, 450 za 4; nivo 20 je maksimum.
var _np_cmd := ""
var _np_upisano := ""
var _np_krenuo := false
var _np_kraj := false
var _np_br := 0

func _server_napredak() -> void:
	if dir == "" or _world() == null: return
	var p = _ai_lik("NapredakLik")
	if p == null: return
	var cmd := FileAccess.get_file_as_string(dir + "/napredak_cmd")
	if cmd != "" and cmd != _np_cmd:
		_np_cmd = cmd
		_np_izvrsi(p, cmd.split(" "))
	var st := JSON.stringify({"attack": p.izracunaj_damage(), "osnovni_napad": p.napad_damage, "osnovni_max_hp": p.max_hp_osnovni,
		"max_hp": p.max_hp, "hp": p.hp, "mana": p.mana, "max_mana": p.max_mana, "ok": _np_cmd.get_slice(" ", 0)})
	if st != _np_upisano:
		_np_upisano = st
		_pisi("napredak_server", st)

func _np_izvrsi(p, c: PackedStringArray) -> void:
	print("[S] napredak komanda: ", " ".join(c))
	if c[1] == "hp":
		p.hp = int(c[2])
		p.mana = int(c[3])
		p._posalji_hp()
		return
	if c[1] == "xp": # XP mimo ubistva (kao nagrada questa): ubistvo je ograničeno na 25% XP-a nivoa
		p.server_isplati_xp(int(c[2]), "test")
		await create_timer(1.0).timeout
		return
	var id := 970 + int(c[0])
	_world().goblin_spawner.spawn({"vrsta": "goblin", "id": id, "pos": Vector3(26, 2, 0)})
	await _cekaj(func(): return _nep("goblin_%d" % id) != null, 3.0)
	var e = _nep("goblin_%d" % id)
	if e:
		e.xp_nagrada = int(c[2]) # test: nagrada po meri krive (sadržaj ostaje: goblin daje 25)
		e.primi_damage(100000, p.get_multiplayer_authority())

func _np_srv() -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir + "/napredak_server"))
	return d if d is Dictionary else {}

# server: [attack, osnovni max HP, max HP, hp, mana, max mana]
func _np_srv_ok(v: Array) -> bool:
	var d := _np_srv()
	return [int(d.get("attack", -1)), int(d.get("osnovni_max_hp", -1)), int(d.get("max_hp", -1)), int(d.get("hp", -1)),
		int(d.get("mana", -1)), int(d.get("max_mana", -1))] == v

func _np_cmd_posalji(cmd: String) -> void:
	_np_br += 1
	_pisi("napredak_cmd", "%d %s" % [_np_br, cmd])
	await _cekaj(func(): return str(_np_srv().get("ok", "")) == str(_np_br), 5.0)

func _uloga_napredak() -> bool:
	var p = _moj()
	if p == null or not p.get_node("ui/Control")._ucitano:
		return (_np_krenuo and p == null) or t > 2 * MAX_T
	if not _np_krenuo:
		_np_krenuo = true
		if _korak == 1: _napredak_scenario(p, p.get_node("ui/Control"))
		else: _napredak_prijava(p, p.get_node("ui/Control"))
	return _np_kraj or t > 2 * MAX_T

func _np_xp_tekst(hud) -> String:
	var l = hud.xp_bar.get_node_or_null("XPLabel")
	return l.text if l else "-"

func _np_poruka(hud) -> String:
	var l = hud.get("_poruka_label")
	return l.text if l != null and l.visible else "-"

func _np_opis(p, hud) -> String:
	var b = hud.xp_bar
	return "HUD Lv.%d xp %d/%d '%s' bar %s/%s, HUD hp %d/%d mana %d/%d, klijent napad %s; server %s" % [hud.level, hud.xp, hud.max_xp,
		_np_xp_tekst(hud), b.value, b.max_value, hud.hp, hud.max_hp, hud.mana, hud.max_mana, p.napad_damage, _np_srv()]

func _np_stub() -> Dictionary:
	return await root.get_node("ApiManager").get_player("NapredakLik")

# HUD i stub (baza) pokazuju [nivo, xp, max_xp]
func _np_nivo_ok(hud, st: Dictionary, v: Array) -> bool:
	return [hud.level, hud.xp, hud.max_xp] == v and [int(st.get("level", -1)), int(st.get("xp", -1)), int(st.get("max_xp", -1))] == v

func _napredak_scenario(p, hud) -> void:
	# 1) nivo 1 (0/100), ranjen: četiri ubistva po 25 XP (= limit od 25% XP-a nivoa) -> tačno nivo 2 (0/250). Server:
	#    napad 12, max HP 115 + štit 10, HP i mana puni; HUD prikazuje isto (max HP sa bonusom opreme), "Level up! Lv.2"
	await _cekaj(func(): return hud.level == 1 and _np_srv().has("attack"), 5.0)
	for _i in 3:
		await _np_cmd_posalji("ubij 25")
	await _cekaj(func(): return hud.xp == 75, 5.0)
	await _np_cmd_posalji("hp 40 30")
	await _np_cmd_posalji("ubij 25")
	var v2 := [12, 115, 125, 125, 110, 110]
	await _cekaj(func(): return hud.level == 2 and _np_srv_ok(v2) and hud.max_hp == 125 and hud.hp == 125, 5.0)
	var poruka := _np_poruka(hud)
	var st: Dictionary = await _np_stub()
	_provera("napredak_ubistvo_daje_xp_i_level_up_po_krivi", _np_nivo_ok(hud, st, [2, 0, 250]) and _np_xp_tekst(hud) == "XP: 0 / 250  |  Lv.2"
		and int(p.napad_damage) == 12, "%s; stub lv %s xp %s/%s" % [_np_opis(p, hud), st.get("level"), st.get("xp"), st.get("max_xp")])
	_provera("napredak_level_up_poruka_u_hud_u", poruka == "Level up! Lv.2", "poruka '%s'" % poruka)
	_provera("napredak_statistike_sa_servera_pun_hp_i_mana_sa_bonusom_opreme", _np_srv_ok(v2) and hud.max_hp == 125 and hud.hp == 125
		and hud.max_mana == 110 and hud.mana == 110 and int(st.get("hp", -1)) == 125,
		"%s; stub hp %s (pre ubistva HP 40, mana 30; osnovni max HP 115 + steel_shield 10)" % [_np_opis(p, hud), st.get("hp")])

	# 2) više nivoa odjednom (XP mimo ubistva, kao nagrada questa): 250 + 450 + 30 -> nivo 4 (30/700), napad 16, max HP 145 + 10
	await _np_cmd_posalji("hp 40 30")
	await _np_cmd_posalji("xp 730")
	var v4 := [16, 145, 155, 155, 130, 130]
	await _cekaj(func(): return hud.level == 4 and _np_srv_ok(v4), 5.0)
	poruka = _np_poruka(hud)
	st = await _np_stub()
	_provera("napredak_vise_nivoa_odjednom", _np_nivo_ok(hud, st, [4, 30, 700]) and _np_xp_tekst(hud) == "XP: 30 / 700  |  Lv.4"
		and _np_srv_ok(v4) and hud.max_hp == 155 and poruka == "Level up! Lv.4",
		"%s; poruka '%s'; stub lv %s xp %s/%s" % [_np_opis(p, hud), poruka, st.get("level"), st.get("xp"), st.get("max_xp")])

	# 3) nivo 20 je maksimum: XP se ne skuplja (0/0), traka "MAX" i puna, sledeće ubistvo ništa ne menja
	await _np_cmd_posalji("xp 1000000")
	var v20 := [48, 385, 395, 395, 290, 290]
	await _cekaj(func(): return hud.level == 20 and _np_srv_ok(v20), 5.0)
	var tekst20 := _np_xp_tekst(hud)
	await create_timer(PORUKA_SLEDECA).timeout # poruka nivoa 20 se ugasi pre sledećeg ubistva
	await _np_cmd_posalji("ubij 500")
	await create_timer(1.5).timeout # odgovor stub-a stiže posle smrti goblina
	st = await _np_stub()
	var b = hud.xp_bar
	_provera("napredak_nivo_20_maksimum_xp_se_ne_skuplja", tekst20 == "XP: MAX  |  Lv.20" and _np_nivo_ok(hud, st, [20, 0, 0])
		and _np_xp_tekst(hud) == "XP: MAX  |  Lv.20" and b.max_value > 0 and b.value == b.max_value and _np_srv_ok(v20)
		and _np_poruka(hud) == "-",
		"%s; poruka posle ubistva na 20 '%s'; stub lv %s xp %s/%s" % [_np_opis(p, hud), _np_poruka(hud), st.get("level"), st.get("xp"), st.get("max_xp")])
	print("[NAPREDAK] korak 1 gotov: ", _np_opis(p, hud))
	_np_kraj = true

func _napredak_prijava(p, hud) -> void:
	var v20 := [48, 385, 395, 395, 290, 290]
	await _cekaj(func(): return hud.level == 20 and _np_srv_ok(v20) and hud.max_hp == 395, 8.0)
	var st: Dictionary = await _np_stub()
	_provera("napredak_statistike_prezive_prijavu", _np_nivo_ok(hud, st, [20, 0, 0]) and _np_xp_tekst(hud) == "XP: MAX  |  Lv.20"
		and _np_srv_ok(v20) and int(p.napad_damage) == 48 and hud.max_hp == 395 and hud.max_mana == 290,
		"%s; stub lv %s napad %s max_hp %s max_mana %s" % [_np_opis(p, hud), st.get("level"), st.get("napad_damage"), st.get("max_hp"), st.get("max_mana")])
	_np_kraj = true

# ---------------------------------------------------------------- SADRŽAJ (uloga quest: QuestLik + PosmatracLik)
# Server: provere scene i podataka (spawn tačke i nivoi, XP prema razlici nivoa, loot tabele) i komande iz
# dir/quest_cmd ("br ubij <nivo> <napadač> [<lik sa štetom 0>]", "br spawn <vrsta> <id> <nivo>"), potvrda u dir/quest_server.
# QuestLik: Village Elder klikom (prihvat, predaja, lanac), loot i kill credit samo napadaču, XP po razlici nivoa
# (PosmatracLik nivo 12 ubija goblina zadatog nivoa), skalirane statistike na klijentu, prodavnica.

const NAJBOLJA_OPREMA := ["dragon_scale_armor", "dragon_staff", "golden_helmet", "golden_sword", "shadow_cloak", "shadow_dagger"]
const VRSTE := {"goblin": "res://Scenes/Enemies/goblin.tscn", "skeleton": "res://Scenes/Enemies/skeleton.tscn",
	"troll": "res://Scenes/Enemies/troll.tscn", "wolf": "res://Scenes/Enemies/wolf.tscn", "spider": "res://Scenes/Enemies/spider.tscn",
	"wraith": "res://Scenes/Enemies/wraith.tscn"}
const NIVOI_VRSTA := {"goblin": [1, 3], "skeleton": [4, 6], "troll": [8, 10], "wolf": [11, 13], "spider": [14, 16], "wraith": [17, 20]}
const BROJ_TACAKA := {"goblin": 3, "skeleton": 3, "troll": 2, "wolf": 3, "spider": 3, "wraith": 3}
const ZONA2 := {"wolf": [11, 12, 13], "spider": [14, 15, 16], "wraith": [17, 18, 20]} # x > 25
# T3/T4 oprema zone 2: vrsta, najniži nivo instance od koje pada (min_nivo), šansa %
const T34_LOOT := {"steel_greaves": ["spider", 11, 3.0], "shadow_boots": ["wraith", 17, 2.0], "dragonscale_leggings": ["wraith", 20, 0.4]}
const NOVI_PREDMETI := ["cloth_trousers", "leather_pants", "steel_greaves", "dragonscale_leggings", "steel_sabatons",
	"shadow_boots", "wooden_shield", "tower_shield", "dragon_shield"]
var _q_srv_provere := false
var _q_cmd := {}

func _telo_scene(vrsta: String, nivo := 1):
	var w = load(VRSTE[vrsta]).instantiate() if ResourceLoader.exists(VRSTE[vrsta]) else null
	if w == null: return [Node3D.new(), Node3D.new()] # vrsta ne postoji (bez implementacije)
	var e = w.get_node("CharacterBody3D") # van stabla: grupa "neprijatelj" još ne postoji
	e.nivo = nivo
	return [w, e]

# očekivani množilac (zadatak): +3 i više 120%, -2..+2 100%, -3..-4 50%, -5..-6 20%, -7 i niže 10%
func _ocekivan_mnozilac(d: int) -> float:
	return 1.2 if d >= 3 else 1.0 if d >= -2 else 0.5 if d >= -4 else 0.2 if d >= -6 else 0.1

func _xp_kriva(n: int) -> int: return 25 * n * n + 75 * n

func _server_quest() -> void:
	if dir == "" or _world() == null: return
	if not _q_srv_provere:
		_q_srv_provere = true
		_q_provere_scene()
		_q_provere_zone2()
		_q_provera_liste()
		_q_provere_xp()
		_q_provere_loota()
		_q_provere_loota_zone2()
		_q_provere_questova()
	for kanal in ["quest", "lovac"]: # QuestLik i LovacLik rade istovremeno, svaki svojim kanalom
		var cmd := FileAccess.get_file_as_string(dir + "/%s_cmd" % kanal)
		if cmd != "" and cmd != _q_cmd.get(kanal, ""):
			_q_cmd[kanal] = cmd
			_q_izvrsi(cmd.split(" "), kanal)

func _q_izvrsi(c: PackedStringArray, kanal: String) -> void:
	print("[S] quest komanda: ", " ".join(c))
	if c[1] == "spawn": # vrsta id nivo; u uglu, smiri ga _server
		_world().goblin_spawner.spawn({"vrsta": c[2], "id": int(c[3]), "pos": Vector3(23, 2, -24 + 3 * (int(c[3]) % 3)), "nivo": int(c[4])})
	elif c[1] == "ubij" or c[1] == "ubijv": # [vrsta] nivo napadač [lik sa štetom 0]
		var vrsta := "goblin"
		if c[1] == "ubijv":
			vrsta = c[2]
			c.remove_at(2)
		var id := (980 if kanal == "quest" else 960) + int(c[0]) % 10
		_world().goblin_spawner.spawn({"vrsta": vrsta, "id": id, "pos": Vector3(-13, 2, -15), "nivo": int(c[2])})
		await _cekaj(func(): return _nep("%s_%d" % [vrsta, id]) != null, 3.0)
		var e = _nep("%s_%d" % [vrsta, id])
		var nula = _ai_lik(c[4]) if c.size() > 4 else null
		if e and nula:
			e.primi_damage(0, nula.get_multiplayer_authority())
		var nap = _ai_lik(c[3])
		if e and nap:
			e.primi_damage(100000, nap.get_multiplayer_authority())
		await create_timer(1.5).timeout # loot, XP i kill credit idu backendu posle smrti
	_pisi("%s_server" % kanal, c[0])

# spawn tačke scene: broj i nivoi po vrsti, daleko od spawna igrača, aggro zone se ne preklapaju, NPC-ovi van aggro zona
func _q_provere_scene() -> void:
	var tacke := get_nodes_in_group("spawn_tacka").filter(func(t): return t.get_parent() == _world())
	var po_vrsti := {}
	var nivoi_ok := true
	var aggro := {}
	for v in VRSTE:
		var we = _telo_scene(v)
		aggro[v] = float(we[1].get("aggro_range")) if we[1].get("aggro_range") != null else 0.0
		we[0].free()
	for t in tacke:
		po_vrsti[t.vrsta] = po_vrsti.get(t.vrsta, []) + [int(t.get("nivo") if t.get("nivo") != null else 1)]
		aggro[t.vrsta] = aggro.get(t.vrsta, 0.0)
	for v in NIVOI_VRSTA:
		var l: Array = po_vrsti.get(v, [])
		nivoi_ok = nivoi_ok and l.size() == BROJ_TACAKA[v] and l.all(func(n): return n >= NIVOI_VRSTA[v][0] and n <= NIVOI_VRSTA[v][1])
	nivoi_ok = nivoi_ok and po_vrsti.get("troll", []).has(10)
	var preklapanja := []
	for i in tacke.size():
		var a = tacke[i]
		if Vector2(a.position.x, a.position.z).length() < 12.0:
			preklapanja.append("%s uz spawn igrača" % a.name)
		for j in range(i + 1, tacke.size()):
			var b = tacke[j]
			if _xz(a.position, b.position) < aggro[a.vrsta] + aggro[b.vrsta] + 0.5:
				preklapanja.append("%s-%s" % [a.name, b.name])
		for n in current_scene.get_children():
			if n.is_in_group("npc") and _xz(a.position, n.position) < aggro[a.vrsta] + 1.0:
				preklapanja.append("%s-%s" % [a.name, n.name])
	_provera("neprijatelji_nivoi_i_spawn_tacke", nivoi_ok and preklapanja.is_empty(),
		"tačke %s (očekivano broj %s, nivoi %s, trol 10), preklapanja %s" % [po_vrsti, BROJ_TACAKA, NIVOI_VRSTA, preklapanja])

# zona 2 (x > 25): 9 tačaka vuk 11-13, pauk 14-16, utvara 17/18/20, na podu (100x50: x -25..75), daleko od (0, 0);
# aggro bez preklapanja proverava neprijatelji_nivoi_i_spawn_tacke za sve tačke
func _q_provere_zone2() -> void:
	var z2 := {}
	var lose := []
	var pod = current_scene.get_node_or_null("Pod")
	var kraj_x: float = pod.position.x + pod.get_node("CollisionShape3D").scale.x / 2.0 if pod else 25.0 # BoxShape3D 1 m
	for t in get_nodes_in_group("spawn_tacka"):
		if t.get_parent() != _world() or t.position.x <= 25.0: continue
		z2[t.vrsta] = z2.get(t.vrsta, []) + [int(t.get("nivo") if t.get("nivo") != null else 1)]
		if t.position.x > kraj_x - 1.0 or absf(t.position.z) > 24.0: lose.append("%s van poda" % t.name)
		if Vector2(t.position.x, t.position.z).length() < 30.0: lose.append("%s blizu (0, 0)" % t.name)
	for v in z2: z2[v].sort()
	var hunter = current_scene.get_node_or_null("QuestNPC_Lovac")
	_provera("zona2_spawn_tacke", z2 == ZONA2 and lose.is_empty() and kraj_x >= 75.0 and hunter != null and hunter.position.x > 25.0,
		"zona 2 %s (očekivano %s), pod do x %.0f, Hunter %s, greške %s" % [z2, ZONA2, kraj_x, hunter.position if hunter else "nema", lose])

# jedna lista vrsta (spawn_point.VRSTE): spawner je koristi, enum u editoru se gradi iz nje, svaka vrsta ima scenu sa
# Enemy skriptom, ime (ime.to_lower() = ključ, kill questovi) i red u teksti.csv
func _q_provera_liste() -> void:
	var sp = load("res://Scripts/World/spawn_point.gd")
	var vrste: Dictionary = sp.get_script_constant_map().get("VRSTE", {})
	var ws: Dictionary = load("res://Scripts/Multiplayer/world_spawner.gd").get_script_constant_map()
	var t := Marker3D.new()
	t.set_script(sp)
	var hint := ""
	for pr in t.get_property_list():
		if pr.name == "vrsta": hint = pr.hint_string
	t.free()
	var csv := FileAccess.get_file_as_string("res://translations/teksti.csv")
	var lose := []
	for v in vrste:
		var w = vrste[v].instantiate()
		var e = w.get_node_or_null("CharacterBody3D")
		if e == null or not e.has_method("baci_loot") or str(e.ime).to_lower() != v: lose.append("%s: scena/ime" % v)
		elif not csv.contains("\n%s," % e.ime): lose.append("%s: nema u teksti.csv" % e.ime)
		w.free()
	_provera("vrste_neprijatelja_jedna_lista", vrste.size() == 6 and hint == ",".join(vrste.keys()) and ws.get("ENEMY_SCENES") == vrste
		and lose.is_empty(), "VRSTE %s, enum '%s', spawner ENEMY_SCENES ista lista=%s, greške %s" % [vrste.keys(), hint,
		ws.get("ENEMY_SCENES") == vrste, lose])

# T3/T4: samo od svoje vrste zone 2 i od instance nivoa >= min_nivo, šansa iz tabele (30000 bacanja); nijedna druga vrsta
func _q_provere_loota_zone2() -> void:
	var lose := []
	for v in VRSTE:
		var we = _telo_scene(v, 20)
		for l in we[1].get("loot_tabela") if we[1].get("loot_tabela") != null else []:
			if T34_LOOT.has(l["id"]) and (T34_LOOT[l["id"]][0] != v or int(l.get("min_nivo", 0)) != T34_LOOT[l["id"]][1]
					or not is_equal_approx(float(l["sansa"]), T34_LOOT[l["id"]][2])):
				lose.append("%s u %s: %s" % [l["id"], v, l])
		we[0].free()
	var nadjeno := {}
	for id in T34_LOOT:
		var x: Array = T34_LOOT[id]
		for n in [x[1] - 1, x[1]]:
			var we = _telo_scene(x[0], n)
			var e = we[1]
			if not e.has_method("baci_loot"):
				lose.append("%s: nema vrste" % x[0])
				we[0].free()
				break
			var br := 0
			for _i in 30000:
				if id in e.baci_loot(): br += 1
			var udeo := 100.0 * br / 30000.0
			if n < x[1] and br > 0: lose.append("%s od %s nivoa %d: %d" % [id, x[0], n, br])
			if n == x[1]:
				nadjeno[id] = snappedf(udeo, 0.01)
				if udeo < x[2] * 0.5 or udeo > x[2] * 1.5: lose.append("%s od %s %d: %.2f%%" % [id, x[0], n, udeo])
			we[0].free()
	_provera("zona2_loot_t3_t4_samo_svoja_zona", lose.is_empty() and nadjeno.size() == 3, "udeo %s (očekivano %s), greške %s" % [nadjeno,
		T34_LOOT, lose])

# svaki od 9 novih predmeta ima izvor: prodavnica (T1), loot vrste sa spawn tačke (do najvišeg nivoa) ili nagrada questa
func _q_provere_novih_predmeta(svi: Array, izvori: Dictionary) -> void:
	var api = root.get_node("ApiManager")
	var van: Array = root.get_node("Config").get_script().get_script_constant_map().get("VAN_PRODAVNICE", [])
	var izvor := {}
	for id in NOVI_PREDMETI:
		var it: Dictionary = await api.get_item(id)
		if izvori.has(id): izvor[id] = izvori[id]
		elif not it.has("error") and int(it.get("quest_item", 0)) == 0 and int(it.get("vrednost", 0)) > 0 and not van.has(id):
			izvor[id] = "prodavnica"
	var t34_u_prodavnici := ["steel_greaves", "steel_sabatons", "tower_shield", "dragonscale_leggings", "shadow_boots",
		"dragon_shield"].filter(func(x): return izvor.get(x, "") == "prodavnica")
	_provera("novi_predmeti_dostupni", izvor.size() == 9 and t34_u_prodavnici.is_empty(), "izvori %s, bez izvora %s, T3/T4 u prodavnici %s" % [
		izvor, NOVI_PREDMETI.filter(func(x): return not izvor.has(x)), t34_u_prodavnici])

# XP: svi pragovi razlike nivoa (-12..+6) i minimum 10% (nikad 0); osnovni XP ~15 ubistava po nivou
func _q_provere_xp() -> void:
	var E = load("res://Scripts/Enemy.gd")
	var ima: bool = E.get_script_method_list().any(func(m): return m.name == "xp_za_razliku")
	var lose := []
	if ima:
		for d in range(-12, 7):
			if not is_equal_approx(E.xp_mnozilac(d), _ocekivan_mnozilac(d)):
				lose.append("%d: %s" % [d, E.xp_mnozilac(d)])
		for n in range(1, 20):
			var k: float = float(_xp_kriva(n)) / E.xp_za_nivo(n)
			if k < 10.0 or k > 20.0:
				lose.append("nivo %d: %.1f ubistava" % [n, k])
		if E.xp_za_razliku(7, -11) != 1 or E.xp_za_razliku(1, -20) != 1:
			lose.append("minimum: %d, %d" % [E.xp_za_razliku(7, -11), E.xp_za_razliku(1, -20)])
	_provera("xp_po_razlici_nivoa_pragovi", ima and lose.is_empty(), "funkcije postoje=%s, odstupanja %s" % [ima, lose])

# loot tabele: najbolja oprema samo od trola nivoa 10 (šansa 0.4% po predmetu, i stvarno bacanje kockica), iron_gloves nigde
func _q_provere_loota() -> void:
	var lose := []
	var ima := false
	for v in ["goblin", "skeleton", "troll"]:
		for n in range(1, 11):
			var we = _telo_scene(v, n)
			var e = we[1]
			for l in e.loot_tabela:
				if l["id"] == "iron_gloves":
					lose.append("iron_gloves u %s" % v)
				if l["id"] in NAJBOLJA_OPREMA and n == 1 and (v != "troll" or int(l.get("min_nivo", 0)) != 10 \
						or not is_equal_approx(float(l["sansa"]), 0.4)):
					lose.append("%s u %s: %s" % [l["id"], v, l])
			if e.has_method("baci_loot") and n in [NIVOI_VRSTA[v][0], NIVOI_VRSTA[v][1], 9]:
				ima = true
				var br := {}
				var puta := 30000 if v == "troll" and n == 10 else 5000
				for _i in puta:
					for id in e.baci_loot():
						if id in NAJBOLJA_OPREMA: br[id] = br.get(id, 0) + 1
				if v == "troll" and n == 10:
					for id in NAJBOLJA_OPREMA:
						var udeo: float = 100.0 * br.get(id, 0) / puta
						if udeo < 0.2 or udeo > 0.6: lose.append("trol 10 %s %.2f%%" % [id, udeo])
				elif not br.is_empty():
					lose.append("%s nivo %d: %s" % [v, n, br])
			we[0].free()
	_provera("najbolja_oprema_samo_trol_nivoa_10", ima and lose.is_empty(), "baci_loot postoji=%s, odstupanja %s" % [ima, lose])
	var van: Array = root.get_node("Config").get_script().get_script_constant_map().get("VAN_PRODAVNICE", [])
	_provera("iron_gloves_van_loota_i_prodavnice", not lose.any(func(x): return str(x).begins_with("iron_gloves")) \
		and van.has("iron_gloves"), "Config.VAN_PRODAVNICE=%s" % [van])

# svaki quest dostupan od nekog NPC-a u svetu (lanac od quest_id), a ono što traži postoji u svetu: kill cilj je vrsta sa
# spawn tačke, fetch cilj pada od takve vrste (do najvišeg nivoa tačke) ili je nagrada drugog questa
func _q_provere_questova() -> void:
	var r = await root.get_node("ApiManager")._zahtev("/quests")
	var svi: Array = r.get("quests", []) if r is Dictionary else []
	var po_id := {}
	for q in svi: po_id[q.id] = q
	var dostupni := {}
	for n in current_scene.get_children():
		if n.is_in_group("npc") and int(n.interaction_type) == 2:
			var id: String = n.quest_id
			while id != "" and po_id.has(id) and not dostupni.has(id):
				dostupni[id] = n.npc_name
				id = str(po_id[id].sledeci_quest) if po_id[id].sledeci_quest != null else ""
	var vrste := {}
	for t in get_nodes_in_group("spawn_tacka"):
		if t.get_parent() == _world(): vrste[t.vrsta] = maxi(vrste.get(t.vrsta, 0), int(t.get("nivo") if t.get("nivo") != null else 1))
	var izvori := {}
	for v in vrste:
		var we = _telo_scene(v, vrste[v])
		for l in we[1].loot_tabela:
			if float(l["sansa"]) > 0 and vrste[v] >= int(l.get("min_nivo", 0)): izvori[l["id"]] = v
		we[0].free()
	for q in svi:
		if q.nagrada_item != null: izvori[q.nagrada_item] = "quest " + q.id
	_q_provere_novih_predmeta(svi, izvori)
	var lose := []
	for q in svi:
		if not dostupni.has(q.id): lose.append("%s bez NPC-a" % q.id)
		if q.tip == "kill" and not vrste.has(q.cilj): lose.append("%s: %s se ne spawn-uje" % [q.id, q.cilj])
		if q.tip == "fetch" and not izvori.has(q.cilj): lose.append("%s: %s nema izvor" % [q.id, q.cilj])
	_provera("questovi_dostupni_u_svetu", svi.size() == 12 and lose.is_empty(), "questova %d, NPC %s, nedostaje %s" % [svi.size(), dostupni, lose])

var _q_krenuo := false
var _q_kraj := false
var _q_br := 0

func _uloga_quest() -> bool:
	var p = _moj()
	if p == null or not p.get_node("ui/Control")._ucitano:
		return (_q_krenuo and p == null) or t > 2 * MAX_T
	if not _q_krenuo:
		_q_krenuo = true
		if _korak == 1: _quest_scenario(p)
		elif _korak == 3: _lovac_scenario(p)
		else: _posmatrac_scenario(p)
	return _q_kraj or t > 2 * MAX_T

func _q_cmd_posalji(cmd: String) -> void:
	var kanal := "lovac" if _korak == 3 else "quest"
	_q_br += 1
	_pisi("%s_cmd" % kanal, "%d %s" % [_q_br, cmd])
	await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/%s_server" % kanal) == str(_q_br), 8.0)

# PosmatracLik: ne napada; javlja svoj quest progres (klijent) dok QuestLik ne završi
func _posmatrac_scenario(p) -> void:
	_pisi("quest_posmatrac", "spreman")
	var qm = root.get_node("QuestManager")
	while not FileAccess.file_exists(dir + "/quest_gotov") and t < 2 * MAX_T:
		_pisi("quest_posmatrac", "progres %d" % qm.progres)
		await create_timer(0.2).timeout
	_q_kraj = true

func _dugme(tekst: String):
	for b in root.get_node("DialogueUI").find_children("*", "Button", true, false):
		if b.text == tr(tekst) and b.is_visible_in_tree(): return b
	return null

func _klikni(c) -> void:
	if c: _klik(c.get_global_rect().get_center())

func _q_dijalog() -> String: # "mod naslov" otvorenog dijaloga
	var d = root.get_node("DialogueUI")
	return "%s %s" % [d._mode, d._title_label.text] if d.is_open() and d._title_label else "-"

func _quest_stub(ime: String) -> Dictionary:
	return await root.get_node("ApiManager").get_player(ime)

# Server javlja ubistvo posle fiksnih 1.5 s, a loot/XP/kill credit stižu backendu (stub) posebnim zahtevima: čeka se da ih
# stub ima (rok je gornja granica), ne fiksno vreme. Vraća poslednje pročitano stanje lika.
const STUB_ROK := 10.0
func _cekaj_stub(ime: String, uslov: Callable, sek := STUB_ROK) -> Dictionary:
	var kraj := Time.get_ticks_msec() + int(sek * 1000)
	var st: Dictionary = await _quest_stub(ime)
	while not uslov.call(st) and Time.get_ticks_msec() < kraj:
		await create_timer(0.2).timeout
		st = await _quest_stub(ime)
	return st

func _komada(pl: Dictionary, id: String) -> int:
	var n := 0
	for e in pl.get("inventory", []):
		if e.id == id: n += int(e.kolicina)
	return n

func _quest_scenario(p) -> void:
	var api = root.get_node("ApiManager")
	var qm = root.get_node("QuestManager")
	var npc = current_scene.get_node_or_null("QuestNPC_Lanac")
	await _cekaj(func(): return npc != null and npc.player_in_range, 5.0)
	var u_dometu: bool = npc != null and npc.player_in_range
	# lanac: goblin_killer pre skupljac_oruzja server odbija; NPC nudi prvi nezavršen (skupljac_oruzja)
	var preskok: Dictionary = await p.prihvati_quest_na_serveru("goblin_killer")
	if npc: _klik(p.kamera.unproject_position(npc.global_position))
	await _cekaj(func(): return _dugme("Accept") != null, 5.0)
	var ponuda1 := _q_dijalog()
	_klikni(_dugme("Accept"))
	await _cekaj(func(): return str(qm.aktivni_quest.get("id", "")) == "skupljac_oruzja", 5.0)
	var aktivan1 := str(qm.aktivni_quest.get("id", ""))
	# predaja klikom: dva mača -> 100 zlata, 120 XP (nivo 2, 20/250); zatim ponuda sledećeg u lancu
	await create_timer(0.5).timeout
	if npc: _klik(p.kamera.unproject_position(npc.global_position))
	await _cekaj(func(): return _dugme("Turn in") != null, 5.0)
	var predaja := _q_dijalog()
	_klikni(_dugme("Turn in"))
	await _cekaj(func(): return _dugme("Accept") != null, 5.0)
	var ponuda2 := _q_dijalog()
	_klikni(_dugme("Accept"))
	await _cekaj(func(): return str(qm.aktivni_quest.get("id", "")) == "goblin_killer", 5.0)
	var st: Dictionary = await _quest_stub("QuestLik")
	var zav: Array = await api.get_completed_quests("QuestLik")
	_provera("quest_klikom_na_npc_prihvat_i_predaja", u_dometu and aktivan1 == "skupljac_oruzja" and predaja.begins_with("turnin")
		and zav == ["skupljac_oruzja"] and int(st.get("gold", 0)) == 200 and _komada(st, "iron_sword") == 0
		and [int(st.get("level", 0)), int(st.get("xp", 0))] == [2, 20] and p.get_node("ui/Control").level == 2,
		"u dometu=%s, prihvaćen '%s', predaja '%s', završeni %s, stub zlato %s mačeva %d nivo %s xp %s, HUD Lv.%s" % [u_dometu,
		aktivan1, predaja, zav, st.get("gold"), _komada(st, "iron_sword"), st.get("level"), st.get("xp"), p.get_node("ui/Control").level])
	_provera("quest_lanac_redosled", not preskok.get("ok", true) and str(preskok.get("poruka", "")) == "Prethodni quest nije zavrsen"
		and ponuda1 == "offer Weapon Collector" and ponuda2 == "offer Goblin Trouble" and str(qm.aktivni_quest.get("id", "")) == "goblin_killer",
		"goblin_killer pre reda: %s; prva ponuda '%s', posle predaje '%s', aktivan '%s'" % [preskok, ponuda1, ponuda2, qm.aktivni_quest.get("id", "")])

	# loot i kill/quest credit: QuestLik ubije goblina, PosmatracLik (pored, aktivan goblin_killer) samo udarac od 0
	await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/quest_posmatrac").begins_with("progres"), PARTNER_ROK)
	await _q_cmd_posalji("ubij 1 QuestLik PosmatracLik")
	await _cekaj(func(): return qm.progres == 1, 3.0)
	# QuestLik-ov loot, kill i progres su u stub-u; PosmatracLik-ov (da ga ima) šalje server u istom trenutku, pre QuestLik-ovog
	st = await _cekaj_stub("QuestLik", func(s): return _komada(s, "goblin_ear") >= 1 and not s.get("kill_dnevnik", []).is_empty() \
		and int(s.get("quest_progres", 0)) >= 1)
	var po: Dictionary = await _quest_stub("PosmatracLik")
	var po_klijent := FileAccess.get_file_as_string(dir + "/quest_posmatrac")
	_provera("loot_samo_napadacima", _komada(st, "goblin_ear") == 1 and po.get("inventory", []).is_empty(),
		"QuestLik goblin_ear %d, PosmatracLik inventar %s" % [_komada(st, "goblin_ear"), po.get("inventory")])
	_provera("bez_stete_bez_kill_i_quest_credita", st.get("kill_dnevnik", []) == ["goblin"] and int(st.get("quest_progres", -1)) == 1
		and qm.progres == 1 and po.get("kill_dnevnik", []).is_empty() and int(po.get("quest_progres", -1)) == 0 and po_klijent == "progres 0",
		"QuestLik kill %s progres %s/klijent %d; PosmatracLik kill %s progres %s, klijent '%s'" % [st.get("kill_dnevnik"),
		st.get("quest_progres"), qm.progres, po.get("kill_dnevnik"), po.get("quest_progres"), po_klijent])

	# XP prema razlici nivoa: PosmatracLik (nivo 12) ubija goblina nivoa 12 + d
	var ocekivano := []
	for d in [3, 8, 2, 0, -2, -3, -4, -5, -6, -7, -11]:
		await _q_cmd_posalji("ubij %d PosmatracLik" % (12 + d))
		ocekivano.append(maxi(1, roundi(roundi(maxf(1, roundi(_xp_kriva(12 + d) / 15.0))) * _ocekivan_mnozilac(d))))
		var n := ocekivano.size() # sledeće ubistvo tek kad je XP ovog u stub-u: redosled dnevnika = redosled ubistava
		po = await _cekaj_stub("PosmatracLik", func(s): return s.get("xp_dnevnik", []).size() >= n)
	var dobijeno: Array = po.get("xp_dnevnik", []).map(func(x): return int(x))
	_provera("xp_po_razlici_nivoa_po_napadacu", dobijeno == ocekivano and int(po.get("level", 0)) == 12,
		"XP po ubistvu %s, očekivano %s (d = +3, +8, +2, 0, -2, -3, -4, -5, -6, -7, -11), nivo %s" % [dobijeno, ocekivano, po.get("level")])

	# nivoi neprijatelja: server spawn-uje trola 10, kostura 5 i goblina 3; klijent vidi nivo i skalirane statistike
	await _q_cmd_posalji("spawn troll 990 10")
	await _q_cmd_posalji("spawn skeleton 991 5")
	await _q_cmd_posalji("spawn goblin 992 3")
	await _cekaj(func(): return _nep("troll_990") != null and _nep("skeleton_991") != null and _nep("goblin_992") != null, 5.0)
	await _q_cmd_posalji("spawn wolf 993 11")
	await _q_cmd_posalji("spawn spider 994 15")
	await _q_cmd_posalji("spawn wraith 995 20")
	await _cekaj(func(): return _nep("wolf_993") != null and _nep("spider_994") != null and _nep("wraith_995") != null, 5.0)
	var opis := []
	var stat_ok := true
	for x in [["troll", 990, 10], ["skeleton", 991, 5], ["goblin", 992, 3]]:
		var e = _nep("%s_%d" % [x[0], x[1]])
		var we = _telo_scene(x[0])
		var b = we[1]
		var hp := roundi(b.max_hp * (1.0 + 0.15 * (x[2] - 1)))
		var steta := roundi(b.napad_damage * (1.0 + 0.10 * (x[2] - 1)))
		var xp := roundi(_xp_kriva(x[2]) / 15.0)
		we[0].free()
		var ok: bool = e != null and int(e.nivo) == x[2] and int(e.max_hp) == hp and int(e.hp) == hp and int(e.napad_damage) == steta \
			and int(e.xp_nagrada) == xp
		stat_ok = stat_ok and ok
		opis.append("%s: %s" % [x[0], "nema" if e == null else "nivo %s hp %s/%s šteta %s xp %s (očekivano %d/%d/%d/%d)" % [e.nivo,
			e.hp, e.max_hp, e.napad_damage, e.xp_nagrada, x[2], hp, steta, xp]])
	_provera("neprijatelji_statistike_skaliraju_sa_nivoom", stat_ok, "; ".join(opis))
	# nove vrste: vuk 11, pauk 15, utvara 20 (statistike iz izveštaja za nivo 1, aggro 8/6/8; XP iz krive)
	opis = []
	stat_ok = true
	for x in [["wolf", 993, 11, 80, 8, 8.0], ["spider", 994, 15, 70, 7, 6.0], ["wraith", 995, 20, 90, 14, 8.0]]:
		var e = _nep("%s_%d" % [x[0], x[1]])
		var hp := roundi(x[3] * (1.0 + 0.15 * (x[2] - 1)))
		var steta := roundi(x[4] * (1.0 + 0.10 * (x[2] - 1)))
		var xp := roundi(_xp_kriva(x[2]) / 15.0)
		var ok: bool = e != null and int(e.nivo) == x[2] and int(e.max_hp) == hp and int(e.hp) == hp and int(e.napad_damage) == steta \
			and int(e.xp_nagrada) == xp and is_equal_approx(float(e.aggro_range), x[5])
		stat_ok = stat_ok and ok
		opis.append("%s: %s" % [x[0], "nema" if e == null else "nivo %s hp %s šteta %s xp %s aggro %s (očekivano %d/%d/%d/%d/%.0f)" % [e.nivo,
			e.max_hp, e.napad_damage, e.xp_nagrada, e.aggro_range, x[2], hp, steta, xp, x[5]]])
	_provera("nove_vrste_nivoi_statistike_xp", stat_ok, "; ".join(opis))

	# prodavnica: iron_gloves i najbolja oprema se ne nude, a server odbija kupovinu
	var mu = root.get_node("MerchantUI")
	mu.open("Merchant")
	await _cekaj(func(): return mu._list != null and mu._list.get_child_count() > 3, 5.0)
	var ponuda := []
	for row in mu._list.get_children():
		var l = row.get_child(0) if row.get_child_count() > 0 else null
		if l is Label: ponuda.append(l.text.trim_prefix("? "))
	var zabranjeno := ["Iron Gloves", "Dragon Scale Armor", "Dragon Staff", "Golden Helmet", "Golden Sword", "Shadow Cloak", "Shadow Dagger",
		"Steel Greaves", "Steel Sabatons", "Tower Shield", "Dragonscale Leggings", "Shadow Boots", "Dragon Shield"]
	var nudi := zabranjeno.filter(func(x): return ponuda.has(x))
	var kup: Dictionary = await p.kupi_na_serveru("iron_gloves")
	var kup_t3: Dictionary = await p.kupi_na_serveru("tower_shield")
	mu._close()
	st = await _quest_stub("QuestLik")
	_provera("prodavnica_bez_iron_gloves_i_najbolje_opreme", ponuda.has("Iron Sword") and nudi.is_empty() and not kup.get("ok", true)
		and _komada(st, "iron_gloves") == 0, "nudi zabranjeno %s (ponuda %d, Iron Sword=%s), kupovina iron_gloves %s" % [nudi, ponuda.size(),
		ponuda.has("Iron Sword"), kup])
	# oružje: arcane_staff (napad 45) van prodavnice, ostalo oružje koje nije quest predmet i ima cenu ostaje
	var oruzje := ["Apprentice Staff", "Battle Axe", "Crossbow", "Hunters Bow", "Iron Dagger", "Iron Sword", "Oak Bow",
		"Rusty Sword", "Spear", "Steel Longsword", "War Hammer"]
	var nedostaje := oruzje.filter(func(x): return not ponuda.has(x))
	_provera("prodavnica_bez_arcane_staff_ostalo_oruzje_da", not ponuda.has("Arcane Staff") and nedostaje.is_empty(),
		"Arcane Staff u ponudi=%s, oružje koje nedostaje %s (očekivano svih %d)" % [ponuda.has("Arcane Staff"), nedostaje, oruzje.size()])
	_provera("prodavnica_t1_da_t3_t4_ne", ponuda.has("Cloth Trousers") and ponuda.has("Wooden Shield") and ponuda.has("Leather Pants")
		and nudi.is_empty() and not kup_t3.get("ok", true) and _komada(st, "tower_shield") == 0,
		"T1 u ponudi: Cloth Trousers=%s Wooden Shield=%s Leather Pants=%s; T3/T4 u ponudi %s; kupovina tower_shield %s" % [
		ponuda.has("Cloth Trousers"), ponuda.has("Wooden Shield"), ponuda.has("Leather Pants"), nudi, kup_t3])
	_pisi("quest_gotov", "1")
	_q_kraj = true

# LovacLik (nivo 1, 6 vučjih krzna, ispred Hunter-a u zoni 2): limit XP-a po ubistvu, pa Hunter klikom (lanac zone 2)
func _lovac_scenario(p) -> void:
	var api = root.get_node("ApiManager")
	var qm = root.get_node("QuestManager")
	# limit: vuk 11 (308 XP uz +10 razlike) -> najviše 25% od 100 = 25; fer borba (goblin 1, 7 XP) nije ograničena
	await _q_cmd_posalji("ubijv wolf 11 LovacLik")
	await _cekaj_stub("LovacLik", func(s): return s.get("xp_dnevnik", []).size() >= 1) # redosled dnevnika = redosled ubistava
	await _q_cmd_posalji("ubij 1 LovacLik")
	var st: Dictionary = await _cekaj_stub("LovacLik", func(s): return s.get("xp_dnevnik", []).size() >= 2)
	var xp_ub: Array = st.get("xp_dnevnik", []).map(func(x): return int(x))
	_provera("xp_limit_po_ubistvu", xp_ub == [25, 7], "nivo 1: vuk 11 -> %s, goblin 1 -> %s (očekivano 25 = 25%% od 100, pa 7)" % [
		xp_ub[0] if xp_ub.size() > 0 else "-", xp_ub[1] if xp_ub.size() > 1 else "-"])
	var npc = current_scene.get_node_or_null("QuestNPC_Lovac")
	await _cekaj(func(): return npc != null and npc.player_in_range, 5.0)
	var u_dometu: bool = npc != null and npc.player_in_range
	var preskok: Dictionary = await p.prihvati_quest_na_serveru("svila_za_krojaca")
	if npc: _klik(p.kamera.unproject_position(npc.global_position))
	await _cekaj(func(): return _dugme("Accept") != null, 5.0)
	var ponuda1 := _q_dijalog()
	_klikni(_dugme("Accept"))
	await _cekaj(func(): return str(qm.aktivni_quest.get("id", "")) == "vucja_krzna", 5.0)
	var aktivan1 := str(qm.aktivni_quest.get("id", ""))
	await create_timer(0.5).timeout
	if npc: _klik(p.kamera.unproject_position(npc.global_position))
	await _cekaj(func(): return _dugme("Turn in") != null, 5.0)
	var predaja := _q_dijalog()
	_klikni(_dugme("Turn in"))
	await _cekaj(func(): return _dugme("Accept") != null, 5.0)
	var ponuda2 := _q_dijalog()
	st = await _quest_stub("LovacLik")
	var zav: Array = await api.get_completed_quests("LovacLik")
	# 32 XP od ubistava + 1200 = 1232: nivoi 1-3 traže 100 + 250 + 450 = 800, ostaje 432/700 na nivou 4
	_provera("quest_lovac_klikom_prihvat_i_predaja", u_dometu and aktivan1 == "vucja_krzna" and predaja.begins_with("turnin")
		and zav == ["vucja_krzna"] and int(st.get("gold", 0)) == 250 and _komada(st, "wolf_pelt") == 1 # 6 + 1 od ubijenog vuka (100%) - 6
		and [int(st.get("level", 0)), int(st.get("xp", 0))] == [4, 432],
		"u dometu=%s, prihvaćen '%s', predaja '%s', završeni %s, stub zlato %s krzna %d nivo %s xp %s" % [u_dometu, aktivan1, predaja,
		zav, st.get("gold"), _komada(st, "wolf_pelt"), st.get("level"), st.get("xp")])
	_provera("quest_lovac_lanac_redosled", not preskok.get("ok", true) and str(preskok.get("poruka", "")) == "Prethodni quest nije zavrsen"
		and ponuda1 == "offer Wolf Pelts" and ponuda2 == "offer Silk for the Tailor",
		"svila_za_krojaca pre reda: %s; prva ponuda '%s', posle predaje '%s'" % [preskok, ponuda1, ponuda2])
	_klikni(_dugme("Decline"))
	_q_kraj = true

# ---------------------------------------------------------------- BUFFOVI (uloga buff: korak 1 BuffLik, korak 2 Buff2Lik)
# Server: komande BuffLik-a iz dir/buff_cmd ("br steta N" | "br ubij" | "br ubijv VRSTA NIVO" | "br ubijn SEME"), stanje
# BuffLik-a po serveru u dir/buff_server; jednom, bez klijenta: bacanje loot-a sa buff-om (30000) i retka oprema.
var _b_srv_provere := false
var _b_cmd := ""
var _b_upisano := ""
var _b_krenuo := false
var _b_kraj := false
var _b_br := 0
const B_TABELA_N := 30 # test goblin: 30 x iron_ore 40%, pa se raspodela po napadaču jasno vidi (bez buff-a ~12, luck ~18)

func _server_buff() -> void:
	if dir == "" or _world() == null: return
	if not _b_srv_provere:
		_b_srv_provere = true
		_b_provere_loota()
	var p = _ai_lik("BuffLik")
	if p == null: return
	var cmd := FileAccess.get_file_as_string(dir + "/buff_cmd")
	if cmd != "" and cmd != _b_cmd:
		_b_cmd = cmd
		_b_izvrsi(p, cmd.split(" "))
	var preostalo := {}
	var bf = p.get("_buffovi")
	if bf is Dictionary:
		for tip in bf: preostalo[tip] = int(bf[tip][1]) - Time.get_ticks_msec()
	var st := JSON.stringify({"attack": p.izracunaj_damage(), "armor": int(p.get("armor")) + (p.buff("oklop") if p.has_method("buff") else 0),
		"buffovi": preostalo, "hp": p.hp, "mrtav": p.mrtav, "raspored": p.get("_raspored_brzine")})
	if st != _b_upisano:
		_b_upisano = st
		_pisi("buff_server", st)

func _b_izvrsi(p, c: PackedStringArray) -> void:
	print("[S] buff komanda: ", " ".join(c))
	var odgovor := c[0]
	if c[1] == "steta":
		var pre: int = p.hp
		p.server_primi_damage(int(c[2]))
		odgovor = "%s %d %d" % [c[0], pre, p.hp]
	elif c[1] == "ubij": # odgovor odmah (klijent proverava stanje mrtvog), posle respawn-a nazad van putanje movera
		p.server_primi_damage(1000000)
		_pisi("buff_odgovor", odgovor)
		await _cekaj(func(): return not p.mrtav, 8.0)
		p.server_postavi_poziciju(Vector3(-22, 1.16, -2), true)
		return
	elif c[1] == "ubijv" or c[1] == "ubijn": # ubijv: samo BuffLik napada; ubijn: Buff2Lik udari prvi (1), BuffLik ubije
		var vrsta := c[2] if c[1] == "ubijv" else "goblin"
		var id := 940 + int(c[0]) % 10
		_world().goblin_spawner.spawn({"vrsta": vrsta, "id": id, "pos": Vector3(-27, 2, 0), "nivo": int(c[3]) if c[1] == "ubijv" else 1})
		await _cekaj(func(): return _nep("%s_%d" % [vrsta, id]) != null, 3.0)
		var e = _nep("%s_%d" % [vrsta, id])
		var p2 = _ai_lik("Buff2Lik")
		if e and c[1] == "ubijn" and p2:
			var tabela := []
			for _i in B_TABELA_N: tabela.append({"id": "iron_ore", "sansa": 40})
			e.loot_tabela = tabela
			e.primi_damage(1, p2.get_multiplayer_authority())
			# očekivano po napadaču: isto seme, isti redosled (Buff2Lik prvi, bez buff-a; BuffLik sa svojim luck-om)
			# seme od zadatog naviše dok bez buff-a i sa luck-om ne daju različit broj (inače se hipoteze ne razlikuju)
			var we = _telo_scene("goblin", 1)
			we[1].loot_tabela = tabela
			var seme := int(c[2])
			var a: Array = []
			var b: Array = []
			for _k in 50:
				seed(seme)
				a = we[1].baci_loot(0)
				b = we[1].baci_loot(p.buff("loot"))
				if a.size() != b.size(): break
				seme += 1
			we[0].free()
			seed(seme)
			odgovor = "%s %d %d" % [c[0], a.size(), b.size()]
		if e: e.primi_damage(1000000, p.get_multiplayer_authority())
		await create_timer(2.0).timeout # loot i XP idu backendu posle smrti
	_pisi("buff_odgovor", odgovor)

# luck: bez buff-a isto bacanje (isto seme), sa +50% šansa x1.5 (najviše 100%); retka oprema i dalje samo trol nivoa 10
func _b_provere_loota() -> void:
	var we = _telo_scene("goblin", 1)
	var e = we[1]
	var metod := (e.get_script().get_script_method_list() as Array).filter(func(m): return m.name == "baci_loot")
	if metod.is_empty() or metod[0].args.size() < 1: # bez implementacije: nema parametra za buff
		we[0].free()
		_provera("luck_bacanje_isto_bez_buffa_x1_5_sa_buffom", false, "Enemy.baci_loot nema parametar za buff loot-a")
		_provera("luck_retka_oprema_samo_trol_10", false, "Enemy.baci_loot nema parametar za buff loot-a")
		return
	var lose := []
	var puta := 30000
	seed(7)
	var bez: Array = e.baci_loot()
	seed(7)
	var nula: Array = e.baci_loot(0) if e.has_method("baci_loot") else []
	if bez != nula: lose.append("seme 7: baci_loot() %s, baci_loot(0) %s" % [bez, nula])
	var br := [{}, {}]
	for i in 2:
		for _k in puta:
			for id in e.baci_loot(0 if i == 0 else 50): br[i][id] = br[i].get(id, 0) + 1
	for l in e.loot_tabela:
		var s0: float = 100.0 * br[0].get(l["id"], 0) / puta
		var s1: float = 100.0 * br[1].get(l["id"], 0) / puta
		var ocek := minf(float(l["sansa"]) * 1.5, 100.0)
		if absf(s0 - float(l["sansa"])) > 1.5 or absf(s1 - ocek) > 1.5:
			lose.append("%s: %.1f%% / %.1f%% (očekivano %.0f / %.0f)" % [l["id"], s0, s1, float(l["sansa"]), ocek])
	we[0].free()
	_provera("luck_bacanje_isto_bez_buffa_x1_5_sa_buffom", lose.is_empty(), "goblin 1, %d bacanja: %s" % [puta, lose if not lose.is_empty() else "sve stavke u ±1.5 poena"])
	var retka := []
	for n in [9, 10]:
		var wt = _telo_scene("troll", n)
		var br_r := {}
		for _k in puta:
			for id in wt[1].baci_loot(50):
				if id in NAJBOLJA_OPREMA: br_r[id] = br_r.get(id, 0) + 1
		wt[0].free()
		for id in NAJBOLJA_OPREMA:
			var udeo: float = 100.0 * br_r.get(id, 0) / puta
			if (n == 9 and udeo > 0.0) or (n == 10 and (udeo < 0.4 or udeo > 0.8)): retka.append("trol %d %s %.2f%%" % [n, id, udeo])
	_provera("luck_retka_oprema_samo_trol_10", retka.is_empty(), "luck +50%%, trol 9: 0, trol 10: 0.4-0.8%% (0.6 očekivano); odstupanja %s" % [retka])

func _uloga_buff() -> bool:
	var p = _moj()
	if p == null or not p.get_node("ui/Control")._ucitano:
		return (_b_krenuo and p == null) or t > 2 * MAX_T
	if not _b_krenuo:
		_b_krenuo = true
		if _korak == 1: _buff_scenario(p)
		else: _buff2_scenario(p)
	return _b_kraj or t > 2 * MAX_T

func _b_srv() -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir + "/buff_server"))
	return d if d is Dictionary else {}

func _b_cmd_posalji(cmd: String) -> PackedStringArray:
	_b_br += 1
	_pisi("buff_cmd", "%d %s" % [_b_br, cmd])
	var br := str(_b_br)
	await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/buff_odgovor").split(" ")[0] == br, 8.0)
	return FileAccess.get_file_as_string(dir + "/buff_odgovor").split(" ")

func _b_rasp_int(r) -> Array: # raspored brzine iz JSON-a (float) ili RPC-a (int) kao int
	return (r as Array).map(func(x): return (x as Array).map(func(y): return int(y))) if r is Array else []

func _b_stub(ime: String) -> Dictionary:
	return await root.get_node("ApiManager").get_player(ime)

func _b_xp_ore(ime: String, uslov := Callable()) -> Array: # uslov(xp, iron_ore): čeka ga u stub-u (_cekaj_stub)
	var pl: Dictionary
	if uslov.is_valid(): pl = await _cekaj_stub(ime, func(s): return uslov.call(int(s.get("xp", -1)), _komada(s, "iron_ore")))
	else: pl = await _b_stub(ime)
	return [int(pl.get("xp", -1)), _komada(pl, "iron_ore")]

func _b_klijent(p) -> Dictionary:
	var b = p.get("buffovi")
	return b if b is Dictionary else {"(nema buffovi)": 0}

func _b_hud(hud) -> String:
	var l = hud.get("buff_label")
	return l.text if l != null else "(nema BuffLabel)"

# BuffLik: istek, napad x1.2, oklop +30, različiti istovremeno, osvežavanje, klijent ne postavlja buff, wisdom limit,
# buff po igraču (wisdom i luck), smrt briše buffove, prodavnica, HUD i tooltip
func _buff_scenario(p) -> void:
	var inv = p.get_node("ui/InventoryUI")
	var hud = p.get_node("ui/Control")
	await _cekaj(func(): return int(_b_srv().get("attack", -1)) == 35 and int(_b_srv().get("armor", -1)) == 68, 5.0)
	var pocetak := _b_srv()
	var s1 := await _b_cmd_posalji("steta 25") # bez buff-a: 25 uz 68 armora -> 14
	var bez_buffa := int(s1[1]) - int(s1[2]) if s1.size() > 2 else -1

	# tooltip pre upotrebe
	var i_str := _inv_index(inv, "elixir_of_strength")
	if i_str >= 0: inv._on_slot_hover(i_str)
	var tooltip: String = inv.tooltip_label.text

	# istek: test eliksir napad +20% 2 s (samo u stub-u)
	await inv._koristi_item("test_kratki_eliksir")
	var sa_kratkim := await _cekaj(func(): return int(_b_srv().get("attack", -1)) == 42, 3.0)
	await _cekaj(func(): return _b_hud(hud) != "", 1.0) # TopBar osveži labelu u svom _process (posle drajvera)
	var hud_kratki := _b_hud(hud)
	var istekao := await _cekaj(func(): return int(_b_srv().get("attack", -1)) == 35 and _b_srv().get("buffovi", {"x": 1}).is_empty() \
		and _b_klijent(p).is_empty() and int(p.get("stat_attack")) == 35, 5.0)
	await _cekaj(func(): return _b_hud(hud) == "", 1.0)
	_provera("buff_istek_posle_trajanja", sa_kratkim and istekao and hud_kratki.begins_with("Attack +20%  0:0") and _b_hud(hud) == "",
		"2 s buff: server attack 42=%s, posle isteka server %s, klijent buffovi %s, stat_attack %s, HUD tokom '%s' posle '%s'" % [
		sa_kratkim, _b_srv(), _b_klijent(p), p.get("stat_attack"), hud_kratki, _b_hud(hud)])

	# napad x1.2: (10 + iron_sword 25) * 1.2 = 42
	await inv._koristi_item("elixir_of_strength")
	var t_str := Time.get_ticks_msec()
	var poruka: String = hud._poruka_label.text if hud._poruka_label else ""
	var napad_ok := await _cekaj(func(): return int(_b_srv().get("attack", -1)) == 42 and int(p.get("stat_attack")) == 42, 3.0)
	await _cekaj(func(): return _b_hud(hud) != "", 1.0)
	var hud_napad := _b_hud(hud)
	_provera("buff_napad_x1_2", napad_ok and int(pocetak.get("attack", -1)) == 35,
		"attack pre %s, posle eliksira server %s klijent %s (očekivano 35 -> 42)" % [pocetak.get("attack"), _b_srv().get("attack"), p.get("stat_attack")])

	# oklop +30: 25 štete uz 68 armora 14, uz 98 armora 12; napad i oklop istovremeno
	await inv._koristi_item("elixir_of_defense")
	var oklop_ok := await _cekaj(func(): return int(_b_srv().get("armor", -1)) == 98 and int(p.get("stat_armor")) == 98, 3.0)
	var s2 := await _b_cmd_posalji("steta 25")
	var sa_buffom := int(s2[1]) - int(s2[2]) if s2.size() > 2 else -1
	_provera("buff_oklop_plus_30", oklop_ok and bez_buffa == 14 and sa_buffom == 12,
		"armor server %s klijent %s; 25 štete: bez buff-a -%d (14), sa buff-om -%d (12)" % [_b_srv().get("armor"), p.get("stat_armor"), bez_buffa, sa_buffom])
	var oba_k := _b_klijent(p)
	await _cekaj(func(): return _b_hud(hud).split("\n").size() == 2, 1.0)
	var hud_oba := _b_hud(hud)
	_provera("buff_razliciti_istovremeno", int(_b_srv().get("attack", -1)) == 42 and int(_b_srv().get("armor", -1)) == 98
		and _b_srv().get("buffovi", {}).has("napad") and _b_srv().get("buffovi", {}).has("oklop") and oba_k.has("napad") and oba_k.has("oklop")
		and hud_oba.split("\n").size() == 2,
		"server %s, klijent %s, HUD '%s'" % [_b_srv(), oba_k, hud_oba.replace("\n", " | ")])

	# osvežavanje: isti eliksir posle cooldown-a (5 s) -> trajanje ponovo puno, napad i dalje 42 (ne 49)
	await create_timer(maxf(0.0, 5.3 - (Time.get_ticks_msec() - t_str) / 1000.0)).timeout
	var pre_osv := int(_b_srv().get("buffovi", {}).get("napad", -1))
	await inv._koristi_item("elixir_of_strength")
	await _cekaj(func(): return int(_b_srv().get("buffovi", {}).get("napad", -1)) > pre_osv + 3000, 3.0)
	var posle_osv := int(_b_srv().get("buffovi", {}).get("napad", -1))
	await create_timer(0.5).timeout
	_provera("buff_osvezavanje_bez_sabiranja", posle_osv > pre_osv + 3000 and posle_osv > 55000 and int(_b_srv().get("attack", -1)) == 42
		and int(p.get("stat_attack")) == 42,
		"preostalo napad pre %d ms, posle %d ms; attack server %s klijent %s (42, ne 49)" % [pre_osv, posle_osv, _b_srv().get("attack"), p.get("stat_attack")])

	# klijent ne može da postavi buff: jedini buff RPC je primi_buffove, a njega server prihvata samo od sebe
	var rpc_buff := []
	var cfg: Dictionary = p.get_script().get_rpc_config() # RPC-ovi su deklarisani u skripti (@rpc), ne na čvoru
	rpc_buff = cfg.keys().map(func(m): return str(m)).filter(func(m): return "buff" in m)
	if p.has_method("primi_buffove"):
		p.primi_buffove.rpc_id(1, {"napad": [500, 600000], "oklop": [1000, 600000], "xp": [1000, 600000]})
	await create_timer(1.0).timeout
	_provera("klijent_ne_postavlja_buff", rpc_buff == ["primi_buffove"] and int(_b_srv().get("attack", -1)) == 42
		and int(_b_srv().get("armor", -1)) == 98 and not _b_srv().get("buffovi", {}).has("xp"),
		"buff RPC-ovi %s; posle lažnog primi_buffove ka serveru: %s" % [rpc_buff, _b_srv()])

	# wisdom: nivo 1 ubija vuka 11 -> i dalje 25 XP (limit 25% nivoa); buff po igraču: Buff2Lik udari prvi, BuffLik ubije
	await inv._koristi_item("elixir_of_wisdom")
	await inv._koristi_item("elixir_of_luck")
	await _cekaj(func(): return _b_srv().get("buffovi", {}).has("xp") and _b_srv().get("buffovi", {}).has("loot"), 3.0)
	var x0 := await _b_xp_ore("BuffLik")
	var wisdom := int(_b_srv().get("buffovi", {}).get("xp", 0)) > 0 # buff aktivan na serveru u trenutku ubistva
	await _b_cmd_posalji("ubijv wolf 11")
	var x1 := await _b_xp_ore("BuffLik", func(xp, _o): return xp != x0[0])
	_provera("wisdom_ne_prelazi_limit", wisdom and x1[0] - x0[0] == 25,
		"BuffLik nivo 1, wisdom aktivan na serveru=%s, vuk 11: +%d XP (limit 25; bez limita 308 * 1.25)" % [wisdom, x1[0] - x0[0]])
	await _cekaj(func(): return FileAccess.file_exists(dir + "/buff2_spreman"), PARTNER_ROK)
	var b0 := await _b_xp_ore("Buff2Lik")
	var r := await _b_cmd_posalji("ubijn 4242")
	var oc_a := int(r[1]) if r.size() > 2 else -1 # Buff2Lik (bez buff-a)
	var oc_b := int(r[2]) if r.size() > 2 else -1 # BuffLik (luck +50%)
	# XP i loot stižu u stub posle smrti goblina: čeka se XP i očekivani broj iron_ore (pogrešan broj padne posle roka)
	var x2 := await _b_xp_ore("BuffLik", func(xp, o): return xp != x1[0] and o == x1[1] + oc_b)
	var b1 := await _b_xp_ore("Buff2Lik", func(xp, o): return xp != b0[0] and o == b0[1] + oc_a)
	_provera("buff_po_igracu_wisdom_i_luck", x2[0] - x1[0] == 9 and b1[0] - b0[0] == 7 and x2[1] - x1[1] == oc_b and b1[1] - b0[1] == oc_a and oc_a != oc_b,
		"goblin 1: XP BuffLik +%d (9 = 7 * 1.25), Buff2Lik +%d (7); iron_ore BuffLik +%d (očekivano %d sa luck), Buff2Lik +%d (očekivano %d bez)" % [
		x2[0] - x1[0], b1[0] - b0[0], x2[1] - x1[1], oc_b, b1[1] - b0[1], oc_a])

	# smrt briše buffove (server i klijent), pa respawn
	await _b_cmd_posalji("ubij")
	var smrt_ok := await _cekaj(func(): return bool(p.get("mrtav")) and _b_klijent(p).is_empty() and _b_srv().get("buffovi", {"x": 1}).is_empty(), 3.0)
	await _cekaj(func(): return _b_hud(hud) == "", 1.0)
	var hud_smrt := _b_hud(hud)
	_provera("smrt_brise_buffove", smrt_ok and hud_smrt == "", "mrtav %s, server %s, klijent %s, HUD '%s'" % [p.get("mrtav"), _b_srv(), _b_klijent(p), hud_smrt])
	await _cekaj(func(): return not bool(p.get("mrtav")), 8.0)

	# prodavnica nudi svih pet (luck više nije quest predmet), kupovina luck-a prolazi
	var mu = root.get_node("MerchantUI")
	mu.open("Merchant")
	await _cekaj(func(): return mu._list != null and mu._list.get_child_count() > 3, 5.0)
	var ponuda := []
	for row in mu._list.get_children():
		var l = row.get_child(0) if row.get_child_count() > 0 else null
		if l is Label: ponuda.append(l.text.trim_prefix("? "))
	var cetiri := ["Elixir of Strength", "Elixir of Defense", "Elixir of Wisdom", "Elixir of Luck"]
	var fali := cetiri.filter(func(x): return not ponuda.has(x))
	var kup: Dictionary = await p.kupi_na_serveru("elixir_of_luck")
	var speed_pre := _komada(await _b_stub("BuffLik"), "speed_potion")
	var kup_speed: Dictionary = await p.kupi_na_serveru("speed_potion")
	mu._close()
	var st := await _b_stub("BuffLik")
	_provera("prodavnica_nudi_cetiri_buff_predmeta", fali.is_empty() and kup.get("ok", false) and _komada(st, "elixir_of_luck") == 1,
		"nedostaje u ponudi %s, kupovina elixir_of_luck %s, u bazi %d" % [fali, kup, _komada(st, "elixir_of_luck")])
	_provera("prodavnica_nudi_speed_potion", ponuda.has("Speed Potion") and kup_speed.get("ok", false)
		and _komada(st, "speed_potion") == speed_pre + 1,
		"Speed Potion u ponudi=%s, kupovina %s, u bazi %d -> %d" % [ponuda.has("Speed Potion"), kup_speed, speed_pre, _komada(st, "speed_potion")])

	# speed_potion: upotreba troši komad; server zakaže +30% (6,5 m/s) na 20 s = 1200 unosa i javi raspored vlasniku;
	# druga upotreba pre cooldown-a (5 s) se odbija i ne troši (BuffLik ima 2: stub 1 + kupljen)
	var sp_baza := _komada(await _b_stub("BuffLik"), "speed_potion")
	var sp_odg: Dictionary = await p.koristi_item_na_serveru("speed_potion")
	await _cekaj(func(): return not _b_rasp_int(_b_srv().get("raspored")).is_empty() and not _b_rasp_int(p.get("_raspored_brzine")).is_empty(), 3.0)
	var rasp: Array = _b_rasp_int(_b_srv().get("raspored"))
	var sp_posle := _komada(await _b_stub("BuffLik"), "speed_potion")
	var sp_cd: Dictionary = await p.koristi_item_na_serveru("speed_potion")
	var sp_posle_cd := _komada(await _b_stub("BuffLik"), "speed_potion")
	var r0: Array = rasp[0] if rasp.size() == 1 else [0, 0, 0]
	var v_buff: float = 5.0 * (100 + int(r0[2])) / 100.0 # BRZINA
	_provera("speed_potion_upotreba_trosi_6_5_na_20s", sp_odg.get("ok", false) and sp_baza - sp_posle == 1 and rasp.size() == 1
		and is_equal_approx(v_buff, 6.5) and int(r0[1]) - int(r0[0]) == 1200 and _b_rasp_int(p.get("_raspored_brzine")) == _b_rasp_int(rasp)
		and not sp_cd.get("ok", true) and str(sp_cd.get("poruka", "")) == "Not ready yet" and sp_posle_cd == sp_posle,
		"u bazi %d -> %d -> %d, odgovor %s, raspored server %s klijent %s (%.2f m/s, %d unosa), druga upotreba %s" % [sp_baza, sp_posle,
		sp_posle_cd, sp_odg, rasp, p.get("_raspored_brzine"), v_buff, int(r0[1]) - int(r0[0]), sp_cd])

	_provera("buff_hud_i_tooltip", "Click: Attack +20% for 60 s  |  cooldown 5 s" in tooltip and poruka == "Attack +20% for 60 s"
		and hud_napad.begins_with("Attack +20%  ") and (hud_napad.ends_with("1:00") or hud_napad.ends_with("0:59")),
		"tooltip '%s', poruka '%s', HUD '%s'" % [tooltip.replace("\n", " | "), poruka, hud_napad])
	_pisi("buff_gotov", "1")
	_b_kraj = true

# Buff2Lik: samo napadač bez buff-a; ostaje prijavljen dok BuffLik ne završi
func _buff2_scenario(_p) -> void:
	_pisi("buff2_spreman", "1")
	while not FileAccess.file_exists(dir + "/buff_gotov") and t < 2 * MAX_T:
		await create_timer(0.2).timeout
	_b_kraj = true

# ---------------------------------------------------------------- BRZINA (uloga brzina: korak 1 BrzinaLik, korak 2 ponovna prijava)
# Buff brzine je zakazan po seq-u unosa (Player_Movement._raspored_brzine). BrzinaLik hoda (x 48..62, z -20) i pije
# test_kratki_speed (+30% 1,5 s) pod veštačkim RTT-om (test_rtt_ms, test_jitter_ms): ivice buff-a moraju biti bez snap-a
# i sa greškom predikcije <= 0,10 m, početak <= RTT + 200 ms (i prvi napitak). Server: stanje BrzinaLik-a u
# dir/brzina_server (raspored, horizontalna brzina, mrtav, peer), komanda dir/brzina_cmd "ubij".
var _br_srv_upisano := ""
var _br_cmd := ""
var _br_krenuo := false
var _br_kraj := false
var _br_hoda := false
var _br_yaw := -PI / 2

func _server_brzina() -> void:
	if dir == "" or _world() == null: return
	var p = _ai_lik("BrzinaLik")
	if p == null: return
	var cmd := FileAccess.get_file_as_string(dir + "/brzina_cmd")
	if cmd != "" and cmd != _br_cmd:
		_br_cmd = cmd
		_br_ubij(p)
	var v: Vector3 = p.velocity
	var uz = p.get("_rtt_uzorci")
	var st := JSON.stringify({"raspored": p.get("_raspored_brzine"), "v": snappedf(Vector2(v.x, v.z).length(), 0.01), "mrtav": p.mrtav,
		"peer": str(p.name), "rtt_uzoraka": uz.size() if uz is Array else -1})
	if st != _br_srv_upisano:
		_br_srv_upisano = st
		_pisi("brzina_server", st)

func _br_ubij(p) -> void: # posle respawn-a nazad u zonu 2 (spawn je na putanji movera)
	p.server_primi_damage(1000000)
	await _cekaj(func(): return not p.mrtav, 8.0)
	p.server_postavi_poziciju(Vector3(45, 1.16, -20), true)

func _br_srv() -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir + "/brzina_server"))
	return d if d is Dictionary else {}

# horizontalna brzina po serveru (medijana uzoraka iz dir/brzina_server tokom sek)
func _br_v_srv(sek: float) -> float:
	var u := []
	var kraj := Time.get_ticks_msec() + int(sek * 1000)
	while Time.get_ticks_msec() < kraj:
		u.append(float(_br_srv().get("v", -1.0)))
		await process_frame
	u.sort()
	return u[u.size() / 2] if not u.is_empty() else -1.0

func _uloga_brzina() -> bool:
	var p = _moj()
	# veštački RTT od prvog frame-a lika, ne tek kad UI javi učitavanje: klijent pod opterećenjem kasni za serverom > 2 s
	# (PING_ZAGREVANJE_MS), pa bi server skupio pongove bez kašnjenja (~15 ms) i prvi napitak zakazao prerano
	if p != null and _korak == 1 and not _br_krenuo: p.set("test_rtt_ms", 250)
	if p == null or not p.get_node("ui/Control")._ucitano:
		return (_br_krenuo and p == null) or t > 2 * MAX_T
	if not _br_krenuo:
		_br_krenuo = true
		if _korak == 1: _brzina_scenario(p)
		else: _brzina_relog(p)
	if _br_hoda: # okret na granicama (server_poz), smer svaki frame
		if p.server_poz.x < 48.0: _br_yaw = -PI / 2 # ka +x
		elif p.server_poz.x > 62.0: _br_yaw = PI / 2
		p.rotation.y = _br_yaw
	return _br_kraj or t > 2 * MAX_T

const BR_RTT_UZORAKA := 4
const BR_ROK := 10.0

func _br_hod(da: bool) -> void:
	_br_hoda = da
	if da: Input.action_press("ui_up")
	else: Input.action_release("ui_up")

# jedan test_kratki_speed: korekcije, snap, najveća greška predikcije i kašnjenje početka (klik -> prvi brži korak)
func _br_ivica(p, rtt: int, kuka: String) -> Dictionary:
	var k0: int = p.korekcije_glatke
	var s0: int = p.korekcije_snap
	p.greska_max = 0.0
	p.set("test_raspored_brzine", kuka)
	p.set("test_brzina_pocela_ms", -1)
	var klik := Time.get_ticks_msec()
	var od := Time.get_unix_time_from_system()
	if rtt > 0: await create_timer(rtt / 2000.0).timeout # zahtev putuje pola RTT-a (odgovor se ne meri)
	var odg: Dictionary = await p.koristi_item_na_serveru("test_kratki_speed")
	var pocela: bool = await _cekaj(func(): return _br_pocela(p) > 0, 3.0)
	var kasni: int = _br_pocela(p) - klik if pocela else -1
	var z_poc := _zastoj_izmedju(od, Time.get_unix_time_from_system())
	await create_timer(1.5 + rtt / 1000.0 + 0.8).timeout # kraj buff-a i poslednja stanja
	return {"ok": bool(odg.get("ok", false)) and pocela, "glatke": p.korekcije_glatke - k0, "snap": p.korekcije_snap - s0,
		"max": snappedf(p.greska_max, 0.001), "kasni": kasni, "odg": odg.get("poruka", ""),
		"z_poc": z_poc, "z": _zastoj_izmedju(od, Time.get_unix_time_from_system())}

# Provera ivica brzine: napitak uspeo i 0 snap-ova uvek; merenja u vremenu (kašnjenje početka, broj korekcija, greška
# predikcije) koja ne prođu su WARN samo ako je u tom prozoru zastao ovaj proces ili server (frame > ZASTOJ_PRAG), kao seq.
# delovi: [[x, kasni_ok, kor_ok], ...]
func _br_provera(ime: String, delovi: Array, detalj: String) -> void:
	var ok := true
	var warn := []
	for d in delovi:
		var x: Dictionary = d[0]
		if not x.ok or x.snap != 0:
			ok = false
			continue
		if not d[1]:
			if x.z_poc == "": ok = false
			else: warn.append("početak uz zastoj %s" % x.z_poc)
		if not d[2]:
			if x.z == "": ok = false
			else: warn.append("korekcije uz zastoj %s" % x.z)
	if ok and not warn.is_empty(): print("WARN %s  neodlučno (zastoj): %s; %s" % [ime, ", ".join(warn), detalj])
	else: _provera(ime, ok, detalj)

func _br_pocela(p) -> int: # test_brzina_pocela_ms (0 ako ga kod igre nema)
	var v = p.get("test_brzina_pocela_ms")
	return int(v) if v != null else 0

func _br_opis(x: Dictionary) -> String:
	return "glatke %d, snap %d, max greška %.3f m, početak %d ms%s%s" % [x.glatke, x.snap, x.max, x.kasni,
		"" if x.ok else " (napitak: %s)" % x.odg, " (zastoj %s)" % x.z if x.z != "" else ""]

func _brzina_scenario(p) -> void:
	# prvi napitak: procena RTT-a od prijave (bez zastoja pri učitavanju); test_rtt_ms 250 je postavljen od prvog frame-a
	await _cekaj(func(): return p.is_on_floor(), 5.0)
	_br_hod(true)
	# klijent ne može da postavi brzinu: lažni raspored ka serveru (guard: samo server šalje raspored)
	var ima: bool = p.has_method("primi_raspored_brzine")
	if ima: p.primi_raspored_brzine.rpc_id(1, [[0, 100000000, 30]])
	await create_timer(1.0).timeout
	var v_laz := await _br_v_srv(1.0)
	var r_laz = _br_srv().get("raspored", [])
	_provera("klijent_ne_postavlja_brzinu", ima and r_laz is Array and r_laz.is_empty() and absf(v_laz - 5.0) < 0.3,
		"lažni raspored [[0, 1e8, 30]] od klijenta: server raspored %s, brzina po serveru %.2f m/s (bazna 5)" % [r_laz, v_laz])
	await create_timer(1.0).timeout
	# bar BR_RTT_UZORAKA pingova posle zagrevanja (bez opterećenja ih je ovde ~4): inače server koristi ENet RTT bez veštačkog
	await _cekaj(func(): return int(_br_srv().get("rtt_uzoraka", 0)) >= BR_RTT_UZORAKA, BR_ROK)
	var uslovi := [["rtt_250_prvi", 250, 0, ""], ["rtt_0", 0, 0, ""], ["rtt_80", 80, 0, ""], ["rtt_150", 150, 0, ""],
		["jitter_150", 150, 50, ""], ["jitter_250", 250, 50, ""], ["kasni", 150, 0, "kasni:500"], ["izgubi", 150, 0, "izgubi"]]
	var rez := {}
	for u in uslovi:
		if u[0] != "rtt_250_prvi":
			p.set("test_rtt_ms", u[1])
			p.set("test_jitter_ms", u[2])
			await create_timer(3.5).timeout # procena RTT-a (12 pingova po 250 ms) se ustali
		rez[u[0]] = await _br_ivica(p, u[1], u[3])
		print("[BRZINA] %s (rtt %d +-%d): %s" % [u[0], u[1], u[2], _br_opis(rez[u[0]])])
	for u in [["rtt_250_prvi", 250, "brzina_ivice_rtt_250_prvi_napitak"], ["rtt_0", 0, "brzina_ivice_rtt_0"], ["rtt_80", 80, "brzina_ivice_rtt_80"],
			["rtt_150", 150, "brzina_ivice_rtt_150"]]:
		var x: Dictionary = rez[u[0]]
		# najviše 4 korekcije po napitku (kao za raspored koji kasni): brzina po satu umesto po seq-u daje 10-17 malih
		_br_provera(u[2], [[x, x.kasni >= 0 and x.kasni <= u[1] + 200, x.glatke <= 4 and x.max <= 0.10]],
			"RTT %d ms: %s (uslov: 0 snap, <= 4 korekcije, <= 0,10 m, početak <= %d ms)" % [u[1], _br_opis(x), u[1] + 200])
	var j1: Dictionary = rez["jitter_150"]
	var j2: Dictionary = rez["jitter_250"]
	_br_provera("brzina_jitter_50ms", [[j1, true, j1.max <= 0.4], [j2, true, j2.max <= 0.4]],
		"150 +-50: %s; 250 +-50: %s (uslov: 0 snap, <= 0,4 m)" % [_br_opis(j1), _br_opis(j2)])
	for u in [["kasni", "brzina_raspored_kasni_500ms"], ["izgubi", "brzina_raspored_izgubljen"]]:
		var x: Dictionary = rez[u[0]]
		_br_provera(u[1], [[x, true, x.glatke <= 4 and x.max <= 0.4]],
			"RTT 150: %s (uslov: 0 snap, najviše 4 korekcije, <= 0,4 m)" % _br_opis(x))
	await _br_osvezavanje(p)
	await _br_smrt(p)
	await _br_odjava(p)

# osvežavanje: drugi napitak stiže serveru pred kraj aktivnog intervala -> isti interval produžen, bez rupe sporog hoda
func _br_osvezavanje(p) -> void:
	p.set("test_rtt_ms", 150)
	p.set("test_jitter_ms", 0)
	await create_timer(3.5).timeout
	var k0: int = p.korekcije_glatke
	var s0: int = p.korekcije_snap
	p.greska_max = 0.0
	var r0 := str(p.get("_raspored_brzine")) # raspored prethodnog napitka: čeka se novi (stiže pola RTT-a posle odgovora)
	var odg1: Dictionary = await p.koristi_item_na_serveru("test_kratki_speed")
	await _cekaj(func(): return p.get("_raspored_brzine") is Array and not p.get("_raspored_brzine").is_empty() \
		and str(p.get("_raspored_brzine")) != r0, 3.0)
	var r1: Array = (p.get("_raspored_brzine") as Array).duplicate(true) if p.get("_raspored_brzine") is Array else []
	var kraj1: int = int(r1[-1][1]) if not r1.is_empty() else 0
	await _cekaj(func(): return p._seq >= kraj1 - 12, 3.0) # zahtev stiže serveru ~8 unosa pre kraja (aktivan interval)
	await create_timer(0.075).timeout
	var odg2: Dictionary = await p.koristi_item_na_serveru("test_kratki_speed")
	await create_timer(1.5 + 0.15 + 0.8).timeout
	var r2: Array = (p.get("_raspored_brzine") as Array) if p.get("_raspored_brzine") is Array else []
	var srv = _br_srv().get("raspored", [])
	_provera("brzina_osvezavanje_bez_rupe", odg1.get("ok", false) and odg2.get("ok", false) and r1.size() == 1 and r2.size() == 1
		and int(r2[0][0]) == int(r1[0][0]) and int(r2[0][1]) > kraj1 + 60 and _b_rasp_int(srv) == _b_rasp_int(r2)
		and p.korekcije_snap - s0 == 0 and p.greska_max <= 0.4,
		"pre osvežavanja %s, posle %s (server %s), drugi napitak %s; glatke %d, snap %d, max %.3f m" % [r1, r2, srv, odg2, p.korekcije_glatke - k0,
		p.korekcije_snap - s0, p.greska_max])

# smrt usred speed_potion-a: brzina po serveru 6,5 -> posle respawn-a 5, raspored prazan na serveru i kod vlasnika
func _br_smrt(p) -> void:
	p.set("test_rtt_ms", 0)
	var odg: Dictionary = await p.koristi_item_na_serveru("speed_potion")
	_pisi("brzina_prvi_speed", str(Time.get_ticks_msec()))
	await create_timer(1.0).timeout
	var v_pre := await _br_v_srv(0.5)
	_pisi("brzina_cmd", "ubij")
	await _cekaj(func(): return bool(p.get("mrtav")), 3.0)
	var bio_mrtav: bool = p.get("mrtav")
	await _cekaj(func(): return not bool(p.get("mrtav")), 8.0)
	await create_timer(1.5).timeout # server vrati lik u zonu 2 (reset)
	var v_posle := await _br_v_srv(1.0)
	var srv = _br_srv().get("raspored", [1])
	var kl = p.get("_raspored_brzine")
	_provera("brzina_smrt_prekida", odg.get("ok", false) and bio_mrtav and absf(v_pre - 6.5) < 0.3 and absf(v_posle - 5.0) < 0.3
		and srv is Array and srv.is_empty() and kl is Array and kl.is_empty(),
		"speed_potion %s; brzina po serveru pre smrti %.2f, posle respawn-a %.2f m/s; raspored server %s, klijent %s" % [
		odg.get("ok", odg.get("poruka")), v_pre, v_posle, srv, kl])

# odjava usred speed_potion-a (korak 2 = ponovna prijava proverava da buff nije preživeo)
func _br_odjava(p) -> void:
	var od := int(FileAccess.get_file_as_string(dir + "/brzina_prvi_speed"))
	await create_timer(maxf(0.0, (od + 5300 - Time.get_ticks_msec()) / 1000.0)).timeout # cooldown 5 s
	var odg: Dictionary = await p.koristi_item_na_serveru("speed_potion")
	await create_timer(1.0).timeout
	var v := await _br_v_srv(0.5)
	_pisi("brzina_odjava", JSON.stringify({"ok": odg.get("ok", false), "v": v, "raspored": _br_srv().get("raspored", [])}))
	_br_hod(false)
	_br_kraj = true

func _brzina_relog(p) -> void:
	var pre = JSON.parse_string(FileAccess.get_file_as_string(dir + "/brzina_odjava"))
	if not pre is Dictionary: pre = {}
	await _cekaj(func(): return p.is_on_floor() and str(_br_srv().get("peer", "")) == str(p.name), 5.0)
	_br_hod(true)
	await create_timer(1.0).timeout
	var v := await _br_v_srv(1.0)
	_br_hod(false)
	var srv = _br_srv().get("raspored", [1])
	var kl = p.get("_raspored_brzine")
	var bf = p.get("buffovi")
	_provera("brzina_odjava_prekida", bool(pre.get("ok", false)) and absf(float(pre.get("v", 0)) - 6.5) < 0.3
		and not (pre.get("raspored", []) as Array).is_empty() and absf(v - 5.0) < 0.3 and srv is Array and srv.is_empty()
		and kl is Array and kl.is_empty() and bf is Dictionary and bf.is_empty(),
		"pre odjave %s; posle prijave brzina po serveru %.2f m/s, raspored server %s klijent %s, buffovi %s" % [pre, v, srv, kl, bf])
	_br_kraj = true

# ---------------------------------------------------------------- EFEKTI (uloga efekti: korak 1 EfektiLik, korak 2 Efekti2Lik)
# Otrov pauka, antidote, nevidljivost i vaskrsenje (migracija 011). Scenario vodi server drajver (_efekti_scenario) nad
# test goblinom i paukom (meta ai_test, brzina 0, bez sopstvenih napada) u zoni 2 kod (35, 22). Klijenti izvršavaju
# komande iz dir/efekti_cmd_<ime> ("N pij ID" | "N tooltip ID" | "N lazni" | "N kraj"), odgovor u dir/efekti_odg_<ime>
# ("N tekst"), a stanje prikaza (HUD, buffovi, providnost svog i tuđeg lika) upisuju u dir/efekti_kl_<ime> (JSON).
const EF_DOM1 := Vector3(35, 1.16, 22)
const EF_DOM2 := Vector3(38, 1.16, 22)
const EF_GOBLIN := Vector3(35, 2, 14)
const EF_PAUK := Vector3(42, 2, 14)
const EF_GOBLIN2 := Vector3(45, 2, 20)
const EF_DALEKO := Vector3(38, 1.16, -10) # 20+ m od oba goblina: leash (POVRATAK)
var _ef_krenuo := false
var _ef_kraj := false
var _ef_cmd := ""
var _ef_upisano := ""
var _ef_cmd_br := 0
var _ef_srv_krenuo := false

func _uloga_efekti() -> bool:
	var p = _moj()
	if p == null or not p.get_node("ui/Control")._ucitano:
		return (_ef_krenuo and p == null) or t > 2 * MAX_T
	_ef_krenuo = true
	var ime: String = root.get_node("GameState").ime_igraca
	var cmd := FileAccess.get_file_as_string(dir + "/efekti_cmd_" + ime)
	if cmd != "" and cmd != _ef_cmd:
		_ef_cmd = cmd
		_ef_izvrsi(p, ime, cmd.split(" "))
	_ef_upisi_stanje(p, ime)
	return _ef_kraj or FileAccess.file_exists(dir + "/efekti_gotov") or t > 2 * MAX_T

# vlasnik vidi sebe, a Efekti2Lik vidi EfektiLik-a providno (nevidljiv) ili normalno, nameplate ostaje
func _ef_prikaz(nevidljiv: bool) -> bool:
	var k1 := _ef_kl("EfektiLik")
	var k2 := _ef_kl("Efekti2Lik")
	var pr := 0.7 if nevidljiv else 0.0
	return k1.get("sync") == nevidljiv and is_equal_approx(float(k1.get("providnost", -1)), pr) \
		and k2.get("drugi_sync") == nevidljiv and is_equal_approx(float(k2.get("drugi_providnost", -1)), pr) \
		and k2.get("drugi_nameplate") == true

func _ef_kl_prazno() -> bool: # klijent EfektiLik: bez buffova i debuffova, HUD prazan
	var k := _ef_kl("EfektiLik")
	return (k.get("buffovi", [1]) as Array).is_empty() and k.get("buff") == "" and k.get("debuff") == ""

func _ef_providnost(lik) -> float:
	var model = lik.get_node_or_null("CharacterMain") if lik else null
	var m: Array = model.find_children("*", "GeometryInstance3D", true, false) if model else []
	return snappedf(m[0].transparency, 0.01) if not m.is_empty() else -1.0

func _ef_upisi_stanje(p, ime: String) -> void:
	var hud = p.get_node("ui/Control")
	var dl = hud.get("debuff_label")
	var drugi = null
	for n in _world().get_children() if _world() else []:
		if n != p and n.is_in_group("player") and str(n.get("ime_sync")) in ["EfektiLik", "Efekti2Lik"]: drugi = n
	var np = drugi.get_node_or_null("Nameplate") if drugi else null
	var st := JSON.stringify({"buff": _b_hud(hud), "debuff": dl.text if dl != null else "(nema DebuffLabel)",
		"debuff_boja": dl.get_theme_color("font_color").to_html() if dl != null else "", "buffovi": _b_klijent(p).keys(),
		"sync": p.get("nevidljiv_sync"), "providnost": _ef_providnost(p),
		"drugi_sync": drugi.get("nevidljiv_sync") if drugi else null, "drugi_providnost": _ef_providnost(drugi),
		"drugi_nameplate": np != null and np.visible})
	if st != _ef_upisano:
		_ef_upisano = st
		_pisi("efekti_kl_" + ime, st)

func _ef_izvrsi(p, ime: String, c: PackedStringArray) -> void:
	print("[EF-K] ", ime, " komanda: ", " ".join(c))
	var inv = p.get_node("ui/InventoryUI")
	var hud = p.get_node("ui/Control")
	var odg := ""
	match c[1]:
		"pij":
			await inv._koristi_item(c[2])
			odg = hud._poruka_label.text if hud._poruka_label else ""
		"tooltip":
			var i := _inv_index(inv, c[2])
			if i >= 0: inv._on_slot_hover(i)
			odg = inv.tooltip_label.text.replace("\n", " | ")
		"lazni": # klijent sebi postavi nevidljivost lokalno i pošalje lažni buff serveru; posle 1 s vrati lokalno stanje
			if "nevidljiv_sync" in p: p.nevidljiv_sync = true
			p.primi_buffove.rpc_id(1, {"nevidljivost": [1, 60000]})
			await create_timer(1.0).timeout
			if "nevidljiv_sync" in p: p.nevidljiv_sync = false
		"kraj":
			_ef_kraj = true
	_pisi("efekti_odg_" + ime, "%s %s" % [c[0], odg])

func _ef_kl(ime: String) -> Dictionary:
	var d = JSON.parse_string(FileAccess.get_file_as_string(dir + "/efekti_kl_" + ime))
	return d if d is Dictionary else {}

func _ef_posalji(ime: String, cmd: String) -> String:
	_ef_cmd_br += 1
	var br := str(_ef_cmd_br)
	_pisi("efekti_cmd_" + ime, "%s %s" % [br, cmd])
	await _cekaj(func(): return FileAccess.get_file_as_string(dir + "/efekti_odg_" + ime).get_slice(" ", 0) == br, 8.0)
	var o := FileAccess.get_file_as_string(dir + "/efekti_odg_" + ime)
	return o.substr(o.find(" ") + 1) if o.get_slice(" ", 0) == br else "(bez odgovora)"

func _server_efekti() -> void:
	if _ef_srv_krenuo or dir == "": return
	var p1 = _ai_lik("EfektiLik")
	var p2 = _ai_lik("Efekti2Lik")
	if p1 and p2 and p1.get("_stanje_ucitano") and p2.get("_stanje_ucitano"):
		_ef_srv_krenuo = true
		_efekti_scenario(p1, p2)

func _ef_bf(p) -> Dictionary: # buffovi po serveru: tip -> [vrednost, preostalo ms]
	var d := {}
	var bf = p.get("_buffovi")
	if bf is Dictionary:
		for tip in bf: d[tip] = [int(bf[tip][0]), int(bf[tip][1]) - Time.get_ticks_msec()]
	return d

func _ef_nevidljiv(p) -> bool:
	return p.has_method("nevidljiv") and p.nevidljiv()

func _ef_spawn(vrsta: String, id: int, poz: Vector3, nivo: int):
	_world().goblin_spawner.spawn({"vrsta": vrsta, "id": id, "pos": poz, "nivo": nivo})
	await _cekaj(func(): return _nep("%s_%d" % [vrsta, id]) != null, 3.0)
	var e = _nep("%s_%d" % [vrsta, id])
	if e:
		e.set_meta("ai_test", true)
		e.brzina = 0.0
		e.moze_napasti = false
	return e

# Pauk udari metu (server, kao njegov napad u dometu): ishod [šteta udarca, otrov posle]
func _ef_ujed(s, p) -> Array:
	s.player = p
	var pre: int = p.hp
	s.napadni_igraca()
	return [pre - p.hp, _ef_bf(p).get("otrov")]

func _ef_umri_respawn(p) -> void: # posle smrti: respawn, nazad kući, pa kraj neosetljivosti
	await _cekaj(func(): return not p.mrtav, 8.0)
	p.server_postavi_poziciju(EF_DOM1, true)
	await create_timer(2.2).timeout

func _efekti_scenario(p1, p2) -> void:
	var id1: int = p1.get_multiplayer_authority()
	var id2: int = p2.get_multiplayer_authority()
	await _cekaj(func(): return not _ef_kl("EfektiLik").is_empty() and not _ef_kl("Efekti2Lik").is_empty(), 20.0)
	p1.server_postavi_poziciju(EF_DOM1, true)
	p2.server_postavi_poziciju(EF_DOM2, true)
	var g = await _ef_spawn("goblin", 2001, EF_GOBLIN, 1)
	var s = await _ef_spawn("spider", 2002, EF_PAUK, 15)
	if g == null or s == null:
		_provera("efekti_scenario", false, "test goblin %s, pauk %s" % [g, s])
		_pisi("efekti_gotov", "1")
		return
	g.aggro_range = 4.0
	g.max_hp = 100000 # napad EfektiLik-a (63) ne sme da ga ubije
	g.hp = 100000
	s.aggro_range = 0.0 # pauk ne bira metu sam: udara samo kad ga drajver pozove (_ef_ujed)
	var hud := {} # tekstovi HUD-a i tooltip-a za efekti_hud_i_tooltip
	var tt := [] # tooltip-ovi dok su napici još u inventaru
	for id in ["invisibility_potion", "resurrection_potion", "antidote"]:
		tt.append(await _ef_posalji("EfektiLik", "tooltip " + id))
	print("[S-EF] start, EfektiLik=%d Efekti2Lik=%d, armor %d, max HP %d" % [id1, id2, p1.armor, p1.max_hp])

	# vrednosti otrova po nivou pauka (scena): 30% po udarcu, 18% napada po sekundi (3 HP/s na nivoima 14-16), 6 s
	var po_nivou := []
	for n in [14, 15, 16]:
		var we = _telo_scene("spider", n)
		var e = we[1]
		if e.has_method("_skaliraj"): e._skaliraj()
		po_nivou.append([n, e.get("napad_damage"), e.get("otrov_sansa"), e.get("otrov_procenat"), e.get("otrov_trajanje"),
			e.otrov_steta() if e.has_method("otrov_steta") else -1])
		we[0].free()
	_provera("pauk_otrov_vrednosti_po_nivou", po_nivou == [[14, 16, 30, 18, 6.0, 3], [15, 17, 30, 18, 6.0, 3], [16, 18, 30, 18, 6.0, 3]],
		"[nivo, napad, šansa %%, %% napada/s, trajanje s, šteta/s]: %s" % [po_nivou])

	# --- NEVIDLJIVOST
	# napitak: 20 s, cooldown 60 s; nevidljiv u aggro dometu (2 m od goblina, aggro 4 m): goblin ostaje u MIROVANJU
	var poruka := await _ef_posalji("EfektiLik", "pij invisibility_potion")
	await _cekaj(func(): return _ef_nevidljiv(p1), 2.0)
	var preostalo := int(_ef_bf(p1).get("nevidljivost", [0, 0])[1])
	var cd := int(p1.get("_item_cd_do_ms").get("invisibility_potion", 0)) - Time.get_ticks_msec()
	p1.server_postavi_poziciju(EF_GOBLIN + Vector3(0, -0.84, 2), true)
	await create_timer(1.0).timeout
	_provera("nevidljiv_bez_aggro", _ef_nevidljiv(p1) and preostalo > 18000 and preostalo <= 20000 and cd > 58000 and cd <= 60000
		and _st(g) == "MIROVANJE" and _tab(g).is_empty(),
		"poruka '%s', nevidljiv=%s (preostalo %d ms, cooldown %d ms), 2 m od goblina: stanje %s, pretnja %s" % [poruka,
		_ef_nevidljiv(p1), preostalo, cd, _st(g), _tab(g)])
	# prikaz: vlasnik i drugi igrač vide providan lik (0,7) sa nameplate-om
	var vid: bool = await _cekaj(func(): return _ef_prikaz(true), 3.0)
	var k_vid := [_ef_kl("EfektiLik"), _ef_kl("Efekti2Lik")]
	hud["nevidljiv"] = str(k_vid[0].get("buff", ""))

	# napad prekida nevidljivost (pre štete), goblin juri napadača
	var bio_nevidljiv := _ef_nevidljiv(p1)
	p1.set("_cilj_srv", "goblin_2001")
	p1.set("_napad_spreman_ms", 0)
	var napad: Dictionary = p1._napadni_cilj()
	await create_timer(0.3).timeout
	_provera("napad_prekida_nevidljivost", bio_nevidljiv and napad.get("ok", false) and not _ef_nevidljiv(p1)
		and not _ef_bf(p1).has("nevidljivost") and _st(g) == "JURENJE" and _meta(g) == id1 and _pr(g, p1) > 0,
		"nevidljiv pre napada=%s, napad %s, posle: nevidljiv=%s, goblin %s meta %d (EfektiLik %d), pretnja %s" % [bio_nevidljiv,
		napad, _ef_nevidljiv(p1), _st(g), _meta(g), id1, _tab(g)])
	var nevid: bool = await _cekaj(func(): return _ef_prikaz(false), 3.0)
	_provera("nevidljiv_providan", vid and nevid,
		"za vreme: vlasnik %s, drugi %s; posle prekida: vlasnik %s, drugi %s" % [k_vid[0], k_vid[1], _ef_kl("EfektiLik"), _ef_kl("Efekti2Lik")])

	# jedina meta postane nevidljiva (test napitak 2 s): goblin odustaje (POVRATAK, pa MIROVANJE na početku)
	await _ef_posalji("EfektiLik", "pij test_kratka_nevidljivost")
	var odustao: bool = await _cekaj(func(): return _st(g) != "JURENJE" and _tab(g).is_empty(), 1.5)
	var st_odustao := _st(g)
	_provera("nevidljivost_prekida_jurenje", odustao and _ef_nevidljiv(p1),
		"nevidljiv=%s, goblin %s, pretnja %s" % [_ef_nevidljiv(p1), st_odustao, _tab(g)])
	# istek (2 s): goblin ga ponovo vidi u aggro dometu
	var vraca: bool = await _cekaj(func(): return not _ef_nevidljiv(p1) and _st(g) == "JURENJE" and _meta(g) == id1, 4.0)
	_provera("istek_nevidljivosti_vraca_aggro", odustao and vraca,
		"za vreme nevidljivosti %s, posle isteka goblin %s meta %d (EfektiLik %d)" % [st_odustao, _st(g), _meta(g), id1])

	# dva igrača u tabeli: meta postane nevidljiva -> goblin prelazi na drugog (ostaje u JURENJU)
	p2.server_postavi_poziciju(EF_GOBLIN + Vector3(2, -0.84, 0), true)
	await _cekaj(func(): return _pr(g, p2) > 0, 2.0)
	await create_timer(0.6).timeout # cooldown test napitka 0,5 s
	await _ef_posalji("EfektiLik", "pij test_kratka_nevidljivost")
	var prelaz: bool = await _cekaj(func(): return _ef_nevidljiv(p1) and _meta(g) == id2 and _st(g) == "JURENJE", 1.5)
	_provera("nevidljivost_druga_meta", prelaz and _pr(g, p1) < 0,
		"nevidljiv=%s, goblin %s meta %d (Efekti2Lik %d), pretnja %s" % [_ef_nevidljiv(p1), _st(g), _meta(g), id2, _tab(g)])
	await _cekaj(func(): return not _ef_nevidljiv(p1), 3.0)

	# klijent ne postavlja nevidljivost: lokalno sync polje i lažni primi_buffove ne menjaju server (goblin ga vidi)
	p1.server_postavi_poziciju(EF_DALEKO, true)
	p2.server_postavi_poziciju(EF_DALEKO + Vector3(3, 0, 0), true)
	await _cekaj(func(): return _st(g) == "MIROVANJE", 3.0)
	p2.server_postavi_poziciju(EF_DOM2, true)
	_ef_posalji("EfektiLik", "lazni") # bez čekanja: klijent drži lažno lokalno stanje 1 s
	await create_timer(0.3).timeout
	p1.server_postavi_poziciju(EF_GOBLIN + Vector3(0, -0.84, 2), true)
	var vidi: bool = await _cekaj(func(): return _st(g) == "JURENJE" and _meta(g) == id1, 1.5)
	await create_timer(1.0).timeout
	_provera("klijent_ne_postavlja_nevidljivost", "nevidljiv_sync" in p1 and vidi and not _ef_nevidljiv(p1) and not p1.nevidljiv_sync,
		"sync polje postoji=%s, posle lažnog: server nevidljiv=%s, sync %s, goblin %s meta %d" % ["nevidljiv_sync" in p1,
		_ef_nevidljiv(p1), p1.get("nevidljiv_sync"), _st(g), _meta(g)])
	p1.server_postavi_poziciju(EF_DOM1, true)

	# napadač koji ode (POVRATAK, regeneracija do punog) ne dobija XP ni loot kad goblina posle ubije drugi
	var g2 = await _ef_spawn("goblin", 2003, EF_GOBLIN2, 1)
	g2.aggro_range = 0.0
	var x1 := await _b_xp_ore("EfektiLik")
	var st2: Dictionary = await _b_stub("Efekti2Lik")
	p2.server_postavi_poziciju(EF_GOBLIN2 + Vector3(1, -0.84, 0), true)
	await create_timer(0.3).timeout
	g2.primi_damage(5, id2)
	await _cekaj(func(): return _st(g2) == "JURENJE", 1.0)
	p2.server_postavi_poziciju(EF_DALEKO, true)
	var povratak: bool = await _cekaj(func(): return _st(g2) == "MIROVANJE", 3.0)
	g2.primi_damage(1000000, id1)
	var x2 := await _b_xp_ore("EfektiLik", func(xp, _o): return xp != x1[0])
	await create_timer(1.0).timeout
	var st2b: Dictionary = await _b_stub("Efekti2Lik")
	_provera("xp_loot_posle_povratka", povratak and x2[0] > x1[0] and int(st2b.get("xp", -1)) == int(st2.get("xp", -2))
		and str(st2b.get("inventory")) == str(st2.get("inventory")),
		"povratak do MIROVANJA=%s; EfektiLik (ubio) XP %d -> %d; Efekti2Lik (udario pa otišao) XP %s -> %s, inventar %s -> %s" % [
		povratak, x1[0], x2[0], st2.get("xp"), st2b.get("xp"), st2.get("inventory"), st2b.get("inventory")])
	p2.server_postavi_poziciju(EF_DOM2, true)

	# --- OTROV (EfektiLik 1 m od pauka nivoa 15; šansa 100% samo u testu)
	s.set("otrov_sansa", 100) # set: bez greške i kad svojstvo ne postoji (provera bez implementacije)
	p1.server_postavi_poziciju(EF_PAUK + Vector3(-1, -0.84, 0), true)
	await create_timer(0.3).timeout
	var u1 := await _ef_ujed(s, p1)
	# tick 1/s zajedno sa regeneracijom (+2): 3 mimo oklopa -> -1 po tick-u, 6 tick-ova, pa samo regeneracija (+2)
	var promene := []
	var hp_pre: int = p1.hp
	var do_ := Time.get_ticks_msec() + 7500
	while Time.get_ticks_msec() < do_:
		await process_frame
		if p1.hp != hp_pre:
			promene.append(p1.hp - hp_pre)
			hp_pre = p1.hp
		if promene.size() == 3 and not hud.has("otrov"):
			hud["otrov"] = str(_ef_kl("EfektiLik").get("debuff", ""))
			hud["otrov_boja"] = str(_ef_kl("EfektiLik").get("debuff_boja", ""))
	_provera("otrov_mimo_oklopa_6_tikova", u1[0] == 13 and u1[1] is Array and u1[1][0] == 3 and u1[1][1] > 5500
		and promene.slice(0, 7) == [-1, -1, -1, -1, -1, -1, 2],
		"oklop %d: udarac -%d (13), otrov %s; promene HP-a (tick 3 - regen 2) %s" % [p1.armor, u1[0], u1[1], promene])

	# osvežavanje: drugi ujed usred otrova vraća trajanje na 6 s, šteta ostaje 3
	await _ef_ujed(s, p1)
	await create_timer(3.0).timeout
	var pre_osv: Array = _ef_bf(p1).get("otrov", [0, 0])
	var u3 := await _ef_ujed(s, p1)
	_provera("otrov_osvezava_bez_sabiranja", pre_osv[1] > 2000 and pre_osv[1] < 3500 and u3[1] is Array and u3[1][0] == 3 and u3[1][1] > 5500,
		"posle 3 s preostalo %s, posle novog ujeda %s (3 HP/s, ~6000 ms)" % [pre_osv, u3[1]])

	# otrov ubija: smrt skida sve (otrov i elixir_of_defense), respawn bez otrova sa punim HP-om
	await _ef_posalji("EfektiLik", "pij elixir_of_defense")
	await _cekaj(func(): return _ef_bf(p1).has("oklop"), 2.0)
	var pre_smrti := _ef_bf(p1).keys()
	p1.hp = 2
	var umro: bool = await _cekaj(func(): return p1.mrtav, 2.0)
	var bf_smrt := _ef_bf(p1)
	var kl_smrt: bool = await _cekaj(func(): return _ef_kl_prazno(), 2.0)
	await _ef_umri_respawn(p1)
	_provera("otrov_ubija", pre_smrti.has("otrov") and pre_smrti.has("oklop") and umro and bf_smrt.is_empty() and kl_smrt
		and p1.hp == p1.max_hp and not _ef_bf(p1).has("otrov"),
		"pre smrti %s, mrtav=%s, posle smrti server %s, klijent %s, posle respawn-a hp %d/%d buffovi %s" % [pre_smrti, umro,
		bf_smrt, _ef_kl("EfektiLik"), p1.hp, p1.max_hp, _ef_bf(p1)])

	# antidote pod otrovom na punom HP-u: skida otrov, +20 HP (do maksimuma), 30 s ne može novi otrov
	p1.server_postavi_poziciju(EF_PAUK + Vector3(-1, -0.84, 0), true)
	await create_timer(0.3).timeout
	var u4 := await _ef_ujed(s, p1)
	p1.hp = p1.max_hp
	p1._posalji_hp()
	poruka = await _ef_posalji("EfektiLik", "pij antidote")
	await _cekaj(func(): return _ef_bf(p1).has("protivotrov"), 2.0)
	var bf_anti := _ef_bf(p1)
	var u5 := await _ef_ujed(s, p1)
	await _cekaj(func(): return str(_ef_kl("EfektiLik").get("buff", "")).begins_with("Poison immunity"), 1.0)
	hud["imunitet"] = str(_ef_kl("EfektiLik").get("buff", ""))
	_provera("antidote_skida_otrov_i_imunitet", u4[1] is Array and not bf_anti.has("otrov") and bf_anti.has("protivotrov")
		and int(bf_anti["protivotrov"][1]) > 28000 and u5[1] == null and str(_ef_kl("EfektiLik").get("debuff", "x")) == "",
		"otrov pre %s, poruka '%s', posle antidota %s, novi ujed: otrov %s" % [u4[1], poruka, bf_anti, u5[1]])

	# odjava pod otrovom: server briše otrov pri odjavi, HP ne pada dok snima (spori save 2,5 s)
	p2.server_postavi_poziciju(EF_PAUK + Vector3(1, -0.84, 0), true)
	await create_timer(0.3).timeout
	var u6 := await _ef_ujed(s, p2)
	await create_timer(0.5).timeout
	_ef_posalji("Efekti2Lik", "kraj")
	await _cekaj(func(): return not is_instance_valid(p2) or not p2.is_in_group("player"), 5.0)
	var hp_odj: int = p2.hp if is_instance_valid(p2) else -1
	var pad := false
	var bf_odj := {}
	do_ = Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < do_ and is_instance_valid(p2):
		await process_frame
		if not is_instance_valid(p2): break
		pad = pad or p2.hp < hp_odj
		bf_odj = _ef_bf(p2)
	await create_timer(1.5).timeout # spori save se završi
	var sacuvano: Dictionary = await _b_stub("Efekti2Lik")
	_provera("odjava_prekida_otrov", u6[1] is Array and hp_odj > 0 and not pad and bf_odj.is_empty() and int(sacuvano.get("hp", -1)) >= hp_odj,
		"otrov pre odjave %s, HP pri odjavi %d, pao tokom snimanja=%s, buffovi tokom snimanja %s, sačuvan HP %s" % [u6[1], hp_odj,
		pad, bf_odj, sacuvano.get("hp")])

	# --- VASKRSENJE (EfektiLik kod kuće; imunitet od antidota je još aktivan i mora da nestane sa ostalim)
	p1.server_postavi_poziciju(EF_DOM1, true)
	await create_timer(5.2).timeout # cooldown elixir_of_defense
	await _ef_posalji("EfektiLik", "pij elixir_of_defense")
	await _ef_posalji("EfektiLik", "pij resurrection_potion")
	await _cekaj(func(): return _ef_bf(p1).has("vaskrsenje") and _ef_bf(p1).has("oklop"), 2.0)
	await _cekaj(func(): return "Resurrection" in str(_ef_kl("EfektiLik").get("buff", "")), 1.0)
	hud["vaskrsenje"] = str(_ef_kl("EfektiLik").get("buff", ""))
	# drugi napitak vaskrsenja dok je aktivno: odbijen, ne troši se, trajanje ostaje; elixir_of_defense i dalje osvežava
	await create_timer(5.2).timeout # cooldown oba napitka
	var v_pre: Array = _ef_bf(p1).get("vaskrsenje", [0, 0])
	var o_pre: Array = _ef_bf(p1).get("oklop", [0, 0])
	var kom_pre := _komada(await _b_stub("EfektiLik"), "resurrection_potion")
	var odbijen := await _ef_posalji("EfektiLik", "pij resurrection_potion")
	var kom_posle := _komada(await _b_stub("EfektiLik"), "resurrection_potion")
	var v_posle: Array = _ef_bf(p1).get("vaskrsenje", [0, 0])
	await _ef_posalji("EfektiLik", "pij elixir_of_defense")
	await _cekaj(func(): return int(_ef_bf(p1).get("oklop", [0, 0])[1]) > 59000, 2.0)
	var o_posle: Array = _ef_bf(p1).get("oklop", [0, 0])
	_provera("vaskrsenje_aktivno_odbija", odbijen == "Already active" and kom_pre > 0 and kom_posle == kom_pre
		and v_pre[1] > 0 and v_posle[1] <= v_pre[1] and o_pre[1] < 56000 and o_posle[1] > 59000,
		"poruka '%s', u bazi %d -> %d, vaskrsenje preostalo %d -> %d ms, oklop osvežen %d -> %d ms" % [odbijen, kom_pre,
		kom_posle, v_pre[1], v_posle[1], o_pre[1], o_posle[1]])
	var bf_v := _ef_bf(p1)
	var poz: Vector3 = p1.global_position
	p1.server_primi_damage(1000000)
	var r1 := [p1.mrtav, p1.hp, _ef_bf(p1), p1.global_position.distance_to(poz)]
	p1.server_primi_damage(100) # u roku od 2 s: neosetljiv
	var hp_neos: int = p1.hp
	var kl_v: bool = await _cekaj(func(): return _ef_kl_prazno(), 2.0)
	_provera("vaskrsenje_presrece_udarac", bf_v.has("vaskrsenje") and int(bf_v["vaskrsenje"][0]) == 50 and int(bf_v["vaskrsenje"][1]) > 590000
		and bf_v.has("oklop") and bf_v.has("protivotrov") and r1[0] == false and r1[1] == p1.max_hp / 2 and (r1[2] as Dictionary).is_empty()
		and r1[3] < 0.05 and hp_neos == r1[1] and kl_v,
		"pre %s; posle smrtonosnog udarca mrtav=%s hp %d/%d buffovi %s pomeren %.2f m; udarac 100 u roku od 2 s: hp %d; klijent %s" % [
		bf_v, r1[0], r1[1], p1.max_hp, r1[2], r1[3], hp_neos, _ef_kl("EfektiLik")])

	# posle vaskrsenja buff-a nema: druga smrtonosna šteta je prava smrt i skida sve (oklop i otrov)
	await create_timer(5.2).timeout # neosetljivost i cooldown elixir_of_defense
	p1.server_postavi_poziciju(EF_PAUK + Vector3(-1, -0.84, 0), true)
	await create_timer(0.3).timeout
	await _ef_ujed(s, p1)
	await _ef_posalji("EfektiLik", "pij elixir_of_defense")
	await _cekaj(func(): return _ef_bf(p1).has("oklop"), 2.0)
	var bf_pre := _ef_bf(p1).keys()
	p1.server_primi_damage(1000000)
	var umro2: bool = p1.mrtav
	var bf_s2 := _ef_bf(p1)
	var kl_s2: bool = await _cekaj(func(): return _ef_kl_prazno(), 2.0)
	_provera("vaskrsenje_jednom", r1[0] == false and not bf_pre.has("vaskrsenje") and umro2,
		"prvi put živ=%s, buffovi pre drugog udarca %s, mrtav=%s" % [r1[0] == false, bf_pre, umro2])
	_provera("smrt_brise_sve_buffove", bf_pre.has("oklop") and bf_pre.has("otrov") and umro2 and bf_s2.is_empty() and kl_s2,
		"pre smrti %s, posle: server %s, klijent %s" % [bf_pre, bf_s2, _ef_kl("EfektiLik")])
	await _ef_umri_respawn(p1)

	# vaskrsenje presreće i smrt od otrova: otrov skinut, 50% HP, isto mesto
	await _ef_posalji("EfektiLik", "pij resurrection_potion")
	await _cekaj(func(): return _ef_bf(p1).has("vaskrsenje"), 2.0)
	p1.server_postavi_poziciju(EF_PAUK + Vector3(-1, -0.84, 0), true)
	await create_timer(0.3).timeout
	var u7 := await _ef_ujed(s, p1)
	poz = p1.global_position
	p1.hp = 2
	var otrov_tick: bool = await _cekaj(func(): return p1.hp == p1.max_hp / 2 or p1.mrtav, 2.0)
	var r3 := [p1.mrtav, p1.hp, _ef_bf(p1), p1.global_position.distance_to(poz)]
	await create_timer(1.5).timeout
	_provera("vaskrsenje_presrece_otrov", u7[1] is Array and otrov_tick and r3[0] == false and r3[1] == p1.max_hp / 2
		and (r3[2] as Dictionary).is_empty() and r3[3] < 0.05 and p1.hp >= r3[1],
		"otrov %s, posle tick-a na 2 HP: mrtav=%s hp %d/%d buffovi %s pomeren %.2f m, 1,5 s kasnije hp %d" % [u7[1], r3[0], r3[1],
		p1.max_hp, r3[2], r3[3], p1.hp])

	# HUD (dva reda: buff i debuff u BOJA_DEBUFF) i tooltip-ovi
	p1.server_postavi_poziciju(EF_DOM1, true)
	var boja := Color(1.0, 0.4, 0.35).to_html()
	_provera("efekti_hud_i_tooltip", hud.get("nevidljiv", "").begins_with("Invisible  0:") and hud.get("otrov", "").begins_with("Poisoned -3 HP/s  0:0")
		and hud.get("otrov_boja", "") == boja and hud.get("imunitet", "").begins_with("Poison immunity  0:")
		and (hud.get("vaskrsenje", "").ends_with("Resurrection 50% HP  10:00") or hud.get("vaskrsenje", "").ends_with("Resurrection 50% HP  9:59"))
		and "Click: Invisible for 20 s  |  cooldown 60 s" in tt[0] and "Click: Resurrection 50% HP for 600 s  |  cooldown 5 s" in tt[1]
		,
		"HUD %s (debuff boja %s), tooltip %s" % [hud, boja, tt])
	_provera("antidote_tooltip_jedan_red", tt[2].count("Click:") == 1 and "Click: +20 HP  Poison immunity for 30 s  |  cooldown 5 s" in tt[2],
		"tooltip antidota '%s'" % tt[2])
	_pisi("efekti_gotov", "1")
