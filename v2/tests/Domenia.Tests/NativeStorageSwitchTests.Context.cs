using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static partial class NativeStorageSwitchTests
{
    [Test]
    public static async Task Native_executor_refuses_unbound_or_previous_session_switches_before_any_file_change()
    {
        using var setup = new Setup(); await setup.Initialize();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: setup.Cache);
        var executor = new AdStorageMoveExecutor(source);
        var draft = await executor.PlanMoveAsync(setup.Destination, None); var plan = Seal(draft);
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, None), "plan non lié refusé");
        executor.Bind(draft, plan);
        Check.True((await executor.CheckAsync(plan, None)).Current, "plan natif lié requalifié");
        source.Reset();
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.CheckAsync(plan, None), "ancien aperçu refusé après changement de session");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(plan, None), "pas de bascule d’un ancien compte");
        Check.False(File.Exists(setup.Destination), "aucune copie créée");
        Check.False(File.Exists(StorageWriteFence.Marker(setup.Database.Path)), "aucune protection de l’original ajoutée");
        var fresh = await executor.PlanMoveAsync(setup.Destination, None); var accepted = Seal(fresh); executor.Bind(fresh, accepted);
        Check.Equal(WriteResult.Applied, (await executor.ExecuteAsync(accepted, None)).Result, "nouvelle confirmation exécutable");
        Check.Equal(VerificationState.Verified, (await executor.VerifyAsync(accepted, None)).State, "relecture durable après epoch changé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => executor.ExecuteAsync(accepted, None), "plan consommé, aucun rejeu");
    }
}
