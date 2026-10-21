using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// In-memory overlay of the fictitious directory (decision of David, 21/10: writes testable in simulation, without any real
/// effect; docs/WRITES.md § 5). It keeps, by object GUID, the objects the writes of the simulation changed; every read of
/// <see cref="SimulatedDirectorySource"/> (home page, screen readers, write executors) sees the directory through it. Never
/// persisted: a new session starts from the generated directory again, the generated world itself never changes (its
/// fingerprint neither). Only the write executors of Domenia.Simulation change it (internal methods). Thread safe.
/// </summary>
public sealed class SimulatedDirectoryOverlay
{
    private readonly Lock gate = new();
    private ImmutableDictionary<Guid, DirectoryUser> users = ImmutableDictionary<Guid, DirectoryUser>.Empty;
    private long version;
    private long usn;
    // Last application, so that consecutive reads of an unchanged directory share one snapshot.
    private DirectorySnapshot? cachedBase;
    private long cachedVersion = -1;
    private DirectorySnapshot? cachedResult;

    /// <summary>Number of changes applied since the start of the session (0: the generated directory as is).</summary>
    public long Version
    {
        get
        {
            lock (gate)
            {
                return version;
            }
        }
    }

    /// <summary>Objects changed by the writes of the session.</summary>
    public int ChangedObjects
    {
        get
        {
            lock (gate)
            {
                return users.Count;
            }
        }
    }

    /// <summary>The directory as the session sees it: <paramref name="snapshot"/> with every changed object in place.</summary>
    public DirectorySnapshot Apply(DirectorySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (gate)
        {
            if (version == 0)
            {
                return snapshot;
            }
            if (ReferenceEquals(cachedBase, snapshot) && cachedVersion == version && cachedResult is not null)
            {
                return cachedResult;
            }
            var changed = users;
            var result = snapshot with
            {
                Users = [.. snapshot.Users.Select(u => changed.TryGetValue(u.ObjectGuid, out var replaced) ? replaced : u)],
            };
            cachedBase = snapshot;
            cachedVersion = version;
            cachedResult = result;
            return result;
        }
    }

    /// <summary>
    /// Changes one user of <paramref name="snapshot"/> (the generated directory, before the overlay). <paramref name="change"/>
    /// receives the user as the session sees it and the next update sequence number; it returns the new user, or null to
    /// leave it as is. Returns the user after the call, or null when no user has this GUID.
    /// </summary>
    internal DirectoryUser? UpdateUser(DirectorySnapshot snapshot, Guid id, Func<DirectoryUser, long, DirectoryUser?> change)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(change);
        lock (gate)
        {
            var current = users.TryGetValue(id, out var known) ? known : snapshot.Users.FirstOrDefault(u => u.ObjectGuid == id);
            if (current is null)
            {
                return null;
            }
            if (usn == 0)
            {
                usn = HighestUsn(snapshot);
            }
            var next = change(current, usn + 1);
            if (next is null)
            {
                return current;
            }
            if (next.ObjectGuid != id)
            {
                throw new InvalidOperationException("A write of the simulation never changes the GUID of an object.");
            }
            usn++;
            users = users.SetItem(id, next);
            version++;
            return next;
        }
    }

    private static long HighestUsn(DirectorySnapshot snapshot)
    {
        long highest = 0;
        foreach (var value in snapshot.Users.Select(u => u.UsnChanged)
            .Concat(snapshot.Computers.Select(c => c.UsnChanged))
            .Concat(snapshot.Groups.Select(g => g.UsnChanged))
            .Concat(snapshot.OrganizationalUnits.Select(o => o.UsnChanged)))
        {
            highest = Math.Max(highest, value);
        }
        return highest;
    }
}
