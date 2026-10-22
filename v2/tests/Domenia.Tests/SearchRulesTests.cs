using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Pure rules of the search screen (text, plan, ranking, lists, surveys, memory), ported from Domenia 1.</summary>
internal static class SearchRulesTests
{
    private const string Root = "DC=example,DC=local";

    private static SearchCandidate Person(string name, string sam, string? mail = null)
    {
        var space = name.IndexOf(' ', StringComparison.Ordinal);
        return new(SearchObjectKind.User, Fixtures.IdOf(name), null, $"CN={name},OU=Utilisateurs,{Root}", name, name, sam, name,
            space > 0 ? name[..space] : null, space > 0 ? name[(space + 1)..] : null, sam + "@example.local", mail, null, name);
    }

    [Test]
    public static void The_bar_refuses_short_texts_and_lone_wildcards_before_any_read()
    {
        Check.False(SearchText.Check("a").Valid, "un seul caractère");
        Check.False(SearchText.Check("*").Valid, "étoile seule");
        Check.Contains("étoile seule", SearchText.Check("**").Reason, "raison de l’étoile seule");
        Check.False(SearchText.Check("*a").Valid, "joker et une lettre");
        Check.True(SearchText.Check("ma").Valid, "deux caractères");
        Check.True(SearchText.Check("", ouMode: true).Valid, "OU sans texte : contenu de l’OU");
        Check.True(SearchText.Check("*", ouMode: true).Browse, "OU avec * : contenu de l’OU");
        Check.False(SearchText.Plan("a", SearchTypeFilter.All, SearchMatchMode.Prefix).Valid, "aucun plan pour un caractère");
    }

    [Test]
    public static void Ldap_literals_follow_rfc_4515_and_keep_typed_wildcards_only_when_asked()
    {
        Check.Equal("a\\2a\\28b\\29\\5c", SearchText.LdapLiteral("a*(b)\\"), "échappement");
        Check.Equal("a*b", SearchText.LdapLiteral("a**b", keepWildcard: true), "jokers fusionnés");
        Check.Equal("\\00", SearchText.LdapLiteral("\0"), "caractère nul");
        Check.Equal("(|(name=dup*)(cn=dup*)(sAMAccountName=dup*)(displayName=dup*)(sn=dup*)(givenName=dup*)(userPrincipalName=dup*)(mail=dup*)(dNSHostName=dup*))",
            SearchText.WordFilter("dup"), "filtre d’un mot");
    }

    [Test]
    public static void Addresses_are_recognized_exactly_and_normalized()
    {
        var ip = SearchText.ParseAddress("10.10.1.12");
        Check.Equal("ipv4", ip?.Kind, "IPv4");
        var mac = SearchText.ParseAddress("00:1a:2b:3c:4d:5e");
        Check.Equal("00-1A-2B-3C-4D-5E", mac?.Value, "MAC normalisée");
        Check.Equal("00-1A-2B-3C-4D-5E", SearchText.ParseAddress("001A2B3C4D5E")?.Value, "MAC sans séparateur");
        Check.Null(SearchText.ParseAddress("00:1a-2b:3c:4d:5e"), "séparateurs mélangés");
        Check.Null(SearchText.ParseAddress("10.10.1"), "adresse partielle");
        Check.Null(SearchText.ParseAddress("10.10.1.256"), "octet hors bornes");
        var plan = SearchText.Plan("10.10.1.12", SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.Equal(SearchPlanKind.Address, plan.Kind, "plan d’adresse");
        Check.Equal("", plan.LdapFilter, "aucune requête d’annuaire pour une adresse");
        Check.Contains("sans scan réseau", plan.Hint, "aucun scan annoncé");
        Check.True(plan.Hint.StartsWith("Adresse IP reconnue", StringComparison.Ordinal), "libellé sans répétition : " + plan.Hint);
    }

    [Test]
    public static void Pasted_identifiers_become_exact_searches_without_opening_anything()
    {
        var guid = SearchText.Plan("{6F9619FF-8B86-D011-B42D-00C04FC964FF}", SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.Equal(SearchPlanKind.Identifier, guid.Kind, "GUID");
        Check.Contains("(objectGUID=\\ff\\19\\96\\6f\\86\\8b\\11\\d0", guid.LdapFilter, "octets du GUID");
        Check.Contains("Aucun résultat n’est ouvert automatiquement", guid.Hint, "rien d’ouvert");
        var sid = SearchText.Plan("s-1-5-21-1-2-3-1104", SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.Equal(SearchIdentifierKind.Sid, sid.Identifier?.Kind, "SID");
        Check.Contains("(objectSid=S-1-5-21-1-2-3-1104)", sid.LdapFilter, "SID en majuscules");
        var dn = SearchText.Plan("CN=Martine Dufour,OU=Lyon,OU=Utilisateurs," + Root, SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.Equal(SearchIdentifierKind.Dn, dn.Identifier?.Kind, "DN avec espaces non coupé");
        var upn = SearchText.Plan("m.dufour@example.local", SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.Equal(SearchPlanKind.Default, upn.Kind, "UPN cherché avec les autres correspondances");
        Check.Contains("(userPrincipalName=m.dufour@example.local)", upn.LdapFilter, "UPN exact en plus");
    }

    [Test]
    public static void The_optional_syntax_refines_without_hidden_filters()
    {
        var plan = SearchText.Plan("poste:pc-lyo", SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.Equal(SearchPlanKind.Syntax, plan.Kind, "jeton poste:");
        Check.Equal(1, plan.Tokens.Length, "un jeton");
        Check.Contains("(objectCategory=computer)", plan.LdapFilter, "type du jeton");
        var unknown = SearchText.Plan("foo:bar", SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.Equal(SearchPlanKind.Default, unknown.Kind, "préfixe inconnu cherché comme texte");
        Check.True(unknown.Notes.Any(n => n.Contains("n’est pas un jeton reconnu", StringComparison.Ordinal)), "préfixe inconnu expliqué");
        var empty = SearchText.ParseSyntax("utilisateur: martin");
        Check.True(empty.Notes.Any(n => n.Contains("sans valeur", StringComparison.Ordinal)), "jeton vide ignoré et dit");
        var mixed = SearchText.ParseSyntax("utilisateur:martin poste:pc");
        Check.Null(mixed.Type, "plusieurs types : aucun type unique");
    }

    [Test]
    public static void Leading_wildcards_and_contains_are_flagged_as_costly()
    {
        var wild = SearchText.Plan("*pont", SearchTypeFilter.All, SearchMatchMode.Prefix);
        Check.True(wild.Costly, "joker en tête coûteux");
        Check.True(wild.Notes.Any(n => n.StartsWith("Joker en tête", StringComparison.Ordinal)), "joker en tête expliqué");
        var contains = SearchText.Plan("pont", SearchTypeFilter.Users, SearchMatchMode.Contains);
        Check.Equal(SearchPlanKind.Contains, contains.Kind, "contient");
        Check.True(contains.Costly, "contient coûteux");
        Check.Contains("(name=*pont*)", contains.LdapFilter, "sous-chaîne");
        Check.False(SearchText.Plan("a b", SearchTypeFilter.All, SearchMatchMode.Contains).Valid, "mots trop courts refusés");
        Check.False(SearchText.ContainsFilter("un deux trois quatre cinq", SearchTypeFilter.All).Valid, "cinq mots refusés");
    }

    [Test]
    public static void Ranking_puts_exact_logins_first_like_domenia_1()
    {
        var exact = Person("Paul Martin", "martin");
        var mail = Person("Martine Dufour", "m.dufour", "martine.dufour@example.local");
        var word = Person("Jean Saint-Martin", "j.saint");
        var start = Person("Martinez Paul", "p.martinez2");
        var inside = Person("Lamartine Hugo", "h.lam");
        Check.Equal(0, SearchMatcher.Rank(exact, "martin"), "compte exact");
        Check.Equal(2, SearchMatcher.Rank(mail, "martin"), "courriel qui commence");
        Check.Equal(3, SearchMatcher.Rank(word, "martin"), "mot exact du nom (tiret séparateur)");
        Check.Equal(4, SearchMatcher.Rank(start, "Martin"), "nom qui commence");
        Check.Equal(6, SearchMatcher.Rank(inside, "martin"), "contenu");
        Check.Equal(9, SearchMatcher.Rank(inside, "  "), "sans requête");
        var sorted = SearchMatcher.Sort([inside, start, word, mail, exact, exact], "martin");
        Check.Equal(5, sorted.Length, "doublon retiré");
        Check.Equal("Paul Martin", sorted[0].Candidate.Name, "premier");
        Check.Equal("Lamartine Hugo", sorted[^1].Candidate.Name, "dernier");
    }

    [Test]
    public static void Words_match_by_prefix_on_folded_attributes()
    {
        var hugo = Person("Hélène Durand", "h.durand");
        Check.True(SearchMatcher.WordMatches("hel", hugo), "accents repliés");
        Check.True(SearchMatcher.WordMatches("h*rand", hugo), "joker interne");
        Check.False(SearchMatcher.WordMatches("rand", hugo), "pas de sous-chaîne sans joker");
        var plan = SearchText.Plan("hel dur", SearchTypeFilter.All, SearchMatchMode.Prefix);
        var predicate = SearchMatcher.Compile(plan, SearchTypeFilter.All);
        Check.True(predicate(hugo), "tous les mots");
        Check.False(SearchMatcher.Compile(plan, SearchTypeFilter.Computers)(hugo), "type exclu");
        Check.True(SearchMatcher.IsAdminAccount(null, "adm-dupont"), "préfixe adm-");
        Check.True(SearchMatcher.IsAdminAccount(1, "x"), "adminCount");
        Check.False(SearchMatcher.IsAdminAccount(0, "madmin"), "faux ami");
    }

    [Test]
    public static void Continuation_doubles_the_list_and_stops_at_the_safety_maximum()
    {
        var next = SearchLists.Continuation(true, 100, 100);
        Check.True(next.Allowed, "suite permise");
        Check.Equal(200, next.NextLimit, "liste doublée");
        Check.Equal(100, next.Page, "lignes suivantes seulement");
        Check.Equal(1000, next.JumpLimit, "saut à 1 000");
        Check.Equal(20_000, SearchLists.Continuation(true, 5000, 5000).JumpLimit, "saut au maximum");
        Check.False(SearchLists.Continuation(true, SearchLimits.MaxLimit, SearchLimits.MaxLimit).Allowed, "maximum atteint");
        Check.False(SearchLists.Continuation(false, 100, 40).Allowed, "liste complète");
        Check.Contains("liste complète", SearchLists.Counter(19, 100, true), "compteur complet");
        Check.Contains("affinez ou chargez la suite", SearchLists.Counter(100, 100, false), "compteur limité");
        Check.Contains("affinez la recherche", SearchLists.Counter(20_000, 20_000, false), "compteur au maximum");
    }

    [Test]
    public static void The_contains_offer_follows_few_plain_results_only()
    {
        Check.NotNull(SearchLists.ContainsOffer("pont", SearchListKind.Search, SearchPlanKind.Default, SearchMatchMode.Prefix, 3, false), "peu de résultats");
        Check.Null(SearchLists.ContainsOffer("pont", SearchListKind.Search, SearchPlanKind.Default, SearchMatchMode.Prefix, 6, false), "assez de résultats");
        Check.Null(SearchLists.ContainsOffer("po*", SearchListKind.Search, SearchPlanKind.Default, SearchMatchMode.Prefix, 0, false), "joker saisi");
        Check.Null(SearchLists.ContainsOffer("pont", SearchListKind.Search, SearchPlanKind.Default, SearchMatchMode.Contains, 0, false), "déjà en mode contient");
        Check.Null(SearchLists.ContainsOffer("pont", SearchListKind.Browse, SearchPlanKind.Default, SearchMatchMode.Prefix, 0, false), "contenu d’OU");
        Check.Contains("ne prouve pas une absence", SearchLists.Absence("Domaine entier", SearchTypeFilter.All, false, 100), "absence bornée");
    }

    [Test]
    public static void Survey_details_say_profile_budgets_window_and_replaced_plan()
    {
        Check.Equal("Standard", SearchSurvey.Profile(null).Id, "profil par défaut");
        Check.Equal("Standard", SearchSurvey.Profile("inconnu").Id, "profil inconnu : Standard");
        var slow = SearchSurvey.Profile("SlowNetwork");
        Check.False(SearchSurvey.WindowOpen(slow, new DateTime(2026, 10, 21, 10, 0, 0)), "réseau lent : fermé un mercredi à 10 h");
        Check.True(SearchSurvey.WindowOpen(slow, new DateTime(2026, 10, 21, 13, 0, 0)), "ouvert à 13 h");
        Check.True(SearchSurvey.WindowOpen(slow, new DateTime(2026, 10, 24, 10, 0, 0)), "ouvert le samedi");
        Check.True(SearchSurvey.WindowOpen(SearchSurvey.Profile(null), new DateTime(2026, 10, 21, 10, 0, 0)), "Standard : à tout moment");
        var closed = SearchSurvey.Details(SurveyMode.Console, slow, false, null, false);
        Check.True(closed.Any(l => l.StartsWith("Hors fenêtre de collecte", StringComparison.Ordinal)), "hors fenêtre annoncé");
        Check.True(closed.Any(l => l.Contains("CIM", StringComparison.Ordinal)), "regroupement CIM annoncé");
        Check.True(closed.Any(l => l.StartsWith("Budget", StringComparison.Ordinal)), "budgets annoncés");
        var resume = new SurveyResume(new string('a', 32), SurveyMode.Ping, "Qui répond ?", 36, 48, DateTimeOffset.UnixEpoch, "");
        Check.True(SearchSurvey.Details(SurveyMode.Ping, SearchSurvey.Profile(null), true, resume, false).Any(l => l.Contains("sera remplacé", StringComparison.Ordinal)), "plan interrompu remplacé");
        Check.True(SearchSurvey.Details(SurveyMode.Ping, SearchSurvey.Profile(null), true, resume, true).Any(l => l.StartsWith("Reprise", StringComparison.Ordinal)), "reprise annoncée");
        var status = SearchSurvey.Status(SurveyMode.Analyse, 12, 48, 9, 1, 1, 10, 4, 36, SearchSurvey.Profile(null), finished: true);
        Check.Equal(7, status.Lines.Length, "sept lignes d’état");
        Check.Contains("12 sur 48", status.Lines[0], "résultats validés");
        Check.Contains("rejeté le compte distant", status.Lines[2], "source suspendue");
        Check.Contains("4", status.Lines[5], "requêtes CIM évitées");
        Check.Contains("36", status.Lines[6], "plan de reprise");
    }

    [Test]
    public static void Scope_labels_say_what_is_read()
    {
        var whole = SearchLists.Scope(true, Root, Root, "example.local", true);
        Check.True(whole.WholeDomain, "domaine entier");
        Check.Equal("Domaine entier", whole.Label, "libellé");
        var paris = SearchLists.Scope(false, "OU=Paris,OU=Postes," + Root, Root, "example.local", false);
        Check.Equal("ou", paris.Mode, "mode OU");
        Check.Contains("Paris", paris.Label, "nom de l’OU");
        Check.Contains("Enfants directs", paris.Label, "profondeur");
        Check.Contains("(dans Postes)", paris.Label, "parent qui distingue les homonymes");
        Check.True(SearchLists.IsRoot("dc=EXAMPLE,dc=local", Root), "racine sans casse");
        Check.False(SearchLists.IsRoot("not a dn", Root), "DN mal formé");
    }

    [Test]
    public static void Surveys_are_never_a_disguised_whole_domain_survey()
    {
        Check.Equal("empty", SearchSurvey.Admit(0, 500, false, false, false, false, false, false).Code, "liste vide");
        Check.Equal("ceiling", SearchSurvey.Admit(501, 500, false, true, false, true, false, false).Code, "plafond");
        Check.Equal("globalWithoutTerm", SearchSurvey.Admit(10, 500, true, false, false, false, false, false).Code, "recherche globale sans terme");
        Check.Equal("domainRoot", SearchSurvey.Admit(10, 500, false, false, true, false, false, false).Code, "racine sans filtre");
        Check.Equal("domainRoot", SearchSurvey.Admit(10, 500, false, false, true, false, true, true).Code, "toute la liste sélectionnée");
        Check.True(SearchSurvey.Admit(10, 500, false, false, true, false, true, false).Allowed, "sélection partielle : son propre filtre");
        Check.True(SearchSurvey.Admit(10, 500, true, true, false, false, false, false).Allowed, "recherche avec terme");
        Check.Equal(4, SearchSurvey.Estimate(64, SurveyMode.Ping), "deux lots de 32");
        Check.Equal(0, SearchSurvey.Estimate(0, SurveyMode.Complete), "rien à relever");
        Check.Equal(8, SearchSurvey.Estimate(8, SurveyMode.Console), "console, quatre à la fois");
        Check.True(SearchSurvey.TryParseMode("unaddressed", out var mode) && mode == SurveyMode.Unaddressed, "mode sans adresse");
        Check.False(SearchSurvey.TryParseMode("scan", out _), "mode inconnu");
    }

    [Test]
    public static void Presence_never_concludes_that_a_workstation_is_off()
    {
        var now = Fixtures.Now;
        Check.Equal(SearchPresenceState.Unknown, SearchTexts.Presence(null, now).State, "jamais relevé");
        Check.Equal(SearchPresenceState.Online, SearchTexts.Presence(Fixtures.Presence(true, TimeSpan.FromHours(2)), now).State, "en ligne");
        var silent = SearchTexts.Presence(Fixtures.Presence(false, TimeSpan.FromHours(2)), now);
        Check.Equal(SearchPresenceState.NoReply, silent.State, "sans réponse");
        Check.Contains("sans preuve qu’il est éteint", silent.Detail, "pas de verdict d’arrêt");
        Check.Equal(SearchPresenceState.Unknown, SearchTexts.Presence(Fixtures.Presence(true, TimeSpan.FromDays(31)), now).State, "relevé trop ancien");
    }

    [Test]
    public static void Recent_searches_are_flat_bounded_and_without_duplicates()
    {
        var at = Fixtures.Now;
        var list = SearchMemoryRules.AddRecent([], "search", "  martin \n dupont ", null, null, at);
        Check.Equal("martin dupont", list[0].Text, "texte aplati");
        list = SearchMemoryRules.AddRecent(list, "search", "MARTIN DUPONT", null, null, at);
        Check.Equal(1, list.Length, "doublon sans casse retiré");
        Check.Equal(1, SearchMemoryRules.AddRecent(list, "search", "a", null, null, at).Length, "texte trop court ignoré");
        for (var i = 0; i < 12; i++)
        {
            list = SearchMemoryRules.AddRecent(list, "search", "recherche " + i.ToString(System.Globalization.CultureInfo.InvariantCulture), null, null, at);
        }
        Check.Equal(SearchMemoryRules.MaxRecentsPerKind, list.Count(r => r.Kind == "search"), "huit au plus");
        Check.Equal("recherche 11", list[0].Text, "plus récente d’abord");
    }

    [Test]
    public static void Ou_favourites_are_perimeters_of_the_session_domain_only()
    {
        var (root, why) = SearchMemoryRules.Favorite(Root, null, true, SearchTypeFilter.All, null, Root, "example.local");
        Check.Null(root, "racine refusée");
        Check.Contains("ne s’épingle pas", why, "raison");
        Check.Null(SearchMemoryRules.Favorite("OU=Paris,DC=autre,DC=local", null, true, SearchTypeFilter.All, null, Root, "example.local").Favorite, "autre domaine");
        var (paris, _) = SearchMemoryRules.Favorite("OU=Paris,OU=Postes," + Root, null, false, SearchTypeFilter.Computers, "pc", Root, "example.local");
        Check.Equal("Paris", paris?.Name, "nom de l’OU");
        Check.False(paris?.Subtree ?? true, "profondeur gardée");
        Check.True(SearchMemoryRules.IsQueryId("local:lowdisk"), "identifiant de requête");
        Check.False(SearchMemoryRules.IsQueryId("../etc"), "identifiant refusé");
    }
}
