using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.App.Secrets;

public sealed class HostCredentialWindow(IDirectorySource source) : IAccountsCredentialWindow
{
    public Task<CredentialWindowEntry?> AskAsync(CredentialWindowRequest request, CancellationToken cancellationToken) =>
        NativeSecretDialog.ShowAsync(() => new CredentialWindow(request, new WindowsCredentialVault(source)), static form => form.TakeEntry(), cancellationToken);
}
