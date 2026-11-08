using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class DemonstrationSessionTests
{
    [Test]
    public static void Demo_command_cannot_combine_with_any_real_host_command()
    {
        Check.True(DemoSessionArguments.Valid(["--demo-session"]), "entrée fermée autorisée");
        foreach (var other in new[] { "--package-update-assistant", "--package-update-health", "--native-read-worker", "installer", "dossier", "--e2e-port", "--simulation" })
        {
            Check.True(DemoSessionArguments.Requested([other, "--demo-session"]), "option repérée quel que soit l’ordre");
            Check.False(DemoSessionArguments.Valid([other, "--demo-session"]), "commande réelle non combinable : " + other);
        }
        Check.True(DemoSessionArguments.Requested(["--demo-session=true"]), "forme mal construite détectée avant dispatch réel");
        Check.False(DemoSessionArguments.Valid(["--demo-session=true"]), "forme non reconnue refusée");
        Check.False(DemoSessionArguments.Valid(["--demo-session", "--demo-session"]), "doublon refusé");
        var mode = DemoSessionArguments.Decision();
        Check.Equal(AppMode.Simulation, mode.Mode, "composition fictive imposée");
        Check.True(mode.JoinedDomain is null, "aucune identité réelle reprise");
    }

    [Test]
    public static void Reserved_world_is_complete_dated_and_deterministic_without_changing_legacy_simulation()
    {
        var options = SimulationOptions.Default with { UseReservedDomain = true, Latency = SimulationLatency.None };
        var world = SimulatedWorldGenerator.Generate(options, TestClock.Reference, TestClock.Paris);
        var again = SimulatedWorldGenerator.Generate(options, TestClock.Reference, TestClock.Paris);
        Check.Equal(world.ComputeFingerprint(), again.ComputeFingerprint(), "graine et horloge reproductibles");
        Check.Equal("example.invalid", world.Directory.Domain.DnsName, "domaine réservé");
        Check.Equal("DC=example,DC=invalid", world.Directory.Domain.RootDn, "racine réservée");
        Check.Equal(1258, world.Directory.Users.Length, "annuaire complet");
        Check.Equal(454, world.Directory.Computers.Length, "parc complet");
        Check.True(world.Directory.Users.All(u => u.DistinguishedName.EndsWith(world.Directory.Domain.RootDn, StringComparison.OrdinalIgnoreCase)), "DN cohérents");
        Check.True(world.Directory.Users.Where(u => u.UserPrincipalName is not null).All(u => u.UserPrincipalName!.EndsWith("@example.invalid", StringComparison.OrdinalIgnoreCase)), "UPN fictifs réservés");
        Check.True(world.Directory.Users.All(u => u.WhenCreated <= u.WhenChanged && u.WhenChanged <= world.Reference), "dates antérieures cohérentes");
        Check.Equal("example.local", SimulatedWorldGenerator.Generate(SimulationOptions.Default, TestClock.Reference, TestClock.Paris).Directory.Domain.DnsName, "fixtures historiques préservées");
    }

    [Test]
    public static async Task Real_unlock_changes_only_demo_then_a_fresh_context_restores_objects_preferences_and_receipts()
    {
        var normal = new SimulatedBridge();
        await normal.Preferences.SetAsync("dashboard.version", JsonSerializer.SerializeToElement(new { items = Array.Empty<string>() }), CancellationToken.None);
        var original = JsonSerializer.Serialize(normal.Source.CurrentDirectory);
        var demo = new SimulatedBridge(reservedDomain: true);
        var camille = demo.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");
        var before = Locked(SimulatedBridge.Json(await demo.CallAsync("dashboard.summary")));
        var planned = SimulatedBridge.Json(await demo.CallAsync("accounts.unlock.plan", JsonSerializer.Serialize(new { dn = camille.DistinguishedName })));
        var receipt = SimulatedBridge.Json(await demo.CallAsync("write.execute", JsonSerializer.Serialize(new
        {
            planId = planned.GetProperty("plan").GetProperty("id").GetString(), token = planned.GetProperty("token").GetString(), typedName = (string?)null,
        })));
        Check.True(receipt.GetProperty("simulated").GetBoolean(), "vrai circuit, reçu fictif");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "relecture métier effective");
        Check.Equal(before - 1, Locked(SimulatedBridge.Json(await demo.CallAsync("dashboard.summary"))), "vrai tableau recalculé");
        await demo.Preferences.SetAsync("demo.choice", JsonSerializer.SerializeToElement("modifié"), CancellationToken.None);
        var fresh = new SimulatedBridge(reservedDomain: true);
        Check.Equal(before, Locked(SimulatedBridge.Json(await fresh.CallAsync("dashboard.summary"))), "nouvelle composition restaure les objets");
        Check.False(fresh.Preferences.TryGet("demo.choice", out _), "aucun choix hérité de l’espace quitté");
        Check.Equal(0, (await fresh.Receipts.ReadAllAsync(CancellationToken.None)).Receipts.Length, "reçus réinitialisés");
        Check.Equal(original, JsonSerializer.Serialize(normal.Source.CurrentDirectory), "contexte précédent inchangé");
        Check.True(normal.Preferences.TryGet("dashboard.version", out var kept) && kept.GetProperty("items").GetArrayLength() == 0, "choix vide précédent conservé");
        Check.Equal(0, (await normal.Receipts.ReadAllAsync(CancellationToken.None)).Receipts.Length, "aucun reçu normal ajouté");
    }

    [Test]
    public static async Task Reserved_audit_readers_never_reintroduce_the_historical_domain()
    {
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { UseReservedDomain = true, Latency = SimulationLatency.None }, TestClock.Fixed());
        var audit = new SimulatedAuditReader(source);
        var payload = JsonSerializer.Serialize(await audit.DomainOverviewAsync(CancellationToken.None))
            + JsonSerializer.Serialize(await audit.ControllersAsync(CancellationToken.None));
        Check.False(payload.Contains("example.local", StringComparison.OrdinalIgnoreCase), "contrôleurs et partitions réellement consommés adaptés");
        Check.True(payload.Contains("example.invalid", StringComparison.OrdinalIgnoreCase), "domaine réservé visible");
    }

    [Test]
    public static async Task Real_network_definition_is_refused_before_its_handler_in_demo()
    {
        var calls = 0;
        var sent = new List<BridgeResponse>();
        var registry = new OperationRegistry([new("test.network", OperationClass.NetworkRead, (_, _, _) =>
        { calls++; return Task.FromResult<object?>(null); }, "sentinelle réseau réel")]);
        using var dispatcher = new BridgeDispatcher(registry, sent.Add, AdmissionGuards.ReadOnlySimulation);
        await dispatcher.HandleAsync("""{"id":"deny","op":"test.network","args":{}}""", CancellationToken.None);
        Check.Equal(0, calls, "aucune entrée dans l’adaptateur réseau");
        Check.Equal("error", sent.Single().Kind, "refus visible au moteur");
    }

    [Test]
    public static void Fictitious_destinations_are_qualified_without_following_real_or_network_paths()
    {
        Check.Equal(2, SimulatedStorageDestinations.Proposal(TestClock.Fixed()).Folders.Length, "destinations inventées complètes");
        Check.True(SimulatedStorageDestinations.Facts(SimulatedStorageDestinations.Root + @"\copie.db").FolderExists, "destination fictive utilisable par le plan");
        foreach (var path in new[] { @"C:\Users\personne\base.db", @"\\serveur\partage\base.db", @"D:\Domenia-Fictif\..\base.db" })
        {
            Check.False(SimulatedStorageDestinations.Facts(path).LocalFixedDrive, "aucune qualification réelle : " + path);
            Check.Throws<DomeniaOperationException>(() => SimulatedStorageDestinations.Browse(path), "navigation réelle refusée avant I/O");
        }
    }

    [Test]
    public static void Demo_clock_remains_controllable_and_advances_expiration_rules()
    {
        var elapsed = TestClock.Fixed();
        var opened = TestClock.Reference.AddDays(4);
        var clock = new DemonstrationClock(opened, TestClock.Paris, elapsed);
        Check.Equal(opened, clock.GetUtcNow(), "instant d’ouverture explicite");
        elapsed.Advance(TimeSpan.FromMinutes(20));
        Check.Equal(opened.AddMinutes(20), clock.GetUtcNow(), "les délais métier ne sont pas figés");
        Check.Equal(TestClock.Paris, clock.LocalTimeZone, "même fuseau pour génération et calculs");
    }

    private static int Locked(JsonElement board) => board.GetProperty("widgets").GetProperty("lockedAccounts").GetProperty("data").GetProperty("value").GetInt32();
}
