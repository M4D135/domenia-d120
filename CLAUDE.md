# Domenia — consignes permanentes du dépôt

Domenia (ex-ADCC) est un outil interne d'administration Active Directory en **Windows PowerShell 5.1 + WPF**.
Ce fichier donne les règles qui valent pour toute session. L'état du lot en cours et le reste à faire sont dans `REPRISE-D120.md`.

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
  wad/Domenia-Core.ps1           cœur monolithique (~23 800 lignes, 598 fonctions, XAML principal inclus)
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

## Statuts du suivi

`NON_CLOTURE` → `DEVELOPPE_NON_RACCORDE` (règles écrites et testées, application inchangée) →
`RACCORDE_A_VALIDER_WINDOWS` (branché, tests d'intégration réussis) → clôture uniquement avec la preuve Windows liée au ZIP.
