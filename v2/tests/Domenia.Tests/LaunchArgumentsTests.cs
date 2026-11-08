using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class LaunchArgumentsTests
{
    private const string Root = "DC=example,DC=local", Paris = "OU=Paris,OU=Postes," + Root;
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static void Launch_overrides_are_bounded_and_other_modes_keep_their_own_arguments()
    {
        var read = LaunchArguments.Parse(["--server", "dc01.example.local", "--base", Paris, "--default-limit", "245", "--no-auto-connect", "--simulation", "--selftest"]);
        Check.True(read.Valid, "options qualifiées");
        Check.Equal("dc01.example.local", read.Options.Server, "serveur explicite");
        Check.Equal(Paris, read.Options.BaseDn, "DN conservé");
        Check.Equal(245, read.Options.DefaultLimit, "limite");
        Check.True(read.Options.NoAutoConnect, "connexion explicite conservée");
        Check.True(read.Remaining.SequenceEqual(["--simulation", "--selftest"]), "autres parseurs propriétaires");
        var aliases = LaunchArguments.Parse(["-Server", "DC01", "-SearchBase", Root, "-DefaultLimit", "20000", "-NoAutoConnect"]);
        Check.True(aliases.Valid, "noms D1"); Check.Equal(20000, aliases.Options.DefaultLimit, "borne exacte");
    }

    [Test]
    public static void Invalid_launch_values_never_leak_the_input_or_leave_partially_accepted_options()
    {
        string[][] bad = [["--server", "secret@example.local"], ["--server", "ldap://dc"], ["--server", "127.0.0.1"],
            ["--server", "dc", "-Server", "other"], ["--base", "CN=secret," + Root], ["--base", "OU=x,DC=example,OU=bad"],
            ["--default-limit", "0"], ["--default-limit", "20001"], ["--default-limit", "1.0"], ["--base"],
            ["--server", new string('s', 4097)]];
        foreach (var args in bad)
        {
            var read = LaunchArguments.Parse(args);
            Check.False(read.Valid, "entrée invalide refusée");
            Check.Equal(LaunchOptions.Default, read.Options, "aucune option partiellement appliquée");
            Check.False(read.Error!.Contains("secret", StringComparison.Ordinal), "aucun argument brut dans l’erreur");
        }
        Check.False(LaunchArguments.Parse(Enumerable.Repeat("--simulation", 129).ToArray()).Valid, "nombre d’arguments borné");
    }

    [Test]
    public static async Task Launch_base_wins_for_this_session_only_and_never_changes_the_saved_scope()
    {
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var prefs = new MemoryPreferenceStore();
        var key = WorkingScope.PreferenceKey(Root);
        await prefs.SetAsync(key, JsonSerializer.SerializeToElement(new { dn = Root, subtree = true }), None);
        var readers = ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]);
        using var engine = new EngineContext(SimulatedBridge.Decision, source, prefs, clock, new RecordingJournal(), readers, launch: new(BaseDn: Paris));
        var scope = WorkingScope.From(engine);
        var session = await source.GetSessionAsync(None);
        Check.Equal(Paris, (await scope.CurrentAsync(session, None))!.Dn, "base CLI locale existante");
        Check.True(prefs.TryGet(key, out var stored), "préférence toujours présente");
        Check.Equal(Root, stored.GetProperty("dn").GetString(), "préférence non réécrite");
        using var next = new WorkingScope(prefs, readers.Find<IOrganizationalUnitIndex>(), new OperationJournal(), clock, new RecordingJournal());
        Check.Equal(Root, (await next.CurrentAsync(session, None))!.Dn, "prochaine session retrouve son choix mémorisé");
    }

    [Test]
    public static async Task Unknown_or_foreign_launch_base_is_refused_without_widening_or_persisting()
    {
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(None);
        foreach (var dn in new[] { "OU=Absente," + Root, "OU=Postes,DC=other,DC=local" })
        {
            var prefs = new MemoryPreferenceStore();
            using var scope = new WorkingScope(prefs, bridge.Context.Readers.Find<IOrganizationalUnitIndex>(), new OperationJournal(), bridge.Clock, bridge.Log, dn);
            var refused = false;
            try { _ = await scope.CurrentAsync(session, None); }
            catch (DomeniaOperationException ex) when (ex.Code == (dn.Contains("other", StringComparison.Ordinal) ? DomeniaErrors.ScopeOutsideDomain : DomeniaErrors.ScopeUnknown))
            { refused = true; }
            Check.True(refused, "refus précis, aucun domaine entier substitué");
            Check.False(prefs.TryGet(WorkingScope.PreferenceKey(Root), out _), "aucune préférence écrite");
        }
    }

    [Test]
    public static async Task Scope_generation_detects_a_change_then_return_and_ignores_identical_choices()
    {
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(None);
        var scope = WorkingScope.From(bridge.Context);
        var initial = await scope.CurrentAsync(session, None);
        var version = scope.SelectionVersion;
        await scope.SetAsync(session, Paris, true, None);
        Check.True(scope.SelectionVersion > version, "OU changée");
        var parisVersion = scope.SelectionVersion;
        await scope.SetAsync(session, Paris, true, None);
        Check.Equal(parisVersion, scope.SelectionVersion, "même choix");
        await scope.SetAsync(session, initial!.Dn, initial.Subtree, None);
        Check.True(scope.SelectionVersion > parisVersion, "retour ne ressuscite pas une ancienne demande");
        Check.Equal(initial.Dn, (await scope.CurrentAsync(session, None))!.Dn, "portée initiale réellement restaurée");
        var disconnected = session with { Domain = null, Scope = null };
        _ = await scope.CurrentAsync(disconnected, None);
        var absentVersion = scope.SelectionVersion;
        _ = await scope.CurrentAsync(disconnected, None);
        Check.Equal(absentVersion, scope.SelectionVersion, "absence inchangée ne crée pas de fausse génération");
    }

    [Test]
    public static async Task Real_search_bridge_uses_launch_limit_and_explicit_requests_keep_their_limit()
    {
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        using var engine = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(),
            ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]), launch: new(DefaultLimit: 17));
        var replies = new List<BridgeResponse>();
        using var dispatcher = new BridgeDispatcher(OperationModules.CreateRegistry(engine, [new SearchOperations()]), replies.Add);
        await dispatcher.HandleAsync("{\"id\":\"policy\",\"op\":\"search.policy\"}", None);
        Check.Equal(17, SimulatedBridge.Json(replies[^1]).GetProperty("defaultLimit").GetInt32(), "valeur fournie à la barre visible");
        await dispatcher.HandleAsync(JsonSerializer.Serialize(new { id = "default", op = "search.browse", args = new { dn = Paris, subtree = true } }), None);
        var first = SimulatedBridge.Json(replies[^1]);
        Check.Equal(17, first.GetProperty("limit").GetInt32(), "limite appliquée au moteur");
        Check.Equal(17, first.GetProperty("rows").GetArrayLength(), "preuve positive : liste effectivement bornée");
        await dispatcher.HandleAsync(JsonSerializer.Serialize(new { id = "explicit", op = "search.browse", args = new { dn = Paris, subtree = true, limit = 9 } }), None);
        Check.Equal(9, SimulatedBridge.Json(replies[^1]).GetProperty("rows").GetArrayLength(), "choix explicite conservé");
    }
}
