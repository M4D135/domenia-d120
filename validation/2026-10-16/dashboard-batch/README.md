# RC1.17.11 — dashboard et lots, 16 octobre 2026

Corrections demandées par David : accueil sans raccourcis redondants, Santé en dernier dans les dispositions livrées, déplacement des sections conservé et annulable, tailles S/M/L respectées même sur une ligne incomplète. Les dispositions personnelles et d’équipe sont préservées.

Le bandeau montre le lot entier (traités/total), y compris pendant les attentes et l’enregistrement ; le panneau conserve les lectures individuelles. Un timeout WMI n’épuise plus le poste suivant quand les appels natifs en nettoyage saturent temporairement le moteur. Les arrêts volontaires, erreurs d’identifiants et erreurs de stockage restent des arrêts.

Chaque widget affiche ses sources et les dates des données, avec plage quand nécessaire, jamais la date du dessin. Le mini ↻ reste visible et relit AD, ping, WMI ou logiciels selon le widget. Les synthèses du parc relisent AD puis leurs mesures ; les dates des données conservées ne sont pas remplacées par une tentative en échec. Une source inconnue reste non datée. Les historiques ne sont pas réécrits.

Le dernier pas de la première configuration prépare automatiquement la première vue depuis la base locale déjà lue. Il attend le calcul, propose de réessayer en cas d’erreur ou d’OU vide, et ne déclenche pas de scan WMI supplémentaire.

## Preuves ciblées

Tests natifs dans **CNAMTS-W11-01**, Windows PowerShell **5.1.26100.6584 x64 STA**, données fictives et collecteurs simulés. Aucun scan AD ou WMI réel. La campagne générale n’a pas été relancée, conformément à la demande de David.

- `admission-before.json` : bug de saturation reproduit, 1 réussite / 1 échec avant correction.
- `admission-after.json` : 21 cas Park ciblés réussis (timeout, reprise après saturation avec/sans ordonnanceur, arrêt, refus et backoff).
- `batch-activity.json` : 5 cas du suivi des lots réussis.
- `sections.json` : 4 cas d’ordre, déplacements, commandes WPF, persistance et annulation réussis.
- `operation-trace.json` : 21 cas réussis après correction des listes et du paramètre de catégorie sous 5.1.
- `widget-sizes.json` : BRD-027 réussi, 48 combinaisons de largeurs sur une à quatre colonnes.
- `widget-refresh.json` : 9 cas ciblés réussis : horloges, bouton WPF permanent et accessible, relance réelle des sources, ForceRefresh et périmètre des mesures, premier calcul, ajouts/file/AD.
- `ui-proof.json`, `accueil.png`, `sante-en-dernier.png` : rendu WPF natif hors écran sur données fictives, 1920 × 1240 ; contrôle visuel effectué. `lot-wmi.png` illustre le suivi du lot avant l’ajout des dates aux widgets. La position de son panneau hors écran n’est pas une qualification de placement dans la console.

Le ZIP DEV final `39AE44650715EF9A3CDFBD7EEEE50EECB51E78E5AB457AE1595B1EEB15524E9F` a été vérifié séparément : **9 cas Boards + 1 contrôle des dates AD/WMI du moteur Query réussis**, parseur natif sans erreur, Windows PowerShell 5.1 x64 STA. Voir `exact-zip/targeted-summary.json`, les rapports associés et `verify-delivery-pack.ps1`. Les 172 fichiers d’exécution PROD et DEV sont identiques ; seuls les manifestes propres à chaque édition diffèrent. Les sources du DEV correspondent intégralement à l’arbre de travail. Une ancienne copie intermédiaire a été détectée puis remplacée avant publication ; elle n’est pas le pack livré. Les résultats source antérieurs et cette vérification ciblée du ZIP final sont distingués dans `delivery.json`. Le worker composé **LocalStore** et l’empreinte du registre ont été relus puis réépinglés (ordre et horloges du dashboard).

## Limites et reste à faire

Pas de qualification générale du ZIP ni de transports AD/WMI réels ; `acceptance_passed` reste inchangé. Deux échecs antérieurs de ParkDetection restent ouverts (confirmation automatique après planification, compteur de filtrage MO-08), ainsi que la qualification générale Boards. Le test de sonde en attente avait une dépendance à un widget ajouté par un autre cas : il utilise désormais sa propre sonde explicite et passe isolément.

La grande liste reste à **151 points implémentés avec qualification Windows en attente et 9 points de qualification seule**. Les guides Markdown sont actualisés ; leurs éditions Word/PDF restent celles du précédent lot documentaire.

Spark a été sollicité pour revue et brouillon ; les deux demandes devenues inutiles ont été annulées sans sortie publique et aucun code généré n’a été intégré. Les preuves ci-dessus viennent des contrôles exécutés, pas d’un avis du modèle.
