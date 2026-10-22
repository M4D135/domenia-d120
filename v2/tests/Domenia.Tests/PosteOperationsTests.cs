using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

/// <summary>
/// Operations of the workstation console through the simulated bridge (docs/ops/poste.md): local reads, network reads
/// served by the simulation, progress events, secrets, authorizations and the writes of the screen through the circuit.
/// </summary>
internal static class PosteOperationsTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static IEnumerable<DirectoryComputer> Workstations(SimulatedBridge bridge) =>
        bridge.Source.CurrentDirectory.Computers.Where(c => c.Name.StartsWith("PC-", StringComparison.Ordinal) || c.Name.StartsWith("PT-", StringComparison.Ordinal)).OrderBy(c => c.Name, StringComparer.Ordinal);

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

    private static string Execute(JsonElement planned, string? typedName = null) => Args(new
    {
        planId = planned.GetProperty("plan").GetProperty("id").GetString(),
        token = planned.GetProperty("token").GetString(),
        typedName,
    });

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
    }

    [Test]
    public static async Task Quick_inventory_publishes_its_progress_and_becomes_the_last_one()
    {
        var bridge = new SimulatedBridge();
        var c = await ReachableAsync(bridge);
        var result = SimulatedBridge.Json(await bridge.CallAsync("poste.inventory", Args(new { dn = c.DistinguishedName, deep = false })));
        Check.True(result.GetProperty("rows").GetArrayLength() > 20, "lignes d’inventaire");
        Check.True(result.GetProperty("access").EnumerateArray().Any(), "état par source");
        Check.True(bridge.Events.Any(e => e.Operation == "poste.inventory:progress"), "progression publiée");
        var console = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn = c.DistinguishedName })));
        Check.True(console.GetProperty("inventory").ValueKind == JsonValueKind.Object, "inventaire mémorisé pour la console");
        Check.False(console.GetProperty("inventory").GetProperty("deep").GetBoolean(), "inventaire rapide");

        var again = new SimulatedBridge();
        _ = await again.CallAsync("poste.ping", Args(new { dn = c.DistinguishedName }));
        var second = SimulatedBridge.Json(await again.CallAsync("poste.inventory", Args(new { dn = c.DistinguishedName, deep = false })));
        Check.Equal(result.GetProperty("rows").GetRawText(), second.GetProperty("rows").GetRawText(), "données du poste déterministes");
    }

    [Test]
    public static async Task Network_reads_of_the_screen_are_served_in_simulation()
    {
        var bridge = new SimulatedBridge();
        var c = await ReachableAsync(bridge);
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
        Check.Equal(DomeniaErrors.SourceUnavailable, (await bridge.CallAsync("poste.tool.open", Args(new { dn, tool = "rdp" }))).Error!.Code, "aucun outil Windows ouvert en simulation");
    }

    [Test]
    public static async Task Secrets_are_revealed_once_and_never_journalled()
    {
        var bridge = new SimulatedBridge();
        var c = Workstations(bridge).First(x => x.Laps == LapsKind.Windows && x.LapsExpiration is not null);
        var view = SimulatedBridge.Json(await bridge.CallAsync("poste.laps", Args(new { dn = c.DistinguishedName })));
        Check.True(view.GetProperty("canReveal").GetBoolean(), "mot de passe lisible");
        Check.False(view.GetRawText().Contains("\"value\"", StringComparison.Ordinal), "les métadonnées ne portent aucune valeur");
        var reveal = SimulatedBridge.Json(await bridge.CallAsync("poste.laps.reveal", Args(new { dn = c.DistinguishedName })));
        var password = reveal.GetProperty("value").GetString()!;
        Check.Equal(20, password.Length, "mot de passe fictif");
        Check.Equal(30, reveal.GetProperty("revealSeconds").GetInt32(), "affiché 30 s");
        Check.Equal(1, reveal.GetProperty("extensions").GetInt32(), "une prolongation");
        Check.True(reveal.GetProperty("simulated").GetBoolean(), "valeur fictive signalée");
        Check.False(bridge.Context.Journal.Snapshot().Any(e => e.Label.Contains(password, StringComparison.Ordinal)), "jamais dans le journal des opérations");
        Check.False(bridge.Log.Lines.Any(l => l.Contains(password, StringComparison.Ordinal)), "jamais dans le journal technique");

        foreach (var computer in Workstations(bridge))
        {
            var list = SimulatedBridge.Json(await bridge.CallAsync("poste.bitlocker.list", Args(new { dn = computer.DistinguishedName })));
            var keys = list.GetProperty("keys").EnumerateArray().ToList();
            if (keys.Count == 0)
            {
                continue;
            }
            var key = SimulatedBridge.Json(await bridge.CallAsync("poste.bitlocker.reveal", Args(new { dn = computer.DistinguishedName, key = keys[0].GetProperty("dn").GetString() })));
            Check.Equal(8, key.GetProperty("blocks").GetArrayLength(), "clé en huit blocs");
            Check.Equal(JsonValueKind.Null, key.GetProperty("value").ValueKind, "la clé ne voyage qu’en blocs");
            var other = Workstations(bridge).First(x => x.DistinguishedName != computer.DistinguishedName);
            Check.Equal(PosteErrors.KeyNotChild, (await bridge.CallAsync("poste.bitlocker.reveal", Args(new { dn = other.DistinguishedName, key = keys[0].GetProperty("dn").GetString() }))).Error!.Code, "clé d’un autre poste refusée");
            return;
        }
        throw new TestFailureException("aucune clé BitLocker dans la simulation");
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
        var typed = planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean() ? PosteDirectoryWrites.TypedName(c) : null;
        var receipt = SimulatedBridge.Json(await bridge.CallAsync("write.execute", Execute(planned, typed)));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "appartenance relue");
        var console = SimulatedBridge.Json(await bridge.CallAsync("poste.open", Args(new { dn = c.DistinguishedName })));
        Check.True(console.GetProperty("computer").GetProperty("groups").EnumerateArray().Any(g => string.Equals(g.GetProperty("dn").GetString(), candidate, StringComparison.OrdinalIgnoreCase)), "la console voit le groupe");

        var profile = SimulatedBridge.Json(await bridge.CallAsync("poste.profile.plan", Args(new { dn = c.DistinguishedName, location = "Bâtiment B, 2e étage" })));
        var changes = profile.GetProperty("plan").GetProperty("changes").EnumerateArray().ToList();
        Check.Equal(1, changes.Count, "seul l’attribut modifié est envoyé");
        Check.Equal("location", changes[0].GetProperty("attribute").GetString(), "emplacement");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, (await bridge.CallAsync("poste.rename.plan", Args(new { dn = c.DistinguishedName, name = "UN-NOM-BEAUCOUP-TROP-LONG" }))).Error!.Code, "nom NetBIOS de 15 caractères au plus");
    }

    [Test]
    public static async Task Stored_bios_reference_is_a_local_setting()
    {
        var bridge = new SimulatedBridge();
        var c = await ReachableAsync(bridge);
        _ = SimulatedBridge.Json(await bridge.CallAsync("poste.probes.collect", Args(new { dn = c.DistinguishedName })));
        var approved = await bridge.CallAsync("poste.bios.reference", Args(new { dn = c.DistinguishedName, action = "approve" }));
        Check.Equal("result", approved.Kind, "approbation enregistrée : " + (approved.Error?.Message ?? ""));
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture dans l’annuaire");
        var readings = SimulatedBridge.Json(await bridge.CallAsync("poste.readings", Args(new { dn = c.DistinguishedName })));
        Check.Contains("\"bios\"", readings.GetRawText(), "comparaison BIOS dans les relevés");
    }
}
