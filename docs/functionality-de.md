# SmO2 Control — Vollständige Funktionsbeschreibung

Garmin Connect IQ Datenfeld für Muskeloxygenierung (SmO₂) mit einem Moxy-Sensor.

---

## 1. Die Kernidee

Der absolute SmO₂-Wert ist zwischen Einheiten kaum vergleichbar. Er hängt ab von
Sensorposition (Millimeter zählen), Fettschichtdicke über dem Muskel,
Anpressdruck der Halterung, Hautdurchblutung, Temperatur und Tagesform. Ein
Datenfeld, das „SmO₂ = 34 %" anzeigt, gibt dem Athleten deshalb keine
handlungsfähige Information.

Innerhalb einer Einheit ist das Signal dagegen sehr aussagekräftig — nicht als
Absolutwert, sondern als **Kinetik**:

1. **Rapide Desaturierung** zu Intervallbeginn: Verbrauch übersteigt Angebot.
   Die Steilheit dieses Abfalls korreliert mit der metabolischen Rate.
2. **Plateau oder fortgesetzter Drift**: Erreicht SmO₂ ein stabiles Plateau,
   balancieren sich Angebot und Verbrauch — die Intensität ist nachhaltig.
   Driftet der Wert weiter nach unten, kann das Angebot nicht mehr folgen — die
   Intensität liegt über dem nachhaltigen Punkt.
3. **Reoxygenierung** in der Pause, oft mit Overshoot über den Ausgangswert.

Die Nachricht des Datenfelds an den Athleten in Echtzeit lautet deshalb nicht
„34 %", sondern: *fällt gerade / stabilisiert sich / driftet weiter / erholt
sich* — und wie schnell.

---

## 2. Zustandsklassifikation

Fünf Zustände, jeder mit eigener Farbe:

| Zustand | Farbe | Bedeutung |
|---|---|---|
| **ON-KIN** | Orange | Rapide Desaturierung — der On-Transient zu Intervallbeginn |
| **OVER** | Rot | Abfall setzt sich fort — über dem nachhaltigen Punkt |
| **CONTROL** | Gelb | Langsamer Abfall — fordernd, aber kontrolliert |
| **STEADY** | Grün | Flach — Angebot deckt Verbrauch, nachhaltig |
| **REOXY** | Blau | Steigend — Erholung oder zu geringe Intensität |

Die wichtigste Unterscheidung ist **ON-KIN gegen OVER**. Jedes harte Intervall
beginnt mit einem steilen Abfall; dieser Abfall ist noch kein Urteil. Was ein
nachhaltiges von einem nicht nachhaltigen Intervall trennt, ist die Frage, ob
danach das Plateau eintritt. Ein Feld, das den Transienten als „überzogen"
bewertet, färbt jedes harte Intervall in seiner ersten Minute rot und ist damit
wertlos.

Alle Zustandsgrenzen besitzen eine Hysterese von ±15 %, damit die Farbe an einer
Schwelle nicht flackert.

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
Samples 0,15 %/s — und zwar *innerhalb eines bombenfesten Plateaus*. Das Signal
bewegt sich real so schnell; das ist kein Glättungsartefakt, und keine Schwelle
auf diesem Trend kann etwas trennen. Ihn zu verlangsamen hilft ebenfalls nicht:
ein exponentieller Filter hat einen unendlichen Schwanz und trägt den
On-Transienten immer weiter mit, kommt also innerhalb eines Intervalls nie zur
Ruhe. Ein endliches Fenster *vergisst* den Transienten, sobald er hinausrutscht.
Für die Frage „ist das Plateau da?" ist Vergessen genau das gewünschte Verhalten.

**Warum 60 Sekunden?** Gemessen an fünf echten Schwellen-Einheiten:

- bei 45 s ist das Plateau-Band ±0,08 %/s — echter Drift verschwindet darin
- bei 90 s verdünnt sich der On-Transient in die vorausgegangene Erholung und
  wird gar nicht mehr erkannt
- bei 60 s liegt die Plateau-Steigung innerhalb von ±0,06 %/s (10.–90.
  Perzentil), während der Transient −0,23 %/s unterschreitet

### 3.3 Schwellen

| Schwelle | Default | Herkunft |
|---|---|---|
| θ_stable | 0,06 %/s | 10.–90. Perzentil der Plateau-Steigung, fünf Sessions |
| θ_drift | 0,15 %/s | Grenze des normalen Plateau-Verhaltens |
| θ_onkin | 2 × θ_drift | zwischen Plateau-Extrem und Transient-Steilheit |

Die On-Kinetik-Schwelle ist von θ_drift abgeleitet statt eine eigene Einstellung
zu sein, damit sie beim Tuning automatisch mitskaliert.

### 3.4 Behandlung des On-Transienten

Sobald die Regressionssteigung unter θ_onkin fällt, gilt der Zustand als
On-Transient. Endet der Abfall, wird das Regressionsfenster **neu gestartet**,
damit die Plateau-Frage ausschließlich aus Post-Transient-Daten beantwortet
wird. Bis das Fenster wieder gefüllt ist (ein Drittel der Fensterlänge, also
20 s), meldet das Feld weiterhin ON-KIN — das ist die ehrliche Antwort
„noch nicht entschieden".

Ein Lap-Druck gilt ebenfalls als Lastwechsel und startet das Fenster neu.

Die steilste erreichte Steigung des Transienten wird pro Lap festgehalten und
ins FIT geschrieben, weil sie mit der metabolischen Rate korreliert.

---

## 4. Session-interne Kalibrierung

Da Absolutwerte zwischen Einheiten nicht vergleichbar sind, wird alles auf ein
innerhalb der Einheit dynamisch kalibriertes Fenster bezogen.

**Stufe 1 — Baseline.** Median der ersten 60 Sekunden gültiger Daten (Fenster
einstellbar). Dient als Referenz-Oben. Bei langen Fenstern wird unterabgetastet,
maximal 120 Samples werden gehalten.

**Stufe 2 — Rollendes Session-Min/Max.** Wird ausschließlich aus *geglätteten*
Werten fortgeschrieben, damit ein einzelner Sensor-Spike die Range nicht
definieren kann. Beide Extreme relaxieren mit 0,02 %/s zurück zum aktuellen
Wert, sobald sie mehr als 3 % davon entfernt sind — so verzerrt ein einmaliger
Ausreißer die Skalierung nicht für den Rest der Einheit.

**Stufe 3 — Lap-Kalibrierung.** Der erste Lap wird als Referenzintervall
behandelt; sein Start- und Endwert verankern das Arbeitsband. Ein zweiter
Lap-Druck innerhalb von 2 Sekunden setzt die Session-Range zurück — gedacht für
den Fall, dass der Sensor während der Einheit umgesetzt wird.

**Stufe 4 — Relative Schwellen.** θ_stable und θ_drift sind in %/s definiert,
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

### Full (ab 200 × 150 px)

- Großer SmO₂-Wert links, in der Zustandsfarbe
- Rechts dreizeilig: Zustandslabel, Steigung in %/s, SCI
- **Sparkline** über das Diagrammfenster (Default 90 s), jedes Liniensegment in
  der Farbe des Zustands an diesem Punkt
- **Lap-Marker** als vertikale Linien
- **Kalibrierungsbänder**: dünne horizontale Linien bei Session-Min und -Max
- **Prognose-Marker**: ausgegraute Linie plus Punkt am rechten Rand
- Untere Zeile: Pace bzw. Power, rechts die Session-Range

### Medium (ab 120 × 70 px)

Wert links in der Zustandsfarbe, Trendpfeil darunter, Mini-Sparkline rechts.

### Compact (alles darunter)

Kein Diagramm. Der Zustand wird vollständig von der **Hintergrundfarbe**
getragen, davor der Wert in Schwarz und ein Trendpfeil — lesbar auf einen Blick
aus einem Vier-Feld-Layout.

### Angezeigte Steigung

Angezeigt wird die Regressionssteigung, nicht der schnelle Holt-Trend. Eine
Zahl, die der Farbe widerspricht, würde nur verwirren.

### Farben

Standard ist die intuitive Ampel-Zuordnung. Die Farbenblind-Variante ersetzt die
Rot-Grün-Achse durch eine Blau-Magenta-Achse (Cyan / Weiß / Violett / Bernstein
/ Magenta), die unter Deuteranopie und Protanopie unterscheidbar bleibt.

---

## 6. Pace-/Power-Kopplung und Entkopplungserkennung

Ist die Anzeige aktiviert, zeigt das Feld die externe Last: Power in Watt, falls
verfügbar, sonst Pace in min/km.

Der informative Moment ist die **Entkopplung**. Über ein 30-Sekunden-Fenster
wird der Variationskoeffizient der Last berechnet. Liegt er unter 4 % — die
externe Last ist also konstant — und befindet sich SmO₂ gleichzeitig in CONTROL
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
`null` — niemals 0 %. Ein SmO₂-Wert von 0 % sieht physiologisch plausibel aus
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
| `smo2` — geglättete Muskeloxygenierung | % |
| `smo2Trend` — Regressionssteigung | %/s |
| `sci` — SmO₂ Control Index | — |
| `smo2State` — Zustand als Zahl | — |
| `thb` — Gesamthämoglobin | g/dl |

**Lap-Felder** (in der Rundenübersicht):

| Feld | Einheit |
|---|---|
| `lapDesatRate` — Desaturationsrate `(Ende − Start) / Lap-Dauer` | %/s |
| `lapOnKinRate` — steilste Steigung des On-Transienten | %/s |
| `lapSmo2Min`, `lapSmo2Max` | % |

**Session-Feld:** `avgSmo2` — Durchschnitt über die Einheit. Der Durchschnitt
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
| `yAxisMode` | Auto | Auto (Session-Range) / fest 20–80 % / fest 0–100 % |
| `baselineSec` | 60 | Länge der Baseline-Erfassung |
| `colorBlind` | aus | Farbenblind-Palette |
| `showPace` | an | Pace-/Power-Zeile samt Entkopplungshinweis |
| `recordFit` | an | SmO₂-Felder ins FIT schreiben |

Fließkomma-Einstellungen sind als Ganzzahlen gespeichert (× 100 bzw. × 1000),
weil der Connect-IQ-Einstellungseditor auf nicht allen Geräten eine verlässliche
Fließkommaeingabe bietet.

Die Y-Achse skaliert im Auto-Modus auf die Session-Range plus Rand statt auf
0–100 %, weil sich beim Moxy praktisch alles zwischen etwa 20 und 80 % abspielt.
Die Hälfte der Pixel für nie auftretende Werte zu reservieren, verschenkt genau
die Auflösung, auf die es ankommt.

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

**`tools/fitreader.py`** ist ein abhängigkeitsfreier FIT-Decoder — kein
`pip install` nötig. Er liest SmO₂ aus den nativen Record-Feldern und erkennt
automatisch Developer-Felder anderer Aufzeichnungs-Apps, deren Feldname die
Sensor-ID enthält. Lap-Enden werden aus `start_time + total_elapsed_time`
abgeleitet, weil nicht jeder Writer `lap.timestamp` korrekt setzt.

**Modus `--synthetic`** erzeugt eine Einheit mit bekannter Grundwahrheit — zwei
nachhaltige und zwei nicht nachhaltige Intervalle — und dient als
Regressionstest der Klassifikation.

---

## 11. Geräteunterstützung

55 Produkte mit ANT+-Funk: Forerunner 245–970, Fenix 6 bis 8, Epix Gen 2,
Enduro, MARQ Gen 2 sowie Edge 530 bis 1050. Geräte ohne ANT+-Radio können
prinzipbedingt nicht mit einem Moxy sprechen und sind bewusst ausgeschlossen.

Benötigte Berechtigungen: ANT, FitContributor. Oberflächensprachen: Englisch und
Deutsch.

---

## 12. Bekannte Grenzen

**Der Simulator kann kein SmO₂ liefern.** Die FIT-Wiedergabe des Connect-IQ-
Simulators speist keine generischen ANT-Kanäle. Im Simulator steht das Feld
dauerhaft auf `SEARCH` — das ist korrektes Verhalten. Für Live-Daten wird
SimulANT+ mit einem ANT-USB-Stick benötigt; für Arbeit am Modell das
Replay-Werkzeug.

**θ_drift ist schwächer belegt als θ_stable.** In den fünf zur Kalibrierung
verwendeten Einheiten plateauen alle Arbeitsintervalle — sie wurden korrekt
gefahren. Damit fehlt ein echtes „über der Schwelle"-Intervall, und die
Drift-Grenze stammt weiterhin aus synthetischen Daten. Eine Einheit mit bewusst
zu hartem Start würde diese Schwelle empirisch absichern.

**Nicht implementiert:** eine modellierte Kennzahl „SmO₂-Kosten pro
Pace-Einheit" sowie die Analyse des Reoxygenierungs-Overshoots in der Erholung.
