using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemotePsExecPlanTests
{
    private static RemoteTaskReadPlan Plan(string store = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        RemoteTaskReadKind kind = RemoteTaskReadKind.UserIdentity) => RemotePsExecPlan.Create(Fixtures.Computer("PC1"), store, @"TEST\operator", Fixtures.Now,
            kind, kind == RemoteTaskReadKind.Software ? new(true, true, false) : null);

    [Test]
    public static void PsExec_plan_has_a_durable_transport_and_package_hash_without_changing_old_task_json()
    {
        var task = RemoteTaskReadRunner.PreparePlan(Fixtures.Computer("PC1"), new('a', 64), @"TEST\operator", Fixtures.Now);
        var json = JsonSerializer.Serialize(task);
        Check.False(json.Contains("Transport", StringComparison.Ordinal) || json.Contains("PsExecSha256", StringComparison.Ordinal), "anciens octets inchangés par les propriétés par défaut");
        var restored = JsonSerializer.Deserialize<RemoteTaskReadPlan>(json)!; Check.Equal(RemoteReadTransport.ScheduledTask, restored.Transport, "défaut historique"); Check.Null(restored.PsExecSha256, "aucun outil inventé");
        var px = Plan(); var cold = JsonSerializer.Deserialize<RemoteTaskReadPlan>(JsonSerializer.Serialize(px))!;
        Check.Equal(px, cold, "transport et SHA traversent le redémarrage"); Check.Equal(RemoteReadTransport.PsExec, cold.Transport, "transport explicite");
        Check.Equal(RemotePsExecBinary.ApprovedSha256, cold.PsExecSha256, "binaire approuvé exact");
        Check.Equal(RemoteTaskReadProgram.Hash(RemoteTaskReadProgram.Script(cold)), cold.ScriptSha256, "programme fixé indépendamment du lanceur");
    }

    [Test]
    public static void PsExec_arguments_are_closed_single_target_no_credentials_and_no_detach()
    {
        foreach (var kind in Enum.GetValues<RemoteTaskReadKind>())
        {
            var plan = Plan(kind: kind); var arguments = RemotePsExecPlan.Arguments(plan, @"D:\Windows");
            Check.Equal(@"\\pc1.test.local", arguments[0], "cible FQDN unique");
            Check.True(arguments.Contains("-s") && arguments.Contains("-r") && arguments.Contains(RemotePsExecPlan.ServiceName(plan)), "SYSTEM et service propre au plan");
            foreach (var denied in new[] { "-u", "-p", "-d", "-c", "-f", "-Command" }) { Check.False(arguments.Contains(denied), "option interdite : " + denied); }
            Check.Equal(@"D:\Windows\Temp\" + plan.DirectoryName + @"\read.ps1", arguments[^1], "seul le programme fixe du dossier propriétaire peut être demandé");
            Check.True(arguments.Sum(a => a.Length + 3) < 30_000, "taille de commande bornée pour chaque type");
            var bytes = RemotePsExecPlan.ProgramBytes(plan);
            Check.True(bytes.AsSpan(0, 3).SequenceEqual(new byte[] { 0xef, 0xbb, 0xbf }), "UTF-8 explicite pour PowerShell Windows");
            Check.Equal(plan.ScriptSha256, Convert.ToHexStringLower(SHA256.HashData(bytes.AsSpan(3))), "source écrite exacte après le BOM imposé");
            Check.Equal(RemoteTaskReadProgram.Script(plan), new UTF8Encoding(false, true).GetString(bytes.AsSpan(3)), "aucune normalisation du programme");
        }
        Check.Throws<InvalidDataException>(() => RemotePsExecPlan.Arguments(Plan(), @"C:\Windows\..\Other"), "pas de chemin réinterprété");
        Check.Throws<InvalidDataException>(() => RemotePsExecPlan.Arguments(Plan() with { Host = "pc1.test.local,pc2" }, @"C:\Windows"), "pas de cibles multiples");
    }

    [Test]
    public static void PsExec_rejects_explicit_credentials_changed_hash_or_transport_before_any_factory_or_journal()
    {
        using var secret = new SecureString(); secret.AppendChar('x'); secret.MakeReadOnly();
        using var credential = new RemoteProbeCredential(@"TEST\operator", secret.Copy(), false);
        var plan = Plan();
        Check.Throws<DomeniaOperationException>(() => RemotePsExecPlan.Validate(plan, credential), "aucun mot de passe en argument");
        Check.Throws<InvalidDataException>(() => RemotePsExecPlan.Validate(plan with { PsExecSha256 = new('b', 64) }, null), "autre paquet non approuvé");
        Check.Throws<InvalidDataException>(() => RemotePsExecPlan.Validate(plan with { ScriptSha256 = new('b', 64) }, null), "autre programme refusé");
        Check.Throws<InvalidDataException>(() => RemoteTaskReadRules.Validate(plan with { Transport = RemoteReadTransport.ScheduledTask }, Fixtures.Now), "plan tâche portant un SHA PsExec incohérent");
        Check.Throws<InvalidDataException>(() => RemoteTaskReadRules.Validate(plan with { PsExecSha256 = null }, Fixtures.Now), "plan PsExec sans SHA refusé");
    }

    [Test]
    public static void PsExec_service_ownership_requires_exact_unique_path_System_and_demand_start()
    {
        var plan = Plan(); var path = @"C:\Windows\" + RemotePsExecPlan.ServiceFile(plan);
        Check.True(RemotePsExecService.Matches(plan, @"C:\Windows", path, "LocalSystem", 0x10, 3), "service propriétaire attendu");
        Check.True(RemotePsExecService.Matches(plan, @"C:\Windows", "\"" + path + "\"", @"NT AUTHORITY\SYSTEM", 0x10, 3), "guillemets autour du même chemin");
        Check.False(RemotePsExecService.Matches(plan, @"C:\Windows", @"C:\Windows\PSEXESVC.exe", "LocalSystem", 0x10, 3), "service générique non attribué");
        Check.False(RemotePsExecService.Matches(plan, @"C:\Windows", path + " --anything", "LocalSystem", 0x10, 3), "commande modifiée");
        Check.False(RemotePsExecService.Matches(plan, @"C:\Windows", path, @"TEST\operator", 0x10, 3), "principal modifié");
        Check.False(RemotePsExecService.Matches(plan, @"C:\Windows", path, "LocalSystem", 0x10, 2), "pas de service permanent");
    }

    [Test]
    public static async Task PsExec_runner_claims_durably_and_labels_every_result_source_with_its_actual_transport()
    {
        foreach (var kind in Enum.GetValues<RemoteTaskReadKind>())
        {
            using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var plan = Plan(db.StoreId, kind);
            var backend = new RemoteTaskReadTests.Backend(plan) { OnRead = () => kind == RemoteTaskReadKind.UserIdentity ? RemoteTaskReadTests.Json(plan)
                : kind == RemoteTaskReadKind.Software ? RemoteTaskReadExtendedTests.SoftwareJson(plan) : RemoteTaskReadExtendedTests.InventoryJson(plan) };
            backend.OnStart = () => Check.Equal(2L, db.ReadTaskReadAsync(plan.Id, CancellationToken.None).GetAwaiter().GetResult()!.Revision, "preuve durable avant artefacts");
            var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (seen, credential) => { Check.Equal(RemoteReadTransport.PsExec, seen.Transport, "factory reçoit le transport durable"); Check.Null(credential, "contexte intégré"); return backend; } };
            var result = await runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
            Check.True(result.CleanupConfirmed, "reçu de nettoyage confirmé par le backend de test"); Check.Equal(1, backend.Starts, "un lancement");
            Check.Equal(InventoryTransport.PsExec, result.Reading.Access.Transport, "transport de la réponse");
            if (result.Inventory is { } inventory) { Check.True(inventory.Access.All(a => a.Transport == InventoryTransport.PsExec), "transport de chaque source d’inventaire"); }
            if (result.Software is { } software) { Check.True(software.Access.All(a => a.Detail.StartsWith("PsExec SYSTEM", StringComparison.Ordinal)), "provenance logiciels exacte"); }
            var cold = new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed());
            Check.Equal(plan, (await cold.ReadTaskReadAsync(plan.Id, CancellationToken.None))!.Plan, "reprise conserve transport et paquet");
        }
    }

    [Test]
    public static async Task Ambiguous_PsExec_start_keeps_proofs_and_never_replays_or_falls_back_to_a_task()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var plan = Plan(db.StoreId);
        var backend = new RemoteTaskReadTests.Backend(plan) { OnStart = () => throw new IOException("Réponse perdue après lancement."), CleanupResult = new(false, false, "Arrêt inconnu.") };
        var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend };
        var result = await runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.False(result.CleanupConfirmed, "issue inconnue conservée"); Check.Equal(1, backend.Starts, "un seul envoi");
        Check.Equal(InventoryTransport.PsExec, result.Reading.Access.Transport, "échec non renommé tâche");
        var cold = new SqliteDirectoryCache(new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed()));
        Check.True((await cold.PendingTaskReadsAsync(CancellationToken.None)).Single().CleanupRequired, "preuve après redémarrage");
        var replay = await runner.RunAsync(plan, cold, null, _ => throw new InvalidOperationException("Aucun accord à reconsommer."), CancellationToken.None);
        Check.Equal(SourceStatus.Error, replay.Reading.Access.Status, "refus de rejeu rendu sans exception hors contrat");
        Check.Contains("déjà été engagée", replay.Reading.Access.Detail, "cause conservée");
        Check.False(replay.CleanupConfirmed, "le rejeu n’invente pas un nettoyage confirmé");
        Check.Equal(1, backend.Starts, "aucun rejeu après reprise");
        var recovery = await runner.RecoverCleanupAsync(plan, cold, null, _ => Task.FromResult(true), CancellationToken.None);
        Check.False(recovery.ExecutionStopped, "service absent ne serait pas une preuve d’arrêt"); Check.Equal(1, backend.RecoveryConnections, "parcours de reprise atteint"); Check.Equal(1, backend.Starts, "la reprise nettoie sans exécuter");
    }

    [Test]
    public static async Task PsExec_result_with_foreign_nonce_is_not_accepted_even_if_backend_reports_clean_exit()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var plan = Plan(db.StoreId);
        var backend = new RemoteTaskReadTests.Backend(plan) { OnRead = () => RemoteTaskReadTests.Json(plan with { Nonce = new('0', 64) }) };
        var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }
            .RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.Equal(1, backend.Starts, "retour réellement reçu après lancement"); Check.Equal(0, result.Reading.Candidates.Length, "aucun résultat étranger");
        Check.False((await db.ReadTaskReadAsync(plan.Id, CancellationToken.None))!.Completion!.ResultReceived, "exitcode simulé ne suffit pas");
    }

    [Test]
    public static async Task PsExec_explicit_credential_refusal_precedes_durable_claim_and_backend_creation()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder); var plan = Plan(db.StoreId); var factories = 0;
        using var secret = new SecureString(); secret.AppendChar('x'); secret.MakeReadOnly(); using var credential = new RemoteProbeCredential(@"TEST\operator", secret.Copy(), false);
        var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => { factories++; return new RemoteTaskReadTests.Backend(plan); } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => runner.RunAsync(plan, new SqliteDirectoryCache(db), credential, _ => Task.FromResult(true), CancellationToken.None), "session intégrée obligatoire");
        Check.Equal(0, factories, "aucune factory native"); Check.Null(await db.ReadTaskReadAsync(plan.Id, CancellationToken.None), "aucune revendication artificielle");
    }
}
