# Domenia 1.0 — bilan des améliorations

**État au 13 octobre 2026, après publication sur `master` et vérification des archives GitHub au commit `abc400f`.** Ce bilan reprend les titres des [30 points initiaux et 12 demandes complémentaires](../2026-10-12/completion-ledger-20261012.json), puis les [11 points de la passe actuelle](completion-ledger.json).

**Réalisé** signifie que le code ou le livrable existe. Cela ne signifie pas que le domaine réel, toutes les machines ou le parcours humain sont qualifiés. Les contrôles indiqués pour les points initiaux sont ceux référencés dans leur registre ; la campagne R6 apporte une validation Windows hors ligne distincte, sur données synthétiques.

## Situation actuelle

| Ensemble | Mise en œuvre | Validation ou livraison |
|---|---|---|
| 30 points initiaux | 30 réalisés dans le registre | Preuves locales et Windows conservées avec leurs limites de plateforme et leurs archives respectives. |
| 12 demandes complémentaires | 12 réalisées dans le registre | La publication déjà attestée concerne la livraison précédente ; elle ne vaut pas publication des changements actuels. |
| B01 à B07 | Réalisés | Validés hors ligne par la campagne R6 ; domaine réel et parcours humain non qualifiés. |
| B08 | Campagne exécutée | R6 : **63 étapes réussies sur 63**, sans dépassement de délai ni modification du runtime. R5 reste une campagne distincte en échec à 62/63, sur les mêmes ZIP. |
| B09 | Quatre guides Word/PDF terminés | **96 pages relues** : 28 technicien et 68 administrateur ; 33 figures par guide. |
| B10 | Packs classiques RC1.17.3 publiés | Commit `abc400f` poussé sur `master` ; les deux archives téléchargées depuis GitHub correspondent exactement aux SHA-256 testés. |
| B11 | Parcours humain prévu | **Bloqué : 0 scénario réussi sur 9**, Mac verrouillé. |

## Les 30 points initiaux

| N° | Point | Mise en œuvre | Contrôles disponibles et limites à conserver |
|---|---|---|---|
| 1 | Lectures partielles et checkpoints fiables | Réalisé | Tests SQLite et résilience moteur. Une lecture partielle ne valide ni absence ni checkpoint ; reprise au dernier repère validé, sans curseur LDAP durable au milieu d’une page. |
| 2 | Fraîcheur et couverture des données | Réalisé | Tests de persistance, widgets et charge synthétique. Les dates de copie, la couverture OU et les tentatives sont distinctes ; elles ne garantissent pas une réplication AD instantanée. |
| 3 | Objets déplacés, supprimés et désactivés | Réalisé | Réconciliation GUID/DN et périmètres vérifiés avec SQLite. Un recensement partiel ou invalide ne retire aucun absent ; les désactivés restent recensés. Aucun objet n’est supprimé dans AD. |
| 4 | SQLite atomique, lots isolés et arrêt/reprise | Réalisé | Tests de transactions, lots isolés, annulation et empreinte du spool. Reprise depuis le dernier checkpoint complet. |
| 5 | Sauvegarde vérifiée, restauration et corruption | Réalisé | Copie SQLite vérifiée et réouverte ; procédure de restauration manuelle documentée. Pas d’assistant graphique de restauration ni de sauvegarde périodique automatique. Le premier essai strictement en lecture seule de la copie WAL sur Mac a échoué et reste documenté. |
| 6 | Requêtes AD bornées, collecte groupée, inconnu distinct du négatif | Réalisé | Tests du moteur, des règles et de la charge synthétique. Concurrence bornée de 1 à 8 postes ; les latences, droits et fournisseurs AD/WMI réels restent à qualifier. |
| 7 | Protection des opérations critiques | Réalisé | Règles de cible, confirmation, verrouillage et reçu testées. Une issue incertaine n’entraîne pas de renvoi automatique ; les permissions et effets AD réels ne sont pas validés par ces fixtures. |
| 8 | Clés de cache, TTL et invalidations | Réalisé | Tests de cache, identité et résilience. Péremption par usage et invalidation du contexte ; mémoire, disque et rétention restent bornés. |
| 9 | Métriques du cache et purge sûre | Réalisé | Règles de purge et moteur testés. Catégories et confirmation explicites ; purger le cache ne supprime pas les associations manuelles, réglages ou journaux. |
| 10 | Réduction des copies et relectures répétées | Réalisé | Tests du code natif, du moteur et des données synthétiques. Décodage différé et accès par identité ; aucune capacité infinie ni plafond universel de RAM promis. |
| 11 | Lots SQLite, index et agrégats | Réalisé | SQLite local et charge synthétique vérifiés. Écriture par lots et agrégats ; les mesures ne prédisent pas les performances d’un autre disque ou d’un stockage réseau. |
| 12 | Workers, réactivité UI, heartbeat et annulation | Réalisé | Tests d’annulation, générations et rappels obsolètes ; contrôles WPF natifs sur données fictives. La fluidité avec un réseau et un annuaire réels reste distincte. |
| 13 | Phases de collecte, progression, OU, quotas et erreurs | Réalisé | Tests de progression, actions et persistance. Phases de lecture, recensement, validation et écriture séparées ; aucun total inventé avant sa disponibilité. |
| 14 | Attributs AD minimaux et lectures coûteuses ciblées | Réalisé | Tests du recensement et des règles. GUID/DN seuls pour le recensement ; les 78 sondes ne sont pas toutes lancées à chaque mise à jour. |
| 15 | Dashboard autonome et consultation détaillée | Réalisé | Tests de requêtes, widgets et charge. Consultation locale détaillée ; toute action AD exige une identité actuelle et les droits nécessaires. |
| 16 | Comptages cohérents avec portée, source et date | Réalisé | Tests des populations et requêtes. Recensé, actif et joignable restent distincts ; le nombre décrit les données visibles au compte et à leur date. |
| 17 | Sélecteurs OU indépendants et pratiques | Réalisé | Tests des périmètres et actions ; arbre et recherche ajoutés en A08. Recherche, Parc/Atelier et Base conservent des portées indépendantes à vérifier avant comparaison. |
| 18 | États vide, incomplet, ancien ou inconnu explicites | Réalisé | Tests de persistance et des règles de requête. Une mesure manquante ne devient pas zéro ; une base inaccessible n’est pas annoncée vide. |
| 19 | Correspondance exacte entre tuile et objets | Réalisé | Tests de segments, GUID, déduplication et DN échappés. Les courbes quotidiennes restituent des agrégats, sans inventer les identités des anciens postes. |
| 20 | Libellés français homogènes | Réalisé | Revue des sources et captures WPF. Les messages propres aux fournisseurs peuvent dépendre des erreurs réellement rencontrées. |
| 21 | Résultats compacts et détails repliables | Réalisé | Pagination, clips et tableaux contrôlés avec WPF ; détails repliables et surfaces adaptatives. Les dernières corrections des petites fenêtres relèvent aussi de B07. |
| 22 | Tri typé global des dates et tailles | Réalisé | Tests SQLite et requêtes : tri avant pagination, dates chronologiques, inconnus et ordre stable. Aucun accès AD réel nécessaire à ces contrôles. |
| 23 | Virtualisation, colonnes et DPI | Réalisé | Recyclage, pages de 200 lignes et géométrie WPF contrôlés. Le multi-écran et les changements de DPI à chaud restent à qualifier ; le lanceur ne promet pas PerMonitorV2. |
| 24 | Contraste, clavier et accessibilité | Réalisé | Règles, focus et événements clavier WPF testés. Aucune certification WCAG, lecteur d’écran ou qualification exhaustive du contraste élevé Windows revendiquée. |
| 25 | Cartes, graphiques, confirmations et erreurs utiles | Réalisé | Widgets, dispositions et événements WPF contrôlés. Le glisser-déposer simulé par événements ne remplace pas la manipulation humaine d’un bureau interactif. |
| 26 | Exports français exploitables | Réalisé | Tests et revue des exports CSV, en-têtes et protection des cellules. Dans l’Atelier, « cette page » désigne bien la page affichée, pas tous les résultats. |
| 27 | Tests et prévention des régressions | Réalisé | Suites locales et Windows conservées avec leur portée. Les échecs COM/SID du banc Mac ne sont pas transformés en succès ; la campagne exhaustive actuelle est suivie en B08. |
| 28 | Mesures de performances et parc de 5 000 postes ou plus | Réalisé | Scénarios synthétiques locaux jusqu’à 10 000 objets ; campagne Windows avec 5 000 postes synthétiques et 78 sondes. Aucun débit AD/CIM réel ni cache infini déduit de ces mesures. |
| 29 | Réduction de duplication et retrait de code abandonné | Réalisé | Empreintes des bibliothèques communes, packaging et revue des sources. Nettoyage ciblé ; le Core existant subsiste, sans prétendre à une refonte exhaustive. |
| 30 | Documentation DOCX/PDF V1.0 | Réalisé | Guides de la passe actuelle relus : 96 pages, quatre fichiers finaux, captures et empreintes liées. Voir B09 ; les illustrations emploient des données fictives. |

Les identifiants de tests, fichiers sources, résultats et limites détaillées de chaque point sont conservés dans le [registre initial](../2026-10-12/completion-ledger-20261012.json). Les résultats plus anciens ne sont ni réécrits ni attribués au nouveau paquet.

## Les 12 demandes complémentaires

| ID | Demande | Mise en œuvre | Contrôles disponibles et limites à conserver |
|---|---|---|---|
| A01 | Moteur Query commun et noyau natif | Réalisé | Bibliothèque commune épinglée et tests Query/natifs. Le code compilé ciblé est en C#/.NET Framework 4.7.2 ; aucune réécriture en assembleur ou C++ livrée. |
| A02 | 78 sondes et 29 widgets Parc | Réalisé | Catalogue et agrégats vérifiés sur données synthétiques. Une sonde disponible dans le catalogue peut rester indisponible sur une machine selon l’OS, les droits ou les services. |
| A03 | Atelier de requêtes, bibliothèque, filtres et pagination 200 | Réalisé | Requêtes, tri et pagination testés sur les résultats complets. L’export de page demeure explicitement limité à cette page. |
| A04 | Deux packs classiques DEV et PROD et reconstruction autonome | Réalisé | Tests du packager et de la fabrique Windows référencés. PROD contient `Domenia.exe` et un dossier ordinaire `wad` ; DEV reste éditable. Publication de la passe actuelle suivie en B10. |
| A05 | Contrôles rapides enVM Windows | Réalisé | Contrôles Windows PowerShell 5.1/WPF sur données fictives. Le statut formel de qualification du build ne devient pas publiable à partir de ces seules preuves. |
| A06 | Publication finale master et nettoyage GitHub | Réalisé pour la livraison déjà attestée | Reçu de publication et suppression contrôlée de 13 branches fusionnées conservés. Cette preuve ne vaut pas publication des changements actuels ; voir B10. |
| A07 | Fenêtre de connexion au-dessus des autres fenêtres | Réalisé | Vraies fenêtres WPF et cycle de vie testés en session 0. Comportement Alt-Tab entre applications d’un bureau utilisateur non qualifié. |
| A08 | Navigation OU en arbre et recherche contextualisée | Réalisé | Tests Windows avec réponses fictives : chargement progressif, tri et gardes de contexte. Coût LDAP et droits du domaine réel non qualifiés. |
| A09 | Atelier séparé, catalogue et bibliothèque de modèles | Réalisé | Quatre onglets, 105 champs dont 78 sondes, 152 modèles et 14 catégories. Compilation et interface testées ; 100 recettes personnelles au maximum, sans collecte au simple choix. |
| A10 | Recettes communes Général, Poste et filtre Recherche | Réalisé | Tests d’identité GUID, cinq présentations et enregistrement par tableau. L’Atelier liste une OU ; le tableau Poste évalue une seule identité et ses données disponibles. |
| A11 | Collecte sélective, dates distinctes et regroupement CIM | Réalisé | Plan des mesures, fraîcheur et réutilisation testés. Les fixtures ne garantissent ni disponibilité des fournisseurs CIM ni performances sur les postes réels. |
| A12 | Base en onglets, zoom et filtres de transfert explicites | Réalisé | Contrôles Windows des onglets, du zoom et des transferts. Les corrections de la passe actuelle sont détaillées en B01–B07 ; DPI multi-écrans et lecteur d’écran restent à qualifier. |

## Les 11 points de la passe actuelle

| ID | Point | Mise en œuvre ou livraison | État des tests et preuves |
|---|---|---|---|
| B01 | Recherche centrée sur les requêtes, catalogue et favoris | Réalisé | Validé hors ligne en R6 : barre unifiée avec 5 vues Annuaire, 152 modèles locaux et recettes personnelles. |
| B02 | Résultats locaux asynchrones, états distincts et périmètre OU de Recherche | Réalisé | Validé hors ligne en R6 : calcul local, compteurs et gardes OU/session/génération. |
| B03 | Atelier dans Outils, crayon et retour au contexte précédent | Réalisé | Validé hors ligne en R6 : navigation, contexte et retour couverts par les tests WPF. |
| B04 | Rendu différé des tableaux masqués et catalogue indexé | Réalisé | Validé hors ligne en R6 : cache, contexte et rendu différé. Les mesures ciblées ne constituent pas une mesure du débit AD ou du rendu de tout parc réel. |
| B05 | Mesures et avertissements de durée des callbacks UI | Réalisé | Instrumentation validée hors ligne en R6 : retours sur le fil d’interface séparés des durées workers. L’avertissement de 551 ms ne nommait pas l’opération ; l’événement exact n’a pas été reproduit. Aucune garantie que tous les callbacks restent sous 120 ms. |
| B06 | Sélecteurs libérés après un lancement refusé et rejets des réponses anciennes | Réalisé | Validé hors ligne en R6 : admissions refusées et réponses obsolètes. |
| B07 | Zoom stable et tableaux utilisables dans les petites surfaces | Réalisé | Validé hors ligne en R6 : zoom 150 %, retour à 100 % et options compactes, avec contrôles de géométrie WPF. |
| B08 | Campagne exhaustive des suites Windows hors ligne | Terminée ; validée hors ligne | **63/63 étapes réussies** : Quick 27, Additional 12, AllOffline 23 et WiringRecherche (44 cas). 59 fichiers `Test-*.ps1` et 4 étapes auxiliaires ; aucun dépassement de délai ni runtime modifié, contrôle PROD `-CheckOnly` réussi. R5 reste en échec à 62/63 ; R6 utilise les mêmes archives, sans collecte invitée concurrente. |
| B09 | Captures 1080p et guides Word/PDF v1.0 | Terminé | Quatre documents, 96 pages relues, 33 figures par guide. 34 images documentaires natives et 37 contrôles de capture ; données fictives, pas de recette humaine déduite. |
| B10 | Packs classiques DEV/PROD, publication et vérification GitHub | RC1.17.3 publié et vérifié | 93 fichiers runtime identiques entre DEV et PROD. Commit `abc400f` poussé sur `master` ; deux ZIP récupérés depuis GitHub et vérifiés par taille et SHA-256. [Reçu de publication](query-navigation/github-packs.json). |
| B11 | Recette humaine à la souris dans la VM | Bloqué par le verrouillage du Mac | Aucun des 9 scénarios applicatifs exécuté : 0 réussite. Les captures hors écran et événements WPF ne remplacent pas cette recette. |

## Limites et reste à faire

- **Annuaire et parc réels : non qualifiés.** Le scénario Windows de 5 000 postes est synthétique. Les droits, réplications AD, fournisseurs CIM, latences et volumes réels doivent faire l’objet d’une recette sur le domaine cible.
- **Incident DLL : cause non établie.** R4 a échoué sur un chargement de `Domenia.Native.dll` et R5 sur `M4D.Admin.Common.Query.dll`, avec `E_UNEXPECTED`, avant les cas concernés. Les sept chargements isolés réussis n’ont pas reproduit l’incident ; le diagnostic reste **INCONCLUSIVE**. La réussite R6 ne prouve pas que cette cause a été corrigée.
- **Campagne R6 : réussite distincte.** Les 63 étapes ont réussi sur les mêmes ZIP que R5, sans collecte invitée concurrente. Les essais R4/R5 restent conservés ; aucune reconstruction du logiciel ni fusion des campagnes ne masque leurs échecs.
- **Durée des callbacks : qualification limitée.** L’avertissement de 551 ms ne contenait pas le nom de l’opération et l’événement exact n’a pas été reproduit. Des métriques ont été ajoutées et le rendu des tableaux masqués a été différé ; le rendu d’un tableau visible conserve un coût réel. Ces changements ne garantissent pas que tous les callbacks passent sous le seuil d’avertissement de 120 ms.
- **Recette humaine : bloquée.** Le verrouillage du Mac empêche le parcours à la souris ; les 9 scénarios restent non exécutés.
- **Publication actuelle : effectuée et vérifiée.** Les packs RC1.17.3 sont présents sur `master` au commit `abc400f` ; le téléchargement GitHub confirme les deux SHA-256. Le statut formel `WindowsQualification=NOT_EVALUATED` et le booléen `Publishable=false` restent inchangés : cette publication ne qualifie pas un domaine réel.
- **Cache et ergonomie : limites explicites.** Mémoire, espace disque et rétention sont finis. Restauration manuelle documentée, sans assistant graphique ; qualification multi-écrans/DPI à chaud, lecteur d’écran et accessibilité complète non revendiquée.
- **MWAD : abandon volontaire.** Le format d’archive custom a été annulé à la demande de l’utilisateur. La cible est bien constituée de deux packs classiques DEV/PROD ; aucun `domenia.wad` n’est attendu.

## Accès aux preuves

- [Registre des 30 points et 12 demandes](../2026-10-12/completion-ledger-20261012.json) et [registre B01–B11](completion-ledger.json).
- [Qualification R6 : réussite 63/63](query-navigation/qualification.json), [rapport Windows original](query-navigation/r6/qualification.json) et [empreintes des preuves exportées](query-navigation/r6/proof-export-manifest.json).
- [Tentative R5 : échec 62/63](query-navigation/intermediate/r5-campaign/attempt-status.json) et [diagnostic de profil inconclusif](query-navigation/intermediate/profile-diagnostic/diagnostic-summary.json).
- [Contrôles documentaires et empreintes](query-navigation/documentation-qa.json) et [recette humaine non exécutée](query-navigation/interactive-gui.json).
- [Comparaison des archives et des sources](query-navigation/archive-source-review.json), [rapport de construction](query-navigation/build-report.json) et [revue de code](query-navigation/code-review.json).

Les registres et rapports détaillés conservent les commandes, plateformes, limites et identités des archives. Le [reçu GitHub](query-navigation/github-packs.json) atteste la publication des deux packs ; les tentatives précédentes restent conservées.


## Actualisation par OU — RC1.17.4

| Point | État et preuve |
|---|---|
| Séparer AD local, relevé des postes et recalcul | Raccordé : trois actions identiques dans Accueil et Recherche, OU et sous-OU explicites. |
| Fraîcheur sans rajeunissement artificiel | Raccordé : provenance du même instantané SQLite, horloges AD/ping/WMI/calcul distinctes, couverture N/M. |
| Enchaînement fiable | Raccordé : reçu propre à l’opération, erreurs et annulations empêchent la suite. |
| Réponse ancienne après sauvegarde | Corrigé : résultat périmé écarté avant rendu. |
| Validation Windows de cette passe | Non exécutée : PC éteint, recette prise en charge par l’utilisateur. |

[Contrôles locaux et limites](ou-refresh/qualification.json) · [Recette proposée](ou-refresh/RECETTE.md).
