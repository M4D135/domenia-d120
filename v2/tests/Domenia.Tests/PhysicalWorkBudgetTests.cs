using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class PhysicalWorkBudgetTests
{
    [Test]
    public static async Task Physical_waiting_is_cancellable_and_never_returns_an_active_workers_place()
    {
        var leases = Enumerable.Range(0, PhysicalWorkBudget.ReadLimit)
            .Select(_ => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Network)).ToArray();
        try
        {
            using var stop = new CancellationTokenSource();
            var cancelled = PhysicalWorkBudget.AcquireAsync(PhysicalWorkRoute.Cim, stop.Token).AsTask();
            Check.False(cancelled.IsCompleted, "aucune place prise au delà du plafond");
            stop.Cancel();
            await Check.ThrowsAsync<OperationCanceledException>(() => cancelled, "annulation de la seule attente");
            Check.Equal(PhysicalWorkBudget.ReadLimit, PhysicalWorkBudget.Snapshot().Outstanding, "tous les propriétaires gardent leur place");
            var pending = PhysicalWorkBudget.AcquireAsync(PhysicalWorkRoute.Cim, default).AsTask();
            leases[0].Dispose();
            using var admitted = await pending.WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(PhysicalWorkBudget.ReadLimit, PhysicalWorkBudget.Snapshot().Outstanding, "une seule place rendue puis reprise");
        }
        finally { foreach (var lease in leases) lease.Dispose(); }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucune fuite après file et annulation");
    }

    [Test]
    public static async Task Wmi_worker_admits_before_its_timer_and_holds_one_place_through_native_cleanup()
    {
        var capacity = new AdaptiveReadBudget(TimeProvider.System, 1);
        using var held = capacity.Acquire("PC-TEST");
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        Task<int>? worker = null;
        var admission = WmiReadWorkers.StartAsync("PC-TEST", null, _ =>
        {
            using (var client = new NativeReadClient(new("PC-TEST", InventoryTransport.Dcom, 20_000, true, null, false, false), null, default))
            {
                var response = client.Read(new(NativeReadKind.Query, 20_000)
                { Category = "Fixture", Namespace = @"root\cimv2", Query = "SELECT Name FROM Win32_ComputerSystem", MaxItems = 1 });
                Check.Equal(SourceStatus.Skipped, response.Reading!.Status, "enfant Windows sans aucun contact réseau");
                Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "un seul bail pour worker et enfant");
            }
            Check.Equal(0, NativeReadProcess.Running, "enfant réellement sorti");
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "worker encore propriétaire pendant sa fin");
            entered.Set();
            Check.True(release.Wait(TimeSpan.FromSeconds(10)), "test libère le worker");
            return 1;
        }, default, capacity).AsTask();
        try
        {
            Check.False(admission.IsCompleted, "admission attendue avant démarrage du worker");
            Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucune ressource physique pendant attente de site");
            held.Dispose();
            worker = await admission.WaitAsync(TimeSpan.FromSeconds(10));
            Check.True(await Task.Run(() => entered.Wait(TimeSpan.FromSeconds(10))), "lecture et nettoyage natif terminés");
            Check.Equal(1, capacity.Snapshot("PC-TEST").Active, "site détenu jusqu’à fin physique du worker");
        }
        finally
        {
            held.Dispose(); release.Set();
            worker ??= await admission.WaitAsync(TimeSpan.FromSeconds(10));
            await worker.WaitAsync(TimeSpan.FromSeconds(10));
        }
        Check.Equal(0, capacity.Snapshot("PC-TEST").Active, "site rendu");
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "physique rendu");
    }

    [Test]
    public static async Task Wmi_waiting_subnet_does_not_occupy_workers_needed_by_a_healthy_subnet()
    {
        var capacity = new AdaptiveReadBudget(TimeProvider.System, 1);
        using var held = capacity.Acquire("198.19.10.1");
        using var stop = new CancellationTokenSource();
        var sent = 0;
        var pending = Enumerable.Range(0, 6).Select(i => WmiReadWorkers.StartAsync("198.19.10." + (i + 2), null,
            _ => { Interlocked.Increment(ref sent); return i; }, stop.Token, capacity).AsTask()).ToArray();
        try
        {
            Check.True(pending.All(t => !t.IsCompleted), "six demandes attendent uniquement leur site");
            var healthy = await WmiReadWorkers.StartAsync("198.19.11.1", null, _ => 42, default, capacity)
                .AsTask().WaitAsync(TimeSpan.FromSeconds(5));
            Check.Equal(42, await healthy.WaitAsync(TimeSpan.FromSeconds(5)), "site sain admis pendant attente du voisin");
            Check.Equal(0, sent, "aucune cible occupée contactée");
        }
        finally
        {
            stop.Cancel();
            foreach (var waiting in pending)
                await Check.ThrowsAsync<OperationCanceledException>(async () => { await waiting; }, "attente annulée sans worker");
        }
        Check.Equal(1, capacity.Snapshot("198.19.10.1").Active, "place tierce conservée");
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucune fuite après annulation des files");
    }

    [Test]
    public static async Task Wmi_worker_cannot_release_a_physical_reservation_still_owned_by_its_child()
    {
        var capacity = new AdaptiveReadBudget(TimeProvider.System, 1);
        IDisposable? child = null;
        try
        {
            var worker = await WmiReadWorkers.StartAsync("PC-OWNERSHIP", null, _ =>
            {
                child = WmiReadWorkers.BorrowPhysicalAdmission();
                Check.Throws<DomeniaOperationException>(() => WmiReadWorkers.BorrowPhysicalAdmission(), "pas de deuxième enfant masqué derrière un seul bail");
                return 1;
            }, default, capacity);
            Check.Equal(1, await worker, "worker terminé");
            Check.NotNull(child, "référence enfant indépendante");
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "fin du worker ne prouve pas fin enfant");
            Check.Equal(1, capacity.Snapshot("PC-OWNERSHIP").Active, "site également détenu jusqu’à sortie enfant");
        }
        finally { child?.Dispose(); child?.Dispose(); }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "libération unique après dernier propriétaire");
        Check.Equal(0, capacity.Snapshot("PC-OWNERSHIP").Active, "site rendu après dernier propriétaire");
    }

    [Test]
    public static void Physical_budget_combines_routes_and_preserves_the_12_13_14_reserved_limits()
    {
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucun bail précédent");
        var leases = new List<IDisposable>();
        try
        {
            for (var i = 0; i < 12; i++) { leases.Add(PhysicalWorkBudget.Acquire((PhysicalWorkRoute)(i % 6), PhysicalWorkPriority.Selection)); }
            var readFailure = Check.Throws<DomeniaOperationException>(() => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory), "treizième lecture refusée");
            Check.Equal("operation.physicalBusy", readFailure.Code, "refus connu avant envoi");
            leases.Add(PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Cim, PhysicalWorkPriority.Explicit));
            Check.Throws<DomeniaOperationException>(() => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Network, PhysicalWorkPriority.Explicit), "pas de quatorzième explicite");
            leases.Add(PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory, PhysicalWorkPriority.Write));
            Check.Equal(14, PhysicalWorkBudget.Snapshot().Outstanding, "écriture réservée admise");
            Check.Equal(14, PhysicalWorkBudget.Snapshot().ByRoute.Sum(), "chaque travail physique compté une fois");
            Check.Throws<DomeniaOperationException>(() => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage, PhysicalWorkPriority.Write), "quinzième refusée sans file");
        }
        finally { foreach (var lease in leases) { lease.Dispose(); lease.Dispose(); } }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "restitution exactement une fois");
    }

    [Test]
    public static void Physical_provider_budgets_apply_to_background_without_blocking_explicit_or_selection()
    {
        foreach (var (route, limit) in new[] { (PhysicalWorkRoute.Directory, 4), (PhysicalWorkRoute.Cim, 3), (PhysicalWorkRoute.Wts, 2),
            (PhysicalWorkRoute.Storage, 1), (PhysicalWorkRoute.Network, 4), (PhysicalWorkRoute.Other, 2) })
        {
            var leases = new List<IDisposable>();
            try
            {
                using var scope = PhysicalWorkBudget.Enter(PhysicalWorkPriority.Background);
                for (var i = 0; i < limit; i++) { leases.Add(PhysicalWorkBudget.Acquire(route)); }
                Check.Throws<DomeniaOperationException>(() => PhysicalWorkBudget.Acquire(route), "plafond fournisseur de fond");
                using var explicitRead = PhysicalWorkBudget.Acquire(route, PhysicalWorkPriority.Explicit);
                using var selection = PhysicalWorkBudget.Acquire(route, PhysicalWorkPriority.Selection);
                Check.Equal(limit + 2, PhysicalWorkBudget.Snapshot().ByRoute[(int)route], "premier plan admis conformément à TRV127");
            }
            finally { foreach (var lease in leases) { lease.Dispose(); } }
        }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "routes vidées");
    }

    [Test]
    public static void Physical_aged_background_gets_one_provider_place_only_when_no_background_is_active()
    {
        var foreground = Enumerable.Range(0, 3).Select(_ => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Cim, PhysicalWorkPriority.Explicit)).ToArray();
        try
        {
            using var scope = PhysicalWorkBudget.Enter(PhysicalWorkPriority.Background, aged: true);
            using var aged = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Cim);
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Background, "une lecture vieillie active");
            Check.Throws<DomeniaOperationException>(() => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Cim), "pas de deuxième exception vieillie");
        }
        finally { foreach (var lease in foreground) { lease.Dispose(); } }
    }

    [Test]
    public static async Task Physical_server_priority_flows_to_workers_and_scope_restores_its_previous_value()
    {
        using var occupied = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage, PhysicalWorkPriority.Selection);
        using (PhysicalWorkBudget.Enter(PhysicalWorkPriority.Background))
        {
            await Task.Run(() => Check.Throws<DomeniaOperationException>(() => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage), "classe de fond propagée"));
        }
        using var after = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage);
        Check.Equal(2, PhysicalWorkBudget.Snapshot().Outstanding, "contexte précédent restauré, pas un fond persistant");
    }

    [Test]
    public static async Task Physical_cancelled_wait_does_not_release_a_blocked_worker_or_its_credential()
    {
        using var password = new System.Security.SecureString(); foreach (var c in Guid.NewGuid().ToString("N")) { password.AppendChar(c); } password.MakeReadOnly();
        var credential = new RemoteProbeCredential("TEST\\reader", password.Copy(), false);
        var lease = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Wts);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var worker = Task.Run(async () =>
        {
            using (lease)
            using (credential) { started.SetResult(); await release.Task.ConfigureAwait(false); }
        }, CancellationToken.None);
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            using var stop = new CancellationTokenSource(); var waiting = worker.WaitAsync(stop.Token); stop.Cancel();
            await Check.ThrowsAsync<OperationCanceledException>(() => waiting, "seule l’attente est annulée");
            Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "appel réellement bloqué toujours compté");
            Check.True(SecureCredentialCopies.Contains(password), "copie tenue pendant le travail détaché");
        }
        finally { release.TrySetResult(); await worker; }
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "libéré après fin du worker");
        Check.False(SecureCredentialCopies.Contains(password), "credential détruit avant restitution finale");
    }

    [Test]
    public static async Task Physical_CIM_child_is_counted_once_and_only_released_after_OS_exit()
    {
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "aucun appel précédent");
        using var client = new NativeReadClient(new("PC-TEST", InventoryTransport.Dcom, 20_000, true, null, false, false), null, default, adaptive: new AdaptiveReadBudget(TimeProvider.System));
        var response = await client.ReadAsync(new(NativeReadKind.Query, 20_000)
        { Category = "Fixture", Namespace = @"root\cimv2", Query = "SELECT Name FROM Win32_ComputerSystem", MaxItems = 1 });
        Check.Equal(SourceStatus.Skipped, response.Reading!.Status, "enfant réel sans contact réseau");
        Check.Equal(1, NativeReadProcess.Running, "un enfant physique"); Check.Equal(1, PhysicalWorkBudget.Snapshot().Outstanding, "aucun double comptage orchestration/enfant");
        using var child = System.Diagnostics.Process.GetProcessById(client.ProcessId!.Value);
        client.Dispose();
        Check.True(child.HasExited, "sortie Windows constatée"); Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "bail rendu après sortie");
    }

    [Test]
    public static void Physical_failed_admission_never_runs_or_replays_work_and_write_scope_cannot_be_downgraded()
    {
        var leases = Enumerable.Range(0, 13).Select(_ => PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory, PhysicalWorkPriority.Write)).ToList();
        var sent = 0;
        try
        {
            using var write = PhysicalWorkBudget.Enter(PhysicalWorkPriority.Write);
            using var nested = PhysicalWorkBudget.Enter(PhysicalWorkPriority.Background);
            leases.Add(PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Storage));
            Check.Throws<DomeniaOperationException>(() => { using var refused = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Directory); sent++; }, "refus avant native");
        }
        finally { foreach (var lease in leases) { lease.Dispose(); } }
        Check.Equal(0, sent, "aucun envoi ni rejeu après libération"); Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "fin propre");
    }
}
