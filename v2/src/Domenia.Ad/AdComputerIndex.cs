using System.Runtime.CompilerServices;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>One local index per immutable directory picture. A changed picture cannot inherit an old identity;
/// ambiguous GUIDs remain refused. Weak ownership releases obsolete pictures with their callers.</summary>
internal sealed class AdComputerIndex
{
    private static readonly ConditionalWeakTable<DirectorySnapshot, AdComputerIndex> Indexes = new();
    private readonly Dictionary<Guid, DirectoryComputer?> computers;
    private readonly Dictionary<string, DirectoryComputer?> names = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, DirectoryComputer?> hosts = new(StringComparer.OrdinalIgnoreCase);

    private AdComputerIndex(DirectorySnapshot snapshot)
    {
        computers = new(snapshot.Computers.Length);
        foreach (var computer in snapshot.Computers)
        {
            if (computer.ObjectGuid == Guid.Empty) continue;
            if (!computers.TryAdd(computer.ObjectGuid, computer)) computers[computer.ObjectGuid] = null;
            if (!names.TryAdd(computer.Name, computer)) names[computer.Name] = null;
            if (computer.DnsHostName is { Length: > 0 } host && !hosts.TryAdd(host.TrimEnd('.'), computer)) hosts[host.TrimEnd('.')] = null;
        }
    }

    internal static AdComputerIndex For(DirectorySnapshot snapshot) => Indexes.GetValue(snapshot, static value => new(value));
    internal DirectoryComputer? Find(Guid id) => computers.GetValueOrDefault(id);
    internal DirectoryComputer? Find(string target)
    {
        var name = target.Trim().TrimEnd('.');
        var candidate = (name.Contains('.') ? hosts : names).GetValueOrDefault(name);
        return candidate is not null && ReferenceEquals(Find(candidate.ObjectGuid), candidate) ? candidate : null;
    }
}
