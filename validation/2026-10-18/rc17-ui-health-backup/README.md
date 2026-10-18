# RC1.17.17 — qualification ciblée interface, santé et sauvegarde

Le 18 octobre 2026, dans **CNAMTS-W11-01 / W11-01**, sous Windows PowerShell **5.1.26100.6584 x64 STA**. Les contrôles natifs ciblés sont réussis : **110 cas uniques retenus**, dont 63 contrôles WPF, 37 santé et 10 stockage (61 assertions). Le lancement PROD et le parcours interactif connexion Windows → accueil → recherche → outils → accueil sont également constatés. Ce bilan ne constitue pas une qualification générale.

## Archives exactes et sources

| Archive | SHA-256 | Fichiers contrôlés |
|---|---|---:|
| PROD | `0393c1b7fd23e732209d3f96c4c91196afcb57ba26f02e86d79bbbc7eb4e908a` | 172 |
| DEV | `001ae72db21059bda3ad5ac72e810d8c69e20b948e2fc18c224f5b070a2eb04b` | 642 |

Les 172 fichiers runtime sont identiques entre PROD et DEV. Les archives proviennent du lot déjà poussé au commit `f7a3ee73461588f29b094f9a4810c09eeac6406a`. `raw/Environment.json` et `raw/FinalEnvironment.json` attestent leurs empreintes et les fichiers extraits, avant les contrôles et après restauration des deux fixtures corrigées. **Aucun runtime ni ZIP remplacé.** Le manifeste des sources du dépôt est régénéré séparément pour les corrections de tests et le suivi ; il ne remplace pas le manifeste embarqué dans les ZIP testés.

## Résultats retenus

| Contrôle | Résultat | Preuve brute |
|---|---:|---|
| Santé, couverture, inconnus, dates et populations | 20/20 | `raw/HealthRules.json` |
| Recettes à révision conservée, politiques par OU, suspension UTC, comparaisons, matrices | 17/17 | `raw/HealthAdvanced.json` |
| Politique et planification de sauvegarde ; export autonome sans WAL ; restauration distincte ; intégrité | 10/10, 61 assertions | `raw/StorageMaintenance.json` |
| Dashboard : source/date, vrai rafraîchissement, tailles fixes 1920/1280/960, sections inventaire/santé | 6/6 retenus | `raw/BoardCritical.json` (6 réussites, 1 échec de fixture séparé ci-dessous) |
| Assistant : calcul automatique avant ouverture, échec récupérable, OU vide | 1/1 après correction de fixture | `raw/FirstStepsCorrected.json` |
| Sections et assistant au-dessus des widgets | 4/4 après correction d’attente obsolète | `raw/BoardSectionsCorrected.json` |
| Formulaires clair/sombre, diagnostic, annulation, géométrie des compteurs d’en-tête | 52/52 | `raw/StableUi.json` |
| Application PROD réelle, session Windows, navigation accueil/recherche/outils/accueil | Réussi en continuation du même processus | `raw/InteractiveResume.json`, captures `raw/Login.png`, `raw/Home.png`, `raw/WsSearch.png`, `raw/TabApplicationTools.png`, `raw/TabDashboard.png` |

Les codes retour et commandes exactes des suites figurent dans `raw/Runs.json`, `raw/UiRuns.json` et `raw/UiCorrectedRuns.json`. Les scripts exécutés sont conservés dans `harness/`. Les rapports et captures récupérés sont liés par SHA-256 dans `Qualification.json`.

Les cas de santé utilisent des données synthétiques, sans WPF ni réseau ; les autres suites instancient les contrôles WPF natifs ou travaillent sur des bases SQLite temporaires via Windows. Le cas synthétique 5 000 postes appartient à HealthRules ; ce n’est pas une qualification de charge représentative. Les widgets sont exercés avec callbacks de collecte simulés. L’AD/WMI distant réel reste prouvé séparément par [rc17-live-ad-wmi](../rc17-live-ad-wmi/README.md).

## Corrections des bancs et tentatives conservées

- `Test-DomeniaBoardSections.ps1` attendait encore l’assistant sous les widgets. L’attente est alignée sur la demande utilisateur et le runtime déjà livré : assistant au-dessus. Les trois autres cas initiaux passaient ; les quatre passent après correction.
- `Test-DomeniaBoards.ps1` ne simulait pas `Request-UiTaskStop`. Après ajout de cette fixture, la closure d’événement ne retrouvait pas `Step-EditorTrial` sous Windows 5.1. Le scriptblock de la fonction est maintenant capturé explicitement. Le cas « Premiers pas » passe. Les six autres cas déjà verts n’ont pas été rejoués après cette dernière correction. `BoardCritical.json` et `BoardCriticalCorrected.json` conservent les deux échecs successifs de fixture ; aucun n’est masqué.
- Les deux fichiers corrigés ont été superposés temporairement dans l’extraction DEV, puis leurs octets originaux rétablis en `finally`. Leurs empreintes finales sont dans `raw/CorrectedTestSources.json` et correspondent aux sources commitées. Les scripts de reprise contiennent les octets exacts envoyés à la VM ; ils sont conservés pour reproduction, pas comme modification des archives livrées.
- Le pilote interactif initial a rencontré une variable PowerShell réservée, une session sans capture exploitable et un mauvais repérage : l’AutomationId de navigation est le `Uid` (`TabDashboard`, `WsSearch`, `TabApplicationTools`), pas le `x:Name`. Le premier rapport « fenêtre principale non atteinte » n’est donc pas une preuve d’échec de connexion : l’accueil était visible. La continuation sur le même processus corrige uniquement ce repérage et réussit. Les tentatives sont conservées, non comptées comme succès.
- Une interruption du labo a nécessité un redémarrage de W11-01 et une réouverture manuelle de session. La cause du gel n’est pas établie. Le contrôle « Premiers pas », le parcours visuel final et l’intégrité finale ont réussi après redémarrage. Aucun changement réseau, AD, sécurité ou contrôleur de domaine.
- `StableUi.json` porte encore le libellé interne historique RC1.6 du banc. Les commandes, le manifeste et les empreintes lient son exécution aux sources RC17. Les fichiers `UiEnvironment.json`/`UiCorrectedEnvironment.json` réutilisent un champ `Scope` descriptif du pilote santé ; les suites réellement exécutées sont celles des rapports et commandes associés.

## Limites et fin de session

La navigation interactive constate le rendu et les changements de page sur le petit labo, avec le profil de l’opérateur et une base vide. Elle ne qualifie pas un dashboard alimenté en données réelles, le cycle automatique complet de sauvegarde, la restauration via l’interface après corruption, tous les parcours de santé, les migrations complètes, le volume 400 000 lignes, les DPI 125/150/200 %, le lecteur d’écran, la charge 10 000–20 000 postes ni la désinstallation sur compte jetable. Le relevé humain global et le renouvellement des captures historiques restent ouverts.

Les fichiers de preuve sont récupérés hors VM avant la fin de tâche. Les tâches temporaires du pilote sont retirées ; les VM et le profil de l’opérateur ne sont pas supprimés (`raw/Cleanup.json`). **Publishable reste faux**, décisions externes 134 et 146 inchangées ; aucun `acceptance_passed` global.
