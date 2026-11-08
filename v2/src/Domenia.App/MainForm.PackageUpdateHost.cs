namespace Domenia.App;

internal sealed partial class MainForm
{
    private void AttachPackageUpdateHost()
    {
        composition.Updates.AttachDefaults(PickDefaultsDestinationAsync);
        composition.Updates.Attach(PickUpdatePathAsync, (package, confirmation) =>
        {
            BeginInvoke(async () =>
            {
                try
                {
                    if (!await BeginPackageUpdateAsync(package.Directory, package.ManifestSha256, confirmation, lifetime.Token).ConfigureAwait(true))
                    { composition.Updates.TransitionFailed("Installation non démarrée ; le contexte et le paquet préparé restent conservés."); }
                }
                catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception)
                {
                    composition.Updates.TransitionFailed("Assistant non démarré : " + ex.Message);
                    if (!IsDisposed) { MessageBox.Show(this, ex.Message, "Mise à jour non démarrée", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
                }
            });
        });
    }

    private Task<string?> PickDefaultsDestinationAsync(CancellationToken token)
    {
        var result = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (IsDisposed) { return Task.FromException<string?>(new InvalidOperationException("Fenêtre fermée.")); }
        BeginInvoke(() =>
        {
            try
            {
                token.ThrowIfCancellationRequested();
                using var dialog = new FolderBrowserDialog { Description = "Préparer le pack avec cette configuration par défaut — choisissez un dossier local de destination", UseDescriptionForTitle = true, ShowNewFolderButton = true };
                var selected = dialog.ShowDialog(this) == DialogResult.OK ? dialog.SelectedPath : null;
                token.ThrowIfCancellationRequested(); result.TrySetResult(selected);
            }
            catch (Exception ex) { result.TrySetException(ex); }
        });
        return result.Task;
    }

    private Task<string?> PickUpdatePathAsync(bool folder, CancellationToken token)
    {
        var result = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (IsDisposed) { return Task.FromException<string?>(new InvalidOperationException("Fenêtre fermée.")); }
        BeginInvoke(() =>
        {
            try
            {
                token.ThrowIfCancellationRequested(); string? selected;
                if (folder)
                {
                    using var dialog = new FolderBrowserDialog { Description = "Dossier de diffusion Domenia (lecture seule)", UseDescriptionForTitle = true, ShowNewFolderButton = false };
                    selected = dialog.ShowDialog(this) == DialogResult.OK ? dialog.SelectedPath : null;
                }
                else
                {
                    using var dialog = new OpenFileDialog { Title = "ZIP de la variante installée avec SHA256SUMS.txt dans le même dossier", Filter = "Pack Domenia (*.zip)|*.zip", CheckFileExists = true, Multiselect = false, RestoreDirectory = true };
                    selected = dialog.ShowDialog(this) == DialogResult.OK ? dialog.FileName : null;
                }
                // Keep the operation alive until the native dialog actually closes, including on cancellation.
                token.ThrowIfCancellationRequested(); result.TrySetResult(selected);
            }
            catch (Exception ex) { result.TrySetException(ex); }
        });
        return result.Task;
    }
}
