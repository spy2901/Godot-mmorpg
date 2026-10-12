extends Node

const CONFIG_PATH = "user://settings.cfg"

var ime_igraca: String = ""      # ime_lika iz login odgovora
var token: String = ""           # samo u memoriji, nikad u settings.cfg
var korisnicko_ime: String = ""  # pamti se samo za popunjavanje polja na loginu
var poruka_logina: String = ""   # poruka za login ekran (npr. posle odbijene registracije)

func _ready() -> void:
	_ucitaj()

func prijavi(odgovor: Dictionary) -> void:
	token = str(odgovor.get("token", ""))
	ime_igraca = str(odgovor.get("ime_lika", ""))
	korisnicko_ime = str(odgovor.get("username", korisnicko_ime))
	_sacuvaj()

func odjava() -> void:
	if token != "":
		ApiManager.logout(token)  # ne čekamo odgovor
	token = ""
	ime_igraca = ""

func _sacuvaj() -> void:
	var cfg = ConfigFile.new()
	cfg.set_value("igrac", "ime", korisnicko_ime)
	cfg.save(CONFIG_PATH)

func _ucitaj() -> void:
	var cfg = ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		korisnicko_ime = str(cfg.get_value("igrac", "ime", ""))
