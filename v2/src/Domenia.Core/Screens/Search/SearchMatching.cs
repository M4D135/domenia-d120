using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// One directory object as the search matches it: its kind, identity and the attributes of the word filter, folded once
/// (accents and case ignored). The same candidate serves the simulated directory and, later, the local base.
/// </summary>
public sealed class SearchCandidate
{
    private readonly string[] folded;

    public SearchCandidate(SearchObjectKind kind, Guid id, string? sid, string dn, string name, string? cn, string? sam, string? display,
        string? given, string? surname, string? upn, string? mail, string? dnsHostName, object source)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(source);
        Kind = kind;
        Id = id;
        Sid = sid;
        Dn = dn;
        Name = name;
        Sam = sam;
        Display = display;
        Upn = upn;
        Mail = mail;
        DnsHostName = dnsHostName;
        Source = source;
        // Same order as SearchText.WordAttributes: name, cn, sAMAccountName, displayName, sn, givenName, userPrincipalName, mail, dNSHostName.
        folded = [Fold(name), Fold(cn), Fold(sam), Fold(display), Fold(surname), Fold(given), Fold(upn), Fold(mail), Fold(dnsHostName)];
        NameKey = Fold(name);
    }

    public SearchObjectKind Kind { get; }

    public Guid Id { get; }

    public string? Sid { get; }

    public string Dn { get; }

    public string Name { get; }

    public string? Sam { get; }

    public string? Display { get; }

    public string? Upn { get; }

    public string? Mail { get; }

    public string? DnsHostName { get; }

    /// <summary>The directory object itself (user, computer, group or OU record).</summary>
    public object Source { get; }

    /// <summary>Folded name: the order of the keyset continuation (« name », as the directory mode sorts).</summary>
    public string NameKey { get; }

    /// <summary>Folded values of the word attributes, in the order of <see cref="SearchText.WordAttributes"/>.</summary>
    public IReadOnlyList<string> Folded => folded;

    /// <summary>Folded values of the « contient » attributes: name, displayName, sAMAccountName, dNSHostName.</summary>
    public IEnumerable<string> ContainsValues => [folded[0], folded[3], folded[2], folded[8]];

    private static string Fold(string? value) => value is null ? "" : FrenchText.Fold(value);
}

/// <summary>
/// Evaluation in memory of the plan of a text, with the semantics of the LDAP filter the directory mode sends (prefix per
/// word on the word attributes, AND between words, typed wildcards, « contient », exact identifiers, explicit tokens, type).
/// Matching ignores accents and case. Pure.
/// </summary>
public static class SearchMatcher
{
    private static readonly char[] WordSeparators = [' ', '-'];

    /// <summary>True when the candidate is of the type asked (OU et conteneurs: OUs; containers are not listed).</summary>
    public static bool OfType(SearchCandidate candidate, SearchTypeFilter type)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        return type switch
        {
            SearchTypeFilter.Users => candidate.Kind == SearchObjectKind.User,
            SearchTypeFilter.Computers => candidate.Kind == SearchObjectKind.Computer,
            SearchTypeFilter.Groups => candidate.Kind == SearchObjectKind.Group,
            SearchTypeFilter.Ous => candidate.Kind == SearchObjectKind.Ou,
            SearchTypeFilter.Contacts => candidate.Kind == SearchObjectKind.Contact,
            _ => true,
        };
    }

    /// <summary>The predicate of a valid plan of the bar, for the given type of the bar.</summary>
    public static Func<SearchCandidate, bool> Compile(SearchPlan plan, SearchTypeFilter type)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (!plan.Valid)
        {
            return static _ => false;
        }
        switch (plan.Kind)
        {
            case SearchPlanKind.Identifier when plan.Identifier is SearchIdentifier exact:
                return c => OfType(c, type) && Exact(exact, c);
            case SearchPlanKind.Contains:
                {
                    var words = SearchText.Words(plan.FreeText).Distinct(StringComparer.Ordinal).Select(FrenchText.Fold).ToArray();
                    return c => OfType(c, type) && words.All(w => c.ContainsValues.Any(v => v.Contains(w, StringComparison.Ordinal)));
                }
            case SearchPlanKind.Browse:
                return c => OfType(c, type);
            case SearchPlanKind.Syntax:
                return SyntaxPredicate(plan, type);
            default:
                {
                    var words = SearchText.Words(plan.FreeText).Select(FrenchText.Fold).ToArray();
                    var loose = plan.Identifier is { Exact: false } identifier ? identifier : null;
                    return c => OfType(c, type) && ((words.Length > 0 && words.All(w => WordMatches(w, c))) || (loose is not null && Loose(loose, c)));
                }
        }
    }

    /// <summary>One word (folded): prefix of a word attribute, or the typed wildcard pattern (LDAP substring, open end).</summary>
    public static bool WordMatches(string word, SearchCandidate candidate)
    {
        ArgumentNullException.ThrowIfNull(word);
        ArgumentNullException.ThrowIfNull(candidate);
        if (!word.Contains('*', StringComparison.Ordinal))
        {
            return candidate.Folded.Any(v => v.Length > 0 && v.StartsWith(word, StringComparison.Ordinal));
        }
        var segments = word.Split('*');
        return candidate.Folded.Any(v => v.Length > 0 && Glob(v, segments));
    }

    /// <summary>
    /// Relevance (lower is better): exact identifier, exact name, identifier prefix, whole word of the name, name prefix, word
    /// prefix, substring, the rest (Domenia 1 Get-DomeniaSearchRank, D034). Accents and case ignored.
    /// </summary>
    public static int Rank(SearchCandidate candidate, string? query)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        return Rank(candidate.Sam, candidate.Upn, candidate.Name, candidate.Display, candidate.Mail, query);
    }

    /// <summary>Relevance of a display row (same rule as for a candidate).</summary>
    public static int Rank(SearchRow row, string? query)
    {
        ArgumentNullException.ThrowIfNull(row);
        return Rank(row.Login, row.Upn, row.Name, row.Display, row.Mail, query);
    }

    private static int Rank(string? samValue, string? upnValue, string nameValue, string? displayValue, string? mailValue, string? query)
    {
        var q = FrenchText.Fold((query ?? "").Trim().Trim('*'));
        if (q.Length == 0)
        {
            return 9;
        }
        var login = Fold(samValue);
        var upn = Fold(upnValue);
        var name = Fold(nameValue);
        var display = Fold(displayValue);
        var mail = Fold(mailValue);
        var upnUser = upn.Split('@')[0];
        if (login == q || upn == q || mail == q || (upn.Length > 0 && upnUser == q))
        {
            return 0;
        }
        if (name == q || display == q)
        {
            return 1;
        }
        if (Starts(login, q) || Starts(upn, q) || Starts(mail, q))
        {
            return 2;
        }
        var words = (name + " " + display).Split(WordSeparators, StringSplitOptions.RemoveEmptyEntries);
        if (words.Any(w => w == q))
        {
            return 3;
        }
        if (Starts(name, q) || Starts(display, q))
        {
            return 4;
        }
        if (words.Any(w => w.StartsWith(q, StringComparison.Ordinal)))
        {
            return 5;
        }
        if (new[] { login, name, display, upn, mail }.Any(v => v.Contains(q, StringComparison.Ordinal)))
        {
            return 6;
        }
        return 7;
    }

    /// <summary>
    /// Deduplicates by identity (GUID, else DN), never by label, then orders by relevance, name and arrival
    /// (Domenia 1 Sort-DomeniaSearchResults).
    /// </summary>
    public static ImmutableArray<(SearchCandidate Candidate, int Rank)> Sort(IEnumerable<SearchCandidate> candidates, string? query)
    {
        ArgumentNullException.ThrowIfNull(candidates);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var ranked = new List<(SearchCandidate Candidate, int Rank, int Position)>();
        var position = 0;
        foreach (var candidate in candidates)
        {
            var identity = candidate.Id != Guid.Empty ? candidate.Id.ToString("D") : "dn:" + candidate.Dn;
            if (identity == "dn:" || !seen.Add(identity))
            {
                continue;
            }
            ranked.Add((candidate, Rank(candidate, query), position++));
        }
        return [.. ranked.OrderBy(r => r.Rank).ThenBy(r => r.Candidate.NameKey, StringComparer.Ordinal).ThenBy(r => r.Position).Select(r => (r.Candidate, r.Rank))];
    }

    /// <summary>Administration account in a result list: adminCount = 1 or a naming rule (Domenia 1 Test-DomeniaAdminAccountRow).</summary>
    public static bool IsAdminAccount(int? adminCount, string? login)
    {
        if (adminCount == 1)
        {
            return true;
        }
        var value = (login ?? "").ToLowerInvariant();
        return value.StartsWith("adm-", StringComparison.Ordinal) || value.StartsWith("adm_", StringComparison.Ordinal) || value.StartsWith("adm.", StringComparison.Ordinal)
            || value.EndsWith("-adm", StringComparison.Ordinal) || value.EndsWith("_adm", StringComparison.Ordinal) || value.EndsWith(".adm", StringComparison.Ordinal)
            || value.StartsWith("admin", StringComparison.Ordinal);
    }

    private static Func<SearchCandidate, bool> SyntaxPredicate(SearchPlan plan, SearchTypeFilter barType)
    {
        var freeWords = SearchText.Words(plan.FreeText).Select(FrenchText.Fold).ToArray();
        var mails = plan.Tokens.Where(t => t.Kind == "Mail").Select(t => FrenchText.Fold(t.Value)).ToArray();
        var typed = plan.Tokens.Where(t => t.Kind != "Mail")
            .Select(t => (Type: SearchText.TypeOfKind(t.Kind), Words: SearchText.Words(t.Value).Select(FrenchText.Fold).ToArray())).ToArray();
        var kinds = typed.Select(t => t.Type).Distinct().ToArray();
        var bodyType = kinds.Length == 1 ? kinds[0] : barType;
        var hasBody = freeWords.Length > 0 || mails.Length > 0;
        return c =>
        {
            foreach (var token in typed)
            {
                if (OfType(c, token.Type) && token.Words.All(w => WordMatches(w, c)))
                {
                    return true;
                }
            }
            if (!hasBody || !OfType(c, bodyType))
            {
                return false;
            }
            var mail = c.Folded[7];
            return mails.All(m => mail.Length > 0 && Glob(mail, m.Split('*'))) && freeWords.All(w => WordMatches(w, c));
        };
    }

    private static bool Exact(SearchIdentifier identifier, SearchCandidate candidate) => identifier.Kind switch
    {
        SearchIdentifierKind.Guid => Guid.TryParse(identifier.Value, out var guid) && candidate.Id == guid,
        SearchIdentifierKind.Sid => string.Equals(candidate.Sid, identifier.Value, StringComparison.OrdinalIgnoreCase),
        SearchIdentifierKind.Dn => SameDn(candidate.Dn, identifier.Value),
        _ => false,
    };

    private static bool Loose(SearchIdentifier identifier, SearchCandidate candidate)
    {
        var value = FrenchText.Fold(identifier.Value);
        return identifier.Kind switch
        {
            SearchIdentifierKind.DownLevel => candidate.Folded[2] == value[(value.IndexOf('\\', StringComparison.Ordinal) + 1)..],
            SearchIdentifierKind.Upn => candidate.Folded[6] == value || candidate.Folded[7] == value,
            SearchIdentifierKind.Fqdn => candidate.Folded[8] == value,
            _ => false,
        };
    }

    private static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    /// <summary>LDAP substring semantics with an open end: the first segment anchors the start unless empty.</summary>
    private static bool Glob(string value, string[] segments)
    {
        var position = 0;
        for (var i = 0; i < segments.Length; i++)
        {
            var segment = segments[i];
            if (segment.Length == 0)
            {
                continue;
            }
            if (i == 0)
            {
                if (!value.StartsWith(segment, StringComparison.Ordinal))
                {
                    return false;
                }
                position = segment.Length;
                continue;
            }
            var at = value.IndexOf(segment, position, StringComparison.Ordinal);
            if (at < 0)
            {
                return false;
            }
            position = at + segment.Length;
        }
        return true;
    }

    private static bool Starts(string value, string prefix) => value.Length > 0 && value.StartsWith(prefix, StringComparison.Ordinal);

    private static string Fold(string? value) => value is null ? "" : FrenchText.Fold(value);
}
