extends CharacterBody3D

enum InteractionType { DIALOGUE, MERCHANT, QUEST_GIVER, TRAINER }

@export var npc_name: String = "NPC"
@export var interaction_type: InteractionType = InteractionType.DIALOGUE
@export_multiline var dialogue_lines: Array[String] = ["Pozdrav, putniče!"]
@export var quest_id: String = ""  # pocetak lanca za QUEST_GIVER
@export var portret: Texture2D = null

@onready var label: Label3D = $Label3D

var prompt: Label3D
var player_in_range: bool = false
var current_player: Node3D = null

func _ready() -> void:
	label.text = npc_name

	prompt = Label3D.new()
	prompt.text = "[F] Razgovor"
	prompt.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	prompt.no_depth_test = true
	prompt.fixed_size = true
	prompt.pixel_size = 0.0008
	prompt.modulate = Color(1.0, 0.85, 0.3)
	prompt.position = Vector3(0, 2.6, 0)
	prompt.visible = false
	add_child(prompt)

	var area: Area3D = $Area3D
	area.body_entered.connect(_on_body_entered)
	area.body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player"):
		player_in_range = true
		current_player = body
		prompt.visible = true
		_update_prompt_text()
		if interaction_type == InteractionType.QUEST_GIVER:
			await _sinhronizuj_lanac()
			_update_prompt_text()

func _on_body_exited(body: Node3D) -> void:
	if body.is_in_group("player"):
		player_in_range = false
		current_player = null
		prompt.visible = false

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("interact"):
		if player_in_range and not DialogueUI._active and not MerchantUI._active:
			interact()

func _update_prompt_text() -> void:
	match interaction_type:
		InteractionType.MERCHANT:
			prompt.text = "[F] Prodavnica"
		InteractionType.QUEST_GIVER:
			if _ovaj_quest_je_aktivan() and QuestManager.je_quest_zavrsen():
				prompt.text = "[F] Predaj zadatak"
			else:
				prompt.text = "[F] Zadatak"
		InteractionType.TRAINER:
			prompt.text = "[F] Trening"
		_:
			prompt.text = "[F] Razgovor"

func interact() -> void:
	if not player_in_range:
		return
	match interaction_type:
		InteractionType.DIALOGUE:
			DialogueUI.open(npc_name, dialogue_lines, portret)
		InteractionType.MERCHANT:
			MerchantUI.open(npc_name)
		InteractionType.QUEST_GIVER:
			await _handle_quest_giver()
		InteractionType.TRAINER:
			DialogueUI.open(npc_name, ["Spreman za trening?", "(Trener sistem dolazi kasnije)"], portret)

# ---------------------------------------------------------------- QUEST GIVER

func _safe_str(v) -> String:
	if v == null:
		return ""
	return str(v)

func _ovaj_quest_je_aktivan() -> bool:
	return quest_id != "" and QuestManager.ima_aktivan_quest() \
		and str(QuestManager.aktivni_quest.get("id", "")) == quest_id

# Prati lanac od quest_id preko sledeci_quest dok ne nadje prvi nezavrsen.
# Vraca "" ako je ceo lanac zavrsen.
func _razresi_lanac(start_id: String) -> String:
	var id = start_id
	var guard = 0
	while id != "" and QuestManager.je_quest_vec_zavrsen(id) and guard < 20:
		var q: Dictionary = await ApiManager.get_quest(id)
		if q.is_empty() or q.has("error"):
			return ""
		id = _safe_str(q.get("sledeci_quest"))
		guard += 1
	return id

# Pomeri quest_id na prvi nezavrsen quest u lancu (ako takav postoji)
func _sinhronizuj_lanac() -> void:
	if quest_id == "":
		return
	var sledeci = await _razresi_lanac(quest_id)
	if sledeci != "":
		quest_id = sledeci

func _handle_quest_giver() -> void:
	if quest_id == "":
		DialogueUI.open(npc_name, ["Nemam trenutno zadatak za tebe."], portret)
		return

	await _sinhronizuj_lanac()

	# Igrac ima aktivan bas ovaj quest
	if _ovaj_quest_je_aktivan():
		if QuestManager.je_quest_zavrsen():
			var quest = QuestManager.aktivni_quest
			DialogueUI.open_quest_turnin(npc_name, quest, func():
				var nagrada = await QuestManager.predaj_quest()
				_isplati_nagradu(nagrada)
				await _ponudi_sledeci(nagrada)
			, portret)
		else:
			DialogueUI.open(npc_name, [
				"Još nisi završio zadatak.",
				"Progres: %d/%d" % [QuestManager.progres, QuestManager.aktivni_quest.get("kolicina", 1)]
			], portret)
		return

	# Igrac ima neki drugi aktivan quest
	if QuestManager.ima_aktivan_quest():
		DialogueUI.open(npc_name, ["Prvo završi zadatak koji već imaš."], portret)
		return

	# Ceo lanac zavrsen
	if QuestManager.je_quest_vec_zavrsen(quest_id):
		DialogueUI.open(npc_name, ["Već si mi pomogao oko svega. Hvala ti."], portret)
		return

	# Ponudi quest
	var quest: Dictionary = await ApiManager.get_quest(quest_id)
	if quest.is_empty() or quest.has("error"):
		DialogueUI.open(npc_name, ["Nemam trenutno zadatak za tebe."], portret)
		return

	DialogueUI.open_quest_offer(npc_name, quest,
		func(): QuestManager.prihvati_quest(quest),
		func(): pass,
		portret
	)

func _isplati_nagradu(quest: Dictionary) -> void:
	var hud = get_tree().get_first_node_in_group("hud")
	if hud:
		hud.dodaj_gold(int(quest.get("nagrada_gold", 0)))
		hud.dodaj_xp(int(quest.get("nagrada_xp", 0)))
	var item_id = _safe_str(quest.get("nagrada_item"))
	if item_id != "":
		var inventory = get_tree().get_first_node_in_group("inventory")
		if inventory:
			inventory.dodaj_item_u_slot(item_id)

func _ponudi_sledeci(zavrsen_quest: Dictionary) -> void:
	var sledeci_id = _safe_str(zavrsen_quest.get("sledeci_quest"))
	if sledeci_id == "":
		return
	sledeci_id = await _razresi_lanac(sledeci_id)
	if sledeci_id == "":
		return
	quest_id = sledeci_id
	var sledeci: Dictionary = await ApiManager.get_quest(sledeci_id)
	if sledeci.is_empty() or sledeci.has("error"):
		return
	DialogueUI.open_quest_offer(npc_name, sledeci,
		func(): QuestManager.prihvati_quest(sledeci),
		func(): pass,
		portret
	)
