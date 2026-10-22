using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Pure rules of the Assistance screen (docs/ops/assistance.md): recipes, captures, findings, comparison, incidents, documents.</summary>
internal static class AssistanceRulesTests
{
    private static readonly DateTimeOffset Now = TestClock.Reference;
    private static readonly TimeZoneInfo Paris = TestClock.Paris;
    private const string Root = "DC=example,DC=local";

    private static Dictionary<string, IReadOnlyList<object?>> Props(params (string Name, object? Value)[] values)
    {
        var map = new Dictionary<string, IReadOnlyList<object?>>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, value) in values)
        {
            map[name] = value is IReadOnlyList<object?> list ? list : [value];
        }
        return map;
    }

    private static SupportSnapshot User(params (string Name, object? Value)[] values) =>
        SupportSnapshots.Create(Props(values), Root, "CN=Camille Bernard,OU=Commercial,OU=Lyon,OU=Utilisateurs," + Root, "Camille Bernard", "user", SnapshotSource.Live, Now, Now);

    private static string[] Codes(ImmutableArray<SupportFinding> findings) => [.. findings.Select(f => f.Code)];

    // ---------------------------------------------------------------- recipes

    [Test]
    public static void Recipes_respect_their_contract()
    {
        var problems = AssistanceRecipes.Validate(AssistanceRecipes.All);
        Check.True(problems.IsEmpty, "recettes valides : " + string.Join(" | ", problems));
        string[] ids = [.. AssistanceRecipes.All.Select(r => r.Id)];
        Check.True(ids.SequenceEqual(["logon", "slow", "disk", "software", "printer", "drive", "remote"]), "sept recettes dans l’ordre : " + string.Join(",", ids));
        Check.True(AssistanceRecipes.All.Take(4).Select(r => r.Steps.Length).SequenceEqual([6, 4, 3, 5]), "étapes des recettes de Domenia 1");
        Check.True(AssistanceRecipes.All.Take(4).All(r => !r.Added) && AssistanceRecipes.All.Skip(4).All(r => r.Added), "recettes ajoutées marquées");
        foreach (var action in AssistanceRecipes.Actions)
        {
            Check.True(AssistanceRecipes.ReadOperations.Contains(action.Operation), "lecture épinglée : " + action.Id);
        }
    }

    [Test]
    public static void Recipe_validation_refuses_what_Domenia_1_refused()
    {
        var view = new AssistanceView("poste", "sante", "Poste");
        var good = new AssistanceStep("a", "A", AssistanceSubject.Computer, "diagnostics", view, "lit", "pour", "coût");
        AssistanceRecipe Recipe(string id, params AssistanceStep[] steps) => new(id, "Titre", "Symptôme", "key", false, [.. steps]);
        Check.Contains("action non autorisée", string.Join("|", AssistanceRecipes.Validate([Recipe("x", good with { Action = "Remove-Everything" })])), "action hors liste");
        Check.Contains("type d’objet non admis", string.Join("|", AssistanceRecipes.Validate([Recipe("x", good with { Subject = AssistanceSubject.User })])), "type d’objet");
        Check.Contains("étape sans identifiant unique", string.Join("|", AssistanceRecipes.Validate([Recipe("x", good, good)])), "étape en double");
        Check.Contains("Recette sans identifiant unique", string.Join("|", AssistanceRecipes.Validate([Recipe("x", good), Recipe("x", good)])), "recette en double");
        Check.Contains("Why absent", string.Join("|", AssistanceRecipes.Validate([Recipe("x", good with { Why = " " })])), "pourquoi absent");
        Check.Contains("aucune étape", string.Join("|", AssistanceRecipes.Validate([Recipe("x")])), "recette vide");
        Check.Contains("symptôme absent", string.Join("|", AssistanceRecipes.Validate([new AssistanceRecipe("y", "T", "", "key", false, [good])])), "symptôme");
    }

    [Test]
    public static void Plan_text_says_the_whole_recipe_before_the_first_click()
    {
        var logon = AssistanceRecipes.Find("logon")!;
        var nb = FrenchText.Nbsp;
        // One colon only (the page writes « Avant le premier clic » as a title) and a number never alone at the end of a line.
        Check.Equal("6" + nb + "étapes, dont 2" + nb + "lectures pour le compte, 3" + nb + "pour le poste et 1" + nb + "sans lecture. 2" + nb + "demandent les droits d’administration du poste. 1"
            + nb + "étape facultative. Aucune étape ne part seule" + nb + "; aucune n’écrit.", AssistanceRecipes.PlanText(logon), "plan de « Connexion impossible »");
        var disk = AssistanceRecipes.Find("disk")!;
        Check.Contains("3" + nb + "étapes, dont 3" + nb + "lectures pour le poste.", AssistanceRecipes.PlanText(disk), "aucune lecture pour le compte : rien n’est dit");
        Check.False(AssistanceRecipes.PlanText(logon).Contains(':', StringComparison.Ordinal), "aucun deux-points dans le plan");
    }

    [Test]
    public static void Step_state_never_claims_success()
    {
        var logon = AssistanceRecipes.Find("logon")!;
        var account = logon.Steps[0];
        var lockouts = logon.Steps[1];
        var reach = logon.Steps[3];
        Check.Equal("Sélectionnez le compte concerné.", AssistanceRecipes.State(lockouts, false, null, Paris).Text, "compte attendu");
        Check.Equal("Sélectionnez le poste concerné.", AssistanceRecipes.State(reach, false, null, Paris).Text, "poste attendu");
        Check.False(AssistanceRecipes.State(reach, false, null, Paris).CanRun, "rien ne part sans sujet");
        var viewOnly = AssistanceRecipes.State(account, true, null, Paris);
        Check.True(viewOnly.CanOpen && !viewOnly.CanRun, "étape sans lecture : vue seulement");
        Check.Equal("À lancer", AssistanceRecipes.State(lockouts, true, null, Paris).Text, "à lancer");
        var at = new DateTimeOffset(2026, 10, 21, 12, 5, 0, TimeSpan.Zero);
        var read = AssistanceRecipes.State(lockouts, true, new StepLaunch(at, StepOutcome.Read, null, null, null), Paris);
        Check.Equal("Lue à 14:05" + FrenchText.Colon + "résultat ci-dessous", read.Text, "heure locale de Paris");
        Check.Equal(Tone.Info, read.Tone, "une lecture n’est pas un succès");
        Check.Contains("rien n’a été lu", AssistanceRecipes.State(lockouts, true, new StepLaunch(at, StepOutcome.Refused, null, "x", "y"), Paris).Text, "refus");
        Check.Contains("rien n’est relancé seul", AssistanceRecipes.State(lockouts, true, new StepLaunch(at, StepOutcome.Failed, null, "x", "y"), Paris).Text, "échec");
    }

    // ---------------------------------------------------------------- captures

    [Test]
    public static void Support_text_masks_secrets_and_bounds_values()
    {
        Check.Equal("password=" + SupportText.Masked, SupportText.Clean("password=Hunter2!"), "mot de passe masqué");
        Check.Contains("Bearer " + SupportText.Masked, SupportText.Clean("Authorization: Bearer abc.def"), "jeton masqué");
        Check.Equal(SupportText.RecoveryKeyMasked, SupportText.Clean("123456-123456-123456-123456-123456-123456-123456-123456"), "clé de récupération");
        Check.Equal(SupportText.Excluded, SupportText.Clean(new byte[] { 1, 2 }), "octets exclus");
        Check.Equal(SupportText.Unsupported, SupportText.Clean(new object()), "objet non pris en charge");
        Check.True(SupportText.Clean(new string('x', 2000)).EndsWith(SupportText.Truncated, StringComparison.Ordinal), "valeur tronquée");
        Check.Equal("a b", SupportText.Clean("a\u0001b"), "caractère de contrôle remplacé");
        Check.Equal("2026-10-21T16:26:00.0000000Z", SupportText.Clean(Now), "date UTC au format o");
    }

    [Test]
    public static void Snapshot_keeps_the_allowlist_only_and_marks_partial_fields()
    {
        var guid = Guid.Parse("443838bd-e367-498e-9a78-0f7f0746cc8f");
        var many = Enumerable.Range(0, 140).Select(i => (object?)("CN=G" + i + "," + Root)).ToList();
        var snapshot = SupportSnapshots.Create(Props(("objectGUID", guid), ("unicodePwd", "secret"), ("sAMAccountName", "c.bernard"), ("memberOf", many),
            ("description", "password=abc"), ("title", "token: 123")), Root.ToUpperInvariant(), "CN=X," + Root, "X", "user", SnapshotSource.Live, Now, Now);
        Check.Equal(29, snapshot.Fields.Length, "29 attributs de la liste blanche (comme le code de Domenia 1)");
        Check.Null(snapshot.Field("unicodePwd"), "attribut secret ignoré");
        Check.Null(snapshot.Field("description"), "note libre ignorée");
        Check.Equal("guid:" + guid.ToString("D"), snapshot.Identity, "identité par GUID");
        Check.Equal("dc=example,dc=local", snapshot.Scope, "périmètre en minuscules");
        Check.Equal(FieldCoverage.Partial, snapshot.Coverage("memberOf"), "plus de 128 valeurs : partiel");
        Check.Equal(SupportSnapshots.MaxValues, snapshot.Field("memberOf")!.Values.Length, "128 valeurs au plus");
        Check.Equal(FieldCoverage.Partial, snapshot.Coverage("title"), "valeur masquée : partiel");
        Check.Equal(FieldCoverage.NotProvided, snapshot.Coverage("mail"), "non fourni");
        Check.Equal(FieldCoverage.Provided, snapshot.Coverage("sAMAccountName"), "fourni");
        var ranged = SupportSnapshots.Create(Props(("memberOf;range=0-1499", "CN=G," + Root)), Root, "CN=Y," + Root, "Y", "user", SnapshotSource.Live, Now, Now);
        Check.Equal(FieldCoverage.Partial, ranged.Coverage("memberOf"), "memberOf découpé : partiel");
        Check.Equal("dn:cn=y,dc=example,dc=local", ranged.Identity, "identité par DN sans GUID");
        var incomplete = SupportSnapshots.Create(Props(("memberOf", "CN=G," + Root)), Root, "CN=Z," + Root, "Z", "user", SnapshotSource.Live, Now, Now, memberOfComplete: false);
        Check.Equal(FieldCoverage.Partial, incomplete.Coverage("memberOf"), "memberOf incomplet : partiel");
    }

    // ---------------------------------------------------------------- findings

    [Test]
    public static void Findings_follow_the_rules_of_Domenia_1()
    {
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 512), ("msDS-User-Account-Control-Computed", 16)), Now, Paris)).Contains("ACCOUNT_LOCKED"), "verrouillé");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 512), ("msDS-User-Account-Control-Computed", 0x800000)), Now, Paris)).Contains("PASSWORD_EXPIRED"), "mot de passe expiré");
        var history = Codes(SupportFindings.Analyse(User(("userAccountControl", 512), ("lockoutTime", 133_000_000_000_000_000L)), Now, Paris));
        Check.True(history.Contains("LOCKOUT_HISTORY") && !history.Contains("ACCOUNT_LOCKED"), "trace sans état calculé : à vérifier, pas verrouillé");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 514)), Now, Paris)).Contains("ACCOUNT_DISABLED"), "désactivé");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 512), ("pwdLastSet", 0L)), Now, Paris)).Contains("PASSWORD_CHANGE_REQUIRED"), "changement exigé");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 0x10200), ("pwdLastSet", 0L)), Now, Paris)).Contains("PASSWORD_STATE_REVIEW"), "pwdLastSet à zéro et non-expiration");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 0x10200)), Now, Paris)).Contains("PASSWORD_NO_EXPIRY"), "non-expiration");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 512), ("accountExpires", AdValues.ToFileTime(Now.AddDays(-1)))), Now, Paris)).Contains("ACCOUNT_EXPIRED"), "compte expiré");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 512), ("accountExpires", AdValues.ToFileTime(Now.AddDays(3)))), Now, Paris)).Contains("ACCOUNT_EXPIRING"), "compte expirant");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 512), ("accountExpires", long.MaxValue - 1)), Now, Paris)).Contains("EXPIRY_INVALID"), "date illisible");
        Check.True(Codes(SupportFindings.Analyse(User(("adminCount", 1), ("userAccountControl", 512)), Now, Paris)).Contains("ADMINCOUNT"), "adminCount");
        Check.True(Codes(SupportFindings.Analyse(User(), Now, Paris)).Contains("UAC_UNKNOWN"), "UAC absent : indéterminé");
        Check.True(Codes(SupportFindings.Analyse(User(("userAccountControl", 512)), Now, Paris)).SequenceEqual(["NO_FINDING"]), "aucun signal, limite dite");
        var old = SupportSnapshots.Create(Props(("userAccountControl", 512)), Root, "CN=X," + Root, "X", "user", SnapshotSource.Live, Now.AddMinutes(-20), Now);
        Check.True(Codes(SupportFindings.Analyse(old, Now, Paris)).Contains("DATA_OLD"), "lecture de plus de 15 minutes");
        var cached = SupportSnapshots.Create(Props(("userAccountControl", 512)), Root, "CN=X," + Root, "X", "user", SnapshotSource.Cache, Now, Now);
        Check.True(Codes(SupportFindings.Analyse(cached, Now, Paris)).Contains("DATA_NOT_LIVE"), "cache : lecture non établie");
    }

    [Test]
    public static void Machine_rules_use_the_signals_without_any_secret()
    {
        var computer = SupportSnapshots.Create(Props(("userAccountControl", 4096)), Root, "CN=PC-1,OU=Postes," + Root, "PC-1", "computer", SnapshotSource.Live, Now, Now);
        var signals = new MachineSignals(LapsKind.Windows, Now.AddDays(-2), false, Now.AddHours(-1), 6.4, Now.AddDays(-45), Now.AddDays(-120));
        var codes = Codes(SupportFindings.Analyse(computer, Now, Paris, signals));
        foreach (var code in new[] { "DNS_NOT_PROVIDED", "LAPS_EXPIRED", "NO_ANSWER", "DISK_LOW", "UPTIME_LONG", "COMPUTER_STALE" })
        {
            Check.True(codes.Contains(code), "règle machine : " + code);
        }
        var none = Codes(SupportFindings.Analyse(computer, Now, Paris, signals with { Laps = LapsKind.None }));
        Check.True(none.Contains("LAPS_ABSENT") && !none.Contains("LAPS_EXPIRED"), "LAPS absent");
        var text = string.Join(" ", SupportFindings.Analyse(computer, Now, Paris, signals).Select(f => f.Evidence + f.Next));
        Check.False(text.Contains("mot de passe :", StringComparison.OrdinalIgnoreCase), "aucune valeur LAPS");
    }

    // ---------------------------------------------------------------- comparison

    [Test]
    public static void Comparison_is_refused_across_domains_or_kinds_and_ignores_case_in_memberOf()
    {
        var a = User(("userAccountControl", 512), ("memberOf", (IReadOnlyList<object?>)["CN=GG-A," + Root, "CN=GG-B," + Root]), ("title", "Vendeur"));
        var b = User(("userAccountControl", 512), ("memberOf", (IReadOnlyList<object?>)["cn=gg-b," + Root.ToLowerInvariant(), "CN=GG-C," + Root]), ("mail", "x@example.local"));
        var cmp = SupportComparison.Compare(a, b);
        Check.True(cmp.Ready && cmp.SameObject, "même objet");
        var memberOf = cmp.Rows.Single(r => r.Attribute == "memberOf");
        Check.Equal(CompareStatus.Different, memberOf.Status, "groupes différents");
        Check.True(memberOf.Added.SequenceEqual(["CN=GG-C," + Root]) && memberOf.Removed.SequenceEqual(["CN=GG-A," + Root]), "casse ignorée, ajouts et retraits");
        Check.Equal(CompareStatus.Undetermined, cmp.Rows.Single(r => r.Attribute == "title").Status, "attribut absent d’un côté : indéterminé, jamais supprimé");
        Check.Equal(SupportComparison.NotProvided, cmp.Rows.Single(r => r.Attribute == "title").After, "non fourni dit");
        var other = SupportSnapshots.Create(Props(("userAccountControl", 4096)), Root, "CN=PC," + Root, "PC", "computer", SnapshotSource.Live, Now, Now);
        Check.NotNull(SupportComparison.Compare(a, other).Refusal, "types différents refusés");
        var foreign = SupportSnapshots.Create(Props(("userAccountControl", 512)), "DC=other,DC=local", "CN=X,DC=other,DC=local", "X", "user", SnapshotSource.Live, Now, Now);
        Check.NotNull(SupportComparison.Compare(a, foreign).Refusal, "périmètres différents refusés");
        Check.False(SupportComparison.Compare(a, null).Ready, "un emplacement vide");
    }

    // ---------------------------------------------------------------- incidents

    [Test]
    public static void Incidents_are_classified_by_fixed_rules()
    {
        (string Text, string Code)[] cases =
        [
            ("Erreur système 1219 : connexions multiples", "SMB_SESSION_CONFLICT"),
            ("Opération annulée par l’opérateur", "CANCELLED"),
            ("Échec d’ouverture de session (0x8007052E)", "AUTH_CONTEXT"),
            ("Accès refusé (0x80070005)", "ACCESS_DENIED"),
            ("Le serveur RPC n’est pas disponible (0x800706BA)", "RPC_UNAVAILABLE"),
            ("Délai dépassé après 60 s", "TIMEOUT"),
            ("Hôte inconnu : pc.example.local", "DNS_NETWORK"),
            ("Le moteur exécute déjà 8 tâches", "ENGINE_BUSY"),
            ("Moteur occupé" + FrenchText.Colon + "3 lectures en cours et 12 en attente. Rien n’a été lancé", "ENGINE_BUSY"),
            ("Assistance · refus assistance.engineBusy" + FrenchText.Colon + "réessayez après la fin des lectures", "ENGINE_BUSY"),
            ("PsExec code 1", "PSEXEC_LICENSE"),
            ("Lecture BitLocker refusée pour l’OU Marseille", "READ_REFUSED"),
            ("Tout va bien", "UNCLASSIFIED"),
        ];
        foreach (var (text, code) in cases)
        {
            Check.True(SupportIncidents.Hints(text).Any(h => h.Code == code), $"« {text} » → {code}");
        }
        Check.True(SupportIncidents.Hints(new string('a', 20_000) + " 1219").All(h => h.Code == "UNCLASSIFIED"), "texte borné à 8 192 caractères");
        var first = SupportIncidents.Create(new RawIncident("k1", Now, Tone.Warn, "Zone", "Accès refusé", "session"), "1");
        var second = SupportIncidents.Create(new RawIncident("k2", Now.AddSeconds(1), Tone.Warn, "Zone", "Accès refusé", "session"), "2");
        var later = SupportIncidents.Create(new RawIncident("k3", Now.AddSeconds(3), Tone.Warn, "Zone", "Accès refusé", "session"), "3");
        Check.True(SupportIncidents.IsAdjacentDuplicate(first, second), "doublon adjacent de moins de 2 s");
        Check.False(SupportIncidents.IsAdjacentDuplicate(first, later), "au-delà de 2 s : gardé");
        Check.True(SupportIncidents.Matches(first, "access_denied") && SupportIncidents.Matches(first, "zone") && !SupportIncidents.Matches(first, "(.*)"), "filtre littéral");
    }

    // ---------------------------------------------------------------- pseudonyms and ticket report

    [Test]
    public static void Pseudonyms_need_a_key_and_are_stable()
    {
        Check.Throws<DomeniaOperationException>(() => Pseudonyms.Of("Camille", "court", "Utilisateur"), "clé trop courte refusée");
        var one = Pseudonyms.Of("Camille Bernard", "cle-de-test-1", "Utilisateur");
        Check.Equal(one, Pseudonyms.Of("camille bernard", "cle-de-test-1", "Utilisateur"), "casse ignorée, même clé, même pseudonyme");
        Check.False(one == Pseudonyms.Of("Camille Bernard", "cle-de-test-2", "Utilisateur"), "autre clé, autre pseudonyme");
        Check.True(one.StartsWith("Utilisateur-", StringComparison.Ordinal) && one.Length == "Utilisateur-".Length + 8, "famille et 8 hexadécimaux");
        var map = Pseudonyms.Map([new KnownName("Camille", "Utilisateur", "Utilisateur"), new KnownName("Camille Bernard", "Utilisateur", "Utilisateur")], "cle-de-test-1", ["Utilisateur"]);
        var masked = Pseudonyms.Mask("Camille Bernard et Camille", map);
        Check.False(masked.Contains("Camille", StringComparison.Ordinal), "noms masqués, le plus long d’abord");
    }

    [Test]
    public static void Ticket_report_keeps_the_object_only_and_never_puts_the_map_in_the_text()
    {
        var guid = Guid.NewGuid().ToString("D");
        TicketStep[] steps =
        [
            new(guid, "Confirmed", Now, "Verrouillages", "6 verrouillages depuis PC-LYO-0042", false, "EXAMPLE\\adm-j.martin"),
            new(guid, "Refused", Now, "Inventaire", "Accès refusé", false, null),
            new(guid, "Sent", Now, "Déverrouillage", "password=secret", false, null),
            new(guid, "NotTested", null, "Sessions", null, false, null),
            new(guid, "Failed", Now, "Identité", "détail", true, null),
            new(Guid.NewGuid().ToString("D"), "Confirmed", Now, "Autre objet", null, false, null),
            new(null, "Confirmed", Now, "Sans GUID", null, false, null),
        ];
        var subject = new TicketSubject(guid, "user", "Camille Bernard", ["c.bernard"]);
        var all = TicketReport.SectionIds;
        var refusedNoGuid = TicketReport.Build(subject with { Guid = null }, steps, all, false, null, null, null, Now, TestClock.Paris);
        Check.False(refusedNoGuid.Ready, "objet sans GUID refusé");
        var refusedKey = TicketReport.Build(subject, steps, all, true, "court", null, null, Now, TestClock.Paris);
        Check.False(refusedKey.Ready, "pseudonymisation sans clé refusée");
        Check.Equal("", refusedKey.Text, "aucun aperçu en clair à la place");
        var plain = TicketReport.Build(subject, steps, all, false, null, null, null, Now, TestClock.Paris);
        Check.True(plain.Ready, "compte rendu produit");
        Check.Equal(new TicketCounts(2, 1, 1, 1), plain.Counts!, "tenté (envoyé, échec), confirmé, refusé, non testé");
        Check.Equal(new TicketExcluded(1, 1), plain.Excluded!, "autre objet et non rattaché écartés");
        Check.Contains("[détail sensible retiré]", plain.Text, "détail sensible retiré");
        Check.Contains("Envoyé, issue non confirmée", plain.Text, "envoyé n’est pas fait");
        Check.False(plain.Text.Contains("secret", StringComparison.OrdinalIgnoreCase) && !plain.Text.Contains("password=***", StringComparison.Ordinal), "secret masqué");
        var masked = TicketReport.Build(subject, steps, all, true, "cle-de-test-1", null, [new KnownName("EXAMPLE\\adm-j.martin", "Compte", "Compte")], Now, TestClock.Paris);
        Check.False(masked.Text.Contains("Camille", StringComparison.Ordinal) || masked.Text.Contains("c.bernard", StringComparison.Ordinal), "noms pseudonymisés");
        Check.True(masked.Map.Length > 0 && masked.Map.All(e => !masked.Text.Contains(e.Original, StringComparison.Ordinal)), "table hors du texte");
        Check.Equal(TicketReport.Hash(masked.Text), masked.Sha256, "empreinte du texte");
    }

    // ---------------------------------------------------------------- capture files

    [Test]
    public static void Capture_files_round_trip_and_refuse_foreign_or_future_captures()
    {
        var snapshot = User(("objectGUID", Guid.NewGuid()), ("userAccountControl", 512), ("sAMAccountName", "c.bernard"));
        var text = CaptureFiles.Export(snapshot);
        using (var document = JsonDocument.Parse(text))
        {
            Check.Equal("Domenia.Capture.1", document.RootElement.GetProperty("Format").GetString(), "format");
            Check.Equal("Cache", document.RootElement.GetProperty("Capture").GetProperty("Source").GetString(), "un fichier n’est jamais une lecture fraîche");
            Check.Equal("Utilisateur", document.RootElement.GetProperty("Capture").GetProperty("Type").GetString(), "type de Domenia 1");
        }
        var back = CaptureFiles.Import(text, Root, Now);
        Check.Equal(snapshot.Identity, back.Identity, "même identité");
        Check.Equal(SnapshotSource.Cache, back.Source, "capture historique");
        Check.Equal(FieldCoverage.Provided, back.Coverage("sAMAccountName"), "fourni conservé");
        Check.Equal(FieldCoverage.Partial, back.Coverage("mail"), "non fourni devient partiel");
        Check.Equal(AssistanceErrors.CaptureInvalid, Check.Throws<DomeniaOperationException>(() => CaptureFiles.Import(text, "DC=other,DC=local", Now), "autre domaine").Code, "code");
        Check.Throws<DomeniaOperationException>(() => CaptureFiles.Import(text, Root, Now.AddDays(-1)), "capture datée dans le futur");
        Check.Throws<DomeniaOperationException>(() => CaptureFiles.Import("{\"Format\":\"Autre\"}", Root, Now), "format inconnu");
        Check.Throws<DomeniaOperationException>(() => CaptureFiles.Import("pas du JSON", Root, Now), "JSON illisible");
        var node = JsonNode.Parse(text)!;
        node["Capture"]!["Fields"]!["unicodePwd"] = new JsonArray((JsonNode?)JsonValue.Create("secret"));
        Check.Null(CaptureFiles.Import(node.ToJsonString(), Root, Now).Field("unicodePwd"), "hors liste blanche ignoré au chargement");
    }

    // ---------------------------------------------------------------- offline dossier

    [Test]
    public static void Offline_dossier_never_takes_the_whole_domain_and_hashes_every_file()
    {
        var pins = new[] { new OfflineDossiers.Workstation(Guid.NewGuid().ToString("D"), "PC-1") };
        Check.False(OfflineDossiers.Perimeter(DossierScope.WorkingOu, null, new ScopeSelection(Root, "example.local", true), Root, pins).Valid, "tout le domaine refusé");
        Check.False(OfflineDossiers.Perimeter(DossierScope.Subject, null, null, Root, pins).Valid, "aucun poste choisi");
        Check.Equal(1, OfflineDossiers.Perimeter(DossierScope.Pins, null, null, Root, pins).Count, "postes épinglés");
        var ou = OfflineDossiers.Perimeter(DossierScope.WorkingOu, null, new ScopeSelection("OU=Lyon,OU=Postes," + Root, "Lyon", true), Root, pins);
        Check.True(ou.Valid && ou.Kind == "OU", "OU de travail");
        // Local time of the operator, as every other export (16:26 UTC is 18:26 in Paris on 21 October 2026).
        Check.Equal("Domenia-Diagnostic-PC-LYO-0042-20261021-1826", OfflineDossiers.FolderName("PC LYO/0042", Now, TestClock.Paris), "nom du dossier à l’heure locale");
        Check.True(OfflineDossiers.IsSecretName("ms-Mcs-AdmPwd") && OfflineDossiers.IsSecretName("BitLockerRecoveryKey") && !OfflineDossiers.IsSecretName("pwdLastSet"), "noms secrets");
        var computers = new JsonArray((JsonNode?)new JsonObject { ["Nom"] = "PC-1", ["LapsPassword"] = "x", ["Systeme"] = "Windows 11" });
        var data = new DossierData(new JsonObject { ["Base"] = "test" }, new JsonObject { ["Objets"] = 1 }, computers, false, new JsonArray(), false, new JsonArray(), new JsonArray(), []);
        var request = new DossierRequest(ou, OfflineDossiers.Sections(["requetes"]), 1000);
        var build = OfflineDossiers.Build(request, data, "Lyon", "2.0.0-dev", Now, TestClock.Paris);
        string[] names = [.. build.Files.Select(f => f.Name)];
        Check.True(names.SequenceEqual(["etat.json", "postes.json", "requetes.json", "LISEZMOI.txt", "manifeste.json", "SHA256SUMS.txt"]), "fichiers : " + string.Join(",", names));
        Check.False(build.Files.Single(f => f.Name == "postes.json").Text.Contains("LapsPassword", StringComparison.Ordinal), "champ secret retiré");
        Check.True(build.Excluded.Contains("postes[0].LapsPassword"), "exclusion dite");
        foreach (var file in build.Files)
        {
            Check.Equal(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(file.Text))), file.Sha256, "empreinte de " + file.Name);
        }
        var sums = build.Files.Single(f => f.Name == "SHA256SUMS.txt").Text;
        Check.Contains(build.Files[0].Sha256 + "  etat.json", sums, "SHA256SUMS");
    }

    // ---------------------------------------------------------------- support dossier

    [Test]
    public static void Support_dossier_has_its_sections_templates_and_a_strict_html()
    {
        var snapshot = User(("userAccountControl", 512), ("msDS-User-Account-Control-Computed", 16));
        var incident = SupportIncidents.Create(new RawIncident("k", Now, Tone.Alert, "Poste", "Le serveur RPC n’est pas disponible (0x800706BA) : brut-secret", "session"), "i");
        var input = new SupportReportInput(snapshot, SupportFindings.Analyse(snapshot, Now, Paris), snapshot, snapshot, incident, "INC-1\u0001\r\n2", ReportTemplate.Text, Now, Paris, "Domenia 2.0.0-dev");
        var text = SupportReport.Build(input);
        foreach (var part in new[] { "DOMENIA | DOSSIER SUPPORT", "Référence du ticket" + FrenchText.Colon + "INC-1 2", "OBJET OBSERVÉ", "CONSTATS ET VÉRIFICATIONS", "COMPARAISON A / B", "INCIDENT DE SESSION CHOISI MANUELLEMENT", "LIMITES" })
        {
            Check.Contains(part, text, "section : " + part);
        }
        Check.False(text.Contains("brut-secret", StringComparison.Ordinal), "le message brut de l’incident n’est jamais exporté");
        Check.Contains("### Objet observé", SupportReport.Build(input with { Template = ReportTemplate.Glpi }), "gabarit GLPI");
        Check.Contains("=== OBJET OBSERVÉ ===", SupportReport.Build(input with { Template = ReportTemplate.ServiceNow }), "gabarit ServiceNow");
        Check.Equal(80, SupportReport.CleanReference(new string('x', 200)).Length, "référence bornée à 80");
        var html = SupportReport.Html("<script>alert(1)</script>", "Dossier support", "abc");
        Check.False(html.Contains("<script>", StringComparison.Ordinal), "texte encodé");
        Check.False(html.Contains("unsafe-inline", StringComparison.Ordinal), "aucun style inline permis");
        var style = html[(html.IndexOf("<style>", StringComparison.Ordinal) + 7)..html.IndexOf("</style>", StringComparison.Ordinal)];
        Check.Contains("'sha256-" + Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(style))) + "'", html, "style épinglé par son empreinte");
    }
}
