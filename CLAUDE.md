# Domenia — consignes permanentes du dépôt

Domenia (ex-ADCC) est un outil interne d'administration Active Directory en **Windows PowerShell 5.1 + WPF**.
Ce fichier donne les règles qui valent pour toute session. L'état du lot en cours et le reste à faire sont dans `REPRISE-D120.md`.

## Moteur de travail — décision de David du 2026-10-08

**Claude Code, en s'aidant du Spark.** David a demandé de « tout faire en autonomie et de s'aider du Spark »
pour le programme d'améliorations du 08/10 (liste `PISTES-AMELIORATION-2026-10-08.md`). Le Spark
(`~/bin/kbza ask --prompt-file FICHIER --no-memory --max-tokens 0`) sert aux brouillons, relectures et passes
mécaniques ; ses sorties sont des brouillons à vérifier, jamais des preuves. Cette décision remplace celle du
2026-10-04 (« Codex uniquement, aucun appel au Spark »). Les tests restent exécutés dans la VM Windows prévue
ci-dessous. Aucun workflow multi-agents sans demande explicite.

## Règles non négociables

1. **Cible unique : Windows PowerShell 5.1 x64 STA.** Aucune syntaxe ni API propre à PowerShell 6/7 ou à .NET moderne
   (ternaire, `??`, `&&`/`||`, `-Parallel`, `$IsWindows`, `ConvertFrom-Json -AsHashtable`, `[Math]::Clamp`,
   `.Contains(x, StringComparison)`, `Dictionary.TryAdd`, `[IO.Path]::GetRelativePath`…). Le garde-fou est
   `dev/tools/Test-DomeniaPs51Compat.ps1` ; il doit rester à 0 erreur.
2. **Aucune preuve inventée.** Un test non exécuté est déclaré non exécuté. `acceptance_passed` ne passe à vrai dans
   `Suivi_D001_D120.json` que sur un rapport Windows PowerShell 5.1 lié au hash du ZIP de livraison
   (`release_guard.py --require-windows`). Une exécution sous un autre moteur n'est jamais présentée comme une preuve 5.1.
3. **Aucun mot de passe, jeton ou secret dans le dépôt**, ni dans un script, ni dans un rapport, ni dans un argument de processus.
4. **Lecture par défaut.** Aucune sonde réseau, aucun scan et aucune écriture AD ne part sans geste explicite de l'opérateur.
   Une écriture n'est jamais rejouée automatiquement.
5. **Ne pas affaiblir Windows** : pas de certificat accepté à l'aveugle, pas de WinRM/pare-feu/antivirus/stratégie modifiés.

## Arborescence

```text
dev/
  Domenia.exe                    lanceur natif (C, conservé à l'octet ; ne pas recompiler sans décision)
  wad/Domenia-Start.ps1          contrôle du manifeste et des empreintes, puis lance le cœur
  wad/Domenia-Modules.ps1        chargeur FERMÉ : liste exacte des modules et de leurs fonctions
  wad/Domenia-Core.ps1           cœur monolithique (~25 900 lignes, ~594 fonctions de premier niveau au 8 octobre 2026, XAML principal inclus)
  wad/modules/                   modules : *.Model.ps1 (règles pures), *.UI.ps1, *.Worker.ps1, *.cs, *.xaml
  wad/tests/                     suites Windows (Test-*.ps1) ; rules/ = tests des règles pures
  tools/                         build (build_packages.py), audits, contrats worker, garde-fou 5.1
  engineering/d120/              lot D001-D120 : suivi, plan, garde de release, outils de labo
```

## Conventions de code

- **Encodage** : `.ps1` en UTF-8 **avec BOM**, fins de ligne **LF** (état réel du projet) ; `.cmd` en CRLF sans BOM.
  Sans BOM, Windows PowerShell 5.1 lit le fichier en ANSI et casse les accents.
- **Guillemets typographiques interdits** dans le code (`‘ ’ “ ”` sont des délimiteurs pour PowerShell). Pour une
  apostrophe dans un texte d'interface, utiliser `ʼ` (U+02BC) ou reformuler.
- **`-and` / `-or` ont la même priorité** en PowerShell : toujours parenthéser.
- **Tableaux d'octets** (GUID, SID) : les renvoyer avec `return ,$bytes`, sinon PowerShell les déroule.
- **C#** : uniquement C# 5 (compilateur d'`Add-Type` sous 5.1). Vérifier avec `mcs -langversion:5` si disponible.
- **Modules** : un domaine = `Domenia-<Domaine>.Model.ps1` (ni WPF, ni réseau, ni disque) + `.UI.ps1` + `.Worker.ps1`.
  Les modules sont *dot-sourcés* dans la portée du cœur : **pas de `Set-StrictMode`** dans un module.
  Tout nouveau module et chacune de ses fonctions doivent être déclarés dans `Domenia-Modules.ps1`.
- **Interface** : composants dans la page, jamais de nouvelle `Window` ni de `ShowDialog` pour un parcours métier.
  Une vue ajoutée se charge depuis un fichier `.xaml` séparé (modèle : `Initialize-DomeniaSupportUi`).
- **Workers** : le code d'une opération est une here-string épinglée par SHA-256. Toute modification impose
  `python tools/update_worker_contracts.py --apply` après relecture, et la liste des opérations modifiées dans les notes de version.
- **Langue** : textes d'interface et documentation en français ; commentaires de code en anglais (style existant).

## Vérifications (toutes doivent passer avant de dire « fait »)

```powershell
# Depuis dev\ , sous Windows PowerShell 5.1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File wad\tests\Test-DomeniaRules.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-DomeniaPs51Compat.ps1 -Root .
powershell -NoProfile -ExecutionPolicy Bypass -File engineering\d120\Test-NativeParser.ps1 -SourceRoot . -ReportPath $env:TEMP\parser.json -RequireWindows51
powershell -NoProfile -ExecutionPolicy Bypass -File engineering\d120\lab\Invoke-LabRun.ps1 -DevRoot . -OutDir $env:TEMP\domenia-out
```

```text
python tools/validate_powershell_static.py
python tools/audit_preload.py
python tools/update_worker_contracts.py
python -m unittest -v engineering/d120/test_release_guard.py     (depuis engineering/d120)
python tools/build_packages.py --output <dossier>
```

Ligne de base réelle avant raccordement (Windows PowerShell 5.1.26100.9549) : 1215 tests réussis, 79 en échec.
Le détail est dans `dev/engineering/d120/lab/baseline-5.1-r1-summary.json`. Toute modification doit être comparée à cette référence :
aucun test qui passait ne doit échouer sans décision explicite et documentée.

## Environnement de test (décision de l'utilisateur, 2026-10-02)

**Les tests s'exécutent dans les VM, jamais sur l'hôte.** L'hôte `DESKTOP-285EKHU` (192.168.1.173) ne sert qu'à relayer :
- VM de test : `CNAMTS-W11-01` (Windows 11 joint au domaine `cnamts.local`, 10.77.0.20) avec `CNAMTS-DC01` (10.77.0.10) ;
  réseau interne VirtualBox `CNAMTS-LAB`. Les deux VM sont démarrées en mode headless.
- Outil : `dev/engineering/d120/lab/lab.sh` (`sync`, `ps`, `file`, `get`, variable `LAB_DIR` pour isoler les travaux parallèles)
  → socket SSH du relais `~/Downloads/Domenia-lab/relais.sh` → `vmctl.ps1` sur l'hôte → `VBoxManage guestcontrol` dans la VM
  (dossier invité `C:\DomeniaLab\<LAB_DIR>`).
- Le compte invité et le **chemin** du fichier mot de passe sont dans `C:\Users\degun\domenia-lab\vm\vm.conf.json` sur l'hôte
  (hors dépôt). Aucun outil ni agent ne lit, n'affiche ni ne recopie ce mot de passe.
- Ne jamais lancer une suite, un script de test ou Domenia lui-même directement sur l'hôte ; ne pas toucher à `PESTO-W11-TEST`.

## Statuts du suivi

`NON_CLOTURE` → `DEVELOPPE_NON_RACCORDE` (règles écrites et testées, application inchangée) →
`RACCORDE_NON_EXECUTE` (branché dans l'application, tests d'intégration écrits, aucun exécuté sous 5.1) →
`RACCORDE_A_VALIDER_WINDOWS` (branché, tests d'intégration réussis) → clôture uniquement avec la preuve Windows liée au ZIP.
Le champ `wiring` (`Aucun`, `Partiel`, `Complet`) dit ce qui est branché ; `remaining` dit ce qui manque.

## Contrôles possibles hors Windows (session cloud)

Sans VM ni Windows, seuls des contrôles **non qualifiants** sont possibles : contrôles Python de la liste ci-dessus,
`Test-DomeniaPs51Compat.ps1`, parseur et règles pures sous PowerShell 7 Linux (archive officielle
`powershell-7.x-linux-x64.tar.gz` extraite dans le dossier temporaire de la session). Les règles qui touchent COM, ACL ou
`SecurityIdentifier` y échouent par construction. Rien de cela n'est une preuve 5.1.
Après toute modification d'un fichier runtime : `python tools/integrate_lots.py --refresh-functions` si des fonctions de
module changent, `python tools/build_packages.py --output <dossier hors arbre>` pour régénérer les manifestes (sinon
`Domenia-Start.ps1` refuse le démarrage), et `python tools/audit_preload.py --rebaseline --decision "..."` seulement
après relecture d'une fonction critique ou d'une charge épinglée.
