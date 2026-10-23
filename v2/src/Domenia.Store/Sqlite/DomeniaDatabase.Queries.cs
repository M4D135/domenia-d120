using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<QueryStoredReadings> ReadQueryResultsAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return QueryStoredReadings.Empty; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false); CheckIdentity(db, allowLegacy: true);
        var result = ReadQueryResults(db); db.Commit(); return result;
    }, cancellationToken);

    private async Task<QueryStoredReadings> SaveQueryResultsCoreAsync(QueryComputerReadings readings, CancellationToken cancellationToken)
    {
        QueryReadingRules.Validate(readings, clock.GetUtcNow());
        if (!InDomain(readings.Dn)) { throw new InvalidDataException("Résultat de requête hors domaine."); }
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                if (!Table(db, "domenia_v2_query_results")) { lastBackup = Backup(db, cancellationToken); } else { EnsureBackup(db, cancellationToken); }
                db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, allowLegacy: false);
                var computerJson = db.Scalar("SELECT CASE WHEN length(CAST(payload AS BLOB))<=1048576 THEN payload END FROM domenia_v2_objects WHERE object_guid=?1 AND kind='computer';", readings.Computer.ToString("D")) as string;
                var computer = computerJson is null ? null : JsonSerializer.Deserialize<DirectoryComputer>(computerJson, Json);
                if (computer is null || computer.ObjectGuid != readings.Computer || !DistinguishedName.AreEqual(computer.DistinguishedName, readings.Dn) || computer.WhenCreated != readings.Created)
                { throw new InvalidDataException("Identité locale du poste modifiée avant stockage du résultat."); }
                db.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_query_results(computer_guid TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL,sha256 TEXT NOT NULL);");
                var before = ReadQueryResults(db);
                var merged = QueryReadingRules.Merge(before.Computers.FirstOrDefault(c => c.Computer == readings.Computer), readings);
                QueryReadingRules.Validate(merged, clock.GetUtcNow());
                var json = JsonSerializer.Serialize(merged, Json);
                if (Encoding.UTF8.GetByteCount(json) > 2_097_152) { throw new InvalidDataException("Requêtes mémorisées limitées à 2 Mio par poste."); }
                var hash = QueryHash(json);
                db.Execute("INSERT INTO domenia_v2_query_results(computer_guid,payload,sha256) VALUES(?1,?2,?3) ON CONFLICT(computer_guid) DO UPDATE SET payload=excluded.payload,sha256=excluded.sha256;", readings.Computer.ToString("D"), json, hash);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                if (db.Scalar("SELECT payload FROM domenia_v2_query_results WHERE computer_guid=?1 AND sha256=?2;", readings.Computer.ToString("D"), hash) as string != json)
                { throw new InvalidDataException("Résultat différent après écriture ; transaction annulée."); }
                _ = ReadQueryResults(db); db.Commit(); return ReadQueryResults(db);
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private QueryStoredReadings ReadQueryResults(SqliteDatabase db)
    {
        if (!Table(db, "domenia_v2_query_results")) { return QueryStoredReadings.Empty; }
        var size = (long?)db.Scalar("SELECT coalesce(sum(length(CAST(payload AS BLOB))),0) FROM domenia_v2_query_results;") ?? 0;
        if (size > 67_108_864) { throw new InvalidDataException("Lectures de requêtes supérieures à 64 Mio ; lecture locale refusée."); }
        var rows = db.Query("SELECT computer_guid,CASE WHEN length(CAST(payload AS BLOB))<=2097152 THEN payload END AS payload,sha256 FROM domenia_v2_query_results ORDER BY computer_guid LIMIT 50001;");
        if (rows.Count > 50_000) { throw new InvalidDataException("Plus de 50 000 postes dans le cache de requêtes."); }
        var result = ImmutableArray.CreateBuilder<QueryComputerReadings>();
        foreach (var row in rows)
        {
            if (row["payload"] is not string json || QueryHash(json) != row["sha256"] as string) { throw new InvalidDataException("Résultat de requête illisible ou empreinte différente."); }
            var item = JsonSerializer.Deserialize<QueryComputerReadings>(json, Json) ?? throw new InvalidDataException("Résultat de requête vide.");
            QueryReadingRules.Validate(item, clock.GetUtcNow());
            if (item.Computer.ToString("D") != row["computer_guid"] as string || !InDomain(item.Dn)) { throw new InvalidDataException("Identité de requête incohérente."); }
            result.Add(item with { Probes = [.. item.Probes.Select(p => p with { Instances = [.. p.Instances.Select(i => i with {
                Values = i.Values.ToImmutableDictionary(v => v.Key, v => RestoreQueryScalar(v.Value), StringComparer.OrdinalIgnoreCase) })] })] });
        }
        return new((long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0, result.ToImmutable());
    }

    private static object? RestoreQueryScalar(object? value) => value is not JsonElement element ? value : element.ValueKind switch
    {
        JsonValueKind.Null => null, JsonValueKind.String => element.GetString(), JsonValueKind.True => true, JsonValueKind.False => false,
        JsonValueKind.Number when element.TryGetInt64(out var number) => number,
        JsonValueKind.Number when element.TryGetDecimal(out var number) => number,
        JsonValueKind.Array when element.GetArrayLength() <= 256 => element.EnumerateArray().Select(e => RestoreQueryScalar(e)).ToArray(),
        _ => throw new InvalidDataException("Valeur de sonde non scalaire ou hors limites."),
    };
    private static string QueryHash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
}
