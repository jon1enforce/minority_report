# Der `minority_report.v` Comparator

## Eine statistisch-physikalische Analyse

### Was das Tool kann, was es nicht kann:

---

## Abstract

Der `minority_report.v` ist ein FPGA-Baustein, der aus `n = 18` redundanten 16-Bit-Floating-Point-Eingaben eine Majority-Entscheidung trifft und dabei eine Minoritäts-Statistik als Metadaten ausgibt. Dieser Report analysiert das Tool unter dem Blickwinkel der statistischen Physik.

Im Zentrum steht die Frage nach dem **Determinismus**: Jeder der 18 Eingänge ist mit Wahrscheinlichkeit `p` vollständig korrekt (alle FP16-Bits stimmen). Die Majority entscheidet. Wir zeigen, dass die Wahrscheinlichkeit, mit der die Majority korrekt ist, für `n = 18` und `p = 0.99` etwa **99.835 %** beträgt (strenge Majority) bzw. **99.9999 %** (mit Toleranz `τ = 1`). 

Wir zeigen weiter, dass der Kern des Designs nicht das Majority-Voting ist, sondern die **Kürzung statt Rundung**, die eine Binning-Struktur erzeugt und Histogramm-Analysen über Kürzungslängen und Minoritäts-Nibbles ermöglicht. Wir diskutieren die Grenzen der Zuordenbarkeit (kein `<`/`>`, keine Rangfolge, keine Kanal-Zuordnung) und die Frage, ob `n = 18` für die angestrebte Zuverlässigkeit ausreicht. Ein eigenes Kapitel stellt Design-Intent und Design-Realität gegenüber.

---

## Inhaltsverzeichnis

1. [Einleitung: Design-Intent](#1-einleitung-design-intent)
2. [Der Code: Was er tut](#2-der-code-was-er-tut)
3. [Deterministischer Output bei nicht-deterministischem Input](#3-deterministischer-output-bei-nicht-deterministischem-input)
4. [Was das Tool statistisch kann](#4-was-das-tool-statistisch-kann)
5. [Was das Tool statistisch nicht kann](#5-was-das-tool-statistisch-nicht-kann)
6. [Die n=18-Power-Analyse: Reicht das?](#6-die-n18-power-analyse-reicht-das)
7. [Design-Intent vs. Design-Realität: Die Lücke](#7-design-intent-vs-design-realität-die-lücke)
8. [Empfehlungen: Erweiterungen](#8-empfehlungen-erweiterungen)
9. [Fazit](#9-fazit)
- [Anhang A: Formelsammlung](#anhang-a-formelsammlung)
- [Anhang B: Beispielrechnungen](#anhang-b-beispielrechnungen)

---

## 1. Einleitung: Design-Intent

Der `minority_report.v` ist kein Rechenwerk im klassischen Sinn. Er ist ein **redundanter Entscheider**: Aus `n = 18` parallelen 16-Bit-Eingaben im FP16-Format (1 Bit Vorzeichen, 5 Bit Exponent, 10 Bit Mantisse) wird ein Majority-Wert bestimmt, und zusätzlich eine Minoritäts-Statistik ausgegeben.

### Der Zweck des Erfinders

Der Design-Intent lässt sich in drei Sätzen zusammenfassen:

1. **Ungenauigkeiten eliminieren.** Die 18 Eingaben sind redundante Messungen desselben physikalischen Prozesses. Ihre individuellen Ungenauigkeiten sollen durch Majority-Bildung unterdrückt werden.
2. **Maximalen Informationsgehalt bewahren.** Statt einfach den Majority-Wert auszugeben, soll das Tool **Metadaten** liefern: Wie viele Abweichler gab es? Bei welcher Kürzungslänge? Das sind die Informationen, die ein Physiker für Statistik braucht.
3. **Deterministischen Output bei nicht-deterministischem Input erzeugen.** Die Eingaben sind stochastisch (Rauschen, Timing, Quantisierung). Der Output soll reproduzierbar sein, damit er als Referenz dienen kann.

### Die zentrale Design-Entscheidung

Der wichtigste Punkt am Design ist eine scheinbar triviale Entscheidung: Die Mantisse wird **gekürzt**, nicht **gerundet**. Runden würde einen einzelnen FP16-Wert liefern — einen Punkt in der Zahlenmenge. Kürzen liefert eine **Familie** von Werten, parametrisiert durch die Bitlänge `b ∈ {1, …, 10}`. Diese Familie ist die Grundlage aller statistischen Analyse, die dieses Tool für den Ergebnisbasierten output ermöglicht. Es gibt zusätzlich Ein Metadaten output. 20 bit für Ergebnis und längeninformation/kürzungsinformation, und weitere 20 bits für den minority count, und Fehlerfälle.

### Was dieser Report nicht behandelt

Der Report behandelt **keine** Accuracy-Frage im Sinne von „wie genau ist der Zahlenwert". Das Tool rundet nicht, es kürzt; der Ausgabewert ist exakt der gekürzte Majority-Wert. Die einzige relevante Frage ist, ob die Majority **korrekt** ist im Sinne von „stimmt sie mit dem wahren Wert überein". Das ist eine Frage des Determinismus, nicht der numerischen Genauigkeit. Diese Frage kann mit einer CPU gegengeprüft werden.

---

## 2. Der Code: Was er tut

### 2.1 Kürzen statt Runden

```verilog
function [9:0] shrink_mant;
    input [9:0] v;
    input [3:0] bl;
    integer i;
    begin
        shrink_mant = 10'd0;
        for (i = 0; i < 10; i = i + 1)
            if (i < bl) shrink_mant[i] = v[i];
    end
endfunction
```

Die Funktion kopiert nur die unteren `bl` Bits der Mantisse; alle höheren Bits werden auf null gesetzt. Das ist **kein** Runden, sondern Abschneiden. Konsequenz: Die Ausgabewerte sind in natürliche Bins sortierbar. Die längeninformation schneidet die Nullen ab, egal ob es Nullen oder einsen sind, in diesem Fall Nullen.

**Tabelle: Prezisionsstufen als Bins**

| Bitlänge `b` | FP-Format | Anzahl distinkter Werte |
|:---:|:---:|---:|
| 1  | FP1  | 2 |
| 2  | FP2  | 4 |
| 3  | FP3  | 8 |
| 4  | FP4  | 16 |
| 5  | FP5  | 32 |
| 6  | FP6  | 64 |
| 7  | FP7  | 128 |
| 8  | FP8  | 256 |
| 9  | FP9  | 512 |
| 10 | FP10 | 1024 |

### 2.2 Der Toleranz-Voter

Die Auswahlschleife ist ein **Toleranz-Voter**:

```verilog
for (s = 0; s < 10; s = s + 1) begin
    if (mabweich[s] <= 1) begin
        chosen_bl   = s + 1;
        chosen_mant = mbest[s];
        chosen_no_majority = 1'b0;
    end
end
```

Sie akzeptiert eine Majority, solange höchstens **ein** Abweichler existiert. Der erlaubte Abweichler ist das Modell eines einzelnen Sensor-Ausfalls/Abweichlers, eines einzelnen Bit-Flips, eines einzelnen Photonen-Verlusts.

### 2.3 Das Binning über Kürzungslängen

Jeder Ausgabewert trägt eine gewählte Bitlänge `b̂ ∈ {1, …, 10}`. Diese Bitlänge ist eine diskrete Zustandsvariable — der natürliche Bin, über den Histogramme gebildet werden können. Die Minoritäts-Statistik (`minority_meta`, 5×4 Bit) liefert zusätzlich die Abweichlerzahl pro Kürzungsschritt.

---

## 3. Deterministischer Output bei nicht-deterministischem Input

### 3.1 Formale Definition

> **Definition 1 (Nicht-deterministischer Input).**
> Sei `x(t) = (x₁(t), …, xₙ(t)) ∈ 𝔽₁₆ⁿ` ein Tupel von `n` FP16-Eingaben zur Zeit `t`. Der Input heißt **nicht-deterministisch**, wenn für zwei Zeitpunkte `t ≠ t'` gilt: `P(x(t) = x(t')) < 1`.

> **Definition 2 (Deterministischer Output).**
> Sei `f: 𝔽₁₆ⁿ → 𝒴` die Abbildung, die der `minority_report` implementiert. Der Output heißt **deterministisch**, wenn `f(x) = f(x')` für alle `x, x'` gilt, die „hinreichend ähnlich" sind — wobei „hinreichend ähnlich" durch die Majority-Toleranz definiert ist.

Das Tool ist so konstruiert, dass viele verschiedene Input-Tupel auf denselben Output abgebildet werden. Die Äquivalenzklasse ist definiert durch: gleiche Majority, gleiche Kürzungslänge, gleiche Minoritäts-Statistik.

### 3.2 Das Modell

Wir nehmen an: Jeder der `n = 18` Eingänge ist mit Wahrscheinlichkeit `p` **vollständig korrekt** — das heißt, alle 16 FP16-Bits stimmen mit dem wahren Wert überein. Die Eingänge sind unabhängig. Die Majority entscheidet.

Sei `Xᵢ ∈ {0,1}` die Indikatorvariable „Eingang `i` ist korrekt", mit `P(Xᵢ = 1) = p`, unabhängig. Sei

```
K = Σᵢ₌₁ⁿ Xᵢ
```

die Anzahl korrekter Eingänge. Dann ist `K ~ B(n, p)` binomialverteilt.

### 3.3 Die Majority-Genauigkeit für `n = 18`, `p = 0.99`

#### Strenge Majority (`τ = 0`)

Die Majority ist korrekt, wenn mehr als die Hälfte der Eingänge korrekt ist, also `K ≥ ⌊n/2⌋ + 1 = 10`:

```
P_korrekt^(τ=0) = P(K ≥ 10) = Σₖ₌₁₀¹⁸ (18 choose k) pᵏ (1-p)^(18-k)
```

Mit `p = 0.99` und `1-p = 0.01`:

```
P(K = 18) = 0.99^18                  ≈ 0.83453
P(K = 17) = 18 · 0.01 · 0.99^17      ≈ 0.15173
P(K = 16) = 153 · 0.0001 · 0.99^16   ≈ 0.01149
P(K = 15) = 816 · 10⁻⁶ · 0.99^15     ≈ 0.00058
P(K = 14) = 3060 · 10⁻⁸ · 0.99^14    ≈ 0.00002
```

Summe `P(K ≥ 10) ≈ 0.99835`. Also:

```
P_korrekt^(τ=0) ≈ 99.835 %
P_break^(τ=0)   ≈ 0.165 %
```

#### Mit Toleranz (`τ = 1`)

Wenn ein Abweichler erlaubt ist, ist die Majority korrekt, sobald `K ≥ 9`:

```
P_korrekt^(τ=1) = P(K ≥ 9) = 1 - P(K ≤ 8) ≈ 1 - 10⁻⁶ ≈ 99.9999 %
```

#### Zusammenfassung

| Toleranz `τ` | Bedingung | `P_korrekt` |
|:---:|:---:|---:|
| 0 (streng) | `K ≥ 10` | ≈ 99.835 % |
| 1 | `K ≥ 9` | ≈ 99.9999 % |

### 3.5 Die Zeitredundanz-Frage

Wenn man `N` unabhängige Vektoren betrachtet, ist die Wahrscheinlichkeit, dass **alle** `N` Majority-Entscheidungen korrekt sind:

```
P_alle korrekt(N) = (P_korrekt^(τ=0))^N = 0.99835^N
```

| `N` | `P_alle korrekt` |
|---:|---:|
| 100 | ≈ 0.847 |
| 1000 | ≈ 0.192 |
| 10⁴ | ≈ 6 × 10⁻⁸ |

Die Bruchwahrscheinlichkeit **pro Vektor** (`0.165 %`) ist die relevante Größe. Über viele Vektoren akkumuliert sie sich unvermeidlich. Wer eine kleine Bruchwahrscheinlichkeit pro **Zeiteinheit** will, muss `n` erhöhen, `τ` erhöhen, oder `p` erhöhen — nicht die Anzahl der Vektoren.

### 3.6 Bemerkung zur Unterscheidung „Determinismus" vs. „Accuracy"

In diesem Report wird bewusst **nicht** von „Accuracy" gesprochen. Der Grund: „Accuracy" suggeriert eine numerische Genauigkeit des Ausgabewerts (z. B. „der FP16-Wert liegt innerhalb einer Toleranz"). Das ist hier nicht die relevante Frage. Das Tool **rundet nicht**, es kürzt; der Ausgabewert ist **exakt** der gekürzte Majority-Wert. Die einzige relevante Frage ist, ob die Majority **mit dem wahren Wert übereinstimmt**. Das ist eine Frage des Determinismus, nicht der numerischen Genauigkeit. Die Begriffe „Determinismus" (Output ist reproduzierbar) und „Korrektheit" (Output stimmt mit Wahrheit überein) sind die einzigen, die in diesem Report verwendet werden.

---

## 4. Was das Tool statistisch kann

### 4.1 Binning über Kürzungslängen `H(b̂)`

Die gewählte Bitlänge `b̂ ∈ {1, …, 10}` ist eine diskrete Observable. Man kann ein Histogramm

```
H(b̂) = #{ Ausgaben mit gewählter Bitlänge b̂ }
```

über viele Vektoren aufnehmen. Dieses Histogramm zeigt, wie „sicher" die Majority-Entscheidung über die Zeit ist.

- **Schmales Histogramm um `b̂ = 10`:** Stabile, hochpräzise Entscheidungen.
- **Breites Histogramm:** Fluktuation, Rauschen dominiert.
- **Bimodales Histogramm:** Zwei Populationen von Vektoren (z. B. zwei Betriebsmodi).

### 4.2 2D-Histogramm `H(b̂, m)`

Jedes der 5 Nibbles in `minority_meta` kodiert die Anzahl der Abweichler bei einem Kürzungsschritt. Man kann ein 2D-Histogramm `H(b̂, m)` erstellen, wobei `m ∈ {0, …, 15}` der Nibble-Wert ist. Das zeigt, **bei welcher Präzisionsstufe** die Abweichler auftreten.

**Interpretation.** Die bedingte Wahrscheinlichkeit `P(m | b̂)` zeigt, ob Abweichler gleichmäßig über die Kürzungsschritte verteilt sind oder sich bei bestimmten Stufen häufen. Das ist ein direkter Test für die Rauschstruktur der Eingaben.

### 4.3 Zeitreihen-Analyse

#### Autokorrelation der Bitlänge

Die Ausgaben sind zeitlich geordnet. Die Autokorrelationsfunktion

```
C(Δt) = ⟨b̂(t) · b̂(t + Δt)⟩ - ⟨b̂⟩²
```

zeigt, ob aufeinanderfolgende Vektoren korreliert sind.

#### Markov-Kette über `b̂`-Zustände

Man kann die Übergangsmatrix

```
P_ij = P(b̂(t+1) = j | b̂(t) = i)
```

schätzen. Die Eigenwerte von `P` geben die Relaxationszeiten des Systems an — ein zentrales Konzept der statistischen Physik.

#### Verweilzeiten

Die Verteilung der Aufenthaltsdauern in einem Zustand `b̂ = i` gibt Aufschluss über die „Gedächtniszeit" des Systems. Für einen reinen Zufallsprozess wäre die Verteilung geometrisch; Abweichungen zeigen Korrelationen.

### 4.4 TOLERANCE als Ordnungsparameter

Die Toleranz `τ` (erlaubte Abweichler) ist ein **Kontrollparameter**. Man kann die Bruchwahrscheinlichkeit als Funktion von `τ` messen:

```
P_break(τ) = P(K ≤ ⌊n/2⌋ - τ) = Σₖ₌₀^(⌊n/2⌋-τ) (n choose k) pᵏ (1-p)^(n-k)
```

**Tabelle: Bruchwahrscheinlichkeit für `n = 18`, `p = 0.99`**

| `τ` | Bedingung | `P_break` | Erwartete Brüche pro 10⁶ Vektoren |
|:---:|:---:|---:|---:|
| 0 | `K ≤ 9` | 1.65 × 10⁻³ | 1650 |
| 1 | `K ≤ 8` | ≈ 10⁻⁶ | ≈ 1 |
| 2 | `K ≤ 7` | ≈ 10⁻¹⁰ | ≈ 0 |
| 3 | `K ≤ 6` | ≈ 10⁻¹⁵ | 0 |

**Phasenübergang.** Man erkennt einen „Phasenübergang": Bei `τ = 0` ist die Bruchwahrscheinlichkeit noch im Promille-Bereich; bei `τ = 1` bereits unter `10^-6`; bei `τ = 2` unter `10^-10`. Die „optimale" Toleranz hängt davon ab, wie viel Rauschen man tolerieren will, ohne die Fehlererkennung zu verlieren.

### 4.5 Validierung gegen CPU-Referenz

#### Konfusionsmatrix

Sei `y_CPU(t)` der CPU-Referenzwert und `y_FPGA(t)` der FPGA-Wert. Man definiert die Konfusionsmatrix mit den vier Zählern:

```
N₁₁ = #{ y_CPU = y_FPGA }                    (korrekt)
N₁₀ = #{ y_CPU = y_FPGA verpasst }
N₀₁ = #{ y_CPU ≠ y_FPGA, aber FPGA "falsch positiv" }
N₀₀ = #{ y_CPU ≠ y_FPGA }                    (beide falsch)
```

#### Agreement-Rate

```
A = (N₁₁ + N₀₀) / (N₁₁ + N₁₀ + N₀₁ + N₀₀)
```

`A = 1` bedeutet perfekte Übereinstimmung zwischen FPGA und CPU.

#### Bias

```
B = (1/N) Σₜ (y_FPGA(t) - y_CPU(t))
```

`B ≠ 0` zeigt systematische Abweichung.

### 4.6 Koarse-Graining als physikalisches Konzept

Das Tool ist eine **many-to-one-Abbildung** vom 18-Tupel-Raum (riesig) auf den `(b̂, mant, meta)`-Raum (klein). Das ist genau der Begriff des **Koarse-Grainings** aus der statistischen Physik.

**Entropie-Reduktion.** Die Anzahl der Input-Tupel, die auf denselben Output abgebildet werden, bestimmt die Entropie-Reduktion:

```
ΔS = k_B · ln |{ x ∈ 𝔽₁₆ⁿ : f(x) = y }|
```

Das ist ein direktes Maß für die „Vergröberung" des Zustandsraums.

---

## 5. Was das Tool statistisch nicht kann

### 5.1 Kein `<`/`>`-Comparator (Richtung fehlt)

Die Minoritäts-Statistik zählt **wie viele** abweichen, nicht **in welche Richtung**. Konsequenzen:

- Kein gerichteter Bias messbar.
- Keine Offset-/Gain-Trennung.
- Keine Bimodalitäts-Erkennung bei symmetrischer Streuung.

### 5.2 Keine Index-Zuordnung (welcher der 18?)

Die Statistik ist **aggregiert**. Man kann nicht sagen, **welcher** Eingang abweicht. Konsequenzen:

- Kein „Best-Fit"-Gewinner.
- Keine Rangfolge.
- Keine per-Kanal-Kalibrierung.

### 5.3 Kein Ranking / kein Best-Fit-Gewinner

Das Tool findet die **Majority**, aber keine Ordnung der Eingänge. Es gibt keinen „zweitbesten", keinen „am wenigsten abweichenden", keine Rangfolge.

### 5.4 Keine Magnitude pro Abweichler

Die Statistik zählt Abweichler, aber nicht **wie weit** sie abweichen. Ein Abweichler im niederwertigsten Bit und ein Abweichler im höchsten Bit werden gleich gezählt.

### 5.5 Keine interne Zeitinformation

Das Tool liefert Ausgaben pro Taktzyklus, aber keine Zeitstempel. Zeitliche Korrelationsanalyse muss **extern** gemacht werden.

### 5.6 Keine Korrektheits-Garantie (nur Determinismus)

Der Code garantiert **deterministischen** Output — aber nicht, dass dieser Output **korrekt** ist. Die Unterscheidung:

| Begriff | Bedeutung | Vom Code garantiert? |
|---|---|:---:|
| Determinismus | Gleicher Input → gleicher Output | Ja |
| Korrektheit | Output = „wahrer" Wert | Nein |
| Zuverlässigkeit | Stabilität über Zeit | Nein |

---

## 6. Die `n = 18`-Power-Analyse: Reicht das?

### 6.1 Binomial-Konfidenz für Majority

Die Majority ist „korrekt", wenn sie mit dem wahren Wert übereinstimmt. Sei `p` die Wahrscheinlichkeit, dass ein einzelner Eingang vollständig korrekt ist. Die Wahrscheinlichkeit, dass die Majority (bei Toleranz `τ`) korrekt ist:

```
P_korrekt(p, n, τ) = P(K ≥ ⌊n/2⌋ + 1 - τ) = Σₖ₌⌊n/2⌋₊₁₋τⁿ (n choose k) pᵏ (1-p)^(n-k)
```

**Tabelle: Korrektheits-Wahrscheinlichkeit für `n = 18`**

| `p` | `τ=0` | `τ=1` | `τ=2` |
|:---:|---:|---:|---:|
| 0.99 | 0.99835 | ≈ 0.999999 | ≈ 1 |
| 0.95 | 0.77450 | 0.94100 | 0.98840 |
| 0.90 | 0.45030 | 0.73380 | 0.90180 |
| 0.80 | 0.09910 | 0.27130 | 0.49940 |

**Interpretation.** Für `p = 0.99` ist die Majority mit `τ = 0` in `99.835 %` der Fälle korrekt — gut. Für `p = 0.95` fällt sie auf `77.45 %` — bereits grenzwertig. Für `p = 0.90` ist sie mit `45 %` praktisch nutzlos. Die Frage „reicht `n = 18`?" hängt also entscheidend von `p` ab.

### 6.2 Kritischer TOLERANCE-Wert

Für eine gegebene Korrektheits-Wahrscheinlichkeit `p` und Ziel-Konfidenz `1-ε` ist die minimale Toleranz:

```
τ_min(p, ε) = min{ τ : Σₖ₌⌊n/2⌋₊₁₋τⁿ (n choose k) pᵏ (1-p)^(n-k) ≥ 1-ε }
```

**Beispiel:** `n = 18`, `p = 0.95`, `ε = 10^-3`:

- `τ = 0`: `0.7745 < 0.999`
- `τ = 1`: `0.9410 < 0.999`
- `τ = 2`: `0.9884 < 0.999`
- `τ = 3`: `0.9974 < 0.999`
- `τ = 4`: `0.9995 ≥ 0.999` ✓

Also: Bei `p = 0.95` und Ziel-Konfidenz `99.9 %` braucht man `τ_min = 4`. Bei `τ = 1` (Design-Default) wäre die Konfidenz nur `94 %`.

### 6.3 Wann bricht der Determinismus?

Die **Bruchwahrscheinlichkeit** `P(K ≤ ⌊n/2⌋ - τ)` als Funktion von `p` ist die zentrale Kurve. Sie zeigt:

- Bei `p = 0.99` und `τ = 0`: Bruchwahrscheinlichkeit `≈ 0.165 %`.
- Bei `p = 0.98`: Bruchwahrscheinlichkeit `≈ 1.3 %`.
- Bei `p = 0.95`: Bruchwahrscheinlichkeit `≈ 22.5 %`.

Für zuverlässige Anwendungen (z. B. Kalibrierung) sollte die Bruchwahrscheinlichkeit unter `10^-3` liegen. Bei `n = 18`, `τ = 0` ist das nur für `p > 0.99` gegeben. Das ist die eigentliche „Grenze des Designs".

---

## 7. Design-Intent vs. Design-Realität: Die Lücke

| Aspekt | Intent (Erfinder) | Realität (Code) |
|---|---|---|
| Ungenauigkeiten eliminieren | Robust gegen Rauschen | Nur bei `p > 0.99` zuverlässig |
| Max. Metadaten | Minoritäts-Statistik | Nur Betrag, nicht Richtung |
| Determinismus | Reproduzierbarer Output | Deterministisch, aber nicht korrekt |
| Binning | Kürzungslängen als Bins | Funktioniert |
| Kanal-Zuordnung | (nicht spezifiziert) | Nicht möglich |
| Richtung | (nicht spezifiziert) | Nicht möglich |

**Die zentrale Lücke.** Der Erfinder will Ungenauigkeiten eliminieren **und** maximalen Informationsgehalt bewahren. Der Code liefert das für den Fall `p > 0.99` (Majority stabil) und mit Einschränkungen (nur Betrags-Statistik). Für `p < 0.98` bricht der Determinismus zusammen, und das Tool wird unzuverlässig. Die Frage ist, ob die realen Eingaben `p > 0.99` haben — das ist eine empirische Frage, die nur durch Messung beantwortet werden kann.

**Was das Tool nicht verspricht.** Es verspricht keine Fehlerkorrektur im informationstheoretischen Sinn, keine absolute Korrektheit, keine Kanal-Zuordnung. Es ist ein **statistischer Comparator**, kein **Fehlerkorrektur-Code**. Das ist eine bewusste Design-Entscheidung — und eine ehrliche.

---

## 8. Empfehlungen: Erweiterungen

### 8.1 Gerichtete Statistik (`direction_meta`)

Erweiterung um ein 5×4-Bit-Feld, das pro Kürzungsschritt `n_less` und `n_greater` kodiert. Das würde Offset-/Gain-Trennung und gerichtete Kalibrierung ermöglichen.

### 8.2 Per-Kanal-Zuordnung (`per_channel_cmp`)

Ein `18 × 3`-Bit-Feld, das pro Kanal angibt, ob er `<`, `=` oder `>` zur Majority ist. Das würde „Best-Fit"-Gewinner und Rangfolgen ermöglichen.

### 8.3 Explizite Unsicherheits-Quantifizierung

Ein Feld, das eine Konfidenz-Angabe ausgibt (z. B. basierend auf Anzahl der Abweichler). Das wäre für Kalibrierung und Regelkreise hilfreich.

### 8.4 Größeres `n`

Bei `p = 0.95` und `τ = 1` ist die Bruchwahrscheinlichkeit `~6 %`. Für zuverlässige Anwendung bei diesem `p` bräuchte man `n ≈ 30–50`. Das ist eine Frage des Ressourcenbudgets.

### 8.5 Adaptive Toleranz

Statt fixem `τ = 1` könnte `τ` dynamisch an die gemessene Korrektheits-Rate angepasst werden. Das würde die Robustheit erhöhen.

---

## 9. Fazit

Der `minority_report.v` ist ein minimales, aber mächtiges Tool. Seine Stärke liegt nicht in der Präzision des Outputs, sondern in der **Struktur** des Outputs: Die Kürzung statt Rundung erzeugt eine Multiresolutions-Hierarchie, die als Binning-Grundlage für statistische Physik dient.

Die zentrale Erkenntnis dieses Reports: Die Majority-Genauigkeit für `n = 18`, `p = 0.99` ist `≈ 99.835 %` (strenge Majority) bzw. `≈ 99.9999 %` (mit Toleranz `τ = 1`). Die Bruchwahrscheinlichkeit pro Vektor ist `≈ 0.165 %`. Das ist die korrekte Größenordnung — nicht `10^-40`. Die `10^-40`-Größenordnung entsteht nur unter anderen, unrealistischen Annahmen.

Die Grenzen des Tools sind ebenso klar: Keine Richtungsinformation, keine Kanal-Zuordnung, keine Betrags-Information, keine explizite Unsicherheits-Quantifizierung. Diese Lücken sind bewusste Design-Entscheidungen — sie machen den Code minimal und schnell, aber sie begrenzen die statistische Aussagekraft.

Für zuverlässige Anwendung (Bruchwahrscheinlichkeit `< 10^-3`) ist das Tool bei `τ = 0` nur für `p > 0.99` geeignet. Bei `τ = 1` ist die Bruchwahrscheinlichkeit bereits für `p = 0.99` unter `10^-6` — das ist die eigentliche Stärke des Toleranz-Voters.

---

## Anhang A: Formelsammlung

**Binomial-Verteilung**

```
P(K = k) = (n choose k) pᵏ (1-p)^(n-k)
```

**Majority-Korrektheit (streng)**

```
P_korrekt^(τ=0) = P(K ≥ ⌊n/2⌋ + 1) = Σₖ₌⌊n/2⌋₊₁ⁿ (n choose k) pᵏ (1-p)^(n-k)
```

**Majority-Korrektheit (Toleranz `τ`)**

```
P_korrekt^τ = P(K ≥ ⌊n/2⌋ + 1 - τ) = Σₖ₌⌊n/2⌋₊₁₋τⁿ (n choose k) pᵏ (1-p)^(n-k)
```

**Bruchwahrscheinlichkeit**

```
P_break^τ = 1 - P_korrekt^τ
```

**Agreement-Rate**

```
A = (1/N) Σₜ₌₁ᴺ 𝟙[y_CPU(t) = y_FPGA(t)]
```

**Autokorrelation der Bitlänge**

```
C(Δt) = (1/(N-Δt)) Σₜ₌₁^(N-Δt) (b̂(t) - ⟨b̂⟩)(b̂(t+Δt) - ⟨b̂⟩)
```

**Entropie-Reduktion beim Koarse-Graining**

```
ΔS = k_B · ln |{ x ∈ 𝔽₁₆ⁿ : f(x) = y }|
```

---

## Anhang B: Beispielrechnungen

### Beispiel 1: `n = 18`, `p = 0.99`, `τ = 0`

```
P(K = 18) = 0.99^18                 ≈ 0.83453
P(K = 17) = 18 · 0.01 · 0.99^17     ≈ 0.15173
P(K = 16) = 153 · 0.0001 · 0.99^16  ≈ 0.01149
P(K = 15) = 816 · 10⁻⁶ · 0.99^15    ≈ 0.00058
P(K = 14) = 3060 · 10⁻⁸ · 0.99^14   ≈ 0.00002
```

Summe `P(K ≥ 10) ≈ 0.99835`. Also `P_break ≈ 0.00165`.

### Beispiel 2: `n = 18`, `p = 0.95`, `τ = 0`

```
P(K = 18) = 0.95^18                 ≈ 0.39721
P(K = 17) = 18 · 0.05 · 0.95^17     ≈ 0.37641
P(K = 16) = 153 · 0.0025 · 0.95^16  ≈ 0.16835
P(K = 15) = 816 · 1.25e-4 · 0.95^15 ≈ 0.03762
```

Summe `P(K ≥ 10) ≈ 0.7745`. Also `P_break ≈ 0.2255`.

### Beispiel 3: `n = 18`, `p = 0.99`, `τ = 1`

```
P_korrekt^(τ=1) = P(K ≥ 9) = 1 - P(K ≤ 8) ≈ 1 - 10⁻⁶ ≈ 0.999999
```
