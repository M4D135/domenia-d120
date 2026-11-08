using System.ComponentModel;
using Domenia.Core;

namespace Domenia.App;

internal sealed partial class MainForm
{
    private bool preparingUpdate;

    /// <summary>UI thread, scheduled after the Bridge response. True means helper authorized and parent closing, not installation success.</summary>
    internal async Task<bool> BeginPackageUpdateAsync(string preparedRoot, string expectedManifestSha256, string confirmation, CancellationToken token)
    {
        if (mode == AppMode.Simulation)
        { throw new DomeniaOperationException("update.simulation", "La démonstration ne peut pas installer une mise à jour réelle."); }
        if (preparingUpdate || IsDisposed) return false;
        preparingUpdate = true;
        var closeAuthorized = false;
        try
        {
            // Refuse a stale or foreign choice before suspending the operator's session.
            var plan = await Task.Run(() => PackageUpdateAssistant.Preview(preparedRoot, expectedManifestSha256), token).ConfigureAwait(true);
            if (plan.Confirmation != confirmation) throw new InvalidDataException("L’aperçu a changé ; relisez-le avant de fermer Domenia.");
            if (!await PrepareTransitionAsync(token).ConfigureAwait(true)) return false;
            await using var assistant = await PackageUpdateAssistant.PrepareAsync(preparedRoot, expectedManifestSha256, confirmation, token).ConfigureAwait(true);
            token.ThrowIfCancellationRequested();
            await assistant.AuthorizeAsync(token).ConfigureAwait(true);
            closeAuthorized = true;
            // Transition already refused uncertain receipts, drained physical readers and fenced new work.
            // The helper still waits for this process to exit; no code can be replaced while another launcher holds it.
            closingChecked = true;
            Close();
            return true;
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or Win32Exception
            or OperationCanceledException or DomeniaOperationException or System.Text.Json.JsonException or InvalidOperationException or TimeoutException)
        {
            if (!IsDisposed) MessageBox.Show(this, "Installation non commencée ou non confirmée.\n\n" + error.Message,
                "Mise à jour différée", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        finally
        {
            preparingUpdate = false;
            if (!closeAuthorized && !IsDisposed) ResumeTransition();
        }
    }
}
