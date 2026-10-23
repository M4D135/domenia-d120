using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    public Task<FicheLocalRead?> ReadFicheAsync(string dn, CancellationToken token) => Task.Run(() =>
    {
        var key = FicheKey(dn);
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return null; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: token);
        CheckIdentity(db, allowLegacy: true);
        if (!Table(db, "domenia_v2_fiches")) { return null; }
        var rows = db.Query("SELECT object_guid,dn_key,payload,summary,sha256,observed_at FROM domenia_v2_fiches WHERE dn_key=?1 ORDER BY julianday(observed_at) DESC LIMIT 2;", key);
        if (rows.Count == 0) { return null; }
        var first = DecodeFiche(rows[0]);
        if (rows.Count > 1 && DecodeFiche(rows[1]).ReadAt == first.ReadAt)
        { throw new InvalidDataException("Plusieurs identités locales datées au même instant pour ce nom : relecture nécessaire."); }
        return first;
    }, token);

    public Task<ImmutableArray<FicheSummary>> ReadFicheIndexAsync(CancellationToken token) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!File.Exists(Path)) { return ImmutableArray<FicheSummary>.Empty; }
        using var db = new SqliteDatabase(Path, readOnly: true, cancellationToken: token);
        CheckIdentity(db, allowLegacy: true);
        if (!Table(db, "domenia_v2_fiches")) { return ImmutableArray<FicheSummary>.Empty; }
        var result = ImmutableArray.CreateBuilder<FicheSummary>();
        foreach (var row in db.Query("SELECT object_guid,dn_key,summary,summary_sha256 FROM domenia_v2_fiches;"))
        {
            token.ThrowIfCancellationRequested();
            var json = (string)row["summary"]!;
            if (FicheHash(json, "") != (string)row["summary_sha256"]!) { throw new InvalidDataException("Empreinte du résumé de fiche invalide."); }
            var summary = JsonSerializer.Deserialize<FicheSummary>(json, Json) ?? throw new InvalidDataException("Index de fiche illisible.");
            if (summary.ObjectGuid == Guid.Empty || summary.ObjectGuid.ToString("D") != (string)row["object_guid"]! || FicheKey(summary.Dn) != (string)row["dn_key"]!
                || !Enum.IsDefined(summary.Kind)) { throw new InvalidDataException("Identité de l’index de fiche incohérente."); }
            result.Add(summary);
        }
        return result.ToImmutable();
    }, token);

    public async Task<FicheLocalRead> SaveFicheAsync(FicheLocalRead fiche, CancellationToken token)
    {
        ValidateFiche(fiche);
        fiche = fiche with { Entry = fiche.Entry with { Attributes = fiche.Entry.Attributes.WithComparers(StringComparer.OrdinalIgnoreCase) } };
        var payload = JsonSerializer.Serialize(fiche, Json);
        if (Encoding.UTF8.GetByteCount(payload) > 4_194_304) { throw new InvalidDataException("Fiche trop volumineuse pour le stockage local."); }
        var summary = JsonSerializer.Serialize(FicheSummary.From(fiche.Entry, fiche.ReadAt), Json);
        var hash = FicheHash(payload, summary);
        await writer.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = new SqliteDatabase(Path, readOnly: false, cancellationToken: token);
                CheckIdentity(db, allowLegacy: false);
                EnsureBackup(db, token);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                db.Execute("INSERT INTO domenia_v2_fiches(object_guid,dn_key,payload,summary,sha256,observed_at,summary_sha256) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(object_guid) DO UPDATE SET dn_key=excluded.dn_key,payload=excluded.payload,summary=excluded.summary,summary_sha256=excluded.summary_sha256,sha256=excluded.sha256,observed_at=excluded.observed_at WHERE julianday(excluded.observed_at)>=julianday(domenia_v2_fiches.observed_at);",
                    fiche.Entry.ObjectGuid.ToString("D"), FicheKey(fiche.Entry.Dn), payload, summary, hash, Stamp(fiche.ReadAt), FicheHash(summary, ""));
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                db.Commit();
                var row = db.Query("SELECT object_guid,dn_key,payload,summary,sha256,observed_at FROM domenia_v2_fiches WHERE object_guid=?1;", fiche.Entry.ObjectGuid.ToString("D")).Single();
                return DecodeFiche(row);
            }, token).ConfigureAwait(false);
        }
        finally { writer.Release(); }
    }

    private FicheLocalRead DecodeFiche(IReadOnlyDictionary<string, object?> row)
    {
        var payload = (string)row["payload"]!;
        var summary = (string)row["summary"]!;
        if (Encoding.UTF8.GetByteCount(payload) > 4_194_304 || FicheHash(payload, summary) != (string)row["sha256"]!)
        { throw new InvalidDataException("Empreinte de fiche locale invalide."); }
        var fiche = JsonSerializer.Deserialize<FicheLocalRead>(payload, Json) ?? throw new InvalidDataException("Fiche locale illisible.");
        ValidateFiche(fiche);
        // JSON dictionaries do not preserve their original case-insensitive comparer.
        var attrs = fiche.Entry.Attributes;
        if (attrs.Keys.Distinct(StringComparer.OrdinalIgnoreCase).Count() != attrs.Count) { throw new InvalidDataException("Attributs de fiche dupliqués."); }
        fiche = fiche with { Entry = fiche.Entry with { Attributes = attrs.WithComparers(StringComparer.OrdinalIgnoreCase) } };
        var storedSummary = JsonSerializer.Deserialize<FicheSummary>(summary, Json) ?? throw new InvalidDataException("Résumé de fiche absent.");
        var summaryDate = storedSummary.ObservedAt;
        var expectedSummary = FicheSummary.From(fiche.Entry, summaryDate);
        if (storedSummary.Mail is null) { expectedSummary = expectedSummary with { Mail = null }; }
        if (fiche.Entry.ObjectGuid.ToString("D") != (string)row["object_guid"]! || FicheKey(fiche.Entry.Dn) != (string)row["dn_key"]!
            || Stamp(fiche.ReadAt) != (string)row["observed_at"]! || summaryDate is not null && summaryDate != fiche.ReadAt
            || JsonSerializer.Serialize(expectedSummary, Json) != summary)
        { throw new InvalidDataException("Identité, résumé ou date de fiche incohérente."); }
        return fiche;
    }

    private void ValidateFiche(FicheLocalRead fiche)
    {
        ArgumentNullException.ThrowIfNull(fiche);
        var entry = fiche.Entry ?? throw new InvalidDataException("Fiche absente.");
        if (!Enum.IsDefined(entry.Kind) || entry.ObjectGuid == Guid.Empty || !InDomain(entry.Dn) || string.IsNullOrWhiteSpace(entry.Name)
            || fiche.ReadAt == DateTimeOffset.MinValue || fiche.ReadAt > clock.GetUtcNow().AddMinutes(2) || entry.Attributes is null
            || entry.Attributes.Count > 4096 || entry.Attributes.Keys.Distinct(StringComparer.OrdinalIgnoreCase).Count() != entry.Attributes.Count
            || entry.Attributes.Any(p => p.Value.IsDefault || p.Value.Length > 50_000 || p.Value.Any(v => v is null)
                || p.Key.StartsWith("__", StringComparison.Ordinal) && p.Key is not ("__memberOfComplete" or "__memberOfNote" or "__memberComplete" or "__memberNote")
                || !p.Key.StartsWith("__", StringComparison.Ordinal) && (!FicheAttributeRules.IsValidName(p.Key) || FicheAttributeRules.IsSensitive(p.Key))))
        { throw new InvalidDataException("Identité, attributs ou date de fiche invalides : aucun stockage."); }
        var identity = entry.Attributes.Where(p => p.Key.Equals("objectGUID", StringComparison.OrdinalIgnoreCase)).SelectMany(p => p.Value).ToArray();
        if (identity.Length != 1 || !Guid.TryParse(identity[0], out var id) || id != entry.ObjectGuid) { throw new InvalidDataException("GUID de fiche incohérent."); }
    }

    private string FicheKey(string dn)
    {
        if (!InDomain(dn)) { throw new InvalidDataException("Fiche hors du domaine de la base."); }
        return DistinguishedName.Format(DistinguishedName.Parse(dn)).ToLowerInvariant();
    }

    private static string FicheHash(string payload, string summary) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(payload + "\n" + summary)));
}
