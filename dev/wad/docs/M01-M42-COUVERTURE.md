# Domenia 1.0 RC1 : suivi honnête du plan M01 à M42

Les 42 points ne sont pas tous clôturés. Une correction intégrée en source n’est pas une validation Windows. Cette matrice évite de confondre un compteur de tests de structure avec la réussite d’une opération AD.

Statuts : **intégré candidat** = raccordé, recette requise ; **partiel** = travaux restants explicités ; **exécution externe requise** = Windows indispensable.

| ID | Modification | État |
|---|---|---|
| M01 | Retirer les mots de passe des lignes de commande | integre candidat |
| M02 | Distinguer sonde et intervention distante | integre candidat |
| M03 | Unifier les erreurs d’accès | partiel |
| M04 | Gérer les identités par vraie ressource | partiel |
| M05 | Rendre LAPS et BitLocker explicables | partiel |
| M06 | Durcir révélation, copie et logs | integre candidat |
| M07 | Définir la protection du cache | partiel |
| M08 | Conserver les mutations en vol après incident | partiel |
| M09 | Planifier puis vérifier chaque écriture | partiel |
| M10 | Comparer les attributs selon leur type | partiel |
| M11 | Corriger grands groupes et appartenances | partiel |
| M12 | Corriger les états utilisateurs | integre candidat |
| M13 | Sauvegarder les liens par modification réelle | partiel |
| M14 | Installer de vraies migrations SQLite | integre candidat |
| M15 | Supprimer les attentes bloquantes WPF | partiel |
| M16 | Sortir toutes les écritures de cache du rendu | partiel |
| M17 | Prioriser ce que l’opérateur voit | integre candidat |
| M18 | Borner et adapter l’ordonnancement | partiel |
| M19 | Unifier les clés et preuves de fraîcheur | partiel |
| M20 | Réconcilier le périmètre, pas seulement les lignes connues | integre candidat |
| M21 | Mesurer la réactivité réellement | partiel |
| M22 | Protéger les modifications de formulaire | partiel |
| M23 | Afficher la provenance de chaque constat | integre candidat |
| M24 | Ajouter une vue Sessions à la demande | integre candidat |
| M25 | Assistant « Pourquoi cette action est indisponible ? » | partiel |
| M26 | Favoris et recherches réutilisables | partiel |
| M27 | Renforcer l’Atelier déjà présent | integre candidat |
| M28 | Finaliser les comportements du GUI | partiel |
| M29 | Renommer l’identité du produit en Domenia | integre candidat |
| M30 | Préserver les installations ADCC existantes | integre candidat |
| M31 | Livrer une production minimale | integre candidat |
| M32 | Construire DEV et PROD depuis la même source | integre candidat |
| M33 | Coordonner lancement, instances et mise à jour | integre candidat |
| M34 | Établir une politique de confiance du paquet | partiel |
| M35 | Découper progressivement le cœur | partiel |
| M36 | Exécuter de vrais tests Windows | execution externe requise |
| M37 | Fournir un mode DEMO isolé et complet | partiel |
| M38 | Libérer et éprouver les ressources natives | partiel |
| M39 | Couvrir les pannes qui comptent | partiel |
| M40 | Tester installation et compatibilité des données | execution externe requise |
| M41 | Exporter un dossier support maîtrisé | partiel |
| M42 | Relier Pesto / FilPro sans mélanger leurs pouvoirs | partiel |

## M01 · Retirer les mots de passe des lignes de commande

**Intégré :** PsExec refuse les credentials explicites avant lancement ; Planificateur distant utilise COM, sans /p ni /rp. Aucun secret ajouté aux arguments de processus.

**Limite / reste :** Tester les transports sur Windows avec marqueurs secrets factices. Les API ont toujours besoin des identifiants en mémoire.

Sources : `wad/Domenia-Core.ps1`

## M02 · Distinguer sonde et intervention distante

**Intégré :** Consentement temporaire de cinq minutes lié à la cible et à la session avant service/tâche/script ; dossier privé sous le vrai WindowsDirectory, ACL et limites de sortie.

**Limite / reste :** Une autorisation vaut pour la cible et la fenêtre de temps, pas un droit supplémentaire. Vérifier ACL, résidus et annulation sur VM.

Sources : `wad/Domenia-Core.ps1`, `wad/modules/Domenia-Guard.UI.ps1`

## M03 · Unifier les erreurs d’accès

**Intégré :** Contrat Kind/Code/NativeCode/Phase/Provider/Target/Uncertain ajouté aux workers et au parcours de récupération.

**Limite / reste :** Certains anciens helpers retournent encore une chaîne ; le repli textuel reste nécessaire. Toutes les erreurs historiques ne conservent pas encore leur code natif.

Sources : `wad/modules/Domenia-Guard.Model.ps1`, `wad/Domenia-Core.ps1`

## M04 · Gérer les identités par vraie ressource

**Intégré :** Scopes indépendants LAPS/BitLocker/AD ; compte local ciblé validé sur le poste via CIM/DCOM ; expiration de trente minutes des comptes alternatifs.

**Limite / reste :** Expiration absolue, pas délai glissant d’inactivité. Les comptes Remote/Secrets permanents du panneau gardent leur durée de session ; pas de compte à usage unique générique.

Sources : `wad/modules/Domenia-Access.UI.ps1`, `wad/modules/Domenia-Sessions.UI.ps1`

## M05 · Rendre LAPS et BitLocker explicables

**Intégré :** Blocages et relances de lecture séparés ; motifs module absent/refus/indisponibilité mieux classés, compte explicite transmis aux cmdlets LAPS.

**Limite / reste :** La séparation exacte lecture/déchiffrement dépend des informations exposées par le fournisseur. Pas de verdict détaillé inventé si le retour reste générique.

Sources : `wad/modules/Domenia-Access.UI.ps1`, `wad/modules/Domenia-Guard.Model.ps1`

## M06 · Durcir révélation, copie et logs

**Intégré :** Copie de secret par API native avec formats d’exclusion historique/cloud ; copie multiple confirmée ; masquage /p et /rp ajouté.

**Limite / reste :** Les copies externes et gestionnaires tiers ne peuvent pas être purgés ni garantis. La journalisation historique n’est pas intégralement remplacée par une liste blanche.

Sources : `wad/modules/Domenia-Clipboard.Native.cs`, `wad/Domenia-Core.ps1`

## M07 · Définir la protection du cache

**Intégré :** Mode Compatible conserve les données existantes ; nouvelles données locales utilisateur ; Portable/UserLocal explicites, refus UNC/lecteur réseau/redirection.

**Limite / reste :** Les ACL d’un ancien cache portable ne sont pas réécrites automatiquement. Pas de chiffrement général ni de purge guidée universelle.

Sources : `wad/Domenia-Core.ps1`

## M08 · Conserver les mutations en vol après incident

**Intégré :** Reçus durables avant les écritures AD du canal IsWrite, stade Sent avant mutation, Unknown après résultat incertain, blocage après relance tant que non résolu.

**Limite / reste :** Les mutations distantes GPUpdate/redémarrage/programme n’utilisent pas toutes ce reçu. Vérification automatique de reprise limitée aux écritures d’attributs ; les autres demandent une revue externe explicite.

Sources : `wad/modules/Domenia-Receipts.Worker.ps1`, `wad/modules/Domenia-Guard.UI.ps1`

## M09 · Planifier puis vérifier chaque écriture

**Intégré :** Préconditions et postconditions existantes conservées ; cible, GUID, serveur et intention consignés pour les écritures AD ; aucun rejeu automatique.

**Limite / reste :** Pas d’assertion LDAP atomique généralisée. La fenêtre de concurrence entre relecture et mutation demeure.

Sources : `wad/Domenia-Core.ps1`, `wad/modules/Domenia-Receipts.Worker.ps1`

## M10 · Comparer les attributs selon leur type

**Intégré :** Comparaison ordinale des champs texte, corrections de casse respectées, blancs distincts d’effacement et validation syntaxique du nom d’attribut.

**Limite / reste :** Pas de moteur de comparaison complet fondé sur le schéma AD pour dates et tous les attributs multivalués.

Sources : `wad/Domenia-Core.ps1`

## M11 · Corriger grands groupes et appartenances

**Intégré :** Test d’appartenance directe par filtre LDAP serveur ; lecture member/memberOf par plages et libération ; liste de groupe plafonnée à 2000 à l’écran avec avertissement.

**Limite / reste :** Pas de nouveau graphe exhaustif d’appartenances imbriquées/principales avec gestion complète des cycles. Une limite ou restriction de visibilité reste à interpréter avec le compte utilisé.

Sources : `wad/Domenia-Core.ps1`

## M12 · Corriger les états utilisateurs

**Intégré :** Etat calculé msDS-User-Account-Control-Computed utilisé pour le verrouillage ; lockoutTime non nul seul ne vaut plus verrouillage courant ; UAC manquant inconnu.

**Limite / reste :** Recette AD avec verrouillage expiré, compte désactivé et politique effective encore requise.

Sources : `wad/Domenia-Core.ps1`

## M13 · Sauvegarder les liens par modification réelle

**Intégré :** Enregistrement ciblé des différences de liens, comparaison d’empreinte sous transaction, conflits conservés et absence de DELETE global de la table.

**Limite / reste :** Lot manuel limité à 64 changements ; historique des suppressions et rétention générale non finalisés. Les observations automatiques gardent leur voie ciblée existante.

Sources : `wad/modules/Domenia-Storage.UI.ps1`, `wad/modules/Domenia-Storage.Worker.ps1`

## M14 · Installer de vraies migrations SQLite

**Intégré :** Schéma legacy 11 préservé, version Domenia 1 ajoutée après sauvegarde cohérente et transaction ; rejet des versions incompatibles/futures.

**Limite / reste :** Migration prise en charge depuis le schéma de la base fournie, pas depuis des versions arbitraires. Migration interrompue à valider sur Windows.

Sources : `wad/Domenia-Core.ps1`

## M15 · Supprimer les attentes bloquantes WPF

**Intégré :** Validation et activation des comptes remplacées par timer/callback ; aucune attente WaitOne du chemin de test de compte ; annulation et résultats tardifs protégés.

**Limite / reste :** Ce n’est pas la suppression de toutes les attentes historiques : certaines fonctions de maintenance/stockage de démarrage et le hachage d’un outil externe restent synchrones.

Sources : `wad/modules/Domenia-Accounts.Async.ps1`

## M16 · Sortir toutes les écritures de cache du rendu

**Intégré :** File bornée d’index, liens et métadonnées en arrière-plan ; admission coordonnée avec LiveCache/IndexBuild, transactions, trois échecs puis reprise manuelle.

**Limite / reste :** Ce n’est pas un écrivain unique pour chaque accès historique de l’application ; initialisation, migration et certaines lectures restent synchrones.

Sources : `wad/modules/Domenia-Storage.UI.ps1`, `wad/modules/Domenia-Storage.Worker.ps1`

## M17 · Prioriser ce que l’opérateur voit

**Intégré :** Chargement progressif conservé, priorité à la sélection et aux lignes réalisées par la grille ; modifications par cellules et lots.

**Limite / reste :** Lignes réalisées ne signifie pas exactement pixels actuellement visibles. Aucun gain mesuré sur un vrai parc n’est annoncé.

Sources : `wad/modules/Domenia-Live.UI.ps1`

## M18 · Borner et adapter l’ordonnancement

**Intégré :** Bornes de files et concurrence, temporisation après erreur de réconciliation, arrêt des retries stockage après trois échecs, anciens retours exclus.

**Limite / reste :** Pas de budgets adaptatifs complets distincts pour chaque contrôleur/protocole. Annulation native toujours coopérative.

Sources : `wad/modules/Domenia-Reconcile.UI.ps1`, `wad/modules/Domenia-Storage.UI.ps1`

## M19 · Unifier les clés et preuves de fraîcheur

**Intégré :** Suivi récent lié au DC et invocationID ; ancien court-circuit USN seul supprimé ; GUID/recréation et contexte conservés dans les modules récents.

**Limite / reste :** L’index historique n’est pas entièrement migré vers une clé composite lecteur/DC/invocationID. La table de provenance prépare cette transition, elle n’est pas présentée comme entièrement alimentée.

Sources : `wad/Domenia-Core.ps1`, `wad/modules/Domenia-Continuity.Model.ps1`

## M20 · Réconcilier le périmètre, pas seulement les lignes connues

**Intégré :** Réconciliation périodique du dernier périmètre explicite, bornée à 500, en arrière-plan et désactivable ; nouvelles lignes intégrées, absences signalées sans suppression.

**Limite / reste :** Pas de synchronisation exhaustive du domaine. Quand la limite est atteinte, une nouvelle recherche reste nécessaire pour une vue complète du périmètre.

Sources : `wad/modules/Domenia-Reconcile.UI.ps1`

## M21 · Mesurer la réactivité réellement

**Intégré :** Indicateurs locaux du retard Dispatcher p50/p95 et des files, délais du premier affichage hérités conservés.

**Limite / reste :** Pas de campagne de performance Windows ni de percentiles détaillés de chaque transport.

Sources : `wad/modules/Domenia-Guard.UI.ps1`

## M22 · Protéger les modifications de formulaire

**Intégré :** Brouillon textuel et indicateurs séparés ; une relecture fraîche ne remplace plus les saisies ; confirmation avant changement/rechargement et comparaison lisible.

**Limite / reste :** La résolution champ par champ n’est pas automatisée ; réapplication volontaire après comparaison. Les mots de passe ne sont pas mémorisés dans le brouillon.

Sources : `wad/modules/Domenia-Guard.UI.ps1`, `wad/Domenia-Core.ps1`

## M23 · Afficher la provenance de chaque constat

**Intégré :** Sources et dates console/cache/tentative conservées ; sessions WTS présentées dans une vue distincte ; capture importée toujours historique.

**Limite / reste :** Les colonnes de confiance historiques ne sont pas une probabilité de fiabilité mesurée.

Sources : `wad/modules/Domenia-Sessions.UI.ps1`, `wad/modules/Domenia-Dossier.Model.ps1`

## M24 · Ajouter une vue Sessions à la demande

**Intégré :** Vue Sessions WTS à la demande, utilisateur/domaine/protocole/état, API mémoire libérée, compte cible possible ; aucune fermeture de session.

**Limite / reste :** Permissions WTS, impersonation et réactivité à éprouver sous Windows.

Sources : `wad/modules/Domenia-Sessions.Native.cs`, `wad/modules/Domenia-Sessions.UI.ps1`

## M25 · Assistant « Pourquoi cette action est indisponible ? »

**Intégré :** Vue Fiabilité : explication des protections actives, refus connus, compte et prérequis ; routes sûres vers reçus et changement de compte.

**Limite / reste :** Pas d’inventaire en temps réel de tous les droits effectifs de chaque bouton. Certains anciens motifs sont textuels.

Sources : `wad/modules/Domenia-Guard.UI.ps1`

## M26 · Favoris et recherches réutilisables

**Intégré :** 50 recherches/périmètres favoris, vérification du domaine, sauvegarde des filtres et lancement explicite ; positions de colonnes/OU conservées.

**Limite / reste :** Pas de pagination AD complète au-delà du plafond ; pas de réinitialisation universelle de toutes les préférences de présentation.

Sources : `wad/modules/Domenia-Guard.UI.ps1`, `wad/modules/Domenia-Guard.Model.ps1`

## M27 · Renforcer l’Atelier déjà présent

**Intégré :** Enregistrement et chargement explicites des captures A/B filtrées, source historique et dates vérifiées, référence ticket, export dossier asynchrone.

**Limite / reste :** Pas d’application automatique des différences de groupes ; dossier limité à 1 Mo ; ce n’est pas un journal d’audit infalsifiable.

Sources : `wad/modules/Domenia-Dossier.Model.ps1`, `wad/modules/Domenia-Dossier.UI.ps1`

## M28 · Finaliser les comportements du GUI

**Intégré :** Navigation/panneaux repliables/aides conservés ; nouveaux contrôles aidés ; dialogues génériques adaptés au thème et à la zone de travail.

**Limite / reste :** Recette 100/125/150/200 %, clavier et rendu réel non exécutée. Aucun audit complet d’accessibilité revendiqué.

Sources : `wad/Domenia-Core.ps1`, `wad/modules/Domenia-UX.help.json`

## M29 · Renommer l’identité du produit en Domenia

**Intégré :** Domenia.exe natif recompilé, ressources PE et icône D, titres, fonctions, modules, scripts, logs et outillage renommés.

**Limite / reste :** ADCC reste volontairement dans les chemins de migration et documents historiques. Les composants Microsoft ne sont pas renommés.

Sources : `wad/Domenia-Core.ps1`

## M30 · Préserver les installations ADCC existantes

**Intégré :** Installateur reprend les configurations ADCC seulement si celles Domenia manquent ; lecture de secours des préférences, adoption contrôlée de l’ancienne base et sauvegardes.

**Limite / reste :** Ne pas lancer l’ancien ADCC après migration ; la première migration exige fermeture manuelle de toutes les anciennes instances. L’ancien lanceur ignore le nouveau protocole de verrou.

Sources : `wad/Domenia-Core.ps1`

## M31 · Livrer une production minimale

**Intégré :** Racine prod strictement Domenia.exe et wad ; déblocage dans wad/Support ; runtime indépendant de DEV, tests, aperçus et documentation.

**Limite / reste :** Ce pack PROD est une édition de distribution d’une RC, pas une certification production.

Sources : `wad/Domenia-Start.ps1`, `wad/Support/DEBLOQUER_TOUT.cmd`

## M32 · Construire DEV et PROD depuis la même source

**Intégré :** Construction déterministe, inventaire runtime fermé, manifestes, contrôle byte-à-byte entre DEV/PROD, absence de base ou log utilisateur.

**Limite / reste :** La détermination de tous les outils dépend du même environnement de compilation ; binaires tiers repris à l’identique.

Sources : `wad/Domenia-Start.ps1`

## M33 · Coordonner lancement, instances et mise à jour

**Intégré :** Verrou commun détenu par le lanceur et le bootstrap ; installateur exclusif, marqueur d’installation interrompue, sauvegarde/restauration avec empreintes.

**Limite / reste :** Le tout premier passage depuis le lanceur ADCC ancien ne peut pas lui imposer rétroactivement le verrou. Fermer toutes les anciennes instances.

Sources : `wad/Domenia-Start.ps1`

## M34 · Établir une politique de confiance du paquet

**Intégré :** Vérification de tous les hashes runtime à chaque lancement, chemins/reparse contrôlés ; outil de signature organisationnelle fourni.

**Limite / reste :** Pas de certificat fourni ni de signature réalisée. Un manifeste livré avec le code n’en garantit pas à lui seul l’authenticité.

Sources : `wad/Domenia-Start.ps1`

## M35 · Découper progressivement le cœur

**Intégré :** Nouveaux composants séparés Accounts.Async, Storage, Receipts, Guard, Sessions, Reconcile, Dossier ; contrats d’opérations explicites.

**Limite / reste :** Le cœur historique reste volumineux ; son extraction complète par domaines n’est pas terminée.

Sources : `wad/modules/Domenia-Accounts.Async.ps1`, `wad/modules/Domenia-Storage.Worker.ps1`, `wad/modules/Domenia-Guard.UI.ps1`

## M36 · Exécuter de vrais tests Windows

**Intégré :** Suite native Windows PowerShell/WPF et workflow CI fournis ; rapport explicite du système et des tests exécutés.

**Limite / reste :** Non exécutés sur cet hôte Linux. Il faut un Windows de recette pour fermer ce point.

Sources : `wad/tests/Test-DomeniaCandidate.ps1`

## M37 · Fournir un mode DEMO isolé et complet

**Intégré :** Aperçus réels XAML principal/login/progressif adaptés au renommage, données fictives, sans accès AD ni cache de production.

**Limite / reste :** Les nouveaux comportements de reçus/transport ne disposent pas tous de scénarios interactifs de démonstration ; certains anciens tests restent historiques.

Sources : `wad/maintenance/Preview-DomeniaUi.ps1`, `wad/maintenance/Preview-DomeniaLogin.ps1`

## M38 · Libérer et éprouver les ressources natives

**Intégré :** Dispose/finally ajoutés sur les helpers AD critiques, WTS, CIM de validation, COM et écrivains ; timers nouveaux arrêtés à la fermeture.

**Limite / reste :** Pas de mesure longue durée handles/mémoire Windows. Tous les helpers historiques ne sont pas encore uniformisés.

Sources : `wad/Domenia-Core.ps1`, `wad/modules/Domenia-Sessions.Native.cs`

## M39 · Couvrir les pannes qui comptent

**Intégré :** Tests de modèles/contrats et scénarios de panne documentés ; assertions Python SQLite réelles et refus de worker altéré natif fourni.

**Limite / reste :** Coupures en vol, DNS lent, UI/AD/CIM, défauts ACL, arrêt des processus et disque plein non testés sur Windows.

Sources : `wad/tests/Test-DomeniaCandidate.ps1`

## M40 · Tester installation et compatibilité des données

**Intégré :** Contrôles réels CRC, manifestes, build reproductible et schéma SQLite ; recette migration/installation/rollback fournie.

**Limite / reste :** La campagne d’installation Windows et de restauration de données reste à exécuter.

Sources : `wad/tests/Test-DomeniaCandidate.ps1`

## M41 · Exporter un dossier support maîtrisé

**Intégré :** Export local d’un dossier technique minimal : compteurs/version/état, aperçu avant sauvegarde, sans cible, compte ni logs bruts.

**Limite / reste :** Pas de pseudonymisation générale des anciens rapports ni d’agrégation automatique de toutes les traces.

Sources : `wad/modules/Domenia-Dossier.UI.ps1`

## M42 · Relier Pesto / FilPro sans mélanger leurs pouvoirs

**Intégré :** Raccourcis Pesto et FilPro avec chemin EXE absolu, empreinte SHA-256, absence de redirection et consentement ; aucun argument ou credential envoyé.

**Limite / reste :** Pas de transfert automatique de contexte : leurs contrats CLI exacts ne sont pas supposés.

Sources : `wad/modules/Domenia-Guard.UI.ps1`
