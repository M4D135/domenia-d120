using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WorkstationDetailsTests
{
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));
    private static string Payload(string format, object[] rows, string host = "PC1", int code = 0, bool truncated = false) =>
        JsonSerializer.Serialize(new { Format = format, Computer = host, Code = code, Truncated = truncated, Rows = rows });

    [Test]
    public static void Local_administrators_use_the_builtin_sid_and_never_enumerate_domain_groups()
    {
        var calls = 0;
        var role = 1;
        var name = "PC1";
        using var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(30), TestClock.Fixed())
        {
            ReadOverride = (_, query, _) => query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
                ? [Row(("Name", name), ("DomainRole", role))]
                : query == "SELECT Name, SID, LocalAccount FROM Win32_Group WHERE LocalAccount=True AND SID='S-1-5-32-544'"
                    ? [Row(("Name", "Administratoren"), ("SID", "S-1-5-32-544"), ("LocalAccount", true))] : throw new InvalidOperationException("Énumération générale interdite"),
            LocalAdminsOverride = group =>
            {
                calls++; Check.Equal("Administratoren", group, "nom localisé résolu depuis le SID");
                return new(InventoryCategories.Admins, SourceStatus.Ok, "RPC", 1, [Row(("Name", @"TEST\support"))]);
            },
        };
        Check.Equal(SourceStatus.Ok, session.ReadLocalAdmins().Status, "groupe local lu");
        role = 5; Check.Equal(SourceStatus.Skipped, session.ReadLocalAdmins().Status, "DC écarté");
        role = -1; Check.Equal(SourceStatus.Unavailable, session.ReadLocalAdmins().Status, "rôle inconnu écarté");
        role = 1; name = "OTHER"; Check.Equal(SourceStatus.Error, session.ReadLocalAdmins().Status, "homonyme écarté");
        Check.Equal(1, calls, "un seul appel de membres autorisé");
    }

    [Test]
    public static void Local_administrator_authentication_rejection_stops_all_later_native_contacts()
    {
        var reads = 0;
        using var session = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed())
        {
            ReadOverride = (_, query, _) => { reads++; return query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
                ? [Row(("Name", "PC1"), ("DomainRole", 1))] : [Row(("Name", "Admins"), ("SID", "S-1-5-32-544"), ("LocalAccount", true))]; },
            LocalAdminsOverride = _ => new(InventoryCategories.Admins, SourceStatus.Refused, "refus", 1, []) { AuthenticationRejected = true },
        };
        Check.True(session.ReadLocalAdmins().AuthenticationRejected, "refus propagé");
        Check.True(session.ReadLocalAdmins().AuthenticationRejected, "refus conservé");
        Check.Equal(2, reads, "aucune deuxième authentification");
    }

    [Test]
    public static async Task Service_dependencies_distinguish_missing_values_from_access_denied_and_keep_group_dependencies()
    {
        var clock = TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock) { SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
        {
            ReadOverride = (_, _, _) => [Row(("Name", "ServiceA"), ("StartMode", "Auto")), Row(("Name", "ServiceB"), ("DelayedAutoStart", true))],
            RegistryOverride = (request, _) => request.Key.EndsWith("ServiceB", StringComparison.Ordinal) ? new(5, null)
                : request.Name == "DependOnService" ? new(0, new[] { "RpcSs" }) : new(0, new[] { "NetworkProvider" }),
        } };
        var result = await reader.ReadAsync("PC1", WorkstationReading.Services, null, CancellationToken.None);
        Check.Equal(SourceStatus.Partial, result.StatusOf(InventoryCategories.Services), "refus partiel explicite");
        Check.True(result.Services[0].DependenciesRead, "liens lus pour le premier service");
        Check.True(result.Services[0].DependsOn.SequenceEqual(["RpcSs", "+NetworkProvider"]), "services et groupes distincts");
        Check.False(result.Services[1].DependenciesRead, "refus ne prouve pas l’absence");
        var rows = PosteServices.Rows(result.Services);
        Check.True(rows.All(r => !r.DependentsComplete), "graphe inverse incomplet signalé");
        Check.True(rows.Single(r => r.Name == "ServiceA").StartLabel.Contains("non lu", StringComparison.Ordinal), "délai inconnu conservé");
        Check.False(new ServiceEntry("old", "old", "", "", null, null, null, null, [], null).DependenciesRead, "ancien cache sans preuve reste inconnu");
    }

    [Test]
    public static void Certificate_projection_retains_expired_certificates_and_discards_private_metadata()
    {
        var payload = Payload("Domenia.CertificatesRead/1", [new { Subject = "CN=poste", Issuer = "CN=CA", NotAfter = "2020-01-01T00:00:00Z", Thumbprint = new string('A', 40), Usages = new[] { "1.3.6.1.5.5.7.3.2" }, PrivateKey = "NEVER-RETAIN" }]);
        var reading = CimSession.ParseInventoryShell(InventoryShellRead.Certificates, payload, "PC1.test.local");
        Check.Equal(SourceStatus.Ok, reading.Status, "magasin lu");
        Check.Equal(1, reading.Items, "certificat expiré conservé pour le bilan");
        Check.Null(reading.Instances[0].Raw("PrivateKey"), "champ étranger écarté");
        Check.Equal("1.3.6.1.5.5.7.3.2", reading.Instances[0].Strings("Usages").Single(), "OID conservé sans traduction inventée");
        reading = CimSession.ParseInventoryShell(InventoryShellRead.Certificates, payload.Replace("2020-01-01T00:00:00Z", "2020-01-01T00:00:00", StringComparison.Ordinal), "PC1");
        Check.Equal(SourceStatus.Partial, reading.Status, "fuseau manquant explicite"); Check.Equal(0, reading.Items, "date non inventée");
        var rejected = false;
        try { CimSession.ParseInventoryShell(InventoryShellRead.Tasks, payload, "PC1"); } catch (JsonException) { rejected = true; }
        Check.True(rejected, "réponse d’une autre source refusée");
        rejected = false;
        try { CimSession.ParseInventoryShell(InventoryShellRead.Certificates, payload, "OTHER"); } catch (JsonException) { rejected = true; }
        Check.True(rejected, "identité étrangère refusée");
    }

    [Test]
    public static void Task_status_zero_is_not_a_success_when_last_result_is_missing_and_dates_require_a_zone()
    {
        var payload = Payload("Domenia.TasksRead/1", [new { Name = "Tâche", Path = @"\Domenia\", Author = "opérateur", State = "3", LastResult = (string?)null, LastRun = "2026-10-23T10:00:00", NextRun = (string?)null }]);
        var reading = CimSession.ParseInventoryShell(InventoryShellRead.Tasks, payload, "PC1");
        Check.Equal(SourceStatus.Partial, reading.Status, "résultat manquant déclaré");
        Check.Null(reading.Instances[0].Raw("LastResult"), "pas de faux code succès");
        Check.Null(reading.Instances[0].Raw("LastRun"), "date sans fuseau refusée");
        payload = Payload("Domenia.TasksRead/1", [new { Name = "Jamais", Path = @"\Domenia\", State = "3", LastResult = "267011", LastRun = (string?)null, NextRun = "2026-10-24T10:00:00Z" }]);
        reading = CimSession.ParseInventoryShell(InventoryShellRead.Tasks, payload, "PC1");
        Check.Equal(SourceStatus.Ok, reading.Status, "tâche jamais exécutée bien renseignée");
        Check.Equal("jamais exécutée", PosteLabels.TaskResult("0x" + reading.Instances[0].Number("LastResult")!.Value.ToString("X8", System.Globalization.CultureInfo.InvariantCulture)).Text, "code traduit");
    }

    [Test]
    public static void Supplementary_sources_require_selected_WinRm_and_report_unconfirmed_shell_cleanup()
    {
        var calls = 0;
        using var dcom = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed())
        { InventoryShellOverride = (_, _) => { calls++; throw new InvalidOperationException(); } };
        Check.Equal(SourceStatus.Unavailable, dcom.ReadInventoryShell(InventoryShellRead.Certificates).Status, "pas de transport implicite");
        Check.Equal(0, calls, "aucun shell lancé");
        using var winrm = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        { InventoryShellOverride = (_, _) => new(SourceStatus.Ok, Payload("Domenia.CertificatesRead/1", []), false, false) };
        var reading = winrm.ReadInventoryShell(InventoryShellRead.Certificates);
        Check.Equal(SourceStatus.Partial, reading.Status, "fermeture inconnue déclarée même pour un magasin vide");
        Check.True(reading.Detail.Contains("non confirmée", StringComparison.Ordinal), "motif visible");
        using var refused = new CimSession("PC1", TimeSpan.FromSeconds(60), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        { AppxOverride = _ => new(SourceStatus.Ok, Payload("Domenia.AppxRead/1", [], code: unchecked((int)0x80070005)), false, false) };
        Check.Equal(SourceStatus.Refused, refused.ReadAppx().Status, "fermeture inconnue ne transforme pas le refus en résultat partiel exploitable");
    }
}
