using System.Collections.Immutable;
using System.Security.Cryptography;

namespace Domenia.Core.Queries;

public sealed partial class QueryLibrary
{
    private sealed record ReferenceExamination(QueryImportPlan Plan, QueryReferencePatch Patch, string BeforeSha256, string RootKey, QueryReferenceAccess Access);
    private readonly Dictionary<string, ReferenceExamination> referenceExaminations = new(StringComparer.Ordinal);
    private const int MaxReferenceReceipts = 512;
    private static string ReferenceHash(byte[]? bytes) => bytes is null ? "absent" : QueryReferenceCodec.Hash(bytes);
    private static bool ValidReferenceReceipt(QueryReferenceReceipt receipt) => receipt.Id is { Length: 32 }
        && receipt.Id.All(char.IsAsciiHexDigitLower) && receipt.PatchId is { Length: 32 } && receipt.PatchId.All(char.IsAsciiHexDigitLower)
        && receipt.Version is >= 1 and <= 1_000_000 && QueryReferenceCodec.IsHash(receipt.Sha256)
        && (receipt.BeforeSha256 == "absent" || QueryReferenceCodec.IsHash(receipt.BeforeSha256))
        && receipt.AppliedAt > DateTimeOffset.UnixEpoch
        && receipt.Created is >= 0 and <= QueryReferenceCodec.MaxItems && receipt.Replaced is >= 0 and <= QueryReferenceCodec.MaxItems
        && receipt.Ignored is >= 0 and <= QueryReferenceCodec.MaxItems && (long)receipt.Created + receipt.Replaced + receipt.Ignored <= QueryReferenceCodec.MaxItems;

    private State ReferenceState(byte[]? bytes, string rootKey)
    {
        if (bytes is { Length: 0 } || (bytes?.Length ?? 0) > MaxDocumentBytes) { throw QueryReferenceCodec.Bad("Bibliothèque vide ou hors limites ; l’absence seule représente une bibliothèque neuve."); }
        ValidateReadEnvelope(bytes, rootKey);
        var state = Parse(bytes);
        if (state.Newer || state.WholeUnreadable || state.Unreadable.Count > 0 || state.ReferenceReceipts.Count > MaxReferenceReceipts)
        { throw QueryReferenceCodec.Bad("Bibliothèque illisible ou plus récente ; aucune application de patch possible."); }
        return state;
    }

    public async Task<QueryPackExport> ExportReferencePatchAsync(string rootDn, string name, long version, IReadOnlyCollection<string>? ids,
        QueryReferenceAccess access, CancellationToken token)
    {
        access.ValidateStore(store); var root = RootKey(rootDn);
        var bytes = await store.ReadReferenceAsync(root, token).ConfigureAwait(false); access.ValidateStore(store); token.ThrowIfCancellationRequested();
        var state = ReferenceState(bytes, root);
        var selected = state.Records.Where(r => !r.Archived && (ids is null || ids.Count == 0 || ids.Contains(r.Id))).OrderBy(r => r.Id, StringComparer.Ordinal).ToArray();
        if (ids is { Count: > 0 } && (ids.Distinct(StringComparer.Ordinal).Count() != ids.Count || selected.Length != ids.Count))
        { throw QueryReferenceCodec.Bad("Sélection d’export modifiée, archivée, absente ou dupliquée ; aucun patch incomplet préparé."); }
        var json = QueryReferenceCodec.Write(name, version, root, clock.GetUtcNow(), selected.Select(r => new QueryReferenceItem(r.Recipe, r.Category, r.Description)));
        return new(json, "Domenia-reference-" + WindowsRelease.Slug(name) + "-v" + version.ToString(System.Globalization.CultureInfo.InvariantCulture) + ".json",
            selected.Length, PackId(name), version, Math.Min(1_000_000, version + 1));
    }

    public async Task<QueryImportPlan> ExamineReferencePatchAsync(string rootDn, string text, QueryReferenceAccess access, CancellationToken token)
    {
        access.ValidateStore(store); var patch = QueryReferenceCodec.Read(text, clock.GetUtcNow()); var root = RootKey(rootDn);
        if (patch.DomainKey != root) { throw QueryReferenceCodec.Bad("Ce patch est destiné à un autre domaine ; aucun import inter-domaine implicite."); }
        var bytes = await store.ReadReferenceAsync(root, token).ConfigureAwait(false); access.ValidateStore(store); token.ThrowIfCancellationRequested();
        var state = ReferenceState(bytes, root); var previous = state.ReferenceReceipts.Where(r => r.PatchId == patch.Id).Select(r => r.Version).DefaultIfEmpty(0).Max();
        var applied = state.ReferenceReceipts.Any(r => r.Sha256 == patch.Sha256);
        if (!applied && previous >= patch.Version) { throw QueryReferenceCodec.Bad("Version de patch périmée ou réutilisée avec un autre contenu ; aucune modification."); }
        var items = patch.Items.Select(item =>
        {
            var current = state.Records.SingleOrDefault(r => r.Id == item.Recipe.Id);
            var identical = current is not null && !current.Archived && QueryRecipeJson.Write(current.Recipe) == QueryRecipeJson.Write(item.Recipe)
                && current.Category == item.Category && current.Description == item.Description;
            var status = applied || identical ? "identical" : current is null ? "new" : "conflict";
            var changes = QueryAnalysis.Compare(current?.Recipe, item.Recipe);
            var references = state.Widgets.Count(w => w.RecipeId == item.Recipe.Id) + state.Consumers.Count(w => w.RecipeId == item.Recipe.Id);
            return new QueryImportItem(item.Recipe.Id, item.Recipe.Name, status, status == "new" ? "Nouvelle" : status == "identical" ? "Identique / déjà traité" : "Conflit local",
                QueryAnalysis.ChangeSummary(changes, status == "new") + " Catégorie : « " + (current?.Category ?? "absente") + " » → « " + item.Category
                    + " ». Description : « " + (current?.Description ?? "absente") + " » → « " + item.Description + " ». " + references + " lien(s) conservé(s) à leur révision.",
                changes, status == "new" ? ["ignore", "create"] : status == "conflict" ? ["ignore", "replace"] : ["ignore"], "ignore", current?.Revision ?? 0);
        }).ToImmutableArray();
        var id = Guid.NewGuid().ToString("N");
        var plan = new QueryImportPlan(id, QueryReferenceCodec.Format, patch.Id, patch.Name, patch.Version, null, patch.CreatedAt.ToString("O"), true,
            "SHA-256 " + patch.Sha256 + " ; intégrité vérifiée, éditeur non authentifié.", previous, items, clock.GetUtcNow() + ExaminationLife)
        { ReferenceSha256 = patch.Sha256, AlreadyApplied = applied, Demonstration = access.Demonstration };
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            foreach (var key in referenceExaminations.Where(p => p.Value.Plan.ExpiresAt < clock.GetUtcNow()).Select(p => p.Key).ToArray()) { referenceExaminations.Remove(key); }
            if (referenceExaminations.Count >= 4) { throw QueryReferenceCodec.Bad("Quatre aperçus de patch sont encore ouverts ; fermez-en un ou attendez son expiration."); }
            referenceExaminations.Add(id, new(plan, patch, ReferenceHash(bytes), root, access));
        }
        finally { gate.Release(); }
        return plan;
    }

    public async Task<QueryReferenceResult> ApplyReferencePatchAsync(string rootDn, string examinationId, IReadOnlyDictionary<string, string> choices, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (!referenceExaminations.TryGetValue(examinationId, out var exam) || exam.RootKey != RootKey(rootDn) || exam.Plan.ExpiresAt < clock.GetUtcNow())
            { throw QueryReferenceCodec.Bad("Aperçu de patch absent ou expiré ; préparez un nouvel aperçu."); }
            void ValidateBeforePublication()
            {
                exam.Access.ValidateStore(store);
                if (clock.GetUtcNow() >= exam.Plan.ExpiresAt) { throw QueryReferenceCodec.Bad("Aperçu de patch expiré pendant la préparation ; aucune nouvelle publication autorisée."); }
            }
            using var sourceLease = exam.Access.Hold(store);
            if (clock.GetUtcNow() >= exam.Plan.ExpiresAt) { throw QueryReferenceCodec.Bad("Aperçu de patch expiré ; préparez un nouvel aperçu."); }
            token.ThrowIfCancellationRequested();
            if (choices.Keys.Any(id => !exam.Plan.Items.Any(i => i.Id == id))) { throw QueryReferenceCodec.Bad("Choix d’import inconnu."); }
            QueryReferenceReceipt? receipt = null; bool replay = false;
            var write = await store.UpdateAsync(exam.RootKey, before =>
            {
                ValidateBeforePublication(); token.ThrowIfCancellationRequested();
                var state = ReferenceState(before, exam.RootKey);
                receipt = state.ReferenceReceipts.SingleOrDefault(r => r.Sha256 == exam.Patch.Sha256);
                if (receipt is not null) { replay = true; return null; } // Never overwrite subsequent local corrections on replay.
                if (ReferenceHash(before) != exam.BeforeSha256) { throw QueryReferenceCodec.Bad("Bibliothèque modifiée depuis l’aperçu ; aucun patch appliqué."); }
                if (state.ReferenceReceipts.Count >= MaxReferenceReceipts) { throw QueryReferenceCodec.Bad("512 reçus de référence conservés ; nouvelle application refusée sans supprimer les preuves."); }
                int created = 0, replaced = 0, ignored = 0;
                foreach (var row in exam.Plan.Items)
                {
                    var action = choices.GetValueOrDefault(row.Id, "ignore");
                    if (!row.AllowedActions.Contains(action)) { throw QueryReferenceCodec.Bad("Choix non autorisé pour « " + row.Name + " »."); }
                    if (action == "ignore") { ignored++; continue; }
                    var item = exam.Patch.Items.Single(i => i.Recipe.Id == row.Id); var index = state.Records.FindIndex(r => r.Id == row.Id);
                    var current = index < 0 ? null : state.Records[index];
                    if ((current?.Revision ?? 0) != row.ExpectedRevision) { throw RevisionChanged(current?.Revision ?? 0); }
                    var provenance = new QueryProvenance(exam.Patch.Id, exam.Patch.Name, exam.Patch.Version, "Référence SHA-256 " + exam.Patch.Sha256, row.Id, QueryEngine.Compile(item.Recipe).Fingerprint, true);
                    var history = current is null ? [] : current.History.Insert(0, new QueryRevision(current.Revision, current.UpdatedAt, current.Fingerprint, QueryRecipeJson.Write(current.Recipe)) { Provenance = current.Provenance });
                    if (history.Length > MaxHistory) { throw QueryReferenceCodec.Bad("Historique plein ; aucun patch appliqué."); }
                    var record = new QueryLibraryRecord(row.Id, item.Recipe.Name, item.Category, item.Description, checked((current?.Revision ?? 0) + 1),
                        current?.CreatedAt ?? clock.GetUtcNow(), clock.GetUtcNow(), false, QueryEngine.Compile(item.Recipe).Fingerprint, item.Recipe, provenance, history, current?.ArchivedWidgets ?? []);
                    if (current is null) { state.Records.Add(record); created++; } else { state.Records[index] = record; replaced++; }
                }
                if (state.Records.Count > MaxRecipes) { throw QueryReferenceCodec.Bad("Bibliothèque pleine ; aucun patch appliqué."); }
                receipt = new(Guid.NewGuid().ToString("N"), exam.Patch.Id, exam.Patch.Version, exam.Patch.Sha256, ReferenceHash(before), clock.GetUtcNow(), created, replaced, ignored)
                { Simulated = exam.Access.Demonstration };
                state.ReferenceReceipts.Add(receipt); state.Generation++;
                var after = Fit(state, exam.RootKey, clock.GetUtcNow());
                ValidateBeforePublication(); token.ThrowIfCancellationRequested();
                return new QueryStoreUpdate(after, KeepPrevious: true) { ValidateContext = ValidateBeforePublication }; // Complete original document is retained by the store.
            }, token).ConfigureAwait(false);
            // Publication may already have happened: do not use the caller's cancelled token or claim "nothing written".
            bool verified;
            try
            {
                var reread = await store.ReadReferenceAsync(exam.RootKey, CancellationToken.None).ConfigureAwait(false);
                var proof = ReferenceState(reread, exam.RootKey).ReferenceReceipts.SingleOrDefault(r => r.Sha256 == exam.Patch.Sha256);
                exam.Access.ValidateStore(store);
                verified = receipt is not null && proof == receipt && (replay || write?.ReadBack == true);
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or QueryDefinitionException
                or DomeniaOperationException or ObjectDisposedException or OperationCanceledException)
            { verified = false; }
            referenceExaminations.Remove(examinationId); cache.Remove(exam.RootKey);
            if (receipt is null) { throw QueryReferenceCodec.Bad("Résultat du patch incertain ; relisez les preuves avant toute autre action."); }
            return new(receipt, replay, store.Persistent, verified, verified
                ? (exam.Access.Demonstration ? "Démonstration — données fictives. " : "") + (replay ? "Patch déjà traité : aucun nouvel effet, corrections locales conservées. " : "Patch et reçu relus ensemble ; original conservé. ") + "SHA-256 " + receipt.Sha256 + (store.Persistent ? "." : " ; stockage de session uniquement.")
                : "Résultat incertain : le reçu n’a pas été confirmé après écriture. Conservez les preuves et relisez la bibliothèque.");
        }
        finally { gate.Release(); }
    }

    public async Task<ImmutableArray<QueryReferenceReceipt>> ReferenceHistoryAsync(string rootDn, QueryReferenceAccess access, CancellationToken token)
    {
        access.ValidateStore(store); var bytes = await store.ReadReferenceAsync(RootKey(rootDn), token).ConfigureAwait(false); access.ValidateStore(store);
        return [.. ReferenceState(bytes, RootKey(rootDn)).ReferenceReceipts.OrderByDescending(r => r.AppliedAt)];
    }

    public async Task DiscardReferencePreviewAsync(string id, CancellationToken token)
    { await gate.WaitAsync(token).ConfigureAwait(false); try { referenceExaminations.Remove(id); } finally { gate.Release(); } }

    internal QueryReferenceAccess DemonstrationAccess(EngineContext context) => store is MemoryQueryLibraryStore memory
        ? QueryReferenceAccess.DemonstrationOnly(context, memory) : throw QueryReferenceCodec.Bad("Le scénario de patch fictif exige une bibliothèque en mémoire ; aucun fichier réel n’est utilisé.");

    public async Task<bool> IsDemonstrationReferencePreviewAsync(string id, CancellationToken token)
    { await gate.WaitAsync(token).ConfigureAwait(false); try { return referenceExaminations.TryGetValue(id, out var exam) && exam.Access.Demonstration; } finally { gate.Release(); } }
}
