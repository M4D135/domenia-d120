using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private static string LegacyIndexNotice(int count) => FrenchText.Integer(count)
        + " objets historiques sans GUID restent conservés dans la base ; hors résultats et totaux tant que leur identité n’a pas été relue dans l’annuaire.";

    private (int Count, string? Fingerprint) ReadUnidentifiedIndex(SqliteDatabase db, SyncScope? scope)
    {
        if (!Table(db, "ad_objects")) { return (0, null); }
        var raw = db.Query("SELECT object_key,object_type,distinguished_name FROM ad_objects WHERE object_type IN ('Machine','Utilisateur') AND COALESCE(object_guid,'')='' ORDER BY object_key LIMIT 300001;");
        if (raw.Count > SyncRowsLimit) { throw new InvalidDataException("Plus de 300 000 identités historiques non relues."); }
        if (raw.Count == 0) { return (0, null); }
        var identified = IndexRows(db, null).Select(x => (x.Type == IndexObjectType.Computer ? "Machine" : "Utilisateur") + "|" + x.Dn).ToImmutableHashSet(StringComparer.OrdinalIgnoreCase);
        var count = 0;
        foreach (var row in raw)
        {
            var dn = row["distinguished_name"] as string;
            var key = row["object_key"] as string;
            if (!InDomain(dn) || !string.Equals(key, (row["object_type"] as string) + "|" + dn, StringComparison.OrdinalIgnoreCase))
            { throw new InvalidDataException("Identité historique sans GUID non reconnue ; aucune identité inventée."); }
            if (scope is not null && !ScopeRules.Contains(new(scope.Dn, scope.Label, scope.Subtree), dn!)) { continue; }
            if (!identified.Contains(key!)) { count++; }
        }
        // Full raw values are already included in the bounded purge inventory, so a D1 edit without revision also stales a plan.
        return (count, ReadPurgeInventory(db, CancellationToken.None).Fingerprint);
    }
}
