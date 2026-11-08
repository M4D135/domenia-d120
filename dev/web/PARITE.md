# Inventaire de parité de l interface (WPF → web)

Chaque onglet et chaque contrôle nommé de l interface WPF actuelle, avec son rôle (catalogue d aide). La nouvelle interface doit couvrir chaque ligne. Généré par `dev/web/tools/parity_inventory.py` à partir de `Domenia-Main.xaml`, des vues `modules/*.xaml` et de `Domenia-UX.help.json`.

## Domenia
- [ ] `UxComboToggle` ToggleButton — 
- [ ] `PART_Popup` Popup — 
- [ ] `PART_SelectedContentHost` ContentPresenter — 
- [ ] `TabHeader` ContentPresenter — 
- [ ] `PART_Track` Track — 
- [ ] `PART_Track` Track — 
- [ ] `PART_SelectedContentHost` ContentPresenter — 
- [ ] `UxBrandCompact` TextBlock — D
- [ ] `BtnUxNavAccounts` Button — Comptes
- [ ] `UxNavIconAccounts` Path — 
- [ ] `UxNavLabelAccounts` TextBlock — Comptes
- [ ] `BtnUxNavTools` Button — Outils
- [ ] `UxNavIconTools` Path — 
- [ ] `UxNavLabelTools` TextBlock — Outils
- [ ] `LstUiProfile` ListBox — Niveau de détail
- [ ] `LstUiProfileTech` ListBoxItem — Essentiel
- [ ] `LstUiProfileExpert` ListBoxItem — Expert
- [ ] `BtnUxNavAccount` Button — Compte connecté
- [ ] `LblUxNavAccount` TextBlock — Compte en préparation
- [ ] `LblUxNavDomain` TextBlock — Domaine non connecté
- [ ] `LblUxAboutCompatibility` TextBlock — Compatibilité de ce poste
- [ ] `BtnUxSidebarToggle` Button — Réduire ou déployer le menu
- [ ] `UxSidebarToggleGlyph` Path — 
- [ ] `BtnUxNavHome` Button — Accueil
- [ ] `UxNavIconHome` Path — 
- [ ] `UxNavLabelHome` TextBlock — Accueil
- [ ] `BtnUxNavSearch` Button — Rechercher
- [ ] `UxNavIconSearch` Path — 
- [ ] `UxNavLabelSearch` TextBlock — Rechercher
- [ ] `BtnUxNavObject` Button — Fiche
- [ ] `UxNavIconObject` Path — 
- [ ] `UxNavLabelObject` TextBlock — Fiche
- [ ] `BtnUxNavComputer` Button — Poste
- [ ] `UxNavIconComputer` Path — 
- [ ] `UxNavLabelComputer` TextBlock — Poste
- [ ] `BtnUxNavRelations` Button — Utilisateurs et postes
- [ ] `UxNavIconRelations` Path — 
- [ ] `UxNavLabelRelations` TextBlock — Utilisateurs et postes
- [ ] `BtnUxNavSupport` Button — Atelier support
- [ ] `UxNavIconSupport` Path — 
- [ ] `UxNavLabelSupport` TextBlock — Atelier support
- [ ] `TxtGlobalSearch` TextBox — Rechercher
- [ ] `UxSearchPlaceholder` TextBlock — {Binding Tag, RelativeSource={RelativeSource TemplatedParent}}
- [ ] `UxSearchGlyph` Path — 
- [ ] `BtnGlobalSearchClear` Button — Vider la recherche
- [ ] `BtnCommandPalette` Button — Palette de commandes
- [ ] `UxSearchSuggestHost` Canvas — 
- [ ] `LblSearchSuggestTitle` TextBlock — Recherches et fiches récentes
- [ ] `LstSearchSuggest` ListBox — Suggestions
- [ ] `LblSearchSuggestHint` TextBlock — Entrée lance la recherche dans lʼannuaire ; les suggestions viennent de la mémoire et de la base locales.
- [ ] `BtnGlobalSearch` Button — Rechercher
- [ ] `LstSearchBarScope` ListBox — Où chercher
- [ ] `ItmSearchBarScopeOu` ListBoxItem — Dans lʼOU choisie
- [ ] `LblSearchBarScopeOu` TextBlock — OU de la recherche
- [ ] `LstSearchBarType` ListBox — Type cherché
- [ ] `BtnAccessRecovery` Button — Accès
- [ ] `LblAccessRecoveryCount` TextBlock — 0
- [ ] `BtnSuiteActivity` Button — Opérations
- [ ] `LblSuiteActivityCount` TextBlock — 0
- [ ] `LblSuiteBatchProgress` TextBlock — 
- [ ] `BtnThemeToggle` Button — Thème clair ou sombre
- [ ] `ThemeIconSun` Path — 
- [ ] `ThemeIconMoon` Path — 
- [ ] `BtnUxHelpToggle` Button — Panneau d’aide
- [ ] `UxHelpBadge` Ellipse — 
- [ ] `BtnNavBack` Button — Précédent
- [ ] `BtnNavForward` Button — Suivant
- [ ] `LblUxPageTitle` TextBlock — Accueil
- [ ] `LblUxDomain` TextBlock — Session AD en préparation
- [ ] `LblUxSubject` TextBlock — 
- [ ] `BtnUxSubjectClear` Button — Désélectionner
- [ ] `BtnPendingOperations` Button — Opérations à vérifier
- [ ] `LblStatus` TextBlock — 
- [ ] `LblPrivilegeTop` TextBlock — 
- [ ] `BtnReadOnlyResume` Button — Repasser en lecture seule
- [ ] `LblWriteMode` TextBlock — Repasser en lecture
- [ ] `LblTaskElapsed` TextBlock — 
- [ ] `PbTop` ProgressBar — Indicateur d’activité
- [ ] `BtnCancelTask` Button — Annuler la lecture
- [ ] `BtnAccountsHeader` Button — Identités de connexion
- [ ] `ChkReadOnlyMode` CheckBox — Protection des modifications
- [ ] `UxLockClosed` Path — 
- [ ] `UxLockOpen` Path — 
- [ ] `UxReadOnlyText` ContentPresenter — 
- [ ] `WorkspaceTabs` TabControl — Choisissez une rubrique dans la barre latérale
- [ ] `BtnUxHelpClose` Button — Réduire le panneau d’aide
- [ ] `LblContextTitle` TextBlock — À quoi sert cet élément ?
- [ ] `LblContextHint` TextBlock — Survolez un contrôle ou utilisez Tab pour lire son rôle ici. Les champs de mot de passe ne sont jamais recopiés dans cette aide.
- [ ] `LblUxHelpGuide` TextBlock — Chapitre du guide
- [ ] `BtnUxHelpGuide` Button — Ouvrir le guide
- [ ] `LblUxSelected` TextBlock — Aucune fiche ouverte
- [ ] `UxSuiteIdentities` Expander — Comptes utilisés
- [ ] `LblSuiteIdentityAd` TextBlock — 
- [ ] `LblSuiteIdentityRemote` TextBlock — 
- [ ] `LblSuiteIdentitySecrets` TextBlock — 
- [ ] `BtnUxHelpAccounts` Button — Ouvrir les comptes
- [ ] `BtnUxStep1` Button — 1. Trouver
- [ ] `BtnUxStep2` Button — 2. Consulter
- [ ] `BtnUxStep3` Button — 3. Préparer
- [ ] `LblUiLogLast` TextBlock — Dernier message du journal
- [ ] `LblUiLogErrorBadge` TextBlock — 1 erreur
- [ ] `ChkUiLogFollow` CheckBox — Suivre
- [ ] `BtnRuntimeHealth` Button — État du moteur
- [ ] `BtnCopyUiLog` Button — Copier
- [ ] `ChkUiLogCopyMask` CheckBox — Masquer les noms à la copie
- [ ] `BtnClearUiLog` Button — Effacer
- [ ] `BtnUxLogToggle` Button — Taille du journal
- [ ] `TxtUiLog` TextBox — Journal de session
- [ ] `LstUiLogReadable` ListBox — Journal de session lisible
- [ ] `TxtSuiteLogFind` TextBox — Rechercher dans le journal
- [ ] `BtnSuiteLogNext` Button — Occurrence suivante
- [ ] `ChkUiLogErrorsOnly` CheckBox — Erreurs seulement
- [ ] `ChkSuiteLogWrap` CheckBox — Retour à la ligne du journal
- [ ] `CmbSuiteLogSize` ComboBox — Taille du texte du journal
- [ ] `CmbSuiteDensity` ComboBox — Densité des résultats
- [ ] `LblSuiteLogFind` TextBlock — 
- [ ] `LogGridSplitter` GridSplitter — Hauteur du journal
- [ ] `BtnUiZoomOut` Button — Réduire le zoom
- [ ] `BtnUiZoomReset` Button — Réinitialiser le zoom à 100 %
- [ ] `BtnUiZoomIn` Button — Agrandir le zoom

### Accueil (`TabDashboard`)
- [ ] `LblFirstStepConnectionMark` TextBlock — 1
- [ ] `LblFirstStepConnection` TextBlock — Se connecter à lʼannuaire avec son compte habituel.
- [ ] `BtnFirstStepConnection` Button — Premiers pas : connexion à lʼannuaire
- [ ] `LblFirstStepOuMark` TextBlock — 2
- [ ] `LblFirstStepOu` TextBlock — Choisir lʼOU racine du domaine. Elle est le défaut des sections qui nʼont pas encore leur propre choix.
- [ ] `BtnFirstStepOu` Button — Premiers pas : choisir lʼOU de travail
- [ ] `LblFirstStepBaseMark` TextBlock — 3
- [ ] `LblFirstStepBase` TextBlock — Faire la première lecture de cette OU dans la base locale (Outils, Base autonome).
- [ ] `BtnFirstStepBase` Button — Premiers pas : première lecture de lʼOU
- [ ] `LblFirstStepDashboardMark` TextBlock — 4
- [ ] `LblFirstStepDashboard` TextBlock — Découvrir le tableau de bord : la vue dʼensemble de lʼOU se calcule depuis la base locale.
- [ ] `BtnFirstStepDashboard` Button — Premiers pas : découvrir le tableau de bord
- [ ] `LblFirstStepsDeferred` TextBlock — Options réglées plus tard
- [ ] `BtnFleetShowMachines` Button — Ouvrir lʼatelier de requêtes
- [ ] `BtnFleetDashboardRefresh` Button — Recalculer la vue sans collecte
- [ ] `LblFleetScope` TextBlock — Périmètre et fraîcheur AD
- [ ] `LblFleetDashboard` TextBlock — Dates des mesures et du calcul
- [ ] `BtnFleetScope` Button — Choisir lʼOU du tableau de bord
- [ ] `BtnFleetOpenSearch` Button — Analyser ces postes dans Rechercher
- [ ] `BtnFleetRefreshAll` Button — Tout actualiser
- [ ] `BtnFleetIndexScope` Button — Mettre à jour la base locale de l’OU
- [ ] `BtnFleetRefreshPostes` Button — Actualiser les postes de l’OU par ping et WMI
- [ ] `BtnFleetRefreshBoth` Button — Mettre à jour la base locale puis les postes
- [ ] `BtnFleetRefreshStop` Button — Arrêter l’actualisation de l’OU
- [ ] `LblFleetOuRefreshStatus` TextBlock — Progression de l’actualisation du périmètre
- [ ] `UxSessionDetails` Expander — Détails de la session et outils de vérification
- [ ] `BtnDashCopy` Button — Copier
- [ ] `BtnDashSelfCheck` Button — Vérifier lʼapplication
- [ ] `BtnDashClearCache` Button — Vider le cache
- [ ] `BtnDashOpenLog` Button — Ouvrir le journal
- [ ] `TxtDashDomain` TextBox — Domaine
- [ ] `TxtDashServer` TextBox — Contrôleur de domaine
- [ ] `TxtDashUser` TextBox — Compte utilisé pour l’annuaire
- [ ] `TxtDashMode` TextBox — Mode de connexion
- [ ] `TxtDashBaseDn` TextBox — Racine de l’annuaire
- [ ] `TxtDashBranch` TextBox — Branche affichée
- [ ] `TxtDashRows` TextBox — Résultats affichés
- [ ] `TxtDashModule` TextBox — Module AD
- [ ] `TxtDashRights` TextBox — Estimation des droits
- [ ] `TxtDashTasks` TextBox — Tâches en cours
- [ ] `TxtDashCache` TextBox — Cache des objets visités
- [ ] `TxtDashSelfCheck` TextBox — Vérification de l’application
- [ ] `TxtDashLinks` TextBox — Associations utilisateur et poste
- [ ] `TxtDashStats` TextBox — Statistiques de la liste
- [ ] `TxtDashSelected` TextBox — Objet sélectionné

### Rechercher (`WsSearch`)
- [ ] `BtnTreeRefresh` Button — Actualiser l’arbre
- [ ] `BtnOuMenu` Button — Options de lʼarbre des OU
- [ ] `ChkSubtree` CheckBox — Inclure les sous-OU dans les résultats
- [ ] `BtnOuFavouriteToggle` Button — Épingler ou retirer lʼOU choisie
- [ ] `UxOuPathDetails` Expander — Chemin complet de l’OU
- [ ] `TxtBranchDn` TextBox — OU utilisée pour la recherche
- [ ] `BtnUxCopyOuPath` Button — Copier le chemin LDAP
- [ ] `LblOuRestoreMessage` TextBlock — OU mémorisée
- [ ] `BtnOuRestoreRetry` Button — Relire lʼOU mémorisée
- [ ] `BtnOuRestoreDismiss` Button — Choisir une autre OU
- [ ] `TxtOuFilter` TextBox — Filtrer les OU
- [ ] `UxOuRefreshExpander` Expander — Actualiser lʼOU
- [ ] `UxSearchOuRefreshTitle` TextBlock — Données de lʼOU
- [ ] `LblSearchOuRefreshScope` TextBlock — Périmètre des données de l’OU
- [ ] `BtnSearchRefreshBase` Button — Mettre à jour la base locale de l’OU
- [ ] `BtnSearchRefreshPostes` Button — Actualiser les postes de l’OU par ping et WMI
- [ ] `BtnSearchRefreshBoth` Button — Mettre à jour la base locale puis les postes
- [ ] `BtnSearchRefreshStop` Button — Arrêter l’actualisation de l’OU
- [ ] `LblSearchOuRefreshStatus` TextBlock — Progression de l’actualisation de l’OU
- [ ] `LblTreeStatus` TextBlock — Arbre pret.
- [ ] `TvDirectory` TreeView — Arbre des OU et conteneurs
- [ ] `SearchOuSplitter` GridSplitter — Largeur de l’arbre des OU
- [ ] `LblSearchCardCount` TextBlock — Lignes affichées
- [ ] `BtnSearchQueryOptions` Button — Options de requête
- [ ] `CmbWorkViewScope` ComboBox — Périmètre des requêtes
- [ ] `LblSearchScope` TextBlock — Dans : tout le domaine | Sous-OU incluses
- [ ] `LblSearchHint` TextBlock — Lecture de la saisie
- [ ] `CmbGlobalType` ComboBox — Type d’objet
- [ ] `CmbPresenceFilter` ComboBox — Présence réseau
- [ ] `LblGlobalLimitUnit` TextBlock — Unité de la limite
- [ ] `TxtGlobalLimit` TextBox — Lignes max
- [ ] `TxtSearchQueryFilter` TextBox — Rechercher dans les requêtes
- [ ] `ChkSearchQueryFavorites` CheckBox — Requêtes favorites
- [ ] `CmbWorkView` ComboBox — Requête à exécuter
- [ ] `BtnWorkView` Button — Exécuter la requête
- [ ] `BtnSearchQueryFavorite` Button — Épingler la requête
- [ ] `BtnSearchQueryWorkshop` Button — Modifier dans lʼatelier
- [ ] `LblSearchQueryDetails` TextBlock — Choisissez une requête pour voir sa source et son périmètre.
- [ ] `LblSearchQuery` TextBlock — Aucune requête appliquée aux résultats.
- [ ] `CmbSearchQueryResult` ComboBox — Résultats de la requête locale
- [ ] `BtnQueryClearSearch` Button — Effacer la requête appliquée
- [ ] `TxtBranchSearch` TextBox — Terme masqué de lʼOU
- [ ] `CmbObjectFilter` ComboBox — Ancien filtre de type
- [ ] `TxtBranchLimit` TextBox — Ancienne limite de branche
- [ ] `BtnClearBranch` Button — Vider la recherche (commande masquée)
- [ ] `BtnLoadBranch` Button — Actualiser les résultats
- [ ] `BtnExportResults` Button — Exporter CSV
- [ ] `BtnGlobalClear` Button — Effacer la recherche
- [ ] `BtnSearchResultMenu` Button — Autres actions de la liste
- [ ] `BtnSearchMore` Button — Charger la suite
- [ ] `BtnSearchMoreJump` Button — Charger jusquʼà 1 000
- [ ] `LblBranchCount` TextBlock — 0 objet
- [ ] `BtnHistoryRefresh` Button — Actualiser la liste de lʼhistorique
- [ ] `BtnSearchContains` Button — Chercher aussi les noms qui contiennent ce texte
- [ ] `BtnAddressDns` Button — Chercher dans le DNS
- [ ] `UxResultToolsExpander` Expander — Actions, filtres et vues
- [ ] `LblSuiteResultCount` TextBlock — Filtre local : affine seulement les lignes déjà chargées.
- [ ] `TxtSuiteResultFilter` TextBox — Filtrer la liste
- [ ] `BtnSuiteResultClear` Button — Effacer le filtre local
- [ ] `ChkLiveVerifyOnClick` CheckBox — Vérifier au clic
- [ ] `ChkLiveUsersOnClick` CheckBox — Vérifier aussi lʼutilisateur connecté
- [ ] `BtnLiveRecheck` Button — Revérifier ce poste
- [ ] `BtnParkVerifyMenu` Button — Choisir la vérification de la liste
- [ ] `ChkListRevalidation` CheckBox — Revérifier la liste en arrière-plan
- [ ] `LblListRevalidation` TextBlock — 
- [ ] `PbParkProgress` ProgressBar — Avancement du relevé de la liste
- [ ] `LblSelectionReadState` TextBlock — Aperçu de lecture
- [ ] `LblSelectionBar` TextBlock — Lignes sélectionnées
- [ ] `BtnSelectionPing` Button — Pinger les postes sélectionnés
- [ ] `BtnSelectionConsole` Button — Utilisateur connecté des postes sélectionnés
- [ ] `BtnSelectionCopy` Button — Copier la sélection pour un ticket
- [ ] `BtnSelectionExport` Button — Exporter la sélection
- [ ] `LblLiveState` TextBlock — Un clic : fiche AD seulement, sans ping · Double-clic : ouvrir la fiche · Aucune sonde de liste
- [ ] `LblParkProgress` TextBlock — Avancement du relevé
- [ ] `BtnParkOutcomeOnline` Button — Afficher les postes en ligne
- [ ] `BtnParkOutcomeNoReply` Button — Afficher les postes sans réponse
- [ ] `BtnParkOutcomeError` Button — Afficher les postes en erreur de ping
- [ ] `CmbSearchWorkspace` ComboBox — Vue personnelle
- [ ] `BtnSearchWorkspaceSave` Button — Enregistrer la vue
- [ ] `BtnSearchWorkspaceOpen` Button — Ouvrir la vue
- [ ] `BtnSearchWorkspaceRemove` Button — Retirer la vue
- [ ] `BtnSearchWorkspaceUndo` Button — Annuler le retrait de vue
- [ ] `CmbResultScope` ComboBox — Portée de lʼexport et des relevés
- [ ] `BtnSearchCompare` Button — Comparer les postes
- [ ] `BtnSearchPreview` Button — Aperçu local
- [ ] `LblSearchFilterSummary` TextBlock — Combinaison des critères
- [ ] `LblResultScope` TextBlock — Lignes traitées par lʼexport et les relevés
- [ ] `BtnParkModePing` Button — Qui répond ?
- [ ] `BtnParkModeConsole` Button — Qui est connecté ?
- [ ] `BtnParkModeAnalyse` Button — Matériel et widgets
- [ ] `BtnParkModeComplet` Button — Complet : correctifs
- [ ] `BtnParkRetryUnaddressed` Button — Réessayer les sans adresse
- [ ] `BtnParkVerify` Button — Arrêter ou vérifier la liste
- [ ] `DgObjects` DataGrid — Résultats : sélection et ouverture explicite
- [ ] `DirectoryFreshGlyph` TextBlock — 
- [ ] `PresenceDot` Ellipse — 
- [ ] `PresenceAgeText` TextBlock — {Binding PresenceAge}
- [ ] `LblSearchEmptyTitle` TextBlock — État de la liste de résultats
- [ ] `LblSearchEmptyText` TextBlock — Explication de la liste vide
- [ ] `BtnSearchEmptyNext` Button — Prochaine action proposée
- [ ] `SearchPreviewSplitter` GridSplitter — Largeur de lʼaperçu
- [ ] `BtnSearchPreviewClose` Button — Fermer lʼaperçu
- [ ] `LblSearchPreview` TextBlock — Objet consulté dans lʼaperçu
- [ ] `DgSearchPreview` DataGrid — Valeurs enregistrées de lʼobjet

### Fiche (`WsObject`)
- [ ] `LblObjectEmptyTitle` TextBlock — Aucune fiche ouverte
- [ ] `TxtObjectEmptySearch` TextBox — Rechercher une fiche
- [ ] `LstObjectEmptyRecent` ListBox — Dernières fiches consultées
- [ ] `LblObjectEmptyRecentNone` TextBlock — Aucune fiche consultée récemment.
- [ ] `LblObjectReadStatus` TextBlock — Sélectionnez un objet dans Rechercher.
- [ ] `BtnObjectReadRetry` Button — Réessayer la lecture AD
- [ ] `DetailTabs` TabControl — Vues de la fiche

#### Resume (`TabGeneric`)
- [ ] `TxtObjType` TextBox — Type de l’objet
- [ ] `TxtObjName` TextBox — Nom de l’objet
- [ ] `LblObjClass` Label — Classe
- [ ] `TxtObjClass` TextBox — Classe Active Directory
- [ ] `LblObjGuid` Label — GUID
- [ ] `TxtObjGuid` TextBox — Identifiant unique
- [ ] `TxtObjCreated` TextBox — Date de création
- [ ] `TxtObjChanged` TextBox — Dernière modification
- [ ] `TxtObjDn` TextBox — Emplacement dans l’annuaire
- [ ] `TxtObjPresence` TextBox — Presence
- [ ] `TxtObjPresenceTarget` TextBox — Cible testee
- [ ] `BtnCopyObjectSummary` Button — Copier le resume
- [ ] `BtnOpenParentBranch` Button — Ouvrir le parent
- [ ] `BtnObjectReread` Button — Relire lʼobjet depuis lʼannuaire
- [ ] `BtnObjectMore` Button — Plus dʼactions sur lʼobjet

#### Utilisateur (`TabUser`)
- [ ] `TxtUserSupportBand` TextBlock — État du compte relevé sur le contrôleur
- [ ] `TxtUserSupportDetail` TextBlock — Limites de lʼétat du compte
- [ ] `BtnUserSupportUnlock` Button — Déverrouiller maintenant le compte verrouillé
- [ ] `BtnUserSupportLockouts` Button — Lire les verrouillages du compte
- [ ] `TxtUserSupportLockouts` TextBlock — Verrouillages journalisés du compte
- [ ] `TxtUserGivenName` TextBox — Prenom
- [ ] `TxtUserSurname` TextBox — Nom
- [ ] `TxtUserDisplayName` TextBox — Nom affiche
- [ ] `TxtUserSam` TextBox — Identifiant court
- [ ] `TxtUserUpn` TextBox — Identifiant de connexion complet
- [ ] `TxtUserMail` TextBox — Mail
- [ ] `TxtUserPhone` TextBox — Telephone
- [ ] `TxtUserOffice` TextBox — Bureau
- [ ] `TxtUserDescription` TextBox — Description
- [ ] `TxtUserTitle` TextBox — Fonction
- [ ] `TxtUserDepartment` TextBox — Service
- [ ] `TxtUserCompany` TextBox — Societe
- [ ] `TxtUserManager` TextBox — Responsable
- [ ] `BtnUserManagerPick` Button — Choisir le responsable
- [ ] `BtnUserManagerOpen` Button — Ouvrir le responsable
- [ ] `BtnUserManagerClear` Button — Retirer le responsable
- [ ] `TxtUserPresence` TextBox — Présence du poste associé
- [ ] `TxtUserState` TextBox — État du compte
- [ ] `TxtUserLastLogon` TextBox — Dernière connexion connue
- [ ] `TxtUserPwdLastSet` TextBox — Date du dernier changement du mot de passe
- [ ] `TxtUserExpires` TextBox — Expiration du compte
- [ ] `TxtUserUac` TextBox — Options du compte AD
- [ ] `TxtUserLinkedComputers` ComboBox — Postes associés
- [ ] `BtnOpenLinkedComputer` Button — Ouvrir le poste
- [ ] `LblUserLinkSummary` TextBlock — Aucun poste associé.
- [ ] `BtnUserSave` Button — Enregistrer
- [ ] `BtnUserEdit` Button — Modifier la fiche
- [ ] `BtnUserCancelEdit` Button — Annuler les modifications
- [ ] `LblUserEditState` TextBlock — État des modifications de la fiche
- [ ] `TxtUserLogonByDc` TextBlock — Activité de connexion du compte
- [ ] `BtnUserLogonByDc` Button — Lire la dernière connexion sur chaque contrôleur

#### Coordonnees (`TabUserContact`)
- [ ] `TxtUserStreet` TextBox — Rue
- [ ] `TxtUserCity` TextBox — Ville
- [ ] `TxtUserState2` TextBox — Departement ou region
- [ ] `TxtUserPostalCode` TextBox — Code postal
- [ ] `TxtUserCountry` TextBox — Pays
- [ ] `TxtUserHomePhone` TextBox — Domicile
- [ ] `TxtUserMobile` TextBox — Mobile
- [ ] `TxtUserFax` TextBox — Telecopie
- [ ] `TxtUserIpPhone` TextBox — Telephone IP
- [ ] `TxtUserWebPage` TextBox — Page web
- [ ] `TxtUserEmployeeId` TextBox — Matricule
- [ ] `TxtUserProfilePath` TextBox — Chemin du profil
- [ ] `TxtUserScriptPath` TextBox — Script de connexion
- [ ] `TxtUserHomeDirectory` TextBox — Dossier de base
- [ ] `TxtUserHomeDrive` TextBox — Lecteur de base
- [ ] `TxtUserWorkstations` TextBox — Postes autorises
- [ ] `BtnUserSaveContact` Button — Enregistrer

#### Compte (`TabUserAdmin`)
- [ ] `BtnUserUnlock` Button — Déverrouiller le compte
- [ ] `BtnUserEnable` Button — Activer
- [ ] `BtnUserDisable` Button — Desactiver
- [ ] `PwdUserNew` PasswordBox — Mot de passe
- [ ] `TxtUserNewVisible` TextBox — Mot de passe
- [ ] `BtnRevealUserNew` Button — Afficher le mot de passe
- [ ] `ChkUnlockAfterReset` CheckBox — Deverrouiller ensuite
- [ ] `PwdUserConfirm` PasswordBox — Mot de passe
- [ ] `TxtUserConfirmVisible` TextBox — Mot de passe
- [ ] `BtnRevealUserConfirm` Button — Afficher la confirmation
- [ ] `ChkMustChangeAtLogon` CheckBox — Changement obligatoire
- [ ] `BtnUserGenPassword` Button — Générer un mot de passe temporaire
- [ ] `BtnUserResetPwd` Button — Mot de passe
- [ ] `ChkPwdNeverExpires` CheckBox — Mot de passe
- [ ] `ChkSmartcardRequired` CheckBox — Carte à puce
- [ ] `ChkAccountNotDelegated` CheckBox — Non delegable
- [ ] `BtnApplyAccountOptions` Button — Appliquer
- [ ] `ExpAccountSecurityOptions` Expander — Options de sécurité avancées
- [ ] `LblAccountSecurityWarning` TextBlock — Avertissement de sécurité
- [ ] `ChkPwdNotRequired` CheckBox — Mot de passe
- [ ] `ChkReversiblePwd` CheckBox — Mot de passe
- [ ] `ChkNoPreAuth` CheckBox — Sans pre-authentification
- [ ] `ChkUseDesOnly` CheckBox — Chiffrement DES
- [ ] `ChkTrustedForDelegation` CheckBox — Delegation approuvee
- [ ] `ChkTrustedToAuthDelegation` CheckBox — Delegation contrainte
- [ ] `DpAccountExpires` DatePicker — Expiration
- [ ] `BtnSetExpiration` Button — Fixer
- [ ] `BtnNeverExpires` Button — Jamais
- [ ] `BtnExpirePwdNow` Button — Mot de passe
- [ ] `BtnUserMove` Button — Choisir lʼOU de destination
- [ ] `TxtUserGroupTarget` TextBox — Groupe
- [ ] `BtnUserAddGroup` Button — Ajouter
- [ ] `BtnUserRemoveGroup` Button — Retirer

#### Groupe (`TabGroup`)
- [ ] `TxtGroupName` TextBox — Nom du groupe
- [ ] `TxtGroupDescription` TextBox — Description
- [ ] `BtnGroupSave` Button — Enregistrer
- [ ] `TxtGroupMemberTarget` TextBox — DN du membre à ajouter ou retirer
- [ ] `BtnGroupAddMember` Button — Ajouter membre
- [ ] `BtnGroupRemoveMember` Button — Retirer membre
- [ ] `TxtGroupMembersFilter` TextBox — Filtrer les membres
- [ ] `LblGroupMembers` TextBlock — Membres
- [ ] `DgGroupMembers` DataGrid — Membres directs du groupe

#### Unité dʼorganisation (`TabContainer`)
- [ ] `TxtNewOuParent` TextBox — Unité dʼorganisation parente
- [ ] `TxtNewOuName` TextBox — Nom
- [ ] `BtnCreateOu` Button — Creer

#### Appartenances (`TabMemberOf`)
- [ ] `BtnMemberOfNested` Button — Lire les groupes imbriqués
- [ ] `TxtMemberOfFilter` TextBox — Filtrer les groupes
- [ ] `LblMemberOf` TextBlock — Groupes
- [ ] `LblMembershipWhy` TextBlock — Pourquoi membre
- [ ] `DgMemberOf` DataGrid — Groupes de lʼobjet

#### Droits comparés (`TabUserAccessDiff`)
- [ ] `TxtAccessDiffOther` TextBox — Second utilisateur
- [ ] `BtnAccessDiffCompare` Button — Comparer les droits
- [ ] `BtnAccessDiffCopy` Button — Copier pour le ticket
- [ ] `LblAccessDiffStatus` TextBlock — État de la comparaison
- [ ] `DgAccessDiff` DataGrid — Groupes comparés

#### Attributs (`TabRaw`)
- [ ] `TxtRawAttrName` TextBox — Nom de lʼattribut Active Directory, par exemple description
- [ ] `TxtRawAttrValue` TextBox — Nouvelle valeur
- [ ] `BtnRawSet` Button — Appliquer
- [ ] `BtnRawCopyAll` Button — Copier tout
- [ ] `BtnRawClear` Button — Effacer
- [ ] `DgRawAttrs` DataGrid — Attributs de lʼobjet

#### Droits effectifs (`TabPermissions`)
- [ ] `BtnPermissionRefresh` Button — Analyser
- [ ] `BtnPermissionCopy` Button — Copier le rapport
- [ ] `LblPermissionSummary` TextBlock — Sélectionnez un objet.
- [ ] `DgPermissions` DataGrid — Estimation par action

### Comptes (`TabAccounts`)
- [ ] `BtnAccountAdRelogin` Button — Changer de compte
- [ ] `LblAccountAdIdentity` TextBlock — Aucune identité active.
- [ ] `LblAccountAdStatus` TextBlock — Aucune connexion à lʼannuaire.
- [ ] `PwdAccountAdCorrection` PasswordBox — Mot de passe actuel du compte de connexion
- [ ] `BtnAccountAdCorrect` Button — Corriger le mot de passe
- [ ] `DgAccountsInUse` DataGrid — Comptes utilisés en ce moment
- [ ] `LblAccountsInMemory` TextBlock — Comptes gardés en mémoire
- [ ] `DgAccountsInMemory` DataGrid — Liste des comptes gardés en mémoire
- [ ] `BtnAccountRemoteClear` Button — Effacer
- [ ] `LblAccountRemoteIdentity` TextBlock — Repli sur le compte AD courant.
- [ ] `TxtAccountRemoteUser` TextBox — Identifiant
- [ ] `PwdAccountRemote` PasswordBox — Mot de passe du compte poste
- [ ] `BtnAccountRemoteSave` Button — Activer
- [ ] `BtnAccountRemoteTry` Button — Essayer sur le poste sélectionné
- [ ] `LblAccountRemoteTry` TextBlock — Résultat de lʼessai du compte poste
- [ ] `ChkAccountRemoteRemember` CheckBox — Mémoriser sur ce PC
- [ ] `BtnAccountRemoteVault` Button — Utiliser le coffre
- [ ] `BtnAccountRemoteForgetVault` Button — Oublier le mot de passe
- [ ] `LblAccountRemoteStatus` TextBlock — Identifiant mémorisé dans la base ; le mot de passe nʼest jamais conservé.
- [ ] `BtnAccountSecretsClear` Button — Effacer
- [ ] `LblAccountSecretsIdentity` TextBlock — Repli sur le compte AD courant.
- [ ] `TxtAccountSecretsUser` TextBox — Identifiant
- [ ] `PwdAccountSecrets` PasswordBox — Mot de passe du compte secrets
- [ ] `BtnAccountSecretsTest` Button — Tester
- [ ] `BtnAccountSecretsSave` Button — Activer
- [ ] `ChkAccountSecretsRemember` CheckBox — Mémoriser sur ce PC
- [ ] `BtnAccountSecretsVault` Button — Utiliser le coffre
- [ ] `BtnAccountSecretsForgetVault` Button — Oublier le mot de passe
- [ ] `LblAccountSecretsStatus` TextBlock — Identifiant mémorisé dans la base ; le mot de passe nʼest jamais conservé.
- [ ] `LblAccountRule` TextBlock — Annuaire : compte de connexion. Postes : compte poste saisi dans Assistance poste sʼil existe, sinon compte Postes, sinon compte de connexio
- [ ] `DgTransportPolicy` DataGrid — Transports utilises
- [ ] `LblTransportPolicy` TextBlock — Aucun transport intrusif sans autorisation explicite et ciblee.

### Utilisateurs et postes (`TabRelations`)
- [ ] `LblRelationsSelection` TextBlock — Sélectionnez un utilisateur ou un poste depuis Rechercher.
- [ ] `LblLinkProbeStatus` TextBlock — Aucune recherche complémentaire en cours.
- [ ] `BtnRelationsHelp` Button — Précautions des relations
- [ ] `LblParkDetectionStatus` TextBlock — Cache conservé ; détection uniquement sur demande.
- [ ] `RelationTabs` TabControl — Vues des relations
- [ ] `BtnRelationSelectUser` Button — 
- [ ] `BtnLinkSelected` Button — 

#### Associations (`TabLinksSelected`)
- [ ] `LblLinkContext` TextBlock — Aucune sélection.
- [ ] `LblLinkOverview` TextBlock — Synthèse des associations
- [ ] `BtnRemoveLink` Button — Supprimer le lien sélectionné
- [ ] `BtnRestoreLink` Button — Restaurer une association
- [ ] `BtnOpenLinksCsv` Button — Exporter les liens visibles
- [ ] `DgLinks` DataGrid — Associations de la sélection
- [ ] `LblLinkEmpty` TextBlock — 
- [ ] `LblRelationAssociateHint` TextBlock — Sélectionnez dʼabord un utilisateur ou un poste dans Rechercher. Ensuite choisissez Détecter ou Rechercher.
- [ ] `RelationAssociateModeTabs` TabControl — 
- [ ] `LblRelationConfirm` TextBlock — 
- [ ] `BtnRelationConfirmCancel` Button — Annuler
- [ ] `BtnRelationConfirmApply` Button — Confirmer l’association

##### Détecter (`TabRelationDetect`)
- [ ] `BtnDetectUserComputers` Button — Rechercher les postes
- [ ] `BtnRelationsStop` Button — Arrêter la recherche inverse
- [ ] `BtnRelationOpenCandidate` Button — Ouvrir le poste candidat
- [ ] `BtnRelationAdopt` Button — Déclarer l’association
- [ ] `ExpRelationOptions` Expander — Options de la recherche inverse
- [ ] `ChkUserScanPark` CheckBox — Vérification réseau volontaire
- [ ] `CmbRelationScanScope` ComboBox — Périmètre des consoles
- [ ] `TxtRelationScanLimit` TextBox — Maximum de postes
- [ ] `ChkRelationEvents` CheckBox — Indices d’authentification du contrôleur
- [ ] `ChkRelationRdp` CheckBox — Sessions RDP
- [ ] `LblRelationPlan` TextBlock — Périmètre de détection
- [ ] `BtnRelationPlanCancel` Button — Annuler le périmètre
- [ ] `BtnRelationPlanRun` Button — Lancer la détection
- [ ] `DgRelationCandidates` DataGrid — Candidats de la recherche inverse

##### Rechercher (`TabRelationSearch`)
- [ ] `TxtRelationComputerSearch` TextBox — Nom du poste
- [ ] `BtnRelationComputerSearch` Button — Rechercher
- [ ] `DgRelationComputerSearch` DataGrid — Postes trouvés
- [ ] `LblRelationComputerSearchStatus` TextBlock — Saisissez au moins deux caractères.
- [ ] `BtnRelationAssociateSearchResult` Button — Associer ce poste

#### Toutes les associations (`TabLinksAll`)
- [ ] `CmbLinkImportFormat` ComboBox — Format de lʼimport
- [ ] `BtnImportLinks` Button — Importer des associations
- [ ] `BtnUndoImport` Button — Annuler l’import
- [ ] `BtnRestoreLinkAll` Button — Restaurer la suppression
- [ ] `BtnPruneLinks` Button — Associations orphelines
- [ ] `BtnExportAllLinks` Button — Exporter tout
- [ ] `TxtAllLinksFilter` TextBox — Filtrer les associations
- [ ] `ChkAllLinksDeclared` ToggleButton — Filtre Déclaré
- [ ] `ChkAllLinksObserved` ToggleButton — Filtre Observé
- [ ] `ChkAllLinksHistory` ToggleButton — Filtre Historique
- [ ] `ChkAllLinksConflict` ToggleButton — Filtre Contradictoire
- [ ] `LblAllLinksCount` TextBlock — 
- [ ] `LblLinkImportSummary` TextBlock — 
- [ ] `DgLinkImportPreview` DataGrid — Aperçu de l’import
- [ ] `BtnLinkImportApply` Button — Importer les lignes retenues
- [ ] `BtnLinkImportCancel` Button — Abandonner l’import
- [ ] `LblLinkOrphanSummary` TextBlock — 
- [ ] `DgLinkOrphans` DataGrid — Associations orphelines
- [ ] `BtnLinkOrphanRemove` Button — Retirer les orphelines cochées
- [ ] `BtnLinkOrphanClose` Button — Fermer la liste des orphelines
- [ ] `LblLinkOrphanConfirm` TextBlock — 
- [ ] `BtnLinkOrphanConfirmCancel` Button — Annuler le retrait
- [ ] `BtnLinkOrphanConfirmApply` Button — Confirmer le retrait
- [ ] `DgAllLinks` DataGrid — Toutes les associations

#### Détail (`TabLinksAttempts`)
- [ ] `DgLinkAttempts` DataGrid — Méthodes essayées lors de la dernière recherche dʼutilisateur

### Poste (`WsComputer`)
- [ ] `LblComputerEmptyTitle` TextBlock — Aucun poste ouvert
- [ ] `TxtComputerEmptySearch` TextBox — Rechercher un poste
- [ ] `LstComputerEmptyRecent` ListBox — Derniers postes consultés
- [ ] `LblComputerEmptyRecentNone` TextBlock — Aucun poste consulté récemment.
- [ ] `LblComputerReadStatus` TextBlock — Sélectionnez un objet dans Rechercher.
- [ ] `BtnComputerReadRetry` Button — Réessayer la lecture AD
- [ ] `LblCompHeaderName` TextBlock — 
- [ ] `LblCompHeaderPresence` TextBlock — Présence non vérifiée
- [ ] `LblCompHeaderSystem` TextBlock — 
- [ ] `BtnCompHeaderUser` Button — Ouvrir la fiche de lʼutilisateur associé
- [ ] `LblCompHeaderUser` TextBlock — 
- [ ] `LblCompHeaderNoUser` TextBlock — aucun associé
- [ ] `LblCompHeaderInventory` TextBlock — Aucun inventaire dans cette session
- [ ] `BtnCompAccountPill` Button — Compte poste
- [ ] `BtnCompHeaderRdp` Button — Bureau à distance
- [ ] `BtnCompHeaderC` Button — Ouvrir le disque C (C$)
- [ ] `BtnCompHeaderPing` Button — Tester la réponse
- [ ] `ComputerTabs` TabControl — Vues dʼassistance poste

#### Vue dʼensemble (`TabComputer`)
- [ ] `TxtCompName` TextBox — Nom du compte ordinateur
- [ ] `TxtCompDns` TextBox — Nom réseau complet
- [ ] `TxtCompPresence` TextBox — Présence réseau
- [ ] `TxtCompOs` TextBox — Système d’exploitation
- [ ] `TxtCompOsVersion` TextBox — Version du système
- [ ] `TxtCompDescription` TextBox — Description
- [ ] `TxtCompLocation` TextBox — Localisation
- [ ] `TxtCompManagedBy` TextBox — Responsable
- [ ] `BtnCompManagedByPick` Button — Choisir le responsable
- [ ] `BtnCompManagedByOpen` Button — Ouvrir le responsable
- [ ] `BtnCompManagedByClear` Button — Retirer le responsable
- [ ] `TxtCompState` TextBox — État du compte ordinateur
- [ ] `TxtCompLastLogon` TextBox — Dernière connexion connue
- [ ] `TxtCompUac` TextBox — Options du compte ordinateur
- [ ] `LblCompLinkBadge` TextBlock — 
- [ ] `LblCompLinkSummary` TextBlock — Aucun utilisateur associé
- [ ] `BtnOpenLinkedUser` Button — Ouvrir la fiche de lʼutilisateur associé
- [ ] `BtnRefreshMachineLink` Button — Détecter à nouveau lʼutilisateur
- [ ] `TxtCompLinkedUser` TextBox — Utilisateur associé
- [ ] `TxtCompLinkSource` TextBox — Origine de l’association
- [ ] `TxtCompLinkConfidence` TextBox — Qualification de lʼassociation
- [ ] `TxtCompLinkWhen` TextBox — Date de l’association
- [ ] `BtnCompSave` Button — Enregistrer
- [ ] `BtnCompEdit` Button — Modifier la fiche
- [ ] `BtnCompCancelEdit` Button — Annuler les modifications
- [ ] `LblCompEditState` TextBlock — État des modifications de la fiche
- [ ] `TxtCompLogonByDc` TextBlock — Activité de connexion du poste
- [ ] `BtnCompLogonByDc` Button — Lire la dernière connexion du poste sur chaque contrôleur
- [ ] `LblComputerDashboard` TextBlock — Lancez un inventaire (rapide ou complet) : le tableau de bord se remplit avec ses résultats.
- [ ] `BtnDashboardInventory` Button — Inventaire rapide pour le tableau de bord
- [ ] `BtnDashboardInventoryDeep` Button — Inventaire complet pour le tableau de bord
- [ ] `LblComputerParkStatus` TextBlock — Avancement du relevé de ce poste
- [ ] `BtnComputerParkStop` Button — Arrêter le relevé de ce poste

#### Intervenir (`TabComputerAdmin`)
- [ ] `BtnCompInterventionGrant` Button — Autoriser une intervention sur ce poste pendant 5 minutes
- [ ] `LblCompIntervention` TextBlock — Temps restant de lʼintervention
- [ ] `BtnCompInterventionRevoke` Button — Retirer lʼautorisation dʼintervention
- [ ] `BtnCompReadFallback` Button — Lire ce poste par tâche planifiée
- [ ] `LblCompInterventionState` TextBlock — État des autorisations du poste
- [ ] `BtnCompRdp` Button — Bureau à distance
- [ ] `BtnCompC` Button — Ouvrir le disque C (C$)
- [ ] `BtnCompManage` Button — Gestion de lʼordinateur
- [ ] `BtnCompEvents` Button — Observateur dʼévénements
- [ ] `BtnCompPSRemote` Button — Copier la commande PowerShell
- [ ] `LblCompOperationAccount` TextBlock — 
- [ ] `BtnCompPing` Button — Tester la réponse
- [ ] `BtnCompOpenDiag` Button — Lancer le diagnostic
- [ ] `BtnCompGpUpdate` Button — Actualiser les stratégies
- [ ] `BtnCompRimotte` Button — Exécuter un programme
- [ ] `BtnCompRestart` Button — Redémarrer le poste
- [ ] `LblCompAccountState` TextBlock — État du compte non lu.
- [ ] `BtnCompEnable` Button — Activer le compte du poste
- [ ] `BtnCompDisable` Button — Désactiver le compte du poste
- [ ] `TxtCompGroupTarget` TextBox — Groupe
- [ ] `BtnCompAddGroup` Button — Ajouter au groupe
- [ ] `BtnCompRemoveGroup` Button — Retirer du groupe
- [ ] `TxtCompNewName` TextBox — Nouveau nom
- [ ] `BtnCompRename` Button — Renommer dans Active Directory
- [ ] `BtnCompMove` Button — Déplacer le poste dans une autre OU
- [ ] `LblCompRestartTitle` TextBlock — Redémarrer le poste
- [ ] `LblCompRestartSessions` TextBlock — Lecture des sessions ouvertes…
- [ ] `LblCompRestartSessionLines` TextBlock — 
- [ ] `RbCompRestartDelayed` RadioButton — Redémarrer après un délai, avec message
- [ ] `TxtCompRestartMessage` TextBox — Message à lʼutilisateur
- [ ] `RbCompRestartNow` RadioButton — Redémarrer maintenant
- [ ] `BtnCompRestartSend` Button — Confirmer le redémarrage
- [ ] `BtnCompRestartCancel` Button — Fermer le panneau de redémarrage
- [ ] `LblCompRunTitle` TextBlock — Exécuter un programme sur le poste
- [ ] `LblCompRunConsent` TextBlock — 
- [ ] `RbCompRunSystem` RadioButton — En arrière-plan (compte système)
- [ ] `RbCompRunUser` RadioButton — Dans la session de lʼutilisateur
- [ ] `TxtCompRunUser` TextBox — Compte de la session
- [ ] `TxtCompRunCommand` TextBox — Programme à lancer
- [ ] `TxtCompRunArguments` TextBox — Arguments du programme
- [ ] `ChkCompRunElevated` CheckBox — Niveau dʼexécution le plus élevé
- [ ] `BtnCompRunStart` Button — Lancer le programme
- [ ] `BtnCompRunCancel` Button — Fermer le panneau dʼexécution
- [ ] `LblCompRunState` TextBlock — 
- [ ] `LblSessionsState` TextBlock — Lecture à la demande, distincte du dernier utilisateur connu. Un accès refusé ne signifie pas absence de session.
- [ ] `BtnSessionsRead` Button — Lire les sessions Windows
- [ ] `DgSessions` DataGrid — Sessions Windows
- [ ] `LblCompServicesState` TextBlock — Services non lus. « Lire les services » interroge ce poste en lecture seule.
- [ ] `BtnCompServicesRead` Button — Lire les services du poste
- [ ] `ChkCompServicesAutoStopped` CheckBox — Automatiques arrêtés seulement
- [ ] `TxtCompServicesFilter` TextBox — Filtrer les services
- [ ] `BtnCompServices` Button — Ouvrir les services dans la console
- [ ] `DgCompServices` DataGrid — Services du poste
- [ ] `BtnCompServiceStart` Button — Démarrer le service sélectionné
- [ ] `BtnCompServiceRestart` Button — Redémarrer le service sélectionné

#### Détails (`TabComputerDetails`)
- [ ] `ComputerDetailTabs` TabControl — Vues de détail du poste

##### Inventaire (`TabInventory`)
- [ ] `BtnRunInventory` Button — Inventaire rapide (≈1 min)
- [ ] `BtnRunInventoryDeep` Button — Inventaire complet (≈3 min)
- [ ] `BtnCopyInventory` Button — Copier
- [ ] `BtnExportInventory` Button — Exporter CSV
- [ ] `CmbInventoryCategory` ComboBox — Catégorie
- [ ] `LblInventoryStatus` TextBlock — Sélectionnez un poste, puis lancez lʼinventaire.
- [ ] `LblInventoryAge` TextBlock — 
- [ ] `LnkInventoryRefresh` Hyperlink — 
- [ ] `DgInventory` DataGrid — Éléments collectés
- [ ] `UxSplitter0` GridSplitter — Faites glisser pour redimensionner les panneaux
- [ ] `DgInventoryAccess` DataGrid — Détail par source

##### Logiciels (`TabSoftware`)
- [ ] `BtnLoadSoftware` Button — Charger les logiciels
- [ ] `ChkSoftwarePerUser` CheckBox — Par utilisateur
- [ ] `ChkSoftwareStore` CheckBox — Applications Store
- [ ] `ChkSoftwareUpdates` CheckBox — Mises à jour
- [ ] `BtnCopySoftware` Button — Copier
- [ ] `BtnExportSoftware` Button — Exporter CSV
- [ ] `BtnSoftwareColumns` ToggleButton — Colonnes
- [ ] `CmbSoftwareView` ComboBox — Affichage des logiciels
- [ ] `LblSoftwareDashboard` TextBlock — Chargez les logiciels pour afficher la synthèse.
- [ ] `TxtSoftwareFilter` TextBox — Filtre
- [ ] `CmbSoftwareScope` ComboBox — Portee
- [ ] `LblSoftwareStatus` TextBlock — Sélectionnez un poste, puis chargez la liste.
- [ ] `LblSoftwareFilterChip` TextBlock — 
- [ ] `BtnSoftwareFilterClear` Button — Retirer le filtre
- [ ] `DgSoftware` DataGrid — Logiciels détectés
- [ ] `LblSoftwareAccessSummary` TextBlock — Aucune portée lue.
- [ ] `ExpSoftwareAccess` Expander — Détail par portée
- [ ] `DgSoftwareAccess` DataGrid — Détail par portée

#### Diagnostic (`TabComputerHealth`)
- [ ] `ComputerDiagTabs` TabControl — Vues de diagnostic du poste

##### Contrôles (`TabComputerChecks`)
- [ ] `BtnRunComputerDiag` Button — Lancer le diagnostic
- [ ] `BtnCopyComputerDiag` Button — Copier le rapport
- [ ] `LblComputerDiag` TextBlock — Pret.
- [ ] `DgComputerDiag` DataGrid — Résultat de chaque contrôle

##### WMI (`TabWmi`)
- [ ] `BtnWmiNamespaces` Button — Charger
- [ ] `BtnWmiClasses` Button — Classes
- [ ] `BtnWmiQuery` Button — Interroger
- [ ] `BtnWmiCopy` Button — Copier
- [ ] `BtnWmiExport` Button — Exporter CSV
- [ ] `TxtWmiWhere` TextBox — Filtre
- [ ] `TxtWmiLimit` TextBox — Limite
- [ ] `LblWmiStatus` TextBlock — Sélectionnez un poste, puis chargez les espaces de noms.
- [ ] `LblWmiNamespaceCount` TextBlock — 0 espace
- [ ] `LstWmiNamespaces` ListBox — 0 espace
- [ ] `UxSplitter2` GridSplitter — Faites glisser pour redimensionner les panneaux
- [ ] `TxtWmiClassFilter` TextBox — Classes
- [ ] `LblWmiClassCount` TextBlock — 0 classe
- [ ] `LstWmiClasses` ListBox — 0 classe
- [ ] `UxSplitter3` GridSplitter — Faites glisser pour redimensionner les panneaux
- [ ] `DgWmiSchema` DataGrid — Propriétés de la classe
- [ ] `UxSplitter4` GridSplitter — Faites glisser pour redimensionner les panneaux
- [ ] `DgWmiInstances` DataGrid — Instances

#### Secrets (`TabSecurity`)
- [ ] `BtnLoadBitLocker` Button — Lister les clés BitLocker
- [ ] `BtnLoadLaps` Button — Lire le mot de passe LAPS
- [ ] `BtnToggleSecrets` Button — Afficher la valeur choisie
- [ ] `BtnCopySecret` Button — Copier
- [ ] `BtnCopyAllSecrets` Button — Copier tout
- [ ] `BtnClearSecrets` Button — Vider
- [ ] `LblSecretsStatus` TextBlock — Sélectionnez un poste, puis listez les clés BitLocker ou lisez le mot de passe LAPS.
- [ ] `BtnSecretsPrerequisite` Button — Ouvrir le prerequis
- [ ] `TxtBitLockerRecoveryId` TextBox — Identifiant de récupération BitLocker
- [ ] `LblBitLockerRecoveryHint` TextBlock — « Lister les clés BitLocker » affiche les métadonnées, sans aucune clé. Une seule clé est lue, à votre demande.
- [ ] `LblSecretsExposure` TextBlock — Une valeur à la fois, affichée brièvement, jamais journalisée ni mise en cache.
- [ ] `LblBitLockerKeyCardId` TextBlock — Identifiant de récupération de la clé affichée
- [ ] `BitLockerKeyBlocks` ItemsControl — Blocs de la clé de récupération
- [ ] `BitLockerKeyRing` Ellipse — Temps restant
- [ ] `LblBitLockerKeyCountdown` TextBlock — Secondes restantes
- [ ] `BtnBitLockerKeyExtend` Button — Prolonger 30 s
- [ ] `BtnBitLockerKeyHide` Button — Masquer maintenant
- [ ] `DgSecrets` DataGrid — Clés et mots de passe récupérés

### Outils (`TabApplicationTools`)
- [ ] `LblRootOuChoice` TextBlock — Aucune OU racine : le domaine entier reste le défaut.
- [ ] `BtnRootOuChoose` Button — Choisir
- [ ] `BtnRootOuReset` Button — Revenir au domaine
- [ ] `ApplicationToolTabs` TabControl — Outils de l’application

#### Fiabilité (`TabGuard`)
- [ ] `LblGuardReceipts` TextBlock — Lecture des reçus locaux en attente. Les écritures restent protégées.
- [ ] `BtnGuardReceiptRefresh` Button — Actualiser les reçus
- [ ] `DgGuardReceipts` DataGrid — Reçus des opérations
- [ ] `LblGuardReceiptSelection` TextBlock — Reçu sélectionné
- [ ] `TxtGuardReceiptReason` TextBox — Motif de la revue
- [ ] `LblGuardReceiptReasonCount` TextBlock — Longueur du motif
- [ ] `BtnGuardReceiptVerify` Button — Vérifier par relecture
- [ ] `BtnGuardReceiptReview` Button — Consigner la revue
- [ ] `LblGuardDraft` TextBlock — Aucune modification de formulaire en attente.
- [ ] `BtnGuardDraft` Button — Comparer les saisies
- [ ] `LblGuardRemote` TextBlock — Les sondes ordinaires ne créent ni service ni tâche. Les anciens transports avec dépôts demandent une autorisation distincte.
- [ ] `LblGuardReadFallback` TextBlock — Une lecture ne bascule jamais seule sur PsExec ou une tâche planifiée. Demandez-le pour la lecture qui en a besoin.
- [ ] `BtnGuardRemote` Button — Autoriser une intervention sur cette machine
- [ ] `BtnGuardReadFallback` Button — Lire ce poste par tache planifiee
- [ ] `BtnGuardRemoteOff` Button — Retirer l'autorisation
- [ ] `BtnGuardExport` Button — Diagnostic expurgé
- [ ] `BtnGuardWhy` Button — Pourquoi une action est indisponible ?
- [ ] `ChkGuardReconcile` CheckBox — Revérifier le périmètre consulté en arrière-plan
- [ ] `LblGuardMetrics` TextBlock — Les mesures locales apparaîtront ici.
- [ ] `BtnGuardPesto` Button — Ouvrir Pesto
- [ ] `BtnGuardFilPro` Button — Ouvrir FilPro

#### Vérification (`TabSelfCheck`)
- [ ] `BtnSelfCheckQuick` Button — Vérification rapide
- [ ] `BtnSelfCheckFull` Button — Vérification complète
- [ ] `BtnSelfCheckCopy` Button — Copier le rapport
- [ ] `BtnSelfCheckExport` Button — Exporter le diagnostic
- [ ] `LblSelfCheckStatus` TextBlock — Check rapide automatique en attente.
- [ ] `DgSelfCheck` DataGrid — Résultat de chaque contrôle

#### Base autonome (`TabIndex`)
- [ ] `BtnIndexScopePick` Button — Choisir lʼOU de mise à jour
- [ ] `LblIndexScopeChoice` TextBlock — Choisissez une OU
- [ ] `IndexWorkspaceTabs` TabControl — 

##### Mise à jour (`TabIndexUpdate`)
- [ ] `BtnIndexScopeUpdate` Button — Tout relire dans lʼOU choisie
- [ ] `LblIndexTileAccounts` TextBlock — Comptes de la base locale
- [ ] `LblIndexTileAccountsDetail` TextBlock — Précision sur les comptes
- [ ] `LblIndexTileComputers` TextBlock — Postes de la base locale
- [ ] `LblIndexTileComputersDetail` TextBlock — Postes actifs et désactivés
- [ ] `LblIndexTileLinks` TextBlock — Associations de la base locale
- [ ] `LblIndexTileLinksDetail` TextBlock — Précision sur les associations
- [ ] `LblIndexTileUpdated` TextBlock — Âge de la dernière mise à jour
- [ ] `LblIndexTileUpdatedDetail` TextBlock — Date de la dernière mise à jour
- [ ] `LblIndexFreshness` TextBlock — 
- [ ] `LblIndexStats` TextBlock — 
- [ ] `PbIndexProgress` ProgressBar — 
- [ ] `LblIndexProgress` TextBlock — 
- [ ] `ChkParkSweepEnabled` CheckBox — Détection manuelle
- [ ] `BtnParkHarvest` Button — Lire le journal du controleur
- [ ] `BtnParkReset` Button — Oublier les relevés
- [ ] `LblParkStatus` TextBlock — Aucun relevé.

##### Données (`TabIndexData`)
- [ ] `TxtIndexSearch` TextBox — Rechercher
- [ ] `LblIndexStatus` TextBlock — Prêt.
- [ ] `BtnIndexBrowse` Button — Afficher / actualiser les objets
- [ ] `BtnIndexPrevious` Button — Page précédente
- [ ] `BtnIndexNext` Button — Page suivante
- [ ] `BtnIndexResetSort` Button — Tri par pertinence
- [ ] `BtnIndexOpen` Button — Ouvrir lʼobjet
- [ ] `BtnIndexExport` Button — Exporter CSV
- [ ] `DgIndex` DataGrid — Résultats de lʼindex local

##### Stockage (`TabIndexStorage`)
- [ ] `LblIndexLocation` TextBlock — Emplacement de la base
- [ ] `LblIndexBackupStatus` TextBlock — 
- [ ] `BtnIndexCopyPath` Button — Copier le chemin de la base
- [ ] `BtnIndexOpenFolder` Button — Ouvrir lʼemplacement de la base
- [ ] `BtnIndexBackup` Button — Sauvegarder la base maintenant
- [ ] `BtnIndexBackupTo` Button — Copier une sauvegarde de la base
- [ ] `BtnStorageMove` Button — Déplacer la base locale
- [ ] `BtnStorageRestore` Button — Restaurer une sauvegarde
- [ ] `BtnStorageResume` Button — Reprendre la bascule
- [ ] `BtnStorageRollback` Button — Revenir à la base précédente
- [ ] `LblStorageMaintenance` TextBlock — Assistant de stockage
- [ ] `LblStorageSpace` TextBlock — Espace disque de la base
- [ ] `BtnGuardStoreResume` Button — Reprendre les sauvegardes
- [ ] `BtnGuardLegacyImport` Button — Reprendre les anciennes données
- [ ] `LblGuardMigration` TextBlock — La simulation des anciennes données sera affichée ici avant confirmation.
- [ ] `ChkStorageAutoBackup` CheckBox — Sauvegarde automatique
- [ ] `TxtStorageBackupHours` TextBox — Intervalle des sauvegardes
- [ ] `TxtStorageBackupKeep` TextBox — Sauvegardes à conserver
- [ ] `LblStorageBackupSchedule` TextBlock — État des sauvegardes
- [ ] `TxtStoragePresenceDays` TextBox — Conservation : Présence ping
- [ ] `TxtStorageConsoleDays` TextBox — Conservation : Utilisateur connecté
- [ ] `TxtStorageInventoryDays` TextBox — Conservation : Inventaire
- [ ] `TxtStorageProbeDays` TextBox — Conservation : Sondes
- [ ] `TxtStorageDetailDays` TextBox — Conservation : Détails
- [ ] `TxtStorageLinkHistoryDays` TextBox — Conservation : historique des associations
- [ ] `BtnStoragePolicySave` Button — Enregistrer les réglages de stockage
- [ ] `BtnStorageRetentionPreview` Button — Prévisualiser la conservation
- [ ] `BtnStorageRetentionApply` Button — Appliquer la conservation
- [ ] `LblStorageRetention` TextBlock — Résultat de la conservation
- [ ] `ExpStorageDataPolicy` Expander — Politique des données locales
- [ ] `LblStorageDataPolicy` TextBlock — Engagement sur les données locales
- [ ] `DgStorageDataPolicy` DataGrid — Données locales de Domenia
- [ ] `ExpStorageMaintenance` Expander — Stockage local
- [ ] `BtnStorageUsage` Button — Mesurer le stockage local
- [ ] `LblStorageUsage` TextBlock — Aucune mesure pour cette session.
- [ ] `BtnStorageIntegrity` Button — Contrôler lʼintégrité de la base
- [ ] `LblStorageIntegrity` TextBlock — Contrôle dʼintégrité
- [ ] `LblStorageLimits` TextBlock — Limites du stockage local
- [ ] `ChkStoragePurgeObservations` CheckBox — Purger les observations
- [ ] `ChkStoragePurgeSnapshots` CheckBox — Purger les instantanés
- [ ] `ChkStoragePurgeIndex` CheckBox — Purger lʼindex local
- [ ] `ChkStoragePurgeHistory` CheckBox — Purger lʼhistorique ancien
- [ ] `TxtStorageHistoryDays` TextBox — Âge minimal en jours
- [ ] `BtnStoragePurgePreview` Button — Simuler la purge
- [ ] `BtnStoragePurge` Button — Purger les données locales
- [ ] `LblStoragePurge` TextBlock — Choisissez les données à oublier puis simulez.

#### Charge & stats (`TabOperationStats`)
- [ ] `BtnOperationStatsRefresh` Button — Actualiser
- [ ] `BtnOperationStatsExport` Button — Exporter CSV
- [ ] `LblOperationStats` TextBlock — Aucune mesure chargee.
- [ ] `DgOperationStats` DataGrid — Statistiques des opérations

#### Relevés (`TabCollectionLimits`)
- [ ] `LblRunsCurrent` TextBlock — Aucun relevé en cours.
- [ ] `BtnRunsStop` Button — Arrêter
- [ ] `LblRunsResume` TextBlock — Aucun relevé interrompu.
- [ ] `BtnRunsResume` Button — Reprendre
- [ ] `BtnRunsResumeDiscard` Button — Abandonner
- [ ] `BtnRunsRefresh` Button — Actualiser la liste
- [ ] `LblRunsList` TextBlock — 
- [ ] `DgRuns` DataGrid — 
- [ ] `CmbCollectionWidgetMax` ComboBox — 
- [ ] `CmbCollectionWmiRetries` ComboBox — 
- [ ] `CmbCollectionWmiRetryDelay` ComboBox — 

#### Atelier de requêtes (`WsQueryWorkshop`)
- [ ] `QueryWorkshopHost` ContentControl — 

#### Audit AD (`WsAdAudit`)

#### Assistance (`WsAssistance`)

#### Domaine (`TabDomain`)
- [ ] `BtnLoadDomain` Button — Analyser le domaine
- [ ] `BtnCopyDomain` Button — Copier le rapport
- [ ] `LblDomainLocalTotals` TextBlock — Totaux de la copie locale
- [ ] `LblDomainStatus` TextBlock — Pret.
- [ ] `DgDomain` DataGrid — Informations relevées

#### Commandes (`TabCmdlets`)
- [ ] `BtnLoadCmdlets` Button — Charger les commandes
- [ ] `TxtCmdletFilter` TextBox — Cherche par nom de commande, module ou paramètre
- [ ] `CmbCmdletModule` ComboBox — Nʼaffiche que les commandes dʼun module
- [ ] `BtnCmdletClearFilter` Button — Effacer le filtre
- [ ] `LblCmdletCount` TextBlock — 0 commande
- [ ] `DgCmdlets` DataGrid — Commandes disponibles
- [ ] `UxSplitter5` GridSplitter — Faites glisser pour redimensionner les panneaux
- [ ] `BtnCopyCmdlet` Button — Copier la commande
- [ ] `BtnCopyCmdletSyntax` Button — Copier la syntaxe
- [ ] `BtnCopyCmdletHelp` Button — Copier lʼaide
- [ ] `TxtCmdletHelp` TextBox — Description, syntaxe, paramètres et exemples de la commande sélectionnée

#### Journal (`TabLog`)
- [ ] `TxtLog` TextBox — Journal technique

### Vue AdAudit
- [ ] `DomeniaAdAuditView` UserControl — 
- [ ] `BtnAdAuditCopy` Button — Copier la vue affichée
- [ ] `AdAuditTabs` TabControl — Vues de lʼaudit AD

#### Objet sélectionné (`TabAdAuditObject`)
- [ ] `BtnAdAuditUseSelection` Button — Reprendre la sélection
- [ ] `LblAdAuditTarget` TextBlock — Aucun objet : ouvrez une fiche depuis Rechercher, puis revenez ici.
- [ ] `AdAuditObjectTabs` TabControl — Lectures de lʼobjet

##### Mot de passe (`TabAdAuditPolicy`)
- [ ] `BtnAdAuditPolicy` Button — Lire la stratégie applicable
- [ ] `LblAdAuditPolicy` TextBlock — Lecture à la demande pour un compte utilisateur.
- [ ] `DgAdAuditPolicy` DataGrid — Stratégie applicable

##### Groupes imbriqués (`TabAdAuditGroups`)
- [ ] `BtnAdAuditGroups` Button — Lire les appartenances imbriquées
- [ ] `LblAdAuditGroups` TextBlock — Lecture à la demande pour un utilisateur, un poste ou un groupe.
- [ ] `CmbAdAuditGroupTarget` ComboBox — Groupe à expliquer
- [ ] `BtnAdAuditGroupConfirm` Button — Confirmer sur le contrôleur
- [ ] `LblAdAuditGroupPath` TextBlock — Lisez dʼabord les appartenances, puis choisissez un groupe.
- [ ] `DgAdAuditGroups` DataGrid — Groupes imbriqués lus

##### Délégations (`TabAdAuditAcl`)
- [ ] `BtnAdAuditAcl` Button — Lire les délégations
- [ ] `ChkAdAuditAclExplicit` CheckBox — Entrées posées sur lʼobjet seulement
- [ ] `TxtAdAuditAclFilter` TextBox — Filtrer les délégations
- [ ] `LblAdAuditAcl` TextBlock — Lecture à la demande pour lʼobjet sélectionné.
- [ ] `BtnAdAuditAclToken` Button — Inclure les groupes du bénéficiaire
- [ ] `LblAdAuditAclEstimate` TextBlock — Sélectionnez une entrée pour estimer les droits de son bénéficiaire.
- [ ] `DgAdAuditAclEstimate` DataGrid — Estimation des droits
- [ ] `DgAdAuditAcl` DataGrid — Entrées de la liste de contrôle dʼaccès

##### Stratégies de groupe (`TabAdAuditGpo`)
- [ ] `BtnAdAuditGpoLinks` Button — Lire les liens GPO
- [ ] `BtnAdAuditGpoApplied` Button — Lire le résultat appliqué sur le poste
- [ ] `LblAdAuditGpo` TextBlock — Lecture à la demande pour un utilisateur, un poste ou une unité dʼorganisation.
- [ ] `DgAdAuditGpoFacts` DataGrid — Constats des stratégies de groupe
- [ ] `DgAdAuditGpo` DataGrid — Liens GPO et résultat appliqué

##### Identité du poste (`TabAdAuditMachine`)
- [ ] `BtnAdAuditMachineIdentity` Button — Vérifier lʼidentité du poste
- [ ] `LblAdAuditMachineIdentity` TextBlock — Lecture à la demande pour un poste.
- [ ] `DgAdAuditMachineIdentity` DataGrid — Identité du poste

##### Postes et utilisateurs (`TabAdAuditHistory`)
- [ ] `LblAdAuditRelationOverview` TextBlock — Sélectionnez un utilisateur ou un poste.
- [ ] `BtnAdAuditHistory` Button — Lire lʼhistorique enregistré
- [ ] `LblAdAuditHistory` TextBlock — Historique non lu.
- [ ] `DgAdAuditHistory` DataGrid — Historique enregistré des associations

#### Contrôleurs (`TabAdAuditDcs`)
- [ ] `BtnAdAuditDcList` Button — Lister les contrôleurs
- [ ] `BtnAdAuditDcProbe` Button — Diagnostiquer les contrôleurs choisis
- [ ] `BtnAdAuditDcServices` Button — Lire les services des contrôleurs
- [ ] `LblAdAuditDc` TextBlock — Listez les contrôleurs, choisissez-en jusquʼà 10, puis lancez le diagnostic.
- [ ] `DgAdAuditDcList` DataGrid — Contrôleurs du domaine
- [ ] `AdAuditDcResultTabs` TabControl — Résultats du diagnostic des contrôleurs

##### Synthèse (`TabAdAuditDcHealth`)
- [ ] `DgAdAuditDcFacts` DataGrid — Constats du diagnostic
- [ ] `DgAdAuditHealth` DataGrid — Synthèse par contrôleur

##### Réplication (`TabAdAuditDcRepl`)
- [ ] `DgAdAuditRepl` DataGrid — Liens de réplication entrants

##### Services (`TabAdAuditDcServices`)
- [ ] `DgAdAuditServices` DataGrid — Services des contrôleurs

#### Identités (`TabAdAuditIdentity`)
- [ ] `LblAdAuditScope` TextBlock — Périmètre : choisissez une OU dans lʼarbre de Rechercher.
- [ ] `BtnAdAuditScan` Button — Analyser les identités de lʼOU
- [ ] `ChkAdAuditScanSubtree` CheckBox — Inclure les sous-OU
- [ ] `LblAdAuditScan` TextBlock — Analyse à la demande. Chaque constat est à revoir : rien nʼest fusionné, renommé ni supprimé.
- [ ] `DgAdAuditScan` DataGrid — Constats sur les identités

### Vue Assistance
- [ ] `DomeniaAssistanceView` UserControl — 
- [ ] `CmbAssistanceRecipe` ComboBox — Recette dʼassistance
- [ ] `LblAssistanceSubject` TextBlock — Aucune sélection : ouvrez la fiche du compte ou du poste concerné.
- [ ] `LblAssistanceRecipe` TextBlock — Choisissez une recette.
- [ ] `DgAssistanceSteps` DataGrid — Étapes de la recette
- [ ] `BtnAssistanceRun` Button — Lancer lʼétape choisie
- [ ] `BtnAssistanceOpen` Button — Ouvrir la vue de lʼétape
- [ ] `LblAssistanceStep` TextBlock — Choisissez une étape.

### Vue CommandPalette
- [ ] `BtnPaletteClose` Button — Fermer la palette
- [ ] `TxtPaletteSearch` TextBox — Rechercher une action
- [ ] `LstPaletteCommands` ListBox — Actions
- [ ] `LblPaletteDetail` TextBlock — Détail de lʼaction choisie
- [ ] `LblPaletteStatus` TextBlock — État de la palette

### Vue DirectorySchema
- [ ] `DomeniaAdSchemaView` UserControl — 
- [ ] `BtnAdSchemaRead` Button — Lire le schéma
- [ ] `CmbAdSchemaKind` ComboBox — 
- [ ] `TxtAdSchemaFilter` TextBox — 
- [ ] `LblAdSchemaStatus` TextBlock — Schéma non lu dans cette session.
- [ ] `DgAdSchemaEntries` DataGrid — 
- [ ] `DgAdSchemaClassAttributes` DataGrid — 
- [ ] `LblAdSchemaDetail` TextBlock — Choisissez une classe ou un attribut.
- [ ] `TxtAdSchemaLdapFilter` TextBox — 
- [ ] `BtnAdSchemaAnalyze` Button — Analyser le filtre
- [ ] `BtnAdSchemaInsert` Button — Ajouter lʼattribut choisi
- [ ] `LblAdSchemaAnalysis` TextBlock — Aucun filtre analysé.

### Vue DirectorySync
- [ ] `DomeniaDirectorySyncView` UserControl — 
- [ ] `LblSyncCensus` TextBlock — 
- [ ] `BtnSyncCensusRun` Button — Relire lʼOU choisie en entier
- [ ] `LblSyncGaps` TextBlock — Liste des objets manquants non lue.
- [ ] `BtnSyncGapRead` Button — Lire les objets manquants…
- [ ] `BtnSyncAbsencesRefresh` Button — Actualiser la liste
- [ ] `BtnSyncAbsencesCheck` Button — Vérifier les disparitions…
- [ ] `LblSyncAbsences` TextBlock — Liste non lue.
- [ ] `DgSyncAbsences` DataGrid — 
- [ ] `LblSnapshotNotice` TextBlock — 
- [ ] `TxtSnapshotLabel` TextBox — 
- [ ] `BtnSnapshotCapture` Button — Enregistrer un relevé du périmètre
- [ ] `BtnSnapshotDelete` Button — Supprimer le relevé choisi…
- [ ] `LblSnapshots` TextBlock — Aucun relevé lu.
- [ ] `DgSnapshots` DataGrid — 
- [ ] `CmbSnapshotBefore` ComboBox — 
- [ ] `CmbSnapshotAfter` ComboBox — 
- [ ] `BtnSnapshotCompare` Button — Comparer
- [ ] `LblSnapshotCompare` TextBlock — Choisissez deux relevés du même périmètre.
- [ ] `DgSnapshotDiff` DataGrid — 

### Vue Inline
- [ ] `LblInlineRequestTitle` TextBlock — 
- [ ] `LblInlineRequestMessage` TextBlock — 
- [ ] `LblInlineRequestChanges` TextBlock — 
- [ ] `LblInlineRequestTyped` TextBlock — 
- [ ] `TxtInlineRequestTyped` TextBox — 
- [ ] `InlineRequestDetails` Expander — Détails techniques
- [ ] `TxtInlineRequestDetails` TextBox — 
- [ ] `BtnInlineRequestAlternate` Button — 
- [ ] `BtnInlineRequestCancel` Button — Réponse sûre
- [ ] `BtnInlineRequestConfirm` Button — Confirmer la demande

### Vue MachineAccount
- [ ] `BtnMachineAccountClose` Button — Fermer le panneau du compte poste
- [ ] `LblMachineCredential` TextBlock — Compte utilisé pour les postes
- [ ] `TxtMachineAdminUser` TextBox — Compte poste
- [ ] `PwdMachineAdmin` PasswordBox — Mot de passe du compte poste
- [ ] `LblMachineAdminPeek` TextBlock — Mot de passe affiché
- [ ] `BtnRevealMachineAdmin` Button — Afficher le mot de passe du compte poste pendant 5 secondes
- [ ] `BtnSetMachineCredential` Button — Utiliser ce compte pour les postes
- [ ] `BtnClearMachineCredential` Button — Revenir au compte de connexion

### Vue Operations
- [ ] `BtnOperationsClose` Button — Fermer le panneau des opérations
- [ ] `BtnOperationsReceipts` Button — Opérations à vérifier
- [ ] `LblSuiteActivityState` TextBlock — 
- [ ] `DgSuiteActivity` DataGrid — Opérations en cours
- [ ] `DgOperationsRecent` DataGrid — Dernières opérations
- [ ] `LblOperationsTrace` TextBlock — Étapes de lʼopération choisie
- [ ] `BtnOperationsCopyTrace` Button — Copier le détail de lʼopération
- [ ] `BtnOperationsJournal` Button — Ouvrir le journal
- [ ] `BtnOperationsDiagnostic` Button — Diagnostic expurgé
- [ ] `LblOperationsHealth` TextBlock — Santé du moteur

### Vue Query
- [ ] `DomeniaQueryView` UserControl — 
- [ ] `BtnQueryBack` Button — Retour
- [ ] `BtnQueryScope` Button — Choisir une OU
- [ ] `LblQueryScope` TextBlock — 
- [ ] `CmbFleetQuery` ComboBox — 
- [ ] `BtnQueryLoad` Button — Charger
- [ ] `BtnQueryNew` Button — Nouvelle
- [ ] `BtnQueryRun` Button — Aperçu local
- [ ] `LblQueryStatus` TextBlock — Choisissez un modèle, ou ajoutez des conditions.
- [ ] `QueryWorkspaceTabs` TabControl — 

#### 2. Aperçu (`TabQueryResults`)
- [ ] `LblQuerySegment` TextBlock — 
- [ ] `BtnQueryClearSegment` Button — Retirer le segment
- [ ] `TxtFleetMachineFilter` TextBox — 
- [ ] `CmbFleetMachineState` ComboBox — 
- [ ] `CmbQueryResult` ComboBox — 
- [ ] `LblFleetMachineCount` TextBlock — 
- [ ] `BtnQueryPrevious` Button — Page précédente
- [ ] `BtnQueryNext` Button — Page suivante
- [ ] `BtnQueryContinueSave` Button — Enregistrer ou réutiliser →
- [ ] `BtnQueryExport` Button — Tout exporter (CSV)
- [ ] `ExpQueryObject` Expander — Objet sélectionné · fiche locale
- [ ] `LblQueryObject` TextBlock — Sélectionnez un poste pour consulter ses données.
- [ ] `BtnQueryObjectOpen` Button — Fiche AD et actions…
- [ ] `BtnQueryObjectCollect` Button — Actualiser ce poste…
- [ ] `BtnQueryObjectCopy` Button — Copier le chemin AD
- [ ] `DgQueryExplanation` DataGrid — 
- [ ] `DgQueryObjectFields` DataGrid — 
- [ ] `ExpQueryGroups` Expander — Répartition complète · toutes les valeurs
- [ ] `LblQueryGroups` TextBlock — 
- [ ] `TxtQueryGroupFilter` TextBox — 
- [ ] `BtnQueryGroupsPrevious` Button — Valeurs précédentes
- [ ] `BtnQueryGroupsNext` Button — Valeurs suivantes
- [ ] `BtnQueryGroupsShow` Button — Afficher ces postes
- [ ] `DgQueryGroups` DataGrid — 
- [ ] `DgFleetMachines` DataGrid — 

#### 1. Créer (`TabQueryCompose`)
- [ ] `TxtQueryFieldSearch` TextBox — 
- [ ] `CmbQueryJunction` ComboBox — 
- [ ] `CmbQueryField` ComboBox — 
- [ ] `CmbQueryOperator` ComboBox — 
- [ ] `TxtQueryValue` TextBox — 
- [ ] `CmbQueryValueChoice` ComboBox — 
- [ ] `BtnQueryAddCondition` Button — Ajouter
- [ ] `BtnQueryBrowseCatalog` Button — Parcourir le catalogue…
- [ ] `LblQueryValueConversion` TextBlock — 
- [ ] `LblQueryFieldHelp` TextBlock — 
- [ ] `DgQueryConditions` DataGrid — 
- [ ] `BtnQueryRemoveCondition` Button — Retirer la condition
- [ ] `BtnQueryCollect` Button — Collecter les données requises…
- [ ] `ExpQueryCollectionPlan` Expander — Plan de collecte des informations manquantes
- [ ] `LblQueryCollectionPlan` TextBlock — 
- [ ] `BtnQueryCoverage` Button — Vérifier les informations disponibles
- [ ] `BtnQueryPreview` Button — Voir l’aperçu local →
- [ ] `ExpQueryAdvanced` Expander — Conditions avancées et paramètres
- [ ] `LstQueryExpression` ListBox — 
- [ ] `BtnQueryGroupAll` Button — + Groupe ET
- [ ] `BtnQueryGroupAny` Button — + Groupe OU
- [ ] `BtnQueryGroupNot` Button — + Groupe NON
- [ ] `BtnQueryTreeCondition` Button — + Critère choisi ci-dessus
- [ ] `BtnQueryTreeRemove` Button — Retirer
- [ ] `BtnQueryTreeUp` Button — ↑
- [ ] `BtnQueryTreeDown` Button — ↓
- [ ] `BtnQueryTreeClear` Button — Effacer les groupes
- [ ] `CmbQueryCollectionProbe` ComboBox — 
- [ ] `CmbQueryQuantifier` ComboBox — 
- [ ] `BtnQueryCollectionAdd` Button — + Collection
- [ ] `CmbQueryInstanceField` ComboBox — 
- [ ] `CmbQueryInstanceOperator` ComboBox — 
- [ ] `TxtQueryInstanceValue` TextBox — 
- [ ] `BtnQueryInstanceAdd` Button — + Critère d’instance
- [ ] `TxtQueryParameterName` TextBox — 
- [ ] `BtnQueryParameterAdd` Button — Paramétrer le critère sélectionné
- [ ] `BtnQueryParameterFreeze` Button — Fixer les valeurs actuelles
- [ ] `DgQueryParameters` DataGrid — 
- [ ] `LblQueryParameterEdit` TextBlock — Sélectionnez un paramètre pour saisir sa valeur.
- [ ] `TxtQueryParameterValue` TextBox — 
- [ ] `CmbQueryParameterChoice` ComboBox — 
- [ ] `BtnQueryParameterScope` Button — OU du tableau de bord
- [ ] `BtnQueryParameterApply` Button — Appliquer la valeur
- [ ] `LblQueryParameterCheck` TextBlock — 
- [ ] `TxtQueryCoherenceHours` TextBox — 
- [ ] `CmbCollectionConcurrency` ComboBox — 
- [ ] `CmbCollectionCache` ComboBox — 
- [ ] `CmbCollectionProfile` ComboBox — 
- [ ] `LblCollectionProfile` TextBlock — 
- [ ] `DgCollectionFreshness` DataGrid — 
- [ ] `CmbCollectionFreshnessValue` ComboBox — 
- [ ] `BtnCollectionFreshnessReset` Button — Revenir aux durées du profil
- [ ] `TxtCollectionWindow` TextBox — 
- [ ] `BtnCollectionWindowApply` Button — Appliquer la fenêtre
- [ ] `LblCollectionWindow` TextBlock — 
- [ ] `ExpQueryCoverage` Expander — Couverture et dates des informations
- [ ] `LblQueryCoverage` TextBlock — Vérifiez la couverture des informations avant lʼaperçu.
- [ ] `DgQueryCoverage` DataGrid — 
- [ ] `DgQueryCoherenceSources` DataGrid — 
- [ ] `LblQueryCoherenceProposal` TextBlock — 
- [ ] `BtnQueryApplyCoherence` Button — Appliquer la fenêtre proposée au brouillon

#### WMI avancé (`TabQueryWmi`)
- [ ] `TxtQueryWmiNamespace` TextBox — root\cimv2
- [ ] `BtnQueryWmiNamespaces` Button — Espaces enfants…
- [ ] `ChkQueryWmiForceRead` CheckBox — Relire sur le poste plutôt que la base
- [ ] `LstQueryWmiNamespaces` ListBox — 
- [ ] `TxtQueryWmiClassFilter` TextBox — 
- [ ] `BtnQueryWmiClasses` Button — Classes de lʼespace…
- [ ] `DgQueryWmiClasses` DataGrid — 
- [ ] `TxtQueryWmiClass` TextBox — Win32_OperatingSystem
- [ ] `BtnQuerySchemaRead` Button — Lire le schéma…
- [ ] `LblQueryWmiClassDescription` TextBlock — 
- [ ] `DgQuerySchema` DataGrid — 
- [ ] `BtnQueryWqlBuild` Button — Préparer le SELECT avec les propriétés cochées
- [ ] `TxtQueryWql` TextBox — SELECT Caption, Version FROM Win32_OperatingSystem
- [ ] `LblQueryWqlPlan` TextBlock — 
- [ ] `TxtQueryWmiLimit` TextBox — 100
- [ ] `BtnQueryWqlRun` Button — Exécuter sur le poste…
- [ ] `BtnQueryWqlRecipe` Button — Préparer une recette locale
- [ ] `LblQueryWmiStatus` TextBlock — Aucune lecture WMI avancée lancée.
- [ ] `BtnQueryWmiRemoteRead` Button — Lire sur le poste…
- [ ] `DgQueryWmiRows` DataGrid — 
- [ ] `CmbQueryAssociationPreset` ComboBox — 
- [ ] `TxtQueryAssociationClass` TextBox — 
- [ ] `TxtQueryAssociationResult` TextBox — 
- [ ] `BtnQueryAssociations` Button — Lire cette relation…

#### 3. Enregistrer (`TabQueryPublish`)
- [ ] `ExpQueryTransfer` Expander — Partager ou importer des recettes
- [ ] `TxtQueryPackName` TextBox — Bibliothèque Domenia
- [ ] `TxtQueryPackVersion` TextBox — 1
- [ ] `BtnQueryPackExport` Button — Exporter ma bibliothèque (JSON)…
- [ ] `BtnQueryScriptExport` Button — Exporter cette requête (PowerShell)…
- [ ] `BtnQueryPackImport` Button — Examiner un pack…
- [ ] `LblQueryImportStatus` TextBlock — L’import affiche les différences avant toute écriture. Les recettes ne lancent jamais de collecte implicitement.
- [ ] `LblQueryImportPack` TextBlock — 
- [ ] `DgQueryImport` DataGrid — 
- [ ] `DgQueryImportChanges` DataGrid — 
- [ ] `BtnQueryImportNew` Button — Choisir les nouvelles
- [ ] `BtnQueryImportApply` Button — Appliquer mes choix…
- [ ] `CmbQueryImportHistory` ComboBox — 
- [ ] `BtnQueryImportRollback` Button — Restaurer avant cet import…
- [ ] `LblQueryPublishSummary` TextBlock — Consultez l’aperçu pour vérifier les postes correspondants et les informations inconnues.
- [ ] `TxtFleetQueryName` TextBox — 
- [ ] `CmbQuerySaveCategory` ComboBox — 
- [ ] `BtnQuerySave` Button — Enregistrer
- [ ] `BtnQueryWidget` Button — Créer une sonde dashboard
- [ ] `BtnQueryDelete` Button — Archiver la requête
- [ ] `LblQueryImpact` TextBlock — 
- [ ] `DgQueryImpact` DataGrid — 
- [ ] `BtnQueryImpactMigrate` Button — Mettre à jour les éléments liés
- [ ] `BtnQueryImpactKeep` Button — Garder lʼancienne version, enregistrer une copie
- [ ] `BtnQueryImpactArchive` Button — Archiver et retirer les widgets
- [ ] `BtnQueryImpactCancel` Button — Annuler
- [ ] `CmbQueryGroupField` ComboBox — 
- [ ] `CmbQueryWidgetDestination` ComboBox — 
- [ ] `CmbQueryWidgetVisual` ComboBox — 
- [ ] `BtnQueryPreviewComputer` Button — Tester sur le poste sélectionné
- [ ] `LblQueryComputerPreview` TextBlock — 
- [ ] `BtnQueryApplySearch` Button — Appliquer aux résultats de Recherche
- [ ] `BtnQueryRevise` Button — Modifier les critères

#### Bibliothèque (`TabQueryLibrary`)
- [ ] `TxtQueryLibrarySearch` TextBox — 
- [ ] `CmbQueryLibraryCategory` ComboBox — 
- [ ] `CmbQueryLibrarySource` ComboBox — 
- [ ] `LblQueryLibraryCount` TextBlock — 
- [ ] `BtnQueryLibraryPrevious` Button — Page précédente
- [ ] `BtnQueryLibraryNext` Button — Page suivante
- [ ] `LblQueryLibraryDescription` TextBlock — Sélectionnez une requête pour consulter son usage.
- [ ] `LblQueryLibraryCollection` TextBlock — 
- [ ] `BtnQueryLibraryUse` Button — Utiliser cette requête
- [ ] `BtnQueryLibraryRestore` Button — Restaurer la requête
- [ ] `DgQueryLibrary` DataGrid — 

#### Informations (`TabQueryCatalog`)
- [ ] `TxtQueryCatalogSearch` TextBox — 
- [ ] `CmbQueryCatalogSource` ComboBox — 
- [ ] `CmbQueryCatalogCategory` ComboBox — 
- [ ] `LblQueryCatalogCount` TextBlock — 
- [ ] `DgQueryCatalog` DataGrid — 
- [ ] `LblQueryCatalogTitle` TextBlock — 
- [ ] `LblQueryCatalogDescription` TextBlock — 
- [ ] `LblQueryCatalogValue` TextBlock — 
- [ ] `LblQueryCatalogCollection` TextBlock — 
- [ ] `LblQueryCatalogAvailability` TextBlock — 
- [ ] `LblQueryCatalogTechnical` TextBlock — 
- [ ] `BtnQueryCatalogUse` Button — Utiliser cette information

### Vue Support
- [ ] `DomeniaSupportView` UserControl — 
- [ ] `LblSupportContext` TextBlock — Ouvre une fiche pour analyser ses données déjà chargées.
- [ ] `BtnSupportClearSession` Button — Vider l'atelier
- [ ] `SupportTabs` TabControl — Étapes de l’Atelier

#### Comprendre (`SupportAnalysisTab`)
- [ ] `BtnSupportAnalyse` Button — Recalculer la synthèse
- [ ] `BtnSupportPin` Button — Epingler la fiche
- [ ] `BtnSupportAccounts` Button — Vérifier les comptes
- [ ] `BtnSupportEngine` Button — État du moteur
- [ ] `LblSupportCoverage` TextBlock — Aucune fiche chargee. Aucun diagnostic invente.
- [ ] `DgSupportFindings` DataGrid — Constats et vérifications
- [ ] `TxtSupportFindingDetail` TextBox — Justification du constat

#### Comparer A / B (`SupportCompareTab`)
- [ ] `CmbSupportFileSlot` ComboBox — 
- [ ] `BtnSupportSaveCapture` Button — Enregistrer la capture
- [ ] `BtnSupportLoadCapture` Button — Charger une capture
- [ ] `BtnSupportCaptureA` Button — Fiche actuelle → A
- [ ] `BtnSupportCaptureB` Button — Capturer la référence B
- [ ] `BtnSupportSwap` Button — Inverser A et B
- [ ] `BtnSupportClearCompare` Button — Effacer les captures
- [ ] `ChkSupportDiffOnly` CheckBox — Afficher seulement les écarts
- [ ] `LblSupportA` TextBlock — A : aucune capture
- [ ] `LblSupportB` TextBlock — B : aucune capture
- [ ] `LblSupportComparison` TextBlock — Capturez A, actualisez ou ouvrez une autre fiche du même type, puis capturez B.
- [ ] `DgSupportDiff` DataGrid — Différences entre A et B
- [ ] `TxtSupportDiffDetail` TextBox — Détail de la différence

#### Incidents expliques (`SupportIncidentsTab`)
- [ ] `TxtSupportIncidentFilter` TextBox — Filtre litteral sur titre, code et zone
- [ ] `BtnSupportClearIncidents` Button — Effacer la liste des incidents
- [ ] `LblSupportIncidents` TextBlock — Avertissements et erreurs de cette session, toutes cibles confondues. Aucun rattachement automatique a la fiche.
- [ ] `DgSupportIncidents` DataGrid — Incidents de la session
- [ ] `TxtSupportIncidentDetail` TextBox — Détail de l’incident

#### Reperes de session (`SupportPinsTab`)
- [ ] `BtnSupportPinCurrent` Button — Épingler cette fiche
- [ ] `BtnSupportOpenPin` Button — Ouvrir la fiche epinglee
- [ ] `BtnSupportRemovePin` Button — Retirer ce repère
- [ ] `DgSupportPins` DataGrid — Fiches épinglées

#### Dossier / ticket (`SupportReportTab`)
- [ ] `TxtSupportTicket` TextBox — 
- [ ] `BtnSupportPreview` Button — Générer le dossier
- [ ] `BtnSupportCopyReport` Button — Copier le dossier
- [ ] `BtnSupportExportHtml` Button — Enregistrer le dossier HTML
- [ ] `ChkSupportIncludeIncident` CheckBox — Ajouter l’incident sélectionné
- [ ] `TxtSupportReport` TextBox — Aperçu du dossier

#### Dossier hors ligne (`SupportOfflineTab`)
- [ ] `CmbSupportOfflineScope` ComboBox — Périmètre du dossier
- [ ] `ChkSupportOfflineObservations` CheckBox — Inclure les observations
- [ ] `ChkSupportOfflineLinks` CheckBox — Inclure les associations
- [ ] `ChkSupportOfflineQueries` CheckBox — Inclure les requêtes enregistrées
- [ ] `BtnSupportOfflineDossier` Button — Préparer le dossier hors ligne
- [ ] `LblSupportOfflineStatus` TextBlock — Aucun dossier préparé dans cette session.

