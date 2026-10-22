Implémente la décision de David du 22/10 pour l'écran « Utilisateurs et postes » (relations) : la mémorisation des
observations (consoles relevées, détection, moisson du journal du contrôleur : REL-014, REL-017, REL-018, REL-030) passe
par UN plan collectif scellé par le moteur (TRV-229), exactement sur le modèle des lots de l'écran Comptes
(`AccountsBatchSeals`, opérations `accounts.batch.preview` / `accounts.batch.confirm` / `accounts.batch.plan`, page
`comptes/batch.js` : fichiers fournis) : une seule confirmation pour toutes les observations en attente d'un résultat,
puis le moteur délivre un plan par lot de 64 (une seule fois par lot), que la page exécute à la suite par `write.execute`,
un reçu et une relecture par lot, sans redemander de confirmation.

À produire (fichiers complets) :
1. `v2/src/Domenia.Core/Screens/Relations/RelationBatchSeals.cs` : sceau d'un lot d'observations (sur le modèle de
   `AccountsBatchSeals`) : `Seal(resultId, keys ordonnées, now)` → `{ id (32 hexadécimaux), fingerprint (SHA-256 de
   « resultId|nombre|clé,clé,… »), count, batches (= ceil(count/64)), typedRequired (vrai dès 2 lots), expiresAt (10 min,
   glissant), confirmed }` ; `Confirm(id, typedCount)` (nombre d'observations revérifié quand exigé ; faux nombre → le sceau
   est dépensé, code `relations.batchCountMismatch`) ; `Next(id, index)` → les clés du lot `index` (0 à batches-1), une seule
   fois par lot (`relations.batchIssued`), refus si non confirmé (`relations.batchUnconfirmed`), inconnu
   (`relations.batchUnknown`), expiré (`relations.batchExpired`). Instance par session : `EngineContext.Shared(...)` comme
   le fait AccountsBatchSeals. Messages en français, codes dans une classe de constantes.
2. `v2/src/Domenia.Bridge/Operations/RelationsBatchOperations.cs` : `public sealed class RelationsBatchOperations :
   IOperationModule` (écran « relations », `Screen => "relations"`) avec trois opérations :
   - `relations.observations.batch.preview` (LocalRead) `{ resultId }` : lit les observations en attente de ce résultat
     comme le fait `relations.observations.pending` / `relations.observations.plan` (lecteur `IRelationsReader`, voir
     `RelationsOperations.cs` fourni : réutilise les mêmes appels), scelle leurs clés et renvoie `{ batch, count, batches,
     typedRequired, typedCount, shown (12 premières lignes : utilisateur, poste, source, date), origin }` ;
   - `relations.observations.batch.confirm` (Local) `{ id, typedCount? }` ;
   - `relations.observations.batch.plan` (LocalRead) `{ id, index }` : délivre le plan du lot en appelant la même logique que
     `relations.observations.plan` avec les clés explicites du lot (`keys`) et renvoie `{ plan, token }` comme elle.
   Arguments lus avec `BridgeArguments` (fourni par l'usage dans RelationsOperations.cs).
3. `v2/web/js/pages/relations/batch.js` : `export async function saveSealed(ctx, { resultId, origin, onProgress })` :
   aperçu scellé (`relations.observations.batch.preview`), confirmation du kit `confirmWrite` (importée de
   `../../kit/index.js` comme dans comptes/batch.js : saisie du nombre quand `typedRequired`), `batch.confirm`, puis pour
   chaque lot `batch.plan` → `write.execute { planId, token, typedName: null }` (exactement comme comptes/batch.js), arrêt au
   premier refus (rien n'est rejoué), `onProgress({ done, total, receipt })` après chaque lot ; renvoie le nombre de lots
   enregistrés. Textes en français avec espaces insécables (`NBSP` de `../../kit/util.js`).
4. Dans `v2/web/js/pages/relations.js`, NE réécris pas le fichier : décris dans NOTES le remplacement exact à faire dans
   `saveBatches` (fourni) pour appeler `saveSealed` quand `all` est vrai.
5. Ajoute aussi les trois opérations au tableau `SimulationOperations` : décris-les dans NOTES (nom et classe).
