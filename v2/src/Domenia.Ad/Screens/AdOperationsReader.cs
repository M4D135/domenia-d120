using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Native operation history and explicitly resumed, durable workstation collections.</summary>
public sealed partial class AdOperationsReader(AdDirectorySource source) : IOperationsReader, IOperationsCollectionRecorder, IOperationsConfirmedResume, IDisposable
{
    private readonly SemaphoreSlim saving = new(1, 1);
    private readonly Lock gate = new();
    private SurveyState? current;
    private string? activeId;
    private long activeEpoch;
    private string? postponed;
    private SurveyOffer? lastOffer;
    private CancellationTokenSource? resumedStop;
    private IDisposable? collectionLease;
    private bool disposed;
    private IOperationsLocalStore Store => source.LocalStore as IOperationsLocalStore ?? throw Unavailable("Magasin local des relevés indisponible ; aucune collecte durable lancée.");
    private EngineContext Context => source.AccountContext ?? throw Unavailable("Contexte de collecte indisponible.");
    private DateTimeOffset Now => source.Clock.GetUtcNow();
    private static DomeniaOperationException Unavailable(string text) => new(DomeniaErrors.SourceUnavailable, text);
    private static DomeniaOperationException Changed() => new("operations.surveyChanged", "Le relevé ou sa progression a changé ; relisez l’offre avant de confirmer.");
    private void CurrentEpoch() { if (source.Epoch != activeEpoch) { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Session modifiée ; relevé arrêté sans nouvelle cible."); } }
    public string CollectionProfile
    {
        get
        {
            System.Text.Json.JsonElement? stored = null;
            if (source.AccountContext is { } context && context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var value)) { stored = value; }
            var settings = CollectionSettingsRules.Read(stored, []);
            return "Profil de collecte : " + CollectionSettingsRules.Profile(settings.Profile).Label + ". Fenêtre : " +
                (CollectionSettingsRules.WindowText(settings) is { Length: > 0 } window ? window : "à tout moment") + ". Reprise uniquement après confirmation.";
        }
    }
    public async Task<CollectionRunsView> RunsAsync(CancellationToken cancellationToken)
    {
        if (source.LocalStore is not IOperationsLocalStore store)
        { return new(Now, false, [], CurrentSurvey(), null, "Aucun relevé en cours.", "Journal local indisponible ; aucun historique inventé."); }
        var read = await store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false); OperationsPersistence.Validate(read);
        var running = CurrentSurvey();
        var offer = Offer(read); lock (gate) { lastOffer = offer; }
        var rows = read.Runs.GroupBy(r => (r.Family, Dn: r.ScopeDn.ToUpperInvariant(), r.Subtree)).Select(g => g.MaxBy(r => r.AttemptAt)!).OrderByDescending(r => r.AttemptAt).Select(Row).ToImmutableArray();
        var note = "";
        if (source.AccountContext is { } context && source.KnownDomain is not null)
        {
            try
            {
                var home = await Domenia.Core.Accueil.AccueilService.From(context).CollectionsAsync(cancellationToken).ConfigureAwait(false);
                rows = [.. rows.Concat(home.Rows.Select(r => new OperationsCollectionRunRow(
                    ((OperationsCollectionFamily)r.Family) + ":" + r.OuDn.ToLowerInvariant() + ":" + r.Subtree,
                    (OperationsCollectionFamily)r.Family, r.Type, r.Ou, r.OuDn, r.At, (OperationsCollectionStatus)r.Status, r.StateLabel,
                    r.Status == Domenia.Core.Accueil.CollectionStatus.Success ? Tone.Ok : Tone.Warn, r.Postes, r.Success, r.Reason ?? "")))
                    .GroupBy(r => r.Id, StringComparer.Ordinal).Select(g => g.MaxBy(r => r.AttemptAt)!).OrderByDescending(r => r.AttemptAt)];
            }
            catch (DomeniaOperationException ex) when (ex.Code is DomeniaErrors.ScopeTooWide or AdErrors.NotConnected)
            { note = " Historique Accueil non chargé : sélectionnez une OU de travail."; }
        }
        return new(Now, true, rows, running, offer, running is { Open: true } ? running.Status : "Aucun relevé en cours.",
            "Progression enregistrée avant chaque reprise. Les postes déjà traités ne sont pas rejoués ; une mesure illisible reste inconnue." + note);
    }
    public SurveyState? CurrentSurvey() { lock (gate) { return current; } }
    private SurveyOffer? Offer(OperationsLocalState state)
    {
        if (state.Survey is not { } survey) { return null; }
        var left = survey.Targets.Length - survey.Completed.Length;
        var active = CurrentSurvey() is { Open: true };
        return new(!active && left > 0, left, survey.Targets.Length, Family(survey.Mode), SearchSurvey.ModeLabel(survey.Mode), survey.Scope.Label, survey.Scope.Dn,
            survey.UpdatedAt, active ? "Relevé en cours ; aucune seconde reprise possible." : FrenchText.Count(left, "poste restant", "postes restants") + ". Les identités AD et le périmètre seront revérifiés avant chaque lecture.", postponed == survey.Id)
        { ResumeToken = survey.Id + ":" + state.Revision.ToString(System.Globalization.CultureInfo.InvariantCulture) };
    }
    public Task<SurveyState> ResumeSurveyAsync(int remaining, CancellationToken cancellationToken) => throw Changed();
    public async Task<SurveyState> ResumeSurveyAsync(int remaining, string token, CancellationToken cancellationToken)
    {
        await saving.WaitAsync(cancellationToken).ConfigureAwait(false);
        IDisposable? acquired = null;
        try
        {
            lock (gate) { ObjectDisposedException.ThrowIf(disposed, this); if (current is { Open: true }) { throw new DomeniaOperationException("operations.surveyBusy", "Un relevé est déjà en cours."); } }
            acquired = await Store.AcquireOperationsLeaseAsync(cancellationToken).ConfigureAwait(false);
            var state = await Store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false); OperationsPersistence.Validate(state);
            var offer = Offer(state); var survey = state.Survey;
            if (survey is null || offer is not { Resumable: true } || remaining != offer.Remaining || token != offer.ResumeToken) { throw Changed(); }
            // The durable claim increments the revision before starting any probe. Concurrent confirmations lose their CAS.
            var next = state with { Revision = state.Revision + 1, Survey = survey with { Interrupted = false, UpdatedAt = Now } };
            await Store.UpdateOperationsAsync(state.Revision, next, cancellationToken).ConfigureAwait(false);
            lock (gate)
            {
                collectionLease = acquired; acquired = null;
                activeId = survey.Id; activeEpoch = source.Epoch; postponed = survey.Id;
                resumedStop = new CancellationTokenSource(); current = State(next.Survey!, true);
                _ = RunRemainingAsync(next.Survey!, resumedStop.Token);
                return current;
            }
        }
        finally { acquired?.Dispose(); saving.Release(); }
    }
    public SurveyState? StopSurvey()
    {
        lock (gate)
        {
            if (current is not { Open: true } state) { return current; }
            if (resumedStop is not null) { resumedStop.Cancel(); } else if (source.AccountContext is { } context) { SearchService.From(context).Stop(state.Id); }
            return current = state with { StopRequested = true, Phase = SurveyPhase.Stopping, PhaseLabel = "Arrêt demandé", Status = "Arrêt demandé ; les mesures terminées restent enregistrées." };
        }
    }
    public async Task<SurveyOffer?> ForgetSurveyAsync(CancellationToken cancellationToken)
    {
        await saving.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (gate) { if (current is { Open: true }) { throw new DomeniaOperationException("operations.surveyBusy", "Arrêtez le relevé avant de l’abandonner."); } }
            using var exclusive = await Store.AcquireOperationsLeaseAsync(cancellationToken).ConfigureAwait(false);
            var before = await Store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
            if (before.Survey is null) { return null; }
            await Store.UpdateOperationsAsync(before.Revision, before with { Revision = before.Revision + 1, Survey = null }, cancellationToken).ConfigureAwait(false);
            lock (gate) { current = null; activeId = null; } return null;
        }
        finally { saving.Release(); }
    }
    public SurveyOffer? PostponeSurvey() { lock (gate) { postponed = lastOffer?.ResumeToken?.Split(':')[0]; return lastOffer = lastOffer is null ? null : lastOffer with { Offered = true }; } }
    public Task<ImmutableArray<ProviderState>> ProviderStatesAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(source.AccountContext is { } context ? AccountAccess.From(context).PausedProviderStates() : ImmutableArray<ProviderState>.Empty);
    }
    public async Task<ImmutableArray<OperationSample>> HistoryAsync(CancellationToken cancellationToken)
    {
        if (source.LocalStore is not IOperationsLocalStore store) { return []; }
        var samples = (await store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false)).Samples;
        var currentKeys = source.AccountContext is { } context
            ? OperationActivity.From(context).Samples().Select(s => (s.Operation, s.At, s.DurationMs)).ToHashSet() : [];
        return [.. samples.Where(s => !currentKeys.Contains((s.Operation, s.At, s.DurationMs))).Select(s => s with { Session = false })];
    }
    public Task<ImmutableArray<CheckRow>> CheckDirectoryAsync(bool full, CancellationToken cancellationToken) => new AdDirectoryChecks(source).CheckDirectoryAsync(full, cancellationToken);
    private static OperationsCollectionFamily Family(SurveyMode mode) => mode == SurveyMode.Ping ? OperationsCollectionFamily.Presence : OperationsCollectionFamily.Inventory;
    private static OperationsCollectionRunRow Row(OperationsCollectionRun r) => new(r.Family + ":" + r.ScopeDn.ToLowerInvariant() + ":" + r.Subtree,
        r.Family, r.Family == OperationsCollectionFamily.Directory ? "Objets AD" : r.Family == OperationsCollectionFamily.Presence ? "Ping" : "WMI", r.ScopeName + (r.Subtree ? " et sous-OU" : ""), r.ScopeDn,
        r.AttemptAt, r.Status, r.Status switch { OperationsCollectionStatus.Success => "réussi", OperationsCollectionStatus.Partial => "partiel", OperationsCollectionStatus.Cancelled => "arrêté", _ => "en échec" },
        r.Status == OperationsCollectionStatus.Success ? Tone.Ok : r.Status == OperationsCollectionStatus.Cancelled ? Tone.Off : Tone.Warn,
        r.Done is { } done ? done + (r.Targets is { } total ? "/" + total : "") + " traités" + (r.Failed is > 0 ? ", " + r.Failed + " non confirmés" : "") : "Non mesuré", r.SuccessAt, r.Reason ?? "");
    private static SurveyState State(OperationsSurveyCheckpoint s, bool open) => new(s.Id, Family(s.Mode), SearchSurvey.ModeLabel(s.Mode), s.Scope.Dn, s.Scope.Label,
        s.Targets.Length, s.Completed.Length, s.Failed, open ? SurveyPhase.Running : SurveyPhase.Done, open ? "En cours" : "Terminé", open, false, s.StartedAt, open ? null : s.UpdatedAt,
        s.Completed.Length + "/" + s.Targets.Length + " postes traités ; " + s.Failed + " lectures non confirmées.");
    public void Dispose()
    {
        lock (gate) { if (disposed) { return; } disposed = true; resumedStop?.Cancel(); }
        // The running collection owns its CTS until its native reads and durable completion have ended.
    }
}
