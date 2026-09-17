extends Area3D

@export var ime_itema = "skeleton_rib"  # ID iz baze

@onready var label = $Label3D

func _ready():
    body_entered.connect(_on_body_entered)
    
    # Dohvati pravo ime iz baze
    _ucitaj_ime()

func _ucitaj_ime():
    var item = await ApiManager.get_item(ime_itema)
    if not item.is_empty():
        label.text = item.get("ime", ime_itema)  # Prikazi pravo ime
    else:
        label.text = ime_itema  # Fallback na ID
    
    label.position = Vector3(0, 1.0, 0)
    label.billboard = BaseMaterial3D.BILLBOARD_ENABLED

func _on_body_entered(body):
    if body.is_in_group("player"):
        var hud = get_tree().get_first_node_in_group("hud")
        if hud:
            hud.dodaj_item(ime_itema)
            QuestManager.azuriraj_progres_fetch(ime_itema)
        queue_free()