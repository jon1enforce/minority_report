# Der `minority_report.v` Comparator

## Eine statistisch-physikalische Analyse

### Was das Tool kann, was es nicht kann

---

## Abstract

Der `minority_report.v` ist ein FPGA-Baustein, der aus `n = 18` redundanten 16-Bit-Floating-Point-Eingaben eine Majority-Entscheidung trifft und dabei eine Minoritäts-Statistik als Metadaten ausgibt. 

Im Zentrum steht die Frage nach dem **Determinismus**: Jeder der 18 Eingänge ist mit Wahrscheinlichkeit `p` vollständig bit-identisch zum wahren Wert. Sind alle 18 bit-identisch (`p^18 ≈ 0.8345`), ist der Output mit Sicherheit korrekt. Für die restlichen Fälle verlangt der Code **Einstimmigkeit im Vorzeichen und Exponenten** sowie **höchstens einen Abweichler in der Mantisse** auf mindestens einer Kürzungsstufe.

Der Kern des Designs ist die **Kürzung statt Rundung**. Sie erzeugt eine Binning-Struktur(wieviel wurde diskret-gekürzt) und ermöglicht Histogramm-Analysen über Kürzungslängen und Minoritäts-Nibbles. Die 5 Nibbles in `minority_meta` kodieren die Abweichungs-Magnitude relativ zur Ausgabelänge und sind absolut rekonstruierbar. Das kürzen garantiert den Determinismus im output zu "prakisch" nahezu 100%. 

Die verbleibenden Grenzen: kein `<`/`>`, keine Rangfolge, keine Kanal-Zuordnung.

---

## Inhaltsverzeichnis

1. [Einleitung: Design-Intent](#1-einleitung-design-intent)
2. [Der Code: Was er tut](#2-der-code-was-er-tut)
3. [Deterministischer Output](#3-deterministischer-output)
4. [Was das Tool statistisch kann](#4-was-das-tool-statistisch-kann)
5. [Was das Tool statistisch nicht kann](#5-was-das-tool-statistisch-nicht-kann)
6. [Design-Intent vs. Design-Realität](#6-design-intent-vs-design-realität)
7. [Fazit](#7-fazit)

---

## 1. Einleitung: Design-Intent

Der `minority_report.v` ist ein **redundanter Entscheider**: Aus `n = 18` parallelen FP16-Eingaben (1 Bit Vorzeichen, 5 Bit Exponent, 10 Bit Mantisse) wird ein Majority-Wert bestimmt, und zusätzlich eine Minoritäts-Statistik ausgegeben.

### Der Zweck 

1. **Ungenauigkeiten eliminieren.** Die 18 Eingaben sind redundante Messungen desselben Prozesses. Ihre individuellen Ungenauigkeiten sollen durch Majority-Bildung unterdrückt werden.
2. **Maximalen Informationsgehalt bewahren.** Statt nur den Majority-Wert auszugeben, liefert das Tool **Metadaten**: Wie viele Abweichler gab es? Bei welcher Kürzungslänge?
3. **Deterministischen Output bei nicht-deterministischem Input erzeugen.** Die Eingaben sind stochastisch, der Output soll reproduzierbar sein.

### Die zentrale Design-Entscheidung

Die Mantisse wird **gekürzt**, nicht **gerundet**. Runden liefert einen einzelnen FP16-Wert. Kürzen liefert eine **Familie** von Werten, parametrisiert durch die Bitlänge `b ∈ {1, …, 10}`. Diese Familie ist die Grundlage aller statistischen Analyse.

### Was dieser Report nicht behandelt

Der Report behandelt **keine** Accuracy-Frage im Sinne von „wie genau ist der Zahlenwert". Das Tool rundet nicht, es kürzt; der Ausgabewert ist exakt der gekürzte Majority-Wert. Die relevante Frage ist, ob die Majority **korrekt** ist. Das ist eine Frage des Determinismus, nicht der numerischen Genauigkeit.

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

```verilog
for (s = 0; s < 10; s = s + 1) begin
    if (mabweich[s] <= 1) begin
        chosen_bl   = s + 1;
        chosen_mant = mbest[s];
        chosen_no_majority = 1'b0;
    end
end
```

Die Auswahlschleife akzeptiert eine Majority, solange höchstens **ein** Abweichler auf der jeweiligen Kürzungsstufe existiert. Der erlaubte Abweichler ist das Modell eines einzelnen Sensor-Ausfalls, eines einzelnen Bit-Flips, eines einzelnen Photonen-Verlusts.

### 2.3 Das Binning über Kürzungslängen

Jeder Ausgabewert trägt eine gewählte Bitlänge `b̂ ∈ {1, …, 10}`. Diese Bitlänge ist eine diskrete Zustandsvariable — der natürliche Bin für Histogramme. Die Minoritäts-Statistik (`minority_meta`, 5×4 Bit) liefert zusätzlich die Abweichlerzahl pro Kürzungsschritt.

---

## 3. Deterministischer Output

### 3.1 Formale Definition

> **Definition 1 (Nicht-deterministischer Input).**
> Sei `x(t) = (x₁(t), …, xₙ(t)) ∈ 𝔽₁₆ⁿ` ein Tupel von `n` FP16-Eingaben zur Zeit `t`. Der Input heißt **nicht-deterministisch**, wenn für zwei Zeitpunkte `t ≠ t'` gilt: `P(x(t) = x(t')) < 1`.

> **Definition 2 (Deterministischer Output).**
> Sei `f: 𝔽₁₆ⁿ → 𝒴` die Abbildung, die der `minority_report` implementiert. Der Output heißt **deterministisch**, wenn `f(x) = f(x')` für alle `x, x'` gilt, die „hinreichend ähnlich" sind — wobei „hinreichend ähnlich" durch die Majority-Toleranz definiert ist.

Viele verschiedene Input-Tupel werden auf denselben Output abgebildet. Die Äquivalenzklasse ist definiert durch: gleiche Majority, gleiche Kürzungslänge, gleiche Minoritäts-Statistik.

### 3.2 Das Modell

Jeder der `n = 18` Eingänge ist mit Wahrscheinlichkeit `p = 0.99` **vollständig bit-identisch** zum wahren Wert (alle 16 Bits). Mit Wahrscheinlichkeit `q = 0.01` weicht er ab. Die Eingänge sind unabhängig.

### 3.3 Was der Code tatsächlich verlangt

Der Output ist **deterministisch gültig** (kein `error_sign`, kein `error_exp`, kein `no_majority`), wenn **alle drei** Bedingungen erfüllt sind:

1. **`sign_ok`:** Alle 18 Vorzeichen sind identisch (`sign_ones == 0` oder `sign_ones == 18`).
2. **`exp_ok`:** Alle 18 Exponenten sind identisch (`exp_max == 18`).
3. **`∃ s ∈ {1..10} : mabweich[s] ≤ 1`:** Auf mindestens einer Kürzungsstufe gibt es höchstens einen Abweichler in der Mantisse.

Das ist **strenger** als eine 50 %-Mehrheit: Der Code verlangt Einstimmigkeit im Vorzeichen und Exponenten und praktisch Einstimmigkeit in der Mantisse.

### 3.4 Was daraus streng folgt

Sind alle 18 Eingänge bit-identisch (Wahrscheinlichkeit `p^18 ≈ 0.8345`), dann gilt sicher:
- `sign_ok = 1`
- `exp_ok = 1`
- `mabweich[s] = 0 ≤ 1` für alle `s`

In diesem Fall ist der Output **mit Sicherheit korrekt** — es gibt keine Abweichler. Daraus folgt die untere Schranke:

```
P(G) ≥ p^18 ≈ 0.8345
```

Eine schärfere obere Schranke als `P(G) ≤ 1` ist ohne Annahme über die Position der Abweichungen nicht möglich.

### 3.5 Was daraus **nicht** folgt

Die exakte per-Vektor-Wahrscheinlichkeit `P(G)` ist ohne Annahme über die Verteilung der Abweichungen auf Vorzeichen, Exponent und Mantisse nicht berechenbar. Insbesondere sind folgende Größen **nicht** durch den Code gedeckt:

- `P(G) ≈ 0.99835` (das wäre `K ≥ 10`, also 50 %-Mehrheit — implementiert der Code nicht).
- `P(G) ≈ 0.999999` (das wäre `K ≥ 9` — auch nicht).
- `P(G) ≈ 10^-40` (das wäre eine kumulative Größe über viele Vektoren, nicht die per-Vektor-Wahrscheinlichkeit).

### 3.6 Bemerkung zur Unterscheidung „Determinismus" vs. „Accuracy"

In diesem Report wird bewusst **nicht** von „Accuracy" gesprochen. „Accuracy" suggeriert eine numerische Genauigkeit des Ausgabewerts. Das ist hier nicht die relevante Frage. Das Tool **rundet nicht**, es kürzt; der Ausgabewert ist **exakt** der gekürzte Majority-Wert. Die einzigen Begriffe, die in diesem Report verwendet werden, sind **Determinismus** (Output ist reproduzierbar) und **Korrektheit** (Output stimmt mit Wahrheit überein).

---

## 4. Was das Tool statistisch kann

### 4.1 Binning über Kürzungslängen `H(b̂)`

Die gewählte Bitlänge `b̂ ∈ {1, …, 10}` ist eine diskrete Observable. Man kann ein Histogramm

```
H(b̂) = #{ Ausgaben mit gewählter Bitlänge b̂ }
```

über viele Vektoren aufnehmen. Es zeigt, wie „sicher" die Majority-Entscheidung über die Zeit ist.

- **Schmales Histogramm um `b̂ = 10`:** Stabile, hochpräzise Entscheidungen.
- **Breites Histogramm:** Fluktuation, Rauschen dominiert.
- **Bimodales Histogramm:** Zwei Populationen von Vektoren (z. B. zwei Betriebsmodi).

### 4.2 2D-Histogramm `H(b̂, m)`

Jedes der 5 Nibbles in `minority_meta` kodiert die Anzahl der Abweichler bei einem Kürzungsschritt. Ein 2D-Histogramm `H(b̂, m)` mit `m ∈ {0, …, 15}` zeigt, **bei welcher Präzisionsstufe** die Abweichler auftreten. Die bedingte Wahrscheinlichkeit `P(m | b̂)` macht sichtbar, ob Abweichler gleichmäßig verteilt sind oder sich bei bestimmten Stufen häufen.

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

Das Tool ist eine **many-to-one-Abbildung** vom 18-Tupel-Raum (riesig) auf den `(b̂, mant, meta)`-Raum (klein) — genau der Begriff des **Koarse-Grainings** aus der statistischen Physik.

**Entropie-Reduktion**

```
ΔS = k_B · ln |{ x ∈ 𝔽₁₆ⁿ : f(x) = y }|
```

Die Anzahl der Input-Tupel, die auf denselben Output abgebildet werden, bestimmt die Vergrößerung des Zustandsraums.

### 4.6 Abweichungs-Magnitude: 5 Stufen, relativ zur FP16-Ausgabelänge — rekonstruierbar

Die 5 Nibbles in `minority_meta` kodieren die Abweichlerzahl auf den **letzten fünf Kürzungsstufen bis `chosen_bl`**. Das ist ein bewusstes Feature: Die Magnitude-Information ist **relativ zur Ausgabelänge** kodiert und durch die im Output enthaltene Längeninformation **absolut rekonstruierbar**.

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
- **Keine Zuordnung zu einem konkreten Eingang.**
- **Keine Richtung** (größer/kleiner als die Majority).
- **Keine feinere Magnitude als 1 Bit.**

**Fazit:** Die Magnitude-Information ist **vorhanden, relativ zur Ausgabelänge kodiert und absolut rekonstruierbar** — aber **aggregiert** und **richtungslos**.

**Der Minority-Count ist selbst eine statistische Größe.** Unabhängig von der Magnitude kann die Abweichlerzahl direkt ausgewertet werden — als Häufigkeitsverteilung über viele Vektoren oder als Zeitreihe (wie oft gab es 0, 1, 2, … Abweichler pro Kürzungsschritt?).

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

| Aspekt | Intent | Realität (Code) |
|---|---|---|
| Ungenauigkeiten eliminieren | Robust gegen Rauschen | Verlangt Einstimmigkeit in sign/exp |
| Max. Metadaten | Minoritäts-Statistik | Betrag/Magnitude vorhanden (aggregiert), Richtung fehlt |
| Determinismus | Reproduzierbarer Output | Deterministisch, aber nicht korrekt (weil u. a. gekürzt) |
| Binning | Kürzungslängen als Bins | Funktioniert |
| Magnitude | (nicht spezifiziert) | 5 Stufen, relativ zur Ausgabelänge, rekonstruierbar |
| Kanal-Zuordnung | (nicht spezifiziert) | Nicht möglich |
| Richtung | (nicht spezifiziert) | Nicht möglich |

**Was das Tool nicht verspricht.** Es verspricht keine Fehlerkorrektur im informationstheoretischen Sinn, keine absolute Korrektheit, keine Kanal-Zuordnung. Es ist ein **statistischer Comparator**, kein **Fehlerkorrektur-Code** — aber **fehlertolerant** im Sinne der Majority-Toleranz: Ein einzelner Abweichler auf der jeweiligen Kürzungsstufe wird akzeptiert, ohne die Majority zu brechen.

---

## 7. Fazit

Der `minority_report.v` ist ein minimales, aber mächtiges Tool. Seine Stärke liegt nicht in der Präzision des Outputs, sondern in der **Struktur** des Outputs: Die Kürzung statt Rundung erzeugt eine Multiresolutions-Hierarchie, die als Binning-Grundlage für statistische Physik dient.

Sind alle 18 Eingänge bit-identisch (`p^18 ≈ 0.8345`), ist der Output mit Sicherheit korrekt. Für die restlichen Fälle verlangt der Code Einstimmigkeit im Vorzeichen und Exponenten sowie höchstens einen Abweichler in der Mantisse auf mindestens einer Kürzungsstufe — strenger als eine 50 %-Mehrheit. Die exakte per-Vektor-Wahrscheinlichkeit `P(G)` für diese Restfälle ist ohne Annahme über die Abweichungsverteilung nicht berechenbar.

Die verbleibenden Grenzen sind bewusste Design-Entscheidungen: keine Richtungsinformation, keine Kanal-Zuordnung, keine per-Kanal-Magnitude, keine explizite Unsicherheits-Quantifizierung. Die Abweichungs-Magnitude ist in 5 Stufen relativ zur Ausgabelänge kodiert und absolut rekonstruierbar — ein Feature, kein Mangel.

---
