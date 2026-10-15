# Qualification qualité et performance (points 122, 125 à 130)

Ces outils préparent la qualification Windows. Aucun nʼa encore été exécuté sous Windows PowerShell 5.1 : leurs
résultats ne seront des preuves quʼune fois produits dans la VM de test, puis rattachés à la matrice de validation.

| Point | Outil | Où lʼexécuter | Ce quʼil prouve, et ce quʼil ne prouve pas |
|---|---|---|---|
| 122 | Panneau *Opérations* de lʼapplication ; scénarios de `wad/tests/Test-DomeniaLoadStability.ps1` | Application ; VM | Médiane, 95e centile (à partir de 20 mesures) et maximum par catégorie, sur les mesures de la session. Ni un test du réseau, ni un engagement de service. |
| 125 | `wad/tests/Test-DomeniaLoadStability.ps1` (`-Computers 20000` pour la qualification) | VM, Windows PowerShell 5.1 x64 STA | Charge et stabilité du chemin local sur 10 000 ou 20 000 postes générés : démarrage à froid, cache chaud, historique volumineux, postes très équipés ; mémoire stabilisée et files bornées. Aucun AD, aucun réseau. |
| 126 | `wad/tests/Test-DomeniaStorageFaults.ps1` | VM | Base tenue ou verrouillée, disque plein (vrai `SQLITE_FULL` du moteur), arrêts brutaux réels avant `COMMIT`, entre `COMMIT` et reçu, pendant la migration et pendant une reconstruction de lʼindex, avec reprise vérifiée. Pas un volume physiquement plein. |
| 127 | `wad/tests/Test-DomeniaNetworkFaults.ps1` | VM | Latence, DNS erroné, refus, pages partielles, déconnexion, réponses dans le désordre sur le code livré, transport doublé. Ne prouve pas le réseau cible. |
| 128 | `wad/tests/fixtures/Domenia-Invariants.ps1` (vérifié à chaque cycle du banc de charge et par les tests de règles `P128`) | VM | Compte du widget égal aux GUID détaillés, rendu daté, inconnu conservé, aucune réponse dʼune ancienne sélection. |
| 129 | `engineering/d120/lab/Invoke-DomeniaGuiJourney.ps1` et `gui-journeys.json` | Session interactive de la VM (console ou bureau à distance), zone de travail de 1920×1080 au moins hors barre des tâches (définition plus grande ou barre masquée automatiquement) | Événements simulés (UI Automation, `SendInput`) et captures 1920×1080 sans infobulle, séparés du relevé humain. Jamais « Qualifié » sans relevé humain complet ni sur une partie des parcours (`-Journeys` donne « Partiel »). Refuse la session 0. |
| 130 | `tools/validation_matrix.py`, `validation-matrix.json`, `MATRICE-VALIDATION.md` | Hors Windows | Distingue preuve synthétique, laboratoire et domaine cible ; refuse un rapport du laboratoire présenté comme preuve du domaine réel. |

## Commandes

Depuis `dev\` dans la VM (Windows PowerShell 5.1 x64) :

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File wad\tests\Test-DomeniaLoadStability.ps1 -ReportPath C:\DomeniaLab\out\charge-10000.json
powershell -NoProfile -STA -ExecutionPolicy Bypass -File wad\tests\Test-DomeniaLoadStability.ps1 -Computers 20000 -Cycles 5 -ReportPath C:\DomeniaLab\out\charge-20000.json
powershell -NoProfile -STA -ExecutionPolicy Bypass -File wad\tests\Test-DomeniaStorageFaults.ps1 -ReportPath C:\DomeniaLab\out\pannes-stockage.json
powershell -NoProfile -STA -ExecutionPolicy Bypass -File wad\tests\Test-DomeniaNetworkFaults.ps1 -ReportPath C:\DomeniaLab\out\pannes-reseau.json
```

Parcours graphiques, dans une session ouverte de la VM :

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File engineering\d120\lab\Invoke-DomeniaGuiJourney.ps1 -DevRoot . -OutDir C:\DomeniaLab\gui -WriteHumanTemplate
# la personne qui qualifie fait les parcours à la main et remplit C:\DomeniaLab\gui\parcours-humain.json
powershell -NoProfile -STA -ExecutionPolicy Bypass -File engineering\d120\lab\Invoke-DomeniaGuiJourney.ps1 -DevRoot . -OutDir C:\DomeniaLab\gui -HumanRecord C:\DomeniaLab\gui\parcours-humain.json
```

Matrice de validation, hors Windows :

```text
python tools/validation_matrix.py                    contrôle la matrice et la page publiée
python tools/validation_matrix.py --write            régénère MATRICE-VALIDATION.md
python tools/validation_matrix.py --classify-report <_campaign.json>
python tools/validation_matrix.py --add-evidence <_campaign.json> --cell SYSTEME/PROTOCOLE/DROIT [--note TEXTE]
python -m unittest -v test_validation_matrix.py      (depuis engineering/d120)
```

Une preuve *Laboratoire* ou *Cible* sʼajoute avec `--add-evidence` : lʼoutil lit le rapport conservé hors de `dev\`,
calcule son SHA-256 et reprend sa date, son domaine et son poste tels que la campagne les a relevés (`Environment` de
`_campaign.json`) ; rien nʼest saisi à la main et lʼenvironnement est déduit de ces faits. À chaque contrôle, un rapport
lisible sur la machine est relu : empreinte, domaine, poste ou environnement différents de la déclaration sont refusés ;
un rapport absent de la machine est signalé comme non relu. Un rapport du domaine `cnamts.local` ou dʼun poste du
laboratoire nʼest jamais compté pour le domaine cible.

## Points à connaître avant lʼexécution

- Après intégration, `tools/update_worker_contracts.py --apply` doit réépingler les opérations `LiveConsole` et
  `LiveSelectedPing` (contrôle dʼidentité du poste qui répond, point 127) ; avant cela, les suites qui vérifient
  lʼempreinte du corps LiveConsole échouent par construction.
- `Invoke-LabRun.ps1` accorde 3 600 s au banc de charge et 1 200 s aux pannes de stockage.
- Les mesures décrivent la machine qui les a produites. Elles ne sont comparables quʼà paramètres identiques.
