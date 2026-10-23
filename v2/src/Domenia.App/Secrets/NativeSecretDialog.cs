using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>One owned modal secret window; cancellation closes it and never publishes an accepted late secret.</summary>
internal static class NativeSecretDialog
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    internal static async Task<T?> ShowAsync<TForm, T>(Func<TForm> create, Func<TForm, T?> take, CancellationToken token)
        where TForm : Form where T : class, IDisposable
    {
        if (!await Gate.WaitAsync(0, token).ConfigureAwait(false))
        { throw new DomeniaOperationException(AccountAccess.ValidationBusy, "Une fenêtre de saisie est déjà ouverte."); }
        try
        {
            var owner = Application.OpenForms.OfType<MainForm>().FirstOrDefault(form => !form.IsDisposed && form.IsHandleCreated)
                ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Fenêtre principale indisponible : aucune saisie de secret possible.");
            var completion = new TaskCompletionSource<T?>(TaskCreationOptions.RunContinuationsAsynchronously);
            EventHandler closed = (_, _) => completion.TrySetCanceled(new CancellationToken(true));
            owner.Disposed += closed;
            try
            {
            owner.BeginInvoke(() =>
            {
#pragma warning disable CA1031 // UI exceptions are forwarded to the awaiting operation, without exposing any entered value.
                try
                {
                    token.ThrowIfCancellationRequested();
                    using var form = create();
                    using var cancel = token.Register(() =>
                    {
                        try
                        {
                            owner.BeginInvoke(() =>
                            {
                                if (!form.IsDisposed) { form.DialogResult = DialogResult.Cancel; form.Close(); }
                            });
                        }
                        catch (InvalidOperationException) { /* owner already closed */ }
                    });
                    var result = form.ShowDialog(owner) == DialogResult.OK ? take(form) : null;
                    if (token.IsCancellationRequested) { result?.Dispose(); completion.TrySetCanceled(token); }
                    else if (!completion.TrySetResult(result)) { result?.Dispose(); }
                }
                catch (OperationCanceledException) { completion.TrySetCanceled(token); }
                catch (Exception error) { completion.TrySetException(error); }
#pragma warning restore CA1031
            });
            return await completion.Task.ConfigureAwait(false);
            }
            finally { owner.Disposed -= closed; }
        }
        finally { Gate.Release(); }
    }
}
