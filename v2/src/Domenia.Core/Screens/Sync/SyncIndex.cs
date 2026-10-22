using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Pure search of the local index (Domenia 1 LocalIndexRead « Search », points 1 to 4 of the autonomous base): the term is
/// normalized (domain prefix, UPN suffix and final « $ » removed), matched exactly, by prefix or anywhere in the record, inside
/// the scope; the sort covers the whole filtered population before the page is cut, with a stable identity to break ties;
/// total and page come from the same state of the base. The term is only compared, never interpreted.
/// </summary>
public static class SyncIndex
{
    public const int DefaultPageSize = 200;
    public const int MaxPageSize = 500;
    public const int MinTermLength = 2;
    public const int MaxTermLength = 100;

    /// <summary>Most rows of a CSV export (the page is only a display bound).</summary>
    public const int ExportLimit = 20_000;

    /// <summary>Term as compared: « EXAMPLE\j.martin », « j.martin@example.local » and « PC-01$ » become « j.martin » and « pc-01 ».</summary>
    public static string Normalize(string? term)
    {
        var clean = (term ?? "").Trim();
        var slash = clean.LastIndexOf('\\');
        if (slash >= 0)
        {
            clean = clean[(slash + 1)..];
        }
        var at = clean.IndexOf('@', StringComparison.Ordinal);
        if (at >= 0)
        {
            clean = clean[..at];
        }
        return FrenchText.Fold(clean.Trim().TrimEnd('$'));
    }

    public static string TypeLabel(IndexObjectType type) => type == IndexObjectType.Computer ? "Poste" : "Utilisateur";

    public static string StateLabel(bool enabled) => enabled ? "Actif" : "Désactivé";

    public static string SortLabel(IndexSort sort, bool descending)
    {
        var name = sort switch
        {
            IndexSort.Relevance => "Pertinence",
            IndexSort.Type => "Type",
            IndexSort.Name => "Nom",
            IndexSort.Login => "Identifiant",
            IndexSort.Upn => "UPN ou DNS",
            IndexSort.State => "État",
            IndexSort.Description => "Détail",
            IndexSort.Score => "Score",
            IndexSort.Reason => "Correspondance",
            IndexSort.LastLogon => "Connexion AD",
            _ => "Modifié dans AD",
        };
        return sort == IndexSort.Relevance ? name : name + (descending ? " (décroissant)" : " (croissant)");
    }

    /// <summary>Score of a record for a normalized term: 100 exact, 90 start of the name, 70 anywhere in the record, 0 none.</summary>
    public static int Score(IndexRecord record, string term)
    {
        ArgumentNullException.ThrowIfNull(record);
        ArgumentNullException.ThrowIfNull(term);
        if (term.Length == 0)
        {
            return 0;
        }
        var name = FrenchText.Fold(record.Name);
        var login = FrenchText.Fold(record.Login ?? "");
        var upn = FrenchText.Fold(record.Upn ?? "");
        if (name == term || login == term || upn == term)
        {
            return 100;
        }
        if (name.StartsWith(term, StringComparison.Ordinal) || (login.Length > 0 && login.StartsWith(term, StringComparison.Ordinal)) || (upn.Length > 0 && upn.StartsWith(term, StringComparison.Ordinal)))
        {
            return 90;
        }
        var key = FrenchText.Fold(string.Join(' ', record.Name, record.Login, record.Upn, record.DisplayName, record.Description, record.Extra));
        return key.Contains(term, StringComparison.Ordinal) ? 70 : 0;
    }

    public static string Reason(int score, bool browse) => score >= 100 ? "Correspondance exacte" : score >= 90 ? "Début du nom" : browse ? "Périmètre local" : "Contenu dans la fiche";

    /// <summary>LAPS schema of the domain as the last read of the schema found it (Domenia 1 $lapsSchema).</summary>
    public const string LapsSchemaPresent = "present";
    public const string LapsSchemaAbsent = "absent";
    public const string LapsSchemaUnknown = "unknown";

    /// <summary>
    /// LAPS state of a workstation of the base (Domenia 1 lapsKind): « windows » or « legacy » with an expiration date (never the
    /// password), « noSchema » when the attribute does not exist in the schema of the domain, « none » when the schema has it
    /// but no value is visible with this account, « unknown » before any read of the schema. Null for a user.
    /// </summary>
    public static (string? State, string? Text) Laps(IndexRecord record, string lapsSchema)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (record.Type != IndexObjectType.Computer)
        {
            return (null, null);
        }
        if (record.Laps != LapsKind.None && record.LapsExpiration is not null)
        {
            return record.Laps == LapsKind.Windows ? ("windows", "Windows LAPS") : ("legacy", "LAPS hérité");
        }
        return lapsSchema switch
        {
            LapsSchemaAbsent => ("noSchema", "Expiration LAPS non disponible dans ce domaine (attribut absent du schéma)"),
            LapsSchemaPresent => ("none", "Aucune expiration visible avec ce compte (LAPS non déployé sur ce poste ou attribut non lisible)"),
            _ => ("unknown", "Schéma LAPS non lu" + SyncText.C + "la prochaine lecture du domaine le précisera"),
        };
    }

    /// <summary>Row of the page for one record.</summary>
    public static IndexHit Hit(IndexRecord record, int score, bool browse, string? association, string lapsSchema = LapsSchemaUnknown)
    {
        ArgumentNullException.ThrowIfNull(record);
        var (lapsState, lapsText) = Laps(record, lapsSchema);
        return new IndexHit(record.ObjectGuid.ToString("D"), record.Type, TypeLabel(record.Type), record.Name, record.Login, record.Upn, record.DisplayName,
            record.Description, record.Extra, record.Enabled, StateLabel(record.Enabled), record.Dn, SyncLocations.Location(record.Dn), association, score,
            Reason(score, browse), record.WhenChanged, record.LastLogon, record.LapsExpiration, record.ObservedAt, lapsState, lapsText);
    }

    /// <summary>
    /// The rows matching the query, sorted over the whole population (no page cut). A term of one character matches nothing
    /// (the page asks for two); an empty term lists the scope.
    /// </summary>
    public static ImmutableArray<(IndexRecord Record, int Score)> Matches(IEnumerable<IndexRecord> rows, IndexQuery query)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(query);
        var term = Normalize(query.Term);
        var browse = term.Length == 0;
        if (!browse && term.Length < MinTermLength)
        {
            return [];
        }
        var matched = new List<(IndexRecord Record, int Score)>();
        foreach (var row in rows)
        {
            if (!query.Scope.IsDomain && !SyncLocations.InScope(row.Dn, query.Scope.Dn))
            {
                continue;
            }
            var score = browse ? 0 : Score(row, term);
            if (browse || score > 0)
            {
                matched.Add((row, score));
            }
        }
        matched.Sort((a, b) => Compare(a, b, query.Sort, query.Descending));
        return [.. matched];
    }

    /// <summary>One page of the query from the rows of the base (total and page from the same rows).</summary>
    public static IndexSearchPage Page(IEnumerable<IndexRecord> rows, IndexQuery query, Func<IndexRecord, string?> association, long generation, string lapsSchema = LapsSchemaUnknown)
    {
        ArgumentNullException.ThrowIfNull(association);
        ArgumentNullException.ThrowIfNull(query);
        var term = Normalize(query.Term);
        var browse = term.Length == 0;
        var limit = Math.Clamp(query.Limit, 1, MaxPageSize);
        var sortLabel = SortLabel(query.Sort, query.Descending);
        if (!browse && term.Length < MinTermLength)
        {
            return new IndexSearchPage(query.Term, false, query.Scope, query.Sort, query.Descending, sortLabel, 0, limit, 1, 1, 0, false, false, generation, [],
                "Saisissez au moins deux caractères, ou laissez vide pour tous les objets du périmètre.");
        }
        var matched = Matches(rows, query);
        var total = matched.Length;
        var offset = Math.Max(0, query.Offset);
        if (offset >= total)
        {
            offset = 0;
        }
        var page = matched.Skip(offset).Take(limit).Select(m => Hit(m.Record, m.Score, browse, association(m.Record), lapsSchema)).ToImmutableArray();
        var pages = Math.Max(1, (total + limit - 1) / limit);
        var number = offset / limit + 1;
        string message;
        if (total == 0)
        {
            message = browse
                ? "Aucun objet de la base locale dans ce périmètre. Mettez-le à jour pour le remplir."
                : "Aucun objet de la base locale ne correspond à " + FrenchText.Quote(SyncText.Flat(query.Term, MaxTermLength)) + ". La base peut être incomplète.";
        }
        else
        {
            message = FrenchText.Count(page.Length, "objet affiché", "objets affichés") + ", " + FrenchText.Count(total, "correspondant", "correspondants")
                + " dans la base · page " + FrenchText.Integer(number) + " sur " + FrenchText.Integer(pages) + ".";
        }
        return new IndexSearchPage(query.Term, browse, query.Scope, query.Sort, query.Descending, sortLabel, offset, limit, number, pages, total,
            offset + page.Length < total, false, generation, page, message);
    }

    /// <summary>The answer when the base is locked by a commit: never an empty result (Domenia 1 point 4).</summary>
    public static IndexSearchPage Busy(IndexQuery query, long generation)
    {
        ArgumentNullException.ThrowIfNull(query);
        return new IndexSearchPage(query.Term, Normalize(query.Term).Length == 0, query.Scope, query.Sort, query.Descending, SortLabel(query.Sort, query.Descending),
            Math.Max(0, query.Offset), Math.Clamp(query.Limit, 1, MaxPageSize), 1, 1, 0, false, true, generation, [],
            "Base locale occupée par un enregistrement" + SyncText.C + "nouvel essai dans un instant.");
    }

    private static int Compare((IndexRecord Record, int Score) a, (IndexRecord Record, int Score) b, IndexSort sort, bool descending)
    {
        int result;
        if (sort == IndexSort.Relevance)
        {
            result = b.Score.CompareTo(a.Score);
        }
        else
        {
            var left = Key(a, sort);
            var right = Key(b, sort);
            // An empty value stays last in both directions.
            if (left is null || right is null)
            {
                result = left is null ? (right is null ? 0 : 1) : -1;
                if (result != 0)
                {
                    return result;
                }
            }
            else
            {
                result = left switch
                {
                    string text => string.Compare(text, (string)right, StringComparison.Ordinal),
                    long number => number.CompareTo((long)right),
                    _ => 0,
                };
                if (descending)
                {
                    result = -result;
                }
            }
        }
        if (result != 0)
        {
            return result;
        }
        result = string.Compare(FrenchText.Fold(a.Record.Name), FrenchText.Fold(b.Record.Name), StringComparison.Ordinal);
        if (result != 0)
        {
            return result;
        }
        result = string.Compare(a.Record.ObjectGuid.ToString("D"), b.Record.ObjectGuid.ToString("D"), StringComparison.Ordinal);
        return result != 0 ? result : string.Compare(a.Record.Dn, b.Record.Dn, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Fixed sort expressions: folded text, dates compared as dates, the D1 order of the reasons kept.</summary>
    private static object? Key((IndexRecord Record, int Score) item, IndexSort sort)
    {
        var r = item.Record;
        static string? Text(string? value) => string.IsNullOrEmpty(value) ? null : FrenchText.Fold(value);
        return sort switch
        {
            IndexSort.Type => Text(TypeLabel(r.Type)),
            IndexSort.Name => Text(r.Name),
            IndexSort.Login => Text(r.Login),
            IndexSort.Upn => Text(r.Upn),
            IndexSort.State => Text(StateLabel(r.Enabled)),
            IndexSort.Description => Text(r.Description),
            IndexSort.Score => (long)item.Score,
            IndexSort.Reason => item.Score >= 100 ? 1L : item.Score >= 90 ? 2L : 0L,
            IndexSort.LastLogon => r.LastLogon?.UtcTicks,
            IndexSort.WhenChanged => r.WhenChanged?.UtcTicks,
            _ => null,
        };
    }
}
