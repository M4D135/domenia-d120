using Domenia.Core;

namespace Domenia.App;

internal sealed partial class Composition
{
    internal bool AccessValidationActive => context.Existing<AccountAccess>()?.ValidationActive == true;

    internal void SweepLocalAccess()
    {
        var snapshot = (context.Directory as ILocalSessionSnapshotSource)?.PeekSession();
        context.Existing<AccountAccess>()?.SweepLocal(snapshot);
        context.Existing<MachineAccountService>()?.SweepLocal(snapshot);
    }

    internal Task BeginAccessClose() => context.Existing<AccountAccess>()?.BeginClose() ?? Task.CompletedTask;
}
