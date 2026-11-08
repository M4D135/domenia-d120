# Synthèse de l'audit de parité Domenia 2 — 30 octobre 2026

Sources : les 293 fiches `AUDIT/<ID>.json`, établies fonction par fonction sur le code de `repo/v2` (master 7b128f32), à partir de `open-items.json` (catalogue `repo/v2/docs/features.json`). Chaque preuve citée a été réellement lue ; aucune fiche n'a conclu `fait` sans preuve ; rien n'est `incertain`.

## Comptes par verdict

| verdict | nombre |
|---|---|
| fait | 75 |
| fait-sans-test | 10 |
| partiel | 191 |
| a-faire | 17 |
| **total** | **293** |

- **85 fonctions sur 293 sont réellement en place** (dont 10 sans test dédié) : une large part des notes « Reste à faire » de FEATURES.md était périmée, comme attendu (2.0.5 → 2.0.8).
- **191 restent partielles** : le cœur existe, mais des écarts précis, listés dans chaque fiche, subsistent (garde-fous annoncés jamais exercés, constantes non conformes, raccordements décoratifs).
- **17 sont à faire** (rien dans le code) : TRV-035, TRV-037, TRV-041, TRV-042, TRV-079, TRV-089, TRV-090, TRV-114, TRV-116, TRV-130, TRV-133, TRV-135, TRV-137, TRV-140, TRV-154, TRV-201, TRV-208.
- Trois fiches (`TRV-034`, `TRV-041`, `TRV-042`) supposent des éléments disparus du produit (XAML, compilation à l'exécution PowerShell) : leur énoncé littéral est impossible et demande un arbitrage de David (abandon ou reformulation), signalé dans leur fiche.

## Répartition des corrections à conduire

218 fonctions demandent un travail (191 partielles, 17 à faire, 10 sans test — pour ces dernières, seuls des tests manquent).
Sur ces 218 : efforts 69 S, 125 M, 24 L ; risques 101 lecture, 74 écriture locale, 15 écriture AD, 28 réseau.

Les 22 lots ci-dessous couvrent exactement ces 218 fonctions (vérifié : chacune une seule fois), de ≤ 15 fonctions, ordonnés par valeur puis dépendances. Les lots touchant des **écritures AD** ou le **réseau** sont signalés : à conduire sur banc d'essai / annuaire de test d'abord.

| lot | fonctions | S/M/L | risques |
|---|---|---|---|
| L01 | 14 | 2/8/4 | ecriture-AD×12, ecriture-locale×1, lecture×1 |
| L02 | 7 | 2/5/0 | reseau×7 |
| L03 | 15 | 4/11/0 | ecriture-locale×6, lecture×9 |
| L04 | 13 | 4/8/1 | ecriture-AD×2, ecriture-locale×2, lecture×6, reseau×3 |
| L05 | 14 | 3/10/1 | ecriture-locale×1, lecture×7, reseau×6 |
| L06 | 11 | 2/8/1 | ecriture-locale×1, lecture×10 |
| L07 | 7 | 4/3/0 | lecture×7 |
| L09 | 10 | 4/5/1 | ecriture-locale×3, lecture×7 |
| L08 | 10 | 4/5/1 | ecriture-locale×1, lecture×7, reseau×2 |
| L11 | 13 | 2/8/3 | ecriture-locale×13 |
| L10 | 8 | 2/4/2 | ecriture-locale×3, lecture×5 |
| L12 | 12 | 2/8/2 | ecriture-locale×12 |
| L13 | 12 | 7/5/0 | ecriture-locale×5, lecture×7 |
| L14 | 6 | 3/3/0 | ecriture-locale×6 |
| L15 | 8 | 5/3/0 | ecriture-locale×1, lecture×2, reseau×5 |
| L16 | 6 | 0/4/2 | ecriture-AD×1, ecriture-locale×1, lecture×2, reseau×2 |
| L17 | 12 | 5/6/1 | ecriture-locale×3, lecture×9 |
| L18 | 14 | 6/6/2 | ecriture-locale×5, lecture×9 |
| L19 | 9 | 5/4/0 | ecriture-locale×3, lecture×6 |
| L20 | 5 | 0/3/2 | ecriture-locale×3, lecture×1, reseau×1 |
| L21 | 8 | 2/6/0 | ecriture-locale×2, lecture×5, reseau×1 |
| L22 | 4 | 1/2/1 | ecriture-locale×2, lecture×1, reseau×1 |

### Lot 1 — L01 · Écritures AD : idempotence, verrous, relectures

Sécuriser le circuit d'écriture AD avant tout : empreinte de plan comme clé d'idempotence, verrou par cible, machine à états, codes LDAP 16/20, garde-fous de relecture et de protection, réinterprétation des reçus au démarrage, sélection des DLL RSAT.

Effectif : 14 fonctions (2 S, 8 M, 4 L). À faire complètes dans ce lot : TRV-140.
- **⚠ écritures AD** — annuaire de test d'abord, journal des reçus vérifié à chaque étape.

- `TRV-228` — Revalidation du plan au moment de l'envoi *[partiel, S, ecriture-AD]*
- `TRV-230` — Reçus en attente : blocage et verrous par cible *[partiel, L, ecriture-AD]*
- `TRV-232` — Idempotence et refus du double envoi *[partiel, L, ecriture-AD]*
- `TRV-233` — Issue d'une écriture (machine à états) *[partiel, M, ecriture-AD]*
- `TRV-234` — Écriture conditionnelle et détection d'écriture concurrente *[partiel, M, ecriture-AD]*
- `TRV-235` — Préconditions relues juste avant l'envoi *[partiel, M, ecriture-AD]*
- `TRV-236` — Verrous par cible et classe d'action *[partiel, L, ecriture-AD]*
- `TRV-237` — Mode lecture seule fermé par défaut *[partiel, M, ecriture-AD]*
- `TRV-238` — Objets protégés et DN illisible *[partiel, M, ecriture-AD]*
- `TRV-239` — Cible d'écriture saisie à la main (DN) *[partiel, M, ecriture-AD]*
- `TRV-212` — Contrôle de fraîcheur avant écriture *[partiel, M, ecriture-AD]*
- `TRV-231` — Reprise après redémarrage sans rejeu *[partiel, M, ecriture-locale]*
- `TRV-225` — Détails techniques d'un plan d'intervention *[partiel, S, lecture]*
- `TRV-140` — Source du module Active Directory épinglée *[a-faire, L, ecriture-AD]*

### Lot 2 — L02 · Opérations à distance et transport

Raccorder les exécuteurs distants réels et les contrats de transport : délais doux/durs, décideur de repli, besoins d'identifiants par opération, contrôle de sûreté du code transport, chaînage PrepareFallbackPlan et conventions des écrans Postes.

Effectif : 7 fonctions (2 S, 5 M, 0 L). À faire complètes dans ce lot : TRV-201.
- **⚠ réseau** — à valider hors production.

- `TRV-229` — Aperçu exact d'une opération collective *[partiel, M, reseau]*
- `TRV-214` — Canal d'écriture unique, verrous et admission *[partiel, M, reseau]*
- `TRV-216` — Postcondition des actions distantes *[partiel, M, reseau]*
- `TRV-207` — Comptes transmis selon l'opération *[partiel, M, reseau]*
- `TRV-200` — Aucun repli intrusif pour une lecture *[partiel, S, reseau]*
- `TRV-201` — Contrôle statique anti-affaiblissement de Windows *[a-faire, S, reseau]*
- `PST-023` — Replis distants PsExec puis tâche planifiée *[partiel, M, reseau]*

### Lot 3 — L03 · Sécurité : gardes locales des opérations

Compléter les gardes déjà écrits mais inactifs : minuteur d'accès, projection liste blanche, inspecteur de résultats worker, déduplication bornée, presse-papiers secret, refus mémorisé par capacité, interruptions de maintenance sur tous les gestes, comparaison d'identité de la cible (DN complet, compte de service).

Effectif : 15 fonctions (4 S, 11 M, 0 L).

- `TRV-186` — Mode écriture confirmé et retour automatique en lecture seule *[partiel, M, lecture]*
- `TRV-189` — Vérification du poste qui répond *[partiel, M, lecture]*
- `TRV-192` — Identité de consultation et invalidation *[partiel, M, lecture]*
- `TRV-196` — Un compte par ressource protégée *[partiel, M, ecriture-locale]*
- `TRV-197` — Une demande par ressource malgré des refus en rafale *[partiel, S, lecture]*
- `TRV-198` — Un seul rejeu de lecture, jamais d'écriture *[partiel, M, lecture]*
- `TRV-199` — Famille d'échec et droit requis cité *[partiel, M, lecture]*
- `TRV-202` — Masquage des secrets dans journaux, traces et exports *[partiel, S, ecriture-locale]*
- `TRV-203` — Exports sans secret *[partiel, S, ecriture-locale]*
- `TRV-204` — Détection d'un refus dans le résultat d'un worker *[partiel, M, lecture]*
- `TRV-205` — Comptes purgés au changement de session ou de domaine *[partiel, M, ecriture-locale]*
- `TRV-206` — Garde « écriture active ou incertaine » *[partiel, M, ecriture-locale]*
- `TRV-210` — Garde de fermeture de la fenêtre *[partiel, M, ecriture-locale]*
- `TRV-211` — État des boutons selon droits et lecture seule *[partiel, M, lecture]*
- `TRV-215` — Résultat d'écriture, postcondition et compensation *[partiel, S, lecture]*

### Lot 4 — L04 · Connexion, comptes, secrets

Achever la connexion et la vie du compte : bornes de délai lues de la configuration, masquage selon Auth.AllowWindowsSession, comparaison du compte mémorisé sans domaine, décompte des lectures avec l'ancien mot de passe, disjoncteur par compte, rapprochement SID, identité de session en une structure, bornes de copie des secrets, règle de compensation.

Effectif : 13 fonctions (4 S, 8 M, 1 L).
- **⚠ écritures AD** — annuaire de test d'abord, journal des reçus vérifié à chaque étape.
- **⚠ réseau** — à valider hors production.

- `TRV-012` — Message de refus de connexion en clair *[partiel, S, lecture]*
- `TRV-013` — Connexion « Continuer en tant que DOMAINE\nom » (session Windows d'abord) *[partiel, M, reseau]*
- `TRV-014` — Mode diagnostic de la connexion *[partiel, S, lecture]*
- `TRV-015` — Coffre Windows à la connexion *[partiel, M, ecriture-locale]*
- `TRV-016` — Connexion explicite à tentative unique *[partiel, M, reseau]*
- `TRV-183` — Blocage des écritures distantes *[partiel, M, ecriture-AD]*
- `TRV-193` — Identité immuable de sélection *[partiel, M, lecture]*
- `TRV-219` — Affichage temporaire d'un mot de passe saisi (œil, 5 s) *[partiel, S, lecture]*
- `TRV-221` — Correction centralisée d'un compte sans reconnexion (anti-verrouillage) *[partiel, M, lecture]*
- `TRV-222` — Rapprochement des noms d'un compte par SID *[partiel, L, reseau]*
- `TRV-223` — Garde d'authentification partagée des workers *[partiel, M, lecture]*
- `TRV-240` — Attributs secrets jamais conservés *[partiel, S, ecriture-AD]*
- `TRV-241` — Presse-papiers protégé *[partiel, M, ecriture-locale]*

### Lot 5 — L05 · Moteur : contrats de sondes, plafonds, calibrage

Appliquer les chiffres annoncés : plafonds et bornes des réglages (1 à 2000, MaxUserProbes, 256 Kio), calibrage sur mesures réelles, isolation des lectures, regroupement par requête, relevés d'utilisation, table déclarative des classes, messages de progression réels des lectures.

Effectif : 14 fonctions (3 S, 10 M, 1 L).
- **⚠ réseau** — à valider hors production.

- `TRV-096` — Classification structurée des erreurs *[partiel, M, lecture]*
- `TRV-097` — Estimation d'impact avant une opération *[partiel, M, lecture]*
- `TRV-099` — Réinitialisation des protections au changement de session *[partiel, M, ecriture-locale]*
- `TRV-100` — Lectures isolées hors processus *[partiel, M, reseau]*
- `TRV-101` — Budget de collecte par widget *[partiel, S, lecture]*
- `TRV-103` — Budget des vérifications sur sélection *[partiel, M, lecture]*
- `TRV-104` — Isolement et limites d'exécution des sondes *[partiel, M, lecture]*
- `TRV-105` — Collecteur unifié ping, console, inventaire, sondes *[partiel, M, reseau]*
- `TRV-106` — Regroupement des requêtes CIM *[partiel, L, reseau]*
- `TRV-113` — Un relevé par portée *[partiel, M, reseau]*
- `TRV-121` — Table déclarative unique des opérations *[partiel, M, lecture]*
- `TRV-122` — Classes et priorités des tâches *[partiel, S, lecture]*
- `TRV-129` — Délais de lecture fondés sur la progression *[partiel, S, reseau]*
- `TRV-146` — Accès LDAP du thread d'interface *[partiel, M, reseau]*

### Lot 6 — L06 · Moteur : ordonnancement, workers, registre

Construire ce qui manque au cœur : minuteur de recherche progressive, cadences des pastilles, registre des minuteries et hôtes de travail, fabrique protégée, durées par fournisseur, annulation de première ligne, tampons de page, registre d'atteignabilité annuaire, sauvegarde des collectes remplacées.

Effectif : 11 fonctions (2 S, 8 M, 1 L). À faire complètes dans ce lot : TRV-114, TRV-130, TRV-135, TRV-137, TRV-133.

- `TRV-114` — Minuteur de la recherche progressive *[a-faire, M, lecture]*
- `TRV-117` — Rafraîchissement limité des pastilles et de la portée *[partiel, S, lecture]*
- `TRV-130` — Propriété et libération des ressources *[a-faire, L, lecture]*
- `TRV-131` — Minuteries protégées et battement de cœur unique *[partiel, M, lecture]*
- `TRV-134` — Mesures d'exécution en mémoire *[partiel, M, lecture]*
- `TRV-141` — Moteur asynchrone de tâches *[partiel, M, lecture]*
- `TRV-142` — Annuler une tâche *[partiel, M, lecture]*
- `TRV-143` — Progression des tâches *[partiel, M, lecture]*
- `TRV-135` — Disponibilité de l'annuaire : hors ligne ou lent *[a-faire, M, lecture]*
- `TRV-137` — Tampon de pages borné (règle présente) *[a-faire, S, lecture]*
- `TRV-133` — Enregistrement d'une collecte remplacée *[a-faire, M, ecriture-locale]*

### Lot 7 — L07 · Moteur : noms, valeurs et projections AD

Fiabiliser la lecture AD elle-même : échappement ADsPath, RFC 4514 avec guillemets, borne 500 DN, catalogue de projections nommées, format commun des faits, conversion des anciens libellés.

Effectif : 7 fonctions (4 S, 3 M, 0 L). À faire complètes dans ce lot : TRV-116.

- `TRV-112` — Clés d'état de présence *[partiel, M, lecture]*
- `TRV-116` — Échappement des barres obliques dans un ADsPath *[a-faire, S, lecture]*
- `TRV-136` — Projection minimale des attributs de liste *[partiel, M, lecture]*
- `TRV-138` — Faits explicables *[partiel, M, lecture]*
- `TRV-139` — Lecture sûre des DN et des valeurs AD *[partiel, S, lecture]*
- `TRV-164` — Désambiguïsation des OU homonymes *[partiel, S, lecture]*
- `TRV-165` — Chemins d'OU lisibles et décodage des DN *[partiel, S, lecture]*

### Lot 8 — L09 · Ateliers de requêtes et bibliothèque partagée

Raccorder l'atelier : création de liste depuis la sélection, exclusion des widgets masqués, garde de révision sans lecture confirmée, protocole de publication de la bibliothèque, reprise des réglages hérités, chemin des points d'attention et des chiffres vers l'atelier, épinglement SHA-256 de la bibliothèque commune.

Effectif : 10 fonctions (4 S, 5 M, 1 L). À faire complètes dans ce lot : TRV-035.

- `TRV-148` — Projection des données du parc en enregistrements *[fait-sans-test, S, lecture]*
- `TRV-149` — Sélection figée par GUID *[partiel, M, ecriture-locale]*
- `TRV-151` — Liaison d'une requête à sa révision stockée *[partiel, S, lecture]*
- `TRV-152` — Caches de calcul et anti-rejeu *[partiel, S, lecture]*
- `TRV-278` — Lecture confirmée et paginée de la bibliothèque *[partiel, M, lecture]*
- `TRV-279` — Migration de l'ancienne bibliothèque JSON *[partiel, M, ecriture-locale]*
- `TRV-035` — Provenance déclarée de la bibliothèque commune M4D *[a-faire, M, lecture]*
- `REQ-034` — Enregistrer la requête (révision SQLite) *[partiel, S, ecriture-locale]*
- `ACC-039` — Ouvrir un chiffre dans l'atelier *[partiel, L, lecture]*
- `ACC-051` — Points d'attention vers une sélection figée *[partiel, M, lecture]*

### Lot 9 — L08 · Moteur : cache et fraîcheur

Mettre le cache au contrat : empreinte de contenu comme clé, cache de plan par empreinte de dépendances (dépend de TRV-151/152 du lot L09), cache progressif LiveCache, cache négatif horodaté, haché de définition pour toutes les sondes, DN hors clé, unité de politique, TTL de visite, réglage ObservationMaxAgeDays.

Effectif : 10 fonctions (4 S, 5 M, 1 L). À faire complètes dans ce lot : TRV-154.
- **⚠ réseau** — à valider hors production.

- `TRV-153` — Cache du fournisseur logiciels *[partiel, S, lecture]*
- `TRV-154` — Caches de plan et de rendu des widgets *[a-faire, M, lecture]*
- `TRV-155` — Âge et validité des observations *[partiel, S, lecture]*
- `TRV-157` — Cache progressif des recherches et observations *[partiel, L, ecriture-locale]*
- `TRV-158` — Cache négatif des échecs récents *[partiel, M, reseau]*
- `TRV-159` — Empreinte de définition des sondes *[partiel, S, reseau]*
- `TRV-160` — Cache de fiche par GUID et lecteur *[partiel, M, lecture]*
- `TRV-161` — Politique de fraîcheur avant modification *[partiel, M, lecture]*
- `TRV-162` — Cache de visite borné *[partiel, M, lecture]*
- `TRV-163` — Calcul différé des onglets lourds *[fait-sans-test, S, lecture]*

### Lot 10 — L11 · Stockage : écritures, lots, verrous, schéma

Rendre conformes les chemins d'écriture SQLite : file d'écriture réelle, lotissage, bornes annoncées, table morte réemployée (domenia_store_batches), nom du verrou global, schema_version, préférences réellement écrites, faits poste complets, gardes de résumé et de départ de relevé.

Effectif : 13 fonctions (2 S, 8 M, 3 L).

- `TRV-248` — Réglages d'expérience bornés et clés étendues *[partiel, M, ecriture-locale]*
- `TRV-251` — Publication des mesures après COMMIT *[partiel, M, ecriture-locale]*
- `TRV-253` — Dernière valeur connue préservée *[partiel, S, ecriture-locale]*
- `TRV-254` — Garde-fous de départ d'un relevé *[partiel, M, ecriture-locale]*
- `TRV-255` — Pipeline AD vers SQLite avant affichage *[partiel, M, ecriture-locale]*
- `TRV-256` — Faits poste enregistrés *[partiel, S, ecriture-locale]*
- `TRV-257` — Mise à jour partielle sans effacer les champs non lus *[partiel, M, ecriture-locale]*
- `TRV-260` — Une base SQLite locale par domaine *[partiel, M, ecriture-locale]*
- `TRV-261` — Écrivain unique et file d'enregistrement *[partiel, L, ecriture-locale]*
- `TRV-262` — Lots canoniques validés avant écriture *[partiel, L, ecriture-locale]*
- `TRV-263` — Reçus de lot et idempotence des enregistrements *[partiel, L, ecriture-locale]*
- `TRV-264` — Bail d'écriture inter-processus *[partiel, M, ecriture-locale]*
- `TRV-265` — Schéma 11/1 en avance seule *[partiel, M, ecriture-locale]*

### Lot 11 — L10 · Stockage : lectures, contrats, workers

Côté lecture : worker épinglé pour les documents, plan durable dans les préférences, budgets constants conformes (96 Kio), lectures détaillées durables, mode de stockage annoncé, catalogue des contrats, worker LocalIndexRead à liste close.

Effectif : 8 fonctions (2 S, 4 M, 2 L).

- `TRV-247` — Écriture et lecture sûres de documents locaux *[partiel, M, ecriture-locale]*
- `TRV-249` — Plan durable de campagne *[partiel, S, ecriture-locale]*
- `TRV-250` — Projection bornée des détails de sonde *[partiel, S, lecture]*
- `TRV-252` — Stockage durable des lectures détaillées *[partiel, M, ecriture-locale]*
- `TRV-258` — Emplacements de données par catégorie et mode de stockage *[partiel, M, lecture]*
- `TRV-259` — Catalogue des formats versionnés *[partiel, L, lecture]*
- `TRV-266` — Couche SQLite unique des workers *[partiel, M, lecture]*
- `TRV-267` — Lectures locales hors du fil d'interface *[partiel, L, lecture]*

### Lot 12 — L12 · Sauvegardes, purge et migrations

Fiabiliser sauvegardes et passages de Domenia 1 : séries Geste-*.db, utilitaire d'écriture atomique, copies de migration autonomes, bascule de domaine, abandons comptés et signalés, refus maintenance sur les gestes, copie de Domenia.settings.json (TRV-037), lecture tolérante du magasin de vues hérité (TRV-090), index poste→liens, reprise de la base D1 depuis Paramètres.

Effectif : 12 fonctions (2 S, 8 M, 2 L). À faire complètes dans ce lot : TRV-037, TRV-090.

- `TRV-268` — Résultat d'enregistrement perdu traité comme un échec *[partiel, M, ecriture-locale]*
- `TRV-269` — Bascule du contexte de base *[partiel, L, ecriture-locale]*
- `TRV-270` — Données en file destinées à une autre base *[partiel, M, ecriture-locale]*
- `TRV-271` — Refus des modifications pendant une maintenance *[partiel, M, ecriture-locale]*
- `TRV-272` — Sauvegarde vérifiée avant un geste qui modifie la base *[partiel, L, ecriture-locale]*
- `TRV-274` — Plan de migration ADCC vers Domenia *[partiel, M, ecriture-locale]*
- `TRV-275` — Sauvegarde avant migration de schéma *[partiel, M, ecriture-locale]*
- `TRV-276` — Écriture atomique de fichiers *[partiel, M, ecriture-locale]*
- `TRV-120` — Index incrémental des liens par poste et utilisateur *[partiel, S, ecriture-locale]*
- `TRV-037` — Migration des préférences vers le dossier Preferences *[a-faire, S, ecriture-locale]*
- `TRV-090` — Lecture tolérante du magasin de vues *[a-faire, M, ecriture-locale]*
- `PAR-028` — Reprendre les anciennes données *[partiel, M, ecriture-locale]*

### Lot 13 — L13 · Paramètres : base locale et diagnostic

Corriger l'écran Base locale : politique d'effacement atteignant la copie de l'avis, suspension des collectes au seuil 512 Mio, garde-fous d'identité de marqueur, colonnes mensongères du mode annuaire, ouverture de l'emplacement, dbstat par table, verdict Sain en mode annuaire, double liste des tables de purge, identité du coffre.

Effectif : 12 fonctions (7 S, 5 M, 0 L).

- `PAR-010` — Reprendre les sauvegardes locales *[partiel, S, ecriture-locale]*
- `PAR-011` — Réserve d'espace disque de la base *[partiel, M, ecriture-locale]*
- `PAR-012` — Reprise d'une maintenance interrompue au démarrage *[partiel, M, ecriture-locale]*
- `PAR-013` — Emplacement lisible de la base locale *[partiel, S, lecture]*
- `PAR-014` — Copier le chemin de la base *[fait-sans-test, S, lecture]*
- `PAR-015` — Ouvrir l'emplacement de la base *[partiel, S, lecture]*
- `PAR-023` — Prévisualiser la conservation *[partiel, M, lecture]*
- `PAR-025` — Mesurer le stockage local *[partiel, M, lecture]*
- `PAR-026` — Contrôler l'intégrité de la base *[partiel, M, lecture]*
- `PAR-030` — Catalogue du cache par périmètre (règle non raccordée) *[partiel, S, lecture]*
- `PAR-031` — Simuler puis purger des données locales *[partiel, S, ecriture-locale]*
- `PAR-049` — Préférences de connexion HKCU *[partiel, S, ecriture-locale]*

### Lot 14 — L14 · Paramètres : assistant et sauvegardes

Achever l'assistant et les sauvegardes réglées : pièces manquantes du déroulement, huit états du libellé, budget LocalStore.BackupTimeoutSeconds appliqué, dispositions de l'annexe, plus les tests des deux sauvegardes déjà branchées.

Effectif : 6 fonctions (3 S, 3 M, 0 L).

- `PAR-016` — Déplacer la base locale *[partiel, M, ecriture-locale]*
- `PAR-020` — État et texte de l'assistant de stockage *[partiel, M, ecriture-locale]*
- `PAR-033` — Sauvegarder maintenant *[partiel, M, ecriture-locale]*
- `PAR-034` — Préférences jointes aux sauvegardes *[partiel, S, ecriture-locale]*
- `PAR-035` — Copier une sauvegarde vers un fichier choisi *[fait-sans-test, S, ecriture-locale]*
- `PAR-036` — Sauvegarde automatique planifiée *[fait-sans-test, S, ecriture-locale]*

### Lot 15 — L15 · Collecte (réglages et widgets)

Raccorder la collecte : travail de fond consultant la fenêtre, trois réglages appliqués, plafonds SE-05 aux relevés de widget, plafond de file, fil de progression par widget, et tests des réglages déjà raccordés.

Effectif : 8 fonctions (5 S, 3 M, 0 L).
- **⚠ réseau** — à valider hors production.

- `PAR-037` — Plafond des widgets *[fait-sans-test, S, ecriture-locale]*
- `PAR-038` — Profil de collecte *[fait-sans-test, S, lecture]*
- `PAR-039` — Durées de fraîcheur par famille *[fait-sans-test, S, lecture]*
- `PAR-040` — Fenêtre de collecte *[partiel, M, reseau]*
- `PAR-041` — Parallélisme, réutilisation et plafond des relevés *[partiel, S, reseau]*
- `TRV-290` — Collecte immédiate à l'ajout d'un widget *[partiel, S, reseau]*
- `TRV-291` — File d'attente des collectes de widgets *[partiel, M, reseau]*
- `TRV-292` — Progression de collecte sur le widget *[partiel, M, reseau]*

### Lot 16 — L16 · Réglages décoratifs à raccorder

Faire que les réglages agissent : les douze commutateurs décoratifs de PAR-043, l'appliqué des tables, l'étiquette « Appliqué », le raccordement secrets/AD, le remplacement confirmé d'OU propre, le suivi de thème hors Paramètres.

Effectif : 6 fonctions (0 S, 4 M, 2 L).
- **⚠ écritures AD** — annuaire de test d'abord, journal des reçus vérifié à chaque étape.
- **⚠ réseau** — à valider hors production.

- `PAR-005` — Profil Essentiel ou Expert *[partiel, M, lecture]*
- `PAR-043` — Commutateurs de fonctionnalités *[partiel, L, reseau]*
- `PAR-044` — Politique centrale des éléments d'interface *[partiel, M, lecture]*
- `PAR-045` — Réglages de sécurité configurables *[partiel, M, ecriture-AD]*
- `PAR-046` — Réglages réseau, accès distant et budgets *[partiel, L, reseau]*
- `PAR-048` — Propagation de l'OU racine aux sections *[partiel, M, ecriture-locale]*

### Lot 17 — L17 · Journal technique

Compléter le journal : barre de journal repliée, phrase bornée 280, masquage des noms, purge de la pastille, synthèse multi-jobs en une ligne (TRV-077), niveau Trace et synthèse par requête (TRV-079), candidats de découverte, code incident INC-XXXX, anneau borné, tests des bascules existantes.

Effectif : 12 fonctions (5 S, 6 M, 1 L). À faire complètes dans ce lot : TRV-079.

- `TRV-070` — Journal de session lisible (Essentiel) ou brut (Expert) *[partiel, M, lecture]*
- `TRV-071` — Journal replié avec dernière ligne et pastille d'erreur *[partiel, L, lecture]*
- `TRV-072` — Rechercher dans le journal *[fait-sans-test, S, lecture]*
- `TRV-073` — Copier le journal avec masquage des noms *[partiel, M, lecture]*
- `TRV-074` — Effacer le journal affiché *[partiel, S, lecture]*
- `TRV-075` — Alerte « Journal indisponible » *[fait-sans-test, S, lecture]*
- `TRV-076` — Provenance d'une mesure enregistrée *[partiel, S, lecture]*
- `TRV-077` — Trace des requêtes de lecture *[partiel, M, lecture]*
- `TRV-078` — Trace des erreurs volontairement ignorées *[partiel, M, lecture]*
- `TRV-079` — Ligne de synthèse par requête dans Domenia.log *[a-faire, M, ecriture-locale]*
- `TRV-080` — Journal de connexion *[partiel, S, ecriture-locale]*
- `TRV-083` — Codes incident et regroupement des erreurs *[partiel, M, ecriture-locale]*

### Lot 18 — L18 · Démarrage : chargeur, intégrité, plan

Reprendre le chargeur D1 : plan phasé et ordonné, codes DOMENIA_MODULE_MISSING, tolérance CRLF/LF, plan des modules, message de refus avec commande, fichier d'erreur de démarrage, chronométrage aux phases, décision de premier plan journalisée, trace d'amorçage, DOMENIA_ROOT/MEGAD, rendu du résultat d'intégrité. TRV-034 (compilation à l'exécution) demande un arbitrage (le XAML/PowerShell n'est plus le produit).

Effectif : 14 fonctions (6 S, 6 M, 2 L).

- `TRV-022` — Lignes de résultat compilées *[partiel, M, lecture]*
- `TRV-024` — Lanceur limité à Windows PowerShell 5.1 x64 STA *[partiel, M, lecture]*
- `TRV-025` — Contrôle d'intégrité du paquet à chaque lancement *[partiel, S, lecture]*
- `TRV-026` — Liste des composants requis tirée du plan des modules *[partiel, M, lecture]*
- `TRV-027` — Blocage d'une mise à jour interrompue *[partiel, S, ecriture-locale]*
- `TRV-029` — Autotest sans lancement (-CheckOnly) *[partiel, S, lecture]*
- `TRV-030` — Journal des échecs de démarrage *[partiel, S, ecriture-locale]*
- `TRV-031` — Chronométrage du démarrage (R40) *[partiel, M, ecriture-locale]*
- `TRV-032` — Plan de modules fermé, phasé et ordonné *[partiel, L, lecture]*
- `TRV-033` — Pré-contrôle syntaxique et contrôle des exports *[partiel, M, lecture]*
- `TRV-034` — Types natifs compilés et bibliothèques épinglées *[partiel, L, lecture]*
- `TRV-036` — Activation de la fenêtre au premier plan maîtrisée *[partiel, M, ecriture-locale]*
- `TRV-039` — Trace d'amorçage et refus de relance cachée *[partiel, S, ecriture-locale]*
- `TRV-040` — Résolution du dossier d'installation *[partiel, S, lecture]*

### Lot 19 — L19 · Démarrage : coquille et fenêtre

Finir la coquille : bornes de la fiche, fermeture d'hôte testée, contrôles d'hôte à revoir pour un .exe natif, surveillant et réglages associés, jalon interface et fonction différée, codes incident d'affichage, activation. TRV-041 et TRV-042 exigent d'abord un arbitrage de David (préflight XAML sans objet ; audit a11y bloquant à reformuler depuis web/js/shell/a11y.js).

Effectif : 9 fonctions (5 S, 4 M, 0 L). À faire complètes dans ce lot : TRV-041, TRV-042.

- `TRV-019` — Écran de connexion : thème, Verr. Maj, annulation *[partiel, S, ecriture-locale]*
- `TRV-020` — Mode démonstration *[partiel, M, ecriture-locale]*
- `TRV-023` — Fermeture sans attente *[partiel, M, ecriture-locale]*
- `TRV-041` — Préflight et compatibilité XAML *[a-faire, S, lecture]*
- `TRV-042` — Collecte des contrôles et contrôles/fonctions critiques *[a-faire, M, lecture]*
- `TRV-043` — Moniteur de démarrage *[partiel, S, lecture]*
- `TRV-044` — Étapes différées après l'affichage d'Accueil *[partiel, M, lecture]*
- `TRV-045` — Rapport d'arrêt fatal *[partiel, S, lecture]*
- `TRV-046` — Auto-test intégré en ligne de commande *[partiel, S, lecture]*

### Lot 20 — L20 · Livraison et intégrité des paquets

Sécuriser la livraison : contrat unique avec étiquette de build, comparaison de reconstruction, options de choix local, vérification Authenticode et épinglement d'empreintes (TRV-089), registre fermé tools/operation-contracts.json (TRV-208).

Effectif : 5 fonctions (0 S, 3 M, 2 L). À faire complètes dans ce lot : TRV-089, TRV-208.
- **⚠ réseau** — à valider hors production.

- `TRV-084` — Identité unique de livraison *[partiel, L, ecriture-locale]*
- `TRV-085` — PROD autonome et reconstruction reproductible *[partiel, M, ecriture-locale]*
- `TRV-088` — Désinstallation sûre *[partiel, M, ecriture-locale]*
- `TRV-089` — Intégrité et confiance de l'éditeur séparées *[a-faire, M, reseau]*
- `TRV-208` — Corps de workers épinglés *[a-faire, L, lecture]*

### Lot 21 — L21 · Tableau de bord, opérations, tableaux

Raccorder les écrans de pilotage : sondes des widgets actifs avant actualisation OU, alerte mémoire (%) sur l'accueil, paramètres revision/clé vers Rechercher, percentiles de file d'attente, phases nommées du panneau, valeur réglée de santé du moteur, info-bulle WMI, reprise des clés Dashboard/Widgets.

Effectif : 8 fonctions (2 S, 6 M, 0 L).
- **⚠ réseau** — à valider hors production.

- `ACC-007` — Plan des sondes figé au clic *[partiel, M, reseau]*
- `ACC-027` — Alertes personnalisées *[partiel, M, ecriture-locale]*
- `ACC-031` — Ouvrir les postes de l'OU dans Rechercher *[partiel, M, lecture]*
- `OPE-001` — Indicateurs de collecte du moteur *[partiel, M, lecture]*
- `OPE-019` — Étapes détaillées d'une opération *[partiel, M, lecture]*
- `OPE-032` — Attente de verrou SQLite bornée et comptée *[partiel, S, lecture]*
- `TRV-287` — Sources proposées comme widgets *[partiel, S, lecture]*
- `TRV-313` — Persistance et migration des dispositions *[partiel, M, ecriture-locale]*

### Lot 22 — L22 · Rechercher : arbre, liste, export

Finir Rechercher : publication/relecture SQLite des sous-branches (budget de lecture), état déplié publié par le kit, budget par tic de la liste, export CSV en fichier.

Effectif : 4 fonctions (1 S, 2 M, 1 L).
- **⚠ réseau** — à valider hors production.

- `RCH-007` — Sous-branches publiées depuis la base locale *[partiel, L, ecriture-locale]*
- `RCH-045` — Branches de l'arbre rouvertes sans lecture *[partiel, M, lecture]*
- `RCH-048` — Application des changements détectés par la revérification *[partiel, M, reseau]*
- `RCH-069` — Exporter la liste en CSV *[partiel, S, ecriture-locale]*

## Dépendances inter-lots à respecter

- **L01 en tête, avant tout essai d'écriture en production** : `TRV-212` (fraîcheur uSNChanged/whenChanged), `TRV-232` (empreinte comme clé d'idempotence) et `TRV-233` (machine à états) conditionnent la sûreté de toutes les écritures AD ; L02 (délais, exécuteurs) les prolonge côté transport.
- **L03 après L01/L02** : plusieurs gardes (interruptions de maintenance, refus par capacité) doivent être raccordés une fois la machine à états d'écriture et le transport stables.
- **L05/L06/L07 avant L08** : plafonds, cadences, tampons de page et projections AD conditionnent l'empreinte et le contenu du cache.
- **L09 avant L08** : le cache de plan `TRV-154` dépend de `TRV-151`/`TRV-152` (révision déterminée, widgets masqués exclus).
- **L11 avant L12** : sauvegardes, purge et abandons comptés s'appuient sur la file d'écriture réelle et le verrou global conformes ; `TRV-037`/`TRV-090`/`PAR-028` (migrations D1) n'ont de sens qu'avec les imports corrigés.
- **L09 avant L21** : les chemins accueil→atelier (`ACC-039`, `ACC-051`) supposent l'atelier et la bibliothèque partagée raccordés.
- **Arbitrages préalables** (sans code) : `TRV-034`, `TRV-041`, `TRV-042` (L18/L19) — énoncés D1 devenus sans objet ; à trancher par David avant d'ouvrir ces lots.

## Méthode de reprise

Pour chaque fonction d'un lot : lire `AUDIT/<ID>.json` (le champ `manque` est précis et vérifiable), implémenter, puis re-vérifier les preuves citées. Un lot n'est clos que lorsque chaque écart listé a une preuve de correction (chemin:ligne) et, pour les risques écriture AD / réseau, un test d'échec explicite du garde-fou concerné. Les fiches `fait-sans-test` intégrées aux lots (PAR-014, PAR-035, PAR-036, PAR-037, PAR-038, PAR-039, TRV-072, TRV-075, TRV-148, TRV-163) n'attendent que ces tests.
