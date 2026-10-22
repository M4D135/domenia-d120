using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// In-memory overlay of the fictitious directory (decision of David, 21/10: writes testable in simulation, without any real
/// effect; docs/WRITES.md § 5). It keeps, by object GUID, the objects the writes of the simulation changed, added or removed
/// (users, computers, groups and OUs); every read of <see cref="SimulatedDirectorySource"/> (home page, screen readers, write
/// executors) sees the directory through it. Never persisted: a new session starts from the generated directory again, the
/// generated world itself never changes (its fingerprint neither). Only the write executors of Domenia.Simulation change it
/// (internal methods). Thread safe.
/// </summary>
public sealed class SimulatedDirectoryOverlay
{
    private readonly Lock gate = new();
    private ImmutableDictionary<Guid, DirectoryUser> users = ImmutableDictionary<Guid, DirectoryUser>.Empty;
    private ImmutableDictionary<Guid, DirectoryComputer> computers = ImmutableDictionary<Guid, DirectoryComputer>.Empty;
    private ImmutableDictionary<Guid, DirectoryGroup> groups = ImmutableDictionary<Guid, DirectoryGroup>.Empty;
    private ImmutableDictionary<Guid, DirectoryOu> ous = ImmutableDictionary<Guid, DirectoryOu>.Empty;
    private ImmutableHashSet<Guid> removed = ImmutableHashSet<Guid>.Empty;
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

    /// <summary>Objects changed, added or removed by the writes of the session.</summary>
    public int ChangedObjects
    {
        get
        {
            lock (gate)
            {
                return users.Count + computers.Count + groups.Count + ous.Count + removed.Count;
            }
        }
    }

    /// <summary>The directory as the session sees it: <paramref name="snapshot"/> with every changed object in place.</summary>
    public DirectorySnapshot Apply(DirectorySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (gate)
        {
            return ApplyLocked(snapshot);
        }
    }

    private DirectorySnapshot ApplyLocked(DirectorySnapshot snapshot)
    {
        if (version == 0)
        {
            return snapshot;
        }
        if (ReferenceEquals(cachedBase, snapshot) && cachedVersion == version && cachedResult is not null)
        {
            return cachedResult;
        }
        var result = snapshot with
        {
            Users = Merge(snapshot.Users, users, removed, u => u.ObjectGuid),
            Computers = Merge(snapshot.Computers, computers, removed, c => c.ObjectGuid),
            Groups = Merge(snapshot.Groups, groups, removed, g => g.ObjectGuid),
            OrganizationalUnits = Merge(snapshot.OrganizationalUnits, ous, removed, o => o.ObjectGuid),
        };
        cachedBase = snapshot;
        cachedVersion = version;
        cachedResult = result;
        return result;
    }

    /// <summary>Base objects replaced by their changed version, removed ones dropped, added ones (unknown GUIDs) appended.</summary>
    private static ImmutableArray<T> Merge<T>(ImmutableArray<T> source, ImmutableDictionary<Guid, T> changed, ImmutableHashSet<Guid> gone, Func<T, Guid> id)
    {
        if (changed.IsEmpty && gone.IsEmpty)
        {
            return source;
        }
        var known = new HashSet<Guid>();
        var builder = ImmutableArray.CreateBuilder<T>(source.Length + changed.Count);
        foreach (var item in source)
        {
            var key = id(item);
            known.Add(key);
            if (gone.Contains(key))
            {
                continue;
            }
            builder.Add(changed.TryGetValue(key, out var replaced) ? replaced : item);
        }
        foreach (var (key, item) in changed.OrderBy(p => p.Key))
        {
            if (!known.Contains(key) && !gone.Contains(key))
            {
                builder.Add(item);
            }
        }
        return builder.ToImmutable();
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
        DirectoryUser? after = null;
        Edit(snapshot, edit =>
        {
            var current = edit.Current.Users.FirstOrDefault(u => u.ObjectGuid == id);
            if (current is null)
            {
                return false;
            }
            after = current;
            var next = change(current, edit.NextUsn());
            if (next is null)
            {
                return false;
            }
            edit.Put(next);
            after = next;
            return true;
        });
        return after;
    }

    // ---------------------------------------------------------------- generic edit
    // Added for the « Fiche » screen (wave 2): computers, groups, OUs and deletions, besides the users of UpdateUser. Other
    // screens that change computers or groups (« Poste ») can go through Edit too instead of a method per kind; the integrator
    // merges the two extensions of this file (see docs/status/fiche.json, « shared »).

    /// <summary>
    /// Applies one write of the simulation as a single change of the overlay (several objects at once when a write touches both
    /// sides of a link, such as member and memberOf). <paramref name="edit"/> sees the directory as the session sees it and
    /// returns true to keep its changes, false to drop them. Returns what it returned.
    /// </summary>
    internal bool Edit(DirectorySnapshot snapshot, Func<SimulatedDirectoryEdit, bool> edit)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        ArgumentNullException.ThrowIfNull(edit);
        lock (gate)
        {
            if (usn == 0)
            {
                usn = HighestUsn(snapshot);
            }
            var work = new SimulatedDirectoryEdit(ApplyLocked(snapshot), usn, users, computers, groups, ous, removed);
            if (!edit(work))
            {
                return false;
            }
            if (!work.Changed)
            {
                return true;
            }
            usn = work.Usn;
            users = work.Users;
            computers = work.Computers;
            groups = work.Groups;
            ous = work.Ous;
            removed = work.Removed;
            version++;
            return true;
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

/// <summary>
/// One change of the overlay in progress (<see cref="SimulatedDirectoryOverlay.Edit"/>): the directory as the session sees it
/// before the change, and the objects put or removed by the write. A write never changes the GUID of an object.
/// </summary>
internal sealed class SimulatedDirectoryEdit
{
    internal SimulatedDirectoryEdit(
        DirectorySnapshot current,
        long usn,
        ImmutableDictionary<Guid, DirectoryUser> users,
        ImmutableDictionary<Guid, DirectoryComputer> computers,
        ImmutableDictionary<Guid, DirectoryGroup> groups,
        ImmutableDictionary<Guid, DirectoryOu> ous,
        ImmutableHashSet<Guid> removed)
    {
        Current = current;
        Usn = usn;
        Users = users;
        Computers = computers;
        Groups = groups;
        Ous = ous;
        Removed = removed;
    }

    /// <summary>The directory as the session sees it before this change.</summary>
    public DirectorySnapshot Current { get; }

    public long Usn { get; private set; }

    public bool Changed { get; private set; }

    internal ImmutableDictionary<Guid, DirectoryUser> Users { get; private set; }

    internal ImmutableDictionary<Guid, DirectoryComputer> Computers { get; private set; }

    internal ImmutableDictionary<Guid, DirectoryGroup> Groups { get; private set; }

    internal ImmutableDictionary<Guid, DirectoryOu> Ous { get; private set; }

    internal ImmutableHashSet<Guid> Removed { get; private set; }

    /// <summary>Next update sequence number of the fictitious controller.</summary>
    public long NextUsn() => ++Usn;

    public void Put(DirectoryUser user)
    {
        ArgumentNullException.ThrowIfNull(user);
        Users = Users.SetItem(user.ObjectGuid, user);
        Changed = true;
    }

    public void Put(DirectoryComputer computer)
    {
        ArgumentNullException.ThrowIfNull(computer);
        Computers = Computers.SetItem(computer.ObjectGuid, computer);
        Changed = true;
    }

    public void Put(DirectoryGroup group)
    {
        ArgumentNullException.ThrowIfNull(group);
        Groups = Groups.SetItem(group.ObjectGuid, group);
        Changed = true;
    }

    public void Put(DirectoryOu ou)
    {
        ArgumentNullException.ThrowIfNull(ou);
        Ous = Ous.SetItem(ou.ObjectGuid, ou);
        Changed = true;
    }

    /// <summary>Removes an object of any kind from the directory seen by the session.</summary>
    public void Remove(Guid id)
    {
        Users = Users.Remove(id);
        Computers = Computers.Remove(id);
        Groups = Groups.Remove(id);
        Ous = Ous.Remove(id);
        Removed = Removed.Add(id);
        Changed = true;
    }
}
