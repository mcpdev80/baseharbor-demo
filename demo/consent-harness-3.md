# consent-harness-3 — demo PR #128, third correction round (lane w91-demo-r3)

## Aufgabe (WAS WIRD ENTWICKELT)
Der demobasierte, geführte Candidate-Consent-Flow (baha `init` -> `up` ->
`up --confirm-candidate`) wird fail-closed gemacht: Der Capture-Validator in
`drive.py` muss im Capture-Pfad wirklich Exit-Code und nicht-optionale Regeln
auswerten (nicht über einen frühen Return umgangen werden), ein verpflichtender
READY-Abschlussmarker wird zur Pflichtregel, und der Aufrufer klassifiziert den
Zwischenzustand nur noch am dokumentierten Candidate-Consent-Abbruch (exakter
Fehlertext + Hash + alle Interaktionen). Bei anderem Fehlertext nach Hash
Abbruch, kein zweiter `up`.

## Head / Basis
- Fix-Kandidat (dieser Branch): `b02570a0d12b1f1b7b96148ec353f783ed527fdc`
- Ziel-Head der Runde (b73be42): `b73be42ba9944d21ffe8869382c37100c3e40384`
- Basis main: `cd9176e0129f01270ca85fd6b29acf99404f6dcd`
- `git ls-remote origin w85-demo-guided-consent` => `b02570a0d12b1f1b7b96148ec353f783ed527fdc`
- PR #128: OPEN, READY (`isDraft=false`), `mergeStateStatus=CLEAN`

## Änderungen (PR #128 Diff)
- `tests/guided/drive.py`
  - (1) frühen `if capture: return rc, buffer` (alte Zeilen 261-262) ENTFERNEN;
    der Exit-Code- und nicht-optionale-Regeln-Validator läuft jetzt auch im
    Capture-Pfad (Luna review-128b Befund 1 / B1).
  - (2) `up_rules`: verpflichtende Regel `READY-abschluss-marker` (non-optional,
    aus dem Core-Transcript: Zeile `READY`). Der frühere Zustand
    `alle-regeln-optional` ist damit der Fehlerzustand.
  - (3) Aufrufer zwischen Zustand NUR als dokumentierter candidate-consent-
    abbruch klassifizieren: exakter erwarteter Fehlertext + extrahierter
    Hash + alle nicht-optionalen Interaktionen erfüllt. Hash bei ANDEREM
    Fehlertext => ABBRUCH, kein zweiter `up`.
- `tests/guided/test_consent_capture.py` (NEU, permanent, auto-discovered
  `unittest`-Test, registriert via `python3 -m unittest discover -s tests
  -p test_*.py`; wird von CI v0424-Targeted mit abgedeckt): lunas sechs Fälle.

## Gegenprobe (b)-Fall wortlich nach Luna
`run_tty(..., capture=True)` mit Prozessende `0` und nie erfüllter
Pflichtregel => jetzt ABBRUCH (früher: `rc=0` + `READY reached`). Der
Pflicht-Prompt ist jetzt durch `up_rules` (non-optional) UND den Aufrufer
abgesichert.

## Regressionen (alle in tests/guided/test_consent_capture.py, fail-closed)
1. rc=0 ohne READY-Marker => ABBRUCH (kein READY-PASS)
2. Pflicht-Prompt fehlt => ABBRUCH
3. rc!=0 ohne Hash => ABBRUCH
4. rc!=0 mit Hash aber fremdem Fehlertext => ABBRUCH, kein zweites up
5. rc!=0 mit Hash aber unvollständigen Interaktionen => ABBRUCH
6. dokumentierter consent-abbruch (Hash + exakter Fehlertext + alle Interaktionen) => zweiter lauf => READY
7. regulärer erfolg ohne Hash => READY-Erfolg

## Ergebnisse lokaler Lauf
- `python3 -m py_compile tests/guided/drive.py`: rc=0
- `python3 -m py_compile tests/guided/test_consent_capture.py`: rc=0
- `python3 -m unittest discover -s tests/guided -p "test_*.py"`: 7/7 OK (rc=0)
- `python3 -m unittest discover -s tests -p "test_*.py"` (CI-Layout): OK (rc=0)
- `bash -n scripts/acceptance.sh`: rc=0
- `git diff --check`: rc=0
- Push `b02570a` auf `w85-demo-guided-consent`; `ls-remote` bestätigt; PR #128 READY
- 7/7 Regressionen grün.

## repo-rule compliance (baseharbor-demo/AGENTS.md)
- Tatsächliche Repo-Checks verwendet (py_compile, unittest discover, bash -n).
- Branchfremde PR-CI nicht erfunden (PR #128 auf main: keine PR-Checks laut
  Repo-Konfiguration, kein Befund).
- Regressions-Test als ECHTER dauertest im Diff (nicht als abgelegtes
  Evidence-Skript außerhalb des Diffs) — lunas Kritik an 7e972f0 berücksichtigt.
- Kein Force-Push, keine Branch-Protection-Umgehung.

## Status
END_DONE w91-demo-r3: validator=erreichbar regressions=7/7 lsremote=b02570a | PR #128 READY, fail-closed candidate-consent im Diff.
