# Correction des recherches — RC1.17.1

## Cause et corrections

Le journal utilisateur signale `Test-DomeniaSearchQueryRow` introuvable au moment de l’ajout des résultats, puis l’arrêt protégé de `Timer:Live` après trois erreurs. Le journal original contient des identités réelles et n’est pas recopié dans le dépôt.

`GetNewClosure()` place le prédicat WPF dans un module dynamique : les fonctions privées au script principal ne sont pas accessibles par leur nom. La liste pouvait donc rester vide alors que les données avaient été récoltées.

- Le filtre Live capture désormais ses critères et la sélection de GUID, sans appeler une fonction applicative par son nom depuis cette fermeture.
- Les sélections actives vides ou privées de leur table de GUID restent vides ; elles ne laissent pas passer tous les objets.
- Une modification de filtre pendant la désactivation de la grille est mémorisée et appliquée après réactivation, y compris la suppression du filtre.
- Le clic sur les graphiques Parc capture explicitement la fonction ouvrant les résultats détaillés.
- Sans filtre texte, le prédicat évite la concaténation de huit champs par ligne ; sans filtre de présence, il évite aussi sa normalisation.
- La recette Windows standard inclut désormais `Test-DomeniaModules` et `Test-DomeniaLiveSearchView`. Le garde existant contre les appels par nom dans une fermeture n’était pas exécuté par la précédente recette rapide.

## Périmètre

Tests sur données fictives dans la VM Windows dédiée, sous PowerShell 5.1 x64 STA, avec les deux portées du lancement réel (`-File Domenia-Start.ps1`, puis `& Domenia-Core.ps1`), chargement des vrais modules, collection WPF et minuteur réels. Le test direct dans une seule portée racine masque ce défaut : le nouveau harnais conserve donc la portée du lanceur et celle de l’application. Les frontières réseau, AD et persistance sont neutralisées dans le test de régression. Les limites de qualification AD réelle restent inchangées.

Les rapports de cette correction sont distincts des campagnes précédentes ; leurs empreintes restent conservées avec chaque campagne.

## Reproduction avant correction

Le [rapport de référence](before-after-f4f5e218/baseline-head-report.json) utilise le code du commit `fc4b956` et le même test que la version corrigée. Il montre **3 erreurs sur 3 passages**, `FaultStopped=true`, minuteur arrêté, **3 lignes reçues et aucune ligne visible**. Le clic du graphique échoue également sur la résolution de sa fonction. Le processus sort avec le code **1**.

La [passe intermédiaire corrigée](before-after-f4f5e218/correction-before-fastpath-report.json) réussit **11 scénarios / 62 assertions**, avec un code de sortie **0**. Elle précède uniquement l’optimisation évitant les allocations inutiles dans le prédicat. Elle ne remplace pas la validation du ZIP final.

La [provenance](before-after-f4f5e218/origin.json) conserve l’empreinte du test commun. Les [empreintes des rapports originaux et normalisés](evidence-normalization.json) distinguent les copies versionnées des sorties Windows brutes.

## Validation du pack livré

La [qualification synthétique Windows](qualification.json) valide **19 suites effectives**, sans échec restant : démarrage et fabrication PROD, parseur/compatibilité 5.1, modules, WPF, connexion, tableaux de bord, requêtes, résilience, tri/pagination/actions, périmètres DN, règles, moteur natif et persistance SQLite.

- **11 scénarios / 62 assertions** dans le [test WPF de régression](final-pack-80893/Test-DomeniaLiveSearchView.json).
- **5 002 lignes visibles sur 5 002** : 5 000 postes, un utilisateur et un groupe ; aucune identité perdue ou dupliquée.
- **2 500 GUID sélectionnés / 2 500 postes affichés**, puis retrait du filtre restaurant les 5 002 lignes.
- **Zéro erreur du minuteur**, file de résultats entièrement vidée, compteurs cohérents ; nouvelle recherche globale et clic de widget réussis.
- Le scénario complet de charge prend **64,519 s** dans cette VM, en incluant l’arrivée progressive, les assertions d’unicité, la requête et son retrait. Ce n’est pas une mesure de débit LDAP ; aucun gain de durée globale n’est démontré par cet essai.

La première campagne conserve un échec du test de tri, dont la dernière assertion exigeait encore une cellule de 48 pixels. La grille compacte validée utilise 28 pixels et `NoWrap`. L’assertion corrigée vérifie précisément cette cellule Description, sa largeur minimale et son ellipse. Le [nouvel essai](final-dev-4773/Test-DomeniaIndexSorting.stdout.txt) passe **545 assertions** ; le [démarrage et la fabrication](final-dev-4773/_quick-ui.json) ont aussi été rejoués sur le DEV final.

La [comparaison des archives](final-zip-comparison.json) démontre que seuls ce test et son empreinte dans le manifeste DEV changent entre les deux campagnes. Les **91 fichiers applicatifs**, tous les autres tests et le lanceur de recette sont identiques ; le **ZIP PROD entier** reste identique. Les preuves précédentes s’appliquent donc à ces mêmes octets.

Les empreintes des packs livrés figurent dans [le manifeste de distribution](../../../packs/manifest.json). Le contrôle formel D001–D120 reste `NOT_EVALUATED` / `Publishable=false` : ces essais en session WPF 0 sur données fictives ne constituent ni une recette du domaine réel ni une validation interactive Alt-Tab, multi-écran ou DPI.
