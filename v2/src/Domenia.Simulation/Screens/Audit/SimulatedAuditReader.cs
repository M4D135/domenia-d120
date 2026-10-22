using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// « Audit AD » in simulation (docs/ops/audit.md): every read is derived from the fictitious directory as the session sees it
/// (<see cref="SimulatedDirectorySource.CurrentDirectory"/>, writes of the session included) and from the fixed data of
/// <see cref="SimulatedAuditData"/>; what the directory does not carry (addresses, sessions, replication state, history) comes
/// from the named sub-stream « screen/audit ». No network, no disk: memory only. Each read waits a realistic delay of its own
/// kind (« latency/screen/audit/… »), cancellable, none with <see cref="SimulationLatency.None"/>.
/// </summary>
public sealed class SimulatedAuditReader : IAuditReader
{
    private const string Dc01 = "DC01.example.local";
    private const string Dc02 = "DC02.example.local";

    private readonly SimulatedDirectorySource source;
    private readonly Lock gate = new();
    private (long Version, Index Index)? built;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedAuditReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    private DateTimeOffset Reference => source.World.Reference;

    private SeededRandom Stream(string name) => source.ScreenStream("audit").Fork(name);

    private Task WaitAsync(string kind, int min, int max, CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync("audit/" + kind, min, max, cancellationToken);

    private Index Current()
    {
        lock (gate)
        {
            var version = source.Overlay.Version;
            if (built is not { } known || known.Version != version)
            {
                known = (version, new Index(source.CurrentDirectory));
                built = known;
            }
            return known.Index;
        }
    }

    // ================================================================ index of the directory

    /// <summary>Objects of one directory picture by normalized DN and SID, with the transitive memberships.</summary>
    private sealed class Index
    {
        public Index(DirectorySnapshot directory)
        {
            Directory = directory;
            Root = directory.Domain.RootDn;
            DomainSid = directory.Domain.DomainSid;
            Users = directory.Users.ToDictionary(u => Norm(u.DistinguishedName), StringComparer.Ordinal);
            Computers = directory.Computers.ToDictionary(c => Norm(c.DistinguishedName), StringComparer.Ordinal);
            Groups = directory.Groups.ToDictionary(g => Norm(g.DistinguishedName), StringComparer.Ordinal);
            Ous = directory.OrganizationalUnits.ToDictionary(o => Norm(o.DistinguishedName), StringComparer.Ordinal);
            GroupsByName = directory.Groups.GroupBy(g => g.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
            UsersBySam = directory.Users.GroupBy(u => u.SamAccountName, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
            Sids = new Dictionary<string, (string Name, string Dn)>(StringComparer.OrdinalIgnoreCase);
            foreach (var u in directory.Users)
            {
                Sids[u.Sid] = (u.SamAccountName, u.DistinguishedName);
            }
            foreach (var c in directory.Computers)
            {
                Sids[c.Sid] = (c.SamAccountName, c.DistinguishedName);
            }
            foreach (var g in directory.Groups)
            {
                Sids[g.Sid] = (g.Name, g.DistinguishedName);
            }
        }

        public DirectorySnapshot Directory { get; }

        public string Root { get; }

        public string DomainSid { get; }

        public Dictionary<string, DirectoryUser> Users { get; }

        public Dictionary<string, DirectoryComputer> Computers { get; }

        public Dictionary<string, DirectoryGroup> Groups { get; }

        public Dictionary<string, DirectoryOu> Ous { get; }

        public Dictionary<string, DirectoryGroup> GroupsByName { get; }

        public Dictionary<string, DirectoryUser> UsersBySam { get; }

        public Dictionary<string, (string Name, string Dn)> Sids { get; }

        public string Rid(int rid) => DomainSid + "-" + rid.ToString(CultureInfo.InvariantCulture);

        public DirectoryGroup? GroupBySid(string sid) => Directory.Groups.FirstOrDefault(g => string.Equals(g.Sid, sid, StringComparison.OrdinalIgnoreCase));

        public DirectoryGroup? Group(string dn) => Groups.GetValueOrDefault(Norm(dn));

        /// <summary>memberOf of any object of the index; empty for an unknown DN.</summary>
        public ImmutableArray<string> MemberOf(string dn)
        {
            var key = Norm(dn);
            return Users.TryGetValue(key, out var u) ? u.MemberOf
                : Computers.TryGetValue(key, out var c) ? c.MemberOf
                : Groups.TryGetValue(key, out var g) ? g.MemberOf
                : [];
        }

        /// <summary>Transitive groups (normalized DNs) of an object, by its memberOf only (primary group excluded).</summary>
        public HashSet<string> Transitive(string dn)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var queue = new Queue<string>(MemberOf(dn));
            while (queue.Count > 0)
            {
                var next = queue.Dequeue();
                if (seen.Add(Norm(next)))
                {
                    foreach (var parent in MemberOf(next))
                    {
                        queue.Enqueue(parent);
                    }
                }
            }
            return seen;
        }

        /// <summary>Transitive user members of a group (members of nested groups included).</summary>
        public List<DirectoryUser> UserMembers(DirectoryGroup group)
        {
            var result = new Dictionary<string, DirectoryUser>(StringComparer.Ordinal);
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var queue = new Queue<string>(group.Members);
            while (queue.Count > 0)
            {
                var member = Norm(queue.Dequeue());
                if (!seen.Add(member))
                {
                    continue;
                }
                if (Users.TryGetValue(member, out var u))
                {
                    result.TryAdd(member, u);
                }
                else if (Groups.TryGetValue(member, out var g))
                {
                    foreach (var m in g.Members)
                    {
                        queue.Enqueue(m);
                    }
                }
            }
            return [.. result.Values];
        }

        public AuditTarget? Target(string dn)
        {
            var key = Norm(dn);
            if (Users.TryGetValue(key, out var u))
            {
                return new AuditTarget(u.DistinguishedName, AuditObjectKind.User, u.DisplayName ?? u.Cn, u.SamAccountName, u.ObjectGuid, u.Sid, null, u.PrimaryGroupId, u.Description);
            }
            if (Computers.TryGetValue(key, out var c))
            {
                return new AuditTarget(c.DistinguishedName, AuditObjectKind.Computer, c.Name, c.SamAccountName, c.ObjectGuid, c.Sid, c.DnsHostName, c.PrimaryGroupId, c.Description);
            }
            if (Groups.TryGetValue(key, out var g))
            {
                return new AuditTarget(g.DistinguishedName, AuditObjectKind.Group, g.Name, g.SamAccountName, g.ObjectGuid, g.Sid, null, null, g.Description);
            }
            if (Ous.TryGetValue(key, out var o))
            {
                return new AuditTarget(o.DistinguishedName, AuditObjectKind.OrganizationalUnit, o.Name, null, o.ObjectGuid, null, null, null, o.Description);
            }
            if (key == Norm(Root))
            {
                return new AuditTarget(Root, AuditObjectKind.Domain, Directory.Domain.DnsName, null, SimulatedAuditData.GuidOf("domain"), DomainSid, null, null, "Racine du domaine");
            }
            return null;
        }
    }

    /// <summary>Normalized DN: escaping and case ignored (a malformed DN stays as written, lower case).</summary>
    private static string Norm(string dn)
    {
        try
        {
            return DistinguishedName.Format(DistinguishedName.Parse(dn)).ToLowerInvariant();
        }
        catch (FormatException)
        {
            return dn.ToLowerInvariant();
        }
    }

    private static bool IsUnder(string dn, string container)
    {
        try
        {
            return DistinguishedName.AreEqual(dn, container) || DistinguishedName.IsWithin(dn, container, subtree: true);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private string Under(string path) => path.Length == 0 ? Current().Root : path + "," + Current().Root;

    private bool Active(DirectoryUser u) => !AdValues.IsDisabled(u.UserAccountControl);

    private static bool IsController(DirectoryComputer c) => AdValues.HasFlag(c.UserAccountControl, AdValues.ServerTrustAccount);

    private static bool IsServer(DirectoryComputer c) => c.OperatingSystem?.Contains("Server", StringComparison.OrdinalIgnoreCase) == true;

    private static AuditObjectRef Ref(DirectoryUser u, string? detail = null, bool privileged = false) =>
        new(u.DistinguishedName, u.DisplayName ?? u.Cn, AuditObjectKind.User, u.SamAccountName, !AdValues.IsDisabled(u.UserAccountControl),
            AdValues.FromFileTime(u.LastLogonTimestamp), AdValues.FromFileTime(u.PasswordLastSet), detail, privileged);

    private static AuditObjectRef Ref(DirectoryComputer c, string? detail = null) =>
        new(c.DistinguishedName, c.Name, AuditObjectKind.Computer, c.SamAccountName, !AdValues.IsDisabled(c.UserAccountControl),
            AdValues.FromFileTime(c.LastLogonTimestamp), AdValues.FromFileTime(c.PasswordLastSet), detail);

    private static AuditObjectRef Ref(DirectoryGroup g, string? detail = null) =>
        new(g.DistinguishedName, g.Name, AuditObjectKind.Group, g.SamAccountName, null, null, null, detail);

    // ================================================================ targets

    public Task<AuditTarget?> FindTargetAsync(string dn, CancellationToken cancellationToken)
    {
        // The local index of the session: answered at once, never a network read.
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Current().Target(dn));
    }

    public async Task<ImmutableArray<AuditTarget>> SearchObjectsAsync(string text, int limit, CancellationToken cancellationToken)
    {
        await WaitAsync("search", 40, 110, cancellationToken).ConfigureAwait(false);
        var needle = FrenchText.Fold(text.Trim());
        if (needle.Length == 0)
        {
            return [];
        }
        var index = Current();
        var candidates = new List<(int Rank, string Sort, AuditTarget Target)>();
        void Consider(string dn, params string?[] names)
        {
            var folded = names.Where(n => !string.IsNullOrEmpty(n)).Select(n => FrenchText.Fold(n!)).ToList();
            var rank = folded.Any(n => n == needle) ? 0 : folded.Any(n => n.StartsWith(needle, StringComparison.Ordinal)) ? 1 : folded.Any(n => n.Contains(needle, StringComparison.Ordinal)) ? 2 : -1;
            if (rank >= 0 && index.Target(dn) is { } target)
            {
                candidates.Add((rank, FrenchText.Fold(target.Name), target));
            }
        }
        foreach (var u in index.Directory.Users)
        {
            Consider(u.DistinguishedName, u.DisplayName, u.Cn, u.SamAccountName);
        }
        foreach (var c in index.Directory.Computers)
        {
            Consider(c.DistinguishedName, c.Name, c.DnsHostName);
        }
        foreach (var g in index.Directory.Groups)
        {
            Consider(g.DistinguishedName, g.Name);
        }
        foreach (var o in index.Directory.OrganizationalUnits)
        {
            Consider(o.DistinguishedName, o.Name);
        }
        Consider(index.Root, index.Directory.Domain.DnsName, index.Directory.Domain.NetbiosName);
        return [.. candidates.OrderBy(c => c.Rank).ThenBy(c => c.Sort, StringComparer.Ordinal).ThenBy(c => c.Target.Dn, StringComparer.Ordinal).Take(limit).Select(c => c.Target)];
    }

    public Task<AuditTarget?> FindDomainGroupAsync(int rid, CancellationToken cancellationToken)
    {
        // The local index of the session, by SID: answered at once, never a network read.
        cancellationToken.ThrowIfCancellationRequested();
        var index = Current();
        return Task.FromResult(index.GroupBySid(index.Rid(rid)) is { } group ? index.Target(group.DistinguishedName) : null);
    }

    // ================================================================ domain overview

    public async Task<DomainOverviewRead> DomainOverviewAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("overview", 650, 1400, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var directory = index.Directory;
        var now = source.Clock.GetUtcNow();
        var zone = source.World.TimeZone;
        var policy = directory.Domain.PasswordPolicy;
        var random = Stream("overview");
        var sections = ImmutableArray.CreateBuilder<OverviewSectionRead>();
        var highestUsn = directory.Users.Select(u => u.UsnChanged).Concat(directory.Computers.Select(c => c.UsnChanged)).Concat(directory.Groups.Select(g => g.UsnChanged)).DefaultIfEmpty(0L).Max() + random.Next(1200, 4800);
        sections.Add(new OverviewSectionRead("directory", "Annuaire", ReadState.Read, null,
        [
            new("Contrôleur interrogé", Dc01),
            new("Serveur", "CN=DC01,CN=Servers,CN=Paris,CN=Sites,CN=Configuration," + index.Root),
            new("Contexte de nommage par défaut", index.Root),
            new("Contexte de configuration", "CN=Configuration," + index.Root),
            new("Contexte de schéma", "CN=Schema,CN=Configuration," + index.Root),
            new("Domaine racine de forêt", index.Root),
            new("Niveau fonctionnel du domaine", "Windows Server 2016"),
            new("Niveau fonctionnel de la forêt", "Windows Server 2016"),
            new("Niveau du contrôleur", "Windows Server 2016"),
            new("USN le plus haut validé", FrenchText.Integer(highestUsn)),
            new("Heure du contrôleur", AuditText.LocalDateTime(now, zone)),
            new("Partitions publiées", string.Join(" | ", SimulatedAuditData.Partitions)),
        ]));
        var ridAllocated = 1600 + directory.ObjectCount + random.Next(400, 900);
        sections.Add(new OverviewSectionRead("fsmo", "Rôles FSMO", ReadState.Read, null,
        [
            new("Émulateur PDC", Dc01),
            new("Maître de schéma", Dc01),
            new("Maître de nommage de domaine", Dc01),
            new("Maître RID", Dc01),
            new("RID restants dans le pool", FrenchText.Integer(1_073_741_823L - ridAllocated), Tone.Ok),
            new("Maître d’infrastructure", Dc02),
        ]));
        sections.Add(new OverviewSectionRead("passwordPolicy", "Stratégie de mot de passe", ReadState.Read, null,
        [
            new("Longueur minimale", FrenchText.Count(policy.MinPasswordLength, "caractère", "caractères")),
            new("Historique conservé", FrenchText.Count(policy.PasswordHistoryLength, "mot de passe", "mots de passe")),
            new("Âge maximal", AuditText.Interval(AdInterval.Of(policy.MaxPasswordAge))),
            new("Âge minimal", AuditText.Interval(AdInterval.Of(TimeSpan.FromDays(1)))),
            new("Seuil de verrouillage", FrenchText.Count(policy.LockoutThreshold, "échec", "échecs")),
            new("Durée de verrouillage", AuditText.Interval(AdInterval.Of(policy.LockoutDuration), minutes: true)),
            new("Fenêtre d’observation", AuditText.Interval(AdInterval.Of(policy.LockoutObservationWindow), minutes: true)),
            new("Complexité exigée", "Oui", Tone.Ok),
            new("Chiffrement réversible", "Non", Tone.Ok),
            new("Quota de comptes machine par utilisateur", FrenchText.Integer(SimulatedAuditData.MachineAccountQuota), Tone.Warn),
        ]));
        var serviceAccounts = directory.Users.Count(u => u.DistinguishedName.Contains("OU=Comptes de service", StringComparison.OrdinalIgnoreCase));
        sections.Add(new OverviewSectionRead("fineGrained", "Stratégies affinées", ReadState.Read, null,
        [
            .. SimulatedAuditData.Psos.Select(p => new OverviewItemRead(p.Name,
                "priorité " + FrenchText.Integer(p.Precedence) + ", longueur minimale " + FrenchText.Integer(p.MinLength) + ", seuil " + FrenchText.Integer(p.LockoutThreshold)
                + ", " + FrenchText.Count(p.ServiceAccounts ? serviceAccounts : p.AppliesToGroups.Length, "cible", "cibles"))),
        ]));
        sections.Add(new OverviewSectionRead("recycleBin", "Corbeille AD", ReadState.Read, null,
        [
            new("Fonctionnalité facultative", "Activée", Tone.Ok),
            new("Objets supprimés visibles", FrenchText.Integer(SimulatedAuditData.DeletedObjectsVisible) + " (limite de lecture 25)"),
        ]));
        sections.Add(new OverviewSectionRead("controllers", "Contrôleurs de domaine", ReadState.Read, null,
        [
            .. directory.Computers.Where(IsController).OrderBy(c => c.Name, StringComparer.Ordinal).Select(c => new OverviewItemRead(c.Name,
                (c.DnsHostName ?? c.Name) + " | " + c.OperatingSystem + " | dernière ouverture " + (AdValues.FromFileTime(c.LastLogonTimestamp) is DateTimeOffset at ? AuditText.LocalDateTime(at, zone) : "inconnue"))),
        ]));
        var subnets = SimulatedAuditData.Sites.Sum(s => s.Subnets.Length);
        sections.Add(new OverviewSectionRead("sites", "Sites et sous-réseaux", ReadState.Read, null,
        [
            .. SimulatedAuditData.Sites.Select(s => new OverviewItemRead("Site " + s.Name, s.Description + " · " + string.Join(", ", s.Subnets))),
            new("Nombre de sites", FrenchText.Integer(SimulatedAuditData.Sites.Length)),
            new("Nombre de sous-réseaux", FrenchText.Integer(subnets)),
        ]));
        sections.Add(new OverviewSectionRead("trusts", "Approbations", ReadState.Read, null,
            [new(SimulatedAuditData.TrustName, "Bidirectionnelle, forêt, NetBIOS " + SimulatedAuditData.TrustNetbios + ", filtrage des SID actif")]));
        sections.Add(new OverviewSectionRead("gpo", "Stratégies de groupe", ReadState.Read, null,
        [
            new("Nombre d’objets GPO", FrenchText.Integer(SimulatedAuditData.Gpos.Length - 1)),
            .. SimulatedAuditData.Gpos.Where(g => g != SimulatedAuditData.SiteParis).OrderBy(g => g.DaysSinceChange).Take(12).Select(g => new OverviewItemRead(g.Name,
                "modifiée le " + AuditText.LocalDateTime(Reference - TimeSpan.FromDays(g.DaysSinceChange) - TimeSpan.FromHours(3), zone) + " · " + AuditGpoRules.StatusText(g.Flags),
                g.Flags == 3 ? Tone.Warn : null)),
        ]));
        var privilegedGroups = new[] { 512, 519, 518 }.Select(r => index.GroupBySid(index.Rid(r)))
            .Concat(new[] { "S-1-5-32-544", "S-1-5-32-548", "S-1-5-32-549", "S-1-5-32-551", "S-1-5-32-550" }.Select(index.GroupBySid))
            .OfType<DirectoryGroup>().ToList();
        sections.Add(new OverviewSectionRead("privilegedGroups", "Groupes privilégiés", ReadState.Read, null,
        [
            .. privilegedGroups.Select(g => new OverviewItemRead(g.Name,
                FrenchText.Count(g.Members.Length, "membre", "membres") + (g.Members.Length > 0 ? " : " + string.Join(", ", g.Members.Take(12).Select(AuditText.NameOf)) : string.Empty),
                g.Members.Length > 5 ? Tone.Warn : null)),
        ]));

        var checks = Checks(index, now);
        int TotalOf(string id) => checks.First(c => c.Id == id).Total;
        sections.Add(new OverviewSectionRead("watchlist", "Comptes à surveiller", ReadState.Read, null,
        [
            new("Mot de passe sans expiration", FrenchText.Count(TotalOf("passwordNeverExpires"), "compte lu", "comptes lus") + ", limite 60"),
            new("Comptes désactivés", FrenchText.Count(TotalOf("disabledAccounts"), "compte lu", "comptes lus") + ", limite 200"),
            new("Sans pré-authentification Kerberos", FrenchText.Count(TotalOf("asrepRoast"), "compte", "comptes") + ", risque d’AS-REP roasting"),
            new("Comptes de service avec SPN", FrenchText.Count(TotalOf("kerberoast"), "compte", "comptes") + ", cible de Kerberoasting", TotalOf("kerberoast") > 0 ? Tone.Warn : null),
            new("Délégation non contrainte", FrenchText.Count(TotalOf("unconstrainedDelegation"), "compte", "comptes")),
            new("Dernier changement du mot de passe krbtgt", checks.First(c => c.Id == "krbtgtPassword").ValueText ?? "Non lu", Tone.Warn),
        ]));
        var elapsed = 640 + random.Next(0, 700);
        return new DomainOverviewRead(Dc01, now, elapsed, sections.ToImmutable(), checks);
    }

    private ImmutableArray<SecurityCheckRead> Checks(Index index, DateTimeOffset now)
    {
        var directory = index.Directory;
        var zone = source.World.TimeZone;
        var checks = ImmutableArray.CreateBuilder<SecurityCheckRead>();
        SecurityCheckRead Found(string id, IEnumerable<AuditObjectRef> objects, int limit = 60, string? valueText = null)
        {
            var all = objects.OrderBy(o => FrenchText.Fold(o.Name), StringComparer.Ordinal).ThenBy(o => o.Dn, StringComparer.Ordinal).ToList();
            return new SecurityCheckRead(id, ReadState.Read, null, [.. all.Take(limit)], all.Count, limit, null, valueText);
        }
        var activeUsers = directory.Users.Where(Active).ToList();
        var protectedSids = new[] { 512, 516, 518, 519 }.Select(index.Rid).Concat(["S-1-5-32-544", "S-1-5-32-548", "S-1-5-32-549", "S-1-5-32-550", "S-1-5-32-551"]).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var protectedGroups = directory.Groups.Where(g => protectedSids.Contains(g.Sid)).Select(g => Norm(g.DistinguishedName)).ToHashSet(StringComparer.Ordinal);
        var privilegedMembers = directory.Groups.Where(g => protectedSids.Contains(g.Sid) && !g.Sid.EndsWith("-516", StringComparison.Ordinal))
            .SelectMany(index.UserMembers).DistinctBy(u => u.ObjectGuid).ToList();
        var protectedUsers = index.GroupBySid(index.Rid(525));
        var inProtectedUsers = protectedUsers is null ? new HashSet<Guid>() : index.UserMembers(protectedUsers).Select(u => u.ObjectGuid).ToHashSet();
        var krbtgt = directory.Users.FirstOrDefault(u => u.Sid.EndsWith("-502", StringComparison.Ordinal));

        var replication = index.UsersBySam.GetValueOrDefault(SimulatedAuditData.ReplicationRightsAccount);
        checks.Add(Found("dcsyncRights", replication is null ? [] : [Ref(replication, "Répliquer les modifications de l’annuaire, Répliquer toutes les modifications de l’annuaire (posées sur la racine du domaine)")]));
        checks.Add(Found("unconstrainedDelegation",
            directory.Users.Where(u => AdValues.HasFlag(u.UserAccountControl, AdValues.TrustedForDelegation)).Select(u => Ref(u))
                .Concat(directory.Computers.Where(c => !IsController(c) && AdValues.HasFlag(c.UserAccountControl, AdValues.TrustedForDelegation)).Select(c => Ref(c)))));
        if (krbtgt is not null && AdValues.FromFileTime(krbtgt.PasswordLastSet) is DateTimeOffset krbtgtSet)
        {
            var days = (long)Math.Floor((now - krbtgtSet).TotalDays);
            checks.Add(new SecurityCheckRead("krbtgtPassword", ReadState.Read, null, [Ref(krbtgt, "Mot de passe changé le " + AuditText.LocalDateTime(krbtgtSet, zone))], 1, 1, days,
                "Inchangé depuis " + FrenchText.Count(days, "jour", "jours") + " (le " + FrenchText.ShortDate(DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(krbtgtSet, zone).DateTime)) + ")"));
        }
        else
        {
            checks.Add(new SecurityCheckRead("krbtgtPassword", ReadState.Unavailable, "pwdLastSet du compte krbtgt non lu.", [], 0, 1, null, null));
        }
        var delegating = index.UsersBySam.GetValueOrDefault(SimulatedAuditData.ConstrainedDelegationAccount);
        checks.Add(Found("constrainedDelegation", delegating is null ? [] : [Ref(delegating, "Vers " + SimulatedAuditData.ConstrainedDelegationTarget + ", avec transition de protocole")]));
        checks.Add(Found("asrepRoast", activeUsers.Where(u => AdValues.HasFlag(u.UserAccountControl, 0x400000)).Select(u => Ref(u, u.AdminCount == 1 ? "Compte à privilèges" : null, u.AdminCount == 1))));
        checks.Add(Found("passwordNotRequired", activeUsers.Where(u => AdValues.HasFlag(u.UserAccountControl, AdValues.PasswordNotRequired)).Select(u => Ref(u))));
        checks.Add(Found("reversibleEncryption", activeUsers.Where(u => AdValues.HasFlag(u.UserAccountControl, 0x80)).Select(u => Ref(u))));
        checks.Add(Found("kerberoast", activeUsers.Where(u => SimulatedAuditData.ServicePrincipalNames.ContainsKey(u.SamAccountName))
            .Select(u => Ref(u, (u.AdminCount == 1 ? "Compte à privilèges · " : string.Empty) + string.Join(", ", SimulatedAuditData.ServicePrincipalNames[u.SamAccountName]), u.AdminCount == 1))));
        var policy = directory.Domain.PasswordPolicy;
        var gaps = (policy.MinPasswordLength < 12 ? 1 : 0) + (policy.LockoutThreshold == 0 ? 1 : 0);
        checks.Add(new SecurityCheckRead("domainPasswordPolicy", ReadState.Read, null, [], gaps, 0, null,
            FrenchText.Count(policy.MinPasswordLength, "caractère", "caractères") + " au minimum, complexité exigée, verrouillage après " + FrenchText.Count(policy.LockoutThreshold, "échec", "échecs")));
        checks.Add(Found("privilegedNotProtected", privilegedMembers.Where(u => Active(u) && u != krbtgt && !inProtectedUsers.Contains(u.ObjectGuid))
            .Select(u => Ref(u, "Membre de " + string.Join(", ", index.Transitive(u.DistinguishedName).Where(protectedGroups.Contains).Select(k => index.Groups[k].Name))))));
        checks.Add(Found("passwordNeverExpires", activeUsers.Where(u => AdValues.HasFlag(u.UserAccountControl, AdValues.DontExpirePassword)).Select(u => Ref(u))));
        checks.Add(new SecurityCheckRead("machineAccountQuota", ReadState.Read, null, [], 0, 0, SimulatedAuditData.MachineAccountQuota,
            "Chaque utilisateur authentifié peut joindre " + FrenchText.Count(SimulatedAuditData.MachineAccountQuota, "poste", "postes") + " au domaine"));
        var staleLimit = now - TimeSpan.FromDays(90);
        checks.Add(Found("staleUsers", activeUsers.Where(u => AdValues.FromFileTime(u.LastLogonTimestamp) is DateTimeOffset at && at < staleLimit)
            .Select(u => Ref(u, "Dernière connexion il y a " + AuditText.Duration(now - AdValues.FromFileTime(u.LastLogonTimestamp)!.Value))), limit: 200));
        var workstations = directory.Computers.Where(c => !IsController(c) && !IsServer(c) && !AdValues.IsDisabled(c.UserAccountControl)).ToList();
        checks.Add(Found("lapsMissing", workstations.Where(c => c.Laps == LapsKind.None || c.LapsExpiration is null).Select(c => Ref(c, "Aucune date d’expiration LAPS lue")), limit: 200));
        checks.Add(new SecurityCheckRead("recycleBin", ReadState.Read, null, [], 0, 0, null, "Corbeille activée sur la forêt"));
        checks.Add(Found("adminCountOrphans", directory.Users.Where(u => u.AdminCount == 1 && u != krbtgt && !index.Transitive(u.DistinguishedName).Overlaps(protectedGroups))
            .Select(u => Ref(u, "adminCount = 1, membre de " + string.Join(", ", u.MemberOf.Select(AuditText.NameOf))))));
        checks.Add(Found("builtinAdminActive", directory.Users.Where(u => u.Sid.EndsWith("-500", StringComparison.Ordinal) && Active(u)
            && AdValues.FromFileTime(u.LastLogonTimestamp) is DateTimeOffset at && at > now - TimeSpan.FromDays(30))
            .Select(u => Ref(u, "Dernière connexion il y a " + AuditText.Duration(now - AdValues.FromFileTime(u.LastLogonTimestamp)!.Value)))));
        checks.Add(Found("neverLoggedUsers", activeUsers.Where(u => u.LastLogonTimestamp is null or 0).Select(u => Ref(u, "Créé le " + AuditText.LocalDateTime(u.WhenCreated, zone)))));
        checks.Add(Found("staleComputers", directory.Computers.Where(c => !IsController(c) && !AdValues.IsDisabled(c.UserAccountControl)
            && (AdValues.FromFileTime(c.LastLogonTimestamp) is DateTimeOffset at ? at < staleLimit : c.WhenCreated < now - TimeSpan.FromDays(60)))
            .Select(c => Ref(c, AdValues.FromFileTime(c.LastLogonTimestamp) is DateTimeOffset at ? "Dernière connexion il y a " + AuditText.Duration(now - at) : "Jamais connecté au domaine")), limit: 200));
        checks.Add(Found("lapsExpired", workstations.Where(c => AdValues.FromFileTime(c.LapsExpiration) is DateTimeOffset at && at < now)
            .Select(c => Ref(c, "Expiré le " + AuditText.LocalDateTime(AdValues.FromFileTime(c.LapsExpiration)!.Value, zone)))));
        checks.Add(Found("disabledInGroups", directory.Users.Where(u => !Active(u) && !u.MemberOf.IsEmpty)
            .Select(u => Ref(u, FrenchText.Count(u.MemberOf.Length, "groupe", "groupes") + " : " + string.Join(", ", u.MemberOf.Take(4).Select(AuditText.NameOf)))), limit: 200));
        checks.Add(Found("privilegedMembers", privilegedMembers.Select(u => Ref(u,
            string.Join(", ", index.Transitive(u.DistinguishedName).Where(protectedGroups.Contains).Select(k => index.Groups[k].Name))))));
        checks.Add(Found("lockedAccounts", directory.Users.Where(u => u.ComputedAccountControl is int c && AdValues.HasFlag(c, AdValues.LockedOut))
            .Select(u => Ref(u, AdValues.FromFileTime(u.LockoutTime) is DateTimeOffset at ? "Verrouillé depuis " + AuditText.LocalDateTime(at, zone) : null))));
        checks.Add(Found("disabledAccounts", directory.Users.Where(u => !Active(u)).Select(u => Ref(u, u.Description)), limit: 200));
        checks.Add(Found("trusts", [new AuditObjectRef("CN=" + SimulatedAuditData.TrustName + ",CN=System," + index.Root, SimulatedAuditData.TrustName, AuditObjectKind.Domain, SimulatedAuditData.TrustNetbios + "$", true, null, null,
            "Bidirectionnelle, approbation de forêt, filtrage des SID actif")]));
        return checks.ToImmutable();
    }

    public async Task<LocalTotalsRead> LocalTotalsAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("totals", 60, 160, cancellationToken).ConfigureAwait(false);
        var directory = Current().Directory;
        return new LocalTotalsRead(ReadState.Read, null, directory.ReadAt, directory.Complete, true,
        [
            new("Utilisateur", false, directory.Users.Count(u => !AdValues.IsDisabled(u.UserAccountControl))),
            new("Utilisateur", true, directory.Users.Count(u => AdValues.IsDisabled(u.UserAccountControl))),
            new("Ordinateur", false, directory.Computers.Count(c => !AdValues.IsDisabled(c.UserAccountControl))),
            new("Ordinateur", true, directory.Computers.Count(c => AdValues.IsDisabled(c.UserAccountControl))),
            new("Groupe", false, directory.Groups.Length),
            new("OU", false, directory.OrganizationalUnits.Length),
            new("Conteneur", false, directory.Domain.Containers.Length),
        ]);
    }

    // ================================================================ controllers

    public async Task<ControllerListRead> ControllersAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("dcs", 120, 260, cancellationToken).ConfigureAwait(false);
        var directory = Current().Directory;
        var controllers = directory.Computers.Where(IsController).OrderBy(c => c.Name, StringComparer.Ordinal).Select(c =>
        {
            var site = directory.Domain.Controllers.FirstOrDefault(d => string.Equals(d.DnsName, c.DnsHostName, StringComparison.OrdinalIgnoreCase))?.Site;
            return new ControllerRead(c.Name, c.DnsHostName ?? c.Name, c.OperatingSystem, site, false, c.DistinguishedName);
        }).ToImmutableArray();
        return new ControllerListRead(controllers, false, Dc01, null, Dc01, source.Clock.GetUtcNow());
    }

    public async Task<ControllerProbesRead> ProbeControllersAsync(IReadOnlyList<string> controllers, string? pdc, CancellationToken cancellationToken)
    {
        await WaitAsync("probe", 500 + (120 * controllers.Count), 900 + (220 * controllers.Count), cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var known = Current().Directory.Computers.Where(IsController).ToDictionary(c => c.DnsHostName ?? c.Name, StringComparer.OrdinalIgnoreCase);
        var results = ImmutableArray.CreateBuilder<ControllerProbeRead>();
        foreach (var name in controllers)
        {
            if (!known.ContainsKey(name))
            {
                // A name that is not a controller of the fictitious domain does not resolve: « not read », never « down ».
                results.Add(new ControllerProbeRead(name, [], "Hôte inconnu (simulation).", false, false, ReadState.NotRead, null, null, null, null, null, ReadState.NotRead, null, []));
                continue;
            }
            var first = name.StartsWith("DC01", StringComparison.OrdinalIgnoreCase);
            var random = Stream("probe/" + name.ToLowerInvariant());
            var skew = first ? 1.2 : -3.6;
            var partner = first ? "DC02" : "DC01";
            var neighbors = SimulatedAuditData.Partitions.Select((partition, i) =>
            {
                var failing = !first && partition.StartsWith("DC=ForestDnsZones", StringComparison.Ordinal);
                var success = failing ? Reference - TimeSpan.FromHours(26) - TimeSpan.FromMinutes(random.Next(5, 40)) : now - TimeSpan.FromMinutes(random.Next(4, 38));
                var attempt = failing ? now - TimeSpan.FromMinutes(random.Next(6, 14)) : success;
                return new ReplicationNeighborRead(partition, partner, success, attempt, failing ? 1722 : 0, failing ? 3 : 0, false);
            }).ToImmutableArray();
            results.Add(new ControllerProbeRead(name, [first ? "10.10.0.11" : "10.20.0.12"], null, true, true, ReadState.Read, null, now + TimeSpan.FromSeconds(skew), now,
                true, 0, ReadState.Read, null, neighbors));
        }
        return new ControllerProbesRead(results.ToImmutable(), [Dc01, Dc02], ReadState.Read, null, pdc, now);
    }

    public async Task<ControllerServicesReads> ControllerServicesAsync(IReadOnlyList<string> controllers, int budgetSeconds, CancellationToken cancellationToken)
    {
        await WaitAsync("services", 600, 1300, cancellationToken).ConfigureAwait(false);
        var known = Current().Directory.Computers.Where(IsController).Select(c => c.DnsHostName ?? c.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var results = controllers.Select(name =>
        {
            if (!known.Contains(name))
            {
                return new ControllerServicesRead(name, ReadState.Unavailable, "Hôte inconnu (simulation) : aucune session CIM.", []);
            }
            var second = name.StartsWith("DC02", StringComparison.OrdinalIgnoreCase);
            ImmutableArray<ServiceStateRead> services =
            [
                new("NTDS", "Running", "Auto"),
                new("Netlogon", "Running", "Auto"),
                new("Kdc", "Running", "Auto"),
                new("W32Time", "Running", "Auto"),
                new("ADWS", second ? "Stopped" : "Running", "Auto"),
                new("DNS", "Running", "Auto"),
                new("DFSR", "Running", "Auto"),
            ];
            return new ControllerServicesRead(name, ReadState.Read, null, services);
        }).ToImmutableArray();
        return new ControllerServicesReads(results, budgetSeconds, 700 + (controllers.Count * 180), source.Clock.GetUtcNow());
    }

    public async Task<ObjectComparisonRead> CompareObjectAsync(AuditTarget target, IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        await WaitAsync("compare", 300, 700, cancellationToken).ConfigureAwait(false);
        var index = Current();
        // DC02 lags behind DC01 for the writes of this session: it still shows the generated directory.
        var generated = source.World.Directory;
        var key = Norm(target.Dn);
        var random = Stream("compare/" + key);
        var readings = ImmutableArray.CreateBuilder<ControllerReadingRead>();
        foreach (var name in controllers)
        {
            var isDc = index.Directory.Computers.Any(c => IsController(c) && string.Equals(c.DnsHostName, name, StringComparison.OrdinalIgnoreCase));
            if (!isDc)
            {
                readings.Add(new ControllerReadingRead(name, false, "Hôte inconnu (simulation).", ImmutableDictionary<string, ImmutableArray<string>>.Empty, []));
                continue;
            }
            var lagging = name.StartsWith("DC02", StringComparison.OrdinalIgnoreCase);
            var attributes = Attributes(target, lagging ? new Index(generated) : index);
            var metadata = attributes.Keys.Order(StringComparer.OrdinalIgnoreCase).Select(attribute =>
            {
                var version = 1 + (int)(SeededRandom.Fnv1a64(key + "/" + attribute) % 7);
                var changed = Reference - TimeSpan.FromDays(1 + (long)(SeededRandom.Fnv1a64(attribute + "/" + key) % 400));
                return new ReplicationMetadataRead(attribute, version, changed, version % 2 == 0 ? "DC02" : "DC01", random.Next(20_000, 900_000), random.Next(20_000, 900_000));
            }).ToImmutableArray();
            if (!lagging && source.Overlay.ChangedObjects > 0)
            {
                // A write of the session on this object: newer version, changed now on DC01.
                var current = index.Users.GetValueOrDefault(key);
                var before = new Index(generated).Users.GetValueOrDefault(key);
                if (current is not null && before is not null && current.LockoutTime != before.LockoutTime)
                {
                    metadata = [.. metadata.Select(m => m.Attribute == "lockoutTime" ? m with { Version = m.Version + 1, ChangedAt = current.WhenChanged, OriginatingController = "DC01" } : m)];
                }
            }
            readings.Add(new ControllerReadingRead(name, true, null, attributes, metadata));
        }
        return new ObjectComparisonRead(target.Dn, target.Name, readings.ToImmutable(), source.Clock.GetUtcNow());
    }

    private static ImmutableDictionary<string, ImmutableArray<string>> Attributes(AuditTarget target, Index index)
    {
        var key = Norm(target.Dn);
        var map = new Dictionary<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase);
        static ImmutableArray<string> One(object? value) => value is null || (value is string s && s.Length == 0) ? [] : [Convert.ToString(value, CultureInfo.InvariantCulture)!];
        if (index.Users.TryGetValue(key, out var u))
        {
            map["displayName"] = One(u.DisplayName);
            map["description"] = One(u.Description);
            map["title"] = One(u.Title);
            map["department"] = One(u.Department);
            map["telephoneNumber"] = One(u.TelephoneNumber);
            map["userAccountControl"] = One(u.UserAccountControl);
            map["lockoutTime"] = One(u.LockoutTime ?? 0);
            map["memberOf"] = [.. u.MemberOf.Select(AuditText.NameOf)];
        }
        else if (index.Computers.TryGetValue(key, out var c))
        {
            map["dNSHostName"] = One(c.DnsHostName);
            map["description"] = One(c.Description);
            map["location"] = One(c.Location);
            map["operatingSystem"] = One(c.OperatingSystem);
            map["operatingSystemVersion"] = One(c.OperatingSystemVersion);
            map["userAccountControl"] = One(c.UserAccountControl);
        }
        else if (index.Groups.TryGetValue(key, out var g))
        {
            map["description"] = One(g.Description);
            map["groupType"] = One(g.GroupType);
            map["member"] = [.. g.Members.Select(AuditText.NameOf)];
            map["managedBy"] = One(g.ManagedByDn is null ? null : AuditText.NameOf(g.ManagedByDn));
        }
        else if (index.Ous.TryGetValue(key, out var o))
        {
            map["description"] = One(o.Description);
            map["managedBy"] = One(o.ManagedByDn is null ? null : AuditText.NameOf(o.ManagedByDn));
        }
        return map.ToImmutableDictionary(StringComparer.OrdinalIgnoreCase);
    }

    // ================================================================ password policy

    public async Task<PasswordPolicyRead> PasswordPolicyAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        await WaitAsync("policy", 140, 320, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var user = index.Users.GetValueOrDefault(Norm(target.Dn)) ?? throw new DomeniaOperationException(AuditErrors.TargetUnknown, AuditErrors.TargetUnknownMessage);
        var policy = index.Directory.Domain.PasswordPolicy;
        var domain = new DomainPolicyRead(policy.MinPasswordLength, policy.PasswordHistoryLength, AdInterval.Of(policy.MaxPasswordAge), AdInterval.Of(TimeSpan.FromDays(1)),
            policy.LockoutThreshold, AdInterval.Of(policy.LockoutDuration), AdInterval.Of(policy.LockoutObservationWindow), 1, SimulatedAuditData.MachineAccountQuota);
        var pso = ResultantPso(index, user);
        PsoRead? psoRead = null;
        string? resultant = null;
        if (pso is not null)
        {
            resultant = "CN=" + pso.Name + ",CN=Password Settings Container,CN=System," + index.Root;
            psoRead = new PsoRead(resultant, pso.Name, pso.Precedence, pso.MinLength, pso.History, pso.Complexity, false,
                pso.MaxAge is TimeSpan max ? AdInterval.Of(max) : AdInterval.NeverExpires, AdInterval.Of(TimeSpan.FromDays(1)), pso.LockoutThreshold,
                pso.LockoutDuration is TimeSpan d ? AdInterval.Of(d) : AdInterval.NeverExpires, AdInterval.Of(TimeSpan.FromMinutes(30)),
                pso.ServiceAccounts ? index.Directory.Users.Count(u => u.DistinguishedName.Contains("OU=Comptes de service", StringComparison.OrdinalIgnoreCase)) : pso.AppliesToGroups.Length);
        }
        // msDS-UserPasswordExpiryTimeComputed as the generated directory carries it: the PSO keeps the domain maximum age (90 days),
        // so the value the controller computes is the same and every screen shows the same expiry.
        var expiry = user.PasswordExpiryComputed;
        return new PasswordPolicyRead(user.DistinguishedName, Dc01, source.Clock.GetUtcNow(), user.UserAccountControl, user.ComputedAccountControl, user.PasswordLastSet,
            expiry, resultant, null, psoRead, domain, SimulatedAuditData.Psos.Length);
    }

    private static SimulatedAuditData.Pso? ResultantPso(Index index, DirectoryUser user)
    {
        var groups = index.Transitive(user.DistinguishedName);
        foreach (var pso in SimulatedAuditData.Psos.OrderBy(p => p.Precedence))
        {
            if (pso.ServiceAccounts && user.DistinguishedName.Contains("OU=Comptes de service", StringComparison.OrdinalIgnoreCase))
            {
                return pso;
            }
            if (pso.AppliesToGroups.Any(name => index.GroupsByName.TryGetValue(name, out var g) && groups.Contains(Norm(g.DistinguishedName))))
            {
                return pso;
            }
        }
        return null;
    }

    // ================================================================ nested groups

    public async Task<GroupGraphRead> NestedGroupsAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        await WaitAsync("groups", 160, 420, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var start = index.MemberOf(target.Dn);
        var nodes = ImmutableArray.CreateBuilder<GroupNodeRead>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var queue = new Queue<string>(start);
        while (queue.Count > 0 && nodes.Count < 2000)
        {
            var dn = queue.Dequeue();
            if (!seen.Add(Norm(dn)) || index.Group(dn) is not { } group)
            {
                continue;
            }
            nodes.Add(new GroupNodeRead(group.DistinguishedName, group.Name, group.Sid, group.AdminCount, group.MemberOf, group.Members.Length > 1500));
            foreach (var parent in group.MemberOf)
            {
                queue.Enqueue(parent);
            }
        }
        PrimaryGroupRead? primary = null;
        if (target.PrimaryGroupId is int rid && index.GroupBySid(index.Rid(rid)) is { } primaryGroup)
        {
            primary = new PrimaryGroupRead(primaryGroup.DistinguishedName, primaryGroup.Name, primaryGroup.Sid);
        }
        var elapsed = 40 + (nodes.Count * 6);
        return new GroupGraphRead(target.Dn, Dc01, source.Clock.GetUtcNow(), elapsed, start, true, null, nodes.ToImmutable(), [], primary, false, null);
    }

    public async Task<MembershipRead> MembershipAsync(AuditTarget target, string groupDn, CancellationToken cancellationToken)
    {
        await WaitAsync("membership", 90, 220, cancellationToken).ConfigureAwait(false);
        var index = Current();
        if (index.Group(groupDn) is null)
        {
            return new MembershipRead(target.Dn, groupDn, null, "Groupe introuvable sur le contrôleur.", Dc01, source.Clock.GetUtcNow());
        }
        // LDAP_MATCHING_RULE_IN_CHAIN: memberOf only, the primary group is not covered.
        var member = index.Transitive(target.Dn).Contains(Norm(groupDn));
        return new MembershipRead(target.Dn, groupDn, member, null, Dc01, source.Clock.GetUtcNow());
    }

    // ================================================================ delegations

    public async Task<AclRead> DelegationsAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        await WaitAsync("acl", 180, 420, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var (aces, isProtected) = SimulatedAuditAcl.Build(index.Directory, target, index.Rid, sam => index.UsersBySam.GetValueOrDefault(sam)?.Sid, name => index.GroupsByName.GetValueOrDefault(name)?.Sid);
        var sids = aces.Select(a => a.Sid).Append(index.Rid(512)).Where(s => s.StartsWith("S-1-5-21-", StringComparison.Ordinal)).Distinct(StringComparer.OrdinalIgnoreCase);
        var names = sids.Where(index.Sids.ContainsKey).ToImmutableDictionary(s => s, s => index.Sids[s].Name, StringComparer.OrdinalIgnoreCase);
        return new AclRead(target.Dn, ReadState.Read, null, aces.Length, false, 1000, aces, index.Rid(512), isProtected, names, null,
            ImmutableDictionary<Guid, string>.Empty, Dc01, source.Clock.GetUtcNow());
    }

    public async Task<TokenGroupsRead> TokenGroupsAsync(string sid, CancellationToken cancellationToken)
    {
        await WaitAsync("token", 90, 220, cancellationToken).ConfigureAwait(false);
        var index = Current();
        if (!index.Sids.TryGetValue(sid, out var principal))
        {
            return new TokenGroupsRead(sid, null, ReadState.Unavailable, "Compte introuvable par son SID sur le contrôleur.", [], Dc01, source.Clock.GetUtcNow());
        }
        var groups = index.Transitive(principal.Dn).Where(index.Groups.ContainsKey).Select(k => index.Groups[k].Sid).ToList();
        var primaryRid = index.Users.GetValueOrDefault(Norm(principal.Dn))?.PrimaryGroupId ?? index.Computers.GetValueOrDefault(Norm(principal.Dn))?.PrimaryGroupId;
        if (primaryRid is int rid)
        {
            groups.Add(index.Rid(rid));
        }
        return new TokenGroupsRead(sid, principal.Name, ReadState.Read, null, [.. groups.Distinct(StringComparer.OrdinalIgnoreCase)], Dc01, source.Clock.GetUtcNow());
    }

    // ================================================================ group policy

    public async Task<GpoLinksRead> GpoLinksAsync(IReadOnlyList<string> containers, CancellationToken cancellationToken)
    {
        await WaitAsync("gpo", 160, 380, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var byContainer = SimulatedAuditData.Links.ToDictionary(l => Norm(Under(l.Path)), StringComparer.Ordinal);
        var reads = containers.Select(dn =>
        {
            byContainer.TryGetValue(Norm(dn), out var links);
            return new GpoContainerRead(dn, links is null ? null : SimulatedAuditData.GpLink(links.Links, index.Root), links?.GpOptions ?? 0, ReadState.Read, null);
        }).ToImmutableArray();
        var gpos = SimulatedAuditData.Gpos.Where(g => g != SimulatedAuditData.SiteParis)
            .Select(g => new GpoRead(g.Guid, g.Name, g.Flags, Reference - TimeSpan.FromDays(g.DaysSinceChange))).ToImmutableArray();
        return new GpoLinksRead(reads, gpos, ReadState.Read, null, Dc01, source.Clock.GetUtcNow());
    }

    public async Task<RsopRead> AppliedPoliciesAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        await WaitAsync("rsop", 400, 1100, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var computer = index.Computers.GetValueOrDefault(Norm(target.Dn)) ?? throw new DomeniaOperationException(AuditErrors.TargetUnknown, AuditErrors.TargetUnknownMessage);
        var name = computer.DnsHostName ?? computer.Name;
        var now = source.Clock.GetUtcNow();
        if (!Answers(computer))
        {
            return new RsopRead(name, ReadState.Unavailable, "Le poste ne répond pas : session CIM impossible (simulation).", null, null, null, now);
        }
        // Links of the chain, from the closest container up to the root, with the block of inheritance.
        var chain = AuditTargets.GpoContainerChain(computer.DistinguishedName, index.Root, AuditObjectKind.Computer);
        var byContainer = SimulatedAuditData.Links.ToDictionary(l => Norm(Under(l.Path)), StringComparer.Ordinal);
        var applied = new List<SimulatedAuditData.Gpo>();
        var blocked = false;
        foreach (var dn in chain)
        {
            if (!byContainer.TryGetValue(Norm(dn), out var links))
            {
                continue;
            }
            foreach (var (gpo, options) in links.Links)
            {
                var enabled = (options & 1) == 0;
                var enforced = (options & 2) != 0;
                if (enabled && (enforced || !blocked) && gpo.Flags is not 2 and not 3 && !applied.Contains(gpo))
                {
                    applied.Add(gpo);
                }
            }
            if ((links.GpOptions & 1) != 0)
            {
                blocked = true;
            }
        }
        var laptop = computer.Name.StartsWith("PT-", StringComparison.OrdinalIgnoreCase);
        var paris = computer.Name.Contains("-PAR-", StringComparison.OrdinalIgnoreCase);
        var gpos = ImmutableArray.CreateBuilder<RsopGpoRead>();
        var orders = ImmutableArray.CreateBuilder<RsopLinkRead>();
        gpos.Add(new RsopGpoRead(null, "Stratégie de groupe locale", false, true, true));
        var order = 1;
        if (paris && !blocked)
        {
            gpos.Add(new RsopGpoRead(SimulatedAuditData.SiteParis.Guid, SimulatedAuditData.SiteParis.Name, false, true, true));
            orders.Add(new RsopLinkRead(SimulatedAuditData.SiteParis.Guid, "CN=Paris,CN=Sites,CN=Configuration," + index.Root, order++));
        }
        foreach (var gpo in Enumerable.Reverse(applied))
        {
            var filtered = gpo == SimulatedAuditData.BitLocker && !laptop;
            gpos.Add(new RsopGpoRead(gpo.Guid, gpo.Name, false, !filtered, true));
            orders.Add(new RsopLinkRead(gpo.Guid, null, filtered ? 0 : order++));
        }
        return new RsopRead(name, ReadState.Read, null, gpos.ToImmutable(), orders.ToImmutable(), null, now);
    }

    /// <summary>The workstation answered the presence check of the generated observations (servers and controllers always answer).</summary>
    private bool Answers(DirectoryComputer computer)
    {
        if (IsController(computer) || IsServer(computer))
        {
            return true;
        }
        var observation = source.World.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid);
        return observation?.Presence.Answered == true && !AdValues.IsDisabled(computer.UserAccountControl);
    }

    // ================================================================ workstation identity

    public async Task<MachineIdentityRead> MachineIdentityAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        await WaitAsync("identity", 260, 700, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var computer = index.Computers.GetValueOrDefault(Norm(target.Dn)) ?? throw new DomeniaOperationException(AuditErrors.TargetUnknown, AuditErrors.TargetUnknownMessage);
        var now = source.Clock.GetUtcNow();
        var name = computer.DnsHostName ?? computer.Name;
        var address = AddressOf(computer);
        if (AdValues.IsDisabled(computer.UserAccountControl))
        {
            return new MachineIdentityRead(name, new DnsResolutionRead(ReadState.Unavailable, [], null, "Nom introuvable dans le DNS (enregistrement supprimé)."),
                new ReportedIdentityRead(ReadState.NotRead, null, null, null, "Poste non interrogé : aucune adresse."), now);
        }
        var resolution = new DnsResolutionRead(ReadState.Read, [address], name, null);
        if (!Answers(computer))
        {
            return new MachineIdentityRead(name, resolution, new ReportedIdentityRead(ReadState.Unavailable, null, null, null, "Le poste ne répond pas (CIM, délai de 20 s dépassé)."), now);
        }
        // A few workstations of the sub-stream answer under another name: the address was given to another workstation.
        var swapped = Swapped(index).GetValueOrDefault(computer.ObjectGuid);
        if (swapped is not null)
        {
            return new MachineIdentityRead(name, resolution with { PtrName = swapped.DnsHostName },
                new ReportedIdentityRead(ReadState.Read, swapped.Name, swapped.DnsHostName, index.Directory.Domain.DnsName, null), now);
        }
        return new MachineIdentityRead(name, resolution, new ReportedIdentityRead(ReadState.Read, computer.Name, name, index.Directory.Domain.DnsName, null), now);
    }

    private static string AddressOf(DirectoryComputer computer)
    {
        var parts = computer.Name.Split('-');
        var octet = parts.Length >= 3 ? SimulatedAuditData.SiteOctet(parts[1]) : IsController(computer) ? 10 : 60;
        var hash = SeededRandom.Fnv1a64("address/" + computer.ObjectGuid.ToString("D"));
        return string.Create(CultureInfo.InvariantCulture, $"10.{octet}.{1 + (int)(hash % 40)}.{10 + (int)((hash >> 8) % 240)}");
    }

    private Dictionary<Guid, DirectoryComputer> Swapped(Index index)
    {
        var answering = index.Directory.Computers.Where(c => !IsController(c) && !IsServer(c) && Answers(c)).OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        var random = Stream("identity/swapped");
        var picks = new List<DirectoryComputer>(answering);
        random.Shuffle(picks);
        var result = new Dictionary<Guid, DirectoryComputer>();
        for (var i = 0; i + 1 < picks.Count && result.Count < 2; i += 2)
        {
            result[picks[i].ObjectGuid] = picks[i + 1];
        }
        return result;
    }

    // ================================================================ relations and history

    /// <summary>Main user of each active workstation: its managedBy, else a person of the same site from the sub-stream.</summary>
    private Dictionary<Guid, DirectoryUser> MainUsers(Index index)
    {
        var random = Stream("relations/main");
        var people = index.Directory.Users.Where(u => Active(u) && u.DistinguishedName.Contains("OU=Utilisateurs", StringComparison.OrdinalIgnoreCase)).ToList();
        var bySite = people.GroupBy(u => u.Office ?? string.Empty, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);
        var result = new Dictionary<Guid, DirectoryUser>();
        foreach (var c in index.Directory.Computers.Where(c => !IsController(c) && !IsServer(c)).OrderBy(c => c.Name, StringComparer.Ordinal))
        {
            if (c.ManagedByDn is not null && index.Users.TryGetValue(Norm(c.ManagedByDn), out var owner))
            {
                result[c.ObjectGuid] = owner;
                continue;
            }
            var site = SimulationProfile.Sites.FirstOrDefault(s => c.Name.Contains("-" + s.Code + "-", StringComparison.OrdinalIgnoreCase))?.Name ?? string.Empty;
            var pool = bySite.GetValueOrDefault(site) ?? people;
            if (pool.Count > 0)
            {
                result[c.ObjectGuid] = pool[random.Next(pool.Count)];
            }
        }
        if (SessionWorkstation(index) is { } own && index.UsersBySam.TryGetValue(SimulationProfile.SessionLogin, out var sessionUser))
        {
            result[own.ObjectGuid] = sessionUser;
        }
        return result;
    }

    /// <summary>
    /// Workstation of the account of the session (Julien Martin in the default world), so that the examples of the screen and
    /// of the guides show its relations and its history: the first desktop of its site, by name, without managedBy, that
    /// answered the presence survey. Null when the account is unknown or disabled (writes of the session).
    /// </summary>
    private DirectoryComputer? SessionWorkstation(Index index)
    {
        if (!index.UsersBySam.TryGetValue(SimulationProfile.SessionLogin, out var user) || !Active(user))
        {
            return null;
        }
        var code = SimulationProfile.Sites.FirstOrDefault(s => string.Equals(s.Name, user.Office, StringComparison.Ordinal))?.Code;
        return index.Directory.Computers
            .Where(c => !IsController(c) && !IsServer(c) && c.ManagedByDn is null && !AdValues.IsDisabled(c.UserAccountControl) && Answers(c)
                && (code is null || c.Name.Contains("-" + code + "-", StringComparison.OrdinalIgnoreCase)))
            .OrderBy(c => c.Name, StringComparer.Ordinal)
            .FirstOrDefault();
    }

    private List<RelationHistoryRow> HistoryRows(Index index, DirectoryComputer computer, DirectoryUser user)
    {
        var random = Stream("history/" + computer.ObjectGuid.ToString("D"));
        var rows = new List<RelationHistoryRow>();
        var count = random.Next(3, 9);
        var other = index.Directory.Users.Where(Active).Skip(random.Next(0, 900)).FirstOrDefault() ?? user;
        for (var i = 0; i < count; i++)
        {
            var (src, kind) = SimulatedAuditData.HistorySources[random.Next(SimulatedAuditData.HistorySources.Length)];
            var who = i == count - 1 && random.Chance(30) ? other : user;
            var at = Reference - TimeSpan.FromDays(random.Next(0, 75)) - TimeSpan.FromMinutes(random.Next(0, 600));
            rows.Add(new RelationHistoryRow(who.SamAccountName, computer.Name, src, kind, kind == AuditRelationKind.Imported ? null : random.Chance(85),
                at, kind == AuditRelationKind.History ? "Ouverture de session interactive" : kind == AuditRelationKind.Imported ? "Ligne 214 du fichier d’inventaire" : null));
        }
        return rows;
    }

    public async Task<ImmutableArray<RelationRecord>> RelationsAsync(AuditTarget target, CancellationToken cancellationToken)
    {
        await WaitAsync("relations", 40, 120, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var main = MainUsers(index);
        var records = ImmutableArray.CreateBuilder<RelationRecord>();
        var pairs = new List<(DirectoryComputer Computer, DirectoryUser User)>();
        if (target.Kind == AuditObjectKind.Computer)
        {
            if (index.Computers.TryGetValue(Norm(target.Dn), out var c) && main.TryGetValue(c.ObjectGuid, out var u))
            {
                pairs.Add((c, u));
            }
        }
        else
        {
            pairs.AddRange(main.Where(p => p.Value.ObjectGuid == target.ObjectGuid).Select(p => (index.Directory.Computers.First(x => x.ObjectGuid == p.Key), p.Value)));
        }
        var own = SessionWorkstation(index);
        foreach (var (computer, user) in pairs)
        {
            if (own is not null && computer.ObjectGuid == own.ObjectGuid)
            {
                records.Add(new RelationRecord(AuditRelationKind.Declared, user.SamAccountName, user.ObjectGuid, computer.Name, computer.ObjectGuid, "Affectation saisie dans Domenia", Reference - TimeSpan.FromDays(41)));
            }
            if (computer.ManagedByDn is not null)
            {
                records.Add(new RelationRecord(AuditRelationKind.Clue, user.SamAccountName, user.ObjectGuid, computer.Name, computer.ObjectGuid, "Attribut managedBy de l’annuaire", computer.WhenChanged));
                if (SeededRandom.Fnv1a64("declared/" + computer.Name) % 2 == 0)
                {
                    records.Add(new RelationRecord(AuditRelationKind.Declared, user.SamAccountName, user.ObjectGuid, computer.Name, computer.ObjectGuid, "Affectation saisie dans Domenia", computer.WhenChanged + TimeSpan.FromDays(2)));
                }
            }
            if (Answers(computer) && source.World.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == computer.ObjectGuid)?.Presence.CheckedAt is DateTimeOffset seen)
            {
                records.Add(new RelationRecord(AuditRelationKind.Console, user.SamAccountName, user.ObjectGuid, computer.Name, computer.ObjectGuid, "Session console (relevé de présence)", seen));
            }
            foreach (var row in HistoryRows(index, computer, user).Where(r => r.Kind == AuditRelationKind.History && r.UserLogin == user.SamAccountName))
            {
                records.Add(new RelationRecord(AuditRelationKind.History, row.UserLogin, user.ObjectGuid, row.Computer, computer.ObjectGuid, row.Source, row.ObservedAt));
            }
        }
        return records.ToImmutable();
    }

    public async Task<RelationHistoryRead> RelationHistoryAsync(AuditTarget target, int limit, CancellationToken cancellationToken)
    {
        await WaitAsync("history", 80, 200, cancellationToken).ConfigureAwait(false);
        var index = Current();
        var main = MainUsers(index);
        var rows = new List<RelationHistoryRow>();
        if (target.Kind == AuditObjectKind.Computer && index.Computers.TryGetValue(Norm(target.Dn), out var computer) && main.TryGetValue(computer.ObjectGuid, out var user))
        {
            rows.AddRange(HistoryRows(index, computer, user));
        }
        else if (target.Kind == AuditObjectKind.User)
        {
            foreach (var (guid, owner) in main.Where(p => p.Value.ObjectGuid == target.ObjectGuid))
            {
                var c = index.Directory.Computers.First(x => x.ObjectGuid == guid);
                rows.AddRange(HistoryRows(index, c, owner).Where(r => string.Equals(r.UserLogin, target.SamAccountName, StringComparison.OrdinalIgnoreCase)));
            }
        }
        if (rows.Count == 0)
        {
            return new RelationHistoryRead(ReadState.Empty, null, 0, limit, []);
        }
        var ordered = rows.OrderByDescending(r => r.ObservedAt).ToList();
        return new RelationHistoryRead(ReadState.Read, null, ordered.Count, limit, [.. ordered.Take(limit)]);
    }

    // ================================================================ identities of an OU

    public async Task<IdentityScanRead> IdentityScanAsync(string baseDn, bool subtree, int limit, CancellationToken cancellationToken)
    {
        await WaitAsync("scan", 500, 1200, cancellationToken).ConfigureAwait(false);
        var index = Current();
        if (Norm(baseDn) != Norm(index.Root) && !index.Ous.ContainsKey(Norm(baseDn)))
        {
            throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
        }
        bool InScope(string dn)
        {
            try
            {
                return DistinguishedName.IsWithin(dn, baseDn, subtree);
            }
            catch (FormatException)
            {
                return false;
            }
        }
        var objects = index.Directory.Users.Where(u => InScope(u.DistinguishedName))
            .Select(u => new IdentityScanObject(u.ObjectGuid, u.DistinguishedName, u.DisplayName ?? u.Cn, AuditObjectKind.User, u.SamAccountName, u.UserPrincipalName, u.Mail, u.EmployeeId, null, u.UserAccountControl))
            .Concat(index.Directory.Computers.Where(c => InScope(c.DistinguishedName))
                .Select(c => new IdentityScanObject(c.ObjectGuid, c.DistinguishedName, c.Name, AuditObjectKind.Computer, c.SamAccountName, null, null, null, c.DnsHostName, c.UserAccountControl)))
            .ToList();
        var truncated = objects.Count > limit;
        return new IdentityScanRead(baseDn, subtree, limit, [.. objects.Take(limit)], truncated, Dc01, source.Clock.GetUtcNow());
    }

    public async Task<LocalNamesRead> LocalNamesAsync(IdentityScanRead scan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scan);
        await WaitAsync("local-names", 60, 160, cancellationToken).ConfigureAwait(false);
        var users = scan.Objects.Where(o => o.Kind == AuditObjectKind.User && !string.IsNullOrEmpty(o.SamAccountName)).OrderBy(o => o.SamAccountName, StringComparer.Ordinal).ToList();
        var computers = scan.Objects.Where(o => o.Kind == AuditObjectKind.Computer).OrderBy(o => o.Name, StringComparer.Ordinal).ToList();
        var total = users.Count + computers.Count;
        var comparedUsers = users.Take(1000).ToList();
        var comparedComputers = computers.Take(1000).ToList();
        // The fictitious local copy knows every name with its own GUID, except a few recreated objects of the sub-stream.
        var random = Stream("identities/" + Norm(scan.BaseDn));
        var recreated = new HashSet<Guid>();
        var computerPicks = new List<IdentityScanObject>(comparedComputers);
        random.Shuffle(computerPicks);
        foreach (var c in computerPicks.Take(Math.Min(2, computerPicks.Count / 40 + (computerPicks.Count > 0 ? 1 : 0))))
        {
            recreated.Add(c.ObjectGuid);
        }
        var userPicks = new List<IdentityScanObject>(comparedUsers);
        random.Shuffle(userPicks);
        foreach (var u in userPicks.Take(userPicks.Count >= 30 ? 1 : 0))
        {
            recreated.Add(u.ObjectGuid);
        }
        Guid LocalGuid(IdentityScanObject o) => recreated.Contains(o.ObjectGuid) ? SimulatedAuditData.GuidOf("recreated/" + o.ObjectGuid.ToString("D")) : o.ObjectGuid;
        return new LocalNamesRead(ReadState.Read, null,
            [.. comparedComputers.Select(c => new LocalNameRead(LocalGuid(c), c.Name))],
            [.. comparedUsers.Select(u => new LocalNameRead(LocalGuid(u), u.SamAccountName!))],
            comparedUsers.Count + comparedComputers.Count, total, true);
    }
}
