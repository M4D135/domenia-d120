using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>
/// The secure window of the host for the fiche (<see cref="IFichePasswordWindow"/>): found by the composition like a screen reader
/// (public class, one public constructor taking the directory source, nothing read there), it shows <see cref="PasswordWindow"/>
/// modally above the main window, on the UI thread, and hands back the password as a SecureString. The web page never sees it.
/// </summary>
public sealed class HostPasswordWindow : IFichePasswordWindow
{
    public HostPasswordWindow(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
    }

    public Task<FichePasswordEntry?> AskAsync(FichePasswordRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        var owner = MainWindow() ?? throw FicheErrors.Error(FicheErrors.Refused, "Fenêtre principale introuvable" + FrenchText.Colon + "aucune saisie possible. Aucune écriture préparée.");
        var completion = new TaskCompletionSource<FichePasswordEntry?>(TaskCreationOptions.RunContinuationsAsynchronously);
        owner.BeginInvoke(() =>
        {
#pragma warning disable CA1031 // Whatever fails while the window is shown is handed to the operation that waits for it (traced there), never lost.
            try
            {
                using var window = new PasswordWindow(request);
                var result = window.ShowDialog(owner);
                completion.TrySetResult(result == DialogResult.OK ? window.TakeEntry() : null);
            }
            catch (Exception ex)
            {
                completion.TrySetException(ex);
            }
#pragma warning restore CA1031
        });
        return completion.Task;
    }

    /// <summary>The main window of the application (the only top-level form besides the secure window itself).</summary>
    private static Form? MainWindow()
    {
        var forms = Application.OpenForms;
        try
        {
            for (var i = 0; i < forms.Count; i++)
            {
                if (forms[i] is { IsDisposed: false, IsHandleCreated: true } form && form is not PasswordWindow)
                {
                    return form;
                }
            }
        }
        catch (ArgumentOutOfRangeException ex)
        {
            // A window closed while the list was read: no owner, the caller refuses the operation.
            TechnicalLog.Warning("Fenêtre sécurisée : liste des fenêtres modifiée pendant sa lecture (" + ex.GetType().Name + ").");
        }
        return null;
    }
}
