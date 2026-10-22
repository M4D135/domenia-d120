using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Opérations screen in simulation (docs/ops/operations.md § 6): collection runs derived from the generated world (its journal and
/// its sites), an interrupted inventory survey of the Bordeaux workstations that the operator can resume, stop or forget, the probes
/// always in error as WMI targets in progressive recovery, statistics of earlier sessions and the directory checks of « Vérifier
/// l’application ». Data depend on the seed and the reference date only (sub-stream « screen/operations »); nothing is read
/// before the first call, no network, no disk. A resumed survey progresses in memory with the clock of the simulation.
/// </summary>
public sealed class SimulatedOperationsReader : IOperationsReader
{
    public const string SurveyBusy = "operations.surveyBusy";
    public const string SurveyBusyMessage = "Un relevé est déjà en cours : la reprise attendra sa fin. Rien n’a été lu.";
    public const string SurveyNone = "operations.surveyNone";
    public const string SurveyNoneMessage = "Aucun relevé interrompu à reprendre : rien n’a été lu.";
    public const string SurveyChanged = "operations.surveyChanged";
    public const string SurveyChangedMessage = "Le relevé interrompu a changé depuis son affichage : relisez-le avant de le reprendre. Rien n’a été lu.";

    private const int PreparingMs = 600;
    private const int ReadingDirectoryMs = 450;
    private const int SavingMs = 700;
    private const int StoppingMs = 400;

    private readonly SimulatedDirectorySource source;
    private readonly Lazy<Derived> derived;
    private readonly Lock gate = new();
    private readonly List<CollectionRun> sessionRuns = [];
    private Survey? survey;
    private int remaining = -1;
    private bool offered;
    private int surveys;

    public SimulatedOperationsReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
        derived = new Lazy<Derived>(Derive, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public string CollectionProfile =>
        "Profil de collecte" + FrenchText.Colon + "simulation (relevés fictifs déterministes, aucune sonde réseau ni WMI). Fenêtre de collecte" + FrenchText.Colon + "sans objet.";

    public async Task<CollectionRunsView> RunsAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("operations/runs", 80, 200, cancellationToken).ConfigureAwait(false);
        var data = derived.Value;
        lock (gate)
        {
            Advance();
            var latest = new Dictionary<(CollectionFamily, string), CollectionRun>();
            foreach (var run in data.Runs.Concat(sessionRuns))
            {
                var key = (run.Family, run.ScopeDn.ToUpperInvariant());
                if (!latest.TryGetValue(key, out var known) || known.AttemptAt <= run.AttemptAt)
                {
                    // A session run keeps the last success of the recorded one when it did not succeed itself.
                    latest[key] = run.SuccessAt is null && known?.SuccessAt is DateTimeOffset success ? run with { SuccessAt = success } : run;
                }
            }
            var rows = latest.Values.OrderByDescending(r => r.AttemptAt).Select(Row).ToImmutableArray();
            var current = State();
            return new CollectionRunsView(source.Clock.GetUtcNow(), true, rows, current, Offer(data), CurrentText(current),
                "Relevés fictifs de la simulation" + FrenchText.Colon + "aucune sonde ne part, les dates suivent l’annuaire généré. Un relevé repris progresse en mémoire.");
        }
    }

    public SurveyState? CurrentSurvey()
    {
        if (!derived.IsValueCreated)
        {
            return null;
        }
        lock (gate)
        {
            Advance();
            return State();
        }
    }

    public async Task<SurveyState> ResumeSurveyAsync(int count, CancellationToken cancellationToken)
    {
        var data = derived.Value;
        lock (gate)
        {
            Advance();
            if (survey is { Open: true })
            {
                throw new DomeniaOperationException(SurveyBusy, SurveyBusyMessage);
            }
            var offer = Offer(data);
            if (!offer.Resumable)
            {
                throw new DomeniaOperationException(SurveyNone, SurveyNoneMessage);
            }
            if (offer.Remaining != count)
            {
                throw new DomeniaOperationException(SurveyChanged, SurveyChangedMessage);
            }
        }
        await source.SimulateScreenLatencyAsync("operations/survey", 120, 260, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            Advance();
            if (survey is { Open: true })
            {
                throw new DomeniaOperationException(SurveyBusy, SurveyBusyMessage);
            }
            var offer = Offer(data);
            if (!offer.Resumable || offer.Remaining != count)
            {
                throw new DomeniaOperationException(SurveyChanged, SurveyChangedMessage);
            }
            surveys++;
            var random = source.ScreenStream("operations").Fork("survey/" + surveys.ToString(CultureInfo.InvariantCulture));
            var steps = new int[count];
            var total = PreparingMs + ReadingDirectoryMs;
            for (var i = 0; i < count; i++)
            {
                total += random.Next(350, 901);
                steps[i] = total;
            }
            // One workstation of the resumed survey does not answer WMI (switched off since), as in the recorded runs; on a longer list,
            // another one does not answer the ping at all (counted apart, never read by WMI).
            var silent = count > 3 ? random.Next(count) : -1;
            var unreachable = -1;
            if (count > 6)
            {
                unreachable = random.Next(count - 1);
                if (unreachable >= silent)
                {
                    unreachable++;
                }
            }
            survey = new Survey(
                "releve-" + surveys.ToString("00", CultureInfo.InvariantCulture), data.Interrupted, steps, silent, unreachable, source.Clock.GetUtcNow(), source.Clock.GetTimestamp());
            offered = true;
            return State()!;
        }
    }

    public SurveyState? StopSurvey()
    {
        if (!derived.IsValueCreated)
        {
            return null;
        }
        lock (gate)
        {
            Advance();
            if (survey is not { Open: true } current)
            {
                return null;
            }
            if (current.StopTimestamp is null)
            {
                current.StopTimestamp = source.Clock.GetTimestamp();
                current.DoneAtStop = DoneOf(current, Elapsed(current));
            }
            return State();
        }
    }

    public Task<SurveyOffer?> ForgetSurveyAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var data = derived.Value;
        lock (gate)
        {
            Advance();
            if (survey is { Open: true })
            {
                throw new DomeniaOperationException(SurveyBusy, "Un relevé est en cours : il ne peut pas être abandonné pendant sa lecture. Arrêtez-le d’abord.");
            }
            remaining = 0;
            offered = true;
            return Task.FromResult<SurveyOffer?>(Offer(data));
        }
    }

    public SurveyOffer? PostponeSurvey()
    {
        var data = derived.Value;
        lock (gate)
        {
            offered = true;
            return Offer(data);
        }
    }

    public async Task<ImmutableArray<ProviderState>> ProviderStatesAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("operations/providers", 20, 60, cancellationToken).ConfigureAwait(false);
        return derived.Value.Providers;
    }

    public async Task<ImmutableArray<OperationSample>> HistoryAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("operations/history", 60, 140, cancellationToken).ConfigureAwait(false);
        return derived.Value.History;
    }

    public async Task<ImmutableArray<CheckRow>> CheckDirectoryAsync(bool full, CancellationToken cancellationToken)
    {
        var rows = new List<CheckRow>();
        var clock = source.Clock;
        async Task Add(string category, string test, Func<Task<(CheckStatus Status, string Detail)>> action)
        {
            var start = clock.GetTimestamp();
            var (status, detail) = await action().ConfigureAwait(false);
            rows.Add(new CheckRow(category, test, status, Math.Round(clock.GetElapsedTime(start).TotalMilliseconds, 1), detail));
        }
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        await Add("Annuaire", "Session", () => Task.FromResult((CheckStatus.Ok,
            "Compte " + session.Account.Login + " · domaine " + (session.Domain?.DnsName ?? "—") + " · contrôleur " + (session.Controller?.DnsName ?? "—") + " (annuaire fictif)."))).ConfigureAwait(false);
        await Add("Annuaire", "Lecture de la base", async () =>
        {
            await source.SimulateScreenLatencyAsync("operations/check", 60, 160, cancellationToken).ConfigureAwait(false);
            var directory = source.CurrentDirectory;
            return (CheckStatus.Ok, "Base " + directory.Domain.RootDn + " lue" + FrenchText.Colon + FrenchText.Count(directory.ObjectCount, "objet", "objets") + ".");
        }).ConfigureAwait(false);
        await Add("Annuaire", "Recherche utilisateur", async () =>
        {
            await source.SimulateScreenLatencyAsync("operations/check", 30, 90, cancellationToken).ConfigureAwait(false);
            var user = source.CurrentDirectory.Users.FirstOrDefault(u => !AdValues.IsDisabled(u.UserAccountControl));
            return user is null ? (CheckStatus.Error, "Aucun utilisateur lisible.") : (CheckStatus.Ok, "Exemple" + FrenchText.Colon + (user.DisplayName ?? user.Cn) + ".");
        }).ConfigureAwait(false);
        await Add("Annuaire", "Recherche machine", async () =>
        {
            await source.SimulateScreenLatencyAsync("operations/check", 30, 90, cancellationToken).ConfigureAwait(false);
            var computer = source.CurrentDirectory.Computers.OrderBy(c => c.Name, StringComparer.Ordinal).FirstOrDefault();
            return computer is null ? (CheckStatus.Error, "Aucune machine lisible.") : (CheckStatus.Ok, "Exemple" + FrenchText.Colon + computer.Name + ".");
        }).ConfigureAwait(false);
        await Add("Annuaire", "Recherche groupe", async () =>
        {
            await source.SimulateScreenLatencyAsync("operations/check", 30, 90, cancellationToken).ConfigureAwait(false);
            var group = source.CurrentDirectory.Groups.OrderBy(g => g.Name, StringComparer.Ordinal).FirstOrDefault();
            return group is null ? (CheckStatus.Error, "Aucun groupe lisible.") : (CheckStatus.Ok, "Exemple" + FrenchText.Colon + group.Name + ".");
        }).ConfigureAwait(false);
        await Add("Annuaire", "Lecture de l’arborescence", async () =>
        {
            await source.SimulateScreenLatencyAsync("operations/check", 30, 90, cancellationToken).ConfigureAwait(false);
            var directory = source.CurrentDirectory;
            var root = directory.Domain.RootDn;
            var branches = directory.OrganizationalUnits.Count(o => DistinguishedName.Parent(o.DistinguishedName) is string parent && DistinguishedName.AreEqual(parent, root))
                + directory.Domain.Containers.Length;
            return (CheckStatus.Ok, FrenchText.Count(branches, "branche lue", "branches lues") + " à la racine du domaine.");
        }).ConfigureAwait(false);
        await Add("Sécurité", "Lecture des droits de la base", () => Task.FromResult((CheckStatus.Info,
            "Non simulée" + FrenchText.Colon + "l’annuaire fictif ne porte aucune liste de contrôle d’accès."))).ConfigureAwait(false);
        if (full)
        {
            await Add("Mesure", "Recherches répétées", async () =>
            {
                var times = new List<double>();
                for (var i = 0; i < 3; i++)
                {
                    var start = clock.GetTimestamp();
                    await source.SimulateScreenLatencyAsync("operations/bench", 30, 90, cancellationToken).ConfigureAwait(false);
                    _ = source.CurrentDirectory.Users.Take(25).Count() + source.CurrentDirectory.Computers.Take(25).Count();
                    times.Add(clock.GetElapsedTime(start).TotalMilliseconds);
                }
                var average = times.Average();
                return (CheckStatus.Ok, "Mesures" + FrenchText.Colon + string.Join(" / ", times.Select(t => FrenchText.Integer((long)Math.Round(t)))) + FrenchText.Nbsp + "ms, moyenne "
                    + ActivityRules.Duration(average) + " (annuaire fictif, 25 objets par recherche).");
            }).ConfigureAwait(false);
        }
        return [.. rows];
    }

    // ---------------------------------------------------------------- survey

    private double Elapsed(Survey s) => source.Clock.GetElapsedTime(s.StartTimestamp).TotalMilliseconds;

    private static int DoneOf(Survey s, double elapsed)
    {
        var done = 0;
        while (done < s.Steps.Length && s.Steps[done] <= elapsed)
        {
            done++;
        }
        return done;
    }

    /// <summary>Moves the survey forward with the clock: preparation, reading, saving, end; or the stop, once asked.</summary>
    private void Advance()
    {
        if (survey is not { Open: true } s)
        {
            return;
        }
        var now = source.Clock.GetTimestamp();
        if (s.StopTimestamp is long stop)
        {
            if (source.Clock.GetElapsedTime(stop, now).TotalMilliseconds < StoppingMs)
            {
                return;
            }
            Finish(s, s.DoneAtStop, CollectionStatus.Cancelled, "Arrêté sur demande" + FrenchText.Colon + "les mesures reçues sont gardées, les postes restants seront proposés de nouveau.");
            return;
        }
        var elapsed = Elapsed(s);
        if (elapsed >= s.Steps[^1] + SavingMs)
        {
            var failed = s.Silent >= 0 ? 1 : 0;
            var ping = s.Unreachable >= 0 ? 1 : 0;
            var reasons = new List<string>();
            if (failed > 0)
            {
                reasons.Add("1 poste sans réponse WMI (éteint ou filtré)");
            }
            if (ping > 0)
            {
                reasons.Add("1 poste sans réponse au ping");
            }
            Finish(s, s.Steps.Length, failed + ping > 0 ? CollectionStatus.Partial : CollectionStatus.Success, reasons.Count > 0 ? string.Join(" · ", reasons) + "." : "");
        }
    }

    private void Finish(Survey s, int done, CollectionStatus status, string reason)
    {
        var data = derived.Value;
        var now = source.Clock.GetUtcNow();
        s.Open = false;
        s.EndedAt = now;
        s.Done = done;
        s.Status = status;
        var failed = status == CollectionStatus.Cancelled ? s.FailedBy(done) : s.Silent >= 0 ? 1 : 0;
        s.Failed = failed;
        s.PingErrors = status == CollectionStatus.Cancelled ? s.PingErrorsBy(done) : s.Unreachable >= 0 ? 1 : 0;
        var previous = Remaining(data);
        remaining = status == CollectionStatus.Cancelled ? Math.Max(0, previous - done) : 0;
        var interrupted = data.Interrupted;
        var total = interrupted.Targets ?? s.Steps.Length;
        var read = total - remaining;
        sessionRuns.Add(new CollectionRun(interrupted.Family, interrupted.ScopeDn, interrupted.ScopeName, interrupted.Subtree, now, status, read, total,
            failed + s.PingErrors, status is CollectionStatus.Success or CollectionStatus.Partial ? now : null, reason));
    }

    private SurveyState? State()
    {
        if (survey is not Survey s)
        {
            return null;
        }
        var elapsed = Elapsed(s);
        var done = s.Open ? (s.StopTimestamp is null ? DoneOf(s, elapsed) : s.DoneAtStop) : s.Done;
        var (phase, label) = !s.Open ? (SurveyPhase.Done, StatusLabel(s.Status))
            : s.StopTimestamp is not null ? (SurveyPhase.Stopping, "Arrêt demandé")
            : elapsed < PreparingMs ? (SurveyPhase.Preparing, "Préparation")
            : elapsed < PreparingMs + ReadingDirectoryMs ? (SurveyPhase.ReadingDirectory, "Lecture AD")
            : done >= s.Steps.Length ? (SurveyPhase.Saving, "Enregistrement")
            : (SurveyPhase.Running, "En cours");
        var failed = s.Open ? s.FailedBy(done) : s.Failed;
        var ping = s.Open ? s.PingErrorsBy(done) : s.PingErrors;
        var inFlight = s.Open && phase == SurveyPhase.Running ? 1 : 0;
        var saves = phase == SurveyPhase.Saving ? 1 : 0;
        // The budget of the simulation always has room: no workstation is left unread for lack of capacity.
        const int Skipped = 0;
        var status = FrenchText.Integer(done) + "/" + FrenchText.Integer(s.Steps.Length) + " postes traités · " + FrenchText.Count(failed, "lecture non confirmée", "lectures non confirmées")
            + " · " + FrenchText.Count(ping, "erreur de ping", "erreurs de ping")
            + " · " + FrenchText.Count(inFlight, "lecture en cours", "lectures en cours")
            + " · " + FrenchText.Count(saves, "enregistrement en attente", "enregistrements en attente")
            + " · " + FrenchText.Count(Skipped, "poste non relu faute de capacité", "postes non relus faute de capacité") + ".";
        var r = s.Run;
        return new SurveyState(s.Id, r.Family, TypeOf(r.Family), r.ScopeDn, OuText(r), s.Steps.Length, done, failed, phase, label, s.Open,
            s.StopTimestamp is not null, s.StartedAt, s.EndedAt, status, ping, inFlight, saves, Skipped);
    }

    private SurveyOffer Offer(Derived data)
    {
        var r = data.Interrupted;
        var left = Remaining(data);
        var open = survey is { Open: true };
        var reason = open
            ? "Relevé en cours" + FrenchText.Colon + "s’il est arrêté, ses postes restants seront proposés ici."
            : left > 0
                ? "Relevé d’inventaire (WMI) de l’OU " + r.ScopeName + " interrompu le " + LocalText(data.InterruptedAt) + FrenchText.Colon
                    + FrenchText.Count(left, "poste restant", "postes restants") + " sur " + FrenchText.Integer(r.Targets ?? 0) + ". « Reprendre » ne lit que ces postes, après confirmation."
                : "Aucun relevé interrompu" + FrenchText.Colon + "rien à reprendre.";
        return new SurveyOffer(!open && left > 0, open ? 0 : left, r.Targets ?? 0, r.Family, TypeOf(r.Family), OuText(r), r.ScopeDn, data.InterruptedAt, reason, offered);
    }

    private int Remaining(Derived data) => remaining >= 0 ? remaining : (data.Interrupted.Targets ?? 0) - (data.Interrupted.Done ?? 0);

    private static string CurrentText(SurveyState? state) =>
        state is { Open: true } s ? s.Type + " · " + s.ScopeName + " — " + s.Status : "Aucun relevé en cours.";

    // ---------------------------------------------------------------- rows

    private static CollectionRunRow Row(CollectionRun run)
    {
        var id = run.Family.ToString().ToLowerInvariant() + ":" + run.ScopeDn.ToLowerInvariant();
        var reason = (run.Reason ?? "").Trim();
        if (reason.Length > 200)
        {
            reason = reason[..200] + "…";
        }
        var tone = run.Status switch
        {
            CollectionStatus.Success => Tone.Ok,
            CollectionStatus.Partial => Tone.Warn,
            CollectionStatus.Cancelled => Tone.Off,
            _ => Tone.Alert,
        };
        return new CollectionRunRow(id, run.Family, TypeOf(run.Family), OuText(run), run.ScopeDn, run.AttemptAt, run.Status, StatusLabel(run.Status), tone,
            Counts(run), run.SuccessAt, reason);
    }

    /// <summary>« 198/200 postes, 2 non confirmés »: only measured counters are written (Domenia 1 Format-DomeniaCollectionCounts).</summary>
    private static string Counts(CollectionRun run)
    {
        if (run.Done is not int done)
        {
            return "";
        }
        var text = FrenchText.Integer(done) + (run.Targets is int targets ? "/" + FrenchText.Integer(targets) : "");
        text += run.Family == CollectionFamily.Directory ? (done > 1 ? " objets AD" : " objet AD") : (done > 1 ? " postes" : " poste");
        if (run.Failed is int failed && failed > 0)
        {
            text += ", " + FrenchText.Integer(failed) + (failed > 1 ? " non confirmés" : " non confirmé");
        }
        return text;
    }

    private static string StatusLabel(CollectionStatus status) => status switch
    {
        CollectionStatus.Success => "réussi",
        CollectionStatus.Partial => "partiel",
        CollectionStatus.Cancelled => "arrêté",
        _ => "en échec",
    };

    private static string TypeOf(CollectionFamily family) => family switch
    {
        CollectionFamily.Directory => "Objets AD",
        CollectionFamily.Presence => "Ping",
        _ => "WMI",
    };

    private static string OuText(CollectionRun run) => run.ScopeName + (run.Subtree ? " et sous-OU" : "");

    private string LocalText(DateTimeOffset at)
    {
        var local = TimeZoneInfo.ConvertTime(at, source.World.TimeZone);
        return local.ToString("dd'/'MM'/'yyyy", CultureInfo.InvariantCulture) + " à " + local.ToString("HH':'mm", CultureInfo.InvariantCulture);
    }

    // ---------------------------------------------------------------- derived data

    private Derived Derive()
    {
        var world = source.World;
        var directory = source.CurrentDirectory;
        var reference = world.Reference;
        var random = source.ScreenStream("operations");
        var root = directory.Domain.RootDn;
        var postes = directory.OrganizationalUnits.FirstOrDefault(o => DistinguishedName.Parent(o.DistinguishedName) is string p && DistinguishedName.AreEqual(p, root)
            && string.Equals(o.Name, "Postes", StringComparison.Ordinal));
        var postesDn = postes?.DistinguishedName ?? "OU=Postes," + root;
        string[] siteOrder = ["Paris", "Lyon", "Marseille", "Lille", "Bordeaux"];
        var sites = siteOrder
            .Select(name => directory.OrganizationalUnits.FirstOrDefault(o => string.Equals(o.Name, name, StringComparison.Ordinal)
                && DistinguishedName.Parent(o.DistinguishedName) is string p && DistinguishedName.AreEqual(p, postesDn)))
            .OfType<DirectoryOu>()
            .ToList();
        int Active(string dn) => directory.Computers.Count(c => !AdValues.IsDisabled(c.UserAccountControl) && DistinguishedName.IsWithin(c.DistinguishedName, dn, true));
        DateTimeOffset Ago(int minutes) => reference - TimeSpan.FromMinutes(minutes);
        var runs = new List<CollectionRun>();
        var underPostes = directory.Computers.Count(c => DistinguishedName.IsWithin(c.DistinguishedName, postesDn, true))
            + directory.OrganizationalUnits.Count(o => DistinguishedName.IsWithin(o.DistinguishedName, postesDn, true));
        runs.Add(new CollectionRun(CollectionFamily.Directory, postesDn, "Postes", true, Ago(12), CollectionStatus.Success, underPostes, null, null, Ago(12), null));

        // Presence (ping) and inventory (WMI) runs per site; the ones named by the fictitious journal keep its dates and counts.
        var presence = random.Fork("presence");
        var inventory = random.Fork("inventory");
        Derived.InterruptedRun? interrupted = null;
        var interruptedAt = Ago(130);
        foreach (var site in sites)
        {
            var total = Active(site.DistinguishedName);
            var name = site.Name;
            var dn = site.DistinguishedName;
            switch (name)
            {
                case "Paris":
                    runs.Add(new CollectionRun(CollectionFamily.Presence, dn, name, true, Ago(28), CollectionStatus.Success, total, total, 0, Ago(28), null));
                    runs.Add(Partial(CollectionFamily.Inventory, dn, name, Ago(1560), total, Math.Min(15, total), NoWmi(Math.Min(15, total))));
                    break;
                case "Lyon":
                    runs.Add(new CollectionRun(CollectionFamily.Presence, dn, name, true, Ago(302), CollectionStatus.Success, total, total, 0, Ago(302), null));
                    runs.Add(Partial(CollectionFamily.Inventory, dn, name, Ago(55), total, Math.Min(8, total), NoWmi(Math.Min(8, total))));
                    break;
                case "Marseille":
                    runs.Add(Partial(CollectionFamily.Presence, dn, name, Ago(1680), total, Math.Min(3, total), "Sondes refusées pour " + FrenchText.Count(Math.Min(3, total), "poste", "postes") + " (pare-feu du site)."));
                    var mrs = inventory.Next(2600, 3400);
                    runs.Add(new CollectionRun(CollectionFamily.Inventory, dn, name, true, Ago(mrs), CollectionStatus.Success, total, total, 0, Ago(mrs), null));
                    break;
                case "Lille":
                    var lil = presence.Next(90, 400);
                    runs.Add(new CollectionRun(CollectionFamily.Presence, dn, name, true, Ago(lil), CollectionStatus.Success, total, total, 0, Ago(lil), null));
                    var lilInv = inventory.Next(3600, 4300);
                    runs.Add(new CollectionRun(CollectionFamily.Inventory, dn, name, true, Ago(lilInv), CollectionStatus.Success, total, total, 0, Ago(lilInv), null));
                    break;
                default:
                    var bdx = presence.Next(1200, 1500);
                    runs.Add(new CollectionRun(CollectionFamily.Presence, dn, name, true, Ago(bdx), CollectionStatus.Success, total, total, 0, Ago(bdx), null));
                    // The interrupted survey of the screen: inventory of Bordeaux, stopped by the closing of the application.
                    var done = Math.Max(1, total * 7 / 12);
                    var lastSuccess = Ago(inventory.Next(11_000, 12_500));
                    var run = new CollectionRun(CollectionFamily.Inventory, dn, name, true, interruptedAt, CollectionStatus.Error, done, total, 0, lastSuccess,
                        "Interrompu" + FrenchText.Colon + "application fermée pendant le relevé (" + FrenchText.Integer(done) + " postes lus sur " + FrenchText.Integer(total) + ").");
                    runs.Add(run);
                    interrupted = new Derived.InterruptedRun(run);
                    break;
            }
        }
        var interruptedRun = interrupted?.Run
            ?? new CollectionRun(CollectionFamily.Inventory, postesDn, "Postes", true, interruptedAt, CollectionStatus.Error, 0, 0, 0, null, null);

        // The probes always in error of the presence model: WMI targets in progressive recovery (healthy sources are not listed).
        var names = world.Presence.ErrorProbes
            .Select(id => directory.Computers.FirstOrDefault(c => c.ObjectGuid == id)?.Name)
            .OfType<string>()
            .Order(StringComparer.Ordinal)
            .ToList();
        ImmutableArray<ProviderState> providers = [.. names.Select(n => new ProviderState("Cim", n, ProviderStateKind.Recovering, null, 1))];

        return new Derived([.. runs], interruptedRun, interruptedAt, providers, History(world, random.Fork("history")));
    }

    private static CollectionRun Partial(CollectionFamily family, string dn, string name, DateTimeOffset at, int total, int failed, string reason) =>
        new(family, dn, name, true, at, failed > 0 ? CollectionStatus.Partial : CollectionStatus.Success, total, total, failed, at, failed > 0 ? reason : null);

    private static string NoWmi(int failed) => FrenchText.Count(failed, "poste sans réponse WMI", "postes sans réponse WMI") + " (éteints ou filtrés).";

    /// <summary>Samples of the 14 previous days, on working hours (deterministic): the local base of an operator who used Domenia.</summary>
    private static ImmutableArray<OperationSample> History(SimulatedWorld world, SeededRandom random)
    {
        (string Operation, int PerDay, int MinMs, int MaxMs, int MinItems, int MaxItems, int FailPercent)[] profiles =
        [
            ("dashboard.summary", 6, 140, 320, 9, 9, 0),
            ("dashboard.widget.refresh", 4, 430, 980, 1, 1, 3),
            ("directory.ou.children", 5, 70, 190, 2, 12, 0),
            ("directory.ou.search", 2, 70, 180, 0, 18, 0),
            ("session.setScope", 1, 45, 130, 1, 1, 0),
            ("accounts.unlock.plan", 1, 100, 260, 1, 1, 8),
            ("write.execute", 1, 520, 1100, 1, 1, 4),
            ("write.receipts.verify", 1, 100, 240, 1, 1, 0),
            ("write.receipts.list", 2, 15, 60, 0, 24, 0),
        ];
        var list = new List<OperationSample>();
        // Sizes of the answers of the remote reads and writes, from their own sub-stream (the dates and durations stay as they were).
        var sizes = random.Fork("sizes");
        var zone = world.TimeZone;
        var today = LocalDays.DateOf(world.Reference, zone);
        for (var back = 14; back >= 1; back--)
        {
            var day = today.AddDays(-back);
            if (day.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday)
            {
                continue;
            }
            var start = LocalDays.StartOf(day, zone);
            foreach (var p in profiles)
            {
                var count = random.Next(0, p.PerDay + 1);
                for (var i = 0; i < count; i++)
                {
                    var at = start + TimeSpan.FromMinutes(random.Next(8 * 60, 18 * 60));
                    var duration = random.Next(p.MinMs, p.MaxMs + 1) + random.NextDouble();
                    var items = random.Next(p.MinItems, p.MaxItems + 1);
                    long? bytes = p.Operation is "dashboard.widget.refresh" or "write.execute" or "write.receipts.verify" ? 600L + (items * (long)sizes.Next(700, 2400)) : null;
                    // The simulation reaches nothing: no remote attempt, no fallback.
                    list.Add(new OperationSample(p.Operation, at, Math.Round(duration, 1), items, !random.Chance(p.FailPercent), false, bytes, 0, 0));
                }
            }
        }
        return [.. list.OrderBy(s => s.At)];
    }

    private sealed record Derived(
        ImmutableArray<CollectionRun> Runs,
        CollectionRun Interrupted,
        DateTimeOffset InterruptedAt,
        ImmutableArray<ProviderState> Providers,
        ImmutableArray<OperationSample> History)
    {
        public sealed record InterruptedRun(CollectionRun Run);
    }

    /// <summary>A resumed survey: cumulative end of each workstation (ms from the start), the silent one, its stop and its end.</summary>
    private sealed class Survey(string id, CollectionRun run, int[] steps, int silent, int unreachable, DateTimeOffset startedAt, long startTimestamp)
    {
        public string Id { get; } = id;
        public CollectionRun Run { get; } = run;
        public int[] Steps { get; } = steps;
        public int Silent { get; } = silent;
        public int Unreachable { get; } = unreachable;
        public int PingErrors { get; set; }
        public DateTimeOffset StartedAt { get; } = startedAt;
        public long StartTimestamp { get; } = startTimestamp;
        public bool Open { get; set; } = true;
        public long? StopTimestamp { get; set; }
        public int DoneAtStop { get; set; }
        public int Done { get; set; }
        public int Failed { get; set; }
        public CollectionStatus Status { get; set; }
        public DateTimeOffset? EndedAt { get; set; }

        public int FailedBy(int done) => Silent >= 0 && Silent < done ? 1 : 0;

        public int PingErrorsBy(int done) => Unreachable >= 0 && Unreachable < done ? 1 : 0;
    }
}
