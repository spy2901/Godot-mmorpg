#!/usr/bin/env python3
"""Lažni backend za run-mmorpg testove (samo stdlib, stanje u memoriji).

Pokretanje: python3 stub_api.py PORT   (run.sh ga podiže i prosleđuje --server-url)
Pokriva samo rute koje game server/klijent zovu u testu. Token "potion-token" -> lik "TestLik".
Nepoznata ruta: 404 {"error": ...} i linija u stderr (vidi se u $OUT/stub.log).
"""
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# XP kriva i statistike po nivou iz pravog backend-a (napredak.py nema zavisnosti), ne kopija
sys.path.insert(0, os.environ.get("BACKEND_DIR", os.path.expanduser("~/mmorpg-server")))
from napredak import primeni_xp, statistike_za_nivo  # noqa: E402

ITEM_USE_KASNJENJE = 0.3  # s: da se dva istovremena zahteva preklope

def _prebroj(inv, eq):
    c = {}
    for e in inv:
        c[e["id"]] = c.get(e["id"], 0) + int(e.get("kolicina", 1))
    for x in eq.values():
        if x:
            c[x] = c.get(x, 0) + 1
    return c


# kao backend routers/players.py _validan_raspored: int slot (0-23, bez ponavljanja) i kolicina >= 1, slotovi opreme
SLOTOVI_OPREME = {"head", "chest", "legs", "boots", "weapon", "shield"}


def _je_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _validan_raspored(inv, eq, db_inv, db_eq):
    return _razlog_odbijanja(inv, eq, db_inv, db_eq) == ""


# "" = prihvaćen; "format" = tipovi/slotovi (kvar game servera), "broj komada" = raspored se mimoišao sa izmenom
# na serveru (loot, kupovina, napitak), backend tada namerno zadrži stanje iz baze
def _razlog_odbijanja(inv, eq, db_inv, db_eq):
    los = _los_format(inv, eq)
    if los:
        return f"format: {los}"
    return "" if _prebroj(inv, eq) == _prebroj(db_inv, db_eq) else "broj komada"


def _los_format(inv, eq):  # "" = ispravan, inače prvi neispravan deo
    if not isinstance(inv, list) or not isinstance(eq, dict):
        return "tip inventory/equipment"
    slotovi = set()
    for e in inv:
        if not isinstance(e, dict) or not isinstance(e.get("id"), str) \
                or not _je_int(e.get("kolicina")) or e["kolicina"] < 1 \
                or not _je_int(e.get("slot")) or not 0 <= e["slot"] < 24 or e["slot"] in slotovi:
            return json.dumps(e)
        slotovi.add(e["slot"])
    los = [k for k, v in eq.items() if k not in SLOTOVI_OPREME or not (v is None or isinstance(v, str))]
    return f"equipment {los}" if los else ""


def _item(id, ime, tip, **x):
    d = {"id": id, "ime": ime, "tip": tip, "ikonica": "?", "vrednost": 1, "quest_item": 0, "stackable": 1,
         "max_stack": 20, "damage": 0, "armor": 0, "hp_bonus": 0, "slot": None, "hp_efekat": 0, "mana_efekat": 0, "cooldown_ms": 0,
         "buff_tip": None, "buff_vrednost": 0, "buff_trajanje_ms": 0}
    d.update(x)
    return d

ITEMS = {i["id"]: i for i in [
    _item("small_health_potion", "Small Health Potion", "consumable", hp_efekat=30, cooldown_ms=5000),
    _item("medium_health_potion", "Medium Health Potion", "consumable", hp_efekat=80, cooldown_ms=7000),
    _item("large_health_potion", "Large Health Potion", "consumable", hp_efekat=150, cooldown_ms=10000),
    _item("mana_potion", "Mana Potion", "consumable", mana_efekat=50, cooldown_ms=5000),
    _item("apple", "Apple", "consumable", hp_efekat=10, cooldown_ms=5000),
    _item("iron_sword", "Iron Sword", "weapon", stackable=0, max_stack=1, damage=25, slot="weapon", vrednost=20),
    # oprema kao u bazi posle migracije 007 (attack = damage, armor, hp_bonus, slot; iron_gloves bez slota)
    _item("golden_sword", "Golden Sword", "weapon", stackable=0, max_stack=1, damage=40, slot="weapon"),
    _item("iron_helmet", "Iron Helmet", "armor", stackable=0, max_stack=1, armor=10, slot="head"),
    _item("iron_chestplate", "Iron Chestplate", "armor", stackable=0, max_stack=1, armor=20, slot="chest"),
    _item("iron_leggings", "Iron Leggings", "armor", stackable=0, max_stack=1, armor=12, slot="legs"),
    _item("iron_boots", "Iron Boots", "armor", stackable=0, max_stack=1, armor=6, slot="boots"),
    _item("steel_shield", "Steel Shield", "armor", stackable=0, max_stack=1, armor=20, hp_bonus=10, slot="shield"),
    _item("dragon_scale_armor", "Dragon Scale Armor", "armor", stackable=0, max_stack=1, armor=35, hp_bonus=50,
          slot="chest"),
    _item("iron_gloves", "Iron Gloves", "armor", stackable=0, max_stack=1, armor=5, vrednost=30),
    # loot neprijatelja iz scena (kao u bazi); najbolja oprema je u bazi quest_item (van prodavnice)
    *[_item(i, i.replace("_", " ").title(), "material") for i in (
        "goblin_ear", "bronze_coin", "leather_scrap", "skeleton_rib", "iron_ore", "silver_coin", "troll_tooth",
        "gold_coin", "steel_ingot")],
    _item("iron_dagger", "Iron Dagger", "weapon", stackable=0, max_stack=1, damage=10, slot="weapon", vrednost=15),
    _item("war_hammer", "War Hammer", "weapon", stackable=0, max_stack=1, damage=30, slot="weapon", vrednost=70),
    _item("dragon_staff", "Dragon Staff", "weapon", stackable=0, max_stack=1, damage=50, slot="weapon", quest_item=1),
    _item("golden_helmet", "Golden Helmet", "armor", stackable=0, max_stack=1, armor=15, hp_bonus=20, slot="head",
          quest_item=1),
    _item("shadow_cloak", "Shadow Cloak", "armor", stackable=0, max_stack=1, armor=8, hp_bonus=15, slot="chest",
          quest_item=1),
    _item("shadow_dagger", "Shadow Dagger", "weapon", stackable=0, max_stack=1, damage=40, slot="weapon", quest_item=1),
    # migracija 009: materijali zone 2 i 9 predmeta za legs/boots/shield (T1 u prodavnici, T3/T4 van nje)
    *[_item(i, i.replace("_", " ").title(), "material") for i in (
        "wolf_pelt", "feather", "spider_web", "poison_gland", "herb_bundle", "shadow_fragment", "magic_dust", "crystal_shard")],
    *[_item(i, ime, "armor", stackable=0, max_stack=1, slot=slot, armor=a, hp_bonus=h, vrednost=v) for i, ime, slot, a, h, v in (
        ("cloth_trousers", "Cloth Trousers", "legs", 2, 0, 6), ("leather_pants", "Leather Pants", "legs", 6, 0, 18),
        ("steel_greaves", "Steel Greaves", "legs", 18, 10, 90), ("dragonscale_leggings", "Dragonscale Leggings", "legs", 26, 30, 450),
        ("steel_sabatons", "Steel Sabatons", "boots", 10, 5, 70), ("shadow_boots", "Shadow Boots", "boots", 14, 15, 280),
        ("wooden_shield", "Wooden Shield", "shield", 6, 0, 10), ("tower_shield", "Tower Shield", "shield", 28, 20, 120),
        ("dragon_shield", "Dragon Shield", "shield", 36, 40, 520))],
    # ostalo oružje iz baze (damage, vrednost kao na Pi-ju): ponuda oružja u prodavnici
    *[_item(i, ime, "weapon", stackable=0, max_stack=1, slot="weapon", damage=dmg, vrednost=v) for i, ime, dmg, v in (
        ("apprentice_staff", "Apprentice Staff", 12, 30), ("arcane_staff", "Arcane Staff", 45, 80),
        ("battle_axe", "Battle Axe", 30, 60), ("crossbow", "Crossbow", 20, 45), ("hunters_bow", "Hunters Bow", 20, 25),
        ("oak_bow", "Oak Bow", 15, 15), ("rusty_sword", "Rusty Sword", 10, 5), ("spear", "Spear", 15, 35),
        ("steel_longsword", "Steel Longsword", 35, 50))],
    _item("stamina_potion", "Stamina Potion", "consumable", mana_efekat=40, cooldown_ms=5000),
    _item("antidote", "Antidote", "consumable", hp_efekat=20, cooldown_ms=5000),
    # migracija 010: buffovi (vrednost kao na Pi-ju; elixir_of_luck više nije quest_item), cooldown 5 s
    *[_item(i, ime, "consumable", vrednost=v, cooldown_ms=5000, buff_tip=bt, buff_vrednost=bv, buff_trajanje_ms=bms)
      for i, ime, v, bt, bv, bms in (
        ("elixir_of_strength", "Elixir of Strength", 100, "napad", 20, 60000),
        ("elixir_of_defense", "Elixir of Defense", 100, "oklop", 30, 60000),
        ("elixir_of_wisdom", "Elixir of Wisdom", 100, "xp", 25, 300000),
        ("elixir_of_luck", "Elixir of Luck", 200, "loot", 50, 300000),
        ("speed_potion", "Speed Potion", 30, "brzina", 30, 20000))],
    # samo u testu (nije u bazi): napad +20% 2 s, za istek buff-a
    _item("test_kratki_eliksir", "Test Short Elixir", "consumable", vrednost=0, cooldown_ms=5000, buff_tip="napad",
          buff_vrednost=20, buff_trajanje_ms=2000),
    # samo u testu: brzina +30% 1,5 s, cooldown 1 s (ivice buff-a brzine pod veštačkim RTT-om, bez čekanja 20 s)
    _item("test_kratki_speed", "Test Short Speed", "consumable", vrednost=0, cooldown_ms=1000, buff_tip="brzina",
          buff_vrednost=30, buff_trajanje_ms=1500),
]}
for _i in ("golden_sword", "dragon_scale_armor"):
    ITEMS[_i]["quest_item"] = 1

# Questovi kao u bazi (GET /quests sa Pi-ja, 2026-10-18) posle migracije 009; lanci skupljac_oruzja -> goblin_killer ->
# skeleton_hunter -> troll_slayer, kosti_za_supu -> lek_od_otrova -> prah_za_napitke, vucja_krzna -> svila_za_krojaca ->
# senke_u_sumi -> kraj_utvara (i q2 -> kraj_utvara). Rute accept/kill/turnin/abandon prate routers/players.py.
def _q(id, naziv, tip, cilj, kolicina, xp, gold, item=None, sledeci=None, opis="..."):
    return {"id": id, "naziv": naziv, "opis": opis, "tip": tip, "cilj": cilj, "kolicina": kolicina, "nagrada_gold": gold,
            "nagrada_xp": xp, "nagrada_item": item, "sledeci_quest": sledeci}

QUESTS = {q["id"]: q for q in [
    _q("goblin_killer", "Goblin Trouble", "kill", "goblin", 5, 100, 50, sledeci="skeleton_hunter"),
    _q("kosti_za_supu", "Bones for Soup", "fetch", "skeleton_rib", 5, 80, 40, sledeci="lek_od_otrova"),
    _q("q2", "Goblin Ears", "fetch", "goblin_ear", 5, 150, 80, item="iron_sword", sledeci="kraj_utvara"),
    _q("skeleton_hunter", "Rise of the Dead", "kill", "skeleton", 5, 150, 75, item="iron_sword", sledeci="troll_slayer"),
    _q("skupljac_oruzja", "Weapon Collector", "fetch", "iron_sword", 2, 120, 100, sledeci="goblin_killer"),
    _q("troll_slayer", "Troll Hunt", "kill", "troll", 3, 300, 150),
    _q("vucja_krzna", "Wolf Pelts", "fetch", "wolf_pelt", 6, 1200, 150, sledeci="svila_za_krojaca"),
    _q("svila_za_krojaca", "Silk for the Tailor", "fetch", "spider_web", 8, 1500, 200, item="steel_sabatons", sledeci="senke_u_sumi"),
    _q("senke_u_sumi", "Shadows in the Forest", "kill", "wraith", 8, 2500, 300, item="tower_shield", sledeci="kraj_utvara"),
    _q("kraj_utvara", "The End of the Wraiths", "kill", "wraith", 3, 3000, 500, item="dragon_shield"),
    _q("lek_od_otrova", "A Cure for Venom", "fetch", "poison_gland", 4, 1400, 150, item="antidote", sledeci="prah_za_napitke"),
    _q("prah_za_napitke", "Dust for Potions", "fetch", "magic_dust", 5, 2200, 250),
]}
ZAVRSENI = {}  # ime -> [quest_id]


def _dodaj(inv, id, n):  # kao inventory_utils: stack do max_stack, nestackable po jedan
    it = ITEMS[id]
    for _ in range(n):
        e = next((e for e in inv if e["id"] == id and it["stackable"] and e["kolicina"] < it["max_stack"]), None)
        if e:
            e["kolicina"] += 1
        else:
            inv.append({"slot": max([e["slot"] for e in inv], default=-1) + 1, "id": id, "kolicina": 1})


def _ukloni(inv, id, n):
    if sum(e["kolicina"] for e in inv if e["id"] == id) < n:
        return False
    for e in [e for e in inv if e["id"] == id]:
        k = min(n, e["kolicina"])
        e["kolicina"] -= k
        n -= k
        if e["kolicina"] == 0:
            inv.remove(e)
    return True


def _upisi_xp(pl, delta):  # kao backend _upisi_xp
    s = primeni_xp(pl, delta)
    pl.update({k: s[k] for k in ("level", "xp", "max_xp", "max_hp", "max_mana", "napad_damage")})
    if s["level_up"]:
        pl["hp"] = s["max_hp"] + sum(ITEMS[i]["hp_bonus"] for i in pl["equipment"].values() if i in ITEMS)
        pl["mana"] = s["max_mana"]
    pl.setdefault("xp_dnevnik", []).append(delta)  # test: XP po ubistvu (razlika nivoa)
    return s

PLAYERS = {"TestLik": {
    "ime": "TestLik", "level": 1, "xp": 0, "max_xp": 100, "gold": 100, "napad_damage": 25,
    "hp": 50, "max_hp": 100, "mana": 100, "max_mana": 100, "pos_x": 9, "pos_y": 1, "pos_z": -7,  # van putanje movera, van aggro dometa
    "aktivni_quest_id": None, "quest_progres": 0, "equipment": {}, "action_bar": None,
    "inventory": [
        {"slot": 0, "id": "small_health_potion", "kolicina": 3},
        {"slot": 1, "id": "large_health_potion", "kolicina": 1},
        {"slot": 2, "id": "medium_health_potion", "kolicina": 3},
        {"slot": 3, "id": "iron_sword", "kolicina": 1},
        {"slot": 4, "id": "apple", "kolicina": 2},
    ],
}}
# mover/observer: lik bez pozicije u bazi (0,0,0) -> ostaje na spawn tački; server ga objavi ostalima tek
# posle učitavanja. Veliki HP: neprijatelji mogu da ga napadnu, a smrt (respawn) bi pomerila merenja.
# MoverLik je nov (0,0,0 = bez pozicije, nasumičan spawn); ObserverLik ima svoju poziciju van putanje movera
# (mover ide x -9..6, z -12..16): na (4, 0) mu je mover u speedhack fazi udarao u leđa (speedhack_max_1.2x 0.42x),
# a na spawn-u bi se stvorili jedan na drugom. Odavde TestLik (9, -7) ostaje ispred kamere (screenshot --window).
# Svi pomoćni likovi imaju fiksnu poziciju van putanje movera (x -9..6, z -12..16) i bar 5 m jedan od drugog (domet
# napada 3.5 m): TestLik (9, -7), ObserverLik (11, 4), RasporedLik (-14, -5), CiljLik (-20, -20), DrugiLik (-15, -16).
# visi se nikad ne učita iz baze; server drajver ga skloni na (14, -14) (VISI_PARKING u driver.gd).
for _ime, _poz in (("MoverLik", (0, 0, 0)), ("ObserverLik", (11, 1.16, 4))):
    PLAYERS[_ime] = dict(PLAYERS["TestLik"], ime=_ime, hp=100000, max_hp=100000,
                         pos_x=_poz[0], pos_y=_poz[1], pos_z=_poz[2], inventory=[])
# ObserverLik ima nekoliko potrošnih predmeta: action bar na screenshot-u (--window) nije prazan
PLAYERS["ObserverLik"]["inventory"] = [
    {"slot": 0, "id": "small_health_potion", "kolicina": 5},
    {"slot": 1, "id": "mana_potion", "kolicina": 2},
    {"slot": 2, "id": "apple", "kolicina": 1},
]
# RasporedLik: raspored action bara posle ponovne prijave (uloga raspored, korak 1 pa korak 2)
PLAYERS["RasporedLik"] = dict(PLAYERS["TestLik"], ime="RasporedLik", pos_x=-14, pos_z=-5, inventory=[
    {"slot": 0, "id": "small_health_potion", "kolicina": 2},
    {"slot": 1, "id": "iron_sword", "kolicina": 1},
    {"slot": 2, "id": "apple", "kolicina": 1},
    {"slot": 3, "id": "mana_potion", "kolicina": 1},
])
# CiljLik: ciljanje (uloga cilj), u uglu mape da test neprijatelji ne smetaju ostalima
PLAYERS["CiljLik"] = dict(PLAYERS["TestLik"], ime="CiljLik", pos_x=-20, pos_y=1.16, pos_z=-20, inventory=[])
# DrugiLik: drugi igrač pored CiljLik-ovog cilja (napad bez sopstvenog cilja)
PLAYERS["DrugiLik"] = dict(PLAYERS["TestLik"], ime="DrugiLik", pos_x=-15, pos_y=1.16, pos_z=-16, inventory=[])
# AiLik / Ai2Lik: AI neprijatelja (uloga ai, server vodi scenario oko test goblina na (20, 20), aggro 5 m): oba van
# aggro-a na početku (6.3 m i 7.2 m), u uglu van putanje movera i ostalih likova. HP 1000: goblin ih udara tokom testa.
for _ime, _poz in (("AiLik", (14, 22)), ("Ai2Lik", (24, 14))):
    PLAYERS[_ime] = dict(PLAYERS["TestLik"], ime=_ime, hp=1000, max_hp=1000, pos_x=_poz[0], pos_y=1.16, pos_z=_poz[1],
                         inventory=[])
# OpremaLik: oprema i statistike (uloga oprema, korak 1 pa korak 2 = ponovna prijava); osnovno attack 25, max HP 100.
# Oprema2Lik (korak 3): drugi igrač koji pokušava da opremi tuđi predmet. Obojica van putanje movera i ostalih.
PLAYERS["OpremaLik"] = dict(PLAYERS["TestLik"], ime="OpremaLik", hp=100, max_hp=100, pos_x=-20, pos_y=1.16, pos_z=10,
                            equipment={}, inventory=[{"slot": i, "id": x, "kolicina": 1} for i, x in enumerate(
                                ["iron_sword", "iron_helmet", "iron_chestplate", "iron_leggings", "iron_boots",
                                 "steel_shield", "dragon_scale_armor", "iron_gloves"])])
# Oprema2Lik ima HP 50/1000 (regeneracija nikad ne stane), a stub njegov /save drži SPORI_SAVE s: posle njegove odjave
# server snima dok mu regeneracija otkucava (server_ne_salje_hp_odjavljenom).
PLAYERS["Oprema2Lik"] = dict(PLAYERS["TestLik"], ime="Oprema2Lik", hp=50, max_hp=1000, pos_x=-20, pos_y=1.16, pos_z=16,
                             inventory=[])
SPORI_SAVE = {"Oprema2Lik": 2.5}
# NapredakLik: napredak kroz nivoe (uloga napredak, korak 1 pa korak 2 = ponovna prijava). Nivo 1 po novoj krivi,
# ranjen (HP 40, mana 30) da se vidi punjenje na level-up, sa steel_shield (+10 max HP). U uglu van ostalih likova.
PLAYERS["NapredakLik"] = dict(PLAYERS["TestLik"], ime="NapredakLik", napad_damage=10, hp=40, max_hp=100, mana=30,
                              pos_x=22, pos_y=1.16, pos_z=0, equipment={"shield": "steel_shield"}, inventory=[])
# /xp/change samo za ove likove: ostali test likovi imaju veštački HP (1000, 100000) koji bi statistike iz nivoa
# prepisale, a njihovi scenariji ubijaju neprijatelje (do sada je /xp/change bio nepoznata ruta)
# QuestLik: quest NPC-ovi u svetu (uloga quest, korak 1): nivo 1, dva mača za skupljac_oruzja, 1.1 m ispred Village
# Elder-a (-11, -9), u dometu njegove sfere, gleda ka njemu (-z, podrazumevano). PosmatracLik (korak 2): pored, sa aktivnim goblin_killer; ne napada (bez loot-a i
# kill credit-a), pa nivo 12 za XP prema razlici nivoa (bez level-upa u toku testa).
PLAYERS["QuestLik"] = dict(PLAYERS["TestLik"], ime="QuestLik", napad_damage=10, hp=100, max_hp=100, gold=100,
                           pos_x=-11, pos_y=1.16, pos_z=-7.9, inventory=[{"slot": 0, "id": "iron_sword", "kolicina": 1},
                                                                         {"slot": 1, "id": "iron_sword", "kolicina": 1}])
_s12 = statistike_za_nivo(12)
PLAYERS["PosmatracLik"] = dict(PLAYERS["TestLik"], ime="PosmatracLik", level=12, xp=0, max_xp=_s12["max_xp"],
                               max_hp=_s12["max_hp"], hp=_s12["max_hp"], max_mana=_s12["max_mana"],
                               mana=_s12["max_mana"], napad_damage=_s12["napad_damage"], pos_x=-14, pos_y=1.16,
                               pos_z=-12, aktivni_quest_id="goblin_killer", quest_progres=0, inventory=[])
# LovacLik (uloga quest, korak 3): nivo 1 sa 6 vučjih krzna, 1.1 m ispred Hunter-a (29, 0) u zoni 2, gleda ka njemu (-z)
PLAYERS["LovacLik"] = dict(PLAYERS["TestLik"], ime="LovacLik", napad_damage=10, hp=100, max_hp=100, gold=100,
                           pos_x=29, pos_y=1.16, pos_z=1.1, inventory=[{"slot": 0, "id": "wolf_pelt", "kolicina": 6}])
# BuffLik (uloga buff, korak 1): nivo 1 (napad 10 + iron_sword 25 = 35), oklop 68 kao OpremaLik (25 štete -> 14), eliksiri.
# Buff2Lik (korak 2): nivo 1 bez buff-a, udara isti cilj (wisdom i luck se računaju po napadaču). Van ostalih likova.
_OKLOP_68 = {"weapon": "iron_sword", "head": "iron_helmet", "chest": "iron_chestplate", "legs": "iron_leggings",
             "boots": "iron_boots", "shield": "steel_shield"}
PLAYERS["BuffLik"] = dict(PLAYERS["TestLik"], ime="BuffLik", napad_damage=10, hp=110, max_hp=100, pos_x=-22, pos_y=1.16,
                          pos_z=-2, equipment=dict(_OKLOP_68), inventory=[
                              {"slot": 0, "id": "elixir_of_strength", "kolicina": 3},
                              {"slot": 1, "id": "elixir_of_defense", "kolicina": 1},
                              {"slot": 2, "id": "elixir_of_wisdom", "kolicina": 1},
                              {"slot": 3, "id": "elixir_of_luck", "kolicina": 1},
                              {"slot": 4, "id": "test_kratki_eliksir", "kolicina": 1},
                              {"slot": 5, "id": "speed_potion", "kolicina": 1}])
PLAYERS["Buff2Lik"] = dict(PLAYERS["TestLik"], ime="Buff2Lik", napad_damage=10, hp=100, max_hp=100, pos_x=-22, pos_y=1.16,
                           pos_z=3, equipment={}, inventory=[])
# BrzinaLik (uloga brzina): hoda na otvorenom u zoni 2 (x 48..62, z -20; pod do x 75 i z -25), van ostalih likova
PLAYERS["BrzinaLik"] = dict(PLAYERS["TestLik"], ime="BrzinaLik", hp=100, max_hp=100, pos_x=45, pos_y=1.16, pos_z=-20,
                            equipment={}, inventory=[{"slot": 0, "id": "test_kratki_speed", "kolicina": 10},
                                                     {"slot": 1, "id": "speed_potion", "kolicina": 2}])
BEZ_ITEM_KASNJENJA = {"BrzinaLik"}  # kašnjenje početka buff-a brzine se meri bez veštačkih 0,3 s backend-a
XP_LIKOVI = {"NapredakLik", "QuestLik", "PosmatracLik", "LovacLik", "BuffLik", "Buff2Lik"}
TOKENI = {"napredak-token": "NapredakLik", "oprema-token": "OpremaLik", "oprema2-token": "Oprema2Lik", "ailik-token": "AiLik", "ai2lik-token": "Ai2Lik", "potion-token": "TestLik", "mover-token": "MoverLik", "observer-token": "ObserverLik",
          "raspored-token": "RasporedLik", "cilj-token": "CiljLik", "drugi-token": "DrugiLik", "quest-token": "QuestLik",
          "posmatrac-token": "PosmatracLik", "lovac-token": "LovacLik", "buff-token": "BuffLik", "buff2-token": "Buff2Lik", "brzina-token": "BrzinaLik"}
LOCK = threading.Lock()


class H(BaseHTTPRequestHandler):
    def _odgovor(self, d, kod=200):
        b = json.dumps(d).encode()
        self.send_response(kod)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _telo(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        p = self.path
        if m := re.fullmatch(r"/items/([\w-]+)", p):
            it = ITEMS.get(m[1])
            return self._odgovor(it) if it else self._odgovor({"error": "Item not found"}, 404)
        if p == "/items":
            return self._odgovor({"items": list(ITEMS.values())})
        if p == "/quests":
            return self._odgovor({"quests": list(QUESTS.values())})
        if m := re.fullmatch(r"/quests/completed/([\w-]+)", p):
            with LOCK:
                return self._odgovor({"completed": list(ZAVRSENI.get(m[1], []))})
        if m := re.fullmatch(r"/quests/([\w-]+)", p):
            q = QUESTS.get(m[1])
            return self._odgovor(q) if q else self._odgovor({"error": "Quest not found"}, 404)
        if m := re.fullmatch(r"/players/([\w-]+)", p):
            with LOCK:
                pl = PLAYERS.get(m[1])
                return self._odgovor(json.loads(json.dumps(pl))) if pl else self._odgovor({"error": "Player not found"}, 404)
        self._nepoznato()

    def do_POST(self):
        p, d = self.path, self._telo()
        if p == "/auth/verify":
            if d.get("token") == "visi-token":  # verify koji visi (duže od ApiManager 3x8 s): server mora sam da izbaci peer-a
                time.sleep(40)
                return self._odgovor({"error": "istek"}, 504)
            ime = TOKENI.get(str(d.get("token", "")))
            return self._odgovor({"status": "ok", "ime_lika": ime, "username": ime.lower()} if ime
                                 else {"error": "Nevazeci ili istekao token"}, 200 if ime else 401)
        if m := re.fullmatch(r"/players/([\w-]+)/save", p):
            if m[1] in SPORI_SAVE:
                print(f"[STUB] spori save {m[1]} ({SPORI_SAVE[m[1]]} s)", file=sys.stderr, flush=True)
                time.sleep(SPORI_SAVE[m[1]])
            with LOCK:
                pl = PLAYERS.get(m[1])
                if not pl:
                    return self._odgovor({"error": "Player not found"}, 404)
                # hp/mana/pozicija uvek; inventar i oprema kao backend: samo kad se broj komada slaže sa "bazom"
                # (inventar ostaje autoritativan ovde: item/use i kupovina ga menjaju mimo game servera)
                for k in ("hp", "mana", "pos_x", "pos_y", "pos_z"):
                    if k in d:
                        pl[k] = d[k]
                razlog = _razlog_odbijanja(d.get("inventory"), d.get("equipment", {}), pl.get("inventory", []), pl.get("equipment", {}))
                if not razlog:
                    pl["inventory"], pl["equipment"] = d["inventory"], d.get("equipment", {})
                else:  # isto upozorenje kao backend, sa razlogom (run.sh: save_raspored_prihvacen)
                    print(f"[STUB] save {m[1]!r}: neispravan inventory/equipment ({razlog}), zadrzano stanje iz baze",
                          file=sys.stderr, flush=True)
            return self._odgovor({"status": "ok"})
        if (m := re.fullmatch(r"/players/([\w-]+)/xp/change", p)) and m[1] in XP_LIKOVI:
            if int(d.get("delta", 0)) <= 0:
                return self._odgovor({"error": "delta mora biti > 0"})
            with LOCK:  # kao backend _upisi_xp: kolone iz primeni_xp, na level-up pun HP (+ hp_bonus opreme) i mana
                return self._odgovor({"status": "ok", **_upisi_xp(PLAYERS[m[1]], int(d["delta"]))})
        if m := re.fullmatch(r"/players/([\w-]+)/inventory/change", p):  # loot
            with LOCK:
                pl, id, n = PLAYERS.get(m[1]), str(d.get("item_id", "")), int(d.get("delta", 0))
                if not pl or id not in ITEMS or n == 0:
                    return self._odgovor({"error": "Player not found" if not pl else "Item not found"})
                if n > 0:
                    _dodaj(pl["inventory"], id, n)
                elif not _ukloni(pl["inventory"], id, -n):
                    return self._odgovor({"error": "Nedovoljno itema"})
                return self._odgovor({"status": "ok", "inventory": pl["inventory"]})
        if m := re.fullmatch(r"/players/([\w-]+)/quest/(accept|kill|abandon|turnin)", p):
            with LOCK:
                return self._odgovor(self._quest(PLAYERS.get(m[1]), m[1], m[2], d))
        if m := re.fullmatch(r"/players/([\w-]+)/action_bar", p):  # kao backend: 10 slotova, predmeti postoje
            sl = d.get("slotovi")
            if not isinstance(sl, list) or len(sl) != 10:
                return self._odgovor({"error": "action bar mora imati 10 slotova"})
            if any(i is not None and i not in ITEMS for i in sl):
                return self._odgovor({"error": "Item not found"})
            with LOCK:
                if m[1] not in PLAYERS:
                    return self._odgovor({"error": "Player not found"})
                PLAYERS[m[1]]["action_bar"] = sl
            return self._odgovor({"status": "ok", "action_bar": sl})
        if m := re.fullmatch(r"/players/([\w-]+)/shop/buy", p):  # bez golda: samo doda komad u novi stack
            with LOCK:
                pl = PLAYERS.get(m[1])
                if not pl or str(d.get("item_id")) not in ITEMS:
                    return self._odgovor({"error": "Player not found" if not pl else "Item not found"})
                inv = pl["inventory"]
                inv.append({"slot": max([e["slot"] for e in inv], default=-1) + 1, "id": d["item_id"], "kolicina": 1})
                return self._odgovor({"status": "ok", "gold": pl["gold"], "inventory": inv})
        if m := re.fullmatch(r"/players/([\w-]+)/item/use", p):
            if m[1] not in BEZ_ITEM_KASNJENJA:
                time.sleep(ITEM_USE_KASNJENJE)
            with LOCK:
                pl = PLAYERS.get(m[1])
                it = ITEMS.get(str(d.get("item_id", "")))
                if not pl:
                    return self._odgovor({"error": "Player not found"})
                if not it:
                    return self._odgovor({"error": "Item not found"})
                if it["tip"] != "consumable" or (it["hp_efekat"] + it["mana_efekat"] <= 0 and not it["buff_tip"]):
                    return self._odgovor({"error": "Item nije potrosni"})
                inv = pl["inventory"]
                if sum(e["kolicina"] for e in inv if e["id"] == it["id"]) < 1:
                    return self._odgovor({"error": "Nedovoljno itema"})
                e = next(e for e in inv if e["id"] == it["id"])
                e["kolicina"] -= 1
                if e["kolicina"] == 0:
                    inv.remove(e)
                pl["item_use_br"] = pl.get("item_use_br", 0) + 1  # test: koliko puta je backend trošio
                return self._odgovor({"status": "ok", "item_id": it["id"], "hp_efekat": it["hp_efekat"],
                                      "mana_efekat": it["mana_efekat"], "cooldown_ms": it["cooldown_ms"],
                                      "buff_tip": it["buff_tip"], "buff_vrednost": it["buff_vrednost"],
                                      "buff_trajanje_ms": it["buff_trajanje_ms"], "inventory": inv})
        self._nepoznato()

    def _quest(self, pl, ime, akcija, d):
        if not pl:
            return {"error": "Player not found"}
        zav = ZAVRSENI.setdefault(ime, [])
        if akcija == "abandon":
            pl["aktivni_quest_id"], pl["quest_progres"] = None, 0
            return {"status": "ok"}
        if akcija == "kill":
            q = QUESTS.get(pl.get("aktivni_quest_id") or "")
            if q and q["tip"] == "kill" and q["cilj"] == d.get("tip") and pl["quest_progres"] < q["kolicina"]:
                pl["quest_progres"] += 1
            pl.setdefault("kill_dnevnik", []).append(d.get("tip"))  # test: kill credit
            return {"status": "ok", "quest_progres": pl["quest_progres"]}
        q = QUESTS.get(str(d.get("quest_id", "")))
        if akcija == "accept":
            if not q:
                return {"error": "Quest not found"}
            if q["id"] in zav:
                return {"error": "Quest vec zavrsen"}
            if pl.get("aktivni_quest_id"):
                return {"error": "Vec imas aktivan quest"}
            if any(x["sledeci_quest"] == q["id"] and x["id"] not in zav for x in QUESTS.values()):
                return {"error": "Prethodni quest nije zavrsen"}
            pl["aktivni_quest_id"], pl["quest_progres"] = q["id"], 0
            return {"status": "ok", "quest": q}
        if not q or pl.get("aktivni_quest_id") != q["id"]:  # turnin
            return {"error": "Quest nije aktivan"}
        if q["id"] in zav:
            return {"error": "Quest vec zavrsen"}
        if q["tip"] == "kill" and pl["quest_progres"] < q["kolicina"]:
            return {"error": "Quest nije zavrsen"}
        if q["tip"] == "fetch" and not _ukloni(pl["inventory"], q["cilj"], q["kolicina"]):
            return {"error": "Nedovoljno itema"}
        if q["nagrada_item"]:
            _dodaj(pl["inventory"], q["nagrada_item"], 1)
        zav.append(q["id"])
        pl["gold"] += q["nagrada_gold"]
        pl["aktivni_quest_id"], pl["quest_progres"] = None, 0
        s = _upisi_xp(pl, q["nagrada_xp"])
        return {"status": "ok", "nagrada": {"naziv": q["naziv"], "gold": q["nagrada_gold"], "xp": q["nagrada_xp"],
                "item": q["nagrada_item"], "sledeci_quest": q["sledeci_quest"]}, "quest": q, "gold": pl["gold"],
                "inventory": pl["inventory"], "stats": s}

    def _nepoznato(self):
        print("[STUB] nepoznata ruta:", self.command, self.path, file=sys.stderr, flush=True)
        self._odgovor({"error": "stub: nepoznata ruta"}, 404)

    def log_message(self, fmt, *a):
        print("[STUB]", fmt % a, file=sys.stderr, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
