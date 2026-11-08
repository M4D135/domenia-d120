# Qualification Domenia v2 sans poste de test — état au 2026-11-02

## Ce qui est arrivé au moyen d'exécution

- Le poste de qualification (`192.168.1.173`, compte `degun`, runner `domenia-pc173`, label
  `domenia-win`) a été **formaté** : `C:\actions-runner`, `C:\DomeniaDev` (SDK .NET 10.0.401, caches,
  preuves) et `C:\dp` (racines courtes des essais) n'existent plus. Le PC a redémarré à 09:10:15
  pendant l'étape 5 du run `41409917018`, ce qui a fait passer cette étape à `cancelled`.
- Les runners **hébergés** sont indisponibles sur le compte : les trois jobs de la sonde
  `spark/sonde-runners` (`windows-latest`, `ubuntu-latest`, `macos-latest`, run `41423088529`) ont
  échoué avec **zéro étape** et cette annotation :
  `The job was not started because recent account payments have failed or your spending limit needs
  to be increased. Please check the 'Billing & plans' section in your settings`
  (`runner_id: 0`, `runner_name: ''` ; dépôt privé, `allowed_actions: all`).
- Le Mac de développement n'a **ni `dotnet`, ni `node`, ni `pwsh`** (seulement `git`, `python3`,
  Homebrew sous `/opt/homebrew`). Les projets de tests ciblent `net10.0-windows` / `win-x64` : ils
  sont inexécutables hors Windows, et les packs PROD/DEV ne peuvent être construits nulle part ici.

Conséquence : **aucune exécution** du produit n'est possible aujourd'hui. Rien ne peut être annoncé
comme qualifié, et aucune intégration à `master` ne doit être faite.

## Chiffres mesurés, à reproduire sur tout nouveau moyen d'exécution

Commit qualifié `06fd7ffe` (branche `codex/integration-22-lots-20261101`), sur le poste avant
formattage, binaires construits par `v2/tools/ci-windows.ps1 -Critical -FinalValidation` :

| contrôle | résultat mesuré |
| --- | --- |
| sélections critiques (`--critical`) | **1544 réussis, 0 en échec, 1544 au total** |
| suite C# complète | **2986 réussis, 0 en échec, 2986 au total** |
| builds Debug + Release `-warnaserror` | code de sortie 0 |

Ces chiffres provenaient des journaux `artifacts/domenia-v2-ci/logs/{critical,full}-csharp.log` du
poste, **détruits avec lui** : ils n'ont plus de preuve attachée et doivent être reproduits.

Conditions d'obtention (à rétablir à l'identique, sous peine de faux échecs) :

- `%LOCALAPPDATA%` et `%APPDATA%` sous le profil de l'utilisateur (DACL privée : le magasin
  utilisateur refuse toute ACE héritée d'un tiers), `%TEMP%` à la racine du lecteur (DACL native
  héritée : `BUILTIN\Utilisateurs` + « Utilisateurs authentifiés » attendus par la publication du
  parc partagé), les deux chemins **courts** (au-delà de ~80 caractères, les bases SQLite et annexes
  de sauvegarde échouent en « Opération SQLite interrompue (code 14…) »). Le bloc est déjà dans
  `.github/workflows/domenia-v2-livraison.yml`.
- Un profil de test distinct par étape et par tentative (`GITHUB_RUN_ATTEMPT`) : supprimer le profil
  d'une étape précédente échoue souvent (fichiers encore verrouillés) et partager une racine entre
  étapes réintroduit la pollution.
- Aucune assertion modifiée pour obtenir ces chiffres. Les trois échecs restants avant `06fd7ffe`
  étaient un défaut d'herméticité de `TemporaryFolder` (héritage de la DACL du dossier temporaire),
  corrigé dans `v2/tests/Domenia.Tests/TestSupport.cs`.

## Ce que le moyen d'exécution doit fournir

- SDK **.NET 10.0.401** présent sur la machine (PATH ou `DOTNET_ROOT`). `ci-windows.ps1` interdit
  toute installation pendant la CI : sans SDK préinstallé il échoue sur
  « SDK .NET préinstallé absent ; aucun setup-dotnet ni installation autorisés ». Ne pas ajouter
  `actions/setup-dotnet` au workflow.
- Restauration **hors ligne** : `v2/vendor/nuget` + son `SHA256SUMS` (contrôlés par le script),
  `NuGet.offline.config` avec un seul feed local, `NUGET_PACKAGES` sous le dossier de preuves.
  Aucun téléchargement de dépendance n'est acceptable.
- Le candidat lance les modules critiques web avec Domenia.WebTests et le WebView2
  privé. `release-manual-ci.ps1` démarre le précontrôle puis la recette du paquet
  avec `--critical`. Cela inclut `write-flow-focus.test.mjs`. Node.js et une VM
  ne sont pas requis pour ces contrôles. La liste complète de `run.mjs` demeure
  distincte de la sélection critique.
- Le brouillon de release appartenait à la branche collective du 1er novembre.
  Sur `codex/candidat-22-lots-20261102`, les ZIP PROD et PROD-LIGHT et leurs empreintes
  sont conservés comme artefacts Actions temporaires. Le transfert des preuves
  doit réussir pour valider le candidat.

## Voies disponibles

1. **Rétablir la facturation GitHub** (`Settings → Billing & plans` du compte `M4D135`) : le même
   workflow fonctionne alors sur runner hébergé, l'input `runner` acceptant `windows-2025`. Aucun
   poste physique n'est nécessaire. Vérifier au préalable que l'image hébergée expose bien un SDK
   satisfaisant `v2/global.json`.
2. **Enrôler n'importe quel autre poste Windows** (poste du parc, VM, machine temporaire) avec
   `v2/tools/enroll-windows-runner.ps1` : le SDK doit être installé avant par l'opérateur, le zip du
   runner est exigé avec son SHA-256, aucune dépendance du produit n'est téléchargée. Minutes
   auto-hébergées : gratuites.
3. **Poursuite sans exécution** (ce qui est fait en attendant) : relecture croisée des lots,
   achèvement documentaire, préparation des outils d'enrôlement. Aucun de ces travaux ne vaut
   qualification.

## Interdits explicites tant qu'aucun moyen d'exécution n'existe

- Annoncer une qualification Windows, un pack qualifié ou une livraison.
- Intégrer un lot à `master` (l'état reste 0/22 intégré ; `origin/master = cf93a6aa`, production 2.0.8).
- Modifier une assertion, un sélecteur de tests critiques ou le contrat de `ci-windows.ps1` pour
  faire passer un vert.
