using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Operations of the workstation console through the simulated bridge (docs/ops/poste.md): local reads, network reads
/// served by the simulation, progress events, collections by kind and partial results, secrets through the secure window of
/// the host only, authorizations and the writes of the screen through the circuit. Written, run at the very end (decision of
/// David, 21/10 and 22/10).
/// </summary>
internal static class PosteOperationsTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static IEnumerable<DirectoryComputer> Workstations(SimulatedBridge bridge) => Workstations(bridge.Source);

    private static IEnumerable<DirectoryComputer> Workstations(SimulatedDirectorySource source) =>
        source.CurrentDirectory.Computers.Where(c => c.Name.StartsWith("PC-", StringComparison.Ordinal) || c.Name.StartsWith("PT-", StringComparison.Ordinal)).OrderBy(c => c.Name, StringComparer.Ordinal);

    /// <summary>First workstation that answers the ping of the simulation (one ping each, as an operator would).</summary>
    private static async Task<DirectoryComputer> ReachableAsync(SimulatedBridge bridge)
    {
        foreach (var c in Workstations(bridge).Take(60))
        {
            var r = await bridge.CallAsync("poste.ping", Args(new { dn = c.DistinguishedName }));
            if (r.Kind == "result" && SimulatedBridge.Json(r).GetProperty("answered").ValueKind == JsonValueKind.True)
            {
                return c;
            }
        }
        throw new TestFailureException("aucun poste ne répond au ping dans la simulation");
    }

    /// <summary>A reachable workstation whose CIM answers (a full inventory reads it without any fallback).</summary>
    private static async Task<DirectoryComputer> ReadableAsync(SimulatedBridge bridge)
    {
        foreach (var c in Workstations(bridge).Take(80))
        {
            var r = await bridge.CallAsync("poste.services", Args(new { dn = c.DistinguishedName }));
            if (r.Kind == "result")
            {
                return c;
            }
        }
        throw new TestFailureException("aucun poste lisible par CIM dans la simulation");
    }

    private static string Execute(JsonElement planned, string? typedName = null) => Args(new
    {
        planId = planned.GetProperty("plan").GetProperty("id").GetString(),
        token = planned.GetProperty("token").GetString(),
        typedName,
    });

    private static string? Typed(JsonElement planned, DirectoryComputer c) =>
        planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean() ? PosteDirectoryWrites.TypedName(c) : null;

    [Test]
    public static async Task List_and_console_read_the_local_base_only()
    {
        var bridge = new SimulatedBridge();
        var list = SimulatedBridge.Json(await bridge.CallAsync("poste.list", Args(new { limit = 50 })));
        var rows = list.GetProperty("rows").EnumerateArray().ToList();
        Check.True(rows.Count is > 0 and <= 50, "postes de l’OU de travail, bornés : " + rows.Count);
        Check.True(list.GetProperty("total").GetInt32() >= rows.Count, "total connu");
        var dn = rows[0].GetProperty("dn").GetString()!;
        var console = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn })));
        Check.Equal(rows[0].GetProperty("name").GetString(), console.GetProperty("computer").GetProperty("name").GetString(), "console du poste choisi");
        Check.True(console.GetProperty("simulated").GetBoolean(), "poste fictif signalé");
        Check.False(console.GetProperty("header").GetProperty("presence").GetProperty("state").GetString() == "pending", "aucun test lancé à l’ouverture");
        Check.True(console.GetProperty("board").ValueKind == JsonValueKind.Object, "tableau construit sans lecture réseau");
        Check.False(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains("ping", StringComparison.OrdinalIgnoreCase)), "aucun ping à l’ouverture");
        Check.Equal(0L, bridge.Source.Overlay.Version, "rien n’est écrit");
        Check.False(console.GetProperty("options").GetRawText().Contains("wapt", StringComparison.OrdinalIgnoreCase), "aucun connecteur WAPT (décision du 22/10)");

        var filtered = SimulatedBridge.Json(await bridge.CallAsync("poste.list", Args(new { text = rows[0].GetProperty("name").GetString() })));
        Check.True(filtered.GetProperty("rows").EnumerateArray().Any(r => r.GetProperty("dn").GetString() == dn), "recherche locale par nom");
    }

    [Test]
    public static async Task Unknown_or_malformed_targets_are_refused()
    {
        var bridge = new SimulatedBridge();
        var user = bridge.Source.CurrentDirectory.Users.First();
        Check.Equal(PosteErrors.ComputerUnknown, (await bridge.CallAsync("poste.open", Args(new { dn = user.DistinguishedName }))).Error!.Code, "un compte utilisateur n’est pas un poste");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.open", Args(new { dn = "pas un DN" }))).Error!.Code, "DN mal formé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.open", "{}")).Error!.Code, "DN absent");
        var dn = Workstations(bridge).First().DistinguishedName;
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.open", Args(new { dn, extra = 1 }))).Error!.Code, "argument inconnu refusé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.events", Args(new { dn, preset = "Tout" }))).Error!.Code, "préréglage inconnu refusé");
        Check.Equal(PosteErrors.QueryRefused, (await bridge.CallAsync("poste.wmi.query", Args(new { dn, ns = @"root\cimv2", cls = "Win32_Product" }))).Error!.Code, "Win32_Product bloquée");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.collect.stop", Args(new { dn, kind = "tout" }))).Error!.Code, "type de relevé inconnu refusé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.probes.collect", Args(new { dn, probes = new[] { "pas.une.sonde" } }))).Error!.Code, "sonde hors du catalogue refusée");
        Check.Equal("operation.unknown", (await bridge.CallAsync("poste.wapt", Args(new { dn }))).Error!.Code, "le connecteur WAPT n’existe plus (décision du 22/10)");
    }

    [Test]
    public static async Task Quick_inventory_publishes_its_progress_and_becomes_the_last_one()
    {
        var bridge = new SimulatedBridge();
        var c = await ReadableAsync(bridge);
        var result = SimulatedBridge.Json(await bridge.CallAsync("poste.inventory", Args(new { dn = c.DistinguishedName, deep = false })));
        Check.True(result.GetProperty("rows").GetArrayLength() > 20, "lignes d’inventaire");
        Check.True(result.GetProperty("access").EnumerateArray().Any(), "état par source");
        Check.False(result.GetProperty("partial").GetBoolean(), "inventaire complet de ses sources : pas partiel");
        Check.True(bridge.Events.Any(e => e.Operation == "poste.inventory:progress"), "progression publiée");
        var console = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn = c.DistinguishedName })));
        Check.True(console.GetProperty("inventory").ValueKind == JsonValueKind.Object, "inventaire mémorisé pour la console");
        Check.False(console.GetProperty("inventory").GetProperty("deep").GetBoolean(), "inventaire rapide");

        // PST-029, PST-036: the last inventory is shown again with its rows, without any network read.
        var cached = SimulatedBridge.Json(await bridge.CallAsync("poste.inventory.cached", Args(new { dn = c.DistinguishedName })));
        Check.Equal(result.GetProperty("rows").GetRawText(), cached.GetProperty("rows").GetRawText(), "mêmes lignes reprises de la session");
        Check.Contains("session", cached.GetProperty("origin").GetString(), "provenance dite");

        var again = new SimulatedBridge();
        _ = await again.CallAsync("poste.ping", Args(new { dn = c.DistinguishedName }));
        var second = SimulatedBridge.Json(await again.CallAsync("poste.inventory", Args(new { dn = c.DistinguishedName, deep = false })));
        Check.Equal(result.GetProperty("rows").GetRawText(), second.GetProperty("rows").GetRawText(), "données du poste déterministes");
    }

    [Test]
    public static async Task Cached_inventory_comes_from_the_local_base_or_is_null()
    {
        var bridge = new SimulatedBridge();
        var withStored = 0;
        var without = 0;
        foreach (var c in Workstations(bridge).Take(40))
        {
            var r = await bridge.CallAsync("poste.inventory.cached", Args(new { dn = c.DistinguishedName }));
            Check.Equal("result", r.Kind, "lecture locale servie");
            var data = SimulatedBridge.Json(r);
            if (data.ValueKind == JsonValueKind.Null)
            {
                without++;
                continue;
            }
            withStored++;
            Check.Contains("Base locale", data.GetProperty("origin").GetString(), "inventaire validé de la base locale");
            Check.True(data.GetProperty("rows").GetArrayLength() > 0, "ses lignes sont réaffichées");
        }
        Check.True(withStored > 0, "des postes ont un inventaire en base");
        Check.False(bridge.Events.Any(), "aucune lecture réseau, aucune progression");
        Check.True(without >= 0, "un poste sans inventaire rend null");
    }

    [Test]
    public static async Task Network_reads_of_the_screen_are_served_in_simulation()
    {
        var bridge = new SimulatedBridge();
        var c = await ReadableAsync(bridge);
        var dn = c.DistinguishedName;
        foreach (var (op, args) in new (string, object)[]
        {
            ("poste.live", new { dn }), ("poste.services", new { dn }), ("poste.processes", new { dn }), ("poste.sessions", new { dn }),
            ("poste.events", new { dn, preset = "Startup", hours = 72, max = 50 }), ("poste.diagnostic", new { dn }), ("poste.quickDiag", new { dn }),
            ("poste.slow", new { dn }), ("poste.logonByDc", new { dn }), ("poste.lastUser.detect", new { dn }), ("poste.probes.collect", new { dn }),
            ("poste.software", new { dn, perUser = true, store = false, updates = false }), ("poste.wmi.namespaces", new { dn }),
            ("poste.wmi.query", new { dn, ns = @"root\cimv2", cls = "Win32_OperatingSystem" }), ("poste.restart.sessions", new { dn }),
        })
        {
            var r = await bridge.CallAsync(op, Args(args));
            Check.Equal("result", r.Kind, op + " servie : " + (r.Error?.Code ?? "") + " " + (r.Error?.Message ?? ""));
        }
        var readings = SimulatedBridge.Json(await bridge.CallAsync("poste.readings", Args(new { dn })));
        Check.True(readings.GetProperty("readings").GetArrayLength() > 0, "relevés datés après la collecte");
        // No host in the tests: no tool opened, no file saved, no secret window.
        Check.Equal(PosteErrors.HostUnavailable, (await bridge.CallAsync("poste.tool.open", Args(new { dn, tool = "rdp" }))).Error!.Code, "aucun lanceur d’outils sans l’hôte");
        Check.Equal(PosteErrors.HostUnavailable, (await bridge.CallAsync("poste.export.save", Args(new { dn, kind = "inventaire", files = new[] { new { part = "lignes", csv = "a;b" } } }))).Error!.Code, "aucun enregistrement de fichier sans l’hôte");
        var host = SimulatedBridge.Json(await bridge.CallAsync("poste.host"));
        Check.False(host.GetProperty("secretWindow").GetBoolean(), "aucune fenêtre sécurisée dans les tests");
        Check.False(host.GetProperty("toolLauncher").GetBoolean(), "aucun lanceur dans les tests");
    }

    [Test]
    public static async Task Probes_are_collected_only_for_the_board()
    {
        var bridge = new SimulatedBridge();
        var c = await ReadableAsync(bridge);
        var readings = SimulatedBridge.Json(await bridge.CallAsync("poste.probes.collect", Args(new { dn = c.DistinguishedName, probes = new[] { "hw.memorymodules" } })));
        Check.True(readings.GetProperty("readings").GetArrayLength() > 0, "lectures interprétées");
        Check.True(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains("1 sonde demandée", StringComparison.Ordinal)), "une seule sonde demandée, dite au journal");
    }

    [Test]
    public static async Task Collections_of_different_kinds_run_together_and_the_same_kind_is_refused()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        var c = await ReadableAsync(bridge);
        var dn = c.DistinguishedName;
        var inventory = bridge.CallAsync("poste.inventory", Args(new { dn, deep = true }));
        await Task.Delay(150);
        var running = SimulatedBridge.Json(await bridge.CallAsync("poste.running"));
        Check.True(running.EnumerateArray().Any(r => r.GetProperty("kind").GetString() == "inventory"), "l’inventaire en cours est nommé");
        var second = await bridge.CallAsync("poste.inventory", Args(new { dn, deep = false }));
        Check.Equal(PosteErrors.Busy, second.Error!.Code, "un second inventaire du même poste est refusé, rien n’est remplacé");
        var diagnostic = await bridge.CallAsync("poste.diagnostic", Args(new { dn }));
        Check.Equal("result", diagnostic.Kind, "un diagnostic n’arrête jamais l’inventaire : " + (diagnostic.Error?.Message ?? ""));
        var done = await inventory;
        Check.Equal("result", done.Kind, "l’inventaire continue jusqu’au bout : " + (done.Error?.Message ?? ""));
        Check.False(SimulatedBridge.Json(done).GetProperty("partial").GetBoolean(), "inventaire non interrompu");
    }

    [Test]
    public static async Task A_stopped_inventory_keeps_what_was_read()
    {
        var bridge = new SimulatedBridge(SimulationLatency.Realistic);
        var c = await ReadableAsync(bridge);
        var dn = c.DistinguishedName;
        var inventory = bridge.CallAsync("poste.inventory", Args(new { dn, deep = true }));
        await Task.Delay(900);
        var stop = SimulatedBridge.Json(await bridge.CallAsync("poste.collect.stop", Args(new { dn, kind = "inventory" })));
        Check.True(stop.GetProperty("stopped").EnumerateArray().Any(k => k.GetString() == "inventory"), "arrêt de l’inventaire seulement");
        var result = await inventory;
        Check.Equal("result", result.Kind, "un arrêt rend un résultat partiel, pas une erreur : " + (result.Error?.Message ?? ""));
        var data = SimulatedBridge.Json(result);
        Check.True(data.GetProperty("partial").GetBoolean(), "résultat partiel");
        Check.True(data.GetProperty("access").EnumerateArray().Any(a => a.GetProperty("statusLabel").GetString() == "Interrompu"), "sources non lues « Interrompu »");
        Check.True(data.GetProperty("access").EnumerateArray().Any(a => a.GetProperty("statusLabel").GetString() == PosteLabels.SourceStatusLabel(SourceStatus.Ok) || a.GetProperty("statusLabel").GetString() == PosteLabels.SourceStatusLabel(SourceStatus.Empty)), "sources lues gardées");
        Check.Contains("Résultat partiel", data.GetProperty("notice").GetString(), "le partiel est dit");
        var console = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn })));
        Check.True(console.GetProperty("inventory").ValueKind == JsonValueKind.Object, "le résultat partiel est enregistré");
    }

    [Test]
    public static async Task A_refused_cim_reads_nothing_without_the_fallback_authorization()
    {
        var bridge = new SimulatedBridge();
        DirectoryComputer? blocked = null;
        JsonElement refused = default;
        foreach (var c in Workstations(bridge).Take(400))
        {
            var r = await bridge.CallAsync("poste.inventory", Args(new { dn = c.DistinguishedName, deep = false }));
            if (r.Kind == "result" && SimulatedBridge.Json(r).GetProperty("noticeAction").ValueKind == JsonValueKind.String)
            {
                blocked = c;
                refused = SimulatedBridge.Json(r);
                break;
            }
        }
        if (blocked is null)
        {
            throw new TestFailureException("aucun poste au CIM refusé dans les 400 premiers postes de la simulation");
        }
        Check.Equal("readFallback", refused.GetProperty("noticeAction").GetString(), "l’autorisation de repli est proposée");
        Check.False(refused.GetProperty("access").EnumerateArray().Any(a => a.GetProperty("statusLabel").GetString() == PosteLabels.SourceStatusLabel(SourceStatus.Ok)), "rien n’est lu sans autorisation (« non lu »)");
        var granted = SimulatedBridge.Json(await bridge.CallAsync("poste.consent.grant", Args(new { dn = blocked.DistinguishedName, kind = "readFallback", minutes = 5 })));
        Check.True(granted.GetProperty("consent").GetProperty("readFallback").GetProperty("active").GetBoolean(), "lecture de repli autorisée");
        var read = SimulatedBridge.Json(await bridge.CallAsync("poste.inventory", Args(new { dn = blocked.DistinguishedName, deep = false })));
        Check.Contains("repli", read.GetProperty("origin").GetString(), "lu par la lecture de repli");
        var history = SimulatedBridge.Json(await bridge.CallAsync("poste.consent.history"));
        Check.True(history.EnumerateArray().Any(h => h.GetProperty("action").GetString() == "Utilisée"), "l’autorisation est consommée une fois");
        var again = SimulatedBridge.Json(await bridge.CallAsync("poste.inventory", Args(new { dn = blocked.DistinguishedName, deep = false })));
        Check.Equal("readFallback", again.GetProperty("noticeAction").GetString(), "une seule lecture : la suivante rend de nouveau « non lu »");
    }

    [Test]
    public static async Task Secrets_are_never_read_without_the_secure_window()
    {
        var bridge = new SimulatedBridge();
        var c = Workstations(bridge).First(x => x.Laps == LapsKind.Windows && x.LapsExpiration is not null && PosteSimLaps(x));
        var view = SimulatedBridge.Json(await bridge.CallAsync("poste.laps", Args(new { dn = c.DistinguishedName })));
        Check.True(view.GetProperty("canReveal").GetBoolean(), "mot de passe lisible");
        // The facts of the view have a « value » each (dates, states): the view itself carries no password field.
        Check.False(view.TryGetProperty("value", out _) || view.TryGetProperty("password", out _), "les métadonnées ne portent aucune valeur");
        var reveal = await bridge.CallAsync("poste.laps.reveal", Args(new { dn = c.DistinguishedName }));
        Check.Equal(PosteErrors.HostUnavailable, reveal.Error!.Code, "sans fenêtre sécurisée : refus avant toute lecture");
        // The refusal itself is journaled (OperationRefusals); no display of a secret is.
        Check.False(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains("affiché dans la fenêtre sécurisée", StringComparison.Ordinal)), "rien n’est affiché ni journalisé");
        var state = SimulatedBridge.Json(await bridge.CallAsync("poste.secret.state"));
        Check.False(state.GetProperty("open").GetBoolean(), "aucune fenêtre ouverte");
    }

    private static bool PosteSimLaps(DirectoryComputer c) => !c.DistinguishedName.Contains("Lille", StringComparison.OrdinalIgnoreCase);

    [Test]
    public static async Task Secrets_go_to_the_secure_window_and_never_to_the_page()
    {
        var bridge = new HostedBridge();
        var c = Workstations(bridge.Source).First(x => x.Laps == LapsKind.Windows && x.LapsExpiration is not null && PosteSimLaps(x));
        _ = await bridge.CallAsync("poste.laps", Args(new { dn = c.DistinguishedName }));
        var response = await bridge.CallAsync("poste.laps.reveal", Args(new { dn = c.DistinguishedName }));
        Check.Equal("result", response.Kind, "révélation servie par la fenêtre de test : " + (response.Error?.Message ?? ""));
        var shown = HostedBridge.Json(response);
        var host = bridge.Host;
        Check.NotNull(host.Secret, "la fenêtre a reçu la valeur");
        var password = host.Secret!.Value!;
        Check.Equal(20, password.Length, "mot de passe fictif");
        Check.False(shown.GetRawText().Contains(password, StringComparison.Ordinal), "la valeur n’est jamais dans la réponse du pont");
        Check.False(shown.TryGetProperty("value", out _), "aucun champ valeur");
        Check.False(shown.TryGetProperty("blocks", out _), "aucun champ blocs");
        Check.Equal(30, shown.GetProperty("revealSeconds").GetInt32(), "affiché 30 s");
        Check.Equal(1, shown.GetProperty("extensions").GetInt32(), "une prolongation");
        Check.True(shown.GetProperty("simulated").GetBoolean(), "valeur fictive signalée");
        Check.False(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains(password, StringComparison.Ordinal)), "jamais dans le journal des opérations");
        Check.False(bridge.Log.Lines.Any(l => l.Contains(password, StringComparison.Ordinal)), "jamais dans le journal technique");
        Check.False(JsonSerializer.Serialize(host.Secret, BridgeJson.Options).Contains(password, StringComparison.Ordinal), "la lecture elle-même ne se sérialise jamais avec sa valeur");
        Check.False(host.Secret.ToString().Contains(password, StringComparison.Ordinal), "ToString ne montre jamais la valeur");
        var hidden = HostedBridge.Json(await bridge.CallAsync("poste.secret.hide"));
        Check.True(hidden.GetProperty("hidden").GetBoolean(), "fenêtre fermée sur « Masquer »");

        foreach (var computer in Workstations(bridge.Source))
        {
            var list = HostedBridge.Json(await bridge.CallAsync("poste.bitlocker.list", Args(new { dn = computer.DistinguishedName })));
            var keys = list.GetProperty("keys").EnumerateArray().ToList();
            if (keys.Count == 0 || list.GetProperty("readState").GetString() == "refused")
            {
                continue;
            }
            var keyDn = keys[0].GetProperty("dn").GetString();
            var guid = keys[0].GetProperty("keyGuid").GetString();
            Check.Equal(36, guid!.Length, "identifiant de récupération complet (GUID), pas ses 8 premiers caractères");
            var mismatch = await bridge.CallAsync("poste.bitlocker.reveal", Args(new { dn = computer.DistinguishedName, key = keyDn, expectedId = Guid.Empty.ToString("D") }));
            Check.Equal(PosteErrors.KeyMismatch, mismatch.Error!.Code, "identifiant différent : aucune valeur (Domenia 1 Mismatch)");
            var key = HostedBridge.Json(await bridge.CallAsync("poste.bitlocker.reveal", Args(new { dn = computer.DistinguishedName, key = keyDn, expectedId = guid })));
            Check.Equal(8, host.Secret!.Blocks.Length, "clé en huit blocs dans la fenêtre");
            Check.False(key.TryGetProperty("blocks", out _), "les blocs ne passent jamais par la page");
            var other = Workstations(bridge.Source).First(x => x.DistinguishedName != computer.DistinguishedName);
            Check.Equal(PosteErrors.KeyNotChild, (await bridge.CallAsync("poste.bitlocker.reveal", Args(new { dn = other.DistinguishedName, key = keyDn, expectedId = guid }))).Error!.Code, "clé d’un autre poste refusée");
            return;
        }
        throw new TestFailureException("aucune clé BitLocker lisible dans la simulation");
    }

    [Test]
    public static async Task A_refused_secret_resource_is_lifted_by_another_account_for_it_only()
    {
        var bridge = new SimulatedBridge();
        var marseille = Workstations(bridge).First(x => x.DistinguishedName.Contains("Marseille", StringComparison.OrdinalIgnoreCase));
        var list = SimulatedBridge.Json(await bridge.CallAsync("poste.bitlocker.list", Args(new { dn = marseille.DistinguishedName })));
        Check.Equal("refused", list.GetProperty("readState").GetString(), "lecture BitLocker refusée (simulation)");
        var other = SimulatedBridge.Json(await bridge.CallAsync("poste.account.other", Args(new { dn = marseille.DistinguishedName, resource = "bitlocker" })));
        Check.True(other.GetProperty("accepted").GetBoolean(), "autre compte accepté (invite fictive)");
        Check.False(other.GetRawText().Contains("password", StringComparison.OrdinalIgnoreCase), "aucun mot de passe");
        var again = SimulatedBridge.Json(await bridge.CallAsync("poste.bitlocker.list", Args(new { dn = marseille.DistinguishedName })));
        Check.False(again.GetProperty("readState").GetString() == "refused", "refus levé pour BitLocker");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.account.other", Args(new { dn = marseille.DistinguishedName, resource = "tout" }))).Error!.Code, "ressource inconnue refusée");
    }

    [Test]
    public static async Task Secrets_index_of_the_working_ou_holds_no_value()
    {
        var bridge = new SimulatedBridge();
        var index = SimulatedBridge.Json(await bridge.CallAsync("poste.secrets.index"));
        Check.True(index.GetProperty("rows").GetArrayLength() > 0, "postes de l’OU de travail");
        Check.False(index.GetRawText().Contains("Password", StringComparison.OrdinalIgnoreCase), "aucune valeur ni attribut de mot de passe");
        Check.Contains("aucune clé, aucune valeur", index.GetProperty("summary").GetString(), "le résumé le dit");
    }

    [Test]
    public static async Task Program_run_needs_the_authorization_of_intervention()
    {
        var bridge = new SimulatedBridge();
        var c = await ReachableAsync(bridge);
        var args = Args(new { dn = c.DistinguishedName, mode = "system", command = @"C:\Windows\System32\notepad.exe" });
        Check.Equal(PosteErrors.ConsentRequired, (await bridge.CallAsync("poste.run.plan", args)).Error!.Code, "sans autorisation : rien n’est préparé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.consent.grant", Args(new { dn = c.DistinguishedName, kind = "intervention", minutes = 99 }))).Error!.Code, "15 minutes au plus");
        var granted = SimulatedBridge.Json(await bridge.CallAsync("poste.consent.grant", Args(new { dn = c.DistinguishedName, kind = "intervention", minutes = 5 })));
        Check.True(granted.GetProperty("consent").GetProperty("intervention").GetProperty("active").GetBoolean(), "autorisation active");
        var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.run.plan", args));
        Check.True(planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "exécuter un programme : nom à saisir");
        var other = Workstations(bridge).First(x => x.DistinguishedName != c.DistinguishedName);
        Check.Equal(PosteErrors.ConsentRequired, (await bridge.CallAsync("poste.run.plan", Args(new { dn = other.DistinguishedName, mode = "system", command = "notepad.exe" }))).Error!.Code, "l’autorisation vaut pour ce seul poste");
        var revoked = SimulatedBridge.Json(await bridge.CallAsync("poste.consent.revoke", Args(new { dn = c.DistinguishedName, kind = "intervention" })));
        Check.True(revoked.GetProperty("removed").GetBoolean(), "autorisation retirée");
        Check.Equal(PosteErrors.ConsentRequired, (await bridge.CallAsync("poste.run.plan", args)).Error!.Code, "retirée : de nouveau refusé");
        var history = SimulatedBridge.Json(await bridge.CallAsync("poste.consent.history"));
        Check.True(history.GetArrayLength() >= 2, "historique de la session");
    }

    [Test]
    public static async Task Program_arguments_never_reach_the_plan_nor_the_receipt()
    {
        var bridge = new SimulatedBridge();
        var c = await ReachableAsync(bridge);
        const string Secret = "--jeton=SECRET-NE-PAS-GARDER-42";
        _ = await bridge.CallAsync("poste.consent.grant", Args(new { dn = c.DistinguishedName, kind = "intervention", minutes = 5 }));
        var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.run.plan", Args(new { dn = c.DistinguishedName, mode = "system", command = @"C:\Outils\maj.exe", arguments = Secret })));
        Check.False(planned.GetRawText().Contains("SECRET-NE-PAS-GARDER", StringComparison.Ordinal), "le plan ne porte pas les arguments");
        Check.Contains("non conservés", SimulatedBridge.Text(planned), "le plan dit leur longueur seulement");
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned, PosteDirectoryWrites.TypedName(c))));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "tâche créée (simulation)");
        Check.False(receipt.GetRawText().Contains("SECRET-NE-PAS-GARDER", StringComparison.Ordinal), "le reçu ne porte pas les arguments");
        var log = await bridge.Receipts.ReadAllAsync(CancellationToken.None);
        Check.False(JsonSerializer.Serialize(log.Receipts, BridgeJson.Options).Contains("SECRET-NE-PAS-GARDER", StringComparison.Ordinal), "le magasin des reçus non plus");
        Check.False(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains("SECRET-NE-PAS-GARDER", StringComparison.Ordinal)), "ni le journal des opérations");
        Check.False(bridge.Log.Lines.Any(l => l.Contains("SECRET-NE-PAS-GARDER", StringComparison.Ordinal)), "ni le journal technique");
    }

    [Test]
    public static async Task An_authorization_expired_between_plan_and_execution_sends_nothing()
    {
        var clock = TestClock.Fixed();
        var bridge = new SimulatedBridge(clock: clock);
        var c = await ReachableAsync(bridge);
        _ = await bridge.CallAsync("poste.consent.grant", Args(new { dn = c.DistinguishedName, kind = "intervention", minutes = 1 }));
        var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.run.plan", Args(new { dn = c.DistinguishedName, mode = "system", command = @"C:\Windows\System32\notepad.exe" })));
        clock.Advance(TimeSpan.FromMinutes(2));
        var response = await bridge.CallAsync("write.execute", Execute(planned, PosteDirectoryWrites.TypedName(c)));
        Check.Equal("write.stale", response.Error?.Code, "autorisation expirée : rien n’est envoyé");
        Check.Contains("expiré", response.Error?.Message, "la raison est dite");
    }

    [Test]
    public static async Task No_authorization_is_granted_while_a_write_stays_to_verify()
    {
        var bridge = new SimulatedBridge(receipts: new FirstVersionOnlyStore());
        var c = Workstations(bridge).First();
        var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.profile.plan", Args(new { dn = c.DistinguishedName, location = "Salle 12" })));
        _ = await bridge.CallAsync("write.execute", Execute(planned, Typed(planned, c)));
        var grant = await bridge.CallAsync("poste.consent.grant", Args(new { dn = c.DistinguishedName, kind = "intervention", minutes = 5 }));
        Check.Equal(PosteErrors.Pending, grant.Error?.Code, "écriture à vérifier sur le poste : aucune autorisation (Domenia 1 PST-010)");
        var history = SimulatedBridge.Json(await bridge.CallAsync("poste.consent.history"));
        Check.True(history.EnumerateArray().Any(h => h.GetProperty("action").GetString() == "Refusée"), "le refus est inscrit dans l’historique");
    }

    [Test]
    public static async Task Immediate_restart_runs_once_with_the_typed_name_and_a_receipt()
    {
        var bridge = new SimulatedBridge();
        var c = await ReachableAsync(bridge);
        var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.restart.plan", Args(new { dn = c.DistinguishedName, mode = "now" })));
        var confirmation = planned.GetProperty("plan").GetProperty("confirmation");
        Check.True(confirmation.GetProperty("typedNameRequired").GetBoolean(), "redémarrage immédiat : nom à saisir");
        Check.Equal(PosteDirectoryWrites.TypedName(c), confirmation.GetProperty("typedName").GetString(), "nom du poste sans $");
        Check.Equal("write.confirmationMismatch", (await bridge.CallAsync("write.execute", Execute(planned, "AUTRE"))).Error!.Code, "mauvais nom refusé");
        planned = SimulatedBridge.Json(await bridge.CallAsync("poste.restart.plan", Args(new { dn = c.DistinguishedName, mode = "now" })));
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned, PosteDirectoryWrites.TypedName(c))));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "redémarrage envoyé (simulation)");
        Check.True(receipt.GetProperty("simulated").GetBoolean(), "reçu simulé");
        var replay = await bridge.CallAsync("write.execute", Execute(planned, PosteDirectoryWrites.TypedName(c)));
        Check.Equal("error", replay.Kind, "jamais rejoué");
        Check.Equal(PosteErrors.Refused, (await bridge.CallAsync("poste.restart.plan", Args(new { dn = c.DistinguishedName, mode = "plus-tard" }))).Error!.Code, "mode inconnu refusé : jamais « maintenant » par défaut");
    }

    [Test]
    public static async Task Rename_changes_the_cn_only()
    {
        var bridge = new SimulatedBridge();
        var c = Workstations(bridge).First();
        var name = "POSTE-ACCUEIL-SALLE-DE-REUNION-12";
        var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.rename.plan", Args(new { dn = c.DistinguishedName, name })));
        var changes = planned.GetProperty("plan").GetProperty("changes").EnumerateArray().ToList();
        Check.Equal(1, changes.Count, "une seule modification");
        Check.Equal("cn", changes[0].GetProperty("attribute").GetString(), "le CN seulement (Rename-ADObject)");
        Check.True(planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "nom tapé");
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned, PosteDirectoryWrites.TypedName(c))));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "renommage relu");
        var after = bridge.Source.CurrentDirectory.Computers.Single(x => x.ObjectGuid == c.ObjectGuid);
        Check.Equal(name, after.Name, "nouveau nom de l’objet");
        Check.Equal(c.SamAccountName, after.SamAccountName, "sAMAccountName inchangé : le poste s’authentifie toujours");
        Check.Equal(c.DnsHostName, after.DnsHostName, "dNSHostName inchangé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.rename.plan", Args(new { dn = after.DistinguishedName, name = new string('A', 64) }))).Error!.Code, "64 caractères refusés (1 à 63)");
    }

    [Test]
    public static async Task Group_membership_and_profile_go_through_the_overlay()
    {
        var bridge = new SimulatedBridge();
        var c = Workstations(bridge).First();
        var groups = SimulatedBridge.Json(await bridge.CallAsync("poste.groups.search", Args(new { text = "" })));
        var candidate = groups.EnumerateArray().Select(g => g.GetProperty("dn").GetString()!)
            .First(g => !c.MemberOf.Contains(g, StringComparer.OrdinalIgnoreCase));
        var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.group.plan", Args(new { dn = c.DistinguishedName, group = candidate, add = true })));
        Check.Equal(0L, bridge.Source.Overlay.Version, "un plan n’écrit rien");
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned, Typed(planned, c))));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "appartenance relue");
        var console = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn = c.DistinguishedName })));
        Check.True(console.GetProperty("computer").GetProperty("groups").EnumerateArray().Any(g => string.Equals(g.GetProperty("dn").GetString(), candidate, StringComparison.OrdinalIgnoreCase)), "la console voit le groupe");

        var profile = SimulatedBridge.Json(await bridge.CallAsync("poste.profile.plan", Args(new { dn = c.DistinguishedName, location = "Bâtiment B, 2e étage" })));
        var changes = profile.GetProperty("plan").GetProperty("changes").EnumerateArray().ToList();
        Check.Equal(1, changes.Count, "seul l’attribut modifié est envoyé");
        Check.Equal("location", changes[0].GetProperty("attribute").GetString(), "emplacement");
    }

    [Test]
    public static async Task Service_wake_and_gpupdate_plans_go_through_the_circuit()
    {
        var bridge = new SimulatedBridge();
        var c = await ReadableAsync(bridge);
        var services = SimulatedBridge.Json(await bridge.CallAsync("poste.services", Args(new { dn = c.DistinguishedName })));
        var stopped = services.GetProperty("rows").EnumerateArray().FirstOrDefault(r => r.GetProperty("canStart").GetBoolean());
        if (stopped.ValueKind == JsonValueKind.Object)
        {
            var planned = SimulatedBridge.Json(await bridge.CallAsync("poste.service.plan", Args(new { dn = c.DistinguishedName, name = stopped.GetProperty("name").GetString(), action = "start" })));
            Check.Equal("poste.service", planned.GetProperty("plan").GetProperty("kind").GetString(), "plan d’un service");
            var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned, Typed(planned, c))));
            Check.Equal("verified", receipt.GetProperty("verification").GetString(), "état du service relu");
        }
        var gpupdate = SimulatedBridge.Json(await bridge.CallAsync("poste.gpupdate.plan", Args(new { dn = c.DistinguishedName })));
        Check.False(gpupdate.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "gpupdate : confirmation simple");
        var wake = await bridge.CallAsync("poste.wake.plan", Args(new { dn = c.DistinguishedName }));
        Check.True(wake.Kind == "result" || wake.Error?.Code is "write.nothingToDo" or "poste.refused", "réveil : plan, ou refus attendu pour un poste qui répond déjà");
    }

    [Test]
    public static async Task Session_account_is_found_by_its_login()
    {
        var bridge = new SimulatedBridge();
        var user = bridge.Source.CurrentDirectory.Users.First();
        var found = SimulatedBridge.Json(await bridge.CallAsync("poste.account.find", Args(new { login = "EXAMPLE\\" + user.SamAccountName })));
        Check.Equal(user.DistinguishedName, found.GetProperty("dn").GetString(), "domaine WTS retiré, compte trouvé par sAMAccountName");
        var none = SimulatedBridge.Json(await bridge.CallAsync("poste.account.find", Args(new { login = "compte-local-inexistant" })));
        Check.Equal(JsonValueKind.Null, none.ValueKind, "aucun compte : null");
    }

    [Test]
    public static async Task Open_option_is_a_local_preference()
    {
        var bridge = new SimulatedBridge();
        Check.False(SimulatedBridge.Json(await bridge.CallAsync("poste.host")).GetProperty("openReadsConsole").GetBoolean(), "désactivée par défaut");
        _ = await bridge.CallAsync("poste.option.set", Args(new { name = "openReadsConsole", value = true }));
        Check.True(SimulatedBridge.Json(await bridge.CallAsync("poste.host")).GetProperty("openReadsConsole").GetBoolean(), "mémorisée");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.option.set", Args(new { name = "autre", value = true }))).Error!.Code, "option inconnue refusée");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture dans l’annuaire");
    }

    [Test]
    public static async Task Stored_bios_reference_is_a_local_setting()
    {
        var bridge = new SimulatedBridge();
        var c = await ReadableAsync(bridge);
        _ = SimulatedBridge.Json(await bridge.CallAsync("poste.probes.collect", Args(new { dn = c.DistinguishedName })));
        var approved = await bridge.CallAsync("poste.bios.reference", Args(new { dn = c.DistinguishedName, action = "approve" }));
        Check.Equal("result", approved.Kind, "approbation enregistrée : " + (approved.Error?.Message ?? ""));
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture dans l’annuaire");
        var readings = SimulatedBridge.Json(await bridge.CallAsync("poste.readings", Args(new { dn = c.DistinguishedName })));
        Check.Contains("\"bios\"", readings.GetRawText(), "comparaison BIOS dans les relevés");
    }

    // ------------------------------------------------------------------ test doubles

    /// <summary>A receipt store whose disk refuses every version after the first: the write stays « à vérifier ».</summary>
    private sealed class FirstVersionOnlyStore : IReceiptStore
    {
        private readonly MemoryReceiptStore inner = new();

        public bool Persistent => true;

        public Task AppendAsync(WriteReceipt receipt, CancellationToken cancellationToken)
        {
            ArgumentNullException.ThrowIfNull(receipt);
            return receipt.Version > 1 ? throw new IOException("disque plein (test)") : inner.AppendAsync(receipt, cancellationToken);
        }

        public Task<ReceiptLog> ReadAllAsync(CancellationToken cancellationToken) => inner.ReadAllAsync(cancellationToken);
    }
}

/// <summary>
/// A host for the tests (secure window, launcher, exports), found like a screen reader when the test assembly is given to
/// the discovery: it keeps what it received so the tests can check that a value reached the window and never the page.
/// </summary>
public sealed class TestPosteHost : IPosteSecretWindow, IPosteToolLauncher, IPosteFileExport
{
    public TestPosteHost(SimulatedDirectorySource source) => ArgumentNullException.ThrowIfNull(source);

    public SecretReading? Secret { get; private set; }

    public bool Open { get; private set; }

    public Task<SecretShown> ShowAsync(SecretReading secret, Action<string> note, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(secret);
        Secret = secret;
        Open = true;
        return Task.FromResult(new SecretShown(secret.Kind, secret.Computer, secret.Identifier, secret.KeyGuid, "Fenêtre de test", secret.ReadAt.AddSeconds(secret.RevealSeconds),
            secret.RevealSeconds, secret.ExtensionSeconds, secret.Extensions, secret.ClipboardLimit, secret.Notice, secret.Simulated, secret.ReadAt));
    }

    public Task<bool> HideAsync(CancellationToken cancellationToken)
    {
        var was = Open;
        Open = false;
        return Task.FromResult(was);
    }

    public SecretWindowState State() => new(Open, false, Secret?.Kind, Secret?.Computer, Secret?.Identifier, null, Secret?.Extensions ?? 0, Open ? "Ouverte" : "Fermée");

    public Task<ToolLaunch> OpenToolAsync(ToolRequest request, CancellationToken cancellationToken) =>
        Task.FromResult(new ToolLaunch(false, request.Simulated, request.Tool, request.Tool, request.Tool + " " + request.Host, "Test : rien n’est lancé.", []));

    public Task<ToolLaunch> OpenSuiteAsync(SuiteRequest request, CancellationToken cancellationToken) =>
        Task.FromResult(new ToolLaunch(false, request.Simulated, request.Tool, request.Label, request.Label, "Test : rien n’est lancé.", []));

    public Task<PosteExportResult> SaveAsync(ExportRequest request, CancellationToken cancellationToken) =>
        Task.FromResult(new PosteExportResult(true, [.. request.Files.Select(f => request.SuggestedName + "-" + f.Part)], "Test : enregistré en mémoire."));
}

/// <summary>The simulated bridge of <see cref="SimulatedBridge"/>, with the test host discovered as a screen reader.</summary>
internal sealed class HostedBridge
{
    private readonly List<BridgeResponse> sent = [];
    private int counter;

    public HostedBridge()
    {
        var clock = TestClock.Fixed();
        Source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        Log = new RecordingJournal();
        ImmutableArray<System.Reflection.Assembly> assemblies = [typeof(SimulatedDirectorySource).Assembly, typeof(TestPosteHost).Assembly];
        Context = new EngineContext(SimulatedBridge.Decision, Source, new MemoryPreferenceStore(), clock, Log, ScreenReaders.Discover(Source, assemblies),
            writers: WriteExecutors.Discover(Source, assemblies), receipts: new MemoryReceiptStore());
        var registry = OperationModules.CreateRegistry(Context, OperationModules.Discover([typeof(DashboardOperations).Assembly]));
        Dispatcher = new BridgeDispatcher(registry, Publish, AdmissionGuards.ReadOnlySimulation);
        Host = Context.Readers.Find<IPosteSecretWindow>() as TestPosteHost ?? throw new TestFailureException("hôte de test non découvert");
    }

    public SimulatedDirectorySource Source { get; }

    public RecordingJournal Log { get; }

    public EngineContext Context { get; }

    public BridgeDispatcher Dispatcher { get; }

    public TestPosteHost Host { get; }

    public async Task<BridgeResponse> CallAsync(string operation, string arguments = "{}")
    {
        var id = "h" + Interlocked.Increment(ref counter).ToString(System.Globalization.CultureInfo.InvariantCulture);
        await Dispatcher.HandleAsync("{\"id\":\"" + id + "\",\"op\":\"" + operation + "\",\"args\":" + arguments + "}", CancellationToken.None).ConfigureAwait(false);
        lock (sent)
        {
            return sent.Last(r => r.Id == id);
        }
    }

    public static JsonElement Json(BridgeResponse response) => SimulatedBridge.Json(response);

    private void Publish(BridgeResponse response)
    {
        lock (sent)
        {
            sent.Add(response);
        }
    }
}
