# Vraća agent_test likove na fiksnu poziciju preko /players/{ime}/save (server key iz env TEST_SERVER_KEY).
# Menja samo poziciju: hp, mana, inventory i equipment se šalju nazad onakvi kakvi su u bazi.
# Ključ se nikad ne ispisuje; ispis je samo ime lika i ok/greška.
import json, os, sys, urllib.request

POZICIJE = {os.environ["TEST_USER_1"]: (0.0, 1.16, 0.0), os.environ["TEST_USER_2"]: (4.0, 1.16, 0.0)}
api = os.environ["TEST_API_URL"].rstrip("/")
kljuc = os.environ.get("TEST_SERVER_KEY", "")
if not kljuc:
    sys.exit("TEST_SERVER_KEY nije postavljen u .env.test")

def zahtev(put, telo=None):
    r = urllib.request.Request(api + put, method="POST" if telo is not None else "GET",
                               data=json.dumps(telo).encode() if telo is not None else None,
                               headers={"X-Server-Key": kljuc, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=10) as o:
        return json.load(o)

for ime, (x, y, z) in POZICIJE.items():
    if not ime.startswith("agent_test"):
        sys.exit(f"odbijeno: '{ime}' nema prefiks agent_test")
    try:
        lik = zahtev(f"/players/{ime}")
        if "error" in lik:
            sys.exit(f"{ime}: {lik['error']}")
        r = zahtev(f"/players/{ime}/save", {"hp": lik["hp"], "mana": lik["mana"], "pos_x": x, "pos_y": y, "pos_z": z,
                                             "inventory": lik["inventory"], "equipment": lik["equipment"]})
        posle = zahtev(f"/players/{ime}")
    except Exception as e:  # HTTPError/URLError: poruka ne sadrži zaglavlja
        sys.exit(f"{ime}: {type(e).__name__} {getattr(e, 'code', '')}")
    if r.get("status") != "ok" or max(abs(posle["pos_" + k] - v) for k, v in zip("xyz", (x, y, z))) > 0.01 \
            or (posle["hp"], posle["mana"], posle["inventory"], posle["equipment"]) != (lik["hp"], lik["mana"], lik["inventory"], lik["equipment"]):
        sys.exit(f"{ime}: upis nije potvrđen")
    print(f"   {ime}: ({lik['pos_x']:.2f}, {lik['pos_y']:.2f}, {lik['pos_z']:.2f}) -> ({x}, {y}, {z})")
