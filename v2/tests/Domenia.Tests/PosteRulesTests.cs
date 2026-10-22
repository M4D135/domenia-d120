using System.Collections.Immutable;
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
}
