# SmO2 Control: vollständige Funktionsbeschreibung

Garmin Connect IQ Datenfeld für Muskeloxygenierung (SmO₂) mit einem Moxy-Sensor.

---

## 1. Die Kernidee

Der absolute SmO₂-Wert ist zwischen Einheiten kaum vergleichbar. Er hängt ab von
Sensorposition (Millimeter zählen), Fettschichtdicke über dem Muskel,
Anpressdruck der Halterung, Hautdurchblutung, Temperatur und Tagesform. Ein
Datenfeld, das „SmO₂ = 34 %" anzeigt, gibt dem Athleten deshalb keine
handlungsfähige Information.

Innerhalb einer Einheit ist das Signal dagegen sehr aussagekräftig, allerdings nicht als
Absolutwert, sondern als **Kinetik**:

1. **Rapide Desaturierung** zu Intervallbeginn: Verbrauch übersteigt Angebot.
   Die Steilheit dieses Abfalls korreliert mit der metabolischen Rate.
2. **Plateau oder fortgesetzter Drift**: Erreicht SmO₂ ein stabiles Plateau,
   balancieren sich Angebot und Verbrauch, die Intensität ist nachhaltig.
   Driftet der Wert weiter nach unten, kann das Angebot nicht mehr folgen, die
   Intensität liegt über dem nachhaltigen Punkt.
3. **Reoxygenierung** in der Pause, oft mit Overshoot über den Ausgangswert.

Die Nachricht des Datenfelds an den Athleten in Echtzeit lautet deshalb nicht
„34 %", sondern: *fällt gerade / stabilisiert sich / driftet weiter / erholt
sich*, und wie schnell.

---

## 2. Zustandsklassifikation

Fünf Zustände, jeder mit eigener Farbe:

| Zustand | Farbe | Bedeutung | Kinetischer Name |
|---|---|---|---|
| **ONSET** | Orange | Rapide Desaturierung, der On-Transient zu Intervallbeginn | ON-KIN |
| **FALLING** | Rot | Abfall setzt sich fort, hier existiert kein Steady State | OVER |
| **DRIFTING** | Gelb | Langsamer Abfall, fordernd, aber kontrolliert | CONTROL |
| **HOLDING** | Grün | Flach, Angebot deckt Verbrauch, nachhaltiger Steady State | STEADY |
| **RECOVER** | Blau | Steigend, Erholung oder zu geringe Intensität | REOXY |

Die Labels benennen das gemessene Verhalten, in Worten, die kein Glossar
brauchen. Die kinetischen Begriffe in der rechten Spalte sind die Alternative
für alle, die die Namen der Literatur bevorzugen: dafür *Klartext-Zustandsnamen*
abschalten.

### Warum keine Zonennummern

Zonennummern waren hier einmal eingebaut und sind wieder verschwunden. Zwei
Gründe, und jeder einzelne genügt.

Die Uhr besitzt das Wort „Zone" schon: für ihre eigenen fünf Herzfrequenz- und
sieben Leistungszonen. Wenn dieses Feld ZONE 2 anzeigt, während das
Herzfrequenzfeld daneben Zone 4 anzeigt, ist das schlechter als gar keine
Angabe.

Das tiefere Problem: Eine Zone ist eine Aussage über die Intensität, dieses
Feld misst eine Steigung. Ein Plateau tritt unterhalb von LT1 genauso auf wie
an der Schwelle, und steigendes SmO₂ unter Last sagt, dass das Angebot den
Verbrauch übersteigt, aber nicht bei welcher Leistung. Es kann also keine
korrekte Abbildung von Steigung auf Zonennummer geben. Eine korrekte bräuchte
die individuellen Muscle-Oxygenation-Breakpoints, die den *absoluten* Pegel
verankern, und diese Information hat das Feld nicht und kann sie nicht
erschließen. Was es sagen kann, ist, ob sich die gewählte Belastung eingependelt
hat. Das ist eine andere, engere Behauptung, und genau die machen diese Labels.

Die wichtigste Unterscheidung ist **ONSET gegen FALLING**. Jedes harte Intervall
beginnt mit einem steilen Abfall; dieser Abfall ist noch kein Urteil. Was ein
nachhaltiges von einem nicht nachhaltigen Intervall trennt, ist die Frage, ob
danach das Plateau eintritt. Ein Feld, das den Transienten als „überzogen"
bewertet, färbt jedes harte Intervall in seiner ersten Minute rot und ist damit
wertlos.

Alle Zustandsgrenzen besitzen eine Hysterese von ±15 %, damit die Farbe an einer
Schwelle nicht flackert.

### Wohin eine Farbe zeitlich gehört

Das Live-Urteil und die Diagrammfarben entstehen bewusst unterschiedlich.

Eine nachlaufende Regression über [t−60, t] schätzt die Steigung in der **Mitte**
dieses Fensters, bei t−30, nicht an seinem Ende. Sie bei t zu zeichnen setzt die
Farbe dreißig Sekunden rechts neben die Form, die sie beschreibt: an einem
echten Intervall gemessen war der Verlauf noch grün, während er mit −0,785 %/s
fiel, und noch orange, als das Plateau längst da war.

Das Diagramm färbt jedes Segment deshalb aus einem **zentrierten** Fenster um
diesen Punkt, das am Live-Rand symmetrisch schrumpft, das übliche Verfahren
für Randeffekte. An einem echten Intervall überprüft: jede Segmentfarbe passt
jetzt zur Richtung, in die die Linie tatsächlich läuft, ausnahmslos.

Zwei Konsequenzen sind wissenswert. Die jüngsten Samples werden aus weniger
Evidenz beurteilt, ein Segment kann also die Farbe wechseln, wenn mehr
hinzukommt. Das ist ehrlich, denn genau dann kommt die Evidenz. Und die allerjüngsten,
für die noch kein brauchbares Fenster existiert, werden grau gezeichnet statt
geraten.

Die Diagrammfarben verzichten außerdem auf die Hysterese des Live-Urteils. Die
Hysterese soll das Flackern des *aktuellen* Zustands verhindern; auf eine
fertige Form angewandt würde sie die Farbe eines Segments davon abhängig machen,
was ihm vorausging, statt davon, was es ist.

---

## 3. Signalverarbeitung

Zwei Schätzer auf zwei Zeitskalen. Sie sind nicht austauschbar.

```
Roh-SmO₂ (~1 Hz, verrauscht)
      |
      +-- Holt doppelt-exponentielle Glättung --> Level, schneller Trend
      |                                            `-- Prognose, Diagramm
      |
      +-- 60-s-Regressionssteigung --------------> Zustandsklassifikation
                                                    `-- Farbe und Anzeigewert
```

### 3.1 Holt-Glättung (Level und Prognose)

Doppelt-exponentielle Glättung nach Holt liefert Level und Trend aus einer
O(1)-Rekursion. Der Trend wird in %/s geführt, nicht in %/Update, weil
`compute()` nicht garantiert exakt mit 1 Hz feuert und die Update-Rate des Moxy
schwankt. Jede Rekursion verwendet das real gemessene Δt.

Parameter: α (Level, Default 0,30), β (Trend, Default 0,15).

Der Holt-Trend liefert die **Prognose**: `Level + h · Trend` sagt den SmO₂-Wert
in `h` Sekunden voraus (Default 15 s, abschaltbar).

### 3.2 Regressionssteigung (Klassifikation)

Ein einfacher Kleinste-Quadrate-Fit über die letzten 60 Sekunden des geglätteten
Levels. Kostet einen Durchlauf von ~60 Multiply-Adds pro Sekunde.

**Warum nicht auch hier exponentielle Glättung?** Nicht wegen Rechenlast. Auf
echten Moxy-Daten überschreitet der schnelle Holt-Trend bei der Hälfte aller
Samples 0,15 %/s, und zwar *innerhalb eines bombenfesten Plateaus*. Das Signal
bewegt sich real so schnell; das ist kein Glättungsartefakt, und keine Schwelle
auf diesem Trend kann etwas trennen. Ihn zu verlangsamen hilft ebenfalls nicht:
ein exponentieller Filter hat einen unendlichen Schwanz und trägt den
On-Transienten immer weiter mit, kommt also innerhalb eines Intervalls nie zur
Ruhe. Ein endliches Fenster *vergisst* den Transienten, sobald er hinausrutscht.
Für die Frage „ist das Plateau da?" ist Vergessen genau das gewünschte Verhalten.

**Warum 60 Sekunden?** Gemessen an fünf echten Schwellen-Einheiten:

- bei 45 s ist das Plateau-Band ±0,08 %/s, echter Drift verschwindet darin
- bei 90 s verdünnt sich der On-Transient in die vorausgegangene Erholung und
  wird gar nicht mehr erkannt
- bei 60 s liegt die Plateau-Steigung innerhalb von ±0,06 %/s (10. bis 90.
  Perzentil), während der Transient −0,23 %/s unterschreitet

### 3.3 Schwellen

| Schwelle | Default | Herkunft |
|---|---|---|
| θ_stable | 0,06 %/s | 10. bis 90. Perzentil der Plateau-Steigung, fünf Sessions |
| θ_drift | 0,15 %/s | Grenze des normalen Plateau-Verhaltens |
| θ_onkin | 2 × θ_drift | zwischen Plateau-Extrem und Transient-Steilheit |

Die On-Kinetik-Schwelle ist von θ_drift abgeleitet statt eine eigene Einstellung
zu sein, damit sie beim Tuning automatisch mitskaliert.

### 3.4 Behandlung des On-Transienten

Sobald die Regressionssteigung unter θ_onkin fällt, gilt der Zustand als
On-Transient. Endet der Abfall, wird das Regressionsfenster **neu gestartet**,
damit die Plateau-Frage ausschließlich aus Post-Transient-Daten beantwortet
wird. Bis das Fenster wieder gefüllt ist (ein Drittel der Fensterlänge, also
20 s), meldet das Feld weiterhin ON-KIN. Das ist die ehrliche Antwort
„noch nicht entschieden".

Ein Lap-Druck gilt ebenfalls als Lastwechsel und startet das Fenster neu.

Die steilste erreichte Steigung des Transienten wird pro Lap festgehalten und
ins FIT geschrieben, weil sie mit der metabolischen Rate korreliert.

---

## 4. Session-interne Kalibrierung

Da Absolutwerte zwischen Einheiten nicht vergleichbar sind, wird alles auf ein
innerhalb der Einheit dynamisch kalibriertes Fenster bezogen.

**Stufe 1, Baseline.** Median der ersten 60 Sekunden gültiger Daten (Fenster
einstellbar). Dient als Referenz-Oben. Bei langen Fenstern wird unterabgetastet,
maximal 120 Samples werden gehalten.

**Stufe 2, rollendes Session-Min/Max.** Wird ausschließlich aus *geglätteten*
Werten fortgeschrieben, damit ein einzelner Sensor-Spike die Range nicht
definieren kann. Beide Extreme relaxieren mit 0,02 %/s zurück zum aktuellen
Wert, sobald sie mehr als 3 % davon entfernt sind, so verzerrt ein einmaliger
Ausreißer die Skalierung nicht für den Rest der Einheit.

**Stufe 3, Lap-Kalibrierung.** Der erste Lap wird als Referenzintervall
behandelt; sein Start- und Endwert verankern das Arbeitsband. Ein zweiter
Lap-Druck innerhalb von 2 Sekunden setzt die Session-Range zurück, gedacht für
den Fall, dass der Sensor während der Einheit umgesetzt wird.

**Stufe 4, relative Schwellen.** θ_stable und θ_drift sind in %/s definiert,
nicht als absolute SmO₂-Prozente. Raten sind zwischen Einheiten deutlich
stabiler als Absolutwerte.

**SmO₂ Control Index (SCI).** Einheitenlose Kennzahl: Betrag der
Regressionssteigung geteilt durch die Session-Range. Damit ist sie über Einheiten
und Sensorpositionen hinweg vergleichbar.

---

## 5. Anzeige

Drei Layout-Stufen, einmalig in `onLayout()` aus der gerenderten Fläche gewählt.
Die Entscheidung fällt nicht pro Frame, weil sich die Größe zur Laufzeit nicht
ändert.

### Full: das ganzseitige und das halbseitige Datenfeld

Das Diagramm erscheint **nur** im ganzseitigen und im halbseitigen Datenfeld.
Dafür müssen zwei Bedingungen gelten, und beide werden gebraucht:

- das nutzbare Rechteck misst mindestens 180 × 110 px, das kleinste, das ein
  ganzseitiges Feld auf irgendeinem unterstützten Gerät bekommt (fenix 7S, mit
  184 × 150), damit das Diagramm im Layout, für das es gedacht ist, nie
  verschwindet
- das Feld belegt mindestens 45 % der Bildschirmhöhe und 90 % der Breite

Die Größe allein ist der falsche Test. Der Mittelstreifen eines
Drei-Feld-Layouts misst auf einer FR970 454 × 158 px, breiter als der
Vollbildschirm einer fenix 7S, aber dort sucht niemand nach einem Verlauf.
45 % der Höhe lässt eine Hälfte durch und schließt ein Drittel aus.

#### Das Drittel-Raster

Wo das Feld *der* Bildschirm ist, wird die Höhe gedrittelt: Metriken im obersten
Drittel, das Diagramm im mittleren, Metriken im unteren.

Gelayoutet wird dabei gegen das ganze Feld und nicht gegen das eingeschriebene
Rechteck, und genau das ist der Punkt. Das Rechteck existiert, damit *ein* Block
Inhalt garantiert auf dem Glas liegt. Eine einzelne Textzeile braucht nur die
Sehne auf ihrer eigenen Höhe, und in der Nähe der Mitte eines runden Displays
ist diese Sehne die volle Breite. Zeilenweise zu rechnen ist der Grund, warum
der Wert auf einer FR970 72 px hoch sein darf und nicht 78 px neben ein Label
gequetscht, und es setzt das Diagramm in den breitesten Teil der Anzeige statt
davon eingerückt.

Zwei Zeilen pro äußerem Drittel, gepackt an den **inneren** Rand und von dort
nach außen wachsend: das Zustandslabel über dem Wert oben, die Rate über der
externen Last unten. Jedes Drittel vom äußeren Rand her zu füllen war der erste
Versuch und scheitert auf einem runden Display aus einem Grund, der sofort
einleuchtet: Bei y = 4 auf einem 454-px-Kreis ist das Glas 73 px breit, dort
passt kein einziges Wort hin. Nach innen zu packen setzt außerdem das größte
Element am nächsten an die Mitte, wo die Sehne am breitesten ist, die beiden
Randbedingungen ziehen also in dieselbe Richtung.

Die zwei Zeilen eines Drittels werden **als Paar** dimensioniert, größte
Variante zuerst, und die erste passende Kombination gewinnt. Einzeln
nacheinander funktioniert es nicht: Der Wert nimmt sich die größte Schrift, die
er bekommen kann, und schiebt sein Label damit in die Kreisspitze. Auf einer
FR970 lässt ein 97 px hoher Wert dem Label eine Sehne von 167 px, während
„DRIFTING" plus Ampel 180 braucht. Eine Schriftstufe beim Wert aufzugeben
bringt dem Label zwei, und dieser Tausch ist für eine gierige Suche unsichtbar.

Die Rate ist auf drei Viertel der Werthöhe gedeckelt, nicht auf das Drittel.
Ihre Zeichenkette ist dreimal so lang, bei gleicher Höhe braucht sie also
dreimal so viel Farbe und liest sich als Schlagzeile. Die Schlagzeile ist SmO₂.

Alles, was kleiner ist als der ganze Bildschirm, fällt auf eine Kopf- und eine
Fußzeile im nutzbaren Rechteck zurück: Wert neben Zustand, Rate neben Last.

#### Was darin steht

- **Wert**: der SmO₂-Wert in der Zustandsfarbe, in der Zeile darüber die
  **farbige Zustandsampel** und ihr Label, dieselbe Scheibe, die die
  diagrammlosen Stufen zeigen, damit über alle Feldgrößen hinweg eine visuelle
  Sprache gilt
- **Diagramm**: der Verlauf über das Diagrammfenster (Default 90 s), jedes
  Segment in der Farbe seines Zustands, und die **Fläche darunter gefüllt** in
  einer abgedunkelten Variante derselben Farbe. Eine dünne Linie muss man
  suchen, eine gefüllte Fläche sieht man einfach.
- **Achsen**: Gitterlinien oben, in der Mitte und unten, die Grenzwerte links
  ausdrücklich mit **MAX** und **MIN** beschriftet. Welches Ende welches ist,
  ist offensichtlich, wenn man das Diagramm betrachtet, und überhaupt nicht
  offensichtlich, wenn man mitten im Intervall hinschaut. Drei Anordnungen, je
  nach Platz: Die Wörter stehen über ihren Zahlen, wo die Höhe dafür reicht,
  daneben, wo nicht, und fallen ganz weg, wo sie nebeneinander mehr als ein
  Viertel der Plotbreite kosten würden. Letzteres ist das halbseitige
  Datenfeld, wo die Benennung ein Drittel des Diagramms gekostet hat, um etwas
  zu sagen, was die Zahlen schon sagten.
- **Lap-Marker** als vertikale Linien
- **Prognose-Nadel**: ein Dreieck am rechten Rand, das auf die Höhe zeigt, auf
  die der Trend zuläuft, in der Zustandsfarbe. Es liest sich wie ein Zeiger auf
  einem Armaturenbrett, und genau das ist die Absicht: eine Marke außen an der
  Skala, die sagt, wohin der Wert läuft, und kein eigener Messpunkt. Es ersetzt
  einen kleinen grauen Punkt, der mitten im Verlauf saß und wie ein verirrter
  Messwert wirkte.
- **Rate** in der Zustandsfarbe, darunter die **externe Last**. Bei Entkopplung
  wird die Last rot und bekommt `DEC` angehängt; die Zeile wird einmal für die
  breiteste Zeichenkette dimensioniert, die sie je hält, und das Wort
  auszuschreiben würde die Pace zwei Schriftstufen kosten für ein Flag, das die
  Farbe schon trägt.

SCI wird nicht angezeigt. Die Kennzahl ist einheitenlos und in Bewegung schwer
zu lesen, und die Rate sagt dasselbe in handlungsfähigen Einheiten. Ins FIT
wird sie weiterhin geschrieben.

### Medium (ab 120 × 70 px) und Compact (alles darunter)

Eine **Ampel** und eine Zahl, als eine Gruppe mittig in der Zelle: erst das
Licht, dann die Zahl. Die Leserichtung läuft von links nach rechts, also soll
das Urteil vor dem Wert stehen, den es einordnet. Die Scheibe ist genau so hoch
wie die Ziffern. Alles andere liest sich als zwei Elemente in zwei Größen statt
als eine Einheit.

Eine farbige Scheibe wird präattentiv erkannt, ein Wort nicht. Eine erloschene
Ampel wird als grauer Ring gezeichnet und nicht als gar nichts, damit ein
Sensorabriss nicht wie ein Layoutfehler aussieht.

Die Zahl ist einstellbar: **SmO₂**, die **Änderungsrate**, **THb** oder der
**Control-Index**. Die Farbe ändert dabei nie ihre Bedeutung.

Wo die Höhe reicht, ergänzt die Medium-Stufe eine **zweite Zeile**, im Standard
die **Änderungsrate**. Das ist die aussagekräftigere Zahl: Die
Zustandsklassifikation wird aus der Rate berechnet, sie bewegt sich also, bevor
sich die Farbe bewegt. Alternativ lässt sich dort der Name der Metrik anzeigen
oder die Zeile abschalten. Ist die Hauptzahl bereits die Rate, fällt die zweite
Zeile auf den Namen zurück, statt dasselbe zweimal zu sagen.

### Angezeigte Steigung

Angezeigt wird die Regressionssteigung, nicht der schnelle Holt-Trend. Eine
Zahl, die der Farbe widerspricht, würde nur verwirren.

Die Einheit lässt sich zwischen **%/s** und **%/min** umschalten. %/s ist die
natürliche Einheit der Regression, aber am Plateau steht dort −0,01 und jede
interessante Stelle liegt hinter dem Komma; %/min hebt die Zahlen in einen
Bereich, den man auf einen Blick vergleichen kann.

### Farben und Symbole

Standard ist die intuitive Ampel-Zuordnung. Die Farbenblind-Variante ersetzt die
Rot-Grün-Achse durch eine Blau-Magenta-Achse (Cyan / Weiß / Violett / Bernstein
/ Magenta), die unter Deuteranopie und Protanopie unterscheidbar bleibt.

Ein Palettenwechsel ist allerdings immer noch nur ein Kanal, und etwa jeder
zwölfte Mann kann genau den nicht lesen, auf den sich dieses Feld am stärksten
stützt. Deshalb trägt die Zustandsampel zusätzlich ein **Symbol**, und die fünf
bilden eine Familie: wie viele Chevrons, und in welche Richtung.

| Zustand | Symbol |
|---|---|
| RECOVER | ein Chevron nach oben |
| HOLDING | ein waagerechter Balken |
| DRIFTING | ein Chevron nach unten |
| FALLING | zwei Chevrons nach unten, übereinander |
| ONSET | ein Balken, darunter ein abfallendes Chevron |

Es sind Striche und keine gefüllten Symbole, denn ein Strich behält seine
Identität bei zwölf Pixeln Breite, wo ein gefülltes Symbol zum Klecks wird. Sie
werden in der Hintergrundfarbe aus der Scheibe ausgestanzt, damit jedes als
Loch im Licht gelesen wird und nicht als zweites Objekt darauf. Connect IQ
kennt keine runden Linienenden, also wird an jedem Eckpunkt der Polylinie eine
Scheibe gezeichnet; daraus entstehen die runden Enden und Ecken. Die
zweiteiligen Symbole werden etwas kleiner und dünner gezeichnet als die
einteiligen, sonst läuft das obere Element durch den Rand des Kreises hinaus.

Unter einem Radius von 7 px ist kein Platz für ein Symbol, dann trägt die
Scheibe die Bedeutung allein.

Dieselben Symbole funktionieren in gleißender Sonne, durch einen nassen
Bildschirm und auf den Graustufen-MIP-Displays, auf denen die Palette ohnehin
zusammenfällt. Deshalb sind sie standardmäßig an und nicht hinter der
Farbenblind-Einstellung versteckt.

---

## 6. Pace-/Power-Kopplung und Entkopplungserkennung

Ist die Anzeige aktiviert, zeigt das Feld die externe Last, gewählt nach
Sportart: **Power in Watt auf dem Rad, Pace überall sonst**. Laufen nach Watt
ist Geschmackssache und die Laufleistung einer Uhr ist verrauscht, deshalb ist
Pace der Default beim Laufen. Die Pace folgt den Einheiten der Uhr.

Der informative Moment ist die **Entkopplung**. Über ein 30-Sekunden-Fenster
wird der Variationskoeffizient der Last berechnet. Liegt er unter 4 %, die
externe Last ist also konstant, und befindet sich SmO₂ gleichzeitig in CONTROL
oder OVER, erscheint der Hinweis `DECOUPLING`. Das bedeutet: bei gleichbleibender
äußerer Last sinkt die Muskeloxygenierung weiter. Das ist beginnende Ermüdung
beziehungsweise Effizienzverlust, und es ist in keinem der beiden Signale allein
sichtbar.

---

## 7. Sensoranbindung

SmO₂ und THb wurden nie in die native Sensordaten-API von Connect IQ
aufgenommen. Das Datenfeld öffnet deshalb **selbst** einen generischen
ANT-Kanal und wertet das ANT+ Muscle-Oxygen-Profil (Data Page 1) aus.

> **Wichtig:** Der Moxy darf **nicht** zusätzlich nativ in der Sensorliste der
> Uhr gekoppelt sein. Ein Sensor kann nur einen ANT-Kanal halten; wer zuerst
> zugreift, blockiert den anderen.

**Kanalparameter:** Device Type 31, Message Period 8192, Radio Frequency 57,
Netzwerk ANT+. Die Sensor-ID ist einstellbar; 0 koppelt an den ersten gefundenen
Moxy, ein konkreter Wert verhindert Fremdkopplung im Studio oder Verein.

**Zustandsautomat:** `SEARCHING → TRACKING → STALE → TRACKING` sowie
`→ CLOSED → SEARCHING`.

- **STALE**, wenn der Event Count länger als 5 Sekunden unverändert bleibt. In
  diesem Fall wird die Trendberechnung eingefroren, damit ein eingefrorener
  Messwert nicht als echte Steigung null missdeutet wird. Das Regressionsfenster
  wird geleert, weil ein Fit über eine Lücke eine Steigung erfinden würde, die
  es nie gab.
- Bei `EVENT_CHANNEL_CLOSED` wird der Kanal automatisch wieder geöffnet.
- Bei `RX_FAIL_GO_TO_SEARCH` geht der Kanal zurück in die Suche.

**Gültigkeitsprüfung.** Die Profil-Codes für „ungültig" und „Umgebungslicht zu
hell" werden auf den *rohen* Feldern geprüft, bevor skaliert wird, und ergeben
`null`, niemals 0 %. Ein SmO₂-Wert von 0 % sieht physiologisch plausibel aus
und wäre damit eine besonders gefährliche Falschangabe. Das offizielle
MoxyField-Beispiel des SDK macht das falsch.

**Ressourcenschonung.** `getPayload()` wird pro Nachricht genau einmal
aufgerufen, weil es allokiert. In `onMessage()` wird kein `requestUpdate()`
ausgelöst; das Feld liest den zuletzt geparsten Wert in `compute()` ab, was den
ANT-Takt sauber vom Render-Takt entkoppelt.

---

## 8. Aufzeichnung im FIT

**Record-Felder** (~1 Hz, in Garmin Connect als Diagramm):

| Feld | Einheit |
|---|---|
| `smo2`, geglättete Muskeloxygenierung | % |
| `smo2Trend`, Regressionssteigung | %/s |
| `sci`, SmO₂ Control Index | keine |
| `smo2State`, Zustand als Zahl | keine |
| `thb`, Gesamthämoglobin | g/dl |

**Lap-Felder** (in der Rundenübersicht):

| Feld | Einheit |
|---|---|
| `lapDesatRate`, Desaturationsrate `(Ende − Start) / Lap-Dauer` | %/s |
| `lapOnKinRate`, steilste Steigung des On-Transienten | %/s |
| `lapSmo2Min`, `lapSmo2Max` | % |

**Session-Feld:** `avgSmo2`, Durchschnitt über die Einheit. Der Durchschnitt
läuft nur bei laufendem Timer weiter; zehn Minuten Stehen mit angelegtem Sensor
verfälschen ihn nicht.

`setData()` wird nur bei tatsächlicher Wertänderung aufgerufen, damit Smart
Recording die Datei nicht unnötig aufbläht. Die Aufzeichnung ist abschaltbar.

---

## 9. Einstellungen

| Einstellung | Default | Bedeutung |
|---|---|---|
| `moxyDeviceNumber` | 0 | ANT-ID des Sensors, 0 = erster gefundener |
| `smoothingAlpha100` | 30 | Holt Level-α × 100. Höher = reaktiver, unruhiger |
| `smoothingBeta100` | 15 | Holt Trend-β × 100 |
| `predictHorizon` | 15 | Prognosehorizont in Sekunden, 0 = aus |
| `steadyWindowSec` | 60 | Länge des Regressionsfensters |
| `thetaStable1000` | 60 | θ_stable × 1000, Grenze Plateau/Abfall |
| `thetaDrift1000` | 150 | θ_drift × 1000, Grenze kontrolliert/überzogen |
| `chartWindowSec` | 90 | Zeitfenster der Sparkline |
| `yAxisMode` | Auto | Auto (letzte Minuten) / Session-Range / fest 20 bis 80 % / fest 0 bis 100 % |
| `baselineSec` | 60 | Länge der Baseline-Erfassung |
| `colorBlind` | aus | Farbenblind-Palette |
| `stateIcons` | an | Symbol in der Zustandsampel, damit das Urteil nicht allein an der Farbe hängt |
| `plainLabels` | an | Zustände in Klartext benennen (RECOVER/HOLDING/DRIFTING/FALLING/ONSET) statt kinetisch (REOXY/STEADY/CONTROL/OVER/ON-KIN) |
| `smallMetric` | SmO₂ | Was die diagrammlosen Stufen neben der Ampel zeigen: SmO₂, Änderungsrate, THb oder Control-Index |
| `smallSecond` | Rate | Zweite Zeile unter dieser Zahl: nichts, Name der Metrik oder Änderungsrate |
| `rateUnit` | %/s | Einheit der angezeigten Rate: %/s oder %/min |
| `rangeScope` | Einheit | Ob sich MIN/MAX und der Session-Modus der Y-Achse auf die gesamte Einheit oder die aktuelle Runde beziehen |
| `showPace` | an | Pace-/Power-Zeile inklusive Entkopplungs-Flag |
| `recordFit` | an | SmO₂-Felder ins FIT schreiben |

Fließkomma-Einstellungen sind als Ganzzahlen gespeichert (× 100 bzw. × 1000),
weil der Connect-IQ-Einstellungseditor auf nicht allen Geräten eine verlässliche
Fließkommaeingabe bietet.

Die Y-Achse nutzt nie 0 bis 100 %: beim Moxy spielt sich praktisch alles zwischen
etwa 20 und 80 % ab, und die Hälfte der Pixel für nie auftretende Werte zu
reservieren verschenkt genau die Auflösung, auf die es ankommt.

Der Default **Auto** skaliert auf das, was gerade zu sehen ist, mit einem
**Boden von 25 Prozentpunkten** auf die sichtbare Spannweite. Dieser Boden ist
die gesamte Absicherung. Ohne ihn würde ein totes Plateau so weit gezoomt, bis
sein eigenes Rauschen das Diagramm füllt und nach wildem Auf und Ab aussieht,
das genaue Gegenteil der Aussage, für die es das Feld gibt. Über fünf Einheiten
gemessen umfasst ein 90-s-Fenster im Plateau typisch 4,8 Punkte und im
On-Transienten 22,5, ein Boden von 25 hält ein Plateau also bei etwa einem
Fünftel der Höhe, während eine echte Desaturierung das Bild füllt. Alternative
ist **Session-Range**: eine Skala, die sich nie bewegt, um den Preis, dass der
Verlauf oft nur einen kleinen Teil des Diagramms nutzt.

---

## 10. Werkzeuge zur Parameterabstimmung

Die Schwellen an der Uhr abzustimmen ist langsam und ungenau. Zwei Werkzeuge
erlauben die Abstimmung an den eigenen aufgezeichneten Intervallen.

**`tools/kinetics_replay.py`** ist eine originalgetreue Python-Portierung von
`source/Kinetics.mc`. Sie liest `.fit`-Dateien direkt von der Uhr oder CSV,
bricht die Einheit nach Laps auf und gibt pro Intervall ein Urteil aus:

```
 per-interval summary
  lap        dur  start    end     rate    onkin    min    max  verdict
  lap02      299   72.0   50.6   -0.072   -0.446   44.3   72.0  sustainable (steady 49%)
  lap04      299   62.8   45.1   -0.059   -0.438   41.6   62.8  sustainable (steady 60%)
```

Zusätzlich: Zustandsverteilung, RMS-Residuum, komprimierte Zeitleiste und ein
Rastersuchlauf über α und β (`--sweep`). Die Parameter bilden direkt auf die
App-Einstellungen ab.

**`tools/fitreader.py`** ist ein abhängigkeitsfreier FIT-Decoder, kein
`pip install` nötig. Er liest SmO₂ aus den nativen Record-Feldern und erkennt
automatisch Developer-Felder anderer Aufzeichnungs-Apps, deren Feldname die
Sensor-ID enthält. Lap-Enden werden aus `start_time + total_elapsed_time`
abgeleitet, weil nicht jeder Writer `lap.timestamp` korrekt setzt.

**Modus `--synthetic`** erzeugt eine Einheit mit bekannter Grundwahrheit: zwei
nachhaltige und zwei nicht nachhaltige Intervalle, und dient als
Regressionstest der Klassifikation.

---

## 11. Geräteunterstützung

55 Produkte mit ANT+-Funk: Forerunner 245 bis 970, Fenix 6 bis 8, Epix Gen 2,
Enduro, MARQ Gen 2 sowie Edge 530 bis 1050. Geräte ohne ANT+-Radio können
prinzipbedingt nicht mit einem Moxy sprechen und sind bewusst ausgeschlossen.

Benötigte Berechtigungen: ANT, FitContributor. Oberflächensprachen: Englisch und
Deutsch.

---

## 12. Bekannte Grenzen

**Der Simulator kann kein SmO₂ liefern.** Die FIT-Wiedergabe des Connect-IQ-
Simulators speist keine generischen ANT-Kanäle. Im Simulator steht das Feld
dauerhaft auf `SEARCH`, und das ist korrektes Verhalten. Für Live-Daten wird
SimulANT+ mit einem ANT-USB-Stick benötigt; für Arbeit am Modell das
Replay-Werkzeug.

**θ_drift ist schwächer belegt als θ_stable.** In den fünf zur Kalibrierung
verwendeten Einheiten plateauen alle Arbeitsintervalle, denn sie wurden korrekt
gefahren. Damit fehlt ein echtes „über der Schwelle"-Intervall, und die
Drift-Grenze stammt weiterhin aus synthetischen Daten. Eine Einheit mit bewusst
zu hartem Start würde diese Schwelle empirisch absichern.

**Nicht implementiert:** eine modellierte Kennzahl „SmO₂-Kosten pro
Pace-Einheit" sowie die Analyse des Reoxygenierungs-Overshoots in der Erholung.
