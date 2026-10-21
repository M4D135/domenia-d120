# Domenia 2 — réécriture C# et interface WebView2

Décisions de David (21 octobre 2026) : tout réécrire en C#, interface en HTML dans WebView2, aucune fonction perdue et de nouvelles ajoutées, 100 % portable sans rien installer, développement et compilation sous Windows (VM Domenia du labo, jointe à `cnamts.local`), tests à la toute fin.

## Cible

- **.NET 10 LTS autonome** (`win-x64`, `SelfContained`), support jusqu'en novembre 2028. Le runtime .NET est livré dans le dossier de l'application : rien à installer, pas de droits d'administration.
- **Moteur WebView2 « version fixe »** livré dans le pack (`runtime/webview2/`, 154.0.4258.62, signature Microsoft vérifiée), SDK `Microsoft.Web.WebView2` 1.0.4258.31. Le pack portable est publié en *Release* GitHub ; le dépôt ne garde que les manifestes et empreintes. Mesuré le 21 octobre 2026 par `tools/build-vm.ps1 -Configuration Release -Publish -Zip` : dossier de 781 Mo, dont 669 Mo pour `runtime/webview2/` (fichiers du moteur fixe seulement, ni symboles ni archive d’installation), et archive `Domenia.zip` de 341 Mo (en Mio, comme les affiche l’outil).
- **Dépendances minimales** : SQLite par `winsqlite3.dll` (fourni par Windows), LDAP par `System.DirectoryServices` / `System.DirectoryServices.Protocols`, WMI/CIM DCOM par `System.Management`, WebView2 par son SDK. Aucun service, aucun port ouvert, aucun cloud.

## Pack PROD : dézipper et lancer

Le pack PROD contient tout : `Domenia.exe` autonome (.NET 10 embarqué), `runtime/webview2/` (moteur fixe), `web/`, les catalogues et guides. L'opérateur le dézippe n'importe où (y compris sur un partage ou une clé), lance `Domenia.exe`, et c'est tout : aucune installation, aucun droit d'administration, aucun prérequis autre que Windows 10/11 x64. Les données utilisateur vont dans `%LOCALAPPDATA%\Domenia` (ou à côté de l'exe en mode portable explicite).

## Disposition du dépôt

```text
v2/
  Domenia.sln             générée et complétée dans la VM par tools/build-vm.ps1 (non versionnée)
  src/
    Domenia.App/          exe WinForms minimal : fenêtre, WebView2, pont, cycle de vie, repli d'erreur
    Domenia.Core/         modèles et règles pures (port des *.Model.ps1), sans E/S
    Domenia.Store/        SQLite (winsqlite3), schéma et migrations, compatibilité avec la base Domenia 1
    Domenia.Ad/    lectures et écritures AD bornées, identités, LAPS/BitLocker, reçus d'écriture
    Domenia.Inventory/    ping, WMI/CIM DCOM, catalogue de sondes, relevés, budgets réseau
    Domenia.Engine/       ordonnanceur de tâches, budgets, garde d'authentification, journal, mesures
    Domenia.Bridge/       contrat des messages page ↔ moteur (opérations fermées, schémas, validation)
    Domenia.Simulation/   annuaire fictif en mémoire, lecture seule, sans réseau ni disque (référence Core seulement)
  web/                    interface HTML/CSS/JS sans chaîne de compilation (modules ES natifs)
    index.html, css/, js/, assets/
  tests/
    Domenia.Tests/        lanceur de tests maison (console), sans paquet externe
    web/                  tests JavaScript (exécutés par le moteur WebView2 lui-même ou Node si présent)
  tools/                  construction du pack portable, inventaires, contrôles
  docs/                   catalogue des fonctions, parité, guides
```

## Principes

1. **Parité d'abord, mieux ensuite.** Le catalogue `docs/FEATURES.md` (extrait du code Domenia 1 : 133 modules, cœur, 97 opérations épinglées, 1 164 contrôles, règles et tests) est la liste de contrôle ; chaque ligne a un statut. Les améliorations (liste du 21/10) s'ajoutent après la parité de chaque écran.
2. **Les règles de sécurité de Domenia 1 sont reprises telles quelles** : lecture seule par défaut, aucune action réseau ni LDAP sans geste explicite, jamais tout le domaine, écritures avec plan, confirmation, reçu et relecture, jamais rejouées automatiquement, aucun secret journalisé ni passé en ligne de commande, garde d'authentification (un refus suspend le compte concerné), mots de passe en `SecureString` jusqu'à l'API Windows.
3. **Le moteur ne bloque jamais l'interface.** Toute lecture AD, WMI, réseau ou SQLite s'exécute en tâche de fond (`Task` + ordonnanceur à budgets) ; la page reçoit progression et résultats par messages.
4. **Pont fermé et typé.** La page n'appelle que des opérations déclarées (`Domenia.Bridge`), chacune avec son schéma d'entrée, sa classe (lecture locale, lecture réseau, écriture), son budget et ses droits ; tout message non conforme est refusé et tracé.
5. **WebView2 verrouillé.** Contenu servi uniquement depuis le dossier `web/` par le nom virtuel `https://domenia.local/`, politique de sécurité de contenu stricte (`default-src 'self'`), navigation hors de ce nom bloquée, nouvelles fenêtres refusées, outils de développement et menu contextuel désactivés en PROD, dossier de données utilisateur sous `%LOCALAPPDATA%\Domenia\WebView2` (`WebView2-Simulation` en simulation), requêtes hors `domenia.local` refusées par l'hôte.
6. **Compatibilité des données.** La base SQLite locale de Domenia 1 (schéma 11) est lue et migrée sans perte ; les réglages et dispositions de tableaux sont repris.
7. **Code de qualité** : C# moderne, `nullable` activé, avertissements traités comme des erreurs, analyseurs .NET, aucune exception avalée sans trace, textes d'interface en français soigné.

## Interface

Un « site » d'application soigné : navigation latérale par espaces (Accueil, Rechercher, Fiches, Parc, Analyses, Assistance, Administration), barre supérieure (recherche universelle et palette de commandes, domaine et contrôleur, lecture seule, centre des opérations, thème, aide), écrans en grille fluide, animations riches par défaut — fond aurora vivant, surfaces en verre, halo qui suit la souris, entrées en cascade, transitions de page, graphiques qui se tracent (décision de David du 21/10) — avec un réglage « Animations : riches, réduites, suivre Windows », thèmes clair, sombre et contraste élevé, accessibilité clavier et lecteur d'écran, DPI natif. Palette héritée de Domenia 1 (`SupportSuite.UI.json`).

## Ordre de réalisation

1. Socle : solution, construction dans la VM, hôte WebView2, pont, lanceur de tests, pack portable.
2. Catalogue complet des fonctions de Domenia 1.
3. Cœur et stockage (règles pures et base, compatibilité de la base existante).
4. Moteur, annuaire, inventaire.
5. Interface : système de design puis chaque écran, parité puis améliorations.
6. Améliorations de la liste du 21/10.
7. Pack portable, guides, puis tests complets sous Windows (à la toute fin, à la demande de David).
