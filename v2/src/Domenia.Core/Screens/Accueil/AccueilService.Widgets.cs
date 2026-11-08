using System.Collections.Immutable;
using System.Security.Cryptography;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed record HomeWidgetPlan(string Id, string WidgetId, string Title, string Kind, ScopeSelection Scope, int Targets, int Fresh,
    bool ConfirmationRequired, string Detail, DateTimeOffset ExpiresAt);
public sealed record HomeWidgetActivity(string Id, string WidgetId, string Title, string Phase, int Done, int Total, int Fresh, int Failed, string Detail);
public sealed record HomeWidgetResult(string Id, int Done, int Fresh, int Failed, string Detail);

public sealed partial class AccueilService
{
    private sealed class WidgetWork(HomeWidgetPlan plan, FleetLayoutItem item, RefreshTargets targets, RefreshQueryWork? queries, FrozenProbe? probe)
    {
        public HomeWidgetPlan Plan { get; } = plan;
        public FleetLayoutItem Item { get; } = item;
        public RefreshTargets Targets { get; } = targets;
        public RefreshQueryWork? Queries { get; } = queries;
        public FrozenProbe? Probe { get; } = probe;
        public CancellationTokenSource? Stop { get; set; }
        public string? DirectoryRefreshId { get; set; }
        public string Phase { get; set; } = "queued";
        public bool Confirmed { get; set; }
        public int Done { get; set; }
        public int Fresh { get; set; } = plan.Fresh;
        public int Failed { get; set; }
        public string Detail { get; set; } = "En file : démarre après la collecte et le recalcul en cours.";
    }

    private readonly Dictionary<string, WidgetWork> widgetPlans = new(StringComparer.Ordinal);
    private readonly List<WidgetWork> widgetQueue = [];
    private WidgetWork? widgetActive;
    private int boardComputations;

    private static string WidgetKind(FleetLayoutItem item) => item.Source switch
    {
        FleetWidgetSource.Probe => "probe",
        FleetWidgetSource.Query => "query",
        _ => item.Key switch
        {
            "fleet.bitlocker" => "bitlocker",
            "fleet.presence" or "fleet.lastcheck" => "presence",
            "fleet.users" => "console",
            "fleet.wmi" or "fleet.reach" or "fleet.models" or "fleet.releases" or "fleet.ram" or "fleet.diskfree" or "fleet.lowdisk" or "fleet.uptime"
                or "fleet.health" or "fleet.attention" => "inventory",
            _ when item.Key.StartsWith("fleet.trend", StringComparison.Ordinal) => "local",
            _ when FleetCatalog.TryGet(item.Key, out _) => "directory",
            _ => throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Source du widget inconnue ; aucune collecte."),
        },
    };

    public async Task<HomeWidgetPlan> PlanWidgetCollectionAsync(string widgetId, string gesture, CancellationToken token)
    {
        if (gesture is not ("add" or "refresh" or "resume"))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Geste de collecte du widget invalide."); }
        var item = LayoutItems().SingleOrDefault(i => i.Id == widgetId)
            ?? throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Widget absent de la disposition enregistrée.");
        if (item.Hidden) { throw new DomeniaOperationException("widget.hidden", "Widget masqué ; affichez-le avant de préparer sa collecte."); }
        if (item.Paused) { throw new DomeniaOperationException("widget.paused", "Widget suspendu ; reprenez sa mesure avant toute collecte."); }
        var probe = item.Source == FleetWidgetSource.Probe ? (await FrozenProbesAsync([item.Key], token).ConfigureAwait(false)).Single() : null;
        var (_, scope, domain) = await ScopeAsync(token).ConfigureAwait(false);
        ScopeRules.EnsureNotDomainRoot(scope, domain);
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var inScope = local.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).ToArray();
        var active = probe?.Definition.SkipOnDc == true ? inScope.Where(c => (c.UserAccountControl & AdValues.ServerTrustAccount) == 0).ToArray() : inScope;
        var excludedControllers = inScope.Length - active.Length;
        var targets = await FreezeRefreshTargetsAsync(active, token).ConfigureAwait(false);
        var kind = WidgetKind(item);
        if ((kind is "directory" or "bitlocker") && await WidgetScopeFreshAsync(kind, scope, token).ConfigureAwait(false)) { kind = "local"; }
        var health = item.Source == FleetWidgetSource.Builtin && item.Key is FleetCatalog.Health or FleetCatalog.Attention;
        var queries = kind == "query" || health ? await PrepareQueryRefreshAsync(health ? [] : [item], local, scope, domain, token, includeHealth: health).ConfigureAwait(false) : null;
        var missing = await MissingWidgetTargetsAsync(item, kind, targets, queries, probe, scope, token).ConfigureAwait(false);
        var settings = CollectionSettingsRules.Read(context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var value) ? value : null, []);
        CollectionAdmission.EnsureTargets(settings, missing.Count, widget: true);
        targets = targets with { Identities = targets.Identities.Where(p => missing.Contains(p.Key)).ToImmutableDictionary() };
        if (queries is not null) { queries = queries with { Identities = targets.Identities }; }
        var title = item.Title ?? probe?.Definition.Name
            ?? (FleetCatalog.TryGet(item.Key, out var definition) ? definition.Title : "Widget de requête");
        var detail = kind switch
        {
            "directory" => "Lecture AD de l’OU et enregistrement après sauvegarde vérifiée ; aucun poste interrogé.",
            "bitlocker" => "Présence des objets de récupération de cette OU, sans lecture des clés.",
            "presence" => "Un ping par poste sans mesure récente ; aucune lecture WMI.",
            "probe" => "Ping puis seulement la sonde de ce widget sur les postes qui répondent."
                + (excludedControllers > 0 ? " " + FrenchText.Integer(excludedControllers) + " contrôleurs exclus ; aucune mesure ni fraîcheur déduite pour eux." : ""),
            "console" => "Ping puis utilisateur console des seuls postes qui répondent.",
            "query" => "Ping puis seules les informations manquantes de la révision de requête mémorisée.",
            "local" => "Recalcul depuis les données locales ; aucune lecture réseau.",
            _ => "Ping puis inventaire léger des seuls postes sans mesure récente et qui répondent.",
        };
        detail += " " + CollectionAdmission.Notice(settings, context.Clock);
        var plan = new HomeWidgetPlan(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), item.Id, title, kind, scope, missing.Count,
            active.Length - missing.Count, gesture != "add" || !CollectionAdmission.Window(settings, context.Clock).Open || missing.Count > 200 || probe?.Definition.Slow == true || kind is "directory" or "bitlocker", detail, Now + PlanLifetime);
        lock (gate)
        {
            foreach (var old in widgetPlans.Where(p => p.Value.Plan.ExpiresAt < Now).Select(p => p.Key).ToArray()) { widgetPlans.Remove(old); }
            if (widgetPlans.Count >= 64) { throw new DomeniaOperationException("widget.plansFull", "Trop de préparations en attente ; fermez les anciennes confirmations."); }
            widgetPlans.Add(plan.Id, new(plan, item, targets, queries, probe));
        }
        return plan;
    }

    private async Task<bool> WidgetScopeFreshAsync(string kind, ScopeSelection scope, CancellationToken token)
    {
        var policy = CollectionCachePolicy.Read(context.Preferences);
        var since = policy.Since("attributes", Now);
        if (kind == "bitlocker")
        {
            var reading = StoredBitLocker(await Reader.FactsAsync(token).ConfigureAwait(false), scope);
            return reading is { Truncated: false } && reading.At >= since && reading.At <= Now;
        }
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var covered = local.Directory.Coverage is { } coverage && (ScopeRules.SameScope(coverage, scope)
            || coverage.Subtree && ScopeRules.Contains(coverage, scope.Dn));
        return local.Directory.Complete && covered && local.Directory.ReadAt >= since && local.Directory.ReadAt <= Now;
    }

    private async Task<HashSet<Guid>> MissingWidgetTargetsAsync(FleetLayoutItem item, string kind, RefreshTargets targets, RefreshQueryWork? queries, FrozenProbe? probe,
        ScopeSelection scope, CancellationToken token)
    {
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var settings = CollectionSettingsRules.Read(context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var storedSettings) ? storedSettings : null, []);
        var policy = new CollectionCachePolicy(settings);
        var freshness = CollectionSettingsRules.FreshnessTable(settings).ToDictionary(f => f.Family, f => f.Seconds);
        HashSet<Guid>? selected = null;
        IEnumerable<Guid> QueryMissing(FrozenFleetQuery query, QueryDataset data) => QueryRefreshRules.MissingTargetIds(query, data, scope,
            targets.Identities, selected ??= targets.Identities.Keys.ToHashSet(), Now, policy.ReuseMinutes, token, freshness);
        var since = policy.Since("attributes", Now);
        if (kind == "local") { return []; }
        if (kind == "directory")
        {
            var covered = local.Directory.Coverage is { } coverage && (ScopeRules.SameScope(coverage, scope)
                || coverage.Subtree && ScopeRules.Contains(coverage, scope.Dn));
            return local.Directory.Complete && covered && local.Directory.ReadAt >= since && local.Directory.ReadAt <= Now
                ? [] : targets.Identities.Keys.ToHashSet();
        }
        if (kind == "bitlocker")
        {
            var facts = await Reader.FactsAsync(token).ConfigureAwait(false);
            var read = StoredBitLocker(facts, scope);
            return read is { Truncated: false } && read.At >= since && read.At <= Now ? [] : targets.Identities.Keys.ToHashSet();
        }
        var rows = local.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        if (kind == "presence")
        {
            // A definitive answer about the name within the window is as fresh as a reading: asking again changes nothing.
            since = policy.Since("presence", Now);
            return targets.Identities.Keys.Where(id => !rows.TryGetValue(id, out var row) || !PresenceOutcomes.Settled(row.Presence, since, Now)).ToHashSet();
        }
        if (kind == "probe")
        {
            var readings = await Reader.StoredProbesAsync(token).ConfigureAwait(false);
            var skipDc = probe?.Definition.SkipOnDc == true;
            return targets.Identities.Where(p => !(skipDc && (p.Value.UserAccountControl & AdValues.ServerTrustAccount) != 0)
                && !policy.Probe(item.Key, readings.ByProbe.GetValueOrDefault(item.Key)?.GetValueOrDefault(p.Key), p.Value, Now)).Select(p => p.Key).ToHashSet();
        }
        if (kind is "console" or "query")
        {
            var reader = context.Readers.Require<IQueryWorkshopReader>();
            var data = await reader.DatasetAsync(token).ConfigureAwait(false);
            if (kind == "console")
            { since = policy.Since("console", Now); return targets.Identities.Keys.Where(id => !data.Console.TryGetValue(id, out var row) || row.Error is not null || row.ObservedAt is null || row.ObservedAt < since || row.ObservedAt > Now).ToHashSet(); }
            if (queries is null) { return []; }
            return queries.Queries.SelectMany(q => QueryMissing(q, data)).ToHashSet();
        }
        var missing = targets.Identities.Keys.Where(id => !rows.TryGetValue(id, out var row) || !policy.Inventory(row.Inventory, Now)).ToHashSet();
        if (queries is not null)
        {
            var data = await context.Readers.Require<IQueryWorkshopReader>().DatasetAsync(token).ConfigureAwait(false);
            missing.UnionWith(queries.Queries.SelectMany(q => QueryMissing(q, data)));
        }
        return missing;
    }

    public async Task<HomeWidgetResult> RunWidgetCollectionAsync(string planId, bool confirmed, CancellationToken token)
    {
        WidgetWork work;
        lock (gate)
        {
            if (!widgetPlans.Remove(planId, out work!)) { throw new DomeniaOperationException(RefreshPlanUnknown, RefreshPlanUnknownMessage); }
            if (work.Plan.ConfirmationRequired && !confirmed) { throw new DomeniaOperationException("widget.confirmation", "Confirmez le nombre de postes avant cette collecte."); }
            if (widgetQueue.Count + (widgetActive is null ? 0 : 1) >= 20) { throw new DomeniaOperationException("widget.queueFull", "La file contient déjà 20 widgets ; retirez une demande ou attendez."); }
            if (widgetActive?.Item.Id == work.Item.Id || widgetQueue.Any(w => w.Item.Id == work.Item.Id))
            { throw new DomeniaOperationException("widget.duplicate", "Ce widget est déjà en collecte ou en file."); }
            work.Confirmed = confirmed;
            work.Stop = CancellationTokenSource.CreateLinkedTokenSource(token);
            widgetQueue.Add(work);
        }
        var stop = work.Stop ?? throw new InvalidOperationException("Widget cancellation is absent.");
        var retainedForDraw = false;
        try
        {
            while (true)
            {
                stop.Token.ThrowIfCancellationRequested();
                await ConfirmWidgetAsync(work, stop.Token).ConfigureAwait(false);
                lock (gate)
                {
                    if (widgetActive is null && widgetQueue.FirstOrDefault() == work && run is null && pendingRefreshDraw is null && !bitLockerReading && dashboard.Measuring == 0 && boardComputations == 0)
                    { widgetQueue.Remove(work); widgetActive = work; work.Phase = "planning"; work.Detail = "Vérification des mesures déjà enregistrées."; break; }
                }
                await Task.Delay(TimeSpan.FromMilliseconds(250), context.Clock, stop.Token).ConfigureAwait(false);
            }
            IDisposable? admission = null;
            try
            {
                // The OU directory pipeline already takes this same admission through its durable recorder.
                if (work.Plan.Kind != "directory" && context.Readers.Find<IHomeWidgetAdmission>() is { } owner)
                {
                    while (admission is null)
                    {
                        await ConfirmWidgetAsync(work, stop.Token).ConfigureAwait(false);
                        try { admission = await owner.AcquireHomeWidgetAdmissionAsync(stop.Token).ConfigureAwait(false); }
                        catch (DomeniaOperationException ex) when (ex.Code == "operations.surveyBusy")
                        { await Task.Delay(TimeSpan.FromSeconds(1), context.Clock, stop.Token).ConfigureAwait(false); }
                    }
                }
                await ExecuteWidgetAsync(work, stop.Token).ConfigureAwait(false);
            }
            finally { admission?.Dispose(); }
            await ConfirmWidgetAsync(work, stop.Token, checkExpiry: false).ConfigureAwait(false);
            SetWidgetProgress(work, "drawing", "Mesures enregistrées ; recalcul et dessin du tableau en attente.");
            retainedForDraw = true;
            return new(work.Plan.Id, work.Done, work.Fresh, work.Failed, work.Failed > 0 ? "Collecte partielle ; les mesures confirmées restent conservées." : "Collecte terminée ; les mesures confirmées sont enregistrées.");
        }
        finally
        {
            CancellationTokenSource[] abandon = [];
            lock (gate)
            {
                widgetQueue.Remove(work);
                if (!retainedForDraw && ReferenceEquals(widgetActive, work))
                {
                    // An interrupted collector can already have committed a partial payload. Do not advance its
                    // followers against the previous picture without a final draw acknowledgment.
                    abandon = [.. widgetQueue.Select(w => w.Stop).OfType<CancellationTokenSource>()];
                    widgetQueue.Clear();
                    widgetActive = null;
                }
                work.Stop = null;
            }
            foreach (var queued in abandon)
            {
                try { queued.Cancel(); }
                catch (ObjectDisposedException) { /* The queued work ended meanwhile. */ }
            }
            stop.Dispose();
        }
    }

    private async Task ConfirmWidgetAsync(WidgetWork work, CancellationToken token, bool checkExpiry = true)
    {
        var settings = CollectionAdmission.Read(context.Preferences);
        CollectionAdmission.EnsureTargets(settings, work.Plan.Targets, widget: true);
        if (work.Plan.Kind != "local" && !work.Confirmed && !CollectionAdmission.Window(settings, context.Clock).Open)
            throw new DomeniaOperationException("widget.confirmation", "La fenêtre est fermée ; préparez une nouvelle demande et confirmez sa collecte.");
        if (checkExpiry && Now > work.Plan.ExpiresAt) { throw new DomeniaOperationException(RefreshPlanExpired, "La demande de widget a expiré dans la file ; préparez une nouvelle collecte."); }
        var (_, scope, domain) = await ScopeAsync(token).ConfigureAwait(false);
        var current = LayoutItems().SingleOrDefault(i => i.Id == work.Item.Id);
        if (!ScopeRules.SameScope(scope, work.Plan.Scope) || current is null || current.Paused || current.Hidden || current.Source != work.Item.Source || current.Key != work.Item.Key || current.QueryBinding != work.Item.QueryBinding)
        { throw new DomeniaOperationException(RefreshScopeChanged, "OU ou widget modifié depuis la demande ; collecte abandonnée."); }
        await ConfirmRefreshTargetsAsync(work.Targets, token).ConfigureAwait(false);
        if (work.Probe is { } probe) { await ConfirmFrozenProbesAsync([probe], token).ConfigureAwait(false); }
        if (work.Queries is { } queries)
        {
            await ConfirmRefreshQueryStoreAsync(queries, token).ConfigureAwait(false);
            var content = await queryLibrary!.ReadAsync(domain, token).ConfigureAwait(false);
            foreach (var query in queries.Queries)
            {
                QueryRefreshRules.Confirm(content, query, domain);
                await QueryPersonalProbes.ConfirmAsync(QueryEngine.Compile(query.Recipe), context.Preferences, token).ConfigureAwait(false);
            }
        }
    }

    private async Task ExecuteWidgetAsync(WidgetWork work, CancellationToken token)
    {
        await EnsureAdmittedAsync(token).ConfigureAwait(false);
        var allowUnanswered = CollectionNetworkPolicy.Read(context.Preferences);
        using var networkPolicy = CollectionNetworkPolicy.Enter(allowUnanswered);
        var missing = await MissingWidgetTargetsAsync(work.Item, work.Plan.Kind, work.Targets, work.Queries, work.Probe, work.Plan.Scope, token).ConfigureAwait(false);
        lock (gate) { work.Fresh += work.Targets.Identities.Count - missing.Count; }
        if (work.Plan.Kind == "local" || missing.Count == 0 && work.Plan.Kind is not ("directory" or "bitlocker")) { return; }
        if (work.Plan.Kind == "directory")
        {
            if (await WidgetScopeFreshAsync("directory", work.Plan.Scope, token).ConfigureAwait(false)) { return; }
            if (context.Readers.Find<IHomeCampaignRecorder>() is { } durable && (await durable.ReadHomeCampaignAsync(token).ConfigureAwait(false)).Plan is not null)
            { throw new DomeniaOperationException("widget.durablePending", "Une actualisation interrompue est conservée ; reprenez-la avant la lecture AD du widget."); }
            SetWidgetProgress(work, "directory", "Lecture AD de l’OU avec sauvegarde et reçu local.");
            var plan = await PlanRefreshAsync("directory", token).ConfigureAwait(false);
            lock (gate) { work.DirectoryRefreshId = plan.Id; }
            var report = await RunRefreshAsync(plan.Id, false, _ => { }, token).ConfigureAwait(false);
            lock (gate) { work.Done = missing.Count; if (report.Status != "success") { work.Failed = missing.Count; } }
            return;
        }
        if (work.Plan.Kind == "bitlocker")
        {
            if (await WidgetScopeFreshAsync("bitlocker", work.Plan.Scope, token).ConfigureAwait(false)) { return; }
            SetWidgetProgress(work, "bitlocker", "Lecture de la présence des objets de récupération, sans les clés.");
            var result = await ReadBitLockerAsync(token, work.Plan.Id).ConfigureAwait(false);
            lock (gate) { work.Done = missing.Count; if (result.Truncated) { work.Failed = missing.Count; } }
            return;
        }
        foreach (var group in missing.Order().Chunk(32))
        {
            await ConfirmWidgetAsync(work, token, checkExpiry: false).ConfigureAwait(false);
            var expected = group.ToImmutableDictionary(id => id, id => work.Targets.Identities[id]);
            SetWidgetProgress(work, "presence", "Vérification réseau des postes sans mesure récente ; les chiffres restent ceux du dernier relevé.");
            var began = Now;
            var measured = await dashboard.MeasureAsync((_, t) => Reader.ReadPresenceAsync(work.Plan.Scope, expected, work.Targets.Epoch, t), token).ConfigureAwait(false);
            var online = expected.Keys.Where(id => measured.Observations.Find(id) is { } row
                && CollectionNetworkPolicy.Eligible(row.Presence, allowUnanswered) && row.Presence.CheckedAt >= began).ToHashSet();
            var failed = group.ToHashSet();
            failed.ExceptWith(work.Plan.Kind == "presence"
                ? expected.Keys.Where(id => measured.Observations.Find(id) is { } row && PresenceOutcomes.Settled(row.Presence, began))
                : online);
            if (online.Count > 0 && work.Plan.Kind == "inventory")
            {
                var before = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
                var policy = CollectionCachePolicy.Read(context.Preferences);
                var inventoryTargets = expected.Where(p => online.Contains(p.Key) && !policy.Inventory(before.Observations.Find(p.Key)?.Inventory, Now)).ToImmutableDictionary();
                if (!inventoryTargets.IsEmpty)
                {
                    SetWidgetProgress(work, "inventory", "Lecture de l’inventaire léger des postes admissibles.");
                    var read = await dashboard.MeasureAsync((_, t) => Reader.ReadInventoryAsync(work.Plan.Scope, inventoryTargets, work.Targets.Epoch, t), token).ConfigureAwait(false);
                    failed.UnionWith(inventoryTargets.Keys.Where(id => read.Observations.Find(id) is not { } row || !row.Inventory.HasReading || row.Inventory.CheckedAt < began));
                }
            }
            else if (online.Count > 0 && work.Plan.Kind == "probe")
            {
                SetWidgetProgress(work, "probe", "Lecture de la sonde mémorisée du widget.");
                var read = await CollectFrozenProbesAsync([work.Probe ?? throw new InvalidOperationException("Définition de sonde non figée.")], work.Plan.Scope,
                    expected.Where(p => online.Contains(p.Key)).ToImmutableDictionary(), work.Targets.Epoch, token, retryFailures: true).ConfigureAwait(false);
                lock (gate) { probes = probes.Merge(read); }
                failed.UnionWith(online.Where(id => !RefreshRules.ProbeAnswered(read.ByProbe.GetValueOrDefault(work.Item.Key)?.GetValueOrDefault(id), began, Now)));
            }
            else if (online.Count > 0 && work.Plan.Kind == "console")
            {
                SetWidgetProgress(work, "console", "Lecture des utilisateurs de console.");
                var reader = context.Readers.Require<IQueryWorkshopReader>();
                await reader.MeasureAsync(new([.. online], false, true, false, [])
                { ExpectedIdentities = expected, ExpectedEpoch = work.Targets.Epoch, OwnsCampaign = true }, token).ConfigureAwait(false);
                var data = await reader.DatasetAsync(token).ConfigureAwait(false);
                failed.UnionWith(online.Where(id => !data.Console.TryGetValue(id, out var row) || row.Error is not null || row.ObservedAt is null || row.ObservedAt < began || row.ObservedAt > Now));
            }
            if (online.Count > 0 && work.Queries is { } queries)
            {
                SetWidgetProgress(work, "query", "Lecture des informations manquantes des requêtes mémorisées.");
                var reader = context.Readers.Require<IQueryWorkshopReader>();
                var querySettings = CollectionSettingsRules.Read(context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var queryJson) ? queryJson : null, []);
                var freshness = CollectionSettingsRules.FreshnessTable(querySettings).ToDictionary(f => f.Family, f => f.Seconds);
                foreach (var query in queries.Queries)
                {
                    await ConfirmWidgetAsync(work, token, checkExpiry: false).ConfigureAwait(false);
                    var dataset = await reader.DatasetAsync(token).ConfigureAwait(false);
                    foreach (var request in QueryRefreshRules.Queue(query, dataset, work.Plan.Scope, expected, online, Now, false,
                        querySettings.Budgets.GetValueOrDefault(CollectionSettingsRules.CacheMinutes, 15), token, freshness))
                    {
                        await ProfileProbeCatalog.ConfirmAsync(context.Preferences, request.PersonalProbes, token).ConfigureAwait(false);
                        var result = await reader.MeasureAsync(request with { ExpectedEpoch = work.Targets.Epoch, OwnsCampaign = true }, token).ConfigureAwait(false);
                        if (result.Failed + result.SkippedDisabled > 0) { failed.UnionWith(request.Computers); }
                    }
                }
            }
            lock (gate) { work.Done += group.Length; work.Failed += failed.Count; latest = null; }
        }
    }

    private void SetWidgetProgress(WidgetWork work, string phase, string detail)
    { lock (gate) { work.Phase = phase; work.Detail = detail; } }

    public async Task<ImmutableArray<HomeWidgetActivity>> WidgetCollectionStateAsync(CancellationToken token)
    {
        var (session, scope, _) = await ScopeAsync(token).ConfigureAwait(false);
        lock (gate)
        {
            return [.. (widgetActive is null ? widgetQueue : widgetQueue.Prepend(widgetActive))
                .Where(w => w.Targets.Epoch == session.Epoch && ScopeRules.SameScope(w.Plan.Scope, scope))
                .Select(w => new HomeWidgetActivity(w.Plan.Id, w.Item.Id, w.Plan.Title, w.Phase, w.Done, w.Plan.Targets, w.Fresh, w.Failed, w.Detail))];
        }
    }

    public void AcknowledgeWidgetDraw(string id)
    { lock (gate) { if (widgetActive?.Plan.Id == id && widgetActive.Phase == "drawing") { widgetActive = null; } } }

    public bool CancelWidgetCollection(string id)
    {
        CancellationTokenSource? cancellation;
        CancellationTokenSource[] abandon = [];
        lock (gate)
        {
            var item = widgetActive?.Plan.Id == id ? widgetActive : widgetQueue.FirstOrDefault(w => w.Plan.Id == id);
            if (item is null) { return widgetPlans.Remove(id); }
            cancellation = item.Stop;
            if (item.Phase == "drawing")
            {
                // No following request may start against figures whose final draw was not acknowledged.
                abandon = [.. widgetQueue.Select(w => w.Stop).OfType<CancellationTokenSource>()];
                widgetQueue.Clear();
                widgetActive = null;
            }
        }
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException) { /* The same work finished meanwhile. */ }
        foreach (var stop in abandon)
        {
            try { stop.Cancel(); }
            catch (ObjectDisposedException) { /* The queued work finished meanwhile. */ }
        }
        return true;
    }

    private void StopWidgetsForDispose()
    {
        string[] ids;
        lock (gate) { ids = [.. widgetQueue.Select(w => w.Plan.Id), .. (widgetActive is null ? Array.Empty<string>() : new[] { widgetActive.Plan.Id })]; widgetPlans.Clear(); }
        foreach (var id in ids) { CancelWidgetCollection(id); }
    }

    /// <summary>Only requests cancellation. The bridge retains each running task through its durable finalization.</summary>
    public void StopForHost()
    {
        StopRefresh();
        StopWidgetsForDispose();
    }
}
