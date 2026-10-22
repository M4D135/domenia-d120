using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// What the « Fiche » screen remembers during one session, in memory only (Domenia 1 Get-DomeniaCallSheetSheetState): the
/// memberOf of the first fiche of each object (changes seen since), and the explicit reads started from a call sheet (4740,
/// policy, presence, sessions, triage), so that the sheet keeps them while the operator moves between tabs. Nothing is written
/// on disk; a new session starts empty. Thread safe.
/// </summary>
public sealed class FicheSession
{
    private readonly Lock gate = new();
    private readonly Dictionary<Guid, FicheGroupBaseline> baselines = new();
    private readonly Dictionary<Guid, (FicheLockoutDiagnosis Diagnosis, DateTimeOffset At)> lockouts = new();
    private readonly Dictionary<Guid, (FichePolicyView View, FichePolicyReading Reading)> policies = new();
    // Readings of a workstation are kept under its objectGUID (Domenia 1, FIC-046): a workstation recreated or renamed under the
    // same DN never inherits the ping, the sessions or the inventory of the previous one during the session.
    private readonly Dictionary<Guid, FichePresenceReading> pings = new();
    private readonly Dictionary<Guid, FicheSessionsReading> sessions = new();
    private readonly Dictionary<Guid, FicheInventoryReading> inventories = new();
    private readonly Dictionary<Guid, string> triageTargets = new();
    private readonly Dictionary<string, FicheRead> reads = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<(string Subject, string Nature), DateTimeOffset> attempts = new();
    private readonly Dictionary<Guid, DateTimeOffset> histories = new();

    /// <summary>The session state of the context (one per engine context, like DashboardService).</summary>
    public static FicheSession From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static _ => new FicheSession());
    }

    /// <summary>
    /// Records the memberOf of a fiche read from the directory: the first one of the session becomes the reference; later ones
    /// add the groups added or removed since. Returns the reference (null before the first fiche).
    /// </summary>
    public FicheGroupBaseline? Observe(FicheEntry entry, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Kind is not (FicheKind.User or FicheKind.Computer or FicheKind.Group or FicheKind.Contact))
        {
            return null;
        }
        var groups = entry.All("memberOf");
        lock (gate)
        {
            if (!baselines.TryGetValue(entry.ObjectGuid, out var baseline))
            {
                baselines[entry.ObjectGuid] = new FicheGroupBaseline(at, groups, []);
                return null;
            }
            var reference = new HashSet<string>(baseline.Groups, StringComparer.OrdinalIgnoreCase);
            var current = new HashSet<string>(groups, StringComparer.OrdinalIgnoreCase);
            var known = baseline.Changes.ToDictionary(c => (c.Dn.ToUpperInvariant(), c.Removed), c => c);
            var changes = new List<FicheGroupChange>();
            foreach (var dn in groups.Where(g => !reference.Contains(g)))
            {
                changes.Add(known.TryGetValue((dn.ToUpperInvariant(), false), out var seen) ? seen : new FicheGroupChange(dn, FicheValues.DisplayName(dn), false, at));
            }
            foreach (var dn in baseline.Groups.Where(g => !current.Contains(g)))
            {
                changes.Add(known.TryGetValue((dn.ToUpperInvariant(), true), out var seen) ? seen : new FicheGroupChange(dn, FicheValues.DisplayName(dn), true, at));
            }
            var updated = baseline with { Changes = [.. changes] };
            baselines[entry.ObjectGuid] = updated;
            return updated;
        }
    }

    /// <summary>
    /// Keeps the last directory read of a fiche (the call sheet is built from it without reading again). When the object changed
    /// since its previous read (another uSNChanged, or another DN after a move), only the reads kept under its GUID are forgotten
    /// (FIC-037, targeted invalidation): its previous DN, its lockouts and its policy. Other objects keep theirs.
    /// </summary>
    public void KeepRead(FicheRead read)
    {
        ArgumentNullException.ThrowIfNull(read);
        lock (gate)
        {
            var guid = read.Entry.ObjectGuid;
            foreach (var stale in reads.Where(r => r.Value.Entry.ObjectGuid == guid
                && (!string.Equals(r.Value.Entry.First("uSNChanged"), read.Entry.First("uSNChanged"), StringComparison.Ordinal) || !string.Equals(r.Key, read.Entry.Dn, StringComparison.OrdinalIgnoreCase))).ToList())
            {
                reads.Remove(stale.Key);
                lockouts.Remove(guid);
                policies.Remove(guid);
            }
            reads[read.Entry.Dn] = read;
            while (reads.Count > 64)
            {
                reads.Remove(reads.MinBy(r => r.Value.ReadAt).Key);
            }
        }
    }

    /// <summary>The last directory read of this DN in the session, or null.</summary>
    public FicheRead? LastRead(string dn)
    {
        lock (gate)
        {
            if (reads.TryGetValue(dn, out var read))
            {
                return read;
            }
            return reads.Values.FirstOrDefault(r => FicheValues.SameDn(r.Entry.Dn, dn));
        }
    }

    /// <summary>The reference memberOf of an object, or null before its first fiche of the session.</summary>
    public FicheGroupBaseline? Baseline(Guid objectGuid)
    {
        lock (gate)
        {
            return baselines.GetValueOrDefault(objectGuid);
        }
    }

    public void KeepLockouts(Guid user, FicheLockoutDiagnosis diagnosis)
    {
        ArgumentNullException.ThrowIfNull(diagnosis);
        lock (gate)
        {
            lockouts[user] = (diagnosis, diagnosis.ReadAt);
        }
    }

    public FicheLockoutDiagnosis? Lockouts(Guid user)
    {
        lock (gate)
        {
            return lockouts.TryGetValue(user, out var kept) ? kept.Diagnosis : null;
        }
    }

    public void KeepPolicy(Guid user, FichePolicyView view, FichePolicyReading reading)
    {
        ArgumentNullException.ThrowIfNull(view);
        ArgumentNullException.ThrowIfNull(reading);
        lock (gate)
        {
            policies[user] = (view, reading);
        }
    }

    public (FichePolicyView View, FichePolicyReading Reading)? Policy(Guid user)
    {
        lock (gate)
        {
            return policies.TryGetValue(user, out var kept) ? kept : null;
        }
    }

    /// <summary>Keeps the explicit ping of a workstation under its objectGUID (FIC-046); a reading without a workstation is not kept.</summary>
    public void KeepPing(FichePresenceReading reading, Guid computer)
    {
        ArgumentNullException.ThrowIfNull(reading);
        if (reading.ComputerDn is null || computer == Guid.Empty)
        {
            return;
        }
        lock (gate)
        {
            pings[computer] = reading;
        }
    }

    public FichePresenceReading? Ping(Guid computer)
    {
        lock (gate)
        {
            return pings.GetValueOrDefault(computer);
        }
    }

    public void KeepSessions(FicheSessionsReading reading, Guid computer)
    {
        ArgumentNullException.ThrowIfNull(reading);
        if (computer == Guid.Empty)
        {
            return;
        }
        lock (gate)
        {
            sessions[computer] = reading;
        }
    }

    /// <summary>Sessions read in this session for the given workstations (GUID and DN), returned by the DN of each workstation.</summary>
    public IReadOnlyDictionary<string, FicheSessionsReading> Sessions(IEnumerable<(Guid Computer, string Dn)> computers)
    {
        ArgumentNullException.ThrowIfNull(computers);
        lock (gate)
        {
            var found = new Dictionary<string, FicheSessionsReading>(StringComparer.OrdinalIgnoreCase);
            foreach (var (computer, dn) in computers)
            {
                if (sessions.TryGetValue(computer, out var reading))
                {
                    found[dn] = reading;
                }
            }
            return found;
        }
    }

    public void KeepInventory(FicheInventoryReading reading, Guid computer)
    {
        ArgumentNullException.ThrowIfNull(reading);
        if (computer == Guid.Empty)
        {
            return;
        }
        lock (gate)
        {
            inventories[computer] = reading;
        }
    }

    public FicheInventoryReading? Inventory(Guid computer)
    {
        lock (gate)
        {
            return inventories.GetValueOrDefault(computer);
        }
    }

    /// <summary>Workstation of the triage chosen in the sheet of a user (the primary association otherwise).</summary>
    public void ChooseTriage(Guid user, string computerDn)
    {
        ArgumentNullException.ThrowIfNull(computerDn);
        lock (gate)
        {
            triageTargets[user] = computerDn;
        }
    }

    public string? TriageTarget(Guid user)
    {
        lock (gate)
        {
            return triageTargets.GetValueOrDefault(user);
        }
    }

    /// <summary>The observation of a workstation with the explicit ping of this session applied when it is more recent.</summary>
    public FicheObservation? WithPing(FicheObservation? observation, Guid computer, string computerDn, string computerName)
    {
        var ping = Ping(computer);
        if (ping is null)
        {
            return observation;
        }
        var answered = ping.State switch { "online" => (bool?)true, "offline" => false, _ => null };
        var baseObservation = observation ?? new FicheObservation(computerDn, computerName, MeasureState.Absent, null, null, null, null, null, MeasureState.Absent, null);
        if (baseObservation.PresenceAt is DateTimeOffset at && at >= ping.CheckedAt)
        {
            return baseObservation;
        }
        return baseObservation with
        {
            PresenceState = answered is null ? MeasureState.Error : MeasureState.Known,
            Answered = answered,
            PresenceAt = ping.CheckedAt,
            LastOnlineAt = answered == true ? ping.CheckedAt : baseObservation.LastOnlineAt,
            ConsoleUser = answered == true ? ping.ConsoleUser : baseObservation.ConsoleUser,
            ConsoleAt = answered == true ? ping.CheckedAt : baseObservation.ConsoleAt,
        };
    }

    /// <summary>
    /// « Relire » of one fiche (FIC-039: only the cache of this object, never the list; Domenia 1 FIC-037): forgets every entry of
    /// the object, designated by its objectGUID (the DN only finds the reads kept for it): the reads kept under any DN, the
    /// explicit reads (lockouts, policy) and, for a workstation, its ping, sessions and inventory. Returns the number of entries
    /// removed.
    /// </summary>
    public int Forget(string dn, Guid? objectGuid = null)
    {
        ArgumentNullException.ThrowIfNull(dn);
        lock (gate)
        {
            var guids = reads.Where(r => FicheValues.SameDn(r.Key, dn)).Select(r => r.Value.Entry.ObjectGuid).ToHashSet();
            if (objectGuid is Guid given && given != Guid.Empty)
            {
                guids.Add(given);
            }
            var removed = 0;
            foreach (var key in reads.Where(r => FicheValues.SameDn(r.Key, dn) || guids.Contains(r.Value.Entry.ObjectGuid)).Select(r => r.Key).ToList())
            {
                removed += reads.Remove(key) ? 1 : 0;
            }
            foreach (var guid in guids)
            {
                removed += (lockouts.Remove(guid) ? 1 : 0) + (policies.Remove(guid) ? 1 : 0) + (pings.Remove(guid) ? 1 : 0)
                    + (sessions.Remove(guid) ? 1 : 0) + (inventories.Remove(guid) ? 1 : 0);
            }
            return removed;
        }
    }

    /// <summary>
    /// Records an attempt to read one nature of a subject (« attributes » of an object, « presence » or « console » of a
    /// workstation), successful or not: shown as « dernière tentative » when it is more recent than the observation, and never
    /// rejuvenates it (FIC-036).
    /// </summary>
    public void KeepAttempt(string subject, string nature, DateTimeOffset at)
    {
        ArgumentNullException.ThrowIfNull(subject);
        ArgumentNullException.ThrowIfNull(nature);
        lock (gate)
        {
            attempts[(subject.ToUpperInvariant(), nature)] = at;
        }
    }

    /// <summary>The last attempt to read this nature of this subject in the session, or null.</summary>
    public DateTimeOffset? Attempt(string? subject, string nature)
    {
        if (subject is null)
        {
            return null;
        }
        lock (gate)
        {
            return attempts.TryGetValue((subject.ToUpperInvariant(), nature), out var at) ? at : null;
        }
    }

    /// <summary>Records when the history of an object (replication metadata) was read, its date of observation (FIC-036).</summary>
    public void KeepHistory(Guid objectGuid, DateTimeOffset at)
    {
        lock (gate)
        {
            histories[objectGuid] = at;
        }
    }

    /// <summary>When the history of this object was last read in the session, or null.</summary>
    public DateTimeOffset? History(Guid objectGuid)
    {
        lock (gate)
        {
            return histories.TryGetValue(objectGuid, out var at) ? at : null;
        }
    }

    /// <summary>Empty list helper for the sheet builder.</summary>
    public static ImmutableArray<T> None<T>() => [];
}
