using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Preparation of one offline dossier, shared by the Assistance screen (assistance.dossier.prepare) and the command line
/// (« Domenia.exe dossier », Domenia 1 « Domenia-Automate.ps1 dossier »): rows of the local index only (never the network nor
/// the directory), 300 seconds at most, the files built by <see cref="OfflineDossiers.Build"/>, then a new dated folder written
/// by the document store. A check given by the caller runs between the read and the write (the screen ignores the answer of
/// another session there).
/// </summary>
public static class OfflineDossierRunner
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(300);

    /// <summary>
    /// Name given to the dossier folder: the workstation for one named workstation, the OU for an OU, else « N-postes »
    /// (Domenia 1 Get-DomeniaOfflineDossierName).
    /// </summary>
    public static string FolderSubject(DossierPerimeter perimeter, string? workstation)
    {
        ArgumentNullException.ThrowIfNull(perimeter);
        if (perimeter.Kind == "OU" && perimeter.OrganizationalUnit is { } ou)
        {
            return SupportReport.CommonName(ou) ?? "OU";
        }
        if (perimeter.Count == 1 && !string.IsNullOrWhiteSpace(workstation))
        {
            return workstation;
        }
        return perimeter.Count.ToString(System.Globalization.CultureInfo.InvariantCulture) + "-postes";
    }

    public static async Task<DossierResult> RunAsync(
        IAssistanceIndex index,
        IDocumentStore documents,
        DossierPerimeter perimeter,
        IEnumerable<string> optional,
        string folderSubject,
        string build,
        TimeProvider clock,
        int unresolved,
        Func<CancellationToken, Task>? beforeWrite,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(index);
        ArgumentNullException.ThrowIfNull(documents);
        ArgumentNullException.ThrowIfNull(perimeter);
        ArgumentNullException.ThrowIfNull(optional);
        ArgumentNullException.ThrowIfNull(clock);
        if (!perimeter.Valid)
        {
            throw new DomeniaOperationException(AssistanceErrors.DossierPerimeter, perimeter.Error ?? "Périmètre du dossier refusé.");
        }
        var request = new DossierRequest(perimeter, OfflineDossiers.Sections(optional), OfflineDossiers.DefaultRows);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(Timeout);
        DossierData data;
        try
        {
            data = await index.DossierDataAsync(request, limit.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new DomeniaOperationException(AssistanceErrors.DossierTimeout, AssistanceErrors.DossierTimeoutMessage);
        }
        if (beforeWrite is not null)
        {
            await beforeWrite(cancellationToken).ConfigureAwait(false);
        }
        var now = clock.GetUtcNow();
        var dossier = OfflineDossiers.Build(request, data, folderSubject, build, now, clock.LocalTimeZone);
        SavedDocument saved;
        try
        {
            saved = await documents.SaveFolderAsync(dossier.FolderName, [.. dossier.Files.Select(f => new DocumentFile(f.Name, f.Bytes))], limit.Token).ConfigureAwait(false);
        }
        catch (DocumentStoreException ex)
        {
            throw new DomeniaOperationException(AssistanceErrors.ExportFailed, "Dossier non enregistré" + FrenchText.Colon + ex.Reason + " Aucun dossier final n’est créé.");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new DomeniaOperationException(AssistanceErrors.DossierTimeout, AssistanceErrors.DossierTimeoutMessage);
        }
        var parts = AssistanceText.List([.. dossier.Sections.Select(s => OfflineDossiers.SectionLabel(s.Section) + FrenchText.Nbsp + FrenchText.Integer(s.Elements) + (s.Truncated ? " (limite atteinte)" : ""))]);
        var message = (saved.Saved ? "Dossier hors ligne prêt (" : "Dossier hors ligne préparé en mémoire, non écrit dans ce mode (") + perimeter.Label + ")" + FrenchText.Colon + parts
            + ". Empreintes dans SHA256SUMS.txt" + FrenchText.Nbsp + "; secrets exclus (liste dans manifeste.json).";
        return new DossierResult(saved.Saved, saved.Path, saved.Name, perimeter.Label, perimeter.Truncated, unresolved, dossier.Sections,
            [.. dossier.Files.Select(f => new DossierFileView(f.Name, f.Sha256, f.Bytes.LongLength, AssistanceText.Bytes(f.Bytes.LongLength)))],
            OfflineDossiers.ExcludedFamilies, message, now);
    }
}
