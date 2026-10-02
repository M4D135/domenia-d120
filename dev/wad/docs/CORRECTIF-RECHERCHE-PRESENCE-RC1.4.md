# Domenia 1.0 RC1.4 : recherche globale indépendante et présence à la sélection

Build : `2026.10.01-DOMENIA-1.0-RC1.4-SEARCH`.
Base : archives Domenia RC1.3 DEV et PROD de cette conversation. Cette livraison modifie le code, pas seulement la configuration. Les bases personnelles ne sont pas incluses.

## Deux parcours distincts dans le même écran

### Barre du haut : tout le domaine

La recherche du bandeau, son bouton et Entrée utilisent toujours la racine du domaine connecté et la portée Subtree. Ils ne reprennent pas la restriction de l’OU sélectionnée, ni le filtre de type d’objet, ni la présence, ni le texte « Filtrer les lignes chargées ».

Le bandeau de résultats indique **Recherche globale · Domaine entier · Tous les types · Aucun filtre de liste**. Les filtres locaux sont temporairement grisés pour ne pas afficher des réglages qui paraissent actifs alors qu’ils ne le sont pas. Leurs valeurs sont conservées pour la navigation dans les OU. Le tri des colonnes reste disponible.

La première passe de recherche inclut désormais les noms affichés, prénoms, noms de famille et adresses de messagerie, en plus des identifiants et de l’ANR. Un poste correspondant au début du texte ne doit plus empêcher la recherche d’une personne sur ces attributs en la réservant à une passe de secours.

**La limite de résultats reste applicable : 100 par défaut, au maximum 500 dans ce parcours.** « Globale » signifie tout le domaine connecté et les types pris en charge, pas une forêt entière, un export exhaustif, ni un contournement des droits de lecture. Les caractères LDAP spéciaux restent échappés ; un joker saisi volontairement reste possible.

### Arbre OU : navigation filtrée

Cliquer une OU ou **Afficher cette OU** utilise sa branche, sa profondeur et les filtres de la liste. Le texte resté dans le bandeau ne restreint plus cette navigation. La sélection de l’arbre n’est pas effacée par une recherche globale. Il est ainsi possible de chercher une personne dans le domaine puis de revenir à son OU de travail en un clic.

**Actualiser** conserve le mode actif. Le bouton historique **Tout le domaine** retire la restriction de branche du navigateur OU ; ce n’est plus un préalable nécessaire pour utiliser la barre du haut. Les recherches enregistrées retiennent leur mode. Les anciens favoris sont interprétés comme des recherches OU.

Au démarrage, la restauration d’une OU charge ses résultats une fois, dans le mode OU, sans filtrer par un ancien texte du bandeau. Les gardes de génération et de contexte restent actives. Une action manuelle prend la priorité ; une OU introuvable ne provoque pas de recherche de remplacement arbitraire sur le domaine.

## Présence et utilisateur : uniquement sur la machine choisie

La réception des résultats ne lance ni balayage ICMP ni sondage des utilisateurs. Un clic sur une seule machine crée une demande liée à son GUID, à la recherche et au contexte du compte. Le ciblage doit être confirmé par la lecture AD fraîche avant l’envoi. Les sélections programmatiques et les multisélections ne créent pas de contrôle collectif.

Dans le worker, un seul appel ICMP est effectué avec une attente demandée de 900 ms. Le résultat est publié immédiatement dans une file de retours à l’interface, **avant la lecture CIM du compte console**. Ce délai demandé n’est pas une garantie sur la résolution DNS ou sur un appel natif bloqué. Les vérifications sont bornées en concurrence ; les appels en nettoyage restent comptés.

La case **Utilisateur à la sélection** ne commande que la lecture utilisateur. Décochée, sélectionner le poste effectue le ping sans accéder aux credentials ni à CIM. Si le compte distant est déjà marqué refusé, le ping peut encore être exécuté par une opération indépendante sans credential. **Revérifier ce poste** redemande volontairement un contrôle de cette seule machine. Les commandes détaillées de diagnostic existantes restent des actions explicites distinctes.

Le double-clic ou Entrée ouvre la fiche et partage le contrôle sélectionné, au lieu d’ajouter un second ping du même parcours. Les clics rapprochés remplacent la demande non envoyée ; les appels déjà envoyés peuvent finir sur leurs cibles propres. Aucune nouvelle sonde n’est démarrée par le tri, les filtres, le rafraîchissement ou la simple arrivée de nouvelles lignes.

### États affichés

| État | Signification |
|---|---|
| Non vérifié | Pas d’observation réseau disponible. Sélectionner le poste pour le contrôler. |
| Vérification en cours | La demande liée à la sélection attend ou exécute le contrôle. |
| En ligne | Une réponse ICMP a été reçue, ou la lecture CIM demandée a répondu. Le détail précise la source. |
| Sans réponse au ping | Pas de réponse ICMP. Ne prouve pas que le poste est éteint : le trafic peut être filtré. |
| Erreur de ping | Le contrôle lui-même n’a pas abouti, par exemple erreur DNS/réseau. |
| État suivi de « (cache) » | Observation historique, avec sa date au survol. Pas un statut fraîchement confirmé. |

Un refus WMI/CIM ne remplace plus un ping positif par « Inconnu ». Inversement, un ping sans réponse ne bloque pas une lecture CIM volontaire : une réponse de CIM peut confirmer la joignabilité malgré le filtrage ICMP. Une lecture utilisateur refusée, vide et une présence réseau négative restent des notions distinctes.

## Mémoire et exactitude des dates

Les observations continuent à être enregistrées par la file SQLite existante. Le record JSON distingue la date de présence, la date de tentative utilisateur et celle du dernier compte réellement observé. **Un ping seul ne rajeunit pas l’ancien utilisateur connecté ni l’association AD.** Un retour réseau plus ancien ne remplace pas un résultat plus récent ; les dates sont comparées comme des dates, pas lexicalement.

Les nouvelles clés de projections séparent Global et OU. Les anciennes projections de recherche ne sont pas mélangées avec le nouveau mode : le premier chargement peut donc attendre LDAP avant de reconstruire ce cache. Les observations utilisateur et les associations restent dans leurs tables existantes. Le schéma SQL n’est pas changé par ce correctif.

La colonne **Présence réseau** garde la clé de présentation `Presence` ; son ordre et sa largeur sauvegardés restent compatibles. Le survol présente la source et la date. Le compte console ne devient pas un inventaire des sessions RDP ; la vue Sessions reste distincte.

## Installation

Fermer Domenia après la fin des opérations d’écriture. Extraire DEV dans un dossier distinct, ouvrir Windows PowerShell depuis ce dossier `dev` et exécuter :

```powershell
# Adapter au dossier contenant actuellement Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

Ne pas supprimer l’installation ni le cache. L’installateur conserve les configurations et `wad\data`, ne remplace pas les données de `%LOCALAPPDATA%\Domenia\Data`, sauvegarde le code remplacé et effectue ses tests avant la copie. Un échec de test doit être examiné, pas contourné. Les modules, le cœur, le catalogue et le manifeste doivent être installés ensemble.

PROD conserve uniquement `Domenia.exe` et `wad` à la racine. `DEBLOQUER_TOUT.cmd` reste dans `wad\Support`. Les fichiers de test/démonstration ne sont pas requis au lancement PROD. Le lanceur et les DLL sont inchangés par rapport à RC1.3. Le moteur et son journal portent la version RC1.4 ; la ressource de version du lanceur conservé peut encore annoncer RC1.

## Vérifications réalisées et limites

**Exécuté ici :** 207 contrôles portables généraux (source, XML, SQLite via Python, contrats et inspection), puis 176 contrôles ciblés de structure, raccordements et comparaison avec RC1.3, sans échec. Les vérifications lexicales ne sont pas le parseur Windows PowerShell. Les deux ZIP sont contrôlés séparément après génération, avec leurs manifestes et la correspondance des 41 fichiers de fonctionnement.

Le cœur conserve ses 573 fonctions d’origine : 551 inchangées, 22 modifiées, et 3 helpers ajoutés. Les modules touchés concernent les observations, leur affichage, la restauration du périmètre, les favoris et l’exclusion des credentials pour ICMP. Le chargeur contrôle ses 20 modules et leurs 216 fonctions. Le registre fermé contient 55 opérations : LiveConsole et LiveCache changent, LiveSelectedPing est ajouté ; les autres corps sont conservés. Les moteurs d’authentification ne sont pas réécrits.

**Fourni, non exécuté ici :** `TESTER-RECHERCHE-PRESENCE.cmd`, 59 scénarios Windows, avec extraction des fonctions par AST, doubles explicites de Ping/CIM/LDAP, tests de dates/caches et deux contrôles WPF. L’installateur le lance avec les suites Modules, Candidate, ACL et Selection, avant toute copie. Un rapport incomplet ou un test ignoré arrête l’installation. Les anciennes preuves restent historiques.

**Non exécuté ici :** Windows PowerShell 5.1, rendu WPF, EXE Windows, accès à l’AD, ICMP ou CIM sur le parc. Aucun débit, délai de première réponse ou résultat réseau réel n’est inventé. Les aperçus DEV utilisent des données fictives et ne prouvent pas le fonctionnement sur le domaine.

## Recette Windows

1. Choisir une OU de postes et le type Machines, saisir un nom d’utilisateur du domaine dans la barre du haut, puis Entrée : le périmètre doit être le domaine et les filtres grisés. L’utilisateur doit être retrouvé selon les droits et la limite.
2. Cliquer **Afficher cette OU** : revenir à la branche sans modifier le texte global ; réactiver les filtres du navigateur. Fermer/rouvrir puis vérifier la restauration de l’OU.
3. Charger une liste puis attendre : aucun ping ou contrôle utilisateur de masse. Cliquer une machine : observer d’abord Présence réseau, puis le compte console si autorisé. Double-cliquer : ouvrir la fiche.
4. Tester un poste joignable avec lecture CIM refusée : présence positive et refus utilisateur distincts. Tester un poste sans réponse ICMP, puis un nom non résolu : états distincts, sans verdict abusif d’arrêt.
5. Désactiver Utilisateur à la sélection, cliquer une autre machine, puis revenir au poste connu : seule la date de présence change, pas l’ancienne observation utilisateur.
6. Changer vite de sélection et d’OU : les retours ne doivent pas remplir une autre cible, ni déclencher une file de contrôles sur l’ancien périmètre.

Référence technique : Microsoft Learn, `System.Net.NetworkInformation.Ping`, remarques sur les pare-feu et la portée d’un ping positif : https://learn.microsoft.com/en-us/dotnet/api/system.net.networkinformation.ping?view=netframework-4.8.1
