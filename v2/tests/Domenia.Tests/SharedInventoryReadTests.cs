using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class SharedInventoryReadTests
{
    private static readonly InventoryReadKey Key = new(Guid.Parse(FakeWriteExecutor.TargetGuid), "CN=PC01,OU=Tests,DC=test,DC=local",
        TestClock.Reference, "PC01.TEST.LOCAL", WorkstationReading.Survey, "1:2:True:TEST\\adm", true, false, false);

    private static Task<InventorySnapshot> SnapshotAsync()
    {
        var reader = new WmiWorkstationReader(TimeProvider.System)
        {
            SessionFactory = (host, budget, token) => new CimSession(host, budget, TimeProvider.System, cancellationToken: token)
            { ReadOverride = (_, query, _) => query.Contains("Win32_ComputerSystem", StringComparison.Ordinal)
                ? [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "PC01", ["DomainRole"] = 1u })] : [] },
        };
        return reader.ReadSharedAsync("PC01", WorkstationReading.Survey, null, CancellationToken.None);
    }

    [Test]
    public static async Task Identical_reads_share_only_live_work_and_count_actual_CIM_projections()
    {
        var value = await SnapshotAsync();
        Check.True(value.CimQueriesIssued > 0, "projections réellement demandées au transport injecté, pas estimées par âge");
        var sharing = new SharedInventoryReads(); var calls = 0;
        var finished = new TaskCompletionSource<InventorySnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<InventorySnapshot> Read(IProgress<PosteProgress> _, CancellationToken token) { Interlocked.Increment(ref calls); return finished.Task; }
        var first = sharing.ReadAsync(Key, Read, null, CancellationToken.None);
        var second = sharing.ReadAsync(Key, Read, null, CancellationToken.None);
        Check.Equal(1, calls, "une seule lecture native pour deux demandeurs identiques");
        finished.SetResult(value);
        var results = await Task.WhenAll(first, second);
        Check.Equal(1, results.Count(r => r.Shared), "un seul résultat supplémentaire partagé");
        var (context, _, _, _) = WriteCircuitTests.FakeCircuit();
        using (context)
        {
            var activity = OperationActivity.From(context);
            foreach (var result in results.Where(r => r.Shared)) { activity.RecordSharedInventory(result.Value.CimQueriesIssued); }
            Check.Equal(1L, activity.SharedInventories, "un inventaire réellement partagé reçu");
            Check.Equal((long)value.CimQueriesIssued, activity.SharedCimQueriesAvoided, "nombre exact des projections du worker évité");
        }
        var fresh = await sharing.ReadAsync(Key, Read, null, CancellationToken.None);
        Check.False(fresh.Shared, "un résultat terminé n’est pas un cache implicite");
        Check.Equal(2, calls, "une demande ultérieure refait sa lecture");
    }

    [Test]
    public static async Task Cancelling_one_consumer_does_not_cancel_the_remaining_consumer()
    {
        var sharing = new SharedInventoryReads(); using var cancelled = new CancellationTokenSource();
        var ended = new TaskCompletionSource<InventorySnapshot>(TaskCreationOptions.RunContinuationsAsynchronously); CancellationToken native = default;
        Task<InventorySnapshot> Read(IProgress<PosteProgress> _, CancellationToken token) { native = token; return ended.Task; }
        var first = sharing.ReadAsync(Key, Read, null, cancelled.Token);
        var second = sharing.ReadAsync(Key, Read, null, CancellationToken.None);
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => first, "premier demandeur arrêté sans attendre le natif");
        Check.False(native.IsCancellationRequested, "le second demandeur garde sa lecture native");
        ended.SetResult(await SnapshotAsync());
        Check.True((await second).Shared, "le second reçoit le résultat normal");
    }

    [Test]
    public static async Task Last_consumer_cancellation_fences_the_key_until_native_completion()
    {
        var sharing = new SharedInventoryReads(); using var cancelled = new CancellationTokenSource();
        var ended = new TaskCompletionSource<InventorySnapshot>(TaskCreationOptions.RunContinuationsAsynchronously); CancellationToken native = default; var calls = 0;
        Task<InventorySnapshot> Read(IProgress<PosteProgress> _, CancellationToken token) { calls++; native = token; return ended.Task; }
        var first = sharing.ReadAsync(Key, Read, null, cancelled.Token);
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => first, "attente UI arrêtée");
        Check.True(native.IsCancellationRequested, "annulation native demandée après le dernier départ");
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => sharing.ReadAsync(Key, Read, null, CancellationToken.None), "pas de nouveau worker sur la clé encore vivante");
        Check.Equal("machine.busy", refusal.Code, "état en nettoyage explicite");
        Check.Equal(1, calls, "aucune relance native");
        ended.SetResult(await SnapshotAsync());
    }

    [Test]
    public static async Task Other_credentials_scope_transport_or_recreated_object_never_share()
    {
        var sharing = new SharedInventoryReads(); var calls = 0;
        var ended = new TaskCompletionSource<InventorySnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        Task<InventorySnapshot> Read(IProgress<PosteProgress> _, CancellationToken token) { calls++; return ended.Task; }
        var keys = new[] { Key, Key with { CredentialGeneration = "2:2:True:TEST\\adm" }, Key with { CredentialGeneration = "1:3:True:TEST\\adm" },
            Key with { ObjectGuid = Guid.Parse(FakeWriteExecutor.OtherGuid) }, Key with { Reading = WorkstationReading.Full }, Key with { WinRm = true } };
        var pending = keys.Select(k => sharing.ReadAsync(k, Read, null, CancellationToken.None)).ToArray();
        Check.Equal(keys.Length, calls, "aucune fusion de sessions, credentials, GUID, périmètres ou transports différents");
        ended.SetResult(await SnapshotAsync());
        Check.True((await Task.WhenAll(pending)).All(r => !r.Shared), "chaque identité conserve sa propre lecture");
    }
}
