using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core;

/// <summary>Limits of the search screen (Domenia 1 defaults: limit 100, at most 20 000, two characters at least).</summary>
public static class SearchLimits
{
    public const int DefaultLimit = 100;
    public const int MaxLimit = 20_000;
    public const int MinChars = 2;

    /// <summary>Longest text accepted from the page (a longer one is refused before any analysis).</summary>
    public const int MaxTextLength = 256;

    /// <summary>Results at or below which a « contient » search is offered (FO-01).</summary>
    public const int ContainsThreshold = 5;

    /// <summary>Lines of the suggestion list under the field.</summary>
    public const int Suggestions = 8;
}

/// <summary>Decision on a typed text before any read (Domenia 1 Get-DomeniaSearchTextCheck, CO-34).</summary>
public sealed record SearchTextCheck(bool Valid, bool Browse, string Reason, string Hint);

/// <summary>Optional explicit syntax of the bar, once read (Domenia 1 ConvertFrom-DomeniaSearchSyntax, D033).</summary>
public sealed record SearchSyntax(ImmutableArray<SearchToken> Tokens, string FreeText, SearchTypeFilter? Type, ImmutableArray<string> Notes, bool HasSyntax);

/// <summary>Filter built from a text: LDAP form, validity and cost (Domenia 1 ConvertTo-DomeniaSearchFilter).</summary>
public sealed record SearchFilterText(string Filter, bool Valid, string Reason, bool Costly);

/// <summary>
/// Pure rules of the text of the search bar, ported from Domenia 1 (Domenia-Search.Model.ps1): checks, optional syntax,
/// pasted identifiers, addresses, RFC 4515 literals and the LDAP filters the directory mode sends. Nothing here reads
/// anything: the plan says what will be searched before the operator presses Enter.
/// </summary>
public static partial class SearchText
{
    /// <summary>Attributes matched word by word (Domenia 1 Get-DomeniaWordFilter, plus « name » so that OUs and groups match too).</summary>
    public static readonly ImmutableArray<string> WordAttributes = ["name", "cn", "sAMAccountName", "displayName", "sn", "givenName", "userPrincipalName", "mail", "dNSHostName"];

    /// <summary>Attributes of a « contient » search (FO-01).</summary>
    public static readonly ImmutableArray<string> ContainsAttributes = ["name", "displayName", "sAMAccountName", "dNSHostName"];

    private static readonly FrozenPrefixes Prefixes = new();

    /// <summary>RFC 4515 escaping; with <paramref name="keepWildcard"/> a typed « * » stays a wildcard and repeated ones merge.</summary>
    public static string LdapLiteral(string? value, bool keepWildcard = false)
    {
        var builder = new StringBuilder();
        var previousWildcard = false;
        foreach (var c in value ?? "")
        {
            var wildcard = false;
            switch (c)
            {
                case '\0':
                    builder.Append("\\00");
                    break;
                case '(':
                    builder.Append("\\28");
                    break;
                case ')':
                    builder.Append("\\29");
                    break;
                case '*':
                    if (keepWildcard)
                    {
                        wildcard = true;
                        if (!previousWildcard)
                        {
                            builder.Append('*');
                        }
                    }
                    else
                    {
                        builder.Append("\\2a");
                    }
                    break;
                case '\\':
                    builder.Append("\\5c");
                    break;
                default:
                    builder.Append(c);
                    break;
            }
            previousWildcard = wildcard;
        }
        return builder.ToString();
    }

    /// <summary>True for a text made only of asterisks and spaces: it names no object and would list the whole perimeter.</summary>
    public static bool IsWildcardOnly(string? text)
    {
        var value = (text ?? "").Trim();
        return value.Length > 0 && value.All(c => c == '*' || char.IsWhiteSpace(c));
    }

    /// <summary>
    /// Can this text be searched? Global (bar): a text of asterisks only, or shorter than the minimum, is refused. OU: an
    /// empty or asterisk-only text lists the OU. Nothing is sent when <see cref="SearchTextCheck.Valid"/> is false.
    /// </summary>
    public static SearchTextCheck Check(string? text, bool ouMode = false, int minimum = SearchLimits.MinChars)
    {
        var value = (text ?? "").Trim();
        var min = Math.Max(1, minimum);
        var hint = ouMode
            ? "Saisissez au moins " + FrenchText.Integer(min) + " caractères, ou * pour lister toute l’OU."
            : "Saisissez au moins " + FrenchText.Integer(min) + " caractères" + FrenchText.Colon + "un nom, un identifiant, une adresse ou un poste.";
        if (value.Length == 0)
        {
            return new SearchTextCheck(ouMode, true, ouMode ? "" : hint, hint);
        }
        if (IsWildcardOnly(value))
        {
            return ouMode
                ? new SearchTextCheck(true, true, "", hint)
                : new SearchTextCheck(false, false, "Saisissez au moins un caractère en plus de *" + FrenchText.Colon + "une étoile seule listerait tout le domaine.", hint);
        }
        if (value.Replace("*", "", StringComparison.Ordinal).Trim().Length < min)
        {
            return new SearchTextCheck(false, false, hint, hint);
        }
        return new SearchTextCheck(true, false, "", hint);
    }

    /// <summary>Words are separated by white space only: hyphens, apostrophes and accents stay inside a word.</summary>
    public static ImmutableArray<string> Words(string? text) =>
        [.. (text ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)];

    /// <summary>LDAP filter of a type (same filters for the bar and the OU list).</summary>
    public static string TypeLdapFilter(SearchTypeFilter type) => type switch
    {
        SearchTypeFilter.Users => "(&(objectCategory=person)(objectClass=user))",
        SearchTypeFilter.Computers => "(objectCategory=computer)",
        SearchTypeFilter.Groups => "(objectCategory=group)",
        SearchTypeFilter.Ous => "(|(objectClass=organizationalUnit)(objectClass=container))",
        _ => "(|(objectCategory=person)(objectCategory=computer)(objectCategory=group)(objectClass=organizationalUnit))",
    };

    /// <summary>Label of a type for the operator.</summary>
    public static string TypeLabel(SearchTypeFilter type) => type switch
    {
        SearchTypeFilter.Users => "Personnes",
        SearchTypeFilter.Computers => "Postes",
        SearchTypeFilter.Groups => "Groupes",
        SearchTypeFilter.Ous => "OU",
        _ => "Tous les types",
    };

    /// <summary>
    /// utilisateur:, poste:, groupe: and mail: (and their short forms) are the only prefixes that refine the search; any other
    /// stays plain text and is explained. No hidden filter is ever added.
    /// </summary>
    public static SearchSyntax ParseSyntax(string? text)
    {
        var tokens = ImmutableArray.CreateBuilder<SearchToken>();
        var notes = ImmutableArray.CreateBuilder<string>();
        var free = new List<string>();
        foreach (Match match in SyntaxPattern().Matches((text ?? "").Trim()))
        {
            if (match.Groups["prefix"].Success)
            {
                var prefix = match.Groups["prefix"].Value.ToLowerInvariant();
                var value = match.Groups["quoted"].Success ? match.Groups["quoted"].Value : match.Groups["bare"].Value;
                if (Prefixes.TryKind(prefix, out var kind))
                {
                    if (string.IsNullOrWhiteSpace(value))
                    {
                        notes.Add("Jeton " + FrenchText.Quote(prefix + ":") + " sans valeur" + FrenchText.Colon + "ignoré.");
                        continue;
                    }
                    var trimmed = value.Trim();
                    tokens.Add(new SearchToken(prefix, kind, trimmed, KindLabel(kind) + FrenchText.Colon + trimmed));
                }
                else
                {
                    free.Add(match.Value);
                    notes.Add(FrenchText.Quote(prefix + ":") + " n’est pas un jeton reconnu" + FrenchText.Colon + "cherché comme texte.");
                }
                continue;
            }
            if (match.Groups["phrase"].Success)
            {
                if (match.Groups["phrase"].Value.Trim().Length > 0)
                {
                    free.Add(match.Groups["phrase"].Value.Trim());
                }
                continue;
            }
            free.Add(match.Groups["word"].Value);
        }
        var kinds = tokens.Where(t => t.Kind != "Mail").Select(t => t.Kind).Distinct(StringComparer.Ordinal).ToList();
        SearchTypeFilter? type = null;
        if (kinds.Count == 1)
        {
            type = TypeOfKind(kinds[0]);
        }
        else if (kinds.Count > 1)
        {
            notes.Add("Plusieurs types demandés" + FrenchText.Colon + "chaque jeton est cherché dans son type.");
        }
        return new SearchSyntax(tokens.ToImmutable(), string.Join(' ', free), type, notes.ToImmutable(), tokens.Count > 0);
    }

    /// <summary>Type of a token kind (« Utilisateur », « Machine », « Groupe »).</summary>
    public static SearchTypeFilter TypeOfKind(string kind) => kind switch
    {
        "Utilisateur" => SearchTypeFilter.Users,
        "Machine" => SearchTypeFilter.Computers,
        "Groupe" => SearchTypeFilter.Groups,
        _ => SearchTypeFilter.All,
    };

    /// <summary>Prefix match of one word on the word attributes; a leading wildcard only when the operator typed it.</summary>
    public static string WordFilter(string word)
    {
        ArgumentNullException.ThrowIfNull(word);
        var literal = LdapLiteral(word, keepWildcard: true);
        var suffix = literal.EndsWith('*') ? "" : "*";
        return "(|" + string.Concat(WordAttributes.Select(a => "(" + a + "=" + literal + suffix + ")")) + ")";
    }

    /// <summary>
    /// Filter of a free text and its tokens: every word must match (in any attribute); a word shorter than the minimum is
    /// refused (it would walk the whole domain); a leading wildcard is flagged as costly.
    /// </summary>
    public static SearchFilterText BuildFilter(string? text, SearchTypeFilter type, IReadOnlyList<SearchToken> tokens, int minimum = SearchLimits.MinChars)
    {
        ArgumentNullException.ThrowIfNull(tokens);
        var words = Words(text);
        var blocks = new List<string>();
        var tokenTypes = new List<string>();
        foreach (var token in tokens)
        {
            if (token.Value.Length == 0)
            {
                continue;
            }
            if (token.Kind == "Mail")
            {
                var literal = LdapLiteral(token.Value, keepWildcard: true);
                blocks.Add("(|(mail=" + literal + "*)(proxyAddresses=smtp:" + literal + "*))");
            }
            else
            {
                var inner = "(&" + string.Concat(Words(token.Value).Select(WordFilter)) + ")";
                tokenTypes.Add("(&" + TypeLdapFilter(TypeOfKind(token.Kind)) + inner + ")");
            }
        }
        var meaningful = words.Count(w => w.Replace("*", "", StringComparison.Ordinal).Length >= minimum);
        if (blocks.Count == 0 && tokenTypes.Count == 0)
        {
            if (words.Length == 0)
            {
                return new SearchFilterText("", false, "Saisissez un nom, un identifiant ou un jeton de recherche.", false);
            }
            if (meaningful == 0)
            {
                return new SearchFilterText("", false, "Saisissez au moins " + FrenchText.Integer(minimum) + " caractères" + FrenchText.Colon + "une recherche plus courte parcourrait tout le domaine.", true);
            }
        }
        blocks.AddRange(words.Select(WordFilter));
        var body = blocks.Count > 0 ? "(&" + TypeLdapFilter(type) + string.Concat(blocks) + ")" : "";
        if (tokenTypes.Count > 0)
        {
            var alternatives = new List<string>(tokenTypes);
            if (body.Length > 0)
            {
                alternatives.Add(body);
            }
            body = alternatives.Count == 1 ? alternatives[0] : "(|" + string.Concat(alternatives) + ")";
        }
        var costly = words.Any(w => w.StartsWith('*'));
        return new SearchFilterText(body, true, "", costly);
    }

    /// <summary>
    /// Pasted DN, GUID, SID, UPN, down-level name or FQDN. GUID, SID and DN become an exact search; the others are explained
    /// and searched with the other matches. Recognizing an identifier never opens a result by itself.
    /// </summary>
    public static SearchIdentifier? RecognizeIdentifier(string? text)
    {
        var value = (text ?? "").Trim();
        if (value.Length == 0 || (value.Any(char.IsWhiteSpace) && !DnStart().IsMatch(value)))
        {
            return null;
        }
        if (GuidPattern().IsMatch(value) && Guid.TryParse(value.Trim('{', '}'), out var guid))
        {
            var bytes = string.Concat(guid.ToByteArray().Select(b => "\\" + b.ToString("x2", CultureInfo.InvariantCulture)));
            return new SearchIdentifier(SearchIdentifierKind.Guid, guid.ToString("D"), "(objectGUID=" + bytes + ")", "GUID reconnu" + FrenchText.Colon + "recherche exacte de cet objet.", true);
        }
        if (SidPattern().IsMatch(value))
        {
            var sid = value.ToUpperInvariant();
            return new SearchIdentifier(SearchIdentifierKind.Sid, sid, "(objectSid=" + sid + ")", "SID reconnu" + FrenchText.Colon + "recherche exacte de ce compte.", true);
        }
        if (DnStart().IsMatch(value))
        {
            var rdns = SplitDn(value);
            if (rdns.Count >= 2 && rdns.All(r => RdnPattern().IsMatch(r)))
            {
                return new SearchIdentifier(SearchIdentifierKind.Dn, value, "(distinguishedName=" + LdapLiteral(value) + ")", "Nom distinctif reconnu" + FrenchText.Colon + "recherche exacte de cet objet.", true);
            }
        }
        if (DownLevelPattern().IsMatch(value))
        {
            var account = value[(value.IndexOf('\\', StringComparison.Ordinal) + 1)..];
            return new SearchIdentifier(SearchIdentifierKind.DownLevel, value, "(sAMAccountName=" + LdapLiteral(account) + ")",
                "Nom DOMAINE\\compte reconnu" + FrenchText.Colon + "l’identifiant est cherché dans le domaine connecté, avec les autres correspondances.", false);
        }
        if (UpnPattern().IsMatch(value))
        {
            var literal = LdapLiteral(value);
            return new SearchIdentifier(SearchIdentifierKind.Upn, value, "(|(userPrincipalName=" + literal + ")(mail=" + literal + "))",
                "Adresse reconnue" + FrenchText.Colon + "nom de connexion et messagerie cherchés, avec les autres correspondances.", false);
        }
        if (FqdnPattern().IsMatch(value))
        {
            return new SearchIdentifier(SearchIdentifierKind.Fqdn, value, "(dNSHostName=" + LdapLiteral(value) + ")",
                "Nom DNS complet reconnu" + FrenchText.Colon + "le poste est cherché avec les autres correspondances (un identifiant à points peut aussi être un compte).", false);
        }
        return null;
    }

    /// <summary>
    /// A text that is exactly an IPv4 or a MAC address (same separator throughout), normalized: « 00-1A-2B-3C-4D-5E ».
    /// A name, a partial address or an IPv6 address keeps the normal search (null).
    /// </summary>
    public static SearchAddress? ParseAddress(string? text)
    {
        var value = (text ?? "").Trim();
        if (value.Length == 0 || value.Any(char.IsWhiteSpace))
        {
            return null;
        }
        if (Ipv4Pattern().IsMatch(value))
        {
            return new SearchAddress("ipv4", value, "adresse IP", value);
        }
        string hex;
        if (MacSeparatedPattern().IsMatch(value))
        {
            hex = value.Replace(":", "", StringComparison.Ordinal).Replace("-", "", StringComparison.Ordinal);
        }
        else if (MacBarePattern().IsMatch(value))
        {
            hex = value;
        }
        else
        {
            return null;
        }
        hex = hex.ToUpperInvariant();
        var pairs = Enumerable.Range(0, 6).Select(i => hex.Substring(i * 2, 2));
        return new SearchAddress("mac", string.Join('-', pairs), "adresse MAC", value);
    }

    /// <summary>What the bar will do with a recognized address, before any read: no network scan is announced.</summary>
    public static string AddressHint(SearchAddress address)
    {
        ArgumentNullException.ThrowIfNull(address);
        return char.ToUpperInvariant(address.Label[0]) + address.Label[1..] + " reconnue (" + address.Value + ")" + FrenchText.Colon
            + "recherche dans les relevés locaux, sans scan réseau. Une adresse peut avoir changé depuis le relevé.";
    }

    /// <summary>Wording shown on every workstation found by an address; an unknown date is said, never invented.</summary>
    public static string AddressNotice(SearchAddress? address, DateTimeOffset? observedAt, string? addresses, TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(timeZone);
        var label = address?.Kind == "mac" ? "adresse MAC" : "adresse IP";
        var text = observedAt is DateTimeOffset at
            ? "adresse relevée le " + FrenchText.ShortDate(LocalDays.DateOf(at, timeZone))
            : "adresse relevée à une date inconnue";
        text += " · " + label;
        if (!string.IsNullOrWhiteSpace(addresses))
        {
            text += " " + addresses.Trim();
        }
        return text;
    }

    /// <summary>
    /// « contient » filter (FO-01): each of one to four words of two characters at least appears inside the name, the display
    /// name, the account or the DNS name; the words are literals (a typed « * » is a character here).
    /// </summary>
    public static (bool Valid, string Filter, ImmutableArray<string> Words, string Reason) ContainsFilter(string? text, SearchTypeFilter type)
    {
        var words = Words(text).Distinct(StringComparer.Ordinal).ToImmutableArray();
        if (words.Length is 0 or > 4)
        {
            return (false, "", [], "Saisissez de un à quatre mots pour chercher les noms qui les contiennent.");
        }
        var blocks = new List<string>();
        foreach (var word in words)
        {
            if (word.Replace("*", "", StringComparison.Ordinal).Length < 2)
            {
                return (false, "", [], "Chaque mot doit compter au moins 2 caractères pour chercher les noms qui le contiennent.");
            }
            var literal = LdapLiteral(word);
            blocks.Add("(|" + string.Concat(ContainsAttributes.Select(a => "(" + a + "=*" + literal + "*)")) + ")");
        }
        var inner = blocks.Count == 1 ? blocks[0] : "(&" + string.Concat(blocks) + ")";
        return (true, "(&" + TypeLdapFilter(type) + inner + ")", words, "");
    }

    /// <summary>
    /// Plan of a text of the bar, without any read: address (local readings), exact identifier, explicit syntax, « contient »,
    /// or default prefix search. The LDAP filter is the one the directory mode sends; the hint explains it to the operator.
    /// </summary>
    public static SearchPlan Plan(string? text, SearchTypeFilter type, SearchMatchMode match, int minimum = SearchLimits.MinChars, bool syntaxEnabled = true)
    {
        var value = (text ?? "").Trim();
        var check = Check(value, ouMode: false, minimum);
        if (!check.Valid)
        {
            return Invalid(check.Reason, value);
        }
        var typeFilter = TypeLdapFilter(type);
        if (match == SearchMatchMode.Contains)
        {
            var contains = ContainsFilter(value, type);
            return contains.Valid
                ? new SearchPlan(SearchPlanKind.Contains, true, "", "Noms qui contiennent " + string.Join(" et ", contains.Words.Select(FrenchText.Quote))
                    + FrenchText.Colon + "plus lent, l’annuaire parcourt tous les noms du périmètre.", [], [], null, null, contains.Filter, true, value)
                : Invalid(contains.Reason, value);
        }
        if (ParseAddress(value) is SearchAddress address)
        {
            return new SearchPlan(SearchPlanKind.Address, true, "", AddressHint(address), [], [], null, address, "", false, value);
        }
        var notes = ImmutableArray.CreateBuilder<string>();
        SearchIdentifier? identifier = null;
        if (syntaxEnabled)
        {
            identifier = RecognizeIdentifier(value);
            if (identifier is { Exact: true })
            {
                return new SearchPlan(SearchPlanKind.Identifier, true, "", identifier.Explanation + " Aucun résultat n’est ouvert automatiquement.", [], [], identifier,
                    null, "(&" + typeFilter + identifier.LdapFilter + ")", false, value);
            }
            if (identifier is not null)
            {
                notes.Add(identifier.Explanation);
            }
            var syntax = ParseSyntax(value);
            if (syntax.HasSyntax)
            {
                var built = BuildFilter(syntax.FreeText, syntax.Type ?? type, syntax.Tokens, minimum);
                var labels = string.Join(" · ", syntax.Tokens.Select(t => t.Label));
                if (!built.Valid)
                {
                    return new SearchPlan(SearchPlanKind.Syntax, false, built.Reason, "Jetons" + FrenchText.Colon + labels + " · " + built.Reason, syntax.Notes, syntax.Tokens,
                        identifier, null, "", built.Costly, syntax.FreeText);
                }
                var hint = "Jetons" + FrenchText.Colon + labels;
                if (syntax.FreeText.Length > 0)
                {
                    hint += " · texte" + FrenchText.Colon + syntax.FreeText;
                }
                foreach (var note in syntax.Notes)
                {
                    hint += " · " + note;
                }
                return new SearchPlan(SearchPlanKind.Syntax, true, "", hint, syntax.Notes, syntax.Tokens, identifier, null, "(&" + typeFilter + built.Filter + ")", built.Costly, syntax.FreeText);
            }
            notes.AddRange(syntax.Notes);
        }
        if (value.Contains('*', StringComparison.Ordinal) && Words(value).Any(w => w.StartsWith('*')))
        {
            notes.Add("Joker en tête" + FrenchText.Colon + "recherche par sous-chaîne, sans index. Elle peut être longue sur un grand domaine ; préférez le début du nom.");
        }
        var filter = BuildFilter(value, type, [], minimum);
        if (!filter.Valid)
        {
            return Invalid(filter.Reason, value);
        }
        var ldap = identifier is null ? filter.Filter : "(|(&" + typeFilter + identifier.LdapFilter + ")" + filter.Filter + ")";
        return new SearchPlan(SearchPlanKind.Default, true, "", string.Join(' ', notes), notes.ToImmutable(), [], identifier, null, ldap, filter.Costly, value);
    }

    private static readonly char[] SimpleBreaks = [' ', '*', '(', ')', '\t'];

    /// <summary>
    /// A simple search (Domenia 1 RCH-055): one word typed as is, no space, no wildcard, no parenthesis, no token, no
    /// identifier. Only such a search shows the rows of the local base while the directory read goes on.
    /// </summary>
    public static bool IsSimple(SearchPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var text = plan.FreeText.Trim();
        return plan.Valid && plan.Kind == SearchPlanKind.Default && plan.Tokens.IsEmpty && plan.Identifier is null && text.Length > 0
            && text.IndexOfAny(SimpleBreaks) < 0;
    }

    /// <summary>Plan of an OU list (browse): the type only, no hidden term (the term goes to the visible local filter).</summary>
    public static SearchPlan BrowsePlan(SearchTypeFilter type) =>
        new(SearchPlanKind.Browse, true, "", "Contenu de l’OU, sans filtre caché" + FrenchText.Colon + "un terme saisi filtre seulement les lignes chargées.",
            [], [], null, null, TypeLdapFilter(type), false, "");

    /// <summary>Splits a DN on unescaped, unquoted commas (escaped commas stay inside their RDN).</summary>
    public static IReadOnlyList<string> SplitDn(string? dn)
    {
        var text = dn ?? "";
        var parts = new List<string>();
        var start = 0;
        var escaped = false;
        var quoted = false;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (escaped)
            {
                escaped = false;
                continue;
            }
            if (c == '\\')
            {
                escaped = true;
                continue;
            }
            if (c == '"')
            {
                quoted = !quoted;
                continue;
            }
            if (c == ',' && !quoted)
            {
                parts.Add(text[start..i].Trim());
                start = i + 1;
            }
        }
        if (start < text.Length)
        {
            parts.Add(text[start..].Trim());
        }
        return [.. parts.Where(p => p.Length > 0)];
    }

    private static string KindLabel(string kind) => kind switch
    {
        "Utilisateur" => "Utilisateur",
        "Machine" => "Poste",
        "Groupe" => "Groupe",
        _ => "Mail",
    };

    private static SearchPlan Invalid(string reason, string text) => new(SearchPlanKind.Default, false, reason, reason, [], [], null, null, "", false, text);

    [GeneratedRegex(@"(?<prefix>\p{L}+):[ \t\u00A0]?(?:""(?<quoted>[^""]*)""|(?<bare>\S*))|""(?<phrase>[^""]*)""|(?<word>\S+)", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex SyntaxPattern();

    [GeneratedRegex(@"^(?i)(CN|OU|DC)=", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex DnStart();

    [GeneratedRegex(@"^(?i)(CN|OU|DC)=\S", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex RdnPattern();

    [GeneratedRegex(@"^\{?[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}?$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex GuidPattern();

    [GeneratedRegex(@"^(?i)S-1-\d+(-\d+){1,14}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex SidPattern();

    [GeneratedRegex(@"^[^\\/\s@]+\\[^\\/\s@]+$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex DownLevelPattern();

    [GeneratedRegex(@"^[^@\s]+@[^@\s]+\.[^@\s.]+$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex UpnPattern();

    [GeneratedRegex(@"^(?i)[a-z0-9]([a-z0-9-]{0,62})(\.[a-z0-9]([a-z0-9-]{0,62})){2,}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex FqdnPattern();

    [GeneratedRegex(@"^(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])(?:\.(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])){3}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex Ipv4Pattern();

    [GeneratedRegex(@"^[0-9A-Fa-f]{2}([:-])([0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex MacSeparatedPattern();

    [GeneratedRegex(@"^[0-9A-Fa-f]{12}$", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex MacBarePattern();

    /// <summary>Known prefixes of the optional syntax and the kind each one asks for.</summary>
    private sealed class FrozenPrefixes
    {
        private readonly Dictionary<string, string> kinds = new(StringComparer.Ordinal)
        {
            ["utilisateur"] = "Utilisateur",
            ["user"] = "Utilisateur",
            ["u"] = "Utilisateur",
            ["poste"] = "Machine",
            ["pc"] = "Machine",
            ["machine"] = "Machine",
            ["ordinateur"] = "Machine",
            ["groupe"] = "Groupe",
            ["group"] = "Groupe",
            ["g"] = "Groupe",
            ["mail"] = "Mail",
            ["email"] = "Mail",
            ["courriel"] = "Mail",
        };

        public bool TryKind(string prefix, out string kind)
        {
            if (kinds.TryGetValue(prefix, out var found))
            {
                kind = found;
                return true;
            }
            kind = "";
            return false;
        }
    }
}
