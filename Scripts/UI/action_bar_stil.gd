# Izgled action bara: SVE boje, dimenzije, razmaci i fontovi su ovde (logika je u action_bar.gd).
# Opšti stil (referenca: kvadratni slotovi u nizu, tanka tamna ivica, taster gore levo, količina dole desno,
# cooldown kao tamni overlay). Bez ikonica i tuđih aseta.
extends RefCounted

# slot
const SLOT_VELICINA := 40          # px, kvadrat
const RAZMAK := 3                  # px između slotova
const IVICA := 1                   # px
const BOJA_SLOT := Color(0.06, 0.06, 0.08, 0.72)
const BOJA_IVICA := Color(0.0, 0.0, 0.0, 0.95)
const BOJA_SLOT_PRAZAN := Color(0.06, 0.06, 0.08, 0.45)

# bar (pozadina iza slotova)
const PADDING := 3                 # px oko slotova
const BOJA_BAR := Color(0.0, 0.0, 0.0, 0.35)
const IVICA_BAR := 1
const BOJA_IVICA_BAR := Color(0.0, 0.0, 0.0, 0.6)
const MARGINA_DNO := 12            # px od dna ekrana

# tekst (FONT = null -> podrazumevani font teme)
const FONT: Font = null
const BOJA_TEKST := Color(1, 1, 1)
const BOJA_OUTLINE := Color(0, 0, 0)
const OUTLINE := 3
const FONT_TASTER := 11            # broj tastera, gore levo
const FONT_KOLICINA := 12          # količina, dole desno
const FONT_OZNAKA := 14            # kratka oznaka predmeta, sredina
const BOJA_OZNAKA := Color(0.95, 0.9, 0.75)
const BOJA_KOLICINA_NULA := Color(0.75, 0.3, 0.3)
const UVLAKA_TEKSTA := 2           # px od ivice slota za taster i količinu

# cooldown
const BOJA_CD_OVERLAY := Color(0, 0, 0, 0.62)
const FONT_CD := 16
const BOJA_CD_TEKST := Color(1.0, 0.95, 0.6)
