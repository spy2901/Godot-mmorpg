extends CharacterBody3D

# ENEMY BASE CLASS 


#ENEMY DEFAULT STATS - MOZE SE PREKORACITI U NASLEDJENIM KLASAMA
@export var ime = "Neprijatelj"
@export var hp = 100
@export var max_hp = 100
@export var brzina = 2.0
@export var napad_damage = 10
@export var aggro_range = 10.0
@export var napad_range = 2.0
@export var xp_nagrada = 50
@export var napad_cooldown = 2.0
@export var loot_tabela = [
    {"id": "goblin_ear", "sansa": 100},   # 100% sansa
    {"id": "iron_ore", "sansa": 50},       # 50% sansa
    {"id": "bronze_coin", "sansa": 75},    # 75% sansa
    {"id": "rusty_sword", "sansa": 10}     # 10% sansa
]  # Svaki tip neprijatelja dropa drugaciji item
@export var moze_napasti = true

#ENEMY UI SETTINGS
@onready var ime_label = $ImeLabel
@onready var hp_label = $HpLabel
@export var tip_neprijatelja: String = ""  # ID za questove, npr. "goblin" — mora da se poklapa sa quests.cilj
@onready var player = get_tree().get_first_node_in_group("player")

func _ready():
	add_to_group("neprijatelj")
	ime_label.text = ime
	ime_label.position = Vector3(0, 2.2, 0)
	hp_label.text = str(hp) + "/" + str(max_hp)
	hp_label.position = Vector3(0, 2.0, 0)
	# Billboard - uvek gleda prema kameri
	ime_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED

func _physics_process(delta):
	var distanca = global_position.distance_to(player.global_position)
	
	# Gravitacija
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	
	if distanca <= aggro_range:
		# Primeti igraca - krece da juri
		var smer = (player.global_position - global_position).normalized()
		
		if distanca > napad_range:
			# Juri igraca
			velocity.x = smer.x * brzina
			velocity.z = smer.z * brzina
		else:
			# Dostigao igraca - napada
			velocity.x = 0
			velocity.z = 0
			if moze_napasti:
				napadni_igraca()
	else:
		# Igrac je daleko - stoji mirno
		velocity.x = 0
		velocity.z = 0
	
	move_and_slide()

func primi_damage(kolicina):
	hp -= kolicina
	hp = max(hp, 0)
	hp_label.text = str(hp) + "/" + str(max_hp)
	if hp == 0:
		var quest_tip = tip_neprijatelja if tip_neprijatelja != "" else ime.to_lower()
		QuestManager.azuriraj_progres_kill(quest_tip)
		# Loot drop
		for loot in loot_tabela:
			var roll = randi() % 100 + 1  # Random broj 1-100
			if roll <= loot["sansa"]:
				var item_scena = load("res://Scenes/Items/item.tscn")
				var item = item_scena.instantiate()
				item.ime_itema = loot["id"]
				get_tree().root.add_child(item)
				# Svaki item malo pomeracen da se ne preklapaju
				item.global_position = global_position + Vector3(
					randf_range(-1.0, 1.0),
					0.5,
					randf_range(-1.0, 1.0)
				)
		# Daj XP igracu
		var hud = get_tree().get_first_node_in_group("hud")
		if hud:
			hud.dodaj_xp(xp_nagrada)
		queue_free()

func napadni_igraca():
	moze_napasti = false
	# Skini HP igracu
	var hud = get_tree().get_first_node_in_group("hud")
	if hud:
		hud.primi_damage(napad_damage)
	
	await get_tree().create_timer(napad_cooldown).timeout
	moze_napasti = true
