# Reprise GitHub — réglages 124/125 et CLI 067 — 25 octobre 2026

Base examinée : `9b1c0333c34020ad88c1448874b91eff884d5406`, branche de travail dédiée `codex/v2-finalisation-20261025`.

## Écarts prouvés

- L’admission et le dispatcher utilisaient les constantes 30/120/25 alors que Configuration exposait `BackgroundAgingSeconds`, `MaxQueueWaitSeconds` et `TickBudgetMs`.
- `ShellAutomation` déclarait les six commandes de lecture, mais `Program.Main` ne raccordait que `dossier`.
- Le lecteur local du dossier exigeait les projections v2. Il ne pouvait pas satisfaire la lecture directe du schéma historique 11 demandée par 067.
- Lire seulement les tables historiques aurait omis les relevés v2 dans `domenia_v2_metadata/fleet` et les requêtes dans `domenia_v2_query_library`.

## Réalisé dans le code

124/125 : `QueueTiming` borné et immuable ; instantané de configuration partagé entre composition, admission/dispatcher et écran Configuration. Vieillissement, expiration, délai annoncé, temps affiché et budget de promotion utilisent les valeurs effectives. Le fichier est relu au lancement, conformément à l’UI existante ; aucune revendication d’application à chaud.

067 : grammaire fermée, routage avant entretien/journaux/composition, six commandes locales, JSON/CSV, base explicite, identité/schéma, transaction readonly, lecture D1 et projections v2, données datées, seuil + sentinelle, retrait des champs secrets, refus des chemins réseau/liens/périphériques, mode démonstration et fichier de sortie existant. Sortie facultative atomique relue SHA256. Aucun fournisseur AD, service ou runtime ajouté.

Concession explicitement documentée : les bases WAL/journal actif sont refusées pour garantir qu’une lecture ne crée/modifie aucun fichier annexe SQLite ; aucune conversion automatique ni modification du mode de journalisation.

## Validation

- 4 tests `QueueTimingTests`, 6 tests `AutomationCommandTests`, 7 tests `AutomationLocalStoreTests` écrits ; **non exécutés et non compilés par ce lot**.
- Relecture du diff et vérification textuelle d’espaces effectuées ; cela ne prouve ni compilation ni réussite fonctionnelle.
- Compilation du nouveau code, tests critiques dans **deux VM Windows**, recette UI/native et publication PROD/DEV : **non vérifiés**.
- Aucun fichier `dev/` modifié, aucune dépendance téléchargée, aucun test ni compilation lancé ici, aucun commit/push par ce sous-lot (intégration centralisée).

Mode d’emploi et recette à effectuer : [automation-cli.md](../../ops/automation-cli.md).

## Intégration et compilation constatées ensuite

Lot intégré dans `ea35a36032cdaa98153dc7106a7a00ae39aae2c1`, puis garde du DN nullable corrigée dans `1ecfedef6f6ba8913151b2f8411ca5650d3b3c64`. La compilation des tests liés à l’interop Windows exigeait aussi `AllowUnsafeBlocks` dans le projet de tests ; ce correctif est inclus dans `fea4c18117d07145d669859f16140739dde03329`. Les échecs intermédiaires restent dans Actions.

[Run Windows 40215771359](https://github.com/M4D135/domenia-d120/actions/runs/40215771359), job `121236451103`, sur `fea4c181` : journaux Debug/Release lus, **0 erreur et 0 avertissement**. Les tests de ce lot sont désormais compilés, mais **aucun test exécuté dans ce passage**. Les validations critiques et UI/native des deux VM restent à établir.
