using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>
/// « Utilisateurs et postes » (docs/ops/relations.md): pure rules of the relations (Domenia 1 Domenia-Relations.Model.ps1),
/// of the import (Domenia-InventoryImport.Model.ps1) and of the comparison of two users (R40), the projection, and the
/// operations through the real bridge in simulation, writes included (plan, confirmation, receipt, re-read).
/// </summary>
internal static class RelationsTests
{
    private static readonly TimeZoneInfo Zone = TestClock.Paris;
    private static readonly DateTimeOffset Now = TestClock.Reference;
    private static readonly Guid UserA = Fixtures.IdOf("user-a");
    private static readonly Guid UserB = Fixtures.IdOf("user-b");
    private static readonly Guid Pc1 = Fixtures.IdOf("pc-1");
    private static readonly Guid Pc2 = Fixtures.IdOf("pc-2");

    private static StoredRelation Link(RelationKind kind, string user = "jdupont", Guid? userGuid = null, string computer = "PC01", Guid? computerGuid = null, DateTimeOffset? when = null, string? source = null) =>
        new(user, userGuid, null, computer, computerGuid, null, kind, source ?? kind switch
        {
            RelationKind.Assignment => RelationRules.ManualSource,
            RelationKind.Console => RelationRules.ConsoleSource,
            RelationKind.History => "Journal du contrôleur 4624",
            RelationKind.Imported => "Import GLPI",
            _ => "Inventaire WAPT",
        }, when ?? Now - TimeSpan.FromDays(1), null, true, null, null);

    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string[] Names(JsonElement element) => [.. element.EnumerateObject().Select(p => p.Name)];

    // ------------------------------------------------------------------ rules

    [Test]
    public static void Kind_of_a_source_follows_the_order_of_Domenia_1()
    {
        Check.Equal(RelationKind.Hint, RelationRules.KindOf("Responsable déclaré (managedBy)"), "un attribut propriétaire est un indice");
        Check.Equal(RelationKind.Assignment, RelationRules.KindOf("Saisie manuelle"), "saisie manuelle");
        Check.Equal(RelationKind.Imported, RelationRules.KindOf("Import GLPI"), "import avant glpi");
        Check.Equal(RelationKind.RemoteSession, RelationRules.KindOf("Session distante WTS (RDP)"), "rdp");
        Check.Equal(RelationKind.History, RelationRules.KindOf("Historique LogonUI"), "logonui = historique");
        Check.Equal(RelationKind.Console, RelationRules.KindOf("Console CIM/DCOM"), "console");
        Check.Equal(RelationKind.Hint, RelationRules.KindOf("Événement Kerberos 4768"), "kerberos = indice");
        Check.Equal(RelationKind.Unknown, RelationRules.KindOf("???"), "inconnu");
    }

    [Test]
    public static void Keys_ignore_authority_suffix_and_dns()
    {
        Check.Equal("jdupont", RelationRules.LoginKey(@"EXAMPLE\JDupont"), "autorité retirée");
        Check.Equal("jdupont", RelationRules.LoginKey("jdupont@example.local"), "suffixe UPN retiré");
        Check.Equal("pc01", RelationRules.ComputerKey("PC01.example.local"), "premier label DNS");
        Check.Equal("pc01", RelationRules.ComputerKey("PC01$"), "compte machine");
    }

    [Test]
    public static void Same_relation_uses_guid_first_then_names()
    {
        var withGuids = Link(RelationKind.Console, userGuid: UserA, computerGuid: Pc1);
        Check.True(RelationRules.Same(withGuids, withGuids with { Computer = "PC01-RENOMME" }), "renommage : même relation par GUID");
        Check.False(RelationRules.Same(withGuids, withGuids with { ComputerGuid = Pc2 }), "objet recréé : autre relation");
        Check.True(RelationRules.Same(Link(RelationKind.Console), withGuids), "ligne héritée sans GUID et la même avec GUID");
        Check.False(RelationRules.Same(withGuids, withGuids with { Kind = RelationKind.History }), "autre nature : autre relation");
    }

    [Test]
    public static void Upsert_refreshes_the_same_relation_and_adds_any_other()
    {
        var declared = Link(RelationKind.Assignment, userGuid: UserA, computerGuid: Pc1);
        var observed = Link(RelationKind.Console, user: "autre", userGuid: UserB, computerGuid: Pc1);
        var refresh = RelationRules.Upsert([declared], declared with { When = Now });
        Check.True(refresh.Refresh, "même relation : date mise à jour");
        var add = RelationRules.Upsert([declared], observed);
        Check.False(add.Refresh, "une observation ne remplace jamais une affectation");
    }

    [Test]
    public static void Primary_is_the_declared_assignment_then_the_most_recent()
    {
        var oldDeclared = Link(RelationKind.Assignment, computer: "PC-A", when: Now - TimeSpan.FromDays(300));
        var recent = Link(RelationKind.Console, computer: "PC-B", when: Now - TimeSpan.FromMinutes(5));
        Check.Equal("PC-A", RelationRules.Primary([recent, oldDeclared])!.Computer, "affectation déclarée d’abord");
        var older = Link(RelationKind.History, computer: "PC-C", when: Now - TimeSpan.FromDays(40));
        Check.Equal("PC-B", RelationRules.Primary([older, recent])!.Computer, "sinon la plus récente");
        Check.Null(RelationRules.Primary([]), "aucune relation");
    }

    [Test]
    public static void Badges_have_a_rule_and_never_a_percentage()
    {
        foreach (var kind in Enum.GetValues<RelationKind>())
        {
            var badge = RelationRules.BadgeOf(kind);
            Check.True(badge.Rule.Length > 10, "règle de " + kind);
            Check.False(badge.Rule.Contains('%', StringComparison.Ordinal) || badge.Label.Contains('%', StringComparison.Ordinal), "aucun pourcentage : " + kind);
        }
        Check.Equal(RelationBadge.Contradictory, RelationRules.BadgeOf(RelationKind.Console, contradicted: true).Badge, "contradiction");
        Check.Equal("À vérifier", RelationRules.BadgeOf(RelationKind.Unknown).Label, "origine inconnue");
    }

    [Test]
    public static void Conflicts_compare_declared_and_observed_only()
    {
        var declared = Link(RelationKind.Assignment, userGuid: UserA, computerGuid: Pc1);
        var other = Link(RelationKind.Console, user: "autre", userGuid: UserB, computerGuid: Pc1);
        var history = Link(RelationKind.History, user: "ancien", userGuid: Fixtures.IdOf("ancien"), computerGuid: Pc1);
        var conflicts = RelationRules.Conflicts([declared, other, history]);
        Check.Equal(1, conflicts.Length, "un poste contradictoire");
        Check.Equal(2, conflicts[0].Keys.Length, "affectation et observation, jamais l’historique");
        Check.Equal(0, RelationRules.Conflicts([declared, history]).Length, "l’historique ne contredit jamais une affectation");
        Check.Equal(0, RelationRules.Conflicts([declared, other with { UserLogin = "jdupont", UserGuid = UserA }]).Length, "même compte : pas de conflit");
    }

    [Test]
    public static void Overview_keeps_three_separate_statements()
    {
        var overview = RelationRules.Overview([Link(RelationKind.Console, when: Now - TimeSpan.FromHours(2)), Link(RelationKind.Hint)], RelationSubjectKind.User, Now, Zone);
        Check.Equal("Aucune affectation déclarée", overview.Lines[0].Value, "aucune affectation : dit comme tel");
        Check.Contains("PC01", overview.Lines[1].Value, "dernière session observée");
        Check.Equal("Aucune ouverture de session ancienne relevée", overview.Lines[2].Value, "historique absent");
        Check.Equal(4, overview.Lines.Length, "autres indices comptés");
        Check.Equal(1, overview.Clues, "un indice");
    }

    [Test]
    public static void Identity_by_guid_and_creation_date()
    {
        var link = Link(RelationKind.History, computerGuid: Pc1, when: Now - TimeSpan.FromDays(400));
        Check.Equal(RelationIdentityMatch.Same, RelationRules.Identity(link, RelationSubjectKind.Computer, Pc1, Now - TimeSpan.FromDays(900)).Match, "même GUID");
        Check.Equal(RelationIdentityMatch.Different, RelationRules.Identity(link, RelationSubjectKind.Computer, Pc2, Now).Match, "autre GUID");
        var legacy = link with { ComputerGuid = null };
        Check.Equal(RelationIdentityMatch.Different, RelationRules.Identity(legacy, RelationSubjectKind.Computer, Pc2, Now - TimeSpan.FromDays(10)).Match, "antérieure à la création : nom réattribué");
        Check.Equal(RelationIdentityMatch.Unknown, RelationRules.Identity(legacy, RelationSubjectKind.Computer, Pc2, Now - TimeSpan.FromDays(900)).Match, "sans GUID : non vérifiable");
    }

    [Test]
    public static void Protected_sources_and_orphan_reasons()
    {
        foreach (var source in new[] { "Manual", "Saisie manuelle", "Import CSV", "import glpi", "Import osquery" })
        {
            Check.True(RelationRules.IsProtectedSource(source), "protégée : " + source);
        }
        Check.False(RelationRules.IsProtectedSource(RelationRules.ConsoleSource), "une console n’est pas protégée");
        Check.Contains("Compte et poste absents", RelationRules.OrphanReason(false, false), "deux absents");
        Check.Contains("Poste absent", RelationRules.OrphanReason(true, false), "poste absent");
        Check.Equal("", RelationRules.OrphanReason(true, true), "pas orpheline");
    }

    [Test]
    public static void Association_steps_refuse_in_one_french_sentence()
    {
        var (state, accepted, _) = RelationRules.Step(RelationAssociationState.Idle, RelationAssociationEvent.Search);
        Check.True(accepted && state == RelationAssociationState.Searching, "recherche");
        var refused = RelationRules.Step(RelationAssociationState.Pending, RelationAssociationEvent.Pick);
        Check.False(refused.Accepted, "un choix pendant une confirmation est refusé");
        Check.Contains("attend déjà sa confirmation", refused.Reason, "phrase française");
        Check.False(refused.Reason.Contains("Pending", StringComparison.Ordinal), "aucun nom interne");
        Check.Equal(RelationAssociationState.Saved, RelationRules.Step(RelationAssociationState.Verifying, RelationAssociationEvent.Verified).State, "enregistrée");
    }

    [Test]
    public static void Observed_account_identity_is_strict()
    {
        var target = new RelationAccountTarget("jdupont", "EXAMPLE", "example.local", "S-1-5-21-1-2-3-1001", "jean.dupont@example.local");
        Check.True(RelationRules.MatchAccount(target, @"EXAMPLE\jdupont", null, "PC01").Match, "même domaine et identifiant");
        Check.True(RelationRules.MatchAccount(target, "x", "S-1-5-21-1-2-3-1001", "PC01").Certain, "SID identique : certain");
        Check.False(RelationRules.MatchAccount(target, @".\jdupont", null, "PC01").Match, "compte local");
        Check.False(RelationRules.MatchAccount(target, @"PC01\jdupont", null, "PC01.example.local").Match, "compte du poste");
        Check.False(RelationRules.MatchAccount(target, @"AUTRE\jdupont", null, "PC01").Match, "autre domaine");
        Check.False(RelationRules.MatchAccount(target, "jdupont", null, "PC01").Match, "nom non qualifié");
        Check.True(RelationRules.MatchAccount(target, "jean.dupont@example.local", null, "PC01").Match, "UPN explicite");
    }

    [Test]
    public static void Candidates_without_guid_are_never_associable()
    {
        var merged = RelationRules.MergeCandidates(
        [
            new RelationProof(Pc1, "PC01", "CN=PC01,DC=test,DC=local", null, "Association mémorisée", "Lien déjà connu."),
            new RelationProof(Pc1, "PC01", null, null, "Responsable déclaré", "Indice."),
            new RelationProof(null, "10.20.1.5", null, "10.20.1.5", "Événement Kerberos 4768", "Indice IP."),
        ]);
        Check.Equal(2, merged.Length, "regroupés par GUID");
        Check.Equal("Association mémorisée + Responsable déclaré", merged[0].Origins, "origines cumulées");
        Check.False(merged[1].Associable, "une adresse IP n’est jamais associable");
        Check.NotNull(merged[1].Blocker, "raison du refus");
    }

    [Test]
    public static void Detection_plan_never_substitutes_the_domain()
    {
        var root = Fixtures.Root;
        var refused = RelationRules.DetectionPlan("ou", root, root, [], 20, "p", null);
        Check.False(refused.Allowed, "racine refusée");
        Check.Contains("domaine entier ne sera pas substitué", refused.Reason, "raison");
        var candidates = Enumerable.Range(1, 30).Select(i => new RelationPlanCandidate(Fixtures.IdOf("c" + i), "PC" + i, "CN=PC" + i + "," + Fixtures.Postes, root, "OU choisie"));
        var plan = RelationRules.DetectionPlan("ou", Fixtures.Postes, root, candidates, 20, "p", Now);
        Check.True(plan.Allowed && plan.Truncated && plan.Targets.Length == 20 && plan.Eligible == 30, "tronqué à la limite");
        var empty = RelationRules.DetectionPlan("candidates", null, root, [], 20, "p", null);
        Check.Contains("Zéro candidat", empty.ZeroMeaning, "zéro ne veut pas dire aucun poste");
        Check.True(RelationRules.WithinPlan(["a", "b"], ["a"]) && !RelationRules.WithinPlan(["a"], ["c"]), "liste sondée incluse");
    }

    [Test]
    public static void Counters_say_partial_and_remaining()
    {
        var counters = RelationRules.NewCounters(3);
        counters = RelationRules.Count(counters, RelationProbeOutcome.Confirmed);
        Check.Contains("2 restants", counters.Text, "restants");
        counters = RelationRules.Count(RelationRules.Count(counters, RelationProbeOutcome.Refused), RelationProbeOutcome.Unreachable);
        Check.Contains("résultat partiel", counters.Text, "refus et injoignables : partiel");
        Check.Contains("arrêté", RelationRules.Count(counters, RelationProbeOutcome.Stopped).Text, "arrêt déclaré");
        Check.Null(RelationRules.Outcome("INCONNU"), "statut inconnu non compté");
    }

    [Test]
    public static void Dates_show_the_year_only_when_needed()
    {
        Check.Equal("21/10 18:00", RelationRules.WhenText(new DateTimeOffset(2026, 10, 21, 16, 0, 0, TimeSpan.Zero), Now, Zone), "cette année, heure locale");
        Check.Equal("21/10/2025 18:00", RelationRules.WhenText(new DateTimeOffset(2025, 10, 21, 16, 0, 0, TimeSpan.Zero), Now, Zone), "autre année");
        Check.Null(RelationRules.WhenText(null, Now, Zone), "sans date");
        Check.Equal(new DateTimeOffset(2026, 10, 8, 7, 15, 0, TimeSpan.Zero), RelationRules.ParseStoredWhen("2026-10-08 09:15:00", Zone), "date sans décalage lue en heure locale");
    }

    // ------------------------------------------------------------------ import

    [Test]
    public static void Csv_is_read_with_its_delimiter_and_quotes()
    {
        var (rows, total, _) = RelationImport.ParseCsv("\uFEFFUserLogin;Computer;When\r\njdupont;PC01;2026-10-01\r\n\r\n\"a;b\";\"PC\"\"2\";\n");
        Check.Equal(2, total, "lignes vides ignorées");
        Check.Equal("a;b", rows[1]["UserLogin"], "guillemets");
        Check.Equal("PC\"2", rows[1]["Computer"], "guillemets doublés");
        Check.Equal(',', RelationImport.Delimiter("User,Computer"), "virgule");
        var record = RelationImport.CsvRow(rows[0], 1);
        Check.Equal("jdupont", record.User, "colonne UserLogin");
        Check.Equal("2026-10-01", record.When, "colonne When");
    }

    [Test]
    public static void Glpi_display_name_is_never_a_login()
    {
        var row = new Dictionary<string, string>(StringComparer.Ordinal) { ["Nom"] = "PC01", ["Utilisateur"] = "Dupont Alice", ["Numéro de série"] = "CZ123" };
        var record = RelationImport.GlpiRow(row, 1);
        Check.Contains("identifiant de connexion absent", record.Reject, "nom affiché refusé");
        var good = RelationImport.GlpiRow(new Dictionary<string, string>(StringComparer.Ordinal) { ["Nom"] = "PC01", ["Usager"] = "adupont" }, 2);
        Check.Equal("adupont", good.User, "colonne Usager");
    }

    [Test]
    public static void Osquery_skips_session_ends_and_system_accounts()
    {
        const string log = """
            {"name":"users","hostIdentifier":"PC01","unixTime":1792000000,"action":"added","columns":{"user":"jdupont","type":"user","time":"1792000000"}}
            {"name":"users","hostIdentifier":"PC01","unixTime":1792000100,"action":"removed","columns":{"user":"jdupont","type":"user"}}
            {"name":"users","hostIdentifier":"PC02","unixTime":1792000200,"action":"added","columns":{"user":"SYSTEM","type":"user"}}
            pas du json
            """;
        var parsed = RelationImport.ParseOsquery(log);
        Check.Equal("resultsLog", parsed.Format, "journal de résultats");
        Check.Equal(1, parsed.Records.Length, "une session de personne");
        Check.Equal(2, parsed.Skipped, "fin de session et compte système ignorés");
        Check.Equal(1, parsed.Rejected, "ligne illisible comptée");
        Check.True(parsed.Records[0].UnixTime, "temps Unix");
    }

    [Test]
    public static void Import_identity_rejects_other_domains_and_addresses()
    {
        Check.Contains("autre domaine", RelationImport.Identity(@"AUTRE\jdupont", "PC01", "example.local", "EXAMPLE"), "autre domaine");
        Check.Contains("Suffixe UPN", RelationImport.Identity("jdupont@autre.fr", "PC01", "example.local", "EXAMPLE"), "autre suffixe");
        Check.Contains("Adresse IP", RelationImport.Identity("jdupont", "10.0.0.1", "example.local", "EXAMPLE"), "adresse IP");
        Check.Contains("Identifiant matériel", RelationImport.Identity("jdupont", "4C4C4544-0047-3510-8051-B4C04F4E3732", "example.local", "EXAMPLE"), "UUID");
        Check.Equal("", RelationImport.Identity(@"EXAMPLE\jdupont", "pc01.example.local", "example.local", "EXAMPLE"), "identité correcte");
        Check.Equal("", RelationImport.NormalizeUser("PC01$"), "compte machine écarté");
        Check.Equal("PC01", RelationImport.NormalizeComputer("pc01.example.local"), "nom normalisé");
    }

    [Test]
    public static void Import_dates_and_priority_inside_the_file()
    {
        Check.Null(RelationImport.When("08/10/2026", false, Now, Zone).Utc, "date ambiguë non lue");
        Check.Contains("dans le futur", RelationImport.When("2027-01-01T00:00:00Z", false, Now, Zone).Note, "date future ignorée");
        var day = TimeSpan.TicksPerDay;
        var decisions = RelationImport.Priority([(1, "pc01", "a", 10 * day), (2, "pc01", "b", 20 * day), (3, "pc02", "c", 0), (4, "pc02", "d", 0), (5, "pc03", "e", 0), (6, "pc03", "e", 0)]);
        Check.Equal("Remplacée", decisions[0].Kind, "date plus récente gagne");
        Check.Equal("Retenue", decisions[1].Kind, "le plus récent");
        Check.Equal("Conflit", decisions[2].Kind, "deux comptes sans date : conflit");
        Check.Equal("Doublon", decisions[5].Kind, "même compte : doublon");
        var batch = RelationImport.BatchId("0123456789abcdef0123456789abcdef", Now);
        Check.Equal(batch, RelationImport.BatchToken("Lot d’import " + batch + ". Importé depuis f.csv."), "jeton relu dans les détails");
        Check.Equal(Now, RelationImport.BatchInstant(batch), "instant du lot");
    }

    [Test]
    public static void Import_statuses_never_replace_an_association()
    {
        Check.Equal("Conflit", RelationImport.Status("jdupont", "PC01", "autre", true, true, true, "", 0, "", "", "").Category, "poste déjà associé à un autre compte");
        Check.Equal("Déjà connue", RelationImport.Status("jdupont", "PC01", "JDupont", true, true, true, "", 0, "", "", "").Category, "déjà connue");
        Check.Equal("Inconnue", RelationImport.Status("jdupont", "PC01", null, true, false, true, "", 0, "", "", "").Category, "absent de l’index");
        Check.Equal("Reportée", RelationImport.Status("jdupont", "PC01", null, true, true, true, "", 64, "", "", "").Category, "au-delà de 64");
        Check.True(RelationImport.Status("jdupont", "PC01", null, true, true, true, "", 0, "", "", "").Import, "valide");
    }

    // ------------------------------------------------------------------ comparison of two users (R40)

    [Test]
    public static void Comparison_finds_privileged_differences_and_paths()
    {
        var bridge = new SimulatedBridge();
        var directory = bridge.Source.CurrentDirectory;
        var julien = directory.Users.Single(u => u.SamAccountName == "j.martin");
        var (admin, reason) = UserGroupComparer.Resolve(directory, @"EXAMPLE\adm-j.martin");
        Check.NotNull(admin, "compte d’administration résolu : " + reason);
        var result = UserGroupComparer.Compare(julien, admin!, directory, Now, Zone);
        Check.True(result.Counts.OnlyLeft > 0 && result.Counts.OnlyRight > 0, "écarts des deux côtés");
        Check.True(result.Groups.Any(g => g.Primary), "groupe principal inclus");
        Check.True(result.Groups.Any(g => g.LeftOrigin == UserGroupOrigin.Nested && g.Path is not null && g.Path.Contains(" → ", StringComparison.Ordinal)), "chemin d’un groupe imbriqué");
        Check.True(result.Counts.PrivilegedDifferences > 0, "écart sur un groupe à privilèges");
        Check.Contains(julien.DistinguishedName, result.Ticket, "le ticket cite les DN");
        Check.Contains("Lecture seule", result.Note, "rien n’est appliqué");
        Check.Null(UserGroupComparer.Resolve(directory, @"AUTRE\j.martin").User, "autre domaine refusé");
    }

    [Test]
    public static void Privileged_groups_follow_Domenia_1()
    {
        Check.True(UserGroupComparer.IsPrivileged("X", "S-1-5-21-1-2-3-512", null), "RID 512");
        Check.True(UserGroupComparer.IsPrivileged("Opérateurs de sauvegarde", "S-1-5-32-551", null), "builtin 551");
        Check.True(UserGroupComparer.IsPrivileged("Groupe", "S-1-5-21-1-2-3-9999", 1), "adminCount");
        Check.False(UserGroupComparer.IsPrivileged("GG-App-CRM", "S-1-5-21-1-2-3-1201", null), "groupe ordinaire");
    }

    // ------------------------------------------------------------------ bridge in simulation

    [Test]
    public static async Task Overview_and_list_have_the_exact_shape()
    {
        var bridge = new SimulatedBridge();
        var overview = SimulatedBridge.Json(await bridge.CallAsync("relations.overview"));
        Check.True(Names(overview).SequenceEqual(["storeLabel", "simulated", "total", "users", "computers", "badges", "contradictions", "unverified", "sessionOnly",
            "lastImport", "restore", "activity", "journalEntries", "summary"]), "propriétés de relations.overview : " + string.Join(",", Names(overview)));
        Check.Equal(7, overview.GetProperty("badges").GetArrayLength(), "sept qualifications");
        Check.Equal(14, overview.GetProperty("activity").GetArrayLength(), "14 jours");
        Check.True(overview.GetProperty("contradictions").GetInt32() >= 9, "au moins les neuf postes contradictoires du monde");
        Check.Equal(JsonValueKind.Object, overview.GetProperty("lastImport").ValueKind, "lot d’import présent");
        Check.Equal(JsonValueKind.Object, overview.GetProperty("restore").ValueKind, "suppression restaurable");
        var list = SimulatedBridge.Json(await bridge.CallAsync("relations.list"));
        var row = list.GetProperty("rows")[0];
        Check.True(Names(row).SequenceEqual(["key", "fingerprint", "userLogin", "userName", "userDn", "userGuid", "computer", "computerDn", "computerGuid", "kind", "badge",
            "badgeLabel", "tone", "rule", "source", "when", "whenText", "details", "persistence", "persistenceLabel", "identity", "identityNote", "verifiedInAd", "protected",
            "batchId", "contradicted", "declarant"]), "propriétés d’une association : " + string.Join(",", Names(row)));
        Check.Equal(overview.GetProperty("total").GetInt32(), list.GetProperty("total").GetInt32(), "même total");
        Check.True(list.GetProperty("rows").EnumerateArray().Any(r => r.GetProperty("identity").GetString() == "unknown"), "lignes héritées sans GUID");
        Check.False(JsonSerializer.Serialize(list).Contains('%', StringComparison.Ordinal), "aucun pourcentage");
    }

    [Test]
    public static async Task Subject_view_of_the_session_account()
    {
        var bridge = new SimulatedBridge();
        var view = SimulatedBridge.Json(await bridge.CallAsync("relations.subject", Args(new { @ref = "j.martin" })));
        Check.Equal("user", view.GetProperty("subject").GetProperty("kind").GetString(), "utilisateur");
        Check.Equal("declared", view.GetProperty("primary").GetProperty("badge").GetString(), "poste principal déclaré");
        Check.True(view.GetProperty("associations").GetArrayLength() >= 4, "associations de Julien");
        Check.Equal("Affectation déclarée", view.GetProperty("overview").GetProperty("lines")[0].GetProperty("fact").GetString(), "synthèse");
        var nodes = view.GetProperty("graph").GetProperty("nodes");
        Check.Equal(1, nodes.EnumerateArray().Count(n => n.GetProperty("depth").GetInt32() == 0), "un centre");
        Check.True(nodes.EnumerateArray().Any(n => n.GetProperty("depth").GetInt32() == 2), "deuxième cercle (collègue relevé)");
        Check.True(view.GetProperty("logons").GetArrayLength() > 0, "dernières ouvertures de session");
        var computer = view.GetProperty("primary").GetProperty("dn").GetString()!;
        var pc = SimulatedBridge.Json(await bridge.CallAsync("relations.subject", Args(new { @ref = computer })));
        Check.Equal("computer", pc.GetProperty("subject").GetProperty("kind").GetString(), "dans l’autre sens");
        Check.Equal("Lire la session de ce poste", pc.GetProperty("direction").GetProperty("detectLabel").GetString(), "libellés du sens");
        var unknown = await bridge.CallAsync("relations.subject", Args(new { @ref = "personne.inconnue" }));
        Check.Equal(RelationErrors.Unknown, unknown.Error?.Code, "sujet inconnu");
    }

    [Test]
    public static async Task Arguments_are_checked_before_any_read()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("relations.subject", "{}")).Error?.Code, "ref obligatoire");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("relations.overview", Args(new { x = 1 }))).Error?.Code, "aucun argument");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("relations.detect.run", Args(new { planId = "abc" }))).Error?.Code, "identifiant mal formé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("relations.harvest.estimate", Args(new { days = 45, maxEvents = 5000 }))).Error?.Code, "jours bornés");
        var julien = bridge.Source.CurrentDirectory.Users.Single(u => u.SamAccountName == "j.martin").DistinguishedName;
        Check.Equal("relation.term", (await bridge.CallAsync("relations.targets.search", Args(new { dn = julien, text = "P" }))).Error?.Code, "deux caractères au moins");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("relations.orphans.plan", Args(new { checkId = new string('a', 32), keys = Enumerable.Range(0, 65).Select(i => "a|b|c" + i).ToArray() }))).Error?.Code, "64 clés au plus");
    }

    [Test]
    public static void Classes_of_the_relations_operations()
    {
        var bridge = new SimulatedBridge();
        (string Name, OperationClass Class)[] expected =
        [
            ("relations.overview", OperationClass.LocalRead), ("relations.list", OperationClass.LocalRead), ("relations.subject", OperationClass.LocalRead),
            ("relations.subjects.search", OperationClass.LocalRead), ("relations.targets.search", OperationClass.NetworkRead),
            ("relations.detect.collect", OperationClass.NetworkRead), ("relations.detect.run", OperationClass.NetworkRead), ("relations.detect.stop", OperationClass.Local),
            ("relations.computer.read", OperationClass.NetworkRead), ("relations.harvest.estimate", OperationClass.LocalRead), ("relations.harvest.run", OperationClass.NetworkRead),
            ("relations.journal", OperationClass.LocalRead), ("relations.import.stage", OperationClass.Local), ("relations.import.preview", OperationClass.LocalRead),
            ("relations.orphans.check", OperationClass.NetworkRead), ("relations.compare", OperationClass.LocalRead), ("relations.sweep.plan", OperationClass.LocalRead),
            ("relations.associate.plan", OperationClass.LocalRead), ("relations.remove.plan", OperationClass.LocalRead), ("relations.restore.plan", OperationClass.LocalRead),
            ("relations.import.plan", OperationClass.LocalRead), ("relations.import.undo.plan", OperationClass.LocalRead), ("relations.orphans.plan", OperationClass.LocalRead),
            ("relations.observations.plan", OperationClass.LocalRead),
        ];
        foreach (var (name, operationClass) in expected)
        {
            Check.True(bridge.Registry.TryGet(name, out var definition), "opération présente : " + name);
            Check.Equal(operationClass, definition!.Class, "classe de " + name);
            if (operationClass == OperationClass.NetworkRead)
            {
                Check.True(definition.ServedInSimulation, "servie par la simulation : " + name);
            }
        }
        Check.Equal(expected.Length, bridge.Registry.Names.Count(n => n.StartsWith("relations.", StringComparison.Ordinal)), "aucune autre opération de l’écran");
    }

    private static async Task<JsonElement> ExecuteAsync(SimulatedBridge bridge, JsonElement planned) =>
        SimulatedBridge.Json(await bridge.CallAsync("write.execute", Args(new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(),
            token = planned.GetProperty("token").GetString(),
            typedName = (string?)null,
        })));

    [Test]
    public static async Task Declared_association_through_the_write_circuit()
    {
        var bridge = new SimulatedBridge();
        var directory = bridge.Source.CurrentDirectory;
        var julien = directory.Users.Single(u => u.SamAccountName == "j.martin");
        var target = directory.Computers.First(c => c.Name.StartsWith("PC-LYO-", StringComparison.Ordinal));
        var planned = SimulatedBridge.Json(await bridge.CallAsync("relations.associate.plan", Args(new { dn = julien.DistinguishedName, target = target.DistinguishedName })));
        var plan = planned.GetProperty("plan");
        Check.Equal(RelationChange.Kind, plan.GetProperty("kind").GetString(), "type d’écriture");
        Check.Equal("relations", plan.GetProperty("target").GetProperty("kind").GetString(), "cible : le magasin local");
        Check.False(plan.GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "confirmation simple");
        Check.Equal("add", plan.GetProperty("changes")[0].GetProperty("kind").GetString(), "ajout");
        var receipt = await ExecuteAsync(bridge, planned);
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "appliquée");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "relue");
        Check.True(receipt.GetProperty("simulated").GetBoolean(), "reçu simulé");
        var view = SimulatedBridge.Json(await bridge.CallAsync("relations.subject", Args(new { @ref = "j.martin" })));
        Check.True(view.GetProperty("associations").EnumerateArray().Any(r => r.GetProperty("computer").GetString() == target.Name && r.GetProperty("badge").GetString() == "declared"),
            "association déclarée visible");
        var journal = SimulatedBridge.Json(await bridge.CallAsync("relations.journal"));
        Check.Equal("added", journal.GetProperty("entries")[0].GetProperty("action").GetString(), "journalisée");
        var again = await bridge.CallAsync("write.execute", Args(new { planId = plan.GetProperty("id").GetString(), token = planned.GetProperty("token").GetString(), typedName = (string?)null }));
        Check.Equal(WriteErrors.TokenUsed, again.Error?.Code, "jamais rejouée");
        var same = await bridge.CallAsync("relations.associate.plan", Args(new { dn = julien.DistinguishedName, target = julien.DistinguishedName }));
        Check.Equal(RelationErrors.SameKind, same.Error?.Code, "types opposés exigés");
    }

    [Test]
    public static async Task Removal_is_optimistic_journaled_and_restorable()
    {
        var bridge = new SimulatedBridge();
        var row = SimulatedBridge.Json(await bridge.CallAsync("relations.list")).GetProperty("rows").EnumerateArray()
            .First(r => r.GetProperty("persistence").GetString() == "stored" && r.GetProperty("kind").GetString() == "console");
        var key = row.GetProperty("key").GetString()!;
        var stale = await bridge.CallAsync("relations.remove.plan", Args(new { key, fingerprint = new string('0', 64) }));
        Check.Equal(WriteErrors.Stale, stale.Error?.Code, "empreinte différente : modifiée ailleurs");
        var planned = SimulatedBridge.Json(await bridge.CallAsync("relations.remove.plan", Args(new { key, fingerprint = row.GetProperty("fingerprint").GetString() })));
        Check.Equal("remove", planned.GetProperty("plan").GetProperty("changes")[0].GetProperty("kind").GetString(), "retrait");
        Check.Equal("verified", (await ExecuteAsync(bridge, planned)).GetProperty("verification").GetString(), "retrait relu");
        var journal = SimulatedBridge.Json(await bridge.CallAsync("relations.journal"));
        var removal = journal.GetProperty("entries")[0];
        Check.Equal("removed", removal.GetProperty("action").GetString(), "retrait journalisé");
        Check.True(removal.GetProperty("restorable").GetBoolean(), "restaurable");
        var restore = SimulatedBridge.Json(await bridge.CallAsync("relations.restore.plan", Args(new { entry = removal.GetProperty("id").GetString() })));
        Check.Equal("applied", (await ExecuteAsync(bridge, restore)).GetProperty("result").GetString(), "restaurée");
        var after = SimulatedBridge.Json(await bridge.CallAsync("relations.journal"));
        Check.Equal("restored", after.GetProperty("entries")[0].GetProperty("action").GetString(), "restauration journalisée");
        var twice = await bridge.CallAsync("relations.restore.plan", Args(new { entry = removal.GetProperty("id").GetString() }));
        Check.True(twice.Error?.Code is RelationErrors.NothingToRestore or RelationErrors.AlreadyExists, "une fois seulement");
    }

    [Test]
    public static async Task A_change_made_elsewhere_stops_the_plan()
    {
        var bridge = new SimulatedBridge();
        var row = SimulatedBridge.Json(await bridge.CallAsync("relations.list")).GetProperty("rows").EnumerateArray()
            .First(r => r.GetProperty("persistence").GetString() == "stored" && r.GetProperty("kind").GetString() == "history");
        var args = Args(new { key = row.GetProperty("key").GetString(), fingerprint = row.GetProperty("fingerprint").GetString() });
        var first = SimulatedBridge.Json(await bridge.CallAsync("relations.remove.plan", args));
        var second = SimulatedBridge.Json(await bridge.CallAsync("relations.remove.plan", args));
        Check.Equal("applied", (await ExecuteAsync(bridge, first)).GetProperty("result").GetString(), "premier retrait");
        var late = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Args(new { planId = second.GetProperty("plan").GetProperty("id").GetString(), token = second.GetProperty("token").GetString(), typedName = (string?)null })));
        Check.Equal("noChange", late.GetProperty("result").GetString(), "déjà retirée : rien n’est écrit");
    }

    [Test]
    public static async Task Import_preview_plan_and_undo()
    {
        var bridge = new SimulatedBridge();
        var directory = bridge.Source.CurrentDirectory;
        var linked = SimulatedBridge.Json(await bridge.CallAsync("relations.list")).GetProperty("rows").EnumerateArray().Select(r => r.GetProperty("computer").GetString()).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var free = directory.Computers.Where(c => c.Name.StartsWith("PC-", StringComparison.Ordinal) && !linked.Contains(c.Name) && !AdValues.IsDisabled(c.UserAccountControl)).Take(3).ToList();
        var people = directory.Users.Where(u => u.Department == "Finances" && !AdValues.IsDisabled(u.UserAccountControl)).Take(3).ToList();
        var csv = "UserLogin;Computer;When\n" + string.Join("\n", free.Select((c, i) => people[i].SamAccountName + ";" + c.Name + ";2026-10-01T08:00:00Z"))
            + "\nAUTRE\\x;PC-INCONNU-01;\n10.0.0.1;10.0.0.1;\n";
        var id = new string('c', 32);
        var staged = SimulatedBridge.Json(await bridge.CallAsync("relations.import.stage", Args(new { id, part = 0, parts = 1, text = csv })));
        Check.True(staged.GetProperty("complete").GetBoolean(), "fichier reçu");
        var preview = SimulatedBridge.Json(await bridge.CallAsync("relations.import.preview", Args(new { id, adapter = "csv", fileName = @"C:\dossier\import.csv" })));
        Check.Equal("import.csv", preview.GetProperty("fileName").GetString(), "nom sans dossier");
        Check.Equal(3, preview.GetProperty("ready").GetInt32(), "trois lignes valides");
        Check.True(preview.GetProperty("counts").GetProperty("reject").GetInt32() >= 1, "rejets comptés");
        var planned = SimulatedBridge.Json(await bridge.CallAsync("relations.import.plan", Args(new { previewId = preview.GetProperty("id").GetString() })));
        Check.Equal(3, planned.GetProperty("plan").GetProperty("changes").GetArrayLength(), "trois ajouts");
        Check.Equal("verified", (await ExecuteAsync(bridge, planned)).GetProperty("verification").GetString(), "import relu");
        var overview = SimulatedBridge.Json(await bridge.CallAsync("relations.overview"));
        Check.Equal(preview.GetProperty("batchId").GetString(), overview.GetProperty("lastImport").GetProperty("batchId").GetString(), "dernier lot = celui-ci");
        var undo = SimulatedBridge.Json(await bridge.CallAsync("relations.import.undo.plan", Args(new { batch = (string?)null })));
        Check.Equal(3, undo.GetProperty("plan").GetProperty("changes").GetArrayLength(), "trois retraits");
        Check.Equal("applied", (await ExecuteAsync(bridge, undo)).GetProperty("result").GetString(), "import annulé");
        Check.Equal(RelationErrors.ImportIncomplete, (await bridge.CallAsync("relations.import.preview", Args(new { id, adapter = "csv", fileName = "import.csv" }))).Error?.Code, "texte lu une seule fois");
    }

    [Test]
    public static async Task Orphans_never_propose_protected_sources()
    {
        var bridge = new SimulatedBridge();
        var check = SimulatedBridge.Json(await bridge.CallAsync("relations.orphans.check"));
        var rows = check.GetProperty("rows");
        Check.True(rows.GetArrayLength() > 0, "orphelines trouvées");
        Check.True(check.GetProperty("protected").GetInt32() > 0, "déclarées sans objet comptées, jamais proposées");
        Check.False(rows.EnumerateArray().Any(r => RelationRules.IsProtectedSource(r.GetProperty("source").GetString())), "aucune source protégée proposée");
        var keys = rows.EnumerateArray().Take(2).Select(r => r.GetProperty("key").GetString()).ToArray();
        var planned = SimulatedBridge.Json(await bridge.CallAsync("relations.orphans.plan", Args(new { checkId = check.GetProperty("id").GetString(), keys })));
        Check.Equal(2, planned.GetProperty("plan").GetProperty("changes").GetArrayLength(), "seules les lignes cochées");
        Check.Equal("verified", (await ExecuteAsync(bridge, planned)).GetProperty("verification").GetString(), "retrait relu");
    }

    [Test]
    public static async Task Detection_shows_the_perimeter_then_probes_only_it()
    {
        var bridge = new SimulatedBridge();
        var julien = bridge.Source.CurrentDirectory.Users.Single(u => u.SamAccountName == "j.martin").DistinguishedName;
        var collect = SimulatedBridge.Json(await bridge.CallAsync("relations.detect.collect", Args(new { dn = julien, scope = "candidates", ouDn = (string?)null, computers = Array.Empty<string>(), limit = 20, kerberos = true })));
        Check.Equal("collect", collect.GetProperty("phase").GetString(), "phase 1");
        Check.True(collect.GetProperty("attempts").EnumerateArray().Any(a => a.GetProperty("status").GetString() == "NON_DEMANDE"), "aucun poste contacté");
        var plan = collect.GetProperty("plan");
        Check.True(plan.GetProperty("allowed").GetBoolean(), "périmètre proposé");
        var planned = plan.GetProperty("targets").GetArrayLength();
        var run = SimulatedBridge.Json(await bridge.CallAsync("relations.detect.run", Args(new { planId = plan.GetProperty("id").GetString() })));
        Check.True(run.GetProperty("within").GetBoolean(), "liste sondée incluse dans le plan");
        Check.Equal(planned, run.GetProperty("counters").GetProperty("queried").GetInt32(), "chaque poste du plan interrogé une fois");
        Check.Equal(planned, bridge.Events.Count(e => e.Operation == "relations.detect.run:progress"), "progression poste par poste");
        if (run.GetProperty("savable").GetInt32() > 0)
        {
            var save = SimulatedBridge.Json(await bridge.CallAsync("relations.observations.plan", Args(new { resultId = run.GetProperty("resultId").GetString(), keys = Array.Empty<string>() })));
            Check.Equal("verified", (await ExecuteAsync(bridge, save)).GetProperty("verification").GetString(), "consoles enregistrées");
        }
        var root = bridge.Source.World.Directory.Domain.RootDn;
        var refused = SimulatedBridge.Json(await bridge.CallAsync("relations.detect.collect", Args(new { dn = julien, scope = "ou", ouDn = root, computers = Array.Empty<string>(), limit = 20, kerberos = false })));
        Check.False(refused.GetProperty("plan").GetProperty("allowed").GetBoolean(), "racine du domaine jamais substituée");
    }

    [Test]
    public static async Task Comparison_and_harvest_through_the_bridge()
    {
        var bridge = new SimulatedBridge();
        var julien = bridge.Source.CurrentDirectory.Users.Single(u => u.SamAccountName == "j.martin").DistinguishedName;
        var compare = SimulatedBridge.Json(await bridge.CallAsync("relations.compare", Args(new { dn = julien, other = "adm-j.martin" })));
        Check.True(Names(compare).SequenceEqual(["left", "right", "attributes", "groups", "counts", "limits", "summary", "note", "ticket", "readAt"]), "forme de la comparaison");
        var missing = await bridge.CallAsync("relations.compare", Args(new { dn = julien, other = "personne.inconnue" }));
        Check.Equal(RelationErrors.CompareUnresolved, missing.Error?.Code, "second compte non résolu");
        var estimate = SimulatedBridge.Json(await bridge.CallAsync("relations.harvest.estimate", Args(new { days = 7, maxEvents = 5000 })));
        var harvest = SimulatedBridge.Json(await bridge.CallAsync("relations.harvest.run", Args(new { estimateId = estimate.GetProperty("id").GetString() })));
        Check.True(harvest.GetProperty("events").GetInt32() <= 5000, "borné");
        Check.True(harvest.GetProperty("machineAccountsIgnored").GetInt32() > 0, "comptes machines ignorés");
    }

    [Test]
    public static void Projection_never_lends_a_reused_name()
    {
        var subject = new RelationObject(RelationSubjectKind.Computer, Pc2, "CN=PC01,OU=Postes,DC=test,DC=local", "PC01", "PC01", null, true, null, Now - TimeSpan.FromDays(10), null, null);
        var oldOwner = Link(RelationKind.History, computer: "PC01", computerGuid: Pc1);
        var legacyBefore = Link(RelationKind.History, computer: "PC01", when: Now - TimeSpan.FromDays(100));
        var mine = Link(RelationKind.Console, computer: "PC01", computerGuid: Pc2, when: Now - TimeSpan.FromHours(1));
        var relations = RelationProjection.SubjectRelations([oldOwner, legacyBefore, mine], subject);
        Check.Equal(1, relations.Length, "seul le lien de son GUID");
        Check.True(ReferenceEquals(mine, relations[0]) || relations[0] == mine, "le bon lien");
        ImmutableArray<RelationRow> none = [];
        Check.Equal(7, RelationProjection.Badges(none).Length, "sept facettes, zéros compris");
    }
}
