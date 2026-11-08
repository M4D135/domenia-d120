# Assistant de mise à jour — lot 022b, 25 octobre 2026

Implémentation du §4 sur l’EXE portable existant, sans lanceur Admin ajouté. Le parent orchestre la compilation Windows ; cet agent n’a exécuté aucun build ni test. Le lot 022a (santé/reprise/rollback) a compilé dans la capture 109, ses huit tests n’ont pas été exécutés. Ce lot ajoute quatre tests du canal IPC et un test du code retour CLI après restauration, toujours non exécutés.

## Parcours concret

`PackageUpdateAssistant.Preview(preparedRoot, expectedManifestSha256)` requalifie la copie préparée et dérive la cible de l’installation hôte. `MainForm.BeginPackageUpdateAsync` est programmé après la réponse Bridge : refus en Simulation, plan relu, appel de la transition commune fournie par le lot Démonstration (admission fermée, écritures non interrompues, opérations drainées), puis préparation de l’assistant externe. Son résultat booléen signifie seulement « assistant autorisé, parent en fermeture ».

L’assistant est le `Domenia.exe` du paquet externe vérifié. Les arguments ne portent qu’un mode fermé, un nom de pipe aléatoire et un PID. Canal local `CurrentUserOnly`, trames bornées à 16 Kio, champs inconnus/répétés refusés, PID client et serveur vérifiés par Windows ; image et instant de création du parent requalifiés. L’assistant relit le plan avant de signaler sa disponibilité, attend la vraie fin du parent sans le tuer et ne remplace rien tant que le verrou d’un autre lanceur est tenu.

Le marqueur pending reste présent durant le contrôle. Un enfant de l’EXE installé reçoit une seule tentative qualifiée par IPC et relit l’ensemble du paquet. Il utilise un nouveau profil privé sous la transaction, ignore les surcharges WebView2 de son propre environnement et refuse un profil redirigé. Il n’instancie pas Composition : aucun annuaire, coffre ou base utilisateur n’est ouvert. WebView2 charge un document local de contrôle et exécute une expression JavaScript ; le reçu porte la transaction, le manifeste, le nonce, le build compilé, la version du navigateur et les deux étapes observées.

Avant de rendre le reçu au lifecycle, le parent attend la sortie de l’enfant et confirme que son Job Windows ne contient plus aucun processus, y compris WebView2. Le Job est assigné avant de transmettre le travail. Tout échec après création du processus devient une PackageHealthException avec le fait de terminaison physique ; une fin inconnue interdit le rollback. Seuls les enfants propres de cet assistant peuvent être terminés, jamais le processus utilisateur découvert ni un autre lanceur.

Le petit assistant natif montre l’avancement puis le bilan et conserve les preuves. Une mise à jour saine permet « Ouvrir Domenia » ; ce lancement explicite de la vraie session reste distinct du contrôle local du runtime. Une restauration binaire vérifiée est affichée comme un échec de mise à jour avec retour arrière, pas comme un succès. Aucun rollback de base n’existe.

## Reprise et limites

Le Programme fournit désormais le callback santé au CLI `livraison`. Depuis le paquet externe correspondant à la nouvelle identité (la copie `new` conservée peut servir), `livraison apercu-reprise <cible> <transaction>` puis `livraison reprendre <cible> <transaction> <Confirmation>` exigent une nouvelle tentative et son accusé. `apercu-restauration` / `restaurer` restent le retour binaire explicite. Le code retour 3 et `Action=rolledBack` distinguent un échec d’installation dont les anciens binaires ont été restaurés. Un pending, un fichier devenu étranger, une terminaison non prouvée ou un autre lanceur conserve les preuves et peut nécessiter une reprise ultérieure.

Le contrôle santé vérifie les octets, le chargement de l’EXE/runtime et WebView2/JavaScript. Il ne prétend pas valider une connexion AD ni l’ouverture/migration de la base réelle. La session réelle n’est pas lancée automatiquement sous les données de l’opérateur. Cette séparation rend le rollback automatique des binaires indépendant de toute migration de données. Les profils de contrôle et reçus restent des preuves privées à archiver explicitement avec la transaction.

Le raccord Program et la transition commune appartiennent au lot Démonstration ; PackageUpdateHost, son picker natif et l’écran Mises à jour appartiennent au parent. Ce lot ne modifie ni acquisition GitHub/UNC/ZIP ni publication PROD/DEV.

## Recette critique Windows après fin du développement

1. Neuf tests `PackageLifecycleTests.Health` : pending jusqu’à l’accusé, nonce ancien refusé, reprise non contournable, fin physique inconnue, rollback de remplacement, fichiers étrangers conservés, réglages/base inchangés, provenance et code retour non nul après rollback.
2. Quatre `PackageUpdateChannelTests` : trames exactes et bornées, doublons/champs inconnus/troncature, vraie connexion locale et PID des deux extrémités, noms fermés.
3. Deux recettes natives sur copies isolées de paquets : santé réelle WebView2 avec reçus et Job vide ; démarrage empêché et retour binaire/reprise, en vérifiant les SHA des préférences/bases témoins. Ajouter un second lanceur tenant le paquet pour constater le refus sans mutation.
4. Les tests existants de manifeste dernier, marqueur remplacé après aperçu et copie temporaire modifiée restent les garde-fous d’intégrité ciblés.

Aucune de ces recettes n’a été exécutée par cet agent. Aucun paquet n’est déclaré publié ou prêt sur cette seule compilation.
