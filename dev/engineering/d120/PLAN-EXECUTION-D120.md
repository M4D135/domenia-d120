# Plan d'execution D001-D120 (RC1.11.0)

Document de travail du lot. Il fixe les decisions prises, l'architecture retenue et l'etat d'avancement.
Il ne vaut pas qualification : aucune ligne de ce fichier n'atteste une execution sous Windows PowerShell 5.1.

## Decisions verrouillees

| Id | Decision | Confiance |
|---|---|---|
| F1 | Cible unique : Windows PowerShell 5.1 x64 STA. Garde-fou `tools/Test-DomeniaPs51Compat.ps1` dans le build. | elevee |
| F2 | Statut maximal pose par le lot : `RACCORDE_A_VALIDER_WINDOWS`. `acceptance_passed` reste faux tant qu'un rapport Windows 5.1 lie au hash du ZIP n'existe pas. | elevee |
| F3 | La preuve Windows est produite par l'operateur avec `QUALIFIER-WINDOWS.cmd`. | elevee |
| F4 | Le moteur RC1.10.7 est modifie. Version RC1.11.0. Les contrats worker modifies sont re-epingles et listes. | elevee |
| F5 | Nouveaux comportements actifs par defaut ; interrupteurs `Features.*` dans `Domenia.config.json` pour ceux qui remplacent un parcours existant. | moderee |
| F6 | Ordre P0, P1, P2 avec un etat reconstructible a chaque palier. | moderee |
| F7 | Encodage existant conserve : UTF-8 avec BOM, fins de ligne LF pour les .ps1, CRLF pour les .cmd. | moderee |
| F8 | `Domenia.exe` conserve a l'octet. Sa version de composant est declaree a part dans le contrat de release. | moderee |
| F9 | Schema SQLite : evolution en avant avec sauvegarde prealable et refus de retour arriere silencieux. | moderee |

## Architecture

- Regles pures : `wad/modules/Domenia-<Domaine>.Model.ps1`. Ni WPF, ni reseau, ni disque. Testables sans domaine.
- Interface : `wad/modules/Domenia-<Domaine>.UI.ps1`, vues XAML separees `Domenia-<Domaine>.xaml` chargees dans des hotes de la fenetre principale.
- Lectures a la demande : `Domenia-<Domaine>.Worker.ps1`, une operation epinglee par lecture, toujours declenchee par un geste explicite.
- Types immuables : `Domenia-Identity.Types.cs`, ecrit en C# 5 (compilateur de Windows PowerShell 5.1).
- Chargeur ferme `Domenia-Modules.ps1` : chaque module declare sa phase et ses dependances.

## Verification

1. Regles pures : `wad/tests/Test-DomeniaRules.ps1`.
2. Integration WPF sur le vrai XAML et les vrais gestionnaires : `wad/tests/Test-DomeniaWiring.ps1`.
3. Campagne Windows : `wad/tests/Invoke-DomeniaQualification.ps1`, dix scenarios requis par `release_guard.py`.

Bac a sable de preparation (jamais une preuve) : PowerShell 7.4 Linux pour le parseur et les regles ;
PowerShell 7.4 et WPF .NET 8 sous Wine pour charger le vrai XAML. Ligne de base des 23 suites existantes
dans ce bac a sable avant modification : 1069 tests reussis, 89 en echec (ecarts d'environnement ou suites historiques).

## Avancement

Voir `Suivi_D001_D120.json` pour le detail par point.
