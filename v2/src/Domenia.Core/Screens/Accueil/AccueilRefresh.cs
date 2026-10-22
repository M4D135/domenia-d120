using System.Collections.Immutable;
using System.Globalization;
using System.Security.Cryptography;

namespace Domenia.Core.Accueil;

/// <summary>
/// Explicit refresh of the working OU (Domenia 1, Domenia-Refresh.UI.ps1, ACC-001 to ACC-008): a plan frozen at the click (OU,
/// workstations, stages, probe plan of the active widgets), confirmed once, run once; the AD read is followed by its storage
/// receipt before any workstation is contacted; ping then WMI of the workstations that answered only; a failed AD read in
/// « Tout actualiser » leaves ping and WMI on the workstations already known; « Arrêter » keeps what was already recorded.
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
    public async Task<RefreshPlan> PlanRefreshAsync(string mode, CancellationToken cancellationToken)
    {
        if (!RefreshModes.Contains(mode, StringComparer.Ordinal))
        {
            throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Arguments invalides" + FrenchText.Colon + FrenchText.Quote("mode") + " doit valoir directory, presence, inventory, all ou resume.");
        }
        var (_, scope, domainDn) = await ScopeAsync(cancellationToken).ConfigureAwait(false);
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
        EnsureAdmitted();
        var simulation = context.Directory.Kind == DirectorySourceKind.Simulation;
        var now = Now;
        // Stages wanted: from the mode, or from what the interrupted refresh did not finish.
        bool wantDirectory;
        bool wantPresence;
        bool wantInventory;
        string? resumeOf = null;
        DateTimeOffset? onlineSince = null;
        var reuseSince = (DateTimeOffset?)(now - TimeSpan.FromDays(RefreshRules.ReuseDays));
        if (mode == "resume")
        {
            if (previous is not { Resumable: true } || !ScopeRules.SameScope(previous.Scope, scope))
            {
                throw new DomeniaOperationException(RefreshNothingToResume, RefreshNothingToResumeMessage);
            }
            var unfinished = previous.Stages.Where(st => st.State is not ("done" or "na")).Select(st => st.Id).ToHashSet(StringComparer.Ordinal);
            wantDirectory = unfinished.Contains("backup") || unfinished.Contains("directory") || unfinished.Contains("commit");
            wantPresence = unfinished.Contains("presence");
            wantInventory = unfinished.Contains("inventory");
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
        var observations = state.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var onlineIds = active.Where(c => observations.TryGetValue(c.ObjectGuid, out var o) && o.Presence is { Answered: true } p && p.CheckedAt is not null
            && (onlineSince is null || p.CheckedAt >= onlineSince)).Select(c => c.ObjectGuid).ToList();
        var objects = state.Directory.Computers.Count(c => ScopeRules.Contains(scope, c.DistinguishedName)) + state.Directory.Users.Count(u => ScopeRules.Contains(scope, u.DistinguishedName))
            + state.Directory.Groups.Count(g => ScopeRules.Contains(scope, g.DistinguishedName)) + state.Directory.OrganizationalUnits.Count(o => ScopeRules.Contains(scope, o.DistinguishedName));
        var items = LayoutItems();
        var warnings = new List<string>();
        // Probe plan frozen at the click: the active probe widgets of the board (paused ones left out, decision of 14/10/2026).
        var probeIds = items.Where(i => i.Source == FleetWidgetSource.Probe && !i.Paused).Select(i => i.Key).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToImmutableArray();
        var queries = items.Count(i => i.Source == FleetWidgetSource.Query && !i.Paused);
        if (wantInventory && queries > 0)
        {
            throw new DomeniaOperationException(RefreshQueryMissing, RefreshQueryMissingMessage);
        }
        if (wantInventory && probeIds.Any(id => ProbeCatalog.Find(id)?.Slow == true))
        {
            warnings.Add("Une sonde lente fait partie du plan" + FrenchText.Colon + "la collecte WMI sera plus longue.");
        }
        if (simulation)
        {
            warnings.Add("Simulation" + FrenchText.Colon + "l’annuaire fictif est relu en mémoire et les postes fictifs répondent selon des manches déterministes ; aucune connexion réelle.");
        }
        ProbeReadings readings;
        lock (gate)
        {
            readings = probes;
        }
        // ACC-038: workstations whose inventory and probes are already up to date are not contacted (estimate on the last ping).
        var toRead = wantInventory ? RefreshRules.Missing(onlineIds, observations, readings, probeIds, reuseSince, now) : ImmutableArray<Guid>.Empty;
        var reused = wantInventory ? onlineIds.Count - toRead.Length : 0;
        if (wantInventory && reused > 0)
        {
            warnings.Add("Collecter seulement ce qui manque" + FrenchText.Colon + FleetBoardCalculator.Plural(reused, "poste en ligne déjà à jour", "postes en ligne déjà à jour")
                + " (inventaire et sondes de moins de " + FrenchText.Integer(RefreshRules.ReuseDays) + " jours) ne sera pas contacté ; « Tout relire » les relit aussi.");
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
            stages.Add(new RefreshStage("inventory", "Inventaire WMI des postes en ligne", "WMI lu uniquement sur les postes qui ont répondu au ping"
                + (wantPresence ? ", sans nouvel écho ni seconde confirmation" : " lors de l’actualisation interrompue")
                + " ; seulement ce qui manque ou date de plus de " + FrenchText.Integer(RefreshRules.ReuseDays) + " jours"
                + (probeIds.Length > 0 ? " ; " + FleetBoardCalculator.Plural(probeIds.Length, "sonde de widget lue", "sondes de widgets lues") : "") + "."));
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
            + (wantInventory ? " (" + FleetBoardCalculator.Plural(onlineIds.Count, "poste en ligne", "postes en ligne") + " au dernier relevé, " + FleetBoardCalculator.Plural(toRead.Length, "à relever", "à relever") + ")" : "") + ".";
        var (title, summary, confirm) = mode switch
        {
            "directory" => ("Mettre à jour la base locale de l’OU", "Relit l’annuaire de l’OU " + scope.Label + " et de ses sous-OU (" + FleetBoardCalculator.Plural(objects, "objet", "objets") + " dans la base), après une sauvegarde vérifiée de la base locale. Aucun ping ni relevé WMI.", "Lancer la mise à jour"),
            "presence" => ("Actualiser la présence (ping)", "Pingue une fois les " + FleetBoardCalculator.Plural(active.Count, "poste actif", "postes actifs") + " de l’OU " + scope.Label + ". Aucun objet AD n’est modifié.", "Lancer le relevé ping"),
            "inventory" => ("Actualiser l’inventaire (ping puis WMI)", "Pingue les " + FleetBoardCalculator.Plural(active.Count, "poste actif", "postes actifs") + " de l’OU " + scope.Label + ", puis lit WMI uniquement sur ceux qui répondent et dont une mesure manque. Une seule confirmation pour l’enchaînement.", "Lancer ping puis WMI"),
            "resume" => ("Reprendre l’actualisation interrompue", "Reprend les étapes que l’actualisation du " + CollectionClocks.Local(previous!.StartedAt, Zone) + " n’a pas terminées sur l’OU " + scope.Label
                + (wantInventory ? " ; WMI seulement sur les postes en ligne pas encore relus" : "") + ". Les mesures déjà enregistrées sont conservées.", "Reprendre"),
            _ => ("Tout actualiser", "Relit l’annuaire de l’OU " + scope.Label + " (après sauvegarde vérifiée), attend le reçu d’enregistrement, pingue les postes actifs puis lit WMI sur ceux qui répondent et dont une mesure manque. Si la lecture AD échoue, ping et WMI partent sur les postes déjà connus.", "Tout actualiser"),
        };
        var plan = new RefreshPlan(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), mode, title, summary, scope, active.Count, [.. stages], probeIds,
            [.. probeIds.Select(id => ProbeCatalog.Find(id)?.Name ?? id)], seconds, estimate, [.. warnings], confirm, now, now + PlanLifetime,
            wantInventory ? onlineIds.Count : 0, reused, RefreshRules.ReuseDays, reuseSince, resumeOf, onlineSince);
        lock (gate)
        {
            foreach (var expired in plans.Where(p => p.Value.ExpiresAt < now).Select(p => p.Key).ToList())
            {
                plans.Remove(expired);
            }
            plans[plan.Id] = plan;
        }
        return plan;
    }

    /// <summary>The refusal of a new collection, raised as refresh.refused (Get-DomeniaStorageCollectionRefusal, ACC-001).</summary>
    private void EnsureAdmitted()
    {
        bool bit;
        int failures;
        Func<long?>? probe;
        lock (gate)
        {
            bit = bitLockerReading;
            failures = localWriteFailures;
            probe = storageProbe;
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
        var now = Now;
        lock (gate)
        {
            plans.Remove(planId, out plan);
        }
        if (plan is null)
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
        EnsureAdmitted();
        LoadPersisted(domainDn);
        var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var state = new RunState(plan, linked) { StartedAt = now, Forced = force };
        lock (gate)
        {
            if (run is not null)
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
                                var goesOn = stages.Skip(i + 1).Any(st => st.Id is "presence" or "inventory");
                                Record(state, stage, "failed", "Aucun reçu d’enregistrement" + FrenchText.Colon + directoryError
                                    + (goesOn ? " Ping et WMI partent sur les postes déjà connus de la base locale." : ""), started, Now, progress, i, stages.Length);
                                if (!goesOn)
                                {
                                    outcome = "error";
                                    state.Stopping = true;
                                }
                            }
                            else
                            {
                                var goesOn = stages.Skip(i + 1).Any(st => st.Id is "presence" or "inventory");
                                Record(state, stage, "done", "Reçu d’enregistrement" + FrenchText.Colon + "OU " + plan.Scope.Label + ", " + FleetBoardCalculator.Plural(directoryCount ?? 0, "objet", "objets")
                                    + ", lecture complète, même session. " + (goesOn ? "Préparation du relevé des postes." : "Aucun ping ni relevé WMI."), started, Now, progress, i, stages.Length);
                            }
                            break;
                        case "presence":
                            presenceStarted = true;
                            collectionApproved = true;
                            collectionStarted ??= started;
                            latestState = await dashboard.MeasureAsync(MeasureFamily.Presence, token).ConfigureAwait(false);
                            presenceDone = true;
                            var (online, noAnswer, unchecked_) = CountPresence(latestState, plan.Scope, started);
                            Record(state, stage, "done", FleetBoardCalculator.Plural(online, "poste en ligne", "postes en ligne") + " sur " + FrenchText.Integer(online + noAnswer + unchecked_)
                                + " · " + FrenchText.Integer(noAnswer) + " sans réponse" + (unchecked_ > 0 ? " · " + FleetBoardCalculator.Plural(unchecked_, "non vérifié (sonde en erreur)", "non vérifiés (sonde en erreur)") : ""), started, Now, progress, i, stages.Length);
                            break;
                        case "inventory":
                            inventoryStarted = true;
                            collectionApproved = true;
                            collectionStarted ??= started;
                            // ACC-004: WMI only on the workstations that answered the ping of this refresh (or of the interrupted one a
                            // resume completes). ACC-038: of those, only the ones whose inventory or a probe of the plan is missing.
                            var before = latestState ?? await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
                            var onlineIds = OnlineIds(before, plan.Scope, plan.OnlineSince ?? collectionStarted ?? started);
                            ProbeReadings known;
                            lock (gate)
                            {
                                known = probes;
                            }
                            var toRead = RefreshRules.Missing(onlineIds, before.Observations.Workstations.ToDictionary(o => o.ComputerGuid), known, plan.Probes,
                                force ? null : plan.ReuseSince, Now).ToHashSet();
                            inventoryOnline = onlineIds.Count;
                            inventoryContacted = toRead.Count;
                            var probeText = "";
                            if (toRead.Count > 0)
                            {
                                latestState = await dashboard.MeasureAsync((_, t) => Reader.ReadInventoryAsync(plan.Scope, toRead, t), token).ConfigureAwait(false);
                                if (plan.Probes.Length > 0)
                                {
                                    var readings = await Reader.CollectProbesAsync(plan.Probes, plan.Scope, toRead, token).ConfigureAwait(false);
                                    lock (gate)
                                    {
                                        probes = probes.Merge(readings);
                                    }
                                    probeText = " · " + FleetBoardCalculator.Plural(plan.Probes.Length, "sonde de widget lue", "sondes de widgets lues");
                                }
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
                            var usable = toRead.Count(id => measuredById.TryGetValue(id, out var observation) && observation.Inventory.HasReading
                                && observation.Inventory.CheckedAt >= started && plan.Probes.All(probeId =>
                                    ProbeCatalog.Find(probeId)?.SkipOnDc == true && computersById.TryGetValue(id, out var c) && (c.UserAccountControl & 8192) != 0
                                    || afterProbes.ByProbe.TryGetValue(probeId, out var byId) && byId.TryGetValue(id, out var reading)
                                        && reading.State == MeasureState.Known && reading.Error is null && reading.At >= started));
                            inventorySucceeded = reusedNow + usable;
                            inventoryFailed = toRead.Count - usable;
                            if (inventoryFailed > 0)
                            {
                                outcome = "partial";
                                probeText += " · " + FleetBoardCalculator.Plural(inventoryFailed, "poste avec une lecture incomplète ou refusée", "postes avec une lecture incomplète ou refusée");
                            }
                            var detail = onlineIds.Count == 0
                                ? "Aucun poste n’a répondu au ping" + FrenchText.Colon + "aucune lecture WMI."
                                : "Inventaire relu sur " + FleetBoardCalculator.Plural(usable, "poste ayant répondu au ping", "postes ayant répondu au ping")
                                  + (reusedNow > 0 ? " · " + FleetBoardCalculator.Plural(reusedNow, "déjà à jour, non contacté", "déjà à jour, non contactés") : "") + probeText;
                            Record(state, stage, "done", detail, started, Now, progress, i, stages.Length);
                            break;
                    }
                }
                catch (OperationCanceledException) when (state.Stopping && !cancellationToken.IsCancellationRequested)
                {
                    Record(state, stage, "stopped", "Arrêtée" + FrenchText.Colon + "les mesures déjà enregistrées sont conservées ; aucune nouvelle collecte ne sera lancée.", started, Now, progress, i, stages.Length);
                }
                catch (DomeniaOperationException ex) when (stage.Id == "directory" && stages.Skip(i + 1).Any(st => st.Id is "presence" or "inventory"))
                {
                    // « Tout actualiser » (decision of 19/10/2026): a failed AD read does not stop ping and WMI.
                    directoryFailed = true;
                    directoryError = ex.Message;
                    directoryStatus = CollectionStatus.Error;
                    Record(state, stage, "failed", "Lecture AD non aboutie (" + ex.Message + ")" + FrenchText.Colon + "ping et WMI partent sur les postes déjà connus de la base locale.", started, Now, progress, i, stages.Length);
                }
                catch (DomeniaOperationException ex)
                {
                    outcome = "error";
                    if (stage.Id == "directory")
                    {
                        directoryStatus = CollectionStatus.Error;
                        directoryError = ex.Message;
                    }
                    Record(state, stage, "failed", ex.Message, started, Now, progress, i, stages.Length);
                    state.Stopping = true;
                    state.StopReason = "Actualisation interrompue" + FrenchText.Colon + ex.Message + " Aucune nouvelle collecte ne sera lancée.";
                }
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
                var targets = plan.Targets;
                long failed = latestState is null ? 0 : CountPresence(latestState, plan.Scope, collectStart).Unchecked;
                var done = (long)targets;
                if (presenceStarted)
                {
                    var status = presenceDone ? (failed > 0 ? CollectionStatus.Partial : CollectionStatus.Success) : state.Stopping ? CollectionStatus.Cancelled : CollectionStatus.Error;
                    recorded.Add(CollectionClocks.Create(CollectionFamily.Presence, domainDn, plan.Scope.Dn, plan.Scope.Subtree, status, collectStart, finished,
                        status == CollectionStatus.Partial ? FleetBoardCalculator.Plural(failed, "poste avec une lecture non confirmée", "postes avec une lecture non confirmée") + " ; " + FrenchText.Integer(done) + "/" + FrenchText.Integer(targets) + " postes traités."
                        : status == CollectionStatus.Cancelled ? "Relevé arrêté." : null,
                        targets, presenceDone ? done : null, presenceDone ? done - failed : null, presenceDone ? failed : null, null, finished));
                }
                if (inventoryStarted)
                {
                    var status = inventoryDone ? inventoryFailed > 0 ? CollectionStatus.Partial : CollectionStatus.Success : state.Stopping ? CollectionStatus.Cancelled : CollectionStatus.Error;
                    recorded.Add(CollectionClocks.Create(CollectionFamily.Inventory, domainDn, plan.Scope.Dn, plan.Scope.Subtree, status, collectStart, finished,
                        status == CollectionStatus.Cancelled ? "Relevé arrêté." : inventoryFailed > 0 ? "Certaines lectures sont incomplètes ou refusées." : null, inventoryOnline, inventoryDone ? inventoryOnline : null, inventoryDone ? inventorySucceeded : null, inventoryDone ? inventoryFailed : null, null, finished));
                }
            }
            lock (gate)
            {
                sessionRuns.AddRange(recorded);
                latest = null;
            }
            if (recorded.Count > 0)
            {
                await PersistRunsAsync(domainDn, cancellationToken).ConfigureAwait(false);
            }
            state.Runs.AddRange(CollectionClocks.Rows(recorded));
            var label = Outcome(plan, outcome, state.StopReason, directoryFailed);
            context.Journal.Add(new JournalEntry(finished, label + (inventoryStarted && inventoryOnline > inventoryContacted
                ? " · " + FleetBoardCalculator.Plural(inventoryOnline - inventoryContacted, "poste déjà à jour non contacté", "postes déjà à jour non contactés") : ""),
                outcome switch { "success" => Tone.Ok, "partial" => Tone.Warn, "cancelled" => Tone.Info, _ => Tone.Alert }));
            var resumable = outcome != "success" && state.Stages.Any(st => st.State is "skipped" or "stopped" or "failed" or "waiting");
            var report = new RefreshReport(state.Id, plan.Mode, outcome, label, plan.Scope, state.StartedAt, finished, [.. state.Stages], [.. state.Runs], state.Stopping, force, resumable);
            lock (gate)
            {
                lastReport = report;
            }
            return report;
        }
        finally
        {
            lock (gate)
            {
                if (ReferenceEquals(run, state))
                {
                    run = null;
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
            var current = run is null ? null : new RefreshReport(run.Id, run.Plan.Mode, "running", run.Plan.Title, run.Plan.Scope, run.StartedAt, null, [.. run.Stages], [.. run.Runs], run.Stopping, run.Forced);
            return new RefreshState(run is not null, current, lastReport);
        }
    }

    private Task StopForScopeChangeAsync()
    {
        lock (gate)
        {
            if (run is not null)
            {
                run.StopReason = "L’OU de travail a changé" + FrenchText.Colon + "actualisation arrêtée.";
            }
        }
        StopRefresh();
        return Task.CompletedTask;
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

    private static (int Online, int NoAnswer, int Unchecked) CountPresence(DirectoryState state, ScopeSelection scope, DateTimeOffset since)
    {
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).Select(c => c.ObjectGuid).ToHashSet();
        var online = 0;
        var noAnswer = 0;
        foreach (var o in state.Observations.Workstations.Where(o => active.Contains(o.ComputerGuid)))
        {
            if (o.Presence.HasReading && o.Presence.CheckedAt >= since)
            {
                if (o.Presence.Answered == true)
                {
                    online++;
                }
                else
                {
                    noAnswer++;
                }
            }
        }
        return (online, noAnswer, Math.Max(0, active.Count - online - noAnswer));
    }

    private static HashSet<Guid> OnlineIds(DirectoryState state, ScopeSelection scope, DateTimeOffset since)
    {
        var active = state.Directory.Computers.Where(c => !AdValues.IsDisabled(c.UserAccountControl) && ScopeRules.Contains(scope, c.DistinguishedName)).Select(c => c.ObjectGuid).ToHashSet();
        return [.. state.Observations.Workstations.Where(o => active.Contains(o.ComputerGuid) && o.Presence.HasReading && o.Presence.Answered == true && o.Presence.CheckedAt >= since).Select(o => o.ComputerGuid)];
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
                "inventory" => "Ping puis inventaire WMI des postes en ligne" + FrenchText.Colon + where,
                "resume" => "Actualisation interrompue reprise et terminée" + FrenchText.Colon + where,
                _ => "Tout actualisé" + FrenchText.Colon + where + " (objets AD, présence, inventaire WMI)",
            },
            "partial" => directoryFailed ? "Actualisation partielle de l’" + where + FrenchText.Colon + "lecture AD non aboutie, ping et WMI faits sur les postes déjà connus" : "Actualisation partielle" + FrenchText.Colon + where,
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
