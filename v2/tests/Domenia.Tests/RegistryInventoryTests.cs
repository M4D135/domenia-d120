using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class RegistryInventoryTests
{
    private static RegistryRequest Value(string key, string name, RegistryMethod method = RegistryMethod.Dword) => new(InventoryRegistry.Machine, key, name, method);

    [Test]
    public static void Registry_contract_refuses_unlisted_keys_values_hives_and_methods_before_contact()
    {
        var calls = 0;
        var session = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed())
        { RegistryOverride = (_, _) => { calls++; return new(0, 1U); } };
        foreach (var request in new[]
        {
            Value(@"SAM\SAM\Domains", "Password"), Value(@"SECURITY\Policy\Secrets", "Value"),
            Value(InventoryRegistry.UpdatePolicy, "Password", RegistryMethod.String),
            new RegistryRequest(0x80000000, InventoryRegistry.SecureBoot, "UEFISecureBootEnabled", RegistryMethod.Dword),
            Value(InventoryRegistry.SecureBoot, "UEFISecureBootEnabled", (RegistryMethod)99),
            Value(InventoryRegistry.Uninstall + @"\App\Subkey", "DisplayName", RegistryMethod.String),
            Value(InventoryRegistry.Uninstall + @"\..", "DisplayName", RegistryMethod.String),
            new RegistryRequest(InventoryRegistry.Users, "invalid\\" + InventoryRegistry.Uninstall, null, RegistryMethod.Keys),
        }) { Check.Equal(SourceStatus.Error, session.ReadRegistry(request).Status, "hors contrat"); }
        Check.Equal(0, calls, "aucun contact refusé par la garde");
        Check.Equal(SourceStatus.Ok, session.ReadRegistry(Value(InventoryRegistry.SecureBoot, "UEFISecureBootEnabled")).Status, "lecture admise");
        Check.Equal(1, calls, "un seul appel autorisé");
    }

    [Test]
    public static void Registry_absence_refusal_unknown_flag_and_zero_are_distinct()
    {
        RegistryReply reply = new(2, null);
        var session = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed()) { RegistryOverride = (_, _) => reply };
        var request = Value(InventoryRegistry.SecureBoot, "UEFISecureBootEnabled");
        var missing = session.ReadRegistry(request);
        Check.True(missing.Answered, "absence lue"); Check.False(missing.Found, "valeur absente");
        reply = new(5, null); var refused = session.ReadRegistry(request);
        Check.False(refused.Answered, "refus non assimilé à une absence"); Check.Equal(SourceStatus.Refused, refused.Status, "refus dit");
        reply = new(0, 0U); var zero = session.ReadRegistry(request);
        Check.True(zero.Found, "zéro présent"); Check.Equal<bool?>(false, zero.Flag, "drapeau lu faux");
        reply = new(0, 2U); Check.Null(session.ReadRegistry(request).Flag, "valeur hors 0/1 inconnue");
        reply = new(0, new[] { "unexpected" }); Check.Equal(SourceStatus.Error, session.ReadRegistry(request).Status, "mauvais type refusé");
        reply = new(0, Enumerable.Range(0, 2050).Select(n => "App" + n).ToArray());
        var names = session.ReadRegistry(new(InventoryRegistry.Machine, InventoryRegistry.Uninstall, null, RegistryMethod.Keys));
        Check.Equal(SourceStatus.Partial, names.Status, "liste tronquée déclarée"); Check.Equal(2048, names.Strings.Length, "borne conservée");
    }

    [Test]
    public static void Registry_authentication_rejection_stops_subsequent_registry_and_CIM_attempts()
    {
        var calls = 0;
        var session = new CimSession("PC1", TimeSpan.FromSeconds(30), TestClock.Fixed())
        {
            RegistryOverride = (_, _) => { calls++; throw new COMException("secret jamais exposé", unchecked((int)0x8007052E)); },
            ReadOverride = (_, _, _) => { calls++; return []; },
        };
        var first = session.ReadRegistry(Value(InventoryRegistry.SecureBoot, "UEFISecureBootEnabled"));
        Check.True(first.AuthenticationRejected, "refus d’identité");
        Check.False(first.Detail.Contains("secret", StringComparison.Ordinal), "message natif non recopié");
        Check.True(session.ReadRegistry(Value(InventoryRegistry.SecureBoot, "UEFISecureBootEnabled")).AuthenticationRejected, "pas de nouvel essai registre");
        Check.True(session.Read("test", @"root\cimv2", "SELECT Name FROM Win32_ComputerSystem", 1).AuthenticationRejected, "pas de nouvel essai CIM");
        Check.Equal(1, calls, "identité refusée essayée une seule fois");
    }

    private static WmiWorkstationReader Reader(Func<RegistryRequest, RegistryReply> registry)
    {
        var clock = TestClock.Fixed();
        return new(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { ReadOverride = (_, _, _) => [], RegistryOverride = (request, _) => registry(request) },
        };
    }

    [Test]
    public static async Task Registry_refusals_never_become_disabled_policy_no_reboot_or_legacy_firmware()
    {
        var reader = Reader(r => r.Key.StartsWith(InventoryRegistry.LocalFirewall, StringComparison.Ordinal) ? new(0, 1U)
            : r.Key.StartsWith(InventoryRegistry.PolicyFirewall, StringComparison.Ordinal) || r.Key == InventoryRegistry.CbsPending || r.Key == InventoryRegistry.UpdatePolicy ? new(5, null)
            : r.Key == InventoryRegistry.SecureBoot ? new(0, 0U) : new(2, null));
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.True(result.Firewall.All(p => p.LocalEnabled == true && p.EffectiveEnabled is null), "une stratégie refusée ne cède pas la priorité au local");
        Check.Equal<bool?>(false, result.PendingReboot?.Complete, "absence de redémarrage non établie");
        Check.Equal(0, result.PendingReboot!.Confirmed.Length, "refus différent d’une obligation");
        Check.Equal<bool?>(false, result.SecureBoot?.Enabled, "désactivation lue");
        Check.Null(result.SecureBoot!.Firmware, "aucun BIOS hérité déduit");
        Check.Equal<bool?>(false, result.Updates?.PolicyRead, "configuration non établie");
        Check.Equal("Configuration WSUS non établie", result.Updates!.WsusText, "aucun Windows Update supposé après refus");
    }

    [Test]
    public static async Task Conflicting_private_firewall_policies_are_unknown_in_the_console_summary()
    {
        var reader = Reader(r => r.Key.StartsWith(InventoryRegistry.LocalFirewall, StringComparison.Ordinal) ? new(0, 1U)
            : r.Key == InventoryRegistry.PolicyFirewall + "StandardProfile" ? new(0, 1U)
            : r.Key == InventoryRegistry.PolicyFirewall + "PrivateProfile" ? new(0, 0U) : new(2, null));
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.Null(result.Firewall.Single(p => p.Name == "Privé").EffectiveEnabled, "contradiction des deux clés de stratégie explicitée");
        var computer = Fixtures.Computer("PC1");
        var header = PosteHeaderRules.Computer(computer, Fixtures.Snapshot(computers: [computer]), new Dictionary<string, string>());
        var board = PosteBoardBuilder.Build(header, result, PosteHealthPolicy.Default, Fixtures.Now, TimeZoneInfo.Utc);
        var json = JsonSerializer.Serialize(board);
        Check.False(json.Contains("Activé sur tous les profils", StringComparison.Ordinal), "aucun résumé sain sur une valeur inconnue");
        Check.True(json.Contains("État incomplet", StringComparison.Ordinal) || json.Contains("\\u00C9tat incomplet", StringComparison.Ordinal), "incomplétude visible dans la fiche");
    }

    [Test]
    public static async Task Registry_keeps_confirmed_reboot_separate_from_file_hints_and_does_not_invent_a_date_timezone()
    {
        var reader = Reader(r => r.Key == InventoryRegistry.CbsPending ? new(0, Array.Empty<string>())
            : r.Key == InventoryRegistry.SessionManager ? new(0, new[] { @"\??\C:\sensitive\NEVER-PUBLISH-FILE" })
            : r.Key == InventoryRegistry.UpdatePolicy ? new(0, "https://admin:NEVER-PUBLISH-PASSWORD@wsus.test.local:8531/?token=NEVER-PUBLISH-TOKEN")
            : r.Name == "UseWUServer" ? new(0, 1U)
            : r.Key == InventoryRegistry.UpdateInstall ? new(0, "2026-10-22 10:30:00")
            : r.Name == "SiteName" ? new(0, "Paris")
            : r.Name == "DynamicSiteName" ? new(0, "Lyon") : new(2, null));
        var result = await reader.ReadAsync("PC1", WorkstationReading.Quick, null, CancellationToken.None);
        Check.Equal<bool?>(true, result.PendingReboot?.Complete, "toutes les sources de redémarrage lues");
        Check.Equal(1, result.PendingReboot!.Confirmed.Length, "CBS confirmé même clé vide");
        Check.Equal(1, result.PendingReboot.Partial.Length, "renommage de fichier reste un indice");
        Check.False(JsonSerializer.Serialize(result).Contains("NEVER-PUBLISH-FILE", StringComparison.Ordinal), "chemins non conservés");
        Check.False(JsonSerializer.Serialize(result).Contains("NEVER-PUBLISH", StringComparison.Ordinal), "aucun chemin, identifiant URI ou jeton conservé");
        Check.Equal("https://wsus.test.local:8531", result.Updates!.WsusServer, "seul le serveur est affiché");
        Check.Null(result.Updates.LastSuccess, "aucun fuseau supposé");
        Check.Equal("2026-10-22 10:30:00", result.Updates.LastSuccessReported, "date déclarée conservée comme texte");
        Check.Equal("Paris", result.Site, "site configuré prioritaire");
        Check.Equal<DateTimeOffset?>(new(2026, 10, 22, 8, 30, 0, TimeSpan.Zero), WmiWorkstationReader.ExplicitOffsetDate("2026-10-22T10:30:00+02:00"), "fuseau explicite conservé");
    }
}
