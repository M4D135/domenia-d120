# ADCC 1.0 R1.3 : détection du dernier utilisateur

Build : `2026.09.21-R1.3-LASTUSER`  
Base : paquet R1.2, avec les correctifs R1.1 du thème conservés.

## Ce que le journal permet de conclure

Le dernier journal fourni indique qu’une tâche « Dernier user » a été annulée, puis détachée de l’interface après cinq secondes sans retour de `BeginStop`. Deux lectures de fiche machine apparaissent peu avant. Le journal ne précise pas l’origine de l’annulation : changement de sélection, remplacement, demande explicite ou délai dépassé. Il ne démontre ni une absence d’utilisateur, ni un nouveau refus d’accès PsExec ou ADMIN$.

La ligne « 0 lien(s) » concerne les associations chargées en cache. Elle ne prouve pas que la détection distante est impossible. Ce correctif ne prétend pas reconstituer des données absentes du paquet installé.

## Défauts trouvés dans le code et modifications

### 1. Rafraîchissement de la même machine

Dans R1.2, l’ouverture avec `Force`, utilisée par le double-clic, purgeait les vues et demandait l’arrêt des sondes de la sélection, même si le DN de la machine était inchangé. R1.3 relit toujours la fiche demandée, mais ne purge plus la sélection dans ce cas. Une nouvelle machine continue de purger l’ancienne fiche.

La détection en cours d’un même poste est réutilisée, même après une demande explicite de rafraîchissement. Une seconde demande ne redémarre pas sans cesse le worker. Le résultat déjà calculé mais encore en attente de son callback est lui aussi conservé.

### 2. État actif après une annulation

Le marqueur `ActiveLinkProbeId` pouvait rester renseigné après une annulation sans callback, puis bloquer les demandes suivantes. Le registre réel des tâches fait désormais autorité. Les tâches annulées, remplacées ou issues d’une ancienne session ne sont pas considérées comme une détection active.

Le marqueur est libéré avant `BeginStop`, puis vérifié au détachement. Ce nettoyage porte sur l’identifiant exact de la sonde et la machine : un ancien worker ne doit pas effacer le marqueur d’une nouvelle sonde. Les workers physiques non terminés restent comptabilisés par le moteur existant ; il n’y a pas de libération prématurée de leurs ressources.

### 3. Lecture distante et limites de temps

Des `OperationTimeoutSec` explicites sont ajoutés aux lectures CIM du compte courant et des profils. Si la première lecture ne donne pas de candidat validé, une lecture CIM de `StdRegProv.GetStringValue` peut interroger `LastLoggedOnSAMUser`, puis `LastLoggedOnUser`, sous HKLM LogonUI. Cette lecture réutilise la session CIM, respecte `Remote.UseRemoteRegistry`, contrôle le code de retour et valide le candidat dans AD avec le compte AD, distinct du compte distant.

Cette nouvelle étape lit le registre via CIM : elle ne démarre pas le service RemoteRegistry et ne change aucun droit. Les autres méthodes et les secours PsExec/tâche planifiée préexistants restent présents. Ces secours peuvent créer les mêmes fichiers, service ou tâche temporaires que dans R1.2 : ils ne deviennent pas des opérations sans écriture du fait de ce correctif.

Le budget global tient compte des délais minimaux des secours et du nettoyage. Par défaut, il est de 52 secondes. Les délais CIM sont des demandes de timeout au fournisseur, pas une garantie d’arrêt physique immédiat de tous les appels réseau natifs.

**Interprétation des résultats :** le compte courant, la dernière valeur LogonUI et le profil récent sont des indices différents. LogonUI peut être historique. La validation d’existence dans AD ne prouve pas qu’une session est encore ouverte. La source du résultat est conservée et affichée.

### 4. Journal exploitable avant la fin

Une file de progression thread-safe relie le worker au moteur de l’interface. Les étapes sont émises avant les appels potentiellement bloquants et transférées au journal persistant pendant l’exécution, avec une limite de drainage par passage. La dernière étape atteinte devient visible même si aucun résultat final n’arrive.

Le journal enregistre le démarrage, le build, l’identifiant de sonde, le budget, les méthodes essayées, le résultat et le motif d’arrêt transmis par le moteur. Les mots de passe ne sont pas ajoutés à cette file. Un journal restant susceptible de contenir des comptes ou noms de machines, il doit être partagé par le canal interne approprié.

En l’absence de cache, le champ utilisateur affiche « Detection en cours... » ou « Non determine » plutôt qu’une case vide. Un échec ou une annulation conserve l’association existante. Les résultats tardifs d’une autre machine ou d’une ancienne sonde restent rejetés.

## Installation sur le dossier existant

Fermer ADCC après la fin des opérations d’administration. Conserver une sauvegarde de l’installation. Extraire tout le nouveau paquet dans un dossier différent, puis ouvrir Windows PowerShell 5.1 dans ce nouveau dossier. Adapter la destination réelle :

```powershell
# Vérifier le plan sans remplacer de code.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf

# Installer dans le dossier qui contient déjà les données.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Le paquet ne contient pas la base personnelle ni les journaux. L’installateur conserve `wad\data` et les configurations déjà présentes, vérifie les empreintes et la syntaxe PowerShell, exécute les deux suites de tests isolés, puis sauvegarde et remplace le code. Un échec de test arrête la mise à jour avant cette copie. Ne pas supprimer l’ancien dossier pour y substituer un dossier neuf vide.

Le retour arrière du code est documenté dans `LIRE-MOI.md`. Les sauvegardes de code ne sont pas des sauvegardes SQLite.

## Recette Windows ciblée

1. Lancer `TESTER-DETECTION.cmd`, qui teste les fonctions réelles avec des doublures de l’interface et du moteur. Lancer aussi `TESTER-DISTANT.cmd` pour les lectures et transports simulés. Aucun de ces deux tests ne contacte le parc ni ne lance l’application.
2. Lancer ADCC depuis le dossier mis à jour. Ouvrir une machine accessible avec le compte choisi. Le journal de démarrage de la sonde doit contenir `R1.3-LASTUSER`.
3. Pendant la détection, redemander la même fiche : la sonde doit rester la même. Vérifier ensuite l’utilisateur, sa source et la conservation du lien local.
4. Sur une autre tentative, annuler puis relancer lorsque le moteur autorise une nouvelle lecture. Le marqueur ne doit pas rester bloqué. Passer à une autre machine et vérifier qu’aucun résultat tardif n’écrase sa fiche.
5. En cas d’échec distant, lire les nouvelles lignes `Association` du journal. Le motif d’arrêt et la dernière méthode doivent permettre de distinguer problème de cycle de tâche, droits et transport. Ne pas interpréter « Non determine » comme une preuve qu’aucun utilisateur n’est connecté.

## Vérifications effectuées et limites

Les rapports `wad/docs/AUDIT-*-R1.3.json` distinguent leurs contrôles statiques et les essais Python/SQLite locaux. Les contrôles du correctif, du thème et de l’accès distant sont des assertions sur le code ; ils ne sont pas des exécutions des fonctions PowerShell.

Bilan des vérifications exécutées sur cette révision :

| Suite | Contrôles réussis | Échecs | Nature |
|---|---:|---:|---|
| Détection R1.3 | 26 | 0 | Assertions statiques sur le source |
| Accès distant | 29 | 0 | Assertions statiques sur le source |
| Thème | 14 | 0 | Source, XML et contrastes calculés |
| Audit général | 44 | 0 | Structure, empreintes, paquet et essais SQL/SQLite Python |

Ces nombres ne sont pas des tests d’accès réel au parc ; certains contrôles statiques se recoupent.

Une nouvelle suite native contient **21 cas** du cycle de détection : double demande, rafraîchissement forcé, drapeau orphelin, annulation et relance, changement de machine, ancienne session, résultats tardifs, progression et cache. La suite distante contient aussi les scénarios CIM LogonUI et progression. Elle extrait le vrai worker et utilise des réponses simulées.

**Windows PowerShell, WPF et un AD réel n’ont pas été exécutés dans l’environnement Linux utilisé pour préparer ce paquet. Les suites natives sont fournies, pas présentées comme déjà réussies.** Les tests isolés ne remplacent pas la recette sur un poste de préproduction ni les droits d’accès nécessaires. Le correctif traite des défauts observés dans le source, mais le journal initial seul ne permet pas de certifier la cause exacte de l’incident ni sa disparition sur le parc.

Les DLL et EXE sont identiques à R1.2. Aucune fonction principale d’origine n’est supprimée. Les empreintes des 46 workers sont contrôlées ; seul `ComputerLastUser` est modifié dans R1.3. Le patch textuel et la liste précise des fonctions modifiées sont dans `wad/docs`.

## Références techniques Microsoft

Références externes utilisées pour la lecture CIM, distinctes des observations tirées du journal et du code :

- StdRegProv et ses méthodes : https://learn.microsoft.com/en-us/previous-versions/windows/desktop/regprov/stdregprov
- Invoke-CimMethod, session, namespace et timeout : https://learn.microsoft.com/en-us/powershell/module/cimcmdlets/invoke-cimmethod?view=powershell-5.1
