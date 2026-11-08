# Runtime .NET privé issu de l’installation Windows — 25 octobre 2026

L’inventaire GitHub Windows `aa52210a`, run `40227092191`, job `121270658930`, ne trouve pas les packs `Microsoft.NETCore.App.Runtime.win-x64` et `Microsoft.WindowsDesktop.App.Runtime.win-x64`. Il confirme les runtimes partagés et `hostfxr` 10.0.13 déjà installés. Ce lot prépare leur copie privée sans installation, téléchargement, SDK embarqué, ASP.NET ni modification du runtime système.

## Interfaces

Le fichier `tools/private-dotnet-runtime.ps1` se charge par dot-sourcing, sans action à son chargement.

- `Get-PrivateDotNetRuntime -DotNetRoot <installation> [-Version 10.0.x]` choisit la plus haute version stable commune à `host/fxr`, `shared/Microsoft.NETCore.App` et `shared/Microsoft.WindowsDesktop.App`, ou exige la version explicitement demandée. Il retourne `sourceRoot`, `version`, `relativeRoot`, `coreLibraryRelativePath`, `directories`, `files`, `fileCount`, `length` et `inventorySha256`.
- `Copy-PrivateDotNetRuntime -Runtime <instantané> -PackageRoot <nouveau dossier PROD>` requalifie la sélection, copie tous ses fichiers et dossiers vers une préparation voisine neuve, puis installe par déplacement sans écrasement dans `runtime/dotnet`. Le retour contient notamment `root`, `version`, `coreLibraryPath` et `inventorySha256`.

Les entrées comprennent `dotnet.exe`, les deux notices de l’installation et les trois arbres complets de cette seule version. Chemins locaux ordinaires, ancêtres sans reparse point, noms non ambigus, architecture PE AMD64 des composants natifs, tailles et SHA256 sont contrôlés. La borne est de 2 048 fichiers, 2 048 dossiers et 2 Gio. L’empreinte d’inventaire dépend des chemins, des dossiers, de la version, des tailles et des empreintes des octets ; elle ne constitue pas une signature de l’éditeur.

La copie ouvre les fichiers de destination avec `CreateNew`, vérifie les octets copiés, requalifie la source après copie et contrôle tout l’arbre de destination, y compris l’absence de fichier ou version supplémentaire. Une destination existante ou un paquet déjà manifesté est refusé. Une préparation interrompue reste à côté du paquet pour diagnostic.

## Raccordement par le publisher

Le publisher doit incorporer `inventorySha256` à l’identité de construction, puis publier avec les paramètres suivants :

```text
SelfContained=false
AppHostDotNetSearch=AppRelative
AppHostRelativeDotNet=runtime/dotnet
RuntimeFrameworkVersion=<version choisie>
RollForward=Disable
```

La restauration NuGet reste fermée sur les entrées locales déjà présentes. Aucun fallback `Global` ou `EnvironmentVariable` ne doit être ajouté. Le même `Domenia.exe` natif lance l’application ; son runtime réside dans le paquet. Les propriétés de recherche ne s’appliquent qu’à `publish`, ce qui impose de livrer cet exécutable publié, pas celui du simple build. Les métadonnées `.NET` peuvent lire `coreLibraryPath` retourné par la copie.

`HostFacts.ReadInventory` compte désormais l’arbre privé et lit la version de son CoreCLR uniquement lorsque la bibliothèque centrale du processus a effectivement été chargée sous `runtime/dotnet`. Le runtime global n’est jamais présenté comme une copie privée. Le chemin historique de publication à plat reste pris en charge.

## Validation à établir

Relecture statique uniquement dans cet environnement ; aucun build ni test local. Le prochain passage Windows doit produire le paquet, exécuter son contrôle local existant et prouver le chargement depuis le runtime privé. Sur une copie de contrôle distincte, l’absence de `runtime/dotnet/host/fxr` doit empêcher le démarrage même si .NET est installé globalement. Cette vérification ne renomme ni ne modifie aucun composant global. La recette UI/native reste manuelle selon la dernière décision utilisateur ; aucune preuve des deux VM n’est déduite de ce lot.

Référence Microsoft : [propriétés AppHostDotNetSearch et AppHostRelativeDotNet](https://learn.microsoft.com/en-us/dotnet/core/project-sdk/msbuild-props#apphostdotnetsearch).
