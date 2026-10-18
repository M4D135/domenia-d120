# RC1.17.20 — qualification ciblée complémentaire et documentation

Qualification générale **non acquise**. Cette reprise complète les preuves critiques déjà conservées dans `../rc20-final-session/` ; elle ne les remplace pas. Les décisions 134/146 et le certificat 141 restent hors périmètre.

## Paquets et méthode

Windows 11 W11-01, Windows PowerShell 5.1.26100.6584 x64 ; tâches WPF dans la session interactive 1. DEV extrait et vérifié avant essais, puis seuls deux harnais de tests ont été réparés. Aucun fichier applicatif modifié.

- PROD SHA-256 : `71E4DB913EE613E68F167A9F384F99C2623922401678458DFA9B957F7E3CB609`.
- DEV SHA-256 : `D78CDB6408A9DA6229AD51B3E0D5C55E7600BDF3C42E8756FAC5E7316442D885`.
- Les ZIP restent identiques. Les corrections des harnais et du suivi appartiennent aux sources, pas rétroactivement aux archives testées.

## Résultats vérifiés

| Contrôle | Résultat | Portée |
| --- | --- | --- |
| QueryScale | 24 assertions, 20 000 objets, 39,509 s | Agrégation et export local synthétiques, aucune collecte de 20 000 machines |
| StorageFaults | 8 cas, 42 assertions | SQLite réel, SQLITE_FULL par quota et arrêts de processus ; pas de volume physique rempli |
| NetworkFaults | 12 cas, 89 assertions | Exceptions de transport injectées ; la preuve AD/WMI réelle RC17 reste distincte |
| VaultQualification | 7 cas natifs | Credential Manager réel, marqueur fictif nettoyé, sans réseau |
| CredentialGuard | Réussi | Doubles de connexions, aucune communication réseau |
| UxQualification corrigé | 15/15 | XAML livré, ressources, accessibilité déclarée, états vides, zoom/focus et panneau court ; pas de lecteur d’écran humain |
| QueryLibraryTiming corrigé | 12 assertions | 631 modèles, 125 recettes ; une mesure Windows, pas un benchmark statistique du rendu |
| Profil standard jetable | 12 contrôles | Installation, démarrage CheckOnly, conservation, réinstallation, suppression explicite du profil et des données locales ; sentinelle extérieure conservée |

Le compte jetable et son profil ont été supprimés après les essais. KI-005 est clos pour ce parcours. Les tentatives préparatoires échouées restent conservées : droits de session, chemin du paquet puis emplacement de journal dans la fixture ; ce ne sont pas des validations de l’application.

## Échecs conservés et reste interne

- `raw/targeted/Rules.json` : **1 041 succès, 34 échecs**. On observe notamment des attentes anciennes (santé en premier au lieu d’en dernier), une dépendance de test absente (Continuity), des fichiers d’ingénierie non livrés dans DEV et des cas fonctionnels à examiner. Aucun effacement d’échec ni succès global déduit des seuls cas réussis.
- `raw/targeted/Geometry.json` : **57 succès, 22 échecs** sur surfaces WPF hors écran. Des grilles/boutons ne satisfont pas les dimensions et positions attendues aux tailles/échelles simulées. Il faut distinguer l’état de fixture des défauts réels avant de modifier le runtime.
- `raw/targeted/Summary.json` : Installer complet arrêté à **240 secondes**, sans rapport final. Le parcours standard ciblé ci-dessus n’en qualifie pas toutes les branches.
- Restent les parcours humains clavier/Narrateur, le DPI réel multimoniteur, RDP réel, l’endurance longue et le parc cible. Ils ne sont pas couverts par les fixtures ou captures documentaires.

Les deux harnais réparés conservent leurs premières traces : UxQualification avait une expression PowerShell mal parenthésée et extrayait un ancien here-string XAML devenu vide ; QueryLibraryTiming attendait exactement cinq vues AD. Les corrections chargent la vue livrée et vérifient les catégories et identités sans figer le nombre de vues AD. Aucune assertion fonctionnelle en échec n’a été transformée en succès par suppression.

**Conserver le laboratoire pour la reprise ciblée des échecs internes.** L’autorisation antérieure d’effacer les VM portait uniquement sur le dernier contrôle critique, avant cette qualification complémentaire.

## Documentation terminée

Les deux guides décrivent RC1.17.20 : fenêtre et réglages conservés, sauvegarde automatique,
parcours actuel de la bibliothèque SQLite, aperçu et enregistrement des requêtes. Les sources
Markdown/JSON et les quatre livrables `DOC/Domenia-1.0-Guide-{technicien,administrateur}.{docx,pdf}`
sont synchronisés. Les PDF sont exportés depuis les DOCX, pas depuis une autre mise en page.
Les 34 pages technicien et 83 pages administrateur ont été inspectées ; planches et empreintes
sont conservées dans `document-review/` et `document-review.json`.

38 PNG ont été rendus par WPF natif ; chaque guide utilise 29 figures. Les cadrages sont adaptés
aux contrôles actuels. Le harnais charge les définitions du chargeur fermé livré ; son magasin
et ses données sont fictifs en mémoire, sans AD ni qualification de persistance SQLite. Les
événements de bibliothèque et la sélection des onglets sont explicites pour le rendu hors écran.
La provenance est liée au SHA-256 du manifeste runtime et à ses 172 fichiers, ainsi qu’au Build.
Les changements de documentation/harnais DEV n’invalident plus artificiellement cette preuve.
Les anciennes captures restent dans l’historique Git et les tentatives dans `raw/capture-history/`.

**54/55 contrôles de capture passent.** Le dernier échec concerne l’Atelier à 1280×720 :
une ligne entière et une partielle, contre deux lignes entières attendues. Cette image n’est pas
une figure des guides. L’échec est conservé dans `raw/captures/atelier-viewport-1280x720.json`
et KI-007 ; il n’est pas confondu avec les 22 échecs de Geometry. La tentative précédente
(53/55) est conservée dans `raw/captures-attempt12/`.

KI-002 et le point 149 sont clos pour la documentation, sans clore la qualification générale.
`doc_sync --check` réussit : zéro écart nouveau, zéro figure sans provenance, aucune aide orpheline.
Les 52 citations particulières déjà relues (exemples, messages composés, renvois) restent dans
la référence ; aucune exception n’a été ajoutée pour faire passer cette mise à jour.

## Clôture de la passe

Les cinq tâches de cette qualification sont retirées ; aucun processus de qualification ni
compte/profil jetable ne subsiste. Les 172 fichiers runtime et les deux archives sont inchangés,
revérifiés dans la VM (`raw/capture-history/Cleanup.json`). Le manifeste source DEV est actualisé
uniquement pour les fichiers non applicatifs modifiés ; cela ne modifie pas les ZIP testés.
Les résultats sont copiés hors VM. **Conserver les VM pour la reprise interne ciblée KI-007** ;
ni certificat 141 ni décisions externes 134/146 n’ont été modifiés.

La demande de relecture Spark n’a fourni aucun texte exploitable avant sa clôture ; elle n’est
pas comptée comme validation. Les conclusions ci-dessus s’appuient sur les rapports natifs et
la vérification directe des fichiers, sans avis de modèle présenté comme preuve.

Les journaux texte archivés ont des fins de ligne LF et leurs blancs de fin de ligne sont retirés ; le contenu des erreurs est conservé.
