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
        if (!DatabaseFileExists()) { return QueryStoredReadings.Empty; }
        using var db = Open(readOnly: true, cancellationToken: cancellationToken);
        db.Begin(write: false); CheckIdentity(db, allowLegacy: true);
        var result = ReadQueryResults(db); db.Commit(); return result;
    }, cancellationToken);

    private async Task<QueryStoredReadings> SaveQueryResultsCoreAsync(QueryComputerReadings readings, CancellationToken cancellationToken)
    {
        _ = await SaveQueryResultCoreAsync(readings, cancellationToken).ConfigureAwait(false);
        return await ReadQueryResultsAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<QueryComputerReadings> SaveQueryResultCoreAsync(QueryComputerReadings readings, CancellationToken cancellationToken)
    {
        QueryReadingRules.Validate(readings, clock.GetUtcNow());
        if (!InDomain(readings.Dn)) { throw new InvalidDataException("Résultat de requête hors domaine."); }
        await writer.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady(); CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = Open(readOnly: false, cancellationToken: cancellationToken);
                CheckIdentity(db, allowLegacy: false);
                if (!Table(db, "domenia_v2_query_results")) { lastBackup = Backup(db, cancellationToken); } else { EnsureBackup(db, cancellationToken); }
                db.Script("PRAGMA synchronous=FULL;"); db.Begin(); CheckIdentity(db, allowLegacy: false);
                var computerJson = db.Scalar("SELECT CASE WHEN length(CAST(payload AS BLOB))<=1048576 THEN payload END FROM domenia_v2_objects WHERE object_guid=?1 AND kind='computer';", readings.Computer.ToString("D")) as string;
                var computer = computerJson is null ? null : JsonSerializer.Deserialize<DirectoryComputer>(computerJson, Json);
                if (computer is null || computer.ObjectGuid != readings.Computer || !DistinguishedName.AreEqual(computer.DistinguishedName, readings.Dn) || computer.WhenCreated != readings.Created
                    || readings.Identity is { } identity && !identity.Matches(computer)
                    || readings.Probes.Any(p => p.Identity is { } proof && !proof.Matches(computer)))
                { throw new InvalidDataException("Identité locale du poste modifiée avant stockage du résultat."); }
                db.Execute("CREATE TABLE IF NOT EXISTS domenia_v2_query_results(computer_guid TEXT PRIMARY KEY NOT NULL,payload TEXT NOT NULL,sha256 TEXT NOT NULL);");
                var before = ReadQueryResult(db, readings.Computer);
                var merged = QueryReadingRules.Merge(before, readings);
                QueryReadingRules.Validate(merged, clock.GetUtcNow());
                var json = JsonSerializer.Serialize(merged, Json);
                if (Encoding.UTF8.GetByteCount(json) > 2_097_152) { throw new InvalidDataException("Requêtes mémorisées limitées à 2 Mio par poste."); }
                var hash = QueryHash(json);
                db.Execute("INSERT INTO domenia_v2_query_results(computer_guid,payload,sha256) VALUES(?1,?2,?3) ON CONFLICT(computer_guid) DO UPDATE SET payload=excluded.payload,sha256=excluded.sha256;", readings.Computer.ToString("D"), json, hash);
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                if (db.Scalar("SELECT payload FROM domenia_v2_query_results WHERE computer_guid=?1 AND sha256=?2;", readings.Computer.ToString("D"), hash) as string != json)
                { throw new InvalidDataException("Résultat différent après écriture ; transaction annulée."); }
                var verified = ReadQueryResult(db, readings.Computer) ?? throw new InvalidDataException("Lecture écrite absente avant commit.");
                db.Commit(); return verified;
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private QueryStoredReadings ReadQueryResults(SqliteDatabase db)
    {
        if (!Table(db, "domenia_v2_query_results")) { return QueryStoredReadings.Empty; }
        // Stream SQLite rows: the native payload and its decoded object are never both retained
        // for the entire park. A bounded local snapshot remains explicit; no partial result escapes.
        var rows = db.ReadRows("SELECT computer_guid,CASE WHEN length(CAST(payload AS BLOB))<=2097152 THEN payload END AS payload,sha256 FROM domenia_v2_query_results ORDER BY computer_guid LIMIT 100001;");
        var result = ImmutableArray.CreateBuilder<QueryComputerReadings>();
        long bytes = 0;
        foreach (var row in rows)
        {
            if (result.Count == OperationsPersistence.MaxTargets) { throw new InvalidDataException("Instantané de requêtes supérieur à 100 000 postes ; aucune lecture partielle."); }
            if (row["payload"] is not string payload || (bytes += Encoding.UTF8.GetByteCount(payload)) > 512L * 1024 * 1024)
            { throw new InvalidDataException("Instantané de requêtes supérieur au budget mémoire de 512 Mio ou ligne hors limites ; aucune lecture partielle."); }
            result.Add(ReadQueryRow(row));
        }
        return new((long?)db.Scalar("SELECT revision FROM domenia_store_state WHERE id=1;") ?? 0, result.ToImmutable());
    }

    private QueryComputerReadings? ReadQueryResult(SqliteDatabase db, Guid computer)
    {
        var row = db.Query("SELECT computer_guid,CASE WHEN length(CAST(payload AS BLOB))<=2097152 THEN payload END AS payload,sha256 FROM domenia_v2_query_results WHERE computer_guid=?1;", computer.ToString("D")).SingleOrDefault();
        return row is null ? null : ReadQueryRow(row);
    }

    private QueryComputerReadings ReadQueryRow(Dictionary<string, object?> row)
    {
        if (row["payload"] is not string json || QueryHash(json) != row["sha256"] as string) { throw new InvalidDataException("Résultat de requête illisible ou empreinte différente."); }
        var item = JsonSerializer.Deserialize<QueryComputerReadings>(json, Json) ?? throw new InvalidDataException("Résultat de requête vide.");
        QueryReadingRules.Validate(item, clock.GetUtcNow());
        if (item.Computer.ToString("D") != row["computer_guid"] as string || !InDomain(item.Dn)) { throw new InvalidDataException("Identité de requête incohérente."); }
        return item with { Probes = [.. item.Probes.Select(p => p with { Instances = [.. p.Instances.Select(i => i with {
            Values = i.Values.ToImmutableDictionary(v => v.Key, v => RestoreQueryScalar(v.Value), StringComparer.OrdinalIgnoreCase) })] })] };
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
