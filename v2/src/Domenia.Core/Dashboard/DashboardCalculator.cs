using System.Collections.Immutable;
using System.Collections.ObjectModel;

namespace Domenia.Core;

/// <summary>
/// Pure computation of the home widgets (docs/OPERATIONS.md § 4 and 5). Same input, same result: the clock, the time zone and
/// the thresholds are inputs; nothing is read from the machine. Works the same on the simulated and the real directory.
/// </summary>
public static class DashboardCalculator
{
    public const string DisabledDetail = "Mesure désactivée : ce widget ne lit rien tant qu’il n’est pas réactivé.";
    public const string NoPresenceDetail = "Aucun relevé de présence : actualisez ce widget pour vérifier les postes de l’OU.";
    public const string NoInventoryDetail = "Aucun relevé d’inventaire : actualisez ce widget pour mesurer l’espace disque.";
    public const string NoJournalDetail = "Aucune opération enregistrée pour l’instant.";
    public const string NoMemoryDetail = "Aucune mesure en mémoire : actualisez ce widget.";

    public static DashboardSummary Compute(DashboardInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var context = new Context(input);
        var widgets = new OrderedDictionary<string, DashboardWidget>(StringComparer.Ordinal);
        foreach (var definition in WidgetCatalog.All)
        {
            widgets.Add(definition.Id, context.Widget(definition));
        }
        var snapshot = input.State.Directory;
        return new DashboardSummary(
            input.Now,
            input.Scope,
            new StoreStatus(snapshot.ReadAt, snapshot.ObjectCount, snapshot.Complete),
            new ReadOnlyDictionary<string, DashboardWidget>(widgets));
    }

    public static DashboardWidget ComputeWidget(string widgetId, DashboardInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (!WidgetCatalog.TryGet(widgetId, out var definition))
        {
            throw new DomeniaOperationException(DomeniaErrors.WidgetUnknown, DomeniaErrors.WidgetUnknownReadMessage);
        }
        return new Context(input).Widget(definition);
    }

    /// <summary>Single shape of a disabled widget, whatever its kind.</summary>
    public static DashboardWidget Disabled(WidgetDefinition definition, string scopeLabel)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return new(definition.Id, definition.Kind, definition.Title, scopeLabel, false, Tone.Off, null, false, DisabledDetail, null);
    }

    /// <summary>Enabled widget without any measure: no data, tone off, the detail says what to do.</summary>
    public static DashboardWidget NotMeasured(WidgetDefinition definition, string scopeLabel, string detail)
    {
        ArgumentNullException.ThrowIfNull(definition);
        return new(definition.Id, definition.Kind, definition.Title, scopeLabel, true, Tone.Off, null, false, detail, null);
    }

    /// <summary>
    /// « Domaine example.local », « OU Postes » or « Session ». A working scope on the domain root (whole domain) is labelled
    /// like the domain widgets.
    /// </summary>
    public static string ScopeLabel(WidgetDefinition definition, string? domainDnsName, ScopeSelection? scope, string? rootDn = null)
    {
        ArgumentNullException.ThrowIfNull(definition);
        var domainLabel = domainDnsName is null ? "Domaine" : "Domaine " + domainDnsName;
        return definition.Scope switch
        {
            WidgetScope.Domain => domainLabel,
            WidgetScope.WorkingOu when scope is not null && ScopeRules.IsDomainRoot(scope, rootDn) => domainLabel,
            WidgetScope.WorkingOu => scope is null ? "OU de travail" : "OU " + scope.Label,
            _ => "Session",
        };
    }

    /// <summary>Percentages to the tenth by the largest remainder method: their sum is exactly 100.0.</summary>
    public static ImmutableArray<double> LargestRemainderPercents(IReadOnlyList<int> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        long total = 0;
        foreach (var v in values)
        {
            total += v;
        }
        if (total <= 0)
        {
            return [.. values.Select(_ => 0.0)];
        }
        var tenths = new long[values.Count];
        var remainders = new long[values.Count];
        long assigned = 0;
        for (var i = 0; i < values.Count; i++)
        {
            var numerator = values[i] * 1000L;
            tenths[i] = numerator / total;
            remainders[i] = numerator % total;
            assigned += tenths[i];
        }
        var order = Enumerable.Range(0, values.Count).OrderByDescending(i => remainders[i]).ThenBy(i => i).ToList();
        for (var k = 0; assigned < 1000 && k < order.Count; k++, assigned++)
        {
            tenths[order[k]]++;
        }
        return [.. tenths.Select(t => t / 10.0)];
    }

    public static double RoundTenth(double value) => Math.Round(value, 1, MidpointRounding.AwayFromZero);

    private sealed record Workstation(DirectoryComputer Computer, WorkstationObservation? Observation)
    {
        public PresenceMeasure Presence => Observation?.Presence ?? PresenceMeasure.Unread;

        public InventoryMeasure Inventory => Observation?.Inventory ?? InventoryMeasure.Unread;
    }

    private sealed record WatchPoint(WatchRule Rule, Tone Severity, double SortValue, string Reason);

    /// <summary>Per-call precomputation; never mutates the input.</summary>
    private sealed class Context
    {
        private readonly DashboardInput input;
        private readonly DashboardPolicy policy;
        private readonly DirectorySnapshot snapshot;
        private readonly DateTimeOffset now;
        private readonly DateOnly today;
        private readonly Lazy<List<Workstation>> workstations;
        private readonly Lazy<List<DirectoryUser>> activeUsers;
        // Workstation figures of the history belong to the OU they were recorded for: never shown for another one.
        private readonly bool historyOfScope;

        public Context(DashboardInput input)
        {
            ArgumentNullException.ThrowIfNull(input.State);
            ArgumentNullException.ThrowIfNull(input.Scope);
            ArgumentNullException.ThrowIfNull(input.Policy);
            ArgumentNullException.ThrowIfNull(input.TimeZone);
            ArgumentNullException.ThrowIfNull(input.DisabledWidgets);
            this.input = input;
            policy = input.Policy;
            snapshot = input.State.Directory;
            now = input.Now;
            today = LocalDays.DateOf(now, input.TimeZone);
            workstations = new Lazy<List<Workstation>>(LoadWorkstations, LazyThreadSafetyMode.None);
            activeUsers = new Lazy<List<DirectoryUser>>(() => [.. snapshot.Users.Where(u => !AdValues.IsDisabled(u.UserAccountControl))], LazyThreadSafetyMode.None);
            historyOfScope = input.State.HistoryScope is null || ScopeRules.SameScope(input.State.HistoryScope, input.Scope);
        }

        /// <summary>A workstation figure of the history, or null when the history was recorded for another OU.</summary>
        private Func<DailyFigures, int?> OfScope(Func<DailyFigures, int?> figure) => historyOfScope ? figure : static _ => null;

        private List<Workstation> Workstations => workstations.Value;

        public DashboardWidget Widget(WidgetDefinition definition)
        {
            var scopeLabel = ScopeLabel(definition, snapshot.Domain.DnsName, input.Scope, input.RootDn ?? snapshot.Domain.RootDn);
            if (input.DisabledWidgets.Contains(definition.Id))
            {
                return Disabled(definition, scopeLabel);
            }
            var requested = definition.Scope == WidgetScope.Domain
                ? new ScopeSelection(snapshot.Domain.RootDn, snapshot.Domain.DnsName, true) : input.Scope;
            if (definition.Scope == WidgetScope.Domain && !snapshot.CoversScope(requested))
            {
                return NotMeasured(definition, scopeLabel, "Le relevé disponible ne couvre pas tous les comptes du domaine. Aucun total n’est déduit des seuls objets connus.");
            }
            if (definition.Scope == WidgetScope.WorkingOu && !snapshot.IncludesScope(requested))
            {
                return NotMeasured(definition, scopeLabel, "Cette OU n’est pas couverte par le relevé disponible. Mettez à jour sa base locale pour calculer ses indicateurs.");
            }
            return definition.Id switch
            {
                WidgetCatalog.WorkstationsOnline => WorkstationsOnline(definition, scopeLabel),
                WidgetCatalog.ActiveAccounts => ActiveAccounts(definition, scopeLabel),
                WidgetCatalog.LockedAccounts => LockedAccounts(definition, scopeLabel),
                WidgetCatalog.PasswordsExpiring => PasswordsExpiring(definition, scopeLabel),
                WidgetCatalog.DiskAlerts => DiskAlerts(definition, scopeLabel),
                WidgetCatalog.OsDistribution => OsDistribution(definition, scopeLabel),
                WidgetCatalog.WorkstationActivity => WorkstationActivity(definition, scopeLabel),
                WidgetCatalog.MeasureFreshness => MeasureFreshness(definition, scopeLabel),
                WidgetCatalog.Watchlist => Watchlist(definition, scopeLabel),
                _ => RecentOperations(definition, scopeLabel),
            };
        }

        private List<Workstation> LoadWorkstations()
        {
            var observations = new Dictionary<Guid, WorkstationObservation>();
            foreach (var observation in input.State.Observations.Workstations)
            {
                observations[observation.ComputerGuid] = observation;
            }
            var scopeRdns = DistinguishedName.Parse(input.Scope.Dn);
            var result = new List<Workstation>();
            foreach (var computer in snapshot.Computers)
            {
                if (AdValues.IsDisabled(computer.UserAccountControl)
                    || !DistinguishedName.IsWithin(DistinguishedName.Parse(computer.DistinguishedName), scopeRdns, input.Scope.Subtree))
                {
                    continue;
                }
                result.Add(new Workstation(computer, observations.GetValueOrDefault(computer.ObjectGuid)));
            }
            return result;
        }

        private DashboardWidget Measured(WidgetDefinition definition, string scopeLabel, Tone tone, DateTimeOffset measuredAt, string detail, object data)
        {
            var partial = definition.Scope == WidgetScope.WorkingOu && !snapshot.Complete;
            if (partial) { detail += " Relevé partiel : chiffres limités aux objets connus, sans total garanti pour l’OU."; }
            var stale = now - measuredAt > policy.StaleAfter;
            return new DashboardWidget(definition.Id, definition.Kind, definition.Title, scopeLabel, true, stale || partial ? Tone.Off : tone, measuredAt, stale, detail, data);
        }

        private bool IsRecent(DateTimeOffset? at) => at is DateTimeOffset a && now - a < policy.ObservationMaxAge;

        private DateTimeOffset? LatestPresence() => Max(Workstations.Where(w => w.Presence.HasReading).Select(w => w.Presence.CheckedAt));

        private DateTimeOffset? LatestInventory() => Max(Workstations.Where(w => w.Inventory.HasReading).Select(w => w.Inventory.CheckedAt));

        private static DateTimeOffset? Max(IEnumerable<DateTimeOffset?> dates)
        {
            DateTimeOffset? max = null;
            foreach (var date in dates)
            {
                if (date is DateTimeOffset d && (max is null || d > max))
                {
                    max = d;
                }
            }
            return max;
        }

        /// <summary>Free percentage of C: from a usable inventory reading (recent, size read), otherwise null.</summary>
        private double? FreePercent(InventoryMeasure inventory)
        {
            if (!inventory.HasReading || !IsRecent(inventory.CheckedAt)
                || inventory.SystemDiskSizeBytes is not long size || size <= 0
                || inventory.SystemDiskFreeBytes is not long free || free < 0 || free > size)
            {
                return null;
            }
            return (double)((decimal)free * 100m / size);
        }

        // ---- KPI helpers ----

        private KpiData Kpi(int value, int? total, string unit, Func<DailyFigures, int?> figure, Func<int, Tone> deltaTone, ImmutableArray<BreakdownItem> breakdown)
        {
            var first = today.AddDays(-(policy.HistoryDays - 1));
            var byDay = new SortedDictionary<DateOnly, int>();
            foreach (var day in input.State.History)
            {
                if (day.Day >= first && day.Day < today && figure(day) is int v && !byDay.ContainsKey(day.Day))
                {
                    byDay.Add(day.Day, v);
                }
            }
            var history = ImmutableArray.CreateBuilder<HistoryPoint>(byDay.Count + 1);
            foreach (var (day, v) in byDay)
            {
                history.Add(new HistoryPoint(day, v));
            }
            history.Add(new HistoryPoint(today, value));

            KpiDelta? delta = null;
            if (byDay.TryGetValue(today.AddDays(-policy.DeltaDays), out var past))
            {
                var difference = value - past;
                delta = new KpiDelta(difference, $"P{policy.DeltaDays}D", FrenchText.DeltaLabel(difference, policy.DeltaDays), deltaTone(difference));
            }
            return new KpiData(value, total, unit, delta, history.ToImmutable(), breakdown);
        }

        private static Func<int, Tone> RiseIs(Tone rise) => d => d > 0 ? rise : d < 0 ? Tone.Ok : Tone.Info;

        private static Tone AlwaysInfo(int _) => Tone.Info;

        // ---- Widgets ----

        private DashboardWidget WorkstationsOnline(WidgetDefinition definition, string scopeLabel)
        {
            var latest = LatestPresence();
            if (latest is not DateTimeOffset measuredAt)
            {
                return NotMeasured(definition, scopeLabel, NoPresenceDetail);
            }
            int online = 0, noAnswer = 0, notChecked = 0;
            foreach (var w in Workstations)
            {
                var p = w.Presence;
                if (p.HasReading && IsRecent(p.CheckedAt))
                {
                    if (p.Answered == true)
                    {
                        online++;
                    }
                    else
                    {
                        noAnswer++;
                    }
                }
                else
                {
                    notChecked++;
                }
            }
            var data = Kpi(online, Workstations.Count, "postes", OfScope(d => d.WorkstationsOnline), AlwaysInfo,
            [
                new BreakdownItem("online", "En ligne", online, Tone.Ok),
                new BreakdownItem("noAnswer", "Sans réponse", noAnswer, Tone.Warn),
                new BreakdownItem("notChecked", "Non vérifié", notChecked, Tone.Off),
            ]);
            var detail = $"Dernier relevé de présence de moins de {FrenchText.Count(policy.ObservationMaxAge.Days, "jour", "jours")}. Une absence de réponse ne prouve pas que le poste est éteint.";
            // A missing answer is never a verdict: the widget stays informative.
            return Measured(definition, scopeLabel, Tone.Info, measuredAt, detail, data);
        }

        private DashboardWidget ActiveAccounts(WidgetDefinition definition, string scopeLabel)
        {
            var active = activeUsers.Value.Count;
            var disabled = snapshot.Users.Length - active;
            var data = Kpi(active, null, "comptes", d => d.ActiveAccounts, AlwaysInfo,
            [
                new BreakdownItem("enabled", "Actifs", active, Tone.Ok),
                new BreakdownItem("disabled", "Désactivés", disabled, Tone.Off),
            ]);
            return Measured(definition, scopeLabel, Tone.Info, snapshot.ReadAt, "Comptes utilisateurs activés de tout le domaine (userAccountControl).", data);
        }

        private DashboardWidget LockedAccounts(WidgetDefinition definition, string scopeLabel)
        {
            int locked = 0, toCheck = 0;
            foreach (var user in activeUsers.Value)
            {
                switch (AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime).Lock)
                {
                    case LockState.Locked:
                        locked++;
                        break;
                    case LockState.ToCheck:
                        toCheck++;
                        break;
                    default:
                        break;
                }
            }
            var data = Kpi(locked, null, "comptes", d => d.LockedAccounts, RiseIs(Tone.Alert),
            [
                new BreakdownItem("locked", "Verrouillés", locked, Tone.Alert),
                new BreakdownItem("toCheck", "À vérifier", toCheck, Tone.Off),
            ]);
            return Measured(definition, scopeLabel, locked > 0 ? Tone.Alert : Tone.Ok, snapshot.ReadAt,
                "Verrouillage calculé par le contrôleur (msDS-User-Account-Control-Computed), comptes actifs.", data);
        }

        private DashboardWidget PasswordsExpiring(WidgetDefinition definition, string scopeLabel)
        {
            int expiring = 0, expired = 0, mustChange = 0, neverExpires = 0;
            var maxAge = snapshot.Domain.PasswordPolicy.MaxPasswordAge;
            foreach (var user in activeUsers.Value)
            {
                switch (AccountState.ClassifyPassword(user, maxAge, now, policy.PasswordExpiringWindow))
                {
                    case PasswordClass.Expiring:
                        expiring++;
                        break;
                    case PasswordClass.Expired:
                        expired++;
                        break;
                    case PasswordClass.MustChange:
                        mustChange++;
                        break;
                    case PasswordClass.NeverExpires:
                        neverExpires++;
                        break;
                    default:
                        break;
                }
            }
            var data = Kpi(expiring, null, "comptes", d => d.PasswordsExpiring, RiseIs(Tone.Warn),
            [
                new BreakdownItem("expiring", $"Expirent sous {FrenchText.Count(policy.PasswordExpiringWindow.Days, "jour", "jours")}", expiring, Tone.Warn),
                new BreakdownItem("expired", "Déjà expirés", expired, Tone.Alert),
                new BreakdownItem("mustChange", "À changer à la prochaine connexion", mustChange, Tone.Info),
                new BreakdownItem("neverExpires", "N’expirent jamais", neverExpires, Tone.Off),
            ]);
            return Measured(definition, scopeLabel, expiring > 0 ? Tone.Warn : Tone.Ok, snapshot.ReadAt,
                "Expiration calculée par le contrôleur (msDS-UserPasswordExpiryTimeComputed), comptes actifs.", data);
        }

        private DashboardWidget DiskAlerts(WidgetDefinition definition, string scopeLabel)
        {
            var latest = LatestInventory();
            if (latest is not DateTimeOffset measuredAt)
            {
                return NotMeasured(definition, scopeLabel, NoInventoryDetail);
            }
            int critical = 0, tight = 0, healthy = 0, unknown = 0;
            foreach (var w in Workstations)
            {
                switch (FreePercent(w.Inventory))
                {
                    case null:
                        unknown++;
                        break;
                    case double p when p < policy.DiskFreeAlertPercent:
                        critical++;
                        break;
                    case double p when p < policy.DiskFreeWarnPercent:
                        tight++;
                        break;
                    default:
                        healthy++;
                        break;
                }
            }
            var alert = policy.DiskFreeAlertPercent;
            var warn = policy.DiskFreeWarnPercent;
            var data = Kpi(critical, null, "postes", OfScope(d => d.DiskAlerts), RiseIs(Tone.Alert),
            [
                new BreakdownItem("critical", $"Moins de {alert}{FrenchText.Nbsp}% libre", critical, Tone.Alert),
                new BreakdownItem("tight", $"{alert} à {warn}{FrenchText.Nbsp}% libre", tight, Tone.Warn),
                new BreakdownItem("healthy", $"{warn}{FrenchText.Nbsp}% et plus", healthy, Tone.Ok),
                new BreakdownItem("unknown", "Sans relevé", unknown, Tone.Off),
            ]);
            var measured = critical + tight + healthy;
            var detail = $"Moins de {alert}{FrenchText.Nbsp}% libre sur C: · {FrenchText.Count(measured, "poste relevé", "postes relevés")} sur {FrenchText.Integer(Workstations.Count)}.";
            var tone = critical > 0 ? Tone.Alert : tight > 0 ? Tone.Warn : Tone.Ok;
            return Measured(definition, scopeLabel, tone, measuredAt, detail, data);
        }

        private DashboardWidget OsDistribution(WidgetDefinition definition, string scopeLabel)
        {
            var groups = new Dictionary<string, (string Label, int Value)>(StringComparer.Ordinal);
            foreach (var w in Workstations)
            {
                var release = WindowsRelease.Describe(w.Computer.OperatingSystem, w.Computer.OperatingSystemVersion);
                var key = release?.Key ?? "nonRenseigne";
                var label = release?.Label ?? "Système non renseigné";
                groups[key] = groups.TryGetValue(key, out var current) ? (current.Label, current.Value + 1) : (label, 1);
            }
            var ranked = groups.Select(g => (Key: g.Key, g.Value.Label, g.Value.Value))
                .OrderByDescending(g => g.Value).ThenBy(g => g.Label, StringComparer.Ordinal).ThenBy(g => g.Key, StringComparer.Ordinal).ToList();
            var parts = new List<(string Key, string Label, int Value, ImmutableArray<string> Members)>();
            const int Shown = 4;
            if (ranked.Count <= Shown)
            {
                parts.AddRange(ranked.Select(r => (r.Key, r.Label, r.Value, ImmutableArray<string>.Empty)));
            }
            else
            {
                parts.AddRange(ranked.Take(Shown).Select(r => (r.Key, r.Label, r.Value, ImmutableArray<string>.Empty)));
                var rest = ranked.Skip(Shown).ToList();
                parts.Add(("autres", "Autres", rest.Sum(r => r.Value), rest.Select(r => r.Label).ToImmutableArray()));
            }
            var percents = LargestRemainderPercents([.. parts.Select(p => p.Value)]);
            var segments = ImmutableArray.CreateRange(parts.Select((p, i) => new DistributionSegment(p.Key, p.Label, p.Value, percents[i], p.Members)));
            var total = Workstations.Count;
            var lead = segments.IsEmpty ? null : new DistributionLead(segments[0].Label, segments[0].Percent);
            var data = new DistributionData(total, "postes", FrenchText.Count(total, "poste", "postes"), segments, lead);
            return Measured(definition, scopeLabel, Tone.Info, snapshot.ReadAt,
                "Attributs operatingSystem et operatingSystemVersion des comptes ordinateur activés.", data);
        }

        private DashboardWidget WorkstationActivity(WidgetDefinition definition, string scopeLabel)
        {
            var anyPresence = Workstations.Any(w => w.Presence.HasReading || w.Presence.LastOnlineAt is not null);
            var seenToday = Workstations.Count(w => w.Presence.LastOnlineAt is DateTimeOffset seen && LocalDays.DateOf(seen, input.TimeZone) == today);
            var points = ImmutableArray.CreateBuilder<SeriesPoint>(policy.SeriesDays);
            for (var offset = policy.SeriesDays - 1; offset >= 0; offset--)
            {
                var day = today.AddDays(-offset);
                int? value;
                if (offset == 0)
                {
                    value = anyPresence ? seenToday : null;
                }
                else
                {
                    value = historyOfScope ? input.State.History.FirstOrDefault(h => h.Day == day)?.WorkstationsSeen : null;
                }
                points.Add(new SeriesPoint(day, FrenchText.DayAbbreviation(day.DayOfWeek), value, offset == 0));
            }
            var built = points.ToImmutable();
            var max = built.Select(p => p.Value ?? 0).DefaultIfEmpty(0).Max();
            var data = new SeriesData("postes", max, built);
            return Measured(definition, scopeLabel, Tone.Info, now,
                "Postes distincts ayant répondu au relevé de présence, par jour. Aujourd’hui : journée en cours.", data);
        }

        private DashboardWidget MeasureFreshness(WidgetDefinition definition, string scopeLabel)
        {
            var latest = LatestPresence();
            if (latest is not DateTimeOffset measuredAt || Workstations.Count == 0)
            {
                return NotMeasured(definition, scopeLabel, NoPresenceDetail);
            }
            var freshLimit = TimeSpan.FromDays(policy.FreshDays);
            int recent = 0, aging = 0, expired = 0, never = 0;
            foreach (var w in Workstations)
            {
                var p = w.Presence;
                if (!p.HasReading || p.CheckedAt is not DateTimeOffset checkedAt)
                {
                    never++;
                }
                else if (now - checkedAt < freshLimit)
                {
                    recent++;
                }
                else if (now - checkedAt < policy.ObservationMaxAge)
                {
                    aging++;
                }
                else
                {
                    expired++;
                }
            }
            var total = Workstations.Count;
            var percent = RoundTenth(recent * 100.0 / total);
            var maxDays = policy.ObservationMaxAge.Days;
            var data = new GaugeData(percent, recent, total, policy.FreshDays,
            [
                new BreakdownItem("recent", $"Moins de {FrenchText.Count(policy.FreshDays, "jour", "jours")}", recent, Tone.Ok),
                new BreakdownItem("aging", $"{policy.FreshDays} à {FrenchText.Count(maxDays, "jour", "jours")}", aging, Tone.Warn),
                new BreakdownItem("expired", $"Plus de {FrenchText.Count(maxDays, "jour", "jours")}", expired, Tone.Alert),
                new BreakdownItem("never", "Jamais relevé", never, Tone.Off),
            ]);
            var tone = percent >= policy.FreshnessOkPercent ? Tone.Ok : percent >= policy.FreshnessWarnPercent ? Tone.Warn : Tone.Alert;
            return Measured(definition, scopeLabel, tone, measuredAt,
                $"Postes actifs dont le dernier relevé de présence date de moins de {FrenchText.Count(policy.FreshDays, "jour", "jours")}.", data);
        }

        private DashboardWidget Watchlist(WidgetDefinition definition, string scopeLabel)
        {
            var rows = new List<(WatchlistRow Row, WatchPoint Top)>();
            foreach (var w in Workstations)
            {
                var points = WatchPoints(w);
                if (points.Count == 0)
                {
                    continue;
                }
                var top = points[0];
                var computer = w.Computer;
                rows.Add((new WatchlistRow(computer.Name, computer.DistinguishedName, computer.ObjectGuid.ToString("D"), top.Rule, top.Reason, top.Severity,
                    points.Count - 1, w.Presence.LastOnlineAt), top));
            }
            var ordered = rows
                .OrderBy(r => r.Top.Severity == Tone.Alert ? 0 : 1)
                .ThenBy(r => (int)r.Top.Rule)
                .ThenBy(r => r.Top.SortValue)
                .ThenBy(r => r.Row.Name, StringComparer.Ordinal)
                .Select(r => r.Row)
                .ToList();
            var shown = ordered.Take(policy.WatchlistRows).ToImmutableArray();
            var data = new WatchlistData(ordered.Count, shown.Length, shown);
            // Disk and restart rules need a recent inventory: without one, an empty list is not a healthy verdict.
            var inventoryKnown = IsRecent(LatestInventory());
            var tone = ordered.Count > 0 ? (ordered[0].Severity == Tone.Alert ? Tone.Alert : Tone.Warn) : inventoryKnown ? Tone.Ok : Tone.Info;
            var detail = ordered.Count == 0
                ? (inventoryKnown ? "Aucun point d’attention sur les postes du périmètre." : "Aucun point d’attention dans l’annuaire.")
                : $"{FrenchText.Count(ordered.Count, "poste", "postes")} avec au moins un point d’attention, du plus grave au moins grave.";
            if (!inventoryKnown)
            {
                detail += $" Aucun relevé d’inventaire de moins de {FrenchText.Count(policy.ObservationMaxAge.Days, "jour", "jours")}{FrenchText.Colon}disques et redémarrages non évalués.";
            }
            // The list mixes directory, presence and inventory figures: it is as old as the oldest of them.
            DateTimeOffset measuredAt = snapshot.ReadAt;
            if (LatestPresence() is DateTimeOffset presence && presence < measuredAt)
            {
                measuredAt = presence;
            }
            if (LatestInventory() is DateTimeOffset inventory && inventory < measuredAt)
            {
                measuredAt = inventory;
            }
            return Measured(definition, scopeLabel, tone, measuredAt, detail, data);
        }

        /// <summary>Points of attention of one workstation, in rule order (the first one is the most serious).</summary>
        private List<WatchPoint> WatchPoints(Workstation w)
        {
            var points = new List<WatchPoint>();
            var computer = w.Computer;
            var free = FreePercent(w.Inventory);
            if (free is double low && low < policy.DiskFreeAlertPercent)
            {
                points.Add(new WatchPoint(WatchRule.LowDisk, Tone.Alert, low, $"Disque C presque plein{FrenchText.Colon}{FrenchText.Percent(low)} libre"));
            }
            var lastLogon = AdValues.FromFileTime(computer.LastLogonTimestamp);
            if (lastLogon is null)
            {
                var createdDays = Days(now - computer.WhenCreated);
                points.Add(new WatchPoint(WatchRule.NeverLoggedOn, Tone.Warn, -createdDays,
                    $"Aucune connexion au domaine enregistrée (compte créé il y a {FrenchText.Count(createdDays, "jour", "jours")})"));
            }
            else if (now - lastLogon.Value > TimeSpan.FromDays(policy.StaleLogonDays))
            {
                var staleDays = Days(now - lastLogon.Value);
                points.Add(new WatchPoint(WatchRule.Stale, Tone.Warn, -staleDays,
                    $"Sans connexion au domaine depuis {FrenchText.Count(staleDays, "jour", "jours")}"));
            }
            if (AdValues.FromFileTime(computer.PasswordLastSet) is DateTimeOffset passwordSet && now - passwordSet > TimeSpan.FromDays(policy.MachinePasswordDays))
            {
                var passwordDays = Days(now - passwordSet);
                points.Add(new WatchPoint(WatchRule.MachinePasswordOld, Tone.Warn, -passwordDays,
                    $"Mot de passe machine changé il y a {FrenchText.Count(passwordDays, "jour", "jours")}"));
            }
            if (free is double tight && tight >= policy.DiskFreeAlertPercent && tight < policy.DiskFreeWarnPercent)
            {
                points.Add(new WatchPoint(WatchRule.DiskTight, Tone.Warn, tight, $"Peu d’espace sur le disque C{FrenchText.Colon}{FrenchText.Percent(tight)} libre"));
            }
            if (free is not null && w.Inventory.LastBootAt is DateTimeOffset boot && boot <= now && now - boot > TimeSpan.FromDays(policy.UptimeDays))
            {
                var uptimeDays = Days(now - boot);
                points.Add(new WatchPoint(WatchRule.Uptime, Tone.Warn, -uptimeDays, $"Sans redémarrage depuis {FrenchText.Count(uptimeDays, "jour", "jours")}"));
            }
            return points;
        }

        private static int Days(TimeSpan span) => span <= TimeSpan.Zero ? 0 : (int)Math.Floor(span.TotalDays);

        private DashboardWidget RecentOperations(WidgetDefinition definition, string scopeLabel)
        {
            var entries = input.Journal.OrderByDescending(e => e.At).ToList();
            if (entries.Count == 0)
            {
                return NotMeasured(definition, scopeLabel, NoJournalDetail);
            }
            var rows = entries.Take(policy.TimelineRows).Select(e => new TimelineRow(e.Label, e.At, e.Tone == Tone.Off ? Tone.Info : e.Tone)).ToImmutableArray();
            var detail = input.SourceKind == DirectorySourceKind.Simulation
                ? "Journal fictif de la simulation, les plus récentes d’abord."
                : "Journal des opérations, les plus récentes d’abord.";
            return Measured(definition, scopeLabel, Tone.Info, entries[0].At, detail, new TimelineData(entries.Count, rows));
        }
    }
}
