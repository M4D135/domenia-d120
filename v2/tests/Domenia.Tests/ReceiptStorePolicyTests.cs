using Domenia.App;
using Domenia.Core;

namespace Domenia.Tests;

internal static class ReceiptStorePolicyTests
{
    [Test]
    public static async Task Native_e2e_uses_a_durable_journal_separate_from_operator_receipts()
    {
        using var folder = new TemporaryFolder();
        var native = ReceiptStorePolicy.Create(AppMode.Directory, true, folder.Path, SilentTechnicalJournal.Instance);
        Check.True(native.Persistent, "recette native jamais en mémoire");
        var plan = WritePlans.Seal(FakeWriteExecutor.Draft(), WritePlans.NewId(), "TEST\\operator", AppMode.Directory, TestClock.Fixed().GetUtcNow(), TestClock.Paris);
        var receipt = WriteReceipts.Sent(plan, WritePlans.NewId(), TestClock.Fixed().GetUtcNow(), new ReceiptDetail("Préconditions", "Cible de recette relue."));
        await native.AppendAsync(receipt, CancellationToken.None);
        (native as IDisposable)?.Dispose();
        var reopened = ReceiptStorePolicy.Create(AppMode.Directory, true, folder.Path, SilentTechnicalJournal.Instance);
        try { Check.Equal(plan.Id, (await reopened.ReadAllAsync(CancellationToken.None)).Receipts.Single().Plan.Id, "reçu survit à une nouvelle session E2E"); }
        finally { (reopened as IDisposable)?.Dispose(); }
        var normal = ReceiptStorePolicy.Create(AppMode.Directory, false, folder.Path, SilentTechnicalJournal.Instance);
        try { Check.Equal(0, (await normal.ReadAllAsync(CancellationToken.None)).Receipts.Length, "recette ne modifie pas le journal opérateur"); }
        finally { (normal as IDisposable)?.Dispose(); }
    }

    [Test]
    public static async Task Missing_native_receipt_folder_refuses_writes_instead_of_using_memory()
    {
        var native = ReceiptStorePolicy.Create(AppMode.Directory, false, null, SilentTechnicalJournal.Instance);
        await Check.ThrowsAsync<IOException>(() => native.ReadAllAsync(CancellationToken.None), "incertitude signalée avant tout plan natif");
        var simulated = ReceiptStorePolicy.Create(AppMode.Simulation, true, null, SilentTechnicalJournal.Instance);
        Check.False(simulated.Persistent, "simulation isolée reste en mémoire");
        Check.Equal(0, (await simulated.ReadAllAsync(CancellationToken.None)).Receipts.Length, "simulation disponible sans disque");
    }
}
