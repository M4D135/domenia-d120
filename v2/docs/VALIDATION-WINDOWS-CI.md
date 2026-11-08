# Compilation Windows sur GitHub

Le workflow `.github/workflows/domenia-v2-windows.yml` permet une compilation Windows réelle du commit poussé sur `v2` ou sur une branche `codex/**`. Il compile aussi les demandes de fusion vers `v2`. Il ne publie aucune release.

## Ce qui est exécuté

Le runner `windows-2025` utilise uniquement le SDK déjà installé compatible avec `global.json` (`10.0.401`, correction la plus récente de la même bande). Aucun `setup-dotnet`, téléchargement de SDK, runtime, navigateur ou paquet NuGet n'est ajouté. Si le SDK ou un pack de ciblage manque, le job échoue avec son diagnostic ; aucun repli ne modifie le SDK demandé.

Les cinq paquets de `vendor/nuget` sont relus et comparés à `SHA256SUMS`. Le restore utilise une configuration temporaire avec cette seule source locale, un cache de paquets propre au job et l'audit NuGet en ligne désactivé. Aucun feed public ni cache personnel n'entre dans la compilation.

Tous les projets `src/` et `tests/` sont compilés en Debug puis Release, avec les avertissements traités comme erreurs. La propriété `SelfContained=false` est limitée à cette commande CI : les sorties dépendent du runtime Windows déjà présent. Le lanceur apphost est conservé quand son pack est disponible dans le SDK afin de préserver les tests des processus enfants. Cette compilation ne produit donc **aucun pack PROD/DEV autonome** et ne change pas la configuration de livraison du projet.

Les preuves `artifacts/domenia-v2-ci/logs/` contiennent le commit réel, l'image Windows, les SDK présents, le SDK choisi, les empreintes NuGet, les journaux de restore/build et `result.json`. Les fichiers sont joints même si une étape échoue. Un état `not-run` reste distinct de `passed`.

## Tests après développement

Un push ordinaire compile seulement. L'entrée manuelle `critical_tests=true` demande la sélection C# `--critical`, après la fin du développement et son push. Le script demande alors aussi `-FinalValidation`. La sélection du projet refuse elle-même les classes manquantes et une sélection vide ; aucun appel au protocole `--native-acceptance` n'est effectué.

La même demande exécute ensuite les quinze contrôles critiques de `tests/tools/test_release_guard.py`, avec Python déjà installé sur le runner et sa seule bibliothèque standard. Ils vérifient les refus de preuves de livraison absentes, altérées ou insuffisantes. Leurs données fictives ne sont jamais des reçus UI/native ; ils ne publient rien. L'absence de Python est un échec explicite, sans installation de secours. `result.json` distingue `critical` (C#) de `releaseGuardCritical`.

La connexion GitHub de cette reprise permet de pousser les sources et de lire les journaux, mais n'expose pas l'envoi de `workflow_dispatch`. Le workflow reconnaît donc aussi **une branche de validation explicite**, `codex/v2-validation-critique-20261025`, à créer depuis le commit de développement terminé et poussé. Seul un push sur ce nom exact demande les contrôles C# critiques locaux ; éditer le workflow ou pousser sur `codex/v2-finalisation-20261025` ne les déclenche pas. Cette branche est distincte de `v2` et ne publie rien. En cas d'échec, conserver le journal et corriger sur la branche de développement avant une nouvelle validation explicite. Ne pas confondre cette vérification Windows locale avec l'acceptation des deux VM du laboratoire.

Le workflow ne lance ni les scénarios AD, ni une recette UI avec un WebView2 téléchargé. Les tests qui exigent le runtime fixe ou une session du laboratoire restent à exécuter dans leur environnement prévu. Le rapport C# n'établit jamais à lui seul une validation UI/native.

## Portée de la preuve

| Résultat observé | Ce qu'il établit |
| --- | --- |
| Build Debug/Release vert | Le commit exact compile sur le Windows hébergé et le SDK indiqué, sans avertissement de compilation. |
| Sélection C# critique verte | Les tests critiques locaux sélectionnés ont réellement terminé sur ce runner Windows. |
| Job rouge ou absent | Aucun succès n'est déduit ; le journal dit ce qui a pu être exécuté. |
| Aucune recette sur les deux VM | Les validations domaine, transport natif et UI du laboratoire restent non vérifiées. |

La publication `v2.0.0` reste conditionnée aux deux VM autorisées et aux archives exactes, conformément au dossier de reprise. Ce workflow ne contourne pas cette exigence et ne possède que `contents: read`.

L'ajout ou la modification du fichier de workflow peut exiger la permission GitHub **Workflows: write** en plus de **Contents: write** pour la connexion qui pousse les sources. Un refus de cette permission doit être conservé et annoncé ; aucune autre identité n'est utilisée pour le contourner.
