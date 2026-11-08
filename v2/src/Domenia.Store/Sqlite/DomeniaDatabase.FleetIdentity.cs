using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private static bool SameFleetComputer(string before, string after)
    {
        var old = JsonSerializer.Deserialize<DirectoryComputer>(before, Json) ?? throw new InvalidDataException("Identité locale de poste illisible.");
        var next = JsonSerializer.Deserialize<DirectoryComputer>(after, Json) ?? throw new InvalidDataException("Nouvelle identité de poste illisible.");
        // Moving the same AD object to another OU or changing its description does not replace the workstation.
        // A recreated identity or different endpoint must never inherit permanently reusable hardware readings.
        return old.ObjectGuid == next.ObjectGuid && old.WhenCreated == next.WhenCreated
            && string.Equals(old.Sid, next.Sid, StringComparison.OrdinalIgnoreCase)
            && string.Equals(old.DnsHostName, next.DnsHostName, StringComparison.OrdinalIgnoreCase)
            && string.Equals(old.SamAccountName, next.SamAccountName, StringComparison.OrdinalIgnoreCase);
    }

    private void InvalidateFleetComputers(SqliteDatabase db, HashSet<Guid> changed)
    {
        if (changed.Count == 0) { return; }
        if (Table(db, "domenia_v2_query_results"))
        {
            foreach (var chunk in changed.Chunk(256))
            {
                var placeholders = string.Join(',', Enumerable.Range(1, chunk.Length).Select(i => "?" + i));
                db.Execute("DELETE FROM domenia_v2_query_results WHERE computer_guid IN (" + placeholders + ");", chunk.Select(id => (object?)id.ToString("D")).ToArray());
            }
        }
        var fleet = ReadFleet(db);
        var next = fleet with
        {
            Observations = fleet.Observations with { Workstations = [.. fleet.Observations.Workstations.Where(x => !changed.Contains(x.ComputerGuid))] },
            Facts = fleet.Facts with
            {
                Machines = fleet.Facts.Machines.RemoveRange(changed),
                Runs = [.. fleet.Facts.Runs.Where(x => x.Family == CollectionFamily.Directory)],
                BitLocker = [.. fleet.Facts.BitLocker.Select(x => x with { Machines = x.Machines.RemoveRange(changed) })],
            },
            Probes = new(fleet.Probes.ByProbe.ToImmutableDictionary(x => x.Key, x => x.Value.RemoveRange(changed), StringComparer.Ordinal)),
            Addresses = fleet.Addresses.RemoveRange(changed),
            Inventories = fleet.Inventories.RemoveRange(changed),
            WorkstationProbes = fleet.WorkstationProbes.RemoveRange(changed),
            WorkstationSecrets = fleet.WorkstationSecrets.RemoveRange(changed),
            WorkstationSessions = fleet.WorkstationSessions.RemoveRange(changed),
            WorkstationDetails = fleet.WorkstationDetails.RemoveRange(changed),
        };
        var header = db.Scalar("SELECT payload FROM domenia_v2_metadata WHERE key='fleet';") as string;
        if (IsRowsFleet(header)) { _ = WriteFleetRows(db, next, changed, next.Facts.BitLocker); }
        else if (header is not null) { ReplaceFleet(db, next); }
        // Do not publish a new in-memory cache until the surrounding directory transaction has committed.
    }
}
