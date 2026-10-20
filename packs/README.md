# Packs Domenia 1.0

| Pack | Télécharger | Utilisation |
|---|---|---|
| PROD | [Domenia_PROD.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_PROD.zip) | Extraire le dossier `prod`, puis lancer `Domenia.exe` en gardant `wad` à côté. |
| DEV | [Domenia_DEV.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_DEV.zip) | Sources et outils ; `dev/FABRIQUER_PROD.cmd` reconstruit une distribution PROD. |

Build actuel : **RC1.17.38**, candidat personnel autonome. Contrôle visuel ciblé terminé.
Démarrage depuis l'hôte au repos : connexion 31.32 → 22.52 s ; accueil 130.07 → 110.34 s (médianes, 2 passages par version).
**Gain global non démontré** ; mesure isolée des exports : 7562 → 128 ms.
Archives inchangées, empreintes vérifiées, 172 fichiers applicatifs identiques DEV/PROD.
[Captures, mesures et limites](../validation/2026-10-20/rc38-startup/final/README.md).

Historique : RC1.17.34. Ping en une seule vague de 192 échos ; « Tout actualiser » et WMI : une seule séance de ping, puis lecture WMI des seuls postes qui répondent (plus de second ping). Opération worker modifiée : ParkPing. RC1.17.33 : Fenêtre de connexion plus rapide (seule la connexion est vérifiée avant ; l’interface principale après) ; l’Accueil n’attend plus la restauration de Rechercher (fin du blocage « En attente de l’OU mémorisée ») ; « Base locale âgée de 999999 min » remplacé par un message exact. RC1.17.31 : Démarrage : fenêtre de connexion environ 6,5 s plus tôt depuis RC1.17.27 (trace utilisateur : 10 s → 3,7 s) ; la racine du domaine mémorisée « avec sous-niveaux » se rouvre sur un seul niveau ; sous-étapes après connexion chronométrées (lignes `Detail/…` de `Domenia-startup.log`). RC1.17.30 : Journal assaini pendant les pings (erreur ignorée « expression Null » à chaque tâche du pool) ; recalcul de la vue d’ensemble refusé pendant un relevé dit « différé » au lieu de « non calculée ». RC1.17.29 : Relevés : le bandeau de reprise propose Reprendre, Plus tard ou **Abandonner** ; l’onglet **Outils > Relevés** montre le relevé en cours (Arrêter), le relevé interrompu (Reprendre, Abandonner) et les **derniers relevés par OU** (date, OU, type, état, postes lus, dernière réussite, motif). Opération worker modifiée : LocalIndexRead (lecture CollectionRuns). RC1.17.28 : Coffre Windows retiré de l’interface (rien n’est lu ni enregistré ; les identifiants déjà présents dans Windows ne sont pas supprimés). Les réglages d’Outils > Relevés s’affichent avec leur valeur enregistrée après redémarrage. Démarrage plus court avant la connexion depuis RC1.17.27. RC1.17.26 : Correctif : la carte « Compte AD » d’Intervenir ne reste plus grisée en changeant de poste (il fallait repasser en lecture seule puis en écriture). RC1.17.25 : erreur « CacheKey … chaîne vide » après « Désactiver le compte » ; boutons d’écriture qui restaient grisés jusqu’au passage lecture/écriture ; bannière verte « … Vérifié par le contrôleur de domaine à HH:mm » après toute écriture AD vérifiée. Depuis RC1.17.24 : Accueil : bouton **Tout actualiser** (objets AD, puis ping et WMI en une confirmation ; si la lecture AD échoue, ping et WMI partent sur les postes déjà connus). Le relevé WMI crée les associations utilisateur-poste depuis la console observée (compte trouvé dans AD, jamais une association déclarée ou importée remplacée). Vue d'ensemble et widgets recalculés toutes les 15 s pendant un relevé, avec la mention « Relevé en cours · partiel · N/M postes lus » ; un relevé arrêté s'affiche « relevé partiel … les postes lus sont exploitables ». Réglages des relevés (plafond des widgets, nouveaux essais WMI) : Outils > Relevés (depuis RC1.17.23). Contrôles hors Windows seulement (pwsh 7 Linux, audits Python) : **aucune exécution Windows PowerShell 5.1 de RC1.17.23 à RC1.17.34**. Preuves RC1.17.22 historiques : [pages accessibles à Windows, 28 étapes natives et cinq captures vérifiées](../validation/2026-10-18/rc22-ui-automation/README.md).

Taille, position et état normal/maximisé sont enregistrés automatiquement. Réduire conserve le dernier état ; rétablir après une réouverture maximisée retrouve la taille normale. Les réglages de sauvegarde automatique et les reçus restent désormais mémorisés après redémarrage (cinq tests Windows ciblés). RC17 a aussi corrigé l'arrêt du lot après timeout WMI ; sa sauvegarde automatique et sa restauration via interface sont [qualifiées sur le pack exact](../validation/2026-10-18/rc17-storage-ui/README.md). Les preuves RC17 et les tests isolés RC18 restent historiques. RC19 corrige l’ordre de chargement des réglages au démarrage. Le [dernier contrôle applicatif RC19](../validation/2026-10-18/rc19-final-session/README.md) confirme deux démarrages, la fenêtre et les réglages conservés, puis une sauvegarde automatique réelle après réouverture. ZIP inchangés. Qualification générale et décisions externes 134/146 ouvertes.

RC20 borne la page LDAP sous le quota pour éviter un échec immédiat des recherches limitées. Le contrôle final du pack RC20 confirme les deux démarrages, les réglages et la sauvegarde automatique. Les preuves précédentes restent historiques.

Accueil simplifié, Santé en dernier par défaut, déplacement des sections et tailles de widgets stables.
Le bandeau suit le lot complet, y compris les attentes et lʼenregistrement ; le panneau détaille les lectures.
La collecte WMI conserve le poste suivant pendant une saturation du moteur après un délai dépassé.
Chaque widget affiche la source et les dates des données, avec un petit ↻ permanent qui relit la source. La première configuration prépare automatiquement sa vue après la lecture de la base.

RC1.17.13 : vérification SQLite de bascule hors du fil d’interface, commandes repliables en très petite hauteur et fabrication déterministe des DLL.
RC1.17.14 : occupation de la base complétée (métadonnées de domaine), empreinte des règles de santé stable à la purge des suspensions expirées, identité des associations harmonisée entre grille, résumé et fiche, transport réellement utilisé affiché au lieu dʼêtre déduit, identité du poste contrôlée aussi pour les sondes seules.

RC1.17.15 : dates UTC des suspensions préservées après relecture JSON ; trois suites santé exécutées sur macOS natif (PowerShell 7.4.6), **45 cas réussis, aucun échec**. Contrôles de compatibilité et d’intégrité des packs ; aucun test VM. La qualification Windows 5.1 de ces packs reste ouverte.

Les contrôles de RC1.17.14 ont été exécutés hors Windows (pwsh 7 Linux, non qualifiant) : bancs
comportementaux ciblés des cinq points, sauvegarde de compatibilité 5.1, audits statiques et contrats
worker re-épinglés après revue indépendante. Aucune exécution sous Windows PowerShell 5.1 de ces
packs (décision David du 17 octobre : aucun test VM) ; la qualification complète sur AD reste ouverte
et aucun point de qualification nʼest clôturé.

Les deux ZIP contiennent le même runtime. La version et les empreintes sont dans
[manifest.json](manifest.json) et [SHA256SUMS](SHA256SUMS).

Depuis la racine du dépôt : `shasum -a 256 -c packs/SHA256SUMS`.

[Guides Word et PDF](../DOC) · [Bilan et portée des contrôles](../validation/2026-10-18/health-suspension-utc/README.md)

Pour reconstruire les archives versionnées :
`python3 dev/tools/build_packages.py --output /chemin/vers/un/dossier-hors-dev`.
Copier les ZIP DEV et PROD obtenus sous les noms stables de ce dossier et mettre
à jour leurs empreintes et le manifeste. Les archives restent des fichiers Git ordinaires.
