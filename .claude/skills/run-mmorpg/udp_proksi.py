#!/usr/bin/env python3
"""UDP proxy jednog klijenta ka game serveru sa promenljivim kašnjenjem (skok RTT-a koji ENet vidi).

Upotreba: udp_proksi.py PORT_SLUSA PORT_SERVERA KONTROLA
  KONTROLA: fajl sa dodatnim RTT-om u ms (pola na putu ka serveru, pola nazad); čita se svakih 20 ms, nema fajla = 0.
  "A-B" = svaki paket dobije nasumičan dodatni RTT iz [A, B] ms (jitter, i dalje bez preuređivanja).
  -1 = crna rupa: svi paketi se odbacuju (server koji ne odgovara na handshake, npr. pun).
Paketi se ne gube i ne preuređuju: vreme isporuke = max(prethodna isporuka u istom smeru, prijem + kašnjenje).
Na kraju (SIGTERM) ispiše broj paketa po smeru.
"""
import collections, os, random, select, signal, socket, sys, time

slusa, cilj, kontrola = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ka_klijentu = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ka_klijentu.bind(("127.0.0.1", slusa))
ka_serveru = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ka_serveru.connect(("127.0.0.1", cilj))
klijent = None
redovi = {ka_serveru: collections.deque(), ka_klijentu: collections.deque()}  # odredište -> [(isporuka, podaci)]
poslednja = {ka_serveru: 0.0, ka_klijentu: 0.0}
broj = {"klijent->server": 0, "server->klijent": 0}
rtt_ms, rtt_do, citano = 0, 0, 0.0
sekunda, po_sek = time.monotonic(), {"klijent->server": 0, "server->klijent": 0}
bajtova = {"klijent->server": 0, "server->klijent": 0}
po_sek_b = {"klijent->server": 0, "server->klijent": 0}

def kraj(*_):
    print("[PROKSI] paketa: %s, bajtova: %s" % (broj, bajtova), flush=True)
    sys.exit(0)
signal.signal(signal.SIGTERM, kraj)

while True:
    sad = time.monotonic()
    if sad - citano > 0.02:
        citano = sad
        try:
            tekst = open(kontrola).read().strip() or "0"
            od, _, do_ = tekst.partition("-") if not tekst.startswith("-") else (tekst, "", "")
            novo, novo_do = int(od), int(do_ or od)
        except (OSError, ValueError):
            novo, novo_do = 0, 0
        if (novo, novo_do) != (rtt_ms, rtt_do):
            print("[PROKSI] t=%.3f dodatni RTT %d-%d -> %d-%d ms" % (time.time(), rtt_ms, rtt_do, novo, novo_do), flush=True)
            rtt_ms, rtt_do = novo, novo_do
    sledeca = min([r[0][0] for r in redovi.values() if r] + [sad + 0.005])
    for s in select.select([ka_klijentu, ka_serveru], [], [], max(0.0, sledeca - sad))[0]:
        podaci, adr = s.recvfrom(65536)
        if s is ka_klijentu:
            klijent, odr, smer = adr, ka_serveru, "klijent->server"
        else:
            odr, smer = ka_klijentu, "server->klijent"
        broj[smer] += 1
        po_sek[smer] += 1
        bajtova[smer] += len(podaci)
        po_sek_b[smer] += len(podaci)
        if rtt_ms < 0:
            continue
        poslednja[odr] = max(poslednja[odr], time.monotonic() + random.uniform(rtt_ms, rtt_do) / 2000.0)
        redovi[odr].append((poslednja[odr], podaci))
    sad = time.monotonic()
    if sad - sekunda >= 1.0:  # paketa po sekundi (ENet koji odbacuje nepouzdane pakete se vidi kao pad klijent->server)
        print("[PROKSI] t=%.3f za 1 s: %s, bajtova %s (RTT +%d ms)" % (time.time(), po_sek, po_sek_b, rtt_ms), flush=True)
        sekunda, po_sek = sad, {"klijent->server": 0, "server->klijent": 0}
        po_sek_b = {"klijent->server": 0, "server->klijent": 0}
    for odr, red in redovi.items():
        while red and red[0][0] <= sad:
            podaci = red.popleft()[1]
            if odr is ka_serveru:
                odr.send(podaci)
            elif klijent:
                odr.sendto(podaci, klijent)
