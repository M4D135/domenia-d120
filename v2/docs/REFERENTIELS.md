# Référentiels indépendants de Domenia

Le format `Domenia.ReferencePatch/1` diffuse des requêtes et sondes **déclaratives déjà enregistrées** dans la bibliothèque de Domenia, avec leurs identifiants, catégories et descriptions. Il ne crée aucun nouveau type de site ou de ticket. Les dispositions de tableaux, profils, préférences et binaires utilisent leurs propres contrats. Une requête importée n’est jamais exécutée pendant l’import ; aucun script PowerShell, formule ou macro n’est accepté comme champ du patch. Les sélections de GUID d’objets réels sont refusées.

## Préparer et appliquer

Dans **Requêtes → Partage**, choisir les recettes personnelles, donner un nom et une version entière, puis cocher **Patch de référence strict**. L’export existant enregistre le JSON préparé. Vérifier les valeurs avant diffusion : les noms et descriptions sont des données de l’opérateur, pas des données automatiquement anonymisées.

Le diffuseur dépose le fichier `Domenia-reference-<nom>-v<version>.json` à côté des ZIP du partage administré : copie sous un nom temporaire, puis renommage seulement après transfert. L’application n’écrit jamais sur ce partage. L’opérateur choisit explicitement le JSON depuis le sélecteur de fichier Windows de **Requêtes → Partage** (un partage accessible avec ses droits Windows convient), ou colle son contenu. Le bouton **Lire le dossier de diffusion mémorisé** lit explicitement `updates.distributionFolder`, la même préférence que Paramètres → Mises à jour. Le partage doit publier `SHA256SUMS.txt` (SHA-256 hexadécimal, deux espaces ou espace puis `*`, nom simple). Le catalogue est borné à 2 Mio / 512 lignes et 32 patches. Les ZIP et autres fichiers valides peuvent figurer dans le même sidecar ; seuls les noms `Domenia-reference-<nom>-v<entier>.json` sont proposés. La sélection utilise un ID serveur de dix minutes, jamais un chemin fourni à la commande. Le catalogue est relu avant et après copie en mémoire bornée ; son SHA brut et celui du fichier doivent correspondre à la sélection. La préférence est relue pour refuser un changement de dossier. Aucun accès automatique, fichier écrit sur le partage ou installation implicite.

L’aperçu montre les ajouts, les identiques, les conflits, les métadonnées et les liens conservés. Tous les choix commencent à **Ignorer**. Un remplacement ou renommage est explicite ; il garde le même ID. Les widgets et autres consommateurs gardent leur révision liée, dont la définition reste disponible. L’absence d’une recette dans le patch n’entraîne aucune suppression. La fermeture de l’aperçu ne modifie pas la bibliothèque.

Après confirmation, le moteur requalifie source, compte et epoch, compare le document complet à celui de l’aperçu, conserve l’original, puis écrit définitions et reçu SHA-256 ensemble. **Patches de référence traités** relit les reçus du stockage. Un reçu atteste le traitement historique ; des corrections locales ultérieures peuvent avoir changé la bibliothèque. Représenter le même SHA après redémarrage ne produit aucun nouvel effet et ne remplace pas ces corrections. Une version inférieure, ou la même version avec un autre contenu, est refusée. Pour changer les choix d’un patch déjà traité, produire une nouvelle version et revoir les conflits.

Le mode démonstration refuse ces opérations côté moteur avant accès au support réel, même en appelant directement le pont ou le service. Le partage historique de packs de la simulation conserve son stockage isolé. Le bouton **Essayer un patch fictif en démonstration** génère deux recettes inventées dans le moteur : un conflit local et un ajout. Il utilise la même bibliothèque mémoire que l’écran et les mêmes règles d’aperçu, CAS et reçu. Une capacité interne est liée à cette instance exacte de `MemoryQueryLibraryStore` ; aucun texte, chemin, source externe ou flag d’autorité n’est accepté. Le reçu porte `Simulated=true` et annonce un stockage de session. Un nouvel essai, même après changement de date, retrouve le même patch ; la réinitialisation de la démo recrée son espace selon le mécanisme de la composition.

## Format et bornes

Un seul objet JSON UTF-8, avec exactement `format`, `application` (`Domenia`), `payload` et `sha256`. `payload` est une chaîne contenant le JSON métier ; `sha256` est le SHA-256 minuscule de ses **octets UTF-8 exacts**. Il couvre donc aussi le nom, la version, le domaine, la date, les catégories et les descriptions. Aucun champ inconnu ou dupliqué n’est accepté. L’empreinte du payload intégrée à l’enveloppe est distincte du SHA des octets du fichier publié dans `SHA256SUMS.txt`. L’enveloppe contient elle-même son empreinte : elle garantit l’intégrité, **pas l’authenticité de l’éditeur**. Utiliser un partage administré dont les droits d’écriture sont restreints ; aucune signature absente n’est annoncée.

Le payload contient exactement `id`, `name`, `version`, `domainKey`, `createdAt`, `items`. Chaque élément contient exactement `definition` (JSON d’une recette validée par le moteur existant), `category`, `description`. L’ID du patch dépend de son nom selon la règle existante `QueryLibrary.PackId`, les IDs métier restent ceux des recettes. `domainKey` est la clé du domaine de la bibliothèque, pas un chemin de base. Le domaine doit correspondre exactement. La date porte un fuseau et ne peut être future au-delà de deux minutes. La version est comprise entre 1 et 1 000 000.

Limites : 16 Mio par fichier, 500 recettes, 1 Mio par définition, quatre aperçus de trente minutes. Les chaînes restent des valeurs JSON ; `+33`, apostrophes, nombres négatifs et alias contenant `|` ou `;` ne passent jamais par un encodeur CSV. Les transformations historiques d’accents des anciens packs ne sont pas appliquées. Une définition nécessitant une normalisation est refusée et doit être réexportée depuis la bibliothèque.

### Exemple fictif de diffusion

```text
\\serveur\Domenia\
  Domenia-reference-exemple-v1.json
  SHA256SUMS.txt
  <ZIP PROD vérifié et son inventaire, selon le contrat de livraison>
```

Exemple destiné uniquement à `DC=example,DC=invalid` (SHA calculé sur le payload présenté, aucune donnée du poste) :

```json
{
  "format": "Domenia.ReferencePatch/1",
  "application": "Domenia",
  "payload": "{\"id\":\"12da73f165a8a83c17abfaef77fea1f2\",\"name\":\"Exemple\",\"version\":1,\"domainKey\":\"e5b85d912981bac45ef154035523d01ffd47d4335b329d0ff952f4572b7efc7f\",\"createdAt\":\"2026-10-25T10:00:00.0000000+00:00\",\"items\":[{\"definition\":\"{\\\"Format\\\":\\\"Domenia.Query/1\\\",\\\"Id\\\":\\\"personal.reference.example\\\",\\\"Name\\\":\\\"Postes fictifs\\\",\\\"Junction\\\":\\\"All\\\",\\\"Clauses\\\":[]}\",\"category\":\"Exemple fictif\",\"description\":\"Alias | ; +33 ; O'Brian ; -12.34\"}]}",
  "sha256": "3f227f32cfe4141d3d6550461f2d94b6c8cbaf146c6f25b24aee249aade4d283"
}
```

## Preuves, atomicité et interruption

Le document de bibliothèque passe au format interne **3**, avec un registre de 512 reçus maximum, conservé par les écritures ordinaires. Un ancien binaire lisant ce document doit le garder en lecture seule. Le quota refuse une nouvelle écriture ; il ne supprime aucun reçu pour faire de la place. Les reçus contiennent ID, version et SHA du patch, SHA du document précédent (ou absence explicite), date et nombres créés/remplacés/ignorés.

Pour SQLite, le document complet antérieur est conservé et relu dans `domenia_v2_query_library_archive`. Original, nouveau document et reçu sont couverts par la transaction locale ; le reçu est relu après commit. Limites des archives : 512 entrées et 128 Mio. La sauvegarde physique SQLite existante reste distincte de cette copie du document métier. La durée de l’aperçu est revérifiée immédiatement avant publication, y compris après une préparation longue. L’annulation avant commit annule cette transaction ; après commit, la relecture de preuve ne reprend pas le jeton annulé de l’appelant.

Pour le support fichier local, les parents sont épinglés par des handles sans partage Delete ; les fichiers sont ouverts avec `OPEN_REPARSE_POINT` et leur type est contrôlé sur le handle. Une absence doit provenir de l’ouverture native, jamais d’un `File.Exists` qui aurait suivi un lien. Les écritures préparées et preuves sont privées dès leur création (DACL protégée utilisateur courant/SYSTEM/Administrateurs) et utilisent `CreateNew` et `Flush(true)`. Le remplacement conserve le fichier **réellement déplacé**, puis vérifie ses octets contre l’aperçu. Une intention durable précède le remplacement ; un marqueur de vérification est écrit uniquement après relecture. Chaque lecture de référence requalifie ces preuves, y compris après redémarrage. Une interruption, une preuve manquante ou un écrivain non coopératif peut laisser une transaction non confirmée : elle bloque les applications suivantes, conserve les fichiers `.reference-*` et nécessite une réconciliation explicite. Aucun rollback, nettoyage ou replay automatique. Le mutex ne prétend pas bloquer les écrivains non coopératifs. Limites : 128 transactions, 512 artefacts et 128 Mio ; les quotas incluent les préparations interrompues.

Ne supprimer aucune archive ni intention pour contourner un refus. La restauration de la bibliothèque ou d’une base complète suit son propre aperçu et ses vérifications ; elle ne doit pas écraser aveuglément les corrections plus récentes.

## Validation et limites de livraison

`QueryReferencePatchTests.cs` et `ReferencePatchScopeTests.cs` couvrent le codec strict et les valeurs exactes, la sauvegarde SQLite réelle relue après redémarrage, l’idempotence après correction locale, les IDs/liens, le CAS intégral, l’annulation à la frontière du commit, les versions/domaines/expirations, le refus de démonstration par pont et service, la conservation du fichier effectivement déplacé lors d’une concurrence injectée, l’expiration atteinte à la frontière du commit, les handles de lecture, le scénario fictif par le vrai pont et la lecture explicite du dossier avec double contrôle SHA/CAS. Dix-huit méthodes de test sont écrites. Les tests sont écrits, **non exécutés à ce stade** ; compilation et tests critiques sont orchestrés séparément sur Windows par le pilote de livraison. Aucun accès SMB, AD ou opération VM n’a été effectué pour développer ce lot. Un succès de compilation ne constitue pas une recette native ou SMB.
