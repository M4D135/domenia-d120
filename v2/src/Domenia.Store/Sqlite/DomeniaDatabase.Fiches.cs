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
        if (!DatabaseFileExists()) { return null; }
        using var db = Open(readOnly: true, cancellationToken: token);
        db.Begin(write: false);
        CheckIdentity(db, allowLegacy: true);
        if (!Table(db, "domenia_v2_fiches")) { return null; }
        var rows = db.Query("SELECT object_guid,dn_key,payload,summary,sha256,observed_at FROM domenia_v2_fiches WHERE dn_key=?1 ORDER BY julianday(observed_at) DESC LIMIT 2;", key);
        if (rows.Count == 0) { return null; }
        if (rows.Count > 1) { throw new InvalidDataException("Plusieurs identités locales pour ce nom : désignez le GUID ou relisez l’annuaire."); }
        var first = DecodeFiche(rows[0]);
        CheckFicheProvenance(db, first);
        return first;
    }, token);

    public Task<FicheLocalRead?> ReadFicheByGuidAsync(Guid id, CancellationToken token) => Task.Run(() =>
    {
        if (id == Guid.Empty) return null;
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) return null;
        using var db = Open(readOnly: true, cancellationToken: token);
        db.Begin(write: false);
        CheckIdentity(db, allowLegacy: true);
        if (!Table(db, "domenia_v2_fiches")) return null;
        var rows = db.Query("SELECT object_guid,dn_key,payload,summary,sha256,observed_at FROM domenia_v2_fiches WHERE object_guid=?1;", id.ToString("D"));
        if (rows.Count == 0) return null;
        var read = DecodeFiche(rows.Single());
        CheckFicheProvenance(db, read);
        return read;
    }, token);

    public Task<ImmutableArray<FicheSummary>> ReadFicheIndexAsync(CancellationToken token) => Task.Run(() =>
    {
        CompatibleDirectoryCache.ValidateLocalPath(Path);
        if (!DatabaseFileExists()) { return ImmutableArray<FicheSummary>.Empty; }
        using var db = Open(readOnly: true, cancellationToken: token);
        db.Begin(write: false);
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

    private async Task<FicheLocalRead> SaveFicheCoreAsync(FicheLocalRead fiche, CancellationToken token)
    {
        ValidateFiche(fiche);
        fiche = fiche with { Entry = fiche.Entry with { Attributes = fiche.Entry.Attributes.WithComparers(StringComparer.OrdinalIgnoreCase) } };
        var payload = JsonSerializer.Serialize(fiche, Json);
        if (Encoding.UTF8.GetByteCount(payload) > 4_194_304) { throw new InvalidDataException("Fiche trop volumineuse pour le stockage local."); }
        var summary = JsonSerializer.Serialize(FicheSummary.From(fiche.Entry, fiche.ReadAt, fiche.Provenance?.ReaderHash), Json);
        var hash = FicheHash(payload, summary);
        await writer.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                EnsureReady();
                CompatibleDirectoryCache.ValidateLocalPath(Path);
                using var db = Open(readOnly: false, cancellationToken: token);
                CheckIdentity(db, allowLegacy: false);
                EnsureBackup(db, token);
                db.Script("PRAGMA synchronous=FULL;");
                db.Begin();
                CheckIdentity(db, allowLegacy: false);
                if ((long)db.Scalar("SELECT count(*) FROM domenia_v2_deletions WHERE object_guid=?1 AND julianday(observed_at)>=julianday(?2);", fiche.Entry.ObjectGuid.ToString("D"), Stamp(fiche.ReadAt))! > 0)
                { throw new InvalidDataException("Cette lecture précède une disparition confirmée ; elle ne peut pas rétablir la fiche."); }
                db.Execute("INSERT INTO domenia_v2_fiches(object_guid,dn_key,payload,summary,sha256,observed_at,summary_sha256) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(object_guid) DO UPDATE SET dn_key=excluded.dn_key,payload=excluded.payload,summary=excluded.summary,summary_sha256=excluded.summary_sha256,sha256=excluded.sha256,observed_at=excluded.observed_at WHERE julianday(excluded.observed_at)>=julianday(domenia_v2_fiches.observed_at);",
                    fiche.Entry.ObjectGuid.ToString("D"), FicheKey(fiche.Entry.Dn), payload, summary, hash, Stamp(fiche.ReadAt), FicheHash(summary, ""));
                db.Execute("UPDATE domenia_store_state SET revision=revision+1 WHERE id=1;");
                var row = db.Query("SELECT object_guid,dn_key,payload,summary,sha256,observed_at FROM domenia_v2_fiches WHERE object_guid=?1;", fiche.Entry.ObjectGuid.ToString("D")).Single();
                var retained = DecodeFiche(row);
                // Use the retained row: an older attempt may have been ignored by the UPSERT.
                StoreFicheProvenance(db, retained);
                CheckFicheProvenance(db, retained);
                db.Commit();
                return retained;
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
        var expectedSummary = FicheSummary.From(fiche.Entry, summaryDate, fiche.Provenance?.ReaderHash);
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
        if (fiche.Provenance is { } proof && (!proof.IsValid || proof.ObjectGuid != entry.ObjectGuid || !FicheValues.SameDn(proof.DomainDn, DomainDn)
            || proof.UsnChanged != entry.Int64("uSNChanged")))
        { throw new InvalidDataException("Provenance de fiche incohérente : aucun stockage."); }
        var identity = entry.Attributes.Where(p => p.Key.Equals("objectGUID", StringComparison.OrdinalIgnoreCase)).SelectMany(p => p.Value).ToArray();
        if (identity.Length != 1 || !Guid.TryParse(identity[0], out var id) || id != entry.ObjectGuid) { throw new InvalidDataException("GUID de fiche incohérent."); }
    }

    private static void StoreFicheProvenance(SqliteDatabase db, FicheLocalRead fiche)
    {
        var id = fiche.Entry.ObjectGuid.ToString("D");
        if (fiche.Provenance is not { } proof)
        {
            // A new unqualified observation cannot inherit a previous reader/version proof.
            db.Execute("DELETE FROM domenia_provenance WHERE object_guid=?1;", id);
            return;
        }
        db.Execute("INSERT INTO domenia_provenance(object_guid,domain_dn,reader,source_dc,invocation_id,usn_changed,observed_at) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(object_guid) DO UPDATE SET domain_dn=excluded.domain_dn,reader=excluded.reader,source_dc=excluded.source_dc,invocation_id=excluded.invocation_id,usn_changed=excluded.usn_changed,observed_at=excluded.observed_at;",
            id, proof.DomainDn, proof.ReaderHash, proof.Controller, proof.InvocationId?.ToString("D"), proof.UsnChanged, Stamp(fiche.ReadAt));
    }

    private static void CheckFicheProvenance(SqliteDatabase db, FicheLocalRead fiche)
    {
        if (fiche.Provenance is not { } proof) return; // Historical records explicitly have no qualification.
        var rows = db.Query("SELECT domain_dn,reader,source_dc,invocation_id,usn_changed,observed_at FROM domenia_provenance WHERE object_guid=?1;", fiche.Entry.ObjectGuid.ToString("D"));
        if (rows.Count != 1) throw new InvalidDataException("Provenance de fiche manquante.");
        var row = rows[0];
        if (!Equals(row["domain_dn"], proof.DomainDn) || !Equals(row["reader"], proof.ReaderHash) || !Equals(row["source_dc"], proof.Controller)
            || !Equals(row["invocation_id"], proof.InvocationId?.ToString("D")) || !Equals(row["usn_changed"], proof.UsnChanged) || !Equals(row["observed_at"], Stamp(fiche.ReadAt)))
            throw new InvalidDataException("Provenance de fiche altérée : relecture nécessaire.");
    }

    private string FicheKey(string dn)
    {
        if (!InDomain(dn)) { throw new InvalidDataException("Fiche hors du domaine de la base."); }
        return DistinguishedName.Format(DistinguishedName.Parse(dn)).ToLowerInvariant();
    }

    private static string FicheHash(string payload, string summary) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(payload + "\n" + summary)));
}
