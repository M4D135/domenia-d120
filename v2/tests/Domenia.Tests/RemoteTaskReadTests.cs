using System.Runtime.InteropServices;
using System.Text.Json;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemoteTaskReadTests
{
    internal static async Task<(DomeniaDatabase Db, RemoteTaskReadPlan Plan)> Open(TemporaryFolder folder)
    {
        var db = new DomeniaDatabase(folder.File("task.db"), Fixtures.Root, TestClock.Fixed());
        await new SqliteDirectoryCache(db).SaveObjectsAsync(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]), null, CancellationToken.None);
        return (db, RemoteTaskReadRunner.PreparePlan(Fixtures.Computer("PC1"), db.StoreId, @"TEST\operator", Fixtures.Now));
    }
    internal static string Json(RemoteTaskReadPlan plan) => JsonSerializer.Serialize(new
    {
        Format = "Domenia.RemoteRead/1", Id = plan.Id.ToString("N"), plan.Nonce,
        Payload = new { Format = "Domenia.UserIdentityRead/1", Computer = "PC1", Code = 0, Truncated = false,
            Rows = new[] { new { Kind = "Console", Account = @"TEST\alice", Sid = (string?)null } } },
    });
    internal sealed class Backend(RemoteTaskReadPlan plan) : IRemoteTaskReadBackend
    {
        internal int Preflights, Starts, Cleanups, RecoveryConnections;
        internal bool Disposed;
        internal Action? OnPreflight, OnStart;
        internal Func<string?>? OnRead;
        internal RemoteTaskReadCleanup CleanupResult = new(true, true, "Nettoyé.");
        public void Preflight(CancellationToken token) { token.ThrowIfCancellationRequested(); Preflights++; OnPreflight?.Invoke(); }
        public void PrepareCleanup(RemoteTaskReadCompletion? previous, CancellationToken token) { token.ThrowIfCancellationRequested(); RecoveryConnections++; }
        public void Start(CancellationToken token) { token.ThrowIfCancellationRequested(); Starts++; OnStart?.Invoke(); }
        public string? ReadResult() => OnRead is null ? Json(plan) : OnRead();
        public bool Finished => true;
        public RemoteTaskReadCleanup Cleanup(Action? recordStopped = null) { Cleanups++; if (CleanupResult.Stopped) { recordStopped?.Invoke(); } return CleanupResult; }
        public void Dispose() => Disposed = true;
    }

    [Test]
    public static async Task Task_read_claim_precedes_artifacts_and_same_plan_never_runs_twice()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await Open(folder); var backend = new Backend(plan); var grants = 0;
        var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend };
        backend.OnStart = () =>
        {
            var prepared = db.ReadTaskReadAsync(plan.Id, CancellationToken.None).GetAwaiter().GetResult()!;
            Check.Equal(2L, prepared.Revision, "plan et revendication durables avant le réseau qui écrit");
            Check.True(prepared.Completion!.ExecutionId != Guid.Empty, "revendication unique");
            Check.Equal(1, grants, "autorisation consommée après précontrôle");
        };
        var result = await runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => { grants++; return Task.FromResult(true); }, CancellationToken.None);
        Check.True(result.CleanupConfirmed, "nettoyage et reçu confirmés"); Check.Equal(InventoryTransport.ScheduledTask, result.Reading.Access.Transport, "transport réel");
        Check.True(result.Reading.Candidates.Single().CurrentConsole, "nature de la preuve conservée"); Check.Equal(1, backend.Cleanups, "nettoyage une fois"); Check.True(backend.Disposed, "ressources libérées");
        var retry = await runner.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => throw new InvalidOperationException("Pas de nouvel accord consommé."), CancellationToken.None);
        Check.Equal(SourceStatus.Error, retry.Reading.Access.Status, "ancien plan refusé"); Check.Equal(1, backend.Starts, "aucun deuxième lancement");
    }

    [Test]
    public static async Task Task_preflight_failure_keeps_consent_and_lost_start_reply_is_not_retried()
    {
        foreach (var preflight in new[] { true, false })
        {
            using var folder = new TemporaryFolder(); var (db, plan) = await Open(folder); var backend = new Backend(plan); var grants = 0;
            void Reject() => throw new COMException("Réponse perdue.", unchecked((int)0x800706BA));
            if (preflight) { backend.OnPreflight = Reject; } else { backend.OnStart = Reject; backend.CleanupResult = new(false, false, "Issue inconnue."); }
            var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }.RunAsync(plan, new SqliteDirectoryCache(db), null,
                _ => { grants++; return Task.FromResult(true); }, CancellationToken.None);
            Check.Equal(preflight ? 0 : 1, grants, "accord seulement après le précontrôle"); Check.Equal(preflight ? 0 : 1, backend.Starts, "jamais de second envoi");
            Check.Equal(preflight, result.CleanupConfirmed, "absence d’artefact distinguée d’une issue perdue");
            Check.Equal(preflight ? 0 : 1, (await db.PendingTaskReadsAsync(CancellationToken.None)).Length, "incertitude durable");
        }
    }

    [Test]
    public static async Task Missing_task_consent_creates_no_artifact_and_finishes_the_local_preparation()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await Open(folder); var backend = new Backend(plan);
        var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(false), CancellationToken.None);
        Check.Equal(0, backend.Starts, "aucune tâche créée"); Check.Equal(1, backend.Cleanups, "précontrôle libéré"); Check.True(result.CleanupConfirmed, "aucun effet distant restant");
        Check.Contains("Autorisation", result.Reading.Access.Detail, "cause explicite");
    }

    [Test]
    public static async Task Task_result_does_not_hide_failed_cleanup_and_blocks_new_work_for_that_host()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await Open(folder); var backend = new Backend(plan) { CleanupResult = new(true, false, "Fichier non supprimé.") };
        var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.Equal(SourceStatus.Partial, result.Reading.Access.Status, "réponse partielle à cause du nettoyage"); Check.Equal(1, result.Reading.Candidates.Length, "résultat reçu conservé");
        var saved = await db.ReadTaskReadAsync(plan.Id, CancellationToken.None);
        Check.True(saved!.Completion!.ResultReceived, "réception indépendante du nettoyage"); Check.True(saved.CleanupRequired, "attente conservée");
        await Check.ThrowsAsync<InvalidDataException>(() => db.PrepareTaskReadAsync(plan with { Id = Guid.NewGuid() }, CancellationToken.None), "autre tâche sur le poste bloquée");
    }

    [Test]
    public static async Task Invalid_task_result_is_never_published_but_owned_artifacts_are_still_cleaned()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await Open(folder);
        var backend = new Backend(plan) { OnRead = () => Json(plan with { Nonce = new('0', 64) }) };
        var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }.RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
        Check.Equal(0, result.Reading.Candidates.Length, "candidats étrangers écartés"); Check.True(result.CleanupConfirmed, "nettoyage même après rejet JSON");
        Check.False((await db.ReadTaskReadAsync(plan.Id, CancellationToken.None))!.Completion!.ResultReceived, "pas de résultat qualifié inventé");
    }

    [Test]
    public static async Task Task_output_rejects_another_operation_nonce_host_duplicate_and_oversized_envelope()
    {
        using var folder = new TemporaryFolder(); var (_, plan) = await Open(folder); var json = Json(plan);
        foreach (var invalid in new[] { json.Replace(plan.Id.ToString("N"), Guid.NewGuid().ToString("N"), StringComparison.Ordinal),
            json.Replace(plan.Nonce, new string('0', 64), StringComparison.Ordinal), json.Replace("PC1", "PC2", StringComparison.Ordinal),
            json.Insert(1, "\"nonce\":\"other\","), new string('x', RemoteTaskReadProgram.MaximumOutput + 1) })
        { Check.Throws<JsonException>(() => RemoteTaskReadProgram.Parse(invalid, plan, Fixtures.Now), "résultat non rattachable refusé"); }
    }

    [Test]
    public static async Task Task_cleanup_ownership_requires_exact_command_marker_principal_and_no_trigger()
    {
        using var folder = new TemporaryFolder(); var (_, plan) = await Open(folder); var xml = RemoteTaskReadProgram.Xml(plan);
        Check.True(RemoteTaskReadProgram.OwnsTask(xml, plan), "programme attendu");
        Check.False(RemoteTaskReadProgram.OwnsTask(xml, plan with { Nonce = new('0', 64) }), "autre nonce");
        XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        foreach (var change in new Action<XElement>[] {
            root => root.Descendants(ns + "Arguments").Single().Value = "-Command whoami",
            root => root.Descendants(ns + "UserId").Single().Value = "S-1-5-19",
            root => root.Element(ns + "Triggers")!.Add(new XElement(ns + "BootTrigger")),
            root => root.Add(new XElement(ns + "Triggers", new XElement(ns + "TimeTrigger"))),
            root => root.Element(ns + "Actions")!.Add(new XElement(ns + "Exec")),
            root => root.Descendants(ns + "Principal").Single().Add(new XElement(ns + "LogonType", "Password")),
        })
        { var document = XElement.Parse(xml); change(document); Check.False(RemoteTaskReadProgram.OwnsTask(document.ToString(), plan), "tâche modifiée non détenue"); }
        Check.False(RemoteTaskReadProgram.OwnsTask("<!DOCTYPE Task [<!ENTITY x SYSTEM 'file:///private'>]>" + xml, plan), "DTD refusée");
    }

    [Test]
    public static async Task Closed_task_XML_is_accepted_by_Windows_without_registering_or_running_any_task()
    {
        using var folder = new TemporaryFolder(); var (_, plan) = await Open(folder);
        object? service = null; object? definition = null;
        try
        {
            service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", true)!)!;
            definition = ((dynamic)service).NewTask(0);
            ((dynamic)definition).XmlText = RemoteTaskReadProgram.Xml(plan);
            Check.True(RemoteTaskReadProgram.OwnsTask((string)((dynamic)definition).XmlText, plan), "aller-retour du parseur Windows, sans RegisterTask ni Run");
        }
        finally
        {
            if (definition is not null && Marshal.IsComObject(definition)) { Marshal.FinalReleaseComObject(definition); }
            if (service is not null && Marshal.IsComObject(service)) { Marshal.FinalReleaseComObject(service); }
        }
    }

    [Test]
    public static async Task A_second_execution_claim_cannot_replace_the_first_even_with_identical_plan_and_account()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await Open(folder); await db.PrepareTaskReadAsync(plan, CancellationToken.None);
        var claim = new RemoteTaskReadCompletion(Fixtures.Now, false, false, false, "Engagée.") { ExecutionId = Guid.NewGuid() };
        await db.CompleteTaskReadAsync(plan.Id, 1, claim, CancellationToken.None);
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 1, claim with { ExecutionId = Guid.NewGuid() }, CancellationToken.None), "revendication concurrente refusée");
        await Check.ThrowsAsync<InvalidDataException>(() => db.CompleteTaskReadAsync(plan.Id, 2, claim with { ExecutionId = Guid.NewGuid() }, CancellationToken.None), "propriétaire non remplaçable");
    }
}
