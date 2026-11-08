using System.Security;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class FilePreferenceStore : IPreferenceStorageInspection
{
    private string? lastWriteFailure;

    public Task<PreferenceStorageAccess> InspectAccessAsync(CancellationToken cancellationToken) => Task.Run(() =>
    {
        cancellationToken.ThrowIfCancellationRequested();
        int waiting; string? failure;
        lock (gate) { waiting = pending.Count; failure = lastWriteFailure; }
        PreferenceStorageAccess State(string state, string reason) => new(path, state, reason, waiting);
        try
        {
            CompatibleDirectoryCache.ValidateLocalPath(path);
            // File.Exists would turn an access denial into absence. Open the exact existing document instead.
            var attributes = File.GetAttributes(path);
            using (var read = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (read.Length > MaxBytes) return State("Document hors limites", "Préférences supérieures à 1 Mio ; fichier conservé.");
            }
            if (attributes.HasFlag(FileAttributes.ReadOnly)) return State("Lecture seule", "Le fichier porte l’attribut lecture seule ; l’enregistrement peut être refusé.");
            if (failure is not null) return State("Dernier enregistrement refusé", failure + " Les choix en attente restent propres à cette session.");
            return State("Lecture disponible", "L’écriture et le remplacement atomique seront vérifiés au prochain enregistrement ; aucun fichier d’essai n’est créé.");
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
        { return failure is null ? State("À créer", "Le fichier est absent ; le droit de création n’a pas été testé.") : State("Dernier enregistrement refusé", failure); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or SecurityException or ArgumentException)
        { return State("Non lisible", "Accès refusé ou fichier occupé (" + ex.GetType().Name + ") ; aucun remplacement ni repli à la consultation."); }
    }, cancellationToken);

    private void RememberWriteFailure(Exception error)
    { lock (gate) lastWriteFailure = "Échec réel d’enregistrement (" + error.GetType().Name + ")."; }
    private void ClearWriteFailure() { lock (gate) lastWriteFailure = null; }
}
