# RC1.17.21 — complément de qualification du labo personnel

Décision de David du 18 octobre : **« Labo personnel uniquement ; documenter ces limites »**. Ce dossier complète les preuves RC17 à RC21. Il ne clôture ni la recette générale ni la redistribution. Les ZIP livrés restent inchangés ; trois bancs corrigés et les outils de parcours graphique sont ajoutés comme harnais complémentaires, avec leurs empreintes dans `Qualification.json`. Aucun code applicatif modifié.

## Résultats Windows PowerShell 5.1

| Contrôle | Résultat et preuve |
|---|---|
| Protection des identifiants | 30 cas réussis, dont témoins négatifs de concurrence. `client/CredentialGuard.json` |
| Associations et accès | RelationsAlignment 68/68, WiringAcces 63/63. `initial-dc/` |
| Relations WPF | 59/59, `Complete=true`, exit 0. `wiring-final/` ; AD/CIM doublés |
| LAPS | 5/5, avec lecture LDAP réelle du schéma et de l’expiration ; aucun secret lu. `client/LapsQualification.json` |
| Rétention volumineuse | Prévisualisation sur 400 000 observations : 392 000 supprimables, cinq assertions réussies, seuil de prévisualisation inférieur à 20 s vérifié. Aucune purge de 392 000 lignes effectuée. `initial-dc/StorageMaintenance.json` |
| Volume NTFS réellement plein | Dix contrôles réussis sur VHD jetable de 128 Mio : 0 octet libre, erreur Windows 112, refus `StorageInsufficientSpace`, intégrité conservée, rejeu unique après libération. `full-volume/` |
| LDAP du labo | RootDSE et objet du DC relus sur Windows Server 2025, compte administrateur du domaine. `LabLDAP.json`, ajouté à la matrice comme preuve limitée du laboratoire |
| Règles du parcours graphique | 8/8 sous Windows PowerShell 5.1. `GuiJourneyRules.json` |
| Compatibilité | Parseur natif 5.1 et garde de compatibilité réussis. `patched-dc/NativeParser.json` et journaux associés |

Le premier rapport de volume plein reste `Passed=false` car la suppression finale du VHD a rencontré le verrou de sa copie de preuve encore en cours. **Les dix assertions fonctionnelles ont réussi.** Le volume était détaché ; la suppression ultérieure est confirmée par `CleanupRecovery.json`, lié au SHA-256 du rapport original. Ce rapport n’a pas été réécrit en succès.

## Corrections des bancs

- CredentialGuard : la barrière n’expire plus dans les workers pendant le démarrage des autres runspaces. Le parent attend un compte à rebours borné et libère toujours la barrière, même sur échec. Les assertions et les témoins sans protection restent conservés.
- LAPS : une variable locale écrasait les faits live dans la portée du script ; le rapport les conserve maintenant.
- WiringRelations : imports Guard/Store manquants, contexte AD requis et callback avant publication remis en phase avec le circuit réel. Le faux résultat représente désormais une relecture SQLite datée ; un cas supplémentaire vérifie qu’un résultat distant non enregistré est rejeté. Les attentes de refus de compte et de conservation de l’historique n’ont pas été assouplies. Compteur fermé actualisé à 59 cas.

- Parcours GUI : WPF expose le `Uid` des boutons de navigation (`WsSearch`, `TabDashboard`) comme AutomationId, avant leur `x:Name`. Les deux définitions identiques du parcours utilisent maintenant ces identifiants ; reprise détaillée dans le complément RC22.

Les rapports initiaux (course, huit échecs de dépendances/contexte, puis ancien compteur de cas) restent dans `initial-dc/` et `patched-dc/`. Le résultat final est dans `wiring-final/`.

## Limites conservées, aucun succès inventé

- Deux écrans avec DPI différents, changement à chaud, écoute Narrateur/NVDA et relevé humain complet : non exécutés, limites acceptées pour le labo personnel.
- Le schéma du labo ne contient ni LAPS historique ni Windows LAPS ; le module est présent. Secrets chiffrés, déchiffrement et comptes délégués ne sont pas qualifiés. Les quatre scénarios manuels restent `NotExecuted`.
- La campagne LoadStability 20 000 postes / cinq cycles a été arrêtée après deux lectures à froid correctes : première vue du parc en **128,426 s puis 142,335 s** sur la VM à un cœur / 4 Gio. La recherche renvoie les 100 résultats attendus et la vue les 20 000 machines. Aucune conclusion positive sur la réactivité ou l’endurance ; il reste une mesure et une optimisation à conduire si ce volume devient une cible. `client/LoadStabilityObservation.json`, sortie -1 et absence de rapport complet conservées.
- Premier parcours natif Preview : 11 étapes réussies, trois sélecteurs introuvables et quatorze étapes non exécutées ; une capture valide. Rapport conservé dans `gui-initial/`. Les sélecteurs puis le modèle d’onglets sont corrigés ; défilement natif 7/7 et démarrage du nouveau pack réussis. Le passage complet RC22 attend une session après arrêt Windows pour expiration de l’évaluation ; [détails RC22](../rc22-ui-automation/README.md). Aucun relevé humain fourni.
- Domaine cible, autres OS, transports et profils de droits : non qualifiés par cette lecture LDAP limitée. La matrice comporte une cellule labo, aucune cellule cible.
- Coordination amont (134), certificat (141) et droits de redistribution (146) restent externes. Le pack personnel reste autonome avec tous les composants embarqués.

## Provenance et nettoyage

VM temporaire `DOMENIA-RC21-FINAL`, clone complet indépendant de `FILPRO-W11B-TEST` ; la VM source est restée arrêtée ; Windows conserve le nom invité `FILPRO-W11B`. L’accès au domaine a été rétabli en raccordant le clone au réseau privé `CNAMTS-LAB`. Le contrôleur `CNAMTS-DC01` est conservé. Aucun secret ni fichier de mot de passe lu ; aucune écriture AD demandée par les tests. `OriginalMachineAccount.json` confirme que le mot de passe du compte machine reste antérieur au clonage.

Les preuves doivent être committées, poussées et vérifiées avant suppression de la VM temporaire. Le reçu de nettoyage final sera ajouté après cette vérification. Les autres VM de projets sont conservées.

`SHA256SUMS` lie les fichiers de ce dossier. Contrôles de sources dans `SourceChecks.json`. Les commandes de matrice s’exécutent depuis `dev/`, pour relire le rapport versionné au chemin relatif indiqué.
