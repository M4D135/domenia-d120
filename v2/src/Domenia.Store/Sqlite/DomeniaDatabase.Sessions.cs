using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<LegacySessionCacheRead> ReadLegacySessionsAsync(DirectoryComputer computer, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ArgumentNullException.ThrowIfNull(computer);
        if (computer.ObjectGuid == Guid.Empty || !InDomain(computer.DistinguishedName) || WorkstationIdentity.ExpectedName(computer) is null)
        { throw new InvalidDataException("Identité du poste hors de la base des sessions."); }
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return new LegacySessionCacheRead(null, null); }
        using var db = new SqliteDatabase(Path, true, cancellationToken: cancellationToken);
        db.Begin(false); CheckIdentity(db, true);
        LegacySessionCacheRead result;
        try { result = ReadLegacySessions(db, computer); }
        catch (Exception ex) when (ex is JsonException or InvalidDataException or FormatException or ArgumentException or OverflowException)
        { result = new(null, "Historique Sessions/WTS de Domenia 1 illisible, ambigu ou incompatible avec ce poste ; original conservé."); }
        db.Commit(); return result;
    }, cancellationToken);

    private LegacySessionCacheRead ReadLegacySessions(SqliteDatabase db, DirectoryComputer computer)
    {
        if (!Table(db, "domenia_details")) { return new(null, null); }
        var columns = db.Query("PRAGMA table_info(domenia_details);").Select(r => (string)r["name"]!).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var limits = new Dictionary<string, int>(StringComparer.Ordinal)
        {
            ["object_guid"] = 40, ["dn"] = 4096, ["attempt_at"] = 100, ["success_at"] = 100, ["status"] = 30,
            ["error"] = 2048, ["payload"] = PosteSessionCache.MaxBytes, ["attempt_payload"] = PosteSessionCache.MaxBytes,
        };
        if (limits.Keys.Concat(["result_kind", "request_key"]).Any(c => !columns.Contains(c))) { throw new InvalidDataException("Schéma du détail incompatible."); }
        // Check sizes inside SQLite before transferring a payload; exact GUID/kind/key and two-row ambiguity sentinel.
        var valid = string.Join(" AND ", limits.Select(p => "(" + p.Key + " IS NULL OR (typeof(" + p.Key + ")='text' AND length(CAST(" + p.Key + " AS BLOB))<=" + p.Value.ToString(CultureInfo.InvariantCulture) + "))"));
        var projection = string.Join(',', limits.Keys.Select(c => "CASE WHEN " + valid + " THEN " + c + " ELSE NULL END AS " + c));
        var rows = db.Query("SELECT " + projection + ",CASE WHEN " + valid + " THEN 1 ELSE 0 END AS valid FROM domenia_details "
            + "WHERE object_guid COLLATE NOCASE IN (?1,?2) AND result_kind='Sessions' COLLATE NOCASE AND request_key='WTS' COLLATE NOCASE LIMIT 2;",
            computer.ObjectGuid.ToString("D"), computer.ObjectGuid.ToString("B"));
        if (rows.Count == 0) { return new(null, null); }
        if (rows.Count != 1 || (long)rows[0]["valid"]! != 1) { throw new InvalidDataException("Détail ambigu ou hors limites."); }
        var row = rows[0];
        string? Text(string key) => row.GetValueOrDefault(key) as string;
        if (!Guid.TryParse(Text("object_guid"), out var guid) || guid != computer.ObjectGuid
            || Text("dn") is not { } dn || !DistinguishedName.AreEqual(dn, computer.DistinguishedName))
        { throw new InvalidDataException("Identité du détail différente."); }
        var attempted = SessionDate(Text("attempt_at"));
        if (attempted < computer.WhenCreated || computer.WhenCreated == DateTimeOffset.MinValue) { throw new InvalidDataException("Ancien compte ordinateur."); }
        var status = Text("status");
        var succeeded = status?.Equals("Success", StringComparison.OrdinalIgnoreCase) == true;
        if (!succeeded && status?.Equals("Error", StringComparison.OrdinalIgnoreCase) != true) { throw new InvalidDataException("État du détail inconnu."); }
        WorkstationSessionRead? success = null;
        if (!string.IsNullOrEmpty(Text("success_at")))
        {
            var at = SessionDate(Text("success_at"));
            if (at >= computer.WhenCreated) { success = ParseLegacySessions(Text("payload"), computer, at); }
        }
        WorkstationSessionRead latest;
        if (succeeded)
        {
            latest = success ?? throw new InvalidDataException("Liste de succès absente.");
            if (latest.At < attempted) { throw new InvalidDataException("Dates de succès incompatibles."); }
        }
        else
        {
            // Error data are not a list. The last success remains independent, never copied into this attempt.
            latest = new(attempted, SourceStatus.Error, [], 0, "Compte non mémorisé (Domenia 1)",
                "Domenia 1 : dernière tentative en échec. " + PosteText.Flat(Text("error") ?? "Cause non mémorisée.", 1900));
        }
        var memory = new WorkstationSessionMemory(WorkstationIdentity.ExpectedName(computer)!, latest, success?.Complete == true ? success : null);
        PosteSessionCache.Validate(memory, clock.GetUtcNow());
        return new(memory, "Historique Domenia 1, lu dans la base locale sans contact au poste.");
    }

    private DateTimeOffset SessionDate(string? value)
    {
        if (value is null || !OffsetSuffix().IsMatch(value) || !DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var at)
            || at == DateTimeOffset.MinValue || at > clock.GetUtcNow().AddMinutes(2))
        { throw new InvalidDataException("Date de sessions absente, sans fuseau ou future."); }
        return at;
    }

    private WorkstationSessionRead ParseLegacySessions(string? payload, DirectoryComputer computer, DateTimeOffset at)
    {
        if (payload is null) { throw new InvalidDataException("Liste de sessions absente."); }
        using var document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 16 });
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || DuplicateJournalProperties(root)
            || !WorkstationIdentity.Matches(computer, JournalText(root, "Computer", 255))
            || SessionDate(JournalText(root, "ObservedUtc", 100)) != at
            || !JournalProperty(root, "Rows", out var records) || records.ValueKind != JsonValueKind.Array || records.GetArrayLength() > PosteSessionCache.MaxSessions)
        { throw new InvalidDataException("Liste de sessions incompatible."); }
        var rows = ImmutableArray.CreateBuilder<LocalSession>(); var unread = 0;
        foreach (var record in records.EnumerateArray())
        {
            if (record.ValueKind != JsonValueKind.Object || !JournalProperty(record, "Id", out var id)
                || !(id.ValueKind == JsonValueKind.Number && id.TryGetInt32(out var number) && number >= 0))
            { throw new InvalidDataException("Identifiant de session invalide."); }
            var detail = JournalText(record, "Detail", 512);
            var partial = detail is null || !detail.Equals("Lecture WTS", StringComparison.OrdinalIgnoreCase);
            if (partial) { unread++; }
            var user = JournalText(record, "User", 320);
            var state = JournalText(record, "State", 64) ?? "Indéterminé";
            state = state switch { "Deconnectee" => "Déconnectée", "Connectee" => "Connectée", "Ecoute" => "Écoute", "Arretee" => "Arrêtée", "Reinitialisation" => "Réinitialisation", "Indetermine" => "Indéterminé", _ => state };
            if (partial && string.IsNullOrWhiteSpace(user)) { state = "Lecture partielle"; }
            var logon = LegacySessionTicks(record, "LogonTicks"); var idle = LegacySessionTicks(record, "IdleTicks");
            rows.Add(new(number.ToString(CultureInfo.InvariantCulture), JournalText(record, "Station", 512), user, JournalText(record, "Domain", 255),
                state, JournalText(record, "Protocol", 32) ?? "Indéterminé", logon > 0 ? DateTimeOffset.FromFileTime(logon) : null,
                idle > 0 ? TimeSpan.FromTicks(idle) : null, null));
        }
        return new(at, unread > 0 ? SourceStatus.Partial : rows.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok, rows.ToImmutable(), unread,
            JournalText(root, "Identity", 320) is { Length: > 0 } identity ? identity : "Compte non mémorisé (Domenia 1)",
            "Relevé WTS conservé par Domenia 1 ; aucune nouvelle lecture réseau.");
    }

    private static long LegacySessionTicks(JsonElement record, string name)
    {
        if (!JournalProperty(record, name, out var value) || value.ValueKind == JsonValueKind.Null) { return 0; }
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var ticks) || ticks < -1) { throw new InvalidDataException("Horloge WTS invalide."); }
        return ticks;
    }
}
