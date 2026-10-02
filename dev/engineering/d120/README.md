# Reprise D001-D120 : lot de developpement, non qualifie pour production

Ce dossier ne modifie pas encore les comportements de l'application. Le moteur RC1.10.7 est conserve octet pour octet. Il ne faut pas installer ce lot en le presentant comme une version corrigee des 120 points.

## Code ajoute

- `release_guard.py` verifie les archives finales, leurs chemins Windows, les tailles, empreintes, fichiers declares, separation PROD et donnees de preuve. L'option `--require-windows` refuse une publication sans rapport Windows 5.1 lie au hash exact du ZIP, avec tous les scenarios obligatoires executes. Ce rapport local n'est pas une signature et sa veracite depend du processus qui le produit.
- `Test-NativeParser.ps1` utilise le vrai parseur du PowerShell qui l'execute et reproduit plusieurs regressions. `-RequireWindows51` refuse de qualifier PowerShell Linux/7 comme Windows PowerShell 5.1. Ce test seul ne valide pas les workers construits dynamiquement, le chargeur ou WPF.
- `rules/Domenia.ReadRules.psm1` developpe les regles pures de relation dans les deux sens, double identite source/cible, perimetre explicite sans substitution, consultation historique sans edition, echappement LDAP, qualification des indices et profils de colonnes. Ces fonctions ne sont PAS encore branchees sur l'interface.
- `Test-ReadRules.ps1` appelle ces vraies fonctions sur des donnees fictives. Aucun domaine n'est contacte.
- `test_release_guard.py` execute des tests positifs et des alterations de ZIP/preuves. Les preuves valides generees ici sont des fixtures de test, pas une qualification de Domenia.

## Verification

```text
python -m unittest -v test_release_guard.py
python release_guard.py chemin/PROD.zip --windows-report preuve.json --require-windows
```

Depuis PowerShell, avec les chemins adaptes :

```powershell
.\Test-NativeParser.ps1 -SourceRoot 'C:\Domenia-DEV' -ReportPath "$env:TEMP\domenia-parser.json" -RequireWindows51
.\Test-ReadRules.ps1 -ReportPath "$env:TEMP\domenia-rules.json"
```

## Conditions de la vraie publication

Le rapport doit couvrir parser.ps51, runtime.modules, worker.contracts, startup.exe_login_main, ui.actual_events, ui.layout_profiles, data.sqlite, security.secret_markers, race.selection et prod.standalone. Aucun de ces scenarios n'est remplace par un CRC de ZIP. Ne pas produire une fausse preuve pour forcer le passage.

Ce lot n'ajoute aucune authentification, aucun scan, aucune mutation, aucune popup et aucun partage de credentials. Il ne touche ni aux archives originales, ni aux donnees ADCC/Domenia. Le pointage D001-D120 garde visibles les raccordements et validations restant a faire.
