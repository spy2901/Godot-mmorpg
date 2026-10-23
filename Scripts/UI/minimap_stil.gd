# Izgled minimape: SVE boje, dimenzije, razmaci i fontovi su ovde (logika je u minimapa.gd). Osnovni izgled, bez ikonica.
extends RefCounted

# okvir (gore desno, sidren uz ivice ekrana)
const VELICINA := 200              # px, kvadrat
const MARGINA := 20                # px od gornje i desne ivice
const RAZMAK_ISPOD := 12           # px između minimape i quest trackera (TopBar)
const BOJA_POZADINA := Color(0.0, 0.0, 0.0, 0.55) # van svih zona
const PROVIDNOST_ZONA := 0.85      # boja zone iz zone.gd sa ovom providnošću
const IVICA := 2                   # px
const BOJA_IVICA := Color(0.0, 0.0, 0.0, 0.9)

# markeri (poluprečnik u px)
const MARKER := 3.5
const BOJA_NEPRIJATELJ := Color(0.9, 0.15, 0.1)
const BOJA_IGRAC := Color(0.3, 0.55, 1.0)       # drugi igrači
const BOJA_MRTAV := Color(0.55, 0.55, 0.55)     # mrtav igrač
const PROVIDNOST_NEVIDLJIV := 0.4               # nevidljiv igrač (kao providan model)
const BOJA_NPC := Color(0.95, 0.95, 0.95)
const BOJA_QUEST := Color(1.0, 0.85, 0.2)       # quest NPC: tačka i "!"
const FONT_QUEST := 14

# strelica sopstvenog lika (vrh ka smeru gledanja)
const STRELICA_DUZINA := 9.0       # px od centra do vrha
const STRELICA_SIRINA := 6.0       # px od centra do zadnjih uglova
const BOJA_STRELICA := Color(1.0, 0.9, 0.3)
const BOJA_STRELICA_IVICA := Color(0.0, 0.0, 0.0)

# oznaka zuma ("40 m", dole desno)
const FONT_ZUM := 11
const BOJA_ZUM := Color(1, 1, 1)
const BOJA_OUTLINE := Color(0, 0, 0)
const OUTLINE := 3
const UVLAKA_ZUM := 4              # px od ivice

const OSVEZAVANJE_HZ := 20         # najviše toliko crtanja u sekundi
