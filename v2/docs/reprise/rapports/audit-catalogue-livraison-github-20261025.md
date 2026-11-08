# Audit ciblé du catalogue et de la livraison — reprise GitHub du 25/10/2026

## Périmètre et preuves disponibles

Base demandée : branche `v2`, commit `9b1c0333c34020ad88c1448874b91eff884d5406`. Travail poursuivi sur `codex/v2-finalisation-20261025`. Le lot 123 du Spark/Mac n'est pas présent dans cette base GitHub et n'a pas été récupéré.

Les 993 entrées du catalogue ont été parcourues par identifiants, statuts et références, puis les chemins de code ci-dessous ont été examinés. Ce relevé est **un audit ciblé de raccordements**, pas une validation fonctionnelle des 993 entrées. Un statut historique `a-faire` ou `partiel` ne prouve pas à lui seul un manque actuel ; un backend présent ne prouve pas une fonctionnalité terminée.

La décision courante est : terminer le développement, commit/push, puis tests **critiques** dans les deux VM autorisées avec recette UI/native. Les anciennes demandes de suites exhaustives sont remplacées. Aucun test de cette reprise n'a été exécuté par l'auteur de ce rapport. L'accès aux deux VM Windows n'est pas disponible depuis cette session.

Compilation réellement observée pour le commit CI `c60ebd110091eefb0185c55e7df9030fec28db8e` :

- GitHub Actions : <https://github.com/M4D135/domenia-d120/actions/runs/40213483359> ; job `121229525937`.
- Windows, SDK **10.0.402 déjà installé**, compatible avec `global.json` (`10.0.401`, `latestPatch`). Restauration depuis les cinq paquets vendus dont les SHA ont été contrôlés ; aucune installation de dépendance.
- Debug et Release : **zéro avertissement, zéro erreur** dans les journaux du job ; fin de la compilation Release à `2026-10-25T16:51:37Z`.
- Aucun test exécuté par ce workflow automatique. Ce passage compile la base et le lot CI ; il ne valide pas les modifications ultérieures non incluses dans ce SHA.

Seconde preuve de compilation revue par l’agent intégrateur : commit `fea4c18117d07145d669859f16140739dde03329`,
run <https://github.com/M4D135/domenia-d120/actions/runs/40215771359>, job `121236451103`.
Debug et Release : zéro avertissement, zéro erreur. Les reprises, réglages/CLI, la garde de livraison, le chargeur strict,
MSI/filtres et le lot Accueil sont inclus dans ce SHA. **Aucun test exécuté. Le raccordement personnel TRV-191 décrit
ci-dessous et les corrections physiques ultérieures ne sont pas inclus dans cette preuve.**

## Restes documentaires devenus insuffisants pour conclure

| Entrée | Mention historique | Raccordement désormais présent dans le code | Limite de ce constat |
| --- | --- | --- | --- |
| ACC-003 | Sauvegarde réelle encore absente | `AccueilRefresh.cs` appelle `PrepareDirectoryRefreshAsync` avant la lecture AD ; le reçu de sauvegarde est conservé dans la progression. | Recette réelle d'échec/arrêt/reprise NON VÉRIFIÉE. |
| ACC-006 | Reçu d'enregistrement encore fictif | La phase `commit` vérifie le reçu de lecture locale et refuse la collecte suivante s'il est absent ou incohérent. | La présence du garde n'est pas un résultat de test. |
| OPE-011 | Cycle de vie décrit comme non raccordé | `LifecycleWorkflow.cs`, les opérations `fiche.lifecycle.*`, `fiche/workflows.js` et le lien de `operations/receipts.js` forment un parcours UI → plan → confirmation → reçu → étape suivante. | Toutes les variantes natives ne sont pas qualifiées. |
| OPE-019 | Point d'accroche de publication UI encore absent | `web/js/bridge.js` mesure le délai jusqu'au prochain rafraîchissement visible ; `operations.publication.report` alimente `OperationActivity.RecordPublication`. Une fenêtre masquée conserve « non mesurée ». | Mesure d'intervalle de publication, pas mesure CPU ; recette UI NON VÉRIFIÉE. |

Ces constats justifient une réconciliation documentaire après validation ciblée. Ils ne justifient ni une promotion automatique de tous les statuts ni une affirmation de parité complète.

## Écarts fonctionnels prouvés et corrections du lot

### TRV-188 — liste anti-Windows Installer divergente

Preuve de départ : `QueryProbeCatalog.MsiProviderClasses` ne contenait que 10 noms, `PosteLabels.MsiProviderClasses` 13. La référence D1 `Get-DomeniaMsiProviderClassNames`, dans `dev/wad/modules/Domenia-Workstation.Model.ps1`, en contient **88**, notamment les classes dont une énumération générique atteint le fournisseur MSI. `CimQuery.IsReadOnlySelect` délègue à `WqlRules.CheckTarget`, donc à la liste courte de Requêtes. Les classes `Win32_Patch`, `Win32_ServiceControl`, `Win32_RegistryAction` et `CIM_SoftwareElementActions` n'étaient pas couvertes par ce garde.

Correction intégrée dans `7e2d6d86` : `Platform/CimReadSafety.cs` porte la liste commune ; Requêtes, Poste et le contrat Accueil utilisent ces mêmes noms. Le transport natif suit déjà le garde de Requêtes. La comparaison **textuelle** des noms D1 et C# retrouve 88 entrées identiques, sans différence. Aucune classe n'a été interrogée pour faire cette comparaison.

Deux tests `CimReadSafetyTests` couvrent les 88 refus dans les consommateurs et la conservation des classes feuilles utiles telles que `Win32_Service`. Tests écrits, **NON EXÉCUTÉS**. Leur compilation est incluse dans `fea4c181` ; les contrôles critiques Windows restent à exécuter.

### TRV-190 — fenêtres temporelles annoncées mais non résolues

Preuve de départ : les sondes `evt.syserrors` et `evt.unexpected` portent les littéraux `{SINCE_24H}` et `{SINCE_7D}` dans les deux catalogues. `WmiFleetProbeReader` et `AdQueryWorkshopReader` construisaient le SELECT depuis `Filter` sans substitution ; aucune résolution de ces jetons n'existait dans `v2/src`. La date relative décrite par le contrat n'était donc pas transmise au fournisseur.

Correction intégrée : `ProbeCatalog.ResolveFilter` résout exclusivement ces deux fenêtres en date DMTF UTC, juste avant l'émission. Jeton inconnu/incomplet, texte de contrôle ou filtre hors borne sont refusés. Les deux consommateurs appellent le même helper ; leur compilation est incluse dans `fea4c181`.

Deux tests `ProbeFilterTests` couvrent la fenêtre UTC exacte, le passage à l'heure locale d'hiver, la grammaire du transport et les refus. Tests écrits, **NON EXÉCUTÉS**. Un test de syntaxe de SELECT n'est pas une lecture WMI réussie.

### TRV-191 — déclaration personnalisée écrasée et chargement permissif

Preuve de départ : `ProbeCatalog.ReadExtended` remplaçait toute origine par `Catalogue détaillé`, sans lire `Behavior`, `Privilege` ni `Cost`. Les tableaux mixtes ignoraient silencieusement les valeurs non textuelles, les indicateurs mal typés devenaient `false`, et les contrats n'étaient pas un garde du chargement réel. L'origine `Personnalisée` et ses obligations ne pouvaient pas être appliquées fidèlement.

Correction intégrée dans `7e2d6d86` : le vrai `ProbeCatalog.Load` passe par `ReadDetailed`. Le parseur borne document/listes/chaînes, refuse clés inconnues ou répétées, types implicites, propriétés ambiguës, types CIM incohérents et projections non déclaratives. Une origine personnalisée conserve ses déclarations de comportement, privilège, coût et cible ; il n'en déduit aucune. `Slow=true` et `SkipOnDc=true` sont obligatoires. Les contrats sont vérifiés avant indexation du catalogue.

Six tests `ProbeDeclarationTests` couvrent le chargement réel, le respect des déclarations, les refus et l'absence de mutation du catalogue global par la simple lecture d'un document. Tests écrits, **NON EXÉCUTÉS**.

**Ce premier correctif ne terminait pas TRV-191.** Le lot courant ajoute le raccordement ci-dessous, au-delà du parseur.
Aucun statut de feature n'est promu par simple présence de code. Le premier raccordement Accueil a depuis été compilé dans `154e81402207662085422042eb58d8dbe4b8ac9f` (Debug/Release 0/0, rapport Windows CI). Cette preuve ne couvre pas l’extension Atelier décrite plus bas. Les recettes et tests critiques restent à établir.

## Premier raccordement TRV-191 : Accueil, puis extensions coordonnées

### Exigence D1 et limites des raccourcis

D1 charge le fichier `Domenia-ProbeCatalog.json`, vérifie les déclarations personnalisées puis fusionne son résultat dans `Get-DomeniaProbeCatalog`. `Get-DomeniaProbe` et `ConvertTo-DomeniaProbePayload` sont consommés par les widgets. `Add-DomeniaRemoteProbeDefinitionHash` associe la projection réelle à une empreinte pour éviter la réutilisation silencieuse d'une ancienne mesure.

Constat historique avant ces lots : les catalogues Accueil, Poste et Requêtes étaient embarqués séparément. Les checkpoints Accueil désignent les sondes par identifiant. Ajouter des entrées à un catalogue statique mutable ferait partager des données entre profils et pourrait attribuer des observations anciennes à une définition modifiée. Le catalogue personnel est donc attaché au contexte de profil. Le premier lot ne raccordait que l’Accueil ; les lots Poste et Atelier ci-dessous étendent ensuite ses consommateurs. La CLI exporte localement les observations et recettes conservées, sans collecte.

L'atelier de requêtes dispose déjà de recettes révisionnées et de widgets liés, mais `StoredWmiResult` ne conserve que `exists` et `count` pour un SELECT mémorisé. Convertir une sonde personnalisée en ce seul SELECT ferait perdre ses valeurs `First`/`All` et ses transformations. Cette conversion n'est donc pas retenue comme équivalent complet.

### Parcours raccordé en code

1. **Profil** : petit catalogue validé dans les préférences du contexte moteur, sans état global mutable. Un instantané immuable de définitions est capturé pour chaque plan. Les règles de profil réel/démonstration et les verrous existants restent applicables.
2. **Import/édition** : le tiroir existant « Ajouter un widget → Sondes WMI » accueille le fichier JSON, l'aperçu des définitions et contrats, puis une confirmation locale. Le jeton de version du catalogue affiché est revérifié avant la sauvegarde. Une entrée invalide refuse le document entier.
3. **Identité de définition** : chaque entrée reçoit une clé `custom.<SHA256 du document canonique>`. Une modification crée une nouvelle clé. Les définitions encore référencées sont conservées, ou leur suppression est refusée avec un motif explicite ; aucun widget existant ne change de signification silencieusement.
4. **Widgets** : le catalogue, le nettoyage de disposition et le calcul du tableau résolvent le même instantané de profil. Les valeurs `First`, `All`, `Count` et les transformations existantes sont conservées. Les postes d'un chiffre viennent du même calcul.
5. **Collecte** : le plan transporte les définitions figées à ses clés ; seuls les appels explicites existants peuvent les émettre. Identité de cible, epoch, exclusion des contrôleurs, classes autorisées, budgets, annulation et fin physique restent contrôlés. La démonstration utilise son lecteur isolé.
6. **Stockage/reprise** : les observations du parc sont enregistrées sous la clé de définition. Un lecteur de cache n'exécute jamais une définition contenue dans une observation. Une reprise refuse une clé devenue absente ; aucune donnée sous une ancienne définition n'est réinterprétée.

Les consommateurs raccordés sont `AccueilService`, `FleetBoardInput/Calculator`, `AccueilRefresh` et ses parties durables/widgets,
`IAccueilReader.CollectFrozenProbesAsync`, `AdAccueilReader`, `SimulatedAccueilReader`, `WmiFleetProbeReader.ReadFrozenAsync`,
`DomeniaDatabase.Fleet`, le pont et le tiroir de catalogue. Aucun catalogue global mutable n'est ajouté. L'éditeur propose
un modèle JSON, la préparation d'une nouvelle version et son aperçu contractuel ; fermer le tiroir ne permet pas à une
réponse tardive de confirmer l'import. Le mock navigateur annonce explicitement qu'il n'effectue aucune validation moteur.

La clé de 71 caractères traverse contrats, bridge, disposition, cache et reprise sans troncature. L'identifiant de carte est
borné séparément à 64 caractères, avec résolution de collision. Une disposition importée/restaurée sans sa définition exacte
est refusée ; un ancien widget orphelin reste visible. La configuration de diffusion générale n'exporte actuellement ni la
disposition du parc ni le catalogue personnel ; leurs références ne sont pas incorporées silencieusement à cet export.

Les limites du profil sont 64 versions et 256 Kio UTF-8, sans suppression implicite. Une déclaration ne peut ajouter de
nouvelle paire classe/espace de noms ; la limite SELECT existante de 4 000 caractères est vérifiée avant le travail natif.
L'exclusion DC est contrôlée depuis AD puis depuis le rôle CIM connu, sans nouvel appel ni nouveau budget. Un DC exclu
n'est pas compté comme fraîchement mesuré. Les mesures enregistrées sont relues avant le calcul des manques.

L'import personnel refuse les métadonnées documentaires que son modèle ne conserve pas (`Qualification` globale,
`DocumentationReviewedUtc`) ; la qualification peut être déclarée via `ProviderQualification`, sans en déduire une revue
réellement réalisée. L'auto-vérification distingue le catalogue embarqué du catalogue personnel et signale les défauts de profil.

Tests écrits, **NON EXÉCUTÉS** : huit `PersonalProbeTests` (bridge, CAS, absence de collecte implicite, profil distinct,
édition sans réattribution, widget simulé, SQLite, reprise sans définition, exclusions et identifiants), quatre
`PersonalProbeNativeTests` (déclarations figées avant transport, identité/rôle CIM, `First/All/Count`, frontière AD/stockage),
plus les tests WebView du panneau dans `personal-probes.test.mjs`. Les sessions natives y sont injectées : même après une
exécution future réussie, elles ne remplaceront pas la recette native réelle des deux VM.

Critères de fermeture : import réellement sauvegardé/relu, usage visible du widget, lecture ou refus natif fidèle, observation liée à la définition et au poste, édition sans réattribution d'anciennes valeurs, reprise refusée après perte de définition, isolation réel/démo. Le seul parseur ou un DTO supplémentaire ne suffisent pas.

### Limite de l'audit des autres fonctionnalités

La relecture D1 complémentaire de l’intégrateur avait établi un reste concret de TRV-191 : le même catalogue personnel
sert aussi les widgets Poste (`Domenia-Widgets.UI.ps1`, appels `Get-DomeniaProbeCatalog`) et l’atelier de requêtes
(`Domenia-Query.Model.ps1`, `Domenia-Query.UI.ps1`). Ce constat a entraîné deux lots supplémentaires :

- [Consommateur Poste](reprise-github-sondes-personnalisees-poste-20261025.md) : catalogue commun de profil, UI de
  personnalisation, plan/confirmation, vrai lecteur AD/CIM, cache/reçu, définition immuable et refus d’import incomplet.
- [Atelier et Query/4](reprise-github-sondes-personnalisees-atelier-20261025.md) : listes et collections du compositeur,
  compilation typée, aperçu et exports, collecte par source manquante/cible, recettes et historiques SQLite, widgets
  Accueil/Poste, Santé, Recherche et export CLI. `First`/`All` conservent leurs valeurs réelles et leurs propriétés ; ils ne
  sont pas convertis en simple `exists/count`.

Le statut de ces extensions est celui de leurs rapports et preuves de compilation, avec **tests critiques et UI/native
NON VÉRIFIÉS**. Le relevé historique « Poste/Atelier non raccordés » ne décrit plus l’arbre de travail de ce lot. Aucun
autre manque fonctionnel concret n’a été établi dans les seuls parcours ciblés de cet audit ; ce constat n’est pas une
validation exhaustive du catalogue.

Les occurrences anciennes « non raccordé », les branches
de refus quand un lecteur n'est pas disponible et le comportement du mock ne constituent pas des preuves de fonctionnalités
absentes dans l'application composée. Le catalogue de 993 entrées n'est pas pour autant déclaré terminé ni validé globalement.

## Préparation de livraison et garde de publication

Le préparateur `release-packages-vm.ps1` reste utilisable pour produire des **candidats non validés**. Le reçu porte `validationStatus: candidate-unvalidated`. Le guide de configuration diffusée est inclus avec les autres guides du paquet. Le schéma strict de `package-release.json` n'est pas changé.

La garde `release-guard.py`, décrite dans `docs/LIVRAISON-FINALE.md`, requiert deux dossiers distincts correspondant aux VM autorisées. Elle contrôle les octets exacts des ZIP PROD/DEV, les sources et le lot de tests, les logs critiques, les scénarios UI et leurs captures figées par SHA, les reçus de canari/compensation et la revue explicite des résultats. Le pilote natif courant dispose d'une sélection critique de **quatre lectures sur trente**, les 26 autres restant explicitement non exécutées. Les parcours UI critiques supplémentaires conservent leur revue propre.

Une empreinte établit la cohérence des fichiers ; elle ne constitue ni une signature d'éditeur, ni une attestation cryptographique d'identité du relecteur. `Returned`, `ProtocolCompleted`, un code zéro ou un build vert ne valent pas recette métier. La garde ne lance aucun test et ne publie rien.

**État de validation au présent relevé : deux VM, tests critiques, recette UI/native, artefacts finaux et SHA de livraison NON VÉRIFIÉS. Aucun PROD/DEV v2.0.0 n'est déclaré publié.**
