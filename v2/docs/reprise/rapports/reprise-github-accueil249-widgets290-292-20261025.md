# Reprise GitHub — Accueil 249 et widgets 290–292

Date : 25 octobre 2026. Base examinée : `9b1c0333c34020ad88c1448874b91eff884d5406`, branche de travail `codex/v2-finalisation-20261025`.

## Écarts constatés dans cette base

- Le journal `IHomeCampaignRecorder` existait dans `AdOperationsReader.HomeCampaign.cs`, sans appel dans le pipeline `AccueilService`. La commande de reprise relisait seulement `lastReport` en mémoire et reconstruisait les cibles et sondes depuis la disposition courante.
- `accueil.refresh.state` était une réponse de session synchrone ; aucune reprise durable n’était proposée après recréation du service.
- L’ajout d’une carte dans `web/js/pages/accueil/board.js` enregistrait et recalculait seulement la disposition. Aucun plan de collecte propre au widget, file bornée ni progression indépendante des chiffres n’y était raccordé.

## Modifications

- Le pipeline Accueil ouvre le journal avant toute lecture, conserve les cibles et les références de requêtes originales, observe uniquement les résultats déjà enregistrés, sauvegarde toutes les dix secondes pendant les relevés longs et à la fin de chaque étape/arrêt. Il conserve son admission jusqu’à la fin du lecteur physique et des écritures finales.
- `accueil.refresh.state` lit localement la reprise. `resume` réutilise son périmètre exact, ses étapes, sondes, révisions et bits de progression ; il refuse une autre identité/session/base, une référence disparue ou une mesure cochée qui n’existe plus localement. Aucune reprise automatique. Une nouvelle campagne remplace un plan interrompu seulement après l’offre explicite et un contrôle de sa révision.
- Les collectes de widgets disposent de plans consommables une fois, limités aux données manquantes de moins de trente jours. L’ajout explicite jusqu’à 200 postes ne demande pas de seconde confirmation. Actualiser, F5 et reprise d’une carte suspendue demandent confirmation. Le plafond configurable des widgets est appliqué ; zéro garde son sens « illimité ».
- Les lectures AD de l’OU (recensement ou présence BitLocker) demandent toujours confirmation : le volume réel n’est pas connu depuis le seul cache. Le dialogue distingue les postes connus localement du nombre inconnu d’objets AD et ne prétend pas figer les découvertes de l’OU.
- Une file de vingt demandes au plus refuse les doublons. Elle requalifie le widget, l’OU, la session, la base et les identités avant admission. Une suppression, une suspension ou un contexte devenu invalide abandonne la demande. Les cartes santé incluent les sources de leurs alertes liées.
- La collecte suivante attend les commits, le recalcul et l’accusé de dessin de la précédente. Le moteur conserve explicitement l’état `drawing` ; un dessin abandonné retire les demandes en attente. L’actualisation globale expose aussi `AwaitingDraw`.
- L’UI affiche la file et les compteurs à une seconde tout en conservant les derniers chiffres. L’aperçu navigateur garde des données fictives et ne prétend pas effectuer des lectures natives.
- La qualification GUID/DN/création/SID/hôte/compte/époque des sondes est transmise jusqu’au lecteur AD. Un changement d’OU annule également les demandes côté moteur. Les échecs de plusieurs requêtes sur le même poste sont comptés une seule fois.

## Vérifications et preuves restant requises

Relecture statique effectuée ; `git diff --check` sans anomalie sur les fichiers de ce lot. **Aucun test exécuté pendant ce développement. Aucune preuve UI/native obtenue par ce lot.** La compilation Windows de la branche modifiée doit être confirmée par la CI, distinctement des tests.

Tests écrits, non exécutés :

- `AccueilDurablePipelineTests` : arrêt avec lecteur physique encore vivant, progression réellement enregistrée, nouvelle instance du service sans replay, reprise sans élargissement, refus d’identité réaffectée/mesure perdue et refus initial du journal avant réseau.
- `AccueilWidgetCollectionTests` : attente de dessin, réemploi des données de la carte précédente, confirmation des gestes autres qu’ajout, refus d’identité changée et abandon de la file après dessin échoué.
- `tests/web/accueil-widget-collections.test.mjs` : progression indépendante des chiffres, un suivi à une seconde, accusé seulement après dessin réussi, préparation tardive après changement d’OU et confirmation réelle.

Après commit/push : exécuter ces tests critiques et les recettes UI/native dans **deux VM Windows**. Vérifier notamment fermeture/réouverture réelle avec SQLite, arrêt d’un lecteur natif lent, changement d’OU/session pendant attente, ajout de 200 puis 201 postes, retrait/suspension d’une carte en file, échec du dessin et révisions de requête archivées. La conservation historique du journal est bornée à 5 000 identités par son format existant ; une campagne au-delà doit être refusée, jamais tronquée.

Ces modifications ne constituent ni une validation finale, ni une autorisation de publier PROD/DEV v2.0.0. Le lot123 local Spark/Mac n’a pas été récupéré ni utilisé.

## Compilation Windows du lot poussé

Commit `fea4c18117d07145d669859f16140739dde03329` : [GitHub Actions 40215771359](https://github.com/M4D135/domenia-d120/actions/runs/40215771359), job `121236451103`. Journaux lus : Debug et Release réussis, **0 avertissement, 0 erreur**, SDK 10.0.402 préinstallé, paquets versionnés uniquement. Fin Release le 25/10/2026 à 17:20:11 UTC. Les tests ont été compilés mais **aucune suite exécutée**. Les corrections ultérieures et la recette UI/native des deux VM ne sont pas validées par ce passage.
