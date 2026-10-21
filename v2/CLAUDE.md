# Domenia 2 — consignes du dossier `v2/`

Ce dossier contient la réécriture de Domenia en C# (.NET 10 LTS autonome) avec une interface HTML dans WebView2.
Lire d'abord `ARCHITECTURE.md`. Les règles de sécurité de la racine du dépôt (`../CLAUDE.md`, section « Règles non
négociables » points 2 à 5) s'appliquent ici aussi ; les règles propres à PowerShell 5.1 (point 1, conventions `.ps1`)
ne concernent que `dev/` (Domenia 1).

## Développement

- **On développe et on compile sous Windows**, dans la VM Domenia du labo (`ssh domenia-vm`, Windows 11 jointe à
  `cnamts.local`, sans accès Internet). SDK : `C:\DomeniaDev\dotnet\dotnet.exe` (10.0.401). Les sources sont
  éditées dans ce dépôt puis synchronisées dans `C:\DomeniaDev\src` (`tools/sync-vm.sh`).
- **Tests à la toute fin** (décision de David du 21/10) : on écrit les tests au fil du code, on les exécute dans la VM
  quand le développement est terminé. Compiler reste permis à tout moment.
- Aucune dépendance téléchargée sans accord explicite de David (la VM n'a pas Internet : les paquets passent par
  `vendor/nuget/`, avec licence et empreinte).

## Code

- C# moderne, `Nullable` activé, `TreatWarningsAsErrors`, analyseurs .NET activés, `InvariantGlobalization` désactivé
  (textes français), `LangVersion` latest.
- Aucune exception avalée sans trace ; aucune opération réseau, LDAP ou WMI sur le fil de l'interface.
- Commentaires en anglais ; textes d'interface et documentation en français soigné (accents, apostrophe typographique
  autorisée dans le HTML et le C#).
- Interface : HTML/CSS/JS en modules ES natifs, sans chaîne de compilation ni bibliothèque en ligne ; politique de
  sécurité de contenu stricte ; aucune ressource externe.

## Parité

Chaque fonction de Domenia 1 est dans `docs/FEATURES.md` avec son statut (`a-faire`, `fait`, `ameliore`, `abandonne` —
ce dernier seulement sur décision écrite de David). Ne rien retirer sans décision.
