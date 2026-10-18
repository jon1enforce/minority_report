# Der `minority_report.v` Comparator

## Eine statistisch-physikalische Analyse

### Was das Tool kann, was es nicht kann

---

## Abstract

Der `minority_report.v` ist ein FPGA-Baustein, der aus `n = 18` redundanten 16-Bit-Floating-Point-Eingaben eine Majority-Entscheidung trifft und dabei eine Minoritäts-Statistik als Metadaten ausgibt. Dieser Report analysiert das Tool unter dem Blickwinkel der statistischen Physik.

Im Zentrum steht die Frage nach dem **Determinismus**: Jeder der 18 Eingänge ist mit Wahrscheinlichkeit `p` vollständig bit-identisch zum wahren Wert. Der Code verlangt **Einstimmigkeit im Vorzeichen und Exponenten** sowie **höchstens einen Abweichler in der Mantisse** auf mindestens einer Kürzungsstufe. Wir zeigen, was daraus streng folgt und was nicht. Die häufig zitierte Größenordnung `10^-40` ist **kein** Ergebnis dieser Rechnung.

Der Kern des Designs ist die **Kürzung statt Rundung**, die eine Binning-Struktur erzeugt und Histogramm-Analysen über Kürzungslängen und Minoritäts-Nibbles ermöglicht. Die 5 Nibbles in `minority_meta` kodieren die **Abweichungs-Magnitude** relativ zur Ausgabelänge und sind absolut rekonstruierbar — ein bewusstes Feature, keine Lücke. Wir diskutieren die verbleibenden Grenzen: kein `<`/`>`, keine Rangfolge, keine Kanal-Zuordnung.

---

## Inhaltsverzeichnis

1. [Einleitung: Design-Intent](#1-einleitung-design-intent)
2. [Der Code: Was er tut](#2-der-code-was-er-tut)
3. [Deterministischer Output](#3-deterministischer-output)
4. [Was das Tool statistisch kann](#4-was-das-tool-statistisch-kann)
5. [Was das Tool statistisch nicht kann](#5-was-das-tool-statistisch-nicht-kann)
6. [Design-Intent vs. Design-Realität](#6-design-intent-vs-design-realität)
7. [Fazit](#7-fazit)
- [Anhang: Was aus dem Code folgt](#anhang-was-aus-dem-code-folgt)

---

## 1. Einleitung: Design-Intent

Der `minority_report.v` ist kein Rechenwerk im klassischen Sinn. Er ist ein **redundanter Entscheider**: Aus `n = 18` parallelen 16-Bit-Eingaben im FP16-Format (1 Bit Vorzeichen, 5 Bit Exponent, 10 Bit Mantisse) wird ein Majority-Wert bestimmt, und zusätzlich eine Minoritäts-Statistik ausgegeben.

### Der Zweck des Erfinders

1. **Ungenauigkeiten eliminieren.** Die 18 Eingaben sind redundante Messungen desselben physikalischen Prozesses. Ihre individuellen Ungenauigkeiten sollen durch Majority-Bildung unterdrückt werden.
2. **Maximalen Informationsgehalt bewahren.** Statt einfach den Majority-Wert auszugeben, soll das Tool **Metadaten** liefern: Wie viele Abweichler gab es? Bei welcher Kürzungslänge? Das sind die Informationen, die ein Physiker für Statistik braucht.
3. **Deterministischen Output bei nicht-deterministischem Input erzeugen.** Die Eingaben sind stochastisch. Der Output soll reproduzierbar sein.

### Die zentrale Design-Entscheidung

Die Mantisse wird **gekürzt**, nicht **gerundet**. Runden würde einen einzelnen FP16-Wert liefern. Kürzen liefert eine **Familie** von Werten, parametrisiert durch die Bitlänge `b ∈ {1, …, 10}`. Diese Familie ist die Grundlage aller statistischen Analyse.

### Was dieser Report nicht behandelt

Der Report behandelt **keine** Accuracy-Frage im Sinne von „wie genau ist der Zahlenwert". Das Tool rundet nicht, es kürzt; der Ausgabewert ist exakt der gekürzte Majority-Wert. Die einzige relevante Frage ist, ob die Majority **korrekt** ist im Sinne von „stimmt sie mit dem wahren Wert überein". Das ist eine Frage des Determinismus, nicht der numerischen Genauigkeit.

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

Die Funktion kopiert nur die unteren `bl` Bits der Mantisse; alle höheren Bits werden auf null gesetzt. Das ist **kein** Runden, sondern Abschneiden. Konsequenz: Die Ausgabewerte sind in natürliche Bins sortierbar.

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

Sie akzeptiert eine Majority, solange höchstens **ein** Abweichler auf der jeweiligen Kürzungsstufe existiert. Der erlaubte Abweichler ist das Modell eines einzelnen Sensor-Ausfalls, eines einzelnen Bit-Flips, eines einzelnen Photonen-Verlusts.

### 2.3 Das Binning über Kürzungslängen

Jeder Ausgabewert trägt eine gewählte Bitlänge `b̂ ∈ {1, …, 10}`. Diese Bitlänge ist eine diskrete Zustandsvariable — der natürliche Bin, über den Histogramme gebildet werden können. Die Minoritäts-Statistik (`minority_meta`, 5×4 Bit) liefert zusätzlich die Abweichlerzahl pro Kürzungsschritt.

---

## 3. Deterministischer Output

### 3.1 Formale Definition

> **Definition 1 (Nicht-deterministischer Input).**
> Sei `x(t) = (x₁(t), …, xₙ(t)) ∈ 𝔽₁₆ⁿ` ein Tupel von `n` FP16-Eingaben zur Zeit `t`. Der Input heißt **nicht-deterministisch**, wenn für zwei Zeitpunkte `t ≠ t'` gilt: `P(x(t) = x(t')) < 1`.

> **Definition 2 (Deterministischer Output).**
> Sei `f: 𝔽₁₆ⁿ → 𝒴` die Abbildung, die der `minority_report` implementiert. Der Output heißt **deterministisch**, wenn `f(x) = f(x')` für alle `x, x'` gilt, die „hinreichend ähnlich" sind — wobei „hinreichend ähnlich" durch die Majority-Toleranz definiert ist.

Das Tool ist so konstruiert, dass viele verschiedene Input-Tupel auf denselben Output abgebildet werden. Die Äquivalenzklasse ist definiert durch: gleiche Majority, gleiche Kürzungslänge, gleiche Minoritäts-Statistik.

### 3.2 Das Modell

Jeder der `n = 18` Eingänge ist mit Wahrscheinlichkeit `p = 0.99` **vollständig bit-identisch** zum wahren Wert (alle 16 Bits). Mit Wahrscheinlichkeit `q = 0.01` weicht er ab. Die Eingänge sind unabhängig.

### 3.3 Was der Code tatsächlich verlangt

Der Output ist **deterministisch gültig** (kein `error_sign`, kein `error_exp`, kein `no_majority`), wenn **alle drei** Bedingungen erfüllt sind:

1. **`sign_ok`:** Alle 18 Vorzeichen sind identisch (`sign_ones == 0` oder `sign_ones == 18`).
2. **`exp_ok`:** Alle 18 Exponenten sind identisch (`exp_max == 18`).
3. **`∃ s ∈ {1..10} : mabweich[s] ≤ 1`:** Auf mindestens einer Kürzungsstufe gibt es höchstens einen Abweichler in der Mantisse.

Das ist **strenger** als eine 50 %-Mehrheit. Der Code verlangt Einstimmigkeit im Vorzeichen und Exponenten, und auf der Mantisse praktisch Einstimmigkeit (höchstens ein Ausreißer auf irgendeiner Kürzungsstufe).

### 3.4 Was daraus streng folgt

**Untere Schranke.** Wenn alle 18 Eingänge bit-identisch sind (Wahrscheinlichkeit `p^18 ≈ 0.8345`), dann gilt sicher:
- `sign_ok = 1`
- `exp_ok = 1`
- `mabweich[s] = 0 ≤ 1` für alle `s`

Also ist der Output deterministisch gültig. Damit:

```
P(G) ≥ p^18 ≈ 0.8345
```

**Obere Schranke.** `G` erfordert `sign_ok ∧ exp_ok`. Ohne Annahme über die Position der Abweichungen ist `P(G) ≤ 1` die einzige sichere obere Schranke.

**Zusammenfassung:**

```
0.8345 ≤ P(G) ≤ 1
```

### 3.5 Was daraus **nicht** folgt

Die exakte per-Vektor-Wahrscheinlichkeit `P(G)` ist **ohne Annahme über die Verteilung der Abweichungen auf Vorzeichen, Exponent und Mantisse nicht berechenbar**. Insbesondere:

- `P(G) ≈ 0.99835` (das wäre die Rechnung für `K ≥ 10`, also 50 %-Mehrheit — die implementiert der Code **nicht**).
- `P(G) ≈ 0.999999` (das wäre `K ≥ 9` — auch nicht).
- `P(G) ≈ 10^-40` (das wäre eine kumulative Größe über viele Vektoren, nicht die per-Vektor-Wahrscheinlichkeit).

### 3.6 Bemerkung zur Unterscheidung „Determinismus" vs. „Accuracy"

In diesem Report wird bewusst **nicht** von „Accuracy" gesprochen. „Accuracy" suggeriert eine numerische Genauigkeit des Ausgabewerts. Das ist hier nicht die relevante Frage. Das Tool **rundet nicht**, es kürzt; der Ausgabewert ist **exakt** der gekürzte Majority-Wert. Die einzige relevante Frage ist, ob die Majority **mit dem wahren Wert übereinstimmt**. Die Begriffe „Determinismus" (Output ist reproduzierbar) und „Korrektheit" (Output stimmt mit Wahrheit überein) sind die einzigen, die in diesem Report verwendet werden.

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

**Interpretation.** Die bedingte Wahrscheinlichkeit `P(m | b̂)` zeigt, ob Abweichler gleichmäßig über die Kürzungsschritte verteilt sind oder sich bei bestimmten Stufen häufen.

### 4.3 Zeitreihen-Analyse

**Autokorrelation der Bitlänge**

```
C(Δt) = ⟨b̂(t) · b̂(t + Δt)⟩ - ⟨b̂⟩²
```

zeigt, ob aufeinanderfolgende Vektoren korreliert sind.

**Markov-Kette über `b̂`-Zustände**

```
P_ij = P(b̂(t+1) = j | b̂(t) = i)
```

Die Eigenwerte von `P` geben die Relaxationszeiten des Systems an.

**Verweilzeiten.** Die Verteilung der Aufenthaltsdauern in einem Zustand `b̂ = i` gibt Aufschluss über die „Gedächtniszeit" des Systems.

### 4.4 Validierung gegen CPU-Referenz

**Konfusionsmatrix**

```
N₁₁ = #{ y_CPU = y_FPGA }                    (korrekt)
N₁₀ = #{ y_CPU = y_FPGA verpasst }
N₀₁ = #{ y_CPU ≠ y_FPGA, aber FPGA "falsch positiv" }
N₀₀ = #{ y_CPU ≠ y_FPGA }                    (beide falsch)
```

**Agreement-Rate**

```
A = (N₁₁ + N₀₀) / (N₁₁ + N₁₀ + N₀₁ + N₀₀)
```

`A = 1` bedeutet perfekte Übereinstimmung zwischen FPGA und CPU.

**Bias**

```
B = (1/N) Σₜ (y_FPGA(t) - y_CPU(t))
```

`B ≠ 0` zeigt systematische Abweichung.

### 4.5 Koarse-Graining als physikalisches Konzept

Das Tool ist eine **many-to-one-Abbildung** vom 18-Tupel-Raum (riesig) auf den `(b̂, mant, meta)`-Raum (klein). Das ist genau der Begriff des **Koarse-Grainings** aus der statistischen Physik.

**Entropie-Reduktion.** Die Anzahl der Input-Tupel, die auf denselben Output abgebildet werden, bestimmt die Entropie-Reduktion:

```
ΔS = k_B · ln |{ x ∈ 𝔽₁₆ⁿ : f(x) = y }|
```

### 4.6 Abweichungs-Magnitude: 5 Stufen, relativ zur FP16-Ausgabelänge — rekonstruierbar

Die 5 Nibbles in `minority_meta` kodieren die Abweichlerzahl auf den **letzten fünf Kürzungsstufen bis `chosen_bl`**. Das ist kein Zufall, sondern ein bewusstes Feature: Die Magnitude-Information ist **relativ zur Ausgabelänge** kodiert und durch die im Output enthaltene Längeninformation **absolut rekonstruierbar**.

`chosen_bl` ist im Output enthalten (`majority_packed[19:16]`). Damit sind die absoluten Kürzungsstufen der 5 Nibbles eindeutig rekonstruierbar:

| Nibble | Relative Position | Absolute Kürzungsstufe |
|:---:|:---:|:---:|
| 4 (oberste 4 Bit) | `chosen_bl - 0` | `chosen_bl` |
| 3 | `chosen_bl - 1` | `chosen_bl - 1` |
| 2 | `chosen_bl - 2` | `chosen_bl - 2` |
| 1 | `chosen_bl - 3` | `chosen_bl - 3` |
| 0 (unterste 4 Bit) | `chosen_bl - 4` | `chosen_bl - 4` |

**Was das liefert:** Die **Position der Abweichler entlang der Kürzungsachse**, absolut rekonstruierbar. Ein Abweichler, der erst auf einer viel feineren Stufe verschwindet, erscheint in einem höheren Nibble. Das ist eine **Magnitude-Information in Bit-Einheiten**: Wie viele Kürzungsschritte mussten durchlaufen werden, bis der Abweichler „weggeschnitten" war?

**Was das nicht liefert:**
- **Keine Zuordnung zu einem konkreten Eingang.** Man sieht nicht, *welcher* der 18 Eingänge den Abweichler verursacht.
- **Keine Richtung.** Man sieht nicht, ob der Abweichler größer oder kleiner als die Majority ist.
- **Keine feinere Magnitude als 1 Bit.** Die Auflösung der Magnitude ist 1 Kürzungsschritt = 1 Bit.

**Fazit:** Die Magnitude-Information ist **vorhanden, relativ zur Ausgabelänge kodiert und absolut rekonstruierbar** — aber **aggregiert** (nicht pro Kanal) und **richtungslos** (nicht `<`/`>`).

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

### 5.3 Keine interne Zeitinformation

Das Tool liefert Ausgaben pro Taktzyklus, aber keine Zeitstempel. Zeitliche Korrelationsanalyse muss **extern** gemacht werden.

### 5.4 Keine Korrektheits-Garantie (nur Determinismus)

Der Code garantiert **deterministischen** Output — aber nicht, dass dieser Output **korrekt** ist. Die Unterscheidung:

| Begriff | Bedeutung | Vom Code garantiert? |
|---|---|:---:|
| Determinismus | Gleicher Input → gleicher Output | Ja |
| Korrektheit | Output = „wahrer" Wert | Möglich, muss mit CPU verifiziert werden |
| Zuverlässigkeit | Stabilität über Zeit | Möglich, muss mit CPU verifiziert werden |

---

## 6. Design-Intent vs. Design-Realität

| Aspekt | Intent (Erfinder) | Realität (Code) |
|---|---|---|
| Ungenauigkeiten eliminieren | Robust gegen Rauschen | Verlangt Einstimmigkeit in sign/exp |
| Max. Metadaten | Minoritäts-Statistik | Betrag/Magnitude vorhanden (aggregiert), Richtung fehlt |
| Determinismus | Reproduzierbarer Output | Deterministisch, aber nicht korrekt, weil u.a. gekürzt |
| Binning | Kürzungslängen als Bins | Funktioniert |
| Magnitude | (nicht spezifiziert) | 5 Stufen, relativ zur Ausgabelänge, rekonstruierbar |
| Kanal-Zuordnung | (nicht spezifiziert) | Nicht möglich |
| Richtung | (nicht spezifiziert) | Nicht möglich |

**Die zentrale Lücke.** Der Erfinder will Ungenauigkeiten eliminieren **und** maximalen Informationsgehalt bewahren. Der Code liefert das für den Fall, dass alle Eingänge bit-identisch sind (`p^18 ≈ 0.8345`), und mit Einschränkungen (Magnitude vorhanden, aber aggregiert; Richtung fehlt). Wie hoch die per-Vektor-Wahrscheinlichkeit `P(G)` genau ist, hängt von der Abweichungsverteilung ab und ist ohne diese Annahme nicht exakt berechenbar.

**Was das Tool nicht verspricht.** Es verspricht keine Fehlerkorrektur im informationstheoretischen Sinn, keine absolute Korrektheit, keine Kanal-Zuordnung. Es ist ein **statistischer Comparator**, kein **Fehlerkorrektur-Code**.

---

## 7. Fazit

Der `minority_report.v` ist ein minimales, aber mächtiges Tool. Seine Stärke liegt nicht in der Präzision des Outputs, sondern in der **Struktur** des Outputs: Die Kürzung statt Rundung erzeugt eine Multiresolutions-Hierarchie, die als Binning-Grundlage für statistische Physik dient.

Die zentrale Erkenntnis dieses Reports: Der Code verlangt **Einstimmigkeit im Vorzeichen und Exponenten** sowie **höchstens einen Abweichler in der Mantisse** auf mindestens einer Kürzungsstufe. Das ist **strenger** als eine 50 %-Mehrheit. Die exakte per-Vektor-Wahrscheinlichkeit `P(G)` ist ohne Annahme über die Abweichungsverteilung nicht berechenbar. Sicher gilt nur die untere Schranke `P(G) ≥ p^18 ≈ 0.8345`.

Die Grenzen des Tools sind ebenso klar: Keine Richtungsinformation, keine Kanal-Zuordnung, keine per-Kanal-Magnitude, keine explizite Unsicherheits-Quantifizierung. Die Abweichungs-Magnitude ist in 5 Stufen relativ zur Ausgabelänge kodiert und absolut rekonstruierbar — ein bewusstes Feature, kein Mangel. Diese Grenzen sind bewusste Design-Entscheidungen — sie machen den Code minimal und schnell, aber sie begrenzen die statistische Aussagekraft.

---

## Anhang: Was aus dem Code folgt

### A.1 Untere Schranke für `P(G)`

Wenn alle 18 Eingänge bit-identisch sind (`p^18 ≈ 0.8345`), gilt sicher:
- `sign_ok = 1`
- `exp_ok = 1`
- `mabweich[s] = 0 ≤ 1` für alle `s`

Also ist der Output deterministisch gültig:

```
P(G) ≥ 0.99^18 ≈ 0.8345
```

### A.2 Fehlerfall bei einem einzigen Vorzeichen-Abweichler

Wenn genau 1 der 18 Eingänge ein abweichendes Vorzeichen hat (`sign_ones = 1` oder `17`), setzt der Code `error_sign = 1`. Der Output ist **nicht** deterministisch gültig, unabhängig von der Mantisse.

### A.3 Fehlerfall bei einem einzigen Exponent-Abweichler

Wenn genau 1 der 18 Eingänge einen abweichenden Exponenten hat (`exp_max = 17` oder weniger), setzt der Code `error_exp = 1`. Der Output ist **nicht** deterministisch gültig.
