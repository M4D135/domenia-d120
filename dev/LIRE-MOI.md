# Domenia 1.0 RC1.13.0 — livraison du 8 octobre 2026

Build : `2026.10.08-DOMENIA-1.0-RC1.13.0-D120`.
Guides : `DOC/Domenia-1.0-Guide-technicien` et `DOC/Domenia-1.0-Guide-administrateur` (.docx et .pdf) dans la livraison.
Cible : Windows PowerShell 5.1 x64, interface WPF. Lancer `Domenia.exe`.

## Les deux packs

- **PROD** : `Domenia.exe` et `wad`, uniquement les composants nécessaires à l'application.
- **DEV** : le même runtime à l'octet, l'installateur, les sources, les outils, les tests et le suivi D001-D120.

Extraire le ZIP entièrement dans un dossier local. Si Windows bloque les fichiers, utiliser
`wad/Support/DEBLOQUER_TOUT.cmd`. Ne pas déplacer le cœur sans les modules et leur manifeste.

## Détection utilisateur / poste

La détection est déclenchée manuellement :

- dans **Rechercher**, **Pinger la liste**, **Détecter la liste** et **Analyser la liste** traitent seulement les postes des résultats chargés après filtrage ; le périmètre est figé au clic ;
- **Analyser la liste** ajoute le relevé WMI léger et les requêtes WMI des widgets des tableaux de bord ;
- la vue d'ensemble du parc de l'**Accueil** suit l'OU choisie dans Rechercher et ne lance aucune analyse ; jamais le domaine entier.

Une confirmation indique le périmètre. Aucun scan ne part au démarrage. Les postes hors ligne sont ignorés.
Le relevé concerne l'utilisateur de la console, pas les sessions RDP. Chaque demande vérifie légèrement la console
pour constater un changement ; l'identité LDAP en cache est réutilisée lorsqu'elle reste valide.
Le cache persiste entre les lancements. Les associations automatiques sont actualisées avec leur historique ;
les associations manuelles et importées restent protégées. Une absence de réponse n'efface pas le dernier utilisateur connu.

## Mise à jour et restauration

Fermer Domenia après la fin des opérations. Conserver une sauvegarde de ses données. Extraire **DEV** dans
un dossier distinct, puis lancer dans Windows PowerShell 5.1 :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Domenia'
```

L'installateur vérifie et prépare la livraison complète, sauvegarde le code précédent, verrouille le lancement,
remplace les fichiers puis contrôle l'ensemble avant activation. Les données et les préférences existantes sont conservées.
Une copie de Domenia ouverte dans un autre dossier n'empêche pas cette mise à jour.
Les versions déjà actives ne sont pas réinstallées. Le build daté distingue cette livraison des candidats précédents.

En cas d'interruption, le lancement reste bloqué jusqu'à restauration. Utiliser le chemin de sauvegarde indiqué
par l'installateur ou dans `wad/Support/.update.pending` :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'C:\Domenia\wad\maintenance\backups\DOSSIER'
```

La restauration contrôle les empreintes et refuse d'écraser un fichier modifié indépendamment. Elle ne touche pas aux données.

## État de validation

La campagne d'intégration Windows PowerShell 5.1 du commit `64e6b69` totalise **2 365 tests réussis, zéro échec**,
avec un arbre propre lié à 423 fichiers et aucune régression par rapport à la campagne précédente.
Elle couvre la détection manuelle, le cache, l'historique et les identités de sélection communes.
L'installateur est vérifié séparément sur six scénarios ciblés réussis : installation, restauration, interruption, verrouillage,
corruption et modifications concurrentes. Les empreintes du code testé sont contrôlées. Les premiers échecs et leurs corrections
restent consignés dans le suivi ; aucune nouvelle campagne complète n'a été relancée.

Les contrôles de construction vérifient les manifestes, les empreintes, le contenu des ZIP et l'identité du runtime DEV/PROD.
Aucun accès AD réel n'a été testé. Les archives restent des **candidates** : la qualification formelle liée aux SHA-256
des deux ZIP n'est pas acquise. Le suivi D001-D120 conserve explicitement ses points restants ; cette livraison ne prétend
pas les clôturer tous. Le lanceur natif est conservé à l'octet et reste non signé.

## Notes de version : relations utilisateur / poste (lot L04, RC1.14)

- Page Relations en deux zones (associations du sujet, panneau « Ajouter une association » avec Détecter | Rechercher),
  un seul statut, précautions derrière « ? » ; qualification en puces (Déclaré, Observé, Contradictoire) ; filtre, puces
  et compteur dans « Toutes les associations », double-clic et clic droit vers la fiche.
- Dates des associations enregistrées en UTC et affichées en heure locale, y compris sur la fiche du poste ; une ancienne
  date sans fuseau est lue comme une heure locale.
- Import CSV avec aperçu dans la page : comptes et postes vérifiés dans l'index local (sans réseau), source forcée
  « Import CSV », 64 associations au plus par import, « Annuler l'import » confirmé dans la page.
- « Restaurer » nomme l'association remise et n'est actif que s'il y a quelque chose à restaurer ; associations orphelines
  listées avec leur motif, retirées après confirmation (64 au plus par retrait), journalisées et restaurables.
- Ancien chemin RC1.10.7 retiré : clés Features.RelationsSymmetry, Features.DetectionPreview et
  UserMachineLink.LinkStaleHours supprimées de la configuration par défaut.
- Opérations worker épinglées modifiées : **LegacyMigration** (reprise des anciennes données : une date d'association
  sans fuseau est lue comme une heure locale pour choisir l'association la plus récente) et **LocalIndexRead** (nouvelle
  lecture `ResolveNames` de l'aperçu d'import, en lecture seule).
