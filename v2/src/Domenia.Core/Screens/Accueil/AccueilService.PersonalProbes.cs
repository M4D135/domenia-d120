using System.Collections.Immutable;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed record PersonalProbeView(string Key, string Id, string Name, string Category, string Fingerprint, string Document, ProbeContract Contract);
public sealed record PersonalProbeCatalogView(string ChoiceToken, int Capacity, bool Persistent, ImmutableArray<PersonalProbeView> Entries);
public sealed record PersonalProbeCandidate(string Key, string Id, string Name, string Category, string Fingerprint, bool Existing, ProbeContract Contract);
public sealed record PersonalProbePreview(string ChoiceToken, string DocumentSha256, int AddedCount, int ExistingCount, int TotalCount, int Capacity,
    ImmutableArray<PersonalProbeCandidate> Candidates, ImmutableArray<string> Warnings);
public sealed record PersonalProbeReceipt(bool ReadBack, bool Persistent, string Text);
public sealed record PersonalProbeSaved(PersonalProbeCatalogView Catalog, int AddedCount, PersonalProbeReceipt Receipt);

public sealed partial class AccueilService
{
    private async Task<PersonalProbeSnapshot> PersonalProbesAsync(CancellationToken token)
    {
        try { return await ProfileProbeCatalog.ReadAsync(context.Preferences, token).ConfigureAwait(false); }
        catch (DomeniaOperationException ex) when (ex.Code == "probes.invalid")
        {
            context.Log.Warning("Catalogue de sondes du profil refusé : contrat invalide. Original conservé ; aucune collecte.");
            throw;
        }
    }

    private ImmutableArray<FrozenProbe> ImportPersonalProbes(string document)
    {
        try { return PersonalProbeCatalog.Import(document); }
        catch (DomeniaOperationException ex) when (ex.Code == "probes.invalid")
        {
            // Record the refusal only at the user-facing boundary; never copy untrusted declarations or values.
            context.Log.Warning("Import de sondes refusé : contrat invalide. Aucun changement ni collecte.");
            throw;
        }
    }

    public async Task<PersonalProbeCatalogView> PersonalProbeCatalogAsync(CancellationToken token) =>
        PersonalProbeViewOf(await PersonalProbesAsync(token).ConfigureAwait(false));

    private PersonalProbeCatalogView PersonalProbeViewOf(PersonalProbeSnapshot snapshot) =>
        new(snapshot.ChoiceToken, PersonalProbeCatalog.Capacity, context.Preferences.Persistent,
            [.. snapshot.Entries.Select(p => new PersonalProbeView(p.Key, p.Definition.Id, p.Definition.Name, p.Definition.Category,
                p.Key[7..], PersonalProbeCatalog.Export(p), ProbeCatalog.Contract(p.Definition)))]);

    public async Task<PersonalProbePreview> PreviewPersonalProbesAsync(string document, string expectedChoiceToken, CancellationToken token)
    {
        var current = await PersonalProbesAsync(token).ConfigureAwait(false);
        PersonalProbeCatalog.RequireChoice(current, expectedChoiceToken);
        var entries = ImportPersonalProbes(document);
        var next = PersonalProbeCatalog.Read(PersonalProbeCatalog.Merge(current, entries));
        var existing = current.Entries.Select(p => p.Key).ToHashSet(StringComparer.Ordinal);
        var added = next.Entries.Length - current.Entries.Length;
        return new(current.ChoiceToken, PersonalProbeCatalog.TextHash(document), added, entries.Length - added, next.Entries.Length,
            PersonalProbeCatalog.Capacity,
            [.. entries.Select(p => new PersonalProbeCandidate(p.Key, p.Definition.Id, p.Definition.Name, p.Definition.Category, p.Key[7..],
                existing.Contains(p.Key), ProbeCatalog.Contract(p.Definition)))],
            ["Aucune collecte à l’import. Chaque sonde conserve sa collecte explicite et l’exclusion des contrôleurs.",
             "Toutes les versions antérieures sont conservées. Une modification crée une autre clé ; les widgets existants gardent leur définition exacte."]);
    }

    public async Task<PersonalProbeSaved> ApplyPersonalProbesAsync(string document, string expectedChoiceToken, string expectedDocumentSha256, CancellationToken token)
    {
        var entries = ImportPersonalProbes(document);
        if (PersonalProbeCatalog.TextHash(document) != expectedDocumentSha256)
        { throw new DomeniaOperationException("probes.changed", "Le document a changé depuis son aperçu ; aucune modification."); }
        if (context.Preferences is not IAtomicPreferenceStore atomic)
        { throw new DomeniaOperationException("probes.invalid", "Enregistrement atomique du catalogue indisponible pour ce profil."); }
        var added = 0;
        await atomic.UpdateAsync(PersonalProbeCatalog.PreferenceKey, value =>
        {
            var current = PersonalProbeCatalog.Read(value);
            PersonalProbeCatalog.RequireChoice(current, expectedChoiceToken);
            var existing = current.Entries.Select(p => p.Key).ToHashSet(StringComparer.Ordinal);
            added = entries.Count(p => !existing.Contains(p.Key));
            return added == 0 ? value : PersonalProbeCatalog.Merge(current, entries);
        }, token).ConfigureAwait(false);
        var readBack = await PersonalProbesAsync(token).ConfigureAwait(false);
        if (entries.Any(p => readBack.Find(p.Key) is null))
        { throw new DomeniaOperationException("probes.changed", "Le catalogue enregistré a changé avant sa relecture ; aucun succès annoncé."); }
        return new(PersonalProbeViewOf(readBack), added, new(true, context.Preferences.Persistent,
            context.Preferences.Persistent ? "Catalogue du profil enregistré et relu. Aucun widget réaffecté, aucune collecte lancée."
                : "Catalogue relu dans cette session isolée, sans écriture sur disque. Aucun widget réaffecté, aucune collecte lancée."));
    }

    public async Task<ProbeContract> ProbeLatestAsync(string key, CancellationToken token)
    {
        var snapshot = await PersonalProbesAsync(token).ConfigureAwait(false);
        var probe = snapshot.Find(key) ?? throw new DomeniaOperationException("probe.unknown", "Définition de sonde absente de ce profil : rien n’a été lu.");
        return ProbeCatalog.Contract(probe.Definition);
    }

    private Task<ImmutableArray<FrozenProbe>> FrozenProbesAsync(IEnumerable<string> keys, CancellationToken token) =>
        ProfileProbeCatalog.ResolveAsync(context.Preferences, keys, token);

    private Task ConfirmFrozenProbesAsync(ImmutableArray<FrozenProbe> definitions, CancellationToken token) =>
        ProfileProbeCatalog.ConfirmAsync(context.Preferences, definitions, token);

    private async Task<ProbeReadings> CollectFrozenProbesAsync(ImmutableArray<FrozenProbe> definitions, ScopeSelection scope,
        IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long epoch, CancellationToken token, bool retryFailures = false)
    {
        await ConfirmFrozenProbesAsync(definitions, token).ConfigureAwait(false);
        var result = retryFailures && Reader is IAccueilProbeRetryReader retry
            ? await retry.RetryFrozenProbesAsync(definitions, scope, targets, epoch, token).ConfigureAwait(false)
            : await Reader.CollectFrozenProbesAsync(definitions, scope, targets, epoch, token).ConfigureAwait(false);
        await ConfirmFrozenProbesAsync(definitions, token).ConfigureAwait(false);
        return result;
    }
}
