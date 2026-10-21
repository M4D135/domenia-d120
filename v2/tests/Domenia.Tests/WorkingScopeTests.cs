using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class WorkingScopeTests
{
    private const string Root = "DC=example,DC=local";
    private const string Postes = "OU=Postes,DC=example,DC=local";
    private const string Paris = "OU=Paris,OU=Postes,DC=example,DC=local";
    private const string Sep = FrenchText.PathSeparator;

    private static string SetScope(string dn, bool subtree) => JsonSerializer.Serialize(new { dn, subtree });

    private static JsonElement Rows(JsonElement summary) =>
        summary.GetProperty("widgets").GetProperty("recentOperations").GetProperty("data").GetProperty("rows");

    [Test]
    public static async Task Set_scope_answers_the_updated_session_and_moves_the_workstation_widgets()
    {
        var bridge = new SimulatedBridge();
        var before = SimulatedBridge.Json(await bridge.CallAsync("session.info"));
        Check.Equal(Postes, before.GetProperty("scope").GetProperty("dn").GetString(), "OU de travail par défaut");

        var session = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", SetScope(Paris, true)));
        Check.True(session.EnumerateObject().Select(p => p.Name).SequenceEqual(
            ["connection", "domain", "controller", "account", "authentication", "scope", "rights", "readOnly", "tasks", "cache", "onboarding"]), "forme de session.info");
        var scope = session.GetProperty("scope");
        Check.Equal(Paris, scope.GetProperty("dn").GetString(), "OU choisie");
        Check.Equal("Paris", scope.GetProperty("label").GetString(), "libellé : nom de l’OU");
        Check.True(scope.GetProperty("subtree").GetBoolean(), "sous-OU comprises");
        // Simulation: writes admitted on the in-memory overlay only (decision of 21/10), so not read only; unchanged by the scope.
        Check.False(session.GetProperty("readOnly").GetBoolean(), "lecture seule inchangée par le choix de l’OU (simulation : écritures en mémoire)");

        var summary = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        Check.Equal(Paris, summary.GetProperty("scope").GetProperty("dn").GetString(), "le tableau de bord suit l’OU de travail");
        var online = summary.GetProperty("widgets").GetProperty("workstationsOnline");
        Check.Equal("OU Paris", online.GetProperty("scopeLabel").GetString(), "périmètre affiché");
        Check.Equal(186, online.GetProperty("data").GetProperty("total").GetInt32(), "postes de Paris");
        Check.Equal("Domaine example.local", summary.GetProperty("widgets").GetProperty("lockedAccounts").GetProperty("scopeLabel").GetString(), "comptes : tout le domaine");
        Check.True(Rows(summary).EnumerateArray().Any(r => r.GetProperty("label").GetString() == "OU de travail" + FrenchText.Colon + "example.local" + Sep + "Postes" + Sep + "Paris"),
            "changement inscrit au journal des opérations");
    }

    [Test]
    public static async Task History_of_another_ou_is_never_shown_as_its_own()
    {
        var bridge = new SimulatedBridge();
        var postes = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary")).GetProperty("widgets");
        Check.Equal(14, postes.GetProperty("workstationsOnline").GetProperty("data").GetProperty("history").GetArrayLength(), "historique de l’OU Postes");
        _ = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", SetScope(Paris, true)));
        var paris = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary")).GetProperty("widgets");
        var kpi = paris.GetProperty("workstationsOnline").GetProperty("data");
        Check.Equal(1, kpi.GetProperty("history").GetArrayLength(), "seul le point du jour");
        Check.Equal(JsonValueKind.Null, kpi.GetProperty("delta").ValueKind, "aucun écart inventé");
        Check.Equal(JsonValueKind.Null, paris.GetProperty("diskAlerts").GetProperty("data").GetProperty("delta").ValueKind, "disques : aucun écart inventé");
        var points = paris.GetProperty("workstationActivity").GetProperty("data").GetProperty("points");
        Check.True(points.EnumerateArray().Take(6).All(p => p.GetProperty("value").ValueKind == JsonValueKind.Null), "jours passés absents");
        Check.Equal(1186, paris.GetProperty("activeAccounts").GetProperty("data").GetProperty("history").EnumerateArray().Last().GetProperty("value").GetInt32(), "historique des comptes inchangé");
        Check.Equal(14, paris.GetProperty("activeAccounts").GetProperty("data").GetProperty("history").GetArrayLength(), "comptes : historique du domaine gardé");
    }

    [Test]
    public static async Task A_presence_round_only_probes_the_working_ou()
    {
        var clock = TestClock.Fixed();
        var bridge = new SimulatedBridge(clock: clock);
        _ = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", SetScope(Paris, true)));
        clock.Advance(TimeSpan.FromMinutes(3));
        var refreshed = SimulatedBridge.Json(await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"workstationsOnline\"}"));
        Check.Equal(186, refreshed.GetProperty("data").GetProperty("total").GetInt32(), "relevé borné à Paris");
        var state = await bridge.Source.ReadLocalAsync(CancellationToken.None);
        var parisGuids = bridge.Source.World.Directory.Computers.Where(c => DistinguishedName.IsWithin(c.DistinguishedName, Paris, true)).Select(c => c.ObjectGuid).ToHashSet();
        var now = clock.GetUtcNow();
        Check.True(state.Observations.Workstations.Where(o => !parisGuids.Contains(o.ComputerGuid)).All(o => o.Presence.CheckedAt != now), "les autres sites gardent leur relevé");
        Check.True(state.Observations.Workstations.Where(o => parisGuids.Contains(o.ComputerGuid)).Count(o => o.Presence.CheckedAt == now) > 150, "les postes de Paris sont relevés maintenant");
    }

    [Test]
    public static async Task The_whole_domain_is_a_choice_but_never_measured()
    {
        var bridge = new SimulatedBridge();
        var session = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", SetScope("dc=example,dc=local", false)));
        var scope = session.GetProperty("scope");
        Check.Equal(Root, scope.GetProperty("dn").GetString(), "racine de la session");
        Check.Equal("example.local", scope.GetProperty("label").GetString(), "libellé : domaine");
        Check.True(scope.GetProperty("subtree").GetBoolean(), "tout le domaine : sous-OU toujours comprises");
        var summary = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        Check.Equal("Domaine example.local", summary.GetProperty("widgets").GetProperty("diskAlerts").GetProperty("scopeLabel").GetString(), "périmètre affiché");
        foreach (var id in new[] { "workstationsOnline", "diskAlerts", "measureFreshness" })
        {
            var refused = await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"" + id + "\"}");
            Check.Equal(DomeniaErrors.ScopeTooWide, refused.Error!.Code, "mesure des postes refusée sur tout le domaine : " + id);
        }
        Check.Equal(0, bridge.Source.PresenceRound, "aucune manche");
        Check.Equal("result", (await bridge.CallAsync("dashboard.widget.refresh", "{\"id\":\"lockedAccounts\"}")).Kind, "lecture d’annuaire admise");
    }

    [Test]
    public static async Task Unknown_containers_other_domains_and_bad_arguments_are_refused()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(DomeniaErrors.ScopeUnknown, (await bridge.CallAsync("session.setScope", SetScope("OU=Absente,DC=example,DC=local", true))).Error!.Code, "OU absente");
        Check.Equal(DomeniaErrors.ScopeUnknown, (await bridge.CallAsync("session.setScope", SetScope("CN=Computers,DC=example,DC=local", true))).Error!.Code, "conteneur");
        var other = await bridge.CallAsync("session.setScope", SetScope("OU=Postes,DC=autre,DC=local", true));
        Check.Equal(DomeniaErrors.ScopeOutsideDomain, other.Error!.Code, "autre domaine");
        Check.Equal(DomeniaErrors.ScopeOutsideDomainMessage, other.Error.Message, "message du contrat");
        foreach (var args in new[] { "{\"dn\":\"" + Paris + "\"}", "{\"subtree\":true}", "{\"dn\":\"pas un DN\",\"subtree\":true}", "{\"dn\":null,\"subtree\":true}", "{\"dn\":\"" + Paris + "\",\"subtree\":\"oui\"}", "{\"dn\":\"" + Paris + "\",\"subtree\":true,\"x\":1}" })
        {
            Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("session.setScope", args)).Error!.Code, "arguments refusés");
        }
        var session = SimulatedBridge.Json(await bridge.CallAsync("session.info"));
        Check.Equal(Postes, session.GetProperty("scope").GetProperty("dn").GetString(), "rien n’a changé");
        Check.Equal(0, ((MemoryPreferenceStore)bridge.Preferences).Writes, "rien n’a été mémorisé");
    }

    [Test]
    public static async Task The_choice_is_remembered_per_domain_and_restored_at_the_next_start()
    {
        var preferences = new MemoryPreferenceStore();
        var first = new SimulatedBridge(preferences: preferences);
        _ = SimulatedBridge.Json(await first.CallAsync("session.setScope", SetScope(Paris, false)));
        var key = WorkingScope.PreferenceKey(Root);
        Check.True(preferences.TryGet(key, out var stored), "mémorisé sous la clé du domaine");
        Check.Equal(Paris, stored.GetProperty("dn").GetString(), "DN mémorisé");
        Check.False(stored.GetProperty("subtree").GetBoolean(), "profondeur mémorisée");
        Check.Equal(key, WorkingScope.PreferenceKey("dc=EXAMPLE,dc=local"), "clé indépendante de la casse");
        var writes = preferences.Writes;
        _ = SimulatedBridge.Json(await first.CallAsync("session.setScope", SetScope(Paris, false)));
        Check.Equal(writes, preferences.Writes, "même choix : aucune écriture");

        var second = new SimulatedBridge(preferences: preferences);
        var scope = SimulatedBridge.Json(await second.CallAsync("session.info")).GetProperty("scope");
        Check.Equal(Paris, scope.GetProperty("dn").GetString(), "OU restaurée au démarrage");
        Check.False(scope.GetProperty("subtree").GetBoolean(), "profondeur restaurée");
        Check.Equal("Paris", scope.GetProperty("label").GetString(), "libellé relu dans l’arbre");
    }

    [Test]
    public static async Task A_remembered_ou_that_no_longer_exists_falls_back_to_the_default()
    {
        var preferences = new MemoryPreferenceStore();
        using (var document = JsonDocument.Parse("""{"dn":"OU=Fermé,OU=Postes,DC=example,DC=local","subtree":true}"""))
        {
            await preferences.SetAsync(WorkingScope.PreferenceKey(Root), document.RootElement, CancellationToken.None);
        }
        using (var other = JsonDocument.Parse("""{"dn":"OU=Postes,DC=autre,DC=local","subtree":true}"""))
        {
            // Remembered for another domain: never read for this one.
            await preferences.SetAsync(WorkingScope.PreferenceKey("DC=autre,DC=local"), other.RootElement, CancellationToken.None);
        }
        var bridge = new SimulatedBridge(preferences: preferences);
        var session = SimulatedBridge.Json(await bridge.CallAsync("session.info"));
        Check.Equal(Postes, session.GetProperty("scope").GetProperty("dn").GetString(), "périmètre par défaut");
        var summary = SimulatedBridge.Json(await bridge.CallAsync("dashboard.summary"));
        Check.True(Rows(summary).EnumerateArray().Any(r => r.GetProperty("tone").GetString() == "warn"
            && r.GetProperty("label").GetString()!.StartsWith("OU de travail mémorisée introuvable", StringComparison.Ordinal)), "l’opérateur est prévenu");
        Check.True(bridge.Log.Lines.Any(l => l.Contains(DomeniaErrors.ScopeUnknown, StringComparison.Ordinal)), "raison tracée par son code");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("Fermé", StringComparison.Ordinal)), "DN jamais recopié dans le journal technique");
    }

    [Test]
    public static async Task Unreadable_remembered_value_is_traced_and_ignored()
    {
        var preferences = new MemoryPreferenceStore();
        using (var document = JsonDocument.Parse("""["OU=Paris"]"""))
        {
            await preferences.SetAsync(WorkingScope.PreferenceKey(Root), document.RootElement, CancellationToken.None);
        }
        var bridge = new SimulatedBridge(preferences: preferences);
        Check.Equal(Postes, SimulatedBridge.Json(await bridge.CallAsync("session.info")).GetProperty("scope").GetProperty("dn").GetString(), "périmètre par défaut");
        Check.True(bridge.Log.Lines.Any(l => l.Contains("OU de travail mémorisée illisible", StringComparison.Ordinal)), "valeur illisible tracée");
    }

    [Test]
    public static async Task Directory_mode_without_ad_refuses_the_tree_and_the_choice()
    {
        var clock = TestClock.Fixed();
        var decision = ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "cnamts.local"));
        var source = new UnavailableDirectorySource("cnamts.local", () => @"CNAMTS\degun");
        using var context = new EngineContext(decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        var sent = new List<BridgeResponse>();
        var dispatcher = new BridgeDispatcher(OperationModules.CreateRegistry(context, OperationModules.Discover([typeof(DashboardOperations).Assembly])), sent.Add, AdmissionGuards.For(decision.Mode));
        await dispatcher.HandleAsync("{\"id\":\"a\",\"op\":\"directory.ou.children\",\"args\":{\"dn\":null}}", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent[^1].Error!.Code, "arbre indisponible");
        await dispatcher.HandleAsync("{\"id\":\"b\",\"op\":\"directory.ou.search\",\"args\":{\"text\":\"paris\"}}", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent[^1].Error!.Code, "recherche indisponible");
        await dispatcher.HandleAsync("{\"id\":\"c\",\"op\":\"session.setScope\",\"args\":{\"dn\":\"OU=Postes,DC=cnamts,DC=local\",\"subtree\":true}}", CancellationToken.None);
        Check.Equal(DomeniaErrors.SourceUnavailable, sent[^1].Error!.Code, "choix indisponible sans connexion");
        await dispatcher.HandleAsync("{\"id\":\"d\",\"op\":\"session.info\"}", CancellationToken.None);
        Check.Equal(JsonValueKind.Null, SimulatedBridge.Json(sent[^1]).GetProperty("scope").ValueKind, "aucune OU de travail");
    }

    [Test]
    public static async Task The_remembered_ou_is_checked_in_the_local_index_never_by_the_tree_panel_reader()
    {
        // The constructor only takes the local index: the panel reader (network reads in directory mode) cannot be used.
        Check.False(typeof(WorkingScope).GetConstructors().SelectMany(c => c.GetParameters()).Any(p => typeof(IDirectoryTreeReader).IsAssignableFrom(p.ParameterType)),
            "aucun lecteur de l’arbre (réseau en mode annuaire) dans le constructeur");
        var bridge = new SimulatedBridge();
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        var preferences = new MemoryPreferenceStore();
        using (var document = JsonDocument.Parse(SetScope(Paris, false)))
        {
            await preferences.SetAsync(WorkingScope.PreferenceKey(Root), document.RootElement, CancellationToken.None);
        }
        var index = new CountingIndex(new OuEntry(Paris, "Paris", "example.local" + Sep + "Postes" + Sep + "Paris", false, new OuCounts(0, 0, 0)));
        using var scope = new WorkingScope(preferences, index, new OperationJournal(), TestClock.Fixed(), new RecordingJournal());
        var current = await scope.CurrentAsync(session, CancellationToken.None);
        Check.Equal(Paris, current!.Dn, "OU restaurée depuis l’index local");
        Check.False(current.Subtree, "profondeur restaurée");
        Check.Equal(1, index.Calls, "une seule vérification, locale");
        _ = await scope.CurrentAsync(session, CancellationToken.None);
        Check.Equal(1, index.Calls, "vérifiée une fois par domaine et par session");
    }

    [Test]
    public static async Task Scope_onboarding_step_and_set_scope_class()
    {
        var bridge = new SimulatedBridge();
        Check.True(bridge.Registry.TryGet("session.setScope", out var definition), "opération déclarée");
        Check.Equal(OperationClass.LocalWrite, definition!.Class, "écriture locale seulement");
        Check.Null(AdmissionGuards.ReadOnlySimulation(definition), "admise en simulation");
        var session = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", SetScope(Paris, true)));
        var step = session.GetProperty("onboarding").GetProperty("steps")[1];
        Check.Equal("scope", step.GetProperty("id").GetString(), "étape du choix de l’OU");
        Check.True(step.GetProperty("done").GetBoolean(), "faite");
    }

    /// <summary>Local OU index that counts its calls (never the network).</summary>
    private sealed class CountingIndex(OuEntry entry) : IOrganizationalUnitIndex
    {
        public int Calls { get; private set; }

        public Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult<OuEntry?>(string.Equals(dn, entry.Dn, StringComparison.OrdinalIgnoreCase) ? entry : null);
        }
    }
}
