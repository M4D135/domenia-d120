using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private OperationsLocalState WithLegacyOperations(SqliteDatabase db, OperationsLocalState state)
    {
        if (!Table(db, "domenia_domain_metadata")) { return state; }
        var rows = db.Query("SELECT domain_dn,family,request_key,attempt_at,status,error,success_at,CASE WHEN length(CAST(payload AS BLOB))<=65536 THEN payload END AS payload,CASE WHEN length(CAST(attempt_payload AS BLOB))<=65536 THEN attempt_payload END AS attempt_payload FROM domenia_domain_metadata WHERE domain_dn=?1 COLLATE NOCASE ORDER BY attempt_at DESC LIMIT 1001;", DomainDn);
        if (rows.Count > 1000) { throw new InvalidDataException("Plus de 1 000 relevés hérités ; lecture bornée non présentée comme complète."); }
        var legacy = rows.Select(ParseLegacyOperation).ToArray();
        var merged = legacy.Concat(state.Runs).DistinctBy(r => (r.Family, Dn: r.ScopeDn.ToUpperInvariant(), r.Subtree, r.AttemptAt))
            .OrderByDescending(r => r.AttemptAt).Take(1000).ToImmutableArray();
        var result = state with { Runs = merged }; OperationsPersistence.Validate(result); return result;
    }

    internal static OperationsCollectionRun ParseLegacyOperation(IReadOnlyDictionary<string, object?> row)
    {
        static DateTimeOffset Date(object? value)
        {
            if (value is not string text || text.Length is < 20 or > 40 || !(text.EndsWith('Z') || text.Length >= 6 && text[^3] == ':' && text[^6] is '+' or '-')
                || !DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed))
            { throw new InvalidDataException("Date héritée sans fuseau ou illisible."); }
            return parsed;
        }
        if (!Enum.TryParse<OperationsCollectionFamily>(row["family"] as string, out var family) || !Enum.IsDefined(family)
            || !Enum.TryParse<OperationsCollectionStatus>(row["status"] as string, out var status) || !Enum.IsDefined(status))
        { throw new InvalidDataException("Famille ou état de relevé hérité inconnu."); }
        var key = row["request_key"] as string ?? ""; var colon = key.IndexOf(':');
        if (colon < 0 || key[..colon] is not ("subtree" or "onelevel")) { throw new InvalidDataException("Profondeur du relevé hérité inconnue."); }
        var dn = key[(colon + 1)..]; var subtree = key[..colon] == "subtree";
        int? done = null, total = null, failed = null;
        var payload = row[status == OperationsCollectionStatus.Success ? "payload" : "attempt_payload"] as string;
        if (payload is not null && payload != "null")
        {
            using var json = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 12 }); var root = json.RootElement;
            if (root.GetProperty("Format").GetString() != "Domenia.CollectionRun/1" || root.GetProperty("Family").GetString() != family.ToString()
                || !DistinguishedName.AreEqual(root.GetProperty("ScopeDn").GetString() ?? "", dn) || root.GetProperty("Subtree").GetBoolean() != subtree)
            { throw new InvalidDataException("Identité du relevé hérité différente de sa clé."); }
            int? Count(string name) => root.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null
                ? value.TryGetInt32(out var count) && count >= 0 ? count : throw new InvalidDataException("Compteur hérité invalide.") : null;
            done = Count("Done"); total = Count("Targets"); failed = Count("Failed");
        }
        var attempt = Date(row["attempt_at"]); var successText = row["success_at"] as string;
        DateTimeOffset? success = string.IsNullOrEmpty(successText) ? null : Date(successText);
        if (success > attempt.AddMinutes(5)) { throw new InvalidDataException("Réussite héritée postérieure à sa tentative."); }
        return new(family, dn, SearchTexts.Leaf(dn), subtree, attempt, status, done, total, failed, success, row["error"] as string);
    }
}
