using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;
using QueryComputerIdentity = Domenia.Core.Queries.QueryComputerIdentity;

namespace Domenia.Core.Accueil;

/// <summary>
/// Explicit refresh of the working OU (Domenia 1, Domenia-Refresh.UI.ps1, ACC-001 to ACC-008): a plan frozen at the click (OU,
/// workstations, stages, probe plan of the active widgets), confirmed once, run once; the AD read is followed by its storage
/// receipt before any workstation is contacted; ping then WMI of the workstations that answered only. Since 26/10, a failed
/// or partial AD prerequisite stops this chain. A separate explicit presence/inventory plan can use the retained cache.
/// « Arrêter » keeps what was already recorded.
/// </summary>
public sealed partial class AccueilService
{
    public const string RefreshRunning = "refresh.running";
    public const string RefreshRunningMessage = "Une actualisation de l’OU est déjà en cours : attendez sa fin ou arrêtez-la.";
    public const string RefreshPlanUnknown = "refresh.planUnknown";
    public const string RefreshPlanUnknownMessage = "Plan d’actualisation inconnu ou déjà utilisé : préparez de nouveau l’actualisation. Rien n’a été lancé.";
    public const string RefreshPlanExpired = "refresh.planExpired";
    public const string RefreshPlanExpiredMessage = "Plan d’actualisation expiré (plus de 5 min) : préparez de nouveau l’actualisation. Rien n’a été lancé.";
    public const string RefreshScopeChanged = "refresh.scopeChanged";
    public const string RefreshScopeChangedMessage = "L’OU de travail a changé depuis le plan : préparez de nouveau l’actualisation. Rien n’a été lancé.";
    public const string RefreshQueryMissing = "refresh.queryMissing";
    public const string RefreshQueryMissingMessage = "Un widget de requête est absent de la bibliothèque : retirez-le ou mettez-le en pause avant de lancer le relevé WMI. Rien n’a été lancé.";

    private static readonly TimeSpan PlanLifetime = TimeSpan.FromMinutes(5);

    private readonly Dictionary<string, RefreshPlan> plans = new(StringComparer.Ordinal);
    private RunState? run;
    private RefreshReport? lastReport;
    private string? pendingRefreshDraw;

    private sealed class RunState(RefreshPlan plan, CancellationTokenSource cancellation)
    {
        public RefreshPlan Plan { get; } = plan;
        public CancellationTokenSource Cancellation { get; } = cancellation;
        // The run is named by its plan: a plan runs once (« jamais rejoué »), its report and its progress carry the same id.
        public string Id { get; } = plan.Id;
        public DateTimeOffset StartedAt { get; init; }
        public List<RefreshStageResult> Stages { get; } = [];
        public List<CollectionRunRow> Runs { get; } = [];
        public bool Stopping { get; set; }
        public string? StopReason { get; set; }
        public bool Forced { get; init; }
        public IHomeCampaignLease? Durable { get; set; }
        public DateTimeOffset? PresenceStartedAt { get; set; }
        public DateTimeOffset? InventoryStartedAt { get; set; }
        public bool DurableFinished { get; set; }
        public bool DirectoryTargetsPending { get; set; }
        public ImmutableArray<FrozenProbe> FrozenProbes { get; init; } = [];
        public required RefreshPerformance Performance { get; init; }
        public ImmutableArray<RefreshBranch> Branches { get; set; } = [];
    }

    public const string RefreshBackupUnavailable = "refresh.backupUnavailable";
    public const string RefreshBackupUnavailableMessage = "Sauvegarde vérifiée de la base locale indisponible dans cette version" + FrenchText.Colon
        + "la relecture AD de l’OU est refusée (aucune lecture AD sans sauvegarde vérifiée). Ping et WMI restent possibles. Rien n’a été lancé.";
    public const string RefreshNothingToResume = "refresh.nothingToResume";
    public const string RefreshNothingToResumeMessage = "Aucune actualisation interrompue à reprendre pour cette OU" + FrenchText.Colon + "lancez une actualisation complète.";

    private Func<long?>? storageProbe;
    private bool bitLockerReading;
    private int localWriteFailures;

    /// <summary>
    /// Modes of the refresh: « directory » (base locale de l’OU), « presence » (ping), « inventory » (ping puis WMI), « all », and
    /// « resume » (the stages an interrupted refresh of the same OU did not finish, improvement of ACC-001).
    /// </summary>
    public static ImmutableArray<string> RefreshModes { get; } = ["directory", "presence", "inventory", "all", "resume"];

    /// <summary>
    /// Free space of the volume that holds the data of Domenia, measured by the host (Domenia.App) just before a refresh: new
    /// collections stop under 512 Mio in directory mode (ACC-001). Without a probe nothing is blocked and nothing is claimed.
    /// </summary>
    public void UseStorageProbe(Func<long?> probe)
    {
        ArgumentNullException.ThrowIfNull(probe);
        lock (gate)
        {
            storageProbe = probe;
        }
    }

    /// <summary>accueil.refresh.plan: the plan of one mode, frozen now, valid 5 minutes (LocalRead: nothing is contacted).</summary>
    public async Task<RefreshPlan> PlanRefreshAsync(string mode, CancellationToken cancellationToken, ImmutableArray<ScopeSelection> branches = default)
    {
        if (!RefreshModes.Contains(mode, StringComparer.Ordinal))
        {
            throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Arguments invalides" + FrenchText.Colon + FrenchText.Quote("mode") + " doit valoir directory, presence, inventory, all ou resume.");
        }
        var (_, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        branches = CampaignBranches.Validate(scope, branches);
        // An explicit OU inside the domain, never the root (Get-DomeniaOuRefreshContext).
        ScopeRules.EnsureNotDomainRoot(scope, domainDn);
        RefreshReport? previous;
        lock (gate)
        {
            if (run is not null)
            {
                throw new DomeniaOperationException(RefreshRunning, RefreshRunningMessage);
            }
            previous = lastReport;
        }
        await EnsureAdmittedAsync(cancellationToken).ConfigureAwait(false);
        var simulation = context.Directory.Kind == DirectorySourceKind.Simulation;
        var now = Now;
        var offered = context.Readers.Find<IHomeCampaignRecorder>() is { } recorder
            ? await recorder.ReadHomeCampaignAsync(cancellationToken).ConfigureAwait(false) : null;
        var saved = mode == "resume" ? offered?.Plan : null;
        if (mode == "resume" && offered is not null && saved is null)
        { throw new DomeniaOperationException(RefreshNothingToResume, RefreshNothingToResumeMessage); }
        if (saved is not null)
        {
            HomeCampaignRules.Validate(saved, (await Reader.FactsAsync(cancellationToken).ConfigureAwait(false)).StoreId, domainDn);
            previous = HomeReport(saved);
        }
        // Stages wanted: from the mode, or from what the interrupted refresh did not finish.
        bool wantDirectory;
        bool wantPresence;
        bool wantInventory;
        string? resumeOf = null;
        DateTimeOffset? onlineSince = null;
        var cachePolicy = CollectionCachePolicy.Read(context.Preferences);
        var reuseSince = (DateTimeOffset?)cachePolicy.Since("inventory", now);
        if (mode == "resume")
        {
            if (previous is not { Resumable: true } || !ScopeRules.SameScope(previous.Scope, scope))
            {
                throw new DomeniaOperationException(RefreshNothingToResume, RefreshNothingToResumeMessage);
            }
            var unfinished = previous.Stages.Where(st => st.State is not ("done" or "na")).Select(st => st.Id).ToHashSet(StringComparer.Ordinal);
            wantDirectory = unfinished.Contains("backup") || unfinished.Contains("directory") || unfinished.Contains("commit");
            wantPresence = unfinished.Contains("presence");
            wantInventory = unfinished.Contains("inventory") || unfinished.Contains("queries");
            if (!wantDirectory && !wantPresence && !wantInventory)
            {
                throw new DomeniaOperationException(RefreshNothingToResume, RefreshNothingToResumeMessage);
            }
            resumeOf = previous.Id;
            // WMI of a resume relies on the ping of the interrupted refresh when it does not ping again.
            if (wantInventory && !wantPresence)
            {
                onlineSince = previous.Stages.FirstOrDefault(st => st.Id == "presence" && st.State == "done")?.StartedAt ?? previous.StartedAt;
            }
            // A forced refresh stays forced: what it already read again since its start is kept, nothing older.
            if (previous.Forced)
            {
                reuseSince = previous.StartedAt;
            }
        }
        else
        {
            wantDirectory = mode is "directory" or "all";
            wantPresence = mode is "presence" or "inventory" or "all";
            wantInventory = mode is "inventory" or "all";
        }
        if (wantDirectory && !simulation && context.Directory is not IDirectoryRefreshPreparation { CanPrepareDirectoryRefresh: true })
        {
            // Domenia 1 (FI-13): a verified backup of the local base comes before every AD read; without it, no AD read.
            throw new DomeniaOperationException(RefreshBackupUnavailable, RefreshBackupUnavailableMessage);
        }
        var state = await context.Directory.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).ToList();
        var availableBranches = CampaignBranches.Summarize(scope, active.Select(QueryComputerIdentity.Of));
        if (saved is not null) { branches = saved.Branches; }
        var selectedBranch = HomeCampaignRules.BranchClassifier(scope, branches);
        active = active.Where(c => selectedBranch(c.DistinguishedName) >= 0).ToList();
        var frozenTargets = await FreezeRefreshTargetsAsync(active, cancellationToken).ConfigureAwait(false);
        if (saved is not null)
        {
            frozenTargets = frozenTargets with { Identities = saved.Targets.ToImmutableDictionary(t => t.Guid) };
            if (HomeTargetsProvisional(saved)) { await ConfirmRefreshContextAsync(frozenTargets, cancellationToken).ConfigureAwait(false); }
            else { await ConfirmRefreshTargetsAsync(frozenTargets, cancellationToken).ConfigureAwait(false); }
            await ConfirmHomeProgressAsync(saved, cancellationToken).ConfigureAwait(false);
            active = active.Where(c => frozenTargets.Identities.ContainsKey(c.ObjectGuid)).ToList();
            onlineSince = saved.PresenceStartedAt;
        }
        var allowUnanswered = saved?.ReadWithoutEcho ?? CollectionNetworkPolicy.Read(context.Preferences);
        var observations = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var onlineIds = active.Where(c => observations.TryGetValue(c.ObjectGuid, out var o) && CollectionNetworkPolicy.Eligible(o.Presence, allowUnanswered) && o.Presence.CheckedAt is not null
            && (onlineSince is null || o.Presence.CheckedAt >= onlineSince)).Select(c => c.ObjectGuid).ToList();
        var objects = state.Directory.Computers.Count(c => ScopeRules.Contains(scope, c.DistinguishedName)) + state.Directory.Users.Count(u => ScopeRules.Contains(scope, u.DistinguishedName))
            + state.Directory.Groups.Count(g => ScopeRules.Contains(scope, g.DistinguishedName)) + state.Directory.OrganizationalUnits.Count(o => ScopeRules.Contains(scope, o.DistinguishedName));
        var items = LayoutItems();
        var computerItems = ImmutableArray<FleetLayoutItem>.Empty;
        if (wantInventory && saved is null)
        {
            var computerLayout = await Domenia.Core.Poste.PosteBoardLayouts.ReadLatestAsync(context.Preferences, "Computer", cancellationToken).ConfigureAwait(false);
            if (!computerLayout.Valid) throw new DomeniaOperationException("refresh.layoutInvalid", "Disposition Poste illisible : aucun plan de collecte partiel. Corrigez la disposition avant de continuer.");
            computerItems = computerLayout.Items;
        }
        var memoryPolicies = saved?.MemoryPolicies ?? (wantInventory ? HomeMemoryPolicy.Freeze(HealthBook(domainDn), scope, now) : []);
        var memoryRequired = HomeMemoryPolicy.Resolver(memoryPolicies);
        var memoryFacts = wantInventory ? await Reader.FactsAsync(cancellationToken).ConfigureAwait(false) : null;
        var warnings = new List<string>();
        if (allowUnanswered) warnings.Add("Les postes sans réponse ICMP peuvent recevoir un essai WMI/WinRM borné si leur nom DNS est résolu. Une absence de réponse au ping ne sera pas présentée comme une présence confirmée.");
        var planSettings = CollectionSettingsRules.Read(context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var planSettingsJson) ? planSettingsJson : null, []);
        if (wantPresence || wantInventory) CollectionAdmission.EnsureTargets(planSettings, frozenTargets.Identities.Count);
        warnings.Add(CollectionAdmission.Notice(planSettings, context.Clock));
        var campaignBudget = CollectionCampaignBudget.For(wantDirectory && active.Count == 0 ? OperationsPersistence.MaxTargets : active.Count,
            planSettings.Budgets.GetValueOrDefault(CollectionSettingsRules.Concurrency, 4), planSettings.Budgets.GetValueOrDefault(CollectionSettingsRules.CampaignMinutes));
        warnings.Add("Durée maximale de cette tentative : " + SettingsFormat.Duration((int)campaignBudget.TotalSeconds)
            + ". Les résultats enregistrés restent disponibles à l’arrêt ; la reprise est explicite.");
        // Probe plan frozen at the click: the active probe widgets of the board (paused ones left out, decision of 14/10/2026).
        var probeIds = saved?.Probes ?? (wantInventory ? items.Concat(computerItems).Where(i => i.Source == FleetWidgetSource.Probe && !i.Paused && !i.Hidden).Select(i => i.Key).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToImmutableArray() : []);
        var frozenProbes = await FrozenProbesAsync(probeIds, cancellationToken).ConfigureAwait(false);
        var queryWork = saved is not null ? await RestoreHomeQueriesAsync(saved, frozenTargets, domainDn, cancellationToken).ConfigureAwait(false)
            : wantInventory ? await PrepareQueryRefreshAsync(items, state with { Directory = state.Directory with { Computers = [.. active] } }, scope, domainDn, cancellationToken, computerItems: computerItems).ConfigureAwait(false) : null;
        if (saved is null && offered?.Plan is { } interrupted)
        { warnings.Add("Cette nouvelle actualisation remplacera, après votre confirmation, la reprise conservée de l’OU " + interrupted.Scope.Label + ". Les mesures déjà enregistrées restent conservées."); }
        if (queryWork is not null)
        {
            CollectionAdmission.EnsureTargets(planSettings, queryWork.Identities.Count);
            warnings.Add(FleetBoardCalculator.Plural(queryWork.Queries.Length, "révision de requête figée", "révisions de requêtes figées")
                + " : après l’inventaire, lecture des informations manquantes (console, sondes ou SELECT bornés), uniquement sur les identités du plan admissibles selon la politique réseau. Durée bornée par les paramètres de campagne ; aucun second ping.");
            foreach (var query in queryWork.Queries)
            { warnings.Add(query.Recipe.Name + " · révision " + FrenchText.Integer(query.Revision) + " · empreinte " + query.Fingerprint[..12]); }
        }
        if (wantInventory && frozenProbes.Any(p => p.Definition.Slow && p.Definition.Origin != "Personnalisée"))
        {
            warnings.Add("Une sonde lente fait partie du plan" + FrenchText.Colon + "la collecte WMI sera plus longue.");
        }
        foreach (var personal in frozenProbes.Where(p => p.Definition.Origin == "Personnalisée"))
        { warnings.Add(personal.Definition.Name + " · collecte personnelle explicite · coût déclaré " + personal.Definition.Cost!.Level
            + " · empreinte " + personal.Key[7..19] + " · contrôleurs exclus."); }
        if (simulation)
        {
            warnings.Add("Simulation" + FrenchText.Colon + "l’annuaire fictif est relu en mémoire et les postes fictifs répondent selon des manches déterministes ; aucune connexion réelle.");
        }
        var storedProbes = await Reader.StoredProbesAsync(cancellationToken).ConfigureAwait(false);
        ProbeReadings readings;
        lock (gate)
        {
            probes = probes.Merge(storedProbes);
            readings = probes;
        }
        // ACC-038: workstations whose inventory and probes are already up to date are not contacted (estimate on the last ping).
        var toRead = wantInventory ? cachePolicy.Missing(onlineIds, observations, readings, probeIds, frozenTargets.Identities, now,
            saved?.Forced == true, (guid, id) => frozenTargets.Identities.TryGetValue(guid, out var target) && (target.UserAccountControl & AdValues.ServerTrustAccount) != 0
                && frozenProbes.Any(p => p.Key == id && p.Definition.SkipOnDc),
            id => frozenTargets.Identities.TryGetValue(id, out var target) && memoryRequired(target.Dn)
                && !cachePolicy.Memory(memoryFacts?.Machines.GetValueOrDefault(id)?.Memory, now, saved?.Forced == true)) : ImmutableArray<Guid>.Empty;
        var reused = wantInventory ? onlineIds.Count - toRead.Length : 0;
        if (wantInventory && reused > 0)
        {
            warnings.Add("Collecter seulement ce qui manque" + FrenchText.Colon + FleetBoardCalculator.Plural(reused, "poste déjà à jour", "postes déjà à jour")
                + " (durées du profil, identité matérielle conservée) ne sera pas contacté ; « Tout relire » les relit aussi.");
        }
        var stages = new List<RefreshStage>();
        if (wantDirectory)
        {
            stages.Add(new RefreshStage("backup", "Sauvegarde vérifiée de la base locale", simulation
                ? "Sans objet en simulation" + FrenchText.Colon + "aucune base locale n’est ouverte, rien à sauvegarder."
                : "Avant toute relecture AD, la base locale est sauvegardée puis vérifiée."));
            stages.Add(new RefreshStage("directory", "Lecture AD de l’OU", "Objets de l’OU " + scope.Label + " et de ses sous-OU relus sur le contrôleur, puis enregistrés dans la base locale."));
            stages.Add(new RefreshStage("commit", "Reçu d’enregistrement local", "La collecte des postes attend le reçu de la base (OU, base, session, complétude)."));
        }
        if (wantPresence)
        {
            stages.Add(new RefreshStage("presence", "Relevé de présence (ping)", "Un écho par poste actif de l’OU ; une absence de réponse ne prouve pas un arrêt."));
        }
        if (wantInventory)
        {
            stages.Add(new RefreshStage("inventory", "Inventaire WMI des postes admissibles", (allowUnanswered
                ? "Lecture WMI bornée sur les postes admissibles, même après un écho ICMP sans réponse"
                : "WMI lu uniquement sur les postes qui ont répondu au ping")
                + (wantPresence ? ", sans nouvel écho ni seconde confirmation" : " lors de l’actualisation interrompue")
                + " ; seulement les données manquantes ou périmées selon le profil de collecte"
                + (probeIds.Length > 0 ? " ; " + FleetBoardCalculator.Plural(probeIds.Length, "sonde de widget lue", "sondes de widgets lues") : "") + "."));
        }
        if (queryWork is not null && (saved is null || !saved.DoneStages.Contains("queries")))
        {
            stages.Add(new RefreshStage("queries", "Informations des requêtes liées", "Révisions figées des widgets et alertes ; seulement les sources manquantes des postes admissibles du plan. Durée bornée par les paramètres de campagne."));
        }
        // Estimate (improvement of ACC-001): budgets of Domenia 1, ping in batches of 64 with 800 ms each (Get-ReachableSet),
        // WMI reads Async.MaxThreads (6) at a time, about three seconds per workstation plus one per widget probe.
        var seconds = 0;
        if (wantDirectory)
        {
            seconds += 4 + objects / 400;
        }
        if (wantPresence)
        {
            seconds += 2 + (int)Math.Ceiling(active.Count / 64.0);
        }
        if (wantInventory)
        {
            seconds += 3 + (int)Math.Ceiling(Math.Max(toRead.Length, 1) / 6.0) * (3 + probeIds.Length);
        }
        var estimate = "Durée estimée en mode annuaire" + FrenchText.Colon + "environ " + (seconds < 90 ? FrenchText.Integer(seconds) + FrenchText.Nbsp + "s" : FrenchText.Integer((long)Math.Ceiling(seconds / 60.0)) + FrenchText.Nbsp + "min")
            + " pour " + FleetBoardCalculator.Plural(active.Count, "poste actif", "postes actifs")
            + (wantInventory ? " (" + FleetBoardCalculator.Plural(onlineIds.Count, allowUnanswered ? "poste admissible" : "poste en ligne", allowUnanswered ? "postes admissibles" : "postes en ligne") + " au dernier relevé, " + FleetBoardCalculator.Plural(toRead.Length, "à relever", "à relever") + ")" : "") + ".";
        var (title, summary, confirm) = mode switch
        {
            "directory" => ("Mettre à jour la base locale de l’OU", "Relit l’annuaire de l’OU " + scope.Label + " et de ses sous-OU (" + FleetBoardCalculator.Plural(objects, "objet", "objets") + " dans la base), après une sauvegarde vérifiée de la base locale. Aucun ping ni relevé WMI.", "Lancer la mise à jour"),
            "presence" => ("Actualiser la présence (ping)", "Pingue une fois les " + FleetBoardCalculator.Plural(active.Count, "poste actif", "postes actifs") + " de l’OU " + scope.Label + ". Aucun objet AD n’est modifié.", "Lancer le relevé ping"),
            "inventory" => ("Actualiser l’inventaire (ping puis WMI)", "Pingue les " + FleetBoardCalculator.Plural(active.Count, "poste actif", "postes actifs") + " de l’OU " + scope.Label + ", puis lit WMI uniquement sur les postes admissibles selon la politique réseau et dont une mesure manque. Une seule confirmation pour l’enchaînement.", "Lancer ping puis WMI"),
            "resume" => ("Reprendre l’actualisation interrompue", "Reprend les étapes que l’actualisation du " + CollectionClocks.Local(previous!.StartedAt, Zone) + " n’a pas terminées sur l’OU " + scope.Label
                + (wantInventory ? " ; WMI seulement sur les postes admissibles pas encore relus" : "") + ". Les mesures déjà enregistrées sont conservées.", "Reprendre"),
            _ => ("Tout actualiser", "Relit l’annuaire de l’OU " + scope.Label + " (après sauvegarde vérifiée), attend le reçu d’enregistrement, pingue les postes actifs puis lit WMI sur les postes admissibles dont une mesure manque. Si la lecture AD échoue ou reste partielle, aucune nouvelle collecte de poste ne démarre ; les résultats précédents sont conservés.", "Tout actualiser"),
        };
        var plan = new RefreshPlan(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), mode, title, summary, scope, active.Count, [.. stages], probeIds,
            [.. frozenProbes.Select(p => p.Definition.Name)], seconds, estimate, [.. warnings], confirm, now, now + PlanLifetime,
            wantInventory ? onlineIds.Count : 0, reused, 0, reuseSince, resumeOf, onlineSince)
        { Branches = branches, AvailableBranches = [.. availableBranches.Take(CampaignBranches.DisplayLimit)], BranchCount = availableBranches.Length, BudgetSeconds = (int)campaignBudget.TotalSeconds, ReadWithoutEcho = allowUnanswered, MemoryPolicies = memoryPolicies };
        lock (gate)
        {
            foreach (var expired in plans.Where(p => p.Value.ExpiresAt < now).Select(p => p.Key).ToList())
            {
                plans.Remove(expired);
                queryRefreshPlans.Remove(expired);
                refreshTargets.Remove(expired);
                homeRefreshPlans.Remove(expired);
            }
            plans[plan.Id] = plan;
            refreshTargets[plan.Id] = frozenTargets;
            if (offered is not null) { homeRefreshPlans[plan.Id] = offered; }
            if (queryWork is not null) { queryRefreshPlans[plan.Id] = queryWork; }
        }
        return plan;
    }

    /// <summary>The refusal of a new collection, raised as refresh.refused (Get-DomeniaStorageCollectionRefusal, ACC-001).</summary>
    private async Task EnsureAdmittedAsync(CancellationToken token)
    {
        if (context.Directory is ICollectionStorage storage)
            CollectionStorageRules.Ensure(await storage.CollectionStorageAsync(token).ConfigureAwait(false), Now, context.Clock.LocalTimeZone);
        bool bit;
        int failures;
        Func<long?>? probe;
        lock (gate)
        {
            bit = bitLockerReading;
            failures = localWriteFailures;
            probe = context.Directory is ICollectionStorage ? null : storageProbe;
        }
        long? free = null;
        if (probe is not null)
        {
            try
            {
                free = probe();
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or System.Security.SecurityException)
            {
                // Not measured: nothing is blocked and nothing is claimed.
                context.Log.Warning("Espace libre du volume des données non mesuré (" + ex.GetType().Name + ").");
            }
        }
        var refusal = RefreshRules.Refusal(new RefreshAdmission(context.Directory.Kind == DirectorySourceKind.Simulation, dashboard.Measuring, bit, failures, free));
        if (refusal is not null)
        {
            throw new DomeniaOperationException(RefreshRules.Refused, refusal);
        }
    }

    /// <summary>
    /// accueil.refresh.run: runs a plan once (the plan is spent at the start). Progress goes to <paramref name="progress"/>. A stop
    /// (accueil.refresh.stop, or an OU changed between stages) ends the stage in progress and launches nothing more; what was
    /// already recorded is kept. Collection runs are recorded only for the families really started. <paramref name="force"/>
    /// (« Tout relire »): every workstation in line is read again, even the ones already up to date (ACC-038).
    /// </summary>
    public async Task<RefreshReport> RunRefreshAsync(string planId, bool force, Action<RefreshProgress> progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(progress);
        RefreshPlan? plan;
        RefreshQueryWork? queryWork;
        RefreshTargets? frozenTargets;
        HomeCampaignStored? offered;
        var now = Now;
        lock (gate)
        {
            plans.Remove(planId, out plan);
            queryRefreshPlans.Remove(planId, out queryWork);
            refreshTargets.Remove(planId, out frozenTargets);
            homeRefreshPlans.Remove(planId, out offered);
        }
        if (plan is null || frozenTargets is null)
        {
            throw new DomeniaOperationException(RefreshPlanUnknown, RefreshPlanUnknownMessage);
        }
        if (now > plan.ExpiresAt)
        {
            throw new DomeniaOperationException(RefreshPlanExpired, RefreshPlanExpiredMessage);
        }
        var (session, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
        if (!ScopeRules.SameScope(scope, plan.Scope))
        {
            throw new DomeniaOperationException(RefreshScopeChanged, RefreshScopeChangedMessage);
        }
        // Every check runs again at the confirmation (Invoke-DomeniaOuRefresh): the plan is already spent, nothing is replayed.
        await EnsureAdmittedAsync(cancellationToken).ConfigureAwait(false);
        if (plan.Stages.Any(s => s.Id == "queries"))
        {
            if (queryWork is null) { throw new DomeniaOperationException(RefreshPlanUnknown, RefreshPlanUnknownMessage); }
            await ConfirmRefreshQueryStoreAsync(queryWork, cancellationToken).ConfigureAwait(false);
        }
        if (plan.Mode == "resume" && offered?.Plan is { } pendingDirectory && HomeTargetsProvisional(pendingDirectory))
        { await ConfirmRefreshContextAsync(frozenTargets, cancellationToken).ConfigureAwait(false); }
        else { await ConfirmRefreshTargetsAsync(frozenTargets, cancellationToken).ConfigureAwait(false); }
        var frozenProbes = await FrozenProbesAsync(plan.Probes, cancellationToken).ConfigureAwait(false);
        if (plan.Mode == "resume" && offered?.Plan is { } resumePlan)
        { await ConfirmHomeProgressAsync(resumePlan, cancellationToken).ConfigureAwait(false); }
        LoadPersisted(domainDn);
        var campaignSettings = CollectionSettingsRules.Read(context.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out var campaignJson) ? campaignJson : null, []);
        if (plan.Stages.Any(s => s.Id is "presence" or "inventory" or "queries"))
            CollectionAdmission.EnsureTargets(campaignSettings, frozenTargets.Identities.Count);
        var campaignDuration = plan.BudgetSeconds > 0 ? TimeSpan.FromSeconds(plan.BudgetSeconds)
            : CollectionCampaignBudget.For(frozenTargets.Identities.Count, campaignSettings.Budgets.GetValueOrDefault(CollectionSettingsRules.Concurrency, 4),
                campaignSettings.Budgets.GetValueOrDefault(CollectionSettingsRules.CampaignMinutes));
        using var deadline = new CancellationTokenSource(campaignDuration, context.Clock);
        var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, deadline.Token);
        force = force || plan.Mode == "resume" && offered?.Plan?.Forced == true;
        var state = new RunState(plan, linked) { StartedAt = now, Forced = force, PresenceStartedAt = plan.Mode == "resume" ? offered?.Plan?.PresenceStartedAt : null,
            FrozenProbes = frozenProbes, DirectoryTargetsPending = plan.Stages.Any(s => s.Id == "directory"), Performance = new(context.Clock),
            Branches = CampaignBranches.Summarize(plan.Scope, frozenTargets.Identities.Values) };
        using var performance = ReadPerformance.Observe(state.Performance.Add);
        using var networkPolicy = CollectionNetworkPolicy.Enter(plan.ReadWithoutEcho);
        using var timedOut = deadline.Token.Register(() =>
        {
            lock (gate) { state.Stopping = true; state.StopReason = "Durée maximale de campagne atteinte. Les résultats enregistrés sont conservés ; reprenez les postes restants explicitement."; }
        });
        lock (gate)
        {
            if (run is not null || widgetActive is not null && widgetActive.DirectoryRefreshId != plan.Id)
            {
                linked.Dispose();
                throw new DomeniaOperationException(RefreshRunning, RefreshRunningMessage);
            }
            run = state;
        }
        var token = linked.Token;
        var stages = plan.Stages;
        var directoryFailed = false;
        string? directoryError = null;
        var directoryStarted = false;
        var collectionStarted = default(DateTimeOffset?);
        var collectionApproved = false;
        DirectoryState? latestState = null;
        CollectionStatus? directoryStatus = null;
        long? directoryCount = null;
        var presenceDone = false;
        PresenceTally? presenceTally = null;
        var inventoryDone = false;
        var inventoryStarted = false;
        var presenceStarted = false;
        var inventoryOnline = 0;
        var inventoryContacted = 0;
        var inventorySucceeded = 0;
        var inventoryFailed = 0;
        var outcome = "success";
        try
        {
            state.Durable = await BeginHomeRefreshAsync(state, frozenTargets, queryWork, offered, domainDn, token).ConfigureAwait(false);
            for (var i = 0; i < stages.Length; i++)
            {
                var stage = stages[i];
                if (state.Stopping || token.IsCancellationRequested)
                {
                    Record(state, stage, "skipped", "Non lancée" + FrenchText.Colon + "actualisation arrêtée.", null, null, progress, i, stages.Length);
                    continue;
                }
                // A change of OU, base or session stops the refresh before the next stage (Test-DomeniaOuRefreshCurrent). Read
                // with the token of the call, not the one a stop cancels: a stop between two stages records them as skipped.
                var (_, current, _) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
                if (!ScopeRules.SameScope(current, plan.Scope))
                {
                    state.Stopping = true;
                    state.StopReason = "L’OU de travail a changé" + FrenchText.Colon + "actualisation arrêtée avant l’étape suivante.";
                    Record(state, stage, "skipped", "Non lancée" + FrenchText.Colon + "l’OU de travail a changé.", null, null, progress, i, stages.Length);
                    continue;
                }
                var started = Now;
                Publish(state, stage, "running", stage.Detail, progress, i, stages.Length);
                try
                {
                    if (stage.Id is "presence" or "inventory" or "queries")
                        CollectionAdmission.EnsureTargets(CollectionAdmission.Read(context.Preferences), frozenTargets.Identities.Count);
                    switch (stage.Id)
                    {
                        case "backup":
                            if (context.Directory.Kind == DirectorySourceKind.Simulation)
                            {
                                Record(state, stage, "na", "Sans objet en simulation" + FrenchText.Colon + "aucune base locale n’est ouverte, rien à sauvegarder.", started, Now, progress, i, stages.Length);
                            }
                            else
                            {
                                var preparation = context.Directory as IDirectoryRefreshPreparation
                                    ?? throw new DomeniaOperationException(RefreshBackupUnavailable, RefreshBackupUnavailableMessage);
                                var backup = await preparation.PrepareDirectoryRefreshAsync(token).ConfigureAwait(false);
                                Record(state, stage, "done", "Sauvegarde locale vérifiée · SHA-256 " + backup.Sha256, started, Now, progress, i, stages.Length);
                            }
                            break;
                        case "directory":
                            directoryStarted = true;
                            latestState = await dashboard.MeasureAsync(MeasureFamily.Directory, token).ConfigureAwait(false);
                            directoryCount = CountObjects(latestState.Directory, plan.Scope);
                            directoryStatus = latestState.Directory.Complete ? CollectionStatus.Success : CollectionStatus.Partial;
                            Record(state, stage, "done", FleetBoardCalculator.Plural(directoryCount.Value, "objet relu", "objets relus") + " dans l’OU " + plan.Scope.Label
                                + (session.Controller is ControllerIdentity dc ? " sur " + dc.DnsName : "") + (latestState.Directory.Complete ? " · lecture complète" : " · lecture partielle"), started, Now, progress, i, stages.Length);
                            break;
                        case "commit":
                            if (latestState is null || directoryStatus != CollectionStatus.Success)
                            {
                                directoryFailed = true;
                                directoryError ??= "Lecture AD partielle" + FrenchText.Colon + "le dernier repère complet est conservé.";
                                directoryStatus = latestState is null ? CollectionStatus.Error : CollectionStatus.Partial;
                                Record(state, stage, "failed", "Aucun reçu d’enregistrement" + FrenchText.Colon + directoryError
                                    + " Aucune nouvelle collecte ne sera lancée.", started, Now, progress, i, stages.Length);
                                outcome = "error";
                                state.Stopping = true;
                                state.StopReason = "Actualisation interrompue sur erreur : " + directoryError;
                            }
                            else
                            {
                                // No subsequent collection starts without this prerequisite and its qualified receipt.
                                var proof = latestState.DirectoryCommit;
                                if (context.Directory.Kind != DirectorySourceKind.Simulation &&
                                    (proof is null || proof.SessionEpoch != frozenTargets.Epoch ||
                                     !proof.Receipt.Matches(frozenTargets.StoreId, domainDn, plan.Scope, latestState.Directory, Now)))
                                { throw new DomeniaOperationException("accueil.refresh.receipt", "Reçu local absent ou incohérent après lecture AD ; aucune collecte des postes n’est lancée."); }
                                // The plan's OU is approved; its local census was only provisional until this complete AD receipt.
                                // Freeze fresh identities here, never by weakening Matches and never after any host work began.
                                var committedBranch = HomeCampaignRules.BranchClassifier(plan.Scope, plan.Branches);
                                var refreshedTargets = await FreezeRefreshTargetsAsync(latestState.Directory.Computers.Where(c =>
                                    committedBranch(c.DistinguishedName) >= 0
                                    && !AdValues.IsDisabled(c.UserAccountControl)), token).ConfigureAwait(false);
                                if (refreshedTargets.Epoch != frozenTargets.Epoch || refreshedTargets.StoreId != frozenTargets.StoreId)
                                { throw new DomeniaOperationException(RefreshScopeChanged, "Session ou base modifiée pendant la relecture AD ; aucune collecte des postes."); }
                                if (stages.Skip(i + 1).Any(st => st.Id is "presence" or "inventory" or "queries"))
                                    CollectionAdmission.EnsureTargets(CollectionAdmission.Read(context.Preferences), refreshedTargets.Identities.Count);
                                if (state.Durable is not null) { await state.Durable.BindDirectoryAsync(latestState, token).ConfigureAwait(false); }
                                frozenTargets = refreshedTargets;
                                if (queryWork is not null) { queryWork = queryWork with { Identities = refreshedTargets.Identities }; }
                                state.DirectoryTargetsPending = false;
                                var goesOn = stages.Skip(i + 1).Any(st => st.Id is "presence" or "inventory");
                                Record(state, stage, "done", "Reçu d’enregistrement" + FrenchText.Colon + "OU " + plan.Scope.Label + ", " + FleetBoardCalculator.Plural(directoryCount ?? 0, "objet", "objets")
                                    + ", lecture complète, même session. " + (proof is null ? "Simulation, sans reçu SQLite. " : "Lot " + proof.Receipt.BatchId + ", révision " + proof.Receipt.Revision + ", SHA-256 " + proof.Receipt.Sha256 + ". ")
                                    + (goesOn ? "Préparation du relevé des postes." : "Aucun ping ni relevé WMI."), started, Now, progress, i, stages.Length);
                            }
                            break;
                        case "presence":
                            presenceStarted = true;
                            collectionApproved = true;
                            collectionStarted ??= started;
                            state.PresenceStartedAt ??= started;
                            await ConfirmRefreshTargetsAsync(frozenTargets, token).ConfigureAwait(false);
                            var confirmedPresence = state.Durable?.State.PresenceDone.ToHashSet() ?? [];
                            var pendingPresence = frozenTargets.Identities.Where(p => !confirmedPresence.Contains(p.Key)).ToImmutableDictionary();
                            latestState = pendingPresence.IsEmpty ? await context.Directory.ReadLocalAsync(token).ConfigureAwait(false)
                                : await ObserveHomeStageAsync(state, frozenTargets, () => dashboard.MeasureAsync((_, t) => Reader.ReadPresenceAsync(plan.Scope, pendingPresence, frozenTargets.Epoch, t), token)).ConfigureAwait(false);
                            RecordOperationsPresence(state.Id, FrozenObservationState(latestState, frozenTargets), state.PresenceStartedAt ?? started);
                            presenceDone = true;
                            // A definitive answer about a name (absent from DNS, invalid) is a result, not a failure: the stage is
                            // done and « Reprendre » never asks again. Only targets still to measure make it partial and resumable.
                            presenceTally = CountPresence(FrozenObservationState(latestState, frozenTargets), plan.Scope, state.PresenceStartedAt ?? started);
                            if (presenceTally.Pending > 0) { outcome = "partial"; }
                            Record(state, stage, presenceTally.Pending > 0 ? "partial" : "done", presenceTally.Text, started, Now, progress, i, stages.Length);
                            break;
                        case "queries":
                            var queryText = await ObserveHomeStageAsync(state, frozenTargets, () => CollectRefreshQueriesAsync(queryWork ?? throw new DomeniaOperationException(RefreshPlanUnknown, RefreshPlanUnknownMessage),
                                plan, force, domainDn, state.PresenceStartedAt ?? plan.OnlineSince ?? collectionStarted ?? started, token)).ConfigureAwait(false);
                            Record(state, stage, "done", queryText, started, Now, progress, i, stages.Length);
                            break;
                        case "inventory":
                            inventoryStarted = true;
                            state.InventoryStartedAt = started;
                            collectionApproved = true;
                            collectionStarted ??= started;
                            // ACC-004: WMI only on the workstations that answered the ping of this refresh (or of the interrupted one a
                            // resume completes). ACC-038: of those, only the ones whose inventory or a probe of the plan is missing.
                            var before = latestState ?? await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
                            await ConfirmRefreshTargetsAsync(frozenTargets, token).ConfigureAwait(false);
                            var onlineIds = OnlineIds(before, plan.Scope, state.PresenceStartedAt ?? plan.OnlineSince ?? collectionStarted ?? started, plan.ReadWithoutEcho).Where(frozenTargets.Identities.ContainsKey).ToList();
                            ProbeReadings known;
                            var committedProbes = await Reader.StoredProbesAsync(token).ConfigureAwait(false);
                            lock (gate)
                            {
                                probes = probes.Merge(committedProbes);
                                known = probes;
                            }
                            var policy = CollectionCachePolicy.Read(context.Preferences);
                            var observationsBefore = before.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
                            var confirmedInventory = state.Durable?.State.InventoryDone.ToHashSet() ?? [];
                            var memoryRequired = HomeMemoryPolicy.Resolver(plan.MemoryPolicies);
                            var memoryBefore = await Reader.FactsAsync(token).ConfigureAwait(false);
                            bool MissingMemory(Guid id) => frozenTargets.Identities.TryGetValue(id, out var target) && memoryRequired(target.Dn)
                                && !policy.Memory(memoryBefore.Machines.GetValueOrDefault(id)?.Memory, Now, force);
                            var toRead = policy.Missing(onlineIds, observationsBefore, known, plan.Probes, frozenTargets.Identities, Now, force,
                                (guid, id) => frozenTargets.Identities.TryGetValue(guid, out var target) && (target.UserAccountControl & AdValues.ServerTrustAccount) != 0
                                    && state.FrozenProbes.Any(p => p.Key == id && p.Definition.SkipOnDc), MissingMemory)
                                .Where(id => !confirmedInventory.Contains(id)).ToHashSet();
                            inventoryOnline = onlineIds.Count;
                            inventoryContacted = toRead.Count;
                            state.Performance.Reused(inventoryOnline - inventoryContacted);
                            var probeText = "";
                            if (toRead.Count > 0)
                            {
                                var inventoryTargets = frozenTargets.Identities.Where(p => toRead.Contains(p.Key)
                                    && (!policy.Inventory(observationsBefore.GetValueOrDefault(p.Key)?.Inventory, Now, force) || MissingMemory(p.Key))).ToImmutableDictionary();
                                latestState = inventoryTargets.IsEmpty ? before : await ObserveHomeStageAsync(state, frozenTargets,
                                    () => dashboard.MeasureAsync((_, t) => Reader.ReadInventoryAsync(plan.Scope, inventoryTargets, frozenTargets.Epoch, t), token)).ConfigureAwait(false);
                                // A stale widget probe does not force another inventory or reread the other, already cached probes.
                                var probeReads = new HashSet<string>(StringComparer.Ordinal);
                                var probeGroups = frozenTargets.Identities.Where(p => toRead.Contains(p.Key)).Select(p => new
                                {
                                    Target = p,
                                    Definitions = state.FrozenProbes.Where(definition =>
                                        !(definition.Definition.SkipOnDc && (p.Value.UserAccountControl & AdValues.ServerTrustAccount) != 0)
                                        && !policy.Probe(definition.Key, known.ByProbe.GetValueOrDefault(definition.Key)?.GetValueOrDefault(p.Key), p.Value, Now, force)).ToImmutableArray(),
                                }).Where(p => !p.Definitions.IsEmpty).GroupBy(p => string.Join("\n", p.Definitions.Select(d => d.Key)), StringComparer.Ordinal);
                                // One shared native reader per workstation, even when several widget probes are missing.
                                foreach (var group in probeGroups)
                                {
                                    var definitions = group.First().Definitions;
                                    var probeTargets = group.ToImmutableDictionary(p => p.Target.Key, p => p.Target.Value);
                                    await ConfirmRefreshTargetsAsync(frozenTargets, token).ConfigureAwait(false);
                                    var readings = await ObserveHomeStageAsync(state, frozenTargets, () => CollectFrozenProbesAsync(definitions, plan.Scope,
                                        probeTargets, frozenTargets.Epoch, token, retryFailures: force)).ConfigureAwait(false);
                                    lock (gate) { probes = probes.Merge(readings); }
                                    probeReads.UnionWith(definitions.Select(d => d.Key));
                                }
                                if (probeReads.Count > 0) { probeText = " · " + FleetBoardCalculator.Plural(probeReads.Count, "sonde de widget lue", "sondes de widgets lues"); }
                            }
                            else
                            {
                                latestState = before;
                            }
                            inventoryDone = true;
                            var reusedNow = onlineIds.Count - toRead.Count;
                            var measuredById = latestState.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
                            var computersById = latestState.Directory.Computers.ToDictionary(c => c.ObjectGuid);
                            ProbeReadings afterProbes;
                            lock (gate) { afterProbes = probes; }
                            var memoryAfter = await Reader.FactsAsync(token).ConfigureAwait(false);
                            var usable = toRead.Count(id => measuredById.TryGetValue(id, out var observation) && observation.Inventory.HasReading
                                && (RefreshRules.InventoryAnswered(observation.Inventory, started, Now) || policy.Inventory(observation.Inventory, started, force))
                                && (!memoryRequired(frozenTargets.Identities[id].Dn) || HomeMemoryPolicy.Answered(memoryAfter.Machines.GetValueOrDefault(id)?.Memory, started, Now)
                                    || policy.Memory(memoryAfter.Machines.GetValueOrDefault(id)?.Memory, started, force)) && plan.Probes.All(probeId =>
                                    state.FrozenProbes.Any(p => p.Key == probeId && p.Definition.SkipOnDc) && computersById.TryGetValue(id, out var c) && (c.UserAccountControl & 8192) != 0
                                    || afterProbes.ByProbe.TryGetValue(probeId, out var byId) && byId.TryGetValue(id, out var reading)
                                        && (RefreshRules.ProbeAnswered(reading, started, Now)
                                            || policy.Probe(probeId, reading, frozenTargets.Identities.GetValueOrDefault(id), started, force))));
                            inventorySucceeded = reusedNow + usable;
                            inventoryFailed = toRead.Count - usable;
                            RecordOperationsInventory(state.Id, FrozenObservationState(latestState, frozenTargets), started, inventoryOnline);
                            if (inventoryFailed > 0)
                            {
                                outcome = "partial";
                                probeText += " · " + FleetBoardCalculator.Plural(inventoryFailed, "poste avec une lecture incomplète ou refusée", "postes avec une lecture incomplète ou refusée");
                            }
                            var detail = onlineIds.Count == 0
                                ? "Aucun poste admissible selon les conditions de collecte" + FrenchText.Colon + "aucune lecture WMI."
                                : "Inventaire et sondes disponibles pour " + FleetBoardCalculator.Plural(usable, "poste", "postes")
                                  + (reusedNow > 0 ? " · " + FleetBoardCalculator.Plural(reusedNow, "déjà à jour, non contacté", "déjà à jour, non contactés") : "") + probeText;
                            // « failed » is kept for a stage that could not run; a stage that ran with reads to complete is « partial ».
                            Record(state, stage, inventoryFailed > 0 ? "partial" : "done", detail, started, Now, progress, i, stages.Length);
                            break;
                    }
                }
                catch (OperationCanceledException) when (state.Stopping && !cancellationToken.IsCancellationRequested)
                {
                    Record(state, stage, "stopped", "Arrêtée" + FrenchText.Colon + "les mesures déjà enregistrées sont conservées ; aucune nouvelle collecte ne sera lancée.", started, Now, progress, i, stages.Length);
                }
                catch (DomeniaOperationException ex)
                {
                    outcome = "error";
                    if (stage.Id is "directory" or "commit")
                    {
                        directoryStatus = CollectionStatus.Error;
                        directoryError = ex.Message;
                    }
                    Record(state, stage, "failed", ex.Message, started, Now, progress, i, stages.Length);
                    state.Stopping = true;
                    state.StopReason = "Actualisation interrompue" + FrenchText.Colon + ex.Message + " Aucune nouvelle collecte ne sera lancée.";
                }
                await SaveHomeProgressAsync(state, frozenTargets).ConfigureAwait(false);
            }
            if (cancellationToken.IsCancellationRequested)
            {
                throw new OperationCanceledException(cancellationToken);
            }
            if (state.Stopping && outcome != "error")
            {
                outcome = "cancelled";
            }
            else if (directoryFailed && outcome == "success")
            {
                outcome = "partial";
            }
            // Collection runs: only the families really started (a refusal or a stop before any network action records nothing),
            // each with the depth really measured: a run on the direct children never dates the descendants (ACC-023).
            var finished = Now;
            var recorded = new List<CollectionRun>();
            if (directoryStarted)
            {
                var status = outcome == "cancelled" && directoryStatus is null ? CollectionStatus.Cancelled : directoryStatus ?? CollectionStatus.Error;
                recorded.Add(CollectionClocks.Create(CollectionFamily.Directory, domainDn, plan.Scope.Dn, plan.Scope.Subtree, status, state.StartedAt, finished,
                    status == CollectionStatus.Cancelled ? "Lecture AD arrêtée avant son enregistrement." : directoryError, null, directoryCount, null, null, session.Controller?.DnsName, finished));
            }
            if (collectionApproved && collectionStarted is DateTimeOffset collectStart)
            {
                var targets = frozenTargets.Identities.Count;
                // Only the targets still to measure are unconfirmed; definitive answers about a name are results. Counted from the
                // presence start of the campaign, so a resume does not call « non confirmée » a reading of the interrupted run.
                var runTally = latestState is null ? null : CountPresence(FrozenObservationState(latestState, frozenTargets), plan.Scope, state.PresenceStartedAt ?? collectStart);
                long failed = runTally?.Pending ?? 0;
                var done = (long)targets;
                if (presenceStarted)
                {
                    var status = presenceDone ? (failed > 0 || !plan.Branches.IsEmpty ? CollectionStatus.Partial : CollectionStatus.Success) : state.Stopping ? CollectionStatus.Cancelled : CollectionStatus.Error;
                    recorded.Add(CollectionClocks.Create(CollectionFamily.Presence, domainDn, plan.Scope.Dn, plan.Scope.Subtree, status, collectStart, finished,
                        status == CollectionStatus.Partial ? FleetBoardCalculator.Plural(failed, "poste avec une lecture non confirmée", "postes avec une lecture non confirmée")
                            + (runTally is { Pending: > 0 } ? " (" + runTally.PendingCauses + ")" : "") + " ; " + FrenchText.Integer(done) + "/" + FrenchText.Integer(targets) + " postes traités."
                            + (!plan.Branches.IsEmpty ? " Branches choisies seulement ; aucune couverture complète de l’OU parente revendiquée." : "")
                        : status == CollectionStatus.Cancelled ? "Relevé arrêté." : null,
                        targets, presenceDone ? done : null, presenceDone ? done - failed : null, presenceDone ? failed : null, null, finished));
                }
                if (inventoryStarted)
                {
                    var status = inventoryDone ? inventoryFailed > 0 || !plan.Branches.IsEmpty ? CollectionStatus.Partial : CollectionStatus.Success : state.Stopping ? CollectionStatus.Cancelled : CollectionStatus.Error;
                    recorded.Add(CollectionClocks.Create(CollectionFamily.Inventory, domainDn, plan.Scope.Dn, plan.Scope.Subtree, status, collectStart, finished,
                        status == CollectionStatus.Cancelled ? "Relevé arrêté." : !plan.Branches.IsEmpty ? "Branches choisies seulement ; aucune couverture complète de l’OU parente revendiquée."
                            : inventoryFailed > 0 ? "Certaines lectures sont incomplètes ou refusées." : null, inventoryOnline, inventoryDone ? inventoryOnline : null, inventoryDone ? inventorySucceeded : null, inventoryDone ? inventoryFailed : null, null, finished));
                }
            }
            lock (gate)
            {
                sessionRuns.AddRange(recorded);
                latest = null;
            }
            if (recorded.Count > 0)
            {
                MarkOperationsSaving(state.Id);
                await PersistRunsAsync(domainDn, cancellationToken).ConfigureAwait(false);
            }
            state.Runs.AddRange(CollectionClocks.Rows(recorded));
            await FinishHomeRefreshAsync(state, frozenTargets, outcome == "success").ConfigureAwait(false);
            state.DurableFinished = true;
            // The stage cards of a success fold away: the report label and the journal keep the definitive answers, the targets
            // still to measure and the hint of a scope where no name resolved. That success alone is journaled as a warning.
            var presenceNote = presenceTally is not null && outcome is "success" or "partial" ? presenceTally.Note : "";
            var label = Outcome(plan, outcome, state.StopReason, directoryFailed) + (presenceNote.Length > 0 ? " · " + presenceNote : "");
            context.Journal.Add(new JournalEntry(finished, label + (inventoryStarted && inventoryOnline > inventoryContacted
                ? " · " + FleetBoardCalculator.Plural(inventoryOnline - inventoryContacted, "poste déjà à jour non contacté", "postes déjà à jour non contactés") : ""),
                outcome switch { "success" => presenceTally is { Unresolved: true } ? Tone.Warn : Tone.Ok, "partial" => Tone.Warn, "cancelled" => Tone.Info, _ => Tone.Alert }));
            var resumable = outcome != "success" && state.Stages.Any(st => st.State is "skipped" or "stopped" or "failed" or "partial" or "waiting");
            var report = new RefreshReport(state.Id, plan.Mode, outcome, label, plan.Scope, state.StartedAt, finished, [.. state.Stages], [.. state.Runs], state.Stopping, force, resumable)
            { Performance = state.Performance.Snapshot(), Branches = [.. state.Branches.Take(CampaignBranches.DisplayLimit)], BranchCount = state.Branches.Length };
            lock (gate)
            {
                lastReport = report;
            }
            return report;
        }
        finally
        {
            if (!state.DurableFinished)
            {
                try { await FinishHomeRefreshAsync(state, frozenTargets, false).ConfigureAwait(false); }
                catch (Exception ex) { context.Log.Warning("Finalisation du plan Accueil non aboutie : " + ex.GetType().Name + ". Le dernier checkpoint est conservé."); }
            }
            lock (gate)
            {
                if (ReferenceEquals(run, state))
                {
                    run = null;
                    if (widgetActive is null) { pendingRefreshDraw = state.Id; }
                }
            }
            linked.Dispose();
        }
    }

    /// <summary>accueil.refresh.stop: stops the refresh in progress (ACC-008); the local writes already engaged finish.</summary>
    public RefreshStopResult StopRefresh()
    {
        RunState? state;
        lock (gate)
        {
            state = run;
            if (state is not null)
            {
                state.Stopping = true;
                state.StopReason ??= "Actualisation arrêtée. Les écritures locales déjà engagées se terminent ; aucune nouvelle collecte ne sera lancée.";
            }
        }
        if (state is null)
        {
            return new RefreshStopResult(false, "Aucune actualisation en cours" + FrenchText.Colon + "rien à arrêter.");
        }
        try
        {
            state.Cancellation.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // Finished meanwhile: nothing left to stop.
        }
        return new RefreshStopResult(true, "Arrêt demandé" + FrenchText.Colon + "l’étape en cours se termine sans lancer de nouvelle collecte.");
    }

    /// <summary>accueil.refresh.state: the refresh in progress, if any, and the last report of the session.</summary>
    public RefreshState RefreshStatus()
    {
        lock (gate)
        {
            var current = run is null ? null : new RefreshReport(run.Id, run.Plan.Mode, "running", run.Plan.Title, run.Plan.Scope, run.StartedAt, null, [.. run.Stages], [.. run.Runs], run.Stopping, run.Forced)
            { Performance = run.Performance.Snapshot(), Branches = [.. run.Branches.Take(CampaignBranches.DisplayLimit)], BranchCount = run.Branches.Length };
            return new RefreshState(run is not null, current, lastReport) { AwaitingDraw = pendingRefreshDraw };
        }
    }

    public void AcknowledgeRefreshDraw(string id)
    { lock (gate) { if (pendingRefreshDraw == id) { pendingRefreshDraw = null; } } }

    private void StopForScopeChange()
    {
        StopWidgetsForDispose();
        lock (gate)
        {
            pendingRefreshDraw = null;
            plans.Clear(); queryRefreshPlans.Clear(); refreshTargets.Clear(); homeRefreshPlans.Clear();
            if (run is not null)
            {
                run.StopReason = "L’OU de travail a changé" + FrenchText.Colon + "actualisation arrêtée.";
            }
        }
        StopRefresh();
    }

    private void StopRunForDispose()
    {
        RunState? state;
        lock (gate)
        {
            state = run;
        }
        try
        {
            state?.Cancellation.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // Already finished.
        }
    }

    private void Record(RunState state, RefreshStage stage, string status, string detail, DateTimeOffset? started, DateTimeOffset? finished, Action<RefreshProgress> progress, int index, int count)
    {
        lock (gate)
        {
            state.Stages.RemoveAll(s => s.Id == stage.Id);
            state.Stages.Add(new RefreshStageResult(stage.Id, stage.Label, status, detail, started, finished));
        }
        var percent = (int)Math.Round(100.0 * (index + 1) / Math.Max(1, count));
        progress(new RefreshProgress(state.Id, stage.Id, status, stage.Label, detail, index, count, percent));
    }

    private void Publish(RunState state, RefreshStage stage, string status, string detail, Action<RefreshProgress> progress, int index, int count)
    {
        lock (gate)
        {
            state.Stages.RemoveAll(s => s.Id == stage.Id);
            state.Stages.Add(new RefreshStageResult(stage.Id, stage.Label, status, detail, Now, null));
        }
        progress(new RefreshProgress(state.Id, stage.Id, status, stage.Label, detail, index, count, (int)Math.Round(100.0 * index / Math.Max(1, count))));
    }

    private static long CountObjects(DirectorySnapshot directory, ScopeSelection scope) =>
        directory.Computers.Count(c => ScopeRules.Contains(scope, c.DistinguishedName)) + directory.Users.Count(u => ScopeRules.Contains(scope, u.DistinguishedName))
        + directory.Groups.Count(g => ScopeRules.Contains(scope, g.DistinguishedName)) + directory.OrganizationalUnits.Count(o => ScopeRules.Contains(scope, o.DistinguishedName));

    /// <summary>
    /// Presence of the active workstations of the scope since <paramref name="since"/>: readings, definitive answers about their
    /// name (PresenceOutcomes: nothing to retry), and the rest still to measure with their causes (transient errors, attempts
    /// without a recorded cause, no result dated since then). Only <see cref="PresenceTally.Pending"/> makes a refresh partial.
    /// </summary>
    private static PresenceTally CountPresence(DirectoryState state, ScopeSelection scope, DateTimeOffset since)
    {
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).Select(c => c.ObjectGuid).ToHashSet();
        var online = 0;
        var noAnswer = 0;
        var definitive = new List<PresenceMeasure>();
        var causes = new List<string>();
        foreach (var id in active)
        {
            var presence = state.Observations.Find(id)?.Presence;
            if (presence is { HasReading: true } && presence.CheckedAt >= since)
            {
                if (presence.Answered == true) { online++; }
                else { noAnswer++; }
            }
            else if (PresenceOutcomes.Definitive(presence, since)) { definitive.Add(presence!); }
            else { causes.Add(PresenceOutcomes.Cause(presence, since)); }
        }
        return new(online, noAnswer, definitive.Count, definitive.Count(m => m.Diagnostic!.Outcome == PresenceReadOutcome.DnsNotFound), causes.Count,
            PresenceOutcomes.DefinitiveText(definitive), PresenceOutcomes.Causes(causes));
    }

    private sealed record PresenceTally(int Online, int NoAnswer, int Definitive, int ResolverAnswers, int Pending, string DefinitiveText, string PendingCauses)
    {
        private const string UnresolvedHint = "aucun nom résolu" + FrenchText.Colon + "vérifiez le DNS de ce poste";

        /// <summary>« 2 non vérifiés (DNS indisponible, délai DNS dépassé) », empty when nothing is left to measure.</summary>
        public string PendingText => Pending > 0 ? FleetBoardCalculator.Plural(Pending, "non vérifié", "non vérifiés") + " (" + PendingCauses + ")" : "";

        /// <summary>
        /// Systemic safeguard: nothing left to measure, no name resolved, and at least two answers of the resolver that a name has
        /// no address (an invalid name never reaches it). A DNS or VPN fault of this workstation looks exactly like that: the stage
        /// stays done and the refresh a success, but both say it.
        /// </summary>
        public bool Unresolved => Pending == 0 && Online + NoAnswer == 0 && ResolverAnswers >= 2;

        /// <summary>« 0 poste en ligne sur 5 · 4 sans réponse · 1 nom absent du DNS », then the targets still to measure or the hint.</summary>
        public string Text => FleetBoardCalculator.Plural(Online, "poste en ligne", "postes en ligne") + " sur " + FrenchText.Integer(Online + NoAnswer + Definitive + Pending)
            + " · " + FrenchText.Integer(NoAnswer) + " sans réponse" + (DefinitiveText.Length > 0 ? " · " + DefinitiveText : "") + (Pending > 0 ? " · " + PendingText : "")
            + (Unresolved ? " · " + UnresolvedHint : "");

        /// <summary>
        /// Note of the report label, read without the stage detail: the definitive answers, the targets still to measure with their
        /// noun (« 1 poste non vérifié (délai DNS dépassé) ») and the hint of <see cref="Unresolved"/>; empty without any.
        /// </summary>
        public string Note => string.Join(" · ", new[]
        {
            DefinitiveText,
            Pending > 0 ? FleetBoardCalculator.Plural(Pending, "poste non vérifié", "postes non vérifiés") + " (" + PendingCauses + ")" : "",
            Unresolved ? UnresolvedHint : "",
        }.Where(s => s.Length > 0));
    }

    private static HashSet<Guid> OnlineIds(DirectoryState state, ScopeSelection scope, DateTimeOffset since, bool allowUnanswered = false)
    {
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).Select(c => c.ObjectGuid).ToHashSet();
        return [.. state.Observations.Workstations.Where(o => active.Contains(o.ComputerGuid) && CollectionNetworkPolicy.Eligible(o.Presence, allowUnanswered) && o.Presence.CheckedAt >= since).Select(o => o.ComputerGuid)];
    }

    private static string Outcome(RefreshPlan plan, string outcome, string? stopReason, bool directoryFailed)
    {
        var where = "OU " + plan.Scope.Label;
        return outcome switch
        {
            "success" => plan.Mode switch
            {
                "directory" => "Objets AD relus et enregistrés" + FrenchText.Colon + where + " et ses sous-OU. Aucun ping ni relevé WMI.",
                "presence" => "Présence relevée par ping" + FrenchText.Colon + where,
                "inventory" => "Ping puis inventaire WMI des postes admissibles" + FrenchText.Colon + where,
                "resume" => "Actualisation interrompue reprise et terminée" + FrenchText.Colon + where,
                _ => "Tout actualisé" + FrenchText.Colon + where + " (objets AD, présence, inventaire WMI)",
            },
            "partial" => directoryFailed ? "Actualisation partielle de l’" + where + FrenchText.Colon + "lecture AD non aboutie, résultats précédents conservés" : "Actualisation partielle" + FrenchText.Colon + where,
            "cancelled" => stopReason ?? "Actualisation arrêtée" + FrenchText.Colon + where,
            _ => stopReason ?? "Actualisation interrompue" + FrenchText.Colon + where,
        };
    }

    /// <summary>Plain-text summary of a refresh for the journal export (no culture read).</summary>
    public static string Describe(RefreshReport report)
    {
        ArgumentNullException.ThrowIfNull(report);
        return string.Join("\n", report.Stages.Select(s => s.Label + FrenchText.Colon + s.State + " — " + s.Detail)) + "\n" + report.Label
            + " (" + report.StartedAt.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture) + ")";
    }
}
