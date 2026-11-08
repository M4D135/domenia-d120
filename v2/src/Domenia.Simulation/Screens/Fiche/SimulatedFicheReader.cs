using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Reads of the « Fiche » screen in simulation (docs/ops/fiche.md): the fictitious directory as the session sees it (writes of the
/// session included), plus data derived from the sub-stream « screen/fiche » (contacts, contact attributes, associations, 4740
/// events, per-controller logons, sessions, quick inventories, ACL estimate, replication metadata). Memory only: no network, no
/// disk. Each read waits a short realistic delay of its own sub-sequence (« latency/screen/fiche/… »), none with
/// <see cref="SimulationLatency.None"/>; the local reads (index, picker, relations, observations) answer at once.
/// </summary>
public sealed class SimulatedFicheReader : IFicheReader
{
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedFicheReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    private SimulatedFicheWorld World => SimulatedFicheWorld.For(source);

    private Task WaitAsync(string kind, int min, int max, CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync("fiche/" + kind, min, max, cancellationToken);

    private SimulatedObject Require(string dn) =>
        World.Find(dn) ?? throw FicheErrors.Error(FicheErrors.Unknown, FicheErrors.UnknownMessage);

    private static int HiddenSensitive(SimulatedObject item) => item.Value is DirectoryComputer { Laps: not LapsKind.None } ? 1 : 0;

    public async Task<FicheLocalRead?> PreviewAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("preview", 20, 60, cancellationToken).ConfigureAwait(false);
        var item = World.Find(dn);
        if (item is null)
        {
            return null;
        }
        var readAt = source.World.Session.Store.LastReadAt ?? source.World.Reference;
        return new FicheLocalRead(World.Entry(item), readAt);
    }

    public async Task<FicheRead> ReadAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("read", 140, 320, cancellationToken).ConfigureAwait(false);
        var item = Require(dn);
        return new FicheRead(World.Entry(item), source.Clock.GetUtcNow(), World.Controller, HiddenSensitive(item));
    }

    public async Task<FicheEntry?> ReadByGuidAsync(Guid objectGuid, CancellationToken cancellationToken)
    {
        await WaitAsync("guid", 40, 110, cancellationToken).ConfigureAwait(false);
        return World.Find(objectGuid) is SimulatedObject item ? World.Entry(item) : null;
    }

    public Task<IReadOnlyDictionary<string, FicheSummary>> IndexAsync(IReadOnlyCollection<string> dns, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dns);
        cancellationToken.ThrowIfCancellationRequested();
        var world = World;
        var result = new Dictionary<string, FicheSummary>(StringComparer.OrdinalIgnoreCase);
        foreach (var dn in dns.Distinct(StringComparer.OrdinalIgnoreCase).Take(2000))
        {
            if (world.Find(dn) is SimulatedObject item)
            {
                result[dn] = world.Summary(item);
            }
        }
        return Task.FromResult<IReadOnlyDictionary<string, FicheSummary>>(result);
    }

    public Task<FicheSummary?> LocalByIdAsync(string id, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(id);
        cancellationToken.ThrowIfCancellationRequested();
        var text = id.Trim();
        var world = World;
        if (Guid.TryParse(text.Trim('{', '}'), out var guid))
        {
            return Task.FromResult(world.Find(guid) is SimulatedObject byGuid ? world.Summary(byGuid) : null);
        }
        if (text.StartsWith("S-1-", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var item in world.All())
            {
                var summary = world.Summary(item);
                if (string.Equals(summary.Sid, text, StringComparison.OrdinalIgnoreCase))
                {
                    return Task.FromResult<FicheSummary?>(summary);
                }
            }
        }
        return Task.FromResult<FicheSummary?>(null);
    }

    public Task<ImmutableArray<FicheSummary>> SearchLocalAsync(string text, IReadOnlyCollection<FicheKind> kinds, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        ArgumentNullException.ThrowIfNull(kinds);
        cancellationToken.ThrowIfCancellationRequested();
        var wanted = FrenchText.Fold(text.Trim());
        if (wanted.Length == 0)
        {
            return Task.FromResult(ImmutableArray<FicheSummary>.Empty);
        }
        var world = World;
        var allowed = kinds.Count == 0 ? null : new HashSet<FicheKind>(kinds);
        var found = new List<(int Rank, FicheSummary Summary)>();
        foreach (var item in world.All())
        {
            if (allowed is not null && !allowed.Contains(item.Kind))
            {
                continue;
            }
            var summary = world.Summary(item);
            var name = FrenchText.Fold(summary.Name);
            var sam = summary.Sam is null ? "" : FrenchText.Fold(summary.Sam);
            var upn = summary.Upn is null ? "" : FrenchText.Fold(summary.Upn);
            int rank;
            if (sam == wanted || name == wanted || upn == wanted)
            {
                rank = 0;
            }
            else if (sam.StartsWith(wanted, StringComparison.Ordinal) || name.StartsWith(wanted, StringComparison.Ordinal))
            {
                rank = 1;
            }
            else if (name.Contains(wanted, StringComparison.Ordinal) || sam.Contains(wanted, StringComparison.Ordinal) || FrenchText.Fold(summary.Dn).Contains(wanted, StringComparison.Ordinal))
            {
                rank = 2;
            }
            else
            {
                continue;
            }
            found.Add((rank, summary));
        }
        var result = found.OrderBy(f => f.Rank).ThenBy(f => f.Summary.Name, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true))
            .Take(Math.Clamp(limit, 1, 200)).Select(f => f.Summary).ToImmutableArray();
        return Task.FromResult(result);
    }

    public async Task<FicheChildren> ChildrenAsync(string dn, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("children", 80, 200, cancellationToken).ConfigureAwait(false);
        var item = Require(dn);
        if (item.Kind is not (FicheKind.Ou or FicheKind.Container))
        {
            return new FicheChildren(item.Dn, [], true, null);
        }
        var children = World.ChildrenOf(item.Dn).Select(c => c.Dn).ToList();
        var bounded = children.Take(Math.Max(1, limit)).ToImmutableArray();
        return new FicheChildren(item.Dn, bounded, bounded.Length == children.Count,
            bounded.Length == children.Count ? null : FrenchText.Integer(limit) + " premiers objets lus sur " + FrenchText.Integer(children.Count));
    }

    public Task<int?> LocalChildCountAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        cancellationToken.ThrowIfCancellationRequested();
        var item = World.Find(dn);
        return Task.FromResult<int?>(item is null || item.Kind is not (FicheKind.Ou or FicheKind.Container) ? null : World.ChildrenOf(item.Dn).Count());
    }

    public async Task<FicheMemberRange> MembersAsync(string dn, int shown, int counted, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var item = Require(dn);
        var all = World.Entry(item).All("member");
        // One delay per range of 1 500 values, as the directory answers member;range=… one range at a time.
        var ranges = Math.Max(1, (Math.Min(all.Length, counted) + 1499) / 1500);
        for (var i = 0; i < ranges; i++)
        {
            await WaitAsync("members", 60, 160, cancellationToken).ConfigureAwait(false);
        }
        var total = Math.Min(all.Length, counted);
        var complete = all.Length <= counted;
        var note = complete ? null : "lecture arrêtée à " + FrenchText.Count(counted, "membre", "membres") + ", le groupe en compte davantage";
        return new FicheMemberRange(item.Dn, [.. all.Take(Math.Max(0, shown))], total, complete, note);
    }

    public async Task<bool?> TransitiveMemberAsync(string dn, string groupDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(groupDn);
        await WaitAsync("transitive", 150, 380, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(dn);
        var groups = world.Directory.Groups.ToDictionary(g => g.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var queue = new Queue<string>(world.Entry(item).All("memberOf"));
        while (queue.Count > 0)
        {
            var next = queue.Dequeue();
            if (!seen.Add(next))
            {
                continue;
            }
            if (FicheValues.SameDn(next, groupDn))
            {
                return true;
            }
            if (groups.TryGetValue(next, out var group))
            {
                foreach (var parent in group.MemberOf)
                {
                    queue.Enqueue(parent);
                }
            }
        }
        // The matching rule of the controller does not follow primaryGroupID: same answer here.
        return false;
    }

    public async Task<ImmutableArray<FicheDestination>> DestinationsAsync(string? parentDn, CancellationToken cancellationToken)
    {
        await WaitAsync("destinations", 60, 160, cancellationToken).ConfigureAwait(false);
        var world = World;
        var root = world.Directory.Domain.RootDn;
        var parent = parentDn is null ? root : Require(parentDn).Dn;
        var list = new List<FicheDestination>();
        foreach (var child in world.ChildrenOf(parent))
        {
            if (child.Kind is not (FicheKind.Ou or FicheKind.Container) || child.Dn.StartsWith("CN=Builtin,", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var grandChildren = world.ChildrenOf(child.Dn).ToList();
            list.Add(new FicheDestination(child.Dn, FicheValues.DisplayName(child.Dn), FicheSheets.KindId(child.Kind), FicheValues.ReadablePath(child.Dn, includeSelf: true),
                grandChildren.Any(g => g.Kind is FicheKind.Ou or FicheKind.Container), grandChildren.Count));
        }
        // OUs first, then the default containers, each by name.
        return [.. list.OrderBy(d => d.Kind == "ou" ? 0 : 1).ThenBy(d => d.Name, StringComparer.Create(CultureInfo.GetCultureInfo("fr-FR"), true))];
    }

    public Task<ImmutableArray<FicheDomeniaRefusal>> RefusalsAsync(string dn, DateTimeOffset since, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        cancellationToken.ThrowIfCancellationRequested();
        var world = World;
        if (world.Find(dn) is not { Value: DirectoryUser user } item)
        {
            return Task.FromResult(ImmutableArray<FicheDomeniaRefusal>.Empty);
        }
        // Refusals of the account guard of Domenia (local memory of the guard): about half of the lockouts of the fictitious journal
        // are preceded by a refusal of Domenia 4 to 110 s before, so that the reconciliation of FIC-045 shows both cases.
        var random = source.ScreenStream("fiche").Fork("refusals/" + user.ObjectGuid.ToString("N"));
        var refusals = new List<FicheDomeniaRefusal>();
        foreach (var lockout in LockoutHistory(world, item, user, source.Clock.GetUtcNow()))
        {
            if (lockout.At >= since && random.Chance(50))
            {
                refusals.Add(new FicheDomeniaRefusal(lockout.At - TimeSpan.FromSeconds(random.Next(4, 110)), user.SamAccountName, "authentification"));
            }
        }
        return Task.FromResult<ImmutableArray<FicheDomeniaRefusal>>([.. refusals.OrderByDescending(r => r.At)]);
    }

    public Task<FicheRelationsRead> RelationsAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        cancellationToken.ThrowIfCancellationRequested();
        var world = World;
        var item = Require(dn);
        var directory = world.Directory;
        string? manager = null;
        string? managedBy = null;
        var reports = ImmutableArray<string>.Empty;
        var manages = ImmutableArray<string>.Empty;
        switch (item.Value)
        {
            case DirectoryUser user:
                manager = user.ManagerDn;
                reports = [.. directory.Users.Where(u => FicheValues.SameDn(u.ManagerDn, user.DistinguishedName)).Select(u => u.DistinguishedName)];
                break;
            case DirectoryComputer computer:
                managedBy = computer.ManagedByDn;
                break;
            case DirectoryGroup group:
                managedBy = group.ManagedByDn;
                break;
            case DirectoryOu ou:
                managedBy = ou.ManagedByDn;
                break;
            case SimulatedContact:
                manager = world.Entry(item).First("manager");
                break;
        }
        if (item.Kind is FicheKind.User or FicheKind.Group or FicheKind.Contact)
        {
            manages = [.. directory.Computers.Where(c => FicheValues.SameDn(c.ManagedByDn, item.Dn)).Select(c => c.DistinguishedName)
                .Concat(directory.Groups.Where(g => FicheValues.SameDn(g.ManagedByDn, item.Dn)).Select(g => g.DistinguishedName))
                .Concat(directory.OrganizationalUnits.Where(o => FicheValues.SameDn(o.ManagedByDn, item.Dn)).Select(o => o.DistinguishedName))];
        }
        return Task.FromResult(new FicheRelationsRead(manager, reports, managedBy, manages, world.Associations(item)));
    }

    public Task<FicheObservation?> ObservationAsync(string computerDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computerDn);
        cancellationToken.ThrowIfCancellationRequested();
        var item = World.Find(computerDn);
        return Task.FromResult(item is null ? null : World.Observation(item));
    }

    public Task<FicheInventoryReading?> StoredInventoryAsync(string computerDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computerDn);
        cancellationToken.ThrowIfCancellationRequested();
        var world = World;
        if (world.Find(computerDn) is not { Value: DirectoryComputer computer } item)
        {
            return Task.FromResult<FicheInventoryReading?>(null);
        }
        var raw = world.RawObservation(computer.ObjectGuid)?.Inventory;
        if (raw is null || !raw.HasReading || raw.CheckedAt is not DateTimeOffset at)
        {
            return Task.FromResult<FicheInventoryReading?>(null);
        }
        ImmutableArray<FicheDisk> disks = raw.SystemDiskSizeBytes is long size && size > 0 ? [new FicheDisk("C:", size, raw.SystemDiskFreeBytes ?? 0)] : [];
        return Task.FromResult<FicheInventoryReading?>(new FicheInventoryReading(item.Dn, computer.Name, "read", at, null, raw.MemoryBytes, null, disks, [], null, raw.LastBootAt,
            null, [], raw.Model, raw.OsCaption, null));
    }

    public async Task<FicheGroupGraph> GroupGraphAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("groups", 120, 300, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(dn);
        var directory = world.Directory;
        var groups = directory.Groups.ToDictionary(g => g.DistinguishedName, StringComparer.OrdinalIgnoreCase);
        var edges = ImmutableDictionary.CreateBuilder<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase);
        var nodes = ImmutableDictionary.CreateBuilder<string, FicheGraphNode>(StringComparer.OrdinalIgnoreCase);
        var start = world.Entry(item).All("memberOf");
        edges[item.Dn] = start;
        var queue = new Queue<(string Dn, int Depth)>(start.Select(s => (s, 1)));
        var truncated = false;
        while (queue.Count > 0)
        {
            var (groupDn, depth) = queue.Dequeue();
            if (nodes.ContainsKey(groupDn) || !groups.TryGetValue(groupDn, out var group))
            {
                continue;
            }
            if (nodes.Count >= 2000 || depth > FicheMemberships.MaxDepth)
            {
                truncated = true;
                continue;
            }
            nodes[groupDn] = new FicheGraphNode(group.DistinguishedName, group.Name, group.Sid, group.AdminCount, group.GroupType);
            edges[groupDn] = group.MemberOf;
            foreach (var parent in group.MemberOf)
            {
                queue.Enqueue((parent, depth + 1));
            }
        }
        FichePrimaryGroup? primary = null;
        var rid = item.Value switch
        {
            DirectoryUser u => u.PrimaryGroupId,
            DirectoryComputer c => c.PrimaryGroupId,
            _ => 0,
        };
        if (rid > 0)
        {
            var primaryGroup = directory.Groups.FirstOrDefault(g => g.Sid.EndsWith("-" + rid.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal) && g.Sid.StartsWith(directory.Domain.DomainSid, StringComparison.Ordinal));
            primary = FicheMemberships.PrimaryGroup(rid, primaryGroup?.DistinguishedName, primaryGroup?.Name);
            if (primaryGroup is not null && !nodes.ContainsKey(primaryGroup.DistinguishedName))
            {
                nodes[primaryGroup.DistinguishedName] = new FicheGraphNode(primaryGroup.DistinguishedName, primaryGroup.Name, primaryGroup.Sid, primaryGroup.AdminCount, primaryGroup.GroupType);
                edges[primaryGroup.DistinguishedName] = primaryGroup.MemberOf;
            }
        }
        return new FicheGroupGraph(item.Dn, edges.ToImmutable(), nodes.ToImmutable(), truncated, 0, primary);
    }

    public async Task<FicheLockoutRead> LockoutEventsAsync(string dn, int hours, int maxEvents, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("lockouts", 450, 1100, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(dn);
        var pdc = world.Directory.Domain.Controllers.FirstOrDefault()?.DnsName ?? "DC01";
        var now = source.Clock.GetUtcNow();
        if (item.Value is not DirectoryUser user)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Le journal des verrouillages se lit pour un compte utilisateur : rien n’a été lu.");
        }
        var windowStart = now - TimeSpan.FromHours(hours);
        var events = LockoutHistory(world, item, user, now).Where(e => e.At >= windowStart).Select(e => e with { Controller = pdc }).ToList();
        var ordered = events.OrderByDescending(e => e.At).ToList();
        var truncated = ordered.Count > maxEvents;
        return new FicheLockoutRead("read", pdc, "émulateur PDC", hours, maxEvents, truncated, [.. ordered.Take(maxEvents)], now, null);
    }

    /// <summary>
    /// 4740 events of the fictitious journal of the account over the longest window (720 h), the same at every read: the last
    /// lockout, a few earlier ones when the account had bad passwords, and sometimes an older lockout already lifted.
    /// </summary>
    private List<FicheLockoutEvent> LockoutHistory(SimulatedFicheWorld world, SimulatedObject item, DirectoryUser user, DateTimeOffset now)
    {
        var random = source.ScreenStream("fiche").Fork("lockouts/" + user.ObjectGuid.ToString("N"));
        var events = new List<FicheLockoutEvent>();
        var associated = world.Associations(item).Select(a => a.Name).ToList();
        var site = user.Office is { Length: >= 3 } office ? office[..3].ToUpperInvariant() : "PAR";
        var fallback = new[] { "SRV-WEB-01", "PT-" + site + "-0" + random.Next(100, 999).ToString(CultureInfo.InvariantCulture) };
        string Caller() => associated.Count > 0 && random.Chance(75) ? associated[random.Next(associated.Count)] : fallback[random.Next(fallback.Length)];
        const int longest = 720;
        if (AdValues.FromFileTime(user.LockoutTime) is DateTimeOffset lockedAt && lockedAt >= now - TimeSpan.FromHours(longest))
        {
            events.Add(new FicheLockoutEvent(lockedAt, Caller(), ""));
            var earlier = user.BadPasswordCount is >= 3 ? random.Next(1, 3) : random.Next(0, 2);
            for (var i = 0; i < earlier; i++)
            {
                events.Add(new FicheLockoutEvent(lockedAt - TimeSpan.FromHours(random.Next(3, 160)), Caller(), ""));
            }
        }
        else if (user.BadPasswordCount is > 0 && random.Chance(35))
        {
            events.Add(new FicheLockoutEvent(now - TimeSpan.FromHours(random.Next(6, 160)), Caller(), ""));
        }
        return events;
    }

    public async Task<FicheLogonReadings> LogonReadingsAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("logons", 600, 1400, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(dn);
        var entry = world.Entry(item);
        var now = source.Clock.GetUtcNow();
        var random = source.ScreenStream("fiche").Fork("logons/" + item.Id.ToString("N"));
        var stamp = entry.FileTime("lastLogonTimestamp");
        var count = entry.Int32("logonCount");
        var readings = new List<FicheLogonReading>();
        var controllers = world.Directory.Domain.Controllers;
        for (var i = 0; i < controllers.Length; i++)
        {
            var dc = controllers[i].DnsName;
            if (i > 0 && random.Chance(12))
            {
                readings.Add(new FicheLogonReading(dc, "RWDC", "unavailable", null, null, "délai de 8 s dépassé"));
                continue;
            }
            DateTimeOffset? last = null;
            if (stamp is DateTimeOffset s)
            {
                var gap = Math.Max(0, (now - s).TotalMinutes - 5);
                last = i == 0
                    ? s + TimeSpan.FromMinutes(random.NextDouble() * Math.Min(gap, 10 * 1440))
                    : random.Chance(70) ? s - TimeSpan.FromMinutes(random.Next(0, 3 * 1440)) : null;
            }
            var share = count is int total ? (int?)(i == 0 ? (int)(total * 0.7) : total - (int)(total * 0.7)) : null;
            readings.Add(new FicheLogonReading(dc, "RWDC", "read", last, share, null));
        }
        return new FicheLogonReadings([.. readings], controllers.Length, false, FicheDiagnostics.Interval(null, "absent"), now);
    }

    public async Task<FichePresenceReading> PingAsync(string computerDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computerDn);
        await WaitAsync("ping", 250, 900, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(computerDn);
        var now = source.Clock.GetUtcNow();
        if (item.Value is not DirectoryComputer computer)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "La présence se mesure sur un poste : rien n’a été envoyé.");
        }
        var observation = world.Observation(item);
        var answered = !AdValues.IsDisabled(computer.UserAccountControl) && observation?.Answered == true;
        var console = answered ? observation?.ConsoleUser : null;
        var detail = answered
            ? "Réponse au ping de " + computer.Name + (computer.DnsHostName is null ? "" : " (" + computer.DnsHostName + ")") + "."
            : "Aucune réponse au ping : poste éteint, hors du réseau ou ICMP filtré. Une absence de réponse n’est pas un verdict.";
        return new FichePresenceReading(item.Dn, computer.Name, answered ? "online" : "offline", answered ? "En ligne" : "Sans réponse au ping", now,
            answered ? now : observation?.LastOnlineAt, console, detail, null);
    }

    public async Task<FicheSessionsReading> SessionsAsync(string computerDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computerDn);
        await WaitAsync("sessions", 400, 1000, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(computerDn);
        var now = source.Clock.GetUtcNow();
        if (item.Value is not DirectoryComputer computer)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "Les sessions se lisent sur un poste : rien n’a été lu.");
        }
        var observation = world.Observation(item);
        if (observation?.Answered != true)
        {
            return new FicheSessionsReading(item.Dn, computer.Name, "failed", [], 0, now, "poste injoignable (RPC indisponible) ; aucune conclusion sur les sessions");
        }
        var random = source.ScreenStream("fiche").Fork("sessions/" + computer.ObjectGuid.ToString("N"));
        var rows = new List<FicheSessionRow>();
        var zone = world.Zone;
        if (observation.ConsoleUser is string console)
        {
            var opened = TimeZoneInfo.ConvertTime(now - TimeSpan.FromMinutes(random.Next(20, 480)), zone).ToString("HH':'mm", CultureInfo.InvariantCulture);
            var idle = random.Chance(30) ? FrenchText.Integer(random.Next(5, 90)) + " min" : null;
            rows.Add(new FicheSessionRow(console[(console.LastIndexOf('\\') + 1)..], "Active", "Console", opened, idle));
        }
        if (random.Chance(15))
        {
            rows.Add(new FicheSessionRow("adm-j.martin", "Déconnectée", "RDP", TimeZoneInfo.ConvertTime(now - TimeSpan.FromHours(random.Next(2, 30)), zone).ToString("HH':'mm", CultureInfo.InvariantCulture), FrenchText.Integer(random.Next(2, 20)) + " h"));
        }
        return new FicheSessionsReading(item.Dn, computer.Name, "read", [.. rows], 0, now, null);
    }

    private static readonly string[] Processes = ["chrome.exe", "Teams.exe", "OUTLOOK.EXE", "MsMpEng.exe", "svchost.exe", "explorer.exe", "WINWORD.EXE", "SearchIndexer.exe", "EXCEL.EXE", "OneDrive.exe"];

    public async Task<FicheInventoryReading> InventoryAsync(string computerDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computerDn);
        await WaitAsync("inventory", 900, 2000, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(computerDn);
        var now = source.Clock.GetUtcNow();
        if (item.Value is not DirectoryComputer computer)
        {
            throw FicheErrors.Error(FicheErrors.NotApplicable, "L’inventaire rapide se lit sur un poste : rien n’a été lu.");
        }
        var observation = world.Observation(item);
        if (observation?.Answered != true)
        {
            return new FicheInventoryReading(item.Dn, computer.Name, "failed", now, null, null, null, [], [], null, null, null, [], null, null,
                "Poste injoignable (CIM/WMI) : les valeurs connues gardent la date de leur dernière lecture réussie.");
        }
        var raw = world.RawObservation(computer.ObjectGuid)?.Inventory;
        var random = source.ScreenStream("fiche").Fork("inventory/" + computer.ObjectGuid.ToString("N") + "/" + now.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture));
        var memory = raw?.MemoryBytes ?? 16L * 1024 * 1024 * 1024;
        var diskSize = raw?.SystemDiskSizeBytes ?? 256L * 1024 * 1024 * 1024;
        var diskFree = raw?.SystemDiskFreeBytes ?? diskSize / 3;
        var disks = new List<FicheDisk> { new("C:", diskSize, diskFree) };
        if (random.Chance(25))
        {
            var dataSize = 512L * 1024 * 1024 * 1024;
            disks.Add(new FicheDisk("D:", dataSize, (long)(dataSize * (0.05 + random.NextDouble() * 0.8))));
        }
        var processes = Processes.OrderBy(_ => random.Next(1000)).Take(6)
            .Select(p => new FicheProcess(p, Math.Round(random.NextDouble() * (p == "MsMpEng.exe" ? 35 : 22), 1), random.Next(60, 900))).ToImmutableArray();
        var pending = random.Chance(20) ? "required" : random.Chance(10) ? "partial" : "none";
        ImmutableArray<string> reasons = pending switch
        {
            "required" => ["Windows Update", "Renommage de fichiers en attente"],
            "partial" => ["Composants Windows (CBS)"],
            _ => [],
        };
        return new FicheInventoryReading(item.Dn, computer.Name, "read", now, Math.Round(5 + random.NextDouble() * 88, 0), memory, (long)(memory * (0.06 + random.NextDouble() * 0.6)),
            [.. disks], processes, 2.0, raw?.LastBootAt, pending, reasons, raw?.Model, raw?.OsCaption ?? computer.OperatingSystem, null);
    }

    public async Task<FichePolicyReading> PasswordPolicyAsync(string userDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(userDn);
        await WaitAsync("policy", 200, 500, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(userDn);
        var now = source.Clock.GetUtcNow();
        var controller = world.Controller ?? "DC01";
        var policy = world.Directory.Domain.PasswordPolicy;
        if (item.Value is DirectoryUser { AdminCount: 1 })
        {
            return new FichePolicyReading("applies", "PSO-Comptes-a-privileges", TimeSpan.FromDays(60), false, 16, 24, true, 3, TimeSpan.FromMinutes(60), false, controller, now);
        }
        if (item.Dn.Contains("OU=Comptes de service,", StringComparison.OrdinalIgnoreCase))
        {
            return new FichePolicyReading("applies", "PSO-Comptes-de-service", null, true, 24, 24, true, 0, null, false, controller, now);
        }
        return new FichePolicyReading("none", null, policy.MaxPasswordAge, policy.MaxPasswordAge == TimeSpan.Zero, policy.MinPasswordLength, policy.PasswordHistoryLength, true,
            policy.LockoutThreshold, policy.LockoutDuration, false, controller, now);
    }

    private const long GenericAll = 0xF01FF;
    private const long GenericRead = 0x20094;
    private const long WriteProperty = 0x20;
    private const long ExtendedRight = 0x100;
    private const long CreateChild = 0x1;

    public async Task<FicheSecurityReading> SecurityAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("security", 250, 700, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(dn);
        var now = source.Clock.GetUtcNow();
        var entry = world.Entry(item);
        var aces = new List<FicheAce> { new(false, "Utilisateurs authentifiés", GenericRead, false, world.Directory.Domain.DnsName) };
        var protectedObject = entry.Int32("adminCount") == 1;
        var dnUpper = item.Dn.ToUpperInvariant();
        if (!protectedObject)
        {
            if (item.Kind == FicheKind.User && dnUpper.Contains(",OU=UTILISATEURS,", StringComparison.Ordinal))
            {
                aces.Add(new FicheAce(false, "GG-Support-N2", WriteProperty | ExtendedRight, true, "OU=Utilisateurs"));
                if (dnUpper.Contains("OU=DÉPARTS,", StringComparison.Ordinal))
                {
                    aces.Add(new FicheAce(true, "GG-Support-N2", 0x10000, false, "OU=Départs"));
                }
            }
            if (dnUpper.Contains(",OU=POSTES,", StringComparison.Ordinal) || dnUpper.StartsWith("OU=POSTES,", StringComparison.Ordinal))
            {
                aces.Add(new FicheAce(false, "GG-Admins-Postes", GenericAll, false, "OU=Postes"));
            }
            if (item.Kind == FicheKind.Group && item.Dn.StartsWith("CN=GG-App-", StringComparison.OrdinalIgnoreCase))
            {
                aces.Add(new FicheAce(false, "GG-Support-N2", WriteProperty, false, null));
            }
            if (item.Kind == FicheKind.Ou && (dnUpper.StartsWith("OU=UTILISATEURS,", StringComparison.Ordinal) || dnUpper.Contains(",OU=UTILISATEURS,", StringComparison.Ordinal)))
            {
                aces.Add(new FicheAce(false, "GG-Support-N2", CreateChild, false, "OU=Utilisateurs"));
            }
        }
        return new FicheSecurityReading(true, null, "Admins du domaine", 6, [.. aces], now);
    }

    public async Task<ImmutableArray<FicheAttributeChange>> AttributeHistoryAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await WaitAsync("metadata", 150, 400, cancellationToken).ConfigureAwait(false);
        var world = World;
        var item = Require(dn);
        var entry = world.Entry(item);
        var controllers = world.Directory.Domain.Controllers.Select(c => c.DnsName).ToList();
        if (controllers.Count == 0)
        {
            return [];
        }
        var random = source.ScreenStream("fiche").Fork("metadata/" + item.Id.ToString("N"));
        var created = entry.Generalized("whenCreated");
        var changed = entry.Generalized("whenChanged");
        if (created is not DateTimeOffset start)
        {
            return [];
        }
        var list = new List<FicheAttributeChange>();
        string Dc() => controllers[random.Next(controllers.Count)];
        foreach (var attribute in new[] { "cn", "objectClass", "sAMAccountName" })
        {
            if (entry.Has(attribute) || attribute == "cn")
            {
                list.Add(new FicheAttributeChange(attribute, start, Dc(), 1));
            }
        }
        if (entry.FileTime("pwdLastSet") is DateTimeOffset pwd)
        {
            list.Add(new FicheAttributeChange("pwdLastSet", pwd, Dc(), random.Next(2, 30)));
        }
        if (entry.FileTime("lockoutTime") is DateTimeOffset locked)
        {
            list.Add(new FicheAttributeChange("lockoutTime", locked, controllers[0], random.Next(2, 9)));
        }
        if (entry.FileTime("lastLogonTimestamp") is DateTimeOffset logon)
        {
            list.Add(new FicheAttributeChange("lastLogonTimestamp", logon, Dc(), random.Next(10, 200)));
        }
        if (changed is DateTimeOffset end && end > start)
        {
            var candidates = new[] { "description", "title", "department", "telephoneNumber", "userAccountControl", "managedBy", "location", "member" }.Where(entry.Has).ToList();
            if (candidates.Count > 0)
            {
                list.Add(new FicheAttributeChange(candidates[random.Next(candidates.Count)], end, Dc(), random.Next(2, 6)));
            }
        }
        return [.. list.OrderByDescending(c => c.At)];
    }
}
