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
    private readonly Dictionary<string, FichePresenceReading> pings = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, FicheSessionsReading> sessions = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, FicheInventoryReading> inventories = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<Guid, string> triageTargets = new();
    private readonly Dictionary<string, FicheRead> reads = new(StringComparer.OrdinalIgnoreCase);

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

    public void KeepPing(FichePresenceReading reading)
    {
        ArgumentNullException.ThrowIfNull(reading);
        if (reading.ComputerDn is null)
        {
            return;
        }
        lock (gate)
        {
            pings[reading.ComputerDn] = reading;
        }
    }

    public FichePresenceReading? Ping(string computerDn)
    {
        lock (gate)
        {
            return pings.GetValueOrDefault(computerDn);
        }
    }

    public void KeepSessions(FicheSessionsReading reading)
    {
        ArgumentNullException.ThrowIfNull(reading);
        lock (gate)
        {
            sessions[reading.ComputerDn] = reading;
        }
    }

    /// <summary>Sessions read in this session for the given workstations.</summary>
    public IReadOnlyDictionary<string, FicheSessionsReading> Sessions(IEnumerable<string> computerDns)
    {
        ArgumentNullException.ThrowIfNull(computerDns);
        lock (gate)
        {
            return computerDns.Where(sessions.ContainsKey).Distinct(StringComparer.OrdinalIgnoreCase)
                .ToDictionary(d => d, d => sessions[d], StringComparer.OrdinalIgnoreCase);
        }
    }

    public void KeepInventory(FicheInventoryReading reading)
    {
        ArgumentNullException.ThrowIfNull(reading);
        lock (gate)
        {
            inventories[reading.ComputerDn] = reading;
        }
    }

    public FicheInventoryReading? Inventory(string computerDn)
    {
        lock (gate)
        {
            return inventories.GetValueOrDefault(computerDn);
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
    public FicheObservation? WithPing(FicheObservation? observation, string computerDn, string computerName)
    {
        var ping = Ping(computerDn);
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

    /// <summary>Forgets the explicit reads of one object (after a write on it): the next sheet reads them again on request.</summary>
    public void Forget(Guid objectGuid)
    {
        lock (gate)
        {
            lockouts.Remove(objectGuid);
            policies.Remove(objectGuid);
        }
    }

    /// <summary>Empty list helper for the sheet builder.</summary>
    public static ImmutableArray<T> None<T>() => [];
}
