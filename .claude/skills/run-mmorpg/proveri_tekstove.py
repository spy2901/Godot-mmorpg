"""Provere tekstova (bez Godot-a), ispis PASS/FAIL kao driver.gd:
  backend_poruke_u_csv   svaka poruka greške iz ~/mmorpg-server (BACKEND_DIR) koju igrač može da vidi ima red u
                         translations/teksti.csv (ključ tačno kao backend, sa en prevodom). Interne poruke (server <->
                         API, igrač ih ne vidi) su u INTERNE; nova poruka backenda mora u CSV ili u INTERNE.
  bez_srpskog_u_prikazu  stringovi u Scripts/*.gd i tekstovi u Scenes/*.tscn nisu na srpskom (slova č ć š ž đ ili
                         tipične srpske reči). Preskaču se komentari, print/push_error/_dbg_seq i debug linije "[...]".
                         Najbolji napor: string bez razmaka (identifikator, ključ rečnika) se ne gleda.
Pokretanje: python3 .claude/skills/run-mmorpg/proveri_tekstove.py  (iz korena repoa)."""
import csv
import os
import re
import sys
from pathlib import Path

KOREN = Path(__file__).resolve().parents[3]
BACKEND = Path(os.environ.get("BACKEND_DIR", Path.home() / "mmorpg-server"))
CSV = KOREN / "translations" / "teksti.csv"

# backend poruke koje igrač ne vidi (greške između game servera i API-ja, ili programske)
INTERNE = {
    "Player not found", "Item not found", "Quest not found", "delta ne sme biti 0", "delta mora biti > 0",
    "kolicina mora biti 1..99", "action bar mora imati 10 slotova", "Nedostaje token", "Nedovoljno itema",
    "Item nije potrosni", "Quest vec zavrsen", "Quest nije aktivan", "Prethodni quest nije zavrsen",
    "Nepoznat tip questa", "Nagrada item ne postoji", "server key not configured", "forbidden",
}

SRPSKE_RECI = r"nije|nema|si|je|za|sa|ili|da|ne|još|već|mi|ti|tvoj|tvoje|lik|lika|predmet|zadatak|igrač|kupi|" \
    r"prodavnica|predaj|prihvati|odbij|učitavam|prijava|lozinka|greška|uspela|uspelo|nedovoljno|dalje|zatvori|" \
    r"poginuo|spreman|hvala|pozdrav|progres|ciljevi|nagrade|odustani|konekcija|povezan|nepovezan|odjava|hostuj|" \
    r"pridruži|mrtav|predaleko|cilja|kupljeno|ubij|donesi|trening|razgovor|servera|ime|zlato|iskustvo|" \
    r"neprijatelj|izlaz|registracija|vrednost|klik|prazno"
SRPSKI = re.compile(r"[čćšžđČĆŠŽĐ]|\b(" + SRPSKE_RECI + r")\b", re.IGNORECASE)
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _provera(ime, ok, detalj):
    print(f"{'PASS' if ok else 'FAIL'} {ime}  {detalj}")
    return ok


def backend_poruke():
    """Poruke grešaka iz ruta backenda: _greska(...), {"error": ...}, HTTPException(detail=...)."""
    poruke = set()
    for f in sorted((BACKEND / "routers").glob("*.py")) + [BACKEND / "auth.py"]:
        src = f.read_text()
        konst = dict(re.findall(r"^(\w+)\s*=\s*(\d+)\s*$", src, re.M))
        for m in re.finditer(r"([A-Z_]+(?:\s*,\s*[A-Z_]+)+)\s*=\s*(\d+(?:\s*,\s*\d+)+)", src):  # MIN, MAX = 8, 128
            konst.update(zip(re.split(r"\s*,\s*", m[1]), re.split(r"\s*,\s*", m[2])))
        for m in re.finditer(r'(?:_greska\([^"\n]*?|"error":\s*|detail=)(f?)"([^"]+)"', src):
            s = m[2]
            if m[1]:
                s = re.sub(r"\{(\w+)\}", lambda k: konst.get(k[1], k[0]), s)
            if s != "poruka":
                poruke.add(s)
    return poruke


def csv_kljucevi():
    with open(CSV, newline="") as f:
        return {r["keys"]: r for r in csv.DictReader(f)}


def proveri_backend():
    if not (BACKEND / "routers").is_dir():
        return _provera("backend_poruke_u_csv", False, f"nema backenda u {BACKEND} (BACKEND_DIR)")
    poruke = backend_poruke()
    kljucevi = csv_kljucevi()
    vidljive = sorted(poruke - INTERNE)
    nema = [p for p in vidljive if not kljucevi.get(p, {}).get("en")]
    zastarele = sorted(INTERNE - poruke)
    return _provera("backend_poruke_u_csv", len(vidljive) > 0 and not nema,
                    f"{len(poruke)} poruka u backendu, {len(vidljive)} vidljivih, bez reda u CSV-u: {nema or '-'}"
                    + (f"; INTERNE kojih više nema u backendu: {zastarele}" if zastarele else ""))


def _bez_komentara(linija):
    """Deo linije pre # koji nije u stringu."""
    u_stringu = False
    for i, c in enumerate(linija):
        if c == '"' and (i == 0 or linija[i - 1] != "\\"):
            u_stringu = not u_stringu
        elif c == "#" and not u_stringu:
            return linija[:i]
    return linija


def srpski_u_prikazu():
    nalazi = []
    for f in sorted((KOREN / "Scripts").rglob("*.gd")):
        for br, linija in enumerate(f.read_text().splitlines(), 1):
            kod = _bez_komentara(linija)
            if re.search(r"\b(print|printerr|push_error|push_warning|_dbg_seq)\(", kod):
                continue
            for s in STRING.findall(kod):
                if " " not in s.strip() and not re.search(r"[čćšžđČĆŠŽĐ]", s) and not s[:1].isupper():
                    continue  # identifikator / ključ rečnika / putanja (jedna reč malim slovom)
                if s.startswith("[") and re.match(r"\[[A-Z-]+\]", s):
                    continue  # debug prefiks ([AUTH], [SEQ] ...)
                if SRPSKI.search(s):
                    nalazi.append(f"{f.relative_to(KOREN)}:{br} \"{s}\"")
    for f in sorted((KOREN / "Scenes").rglob("*.tscn")):
        for br, linija in enumerate(f.read_text().splitlines(), 1):
            m = re.match(r'(text|title|placeholder_text|tooltip_text|ime|npc_name|dialogue_lines)\s*=\s*(.*)', linija)
            if m and SRPSKI.search(" ".join(STRING.findall(m[2]))):
                nalazi.append(f"{f.relative_to(KOREN)}:{br} {m[2]}")
    return nalazi


if __name__ == "__main__":
    ok = proveri_backend()
    nalazi = srpski_u_prikazu()
    ok &= _provera("bez_srpskog_u_prikazu", not nalazi, f"{len(nalazi)} nalaza: {'; '.join(nalazi[:8]) or '-'}")
    sys.exit(0 if ok else 1)
