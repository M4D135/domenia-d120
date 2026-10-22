using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core.Queries;

/// <summary>Instances of one probe collection on one object; <see cref="Complete"/> is false when some may be missing.</summary>
public sealed record QueryCollection(ImmutableArray<ProbeInstance> Instances, bool Complete);

/// <summary>Last console user reading (its own clock: a ping never renews it).</summary>
public sealed record ConsoleReading(string? User, DateTimeOffset? ObservedAt, string? Error);

/// <summary>Stored result of an advanced WMI SELECT on one workstation (counts only: the rows stay in the fiche).</summary>
public sealed record StoredWmiResult(string RequestKey, DateTimeOffset? At, bool Success, long StoredCount, bool CountComplete, bool Truncated);

/// <summary>
/// Everything a query reads, already stored: directory copy, workstation readings (presence, inventory, console, probes),
/// BitLocker keys visible in AD and stored WMI SELECT results. <see cref="Version"/> changes with any of them, so an
/// evaluation knows when its data is no longer the current one. The local base fills it in directory mode, the
/// fictitious directory in simulation.
/// </summary>
public sealed record QueryDataset(
    DirectorySnapshot Directory,
    FleetObservations Observations,
    ImmutableDictionary<Guid, ImmutableArray<ProbeReading>> Probes,
    ImmutableDictionary<Guid, ConsoleReading> Console,
    ImmutableDictionary<Guid, char> BitLocker,
    ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>> Details,
    long Version,
    string SourceLabel,
    bool Simulated);

/// <summary>
/// One object as the engine evaluates it: typed values by information, quality of the missing ones (« Expiré », « Erreur de
/// lecture »…), date of each clock, probe collections and the LDAP view of the object.
/// </summary>
public sealed class QueryRecord
{
    public QueryRecord(string id, QueryTarget target, string name, string dn, ILdapEntry entry)
    {
        Id = id;
        Target = target;
        Name = name;
        Dn = dn;
        Entry = entry;
    }

    /// <summary>GUID in lower-case « D » form.</summary>
    public string Id { get; }

    public QueryTarget Target { get; }

    public string Name { get; }

    public string Dn { get; }

    public ILdapEntry Entry { get; }

    public Dictionary<string, object> Values { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, string> Quality { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, DateTimeOffset> Clocks { get; } = new(StringComparer.Ordinal);

    public Dictionary<string, QueryCollection> Collections { get; } = new(StringComparer.Ordinal);

    /// <summary>True for an enabled account, false when disabled, null when the state is unknown.</summary>
    public bool? Active => Values.TryGetValue("active", out var active) && active is bool b ? b : null;

    public object? Value(string field) => Values.GetValueOrDefault(field);

    /// <summary>« Disponible », « Disponible · Expiré », the quality label, or « Non lu ».</summary>
    public string State(string field)
    {
        var known = Values.ContainsKey(field);
        var quality = Quality.GetValueOrDefault(field);
        if (known)
        {
            return quality is null ? "Disponible" : "Disponible · " + quality;
        }
        return quality ?? "Non lu";
    }
}

/// <summary>Options of the record builder: readings older than <see cref="MaxAgeDays"/> are expired (Domenia 1: 30 days).</summary>
public sealed record QueryRecordOptions(int MaxAgeDays = 30)
{
    public static QueryRecordOptions Default { get; } = new();
}

/// <summary>
/// Builds the records of one target inside a scope (Domenia 1 ConvertTo-DomeniaQueryRecords, extended to users and groups).
/// Pure: the same dataset, scope, instant and zone give the same records. Every channel keeps its own date: a fresh ping
/// never makes an older inventory or probe fresh; an expired, failed or undated reading gives no value, never zero.
/// </summary>
public static class QueryRecordBuilder
{
    public static ImmutableArray<QueryRecord> Build(QueryDataset dataset, QueryTarget target, ScopeSelection? scope, DateTimeOffset now, QueryRecordOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(dataset);
        options ??= QueryRecordOptions.Default;
        var directory = dataset.Directory;
        bool InScope(string dn) => scope is null || ScopeRules.Contains(scope, dn) || ScopeRules.IsDomainRoot(scope, directory.Domain.RootDn);
        return target switch
        {
            QueryTarget.User => [.. directory.Users.Where(u => InScope(u.DistinguishedName)).Select(u => User(u, dataset, now))],
            QueryTarget.Group => [.. directory.Groups.Where(g => InScope(g.DistinguishedName)).Select(g => Group(g, dataset, now))],
            _ => BuildComputers(dataset, directory.Computers.Where(c => InScope(c.DistinguishedName)), now, options),
        };
    }

    /// <summary>Record of one computer, whatever the scope (tests on one workstation, object detail).</summary>
    public static QueryRecord? Computer(QueryDataset dataset, Guid id, DateTimeOffset now, QueryRecordOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(dataset);
        var computer = dataset.Directory.Computers.FirstOrDefault(c => c.ObjectGuid == id);
        return computer is null ? null : BuildComputers(dataset, [computer], now, options ?? QueryRecordOptions.Default)[0];
    }

    private static ImmutableArray<QueryRecord> BuildComputers(QueryDataset dataset, IEnumerable<DirectoryComputer> computers, DateTimeOffset now, QueryRecordOptions options)
    {
        var observations = dataset.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        return [.. computers.Select(c => Computer(c, dataset, observations.GetValueOrDefault(c.ObjectGuid), now, options))];
    }

    private static decimal Days(DateTimeOffset now, DateTimeOffset at) => Math.Max(0m, Math.Round((decimal)(now - at).TotalDays, 4));

    private static void Common(QueryRecord record, QueryDataset dataset, string dn, string? description, string? site)
    {
        record.Values["name"] = record.Name;
        record.Values["dn"] = dn;
        if (!string.IsNullOrWhiteSpace(description))
        {
            record.Values["description"] = description;
        }
        if (site is not null)
        {
            record.Values["site"] = site;
        }
        record.Clocks["ad"] = dataset.Directory.ReadAt;
    }

    private static string? Site(string dn)
    {
        if (DistinguishedName.Parent(dn) is not string parent)
        {
            return null;
        }
        try
        {
            var names = DistinguishedName.Parse(parent);
            return names.Length > 0 && !string.Equals(names[0].Type, "DC", StringComparison.OrdinalIgnoreCase) ? names[0].Value : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static void Activity(QueryRecord record, long? lastLogon, DateTimeOffset created, long? passwordLastSet, DateTimeOffset now)
    {
        if (AdValues.FromFileTime(lastLogon) is DateTimeOffset logon && logon <= now.AddMinutes(5))
        {
            var days = Days(now, logon);
            record.Values["logonDays"] = days;
            record.Values["logonBucket"] = days switch
            {
                < 7m => 0m,
                < 30m => 1m,
                < 90m => 2m,
                < 180m => 3m,
                _ => 4m,
            };
        }
        else
        {
            record.Values["logonBucket"] = 5m;
        }
        record.Values["createdRecent"] = created >= now.AddDays(-30);
        record.Values["createdDays"] = Days(now, created);
        if (AdValues.FromFileTime(passwordLastSet) is DateTimeOffset set && set <= now.AddMinutes(5))
        {
            record.Values["passwordAgeDays"] = Days(now, set);
        }
    }

    private static QueryRecord Computer(DirectoryComputer computer, QueryDataset dataset, WorkstationObservation? observation, DateTimeOffset now, QueryRecordOptions options)
    {
        var record = new QueryRecord(computer.ObjectGuid.ToString("D"), QueryTarget.Computer, computer.Name, computer.DistinguishedName, DirectoryLdapEntry.From(computer, dataset.Directory.Domain));
        var v = record.Values;
        Common(record, dataset, computer.DistinguishedName, computer.Description, Site(computer.DistinguishedName));
        v["sam"] = computer.SamAccountName;
        Put(v, "dnsHostName", computer.DnsHostName);
        Put(v, "location", computer.Location);
        Put(v, "managedBy", computer.ManagedByDn);
        if (!computer.MemberOf.IsDefaultOrEmpty)
        {
            v["memberOf"] = string.Join(" ; ", computer.MemberOf);
        }
        v["active"] = !AdValues.IsDisabled(computer.UserAccountControl);
        var os = computer.OperatingSystem?.Trim();
        Put(v, "os", os);
        Put(v, "version", computer.OperatingSystemVersion);
        var label = string.IsNullOrEmpty(os) ? "Système non renseigné" : os.Replace("Microsoft ", "", StringComparison.Ordinal).Replace("Professionnel", "Pro", StringComparison.Ordinal).Replace("Professional", "Pro", StringComparison.Ordinal);
        v["osLabel"] = label;
        var release = WindowsRelease.Describe(os, computer.OperatingSystemVersion);
        var build = WindowsRelease.ParseBuild(computer.OperatingSystemVersion);
        v["release"] = build is null ? "Version non lue" : release?.Label ?? label + " (build " + build.Value.ToString(CultureInfo.InvariantCulture) + ")";
        v["osFamily"] = string.IsNullOrEmpty(os) ? "Système non renseigné" : release?.IsServer == true ? "Serveurs" : "Postes de travail";
        v["lifeStatus"] = WindowsLifecycle.Status(os, computer.OperatingSystemVersion, now);
        v["win10"] = os is not null && os.Contains("Windows 10", StringComparison.OrdinalIgnoreCase)
            && !os.Contains("LTSC", StringComparison.OrdinalIgnoreCase) && !os.Contains("LTSB", StringComparison.OrdinalIgnoreCase) && !os.Contains("IoT", StringComparison.OrdinalIgnoreCase);
        Activity(record, computer.LastLogonTimestamp, computer.WhenCreated, computer.PasswordLastSet, now);
        if (v.TryGetValue("passwordAgeDays", out var age) && age is decimal days)
        {
            v["passwordOld"] = days > 60m;
        }
        v["laps"] = computer.Laps switch
        {
            LapsKind.None => "N",
            _ when AdValues.FromFileTime(computer.LapsExpiration) is null => "N",
            _ when AdValues.FromFileTime(computer.LapsExpiration) <= now => "E",
            _ => "O",
        };
        if (dataset.BitLocker.TryGetValue(computer.ObjectGuid, out var key))
        {
            v["bitlocker"] = key.ToString();
        }
        Presence(record, observation?.Presence, now, options);
        Console(record, dataset.Console.GetValueOrDefault(computer.ObjectGuid), now, options);
        Inventory(record, observation?.Inventory, now, options);
        if (dataset.Probes.TryGetValue(computer.ObjectGuid, out var readings))
        {
            foreach (var reading in readings)
            {
                Probe(record, reading, now, options);
            }
        }
        if (dataset.Details.TryGetValue(computer.ObjectGuid, out var details))
        {
            foreach (var detail in details)
            {
                Detail(record, detail, now, options);
            }
        }
        return record;
    }

    private static void Put(Dictionary<string, object> values, string key, string? value)
    {
        if (!string.IsNullOrWhiteSpace(value))
        {
            values[key] = value;
        }
    }

    private static void Presence(QueryRecord record, PresenceMeasure? presence, DateTimeOffset now, QueryRecordOptions options)
    {
        var v = record.Values;
        v["presenceBucket"] = "Non vérifié";
        if (presence is null || presence.State == MeasureState.NotRead)
        {
            return;
        }
        if (presence.CheckedAt is DateTimeOffset at)
        {
            record.Clocks["presence"] = at;
        }
        switch (presence.State)
        {
            case MeasureState.Error:
                record.Quality["presence"] = "Erreur de lecture";
                record.Quality["checkedDays"] = "Erreur de lecture";
                return;
            case MeasureState.Refused:
                record.Quality["presence"] = "Accès refusé";
                record.Quality["checkedDays"] = "Accès refusé";
                return;
            case MeasureState.Incomplete:
                record.Quality["presence"] = "Lecture incomplète";
                return;
        }
        if (presence.CheckedAt is not DateTimeOffset checkedAt || checkedAt > now.AddMinutes(5))
        {
            record.Quality["presence"] = "Date de relevé inconnue";
            return;
        }
        if ((now - checkedAt).TotalDays > options.MaxAgeDays || presence.State == MeasureState.Expired)
        {
            record.Quality["presence"] = "Expiré";
            record.Quality["checkedDays"] = "Expiré";
            return;
        }
        if (presence.Answered is not bool answered)
        {
            return;
        }
        v["checkedDays"] = Days(now, checkedAt);
        v["presence"] = answered ? "En ligne" : "Sans réponse";
        v["presenceBucket"] = answered ? "En ligne" : "Sans réponse";
    }

    private static void Console(QueryRecord record, ConsoleReading? reading, DateTimeOffset now, QueryRecordOptions options)
    {
        if (reading is null)
        {
            return;
        }
        if (reading.ObservedAt is DateTimeOffset at)
        {
            record.Clocks["console"] = at;
        }
        if (reading.Error is not null)
        {
            record.Quality["user"] = "Erreur de lecture";
            return;
        }
        if (reading.ObservedAt is not DateTimeOffset observed || observed > now.AddMinutes(5))
        {
            record.Quality["user"] = "Date de relevé inconnue";
            return;
        }
        if ((now - observed).TotalDays > options.MaxAgeDays)
        {
            record.Quality["user"] = "Expiré";
            return;
        }
        Put(record.Values, "user", reading.User);
    }

    private static readonly string[] InventoryFields = ["inventoryDays", "model", "observedRelease", "ramGB", "diskFreePercent", "uptimeDays"];

    private static void Inventory(QueryRecord record, InventoryMeasure? inventory, DateTimeOffset now, QueryRecordOptions options)
    {
        if (inventory is null || inventory.State == MeasureState.NotRead)
        {
            return;
        }
        if (inventory.CheckedAt is DateTimeOffset at)
        {
            record.Clocks["inventory"] = at;
        }
        var state = inventory.State switch
        {
            MeasureState.Error => "Erreur au dernier relevé",
            MeasureState.Refused => "Accès refusé",
            MeasureState.Incomplete => "Lecture incomplète",
            MeasureState.Expired => "Expiré",
            _ when inventory.CheckedAt is DateTimeOffset c && (now - c).TotalDays > options.MaxAgeDays => "Expiré",
            _ => null,
        };
        if (state is not null)
        {
            foreach (var field in InventoryFields)
            {
                record.Quality[field] = state;
            }
            return;
        }
        if (!inventory.HasReading || inventory.CheckedAt is not DateTimeOffset checkedAt || checkedAt > now.AddMinutes(5) || (now - checkedAt).TotalDays > options.MaxAgeDays)
        {
            return;
        }
        var v = record.Values;
        v["inventoryDays"] = Days(now, checkedAt);
        Put(v, "model", inventory.Model);
        if (inventory.Build is string build && build.Length > 0)
        {
            var caption = inventory.OsCaption ?? "";
            v["observedRelease"] = WindowsRelease.Describe(caption.Length > 0 ? caption : "Windows", "10.0 (" + build + ")")?.Label ?? "Build " + build;
        }
        if (inventory.MemoryBytes is long ram && ram > 0)
        {
            v["ramGB"] = Math.Round(ram / (1024m * 1024m * 1024m), 2);
        }
        if (inventory.SystemDiskSizeBytes is long size && size > 0 && inventory.SystemDiskFreeBytes is long free && free >= 0 && free <= size)
        {
            v["diskFreePercent"] = Math.Round(100m * free / size, 2);
        }
        if (inventory.LastBootAt is DateTimeOffset boot && boot <= now)
        {
            v["uptimeDays"] = Days(now, boot);
        }
    }

    private static void Probe(QueryRecord record, ProbeReading reading, DateTimeOffset now, QueryRecordOptions options)
    {
        if (QueryProbeCatalog.Find(reading.ProbeId) is not { } probe)
        {
            return;
        }
        var field = QueryCatalog.ProbePrefix + probe.Id;
        if (reading.CheckedAt is DateTimeOffset at)
        {
            record.Clocks["probe:" + probe.Id] = at;
        }
        if (reading.Error is not null)
        {
            record.Quality[field] = "Erreur de lecture";
            return;
        }
        if (reading.Skipped)
        {
            record.Quality[field] = "Non applicable / ignoré";
            return;
        }
        if (reading.CheckedAt is not DateTimeOffset checkedAt || checkedAt > now.AddMinutes(5))
        {
            record.Quality[field] = "Date de relevé inconnue";
            return;
        }
        if ((now - checkedAt).TotalDays > options.MaxAgeDays)
        {
            record.Quality[field] = "Expiré";
            return;
        }
        if (reading.Instances.Length > QueryLimits.MaxInstances)
        {
            record.Quality[field] = "Lecture incomplète";
            return;
        }
        var complete = reading.Count is long count && count == reading.Instances.Length && !reading.Truncated && probe.Mode != "First";
        record.Collections[probe.Id] = new QueryCollection(reading.Instances, complete);
        if (reading.Truncated && probe.Mode != "Count")
        {
            record.Quality[field] = "Lecture incomplète";
            return;
        }
        if (probe.Mode == "Count" && !reading.CountComplete)
        {
            record.Quality[field] = "Lecture incomplète";
            return;
        }
        if (probe.Mode == "Count" && reading.Count is null)
        {
            record.Quality[field] = "Non lu";
            return;
        }
        var values = QueryProbeCatalog.Values(probe, reading, now);
        if (values.Count == 0)
        {
            return;
        }
        if (probe.Numeric)
        {
            if (values[0] is decimal number)
            {
                record.Values[field] = number;
            }
            else if (QueryProbeCatalog.Number(QueryProbeCatalog.Invariant(values[0])) is decimal parsed)
            {
                record.Values[field] = parsed;
            }
        }
        else
        {
            record.Values[field] = string.Join(" ; ", values.Select(QueryProbeCatalog.Invariant));
        }
    }

    private static void Detail(QueryRecord record, StoredWmiResult detail, DateTimeOffset now, QueryRecordOptions options)
    {
        var prefix = QueryCatalog.DetailPrefix + detail.RequestKey + ":";
        string? quality = !detail.Success ? "Erreur de lecture"
            : detail.At is not DateTimeOffset at || at > now.AddMinutes(5) ? "Date de relevé inconnue"
            : (now - at).TotalDays > options.MaxAgeDays ? "Expiré"
            : null;
        if (quality is not null)
        {
            record.Quality[prefix + "exists"] = quality;
            record.Quality[prefix + "count"] = quality;
            return;
        }
        record.Clocks["detail:" + detail.RequestKey] = detail.At!.Value;
        if (detail.StoredCount > 0)
        {
            record.Values[prefix + "exists"] = true;
        }
        else if (detail.CountComplete)
        {
            record.Values[prefix + "exists"] = false;
        }
        if (detail.CountComplete && !detail.Truncated)
        {
            record.Values[prefix + "count"] = (decimal)detail.StoredCount;
        }
        else
        {
            record.Quality[prefix + "count"] = "Lecture incomplète";
        }
    }

    private static QueryRecord User(DirectoryUser user, QueryDataset dataset, DateTimeOffset now)
    {
        var record = new QueryRecord(user.ObjectGuid.ToString("D"), QueryTarget.User, user.Cn, user.DistinguishedName, DirectoryLdapEntry.From(user, dataset.Directory.Domain));
        var v = record.Values;
        Common(record, dataset, user.DistinguishedName, user.Description, Site(user.DistinguishedName));
        Put(v, "displayName", user.DisplayName);
        v["sam"] = user.SamAccountName;
        Put(v, "upn", user.UserPrincipalName);
        Put(v, "mail", user.Mail);
        Put(v, "title", user.Title);
        Put(v, "department", user.Department);
        Put(v, "office", user.Office);
        Put(v, "telephone", user.TelephoneNumber);
        Put(v, "manager", user.ManagerDn);
        Put(v, "employeeId", user.EmployeeId);
        if (!user.MemberOf.IsDefaultOrEmpty)
        {
            v["memberOf"] = string.Join(" ; ", user.MemberOf);
        }
        v["active"] = !AdValues.IsDisabled(user.UserAccountControl);
        v["adminCount"] = user.AdminCount == 1;
        if (user.BadPasswordCount is int bad)
        {
            v["badPwdCount"] = (decimal)bad;
        }
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        v["lockState"] = state.Lock switch
        {
            LockState.Locked => "Verrouillé",
            LockState.ToCheck => "À vérifier",
            _ => "Déverrouillé",
        };
        var policy = dataset.Directory.Domain.PasswordPolicy;
        v["passwordState"] = AccountState.ClassifyPassword(user, policy.MaxPasswordAge, now, TimeSpan.FromDays(7)) switch
        {
            PasswordClass.MustChange => "À changer",
            PasswordClass.NeverExpires => "N’expire jamais",
            PasswordClass.Expired => "Expiré",
            PasswordClass.Expiring => "Expire bientôt",
            _ => "Valide",
        };
        v["passwordNeverExpires"] = state.PasswordNeverExpires;
        v["passwordNotRequired"] = state.PasswordNotRequired;
        Activity(record, user.LastLogonTimestamp, user.WhenCreated, user.PasswordLastSet, now);
        if (!state.PasswordNeverExpires && user.PasswordExpiryComputed != AdValues.Never)
        {
            var expiry = AdValues.FromFileTime(user.PasswordExpiryComputed);
            if (expiry is null && user.PasswordExpiryComputed is null && AdValues.FromFileTime(user.PasswordLastSet) is DateTimeOffset set)
            {
                expiry = set + policy.MaxPasswordAge;
            }
            if (expiry is DateTimeOffset date)
            {
                v["passwordExpiresInDays"] = Math.Round((decimal)(date - now).TotalDays, 4);
            }
        }
        if (user.AccountExpires is long expires && expires != 0 && expires != AdValues.Never && AdValues.FromFileTime(expires) is DateTimeOffset end)
        {
            v["accountExpiresDays"] = Math.Round((decimal)(end - now).TotalDays, 4);
        }
        v["privileged"] = Privileged(dataset.Directory, record.Entry);
        return record;
    }

    private static bool Privileged(DirectorySnapshot directory, ILdapEntry entry)
    {
        var chain = PrivilegedChain(directory);
        var memberOf = LdapSchema.Find("memberOf")!;
        foreach (var group in chain.Groups)
        {
            if (chain.Links.Reaches(entry, memberOf, group))
            {
                return true;
            }
        }
        return false;
    }

    private static readonly SnapshotCache<DirectorySnapshot, (ImmutableArray<string> Groups, DirectoryLdapChain Links)> PrivilegedCache = new();

    private static (ImmutableArray<string> Groups, DirectoryLdapChain Links) PrivilegedChain(DirectorySnapshot directory) =>
        PrivilegedCache.GetValue(directory, static d => (
            [.. d.Groups.Where(g => g.Sid.EndsWith("-512", StringComparison.Ordinal) || g.Sid.EndsWith("-518", StringComparison.Ordinal) || g.Sid.EndsWith("-519", StringComparison.Ordinal) || g.Sid == "S-1-5-32-544").Select(g => g.DistinguishedName)],
            new DirectoryLdapChain(d)));

    private static QueryRecord Group(DirectoryGroup group, QueryDataset dataset, DateTimeOffset now)
    {
        var record = new QueryRecord(group.ObjectGuid.ToString("D"), QueryTarget.Group, group.Name, group.DistinguishedName, DirectoryLdapEntry.From(group, dataset.Directory.Domain));
        var v = record.Values;
        Common(record, dataset, group.DistinguishedName, group.Description, Site(group.DistinguishedName));
        v["sam"] = group.SamAccountName;
        Put(v, "mail", group.Mail);
        Put(v, "managedBy", group.ManagedByDn);
        v["adminCount"] = group.AdminCount == 1;
        if (!group.MemberOf.IsDefaultOrEmpty)
        {
            v["memberOf"] = string.Join(" ; ", group.MemberOf);
        }
        var type = group.GroupType;
        v["scope"] = (type & 0x1) != 0 ? "Local intégré" : (type & 0x2) != 0 ? "Global" : (type & 0x4) != 0 ? "Domaine local" : (type & 0x8) != 0 ? "Universel" : "Global";
        v["groupKind"] = (type & unchecked((int)0x80000000)) != 0 ? "Sécurité" : "Distribution";
        v["members"] = (decimal)group.Members.Length;
        var primary = group.Sid.EndsWith("-513", StringComparison.Ordinal) || group.Sid.EndsWith("-514", StringComparison.Ordinal)
            || group.Sid.EndsWith("-515", StringComparison.Ordinal) || group.Sid.EndsWith("-516", StringComparison.Ordinal);
        v["empty"] = group.Members.Length == 0 && !primary;
        v["builtin"] = group.Sid.StartsWith("S-1-5-32-", StringComparison.Ordinal) || group.DistinguishedName.Contains("CN=Builtin,", StringComparison.OrdinalIgnoreCase);
        v["createdRecent"] = group.WhenCreated >= now.AddDays(-30);
        v["createdDays"] = Days(now, group.WhenCreated);
        return record;
    }
}

/// <summary>Weak cache keyed by the snapshot instance (derived data computed once per directory read).</summary>
internal sealed class SnapshotCache<TKey, TValue> where TKey : class
{
    private readonly System.Runtime.CompilerServices.ConditionalWeakTable<TKey, Box> table = new();

    public TValue GetValue(TKey key, Func<TKey, TValue> factory) => table.GetValue(key, k => new Box(factory(k))).Value;

    private sealed class Box(TValue value)
    {
        public TValue Value { get; } = value;
    }
}

/// <summary>
/// End of support of Windows releases (delivered reference, dates from the Microsoft lifecycle): « Ended » when passed,
/// « Soon » within 90 days, « Ok » beyond, « Unknown » when the release or edition is not recognised.
/// </summary>
public static class WindowsLifecycle
{
    private static readonly (string Release, bool Enterprise, DateOnly End)[] Table =
    [
        ("Windows 10 22H2", false, new DateOnly(2025, 10, 14)),
        ("Windows 10 22H2", true, new DateOnly(2025, 10, 14)),
        ("Windows 10 21H2", true, new DateOnly(2024, 6, 11)),
        ("Windows 10 LTSC 2021", true, new DateOnly(2027, 1, 12)),
        ("Windows 10 LTSC 2019", true, new DateOnly(2029, 1, 9)),
        ("Windows 10 LTSB 2016", true, new DateOnly(2026, 10, 13)),
        ("Windows 11 23H2", false, new DateOnly(2025, 11, 11)),
        ("Windows 11 23H2", true, new DateOnly(2026, 11, 10)),
        ("Windows 11 24H2", false, new DateOnly(2026, 10, 13)),
        ("Windows 11 24H2", true, new DateOnly(2027, 10, 12)),
        ("Windows 11 25H2", false, new DateOnly(2027, 10, 12)),
        ("Windows 11 25H2", true, new DateOnly(2028, 10, 10)),
        ("Windows 11 LTSC 2024", true, new DateOnly(2034, 10, 10)),
        ("Windows Server 2016", true, new DateOnly(2027, 1, 12)),
        ("Windows Server 2019", true, new DateOnly(2029, 1, 9)),
        ("Windows Server 2022", true, new DateOnly(2031, 10, 14)),
        ("Windows Server 2025", true, new DateOnly(2034, 10, 10)),
    ];

    public static string Status(string? operatingSystem, string? version, DateTimeOffset now)
    {
        var release = WindowsRelease.Describe(operatingSystem, version);
        if (release is null || WindowsRelease.ParseBuild(version) is null)
        {
            return "Unknown";
        }
        var enterprise = release.IsServer || (operatingSystem ?? "").Contains("Entreprise", StringComparison.OrdinalIgnoreCase)
            || (operatingSystem ?? "").Contains("Enterprise", StringComparison.OrdinalIgnoreCase) || (operatingSystem ?? "").Contains("Education", StringComparison.OrdinalIgnoreCase)
            || (operatingSystem ?? "").Contains("Éducation", StringComparison.OrdinalIgnoreCase) || (operatingSystem ?? "").Contains("LTSC", StringComparison.OrdinalIgnoreCase);
        foreach (var row in Table)
        {
            if (string.Equals(row.Release, release.Label, StringComparison.Ordinal) && row.Enterprise == enterprise)
            {
                var end = new DateTimeOffset(row.End.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero);
                return end <= now ? "Ended" : end <= now.AddDays(90) ? "Soon" : "Ok";
            }
        }
        return "Unknown";
    }
}
