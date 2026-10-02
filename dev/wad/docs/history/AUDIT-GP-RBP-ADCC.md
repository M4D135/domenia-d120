# Audit croisé GP / RBP / ADCC

## Périmètre et niveau de preuve

Cet audit rapproche les décisions retrouvées dans les discussions GP et RBP avec les guides de livraison accessibles dans la bibliothèque, puis les confronte au code ADCC R1.10 fourni dans cette conversation.

Documents lus : **GP_17_RC14_GUIDE.md**, **GP_17_RC14_VALIDATION.md**, **RBP_2.3.0_Nouveautes.md**, **RBP_2.3.0_Recette_Windows.md**, **ADCC_Interface_Compacte_R1.10.md**. GP 17.0-RC14 et RBP 2.3.0 sont les versions retrouvées pour ce travail, pas une assertion qu'aucune version ultérieure n'existe ailleurs.

Il s'agit d'un audit comparatif des parcours et décisions, avec modification du code d'ADCC. Ce n'est pas une revue exhaustive du code source de GP/RBP, une lecture certifiée de chaque message de ces discussions, ni une validation de leur comportement Windows. Les guides distinguent eux-mêmes les contrôles de préparation et les essais Windows restant à effectuer.

## Le point commun à rechercher

L'opérateur doit reconnaître les mêmes repères entre les outils : une connexion courte, un compte utilisé explicite, une action principale compréhensible, un suivi qui dit ce qui se passe, un journal lisible, des erreurs utiles et des préférences d'apparence durables.

Uniformiser ces repères ne signifie pas fusionner les moteurs. ADCC consulte et administre plusieurs ressources sous différentes identités ; GP traite l'appartenance au domaine et le nom des postes ; RBP intervient sur les profils et leur sauvegarde. Leurs autorisations, preuves de réussite et reprises ne sont pas interchangeables.

## Comparaison et décisions de R1.11

| Sujet | Enseignement de GP ou RBP | Décision concrète dans ADCC |
|---|---|---|
| Connexion | RBP : deux champs, compte Windows alternatif, Verr. Maj et thème au login. GP : éviter une authentification redondante. | Conserver le login compact R1.10 ; ajouter thème et Verr. Maj ; ne pas recréer la fenêtre ni introduire un second login. |
| Identité | GP montre le compte et la cible avant la jonction. ADCC possède trois contextes de compte. | Rappel dépliable AD / Postes / Secrets dans l'aide, avec mention que cela ne prouve pas les droits. |
| Opérations | GP distingue précontrôle, demande envoyée, redémarrage attendu et vérification ; une interruption n'est pas une annulation garantie. | Vue des opérations réellement actives, durée, type, arrêt demandé et nettoyage. Une écriture incertaine reste à vérifier. |
| Journal | RBP sépare l'action longue de sa lecture et conserve les préférences de texte. | Recherche dans le journal, taille de texte, retour à la ligne, suivi suspendable, repli sans effacement. |
| Apparence | RBP ne réécrit pas le choix du thème à chaque rendu et signale une sauvegarde impossible. | Palette commune login/chargement/principale ; enregistrement au clic ; message explicite lors d'un échec. |
| Lecture compacte | RBP conserve dimensions et préférences sans restaurer une action dangereuse. | Confort/Compact pour la grille de résultats ; préférences bornées ; aucun nouveau stockage de cible, confirmation ou mode écriture. |
| Parcours direct | GP évite une file lorsque la tâche locale est simple. | Ouvrir directement les opérations ou affiner localement les résultats, sans créer une nouvelle file ni un assistant obligatoire. |
| Livraison | GP/RBP gardent EXE, script et wad ensemble ; un contrôle du lanceur ne prouve pas le métier. | Pack complet conservé ; vérificateur de cohérence et de syntaxe local ; aucune réussite AD déduite d'un code de sortie du lanceur. |

Sources : GP, sections « Choisir le parcours », « Jonction directe », « Protections et reprise » ; RBP, sections « Thème lié à l'utilisateur », « Améliorations de confort », « Stockage des préférences » et « Un véritable RBP.exe ».

## Défauts constatés dans ADCC R1.10

**Priorité du profil d'interface.** `Load-AdccSettings` chargeait le JSON puis pouvait remplacer son profil valide par le fichier historique. R1.11 ne consulte ce dernier comme source de profil que si le JSON ne fournit pas un profil reconnu. Le défaut est établi dans le source ; il ne constitue pas un diagnostic rétrospectif de tous les réglages observés par l'utilisateur.

**Export plus large que la grille.** `Export-CurrentResults` utilisait `BranchObjects` en l'absence de sélection. Des lignes masquées par la présence pouvaient ainsi revenir dans le CSV. L'export s'appuie maintenant sur les éléments visibles et intersecte une éventuelle sélection avec cette liste.

**Enregistrement silencieusement infructueux.** Le résultat faux de `Write-AdccPreference` était ignoré par `Save-AdccSettings`. La sauvegarde du thème peut maintenant signaler cet échec au lieu de présenter le choix comme mémorisé. Le traitement des écritures AD n'est pas impliqué dans cette correction.

**Repère d'étape trompeur.** Le premier numéro du panneau d'aide restait mis en avant sans rapport avec l'espace consulté. Le style suit maintenant le marqueur de navigation actif. Ces étapes restent des raccourcis, pas une progression métier certifiée.

## Ce qui n'a volontairement pas été transplanté

La connexion intégrée GP dépend de son contexte local/UAC. ADCC conserve sa validation actuelle, son choix explicite de compte Windows et ses identités distinctes pour les postes et les secrets. Aucun compte ne gagne de droits par harmonisation de l'interface.

La règle GP « renommer puis déplacer uniquement si le site change », `dsregcmd /leave`, la jonction et les reçus de reprise restent dans GP. Les déplacer dans une évolution graphique d'ADCC aurait ajouté des opérations sensibles sans demande correspondante.

Le relais SID/UAC, les opérations USMT, la réparation des profils et les validations de sauvegarde restent dans RBP. Les préférences ADCC ne sont pas réécrites dans les ruches RBP. Aucun fichier de configuration GP ou RBP n'est livré dans le pack ADCC.

La vue des opérations d'ADCC n'ajoute pas de bouton pour rejouer toutes les erreurs. Un dépassement de délai sur une mutation peut laisser un résultat inconnu ; harmoniser les mots ne remplace pas la relecture de l'état réel.

## Socle partageable, sans fausse mutualisation

`wad/modules/SupportSuite.UI.json` définit les deux palettes, un vocabulaire et des règles d'usage. ADCC R1.11 est le seul produit déclaré dans **ImplementedIn**. Les palettes sont effectivement utilisées par sa connexion, son chargement et sa fenêtre principale. Les métriques constituent des recommandations d'adoption, pas des modifications automatiques de tous les écrans.

Pour une adoption ultérieure dans GP/RBP, garder les palettes et composants de présentation indépendants de l'authentification. Chaque outil doit conserver son propre stockage de préférences, ses droits et ses validations métier. Une migration doit inclure les aperçus propres à chaque logiciel, un contrôle de thème avant/après changement d'identité et une recette de retour arrière. Aucun partage automatique de mots de passe, de cibles ou de confirmations.

## Contrôles de cette livraison

Les 98 vérifications exécutées sont des contrôles Python de source, XML, contrastes et empreintes. Les fonctions critiques de connexion, de recherche, d'écriture et le code commun des workers restent identiques à R1.10. Les 45 corps d'opérations vérifiés par empreinte sont conservés. Les 48 nouveaux scénarios PowerShell et les 13 scénarios WPF ajoutés sont fournis pour Windows, non annoncés comme exécutés ici.

Les aperçus GP/RBP décrits dans leurs guides ne sont pas des validations réalisées à nouveau pendant cet audit. Aucune capture Windows ni authentification sur le domaine n'a été produite ici.
