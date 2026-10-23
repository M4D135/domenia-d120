using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Object type of a search row (docs/ops/rechercher.md § 2). JSON: « user », « computer », « group », « ou ».</summary>
public enum SearchObjectKind
{
    User,
    Computer,
    Group,
    Ou,
    Contact,
}

/// <summary>Type selector of the bar and of the OU list (Domenia 1 Get-DomeniaTypeFilter, Get-DomeniaSearchBarTypes).</summary>
public enum SearchTypeFilter
{
    All,
    Users,
    Computers,
    Groups,
    Ous,
    Contacts,
}

/// <summary>How the words of the text are matched: start of the values (default) or anywhere (« contient », FO-01).</summary>
public enum SearchMatchMode
{
    Prefix,
    Contains,
}

/// <summary>What produced a list: the bar, an OU, a ready-made view, an address, a local query.</summary>
public enum SearchListKind
{
    Search,
    Browse,
    View,
    Address,
    LocalQuery,
    /// <summary>The frozen selection of the query workshop (REQ-048): the matching objects of a preview, by GUID.</summary>
    Selection,
}

/// <summary>How the text of the bar refines the search (Domenia 1 Get-DomeniaGlobalSearchPlan).</summary>
public enum SearchPlanKind
{
    Default,
    Identifier,
    Syntax,
    Contains,
    Address,
    Browse,
    View,
    LocalQuery,
    Selection,
}

/// <summary>Identifier recognized in a pasted text (Domenia 1 Get-DomeniaPastedIdentifier).</summary>
public enum SearchIdentifierKind
{
    None,
    Guid,
    Sid,
    Dn,
    DownLevel,
    Upn,
    Fqdn,
}

/// <summary>Presence key of a workstation (Domenia 1 FI-16 keys: Online, NoReply, Error, Unknown).</summary>
public enum SearchPresenceState
{
    Online,
    NoReply,
    Error,
    Unknown,
}

/// <summary>One explicit token of the optional syntax (« utilisateur: dupont »).</summary>
public sealed record SearchToken(string Prefix, string Kind, string Value, string Label);

/// <summary>Identifier recognized in the text; <see cref="Exact"/> for GUID, SID and DN (the filter is replaced).</summary>
public sealed record SearchIdentifier(SearchIdentifierKind Kind, string Value, string LdapFilter, string Explanation, bool Exact);

/// <summary>IPv4 or MAC address typed in the bar, normalized for the local read (R40).</summary>
public sealed record SearchAddress(string Kind, string Value, string Label, string Original);

/// <summary>
/// What the engine will do with a text, decided without any read: kind, validity, hint for the operator, tokens,
/// identifier, address, and the LDAP filter the directory mode sends (shown in a folded detail, never hidden).
/// </summary>
public sealed record SearchPlan(
    SearchPlanKind Kind,
    bool Valid,
    string Reason,
    string Hint,
    ImmutableArray<string> Notes,
    ImmutableArray<SearchToken> Tokens,
    SearchIdentifier? Identifier,
    SearchAddress? Address,
    string LdapFilter,
    bool Costly,
    string FreeText);

/// <summary>Perimeter of a list as the operator reads it (« Partout · domaine entier », « Dans « Paris » · sous-OU incluses »).</summary>
public sealed record SearchScopeInfo(string Mode, string Dn, string Label, string Path, bool Subtree, bool WholeDomain, string Chip);

/// <summary>State of an account or object, with its tone (Actif, Désactivé, Verrouillé, Mot de passe expiré…).</summary>
public sealed record SearchState(string Key, string Label, Tone Tone);

/// <summary>Flags read by the quick filters of the list; every one is a rule of Domenia 1 (docs/ops/rechercher.md § 2.2).</summary>
public sealed record SearchFlags(
    bool Disabled,
    bool Locked,
    bool LockToCheck,
    bool PasswordExpired,
    bool PasswordNeverExpires,
    bool PasswordNotRequired,
    bool MustChange,
    bool Inactive,
    bool NeverLoggedOn,
    bool Admin,
    bool AccountExpiring,
    bool AccountExpired);

/// <summary>Last presence reading of a workstation, as the list shows it: a missing answer is never a verdict.</summary>
public sealed record SearchPresence(SearchPresenceState State, string Label, Tone Tone, DateTimeOffset? CheckedAt, DateTimeOffset? LastOnlineAt, string Detail);

/// <summary>Console user of a workstation (CIM in directory mode); <see cref="State"/> « seen », « none » or « unknown ».</summary>
public sealed record SearchConsole(string State, string Label, string? User, string? Login, string? UserDn, DateTimeOffset? At);

/// <summary>Remembered association between a workstation and a user, with its source and qualification (DS-20).</summary>
public sealed record SearchAssociation(string Label, string? Dn, string Source, string Qualification, string Note);

/// <summary>Address of a workstation found in the local readings (R40), with the date of the reading.</summary>
public sealed record SearchAddressReading(string? Ip, string? Mac, DateTimeOffset? ObservedAt, string Notice);

/// <summary>Group details shown in the list.</summary>
public sealed record SearchGroupInfo(string ScopeLabel, int Members);

/// <summary>Canonical display row of a directory object (Domenia 1 ConvertTo-DomeniaDirectoryDisplayRow, RCH-072).</summary>
public sealed record SearchRow(
    string Id,
    SearchObjectKind Kind,
    string KindLabel,
    string Name,
    string? Display,
    string? Login,
    string? Upn,
    string? Mail,
    string? Description,
    string Dn,
    string Container,
    SearchState State,
    SearchFlags Flags,
    string? Os,
    string? OsVersion,
    DateTimeOffset? LastLogon,
    DateTimeOffset? Changed,
    DateTimeOffset? Created,
    DateTimeOffset ReadAt,
    SearchPresence? Presence,
    SearchConsole? Console,
    SearchAssociation? Association,
    SearchAddressReading? Address,
    SearchGroupInfo? Group,
    string? Verdict,
    int Rank);

/// <summary>« Charger la suite » decision (Domenia 1 Get-DomeniaContinuationDecision, MO-07).</summary>
public sealed record SearchContinuation(bool Allowed, int NextLimit, int Page, int JumpLimit, string? JumpText, string Reason);

/// <summary>Offer of a « contient » search after few results (FO-01): the read starts on its click only.</summary>
public sealed record SearchContainsOffer(string Term, string Label, string Tip);

/// <summary>Offer of an explicit reverse DNS lookup after an IPv4 found nothing locally (R40).</summary>
public sealed record SearchDnsOffer(string Ip, string Label, string Tip);

/// <summary>Ready-made view behind a list (work views of Domenia 1, D038).</summary>
public sealed record SearchViewInfo(string Id, string Name, string Note, bool WholeDomain, bool SurveyAllowed, string Reason);

/// <summary>
/// Totals of a local query (Correspondants, Inconnus, Non correspondants), and its coverage (RCH-120): the date since which
/// every workstation of the perimeter has a reading (last complete read covering it), or null with the reason in
/// <see cref="Coverage"/>.
/// </summary>
public sealed record SearchVerdictTotals(int Match, int Unknown, int NoMatch, string Shown, DateTimeOffset? CompleteAt = null, string Coverage = "");

/// <summary>
/// Last explicit list read again with its own filter, perimeter, type and size (RCH-047, RCH-048): rows read now, objects
/// new in the perimeter, objects moved out of it (followed by their GUID) and objects not found again (never a proof of
/// deletion), with the checkpoint of this read.
/// </summary>
public sealed record SearchReconcile(
    string ListId,
    ImmutableArray<SearchRow> Rows,
    ImmutableArray<string> Added,
    ImmutableArray<string> Moved,
    ImmutableArray<string> Missing,
    int Loaded,
    string Checkpoint,
    DateTimeOffset ReadAt,
    string Summary);

/// <summary>A saved search of Domenia 1 (bloc Fiabilité retiré), as its settings file keeps it (RCH-004).</summary>
public sealed record SearchLegacySaved(string Mode, string Dn, string? Name, bool Subtree, SearchTypeFilter Type, string? Query);

/// <summary>Stored measures of a list read again from the local base, by pages of 250 (RCH-083).</summary>
public sealed record SearchMeasures(ImmutableArray<SearchRow> Rows, int Offset, int? Next, int Total, DateTimeOffset ReadAt);

/// <summary>Fiche of one object read again on its selection (RCH-129), to refresh its row (RCH-077).</summary>
public sealed record SearchPreload(SearchRow Row, string SourceLabel, DateTimeOffset ReadAt);

/// <summary>Result of every list operation (search.run, search.browse, search.view, search.more, search.localQuery).</summary>
public sealed record SearchResult(
    string ListId,
    SearchListKind Kind,
    SearchScopeInfo Scope,
    SearchTypeFilter Type,
    string Text,
    SearchMatchMode Match,
    SearchPlan Plan,
    ImmutableArray<SearchRow> Rows,
    int Loaded,
    int Limit,
    bool Complete,
    bool LimitReached,
    SearchContinuation Continuation,
    string Counter,
    string Absence,
    SearchContainsOffer? Offer,
    SearchDnsOffer? Dns,
    SearchViewInfo? View,
    SearchVerdictTotals? Verdicts,
    string SourceLabel,
    DateTimeOffset ReadAt,
    bool Appended);

/// <summary>One line under the search field: a recent entry or an object of the local base (never a directory request).</summary>
public sealed record SearchSuggestion(string Source, string Text, string Label, string Detail, SearchObjectKind? Kind, string? Dn);

/// <summary>One fact of the local preview, with the date of the value (« Date non confirmée » when unknown).</summary>
public sealed record SearchPreviewItem(string Label, string Value, string Date, Tone? Tone, bool Mono);

/// <summary>A section of the local preview (identity, directory attributes, presence, console, inventory, addresses).</summary>
public sealed record SearchPreviewSection(string Id, string Title, ImmutableArray<SearchPreviewItem> Items);

/// <summary>Stored fiche of one object, read from the local base only (RCH-001).</summary>
public sealed record SearchPreview(SearchRow Row, ImmutableArray<SearchPreviewSection> Sections, string Source, int Attributes, bool Truncated);

/// <summary>One value of a comparison column, with its own date.</summary>
public sealed record SearchComparisonValue(string Text, string Date, bool Known);

/// <summary>One property compared between two to eight objects; <see cref="Difference"/> same, different, dateOnly, unknown.</summary>
public sealed record SearchComparisonLine(string Family, string Property, string Comparison, string Difference, ImmutableArray<SearchComparisonValue> Values);

/// <summary>Comparison table (RCH-002), extended to users: objects of one kind only.</summary>
public sealed record SearchComparison(SearchObjectKind Kind, ImmutableArray<SearchRow> Objects, ImmutableArray<SearchComparisonLine> Lines, int Different, int Same, int Unknown, string Summary);

/// <summary>Entry of the catalog of ready-made views and local queries (RCH-118, 120).</summary>
public sealed record SearchCatalogEntry(
    string Id,
    string Name,
    string Category,
    string Source,
    string TypeLabel,
    string Description,
    string Cost,
    string LdapFilter,
    bool Favorite,
    bool Local);

/// <summary>Catalog of the ready-made views and local queries, with the query favorites of the operator.</summary>
public sealed record SearchCatalog(ImmutableArray<SearchCatalogEntry> Entries, int Favorites, string Note);

/// <summary>A container of the domain root (not an OU): « Users », « Computers », or a system container folded apart (UI-16).</summary>
public sealed record SearchContainer(string Dn, string Name, bool System, int Objects);

/// <summary>Well-known containers of the domain root (Domenia 1 Get-DomeniaSystemContainerNames, Test-DomeniaSystemContainer).</summary>
public static class SearchContainers
{
    /// <summary>System containers folded under « Conteneurs système »; Users and Computers stay visible.</summary>
    public static readonly ImmutableArray<string> SystemNames =
        ["System", "Program Data", "ForeignSecurityPrincipals", "LostAndFound", "Infrastructure", "NTDS Quotas", "TPM Devices", "Keys", "Managed Service Accounts", "Builtin"];

    /// <summary>True for a well-known system container placed directly under the domain root; an OU never is.</summary>
    public static bool IsSystem(string dn, string rootDn)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(rootDn);
        try
        {
            var names = DistinguishedName.Parse(dn);
            var parent = DistinguishedName.Parent(dn);
            return names.Length > 0 && string.Equals(names[0].Type, "CN", StringComparison.OrdinalIgnoreCase)
                && parent is not null && DistinguishedName.AreEqual(parent, rootDn)
                && SystemNames.Contains(names[0].Value, StringComparer.OrdinalIgnoreCase);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
