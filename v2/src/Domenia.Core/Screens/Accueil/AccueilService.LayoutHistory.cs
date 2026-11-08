using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core.Accueil;

public sealed partial class AccueilService
{
    public static void ValidateStoredLayout(JsonElement value) =>
        _ = BoardLayoutHistory.Read(value, FleetCatalog.DefaultLayout(), NormalizeStoredLayout);

    public FleetLayoutView Layout() => LayoutView(context.Preferences.TryGet(LayoutPreference, out var value) ? value : null);

    public async Task<FleetLayoutView> LayoutLatestAsync(CancellationToken token) => context.Preferences is IAtomicPreferenceStore atomic
        ? LayoutView(await atomic.ReadLatestAsync(LayoutPreference, token).ConfigureAwait(false)) : Layout();

    private FleetLayoutView LayoutView(JsonElement? value)
    {
        FleetLayoutView view;
        try
        {
            var state = BoardLayoutHistory.Read(value, FleetCatalog.DefaultLayout(), NormalizeStoredLayout);
            view = new(state.Items, !FleetCatalog.IsDefault(state.Items), FleetCatalog.MaxItems) { ChoiceToken = state.ChoiceToken, History = state.History };
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException)
        {
            view = new([], true, FleetCatalog.MaxItems) { Valid = false, Reason = "Disposition ou historique incompatible conservé. Aucun remplacement automatique.",
                ChoiceToken = BoardLayoutHistory.ChoiceToken(value) };
        }
        lock (gate) { layout = view.Items; }
        return view;
    }

    private static ImmutableArray<FleetLayoutItem> NormalizeStoredLayout(IReadOnlyList<FleetLayoutItem> items)
    {
        if (items.Count > FleetCatalog.MaxItems || items.Any(i => i is null || i.Key is null || i.Title is { Length: > FleetCatalog.MaxTitleLength }
            || i.Title?.Any(char.IsControl) == true || i.Group is { Length: > 80 } || i.Group?.Any(char.IsControl) == true || i.Height is not (null or "S" or "M" or "L")))
            throw new InvalidDataException("Au plus 64 cartes valides ; aucune troncature.");
        foreach (var item in items)
            if (item.QueryBinding is not null && (item.Source != FleetWidgetSource.Query || !BoardQueryBindings.Valid(item.QueryBinding, item.Key)))
                throw new InvalidDataException("Liaison de requête illisible ; aucune disposition remplacée.");
        var clean = Clean(items);
        if (clean.Length != items.Count) throw new InvalidDataException("Une carte n’a plus de représentation dans le parc ; disposition entière conservée.");
        return clean;
    }

    public async Task<FleetLayoutView> SaveLayoutAsync(IReadOnlyList<FleetLayoutItem> items, CancellationToken token, string? expectedChoiceToken = null, Func<CancellationToken, IDisposable>? qualify = null)
    {
        ArgumentNullException.ThrowIfNull(items);
        var normalized = NormalizeStoredLayout(items);
        var personal = await PersonalProbesAsync(token).ConfigureAwait(false);
        RequirePersonalLayoutDefinitions(normalized, personal);
        normalized = [.. normalized.Select(item => item.Source == FleetWidgetSource.Probe && PersonalProbeCatalog.IsKey(item.Key)
            ? item with { Visual = ProbeCatalog.Visuals(personal.Find(item.Key)!.Definition) is { } visuals && visuals.Contains(item.Visual, StringComparer.Ordinal) ? item.Visual
                : ProbeCatalog.Visuals(personal.Find(item.Key)!.Definition)[0] } : item)];
        return await ChangeLayoutAsync(current =>
        {
            BoardLayoutHistory.RequireChoice(current, expectedChoiceToken);
            return BoardLayoutHistory.Next(current, normalized, FleetCatalog.DefaultLayout(), NormalizeStoredLayout, Now);
        }, token, qualify).ConfigureAwait(false);
    }

    public async Task<FleetLayoutView> ResetLayoutAsync(string? preset, CancellationToken token, string? expectedChoiceToken = null)
    {
        if (preset is not null && FleetCatalog.Presets.All(p => p.Id != preset))
            throw new DomeniaOperationException("layout.preset", "Disposition prédéfinie inconnue : rien n’a été changé.");
        var current = await LayoutLatestAsync(token).ConfigureAwait(false);
        if (!current.Valid) throw new InvalidDataException(current.Reason);
        var items = preset is null ? FleetCatalog.DefaultLayout() : FleetCatalog.ApplyPreset(preset, current.Items);
        return await SaveLayoutAsync(items, token, expectedChoiceToken ?? current.ChoiceToken).ConfigureAwait(false);
    }

    public async Task<FleetLayoutView> RestoreLayoutAsync(string versionId, string expectedChoiceToken, CancellationToken token)
    {
        var personal = await PersonalProbesAsync(token).ConfigureAwait(false);
        return await ChangeLayoutAsync(current =>
        {
            var restored = BoardLayoutHistory.Restore(current, versionId, expectedChoiceToken, FleetCatalog.DefaultLayout(), NormalizeStoredLayout, Now);
            RequirePersonalLayoutDefinitions(BoardLayoutHistory.Read(restored, FleetCatalog.DefaultLayout(), NormalizeStoredLayout).Items, personal);
            return restored;
        }, token).ConfigureAwait(false);
    }

    private static void RequirePersonalLayoutDefinitions(IEnumerable<FleetLayoutItem> items, PersonalProbeSnapshot personal)
    {
        _ = personal.Resolve(items.Where(item => item.Source == FleetWidgetSource.Probe && PersonalProbeCatalog.IsKey(item.Key)).Select(item => item.Key).Distinct());
    }

    private async Task<FleetLayoutView> ChangeLayoutAsync(Func<JsonElement?, JsonElement?> update, CancellationToken token, Func<CancellationToken, IDisposable>? qualify = null)
    {
        if (context.Preferences is not IAtomicPreferenceStore atomic) throw new InvalidDataException("Enregistrement atomique de la disposition indisponible.");
        IDisposable? sourceLease = null;
        try
        {
            var saved = await atomic.UpdateAsync(LayoutPreference, current =>
            {
                sourceLease = qualify?.Invoke(token);
                return update(current);
            }, token).ConfigureAwait(false);
            lock (gate) { localWriteFailures = 0; }
            return LayoutView(saved); // No optimistic presentation is installed before durable success.
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            lock (gate) { localWriteFailures++; }
            context.Log.Warning("Disposition du parc non enregistrée : " + ex.GetType().Name + ". Choix précédent conservé.");
            throw;
        }
        finally { sourceLease?.Dispose(); }
    }
}
