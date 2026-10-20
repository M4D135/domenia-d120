# RC1.17.35 — Premiers pas et livraison, 20 octobre 2026

> Suite de cette qualification et correctifs RC1.17.36 :
> [résultats complémentaires](../rc35-qualification/README.md).
> Les mentions « incomplet » ci-dessous décrivent la première passe conservée.


Le périmètre ciblé est corrigé et vérifié sous Windows PowerShell 5.1 x64.
Travail terminé directement par Codex, à la demande de David pendant la maintenance du Spark.
Base master `83b7795`, passation et premier correctif repris depuis `3a2b939`.
[Résultats structurés et liaisons aux sources](Verification.json).

## Corrections

- L’OU acceptée redessine immédiatement la carte. La première lecture dépend d’une
  couverture complète de cette OU et de sa profondeur, jamais du compteur global.
- Marqueurs absents, tentative partielle seule, autre OU ou profondeur inconnue/incompatible :
  l’étape reste à faire. Une lecture complète antérieure reste utilisable après une tentative
  partielle ; une lecture complète vide permet de continuer.
- Le premier tableau de bord accepte zéro poste. Un résultat sans comptage ou une erreur
  restent récupérables. Le calcul d’une ancienne OU ne bloque plus la nouvelle carte.
- Une lecture AD partielle attend son reçu de stockage. Son état reste partiel ; depuis
  l’Accueil, la collecte peut suivre sur les postes connus seulement après cette confirmation.
  Le banc de sauvegarde termine l’écriture simulée d’annulation avant son scénario suivant.
- La fabrique PROD Windows accepte les helpers de trace explicitement facultatifs, comme
  le générateur Python. Le parseur natif charge les dépendances actuelles des workers et
  vérifie leurs corps composés. Aucun corps worker n’a été changé.

## Résultats

| Contrôle | Résultat et preuve |
|---|---|
| Régression sur master non corrigé | Échec attendu : étape OU non redessinée, [1 cas rouge](red/Boards-red.json). |
| Parcours WPF Premiers pas | [3/3](application/windows/FirstSteps.json), vrais contrôles et callbacks, transports fictifs ; aucun scan déclenché. |
| Actualisation OU, reçus, annulation et sauvegarde préalable | [58/58](application/windows/OuRefresh.json), orchestration réelle avec doubles de transport. |
| Fraîcheur, dont SQLite réel | [22/22](intermediate/windows/Freshness.json). |
| Règles de livraison et premier lancement | [17/17](intermediate/windows/Delivery.json), dont FRN-001 à FRN-004. |
| Analyse native des sources et workers | [335 fichiers, 97 workers, zéro échec](delivery/NativeParser.json). Workers assemblés et analysés, jamais invoqués. |
| Compatibilité du runtime PowerShell 5.1 | [PASS](application/windows/Ps51Compat.json). |
| Démarrage PROD `-CheckOnly` | [Code 0](delivery/Runner.json), 172 fichiers vérifiés et 130 modules chargés ; aucun accès AD. Ce contrôle n’ouvre pas l’application. |
| Fabrication PROD depuis le DEV livré | [4 contrôles réussis](delivery/Factory.json) : structure, égalité du code, métadonnées et démarrage. Seul le statut devient volontairement `LocalBuildRequiresValidation`. |
| Cohérence des archives livrées | [172 fichiers applicatifs identiques DEV/PROD](delivery/RuntimeIdentity.json), manifestes et empreintes vérifiés. |

Les audits obligatoires de construction passent : version, imports, composition et contrats
worker, syntaxe statique, documentation, inventaire des composants et intégrité des ZIP.
[Rapport de construction](build-report.json).

## Archives et chaîne de preuve

- PROD : `6a60a30a27cba4ec5d83ba76e81a9f99ff8c4bac7911977262ebaa7af477f94d`
- DEV : `4910d9251c351ba3f261954840f845641d8818217a53e67825c8e0fccf25ccd7`

Le PROD final est identique à l’octet au PROD des essais applicatifs `application/`.
Après ces essais, seuls deux outils DEV et son manifeste ont changé ; ils ont été testés
dans `delivery/` sur les archives définitives. Les résultats Fraîcheur/Livraison conservés
portent sur des tests, modules et DLL identiques ; les deux fonctions Core utilisées
par Fraîcheur sont également identiques, avec leurs empreintes dans `Verification.json`.

Les échecs intermédiaires restent dans `intermediate/` et `application/` :
trois assertions d’actualisation OU, un harnais de workers dépassé par les refactorisations,
puis le refus de fabrication native corrigé. Le premier superviseur n’a pas conservé
les codes de sortie de certains processus ; les rapports des suites restent disponibles.
Les superviseurs applicatif et final conservent leurs codes de sortie.
Les anciens rapports ne sont ni remplacés ni présentés comme des succès.

## Limites et laboratoire

Deux bancs plus larges ont été arrêtés à leur budget de 240 secondes : Boards complet
(41 cas passés sur 66 avant interruption) et WiringCache complet (aucun rapport final).
Ils restent **incomplets**. Les trois parcours Premiers pas ont ensuite été terminés séparément.
Aucune campagne générale, recette humaine, multi-écrans, Narrateur ou qualification AD/WMI
du parc réel n’est revendiquée pour RC1.17.35. Les autres preuves restent historiques.
Les composants embarqués et le statut de candidat personnel autonome sont conservés ;
`Publishable=false` reste inchangé.

Les essais ont tourné dans **DOMENIA-FIRSTRUN-20261020**
(`8bf8233b-79e3-485a-a84a-74c8cbeaea44`), clone complet indépendant créé pour cette tâche.
Son nom Windows interne reste FILPRO-W11B : les tests n’ont pas été exécutés dans la VM source.
Le [reçu de création](Clone.json) confirme l’identité et la configuration source inchangée.
PESTO et les autres projets n’ont pas été utilisés.
La première VM temporaire et son disque ont été supprimés après push vérifié du commit `287299d`,
avant la nouvelle demande de conservation ci-dessous.
Les sept VM préexistantes sont conservées, dont CNAMTS-DC01 toujours démarré.
Le journal VirtualBox résiduel a été retiré après inspection ; le dossier de la VM est absent.
[Reçu final de nettoyage](Cleanup.json).


## Conservation demandée après le nettoyage

David a ensuite demandé de garder une VM au cas où. La suppression était déjà terminée :
une **nouvelle copie complète indépendante** de FILPRO-W11B-TEST a été créée sous le même
nom **DOMENIA-FIRSTRUN-20261020**, UUID `bc2f1ac0-9545-49bd-a0f5-cb89d352cf61`.
Il ne s’agit pas de l’ancienne VM restaurée. La configuration source est restée identique
pendant le clonage ([reçu](KeptClone.json)).

Les packs définitifs DEV et PROD RC1.17.35 sont extraits dans `C:\DomeniaLab\RC1.17.35`.
Leurs empreintes ZIP et les 172 fichiers applicatifs de chaque édition ont été vérifiés,
sans lancer l’application ni reprendre les tests ([déploiement](KeptDeployment.json)).
Le démarrage firmware bloqué à deux processeurs a été résolu en revenant à un processeur,
comme lors des essais initiaux. Windows et le contrôle invité ont ensuite répondu.

La VM est **conservée en état sauvegardé VirtualBox** (mémoire et disque gardés), après
un arrêt Windows qui n’a pas terminé dans le délai d’attente. Elle ne consomme plus de CPU.
Au prochain démarrage, laisser cet éventuel arrêt se terminer puis redémarrer si nécessaire.
Les sept VM préexistantes restent enregistrées ; CNAMTS-DC01 reste démarré.
[État final vérifié](RetainedVm.json). Les preuves de qualification précédentes portent
sur l’ancienne VM ; aucune nouvelle qualification n’est revendiquée pour cette copie.
