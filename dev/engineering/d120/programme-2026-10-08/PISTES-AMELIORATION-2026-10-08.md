# Domenia — pistes d'amélioration (8 octobre 2026)

Base : Domenia 1.0 RC1.13.0 (commit 6246304). Liste de travail : rien n'est encore appliqué.

## D'où viennent ces propositions

- **Revue du code par domaine** : 7 agents (interface, accueil et widgets, Rechercher, fiche et poste, outils et comptes, moteur, qualité), 296 propositions brutes, 250 après fusion des doublons. Chaque proposition cite le code ou une capture.
- **Bugs, sécurité et fiabilité vérifiés une seconde fois** : 73 affirmations relues par des agents chargés de les réfuter : 44 confirmées, 26 partielles, 3 écartées (voir la fin).
- **Spark** (QAD local, 87 idées à partir des guides et de l'interface) : chaque idée vérifiée contre le code. 44 valides ; 23 nouvelles ajoutées en fin de liste (SP-), les autres rejoignent une proposition existante (mention « aussi proposé par le Spark »).
- Grok n'a pas pu répondre (crédit épuisé) ; opencode non utilisé.

Lecture : **impact** fort / moyen / faible ; **effort** S (moins d'une demi-journée), M (un à deux jours), L (plus).

## Gains rapides recommandés

- CO-01 — Fiche utilisateur : l'état du compte est caché sous « Dernière connexion » (deux champs dans la même cellule)
- CO-02 — « Annuler » arrête une sauvegarde de fond au lieu de la recherche
- CO-03 — Trier les dates et les tailles sur leur vraie valeur, pas sur le texte
- CO-04 — Exports CSV en « ; », avec les colonnes visibles et des en-têtes français
- CO-06 — Un raccourci ou un menu ne fait plus passer tout le profil en Expert
- SE-02 — Le worker d'écriture appelle la garde des attributs bruts
- SE-04 — « Mettre à jour tout » ne lit plus le journal du contrôleur sans le dire
- SE-05 — Plafond sur Pinger, Détecter et Analyser (pas de relevé déguisé sur tout le domaine)
- FI-02 — Plus de boucle de fenêtres d'erreur quand un minuteur est en panne
- UX-01 — Journal replié : afficher la dernière ligne, avec une pastille rouge en cas d'erreur
- UX-04 — Journal visible débarrassé des lignes internes du moteur
- UI-01 — Afficher l'objet en cours près du titre et dans la barre des tâches
- DS-03 — Filtres de Rechercher porteurs de leur sens (« Tous les types », « 100 lignes max »)
- PF-01 — Tick Live : ne plus recalculer l'identité 12 fois par seconde

## Grands chantiers recommandés

- 1. Passe de langue complète : UI-04 (accents, apostrophe ʼ, vouvoiement), UI-21 (glossaire sans jargon), avec deux prérequis, FI-16 (états hors des libellés) et TE-01 (contrôle automatique), et la migration des noms de section enregistrés.
- 2. Zéro fenêtre bloquante pour les flux métier : UX-06 (bandeaux d'info et d'erreur), UX-07 et UX-08 (confirmations d'impact et d'écriture en clair, dans la page), UX-32 (Opérations et santé du moteur en panneau), UI-26 (fin de la fenêtre Rimotte).
- 3. Rechercher refondu : DS-06 (une carte, fil d'Ariane), DS-07 (arbre à pleine hauteur), UI-23 (un bouton « Vérifier la liste ▾ »), FO-01, FO-04 et FO-05 (recherche « contient », favoris d'OU, texte dans une OU), DS-20 (choix des colonnes).
- 4. Tableaux de widgets fluides et allégés : DS-04 (grille en colonnes calculées), DS-05 (carte Santé unique), UX-11 (disposition par défaut d'environ 14 widgets), UX-10 et UX-34 (widgets cliquables utiles), UI-24 (mode Personnaliser léger).
- 5. Assistance poste simplifiée : UX-21 (5 vues au lieu de 8 onglets), DS-08 (en-tête fixe avec actions rapides), UI-07 (actions en cartes), UX-15 (compte poste visible), FO-07 (inventaire gardé pendant la session).
- 6. Accueil exact : FI-04 (relevés croisés par GUID avec les postes actifs de l'OU, âge affiché), MO-01 (score proportionnel au parc), FO-08 (table de fin de service), CO-11, CO-12 et CO-13 (comptes justes, pare-feu effectif, LTSC).
- 7. Moteur sobre et réactif : PF-06 et FI-05 (pulsation unique, minuteurs protégés, moins de 3 réveils par seconde au repos), PF-04 (débit par budget de temps et priorité), PF-05 (runspaces en pool), PF-03 et PF-07 (FleetStats filtré en SQL, requêtes préparées), validés par TE-05.
- 8. Sécurité des lectures et écritures : SE-09 (brancher ou supprimer les règles de Safety.Model, verrou par cible, codes LDAP ≥81), SE-07 (aucun transport intrusif sans le demander pour cette lecture), SE-08 (redémarrage avec sessions et délai), CD-01 en parallèle pour sortir le XAML et les workers du cœur.

## Corrections (34)

### CO-01 — Fiche utilisateur : l'état du compte caché sous « Dernière connexion »
*Impact fort, effort S*

- **Constat** : « Etat »/TxtUserState et « Derniere connexion »/TxtUserLastLogon sont dans la même cellule (ligne 8, colonnes 2 et 3). Les champs se superposent : Actif, Verrouillé ou Mot de passe expiré est illisible.
- **Proposition** : Une ligne propre pour l'état (Présence et État ligne 8, Dernière connexion et Mot de passe changé le ligne 9). Règle audit_ui.py qui refuse deux contrôles dans la même cellule.
- **Vérification** : confirmé. Les deux libellés « Etat » et « Derniere connexion » sont en Grid.Row=8/Column=2, et TxtUserState et TxtUserLastLogon tous deux en Grid.Row=8/Column=3 (Domenia-Core.ps1:4868-4871), avec un fond BgReadonly opaque. Aucun Grid.SetRow ni SetColumn ne les déplace. TxtUserLastLogon, déclaré après, recouvre donc l'état du compte rempli en 7284.
- Preuve : `Domenia-Core.ps1:4868-4871 (vérifié), 7284-7285`

### CO-02 — « Annuler » arrête une tâche de fond au lieu de la recherche
*Impact fort, effort S*

- **Constat** : LatestTaskId est mis à jour pour toute tâche, y compris les sauvegardes locales toutes les 350 ms. Annuler arrête « Enregistrement cache et liens » et affiche à tort « Cette ecriture AD ne peut pas etre annulee ». La barre de progression montre aussi cette tâche de fond.
- **Proposition** : Mémoriser LatestTaskId pour Write, Explicit et Selection seulement. Annuler vise la tâche annulable de premier plan la plus récente. Tâche locale : « Enregistrement local : il se termine seul. ».
- **Vérification** : confirmé. Start-UiTask fixe LatestTaskId pour toute tâche (Core:21345, 21352 ; Engine.UI.ps1:343), y compris « Enregistrement cache et liens » (Storage.UI.ps1:168, NonCancellable mais pas IsWrite). Stop-LatestUiTask (21427-21439) vise alors cette tâche, et Request-UiTaskStop affiche « Cette ecriture AD ne peut pas etre annulee » (21385-21386) sans arrêter la recherche ; la barre affiche aussi son nom (9237-9243). Précision : le minuteur de 350 ms ne lance un enregistrement que s'il y a des éléments en attente.
- Preuve : `Domenia-Core.ps1:21345, 21352 (vérifié), 21427-21439, 19470 ; modules/Domenia-Engine.UI.ps1:343 ; modules/Domenia-Storage.UI.ps1:166`

### CO-03 — Tri faux des dates et des tailles dans les grilles
*Impact fort, effort S*

- **Constat** : Les dates sont des chaînes « jj/MM/aaaa HH:mm:ss » (ou « Jamais ») sans SortMemberPath. Trier « Dernière connexion », « Modifié » ou « Installé le » classe par jour du mois (le 01/12/2025 avant le 02/01/2026). « Taille » se trie comme du texte (94 Mo après 2353,5 Mo) et reste en Mo alors que la synthèse dit « 6,2 Go ».
- **Proposition** : Propriétés de tri typées (DateTime ou ISO, « Jamais » = 0, SizeKb) en SortMemberPath. Affichage court (« il y a 3 j ») avec date complète en infobulle. Tailles via Format-DomeniaDashboardSize.
- **Vérification** : partiel. Le tri des dates est bien faux : LastLogon, Changed et InstallDate sont des chaînes « dd/MM/yyyy… » ou « Jamais » (Core:1480-1491, 8333-8341, 13103-13116, Live.Types.cs) sans SortMemberPath (4743-4746, 5748). « Taille » se trie bien comme du texte malgré SizeKb disponible. Mais elle ne « reste pas en Mo » : Format-Size du worker (13093-13101) passe en Go au-delà de 1024 Mo.
- Preuve : `Domenia-Core.ps1:1485-1491, 8336, 4743-4746, 5748-5749 ; modules/Domenia-Live.Types.cs:21-48 ; logiciels.png`

### CO-04 — Exports CSV illisibles dans Excel français
*Impact fort, effort S*

- **Constat** : Les 9 Export-Csv n'ont ni -Delimiter ni -UseCulture : tout tombe en colonne A. L'export de Rechercher recopie les propriétés internes en anglais (SessionDisplay, PresenceDetail multiligne, Rank, Guid…). L'inventaire n'a pas le poste dans le nom ($computer calculé puis inutilisé), et une fenêtre bloquante confirme.
- **Proposition** : -Delimiter ';' partout. Colonnes visibles seulement, dans l'ordre, en-têtes français. Nom avec OU ou poste et heure. Confirmation dans la page avec « Ouvrir le dossier ».
- **Vérification** : confirmé. Les 9 Export-Csv (Core:10669, 12166, 12168, 13615, 13868, 19535, 20667, 20762, 24114) n'ont ni -Delimiter ni -UseCulture : séparateur virgule, illisible dans un Excel français réglé sur « ; ». L'export de Rechercher passe les DomeniaLiveRow bruts (Experience.UI.ps1:13-24) à ConvertTo-DomeniaSpreadsheetSafeRow (219-233), qui recopie toutes les propriétés internes (Rank, Guid, SessionDisplay…). Export-DomeniaInventory calcule $computer (12161-12162) sans l'utiliser dans le nom, puis ouvre un Show-InfoBox (12170).
- Aussi proposé par le Spark (idée 47).
- Preuve : `Domenia-Core.ps1:10669, 12166, 12168, 13615, 13868, 19535, 20667, 20762 (vérifié), 219-233, 12160-12172`

### CO-05 — Filtre local bloqué après une recherche globale
*Impact fort, effort S*

- **Constat** : Le guide (ch. 1, étape 4) dit d'affiner une recherche globale avec « Dans les résultats ». En mode global, ce bloc est désactivé et le texte ignoré.
- **Proposition** : Autoriser le filtre local sur toute liste (aucun réseau), remis à zéro à chaque nouvelle recherche.
- **Vérification** : confirmé. Après une recherche globale, Set-DomeniaSearchMode met SearchBrowserLayout.Tag à « Global » (Core:6884-6889, 9860). Le DataTrigger de la ligne 4687 désactive alors le bloc « Dans les résultats », et Update-DomeniaLiveFilter force $query='' en mode Global (Live.UI.ps1:251). Cela contredit guides/technicien.md:23 (étape 4).
- Preuve : `Domenia-Core.ps1:4687 ; modules/Domenia-Live.UI.ps1:251 ; technicien.md:23`

### CO-06 — Un raccourci fait passer tout le profil en Expert
*Impact fort, effort S*

- **Constat** : Select-DomeniaWorkspace appelle Apply-DomeniaUiProfile 'Admin' dès qu'on cible TabLog, TabWmi, TabRaw, TabPermissions… Ctrl+L, la palette ou le menu « Explorateur WMI » basculent toute l'interface, sans prévenir, et le choix est enregistré.
- **Proposition** : Ne jamais changer de profil depuis un raccourci, un menu ou la palette. En Essentiel, Ctrl+L déplie le journal de session ; un onglet Expert s'affiche seul, temporairement, ou est refusé avec sa raison.
- **Vérification** : partiel. Le comportement est réel : Select-DomeniaWorkspace appelle Apply-DomeniaUiProfile 'Admin' pour TabLog/TabWmi/TabRaw/TabPermissions… (Core:9416-9418), et Save-DomeniaUiProfile persiste le choix via Set-DomeniaSetting (2293-2297). Mais c'est voulu (commentaire 9415) et documenté pour Ctrl+L dans guides/administrateur.md:808 (« Ctrl+L … bascule en profil Expert »). Le défaut se réduit à l'absence d'avertissement et à la persistance pour les autres accès (menu « Explorateur WMI », palette).
- Preuve : `Domenia-Core.ps1:9418-9421 (vérifié), 2293-2303, 12882, 15775 ; administrateur.md §13`

### CO-07 — Reçus jamais archivés : écritures bloquées au 513e
*Impact fort, effort M*

- **Constat** : Chaque écriture crée un reçu .json et rien ne les retire. Au-delà de 512, toute écriture est refusée (« archivage manuel des recus termines requis »). Avant chaque écriture, tous les reçus sont relus, et la DACL du dossier est réappliquée.
- **Proposition** : Sous writer.lock, déplacer les reçus terminés (Verified, NotSent, Reviewed, Delivered) de plus de 30 jours vers Receipts/Archive/AAAA-MM, jamais un reçu non résolu. Compteur dans Opérations. DACL posée une fois par session.
- **Vérification** : confirmé. Chaque écriture appelle New-WReceipt (Domenia-Core.ps1:21049), aucune fonction ne supprime ni n'archive les reçus, et l'archivage est noté « suivi à part » (D029). Avant chaque envoi, tous les *.json sont relus et la DACL est réappliquée par Get-WReceiptRoot (Domenia-Core.ps1:21033-21047 ; Domenia-Receipts.Worker.ps1:3-25). Correction de comptage : le refus part au-delà de 512 fichiers déjà présents, donc à la 514e écriture, pas à la 513e (Receipts.Worker.ps1:81, Core:21036).
- Preuve : `modules/Domenia-Receipts.Worker.ps1:81 (vérifié), 3-25, 32-47 ; Domenia-Core.ps1:21033-21047`

### CO-08 — Import d'associations sans aperçu ni retour arrière
*Impact fort, effort M*

- **Constat** : Import-LinksCsv ajoute directement, avec « Confidence 80 ». Il recopie la colonne Source du fichier : un CSV peut se faire passer pour une saisie déclarée. Il ignore en silence un poste connu, ne journalise rien et n'a aucun test.
- **Proposition** : Aperçu dans la page (valides, ignorées, inconnues dans AD). Source forcée « Import CSV » (badge Importé), chaque ligne journalisée, « Annuler l'import ». Test de règle.
- **Vérification** : partiel. Le cœur est réel : il n'y a ni aperçu ni annulation, et les colonnes Source, Confidence (80 par défaut) et VerifiedInAD sont reprises du CSV. Une Source « Saisie manuelle » est donc classée Affectation par Get-DomeniaRelationKind (Domenia-Core.ps1:7871-7876 ; Relations.Model.ps1:72), et aucun test n'appelle Import-LinksCsv. En revanche, « ne journalise rien » est faux : un bilan part dans Write-AppLog (Core:7897-7899). Le poste déjà connu n'est pas ignoré en silence : il est compté dans « deja present(s) », même si le libellé est trompeur quand l'utilisateur diffère.
- Preuve : `Domenia-Core.ps1:7829-7900`

### CO-09 — « Disque C: : 13 % libre » et alertes du poste
*Impact moyen, effort S*

- **Constat** : Le texte colle « C: » et « : » : double deux-points. D'autres alertes sont techniques (« relation d approbation a verifier », « replique a 14 j pres »). L'écart d'horloge est mesuré par rapport au poste d'administration, pas au contrôleur.
- **Proposition** : « Peu d'espace sur C: (13 % libre) », « C: presque plein (8 % libre) », « Mot de passe machine ancien : prévenir l'administrateur », « date approximative, à 14 jours près ». Écart d'horloge mesuré par rapport au contrôleur connecté.
- **Vérification** : confirmé. Sur la branche Warn (10-20 %), le texte vaut 'Disque ' + 'C:' + ' : ' + pourcentage, d'où « Disque C: : 13 % libre. » (BoardComputer.UI.ps1:201), visible sur tableau-poste.png. Les libellés « relation d approbation a verifier » et « replique a 14 j pres » sont bien présents (lignes 17-18 et 27). L'écart d'horloge compare l'heure du poste à Get-Date du poste d'administration (Domenia-Core.ps1:11533), alors que l'alerte Kerberos parle de l'écart avec le contrôleur (ligne 59).
- Preuve : `modules/Domenia-BoardComputer.UI.ps1:201 (vérifié), 17-18, 27, 59 ; tableau-poste.png`

### CO-10 — Verdict « Bon état » affiché en orange
*Impact moyen, effort S*

- **Constat** : Avec un seul point à surveiller, score 90 et verdict « Bon etat » (seuil 85), mais l'état est Warn : anneau et texte orange.
- **Proposition** : Verdict tiré de l'état (au moins un point à surveiller = « À surveiller »), une seule règle dans Get-DomeniaBoardHealth.
- **Vérification** : confirmé. Get-DomeniaBoardHealth donne score 90 et verdict « Bon etat » (score >= 85), mais State vaut Warn dès qu'un avertissement existe (Boards.Model.ps1:176-178). New-DomeniaHealthCard colore l'arc avec Get-DomeniaStateColor State et le verdict avec StatusWarning (Charts.UI.ps1:924, 942 ; Widgets.UI.ps1:365) : on lit donc « Bon etat » en orange.
- Preuve : `modules/Domenia-Boards.Model.ps1:176-178 ; modules/Domenia-Charts.UI.ps1:924, 942`

### CO-11 — « Utilisateurs détectés » compte des postes
*Impact moyen, effort S*

- **Constat** : La tuile ajoute 1 par observation portant un LinkUser : un utilisateur vu sur deux postes compte deux fois.
- **Proposition** : Compter les LinkUser distincts (sans casse), détail « sur N postes avec une session ». Sinon renommer « Postes avec un utilisateur ».
- **Vérification** : confirmé. $users++ est incrémenté pour chaque observation de présence du périmètre qui porte un LinkUser, une ligne par poste (BoardFleet.Model.ps1:114), sans dédoublonnage par utilisateur. La tuile « Utilisateurs detectes » (ligne 138 ; Boards.Model.ps1:57) compte donc des postes avec utilisateur, et un même utilisateur vu sur deux postes compte deux fois.
- Preuve : `modules/Domenia-BoardFleet.Model.ps1:114, 138 ; accueil.png`

### CO-12 — Pare-feu : faux « profil désactivé »
*Impact moyen, effort S*

- **Constat** : La collecte lit 6 clés (3 de stratégie, 3 locales) que la tuile additionne (« 3 / 6 profils actifs »). Une GPO qui force le pare-feu avec une clé locale à 0 lève une fausse alerte. L'expression 'on' reconnaît aussi « Inconnu » et « Non ».
- **Proposition** : État effectif par profil (la stratégie prime), « 3 profils sur 3 actifs (stratégie) », comparaison de valeurs exactes, alerte sur l'état effectif seulement.
- **Vérification** : partiel. La fausse alerte est réelle. La collecte ajoute jusqu'à 6 lignes, 3 de stratégie et 3 locales (Domenia-Core.ps1:11663-11679), et la tuile compte comme « desactive » toute ligne locale à 0, même quand la GPO force EnableFirewall=1 (BoardComputer.UI.ps1:265-268). En revanche, le point sur l'expression 'on' qui reconnaîtrait « Inconnu » ou « Non » ne se déclenche pas : le collecteur n'émet que « Active » ou « Desactive » (Core:11674-11676), et la ligne Etat est exclue par Get-DomeniaCategorySummary.
- Preuve : `Domenia-Core.ps1:11663-11679 ; modules/Domenia-BoardComputer.UI.ps1:265-272`

### CO-13 — Windows 10 LTSC signalé critique à tort
*Impact moyen, effort S*

- **Constat** : Le parc classe critique tout « Windows 10* », le poste le build 19044, qui est aussi LTSC 2021. LTSC, LTSB et IoT restent supportés après le 14/10/2025.
- **Proposition** : Exclure LTSC, LTSB et IoT côté annuaire et CIM, avec leur propre date de fin (FO-08).
- **Vérification** : confirmé. Le parc compte en critique tout operatingSystem AD de la forme 'Windows 10*', LTSB, LTSC et IoT compris (BoardFleet.Model.ps1:78, 120). Le poste traduit le build 19044 en « Windows 10 21H2 » sans regarder la légende, sauf pour les serveurs, puis lève une alerte (Boards.Model.ps1:120-130 ; BoardComputer.UI.ps1:92-93). Aucune gestion LTSC/LTSB n'existe dans le code. Précision : côté poste, seuls les builds 19043-19045 sont concernés ; LTSC 2019 (17763) et LTSB 2016 (14393) n'y sont pas signalés.
- Preuve : `modules/Domenia-BoardFleet.Model.ps1:78 ; modules/Domenia-BoardComputer.UI.ps1:93 ; modules/Domenia-Boards.Model.ps1:120, 130`

### CO-14 — Seuils différents entre jauge, tuile et alerte
*Impact moyen, effort S*

- **Constat** : La jauge passe à l'orange au-delà de 80 %, l'alerte mémoire part au-delà de 90 %. Le disque est « À surveiller » sous 20 % sur le poste, mais le parc n'alerte que sous 10 % et découpe à 25 %.
- **Proposition** : Get-DomeniaBoardThresholds dans Boards.Model ; le dessin se colore selon entry.State. Seuil disque du parc aligné sur le poste.
- **Vérification** : confirmé. La jauge passe en Warn au-delà de 80 % et en Alert au-delà de 90 % (Charts.UI.ps1:635-636), alors que la mémoire n'émet un point « Warn » qu'au-delà de 90 % (BoardComputer.UI.ps1:174-175) : orange sans alerte entre 81 et 90 %, rouge pour une alerte simplement Warn au-delà. Le disque est Warn sous 20 % sur le poste (ligne 83), alors que le parc n'alerte que sous 10 % et découpe ses tranches à 10/25/50 % (BoardFleet.Model.ps1:195-196, 235).
- Preuve : `modules/Domenia-Charts.UI.ps1:635-639 ; modules/Domenia-BoardComputer.UI.ps1:83, 175 ; modules/Domenia-BoardFleet.Model.ps1:195-196, 235`

### CO-15 — Légende de jauge qui déborde de l'anneau
*Impact moyen, effort S*

- **Constat** : La légende sous le pourcentage n'a pas de largeur maximale : « Au moment de l inventaire » coupe le trait (Charge du processeur).
- **Proposition** : MaxWidth d'environ 1,5 × rayon intérieur, centrée sur 2 lignes, ou sous l'anneau. Une charge CPU instantanée peut devenir une petite tuile chiffrée.
- **Vérification** : confirmé. La légende de la jauge est un TextBlock à retour à la ligne, sans MaxWidth, centré dans la grille de l'anneau entier (Charts.UI.ps1:645-653 ; New-DomeniaChartText:57-77). Elle peut donc s'étendre sur toute la largeur extérieure, de 186 px en taille S, et chevaucher le trait de l'arc. C'est visible sur tableau-poste.png, où « Au moment de l inventaire » recouvre l'arc de « Charge du processeur ».
- Preuve : `modules/Domenia-Charts.UI.ps1:645-653 ; tableau-poste.png`

### CO-16 — Axes, graduations et unités des graphiques
*Impact moyen, effort S*

- **Constat** : La graduation haute vaut le maximum et chevauche l'étiquette ; une demi-graduation affiche « 1,5 » poste. Tranches sans unité (« <= 4 », « 4-8 »), titre « Espace libre sur C: (%) (19 postes) », 12 Go rangé dans « 16 Go ». Gros logiciels en Mo (« 2354 Mo ») et noms coupés à 150 px même dans une carte de 600 px.
- **Proposition** : Graduations arrondies (1, 2, 5 × 10^n), entières pour les comptes, sans axe si les barres sont étiquetées. « ≤ 4 Go », « 4 à 8 Go », « moins de 7 j ». « 19 postes » en sous-titre. Tranches « 5 à 8 Go », « 9 à 16 Go ». Tailles via Format-DomeniaDashboardSize. Libellés larges de Min(260, 42 % de la carte).
- **Vérification** : partiel. La plupart des points sont réels : demi-graduation Round(max*0.5,1) qui donne « 1,5 » (Charts.UI.ps1:748), tranches sans unité '<= 4' et '4-8' (Probes.Model.ps1:138), titre Name + ' (N postes)' qui donne « Espace libre sur C: (%) (19 postes) » (Boards.Model.ps1:436 ; Probes.Model.ps1:30), 12 Go rangé dans « 16 Go » car gb <= 17 (BoardFleet.Model.ps1:186), tailles en Mo (BoardSoftware.Model.ps1:150-155), libellés plafonnés à 150 px (Charts.UI.ps1:687). En revanche, le chevauchement de la graduation haute n'est pas établi : son libellé est dans la marge gauche (x 0-28) et la valeur de la barre au-dessus de la ligne, dans sa colonne (lignes 750-752, 789-790). accueil.png ne montre pas de recouvrement.
- Preuve : `modules/Domenia-Charts.UI.ps1:687, 737-755 ; modules/Domenia-Probes.Model.ps1:127-141 ; modules/Domenia-Boards.Model.ps1:436 ; modules/Domenia-BoardFleet.Model.ps1:72, 183-191 ; modules/Domenia-BoardSoftware.Model.ps1:150-155 ; accueil.png ; logiciels.png`

### CO-17 — Échap vide la liste affichée
*Impact moyen, effort S*

- **Constat** : Dans la barre du haut, Échap efface le texte mais aussi la liste (BranchObjects et DgObjects vidés). La recherche en cours n'est pas arrêtée : le compteur se réécrit ensuite et « Pinger la liste » reste actif devant une grille vide.
- **Proposition** : Échap efface seulement le texte ; barre vide, il ferme l'aide en surimpression ou la palette. Seul « Effacer » vide la liste, via Clear-DomeniaGlobalSearch.
- **Vérification** : confirmé. Le raccourci Échap, actif quand TxtGlobalSearch a le focus, vide le texte, BranchObjects et DgObjects (Domenia-Core.ps1:15778-15790). Contrairement à Clear-DomeniaGlobalSearch (Core:9768-9781), il n'arrête ni le minuteur ni les tâches de recherche, et ne remet pas SearchListHasMachine à faux. La pompe progressive continue de réécrire LblBranchCount, et à la finalisation Update-DomeniaLoginColumnFromRows $s.Rows peut laisser BtnParkPing actif devant une grille vide (Live.UI.ps1:812-827, 152).
- Preuve : `Domenia-Core.ps1:15778-15790 (vérifié) ; modules/Domenia-Live.UI.ps1 ; technicien.md §9`

### CO-19 — Compteur de ping faux
*Impact moyen, effort S*

- **Constat** : En ping seul, « sans réponse » = Done − Online : échecs de worker et erreurs DNS comptent comme postes muets.
- **Proposition** : Compter à part En ligne, Sans réponse, Erreur ; en fin de relevé, trois pastilles cliquables qui filtrent.
- **Vérification** : confirmé. Fail-DomeniaParkSession construit un paquet valide qui passe Done++ sans Online (Park.UI:160, 180). En ping seul, une erreur de worker ou une résolution DNS échouée (« Erreur de ping », Live.Model probe ligne ~191) tombe donc dans « sans reponse » = Done-Online (Park.UI:10), alors que la grille affiche « Non vérifié » ou « Erreur de ping ».
- Aussi proposé par le Spark (idée 29).
- Preuve : `modules/Domenia-Park.UI.ps1:10`

### CO-20 — « Postes sans connexion » oublie les jamais connectés
*Impact moyen, effort S*

- **Constat** : Le filtre (lastLogonTimestamp<=X) ignore les postes sans attribut, souvent les plus anciens.
- **Proposition** : (|(lastLogonTimestamp<=X)(!(lastLogonTimestamp=*))) et « Jamais » à l'affichage.
- **Vérification** : confirmé. Le filtre LDAP (&(objectCategory=computer)(lastLogonTimestamp<=X)) (Domenia-Search.Model.ps1:386) n'évalue pas à vrai pour un objet sans l'attribut. Les postes jamais connectés ou pré-créés sont donc exclus de la vue, et aucune branche (!(lastLogonTimestamp=*)) ne les ajoute.
- Preuve : `modules/Domenia-Search.Model.ps1:386`

### CO-21 — Un terme de recherche invisible filtre l'OU
*Impact moyen, effort S*

- **Constat** : Le mode OU lit le champ masqué TxtBranchSearch, qu'un favori ou l'historique peut remplir : la liste est filtrée par un texte qu'on ne voit ni n'efface.
- **Proposition** : Afficher ce terme en puce « compta × », ou le supprimer avec les contrôles hérités (CD-04).
- **Vérification** : partiel. Le champ TxtBranchSearch est bien dans une Grid Collapsed (Core:4656-4657), et un favori OU (Guard.UI:152-153) ou l'historique (Search.UI:180) peut le remplir. Le terme n'est pourtant pas invisible : Update-DomeniaSearchScopeUi l'ajoute à LblSearchScope (« Terme de la recherche enregistrée », Core:6928-6929, infobulle = texte complet). Il s'efface en choisissant une OU dans l'arbre (Core:6866) ou par « Effacer » (Core:9786) ; le défaut se réduit à l'absence de champ éditable dédié.
- Aussi proposé par le Spark (idée 87).
- Preuve : `Domenia-Core.ps1:6876-6882, 6929 ; modules/Domenia-Guard.UI.ps1:150 ; modules/Domenia-Search.UI.ps1:183`

### CO-22 — Options du compte affichées en nombre brut
*Impact moyen, effort S*

- **Constat** : TxtUserUac et TxtCompUac reçoivent [string]$uac : 66048 ou 4096 à l'écran. La capture montre « Compte ordinateur standard » parce que le script l'injecte. « Login » et « UPN » restent techniques.
- **Proposition** : Traduire les bits avec Get-UacStatusLabel ou Get-DomeniaAccountState. « Login » devient « Identifiant », « UPN » « Nom de connexion ».
- **Vérification** : confirmé. TxtUserUac et TxtCompUac reçoivent [string]$uac brut, valeur lue directement de userAccountControl (Core:7269/7288 et 7380/7390), sans traduction en libellé. Le script de capture injecte « Compte ordinateur standard » (guides/captures/capture-guides.ps1:258), ce qui masque le nombre réellement affiché. Les étiquettes « Login » et « UPN » (Core:4846-4848) restent techniques.
- Preuve : `Domenia-Core.ps1:7288, 7390, 4846-4848 ; guides/captures/capture-guides.ps1:258`

### CO-23 — « Pwd last set » : libellé anglais et aide de mot de passe
*Impact moyen, effort S*

- **Constat** : Le champ date TxtUserPwdLastSet s'appelle « Pwd last set » et porte l'aide d'une PasswordBox (« Saisie protégée : l'aide contextuelle ne lit jamais la valeur »), avec le nom accessible « Mot de passe ».
- **Proposition** : Libellé « Mot de passe changé le », aide qui explique la date, nom accessible propre (UI-12).
- **Vérification** : confirmé. Le Label vaut « Pwd last set » (Core:4872). Le TextBox TxtUserPwdLastSet porte ToolTip/HelpText « Saisie protégée : l'aide contextuelle ne lit jamais la valeur » et AutomationProperties.Name « Mot de passe » (Core:4873). Domenia-UX.help.json:737-741 reprend le titre « Mot de passe » en specific-sensitive, alors que le champ affiche une date.
- Preuve : `Domenia-Core.ps1:4872-4873 (vérifié)`

### CO-24 — Textes du tableau du poste contraires à l'inventaire rapide
*Impact moyen, effort S*

- **Constat** : Le résumé dit que l'inventaire complet ajoute les correctifs, et les sections vides « Inventaire complet requis : correctifs / protection ». Or le rapide collecte déjà correctifs, antivirus, pare-feu et BitLocker.
- **Proposition** : Le complet ajoute processus, événements, tâches planifiées, certificats. Une section vide dit « non lu, voir le détail par source ».
- **Vérification** : confirmé. Le collecteur d'inventaire n'isole sous if ($deep) que Processus et Événements (Core:11933+). Correctifs (11699), BitLocker, Pare-feu et Antivirus sont donc collectés en rapide. Pourtant le résumé dit « L inventaire complet ajoute correctifs » (BoardComputer.UI:356) et les indices des sections vides annoncent « Inventaire complet requis : correctifs... / protection, correctifs... » (351-352), comme l'infobulle du bouton complet (Core:5496).
- Preuve : `modules/Domenia-BoardComputer.UI.ps1:345-356 ; Domenia-Core.ps1:11699, 5638`

### CO-25 — Ping : résultat en anglais, présence non mise à jour
*Impact moyen, effort S*

- **Constat** : Le ping affiche « #1 Success 3ms 10.0.0.5 » dans la seule barre d'état, après une tentative de 800 ms, sans mettre à jour la Présence de la fiche.
- **Proposition** : 2 tentatives, « Répond en 3 ms (10.0.0.5) » ou « Pas de réponse », mise à jour de TxtCompPresence et de la pastille.
- **Vérification** : confirmé. Le ping de la fiche (BtnCompPing, Core:19429) fait un seul Ping.Send(...,800) et formate « #1 $Status ${Ms}ms $Address » avec l'énumération IPStatus anglaise (Core:17076-17080). Complete-DomeniaComputerToolUi n'appelle que Set-Status (Core:16828) : aucune mise à jour de TxtCompPresence ni de la présence de la ligne.
- Preuve : `Domenia-Core.ps1:17076-17082, 16818-16829`

### CO-26 — Recherche locale incomplète après ouverture d'une fiche
*Impact moyen, effort S*

- **Constat** : IndexBulk met Extra (système, emplacement, service) dans search_key ; la mise à jour d'une ligne, faite à chaque ouverture de fiche, le recalcule sans Extra. Un poste ouvert n'est plus trouvé par « Windows 10 ».
- **Proposition** : Une seule formule de search_key (ou reprendre Row.Key), et une réparation unique par UPDATE ad_objects SET search_key=lower(…||extra).
- **Vérification** : confirmé. Show-AdObjectResult appelle Sync-DomeniaIndexEntry pour chaque lecture vive d'un utilisateur ou d'un poste (Core:22193-22194, 7318). La ligne est persistée en Kind 'Index' (Add-DomeniaIndexPersistence), dont le search_key omet Extra (Storage.Worker.ps1:279), contrairement à IndexBulk (326). Or la recherche locale normale est 100 % SQLite sur search_key (Core:14262-14265, Engine.Worker:194) : « windows 10 » ne retrouve plus ce poste.
- Preuve : `modules/Domenia-Storage.Worker.ps1:279 et 326 (vérifié) ; Domenia-Core.ps1:14617, 14639`

### CO-27 — Créer une OU : deux fenêtres et une promesse non tenue
*Impact moyen, effort S*

- **Constat** : Le menu de l'arbre ouvre un formulaire puis une fenêtre où taper CREER ; une faute annule sans explication. Le message promet une protection contre la suppression que la voie ADSI ne pose pas.
- **Proposition** : Un seul parcours dans l'onglet Unité d'organisation, OU parente en clair, confirmation intégrée sans mot à taper. N'annoncer la protection que si elle est posée.
- **Vérification** : confirmé. Le menu ouvre Show-DomeniaFormDialog (fenêtre WPF, Core:1923) puis Confirm-TextAction ouvre une seconde fenêtre exigeant « CREER » en -ceq (Core:21963-21973). Une faute donne seulement « Creation OU annulee. » sans en dire la cause (Core:23931). Le message promet « une OU protegee contre la suppression accidentelle » alors que la branche ADSI ne pose pas cette protection (Core:23952-23957), ce que le résultat admet après coup.
- Preuve : `Domenia-Core.ps1:12972-12977, 23926-23935, 21963-21974, 5073-5089`

### CO-28 — « Restaurer la suppression » actif sans rien à restaurer
*Impact moyen, effort S*

- **Constat** : La disponibilité vaut vrai dès que le fichier journal existe : après une restauration, le bouton répond « Aucune suppression locale à restaurer. ». Le libellé ne dit pas ce qui sera remis.
- **Proposition** : Disponibilité calculée par Get-DomeniaRelationsRestorableEntry, en cache invalidé à chaque suppression ou restauration. Libellé « Restaurer jdupont → PC01 ».
- **Vérification** : confirmé. Test-DomeniaRelationsRestoreAvailable renvoie JournalPresent dès que le fichier journal existe (Relations.UI:448-456), et Add-DomeniaRelationHistory le passe à vrai même pour une entrée « Restored » (420). Après une restauration, le bouton reste actif et Restore-DomeniaRemovedLink répond « Aucune suppression locale à restaurer. » (587). Le libellé et l'infobulle restent génériques (Core:5296), sans jamais nommer l'association visée.
- Preuve : `modules/Domenia-Relations.UI.ps1:402-422, 448-456, 581-598`

### CO-29 — Dates des associations : UTC et heure locale mélangées
*Impact moyen, effort S*

- **Constat** : Les consoles observées enregistrent en ISO UTC, les liens manuels et importés en « yyyy-MM-dd HH:mm:ss » local. La colonne Date mélange les deux et le tri devient faux.
- **Proposition** : Tout stocker en UTC ISO, afficher en heure locale (« 08/10 09:15 »), trier sur la date.
- **Vérification** : confirmé. Les consoles stockent When=ObservedUtc au format ISO UTC « o » (Relations.UI.ps1:1392 puis 612), la saisie manuelle et l'import écrivent « yyyy-MM-dd HH:mm:ss » local (Core:18765/18796/18824, 7873), et Live.UI.ps1:468 ajoute un 3e format local « s » ; la colonne Date lie When brut (Core:5306, 5397) et rien ne normalise (Add-DomeniaRelation, Relations.UI:457-520). Pire que décrit : ConvertTo-DomeniaUtcDate (Common.Model:171, AssumeUniversal) lit l'heure locale comme UTC, ce qui fausse aussi le choix « plus récent » de Select-DomeniaPrimaryRelation et du placement (Relations.Model:167-171, 195-197).
- Preuve : `modules/Domenia-Relations.UI.ps1:614, 1266-1331 ; Domenia-Core.ps1:7870, 5306, 5397`

### CO-30 — Noms d'états internes affichés à l'utilisateur
*Impact moyen, effort S*

- **Constat** : Step-DomeniaAssociationState renvoie « Action « Pick » impossible dans l etat « Idle ». », affiché tel quel dans la confirmation et la barre d'état.
- **Proposition** : Un message français par cas (« Choisissez d'abord une ligne dans les résultats. »), noms internes au journal.
- **Vérification** : confirmé. Step-DomeniaAssociationState renvoie « Action « Pick » impossible dans l etat « … » » (Relations.Model.ps1:270), et Step-DomeniaRelationsAssociation sans -Quiet l'écrit tel quel dans LblRelationConfirm et la barre d'état (Relations.UI.ps1:168-169). Chemin réel : « Adopter » un second candidat pendant qu'une association est en attente (Pick depuis Pending, UI:1070 ; le bouton reste actif, UI:201) ou après « Arrêter » qui remet Idle avec les candidats encore listés (UI:954).
- Preuve : `modules/Domenia-Relations.Model.ps1:270 ; modules/Domenia-Relations.UI.ps1:164-174`

### CO-31 — Comptes, zone Annuaire : champ trompeur et messages périmés
*Impact moyen, effort S*

- **Constat** : Modifier « Identifiant » ne change rien. En session Windows, « Tester la connexion » échoue toujours (« Utilise Relogger... »), et un message cite un bouton qui n'existe pas. « Se connecter » écrit LastLogin que la connexion ne lit pas (elle lit Auth.LastLogin), même sans « Mémoriser ».
- **Proposition** : Une carte en lecture seule (identité, contrôleur) avec « Changer de compte », qui préremplit la connexion. Supprimer le champ, Tester et l'écriture de LastLogin.
- **Vérification** : confirmé. « Se connecter » écrit Settings.LastLogin via Set-DomeniaSetting (Core:19133, 19243) sans condition « Mémoriser », clé jamais relue : la fenêtre de connexion lit Config.Auth.LastLogin (Core:25436), donc le champ Identifiant n'a aucun effet. En session Windows Conn.Credential vaut $null (Core:24749) et Test-DomeniaActiveDirectoryCredential lève toujours « Utilise Relogger... » (Core:19034), et l'autre message cite « Utiliser / relogger » alors que les boutons s'appellent « Se connecter » et « Changer de compte » (Core:19045, 5167-5181).
- Preuve : `Domenia-Core.ps1:5168-5180, 19030-19046, 19133, 19240-19245, 25436`

### CO-32 — F1 ouvre les Outils au lieu de l'aide
*Impact moyen, effort S*

- **Constat** : Sous Windows, F1 veut dire Aide ; ici F1 ouvre la page Outils.
- **Proposition** : F1 ouvre ou ferme le panneau d'aide (Switch-DomeniaUxHelp). Ctrl+1 à Ctrl+7 pour les rubriques.
- **Vérification** : confirmé. La table des raccourcis lie F1 à Select-DomeniaWorkspace « TabApplicationTools » (Core:15768), et le journal l'annonce comme « F1 outils » (Core:15830). Aucun autre gestionnaire de F1 n'existe, alors que Shell.Model.ps1:801 promet « F1 : aide détaillée / motif dans le panneau d'aide » (UxHelpPanel). L'onglet Outils contient bien une aide sur les commandes, mais pas le panneau d'aide promis.
- Preuve : `Domenia-Core.ps1:15768 (vérifié)`

### CO-33 — Objets avec « / » dans le nom inaccessibles
*Impact moyen, effort S*

- **Constat** : Get-LdapPath et Get-WLdapPath collent le DN dans « LDAP://serveur/DN » sans échapper « / ». Une OU « Compta/Paie » ne s'ouvre ni ne se modifie.
- **Proposition** : Échapper « / » en « \/ » dans les deux fonctions (contrat worker), avec un test sur un DN contenant « / ».
- **Vérification** : confirmé. Get-LdapPath et Get-WLdapPath concatènent le DN brut dans « LDAP://serveur/DN » (Core:1090-1096, 8211-8216), sans aucun échappement de « / » nulle part dans le code. Or ADSI exige « \/ » dans un ADsPath. La lecture de la fiche (New-WEntry dans Open-AdObject, Core:22120), les recherches enracinées sur une OU (New-WSearcher, Core:8286) et toutes les écritures (Core:23364-24035) passent par ce chemin et échouent donc pour une OU « Compta/Paie ».
- Preuve : `Domenia-Core.ps1:1090-1096, 8211-8216`

### CO-34 — Filtre LDAP invalide avec « ** » (à confirmer en VM)
*Impact moyen, effort S*

- **Constat** : Les étoiles sont gardées telles quelles : « jean** » donne un filtre invalide (RFC 4515) et une erreur technique. L'aide dit « ou * pour un apercu » alors que le global refuse « * », et elle tutoie.
- **Proposition** : Fusionner les étoiles consécutives, refuser un texte fait seulement d'étoiles avec un message clair, aide selon le mode (« * » seulement dans une OU).
- **Vérification** : partiel. Seuls deux points sont établis. Escape-LdapValue -KeepWildcard (Core:1439) garde « ** » tel quel dans (name=jean**) (Core:9912-9916), sans réduction des étoiles, mais je n'ai pas pu vérifier que le client ou le contrôleur AD rejette ce filtre (à confirmer en VM). Le message « Saisis au moins… » tutoie bien (Core:9833). En revanche, le global ne refuse pas « * » : le plan renvoie un plan valide (Search.Model.ps1:179) et Core:9832/9909 l'acceptent comme aperçu.
- Preuve : `Domenia-Core.ps1:7019-7026, 9830-9834, 9912-9916`

### CO-35 — « Tester la présence réseau » quitte la liste
*Impact faible, effort S*

- **Constat** : L'entrée du menu Analyser appelle Queue-DomeniaSelectedObjectOpen -Immediate -Force, qui bascule sur la Fiche.
- **Proposition** : Appeler Request-DomeniaLiveRecheck pour rester dans Rechercher, et renommer l'entrée « Revérifier ce poste ».
- **Vérification** : confirmé. L'entrée « Tester la presence reseau » du menu contextuel de la liste (Build-DomeniaObjectsContextMenu, Core:12895) appelle Queue-DomeniaSelectedObjectOpen -Immediate -Force, qui bascule sur WsObject/TabGeneric (Core:10307-10309). De plus, Invoke-DomeniaPendingSelectionOpen ouvre l'objet avec -SuppressRemoteProbes (Core:10284) : l'entrée ne lance donc même pas de sonde de présence.
- Preuve : `Domenia-Core.ps1:12895, 10307-10309`

## Sécurité (14)

### SE-02 — Garde des attributs bruts jamais appelée par le worker
*Impact fort, effort S*

- **Constat** : Test-WRawAttributeAllowed (AllowRawAttributeWrite et liste bloquée) est défini dans WorkerCommon, mais rien ne l'appelle. Seule l'interface contrôle, et elle ignore BlockSensitiveRawAttributes.
- **Proposition** : Appeler Test-WRawAttributeAllowed dans le worker d'écriture pour chaque changement Raw, et aligner l'interface sur la même règle.
- **Vérification** : partiel. Test-WRawAttributeAllowed (21921) n'est appelé nulle part, et le worker WriteAttributes accepte n'importe quel attribut ; l'écriture brute arrive avec Capability « Edit » (23987). Mais Set-OrClearRawAttribute (23974-23977) vérifie AllowRawAttributeWrite et applique toujours la liste bloquée : ignorer BlockSensitiveRawAttributes rend le contrôle plus strict, pas plus faible. Il manque une seconde garde côté worker ; aucune faille n'est atteignable depuis l'interface.
- Preuve : `Domenia-Core.ps1:21921 (seule occurrence, vérifié), 23287-23400, 23974-23977`

### SE-03 — Garde Win32_Product contournable
*Impact fort, effort S*

- **Constat** : Les deux gardes ne bloquent que le nom exact Win32_Product. CIM_Product, Win32_SoftwareFeature et les autres classes MSI passent, alors que Test-DomeniaMsiProviderClass existe sans être branché.
- **Proposition** : Appeler Test-DomeniaMsiProviderClass dans les deux gardes. Dans le worker des widgets, refuser toute classe absente de Get-DomeniaProbeCatalog.
- **Vérification** : confirmé. Assert-DomeniaWmiReadQuery (348) et le worker (13652) ne comparent que -ieq 'Win32_Product'. L'explorateur WMI (13832) accepte toute classe proposée par Get-CimClass : CIM_Product, qui énumère aussi les sous-classes dont Win32_Product, et Win32_SoftwareFeature passent. Test-DomeniaMsiProviderClass (Workstation.Model:367) n'est appelé qu'en test. Les sondes de Live.Model:233 viennent d'un catalogue figé (Probes.Model) sans classe MSI : elles ne sont pas une voie d'accès.
- Preuve : `Domenia-Core.ps1:348, 13652 (vérifié) ; modules/Domenia-Workstation.Model.ps1:367 ; modules/Domenia-Live.Model.ps1:233`

### SE-04 — « Mettre à jour tout » lit aussi le journal du contrôleur sans le dire
*Impact fort, effort S*

- **Constat** : Le bouton appelle Start-DomeniaIndexBuild -UpdateLinks ; à la fin, Start-DomeniaLogonHarvest -Silent lit le journal Sécurité du contrôleur (jusqu'à 5000 événements) sans confirmation. La confirmation n'en parle pas.
- **Proposition** : Retirer l'enchaînement, ou l'afficher dans la confirmation comme une case « Lire aussi les ouvertures de session du contrôleur », décochée.
- **Vérification** : confirmé. BtnIndexBuild appelle Start-DomeniaIndexBuild -UpdateLinks (19487), dont la confirmation (15299-15300, estimation IndexBuild 20678) ne chiffre que l'activité AD. À la fin, Complete-DomeniaIndexBuildUi (15282-15284) lance Start-DomeniaLogonHarvest -Silent, qui saute sa propre confirmation (14858) et lit le journal Security du contrôleur (4624, MaxEvents 5000). L'infobulle (6021) dit seulement « resynchronise les associations connues ».
- Preuve : `Domenia-Core.ps1:15282-15284, 19487 (vérifié), 14858`

### SE-05 — Pinger, Détecter et Analyser sans plafond
*Impact fort, effort S*

- **Constat** : Start-DomeniaOnlinePark prend toutes les lignes « Machine » de la grille. Avec « Tout le domaine » et une limite à 20 000, on retrouve la détection sur tout le parc qui a été retirée.
- **Proposition** : Plafond réglable (500 postes par défaut) avec message clair. Refuser le relevé si l'OU est la racine sans autre filtre. Dire dans la confirmation « liste limitée à 100 : les autres postes ne sont pas concernés ».
- **Vérification** : partiel. Aucun plafond : Park.UI:56 prend toutes les lignes Machine de DgObjects, et la recherche peut en afficher 20 000 (Core:9874). En revanche, Complete-DomeniaParkTargets (Park.UI:88-93) demande une confirmation qui affiche le nombre exact de postes, traite quatre postes à la fois et peut être arrêté. Ce n'est donc pas un retour de la détection implicite retirée ; c'est une opération explicite et comptée, mais sans limite.
- Preuve : `modules/Domenia-Park.UI.ps1:41, 56 ; Domenia-Core.ps1:9875, 4591`

### SE-06 — Retour automatique en lecture seule
*Impact fort, effort S*

- **Constat** : Une fois la lecture seule retirée, l'écriture reste active jusqu'au geste inverse, même des heures plus tard.
- **Proposition** : Retour en lecture seule après 15 min sans écriture (réglable), avec compte à rebours dans la pastille (« Modifications autorisées · 12 min ») et « Repasser en lecture ».
- **Vérification** : confirmé. Aucun minuteur ne remet le mode lecture seule. ReadOnlyMode ne repasse à vrai qu'au démarrage (24384), lors d'une reconnexion de compte (Start-DomeniaAccountRelogin, 19171) ou par la case à cocher (19618). Dans une même session, l'écriture reste donc active sans limite de durée.
- Preuve : `Domenia-Core.ps1:19617-19650, 22390-22406`

### SE-07 — Une lecture ne passe jamais par une tâche SYSTEM sans le demander
*Impact fort, effort M*

- **Constat** : Si CIM échoue alors que l'autorisation de 5 min est active, inventaire, logiciels, WMI et diagnostic passent par PsExec ou une tâche planifiée. Le guide relève la contradiction avec « Jamais utilise par une lecture ». Côté logiciels, une portée utilisateur vide (personne connecté) suffit à déclencher ce repli.
- **Proposition** : Demander pour chaque lecture : « CIM ne répond pas. Lire par tâche planifiée sur ce poste ? ». Corriger needTask : une portée utilisateur vide n'est pas un échec.
- **Vérification** : partiel. Le repli PsExec ou tâche SYSTEM n'est possible qu'avec l'autorisation explicite de 5 minutes pour ce poste (Assert-WRemoteArtifactPermission 8645 ; Guard.UI:104-110 annonce « prochaine action volontaire, relancez votre diagnostic »). La règle affichée dit aujourd'hui « sert aussi de repli aux lectures du poste » (Access.Model:426) ; le guide (administrateur.md:224) cite un texte périmé. Restent réels : sous autorisation, les logiciels lancent une tâche dès que la portée utilisateur est vide, même si CIM a répondu (Core:13441) ; Test-DomeniaTransportFallbackAllowed (Access.Model:432, « jamais pour une lecture ») n'est branché nulle part.
- Preuve : `Domenia-Core.ps1:11386, 11413, 13441-13448 ; administrateur.md:224`

### SE-08 — Redémarrer en sachant qui est connecté
*Impact fort, effort M*

- **Constat** : Confirm-Action affiche seulement « Redemarrer immediatement PC ? », puis Restart-Computer -Force. L'utilisateur perd son travail, sans message ni délai, alors que la lecture des sessions existe.
- **Proposition** : Panneau dans la page : sessions ouvertes (WTS), puis « Dans 5 min avec message à l'utilisateur » (par défaut) ou « Maintenant ».
- **Vérification** : confirmé. Core:17104-17112 : après les seules gardes du mode écriture, Confirm-Action affiche « Redemarrer immediatement $name ? » puis le worker lance Restart-Computer -Force. Aucune lecture des sessions, aucun message ni délai pour l'utilisateur connecté.
- Preuve : `Domenia-Core.ps1:17104-17112 ; modules/Domenia-Sessions.UI.ps1`

### SE-09 — Règles de sécurité écrites mais non branchées
*Impact fort, effort L*

- **Constat** : 25 des 36 fonctions de Safety.Model ne servent qu'aux tests : Test-DomeniaOperationAllowed (verrou par cible), Resolve-DomeniaConditionalWrite (code LDAP ≥81 = issue à vérifier), Test-DomeniaPreconditionCurrent, Get-DomeniaCompensation. Une quinzaine de fonctions d'Insight.Model aussi.
- **Proposition** : Trancher une par une : brancher ou supprimer. D'abord le verrou par cible et la lecture des codes LDAP ≥81 dans le chemin d'écriture.
- **Vérification** : partiel. Le chiffre est surévalué : 16 fonctions de Safety.Model sur 36 n'ont aucun appel en production, directement ou par une autre fonction ; ce sont bien les quatre citées, plus Batch, DryRun, OperationLock, SessionEndPlan, etc. Les 20 autres servent, par exemple Get-DomeniaAtomicStrategy (23237), Test-DomeniaPlanStillValid (22915), Test-DomeniaWriteAdmission (22999) et Resolve-DomeniaPostcondition (22668) ; la règle LDAP ≥ 81 est recodée en ligne (23341-23343). À l'inverse, aucune des 56 fonctions d'Insight.Model n'est appelée en production, bien plus qu'« une quinzaine ».
- Preuve : `modules/Domenia-Safety.Model.ps1 ; tests/rules/Safety.Tests.ps1 ; dev/engineering/d120/raccordement/regles-points-ouverts.md`

### SE-10 — Options de compte dangereuses séparées des courantes
*Impact moyen, effort S*

- **Constat** : Un même bloc, validé par un seul « Appliquer », mêle « Mot de passe sans expiration » à « Sans pre-authentification », « Chiffrement DES », « Mot de passe non requis », « Chiffrement reversible » et aux délégations.
- **Proposition** : 2 ou 3 options visibles. Les autres dans « Options de sécurité avancées », replié et réservé à Expert, avec avertissement rouge et avant/après.
- **Vérification** : partiel. Les neuf options sont bien dans le même bloc avec un seul bouton Appliquer (4992-5003). Mais Apply-UserAccountOptions (23588-23612) classe « mot de passe non requis », chiffrement réversible, pré-authentification, DES et les deux délégations en haut risque. Il exige alors la saisie « RISQUE » (RequireTypedHighRiskConfirmation, vrai par défaut). Le mélange relève de l'ergonomie : il n'y a pas de validation en un seul clic.
- Preuve : `Domenia-Core.ps1:4992-5003`

### SE-12 — DN saisi : contrôler syntaxe et domaine
*Impact moyen, effort S*

- **Constat** : Resolve-WGroupDn et Resolve-WObjectDn renvoient tel quel tout texte commençant par CN=, OU= ou DC=, sans vérifier la syntaxe ni le suffixe : CN=Configuration est accepté comme cible d'écriture.
- **Proposition** : Valider avec Split-DomeniaDn, exiger le suffixe BaseDn, résoudre vers le GUID et réafficher le nom lisible dans la confirmation.
- **Vérification** : partiel. Resolve-WGroupDn/Resolve-WObjectDn (Domenia-Core.ps1:23046-23064) renvoient bien tout texte commençant par CN=/OU=/DC= sans contrôle de syntaxe ni de suffixe. En revanche, CN=Configuration ne peut pas devenir une cible d'écriture : côté groupe, Test-WDirectMembership (21889-21898) exige objectCategory=group et lève une erreur avant toute écriture ; côté membre, l'écriture porte sur le groupe sélectionné (DN issu du plan, 23866-23876) et c'est AD qui valide le DN membre. La preuve Search.Model.ps1:408 (Split-DomeniaDn) est hors sujet.
- Preuve : `Domenia-Core.ps1:23046-23064 ; modules/Domenia-Search.Model.ps1:408`

### SE-13 — Revalidation AD de fond : la couper par défaut
*Impact moyen, effort S*

- **Constat** : Tant que la grille est visible, les objets listés sont relus dans AD par lots de 24 toutes les 60 s, sans signe à l'écran. RevalidateListedObjects vaut vrai par défaut : trafic réseau sans geste.
- **Proposition** : Désactiver par défaut (règle « rien sur le réseau sans geste »). Si on la garde, afficher « Liste vérifiée à 14:32 » et un interrupteur dans la page.
- **Vérification** : partiel. La revalidation est bien active par défaut (RevalidateListedObjects=$true, Domenia-Core.ps1:19761 ; Continuity.UI.ps1:233-250) et se lance sans geste. Mais elle n'est pas « sans signe » : la colonne « Fraîcheur AD » (Core:4723, visible par défaut, Shell.Model.ps1:392-394) affiche « AD revalide » ou « AD mis a jour ». Elle ne tourne que si la fenêtre est active et la page Rechercher affichée (Engine.Model.ps1:515-560), hors démo, et par lots de 24 toutes les 2 s jusqu'à vider la file, puis toutes les 60 s.
- Preuve : `modules/Domenia-Continuity.UI.ps1:178-250, 233 ; Domenia-Core.ps1:19761 (vérifié)`

### SE-14 — Clés de configuration trompeuses
*Impact moyen, effort S*

- **Constat** : 61 clés par défaut ne sont lues par aucun code, dont certaines qui semblent protéger : Security.NeverLogSecretValues, Security.MaskSecretsByDefault, Features.ScopedLocks, UI.ReadOnlyDefault, Async.MinThreads. Un admin peut les croire actives.
- **Proposition** : Les retirer des valeurs par défaut et ajouter un contrôle hors Windows qui échoue si une clé par défaut n'est lue nulle part.
- **Vérification** : partiel. Les clés citées (Security.NeverLogSecretValues/MaskSecretsByDefault, Features.ScopedLocks, UI.ReadOnlyDefault, Async.MinThreads) ne sont lues par aucun code en dehors de New-DefaultConfig (Core:19713-19940). Une recherche par nom en trouve au moins 52. Mais guides/administrateur.md:1163-1165 (« Clés sans effet ») les liste explicitement comme inactives, et le Domenia.config.json livré (9 lignes) ne les contient pas : le risque de tromper un admin se limite aux valeurs par défaut en mémoire.
- Preuve : `administrateur.md ch. 17 et 22 ; Domenia-Core.ps1:19700-19900`

### SE-15 — Le paquet DEV embarque le labo et l'historique
*Impact moyen, effort S*

- **Constat** : build_packages.py emballe tout dev/ hors caches : l'hôte et le compte du labo (degun@192.168.1.173), 16 CORRECTIF-*.md, 20 .patch et 3,7 Mo de wad/docs historiques.
- **Proposition** : Exclure engineering/d120/lab et wad/docs/history du ZIP DEV, ou les livrer à part. Passer l'hôte du labo par variable d'environnement.
- **Vérification** : confirmé. select_members (dev/tools/build_packages.py:44-56) parcourt tout dev/ et n'exclut que __pycache__, .git, backups, wad/data, le dossier de sortie et la préparation. Le manifeste DEV (wad/package-manifest.json:79, 366, 1059…) contient bien engineering/d120/lab/lab.sh (HOST degun@192.168.1.173, ligne 15), les CORRECTIF-*.md (16), les .patch (20) et wad/docs (3,7 Mo).
- Preuve : `dev/tools/build_packages.py:21, 44-46 ; dev/engineering/d120/lab/lab.sh:15-21`

### SE-16 — Mot de passe de connexion manipulé en chaîne
*Impact moyen, effort M*

- **Constat** : La connexion lit [string]PasswordBox.Password ou le TextBox « révélé ». « Afficher » recopie le mot de passe en clair dans un TextBox, qui garde un historique d'annulation. Les « $plainPassword = '' » donnent l'illusion d'un effacement.
- **Proposition** : PSCredential construit depuis SecurePassword. Révélation en superposition en lecture seule masquée après 5 s, sans copie. Retirer les pseudo-effacements et documenter la vraie limite (DirectoryEntry exige une chaîne).
- **Vérification** : partiel. Le mot de passe est bien lu en [string] (Core:25047 : PasswordBox.Password ou TextBox révélé), et « Afficher » le recopie en clair dans TxtLoginPasswordVisible (25136), sans IsUndoEnabled=False (2136/25345). Les « $plainPassword = '' » (1127-1138, 8243-8249) n'effacent pas la chaîne immuable en mémoire. C'est une limite de durcissement propre à PowerShell 5.1/WPF : aucune fuite n'est démontrée. L'exploitation de l'historique d'annulation reste hypothétique, puisque le champ est vidé et masqué (25127, 25101).
- Preuve : `Domenia-Core.ps1:25047, 25124-25137, 1127-1138, 8243-8249`

## Fiabilité (22)

### FI-01 — Erreurs perdues pendant l'affichage d'une erreur
*Impact fort, effort S*

- **Constat** : Le gestionnaire global met HandlingDispatcherException à vrai pendant tout l'affichage, qui est bloquant (PushFrame), alors que les minuteurs tournent. Toute exception levée pendant ce temps est marquée traitée et abandonnée, sans Write-AppLog.
- **Proposition** : Journaliser d'abord, tester le drapeau ensuite. Mettre en file les erreurs arrivées pendant l'affichage et les compter (« 3 autres erreurs »).
- **Vérification** : confirmé. Domenia-Core.ps1:2093-2094 sort avec Handled=$true sans Write-AppLog tant que HandlingDispatcherException est vrai. Or ce drapeau reste levé pendant Show-ErrorBox → Show-DomeniaDialog → Show-DomeniaEmbeddedWindow, qui pompe un PushFrame imbriqué (Domenia-Embedded.UI.ps1:201) où les autres DispatcherTimer continuent de tourner. Seule la première exception est journalisée (Core:2074), les suivantes sont perdues.
- Preuve : `Domenia-Core.ps1:2088-2104 ; modules/Domenia-Embedded.UI.ps1:111, 201`

### FI-02 — Boucle de fenêtres d'erreur avec un minuteur en panne
*Impact fort, effort S*

- **Constat** : L'anti-répétition de 3 s compare une heure prise avant l'affichage à celle enregistrée après fermeture. Les minuteurs sans try (relevé, stockage, validation de compte) relancent la même erreur dès la fermeture. Le moteur écrit aussi une ligne et un Set-Status toutes les 250 ms tant que Complete-UiTasks échoue.
- **Proposition** : Dédoublonner par signature (type, message, source) avec un compteur « même erreur ×12 ». Arrêter le minuteur fautif après 3 échecs, avec un message clair. Limiter à 1 ligne par minute pour une même erreur du moteur.
- **Vérification** : partiel. Deux points sont réels. Le garde de 3 s mémorise $now pris avant l'affichage (Core:2095-2098), donc une fenêtre restée ouverte plus de 3 s ne protège pas l'erreur suivante. Le minuteur moteur écrit aussi une ligne et un Set-Status à chaque tick de 250 ms, sans limitation (Core:21136-21142). En revanche, les minuteurs cités sans try ne peuvent pas boucler (Park.UI:110, Storage.UI:11, Accounts.Async:15) : un DispatcherTimer dont le Tick lève n'est pas réarmé par WPF (Restart est appelé après Tick), si bien qu'il s'arrête en silence après une seule fenêtre, ce qui est un autre défaut (minuteur mort avec IsEnabled toujours vrai).
- Preuve : `Domenia-Core.ps1:2095-2098, 21136-21142 ; modules/Domenia-Park.UI.ps1:110 ; modules/Domenia-Storage.UI.ps1:11 ; modules/Domenia-Accounts.Async.ps1:15`

### FI-03 — Une écriture refusée parce que des lectures traînent
*Impact fort, effort S*

- **Constat** : Test-DomeniaTaskAdmission teste Outstanding >= MaxOutstanding (12) avant la classe : une écriture est refusée (« Limite physique atteinte ») dès que des lectures détachées occupent les places. Le commentaire « A write is never starved » n'est pas tenu.
- **Proposition** : Réserver une place physique aux écritures et une aux actions explicites, hors plafond des lectures. Message : « Des lectures se terminent ; l'écriture partira dans un instant ».
- **Vérification** : confirmé. Test-DomeniaTaskAdmission (Engine.Model.ps1:194-196) rejette toute classe, Write comprise, dès que Outstanding >= MaxOutstanding. Outstanding compte les tâches actives (annulées comprises) plus les lectures détachées (Engine.UI.ps1:47-49), et le cas Write qui ajoute une place (ligne 201) n'est évalué qu'après. Le refus est explicite (« Limite physique atteinte ») mais contredit le commentaire de la ligne 200 et le guide admin l.939 (« canal dédié »).
- Preuve : `modules/Domenia-Engine.Model.ps1:186-210 (vérifié : lignes 194-195 avant le cas Write)`

### FI-04 — Relevés périmés, déplacés ou supprimés comptés dans l'OU
*Impact fort, effort M*

- **Constat** : Les observations sont rattachées par DN, sans croisement avec les postes actifs de l'OU. Un poste déplacé reste compté dans l'ancienne OU ; un poste supprimé alimente encore Présence, disques et requêtes. Le total de présence peut dépasser « Postes actifs ». Un relevé de 3 mois pèse autant que celui du jour.
- **Proposition** : Croiser par GUID avec les postes actifs du périmètre. Écarter les relevés de plus de N jours (30 par défaut). Afficher l'âge (« relevé il y a 3 j ») et griser au-delà de 7 jours, y compris pour le poste.
- **Vérification** : confirmé. Le worker FleetStats lit tout park_session_cache sans jointure avec ad_objects ni contrôle du GUID (Engine.Worker.ps1:155-163), contrairement à ParkTargets qui vérifie le GUID (l.122). Le modèle compte ensuite la présence par DN, sans recouper avec $machines ni filtrer par âge (BoardFleet.Model.ps1:101-118). La table n'est vidée que par une purge manuelle (Cache.Model:402), et Get-DomeniaWidgetResults filtre lui aussi par DN seul (Widgets.UI.ps1:847-857).
- Preuve : `modules/Domenia-BoardFleet.Model.ps1:101-120 ; modules/Domenia-Widgets.UI.ps1:847-857 ; modules/Domenia-Boards.Model.ps1:433`

### FI-05 — Une fabrique unique de minuteurs protégés
*Impact fort, effort M*

- **Constat** : Le code crée 32 DispatcherTimer mais n'en enregistre que 13. Une quinzaine de Tick n'ont aucun try au premier niveau (rendu, LinkProbe, connexion rapide, Charts, Guard, Access).
- **Proposition** : New-DomeniaTimer -Owner -IntervalMs -Tick : enregistrement, try/catch, une ligne de journal par erreur, arrêt au changement d'époque et après N échecs. Migrer tous les minuteurs, en même temps que PF-06.
- **Vérification** : partiel. Les décomptes sont proches : 32 créations de DispatcherTimer, mais 12 enregistrements Register-DomeniaOwnedTimer et non 13. Plusieurs Tick restent sans aucun try, par exemple Charts.UI:172, Guard.UI:188, Park, Storage et Accounts. En revanche, LinkProbe (Core:7598) et connexion rapide (Core:25028/25106) appellent des fonctions dont le corps est entièrement dans un try (Core:7604, 24852), et le rendu de l'arbre a un try par travail (Core:6697).
- Preuve : `modules/Domenia-Engine.UI.ps1:242 ; Domenia-Core.ps1:6692, 7598, 25028, 25106 ; modules/Domenia-Charts.UI.ps1:172 ; modules/Domenia-Guard.UI.ps1:188`

### FI-06 — L'installateur lance des tests sur le poste de production
*Impact fort, effort M*

- **Constat** : INSTALLER-MISE-A-JOUR.ps1 exécute wad/tests/Test-DomeniaPreload.ps1 (WPF, moteur) sur la machine cible, alors que le guide interdit les suites sur un poste de production. Il exige aussi le paquet DEV complet (436 fichiers).
- **Proposition** : Vérifier à la place un rapport de qualification produit en VM et lié au hash du ZIP (release_guard le produit), plus le -CheckOnly de la version préparée. Livrer l'installateur dans le paquet PROD.
- **Vérification** : partiel. L'installateur exécute bien wad\tests\Test-DomeniaPreload.ps1 sur la machine cible avant copie (INSTALLER-MISE-A-JOUR.ps1:232-241) et exige le ZIP DEV. Cela contredit le chapitre 21 (administrateur.md:1326-1328), alors que le chapitre 16 l'annonce comme « porte de tests » (l.988). La suite est toutefois isolée : elle analyse la syntaxe, importe des fonctions, charge le XAML et remplace Start-UiTask par un bouchon (Test-DomeniaPreload.ps1:90). Elle ne lance donc ni le vrai moteur, ni AD, ni wad\data.
- Preuve : `dev/INSTALLER-MISE-A-JOUR.ps1:232-237 (vérifié) ; administrateur.md ch. 16 et 21`

### FI-07 — Code incident pour relier l'écran au journal
*Impact moyen, effort S*

- **Constat** : Show-DomeniaOperationError accepte -CorrelationId, mais aucun des 9 appelants ne le passe. Le support ne retrouve pas la ligne de Domenia.log qui correspond à une capture.
- **Proposition** : Un code court par erreur (« INC-7F3A »), affiché dans le bandeau, écrit dans Domenia.log et dans l'incident Support, avec « Copier pour le support ».
- **Vérification** : confirmé. Aucun appelant de Show-DomeniaOperationError ne passe -CorrelationId. Ils sont environ 45 et non 9 (Core:2085, 2097, 9765, 10215…, Accounts.Async:57, Secrets.UI:108…). Même fourni, l'identifiant ne préfixerait que la ligne du journal (Core:2073-2074) : Show-ErrorBox n'affiche que le texte convivial (Core:2077).
- Preuve : `Domenia-Core.ps1:2070-2079, 9765, 10215, 10496, 10644 ; modules/Domenia-Accounts.Async.ps1:57`

### FI-08 — Avertissements et erreurs écrits dans Domenia.log
*Impact moyen, effort S*

- **Constat** : Set-Status n'écrit que dans le journal à l'écran. Les 191 Set-Status WARN ou ERROR (« Releve impossible »…) disparaissent à la fermeture.
- **Proposition** : Faire passer WARN et ERROR par Write-AppLog, via la file asynchrone de PF-09.
- **Vérification** : confirmé. Set-Status (Core:1708-1724) n'appelle que Add-DomeniaUiLog, qui ajoute la ligne à $script:UiLogLines en mémoire et à TxtUiLog (Core:2159-2232). L'écriture sur disque n'a lieu qu'en repli, si l'affichage échoue (Domenia-ui-log-errors.log). Les incidents de support sont eux aussi en mémoire (Support.UI:47-63), et on compte bien 191 Set-Status WARN/ERROR, par exemple « Releve impossible » (Park.UI:65).
- Preuve : `Domenia-Core.ps1:1708-1724, 2159-2240`

### FI-09 — Retours à la ligne qui cassent Domenia.log
*Impact moyen, effort S*

- **Constat** : Write-AppLog écrit le texte brut dans une ligne à tabulations. Une pile d'exception éclate sur plusieurs lignes, et une valeur AD avec saut de ligne peut fabriquer une fausse ligne.
- **Proposition** : Échapper retour chariot, saut de ligne et tabulation. Pile sur des lignes de continuation préfixées « | », au même horodatage.
- **Vérification** : confirmé. Write-AppLog (Core:17159-17161) concatène le texte brut dans une ligne à tabulations. Protect-DomeniaLogText et Protect-DomeniaSecretText ne retirent ni CR ni LF (Core:181-206, Access.Model:380-396). Or des appelants passent Exception.ToString(), qui contient la pile (Core:21139 ; Technical en Core:2011 via 2074), alors que la trace de démarrage, elle, nettoie [\r\n\t] (Core:362).
- Preuve : `Domenia-Core.ps1:17159, 362, 21139`

### FI-10 — Journal perdu si le dossier de données est refusé
*Impact moyen, effort S*

- **Constat** : Write-AppLog avale toute erreur d'Initialize-DomeniaDataStore : rien n'est écrit, sans signe, alors que la trace de connexion se replie sur LOCALAPPDATA puis TEMP.
- **Proposition** : Même chaîne de repli pour Domenia.log et pastille « Journal indisponible » dans le pied du journal.
- **Vérification** : partiel. Le catch vide de Write-AppLog (Core:17145-17163) avale bien toute erreur d'écriture de Domenia.log, sans repli ni signal ; le texte va seulement au journal à l'écran (Core:17137). Mais un dossier de données refusé au démarrage est fatal (Core:25769) : le catch global écrit la trace de démarrage et Domenia-login.log en repli LOCALAPPDATA/TEMP puis affiche un message (Core:25846-25869). Une fois validé, Initialize-DomeniaDataStore revient tout de suite (Core:19942). La perte silencieuse ne concerne donc que les échecs d'écriture en cours de session (verrou, disque plein, ACL).
- Preuve : `Domenia-Core.ps1:17145-17163, 19954-19970 ; administrateur.md ch. 20`

### FI-11 — Annulation de widget effacée par un recalcul de fond
*Impact moyen, effort S*

- **Constat** : Toute nouvelle donnée efface l'annulation, qui n'a qu'un niveau. Sur l'Accueil, un recalcul automatique peut retirer « Annuler » quelques secondes après un retrait par erreur.
- **Proposition** : Séparer l'annulation de la disposition des données. Pile d'une dizaine d'étapes et Ctrl+Z. Effacement seulement au changement d'objet, pour le poste.
- **Vérification** : confirmé. Show-DomeniaBoard remet UndoLayout et UndoText à zéro dès qu'un -Data est fourni (Widgets.UI.ps1:76), et l'annulation n'a qu'un niveau (l.52). Sur l'Accueil, un IndexBulk enregistré en arrière-plan (Storage.UI:241) ou une purge (Storage.UI:583) appelle Request-DomeniaFleetRefresh -Force. Celui-ci relance FleetStats, puis Show-DomeniaBoard -Board Fleet -Data $board (Dashboard.UI.ps1:190), ce qui retire « Annuler ».
- Aussi proposé par le Spark (idée 65).
- Preuve : `modules/Domenia-Widgets.UI.ps1:52, 76 ; modules/Domenia-Dashboard.UI.ps1:190 ; modules/Domenia-Storage.UI.ps1:241, 583`

### FI-12 — Délai d'attente SQLite figé à 300 ms dans les workers
*Impact moyen, effort S*

- **Constat** : L'interface lit DatabaseBusyTimeoutMs (2500 dans la configuration), mais les workers codent 300 ms et LocalIndexRead 250 ms. Pendant un checkpoint WAL, SQLITE_BUSY arrive vite, et trois échecs suspendent les sauvegardes.
- **Proposition** : Passer la valeur configurée dans le contexte, l'utiliser partout, aligner le défaut du code sur celui documenté et compter les SQLITE_BUSY.
- **Vérification** : partiel. Les 300 ms codés en dur sont bien là et ignorent la configuration (Storage.Worker.ps1:45/389/595/813, Live.Model.ps1:340, Migration.Worker.ps1:51), et trois échecs suspendent bien le writer (Storage.UI.ps1:267-269). Mais Storage.UI.ps1:124 ne lance aucun job de persistance tant qu'un autre écrivain local tourne (LocalStore, LiveCache, IndexBuild, StoragePurge, LegacyMigration). Aucun checkpoint explicite n'existe (aucun wal_checkpoint) et le 2500 n'est qu'une valeur par défaut générée (Core:19934, repli 1000 en Core:20300, absente de Domenia.config.json) : le déclencheur « checkpoint WAL » n'est pas établi.
- Preuve : `modules/Domenia-Storage.Worker.ps1:45, 389, 595, 813 ; modules/Domenia-Live.Model.ps1:340 ; modules/Domenia-Migration.Worker.ps1:51 ; Domenia-Core.ps1:19934, 20300`

### FI-13 — Sauvegarde avant les gestes qui modifient la base
*Impact moyen, effort S*

- **Constat** : Seule une migration de schéma déclenche une sauvegarde. « Mettre à jour tout », l'import CSV, « Nettoyer » et « Oublier les relevés » modifient la base sans copie.
- **Proposition** : Lancer le worker StorageBackup existant avant ces 4 gestes, dans la rotation de 7 copies, et le dire dans la confirmation.
- **Vérification** : partiel. Seule la migration appelle Backup-DomeniaDatabase (Core:20475, Migration.UI.ps1:197). Les autres gestes n'ont pas de copie automatique, mais le risque est plus étroit qu'annoncé : l'import CSV ne fait qu'ajouter et ignore les postes déjà liés (Core:7865). « Mettre à jour tout » reconstruit depuis l'AD après confirmation de l'impact (Core:15299-15300). « Nettoyer » et « Oublier les relevés » demandent une confirmation et ne touchent que des liens automatiques ou des relevés réobtenables (Core:18120, 19502). La purge passe par une simulation avec empreinte, et une sauvegarde manuelle existe (Storage.UI.ps1:621).
- Preuve : `Domenia-Core.ps1:15296-15320, 7829, 18090, 19501-19507`

### FI-14 — Plafond de 100 fichiers au démarrage
*Impact moyen, effort S*

- **Constat** : Domenia-Start refuse de démarrer au-delà de 100 fichiers runtime. Le manifeste en compte déjà 82 : l'extraction du cœur (CD-01) fera franchir le plafond.
- **Proposition** : Monter la borne (250) ou la lire dans release-contract.json, avec un test qui alerte à 80 %.
- **Vérification** : partiel. La borne existe (Domenia-Start.ps1:22 : plus de 100 entrées runtime donnent « Liste du runtime invalide »), mais le manifeste actuel n'en déclare que 82 (package-manifest.json). Aucun défaut aujourd'hui : c'est un risque futur, qui dépend du nombre de fichiers que produira CD-01.
- Preuve : `Domenia-Start.ps1:21-22 ; package-manifest.json`

### FI-15 — Erreur locale prise pour un refus de compte (à confirmer en VM)
*Impact moyen, effort S*

- **Constat** : Show-ErrorBox et chaque Set-Status WARN ou ERROR appellent Request-DomeniaAccessRecovery. Sans tâche courante, le contrôle des besoins est sauté : un accès refusé à un fichier pourrait proposer de changer de compte AD.
- **Proposition** : Proposer la reprise de compte seulement si l'erreur vient d'une tâche dont l'opération exige un compte (Get-DomeniaOperationCredentialNeeds).
- **Vérification** : confirmé. Sans job courant ni OperationId, le contrôle des besoins est sauté (Access.UI.ps1:165-169). Le repli texte de Guard.Model.ps1:30 (`access.*denied|acc[eè]s.*refus`) classe « Access to the path … is denied » en AccessDenied, avec la portée « Directory ». Exemple : un import CSV refusé (Core:7903) n'affiche pas son erreur, car Show-ErrorBox sort à Core:1997. Le minuteur (Access.UI.ps1:546) propose alors « Utiliser un autre compte ? », qui mène à Start-DomeniaAccountRelogin (Access.UI.ps1:338-341). Set-Status WARN/ERROR ajoute de son côté une entrée au badge d'accès (Core:1713-1715).
- Preuve : `Domenia-Core.ps1:1713-1715, 1995-1997 ; modules/Domenia-Access.UI.ps1:145-160`

### FI-16 — Ne plus déduire l'état du texte affiché
*Impact moyen, effort M*

- **Constat** : La raison de désactivation est retrouvée par regex sur des préfixes non accentués (« Desactive|Droit indetermine… »). La couleur de présence dépend du libellé (« Sans réponse au ping* ») alors que la grille affiche « Sans reponse ». Corriger les accents casserait l'un et l'autre.
- **Proposition** : Porter état et raison dans des propriétés dédiées, lues par la couleur et l'aide. Prérequis de UI-04.
- **Vérification** : partiel. La regex sans accents ne sert qu'à ajouter la raison à l'aide contextuelle (UX.UI.ps1:57-60) ; l'état désactivé n'est pas déduit du texte, et les infobulles actuelles sont bien sans accents (Core:22469-22475). La couleur de présence n'est appliquée qu'aux fiches, dont le libellé vient de Live.Model.ps1:119 (« Sans réponse au ping »), et la grille renvoie le même libellé accentué (Core:2380). « Sans reponse » est une catégorie du tableau du parc, avec sa propre table de couleurs (BoardFleet.Model.ps1:167-170). Il y a donc une fragilité latente, pas de décalage actuel.
- Preuve : `modules/Domenia-UX.UI.ps1:57-60 ; Domenia-Core.ps1:2342-2354 ; recherche.png`

### FI-17 — Requêtes WMI des widgets à fiabiliser
*Impact moyen, effort M*

- **Constat** : Win32_DesktopMonitor sous-compte les écrans. Vitesse du lien et carte connectée incluent VPN et Hyper-V. Le Wi-Fi est reconnu par le nom « %Wi%Fi% ». Win32_LogonSession type 2 compte DWM et UMFD. PCSystemType 8 veut dire « Maximum ». Win32_UserAccount sur un contrôleur énumère l'annuaire. Win32_NTLogEvent est très lent.
- **Proposition** : WmiMonitorID (root/wmi), PhysicalAdapter=TRUE, MSFT_NetAdapter NdisPhysicalMedium=9, exclure DWM et UMFD, PCSystemTypeEx, ignorer les contrôleurs (ProductType 2) pour les comptes locaux, requêtes lentes signalées dans l'éditeur.
- **Vérification** : confirmé. Le catalogue (Probes.Model.ps1:17-60) utilise bien Win32_DesktopMonitor (sous-compte connu), Win32_NetworkAdapter avec NetConnectionStatus=2 sans PhysicalAdapter (adaptateurs VPN et vEthernet inclus), le nom LIKE '%Wi%Fi%' (manque par exemple « Wireless-AC »), LogonType=2 (inclut DWM et UMFD) et PCSystemType 8 mappé à « Tablette » alors que 8 = Maximum. S'y ajoutent Win32_UserAccount LocalAccount=TRUE (énumère l'annuaire sur un DC) et Win32_NTLogEvent. Seule nuance : la lenteur de NTLogEvent est bornée par OperationTimeoutSec ≥ 10 s (Live.Model.ps1:237), ce qui donne un échec et pas un blocage.
- Preuve : `modules/Domenia-Probes.Model.ps1:17, 19, 38, 41-42, 46, 58-60`

### FI-18 — Un relevé par page, pas un seul partagé
*Impact moyen, effort M*

- **Constat** : $script:ParkRun est unique : « Analyser la liste » et les requêtes du poste se le partagent. Lancer l'un pendant l'autre donne « Un releve est deja en cours. » dans le seul journal, et la progression s'affiche sur Rechercher même depuis le poste.
- **Proposition** : Un relevé par portée (Liste, Poste) ou une file pour la demande du poste. État et « Arrêter » à côté du bouton qui a lancé.
- **Vérification** : confirmé. Un seul $script:ParkRun ; un second lancement lève « Un releve est deja en cours. », qui finit dans Set-Status WARN, c'est-à-dire le seul journal (Park.UI.ps1:42 et 65, Core:1708-1713). Les boutons ne sont pas désactivés (Park.UI.ps1:28-31). Depuis la fiche, ScopeTargets force DisplayedResults, donc Scope='Results' (Park.UI.ps1:52 et 59), et la progression s'écrit dans LblLiveState de Rechercher (Park.UI.ps1:26).
- Preuve : `modules/Domenia-Park.UI.ps1:42, 59, 150 ; modules/Domenia-Widgets.UI.ps1:877-890`

### FI-19 — Lectures SQLite restantes sur l'interface
*Impact moyen, effort M*

- **Constat** : La dette mesurée garde 711 chemins « Stockage » depuis l'interface : Load-DomeniaIndexMetadata, Load-UserMachineLinks, Load-DomeniaParkState, Get-DomeniaSecretIndexEntry, Get-DomeniaParkCoverage lisent encore la base sur le Dispatcher.
- **Proposition** : Les faire passer par de nouvelles actions LocalIndexRead avec rappels. Objectif : zéro entrée « Stockage » dans la dette.
- **Vérification** : confirmé. La dette de référence totalise bien 711 occurrences « Stockage » (477 clés, ui-blocking-debt-baseline.json). Load-DomeniaIndexMetadata, Load-UserMachineLinks, Load-DomeniaParkState, Get-DomeniaSecretIndexEntry et Get-DomeniaParkCoverage lisent SQLite de façon synchrone (Core:14102, 20862, 14961, 15596, 15036). Ces fonctions sont appelées depuis des gestionnaires du Dispatcher (par exemple Core:15266 dans Complete-DomeniaIndexBuildUi, Core:19182-19183, Core:15617). Nuance : le chiffre 711 compte aussi Initialize, Backup, Close et Get-DomeniaDatabasePath, pas seulement des lectures.
- Preuve : `dev/tools/ui-blocking-baseline.json ; dev/tools/ui-blocking-debt-baseline.json ; modules/Domenia-Engine.Worker.ps1:9`

### FI-20 — Supprimer les attentes actives (démarrage, déplacement)
*Impact moyen, effort M*

- **Constat** : Le préchargement boucle sur Complete-UiTasks, DoEvents, PushFrame et Start-Sleep 35 ms (jusqu'à 2×50 s si le contrôleur ne répond pas). Move-DomeniaSelectedComputerWithOuPicker attend 3 s en boucle que la fiche charge, puis échoue. Risque de réentrance.
- **Proposition** : Rappels de fin de tâche au lieu de boucles. Retirer l'option RequireReadyBeforeMainWindow. Construire le plan de déplacement depuis le DN et le GUID de la ligne. « Continuer sans cache » après 10 s.
- **Vérification** : partiel. La boucle de préchargement (Core:24305-24310 et 24329), avec ses jusqu'à 2×50 s, ne s'exécute pas par défaut : RequireReadyBeforeMainWindow vaut $false (Core:19828), ce qui fait un retour immédiat (Core:24244-24248), et cette clé est absente de Domenia.config.json. La boucle de déplacement est bien active (Core:7794-7804). Elle reste bornée à 3 s après le sélecteur modal, pendant lequel la fiche charge, et échoue sans aucune écriture ; le risque de réentrance via DoEvents/PushFrame (Core:1672-1687) est réel mais limité à ce chemin.
- Preuve : `Domenia-Core.ps1:1672-1692, 24233-24240, 24295-24330, 7794-7804`

### FI-21 — « Relire l'objet » vide tout le cache
*Impact faible, effort S*

- **Constat** : Refresh-SelectedObject vide tout le cache des fiches puis relance la liste entière, pour un seul objet.
- **Proposition** : Invalider seulement les clés du GUID (logique déjà écrite dans Invoke-DomeniaObjectChanges), sans relancer la liste.
- **Vérification** : confirmé. Refresh-SelectedObject, appelé seulement par le menu « Relire l objet depuis AD » (Core:12894), vide tout $script:VisitCache, rouvre l'objet avec -Force et relance Load-BranchObjects (Core:16666-16671). Le flux de continuité invalide au contraire seulement les entrées de l'objet, par GUID (Continuity.UI.ps1:198-212). Impact : performances seulement ; la liste n'est rechargée que si SelectedBranchDn est renseigné.
- Preuve : `Domenia-Core.ps1:16666-16671 ; modules/Domenia-Continuity.UI.ps1:178-215`

### FI-22 — Erreur fatale annoncée comme « initialisation »
*Impact faible, effort S*

- **Constat** : Le try principal englobe ShowDialog() : une exception en pleine session affiche « DOMENIA na pas pu terminer son initialisation. », sans apostrophe.
- **Proposition** : Distinguer avant et après affichage. Après : « Domenia s'est arrêté de façon inattendue », avec code incident et chemins des journaux.
- **Vérification** : partiel. ShowDialog() est bien dans le try principal et le message est bien « DOMENIA na pas pu terminer son initialisation », sans apostrophe (Core:25842 et 25862). Mais Initialize-Window enregistre un gestionnaire Dispatcher.UnhandledException qui met Handled=$true pour toute exception (Core:2090-2101, enregistré en Core:24362). Une exception en pleine session sur le Dispatcher n'atteint donc normalement pas ce catch : seuls des cas résiduels hors Dispatcher afficheraient le message trompeur.
- Preuve : `Domenia-Core.ps1:25844-25873`

## Interface (31)

### UI-01 — Afficher l'objet en cours près du titre et dans la fenêtre
*Impact fort, effort S*

- **Constat** : L'objet sélectionné n'est rappelé que dans le panneau d'aide, souvent fermé. Get-DomeniaPageTitle (« Fiche · Jean Dupont ») est écrit et testé, mais seuls les tests l'appellent. Le titre de la fenêtre reste « Domenia 1.0 ».
- **Proposition** : Brancher Get-DomeniaPageTitle : une puce « Poste · PC-COMPTA-014 » près du titre de page, avec ✕ pour désélectionner, et un titre de fenêtre « Fiche · Camille Martin — Domenia » (utile avec Alt+Tab). Accentuer au passage « Aucune selection » dans le modèle.
- Preuve : `modules/Domenia-Shell.Model.ps1:79-106 ; tests/rules/Shell.Tests.ps1:4-20 (seuls appelants, vérifié) ; Domenia-Core.ps1:8206, 6229`

### UI-02 — Erreur interne : ne plus montrer le message .NET brut
*Impact fort, effort S*

- **Constat** : Pour une erreur non reconnue, l'écran affiche « $Operation : $message », par exemple « Erreur interne de l'interface : Impossible d'appeler une méthode dans une expression Null ». Le texte fixe n'a pas d'accents (« Le detail technique a ete enregistre »).
- **Proposition** : Afficher « Un affichage n'a pas pu se mettre à jour. Votre travail est conservé. » avec le code incident (FI-07). Le texte technique va au journal et au profil Expert.
- Preuve : `Domenia-Core.ps1:2064, 2076, 2097`

### UI-03 — En-tête de l'Accueil plus sobre
*Impact fort, effort S*

- **Constat** : La carte empile deux phrases d'instructions (« Parc incomplet ? Outils, Base autonome, Mettre a jour tout. », « Pour pinger, détecter… »), un bouton Actualiser presque inutile puisque le calcul est automatique, et deux dates qui ne concordent pas (calcul 12:24, analyse 12:04). La section « Vue d ensemble » répète le titre. « Postes actifs » côtoie « Postes inactifs », qui en sont une partie.
- **Proposition** : Une ligne d'état : « Postes › Lyon · 26 postes · base à jour il y a 5 min », avec un fil d'OU cliquable, une petite icône d'actualisation et un seul lien « Analyser ces postes dans Rechercher ». Renommer la première section « Santé ». Remplacer « actifs / inactifs » par « Postes » et « Sans connexion depuis 90 j ».
- Aussi proposé par le Spark (idée 38).
- Preuve : `accueil.png ; modules/Domenia-BoardFleet.Model.ps1:136, 239 ; modules/Domenia-Dashboard.UI.ps1:194 ; Domenia-Core.ps1:4429-4441 ; modules/Domenia-Boards.Model.ps1:54-55`

### UI-04 — Passe complète : accents, apostrophes, vouvoiement
*Impact fort, effort M*

- **Constat** : Sur 263 messages Set-Status, 29 seulement sont accentués. Environ 650 lignes ont « d » ou « l » sans apostrophe. Tutoiement et vouvoiement se mélangent : « Selectionne un » (21 fois), « Tu vas activer le mode ecriture », « Saisis au moins ». Ces défauts se voient partout : « Etat », « Derniere connexion », « Detecter l utilisateur », « Vue d ensemble », « point(s) a verifier », « Mettre a jour tout », « lidentifiant », « DOMENIA na pas pu », et les messages du moteur (« File d attente pleine », « Timeout apres 45s »). Get-DomeniaStatusGlyph écrit « A verifier » alors que le JSON écrit « À vérifier ».
- **Proposition** : Faire une seule passe : accents, apostrophe ʼ (U+02BC, règle du dépôt), vouvoiement, pluriels gérés par une fonction (elle existe déjà dans BoardSoftware) et « Domenia » au lieu de « DOMENIA ». Trois précautions. D'abord, sortir les états des libellés (FI-16) et repérer les colonnes par x:Name ou Tag. Ensuite, ajouter dans ConvertTo-DomeniaBoardLayout une table ancien nom → nouveau nom de section, sinon les sections enregistrées se dédoublent. Enfin, mettre à jour les tests qui figent ces chaînes. Le contrôle automatique est TE-01.
- Preuve : `Domenia-Core.ps1:4431, 4741-4746, 5476-5478, 9738, 9833, 19628, 21344, 25350, 25864 ; modules/Domenia-Boards.Model.ps1:8-79 ; modules/Domenia-Widgets.UI.ps1:141-150 ; modules/Domenia-Engine.Model.ps1:192-209 ; modules/Domenia-Shell.Model.ps1:1062-1067 ; Domenia-UX.help.json ; toutes les captures`

### UI-05 — Barre de recherche écrasée en demi-écran
*Impact fort, effort M*

- **Constat** : À droite du bandeau, environ 526 px sont fixes : flèches, Accès, Opérations, Ctrl+K, thème, « ? ». À 960 px de large, la zone de saisie tombe à quelques dizaines de pixels. Le menu ne se replie que si la fenêtre est aussi courte (moins de 940). Or le demi-écran à côté de l'outil de tickets est un usage courant.
- **Proposition** : Sous 1280 px de large, replier le menu automatiquement, sans toucher la préférence enregistrée. Passer les boutons en icônes (DS-01). Garantir au moins 280 px à la recherche.
- Preuve : `Domenia-Core.ps1:4155, 4276-4303 ; modules/Domenia-UX.UI.ps1:230`

### UI-06 — Groupes et appartenances listés en DN
*Impact fort, effort M*

- **Constat** : LstGroupMembers et LstMemberOf affichent des DN complets, en Consolas 12. Pour ajouter un membre, il faut taper son DN dans un champ de 520 px. Il n'y a ni filtre, ni type, ni compteur.
- **Proposition** : Une grille Nom / Type (icône) / OU, avec un filtre local et un compteur. L'ajout passe par une recherche ciblée par nom. Ajouter « Pourquoi membre ? », qui s'appuie sur Find-DomeniaMembershipPath pour les groupes imbriqués.
- Preuve : `Domenia-Core.ps1:5063-5070, 5095 ; modules/Domenia-Directory.Model.ps1:312`

### UI-07 — Onglet Actions du poste en cartes
*Impact fort, effort M*

- **Constat** : Douze boutons sont alignés en vrac. Activer et Désactiver s'affichent tous les deux. Redémarrer (rouge) touche « Actualiser les stratégies ». Viennent ensuite les champs Renommer et Groupe, puis un paragraphe technique. La moitié de la page reste vide.
- **Proposition** : Quatre cartes avec icônes : Se connecter (Bureau à distance, C$, consoles), Vérifier (Ping, Diagnostic), Intervenir (Stratégies, Exécuter, et Redémarrer isolé), Compte AD (un seul bouton Activer ou Désactiver selon l'état, Groupes). Supprimer le paragraphe.
- Preuve : `Domenia-Core.ps1:5509-5549 ; actions-poste.png`

### UI-08 — Logiciels : la liste est écrasée par les graphiques
*Impact fort, effort M*

- **Constat** : La synthèse en graphiques est ouverte par défaut et le détail par portée prend 150 px. La grille ne montre qu'environ 4 lignes, avec un défilement horizontal. Les colonnes Désinstallation, Source et Emplacement encombrent, et deux lignes d'état décrivent la même liste.
- **Proposition** : Un sélecteur « Liste | Synthèse », sur Liste par défaut. Le détail par portée tient en une ligne. Les colonnes techniques passent derrière un bouton « Colonnes ». Une seule ligne d'état.
- Preuve : `Domenia-Core.ps1:5709, 5740-5763 ; logiciels.png`

### UI-09 — Relations : trois niveaux d'onglets et en-tête chargé
*Impact fort, effort M*

- **Constat** : Pour associer, il faut passer par Relations > Associer > Détecter ou Rechercher : des onglets dans des onglets. L'en-tête fait 6 lignes : deux avertissements, une consigne et deux statuts (« Cache conserve ; detection uniquement sur demande. »).
- **Proposition** : Deux zones. À gauche, les associations du sujet. À droite, un panneau « Ajouter » avec un sélecteur Détecter | Rechercher. Un seul statut, et les avertissements derrière un « ? ».
- Preuve : `Domenia-Core.ps1:5275-5283, 5317-5326, 5360`

### UI-10 — Moins d'infobulles, et jamais sur un conteneur
*Impact moyen, effort S*

- **Constat** : WorkspaceTabs et TxtUiLog portent une infobulle. WPF la remonte : elle apparaît au survol de tout fond de page ou du journal. Des styles posent aussi une infobulle générique sur chaque ligne de grille, chaque en-tête, chaque nœud et chaque entrée de menu (« Action du menu. Vérifiez la sélection… »), et elle reste 20 s.
- **Proposition** : Aucune infobulle sur les conteneurs ni dans les styles. Une infobulle d'une ligne pour les boutons-icônes. Les explications vont dans le panneau d'aide.
- Preuve : `Domenia-Core.ps1:4356, 6334, 3855, 3866, 3960, 4150 ; modules/Domenia-UX.UI.ps1:85-89 ; Domenia-UX.help.json`

### UI-11 — Panneau d'aide : l'utile en premier, fermé au départ
*Impact moyen, effort S*

- **Constat** : La carte « À quoi sert cet élément ? » n'arrive qu'en 3e position, souvent sous la ligne de flottaison. Avant elle viennent « Contexte de travail », une phrase de réassurance et des étapes statiques. Le panneau est ouvert au premier lancement et prend 300 px : sur 1366 px de large, il reste environ 800 px.
- **Proposition** : Mettre la carte contextuelle en tête, puis un lien vers le chapitre du guide. Supprimer les étapes statiques et la réassurance. Fermer le panneau par défaut, avec une pastille sur « ? » au premier lancement.
- Preuve : `Domenia-Core.ps1:6213-6300 ; modules/Domenia-UX.UI.ps1:444, 488-500`

### UI-12 — Noms accessibles = libellés visibles
*Impact moyen, effort S*

- **Constat** : Initialize-DomeniaUxControlHelp remplace le nom accessible par le titre du catalogue. Le lecteur d'écran annonce « Protection des modifications » pour « Lecture seule », « Autre compte » pour « Accès ». Six contrôles s'appellent « Mot de passe » : TxtUserPwdLastSet, ChkPwdNeverExpires, ChkPwdNotRequired, ChkReversiblePwd, BtnUserResetPwd, BtnExpirePwdNow.
- **Proposition** : Le nom accessible reprend le libellé visible (WCAG 2.5.3), et le titre du catalogue va dans HelpText. Ajouter un test : le libellé visible doit figurer dans le nom, sans doublon dans un même onglet.
- Preuve : `modules/Domenia-UX.UI.ps1:90 ; Domenia-Core.ps1:4872-4873, 4986-4996, 5017 ; Domenia-UX.help.json`

### UI-13 — Annoncer la page et les messages au lecteur d'écran
*Impact moyen, effort S*

- **Constat** : La rubrique active n'est signalée que visuellement (Tag 'Active'). Dans la fenêtre principale, aucune zone n'est annoncée : seule la connexion utilise LiveSetting.
- **Proposition** : Mettre ItemStatus « Page actuelle » sur la rubrique active, et LiveSetting=Polite sur le titre de page, la dernière ligne du journal et l'état d'écriture.
- Preuve : `modules/Domenia-UX.UI.ps1:158 ; Domenia-Core.ps1:25283, 25311`

### UI-14 — Éditeur de widget : jargon WMI et boutons en double
*Impact moyen, effort S*

- **Constat** : Une requête est décrite par « Win32_LogicalDisk (root\cimv2) », dans une section « Requetes WMI · ». Le badge dit « affiche ». Rien ne prévient que la requête interrogera le poste. Le panneau a « Fermer » en haut et « Annuler » en bas.
- **Proposition** : Décrire en clair : « Lu sur le poste, à la demande », avec la classe en infobulle. Badges « Déjà affiché » et « Interroge le poste ». Garder seulement Annuler et Ajouter. Présenter les représentations en vignettes cliquables.
- Aussi proposé par le Spark (idée 58).
- Preuve : `editeur-widget.png ; modules/Domenia-Widgets.UI.ps1:590, 596 ; modules/Domenia-Embedded.UI.ps1:132`

### UI-15 — États vides : un seul, en trois variantes
*Impact moyen, effort S*

- **Constat** : Deux bordures d'état vide s'empilent. Pendant « Recherche en cours… », on lit « Aucun résultat affiché ». Quand le filtre local masque tout, le message propose de « lancer une recherche ».
- **Proposition** : Un seul état vide, en trois variantes : chargement (lignes fantômes), aucun résultat (avec la puce « contient » de FO-01), tout masqué par un filtre (bouton « Effacer le filtre »).
- Aussi proposé par le Spark (idée 16, 86).
- Preuve : `Domenia-Core.ps1:4124-4135, 4750, 4757-4759`

### UI-16 — Arbre des OU : conteneurs système et faux chevrons
*Impact moyen, effort S*

- **Constat** : L'arbre montre tous les conteneurs : System, Program Data, ForeignSecurityPrincipals, LostAndFound… Chaque nœud reçoit un faux enfant « Chargement... », donc un chevron, même sans sous-OU. Un nœud en chargement est grisé.
- **Proposition** : Regrouper les conteneurs système dans un nœud replié « Conteneurs système », en gardant Users et Computers visibles. Retirer le chevron d'un nœud chargé sans enfant. Remplacer le grisé par une petite roue.
- Preuve : `Domenia-Core.ps1:6666, 6745, 9569`

### UI-17 — Association utilisateur-poste en une ligne
*Impact moyen, effort S*

- **Constat** : L'association occupe 4 champs : Utilisateur associé, Source (« Console observee »), Qualification (« Observe ») et Détecté le. Dans la barre Actions, Détecter, Ouvrir et Enregistrer sont au même niveau.
- **Proposition** : Une seule ligne avec badge : « Camille Martin · vue en console le 08/10 à 08:15 [Ouvrir la fiche] [Détecter à nouveau] ». L'enregistrement passe par le mode édition (UX-13).
- Preuve : `Domenia-Core.ps1:5463-5486 ; fiche-poste.png`

### UI-18 — Reçus : états et opérations en clair
*Impact moyen, effort S*

- **Constat** : DgGuardReceipts affiche l'état brut (Prepared, Verified, Reviewed, Delivered, NotSent), le code de l'opération (WriteUnlock…) et le DN comme cible. La revue exige de 12 à 240 caractères, dans une fenêtre.
- **Proposition** : Libellés français (« Envoyée, à vérifier », « Vérifiée », « Revue manuelle »), nom lisible de l'opération et de l'objet, DN en infobulle. Puce pastel par état. Revue dans un champ de la page.
- Preuve : `modules/Domenia-Receipts.Worker.ps1:76-119 ; Domenia-Core.ps1:5949-5951 ; modules/Domenia-Guard.UI.ps1:45-60`

### UI-19 — Emplacement de la base : un résumé, pas un chemin
*Impact moyen, effort S*

- **Constat** : Le champ affiche C:\Users\…\Domains\716ab6f3adb11ba326cf…\Domenia.db, et une 2e ligne répète le chemin des sauvegardes.
- **Proposition** : « Base du domaine example.local · 4,2 Mo · sauvegardée il y a 2 h », avec « Copier le chemin » et le chemin complet en infobulle. Alerte douce si la dernière sauvegarde date de plus de 7 jours.
- Aussi proposé par le Spark (idée 73).
- Preuve : `base-autonome.png ; modules/Domenia-Storage.UI.ps1:604-615`

### UI-20 — Connexion : erreurs claires, sans code AD
*Impact moyen, effort S*

- **Constat** : Les erreurs sont tutoyées, sans accents, avec des codes : « Ce compte est verrouille (code AD 775). Arrete les essais et verifie son etat. », « Acces refuse par AD. Consulte le diagnostic. ».
- **Proposition** : Messages accentués, vouvoyés, avec une action concrète : « Compte verrouillé. Demandez son déverrouillage puis réessayez. ». Le code AD ne figure que dans « Copier le diagnostic ».
- Preuve : `Domenia-Core.ps1:17311-17321, 24805-24823, 24883`

### UI-21 — Glossaire d'interface : remplacer le jargon visible
*Impact moyen, effort M*

- **Constat** : Les techniciens lisent des termes techniques : « Etat moteur », « workers », « Pinger », « Console au clic », « Voir le chemin LDAP », « Fraîcheur AD », « Source lien », « Attribut managedBy », « Donnees lues par CIM », « CIM/DCOM », « ICMP », « … en 123 ms sur dc01 », « Self-check termine », des préfixes « OU » et « CN » dans l'arbre. Comptes affiche « POSTES / WMI / DISTANT », « TRANSPORTS UTILISES » et « Les trois scopes sont independants ». Les messages du moteur parlent de « Limite physique atteinte », « Callback UI », « ETAT INCONNU ».
- **Proposition** : Rédiger un glossaire court et l'appliquer. Ping devient « Tester la réponse », Console « Utilisateur connecté », managedBy « Responsable indiqué dans l'annuaire », et on écrit « Emplacement », « Vérifié à l'instant ». Les titres passent en casse normale (« Annuaire », « Postes », « Clés BitLocker et LAPS »). Une lecture en attente devient « Lecture en attente : elle partira dès qu'une place se libère. ». DN, durées en ms, nom du serveur et transports restent pour le journal et le profil Expert. Ajouter des icônes dossier et conteneur dans l'arbre.
- Aussi proposé par le Spark (idée 58).
- Preuve : `Domenia-Core.ps1:6318, 6680, 6703, 9735, 9738, 10479, 10638, 11112, 5170, 5190, 5240-5250, 21515-21525 ; modules/Domenia-BoardComputer.UI.ps1:17-18, 52, 156, 360 ; modules/Domenia-Search.Model.ps1:204-207 ; modules/Domenia-Park.UI.ps1:88 ; modules/Domenia-Engine.Model.ps1:251-271, 454 ; tableau-poste.png`

### UI-22 — Journal de session lisible pour un technicien
*Impact moyen, effort M*

- **Constat** : Les lignes suivent le format « 12:04:31.512 [INFO] [Statut] … », en Consolas 11, avec des millisecondes, des noms de DC et des « workers ». Aucune couleur par niveau, aucun filtre. En Essentiel, le bouton « Etat moteur » est visible, et « Copier » ne masque pas les noms internes.
- **Proposition** : En Essentiel, vue lisible par défaut : heure HH:mm, icône ✓ ⚠ ✕, phrase, couleur par niveau, filtre « Erreurs seulement ». « Copier » propose de masquer les noms. Le format brut et « État du moteur » restent en Expert.
- Preuve : `Domenia-Core.ps1:2178-2184, 6315-6334, 15830 ; base-autonome.png ; accueil.png`

### UI-23 — Un seul bouton pour la lecture graduée de la liste
*Impact moyen, effort M*

- **Constat** : Pinger, Détecter et Analyser la liste sont trois niveaux d'une même lecture, chacun avec sa confirmation. « Détecter » ne dit pas ce qui est détecté, et son bouton bleu concurrence « Rechercher ».
- **Proposition** : Un bouton « Vérifier la liste ▾ » avec trois choix : « Qui répond ? », « Qui est connecté ? », « Matériel et widgets ». Le dernier choix fait devient l'action par défaut. Un seul bouton principal par zone.
- Preuve : `Domenia-Core.ps1:4695-4698 ; recherche-actions.png`

### UI-24 — Mode Personnaliser plus léger
*Impact moyen, effort M*

- **Constat** : Chaque carte porte deux boutons ronds qui débordent du coin. La tuile « Ajouter ici » crée une ligne orpheline. « Ajouter un widget » et « Personnaliser » restent affichés en permanence. Retirer apparaît au simple survol, même hors personnalisation.
- **Proposition** : Hors édition, un seul bouton discret « Modifier ». En édition : un badge « – » par carte, un clic sur la carte pour la modifier, et un « + » dans l'en-tête de section. Plus aucun retrait au survol hors édition.
- Preuve : `personnaliser.png ; modules/Domenia-Widgets.UI.ps1:198-205, 225-262, 464-479`

### UI-25 — Widgets : clavier et lecteur d'écran
*Impact moyen, effort M*

- **Constat** : Chaque widget compte deux arrêts de tabulation (Modifier, Retirer), soit environ 84 sur le tableau du poste. Le nom accessible ne donne que le titre, sans la valeur ni l'état.
- **Proposition** : Un arrêt par widget. Les flèches passent d'un widget à l'autre, Ctrl+←/→ déplace, Suppr retire en édition, Entrée ouvre la modification. Nom accessible : « Titre : valeur, détail, état ».
- Preuve : `modules/Domenia-Widgets.UI.ps1:454, 470-479`

### UI-26 — Exécuter un programme : un panneau au lieu de la fenêtre « Rimotte »
*Impact moyen, effort M*

- **Constat** : Show-DomeniaRimotteDialog ouvre une fenêtre « Rimotte integre » aux couleurs codées en dur (#F3F6FB, White), qui ignore le thème sombre. Elle garde une option grisée « non propose », un paragraphe sur un mode retiré et du jargon (SYSTEM session 0, RunOnce). Le journal écrit « Rimotte : … ».
- **Proposition** : Un panneau dans la page, aux couleurs du thème, avec deux choix : « En arrière-plan (compte système) » et « Dans la session de l'utilisateur ». Retirer l'option abandonnée et le nom Rimotte.
- Preuve : `Domenia-Core.ps1:16958-16990`

### UI-27 — Comptes : montrer les comptes réellement utilisés
*Impact moyen, effort M*

- **Constat** : Le compte saisi dans l'onglet Diagnostic d'un poste passe avant le compte Postes, mais n'apparaît pas dans Comptes. Les comptes temporaires ne se voient que dans la fenêtre du bouton Accès, sous des clés internes.
- **Proposition** : Ajouter à Comptes une section « En ce moment » : le compte utilisé pour chaque ressource, et les comptes temporaires avec leur durée restante et un bouton « Oublier ».
- Aussi proposé par le Spark (idée 53).
- Preuve : `modules/Domenia-Relations.UI.ps1:100-106 ; Domenia-Core.ps1:19060-19080 ; modules/Domenia-Access.UI.ps1:520-533`

### UI-28 — Aide en surimpression : bord net et Échap
*Impact faible, effort S*

- **Constat** : En fenêtre étroite, l'aide passe au-dessus du contenu, avec le même fond, sans bord ni ombre. Ni Échap ni un clic à côté ne la ferment.
- **Proposition** : Bordure gauche ou ombre légère. Fermer par Échap et par un clic hors du panneau.
- Preuve : `modules/Domenia-UX.UI.ps1:373-376 ; Domenia-Core.ps1:6213`

### UI-29 — Titres de page alignés sur le menu
*Impact faible, effort S*

- **Constat** : Le menu dit « Rechercher » et le titre « Recherche et filtre OU ». Même écart pour « Comptes et accès », « Outils et vérifications », « Relations utilisateur / poste ». Le badge « Session AD · » est du jargon.
- **Proposition** : Titre = libellé du menu, suivi du sujet (« Fiche · Camille Martin »). Badge : « Connecté à example.local ».
- Preuve : `modules/Domenia-UX.UI.ps1:166-177 ; recherche.png`

### UI-30 — Profil Essentiel/Expert : un choix explicite
*Impact faible, effort S*

- **Constat** : Une liste déroulante sans libellé, qui n'affiche que « Essentiel », trône dans l'en-tête de chaque page. Le message de bascule n'a pas d'accents (« Les droits ne sont pas modifies »).
- **Proposition** : Un contrôle segmenté « Essentiel | Expert », ou un réglage dans le menu du compte en pied de menu. Corriger le message.
- Preuve : `Domenia-Core.ps1:4344-4347, 2311-2313 ; accueil.png`

### UI-31 — Secrets : bouton toujours grisé et libellés qui s'écrasent
*Impact faible, effort S*

- **Constat** : En mode valeur unique (actif par défaut), « Copier tout » est grisé en permanence, à côté de « Une valeur a la fois ». Le bouton d'affichage reçoit trois libellés successifs, posés à trois endroits du code.
- **Proposition** : Masquer « Copier tout » en mode valeur unique. Fixer le libellé à un seul endroit. Renommer les boutons « Lister les clés BitLocker » et « Lire le mot de passe LAPS ».
- Preuve : `Domenia-Core.ps1:5885-5887, 10699, 10724-10725, 22318-22340`

## Design (22)

### DS-01 — Bandeau du haut : boutons-icônes et indication Ctrl K
*Impact fort, effort S*

- **Constat** : Accès (108 px) et Opérations (144 px) ont un libellé calé à gauche et un badge masqué qui garde sa place : on dirait deux champs vides à côté de la recherche. Le bouton « Ctrl + K » n'affiche qu'un raccourci, et un technicien ne sait pas ce qu'il fait.
- **Proposition** : Des boutons-icônes de 40 px, avec une pastille de compteur seulement au-dessus de zéro et le libellé en infobulle ; les emplacements restent fixes (D082). Retirer le bouton « Ctrl + K » et placer une indication grise « Ctrl K », cliquable, à droite dans la barre de recherche.
- Aussi proposé par le Spark (idée 2).
- Preuve : `Domenia-Core.ps1:4280-4296 (vérifié) ; accueil.png ; recherche.png`

### DS-02 — Lecture seule : un interrupteur clair, sans halo flou
*Impact fort, effort S*

- **Constat** : Aujourd'hui, on trouve une case « Lecture seule » couleur lien : la cocher protège, la décocher autorise. Une fenêtre au tutoiement s'ouvre (« Tu vas activer le mode ecriture »). Une pastille de 240 px affiche « MODE ECRITURE AD ACTIF » avec un émoji 🔴, et un halo rouge flou (BlurRadius 34) entoure la fenêtre, ce qui ralentit en RDP. Les couleurs sont codées en dur (#B91C1C, #DC2626, #7C3AED).
- **Proposition** : Un interrupteur avec cadenas : « Lecture seule » (neutre) ↔ « Écriture active » (rouge plein). Un cadre plein de 3 px, sans effet. Une confirmation en une phrase, au vouvoiement, dans un petit panneau sous le bandeau. Des couleurs prises dans le thème. Le retour automatique est traité en SE-06.
- Preuve : `Domenia-Core.ps1:4331-4343, 6339-6343, 19617-19650, 22390-22406 ; base-autonome.png`

### DS-03 — Filtres sans intitulé sur les écrans courants
*Impact fort, effort S*

- **Constat** : Sous 940 px de hauteur utile, les intitulés des filtres disparaissent. En 1440×900, on voit « Tous », « Tous », « 100 », une liste vide et « Afficher », sans savoir à quoi ils servent.
- **Proposition** : Écrire le sens dans le contrôle lui-même : « Tous les types », « Toute présence », « 100 lignes max », « Vues prêtes… ». Les intitulés peuvent alors disparaître sans perte de sens.
- Preuve : `modules/Domenia-UX.UI.ps1:229, 245-252 ; recherche.png`

### DS-04 — Tableaux de widgets en grille fluide
*Impact fort, effort M*

- **Constat** : Les cartes ont des largeurs fixes (230, 345, 440, 660 px) dans un WrapPanel. À 1440 px, chaque rangée s'arrête vers 1207 px et laisse 180 à 250 px vides. « Dernière analyse » se retrouve seule sur une ligne, et la carte des points fait 660 px pour deux lignes.
- **Proposition** : Calculer le nombre de colonnes selon la largeur (4, 3 ou 2). Compacte, Moyenne et Large occupent 1, 2 ou 3 colonnes. Les cartes s'étirent pour remplir la rangée et leurs hauteurs s'alignent.
- Preuve : `modules/Domenia-Boards.Model.ps1:225-243 ; modules/Domenia-Dashboard.UI.ps1:36 ; modules/Domenia-Widgets.UI.ps1 ; accueil.png ; tableau-poste.png ; logiciels.png`

### DS-05 — Réunir score et points à vérifier en une carte
*Impact fort, effort M*

- **Constat** : « 2 critique(s) · 2 a surveiller » apparaît deux fois côte à côte. La carte des points garde 250 px de haut, entièrement teintée, même pour deux lignes. Le titre annonce « 4 point(s) » mais la carte en liste 5, car l'information n'est pas comptée.
- **Proposition** : Une carte « Santé » unique : le score à gauche, la liste à droite. La hauteur suit le contenu, la teinte se limite à l'icône ou à un liseré. Titre : « 4 points à vérifier · 1 information ». Si tout va bien, une seule ligne verte.
- Preuve : `accueil.png ; tableau-poste.png ; modules/Domenia-Boards.Model.ps1:190, 237 ; modules/Domenia-Charts.UI.ps1:269-274, 400`

### DS-06 — Rechercher : une seule carte avant la liste
*Impact fort, effort M*

- **Constat** : La carte « Périmètre des résultats » est presque vide. Ensuite viennent la barre Résultats, le filtre local, 6 boutons et 2 lignes d'aide. À 900 px de haut, il reste 9 lignes de résultats visibles.
- **Proposition** : Une seule carte. En en-tête, un fil d'Ariane cliquable (« example.local › Lyon › Postes · 48 objets »). Une barre d'outils : filtres en menus compacts, recherche locale, « Vérifier ▾ », menu « ⋯ » pour Exporter et Actualiser. Supprimer les 2 lignes d'aide.
- Preuve : `Domenia-Core.ps1:4618-4700 ; recherche.png`

### DS-07 — Panneau des OU : toute la hauteur pour l'arbre
*Impact fort, effort M*

- **Constat** : Au-dessus de l'arbre s'empilent une intro, « Tout le domaine », la carte Périmètre, « Afficher cette OU », « Inclure les sous-OU » et « Voir le chemin LDAP ». L'arbre ne commence qu'à mi-hauteur, et le périmètre est répété à droite.
- **Proposition** : Donner toute la hauteur à l'arbre, avec un champ « Filtrer les OU » en haut. Sous-OU et chemin passent dans un menu d'en-tête. Supprimer la carte Périmètre et « Afficher cette OU », qui fait comme un clic sur le nœud.
- Aussi proposé par le Spark (idée 39).
- Preuve : `Domenia-Core.ps1:4581-4606 ; recherche.png`

### DS-08 — En-tête fixe pour le poste
*Impact fort, effort M*

- **Constat** : Sous le titre, on lit « Machine : PC-COMPTA-014 | Fiche AD chargee. ». La pastille « Session AD » change de place d'un onglet à l'autre. Les actions courantes sont dispersées dans les onglets.
- **Proposition** : Un en-tête fixe, quel que soit l'onglet : nom, système, pastille de présence colorée, utilisateur associé (lien), âge du dernier inventaire, et 3 actions rapides (Bureau à distance, C$, Ping).
- Preuve : `fiche-poste.png ; tableau-poste.png`

### DS-09 — Base autonome : chiffres en tuiles, grille à pleine hauteur
*Impact fort, effort M*

- **Constat** : Les boutons, deux encadrés et une longue phrase occupent l'écran : la grille ne garde qu'environ 50 px, et ses colonnes fixes (1280 px plus Détail) coupent la dernière. Le résumé tient en une phrase technique (« association(s) user-machine (29 verifiee(s))… repere de suivi 184522. Chargement complet RAM desactive. »), et la fin affiche « en 48213 ms ».
- **Proposition** : Un en-tête compact avec 4 tuiles pastel : Comptes, Postes, Associations, Dernière mise à jour « il y a 1 h ». Encadrés repliables. La grille prend toute la place restante, en largeurs relatives. Score et Correspondance seulement en Expert. USN, RAM et millisecondes vont au journal.
- Aussi proposé par le Spark (idée 73).
- Preuve : `base-autonome.png ; Domenia-Core.ps1:6017-6081, 15273-15276, 15325`

### DS-10 — Icône de thème nette, même sens partout
*Impact moyen, effort S*

- **Constat** : La fenêtre principale utilise 🌞/🌙, que WPF rend en monochrome : on voit un visage dans accueil.png. La connexion utilise ☀/☾, qui donne un carré vide dans connexion.png. L'une montre le thème actuel, l'autre le thème cible.
- **Proposition** : Des icônes Path soleil et lune, au trait du menu (1,7). Une seule convention : l'icône du thème vers lequel on bascule. Nom accessible : « Passer au thème sombre ».
- Aussi proposé par le Spark (idée 8).
- Preuve : `Domenia-Core.ps1:4297-4301, 3485-3515, 25274 ; modules/Domenia-Experience.UI.ps1:273-283 ; accueil.png ; connexion.png`

### DS-11 — Boutons désactivés lisibles, cartes sombres visibles
*Impact moyen, effort S*

- **Constat** : Un bouton désactivé passe à 45 % d'opacité, soit un contraste d'environ 2,5:1. « Arrêter » grisé est rose pâle (environ 2,2:1). En thème sombre, carte et fond sont à 1,13:1 : les cartes disparaissent. Au survol, l'opacité ne passe qu'à 0,92.
- **Proposition** : Un style désactivé dédié : fond BgReadonly, texte MutedColor à 4,5:1 au moins. Masquer « Arrêter » quand rien ne tourne. Éclaircir BgCard en sombre (vers #1E2D44). Au survol, une teinte (RowHoverBg). Un seul anneau de focus.
- Preuve : `Domenia-Core.ps1:3621-3640, 3652-3657 ; SupportSuite.UI.json (Dark) ; recherche.png`

### DS-12 — Menu latéral épuré et regroupé
*Impact moyen, effort S*

- **Constat** : « Réduire le menu » occupe la place juste sous le logo. Le pied affiche la version et un slogan. Comptes porte un bouclier. Rubriques de travail et de réglage sont mélangées, et l'identité utilisée est cachée dans l'aide.
- **Proposition** : Rubriques de travail en haut, Comptes et Outils en bas. Bascule de repli en petite icône en bas. Le pied montre le compte et le domaine connectés, avec un menu pour changer de compte. La version passe dans « À propos ». Barre d'accent à gauche sur la rubrique active.
- Preuve : `Domenia-Core.ps1:4160-4235, 6231-6237 ; accueil.png`

### DS-13 — Une seule taille de chiffre par rangée
*Impact moyen, effort S*

- **Constat** : La taille de la valeur dépend de sa longueur (27, 21, 18 ou 15 px). Dans une même rangée, « 16 Go », « Intel Core i5-1345U » et « Service informatique » ont trois tailles.
- **Proposition** : 27 px pour les nombres, 18 px pour les textes sur 2 lignes au plus, puis points de suspension et infobulle. Le texte ne rétrécit plus selon sa longueur.
- Preuve : `modules/Domenia-Charts.UI.ps1:364-368 ; tableau-poste.png`

### DS-14 — Graphiques : pastels catégoriels, couleurs d'état réservées
*Impact moyen, effort S*

- **Constat** : La palette des parts reprend le jaune Warn (#FCD34D) et le vert Ok (#86EFAC) : « Adobe » ou « 32 bits » en jaune passent pour des alertes. Sur blanc, le bleu #93C5FD est à environ 1,8:1 et le jaune à environ 1,4:1, sous les 3:1 requis.
- **Proposition** : Pastels catégoriels hors teintes d'état : bleu, violet, sarcelle, rose, ciel, pêche, lilas, sauge. Jaune, vert et rouge réservés au sens. Contour de 1 px plus foncé ou remplissage foncé pour atteindre 3:1, à vérifier aussi en sombre. Séries déclarées dans le JSON de thème (CD-05).
- Preuve : `modules/Domenia-Charts.UI.ps1:22, 512, 633, 706 ; modules/Domenia-Boards.Model.ps1:107 ; logiciels.png`

### DS-15 — Présence et états en pastilles
*Impact moyen, effort S*

- **Constat** : Présence, vérification et « Fraîcheur AD » s'affichent en texte gris (« En ligne (cache) », « Cache · à vérifier »). Get-DomeniaPresenceColor existe mais ne sert que dans la fiche.
- **Proposition** : Pastilles pastel (vert, ambre, gris) avec un libellé court. Remplacer « (cache) » par un âge discret (« il y a 2 h »). Réduire « Fraîcheur AD » à une icône avec infobulle.
- Preuve : `Domenia-Core.ps1:2342-2355, 4720-4740 ; modules/Domenia-Live.Model.ps1:124-125`

### DS-16 — Base autonome : un seul bouton principal
*Impact moyen, effort S*

- **Constat** : « Mettre a jour tout », « Mettre a jour les changements » et « Lire le journal du controleur » sont tous trois en style principal. « Ouvrir l objet » et « Exporter CSV » sont à côté, alors qu'ils agissent sur la grille du bas.
- **Proposition** : Un bouton principal « Mettre à jour » (les changements), et « Tout relire » en secondaire. « Ouvrir » et « Exporter » juste au-dessus de la grille.
- Aussi proposé par le Spark (idée 70).
- Preuve : `base-autonome.png ; Domenia-Core.ps1:6021-6024, 6046`

### DS-17 — Qualification des associations en puces
*Impact moyen, effort S*

- **Constat** : Get-DomeniaEvidenceBadge renvoie « Declare », « Observe », « Importe », « Source a verifier », alors que les messages écrivent « (Déclaré) ». La colonne est du texte gris.
- **Proposition** : Séparer la clé interne du libellé. Puces pastel : Déclaré bleu, Observé vert, Indice gris, Contradictoire orange, avec la règle en infobulle.
- Preuve : `modules/Domenia-Relations.Model.ps1:217-251 ; modules/Domenia-Relations.UI.ps1:1145`

### DS-18 — Thème sombre complet : barre de titre et barres de défilement
*Impact moyen, effort M*

- **Constat** : Aucun appel DWM : la barre de titre Windows reste claire en sombre. Aucun style ScrollBar : les barres classiques, épaisses et à flèches, se voient sur toutes les captures.
- **Proposition** : Un petit appel natif en C# 5 (DWMWA_USE_IMMERSIVE_DARK_MODE) dans un .cs existant. Un style ScrollBar fin (6 à 8 px, pouce arrondi, sans flèches) branché sur les jetons.
- Preuve : `Domenia-Core.ps1:3598-4150 (aucun style ScrollBar) ; accueil.png ; recherche.png`

### DS-19 — Échelle typographique et jetons d'espacement
*Impact moyen, effort M*

- **Constat** : Le XAML utilise 15 tailles de police (de 10,5 à 27), 9 rayons d'angle et 8 hauteurs de bouton. Les Metrics de SupportSuite.UI.json (Radius 12, ButtonHeight 36) ne sont pas appliquées. xml:lang fr-FR n'existe que sur la connexion. Trois titres s'empilent sur l'Accueil.
- **Proposition** : 5 styles de texte (Titre 22, Section 17, Corps 13, Légende 11,5, Chiffre 26), des espacements 4/8/12/16/24 et 3 rayons (8, 12, 16) en ressources, appliqués page par page. Ajouter xml:lang=fr-FR sur la fenêtre principale.
- Aussi proposé par le Spark (idée 13, 14).
- Preuve : `Domenia-Core.ps1:3568, 4269 ; SupportSuite.UI.json (Metrics) ; accueil.png`

### DS-20 — Grille de résultats : choisir ses colonnes
*Impact moyen, effort M*

- **Constat** : La grille a 17 colonnes (environ 3500 px), d'où un défilement horizontal dès 1440 px. L'association occupe trois colonnes et « Chemin complet » 520 px. La disposition enregistrée ne garde que la largeur et l'ordre.
- **Proposition** : Un clic droit sur l'en-tête ouvre « Colonnes… », à cocher, avec choix enregistré. Fusionner les trois colonnes d'association en une cellule « Camille Martin · observé ».
- Aussi proposé par le Spark (idée 44).
- Preuve : `Domenia-Core.ps1:4717-4747 ; modules/Domenia-Continuity.UI.ps1:45-55 ; recherche.png`

### DS-21 — Précédent/Suivant à côté du titre de page
*Impact faible, effort S*

- **Constat** : Les flèches sont collées au bouton Rechercher, loin du titre qu'elles font changer. Ce sont des caractères Unicode, pas des icônes.
- **Proposition** : Placer les flèches à gauche du titre de page, comme dans Finder, avec des icônes Path au trait du menu.
- Preuve : `Domenia-Core.ps1:4276-4277 ; accueil.png`

### DS-22 — Fiche poste : champs mal alignés
*Impact faible, effort S*

- **Constat** : TxtCompPresence (colonne 3, marge droite 14) s'arrête 13 px avant les autres champs. TxtCompManagedBy (colonne 1, marge 0) déborde de 14 px sur la gouttière.
- **Proposition** : Deux styles, champ gauche et champ droit, pour toutes les fiches, au lieu de marges écrites à la main. Remettre Présence à sa place dans l'ordre du XAML.
- Preuve : `Domenia-Core.ps1:5445, 5455 ; fiche-poste.png`

## Expérience (42)

### UX-01 — Journal replié : afficher le dernier message
*Impact fort, effort S*

- **Constat** : Set-Status écrit seulement dans le journal du bas, et LblStatus reste masqué. Sous 940 px de haut (portable 1080p à 125 %), le journal est replié d'office : aucun retour pour « Recherche terminée », une erreur ou un refus. Replié, il garde pourtant Suivre, Etat moteur, Copier et Effacer, qui agissent sur un contenu invisible.
- **Proposition** : Barre repliée : titre, dernière ligne (heure, icône, phrase) et chevron ˄ ; un clic déplie. Une erreur garde une pastille rouge jusqu'à sa lecture. Les commandes n'apparaissent qu'une fois le journal déplié.
- Preuve : `Domenia-Core.ps1:1708-1722, 4329, 6316-6321 ; modules/Domenia-UX.UI.ps1:226-229, 343-347 ; modules/Domenia-Experience.UI.ps1:162-176 ; recherche.png ; accueil.png`

### UX-02 — « Exporter CSV » n'exporte qu'une ligne après un clic
*Impact fort, effort S*

- **Constat** : L'export prend la sélection dès qu'il y en a une. Or un simple clic sélectionne une ligne (et lance un ping) : l'export ne sort alors qu'une ligne, sans prévenir.
- **Proposition** : Un menu « Toute la liste (48) » ou « Sélection (3) ». À défaut, prendre la sélection seulement à partir de 2 lignes, et toujours afficher le nombre de lignes exportées.
- Aussi proposé par le Spark (idée 47).
- Preuve : `modules/Domenia-Experience.UI.ps1:13-24 ; Domenia-Core.ps1:10664`

### UX-03 — Filtre de présence : ne pas le garder d'une session à l'autre
*Impact fort, effort S*

- **Constat** : Le filtre de présence est restauré au démarrage. Or à ce moment tous les postes sont « Non vérifié » : avec « En ligne » mémorisé, la liste paraît vide, et sur écran court l'intitulé du filtre est masqué.
- **Proposition** : Repartir sur « Toute présence » à chaque démarrage, ou afficher une puce « Filtre : En ligne × ». Prévoir un état vide « Le filtre masque 48 lignes ».
- Preuve : `Domenia-Core.ps1:3102, 3118, 19302`

### UX-04 — Journal de session envahi par le moteur
*Impact fort, effort S*

- **Constat** : Chaque tâche, y compris les sauvegardes toutes les 350 ms, écrit dans le journal visible « Preparation : nom=…, operation=LocalStore, payload=1, timeout=120s ». Il s'y ajoute « Lecture identique partagee… » et « Demande sortie de la file… ». Les lignes utiles sont noyées.
- **Proposition** : Deux niveaux : Trace (fichier seulement) et Session (visible). Le journal visible ne garde que des faits utiles, en français simple : « Recherche terminée : 42 résultats ».
- Preuve : `Domenia-Core.ps1:21232-21246 ; modules/Domenia-Engine.UI.ps1:280, 344 ; accueil.png ; base-autonome.png`

### UX-05 — Déplacer un utilisateur : sélecteur d'OU, pas un DN à taper
*Impact fort, effort S*

- **Constat** : « Déplacer vers » est un champ libre où taper le chemin complet de l'OU. Les champs Groupe des onglets Compte et Actions demandent aussi « Nom ou chemin complet ». Le poste a déjà un sélecteur d'OU intégré (Show-DomeniaInlinePicker).
- **Proposition** : Réutiliser ce sélecteur pour l'utilisateur (recherche, OU actuelle, fil d'Ariane) et supprimer le champ texte. Pour les groupes, autocomplétion par préfixe, en lecture ciblée et limitée.
- Preuve : `Domenia-Core.ps1:5024-5026, 5037, 5539, 19423, 7769-7773 ; modules/Domenia-Embedded.UI.ps1:275`

### UX-06 — Informations et erreurs en bandeau, sans fenêtre bloquante
*Impact fort, effort M*

- **Constat** : Show-InfoBox, Show-ErrorBox et Confirm-WarningAction sont appelés plus de 100 fois, dont 82 pour Show-ErrorBox. Chaque appel ouvre une feuille modale avec voile et un cadre Dispatcher imbriqué, même pour une information (« État du moteur ») ou une lecture ratée.
- **Proposition** : Info et succès : un bandeau discret pendant 5 s, avec « Voir le détail ». Erreurs : un bandeau non bloquant en haut de page, avec « Copier le détail » et « Ouvrir le journal ». Le modal reste réservé aux décisions et aux confirmations d'écriture.
- Preuve : `Domenia-Core.ps1:1775-1800, 1904-1914, 1993-2000, 311-314 ; modules/Domenia-Embedded.UI.ps1:116-140, 201`

### UX-07 — Confirmation d'impact en clair, dans la page
*Impact fort, effort M*

- **Constat** : Confirm-DomeniaOperationImpact ouvre une fenêtre pleine de jargon : « worker(s) », « pic théorique Mbit/s », « appels RPC Planificateur », « Fallback distant », « req/s », et la faute « Parallellisme ». C'est ce qu'on voit avant « Mettre à jour tout » et « Lire le journal du contrôleur ».
- **Proposition** : Un panneau dans la page avec une phrase : « Environ 2 min · 238 objets lus dans l'annuaire · aucun poste contacté », puis Lancer et Annuler. Les chiffres techniques vont dans un volet « Détails » replié, en Expert.
- Preuve : `Domenia-Core.ps1:20717-20745`

### UX-08 — Confirmations d'écriture AD : avant/après en clair
*Impact fort, effort M*

- **Constat** : Désactiver, réinitialiser le mot de passe, options du compte, déplacer, groupes, renommer : tout passe par Confirm-Action, qui ouvre une fenêtre. On y lit le DN, le GUID, le contrôleur, l'empreinte et des lignes comme « lockoutTime (Clear) : [133…] -> [] ».
- **Proposition** : Un seul panneau intégré (Request-DomeniaInlineConfirmation existe déjà), avec l'avant et l'après en clair : « Compte : verrouillé → déverrouillé ». GUID, DN, contrôleur et empreinte vont dans « Détails techniques », replié.
- Preuve : `Domenia-Core.ps1:23285, 23454, 23523, 23619, 23678, 23730, 23770, 23812, 23860, 23905, 22864-22885 ; modules/Domenia-Inline.UI.ps1:48`

### UX-09 — Fiche et Assistance poste : une page vide plutôt qu'un bouton grisé
*Impact fort, effort M*

- **Constat** : Sans sélection, ces deux rubriques sont grisées, avec une raison en infobulle et sans accents. Le message prévu « Ouvrez d abord une fiche » ne s'affiche jamais, car un bouton désactivé ne reçoit pas de clic.
- **Proposition** : Garder les rubriques actives. Afficher une page vide soignée : « Aucune fiche ouverte », un champ de recherche et les dernières fiches consultées (mémoire locale, sans réseau).
- Preuve : `modules/Domenia-UX.UI.ps1:129-133, 154-163 ; accueil.png`

### UX-10 — Points d'attention cliquables
*Impact fort, effort M*

- **Constat** : « 2 poste(s) sous Windows 10 » ne dit pas lesquels, et aucune ligne n'est cliquable, alors que le fournisseur connaît déjà les postes concernés (Targets). Côté poste, rien ne mène à l'action utile.
- **Proposition** : Un clic sur une ligne déplie, dans la carte, les postes concernés (nom, OU, date), avec « Copier » et « Afficher dans Rechercher », sans requête réseau. Côté poste, un lien vers l'onglet utile (Redémarrer, Ouvrir C$, Secrets), sans rien exécuter.
- Aussi proposé par le Spark (idée 60).
- Preuve : `modules/Domenia-Charts.UI.ps1:382-430 ; modules/Domenia-BoardFleet.Model.ps1:71, 124-127`

### UX-11 — Disposition par défaut allégée
*Impact fort, effort M*

- **Constat** : La disposition livrée reprend tout le catalogue : 42 widgets sur le poste, dont 17 tuiles en « Sécurité et état » et 8 tuiles de texte en « Identité ». La page devient un mur de cartes.
- **Proposition** : Une sélection d'environ 14 widgets selon le profil. Une représentation « Fiche » (lignes libellé/valeur) pour Identité et Compte machine : 2 cartes au lieu de 15 tuiles. Un widget « Liste d'état » à coches (BitLocker, pare-feu, antivirus, redémarrage, correctifs). Le reste reste dans le catalogue.
- Preuve : `modules/Domenia-Boards.Model.ps1:8-49, 257-260 ; administrateur.md §9`

### UX-12 — Avancement d'un relevé visible
*Impact fort, effort M*

- **Constat** : L'état du relevé s'écrit dans LblLiveState : texte gris de 11 px, tronqué, sans barre ni état par ligne. Le bouton « Arrêter » reste rouge en permanence, même grisé.
- **Proposition** : Une barre fine sous les actions (« 12/48 · 9 joignables ») et un indicateur sur les lignes en cours. Pendant le relevé, le bouton de lancement devient « Arrêter (12/48) ».
- Aussi proposé par le Spark (idée 29).
- Preuve : `modules/Domenia-Park.UI.ps1:26 ; Domenia-Core.ps1:4698-4700 ; recherche-actions.png`

### UX-13 — Fiches : vrai mode édition et alerte de perte
*Impact fort, effort M*

- **Constat** : En lecture seule, Description, Localisation et Responsable restent des zones blanches modifiables, alors qu'« Enregistrer » est grisé. Hors lecture seule, Enregistrer est actif dès qu'on a le droit. Rien ne signale un champ modifié, ni une perte quand on change d'objet.
- **Proposition** : En lecture seule, champs verrouillés. Sinon, un crayon « Modifier » ouvre l'édition : champs modifiés surlignés, Enregistrer et Annuler, et une alerte dans la page si l'on quitte sans enregistrer.
- Preuve : `fiche-poste.png ; Domenia-Core.ps1:22257, 19412, 19426`

### UX-14 — Responsable : nom lisible et sélecteur
*Impact fort, effort M*

- **Constat** : TxtUserManager et TxtCompManagedBy affichent le DN complet et acceptent du texte libre. « Service informatique » envoie un DN invalide à l'enregistrement. La capture ne montre un nom que parce qu'il est injecté.
- **Proposition** : Afficher le nom (Get-DomeniaCnFromDn) avec un bouton « Ouvrir ». Pour modifier, un sélecteur dans la page : recherche par nom, 20 résultats au plus. Le DN reste interne.
- Preuve : `Domenia-Core.ps1:4865 (vérifié), 5455, 7283, 7387, 23424 ; guides/captures/capture-guides.ps1:258`

### UX-15 — Compte utilisé pour les postes : le montrer en permanence
*Impact fort, effort M*

- **Constat** : Le cadre « Compte poste / Mot de passe » est caché dans l'onglet Diagnostic, alors qu'il sert pour C$, les consoles, l'inventaire et les sessions. L'onglet Actions l'explique par une phrase technique.
- **Proposition** : Une pastille permanente dans l'en-tête d'Assistance poste : « Compte poste : session Windows ▾ ». Elle ouvre un panneau latéral pour saisir un compte ou revenir au compte de connexion. Retirer la phrase de l'onglet Actions.
- Aussi proposé par le Spark (idée 53).
- Preuve : `Domenia-Core.ps1:5560-5600, 5547 ; actions-poste.png`

### UX-16 — Autorisation d'intervention : la sortir de l'onglet masqué
*Impact fort, effort M*

- **Constat** : « Exécuter un programme » et les replis PsExec ou tâche planifiée exigent « Autoriser une intervention sur cette machine ». Ce bouton est dans TabGuard, masqué par défaut. L'erreur renvoie à « Outils > Fiabilite », invisible : l'utilisateur est bloqué.
- **Proposition** : Mettre l'autorisation dans l'onglet Actions du poste, sous forme de pastille avec compte à rebours (« Intervention autorisée 4:59 · Retirer »). Corriger le message d'erreur.
- Preuve : `Domenia-Core.ps1:5930, 5960, 8649`

### UX-17 — Diagnostic : un verdict et sans faux échecs
*Impact fort, effort M*

- **Constat** : Sur un poste sain, le port 5986 fermé, PsExec « non autorisé » et le Planificateur comptent comme échecs : « 3 en echec ». Les états sont des codes (OK, REFUSE, INJOIGNABLE, IGNORE), et les colonnes Methode et Duree ms visent des experts.
- **Proposition** : Une phrase de verdict en haut : « Le poste répond, C$ accessible, Bureau à distance ouvert ; WinRM fermé (normal) ». Les contrôles optionnels passent en Info, et les lignes de transport en Expert. Badges colorés en mots français.
- Aussi proposé par le Spark (idée 52).
- Preuve : `Domenia-Core.ps1:15893-15960, 16105-16111, 5614-5625`

### UX-18 — BitLocker : une clé facile à dicter
*Impact fort, effort M*

- **Constat** : La colonne Valeur fait 260 px sans retour à la ligne : la clé de 55 caractères est tronquée. Elle reste 30 s, trop peu pour dicter 48 chiffres. La colonne « Compte » contient en fait l'identifiant de récupération, et Detail affiche le DN.
- **Proposition** : Une carte d'affichage : 8 blocs de chiffres, grande police à chasse fixe, identifiant rappelé pour vérification, anneau de compte à rebours et « Prolonger 30 s ». Renommer la colonne « Identifiant » et retirer le DN.
- Preuve : `Domenia-Core.ps1:5905 ; modules/Domenia-Access.Model.ps1:375 ; modules/Domenia-Secrets.UI.ps1:107`

### UX-19 — Onglet Fiabilité masqué : redistribuer son contenu
*Impact fort, effort M*

- **Constat** : TabGuard est masqué, mais il contient les reçus, Mesurer/Purger, les recherches enregistrées, la reprise des sauvegardes et Pesto. Plusieurs messages renvoient pourtant à « Outils > Fiabilite » (« Voir le stockage dans Fiabilité », « Reprise dans Fiabilite ») : le technicien tombe dans une impasse.
- **Proposition** : Placer chaque fonction là où on la cherche : les recherches enregistrées dans Rechercher (FO-04), Mesurer/Purger dans Base autonome. « Opérations à vérifier » devient une pastille d'en-tête, visible seulement s'il reste un reçu en attente. Remplacer les chemins écrits par des boutons qui passent par la table des routes.
- Preuve : `Domenia-Core.ps1:5930-5970, 8649, 9426 ; modules/Domenia-Relations.UI.ps1:627, 646 ; modules/Domenia-Guard.UI.ps1:88-89 ; modules/Domenia-Cache.Model.ps1:360 ; modules/Domenia-Park.UI.ps1:13 ; modules/Domenia-Access.UI.ps1:394 ; administrateur.md ch. 22`

### UX-20 — Parcours de premier lancement
*Impact fort, effort M*

- **Constat** : Le code ne gère aucun premier lancement. Avec une base vide, Outils affiche « Utilise  Mettre a jour tout  pour creer… » (tutoiement, doubles espaces). L'Accueil renvoie par écrit vers « Outils, Base autonome, Mettre a jour tout ».
- **Proposition** : Une carte « Premiers pas » sur l'Accueil : choisir mon OU, construire la base, compte des postes, première sauvegarde. Chaque étape a son bouton, et la carte disparaît une fois tout fait. Remplacer les chemins écrits par des liens.
- Preuve : `Domenia-Core.ps1:15330 ; accueil.png ; aucun « FirstRun » dans dev/wad`

### UX-21 — Assistance poste : passer de 8 onglets à 5 vues
*Impact fort, effort L*

- **Constat** : L'assistance poste compte 8 onglets (Machine, Tableau de bord, Actions, Sessions, Diagnostic, Inventaire, Logiciels, Secrets), plus WMI en Expert. Inventaire répète les boutons du tableau de bord, et Machine reprend surtout des données de la Fiche.
- **Proposition** : 5 vues : Vue d'ensemble (fiche et tableau de bord), Intervenir (actions et sessions), Détails (inventaire et logiciels), Diagnostic, Secrets. À mener avec l'en-tête fixe (DS-08).
- Preuve : `Domenia-Core.ps1:5416-5876 ; fiche-poste.png ; tableau-poste.png`

### UX-22 — Animation d'entrée jouée une seule fois
*Impact moyen, effort S*

- **Constat** : Chaque recalcul de l'Accueil rejoue l'entrée complète : fondu des cartes et comptage depuis 0. Or ces recalculs arrivent seuls (fin d'analyse, base enregistrée), pendant que l'utilisateur lit. Aucun réglage ne coupe l'animation.
- **Proposition** : Une entrée par tableau et par session. Ensuite, un fondu sur les seules valeurs qui changent, sans recompter. Ajouter « Réduire les animations » dans les préférences.
- Aussi proposé par le Spark (idée 17).
- Preuve : `modules/Domenia-Dashboard.UI.ps1:190, 196 ; modules/Domenia-Charts.UI.ps1:198-240 ; administrateur.md §9`

### UX-23 — Score partiel après un inventaire rapide
*Impact moyen, effort S*

- **Constat** : Après un inventaire rapide, Activité et Sécurité ne sont pas lues, mais le score se calcule et peut afficher « Bon état ». Un poste sans BitLocker ni pare-feu paraît sain.
- **Proposition** : Un badge « Partiel : sécurité non vérifiée » sous le score, avec « Inventaire complet » dans la carte. Ou un score grisé tant que les sections clés manquent.
- Preuve : `modules/Domenia-BoardComputer.UI.ps1:347-356, 364 ; modules/Domenia-Boards.Model.ps1:181-192`

### UX-24 — Confirmation du relevé : trois lignes justes
*Impact moyen, effort S*

- **Constat** : La cible affichée est le domaine alors que seuls les postes affichés sont visés. Le message est long, sans accents et technique (« releve WMI leger », « CIM/DCOM », « ICMP »). Les postes sans GUID sont écartés sans le dire : 45 annoncés pour 48 visibles.
- **Proposition** : Trois lignes : « 48 postes affichés (Postes, sous-OU) », « Ce qui sera lu : présence · utilisateur · matériel », et une durée estimée. Expliquer les écarts de nombre. Mettre le nombre dans le bouton : « Pinger 48 postes ».
- Preuve : `modules/Domenia-Park.UI.ps1:56, 88-93`

### UX-25 — Liste de l'historique : le dire à l'écran
*Impact moyen, effort S*

- **Constat** : Après Précédent ou Suivant, la recherche vivante est arrêtée : un clic ne pingue plus, et seul « historique, non relu » s'ajoute au compteur. Le type d'objet n'est pas mémorisé, donc le filtre affiché peut contredire la liste.
- **Proposition** : Un bandeau discret « Liste de l'historique · Actualiser ». Mémoriser aussi le type, la présence et le filtre local dans l'instantané.
- Preuve : `modules/Domenia-Search.UI.ps1:68-118, 178 ; modules/Domenia-Live.UI.ps1:391-394`

### UX-26 — Menu clic droit court et sans écriture
*Impact moyen, effort S*

- **Constat** : Sur une ligne de poste, le clic droit propose environ 30 entrées dans 6 sous-menus, dont « Redemarrer le poste », « Supprimer l objet », « Copier une commande PSRemote » et « Explorateur WMI ».
- **Proposition** : Garder 8 entrées : Ouvrir la fiche, Assistance poste, Revérifier, Rechercher l'utilisateur associé, Ouvrir l'OU parente, Copier ▸, Exporter. Les écritures restent dans la fiche.
- Preuve : `Domenia-Core.ps1:12840-12940`

### UX-27 — Ouvrir la fiche sur l'onglet utile
*Impact moyen, effort S*

- **Constat** : Set-VisibleTabsForType ouvre toujours le Résumé technique (Type, Classe, GUID, DN). Le bouton rouge « Supprimer » y côtoie « Copier le resume », et la copie du DN est cachée dans un clic droit.
- **Proposition** : Ouvrir un utilisateur sur l'onglet Utilisateur et un poste sur sa vue d'ensemble. Classe et GUID en Expert. « Supprimer » dans un menu « Plus… », avec saisie du nom pour confirmer.
- Preuve : `Domenia-Core.ps1:9472, 4791-4808`

### UX-28 — Connexion : mettre en avant la session Windows
*Impact moyen, effort S*

- **Constat** : « Utiliser mon compte Windows » est un bouton secondaire, sous « Se connecter », et il ne dit pas quel compte sera utilisé. « Mémoriser uniquement l'identifiant » est maladroit.
- **Proposition** : En session de domaine, le bouton principal devient « Continuer en tant que EXEMPLE\jdupont », et le formulaire passe en second (« Utiliser un autre compte »). Case : « Se souvenir de mon identifiant ».
- Preuve : `connexion.png ; Domenia-Core.ps1:25303-25306, 25445-25450`

### UX-29 — Installateur : demander, limiter les sauvegardes, vouvoyer
*Impact moyen, effort S*

- **Constat** : Avec ConfirmImpact Medium, l'installation démarre juste après la liste, sans rien demander. Chaque mise à jour garde files et prepared dans les sauvegardes, sans rotation. Les messages tutoient (« ton DOMENIA actuel »). La restauration exige le chemin exact.
- **Proposition** : Demander « Installer ces N fichiers ? (O/N) ». Supprimer prepared après un succès et garder les 5 dernières sauvegardes. Ajouter -RestoreLatest. Messages accentués, vouvoyés, et résumé final : version avant/après.
- Preuve : `dev/INSTALLER-MISE-A-JOUR.ps1:6, 175, 222, 231, 239-246, 307-308`

### UX-30 — Accueil rafraîchi même quand la fenêtre est inactive
*Impact moyen, effort S*

- **Constat** : La politique d'inactivité ne considère la fenêtre visible que si elle est active. Un accueil affiché sur un 2e écran pendant qu'on travaille dans le ticket n'est jamais rafraîchi.
- **Proposition** : Suspendre ViewRebuild seulement si la fenêtre est réduite ou masquée. Garder IsActive pour les lectures réseau de fond.
- Preuve : `modules/Domenia-Engine.Model.ps1:515-530 ; modules/Domenia-Engine.UI.ps1:426-462`

### UX-31 — F5 actualise la page en cours
*Impact moyen, effort M*

- **Constat** : F5 relit toujours l'arbre des OU dans AD, même sur l'Accueil ou une fiche.
- **Proposition** : F5 actualise la page : recalcul local sur l'Accueil, relecture de l'OU affichée dans Rechercher, relecture de la fiche. Toujours un geste explicite, jamais tout le domaine.
- Preuve : `Domenia-Core.ps1:15765`

### UX-32 — Opérations et santé du moteur sans quitter la page
*Impact moyen, effort M*

- **Constat** : Le bouton Opérations envoie dans un onglet caché, « Opérations et confort », qui mêle suivi des tâches et densité. Le bouton « Etat moteur » ouvre une fenêtre avec du texte brut (« ecriture=True | annulation=False », CorrelationId).
- **Proposition** : Un panneau déroulant sous le bouton Opérations : tâches en cours et en attente, durée, Arrêter par ligne, plus une zone « Santé » en clair (mémoire, retard de l'interface, dernière sauvegarde). La densité part dans les réglages et TabExperience disparaît.
- Preuve : `modules/Domenia-Experience.UI.ps1:26-29 ; Domenia-Core.ps1:5971, 274-297, 303-306 ; base-autonome.png`

### UX-33 — Vues de travail appliquées à l'OU par défaut
*Impact moyen, effort M*

- **Constat** : 4 vues sur 5 ont NeedsOu=$false et s'annoncent « Périmètre : domaine entier ». Suivies de « Détecter la liste », elles donnent une liste à l'échelle du parc. Le menu des vues reste vide tant qu'on n'a rien choisi.
- **Proposition** : Appliquer chaque vue à l'OU choisie, avec une puce « Dans : Postes ⌄ ». Le domaine entier n'est qu'un choix explicite, sans relevé possible. Texte d'attente « Vues prêtes… ».
- Aussi proposé par le Spark (idée 21).
- Preuve : `modules/Domenia-Search.Model.ps1:382-386 ; modules/Domenia-Search.UI.ps1:35 ; recherche.png`

### UX-34 — Cartes : soulèvement seulement si elles sont cliquables
*Impact moyen, effort M*

- **Constat** : Toutes les cartes se soulèvent au survol et les parts de donut montrent une main, mais aucun clic ne fait rien. « Postes par sous-OU » ne permet pas de descendre, et reste affiché avec une seule barre « (directement dans l OU) ».
- **Proposition** : Réserver le soulèvement aux widgets cliquables et en ajouter d'utiles : « Utilisateur connecté » ouvre sa fiche, « LAPS » mène à Secrets, une barre d'OU sélectionne la sous-OU. Masquer le graphique des sous-OU quand il n'y a qu'un groupe.
- Preuve : `modules/Domenia-Charts.UI.ps1:289-306 ; modules/Domenia-BoardFleet.Model.ps1:86-93, 157-165 ; tableau-poste.png`

### UX-35 — Glisser-déposer réservé à Personnaliser
*Impact moyen, effort M*

- **Constat** : On peut glisser une carte depuis n'importe où, même hors personnalisation : déplacements accidentels. Le retour visuel se limite à une barre de 4 px, et on ne sait pas si la carte ira avant ou après.
- **Proposition** : Glisser seulement en Personnaliser. Indicateur avant ou après selon la moitié survolée, place libérée animée, aperçu sous le curseur.
- Preuve : `modules/Domenia-Widgets.UI.ps1:481-502 ; technicien.md §6`

### UX-36 — Réinitialiser un mot de passe : générateur et changement obligatoire
*Impact moyen, effort M*

- **Constat** : ChkMustChangeAtLogon n'a pas de IsChecked : la case est décochée, alors qu'un mot de passe donné par le support doit être changé. Rien ne génère un mot de passe ni ne vérifie la stratégie.
- **Proposition** : Cocher la case par défaut (réglable). Un bouton « Générer » crée un mot de passe temporaire conforme, montré une fois, avec copie et effacement auto. Vérifier la stratégie en direct avec Resolve-DomeniaPasswordPolicy.
- Preuve : `Domenia-Core.ps1:4975-4990 ; modules/Domenia-Directory.Model.ps1:182`

### UX-37 — Inventaire : valeurs traduites, pas de codes
*Impact moyen, effort M*

- **Constat** : Add-Item recopie les valeurs brutes : rôle « 1 », châssis « 10 », langue « 1036 », carte « 2, 1000 Mb/s », BitLocker « 6 », SMART « Pred Fail ». La colonne Source affiche Win32_ComputerSystem.
- **Proposition** : Une table de traduction pure et testée dans Domenia-Workstation.Model (« Connectée, 1 Gb/s », « Portable », « Français »). Colonne Source en Expert.
- Preuve : `Domenia-Core.ps1:11430, 11432, 11436, 11493, 11543, 11595, 11618, 11659`

### UX-38 — Services du poste lisibles dans la page
*Impact moyen, effort M*

- **Constat** : Le guide reconnaît que la console Services peut s'ouvrir sur le poste local, et qu'il faut alors passer par Action > Se connecter.
- **Proposition** : Une liste des services lue à la demande (Win32_Service), avec le filtre « automatiques arrêtés ». Démarrer ou redémarrer seulement hors lecture seule. À défaut, ouvrir compmgmt.msc, qui suit /computer.
- Preuve : `Domenia-Core.ps1:5518, 17066 ; technicien.md:91`

### UX-39 — Sessions Windows : lignes utiles et heure locale
*Impact moyen, effort M*

- **Constat** : La lecture renvoie la session 0 et l'écouteur RDP, sans utilisateur. L'état affiche ObservedUtc en ISO et le mot « WTS ». Ni l'heure d'ouverture ni l'inactivité ne sont lues. Sans poste choisi, une fenêtre bloquante s'ouvre.
- **Proposition** : Masquer les sessions sans compte. Ajouter « Ouverte à » et « Inactive depuis » (WTSSessionInfo), et « Ouvrir la fiche » par ligne. « Lu à 10:12 » en heure locale. Message dans la page au lieu de la fenêtre.
- Preuve : `modules/Domenia-Sessions.UI.ps1:22, 26-27 ; modules/Domenia-Sessions.Native.cs:43-49`

### UX-40 — Nettoyer les associations : liste claire et restaurable
*Impact moyen, effort M*

- **Constat** : Start-PruneOrphanLinks ouvre une fenêtre qui liste « user=True, pc=False ». Les suppressions ne passent pas par Remove-DomeniaRelation : elles ne sont ni journalisées ni restaurables.
- **Proposition** : Lister les orphelins dans l'onglet, avec un motif clair (« compte supprimé d'AD ») et des cases à cocher. Suppression journalisée et restaurable.
- Preuve : `Domenia-Core.ps1:18090-18140 ; modules/Domenia-Relations.UI.ps1:529-552`

### UX-41 — Aide au survol plus calme
*Impact faible, effort S*

- **Constat** : Chaque survol réécrit l'aide, qui clignote. Pour un contrôle sans entrée, un texte générique sans accents remplace l'aide utile.
- **Proposition** : Délai d'environ 400 ms au survol, mise à jour immédiate au focus clavier. Pour un contrôle inconnu, garder l'aide précédente.
- Preuve : `modules/Domenia-UX.UI.ps1:44-47, 93-99`

### UX-42 — Commande PowerShell : message dans la page et compte poste
*Impact faible, effort S*

- **Constat** : Show-InfoBox ouvre une fenêtre qui parle de « faux positifs antivirus ». La commande copiée (Enter-PSSession) ignore le compte poste saisi.
- **Proposition** : Message dans la page « Commande copiée ». Ajouter -Credential quand un compte poste est actif. Libellé : « Copier la commande PowerShell ».
- Preuve : `Domenia-Core.ps1:17087-17091`

## Fonctions nouvelles (22)

### FO-01 — Recherche « contient » sans syntaxe
*Impact fort, effort S*

- **Constat** : La barre cherche par préfixe et s'arrête au premier filtre qui renvoie un résultat. « compta » trouve « Compta Lyon » mais jamais « PC-COMPTA-014 » : il faut connaître *compta*.
- **Proposition** : Sous le compteur, une puce « Chercher aussi les noms qui contiennent « compta » » : geste explicite, même limite, même périmètre.
- Preuve : `Domenia-Core.ps1:9967-9996, 10090`

### FO-02 — Palette Ctrl+K façon Spotlight
*Impact fort, effort M*

- **Constat** : La palette s'ouvre en feuille latérale avec 10 actions codées en dur, sans accents (« Revenir a la racine »), et un titre doublé. Elle propose des actions indisponibles ou Expert, et le code traite encore « support » et « supportdiff », absents de la liste.
- **Proposition** : Panneau flottant centré en haut, dans DomeniaDialogLayer. Liste générée depuis Get-DomeniaShellPages et un catalogue d'actions, filtrée par profil. Action indisponible grisée avec sa raison. Recherche insensible aux accents, raccourci affiché par ligne, Échap pour fermer.
- Preuve : `Domenia-Core.ps1:18872-18968 ; modules/Domenia-Shell.Model.ps1:55-68`

### FO-03 — Barre de recherche : loupe, effacer, récents et suggestions locales
*Impact fort, effort M*

- **Constat** : Le champ du haut n'a ni loupe, ni ×, ni recherches ou fiches récentes. Il ne réagit qu'à Entrée et ne suggère rien.
- **Proposition** : Loupe et × qui vide le texte. Au focus, les 8 dernières recherches et fiches (mémoire locale). Pendant la frappe, suggestions tirées de la base autonome, sans réseau. Entrée reste le seul geste qui interroge AD.
- Aussi proposé par le Spark (idée 20).
- Preuve : `Domenia-Core.ps1:4255-4272, 19337-19346`

### FO-04 — Favoris d'OU en haut de l'arbre
*Impact fort, effort M*

- **Constat** : Les « Recherches enregistrées » existent, mais dans l'onglet Fiabilité masqué : personne ne peut s'en servir. Le signet d'OU ne retient que la dernière position.
- **Proposition** : Une section « Favoris » épinglée en haut de l'arbre : étoile au survol d'une OU, clic pour l'afficher. Reprendre les données SavedSearches et retirer le bloc caché.
- Preuve : `Domenia-Core.ps1:5930, 5961-5964 ; modules/Domenia-Guard.UI.ps1:113-161 ; modules/Domenia-Continuity.UI.ps1:70-79`

### FO-05 — Chercher un texte dans une OU
*Impact fort, effort M*

- **Constat** : Le champ texte de l'OU est masqué. La barre du haut ignore l'OU et grise Type et Présence sans explication. Le filtre local ne voit que les lignes chargées. Le filtre par type en global repose sur des jetons « poste: » cachés.
- **Proposition** : Une puce de portée « Partout | Dans « Postes » » et un sélecteur « Tout · Personnes · Postes · Groupes » dans la barre. En global, masquer les filtres propres à l'OU au lieu de les griser.
- Aussi proposé par le Spark (idée 19, 21).
- Preuve : `Domenia-Core.ps1:4623-4640, 4657-4666, 6895`

### FO-06 — Fiche utilisateur : brancher les informations de support
*Impact fort, effort M*

- **Constat** : Get-DomeniaUserSupportSummary, Resolve-DomeniaPasswordPolicy, Get-DomeniaLockoutDiagnosis et Find-DomeniaMembershipPath sont écrits dans Directory.Model, mais jamais appelés. La fiche n'affiche ni expiration du mot de passe, ni mauvais mots de passe, ni heure de verrouillage.
- **Proposition** : Un bandeau d'état en tête de l'onglet Utilisateur : « Verrouillé depuis 09:12 [Déverrouiller] », « Mot de passe expire dans 5 j », « 3 mauvais mots de passe », avec l'action contextuelle.
- Preuve : `modules/Domenia-Directory.Model.ps1:138, 182, 262, 312`

### FO-07 — Tableau du poste gardé pendant la session
*Impact fort, effort M*

- **Constat** : Le tableau du poste se vide quand on choisit un autre objet (le guide dit que c'est « normal »). Revenir sur un poste oblige à relancer un inventaire réseau.
- **Proposition** : Garder en mémoire, pour la session, le dernier inventaire de chaque poste, avec son âge (« inventaire d'il y a 12 min · Actualiser »), réaffiché sans requête.
- Preuve : `technicien.md:171 ; Domenia-Core.ps1:12047-12055`

### FO-08 — Table de fin de service pour toutes les versions
*Impact fort, effort M*

- **Constat** : Seul Windows 10 a une date de fin. Au 08/10/2026, Windows 11 22H2 Entreprise et 23H2 Pro ne sont plus maintenus, et 23H2 Entreprise s'arrête le 10/11/2026 : ces postes ressortent « Build 22621 » sans alerte.
- **Proposition** : Une table de données (build, famille d'édition, date de fin) dans un JSON de modules. « Fin de service le … », « À surveiller » 90 jours avant, « Critique » après. Widget parc « Versions en fin de service ».
- Preuve : `modules/Domenia-Boards.Model.ps1:115-132 ; modules/Domenia-BoardComputer.UI.ps1:92-97`

### FO-09 — Graphiques des logiciels reliés à la liste
*Impact fort, effort M*

- **Constat** : Les anneaux Éditeurs et Portée, et les barres des plus gros logiciels, sont décoratifs : un clic ne filtre pas le tableau, alors que le curseur devient une main.
- **Proposition** : Un clic sur une part ou une barre filtre la liste, avec une pastille « Filtré : Adobe ✕ ». Un nouveau clic retire le filtre.
- Preuve : `logiciels.png ; modules/Domenia-Charts.UI.ps1:525-529, 572-588`

### FO-10 — Historique local pour de vraies courbes
*Impact fort, effort L*

- **Constat** : La représentation « Courbe » est proposée sur des tranches qui ne sont pas des dates (« <7j » … « Jamais », tranches de mémoire) : elle trompe. Aucun widget ne montre une évolution.
- **Proposition** : Un instantané quotidien des chiffres du parc par OU dans la base locale, sans réseau. Widgets « Évolution sur 90 jours » (Windows 10, inactifs, disques pleins). D'ici là, retirer « Courbe » des données non temporelles.
- Preuve : `modules/Domenia-Boards.Model.ps1:208-209 ; modules/Domenia-Charts.UI.ps1:818-899`

### FO-11 — Widgets parc tirés de l'index, sans WMI
*Impact fort, effort L*

- **Constat** : FleetStats ne lit que name, guid, extra et last_logon, et écarte les comptes désactivés. La version 24H2 ou 25H2 n'est connue que pour les postes analysés, et rien ne montre les comptes désactivés, les postes récents ni les mots de passe machine anciens.
- **Proposition** : Indexer operatingSystemVersion, whenCreated et pwdLastSet, déjà lisibles. Widgets « Versions de Windows » sur tout le périmètre, « Comptes ordinateur désactivés », « Créés ces 30 jours », « Mot de passe machine > 60 j », « Serveurs / postes ». Ajouter BitLocker au parc.
- Preuve : `modules/Domenia-Engine.Worker.ps1:141-143 ; Domenia-Core.ps1:14602-14605`

### FO-12 — Restaurer une sauvegarde depuis l'application
*Impact fort, effort L*

- **Constat** : Le guide décrit une restauration manuelle « non outillée et non jouée ». Domenia ne liste même pas les sauvegardes.
- **Proposition** : Lister les sauvegardes dans Base autonome (date, taille, contrôle) avec « Restaurer au prochain démarrage ». Un marqueur fait adopter la sauvegarde au lancement suivant, en mettant la base actuelle de côté.
- Aussi proposé par le Spark (idée 72).
- Preuve : `administrateur.md ch. 18 ; modules/Domenia-Storage.UI.ps1:621-649`

### FO-13 — Copier le résumé pour un ticket
*Impact moyen, effort S*

- **Constat** : Rien ne copie un widget ou le résumé d'un poste. Seul « Copier » existe, caché dans « Détails de la session ». Le technicien recopie score et points à la main.
- **Proposition** : « Copier » dans le menu de chaque widget (texte brut) et « Copier le résumé » dans la barre du tableau : poste, date d'inventaire, score, points, identité.
- Preuve : `modules/Domenia-Widgets.UI.ps1:401-436 ; Domenia-Core.ps1:4449`

### FO-14 — Toutes les associations : filtre et ouverture de fiche
*Impact moyen, effort S*

- **Constat** : La grille n'a ni recherche, ni filtre par qualification, ni compteur. Aucun double-clic n'ouvre l'utilisateur ou le poste.
- **Proposition** : Champ filtre, puces Déclaré / Observé / Contradictoire, compteur. Double-clic : fiche de la colonne cliquée. Clic droit : « Ouvrir l'utilisateur » ou « Ouvrir le poste ».
- Preuve : `Domenia-Core.ps1:5392-5398, 19450-19458`

### FO-15 — Widgets logiciels utiles au support
*Impact moyen, effort M*

- **Constat** : Le modèle ne garde ni la date d'installation (pourtant affichée), ni rien qui réponde à « qu'est-ce qui a changé sur ce poste ? ». La tuile « Installés en plusieurs versions : 0 » occupe la place pour rien.
- **Proposition** : « Installés ces 30 derniers jours », « Composants d'exécution » (VC++, .NET) et « Navigateurs et versions ». Tuiles à 0 masquées ou réduites à une coche.
- Preuve : `modules/Domenia-BoardSoftware.Model.ps1:46-53, 81-89 ; logiciels.png`

### FO-16 — Gérer les sections des tableaux
*Impact moyen, effort M*

- **Constat** : L'ordre des sections suit leur premier widget. On ne peut ni renommer, ni déplacer, ni replier, ni supprimer une section. Un nom vide devient « Mes widgets ».
- **Proposition** : Menu sur le titre de section : Renommer, Monter/Descendre, Replier (mémorisé), Supprimer (widgets déplacés, annulation possible).
- Preuve : `modules/Domenia-Boards.Model.ps1:317-325 ; modules/Domenia-Widgets.UI.ps1:697-701, 800`

### FO-17 — Disposition d'équipe définie par l'admin
*Impact moyen, effort M*

- **Constat** : La disposition par défaut est l'ordre du catalogue codé en dur. Un admin ne peut pas diffuser une disposition type.
- **Proposition** : Clé facultative DefaultLayout par tableau dans la configuration déployée ; « Par défaut » y ramène. Export et import en JSON.
- Aussi proposé par le Spark (idée 68).
- Preuve : `modules/Domenia-Boards.Model.ps1:257-274 ; modules/Domenia-Widgets.UI.ps1:559`

### FO-18 — Actions sur une sélection multiple
*Impact moyen, effort M*

- **Constat** : La grille permet la sélection multiple, mais seules la copie et l'export en tiennent compte. « Revérifier ce poste » se grise dès 2 lignes.
- **Proposition** : Barre contextuelle « 3 postes sélectionnés : Pinger · Qui est connecté ? · Copier · Exporter », avec la même confirmation et la sélection comme périmètre.
- Aussi proposé par le Spark (idée 26).
- Preuve : `Domenia-Core.ps1:4703 ; modules/Domenia-Live.UI.ps1:144-152`

### FO-19 — Comptes : tester réellement le compte Postes
*Impact moyen, effort M*

- **Constat** : Pour le compte Postes, « Tester » et « Activer » font la même authentification AD ; le message le reconnaît. On ne sait pas si le compte est administrateur des postes.
- **Proposition** : Un seul bouton « Activer ». Ajouter « Essayer sur le poste sélectionné » : lecture WMI légère sur un seul poste, sur geste, avec « accès administrateur OK » ou « refusé ».
- Preuve : `modules/Domenia-Accounts.Async.ps1:42-50 ; Domenia-Core.ps1:19247-19262, 5205-5206`

### FO-20 — Première installation outillée
*Impact moyen, effort M*

- **Constat** : L'installateur refuse une destination sans wad/Domenia-Core.ps1 : la première installation se fait à la main (extraire, DEBLOQUER_TOUT.cmd, --check).
- **Proposition** : Un mode -Install vers un dossier vide : copie contrôlée par empreintes, déblocage, --check, raccourcis Bureau et menu Démarrer.
- Preuve : `dev/INSTALLER-MISE-A-JOUR.ps1:180 ; administrateur.md « Première installation »`

### FO-21 — Raccourcis clavier faciles à trouver
*Impact faible, effort S*

- **Constat** : La liste des raccourcis n'existe que dans une ligne technique du journal au démarrage et dans le guide.
- **Proposition** : Ctrl+/ ouvre un panneau « Raccourcis clavier ». Raccourci affiché dans la palette et l'infobulle du menu (« Accueil  Ctrl+1 »). Supprimer la ligne du journal.
- Aussi proposé par le Spark (idée 33).
- Preuve : `Domenia-Core.ps1:15830 (vérifié) ; technicien.md §9`

### FO-22 — Thème automatique et contraste élevé
*Impact faible, effort M*

- **Constat** : Seuls Clair et Sombre existent. Domenia ne lit ni le choix de Windows ni SystemParameters.HighContrast.
- **Proposition** : Ajouter « Automatique » (AppsUseLightTheme, registre local). En contraste élevé, couleurs système.
- Preuve : `Domenia-Core.ps1:3362-3366, 3557-3564`

## Performance (28)

### PF-01 — Tick Live : identité recalculée 12 fois par seconde
*Impact fort, effort S*

- **Constat** : Toutes les 80 ms, Invoke-DomeniaLiveTick appelle Reset-DomeniaLiveIdentity, qui reconstruit la signature avec deux Get-Command, plus Where-Object, Sort-Object et ForEach-Object sur les comptes temporaires.
- **Proposition** : Un compteur de génération des comptes, incrémenté à chaque changement d'identifiants. Recalculer seulement si ce compteur, l'époque ou la base DN changent.
- Preuve : `modules/Domenia-Live.UI.ps1:4-18, 46-48, 55-58, 742-746`

### PF-02 — Résultat LDAP entièrement chargé avant les limites
*Impact fort, effort S*

- **Constat** : foreach ($r in @($collection)) énumère toutes les pages LDAP avant le premier tour. Les arrêts sur MaxObjects et sur le budget de temps ne soulagent donc ni le contrôleur ni la mémoire. Même motif dans d'autres workers.
- **Proposition** : Itérer sur $collection directement (pagination paresseuse), SizeLimit à MaxObjects+1, et disposer chaque SearchResultCollection.
- Preuve : `Domenia-Core.ps1:15486-15490 (vérifié), 7682, 7755, 9573, 10888`

### PF-03 — Vue d'ensemble : ne plus décoder tout le cache à chaque calcul
*Impact fort, effort M*

- **Constat** : À chaque changement d'OU ou relevé, FleetStats lit tous les postes du domaine, filtre l'OU en PowerShell, et décode en JSON toutes les lignes de park_session_cache (jusqu'à 256 Ko chacune), même pour une petite OU : plusieurs secondes sur un grand domaine.
- **Proposition** : Filtrer le DN en SQL (suffixe, COLLATE NOCASE) et ne joindre que les observations de l'OU. Garder en mémoire du worker les observations décodées et ne décoder que les lignes changées, ou ajouter des colonnes de synthèse (présence, utilisateur, disque, build, date). Mesurer sur 5 000 postes en démonstration.
- Preuve : `modules/Domenia-Engine.Worker.ps1:135-170`

### PF-04 — Débit du moteur : plus d'une promotion par tick
*Impact fort, effort M*

- **Constat** : Avec 250 ms par tick, une file de 32 lectures met au moins 8 s à démarrer, même avec des places libres. Douze résultats arrivés ensemble mettent 1,5 s à s'afficher (2 par tick), dans l'ordre d'arrivée : la fiche cliquée peut attendre derrière des sondes de fond.
- **Proposition** : Promouvoir en boucle tant que l'admission dit Start. Remplacer MaxCompletionsPerTick par un budget de temps (environ 25 ms) et traiter par priorité : Write, Explicit, Selection, Background. Mesurer l'attente en file.
- Preuve : `modules/Domenia-Engine.UI.ps1:317-353 ; Domenia-Core.ps1:21479, 21546-21547, 19808-19810`

### PF-05 — Un runspace ouvert par tâche sur le thread de l'interface
*Impact fort, effort M*

- **Constat** : Hors 5 opérations en pool, chaque tâche crée un runspace et y injecte environ 1300 lignes de WorkerCommon (environ 75 Ko). Open() est synchrone sur le Dispatcher : ouvrir une fiche, pinger ou sauvegarder paie ce coût à chaque fois.
- **Proposition** : Étendre les pools à OpenAdObject, TreeChildren, ComputerPing, SelectedPresence, LocalIndexRead, LocalStore. À défaut, un runspace de réserve ouvert hors Dispatcher. Objectif : p95 de RunspaceOpen sous 5 ms.
- Preuve : `Domenia-Core.ps1:21066, 21082-21118, 8210-9178`

### PF-06 — Une pulsation unique au lieu de 30 réveils par seconde
*Impact fort, effort M*

- **Constat** : Neuf minuteries tournent sans tâche : moteur 250 ms, sauvegarde 350 ms, Live 80 ms, réconciliation 250 ms, continuité 700 ms, Fiabilité 500 ms, Accès 500 ms, Assistance 1 s, sondes 2 s. Environ 30 exécutions par seconde au repos, coûteux sur RDS et VDI.
- **Proposition** : Une pulsation possédée par le moteur, avec un intervalle par abonné. Arrêter le minuteur asynchrone sans tâche ni file. Tout suspendre fenêtre réduite. Cible : moins de 3 réveils par seconde au repos. À mener avec FI-05.
- Preuve : `Domenia-Core.ps1:21134-21143, 7596-7599 ; modules/Domenia-Storage.UI.ps1:10-11 ; modules/Domenia-Live.UI.ps1:46-49 ; modules/Domenia-Reconcile.UI.ps1:154-155 ; modules/Domenia-Continuity.UI.ps1:310-326 ; modules/Domenia-Guard.UI.ps1:187-199 ; modules/Domenia-Access.UI.ps1:535 ; modules/Domenia-Support.UI.ps1:303-311`

### PF-07 — SQLite : requêtes préparées pour les écritures en masse
*Impact fort, effort M*

- **Constat** : Le worker construit chaque INSERT par concaténation et l'exécute ligne par ligne avec sqlite3_exec, jusqu'à 250 000 lignes : chaque ligne est réanalysée.
- **Proposition** : Ajouter sqlite3_bind_text, sqlite3_bind_int64 et sqlite3_reset au type natif, préparer un INSERT par table et le réutiliser dans la transaction. Mesurer avec les échantillons IndexBuild existants.
- Preuve : `modules/Domenia-Storage.Worker.ps1:27-33, 276-281, 320-329 ; Domenia-Core.ps1:20231-20262`

### PF-08 — Fenêtre principale chargée deux fois au démarrage
*Impact fort, effort M*

- **Constat** : La prévalidation construit la fenêtre complète (XamlReader.Load et aide de toutes les commandes), puis la ferme. Load-XamlWindow refait tout après la connexion, et le contrôle du XAML passe trois fois sur environ 2700 lignes.
- **Proposition** : Garder l'instance prévalidée (même thread STA), ou réserver la sonde complète à -CheckOnly. Mesurer avec la trace « Prevalidation interface ».
- Preuve : `Domenia-Core.ps1:25808-25820, 6510-6527, 6541-6562, 6581-6583`

### PF-09 — Journal disque écrit hors du fil de l'interface
*Impact fort, effort M*

- **Constat** : À chaque ligne, Write-AppLog fait Initialize-DomeniaDataStore, Test-Path, Get-Item et AppendAllText sur le Dispatcher, et masque le texte deux fois. Write-AppLog pèse 792 chemins sur 3874 dans la dette de blocage, Add-DomeniaUiLog 264.
- **Proposition** : File en mémoire vidée toutes les 500 ms et à la fermeture. Contrôle de taille toutes les 200 lignes. Un seul masquage. Clé de dette : (fonction, appel bloquant) plutôt que le chemin complet.
- Preuve : `Domenia-Core.ps1:17133-17164, 2167 ; dev/tools/ui-blocking-debt-baseline.json`

### PF-10 — Get-Command retiré des chemins chauds
*Impact moyen, effort S*

- **Constat** : 67 appels Get-Command … SilentlyContinue, dont plusieurs à chaque tick ou tâche (Update-TaskUi, Request-DomeniaDashboardRefresh, Complete-UiTasks, Get-DomeniaFeatureFlag). Le chargeur fermé garantit pourtant ces fonctions.
- **Proposition** : Résoudre une fois des booléens $script:Has… après le chargement, mettre en cache les drapeaux Features, et interdire Get-Command dans les gestionnaires de minuterie par une règle d'audit.
- Preuve : `Domenia-Core.ps1:9208, 24153, 24167, 21410, 21576, 6524 ; modules/Domenia-Engine.UI.ps1:181, 397 ; modules/Domenia-Common.Model.ps1:177-190`

### PF-11 — Détails masqués de l'Accueil recalculés à chaque tâche
*Impact moyen, effort S*

- **Constat** : À chaque départ ou fin de tâche, y compris les sauvegardes, Update-TaskUi déclenche Update-Dashboard, qui réécrit une quinzaine de champs et parcourt toute la branche. Ces champs sont dans « Détails de la session », fermé par défaut.
- **Proposition** : Mettre à jour ces champs à l'ouverture de l'expander et tant qu'il reste ouvert. Retirer l'appel de Update-TaskUi.
- Preuve : `Domenia-Core.ps1:9257, 24146-24210, 7064-7081, 4445`

### PF-12 — Suivi des opérations : grille remplacée toutes les 500 ms
*Impact moyen, effort S*

- **Constat** : La signature de la grille inclut la durée formatée, qui change chaque seconde. ItemsSource est donc remplacé sans cesse : sélection, défilement et focus sautent.
- **Proposition** : Signature sur Id et State seulement. Lignes typées notifiantes, comme Domenia.Live.ResultRow, et durée mise à jour sur place.
- Preuve : `modules/Domenia-Experience.UI.ps1:85-90 ; modules/Domenia-Experience.Model.ps1:116-124`

### PF-13 — Journal technique TxtLog sans limite
*Impact moyen, effort S*

- **Constat** : Write-AppLog ajoute chaque ligne à TxtLog sans jamais le purger, alors que le journal de session est borné à 2500 lignes. Une longue journée gonfle la mémoire et ralentit ScrollToEnd.
- **Proposition** : Même tampon circulaire que le journal de session (par exemple 5000 lignes), ou supprimer TxtLog, qui double le journal visible et le fichier.
- Preuve : `Domenia-Core.ps1:17139-17142, 2174-2193, 6205`

### PF-14 — Arbre : une requête AD par nœud parcouru au clavier
*Impact moyen, effort S*

- **Constat** : Chaque sélection dans l'arbre lance une recherche : les flèches envoient une requête par nœud traversé. Même chose pour Type d'objet et Sous-OU.
- **Proposition** : Temporiser d'environ 300 ms la sélection au clavier et les changements de type ; garder l'immédiat à la souris.
- Preuve : `Domenia-Core.ps1:6859-6867, 19324-19326`

### PF-15 — Filtre local calculé une fois par ligne
*Impact moyen, effort S*

- **Constat** : Update-DomeniaLiveFilter recolle 8 champs par ligne sur le fil de l'interface, toutes les 400 ms pendant le chargement, jusqu'à 20 000 lignes. La règle de présence est dupliquée.
- **Proposition** : Une clé de recherche en minuscules calculée à l'ajout et à chaque nouvelle observation. Réutiliser Test-DomeniaPresenceMatch.
- Preuve : `modules/Domenia-Live.UI.ps1:243-275 ; modules/Domenia-Live.Model.ps1:128-137`

### PF-16 — Relations rechargées seulement quand la page est visible
*Impact moyen, effort S*

- **Constat** : Chaque sélection dans Rechercher appelle Refresh-DomeniaRelationViews, qui relie DgAllLinks à toutes les associations et recalcule les qualifications, même page Relations cachée.
- **Proposition** : Noter « à rafraîchir » tant que la page est cachée, et rafraîchir à l'ouverture.
- Preuve : `modules/Domenia-Relations.UI.ps1:74-81, 289-305`

### PF-17 — Comptes de la reconstruction calculés par le worker
*Impact moyen, effort S*

- **Constat** : Après « Mettre à jour tout », Complete-DomeniaIndexBuildUi passe deux fois Where-Object sur jusqu'à 60 000 lignes, sur le Dispatcher : l'interface se fige environ une seconde.
- **Proposition** : Le worker renvoie UserCount et ComputerCount, qu'il connaît déjà.
- Preuve : `Domenia-Core.ps1:15262-15272, 15540-15546`

### PF-18 — Chaque module analysé deux fois au chargement
*Impact moyen, effort S*

- **Constat** : Le chargeur fait ParseFile sur les 60 modules, puis les dot-source, ce qui les réanalyse. Assert-DomeniaRuntimeImports appelle ensuite Get-Item Function: pour chaque fonction.
- **Proposition** : Dot-sourcer le ScriptBlock issu de l'AST déjà analysé (en vérifiant que l'origine fichier est gardée), ou réserver ParseFile à -CheckOnly. Lire Function: une fois. Chronométrer le chargeur.
- Preuve : `Domenia-Modules.ps1:1186-1201, 1222-1237, 1248-1280`

### PF-19 — Contrôle d'empreintes plus rapide et liste requise générée
*Impact moyen, effort S*

- **Constat** : Domenia-Start appelle Get-FileHash fichier par fichier et remonte tous les dossiers parents. La liste requise est écrite à la main : Migration.UI y figure deux fois, et 14 fichiers (Charts, Widgets, Boards, Probes…) manquent.
- **Proposition** : Une seule instance SHA256 en lecture séquentielle, cache des dossiers contrôlés. Liste dérivée de Get-DomeniaRuntimeModulePlan. Durée dans la trace de démarrage.
- Preuve : `Domenia-Start.ps1:23-38, 46-104`

### PF-20 — Tableaux : ne redessiner que le widget modifié
*Impact moyen, effort M*

- **Constat** : Chaque déplacement ou changement de taille reconstruit tout le tableau. Le catalogue est réanalysé par widget. Chaque widget crée deux boutons par XamlReader.Parse et un menu complet. Les mesures des requêtes utilisent un $results += quadratique. Chaque carte porte une ombre animée, lente en RDP.
- **Proposition** : Catalogue et modèles de boutons en cache (ressources). Menu créé à l'ouverture. List[object] et mesures mémorisées par (requête, OU, version). Redessin du seul widget touché. Ombre statique, effets coupés si IsRemoteSession.
- Aussi proposé par le Spark (idée 17).
- Preuve : `modules/Domenia-Widgets.UI.ps1:80-126, 374-396, 475, 856 ; modules/Domenia-Boards.Model.ps1:82-99 ; modules/Domenia-Charts.UI.ps1:261-306`

### PF-21 — Agrégation du parc faite dans le worker
*Impact moyen, effort M*

- **Constat** : Complete-DomeniaFleetDashboard appelle Get-DomeniaFleetBoardData sur le Dispatcher. Le modèle refiltre l'OU déjà filtrée et invoque des scriptblocks pour chaque poste et observation.
- **Proposition** : Agréger dans le worker FleetStats et ne renvoyer que compteurs et cibles. Sinon, code en ligne sans second filtrage. Cible : rappel sous 120 ms.
- Preuve : `modules/Domenia-Dashboard.UI.ps1:170-196 ; modules/Domenia-BoardFleet.Model.ps1:30-120`

### PF-22 — Logiciels lus deux fois
*Impact moyen, effort M*

- **Constat** : L'inventaire rapide collecte déjà jusqu'à 250 logiciels, mais l'onglet Logiciels repart de zéro avec une 2e requête au poste.
- **Proposition** : Remplir l'onglet avec l'inventaire (« Liste de l'inventaire de 12:24 · Actualiser »), ou retirer les logiciels de l'inventaire rapide.
- Preuve : `Domenia-Core.ps1:11726, 13556`

### PF-23 — Contexte worker mis en cache
*Impact moyen, effort M*

- **Constat** : Get-WorkerContext recrée environ 70 propriétés (25 Get-CfgValue, réglages WAPT et sécurité) à chaque départ sur le Dispatcher, même pour LocalStore.
- **Proposition** : Partie statique en cache par génération de configuration (WorkerContextStatic existe), identités calculées par opération, contexte minimal pour les opérations locales : moins de secrets en circulation.
- Preuve : `Domenia-Core.ps1:21697-21812`

### PF-24 — Une seule source pour les aides : XAML allégé d'un quart
*Impact moyen, effort M*

- **Constat** : Les attributs ToolTip, HelpText et ShowOnDisabled pèsent environ 95 Ko sur les 359 Ko du XAML. help.json les remplace au démarrage de toute façon, et les textes divergent (BtnAccessRecovery).
- **Proposition** : help.json devient la source unique. Un script retire ces attributs du XAML et un test empêche leur retour.
- Preuve : `Domenia-Core.ps1:3566-6345 ; modules/Domenia-UX.UI.ps1:85-91`

### PF-25 — Disposition des grilles enregistrée seulement si elle change
*Impact faible, effort S*

- **Constat** : Save-DomeniaGridLayout est branché sur chaque PreviewMouseLeftButtonUp : chaque clic sur une ligne sérialise et écrit toutes les dispositions.
- **Proposition** : Enregistrer au réordonnancement, en fin de redimensionnement ou à la fermeture si quelque chose a changé.
- Preuve : `modules/Domenia-Continuity.UI.ps1:41, 45-55`

### PF-26 — SQLite : maintenance sortie des lots
*Impact faible, effort S*

- **Constat** : Chaque lot relit deux fois schema_info, exécute CREATE TABLE IF NOT EXISTS park_session_cache par observation et purge operation_runs à chaque COMMIT.
- **Proposition** : Créer la table dans le schéma. Purger seulement après insertion et au-delà de 11 000 lignes. Vérifier le schéma une fois par session.
- Preuve : `modules/Domenia-Storage.Worker.ps1:266-269, 290, 337 ; Domenia-Core.ps1:20479-20530`

### PF-27 — Membres de groupe lus deux fois
*Impact faible, effort S*

- **Constat** : Le premier RefreshCache inclut member et memberOf (jusqu'à 5000 valeurs), puis les ignore et relit tout par plages de 1000.
- **Proposition** : Exclure member et memberOf du premier RefreshCache et lire par plages de 1500.
- Preuve : `Domenia-Core.ps1:8439-8475`

### PF-28 — Navigation : boutons et aides en cache
*Impact faible, effort S*

- **Constat** : À chaque changement de page, Sync-DomeniaUxNavigation parcourt plus de 636 contrôles nommés avec une regex et recalcule l'aide de chaque bouton.
- **Proposition** : Mettre en cache la liste des boutons de navigation et leurs textes dès l'initialisation.
- Preuve : `modules/Domenia-UX.UI.ps1:142-164`

## Moteur (9)

### MO-01 — Score du parc proportionnel au nombre de postes
*Impact fort, effort M*

- **Constat** : Le parc reprend la formule du poste : 100 − 25 par règle critique. Un seul poste Windows 10 sur 2000 donne 75 « Critique », et 4 postes sur 26 donnent 30/100. Le score ne dit pas quelle part du parc va mal.
- **Proposition** : Score = part des postes sans point critique ni à surveiller, avec un verdict par paliers. Afficher « 22 postes sur 26 sans problème » et garder les règles pour le détail.
- Preuve : `modules/Domenia-Boards.Model.ps1:171-191 ; accueil.png`

### MO-02 — « Mettre à jour tout » lit tout le domaine (à arbitrer)
*Impact fort, effort M*

- **Constat** : La reconstruction de la base lit en Subtree, depuis la racine, tous les utilisateurs et postes (jusqu'à 200 000 objets). Cela heurte la règle « jamais tout le domaine », alors que l'Accueil ne suit plus que l'OU de Rechercher.
- **Proposition** : Restreindre la mise à jour à l'OU de Rechercher, avec un delta uSNChanged par OU, renommer le bouton « Mettre à jour cette OU » et annoncer le nombre estimé. À arbitrer : la recherche « Partout » et les suggestions locales s'appuient sur l'index du domaine.
- Preuve : `Domenia-Core.ps1:15403-15408, 15478-15486 (vérifié : Subtree depuis BaseDn), 15297-15320 ; base-autonome.png`

### MO-03 — File de sauvegarde : minuterie à la demande, ordre garanti
*Impact moyen, effort S*

- **Constat** : La minuterie de 350 ms tourne même file vide et parcourt les tâches avec Where-Object. Pending est une hashtable : l'ordre d'envoi n'est pas garanti. Chaque petit lot ouvre un runspace neuf, et le seuil « 4 tâches » est codé en dur.
- **Proposition** : Armer la minuterie à la mise en file et l'arrêter quand Pending est vide. Dictionnaire ordonné pour un vrai premier entré, premier sorti. Regrouper sur 1 à 2 s. Dériver le seuil de Get-DomeniaEngineLimits.
- Preuve : `modules/Domenia-Storage.UI.ps1:8-11, 101-172`

### MO-04 — « Dénombrer » ne doit plus compter tout l'annuaire
*Impact moyen, effort S*

- **Constat** : Le bouton lance cinq requêtes Subtree sur la racine (utilisateurs, postes, groupes, OU, contacts) et matérialise chaque collection juste pour un nombre.
- **Proposition** : Supprimer le bouton ou le limiter à l'OU de Rechercher. Les totaux du domaine peuvent venir de la base locale, avec leur date, sans requête AD.
- Preuve : `Domenia-Core.ps1:12492-12510, 19561`

### MO-05 — La file doit tenir compte du budget du fournisseur
*Impact moyen, effort M*

- **Constat** : Select-DomeniaNextQueuedTask choisit sur la seule classe. Le budget du fournisseur n'est vérifié qu'au départ, qui lève une erreur : la tâche est retirée de la file au lieu d'attendre (par exemple un LiveCache promu pendant un LocalStore).
- **Proposition** : Passer la charge par fournisseur à la sélection et sauter les candidats saturés en les gardant en file. Une erreur seulement pour un refus durable.
- Preuve : `modules/Domenia-Engine.Model.ps1:212-224, 431-457 ; modules/Domenia-Engine.UI.ps1:109-114, 339-351`

### MO-06 — Moins de bruit dans les points du poste
*Impact moyen, effort M*

- **Constat** : Toute erreur du journal Système sur 3 jours lève « À surveiller », ce qui touche presque tous les postes (DCOM 10016…). Les services automatiques arrêtés sont rouges, même à démarrage différé ou sur déclencheur.
- **Proposition** : Liste d'exclusions (ID d'événements, services) dans un JSON. Erreurs génériques en « Information » ; « À surveiller » pour les sources critiques (disque, NTFS, Kernel-Power 41). Exclure les services sur déclencheur.
- Preuve : `modules/Domenia-BoardComputer.UI.ps1:237-238, 254-258, 300-321`

### MO-07 — « Charger la suite » : lire seulement la page suivante
*Impact moyen, effort M*

- **Constat** : La même requête est relancée avec une limite doublée (100, 200, 400…) : 7 clics et environ 25 000 lignes relues pour atteindre 12 800. New-DomeniaContinuation (reprise par nom) est écrite mais jamais utilisée.
- **Proposition** : Brancher la reprise par nom. Proposer aussi « Charger jusqu'à 1 000 » en un clic.
- Preuve : `modules/Domenia-Live.UI.ps1:867-876 ; modules/Domenia-Search.Model.ps1:342-361`

### MO-08 — Ping d'une liste beaucoup plus rapide
*Impact moyen, effort M*

- **Constat** : Le relevé admet un poste par tick de 250 ms, 4 en parallèle, avec 20 s de délai par worker, même en ping seul. 500 postes éteints prennent plusieurs minutes.
- **Proposition** : Pour « Pinger la liste », un seul worker qui envoie les échos en parallèle (SendPingAsync, 32 à la fois, délai 1 s). Garder 4 en parallèle pour les lectures WMI.
- Preuve : `modules/Domenia-Park.UI.ps1:110, 124-147`

### MO-09 — Logiciels par utilisateur sans WinRM
*Impact moyen, effort M*

- **Constat** : La portée utilisateur ne lit que les ruches HKU déjà chargées, et seulement via WinRM, alors que l'infobulle annonce « le profil de chaque utilisateur » et que la case est cochée. Sans WinRM : une ligne INDISPONIBLE et une tentative de repli à chaque fois.
- **Proposition** : Lire HKU par StdRegProv (0x80000003) sur la session DCOM déjà ouverte. Infobulle : « utilisateurs connectés ». En cas d'échec, « non lu », sans repli.
- Preuve : `Domenia-Core.ps1:13343-13354, 5703`

## Code (14)

### CD-01 — Sortir le XAML et les workers du cœur, vues lourdes à la demande
*Impact fort, effort L*

- **Constat** : Get-MainXaml est une here-string de 2779 lignes (environ 359 Ko), plus 230 lignes de XAML de connexion. Elle est analysée d'un bloc au démarrage, Outils, Comptes et Relations compris. Le cœur fait 25 884 lignes, alors que la règle du dépôt veut des vues .xaml séparées.
- **Proposition** : Dans l'ordre : Domenia-Main.xaml sans logique ; WorkerCommon et workers (texte identique, empreintes inchangées) dans Domenia-*.Worker.ps1 ; connexion dans Domenia-Login.UI.ps1 ; Outils, Comptes et Relations en .xaml chargés au premier affichage, comme Initialize-DomeniaSupportUi. Objectif : un cœur sous 15 000 lignes. Prévoir FI-14.
- Aussi proposé par le Spark (idée 74).
- Preuve : `Domenia-Core.ps1:3567-6346, 8210, 11130, 13066, 12182, 24500-25520 ; CLAUDE.md (vues .xaml séparées)`

### CD-02 — Retirer le code mort du cœur, de l'index et des requêtes
*Impact moyen, effort S*

- **Constat** : Une cinquantaine de fonctions n'ont aucune référence (environ 980 lignes) : Get-DomeniaParkPriority, Show-DomeniaObjectPicker, Get-LoginXamlLegacy, Stop-UiTask, Load-DomeniaIndex, Upsert-DomeniaIndexEntryRow, Get-DomeniaIndexSuggestionText (toujours vide)… Get-DomeniaProbeVisuals n'est appelée nulle part et la requête sec.uac est déclarée puis filtrée. S'y ajoutent 18 blocs de 4 lignes vides ou plus.
- **Proposition** : Un commit de suppression dédié, avec mise à jour de Domenia-Modules.ps1, des manifestes et d'audit_preload. Ajouter tools/audit_dead_functions.py au contrôle hors Windows.
- Preuve : `Domenia-Core.ps1:983, 1348, 2107, 3193, 7482, 7594, 14080, 14533, 15395, 16657, 21422 ; modules/Domenia-Probes.Model.ps1:40, 69, 72-81 ; Domenia-Modules.ps1:1084 (vérifié)`

### CD-03 — Retirer les restes du balayage du parc
*Impact moyen, effort S*

- **Constat** : ParkSweep (retiré le 05/10) et PresenceScan sont enregistrés parmi les 68 opérations épinglées mais jamais appelés, et Safety.Model les liste encore. Start-DomeniaOnlinePark garde des branches Scope='Park' inaccessibles (« Detecter sur tout le parc »).
- **Proposition** : Retirer les deux opérations (registre à 66), leurs fonctions et les branches « tout le parc ». La surface d'exécution et le ch. 15 du guide diminuent d'autant.
- Preuve : `dev/tools/operation-contracts.json (vérifié) ; Domenia-Core.ps1:2552, 15120-15139 ; modules/Domenia-Park.UI.ps1:41, 52, 59, 88, 93 ; modules/Domenia-Safety.Model.ps1:19-25`

### CD-04 — Supprimer les contrôles cachés et onglets morts
*Impact moyen, effort M*

- **Constat** : BtnAccountsHeader « Identites » est toujours masqué. BtnUxNavSupport et BtnUxStep3 visent une route absente (TabSupport). LblStatus et LblPrivilegeTop ne sont jamais visibles. TabCmdlets, retiré, garde 112 références. TxtBranchSearch, CmbObjectFilter, TxtBranchLimit et BtnClearBranch sont cachés mais câblés. ChkUserScanPark, deux boutons invisibles et la case RDP « non disponible » restent dans Relations. help.json a des entrées orphelines.
- **Proposition** : Supprimer ces éléments et leurs gestionnaires après vérification des appels. Pour Get-DomeniaStatusGlyph, appelée seulement par les tests : la brancher sur les colonnes d'état (icône et mot) ou la retirer.
- Aussi proposé par le Spark (idée 87).
- Preuve : `Domenia-Core.ps1:4214, 4329-4340, 4657-4666, 5332, 5339, 5409-5410, 6138, 6273, 16673-16690 ; modules/Domenia-UX.UI.ps1:122, 161 ; modules/Domenia-Shell.Model.ps1:1045 ; modules/Domenia-Relations.UI.ps1:757`

### CD-05 — Une seule palette de couleurs
*Impact moyen, effort M*

- **Constat** : Trois sources se contredisent : les ressources XAML, la table d'Apply-DomeniaTheme (aussitôt écrasée par Set-DomeniaUxPalette) et 119 couleurs hex dans le cœur. Les couleurs d'état des graphiques diffèrent entre Charts.UI et Boards.Model.
- **Proposition** : SupportSuite.UI.json devient l'unique source, avec jetons d'état et séries pastel (DS-14). Supprimer la table d'Apply-DomeniaTheme et remplacer les hex par des jetons.
- Preuve : `Domenia-Core.ps1:3570-3597, 3420-3450, 3519-3521, 2342-2354 ; modules/Domenia-Charts.UI.ps1:22, 32 ; modules/Domenia-Boards.Model.ps1:107`

### CD-06 — Relations : supprimer l'ancien chemin RC1.10.7
*Impact moyen, effort M*

- **Constat** : RelationsSymmetry et DetectionPreview gardent deux chemins dans presque chaque fonction. L'ancien réintroduit la confiance en pourcentage, la confirmation en fenêtre et un élargissement silencieux du périmètre.
- **Proposition** : Fixer les deux drapeaux à vrai et supprimer les branches « -not $model » et l'élargissement automatique.
- Preuve : `modules/Domenia-Relations.UI.ps1:1-5, 919-930, 1100-1110, 1157-1183`

### CD-07 — Une table déclarative des opérations
*Impact moyen, effort M*

- **Constat** : Classe, fournisseur, identités, isolement, partage et pool sont décidés par des tableaux codés en dur, recréés à chaque appel. SessionsList est à la fois distant et local. Ajouter une opération touche six listes.
- **Proposition** : Une table unique (Opération → Classe, Fournisseur, Identités, Pool, Partage, Isolable), lue une fois, qui génère aussi le test de référence.
- Preuve : `modules/Domenia-Engine.Model.ps1:115-127, 175-184, 274-329, 349-362 ; Domenia-Core.ps1:21066`

### CD-08 — Couche SQLite copiée sept fois
*Impact moyen, effort M*

- **Constat** : Open-DomeniaDatabase et ses aides existent dans le cœur, Live.Model, Migration.Worker et 4 fois dans Storage.Worker. Une copie a déjà divergé (sans drapeau CREATE, busy_timeout à 300).
- **Proposition** : Étendre update_migration_worker.py pour générer toutes les copies depuis une source, et un test qui échoue si deux copies diffèrent. Corrige aussi FI-12.
- Preuve : `Domenia-Core.ps1:20289 ; modules/Domenia-Live.Model.ps1:329 ; modules/Domenia-Migration.Worker.ps1:40 ; modules/Domenia-Storage.Worker.ps1:34, 378, 584, 802 ; dev/tools/update_migration_worker.py`

### CD-09 — 995 blocs catch vides
*Impact moyen, effort M*

- **Constat** : 802 « catch { } » dans le cœur et 193 dans les modules : une panne réelle (thème, fiche, stockage) peut passer sans trace.
- **Proposition** : Write-DomeniaSwallowed 'contexte' $_ (DEBUG, échantillonné) partout où l'erreur n'est pas attendue, et un audit Python qui suit cette dette comme ui-blocking.
- Preuve : `Domenia-Core.ps1 (802), modules/*.ps1 (193)`

### CD-10 — Trois fenêtres de connexion à unifier
*Impact moyen, effort M*

- **Constat** : Trois gabarits divergent (ancien, standard, debug), avec trois formulations de la même case dont une fautive (« Se souvenir uniquement de lidentifiant »), et des tailles et polices différentes.
- **Proposition** : Un seul gabarit ; le mode Debug n'ajoute que le volet de diagnostic. Corriger la case (voir UX-28).
- Preuve : `Domenia-Core.ps1:2107-2154, 25195-25313, 25317-25379, 25350 ; connexion.png`

### CD-11 — GPUpdate et Redémarrage : repli inaccessible
*Impact faible, effort S*

- **Constat** : $DomeniaWriteDispatched est mis à vrai avant Invoke-Command et Restart-Computer : le repli par tâche planifiée n'est jamais atteint.
- **Proposition** : Supprimer ce repli (une écriture n'est jamais rejouée) et afficher en cas d'échec « Non envoyé : le poste n'accepte pas la commande à distance ».
- Preuve : `Domenia-Core.ps1:17097, 17108`

### CD-12 — Erreur d'une tâche analysée trois fois
*Impact faible, effort S*

- **Constat** : Complete-UiTasks applique une regex, Get-DomeniaStructuredError et Get-DomeniaErrorDecision ; Register-DomeniaTaskOutcome refait deux fois Get-DomeniaStructuredError, et les besoins de compte sont calculés deux fois.
- **Proposition** : Calculer l'erreur structurée une fois, la stocker sur le job et la réutiliser.
- Preuve : `Domenia-Core.ps1:21600-21625 ; modules/Domenia-Engine.UI.ps1:356-391`

### CD-13 — Trois copies de l'échappement LDAP
*Impact faible, effort S*

- **Constat** : Escape-LdapValue, Escape-WLdap et ConvertTo-DomeniaLdapLiteral sont identiques, de même que Get-DomeniaParentDn et Get-WParentDn.
- **Proposition** : Utiliser la version Model côté interface (9 appels) et générer la copie worker depuis le Model.
- Preuve : `Domenia-Core.ps1:1429, 8364, 7725, 21910 ; modules/Domenia-Search.Model.ps1:6`

### CD-14 — Outil de contrats : ajout et retrait assistés
*Impact faible, effort S*

- **Constat** : update_worker_contracts.py refuse tout écart de liste : retirer une opération (CD-03) impose d'éditer à la main le JSON, Get-DomeniaWorkerOperationHashes et l'empreinte du registre.
- **Proposition** : Options --add OP FONCTION et --remove OP qui mettent à jour les trois endroits, affichent le diff et exigent --apply.
- Preuve : `dev/tools/update_worker_contracts.py:19-33`

## Tests (8)

### TE-01 — Contrôle automatique de l'orthographe d'interface
*Impact moyen, effort S*

- **Constat** : Aucun audit ne détecte un libellé sans accent, sans apostrophe ou tutoyé : chaque correction peut régresser au lot suivant.
- **Proposition** : tools/audit_wording.py : lire Content, Text, Header et ToolTip du XAML, Set-Status, Set-DomeniaContextHint et help.json ; refuser une liste de mots (Etat, Derniere, Detecter, Perimetre, Synthese, resultat…), les motifs « d »/« l »/« n » suivis d'un mot et les impératifs tutoyés. Partir de l'existant comme référence et faire baisser le compte.
- Preuve : `tests/audit_ui.py et audit_theme.py ne contrôlent pas le texte ; dev/tools/`

### TE-02 — D029 : assertion toujours vraie
*Impact moyen, effort S*

- **Constat** : Dans « mesure native en runspace », do{…;$turns++}while rend $turns -gt 0 toujours vrai. Le plafond fixe de 10 s pour 10 000 lignes casse dans une VM chargée.
- **Proposition** : Vérifier que le Dispatcher a réellement tourné (compteur d'un DispatcherTimer pendant IsCompleted faux). Plafond à 60 s, durée sortie comme mesure.
- Preuve : `tests/Test-DomeniaWiringCache.ps1:2810-2825`

### TE-03 — Seuils en millisecondes dans les tests du moteur
*Impact moyen, effort S*

- **Constat** : Des assertions dépendent de la charge de la VM : moins de 50 ms pour une saisie, de 1500 ms pour un rappel, de 250 ms pour Start-DomeniaStorageWork.
- **Proposition** : Preuves structurelles (aucun appel bloquant atteint, via UiBlocking) ou médiane de 5 essais avec tolérance, rapportée comme mesure.
- Preuve : `tests/Test-DomeniaWiringMoteur.ps1:503-514, 530-534, 928-933`

### TE-04 — Référence de tests périmée et suite Thème obsolète
*Impact moyen, effort S*

- **Constat** : CLAUDE.md compare encore à la référence r1 (1215 réussis, 79 échecs), alors que la campagne du 05/10 donne 2365 réussis et 0 échec. Test-DomeniaTheme teste Get-LoginXamlLegacy, une fonction morte.
- **Proposition** : Retirer Get-LoginXamlLegacy de la suite. Après la prochaine campagne en VM, figer une référence par nom de test (compare_runs.py) et la citer dans CLAUDE.md.
- Preuve : `CLAUDE.md (Vérifications) ; tests/Test-DomeniaTheme.ps1:29, 154 ; dev/engineering/d120/lab/compare_runs.py`

### TE-05 — Banc de charge du moteur en démonstration
*Impact moyen, effort M*

- **Constat** : Aucune suite ne mesure le débit du moteur ni le coût au repos : 1 promotion par tick ou 30 réveils par seconde passent inaperçus.
- **Proposition** : Test-DomeniaEngineLoad.ps1 en démonstration (Demo.LatencyMs=200) : 40 lectures, 1 écriture refusée proprement, durée totale, attente maximale en file, p95 du Dispatcher, moins de 3 ticks par seconde au repos. À exécuter en VM.
- Preuve : `Domenia-Core.ps1:19743-19746 ; modules/Domenia-Guard.UI.ps1:189-198 ; tests/ (aucune suite de charge)`

### TE-06 — Modèles sans tests de règles
*Impact moyen, effort M*

- **Constat** : Probes.Model (transformations GB, DaysSince, Year, Map, Release), Live.Model (24 fonctions), Park.Model, Demo.Model et Dossier.Model ne sont chargés par aucun test de tests/rules.
- **Proposition** : Probes.Tests.ps1 (chaque transformation, valeur vide, erreur, Map inconnue) et Live.Tests.ps1, inscrits dans Test-DomeniaRules.
- Preuve : `tests/Test-DomeniaRules.ps1:23 ; modules/Domenia-Probes.Model.ps1:92-117`

### TE-07 — Tests de règles pour les corrections des tableaux
*Impact faible, effort S*

- **Constat** : Aucune règle ne vérifie la cohérence verdict/couleur, le comptage unique des utilisateurs, l'état effectif du pare-feu, l'exemption LTSC ni le texte du disque.
- **Proposition** : Boards.Tests : verdict cohérent avec un point à surveiller. BoardFleet.Tests : même LinkUser sur 2 postes = 1 utilisateur, DN hors postes actifs ignoré, LTSC non critique. Cas pare-feu stratégie=1 / local=0.
- Preuve : `tests/rules/Boards.Tests.ps1 ; tests/rules/BoardFleet.Tests.ps1:46-52`

### TE-08 — Test d'interface lié à l'écran 1024×768 de la VM
*Impact faible, effort S*

- **Constat** : L'aperçu -Verify force une largeur de 1600 sur un écran réel de 1024×768 : « Panneau latéral en grande largeur » échoue dans la référence du labo.
- **Proposition** : Simuler la zone de travail comme Test-DomeniaGeometry (tailles imposées, MaxWidth levé), ou mesurer dans un conteneur de taille fixe.
- Preuve : `maintenance/Preview-DomeniaUi.ps1:349-356 ; tests/Test-DomeniaGeometry.ps1:110-120 ; dev/engineering/d120/lab/baseline-5.1-r1-summary.json`

## Documentation (1)

### DO-01 — Captures du guide produites par le vrai formatage
*Impact moyen, effort S*

- **Constat** : capture-guides.ps1 injecte des textes que l'application ne produit pas : « Console lue », « Sans reponse », « A jour », « Compte ordinateur standard », « Service informatique », « En ligne (ping 3 ms) ». Le guide montre donc des libellés introuvables.
- **Proposition** : Construire les lignes avec les fonctions du modèle (Get-DomeniaLivePresenceView, Get-DomeniaLiveObservationView, formateurs de CO-22 et UX-14). Contrôle : toute valeur injectée égale la sortie du formateur réel.
- Preuve : `guides/captures/capture-guides.ps1:175, 231-234, 258-259 ; recherche.png ; fiche-poste.png`

## Idées du Spark en plus (23)

### SP-01 — Barre de recherche : dire quoi chercher, pas seulement où
*Impact fort, effort S ; idée 1 du Spark, vérifiée dans le code*

- **Proposition** : Remplacer le texte d'attente « Rechercher dans tout le domaine… » par « Personne, poste ou groupe, dans tout le domaine… », qui garde la portée, et mettre à jour guides/technicien.md:18, 20 et 365.
- **Vérification** : Le placeholder est bien 'Rechercher dans tout le domaine…' (dev/wad/Domenia-Core.ps1:4262) et il dit où l'on cherche, pas quoi. Mais la portée est voulue : la recherche ignore l'OU et les filtres (Core:4253, 4275 ; vue Rechercher : 'La barre du haut cherche partout'). Elle renvoie aussi des groupes (guides/images/recherche.png). La proposition perd ces deux informations.

### SP-02 — Vue compacte de six colonnes par défaut dans les résultats
*Impact fort, effort S ; idée 11 du Spark, vérifiée dans le code*

- **Proposition** : Afficher par défaut Type, Nom, Utilisateur connecté, Association mémorisée, Présence réseau et État, les autres colonnes restant réactivables par le menu d'en-tête avec largeur et position conservées (Resolve-DomeniaColumnPreferences).
- **Vérification** : DgObjects a 18 colonnes (Core:4717-4747). Les vues D084 n'en masquent que quelques-unes : 18 en mixte, 16 pour les postes, 14 pour les utilisateurs (Domenia-Shell.Model.ps1:383-395). Il n'y a aucun sélecteur de colonnes, et la capture recherche.png montre un défilement horizontal. En revanche, 'Allumé' est faux : la présence est une réponse réseau. 'Poste connu' est faux pour une ligne poste : l'association y donne l'utilisateur.

### SP-03 — En-tête de page : vérifier le rognage à 960 px
*Impact fort, effort M ; idée 7 du Spark, à préciser*

- **Proposition** : Vérifier à 960 px, menu ouvert et à 150 %, si la colonne Lecture seule / profil est rognée et, si oui, passer ce WrapPanel sous le titre en mode Compact, sans rendre variables les emplacements fixes de la barre d'activité.
- **Vérification** : MinWidth=504 existe bien (Core:4312), mais c'est un invariant voulu : emplacements fixes, aucun voisin ne bouge, Annuler n'est jamais rogné (Core:4310 ; Domenia-Shell.Model.ps1:121-123 et 184-190). Il est vérifié par Test-DomeniaWiringInterface.ps1:265. Une adaptation en largeur et en hauteur existe déjà (Domenia-UX.UI.ps1:222-294 et 488-500). Aucun cas d'échec concret n'est cité.

### SP-04 — AD injoignable signalé dans le badge de session
*Impact fort, effort M ; idée 37 du Spark, vérifiée dans le code*

- **Proposition** : Quand l'AD est injoignable, faire afficher à UxDomainBadge « AD injoignable depuis HH:MM · données déjà lues seulement », puis revenir seul à « Session AD · domaine » au prochain succès, sans relance automatique ni bandeau.
- **Vérification** : La source « base locale » est déjà indiquée sur l'Accueil : « Base autonome locale et derniers releves » (Dashboard.UI.ps1:194, Core:4432, capture accueil.png). La perte de l'AD ($script:DirectoryReachability.Offline, Engine.UI.ps1:373-378) n'apparaît qu'en infobulles (Core:22471, Core:22486, Selection.UI.ps1:211-215). Le terme « dossier local » n'existe pas dans Domenia.

### SP-05 — Copier les lignes sélectionnées « Pour un ticket »
*Impact fort, effort M ; idée 48 du Spark, vérifiée dans le code*

- **Proposition** : Ajouter au menu Copier de Rechercher l'entrée « Pour un ticket » : une ligne lisible par objet sélectionné (Type · Nom · Compte · Présence · Utilisateur console · OU), sans GUID ni champ interne, passée par Protect-DomeniaSecretText.
- **Vérification** : Copier > « La ou les lignes sélectionnées » produit « Name=…<TAB>Login=… » avec toutes les propriétés internes (Get-DomeniaRowText, Core:12621-12643). « Le résumé complet » ne couvre qu'un seul objet, en 6 lignes (Core:1382-1396). L'Atelier support, qui servait à rédiger un ticket, est retiré depuis le 07/10 (administrateur.md:13).

### SP-06 — Inventaire : boutons « rapide » et « complet » avec durée
*Impact fort, effort M ; idée 56 du Spark, vérifiée dans le code*

- **Proposition** : Renommer les boutons de l'onglet Inventaire « Inventaire rapide (≈1 min) » et « Inventaire complet (≈3 min) » d'après les budgets de 55 et 150 s, la progression par source (worker épinglé, contrat SHA) étant un lot à part.
- **Vérification** : Les boutons de l'onglet Inventaire s'appellent « Rapide » et « Complet » (Core:5634-5635), alors que le tableau de bord dit « Inventaire rapide » et « Inventaire complet » (Core:5495-5496). Aucune progression n'est affichée pendant la lecture : seulement « en cours » (Core:12104), et le « Detail par source » n'arrive qu'à la fin.

### SP-07 — Catalogue de widgets : filtres rapides par catégorie
*Impact fort, effort M ; idée 64 du Spark, à préciser*

- **Proposition** : Ajouter au-dessus du catalogue des filtres rapides par catégorie existante (Sécurité, Disques, Réseau, Matériel, Système…) et un choix « Tableau de bord / Requêtes WMI », plutôt que des préréglages par tableau.
- **Vérification** : Le catalogue est déjà propre à chaque tableau (Poste, Parc, Logiciels : Widgets.UI.ps1:583-600), regroupé par section et filtrable par recherche. Il reste long sur le poste : 42 informations intégrées (Boards.Model.ps1:8-49) et 53 requêtes WMI (Probes.Model.ps1:8-60). Les préréglages proposés « Poste/Parc/Logiciels » font doublon avec les tableaux existants.

### SP-08 — Sauvegarde automatique de la base autonome
*Impact fort, effort M ; idée 71 du Spark, vérifiée dans le code*

- **Proposition** : Lancer, via le worker StorageBackup et sa rotation LocalStore.DatabaseBackupCount, une sauvegarde après chaque mise à jour réussie de la base ou à l'ouverture si la dernière a plus de 24 h, résultat affiché dans la barre d'état et LblIndexBackupStatus, sans tâche planifiée Windows.
- **Vérification** : Exact : aucune sauvegarde automatique (administrateur.md:1222). La sauvegarde ne part que d'un clic (Storage.UI.ps1:621-637), et un script séparé Sauvegarder-Cache.ps1 existe (administrateur.md:1224).

### SP-09 — Vérifier hors ligne la signature Authenticode du paquet
*Impact fort, effort L ; idée 81 du Spark, vérifiée dans le code*

- **Proposition** : Signer une copie préparée par build_packages.py --stage-dir et ajouter tools/Test-DomeniaSignature.ps1, appelé par Verifier-Paquet.ps1, qui utilise Get-DomeniaSignatureVerdict hors ligne et rend séparément l'intégrité par le manifeste et l'éditeur épinglé par empreinte de certificat.
- **Vérification** : Le constat est juste : « Le manifeste n'est pas une signature » (administrateur.md:1267, Verifier-Paquet.ps1:46). Un outil de signature existe (dev/tools/Signer-Distribution.ps1). Le verdict Authenticode Get-DomeniaSignatureVerdict existe aussi (Domenia-Release.Model.ps1:1228), mais seuls les tests l'appellent. La fiche D116 est marquée PARTIEL (dev/engineering/d120/raccordement/carte-release-build.json).

### SP-10 — Menu latéral : renommer Assistance poste et Relations
*Impact moyen, effort S ; idée 3 du Spark, à préciser*

- **Proposition** : Ne changer que deux libellés, « Assistance poste » en « Poste » et « Relations » en « Utilisateurs et postes », en gardant Fiche, Comptes et Outils, et répercuter dans Domenia-UX.UI.ps1:168 et les guides.
- **Vérification** : Le menu réel est Accueil, Rechercher, Fiche, Assistance poste, Relations, Comptes, Outils (Core:4184-4245 ; technicien.md:364). La proposition supprime 'Fiche'. 'Accès' entre en collision avec le bouton d'en-tête 'Accès' (comptes temporaires, Core:4280). 'Paramètres' décrit mal Outils, qui regroupe Vérification, Base autonome, Domaine et Journal (Core:5925-5929).

### SP-11 — Retirer les restes de la vue Atelier support
*Impact moyen, effort S ; idée 4 du Spark, vérifiée dans le code*

- **Proposition** : Supprimer la partie vue de l'Atelier (bouton de menu masqué, BtnUxHomeSupport, BtnUxStep3, cas de palette support et supportdiff, routes UX, Initialize-DomeniaSupportUi, Domenia-Support.xaml et tests de la vue) en conservant les fonctions Model et Session encore appelées, puis comparer à la référence de tests en documentant les tests retirés.
- **Vérification** : L'Atelier n'est plus chargé (Core:24366, décision du 07/10 ; administrateur.md:13). Restent pourtant le bouton de menu masqué (Core:4214-4219), la carte d'accueil BtnUxHomeSupport (Core:4393) et BtnUxStep3 (Core:6273). Restent aussi les cas de palette 'support' et 'supportdiff' (Core:18948-18949), les routes de Domenia-UX.UI.ps1:161 et 168, Initialize-DomeniaSupportUi (Domenia-Modules.ps1:650) et Test-DomeniaSupport.ps1. Attention : plusieurs fonctions Support sont encore appelées ailleurs (Sync/Update-DomeniaSupportComparison dans Dossier.UI, ConvertTo-DomeniaSupportText dans Insight.Model, Set-DomeniaSupportObjectSource et Add-DomeniaSupportIncidentFromLog dans Core).

### SP-12 — Renommer la carte trompeuse « Gérer les comptes »
*Impact moyen, effort S ; idée 5 du Spark, vérifiée dans le code*

- **Proposition** : Titrer la carte « Identités de connexion », sous-titre « Comptes utilisés par Domenia : annuaire, postes, secrets », et harmoniser le menu « Comptes » et le titre de TabAccounts, sans « Mes accès » qui heurterait le bouton Accès.
- **Vérification** : La carte 'Gérer les comptes' (Core:4406-4414) ouvre TabAccounts, c'est-à-dire les identités qu'utilise Domenia (annuaire, postes, secrets : Core:5157). Elle ne sert pas à gérer des comptes AD, donc le libellé induit en erreur. En revanche, 'Mes accès' entrerait en collision avec le bouton d'en-tête 'Accès' (Core:4280).

### SP-13 — Réglage d'administration pour masquer le profil Expert
*Impact moyen, effort S ; idée 9 du Spark, à préciser*

- **Proposition** : Si David le valide, ajouter un réglage Ui.AllowExpertProfile, vrai par défaut, qui à faux masque l'entrée Expert et neutralise la bascule par Ctrl+L, sans nouvelle page.
- **Vérification** : Expert est bien proposé dans la liste de l'en-tête (Core:4344-4347) et ne donne aucun droit. Il n'existe pas de page 'Paramètres', et Ctrl+L bascule aussi en Expert (administrateur.md:808). Le guide demande seulement de remettre Essentiel aux techniciens : rien ne dit s'il faut verrouiller ou simplement déplacer le choix.

### SP-14 — Filtre local : libellé « Filtrer la liste » avec exemple
*Impact moyen, effort S ; idée 22 du Spark, vérifiée dans le code*

- **Proposition** : Renommer « Dans les résultats » en « Filtrer la liste » avec le texte d'exemple « nom, login, poste… (sans requête AD) », expliquer par une infobulle pourquoi le champ est grisé en recherche globale tant qu'il l'est, et corriger guides/technicien.md:23.
- **Vérification** : Le libellé « Dans les résultats » (Domenia-Core.ps1:4688) est vague. Son sous-titre explicatif est remplacé par le compteur, tronqué à 112 px (Domenia-Core.ps1:1595 ; capture guides/images/recherche.png). Le nom d'accessibilité dit déjà « Filtrer les lignes chargées » (Domenia-Core.ps1:4689). À noter : ce filtre est grisé et ignoré après une recherche globale (Domenia-Core.ps1:4687 ; D031, :1588-1591), alors que guides/technicien.md:23 dit de l'utiliser après la barre du haut.

### SP-15 — Clic sur un poste sans ping : case « Vérifier au clic »
*Impact moyen, effort S ; idée 27 du Spark, vérifiée dans le code*

- **Proposition** : Remplacer « Utilisateur au clic » par « Vérifier au clic » avec la sous-option « + utilisateur connecté » : décochée, un clic précharge seulement la fiche AD sans ping, « Revérifier ce poste » restant le geste manuel.
- **Vérification** : Constat vrai : la case visible « Utilisateur au clic » (ChkLiveUsers, Domenia-Core.ps1:4693) ne commande que la lecture de la console (AutoDetect, Domenia-Live.UI.ps1:39-42). Le ping d'un poste sélectionné part toujours (Select-DomeniaLiveResult, Domenia-Live.UI.ps1:391-415 ; info-bulle « Décochée : ping seulement »). Aucun moyen dans l'interface de cliquer sans contacter le réseau.

### SP-16 — Renommer « Ouvrir C$ » en « Ouvrir le disque C »
*Impact moyen, effort S ; idée 50 du Spark, vérifiée dans le code*

- **Proposition** : Renommer le bouton « Ouvrir le disque C » en gardant « C$ » dans l'infobulle et AutomationProperties, remplacer le texte figé voisin par Get-DomeniaMachineOperationAccountText et mettre à jour technicien.md:95.
- **Vérification** : Le bouton s'appelle « Ouvrir C$ » (Core:5515). Le compte utilisé n'apparaît qu'après coup, dans la barre d'état (« C$ de X ouvert avec … », Core:17046-17050). Avant le clic, l'onglet Actions n'affiche qu'un texte figé (Core:5546). Pourtant Get-DomeniaMachineOperationAccountText existe déjà (Core:17010-17016), mais il n'est affiché que dans Diagnostic (LblMachineCredential, Core:5597).

### SP-17 — Section vide du tableau : bouton qui lance la lecture
*Impact moyen, effort S ; idée 61 du Spark, vérifiée dans le code*

- **Proposition** : Sous le texte d'une section vide, ajouter un bouton qui déclenche l'action existante correspondante (Inventaire rapide, Inventaire complet, Charger les logiciels, Ouvrir la fiche), et sur l'Accueil seulement un lien « Aller dans Rechercher », sans lancer d'analyse.
- **Vérification** : Constat partiellement vrai : les sections vides n'affichent qu'un texte gris sans bouton (Widgets.UI.ps1:98-104), mais les textes varient selon la section (BoardComputer.UI.ps1:347-353 : inventaire rapide, inventaire complet, fiche AD ; BoardSoftware.Model.ps1:58 ; BoardFleet.Model.ps1:175,180).

### SP-18 — Widget sans donnée : emplacement « Non lu par cet inventaire »
*Impact moyen, effort S ; idée 62 du Spark, vérifiée dans le code*

- **Proposition** : Quand le tableau a déjà des données et qu'une section est partiellement remplie, afficher un emplacement compact « Non lu par cet inventaire » au lieu de masquer le widget, en gardant le masquage avant toute lecture.
- **Vérification** : Vrai pour les widgets intégrés : New-DomeniaBoardWidget renvoie $null hors personnalisation (Widgets.UI.ps1:441). Les widgets de requête WMI affichent déjà « En attente » (Boards.Model.ps1:423) et une section entièrement vide montre déjà son texte d'aide (Widgets.UI.ps1:100-104).

### SP-19 — Recherche du catalogue : petite table de synonymes
*Impact moyen, effort S ; idée 66 du Spark, à préciser*

- **Proposition** : Ajouter une table de synonymes pour les termes absents du catalogue (RAM, stockage, SSD, Defender, reboot/redémarrer, IP, uptime, MAJ/correctif), la recherche actuelle trouvant déjà disque, mémoire, antivirus et démarrage.
- **Vérification** : La recherche fait une correspondance par sous-chaîne, sans accents ni majuscules, sur le titre, la description et la section, tous les mots devant correspondre (Boards.Model.ps1:449-456 ; Widgets.UI.ps1:777). Les cinq mots proposés trouvent déjà leurs widgets (« Disque systeme », « Espace libre sur C: », « Memoire », « Antivirus declare », « Demarrage automatique »).

### SP-20 — Définir ou renommer « Base autonome »
*Impact moyen, effort S ; idée 69 du Spark, à préciser*

- **Proposition** : Si David veut renommer, adopter « Copie locale de l'annuaire » d'un coup dans l'interface, les guides et les messages ; sinon garder le terme du glossaire et ajouter sa phrase de définition sous le titre de l'onglet.
- **Vérification** : « Base autonome » est le terme défini dans le glossaire (administrateur.md:1452) et repris 31 fois dans Domenia-Core.ps1, dans 6 modules et dans les guides. « Dossier local » serait inexact : c'est un fichier SQLite par domaine, avec les associations et les relevés (administrateur.md:1183).

### SP-21 — Remplacer les derniers glyphes emoji et symboles par des Path
*Impact moyen, effort M ; idée 15 du Spark, vérifiée dans le code*

- **Proposition** : Convertir en icônes Path au standard du menu (20 px, trait 1,7) les glyphes restants, dont ↻ en Segoe UI Symbol et les symboles de Domenia-Charts.UI.ps1 et Domenia-Widgets.UI.ps1, en laissant les flèches ← → en texte.
- **Vérification** : Le standard existe déjà : icônes Path linéaires de 20 px, trait 1.7 dans 14 cas sur 18, extrémités arrondies (Core:4186-4242). Le mélange vient des glyphes : emojis 🌞/🌙 (Core:4300) et 🔴 (Core:4333), ↻ en Segoe UI Symbol (Core:4578), ☀/☾ à la connexion, et des symboles dans Domenia-Charts.UI.ps1 et Domenia-Widgets.UI.ps1.

### SP-22 — Tri par nom par défaut en mode OU
*Impact moyen, effort M ; idée 46 du Spark, vérifiée dans le code*

- **Proposition** : En mode OU seulement, poser par défaut un tri Nom ascendant sur la CollectionView (Live.UI.ps1:190-197), remplacé par un clic sur une colonne, sans toucher au classement par pertinence de la recherche globale.
- **Vérification** : Moitié déjà faite : la recherche globale est classée par pertinence puis par nom (Domenia-Live.UI.ps1:177-197, Sort-DomeniaSearchResults dans Domenia-Search.Model.ps1:264-279, option Features.SearchRanking). En mode OU, aucun tri n'est posé : les lignes restent dans l'ordre d'arrivée LDAP (seul cas de SortDescriptions : Live.UI:194-196).

### SP-23 — Rapports de diagnostic pseudonymisés, en option
*Impact moyen, effort M ; idée 83 du Spark, vérifiée dans le code*

- **Proposition** : Brancher en option New-DomeniaTicketReport (pseudonymisation HMAC existante) sur « Exporter le diagnostic » et « Copier le rapport », avec la clé de l'opérateur et un aperçu à relire dans la page, sans purge programmée du journal d'audit.
- **Vérification** : Le constat est juste : « ils ne sont pas anonymisés » (administrateur.md:1269). La pseudonymisation HMAC existe déjà, avec un ticket relisible (ConvertTo-DomeniaPseudonym et New-DomeniaTicketReport, Domenia-Insight.Model.ps1:362, 426). Ces fonctions ne sont qu'exportées (Domenia-Modules.ps1:366, 371) : rien ne les appelle à l'exécution. Le journal tourne déjà à 5 Mo (Domenia-Core.ps1:17149). Le journal d'audit n'est jamais purgé, par choix (Domenia-Cache.Model.ps1:376).

## Écartés

### Affirmations de bug réfutées ou déjà corrigées

- **SE-01 — Modifications LDAP inconnues ignorées : écriture partielle** : réfuté. Le seul appelant (Domenia-Core.ps1:23290-23314) ne produit que Delete/Add/Replace/Clear, ignore déjà les noms vides et n'ajoute jamais un Add vide : les « continue » de 23092-23113 ne sont pas atteignables. Même s'ils l'étaient, la relecture finale compare chaque changement et lève « Verification post-ecriture echouee » (23388) : l'écart serait signalé.
- **SE-11 — « Renommer dans AD » réservé à Expert** : réfuté. Le renommage ne change que le CN (Rename-ADObject ou DirectoryEntry.Rename, 23914-23915) : sAMAccountName et dNSHostName restent intacts, donc le canal sécurisé du poste ne casse pas. La confirmation (23901) dit aussi « Le poste Windows distant ne sera pas renomme ». Le champ est bien visible au niveau Default (584-585), mais il est prérempli avec le nom actuel, ce qui donne une opération sans effet tant qu'il n'est pas modifié.
- **CO-18 — Poste en échec de relevé introuvable par le filtre** : réfuté. Le paquet d'échec (Domenia-Park.UI.ps1:180) n'a pas de PresenceCheckedUtc. ConvertTo-DomeniaLiveObservation (Domenia-Live.Model.ps1:68-74), appelée avec Previous=$null (Park.UI:186), ignore donc sa Presence et garde le défaut accentué « Non vérifié » ; la cellule et le filtre (Live.UI:255-263) concordent. La valeur « Non verifie » n'atteint que park_session_cache, que BoardFleet.Model:112 range de toute façon dans « Non verifie ».

### Idées du Spark déjà en place ou fondées sur une prémisse fausse

- **Idée 6** (déjà en place) — l’en-tête est surchargé: titre, badge, activité, écriture, profil, lecture seule. Au repos, l'en-tête de page n'affiche déjà que le titre, le badge de domaine, Lecture seule et le profil (guides/images/accueil.png). Chronomètre, barre de progression et Annuler sont masqués (Hidden) sans tâche (Core:9224-9232). Le bandeau rouge d'écriture n'apparaît qu'en mode écriture (Core:22389-22398). LblStatus et LblPrivilegeTop sont repliés (Collapsed, Core:4329-4330).
- **Idée 10** (prémisse fausse) — la case “Lecture seule” est un simple checkbox. Ce n'est pas une simple case. La décocher exige une confirmation explicite (Confirm-WarningAction, Core:19619-19640), et elle est bloquée en démonstration. Le mode écriture affiche un bandeau rouge, un halo et le titre de fenêtre '[ECRITURE AD ACTIVE]' (Core:4331, 22389-22398). Renommer en 'Consultation' casserait le vocabulaire 'Lecture seule' des infobulles et des guides (technicien.md:16, 366, 402).
- **Idée 12** (déjà en place) — les couleurs sont trop techniques et parfois agressives. La palette pastel des widgets existe déjà (décision du 07/10) : Get-DomeniaChartPalette et Get-DomeniaBoardColor (Domenia-Charts.UI.ps1:20-28 ; Domenia-Boards.Model.ps1:104-107). Le rouge est réservé aux états Alert et critiques. Le rouge vif (#B91C1C) ne sert qu'au bandeau 'MODE ECRITURE AD ACTIF' (Core:4331).
- **Idée 18** (déjà en place) — la fenêtre est mal adaptée aux écrans étroits. L'adaptation à la taille de la fenêtre existe déjà. La fenêtre a une largeur minimale de 960 (Domenia-Core.ps1:3568). Le panneau d'aide passe en superposition sous 1040 unités utiles (Get-DomeniaUxLayoutPlan, Domenia-UX.UI.ps1:488-500). La mise en page se replie sous 940 et 700 de hauteur (Get-DomeniaUxHeightPlan, Domenia-UX.UI.ps1:222-234 ; Set-DomeniaUxShortLayout). Le menu latéral se réduit (68 contre 204) à la main ou automatiquement (Domenia-UX.UI.ps1:230, 514). La capture captures-20261007/WsSearch_Light_Compact.png montre le menu en icônes et les filtres qui passent à la ligne.
- **Idée 23** (contraire aux règles) — la limite est un champ texte libre. Le champ « Limite » est bien un champ texte (TxtGlobalLimit, Domenia-Core.ps1:4646). Mais une liste plafonnée à 500 contredit la décision de David du 2026-10-05 : au moins 10 000 résultats affichables, ancien plafond de 500 supprimé, maximum 20 000 (Domenia-Core.ps1:9872-9874). « Charger la suite » double la limite jusqu'à 20 000.
- **Idée 24** (prémisse fausse) — “Charger la suite” est technique. « Charger la suite » n'est pas du jargon : le libellé est exact. Le bouton relance une lecture AD de la même recherche avec une limite doublée, jusqu'à 20 000 (info-bulle Domenia-Core.ps1:4683 ; D037, :9870 ; Domenia-Search.Model.ps1:343). « Afficher plus » laisserait croire à un simple affichage local et cacherait la nouvelle requête AD. Il se confondrait aussi avec le filtre local.
- **Idée 25** (déjà en place) — “Aucun résultat affiché” n’aide pas assez. Le texte réellement visible n'est pas « Aucun résultat affiché ». Ce bloc est masqué par le calque « Aucune ligne à afficher », qui conseille déjà « Lancez une recherche, choisissez une OU ou ajustez les filtres » (Domenia-Core.ps1:4759), ce qui revient à la proposition. Le vrai manque, un message adapté à la situation et une action unique, est traité au n°16. guides/technicien.md:60 cite un message que l'utilisateur ne voit pas.
- **Idée 28** (déjà en place) — la confirmation d’un relevé doit rester dans la page. La confirmation est déjà dans la page. Après un relevé, Domenia appelle Request-DomeniaInlineConfirmation dans InlineRequestPanel (Domenia-Park.UI.ps1:86-93 ; Domenia-Inline.UI.ps1:48-78 ; Domenia-Inline.xaml:2). Le message donne le nombre de postes et la nature des lectures, avec les boutons Pinger, Analyser ou Verifier les sessions, et Annuler. La boîte de dialogue ne sert de repli que sans fenêtre principale (Domenia-Inline.UI.ps1:64-67).
- **Idée 30** (déjà en place) — “Arrêter” n’est pas toujours évident pendant une tâche. « Arrêter » (BtnParkResultsStop) est toujours visible à côté des actions de liste. Il n'est actif que pendant un relevé (Domenia-Core.ps1:4698 ; Domenia-Park.UI.ps1:28-32 ; visible dans les captures). Pour toute lecture annulable, le bouton global « Annuler » (BtnCancelTask) apparaît avec le chrono dès qu'une tâche tourne (Domenia-Core.ps1:4339, 9226-9231, :19470). La page « Opérations » permet aussi d'arrêter chaque worker.
- **Idée 31** (déjà en place) — les flèches précédent/suivant sont discrètes. Les infobulles existent déjà, visibles même quand le bouton est grisé : « sans nouvelle lecture ni sonde des postes », avec Alt+Gauche et Alt+Droite (dev/wad/Domenia-Core.ps1:4278-4279). Les raccourcis sont branchés dans dev/wad/modules/Domenia-Search.UI.ps1:276-283.
- **Idée 32** (déjà en place) — pas de favoris pour OU, postes ou recherches. Les favoris de recherche existent (D038) : OU, texte, filtres et sous-OU, 50 au plus par domaine, persistés dans 'SavedSearches'. Code : Domenia-Guard.UI.ps1:113-145, XAML Core:5963-5964, défaut Core:2886. Ils sont dans l'onglet « Fiabilité », masqué (Core:5930) par décision de David du 07/10 (Core:9426, administrateur.md:13). Les repères de fiches étaient dans l'Atelier, retiré (Domenia-Support.xaml:42,103 ; Core:4214).
- **Idée 34** (prémisse fausse) — l’aide contextuelle est trop générale. L'aide est déjà propre à chaque contrôle : 505 entrées (Domenia-UX.help.json), affichées au survol ou au Tab (Domenia-UX.UI.ps1:66-74, Core:6295). L'objet chargé est rappelé (UX.UI.ps1:178-186). Les actions par type d'objet sont dans le menu contextuel des résultats (Core:12840-12870). Seule la carte « Aide et prochaines étapes » est fixe (Core:6240) ; on pourrait l'adapter au type d'objet, en navigation seule.
- **Idée 35** (déjà en place) — les messages d’erreur sont techniques. D052 : ConvertTo-DomeniaErrorInfo produit « Opération : explication + prochaine action » (Core:2005-2040). Le texte vient de Get-DomeniaErrorDecision, qui donne Text et Next par catégorie (Domenia-Access.Model.ps1:90-140). Le détail technique part au journal (Core:2073-2076). Reste à traiter : une erreur non classée affiche encore le message brut (Core:2066).
- **Idée 36** (déjà en place) — un nouveau technicien ne sait pas par où commencer. La carte « Aide et prochaines étapes » est toujours affichée dans la colonne d'aide : 1 Trouver, 2 Consulter (Core:6240-6290). L'étape 3 « Préparer » est masquée avec l'Atelier. Les boutons s'activent selon ce qui est disponible (Domenia-UX.UI.ps1:150-165). Le chapitre 1 du guide technicien fait la prise en main.
- **Idée 40** (déjà en place) — pas de raccourci vers les OU fréquentes. Les favoris de recherche D038 mémorisent l'OU : DN, sous-OU, type et limite (Domenia-Guard.UI.ps1:118-145). La dernière OU est aussi restaurée par domaine (Continuity.UI.ps1:70-100, OuBookmarksJson). Ils sont dans l'onglet « Fiabilité », masqué (Core:5930) par décision de David du 07/10 (Core:9426).
- **Idée 41** (déjà en place) — le chemin LDAP est caché dans un expander. Le bouton « Copier le chemin » existe (BtnUxCopyOuPath Core:4604, Copy-DomeniaUxOuPath Domenia-UX.UI.ps1:626), sous l'expander « Voir le chemin LDAP » (Core:4601). La carte périmètre montre le chemin lisible (LblOuScopePath Core:4596). Le DN de chaque ligne est aussi dans la colonne « Chemin complet ».
- **Idée 42** (déjà en place) — l’arbre peut être lourd à charger. Le chargement paresseux existe : nœud « Chargement... » et Load-TreeChildren au dépliage (Core:6661-6667). La requête OneLevel tourne en tâche de fond (Core:9554-9575) et le rendu se fait par lots (Core:6672, Core:6741). La virtualisation n'est pas déclarée sur TvDirectory (Core:4609) ; ne l'ajouter que si une OU très large est mesurée lente.
- **Idée 43** (prémisse fausse) — toutes les colonnes s’adressent à un admin. Les colonnes suivent déjà le contenu (décision de David du 07/10). Les colonnes de poste n'apparaissent que si la liste contient un poste, « Compte » que si une ligne a un compte (Domenia-Live.UI.ps1:105-143). Plusieurs colonnes servent le technicien (Utilisateur connecté, Présence réseau). Le profil Essentiel/Expert existe déjà (Core:4344, Core:2288-2304) et masque les vues expertes (UX.UI.ps1:193-205). Les vues D084 sont écrites mais non raccordées (Shell.Model.ps1:383-401).
- **Idée 45** (prémisse fausse) — les badges sont peu lisibles. Les résultats n'ont pas de badges graphiques : « Qualification » et « Présence réseau » sont du texte simple (Core:4735-4741 ; Relations Core:5306), avec une légende en infobulle d'en-tête (Core:4736 ; capture recherche.png). Si un repère visuel est voulu : un point coloré devant « Présence réseau », via Get-DomeniaPresenceColor (Core:2342), en gardant le texte.
- **Idée 49** (prémisse fausse) — les libellés d’actions sont techniques. Les libellés sont déjà en clair : « Journaux », « Services », « Gestion de l ordinateur », « Bureau à distance » (Core:5514-5518 ; capture actions-poste.png). « Gestion de l ordinateur » est le nom exact de la console Windows (compmgmt.msc) que le technicien connaît : la renommer brouillerait le repère. Seul « Ouvrir C$ » est du jargon, voir #50.
- **Idée 51** (déjà en place) — l’ouverture des consoles est opaque en cas de refus. Le message existe déjà. En cas de refus du partage, Fail-DomeniaAdminShareOpen (Core:17052-17058) affiche « Console ouverte avec la session Windows : <motif> » (WARN) et ouvre quand même la console. Pour C$, le refus passe par Show-DomeniaOperationError, et un succès indique le compte utilisé (Core:17050). Il reste un petit trou : sans compte poste défini, aucun message n'est affiché (Core:17029, Account vide).
- **Idée 54** (déjà en place) — LAPS et BitLocker sont sensibles. Déjà en place : secrets masqués par défaut ; une seule valeur révélée à la fois, pendant 30 s, sur geste explicite (Get-DomeniaSecretExposurePolicy dans Domenia-Access.Model.ps1:372-378, minuterie dans Domenia-Secrets.UI.ps1:67-82) ; copie unique (CopyOneAtATime) ; presse-papiers effacé automatiquement après 30 s, réglable par Security.AutoClearSecretClipboardSeconds (Core:11029-11046), et seulement si son contenu n'a pas changé (Core:10673-10686). Passer de 30 s à 10 s n'est qu'un choix de réglage.
- **Idée 55** (prémisse fausse) — les sessions RDP ne sont pas comptées. L'onglet « Sessions Windows » liste toutes les sessions WTS, avec une colonne Protocole Console/RDP (Domenia-Sessions.Native.cs:47-49 ; grille DgSessions, Core:5553). Seule la colonne « Utilisateur connecté (console) » de la liste de résultats se limite à la console, et c'est voulu (Win32_ComputerSystem.UserName, Live.Model.ps1:159) ; technicien.md:190 renvoie vers l'onglet Sessions. Amélioration mineure possible : afficher « À l'écran » au lieu de Console et « À distance (RDP) » au lieu de RDP.
- **Idée 57** (déjà en place) — la liste des logiciels est dense. Déjà en place : filtre local instantané TxtSoftwareFilter, déclenché à chaque frappe, sur nom, éditeur, version et emplacement (Core:5726, 13483, 19574) ; filtre de portée Toutes/Machine/Utilisateur/Store (CmbSoftwareScope, Core:5728) ; mises à jour masquées par défaut (ChkSoftwareUpdates, Core:5705) ; « Synthèse en graphiques » (Core:5709). Des puces de filtre ne seraient qu'un changement d'habillage de la liste de portée.
- **Idée 59** (déjà en place) — le score 0/100 est abstrait. Le score n'est pas présenté seul. La tuile « Etat general » affiche le score avec un verdict en mots (Bon etat, A surveiller, Degrade, Critique) et le nombre de points (Get-DomeniaBoardHealth et Complete-DomeniaBoardData, Domenia-Boards.Model.ps1:171-191). Juste à côté, les points d'attention sont triés du plus grave au moins grave (capture tableau-poste.png). Le seul ajout possible : expliquer le calcul (100 − 25 par point critique − 10 par point à surveiller) dans l'infobulle.
- **Idée 63** (déjà en place) — l’éditeur “Ajouter un widget” ouvre une fenêtre. L'éditeur construit une Window, puis Show-DomeniaEmbeddedWindow (Widgets.UI.ps1:625,830) en extrait le contenu et l'affiche comme panneau latéral aligné à droite dans DomeniaDialogLayer de la fenêtre principale (Embedded.UI.ps1:107-125 ; capture editeur-widget.png). Seul le guide parle encore d'une « fenêtre » (technicien.md:266,272).
- **Idée 67** (déjà en place) — l’aperçu peut être fictif. Get-DomeniaBoardPreviewEntry utilise les données réelles du tableau quand elles existent, sinon un exemple (Widgets.UI.ps1:603-610). Les exemples sont étiquetés « Exemple » ou « Apercu » (Boards.Model.ps1:457-468).
- **Idée 75** (déjà en place) — les workers sont épinglés mais peu observables. Le bouton « Etat moteur » montre la mémoire, les workers actifs, les annulations et le cache (Domenia-Core.ps1:6318). L'onglet « Charge & stats » donne durée, volume réseau, repli distant et taux de réussite (Domenia-Core.ps1:6084). Les contrats des workers sont épinglés par SHA-256 (Domenia-Core.ps1:20893, tools/operation-contracts.json, update_worker_contracts.py) et testés par Test-DomeniaWiringMoteur.ps1.
- **Idée 76** (déjà en place) — le DataGrid est large et lourd. DgObjects virtualise déjà lignes et colonnes en mode Recycling (style global Domenia-Core.ps1:3841-3844, grille 4703). Les colonnes poste et lien n'apparaissent que si la liste contient des postes ou des utilisateurs (Domenia-Live.UI.ps1:128-143). Les largeurs sont fixes et mémorisées (Domenia-Continuity.UI.ps1:35-51). Une largeur Auto forcerait des remesures pendant le défilement virtualisé.
- **Idée 77** (déjà en place) — le cache est global et peu fin. La durée de fraîcheur dépend déjà de la nature : Identité 24 h, Attributs 15 min, Présence 2 min, Console 5 min (Domenia-Cache.Model.ps1:91-100). Les échecs ont un cache négatif dont la durée dépend du type d'échec (:266-276). Le cache de visite a son propre TTL : 90 s par défaut, 45 s pour une fiche (Domenia-Core.ps1:9283, 22006). Il est vidé après chaque écriture (Invoke-DomeniaPostWriteRefresh, :16755). Une purge ciblée par GUID existe (Domenia-Continuity.UI.ps1:198-213), ainsi qu'une purge par catégorie (Domenia-Cache.Model.ps1:368-440).
- **Idée 78** (déjà en place) — SQLite peut devenir lent sur gros domaine. ad_objects a déjà des index sur le GUID, le DN, le nom, le login, l'UPN, usn_changed et object_type (Domenia-Core.ps1:20492-20498). L'historique est indexé par poste et par utilisateur avec la date (:20506-20507). Les observations ont une clé primaire (scope_key, object_key) (Domenia-Live.Model.ps1:470). Aucune requête SQL ne filtre sur last_logon ni sur une OU, donc ces deux index ne serviraient à rien. Le seul balayage complet est search_key LIKE '%x%' (Domenia-Core.ps1:14172, Domenia-Engine.Worker.ps1:194) : à mesurer avant de recourir à FTS.
- **Idée 79** (prémisse fausse) — les relevés sont plafonnés à 4 postes sans adaptation. Le plafond de 4 est voulu et documenté (Domenia-Park.UI.ps1:144, administrateur.md:103,577), mais il n'est pas figé. Le moteur impose un budget CIM de 3 lectures simultanées, avec un seuil d'échecs et un backoff de 60 à 600 s (Domenia-Engine.Model.ps1:368, 447-454). Le relevé s'arrête si les identifiants sont rejetés (Domenia-Park.UI.ps1:162). Il marque une pause quand la persistance sature : 64 en attente ou lien occupé (:140-141), et pendant une écriture (:136). Les postes partent un par un, avec une admission par tick (:145-149).
- **Idée 80** (déjà en place) — les tests WPF réels restent insuffisamment qualifiés. De vraies fenêtres WPF sont chargées, affichées puis mesurées (Test-DomeniaGeometry.ps1:63-83, Test-DomeniaStableUi.ps1:48,96). audit_ui.py et audit_compact_ui.py contrôlent les AutomationProperties. Les captures d'écran viennent de la vraie fenêtre rendue dans la VM (guides/captures/capture-guides.ps1:2-4). Seule absence : une comparaison pixel à pixel entre deux versions.
- **Idée 82** (déjà en place) — PsExec et tâche planifiée peuvent servir de repli. PsExec, ADMIN$ et le Planificateur exigent une autorisation explicite pour une seule cible, valable 5 minutes et liée à la session (Domenia-Guard.UI.ps1:110 ; Assert-WRemoteArtifactPermission, Domenia-Core.ps1:8645-8650). Sans elle, l'erreur indique « désactivé par défaut ». Le transport utilisé est noté dans le journal et les statistiques (Domenia-Core.ps1:8733, 13541). La table des transports affiche leur état (Domenia-Access.Model.ps1:420-428).
- **Idée 84** (déjà en place) — les droits nécessaires sont obscurs. L'onglet « Droits effectifs » estime les droits en lecture seule : bouton Analyser, colonnes Action, État, Source et Détail, copie du rapport (Domenia-Core.ps1:5126-5146). L'estimation se fait aussi à l'ouverture d'un objet (administrateur.md:132-134). Le clic droit sur l'arbre propose « Analyser les droits sur cette OU » (administrateur.md:70). Le chapitre 13 « Droits à prévoir » les décrit (administrateur.md:794). Limite : l'onglet n'apparaît qu'en profil Expert.
- **Idée 85** (déjà en place) — les écritures sensibles sont déjà protégées mais peu traçables. Chaque écriture laisse un reçu durable (administrateur.md:847 ; DgGuardReceipts, Domenia-Core.ps1:5953). Aucune écriture n'est rejouée automatiquement (Test-DomeniaAutoRetryAllowed, Domenia-Engine.Model.ps1). Une nouvelle écriture est refusée tant que l'état reste Unknown ou UnknownPending (Domenia-Core.ps1:22571). La revue d'un reçu exige un motif de 12 à 240 caractères (Domenia-Guard.UI.ps1:56). Un motif obligatoire avant chaque écriture ajouterait un formulaire au parcours, ce que les règles excluent.

### Écartées lors de la fusion des propositions

- État partagé éparpillé ($script:, 192 affectations) : écarté, pas de livrable précis ; CD-01 le traitera morceau par morceau.
- Harnais de test commun (Domenia.TestKit) : écarté, migration au fil de l'eau sans gain visible pour l'utilisateur.
- Regrouper Accès et Opérations sous une icône « Activité » : variante non retenue, les emplacements fixes (D082) restent.
- Rétablir le repli par tâche planifiée de GPUpdate/Redémarrage : refusé, une écriture n'est jamais rejouée (CD-11 le supprime).
- Revalidation AD de fond seulement affichée : jugé insuffisant au regard de « rien sur le réseau sans geste » ; SE-13 propose de la couper par défaut.
- « Mettre à jour tout » limité à l'OU (MO-02) : gardé mais à arbitrer par David, car la recherche « Partout » et les suggestions locales reposent sur l'index du domaine.
- Choix « domaine entier » pour les vues de travail (UX-33) : gardé seulement comme choix secondaire explicite, jamais par défaut, et sans relevé possible.
- Fusions : accents et vouvoiement (8 propositions en UI-04), jargon (5 en UI-21), tri des dates et tailles (3 en CO-03), export CSV (2), Échap (2), pare-feu (2), disque C: (2), jauge (2), grille fluide (2), FleetStats (2), journaux disque et TxtLog (4), fenêtres modales (2), Fiabilité masqué (2), code mort (8 répartis en CD-02 à CD-04), vues lourdes et XAML (2 en CD-01), attentes actives (3 en FI-20).
