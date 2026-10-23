using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>Native reset entry; shares modal ownership and cancellation with the account credential window.</summary>
public sealed class HostPasswordWindow : IFichePasswordWindow
{
    public HostPasswordWindow(IDirectorySource source) { ArgumentNullException.ThrowIfNull(source); }
    public Task<FichePasswordEntry?> AskAsync(FichePasswordRequest request, CancellationToken cancellationToken) =>
        NativeSecretDialog.ShowAsync(() => new PasswordWindow(request), static form => form.TakeEntry(), cancellationToken);
}
