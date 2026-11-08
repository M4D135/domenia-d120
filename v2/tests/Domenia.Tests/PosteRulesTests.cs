using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

/// <summary>Pure rules of the workstation console (screen « poste », docs/ops/poste.md): no source, no bridge.</summary>
internal static class PosteRulesTests
{
    private static AttentionPoint Point(AttentionLevel level, string rule = "disk.free", string? reason = null) =>
        new(level, "Point " + level, rule, null, reason);

    [Test]
    public static void Health_score_follows_domenia_1()
    {
        var policy = PosteHealthPolicy.Default;
        var clean = PosteBoardBuilder.Health([], policy, null, null);
        Check.Equal(100, clean.Score, "aucun point : 100");
        Check.Equal("Bon état", clean.Verdict, "verdict sans point");

        var watch = PosteBoardBuilder.Health([Point(AttentionLevel.Warn), Point(AttentionLevel.Info)], policy, null, null);
        Check.Equal(90, watch.Score, "un point à surveiller : −10, l’information ne compte pas");
        Check.Equal("À surveiller", watch.Verdict, "verdict à surveiller");

        var critical = PosteBoardBuilder.Health([Point(AttentionLevel.Alert), Point(AttentionLevel.Warn)], policy, null, null);
        Check.Equal(65, critical.Score, "−25 et −10");
        Check.Equal("Critique", critical.Verdict, "un point critique suffit");

        var degraded = PosteBoardBuilder.Health([.. Enumerable.Range(0, 5).Select(_ => Point(AttentionLevel.Warn))], policy, null, null);
        Check.Equal(50, degraded.Score, "cinq points à surveiller");
        Check.Equal("Dégradé", degraded.Verdict, "sous 60 sans point critique");

        var floor = PosteBoardBuilder.Health([.. Enumerable.Range(0, 6).Select(_ => Point(AttentionLevel.Alert))], policy, null, null);
        Check.Equal(0, floor.Score, "jamais sous 0");
    }

    [Test]
    public static void Health_without_reading_never_claims_a_good_state()
    {
        var partial = PosteBoardBuilder.Health([], PosteHealthPolicy.Default, "Aucun inventaire : contrôles incomplets.", "inventory.quick");
        Check.Null(partial.Score, "aucun score sans données");
        Check.Equal("Données insuffisantes", partial.Verdict, "pas de « Bon état » inventé");
        Check.Equal(Tone.Off, partial.State, "ton neutre");

        var suppressed = PosteBoardBuilder.Health([Point(AttentionLevel.Alert, reason: "Règle désactivée dans les règles de santé")], PosteHealthPolicy.Default, null, null);
        Check.Equal(100, suppressed.Score, "un point d’une règle désactivée ne compte pas");
        Check.Equal(1, suppressed.Suppressed.Length, "mais il reste explicable");
    }

    [Test]
    public static void Routes_accept_the_tab_names_of_domenia_1()
    {
        Check.Equal("diagnostic", PosteRoutes.Resolve("TabWmi")!.View, "TabWmi");
        Check.Equal("wmi", PosteRoutes.Resolve("TabWmi")!.Tab, "onglet WMI");
        Check.Equal("inventaire", PosteRoutes.Resolve("TabSoftware")!.View, "TabSoftware");
        Check.Equal("logiciels", PosteRoutes.Resolve("TabSoftware")!.Tab, "onglet logiciels");
        Check.Equal("secrets", PosteRoutes.Resolve("TabSecurity")!.View, "TabSecurity");
        Check.Equal("intervenir", PosteRoutes.Resolve("intervenir")!.View, "vue de Domenia 2");
        Check.Null(PosteRoutes.Resolve("TabInconnu"), "nom inconnu : aucune route");
        Check.Null(PosteRoutes.Resolve(""), "vide : aucune route");
    }

    [Test]
    public static void Event_queries_are_bounded_and_say_so()
    {
        var preset = PosteEvents.Preset("Startup") ?? PosteEvents.Presets[0];
        var now = TestClock.Reference;
        var big = PosteEvents.Query(preset, 5000, 999, now);
        Check.Equal(720, big.WindowHours, "720 h au plus");
        Check.Equal(200, big.MaxEvents, "200 événements au plus");
        Check.True(big.Clamped, "la borne est dite");
        Check.Equal(now.AddHours(-720), big.Start, "début de la fenêtre");
        var small = PosteEvents.Query(preset, 0, 0, now);
        Check.Equal(1, small.WindowHours, "1 h au moins");
        Check.Equal(1, small.MaxEvents, "1 événement au moins");
        var exact = PosteEvents.Query(preset, 72, 50, now);
        Check.False(exact.Clamped, "valeurs admises : aucune borne");
    }

    [Test]
    public static void Wmi_explorer_reads_only_and_blocks_the_msi_provider()
    {
        var (ok, okReason) = PosteWmi.Validate(@"root\cimv2", "Win32_OperatingSystem", null, null);
        Check.NotNull(ok, "requête simple admise : " + okReason);
        Check.Equal("SELECT * FROM Win32_OperatingSystem", PosteWmi.Query(ok!), "requête affichée");
        Check.Equal(25, ok!.Limit, "25 instances par défaut");
        Check.Equal(500, PosteWmi.Validate(@"root\cimv2", "Win32_Service", "State='Running'", 9999).Request!.Limit, "500 instances au plus");
        Check.Null(PosteWmi.Validate(@"root\cimv2", "Win32_Product", null, null).Request, "Win32_Product bloquée");
        Check.Null(PosteWmi.Validate(@"root\cimv2", "Win32_Service", "Name='a'; DELETE", null).Request, "point-virgule refusé");
        Check.Null(PosteWmi.Validate("cimv2", "Win32_Service", null, null).Request, "espace de noms hors de root");
        Check.Null(PosteWmi.Validate(@"root\cimv2", "Win32 Service", null, null).Request, "nom de classe invalide");
    }

    [Test]
    public static void Services_profile_knows_expected_stops_and_valid_names()
    {
        Check.True(PosteServices.IsValidName("Spooler"), "nom simple");
        Check.True(PosteServices.IsValidName("MSSQL$SQLEXPRESS"), "instance nommée");
        Check.False(PosteServices.IsValidName("Spooler & calc"), "caractères refusés");
        Check.False(PosteServices.IsValidName(""), "vide refusé");
        Check.True(PosteServices.Profile.Length >= 10, "profil de référence des services de gestion");
    }

    [Test]
    public static void Wake_on_lan_needs_a_valid_card_and_an_allowed_subnet()
    {
        Check.Equal("00-11-22-33-44-55", PosteRemote.Mac("00:11:22:33:44:55").Normalized, "deux-points acceptés");
        Check.Equal("00-11-22-33-44-55", PosteRemote.Mac("0011.2233.4455").Normalized, "format Cisco accepté");
        Check.False(PosteRemote.Mac("FF-FF-FF-FF-FF-FF").Valid, "diffusion refusée");
        Check.False(PosteRemote.Mac("01-00-5E-00-00-01").Valid, "multicast refusé");
        Check.False(PosteRemote.Mac("00-00-00-00-00-00").Valid, "adresse nulle refusée");
        var packet = PosteRemote.WakePacket("00-11-22-33-44-55");
        Check.Equal(102, packet.Length, "102 octets");
        Check.True(packet.Take(6).All(b => b == 0xFF), "six octets 0xFF");
        Check.Equal((byte)0x55, packet[101], "adresse répétée 16 fois");
        Check.Equal("10.20.3.255", PosteRemote.Broadcast("10.20.1.17", 22), "diffusion dirigée d’un /22");
        Check.Equal("", PosteRemote.Broadcast("10.20.0.0", 22), "adresse de réseau refusée");
        Check.True(PosteRemote.InNetwork("10.20.1.17", "10.0.0.0/8"), "dans le périmètre");
        Check.False(PosteRemote.InNetwork("192.168.1.10", "10.0.0.0/8"), "hors du périmètre");
        Check.False(PosteRemote.Wake(false, ["10.0.0.0/8"], "00-11-22-33-44-55", "10.20.1.17", 22).Allowed, "désactivé par défaut");
        Check.False(PosteRemote.Wake(true, ["10.0.0.0/8"], "00-11-22-33-44-55", "192.168.1.10", 24).Allowed, "réseau hors périmètre");
        var allowed = PosteRemote.Wake(true, ["10.0.0.0/8"], "00-11-22-33-44-55", "10.20.1.17", 22);
        Check.True(allowed.Allowed, "un poste, une carte, un sous-réseau autorisé");
        Check.Equal("10.20.3.255", allowed.Broadcast, "diffusion du sous-réseau du poste");
    }

    [Test]
    public static void Restart_and_run_requests_are_checked_before_any_plan()
    {
        var (now, nowRequest) = PosteRemote.Restart("PC-PAR-0001", "now", null, null, winRmAllowed: false);
        Check.True(now.Valid && nowRequest!.Now, "immédiat sans WinRM");
        var (delayedRefused, _) = PosteRemote.Restart("PC-PAR-0001", "delayed", 15, null, winRmAllowed: false);
        Check.False(delayedRefused.Valid, "différé refusé sans WinRM");
        var (delayed, request) = PosteRemote.Restart("PC-PAR-0001", "delayed", 15, "Merci d’enregistrer\nvotre travail \"maintenant\"", winRmAllowed: true);
        Check.True(delayed.Valid, "différé admis");
        Check.Equal(900, request!.DelaySeconds, "15 minutes");
        Check.False(request.Message.Contains('\n', StringComparison.Ordinal), "aucun retour à la ligne dans le message");
        Check.False(request.Message.Contains('"', StringComparison.Ordinal), "aucun guillemet droit dans le message");
        Check.False(PosteRemote.Restart("PC-PAR-0001", "delayed", 15, new string('x', 401), true).Check.Valid, "message de plus de 400 caractères refusé");
        Check.False(PosteRemote.Restart("PC-PAR-0001", "plus tard", null, null, true).Check.Valid, "mode inconnu refusé");

        Check.True(PosteRemote.Run("PC-PAR-0001", "system", @"C:\Windows\System32\notepad.exe", null, null, true).Check.Valid, "arrière-plan admis");
        Check.False(PosteRemote.Run("PC-PAR-0001", "interactive", @"C:\Windows\System32\notepad.exe", null, null, true).Check.Valid, "session sans compte refusée");
        Check.False(PosteRemote.Run("PC-PAR-0001", "system", "cmd.exe\r\ncalc.exe", null, null, true).Check.Valid, "caractère de contrôle refusé");
        Check.False(PosteRemote.Run("PC-PAR-0001", "system", "", null, null, true).Check.Valid, "programme absent refusé");
    }

    [Test]
    public static void Commands_quote_values_and_never_carry_a_password()
    {
        var commands = PosteRemote.Commands("PC-PAR-0001.example.local", @"EXAMPLE\adm-j.martin");
        Check.Equal(@"Enter-PSSession -ComputerName 'PC-PAR-0001.example.local' -Credential 'EXAMPLE\adm-j.martin'", commands.PsRemote, "Enter-PSSession");
        Check.Equal(@"\\PC-PAR-0001.example.local\c$", commands.Unc, "chemin UNC");
        Check.True(commands.UsesCredential, "compte d’exploitation déclaré");
        Check.Contains("jamais copié", commands.PsStatus, "le mot de passe n’est jamais copié");
        Check.Contains("'O''Neil'", PosteRemote.Commands("O'Neil", null).PsRemote, "apostrophe doublée");
        Check.False(PosteRemote.Commands("PC-PAR-0001", null).PsRemote.Contains("-Credential", StringComparison.Ordinal), "sans compte : session Windows");
    }

    [Test]
    public static void Suite_tools_receive_declared_fields_only()
    {
        var context = new Dictionary<string, string?>(StringComparer.Ordinal)
        {
            ["ComputerName"] = "PC-PAR-0001",
            ["ComputerGuid"] = "not-a-guid",
            ["UserLogin"] = "j.martin",
            ["UserGuid"] = null,
            ["Domain"] = "example.local",
        };
        Check.False(PosteRemote.Suite("Pesto", null, context, explicitGesture: false).Allowed, "jamais sans geste explicite");
        var plan = PosteRemote.Suite("Pesto", null, context, explicitGesture: true);
        Check.True(plan.Allowed, "ouverture admise sur geste");
        Check.Equal("NoArgument", plan.Mode, "sans contrat reconnu : aucun argument");
        Check.True(plan.Arguments.IsEmpty, "rien n’est transmis");
    }

    [Test]
    public static void Recovery_keys_stay_children_of_the_open_workstation()
    {
        const string Computer = "CN=PC-PAR-0001,OU=Paris,OU=Postes,DC=example,DC=local";
        Check.True(PosteSecrets.IsDirectChild(Computer, "CN=2026-10-01T10:00:00-00:00{AB12CD34-0000-0000-0000-000000000000}," + Computer), "enfant direct");
        Check.False(PosteSecrets.IsDirectChild(Computer, "CN=x,CN=y," + Computer), "petit-enfant refusé");
        Check.False(PosteSecrets.IsDirectChild(Computer, "CN=x,CN=PC-PAR-0002,OU=Paris,OU=Postes,DC=example,DC=local"), "autre poste refusé");
        Check.False(PosteSecrets.IsDirectChild(Computer, "pas un DN"), "DN mal formé refusé");
        var blocks = PosteSecrets.Blocks("000011-000022-000033-000044-000055-000066-000077-000088");
        Check.Equal(8, blocks.Length, "huit blocs");
        Check.Equal("Bloc 1", blocks[0].Label, "blocs numérotés");
        Check.True(PosteSecrets.Blocks("1234-5678").IsEmpty, "autre forme : aucun bloc dicté");
        var keys = ImmutableArray.Create(
            new BitLockerKeyInfo("AB12CD34", "AB12CD34-1111-2222-3333-444455556666", "CN=a," + Computer, null, "", "C:"),
            new BitLockerKeyInfo("AB12EF56", "AB12EF56-1111-2222-3333-444455556666", "CN=b," + Computer, null, "", "D:"));
        Check.False(PosteSecrets.Find(keys, "AB1").Unique, "moins de quatre caractères : aucune recherche");
        Check.Equal(2, PosteSecrets.Find(keys, "{ab12").Matches.Length, "accolades et casse ignorées");
        Check.True(PosteSecrets.Find(keys, "AB12-CD").Unique, "tirets ignorés, clé unique");
    }

    [Test]
    public static void Bios_versions_are_ordered_only_when_comparable()
    {
        Check.Equal("Equal", BiosReferences.Compare("1.12.0", "1.12.0"), "égales");
        Check.Equal("Older", BiosReferences.Compare("1.9.0", "1.12.0"), "plus ancienne (numérique, pas alphabétique)");
        Check.Equal("Newer", BiosReferences.Compare("N22ET80W (1.57)", "N22ET79W (1.56)"), "plus récente");
        Check.Equal("Different", BiosReferences.Compare("A10", "1.2.3"), "formats différents");
        Check.Equal("Unknown", BiosReferences.Compare("", "1.0"), "version inconnue");
        var book = BiosReferences.Approve([], new BiosReference("Dell Inc.", "Latitude 5440", "1.12.0", TestClock.Reference));
        Check.NotNull(BiosReferences.Find(book, "Dell Inc.", "Latitude 5440"), "référence approuvée");
        Check.True(BiosReferences.Remove(book, "Dell Inc.", "Latitude 5440").IsEmpty, "référence retirée");
        Check.False(BiosReferences.IsValid(new BiosReference("Dell", "", "1.0", TestClock.Reference)), "modèle vide refusé");
    }

    [Test]
    public static void Volume_forecast_needs_enough_regular_samples()
    {
        const long Size = 256L * 1024 * 1024 * 1024;
        var start = TestClock.Reference.AddDays(-60);
        var few = PosteReadings.Forecast("C:", [new VolumeSample(start, Size, Size / 2), new VolumeSample(start.AddDays(1), Size, Size / 2)], TestClock.Paris);
        Check.Equal("Insufficient", few.Status, "deux relevés : aucune prévision");
        var falling = Enumerable.Range(0, 12).Select(i => new VolumeSample(start.AddDays(i * 5), Size, Size / 4 - i * 2L * 1024 * 1024 * 1024)).ToList();
        var forecast = PosteReadings.Forecast("C:", falling, TestClock.Paris);
        Check.Equal("Forecast", forecast.Status, "baisse régulière : prévision");
        Check.True(forecast.DaysLeft is > 0 and < 730, "saturation dans l’horizon de deux ans");
        Check.NotNull(forecast.SaturationAt, "date de saturation");
        var stable = Enumerable.Range(0, 12).Select(i => new VolumeSample(start.AddDays(i * 5), Size, Size / 2)).ToList();
        Check.Equal("Stable", PosteReadings.Forecast("C:", stable, TestClock.Paris).Status, "espace stable");
    }

    [Test]
    public static void Probe_catalog_matches_domenia_1()
    {
        Check.Equal(33, ProbeCatalog.Probes.Length, "33 sondes en lecture seule");
        Check.Equal(ProbeCatalog.Probes.Length, ProbeCatalog.Probes.Select(p => p.Id).Distinct(StringComparer.Ordinal).Count(), "identifiants uniques");
        Check.True(ProbeCatalog.Probes.All(p => !string.Equals(p.Class, "Win32_Product", StringComparison.OrdinalIgnoreCase)), "jamais Win32_Product");
        foreach (var reading in PosteReadings.Catalog)
        {
            Check.True(reading.Probes.All(id => ProbeCatalog.Find(id) is not null), "sondes du relevé " + reading.Id + " connues");
        }
    }

    [Test]
    public static void Dsreg_analysis_never_evaluates_sso_from_an_admin_session()
    {
        const string Text = """
            +----------------------------------------------------------------------+
            | Device State                                                         |
            +----------------------------------------------------------------------+
                         AzureAdJoined : YES
                          DomainJoined : YES
                           Device Name : PC-PAR-0001
            +----------------------------------------------------------------------+
            | User State                                                           |
            +----------------------------------------------------------------------+
                           AzureAdPrt : YES
                    Executing Account Name : EXAMPLE\adm-j.martin, adm-j.martin@example.local
            """;
        var admin = PosteDsreg.Analyze(Text, DsregCollector.AdministrativeAccount, @"EXAMPLE\j.martin", "PC-PAR-0001", null);
        Check.True(admin.Recognized, "texte reconnu");
        Check.Equal("NonEvaluable", admin.SsoVerdict, "collecté sous un compte d’administration : SSO non évaluable");
        Check.Equal(true, admin.ComputerMatches, "nom du poste vérifié");
        var other = PosteDsreg.Analyze(Text, DsregCollector.EndUserSession, @"EXAMPLE\j.martin", "PC-PAR-0001", null);
        Check.Equal("NonEvaluable", other.SsoVerdict, "compte exécutant différent de l’utilisateur final");
        Check.False(PosteDsreg.Analyze("bonjour", DsregCollector.EndUserSession, null, null, null).Recognized, "texte quelconque non reconnu");
    }

    [Test]
    public static void Recovery_identifier_read_back_must_be_the_one_chosen()
    {
        const string Guid = "AB12CD34-1111-2222-3333-444455556666";
        Check.True(PosteSecrets.MatchesExpected(Guid, "{ab12cd34-1111-2222-3333-444455556666}"), "accolades, tirets et casse ignorés");
        Check.False(PosteSecrets.MatchesExpected(Guid, "AB12CD34"), "les 8 premiers caractères ne suffisent pas pour lire une valeur");
        Check.False(PosteSecrets.MatchesExpected(Guid, "AB12CD34-1111-2222-3333-444455556667"), "identifiant différent : aucune valeur");
        Check.False(PosteSecrets.MatchesExpected(null, Guid), "identifiant absent : aucune valeur");
        var keys = ImmutableArray.Create(new BitLockerKeyInfo("AB12CD34", Guid, "CN=a,CN=PC,DC=example,DC=local", null, "", "C:"));
        Check.True(PosteSecrets.Find(keys, Guid).Unique, "l’identifiant complet lu sur l’écran du poste retrouve la clé");
    }

    [Test]
    public static void Secrets_index_of_an_older_holder_of_the_name_is_left_out()
    {
        var computer = System.Guid.NewGuid();
        var created = new DateTimeOffset(2025, 3, 1, 8, 0, 0, TimeSpan.Zero);
        Check.True(PosteSecrets.IndexApplies(computer, created.AddDays(10), computer, created), "même GUID, écrit après la création");
        Check.False(PosteSecrets.IndexApplies(System.Guid.NewGuid(), created.AddDays(10), computer, created), "autre GUID : ancien détenteur du nom");
        Check.False(PosteSecrets.IndexApplies(computer, created.AddDays(-1), computer, created), "écrit avant la création du poste actuel");
    }

    [Test]
    public static void Health_policy_follows_the_ou_of_the_computer()
    {
        const string Root = "DC=example,DC=local";
        const string Computer = "CN=PC-PAR-0001,OU=Paris,OU=Postes," + Root;
        var now = new DateTimeOffset(2026, 10, 22, 8, 0, 0, TimeSpan.Zero);
        var book = JsonDocument.Parse("""
            {
              "domainDn": "DC=example,DC=local",
              "default": { "thresholds": { "diskFreeAlert": 8, "diskFreeWarn": 25 }, "disabledRules": ["lowdisk"],
                           "customRules": [ { "id": "custom.uptime", "name": "Redémarrage trop ancien", "measure": "UptimeDays", "operator": "GreaterThan", "threshold": 20, "severity": "Warn" },
                                            { "id": "custom.query", "name": "Requête", "measure": "Query" } ] },
              "scopes": [ { "scopeDn": "OU=Postes,DC=example,DC=local", "overrides": { "thresholds": { "diskFreeWarn": 30 } } },
                          { "scopeDn": "OU=Paris,OU=Postes,DC=example,DC=local", "overrides": { "ruleStates": { "lowdisk": true },
                            "suspensions": [ { "ruleId": "disk.tight", "untilUtc": "2026-10-30T00:00:00Z", "reason": "Migration des disques" },
                                             { "ruleId": "certificates", "untilUtc": "2026-10-01T00:00:00Z", "reason": "Terminée" } ] } } ]
            }
            """).RootElement.Clone();
        var policy = PosteHealthPolicies.Resolve(book, Root, Computer, now, TimeZoneInfo.Utc);
        Check.Equal(8, policy.DiskFreeAlert, "seuil du domaine");
        Check.Equal(30, policy.DiskFreeWarn, "seuil de l’OU ancêtre, le plus proche l’emporte");
        Check.True(policy.IsEnabled("lowdisk"), "règle réactivée par l’OU du poste");
        Check.False(policy.Counts("disk.tight"), "règle suspendue jusqu’au 30/10 : ne compte pas");
        Check.True(policy.Counts("certificates"), "suspension échue : la règle compte de nouveau");
        Check.Equal(1, policy.CustomRules.Length, "une alerte personnalisée sur une mesure");
        Check.Equal(1, policy.QueryRules, "une alerte sur requête, évaluée par l’atelier");
        Check.Contains("Paris", policy.Origin, "origine dite (OU du poste)");

        var other = PosteHealthPolicies.Resolve(JsonDocument.Parse("""{ "domainDn": "DC=autre,DC=local", "default": { "thresholds": { "diskFreeAlert": 5 } } }""").RootElement.Clone(), Root, Computer, now, TimeZoneInfo.Utc);
        Check.Equal(PosteHealthPolicy.Default.DiskFreeAlert, other.DiskFreeAlert, "règles d’un autre domaine ignorées");
        var damaged = PosteHealthPolicies.Resolve(JsonDocument.Parse("""{ "default": { "thresholds": { "diskFreeAlert": 40, "diskFreeWarn": 20 } } }""").RootElement.Clone(), Root, Computer, now, TimeZoneInfo.Utc);
        Check.Equal(PosteHealthPolicy.Default.DiskFreeAlert, damaged.DiskFreeAlert, "critique au-dessus de la surveillance : seuils livrés");
        Check.Equal(PosteHealthPolicy.Default.DiskFreeAlert, PosteHealthPolicies.Resolve(null, Root, Computer, now, TimeZoneInfo.Utc).DiskFreeAlert, "sans règles : seuils livrés avec Domenia 1");
    }

    [Test]
    public static void Session_authorizations_and_collections_are_scoped()
    {
        var session = new PosteSessionProbe();
        var s = session.Session;
        var now = new DateTimeOffset(2026, 10, 22, 8, 0, 0, TimeSpan.Zero);
        const string Dn = "CN=PC-PAR-0001,OU=Paris,DC=example,DC=local";
        Check.False(s.EnsureSession("adm|example.local", now), "première liaison");
        s.Grant(ConsentKind.Intervention, Dn, "PC-PAR-0001", 5, now);
        s.Grant(ConsentKind.ReadFallback, Dn, "PC-PAR-0001", 5, now);
        Check.True(s.ConsumeReadFallback(Dn, "inventaire", now.AddMinutes(1)), "une lecture de repli consommée");
        Check.False(s.ConsumeReadFallback(Dn, "inventaire", now.AddMinutes(1)), "une seule");
        Check.True(s.EnsureSession("autre|example.local", now.AddMinutes(2)), "autre compte : changement de session");
        Check.False(s.Covers(ConsentKind.Intervention, Dn, now.AddMinutes(2)), "autorisations effacées au changement de session");

        using var inventory = s.BeginCollection(Dn, "PC-PAR-0001", CollectionKind.Inventory, now, CancellationToken.None);
        using var diagnostic = s.BeginCollection(Dn, "PC-PAR-0001", CollectionKind.Diagnostic, now, CancellationToken.None);
        var busy = Check.Throws<DomeniaOperationException>(() => s.BeginCollection(Dn, "PC-PAR-0001", CollectionKind.Inventory, now, CancellationToken.None), "même type sur le même poste");
        Check.Equal(PosteErrors.Busy, busy.Code, "refus clair, rien n’est remplacé");
        var stopped = s.StopCollection(Dn, CollectionKind.Diagnostic);
        Check.Equal(1, stopped.Length, "seul le diagnostic est arrêté");
        Check.True(diagnostic.IsCancellationRequested, "diagnostic arrêté");
        Check.False(inventory.IsCancellationRequested, "l’inventaire continue");
        Check.Equal(2, s.Running().Length, "les deux relevés restent listés jusqu’à leur fin");
    }

    [Test]
    public static void Program_arguments_are_sealed_by_their_fingerprint_only()
    {
        Check.Equal("sans argument", PosteRemote.ArgumentsText(null), "aucun argument");
        Check.Contains("non conservés", PosteRemote.ArgumentsText("--mot-de-passe=x"), "longueur seulement");
        Check.False(PosteRemote.ArgumentsText("--mot-de-passe=x").Contains("mot-de-passe", StringComparison.Ordinal), "jamais le texte");
        Check.Equal(64, PosteRemote.ArgumentsDigest("a b c").Length, "empreinte SHA-256");
        Check.Equal("", PosteRemote.ArgumentsDigest(""), "pas d’empreinte sans argument");
        var (_, request) = PosteRemote.Run("PC-PAR-0001", "system", @"C:\Outils\maj.exe", "--jeton=SECRET", null, true);
        Check.False(request!.Summary.Contains("SECRET", StringComparison.Ordinal), "le résumé ne cite pas les arguments");
        var probe = new PosteSessionProbe();
        var now = new DateTimeOffset(2026, 10, 22, 8, 0, 0, TimeSpan.Zero);
        var digest = PosteRemote.ArgumentsDigest("--jeton=SECRET");
        probe.Session.KeepRunArguments(digest, "--jeton=SECRET", now.AddMinutes(5), now);
        Check.True(probe.Session.HasRunArguments(digest, now.AddMinutes(1)), "gardés en mémoire jusqu’à l’envoi");
        Check.Equal("--jeton=SECRET", probe.Session.TakeRunArguments(digest, now.AddMinutes(1)), "remis à l’exécuteur");
        Check.Null(probe.Session.TakeRunArguments(digest, now.AddMinutes(1)), "puis oubliés");
    }

    [Test]
    public static void Texts_of_the_board_say_what_they_read()
    {
        Check.Equal("TPM 2.0 (niveau 0, révision 1.59) · activé, opérationnel", PosteLabels.TpmText(new TpmInfo("2.0, 0, 1.59", true, true, true)), "TPM lisible");
        Check.Contains("non lu", PosteLabels.TpmText(new TpmInfo(null, null, null, null)), "TPM non lu");
        Check.Equal("4096 · compte de poste de travail", PosteLabels.UacText(4096), "userAccountControl d’un poste");
        Check.Contains("désactivé", PosteLabels.UacText(4098), "compte désactivé");
        var restart = PosteSessions.ForRestart(null, null);
        Check.False(restart.Known, "lecture en cours");
        Check.Equal(4, PosteDiagnostics.QuickServices.Length, "quatre services du diagnostic rapide (aucun service WAPT)");
        var updates = PosteUpdates.Facts(new UpdateConfig("http://wsus.example.local:8530", true, "WSUS", null, "Succeeded"), new DateTimeOffset(2026, 10, 22, 8, 0, 0, TimeSpan.Zero), TimeZoneInfo.Utc);
        Check.Equal(1, updates.Length, "un seul fournisseur : Windows Update");
        Check.Equal("Windows Update", updates[0].Label, "Windows Update seul");
    }

    /// <summary>A fresh session of the workstation console, outside any directory source (rules only).</summary>
    private sealed class PosteSessionProbe
    {
        public PosteSession Session { get; } = PosteSession.For(new UnavailableDirectorySource(null, () => "adm-test"));
    }
}
