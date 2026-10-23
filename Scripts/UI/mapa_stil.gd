# Izgled mape sveta (M): SVE boje, dimenzije, razmaci i fontovi su ovde (logika je u mapa_sveta.gd). Ravne boje, bez ikonica.
extends RefCounted

const SLOJ := 40                   # CanvasLayer: iznad HUD-a, ispod prodavnice (50) i dijaloga (100)
const BOJA_ZATAMNJENJE := Color(0.0, 0.0, 0.0, 0.75) # preko celog ekrana
const MARGINA := 60                # px od ivice ekrana do mape (skaliranje na granice svih zona)

# zone (boja zone iz zone.gd)
const IVICA_ZONE := 2              # px
const BOJA_IVICA_ZONE := Color(0.0, 0.0, 0.0, 0.9)
const IVICA_ISTAKNUTA := 4         # px: zona u kojoj je igrač
const BOJA_ISTAKNUTA := Color(1.0, 0.85, 0.3)

# tekst zone: ime, ispod "Lv. 1-10" (FONT = null -> podrazumevani font teme)
const FONT: Font = null
const FONT_IME := 28
const FONT_NIVO := 18
const RAZMAK_TEKSTA := 6           # px između imena i nivoa
const BOJA_TEKST := Color(1, 1, 1)
const BOJA_NIVO := Color(0.95, 0.85, 0.55)
const BOJA_OUTLINE := Color(0, 0, 0)
const OUTLINE := 6

# strelica igrača (vrh ka smeru gledanja)
const STRELICA_DUZINA := 14.0      # px od centra do vrha
const STRELICA_SIRINA := 9.0       # px od centra do zadnjih uglova
const BOJA_STRELICA := Color(1.0, 0.9, 0.3)
const BOJA_STRELICA_IVICA := Color(0.0, 0.0, 0.0)
