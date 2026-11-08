# Version actuelle : ADCC 1.0 R1.10, interface compacte

Menu gauche repliable en icônes, aide droite rétractable, sélection OU lisible et login standard simplifié comme la référence RBP.

Le guide actuel est **INTERFACE-COMPACTE-R1.10.md**. Pour un aperçu sans AD : **APERCU-INTERFACE.cmd** et **APERCU-CONNEXION.cmd**.

Pour mettre à jour sans perdre la base : extraire ailleurs, fermer ADCC, puis utiliser **INSTALLER-MISE-A-JOUR.ps1 -Destination 'CHEMIN_DE_L_INSTALLATION'**. Ne pas supprimer l’ancien dossier et ne pas copier seulement le cœur.

La livraison inclut les lanceurs, le code et les modules complets. PowerShell/WPF et l’authentification au domaine n’ont pas été exécutés dans l’environnement Linux de préparation. Les tests Windows sont fournis.

## Historique des versions précédentes

Les sections suivantes et leurs anciennes assertions de test décrivent leur propre version, pas les validations actuelles.

---

# Version actuelle : ADCC 1.0 R1.9, Recherche + filtre OU

L'arbre des OU est intégré à gauche de la page Rechercher. Les résultats à droite sont interrogés dans la branche choisie. Consulter **RECHERCHE-OU-R1.9.md** pour le fonctionnement, l'installation et les limites de vérification. La suite de tests dédiée est **TESTER-RECHERCHE.cmd**.

Le texte ci-dessous décrit aussi les versions antérieures conservées dans ce pack. Le périmètre de recherche courant est désormais l'OU affichée, pas systématiquement tout le domaine.

---

# Version courante : ADCC 1.0 R1.7.2, erreur native de connexion

**Build : `2026.09.22-R1.7.2-NATIVE`. Lire `CORRECTIF-CONNEXION-R1.7.2.md`.**

R1.7.1 pouvait masquer une exception du getter `NativeObject` par son propre message `ADCC_AUTH_NATIVE_NULL`. Le getter est maintenant appelé comme méthode CLR explicite. L'authentification et la lecture réelle de la base restent obligatoires. Ce correctif ne permet pas de conclure que le compte ou son mot de passe est valide.

**Ne pas supprimer l'installation actuelle ni `wad/data`.** Extraire ce pack ailleurs et utiliser l'installateur pour conserver les données et les configurations. L'interface, les modules et les binaires sont conservés.

`TESTER-CONNEXION.cmd` contient **47 scénarios isolés, fournis mais non exécutés ici**. L'installateur les exige avant la copie. Les **84 contrôles statiques** courants passent ; ils ne remplacent ni Windows PowerShell, ni WPF, ni une connexion à votre domaine. Le ZIP et le manifeste sont contrôlés séparément à l'empaquetage.

Le détail du diagnostic natif est accessible depuis **Copier le diagnostic** sur le login. Ne pas multiplier les tentatives avec les identifiants réels. Les résultats des révisions ci-dessous sont historiques.

---

# Révision précédente : ADCC 1.0 R1.7.1, correctif de connexion

**Build : `2026.09.22-R1.7.1-LOGIN`. Lire `CORRECTIF-CONNEXION-R1.7.1.md`.**

Correction d'un parcours ADSI pouvant masquer l'erreur initiale par un accès à une collection nulle. Les diagnostics de connexion sont conservés et accessibles depuis le login standard. L'interface guidée R1.7 reste présente.

**Ne pas supprimer votre installation actuelle ni `wad/data`.** Extraire ce pack ailleurs puis utiliser l'installateur de mise à jour pour conserver la base et les configurations. `TESTER-CONNEXION.cmd` lance les 30 nouveaux scénarios PowerShell isolés, sans accès réel à un domaine.

Ici, 62 contrôles de source/XML/empreintes ont été exécutés, pas Windows PowerShell, WPF ni une connexion à votre AD. La capture seule ne permet pas de garantir que la cause sous-jacente du refus AD est résolue. Les résultats des anciennes révisions ci-dessous sont historiques.

---

# Révision précédente : ADCC 1.0 R1.7, interface guidée

**Lire `INTERFACE-GUIDEE-R1.7.md` pour cette révision.**

Navigation latérale, recherche permanente, cartes réorganisées, aide contextuelle à droite et catalogue de 403 descriptions. Les fonctions AD restent dans le moteur existant.

- **APERCU-INTERFACE.cmd** : inspecter le vrai XAML sous Windows, avec données fictives et sans connexion AD.
- **TESTER-INTERFACE.cmd** : exécuter les 25 scénarios WPF locaux.
- **INSTALLER-MISE-A-JOUR.ps1** : mise à jour avec sauvegarde du code, conservation des données et tests avant copie.

Les contrôles exécutés pour préparer ce paquet l'ont été sous Linux. Les scénarios Windows/WPF sont fournis, pas annoncés comme déjà passés. Le paquet neuf ne contient pas votre base : ne supprimez pas votre installation actuelle.

## Documentation historique des versions précédentes

Les sections suivantes décrivent les révisions antérieures. La disposition courante de l'interface et les résultats courants sont documentés dans `INTERFACE-GUIDEE-R1.7.md` et `wad/docs/AUDIT-UI-R1.7.json`.

# Mise à jour R1.5 : Atelier support intégré

**Build courant : `2026.09.21-R1.5-ATELIER`. Version publique : 1.0.**

Le nouvel onglet **Atelier** apporte une synthèse locale justifiée, deux captures A/B comparables, des incidents expliqués, 24 repères de session et un dossier texte/HTML prêt à partager manuellement. Pas d'IA distante, de scan automatique ni de réparation automatique ajoutés.

**Lire [ATELIER-SUPPORT-R1.5.md](ATELIER-SUPPORT-R1.5.md)** pour les nouveautés, les limites, l'installation et la recette Windows. Extraire le paquet à côté du dossier actuel et utiliser `INSTALLER-MISE-A-JOUR.ps1`. Ne pas supprimer ni remplacer `wad/data` : le paquet ne contient pas ta base personnelle. Ne pas copier seulement le cœur, il dépend des nouveaux modules.

`TESTER-ATELIER.cmd` fournit 52 tests fonctionnels isolés et un test WPF optionnel, sans connexion à l'AD. Ces tests natifs sont à exécuter sous Windows ; seuls les audits source/XML/Python/SQLite ont été exécutés pendant cette construction. Le moteur d'authentification et les opérations distantes R1.4 sont conservés.

La suite de ce fichier documente les versions historiques et les procédures générales.

---

# Mise à jour R1.4 : validation des comptes

**Build historique : `2026.09.21-R1.4-ACCOUNTS`.** Lire d'abord [`CORRECTIF-COMPTES-R1.4.md`](CORRECTIF-COMPTES-R1.4.md).

Le panneau Comptes réutilise le moteur du login ADSI, conserve l'identité réellement validée, protège le test du compte AD contre un changement de nom et conserve le bon nom de compte pour les workers Secrets. Le moteur du login lui-même et les corrections R1.1 à R1.3 restent inchangés.

**Extraire à côté de l'installation existante et utiliser `INSTALLER-MISE-A-JOUR.ps1`, sans supprimer `wad/data`.** Le cache et les réglages sont préservés. Les 25 nouveaux scénarios PowerShell isolés sont exécutés par l'installateur avant la copie, avec les suites distantes et détection déjà présentes. Ils sont également accessibles par `TESTER-COMPTES.cmd`.

Les contrôles réalisés ici sont source/XML/Python/SQLite, pas une exécution Windows, WPF ou AD. La validation réelle des comptes sur le domaine reste à effectuer sur le poste de l'utilisateur. Un compte validé dans AD n'a pas nécessairement les droits sur tous les postes.

La suite de ce document conserve les versions historiques et les procédures générales.

---

# Mise à jour R1.3 : détection du dernier utilisateur

**Build historique : `2026.09.21-R1.3-LASTUSER`.** Les corrections du thème et de l’accès distant restent présentes.

Lire [`CORRECTIF-DETECTION-R1.3.md`](CORRECTIF-DETECTION-R1.3.md). Cette révision corrige les sondes interrompues au rafraîchissement du même poste, le marqueur actif après annulation, les timeouts CIM et le suivi des étapes dans le journal persistant.

**Mettre à jour le dossier existant via `INSTALLER-MISE-A-JOUR.ps1`, sans supprimer `wad/data`.** L’installateur lance les tests PowerShell distants isolés et les 21 scénarios de cycle de détection avant de remplacer le code. `TESTER-DETECTION.cmd` permet d’exécuter séparément ces scénarios sans connexion au parc.

Les contrôles exécutés ici sont statiques et Python/SQLite. La validation native Windows/WPF et la recette sur AD ne sont pas présentées comme effectuées. Voir le rapport pour les limites et la procédure précise.

La suite de ce document conserve l’historique des versions et les procédures générales.

---

# Mise à jour R1.2 : détection utilisateur et accès distant

**Build historique : `2026.09.21-R1.2-REMOTE`.** Les correctifs du thème sombre R1.1 sont conservés.

Lire [`CORRECTIF-DISTANT-R1.2.md`](CORRECTIF-DISTANT-R1.2.md) avant l'installation. Il détaille la construction des arguments PsExec, le compte distant utilisé, le staging ADMIN$, les limites de validation et la recette ciblée.

**Installer dans le dossier existant via `INSTALLER-MISE-A-JOUR.ps1`, sans remplacer `wad/data` ni les réglages.** Le programme lance les tests distants isolés avant toute copie de code. `TESTER-DISTANT.cmd` permet de les exécuter séparément, sans contacter le parc. Ces tests natifs doivent encore être validés sur Windows ; ils n'ont pas été exécutés ici.

La documentation des versions antérieures est conservée ci-dessous pour l'historique et les procédures générales.

---

# Mise à jour R1.1 : thème sombre et restauration

Build historique : **2026.09.21-R1.1-THEME**. Lire d'abord
[`CORRECTIF-THEME-R1.1.md`](CORRECTIF-THEME-R1.1.md) pour l'installation sur ton
dossier existant et les tests. Les données et réglages existants sont conservés.
`TESTER-THEMES.cmd` fournit les tests natifs Windows de ce correctif.

La documentation ci-dessous décrit le socle R1, conservé dans ce paquet.

---

# AD⚡CC 1.0 — Reliability R1

**Build : `2026.09.21-R1-RELIABILITY` — 21 septembre 2026**

Version modifiée du projet fourni. Le nom ADCC, la version publique 1.0, les fonctions d’administration et le répertoire `wad` sont conservés. Le cœur PowerShell est modifié ; les exécutables et DLL fournis d’origine ne sont ni recompilés ni remplacés par d’autres versions.

## Démarrage

Extraire **tout** le dossier ADCC dans un répertoire local accessible en écriture. Ne pas lancer depuis l’aperçu du ZIP.

- `Lancer-ADCC.vbs` : lancement habituel sans console, via le lanceur PowerShell corrigé.
- `LANCER-ADCC.cmd` : lancement avec console visible ; à privilégier pour le premier essai et pour récupérer une erreur de démarrage.
- `TESTER-ADCC.cmd` : tests locaux PowerShell/SQLite et autotest WPF, sans écriture Active Directory. Le rapport est enregistré dans `wad\data\TestReports`.

Cible : **Windows 64 bits, Windows PowerShell 5.1 et environnement graphique WPF**. Le composant Windows `winsqlite3.dll` doit être disponible pour le cache. PowerShell 7 (`pwsh`) et Server Core sans interface graphique ne sont pas les environnements ciblés. Python n’est pas nécessaire au fonctionnement d’ADCC ni aux tests Windows.

Aucun lanceur ne modifie la politique d’exécution PowerShell. Une GPO, une exigence de signature ou une règle antivirus doit être traitée par le processus d’administration de ton organisation, pas par un contournement intégré. Le déblocage éventuel porte uniquement sur la marque de téléchargement des fichiers explicitement listés et vérifiés dans le manifeste ; ce n’est ni une signature ni une autorisation de sécurité.

## Mettre à jour ton ADCC existant sans remplacer tes données

**Le paquet neuf ne contient volontairement pas ta base AD, tes paramètres personnels, tes identifiants enregistrés ni tes journaux.** La base de l’archive source reste intacte. Pour retrouver ton parc, utiliser l’installation existante et la procédure ci-dessous, plutôt que lancer une copie neuve vide en supposant qu’elle contient ton historique.

Fermer ADCC, après la fin de toute écriture AD. Extraire le nouveau paquet dans un dossier distinct. Ouvrir Windows PowerShell 5.1 dans ce nouveau dossier, puis adapter uniquement le chemin de destination :

```powershell
# Prévisualiser : vérifications et plan, aucune copie.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf

# Installer après lecture du plan.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

L’installateur vérifie les empreintes SHA-256 du paquet et analyse les scripts avec le parseur natif PowerShell. Il sauvegarde les fichiers de code remplacés avant la première modification. **Il ne copie rien dans `wad\data`, ne supprime pas ta base et conserve les fichiers de configuration/préférences déjà présents.** Les fichiers inchangés ne sont pas recopiés. Les chemins sortant de l’installation et les jonctions détectées sont refusés.

Les sauvegardes de code sont dans `wad\maintenance\backups\<date-identifiant>`. Un échec déclenche une tentative de retour arrière ; si un fichier a changé indépendamment, la restauration refuse de l’écraser. Les messages et la sauvegarde permettent alors une intervention manuelle. Comme toute mise à jour de fichiers, cette opération suppose que l’application reste fermée : ne pas la rouvrir pendant la copie.

Retour arrière explicite, depuis le paquet extrait ou le script `RESTAURER-CODE.ps1` copié dans la sauvegarde :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Outils\ADCC\wad\maintenance\backups\<date-identifiant>' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Outils\ADCC\wad\maintenance\backups\<date-identifiant>'
```

**Cette restauration concerne le code, pas les données SQLite.** Il reste prudent de conserver une copie complète de ton installation, application fermée, avant tout déploiement.

## Changements principaux

| Domaine | Modification |
|---|---|
| Moteur asynchrone | Nettoyage des lectures détachées une fois réellement terminées ; attente des deux handles de fin avant libération ; plafond tenant compte des annulations ; rejet des retours d’une ancienne session. |
| Changement de compte | Refus pendant une opération active ou incertaine ; sauvegarde préalable d’un index modifié ; remise à zéro des vues, droits estimés et caches ; retour en lecture seule ; retrait des comptes secondaires si le périmètre AD change. |
| Secrets | Masque intégral, aucune propriété brute `Value` dans les lignes liées à la grille, résolution de la copie par index ; remasquage après 60 s ou perte d’activation ; retrait des références après 300 s par défaut ; effacement invalidant une lecture encore en cours. |
| Cache et réglages | Réglages remplacés atomiquement et repli sur un JSON `.bak` valide ; sauvegarde SQLite par son API native avec contrôle de la copie ; suppression des déplacements/restaurations automatiques d’une base illisible. |
| Multi-domaines | Un cache par Base DN ; adoption de l’ancien cache seulement si ses métadonnées identifient le même périmètre. Les anciens fichiers non identifiés ne sont pas déplacés ni supprimés. |
| Recherche locale | UPN complet conservé ; `%`, `_` et `!` échappés comme caractères de recherche littéraux ; priorité de correspondance exacte conservée. |
| Exports et logs | Filtrage des cellules CSV ressemblant à des formules ; masquage de plusieurs formes de secrets dans les logs ; journaux historiques bruts exclus du ZIP de diagnostic ; remplacement atomique d’un ZIP exporté. |
| Accès distant / WMI | Compte distant dédié indépendant du mode d’authentification AD ; délais de lecture des sorties de processus bornés ; recherche de PsExec dans le dossier portable ; blocage de `Win32_Product` et bornes WMI. L’ordre des mécanismes de repli existants est conservé. |
| Interface | Journal maintenu en bas ; boutons Copier et État moteur ; option Suivre pour suspendre le défilement ; purge des anciennes lignes par lots. Aucun scan réseau déclenché par État moteur. |

## Réglages ajoutés

Ces valeurs sont fusionnées avec la configuration existante par l’application. Il n’est pas nécessaire de remplacer tout ton fichier de configuration pour bénéficier des valeurs par défaut.

```json
{
  "Async": { "MaxOutstandingWorkers": 12 },
  "Security": { "SecretMemorySeconds": 300 },
  "Remote": { "UsePsExecFallback": true },
  "LocalStore": { "BackupTimeoutSeconds": 30 }
}
```

`MaxThreads` reste à 6 par défaut ; la limite physique de 12 inclut les lectures encore en cours d’annulation. Un appel natif bloqué n’est pas magiquement tué : il peut rester actif jusqu’à son retour ou la fin du processus, mais il ne doit plus restituer ses résultats dans une vue obsolète et compte dans la limite.

## Sauvegarder explicitement le cache

Identifier le chemin du cache actif avec le bouton **État moteur**. De préférence, fermer ADCC puis exécuter :

```powershell
.\wad\maintenance\Sauvegarder-Cache.ps1 -DatabasePath 'C:\Outils\ADCC\wad\data\ADCC.db' -WhatIf
.\wad\maintenance\Sauvegarder-Cache.ps1 -DatabasePath 'C:\Outils\ADCC\wad\data\ADCC.db'
```

Adapter le chemin pour un cache placé sous `wad\data\Domains\<identifiant>`. La copie est créée dans le sous-dossier `Backups` voisin de la base. Sept copies sont conservées par défaut ; la rétention ne supprime pas la base source. Le délai de 30 secondes borne la boucle de copie SQLite, **pas nécessairement la durée totale de l’outil**, qui comprend ouverture, contrôle et opérations disque.

En cas de cache illisible : fermer toutes les instances, conserver ensemble le `.db` et ses éventuels `-wal`, `-shm` et `-journal`, puis intervenir sur des copies. Ne pas remplacer seulement le `.db` en laissant des fichiers WAL d’une autre version. La vérification SQLite de la structure ne remplace pas la vérification du domaine, du contenu et de la fraîcheur d’une sauvegarde.

## Vérification avant production

Lire `wad\docs\VERIFICATIONS.md` pour la séparation exacte entre tests réalisés et tests à exécuter sous Windows. Passer `TESTER-ADCC.cmd`, puis vérifier l’affichage et l’authentification sur ton environnement. Commencer en lecture seule ; tester les actions d’écriture uniquement sur des objets dédiés dans une OU de test, avec contrôle du résultat depuis un autre outil AD.

Aucune session réelle sur ton AD, aucun essai LAPS/BitLocker réel et aucun test antivirus de ton organisation n’ont été exécutés lors de cette livraison. Le paquet est une révision à valider en préproduction, **pas une certification “zéro bug”**.
