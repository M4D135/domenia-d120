using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemoteTaskReadExtendedTests
{
    internal static string InventoryJson(RemoteTaskReadPlan plan)
    {
        var sources = RemoteTaskReadInventory.Queries(plan.Kind).Select(q =>
        {
            var row = q.Properties.ToDictionary(p => p, _ => (object?)null);
            object[] values = [];
            if (q.Class == "Win32_ComputerSystem")
            { row["Name"] = "PC1"; row["Domain"] = "test.local"; row["DomainRole"] = "1"; values = [row]; }
            if (q.Class == "Win32_OperatingSystem")
            { row["Caption"] = "Windows"; row["Version"] = "10.0"; row["SystemDrive"] = "D:"; values = [row]; }
            if (q.Class == "Win32_LogicalDisk")
            { row["DeviceID"] = "D:"; row["Size"] = "1000"; row["FreeSpace"] = "750"; values = [row]; }
            return new { q.Class, Code = 0, Truncated = false, Rows = values };
        }).ToArray();
        return Envelope(plan, new { Format = "Domenia.TaskInventory/1", Computer = "PC1", Sources = sources,
            Reboot = new { Code = 0, Values = new { Cbs = false, Update = false, Rename = false } } });
    }
    internal static string SoftwareJson(RemoteTaskReadPlan plan) => Envelope(plan, new
    {
        Format = "Domenia.TaskSoftware/1", Computer = "PC1", Rows = Array.Empty<object>(),
        Scopes = new[] { "Machine", "Utilisateur", "Store" }.Select(scope => new { Scope = scope, Code = 0, Truncated = false,
            Skipped = scope == "Utilisateur" && !plan.Software!.PerUser || scope == "Store" && !plan.Software!.Store, Items = 0 }),
    });
    private static string Envelope(RemoteTaskReadPlan plan, object payload) => JsonSerializer.Serialize(new
    { Format = "Domenia.RemoteRead/1", Id = plan.Id.ToString("N"), plan.Nonce, Payload = payload });
    private static RemoteTaskReadPlan Plan(DomeniaDatabase db, RemoteTaskReadKind kind, SoftwareRequest? software = null) =>
        RemoteTaskReadRunner.PreparePlan(Fixtures.Computer("PC1"), db.StoreId, @"TEST\operator", Fixtures.Now, kind, software);

    [Test]
    public static async Task Closed_task_programs_seal_the_kind_and_options_and_fit_the_Windows_command_limit()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder);
        foreach (var kind in Enum.GetValues<RemoteTaskReadKind>())
        {
            var plan = Plan(db, kind, kind == RemoteTaskReadKind.Software ? new(true, true, false) : null);
            Check.True(RemoteTaskReadProgram.Arguments(plan).Length < 30_000, "commande sous la limite Windows");
            Check.True(RemoteTaskReadProgram.OwnsTask(RemoteTaskReadProgram.Xml(plan), plan), "programme propriétaire exact");
            Check.Equal(RemoteTaskReadProgram.Hash(RemoteTaskReadProgram.Script(plan)), plan.ScriptSha256, "programme scellé");
            Check.False(RemoteTaskReadProgram.Script(plan).Contains("Win32_Product", StringComparison.Ordinal), "aucun fournisseur MSI");
        }
        var software = Plan(db, RemoteTaskReadKind.Software, new(false, false, false));
        Check.Throws<InvalidDataException>(() => RemoteTaskReadProgram.Xml(software with { Software = new(false, false, true) }), "options changées invalident le programme");
        Check.Throws<InvalidDataException>(() => RemoteTaskReadRules.Validate(software with { Kind = RemoteTaskReadKind.UserIdentity }, Fixtures.Now), "options incompatibles refusées");
    }

    [Test]
    public static async Task Task_inventory_uses_native_projection_and_keeps_uncovered_sources_unknown()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder);
        foreach (var kind in new[] { RemoteTaskReadKind.InventoryQuick, RemoteTaskReadKind.InventoryFull, RemoteTaskReadKind.Diagnostic })
        {
            var plan = Plan(db, kind); var parsed = RemoteTaskReadProgram.ParseResult(InventoryJson(plan), plan, Fixtures.Now);
            var value = parsed.Inventory!;
            Check.Equal("PC1", value.ReportedName, "identité relue"); Check.Equal("Windows", value.Os!.Caption, "projection commune");
            Check.Equal("D:", value.Volumes.Single().Id, "aucune lettre système supposée"); Check.True(value.PendingReboot!.Complete == true, "trois sources effectivement reçues");
            Check.True(value.Access.All(a => a.Transport == InventoryTransport.ScheduledTask), "transport conservé");
            if (kind != RemoteTaskReadKind.Diagnostic) { Check.Equal(SourceStatus.Unavailable, value.StatusOf(InventoryCategories.Admins), "absence de couverture explicitement inconnue"); }
        }
    }

    [Test]
    public static async Task Task_inventory_preserves_Domenia1_BIOS_serial_without_inventing_a_refused_value()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder);
        var plan = Plan(db, RemoteTaskReadKind.InventoryFull);
        var root = JsonNode.Parse(InventoryJson(plan))!.AsObject();
        var bios = root["Payload"]!["Sources"]!.AsArray().Single(n => (string?)n!["Class"] == "Win32_BIOS")!;
        var row = new JsonObject();
        foreach (var field in RemoteTaskReadInventory.Queries(plan.Kind).Single(q => q.Class == "Win32_BIOS").Properties) { row[field] = null; }
        row["SerialNumber"] = "BIOS-SERIAL-01"; bios["Rows"] = new JsonArray(row);
        Check.Equal("BIOS-SERIAL-01", RemoteTaskReadProgram.ParseResult(root.ToJsonString(), plan, Fixtures.Now).Inventory!.System!.SerialNumber, "numéro BIOS quand le châssis ne répond pas");
        bios["Code"] = unchecked((int)0x80070005);
        Check.Null(RemoteTaskReadProgram.ParseResult(root.ToJsonString(), plan, Fixtures.Now).Inventory!.System!.SerialNumber, "source refusée ne qualifie pas le numéro");
        bios["Code"] = 0; bios["Truncated"] = true;
        Check.Null(RemoteTaskReadProgram.ParseResult(root.ToJsonString(), plan, Fixtures.Now).Inventory!.System!.SerialNumber, "source tronquée ne qualifie pas le numéro");
    }

    [Test]
    public static async Task Task_payload_rejects_wrong_kind_identity_DC_duplicate_missing_and_unbounded_fields()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var plan = Plan(db, RemoteTaskReadKind.Diagnostic);
        var good = InventoryJson(plan);
        foreach (var change in new Action<JsonObject>[]
        {
            n => n["Payload"]!["Computer"] = "OTHER",
            n => n["Payload"]!["Sources"]![0]!["Rows"]![0]!["DomainRole"] = "4",
            n => n["Payload"]!["Sources"]![0]!["Rows"]![0]!["DomainRole"] = null,
            n => n["Payload"]!["Sources"]!.AsArray().Add(n["Payload"]!["Sources"]![0]!.DeepClone()),
            n => n["Payload"]!["Sources"]![0]!.AsObject().Remove("Code"),
            n => n["Payload"]!["Sources"]![0]!["Code"] = "0",
            n => n["Payload"]!["Sources"]![0]!["Rows"]![0]!["Name"] = new string('X', 4097),
            n => n["Payload"]!["Reboot"]!["Values"]!["Rename"] = "false",
        })
        { var node = JsonNode.Parse(good)!.AsObject(); change(node); Check.Throws<JsonException>(() => RemoteTaskReadProgram.ParseResult(node.ToJsonString(), plan, Fixtures.Now), "réponse contradictoire rejetée"); }
        Check.Throws<JsonException>(() => RemoteTaskReadProgram.ParseResult(good, plan with { Kind = RemoteTaskReadKind.Software, Software = new(false, false, false) }, Fixtures.Now), "autre programme rejeté");
    }

    [Test]
    public static async Task Task_software_requires_exact_requested_scopes_and_marks_refused_empty_distinctly()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var plan = Plan(db, RemoteTaskReadKind.Software, new(true, false, false));
        var node = JsonNode.Parse(SoftwareJson(plan))!.AsObject();
        node["Payload"]!["Scopes"]![0]!["Code"] = unchecked((int)0x80070005);
        var result = RemoteTaskReadProgram.ParseResult(node.ToJsonString(), plan, Fixtures.Now).Software!;
        Check.Equal(SourceStatus.Refused, result.Access.Single(a => a.Scope == "Machine").Status, "refus jamais transformé en zéro logiciel");
        Check.Equal(SourceStatus.Empty, result.Access.Single(a => a.Scope == "Utilisateur").Status, "ruches lues vides");
        Check.Equal(SourceStatus.Skipped, result.Access.Single(a => a.Scope == "Store").Status, "portée non demandée");
        node["Payload"]!["Scopes"]![2]!["Skipped"] = false;
        Check.Throws<JsonException>(() => RemoteTaskReadProgram.ParseResult(node.ToJsonString(), plan, Fixtures.Now), "portée ajoutée refusée");
    }

    [Test]
    public static async Task Extended_task_reads_share_the_durable_claim_and_keep_cleanup_independent()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var plan = Plan(db, RemoteTaskReadKind.Software, new(false, false, false));
        var backend = new RemoteTaskReadTests.Backend(plan) { OnRead = () => SoftwareJson(plan), CleanupResult = new(true, false, "Fichier restant.") }; var grants = 0;
        var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend };
        var result = await runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => { grants++; return Task.FromResult(true); }, CancellationToken.None);
        Check.True(result.Software!.Complete, "qualité de la lecture distincte du nettoyage"); Check.False(result.CleanupConfirmed, "artefact restant visible");
        Check.True((await db.ReadTaskReadAsync(plan.Id, CancellationToken.None))!.Completion!.ResultReceived, "résultat reçu durable");
        await runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => { grants++; return Task.FromResult(true); }, CancellationToken.None);
        Check.Equal(1, grants, "consentement consommé une fois"); Check.Equal(1, backend.Starts, "aucun nouvel envoi sur reprise");
    }

    [Test]
    public static async Task Closing_barrier_rejects_new_remote_workers_without_record_or_consent_then_reopens()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await RemoteTaskReadTests.Open(folder); var backend = new RemoteTaskReadTests.Backend(plan);
        var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend };
        using (RemoteTaskReadRunner.SuspendNewReads())
        {
            using (RemoteTaskReadRunner.SuspendNewReads()) { Check.Equal(0, RemoteTaskReadRunner.ActiveReads, "aucun worker admis"); }
            await Check.ThrowsAsync<DomeniaOperationException>(() => runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => throw new InvalidOperationException("Pas de consentement consommé."), CancellationToken.None), "fermeture bloque l’admission");
            Check.Null(await db.ReadTaskReadAsync(plan.Id, CancellationToken.None), "aucune préparation pendant la fermeture");
        }
        var result = await runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.True(result.CleanupConfirmed, "reprise après annulation de fermeture"); Check.Equal(0, RemoteTaskReadRunner.ActiveReads, "compteur libéré après nettoyage réel");
    }

    [Test]
    public static async Task Native_software_fallback_requires_one_consent_and_final_AD_identity()
    {
        foreach (var changed in new[] { false, true })
        {
            using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var pc = Fixtures.Computer("PC1"); var cache = new SqliteDirectoryCache(db);
            var started = false; var calls = 0;
            using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [AdPosteNetworkTests.Entry(started && changed ? pc with { ObjectGuid = Guid.NewGuid() } : pc)] };
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
            var reader = new AdPosteReader(source)
            {
                InventoryReaderOverride = _ => new(TestClock.Fixed()) { SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
                { ReadOverride = (_, _, _) => throw new COMException("Indisponible", unchecked((int)0x800706BA)), RegistryOverride = (_, _) => new(5, null) } },
                TaskReadRunnerFactory = () => new(TestClock.Fixed()) { BackendOverride = (plan, credential) =>
                {
                    calls++; Check.Equal(@"TEST\operator", credential!.Account, "compte sélectionné conservé");
                    return new RemoteTaskReadTests.Backend(plan) { OnRead = () => SoftwareJson(plan), OnStart = () => started = true };
                } },
            };
            var first = await reader.SoftwareAsync(pc.DistinguishedName, new(false, false, false), CancellationToken.None);
            Check.Equal("readFallback", first.NoticeAction, "accord proposé sans artefact"); Check.Equal(0, calls, "aucun worker sans accord");
            PosteSession.For(source).Grant(ConsentKind.ReadFallback, pc.DistinguishedName, pc.Name, 5, Fixtures.Now, pc.ObjectGuid);
            if (changed) { await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SoftwareAsync(pc.DistinguishedName, new(false, false, false), CancellationToken.None), "identité AD après tâche requise"); }
            else { var read = await reader.SoftwareAsync(pc.DistinguishedName, new(false, false, false), CancellationToken.None); Check.True(read.Complete, "portée demandée reçue sous SYSTEM"); }
            Check.Equal(1, calls, "un seul worker"); Check.False(PosteSession.For(source).Covers(ConsentKind.ReadFallback, pc.DistinguishedName, Fixtures.Now, pc.ObjectGuid), "accord consommé");
            Check.Equal(0, await reader.PendingTaskReadCountAsync(CancellationToken.None), "nettoyage localement relu indépendamment de la validation AD");
        }
    }
}
