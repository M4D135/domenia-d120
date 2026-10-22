using System.Collections.Concurrent;
using System.Collections.Frozen;
using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Search screen in simulation (docs/ops/rechercher.md): every read is evaluated in memory on the fictitious directory as the
/// session sees it (<see cref="SimulatedDirectorySource.CurrentDirectory"/>, through <see cref="SimulatedDirectorySource.ReadLocalAsync"/>)
/// with the pure rules of Domenia.Core (plan, matcher, rows, views). What the generator does not hold — addresses of the
/// workstations, console users, associations, the DNS zone, survey outcomes — is derived from the screen stream
/// « screen/search » of the seed (PLATFORM.md § 4): deterministic, independent of the other screens. Survey results stay in
/// the memory of this reader for the session. No network, no disk.
/// </summary>
public sealed class SimulatedSearchReader : ISearchReader
{
    private const string Source = "Annuaire fictif";
    private const string Readings = "Relevés fictifs";

    private static readonly FrozenDictionary<string, int> SiteSubnets = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase)
    {
        ["Paris"] = 10, ["Lyon"] = 20, ["Marseille"] = 30, ["Lille"] = 40, ["Bordeaux"] = 50, ["Quarantaine"] = 60,
    }.ToFrozenDictionary(StringComparer.OrdinalIgnoreCase);

    private readonly SimulatedDirectorySource source;
    private readonly Lazy<Derived> derived;
    private readonly Lock gate = new();
    private (DirectorySnapshot Snapshot, CandidateIndex Index)? built;
    private readonly ConcurrentDictionary<Guid, PresenceMeasure> surveyed = new();
    private readonly ConcurrentDictionary<Guid, SearchConsole> consoles = new();
    private readonly ConcurrentDictionary<Guid, DateTimeOffset> addressSeen = new();

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedSearchReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
        derived = new Lazy<Derived>(() => Derive(source), LazyThreadSafetyMode.ExecutionAndPublication);
    }

    private TimeZoneInfo Zone => source.World.TimeZone;

    public async Task<SearchPage> FindAsync(SearchQuery query, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(query);
        var kind = query.Kind == SearchListKind.Browse ? "search/browse" : "search/find";
        await source.SimulateScreenLatencyAsync(kind, 40, 180, cancellationToken).ConfigureAwait(false);
        var (state, index, factory, now) = await StateAsync(cancellationToken).ConfigureAwait(false);
        Func<SearchCandidate, bool> match;
        if (query.Kind == SearchListKind.View)
        {
            var view = SearchViews.All(now).FirstOrDefault(v => v.Id == query.ViewId)
                ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, SearchErrors.ViewUnknownMessage);
            match = c => SearchMatcher.OfType(c, view.Type) && view.Matches(c.Source);
        }
        else
        {
            match = SearchMatcher.Compile(query.Plan, query.Type);
        }
        var root = state.Directory.Domain.RootDn;
        var listingBase = query.Kind is SearchListKind.Browse or SearchListKind.View;
        var rows = ImmutableArray.CreateBuilder<SearchRow>(Math.Min(query.Take, 512));
        var more = false;
        string? last = null;
        foreach (var candidate in index.Ordered)
        {
            if (query.After is string after && string.CompareOrdinal(candidate.NameKey, after) < 0)
            {
                continue;
            }
            if (query.Known.Contains(candidate.Id.ToString("D")) || !InScope(candidate.Dn, query.BaseDn, query.Subtree, root, listingBase) || !match(candidate))
            {
                continue;
            }
            if (rows.Count == query.Take)
            {
                more = true;
                break;
            }
            rows.Add(factory.Row(candidate.Source));
            last = candidate.NameKey;
        }
        return new SearchPage(rows.ToImmutable(), more, last, state.Directory.ReadAt, Source);
    }

    public async Task<ImmutableArray<SearchContainer>> ContainersAsync(CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("search/tree", 40, 120, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var root = directory.Domain.RootDn;
        int Count(string dn) => directory.Users.Count(u => Under(u.DistinguishedName, dn)) + directory.Computers.Count(c => Under(c.DistinguishedName, dn))
            + directory.Groups.Count(g => Under(g.DistinguishedName, dn));
        return [.. directory.Domain.Containers.Select(dn => new SearchContainer(dn, SearchTexts.Leaf(dn), SearchContainers.IsSystem(dn, root), Count(dn)))
            .OrderBy(c => c.System).ThenBy(c => c.Name, StringComparer.OrdinalIgnoreCase)];
    }

    public async Task<SearchPage> FindAddressAsync(SearchAddress address, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(address);
        await source.SimulateScreenLatencyAsync("search/local", 30, 120, cancellationToken).ConfigureAwait(false);
        var (state, index, factory, _) = await StateAsync(cancellationToken).ConfigureAwait(false);
        var data = derived.Value;
        var matches = data.Addresses.Where(p => p.Value.Read && (address.Kind == "mac"
                ? string.Equals(p.Value.Mac, address.Value, StringComparison.OrdinalIgnoreCase)
                : string.Equals(p.Value.Ip, address.Value, StringComparison.Ordinal)))
            .Select(p => (Id: p.Key, Seen: AddressSeen(p.Key, p.Value)))
            .OrderByDescending(p => p.Seen)
            .ToList();
        var rows = ImmutableArray.CreateBuilder<SearchRow>();
        foreach (var (id, seen) in matches.Take(Math.Max(1, limit)))
        {
            if (!index.ById.TryGetValue(id, out var candidate))
            {
                continue;
            }
            var row = factory.Row(candidate.Source);
            var reading = data.Addresses[id];
            var shown = address.Kind == "mac" ? reading.Mac : reading.Ip;
            rows.Add(row with { Address = new SearchAddressReading(reading.Ip, reading.Mac, seen, SearchText.AddressNotice(address, seen, shown, Zone)) });
        }
        return new SearchPage(rows.ToImmutable(), matches.Count > Math.Max(1, limit), null, state.Observations.TakenAt ?? state.Directory.ReadAt, Readings);
    }

    public async Task<(SearchPage Page, SearchVerdictTotals Totals)> LocalQueryAsync(string queryId, string baseDn, bool subtree, string verdict, int limit, CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("search/local", 30, 120, cancellationToken).ConfigureAwait(false);
        var (state, index, factory, now) = await StateAsync(cancellationToken).ConfigureAwait(false);
        var query = SearchViews.LocalQueries.FirstOrDefault(q => q.Id == queryId)
            ?? throw new DomeniaOperationException(SearchErrors.ViewUnknown, SearchErrors.ViewUnknownMessage);
        var root = state.Directory.Domain.RootDn;
        int match = 0, unknown = 0, noMatch = 0;
        var rows = new List<SearchRow>();
        foreach (var candidate in index.Ordered)
        {
            if (candidate.Source is not DirectoryComputer computer || AdValues.IsDisabled(computer.UserAccountControl)
                || AdValues.HasFlag(computer.UserAccountControl, AdValues.ServerTrustAccount) || !InScope(candidate.Dn, baseDn, subtree, root, listingBase: true))
            {
                continue;
            }
            var result = query.Evaluate(computer, factory.Observation(computer.ObjectGuid), now);
            switch (result.Verdict)
            {
                case SearchViews.Match:
                    match++;
                    break;
                case SearchViews.NoMatch:
                    noMatch++;
                    break;
                default:
                    unknown++;
                    break;
            }
            if (verdict == "all" || verdict == result.Verdict)
            {
                rows.Add(factory.Computer(computer, 9, SearchViews.VerdictLabel(result.Verdict) + " · " + result.Value));
            }
        }
        var shown = verdict switch
        {
            SearchViews.Match => "Correspondants",
            SearchViews.NoMatch => "Non correspondants",
            SearchViews.Unknown => "Inconnus",
            _ => "Tous les postes",
        };
        var take = Math.Max(1, limit);
        return (new SearchPage([.. rows.Take(take)], rows.Count > take, null, state.Observations.TakenAt ?? state.Directory.ReadAt, Readings),
            new SearchVerdictTotals(match, unknown, noMatch, shown));
    }

    public async Task<ImmutableArray<SearchSuggestion>> SuggestAsync(string text, SearchTypeFilter type, int max, CancellationToken cancellationToken)
    {
        var folded = FrenchText.Fold(text.Trim());
        if (folded.Length < SearchLimits.MinChars)
        {
            return [];
        }
        var (_, index, _, _) = await StateAsync(cancellationToken).ConfigureAwait(false);
        bool Starts(SearchCandidate c) => c.Folded[0].StartsWith(folded, StringComparison.Ordinal) || c.Folded[2].StartsWith(folded, StringComparison.Ordinal)
            || c.Folded[3].StartsWith(folded, StringComparison.Ordinal) || c.Folded[4].StartsWith(folded, StringComparison.Ordinal);
        bool Contains(SearchCandidate c) => c.ContainsValues.Any(v => v.Contains(folded, StringComparison.Ordinal));
        var found = index.Ordered.Where(c => SearchMatcher.OfType(c, type) && Starts(c))
            .Concat(index.Ordered.Where(c => SearchMatcher.OfType(c, type) && !Starts(c) && Contains(c)))
            .Take(Math.Clamp(max, 1, 50));
        return [.. found.Select(c => new SearchSuggestion("local", c.Name, c.Name, Detail(c), c.Kind, c.Dn))];
    }

    public async Task<SearchPreview?> PreviewAsync(Guid id, CancellationToken cancellationToken)
    {
        var (state, index, factory, _) = await StateAsync(cancellationToken).ConfigureAwait(false);
        if (!index.ById.TryGetValue(id, out var candidate))
        {
            return null;
        }
        var row = factory.Row(candidate.Source);
        return SearchDetails.Preview(row, candidate.Source, state.Directory, factory.Observation(id), Zone, Source);
    }

    public async Task<SearchComparison> CompareAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var (state, index, factory, _) = await StateAsync(cancellationToken).ConfigureAwait(false);
        var items = ids.Where(index.ById.ContainsKey).Select(i => index.ById[i])
            .Select(c => (factory.Row(c.Source), c.Source, factory.Observation(c.Id))).ToList();
        return SearchDetails.Compare(items, state.Directory, Zone);
    }

    public async Task<ImmutableArray<SearchRow>> LocalRowsAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var (_, index, factory, _) = await StateAsync(cancellationToken).ConfigureAwait(false);
        return [.. ids.Where(index.ById.ContainsKey).Select(i => factory.Row(index.ById[i].Source))];
    }

    public async Task<ImmutableArray<SearchRow>> RereadAsync(IReadOnlyList<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        await source.SimulateScreenLatencyAsync("search/reread", 60, 160, cancellationToken).ConfigureAwait(false);
        return await LocalRowsAsync(ids, cancellationToken).ConfigureAwait(false);
    }

    public async Task<string?> ReverseDnsAsync(string ipv4, CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("search/dns", 200, 600, cancellationToken).ConfigureAwait(false);
        return derived.Value.Dns.GetValueOrDefault(ipv4);
    }

    public async Task<SurveyOutcome> ProbeAsync(Guid id, SurveyMode mode, int run, CancellationToken cancellationToken)
    {
        var (min, max) = mode switch
        {
            SurveyMode.Ping => (30, 140),
            SurveyMode.Console or SurveyMode.Unaddressed => (220, 640),
            _ => (420, 1100),
        };
        await source.SimulateScreenLatencyAsync("search/probe", min, max, cancellationToken).ConfigureAwait(false);
        var (_, index, factory, now) = await StateAsync(cancellationToken).ConfigureAwait(false);
        if (!index.ById.TryGetValue(id, out var candidate) || candidate.Source is not DirectoryComputer computer)
        {
            throw new DomeniaOperationException(SearchErrors.NotWorkstation, SearchErrors.NotWorkstationMessage);
        }
        var world = source.World;
        var previous = surveyed.TryGetValue(id, out var known) ? known : factory.Observation(id)?.Presence ?? PresenceMeasure.Unread;
        PresenceMeasure measure;
        string? detail = null;
        if (world.Presence.ErrorProbes.Contains(id))
        {
            measure = new PresenceMeasure(MeasureState.Error, null, now, previous.LastOnlineAt);
            detail = "Nom non résolu par le DNS" + FrenchText.Colon + "aucun écho envoyé.";
        }
        else
        {
            var random = source.ScreenStream("search").Fork("survey/" + run.ToString(CultureInfo.InvariantCulture) + "/" + id.ToString("N"));
            var before = SearchTexts.Presence(previous, now).State;
            var chance = before switch
            {
                SearchPresenceState.Online => 92,
                SearchPresenceState.NoReply => 30,
                _ => 55,
            };
            if (world.Weekend)
            {
                chance /= 3;
            }
            var answered = !world.Presence.NeverAnswer.Contains(id) && random.Chance(chance);
            measure = new PresenceMeasure(MeasureState.Known, answered, now, answered ? now : previous.LastOnlineAt);
        }
        surveyed[id] = measure;
        var presence = SearchTexts.Presence(measure, now);
        SearchConsole? console = null;
        if (presence.State == SearchPresenceState.Online)
        {
            addressSeen[id] = now;
            if (mode != SurveyMode.Ping)
            {
                console = ConsoleRead(computer, run, now);
                consoles[id] = console;
            }
        }
        return new SurveyOutcome(id.ToString("D"), computer.Name, SearchSurvey.OutcomeKind(presence.State), presence, console, detail);
    }

    public async Task<NetworkDiagnosticLine> DiagnoseAsync(Guid id, CancellationToken cancellationToken)
    {
        await source.SimulateScreenLatencyAsync("search/diag", 240, 820, cancellationToken).ConfigureAwait(false);
        var (_, index, factory, now) = await StateAsync(cancellationToken).ConfigureAwait(false);
        if (!index.ById.TryGetValue(id, out var candidate) || candidate.Source is not DirectoryComputer computer)
        {
            throw new DomeniaOperationException(SearchErrors.NotWorkstation, SearchErrors.NotWorkstationMessage);
        }
        var world = source.World;
        var random = source.ScreenStream("search").Fork("diag/" + id.ToString("N") + "/" + now.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));
        var address = derived.Value.Addresses.TryGetValue(id, out var reading) ? reading.Ip : null;
        var previous = surveyed.TryGetValue(id, out var known) ? known : factory.Observation(id)?.Presence;
        var wasOnline = SearchTexts.Presence(previous, now).State == SearchPresenceState.Online;
        if (world.Presence.ErrorProbes.Contains(id) || address is null)
        {
            var ping = new SearchPresence(SearchPresenceState.Error, "Nom non résolu", Tone.Alert, now, previous?.LastOnlineAt, "Le nom DNS du poste n’a pas été résolu" + FrenchText.Colon + "aucun test envoyé.");
            var none = SearchSurvey.DiagnosticPorts.Select(p => new NetworkPort(p.Port, p.Service, "untested", "Non testé", Tone.Off)).ToImmutableArray();
            return new NetworkDiagnosticLine(id.ToString("D"), computer.Name, address, ping, none, "Nom non résolu" + FrenchText.Colon + "aucun test.", Tone.Alert);
        }
        var answered = !world.Presence.NeverAnswer.Contains(id) && random.Chance(wasOnline ? 90 : 35);
        var echo = answered
            ? new SearchPresence(SearchPresenceState.Online, "Répond au ping", Tone.Ok, now, now, "Écho ICMP reçu.")
            : new SearchPresence(SearchPresenceState.NoReply, "Pas de réponse", Tone.Warn, now, previous?.LastOnlineAt, "Aucun écho ICMP" + FrenchText.Colon + "poste éteint, hors réseau ou ICMP filtré.");
        var ports = SearchSurvey.DiagnosticPorts.Select(p =>
        {
            if (!answered)
            {
                return new NetworkPort(p.Port, p.Service, "filtered", "Délai dépassé", Tone.Warn);
            }
            var open = p.Port switch { 445 => random.Chance(95), 135 => random.Chance(95), 5985 => random.Chance(70), _ => random.Chance(8) };
            return open ? new NetworkPort(p.Port, p.Service, "open", "Ouvert", Tone.Ok) : new NetworkPort(p.Port, p.Service, "closed", "Fermé", Tone.Off);
        }).ToImmutableArray();
        var openNames = ports.Where(p => p.State == "open").Select(p => p.Service).ToList();
        var summary = answered
            ? openNames.Count > 0 ? "Joignable · ouverts" + FrenchText.Colon + string.Join(", ", openNames) : "Joignable · aucun port de gestion ouvert"
            : "Ne répond ni au ping ni aux ports testés" + FrenchText.Colon + "poste éteint, hors réseau ou filtré.";
        var tone = !answered ? Tone.Warn : ports.Any(p => p.Port == 445 && p.State == "open") ? Tone.Ok : Tone.Warn;
        return new NetworkDiagnosticLine(id.ToString("D"), computer.Name, address, echo, ports, summary, tone);
    }

    // ---------- State, index and derived data ----------

    private async Task<(DirectoryState State, CandidateIndex Index, SearchRowFactory Factory, DateTimeOffset Now)> StateAsync(CancellationToken cancellationToken)
    {
        var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        CandidateIndex index;
        lock (gate)
        {
            if (built is not { } known || !ReferenceEquals(known.Snapshot, state.Directory))
            {
                known = (state.Directory, CandidateIndex.Build(state.Directory));
                built = known;
            }
            index = known.Index;
        }
        var now = source.Clock.GetUtcNow();
        var observed = state.Observations.Workstations.GroupBy(o => o.ComputerGuid).ToDictionary(g => g.Key, g => g.Last());
        return (state, index, new SearchRowFactory(state.Directory, state.Observations.Workstations, new Enrichment(this, index, observed), now), now);
    }

    /// <summary>
    /// True when the object is in the perimeter: under the base (direct child only unless sub-OUs are included). A list of an
    /// OU or a view never lists the base itself; the global search at the root lists everything of the domain.
    /// </summary>
    private static bool InScope(string dn, string baseDn, bool subtree, string rootDn, bool listingBase)
    {
        try
        {
            if (SearchLists.IsRoot(baseDn, rootDn) && subtree)
            {
                return DistinguishedName.IsWithin(dn, rootDn, subtree: true);
            }
            return DistinguishedName.IsWithin(dn, baseDn, subtree) && !(listingBase && DistinguishedName.AreEqual(dn, baseDn));
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool Under(string dn, string containerDn)
    {
        try
        {
            return DistinguishedName.IsWithin(dn, containerDn, subtree: true);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static string Detail(SearchCandidate c)
    {
        var kind = c.Kind switch
        {
            SearchObjectKind.User => "Utilisateur",
            SearchObjectKind.Computer => "Poste",
            SearchObjectKind.Group => "Groupe",
            _ => "OU",
        };
        var detail = Source + " · " + kind;
        if (!string.IsNullOrEmpty(c.Sam) && !string.Equals(c.Sam, c.Name, StringComparison.OrdinalIgnoreCase))
        {
            detail += " · " + c.Sam;
        }
        if (!string.IsNullOrEmpty(c.Display) && !string.Equals(c.Display, c.Name, StringComparison.OrdinalIgnoreCase))
        {
            detail += " · " + c.Display;
        }
        return detail;
    }

    private DateTimeOffset? AddressSeen(Guid id, AddressInfo info) => addressSeen.TryGetValue(id, out var at) ? at : info.ObservedAt;

    private SearchConsole ConsoleRead(DirectoryComputer computer, int run, DateTimeOffset now)
    {
        var random = source.ScreenStream("search").Fork("console/" + run.ToString(CultureInfo.InvariantCulture) + "/" + computer.ObjectGuid.ToString("N"));
        var data = derived.Value;
        var userId = data.Owners.TryGetValue(computer.ObjectGuid, out var owner) && random.Chance(80) ? owner
            : data.Consoles.TryGetValue(computer.ObjectGuid, out var seen) && random.Chance(70) ? seen
            : (Guid?)null;
        return userId is Guid user && data.Users.TryGetValue(user, out var person)
            ? new SearchConsole("seen", (person.DisplayName ?? person.Cn) + " (" + person.SamAccountName + ")", person.DisplayName ?? person.Cn, person.SamAccountName, person.DistinguishedName, now)
            : new SearchConsole("none", "Aucune session à la console", null, null, null, now);
    }

    private static Derived Derive(SimulatedDirectorySource source)
    {
        var world = source.World;
        var directory = world.Directory;
        var random = source.ScreenStream("search");
        var observations = world.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        var users = directory.Users.ToFrozenDictionary(u => u.ObjectGuid);
        var userByDn = directory.Users.ToDictionary(u => u.DistinguishedName, u => u, StringComparer.OrdinalIgnoreCase);
        var addresses = new Dictionary<Guid, AddressInfo>();
        var dns = new Dictionary<string, string>(StringComparer.Ordinal);
        var counters = new Dictionary<int, int>();
        var macs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var macRandom = random.Fork("mac");
        var ipRandom = random.Fork("ip");
        foreach (var computer in directory.Computers)
        {
            var subnet = Subnet(computer);
            var n = counters.GetValueOrDefault(subnet) + ipRandom.Next(1, 3);
            counters[subnet] = n;
            var ip = string.Create(CultureInfo.InvariantCulture, $"10.{subnet}.{1 + n / 240}.{10 + n % 240}");
            observations.TryGetValue(computer.ObjectGuid, out var observation);
            var model = observation?.Inventory.Model ?? (subnet == 1 ? "VMware" : "Dell");
            string mac;
            do
            {
                mac = MacPrefix(model) + "-" + string.Join('-', Enumerable.Range(0, 3).Select(_ => macRandom.Next(256).ToString("X2", CultureInfo.InvariantCulture)));
            }
            while (!macs.Add(mac));
            var presence = observation?.Presence;
            var inventory = observation?.Inventory;
            DateTimeOffset? seen = null;
            if (presence is { HasReading: true, Answered: true } && presence.CheckedAt is DateTimeOffset p)
            {
                seen = p;
            }
            if (inventory is { HasReading: true } && inventory.CheckedAt is DateTimeOffset i && (seen is null || i > seen))
            {
                seen = i;
            }
            if (seen is null && presence?.LastOnlineAt is DateTimeOffset last)
            {
                seen = last;
            }
            var enabled = !AdValues.IsDisabled(computer.UserAccountControl);
            // Servers and controllers have no workstation reading: their addresses are known from the DNS only.
            var read = seen is not null && subnet != 1;
            addresses[computer.ObjectGuid] = new AddressInfo(ip, mac, seen, read);
            if (enabled && computer.DnsHostName is string host)
            {
                dns[ip] = host;
            }
        }
        // DHCP reuse: a few laptops of one site were seen on the same address at different dates (the newest wins in the DNS).
        var laptops = directory.Computers.Where(c => c.Name.StartsWith("PT-", StringComparison.Ordinal) && addresses[c.ObjectGuid].Read).ToList();
        var shared = random.Fork("dhcp");
        shared.Shuffle(laptops);
        for (var k = 0; k + 1 < Math.Min(laptops.Count, 6); k += 2)
        {
            var first = addresses[laptops[k].ObjectGuid];
            var second = addresses[laptops[k + 1].ObjectGuid];
            var older = (second.ObservedAt ?? DateTimeOffset.MinValue) < (first.ObservedAt ?? DateTimeOffset.MinValue) ? laptops[k + 1] : laptops[k];
            var newer = ReferenceEquals(older, laptops[k]) ? laptops[k + 1] : laptops[k];
            dns.Remove(addresses[older.ObjectGuid].Ip);
            addresses[older.ObjectGuid] = addresses[older.ObjectGuid] with { Ip = addresses[newer.ObjectGuid].Ip };
        }
        // Owners declared in the directory (managedBy), then console users of the workstations online today.
        var owners = new Dictionary<Guid, Guid>();
        foreach (var computer in directory.Computers)
        {
            if (computer.ManagedByDn is string owner && userByDn.TryGetValue(owner, out var user))
            {
                owners[computer.ObjectGuid] = user.ObjectGuid;
            }
        }
        var consoles = new Dictionary<Guid, Guid>();
        var consoleRandom = random.Fork("console");
        var bySite = directory.Users.Where(u => !AdValues.IsDisabled(u.UserAccountControl) && u.Office is not null)
            .GroupBy(u => u.Office!, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);
        foreach (var computer in directory.Computers)
        {
            if (!observations.TryGetValue(computer.ObjectGuid, out var observation) || observation.Presence is not { HasReading: true, Answered: true }
                || !consoleRandom.Chance(72))
            {
                continue;
            }
            if (owners.TryGetValue(computer.ObjectGuid, out var owner) && consoleRandom.Chance(80))
            {
                consoles[computer.ObjectGuid] = owner;
                continue;
            }
            var site = SiteOf(computer.DistinguishedName);
            if (site is not null && bySite.TryGetValue(site, out var people) && people.Count > 0)
            {
                consoles[computer.ObjectGuid] = consoleRandom.Pick(people).ObjectGuid;
            }
        }
        var userComputers = owners.Select(p => (User: p.Value, Computer: p.Key, Declared: true))
            .Concat(consoles.Where(p => !owners.ContainsKey(p.Key) || owners[p.Key] != p.Value).Select(p => (User: p.Value, Computer: p.Key, Declared: false)))
            .GroupBy(x => x.User)
            .ToFrozenDictionary(g => g.Key, g => g.Select(x => (x.Computer, x.Declared)).ToImmutableArray());
        return new Derived(addresses.ToFrozenDictionary(), dns.ToFrozenDictionary(StringComparer.Ordinal), owners.ToFrozenDictionary(), consoles.ToFrozenDictionary(),
            users, userComputers);
    }

    private static int Subnet(DirectoryComputer computer)
    {
        if (AdValues.HasFlag(computer.UserAccountControl, AdValues.ServerTrustAccount) || computer.DistinguishedName.Contains("OU=Serveurs", StringComparison.OrdinalIgnoreCase))
        {
            return 1;
        }
        return SiteOf(computer.DistinguishedName) is string site && SiteSubnets.TryGetValue(site, out var subnet) ? subnet : 90;
    }

    /// <summary>Site of an object from the first OU under « Postes » or « Utilisateurs » (« OU=Paris,OU=Postes,… » → Paris).</summary>
    private static string? SiteOf(string dn)
    {
        try
        {
            var names = DistinguishedName.Parse(dn);
            for (var i = 0; i + 1 < names.Length; i++)
            {
                var parent = names[i + 1];
                if (string.Equals(names[i].Type, "OU", StringComparison.OrdinalIgnoreCase) && string.Equals(parent.Type, "OU", StringComparison.OrdinalIgnoreCase)
                    && (string.Equals(parent.Value, "Postes", StringComparison.OrdinalIgnoreCase) || string.Equals(parent.Value, "Utilisateurs", StringComparison.OrdinalIgnoreCase)))
                {
                    return names[i].Value;
                }
            }
        }
        catch (FormatException)
        {
            return null;
        }
        return null;
    }

    private static string MacPrefix(string model) =>
        model.StartsWith("Dell", StringComparison.OrdinalIgnoreCase) ? "D4-81-D7"
        : model.StartsWith("HP", StringComparison.OrdinalIgnoreCase) ? "3C-52-82"
        : model.StartsWith("Lenovo", StringComparison.OrdinalIgnoreCase) ? "8C-16-45"
        : "00-50-56";

    private sealed record AddressInfo(string Ip, string Mac, DateTimeOffset? ObservedAt, bool Read);

    private sealed record Derived(
        FrozenDictionary<Guid, AddressInfo> Addresses,
        FrozenDictionary<string, string> Dns,
        FrozenDictionary<Guid, Guid> Owners,
        FrozenDictionary<Guid, Guid> Consoles,
        FrozenDictionary<Guid, DirectoryUser> Users,
        FrozenDictionary<Guid, ImmutableArray<(Guid Computer, bool Declared)>> UserComputers);

    /// <summary>Candidates of one directory snapshot, in the order of the continuation (folded name, then DN).</summary>
    private sealed class CandidateIndex
    {
        private CandidateIndex(ImmutableArray<SearchCandidate> ordered)
        {
            Ordered = ordered;
            ById = ordered.ToFrozenDictionary(c => c.Id);
        }

        public ImmutableArray<SearchCandidate> Ordered { get; }

        public FrozenDictionary<Guid, SearchCandidate> ById { get; }

        public static CandidateIndex Build(DirectorySnapshot snapshot) =>
            new([.. SearchRowFactory.Candidates(snapshot).OrderBy(c => c.NameKey, StringComparer.Ordinal).ThenBy(c => c.Dn, StringComparer.OrdinalIgnoreCase)]);
    }

    /// <summary>Facts of the simulation beside the directory: survey results, console users, associations and addresses.</summary>
    private sealed class Enrichment(SimulatedSearchReader reader, CandidateIndex index, Dictionary<Guid, WorkstationObservation> observed) : ISearchEnrichment
    {
        public PresenceMeasure? Presence(Guid computer) => reader.surveyed.TryGetValue(computer, out var measure) ? measure : null;

        public SearchConsole? Console(Guid computer)
        {
            if (reader.consoles.TryGetValue(computer, out var read))
            {
                return read;
            }
            var data = reader.derived.Value;
            if (data.Consoles.TryGetValue(computer, out var user) && data.Users.TryGetValue(user, out var person))
            {
                var at = data.Addresses.TryGetValue(computer, out var info) ? info.ObservedAt : null;
                return new SearchConsole("seen", (person.DisplayName ?? person.Cn) + " (" + person.SamAccountName + ")", person.DisplayName ?? person.Cn, person.SamAccountName, person.DistinguishedName, at);
            }
            var presence = Presence(computer) ?? (observed.TryGetValue(computer, out var observation) ? observation.Presence : null);
            return presence is { HasReading: true, Answered: true }
                ? new SearchConsole("none", "Aucune session à la console", null, null, null, presence.CheckedAt)
                : new SearchConsole("unknown", "Non déterminé", null, null, null, null);
        }

        public SearchAssociation? Association(Guid objectId)
        {
            var data = reader.derived.Value;
            if (index.ById.TryGetValue(objectId, out var candidate) && candidate.Source is DirectoryUser)
            {
                if (!data.UserComputers.TryGetValue(objectId, out var computers) || computers.IsEmpty)
                {
                    return null;
                }
                var names = computers.Select(c => index.ById.TryGetValue(c.Computer, out var pc) ? pc.Name : null).OfType<string>().Order(StringComparer.Ordinal).ToList();
                if (names.Count == 0)
                {
                    return null;
                }
                var declared = computers.Any(c => c.Declared);
                var label = names[0] + (names.Count > 1 ? " + " + FrenchText.Count(names.Count - 1, "autre", "autres") : "");
                return new SearchAssociation(label, null, declared ? "Déclaré dans l’annuaire (managedBy)" : "Sessions observées à la console",
                    declared ? "Déclaré" : "Observé", string.Join(", ", names) + ". L’identité de la personne au poste n’est pas vérifiable par Domenia.");
            }
            if (data.Owners.TryGetValue(objectId, out var owner) && data.Users.TryGetValue(owner, out var person))
            {
                return new SearchAssociation((person.DisplayName ?? person.Cn) + " (" + person.SamAccountName + ")", person.DistinguishedName, "Déclaré dans l’annuaire (managedBy)", "Déclaré",
                    "Association déclarée par l’attribut managedBy" + FrenchText.Colon + "l’identité de la personne au poste n’est pas vérifiable par Domenia.");
            }
            if (data.Consoles.TryGetValue(objectId, out var seen) && data.Users.TryGetValue(seen, out var user))
            {
                return new SearchAssociation((user.DisplayName ?? user.Cn) + " (" + user.SamAccountName + ")", user.DistinguishedName, "Dernière session observée à la console", "Observé",
                    "Observé lors d’un relevé" + FrenchText.Colon + "un autre utilisateur peut s’y connecter depuis.");
            }
            return null;
        }

        public SearchAddressReading? Address(Guid computer)
        {
            var data = reader.derived.Value;
            if (!data.Addresses.TryGetValue(computer, out var info) || !info.Read && !reader.addressSeen.ContainsKey(computer))
            {
                return null;
            }
            var seen = reader.AddressSeen(computer, info);
            return new SearchAddressReading(info.Ip, info.Mac, seen, SearchText.AddressNotice(null, seen, info.Ip, reader.Zone));
        }
    }
}
