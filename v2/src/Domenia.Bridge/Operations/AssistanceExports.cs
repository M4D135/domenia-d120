using System.Globalization;
using System.Text;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Documents written by the Assistance screen (docs/ops/assistance.md § 7): captures, support dossiers, ticket reports and
/// offline dossiers, in %LOCALAPPDATA%\Domenia\Exports (Exports-simulation in simulation, never shared). Every file is new
/// and dated: nothing is ever overwritten (a name already taken gets « -2 », « -3 »…). A file is written beside its target in a
/// temporary file (write-through, flushed) then renamed; a dossier is written in a temporary folder then renamed, so a stop never
/// leaves half a document under its final name. A link (reparse point) in place of the folder is refused. Where the receipts of
/// the mode live in memory (capture, E2E, no data folder), nothing is written: the result says so and keeps the fingerprint.
/// </summary>
internal sealed class AssistanceExports
{
    public const int MaxDocumentBytes = 1_048_576;
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);
    private readonly EngineContext context;

    public AssistanceExports(EngineContext context)
    {
        this.context = context;
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify);
        Folder = context.Receipts.Persistent && Path.IsPathFullyQualified(root)
            ? Path.Combine(root, ProductInfo.Name, context.Mode == AppMode.Simulation ? "Exports-simulation" : "Exports")
            : null;
    }

    /// <summary>Folder of the exports; null when nothing may be written in this mode.</summary>
    public string? Folder { get; }

    public bool Persistent => Folder is not null;

    public string Label => Folder is not null
        ? "Documents enregistrés dans " + Folder + ", jamais remplacés."
        : "Mode capture, E2E ou sans dossier de données" + FrenchText.Colon + "les documents restent en mémoire, rien n’est écrit sur le disque.";

    /// <summary>Local date for the file names (Domenia-Support-AAAAMMJJ-HHmmss.html).</summary>
    public string Stamp(DateTimeOffset at) => TimeZoneInfo.ConvertTime(at, context.Clock.LocalTimeZone).ToString("yyyyMMdd'-'HHmmss", CultureInfo.InvariantCulture);

    public async Task<ExportResult> SaveFileAsync(string name, string text, DateTimeOffset at, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        var bytes = Utf8.GetBytes(text);
        if (bytes.Length > MaxDocumentBytes)
        {
            throw new DomeniaOperationException(AssistanceErrors.ExportTooLarge, AssistanceErrors.ExportTooLargeMessage);
        }
        var sha = TicketReport.Hash(text);
        if (Folder is null)
        {
            return new ExportResult(false, null, name, null, sha, bytes.Length, "Document préparé, non écrit" + FrenchText.Colon + "ce mode garde tout en mémoire.", at);
        }
        var temporary = "";
        try
        {
            PrepareFolder();
            var target = Unique(name, isFolder: false);
            temporary = Path.Combine(Folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");
            await WriteAsync(temporary, bytes, cancellationToken).ConfigureAwait(false);
            File.Move(temporary, target, overwrite: false);
            temporary = "";
            return new ExportResult(true, target, Path.GetFileName(target), Folder, sha, bytes.Length, "Document enregistré" + FrenchText.Colon + Path.GetFileName(target), at);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            context.Log.Warning($"Assistance : document non enregistré ({ex.GetType().Name}).");
            throw new DomeniaOperationException(AssistanceErrors.ExportFailed, "Document non enregistré" + FrenchText.Colon + Reason(ex) + " Rien n’a été remplacé.");
        }
        finally
        {
            Discard(temporary, isFolder: false);
        }
    }

    public async Task<(bool Saved, string? Path, string Name)> SaveFolderAsync(string name, IReadOnlyList<DossierFile> files, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(files);
        if (Folder is null)
        {
            return (false, null, name);
        }
        var temporary = "";
        try
        {
            PrepareFolder();
            var target = Unique(name, isFolder: true);
            temporary = Path.Combine(Folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");
            Directory.CreateDirectory(temporary);
            foreach (var file in files)
            {
                await WriteAsync(Path.Combine(temporary, file.Name), Utf8.GetBytes(file.Text), cancellationToken).ConfigureAwait(false);
            }
            Directory.Move(temporary, target);
            temporary = "";
            return (true, target, Path.GetFileName(target));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            context.Log.Warning($"Assistance : dossier hors ligne non enregistré ({ex.GetType().Name}).");
            throw new DomeniaOperationException(AssistanceErrors.ExportFailed, "Dossier non enregistré" + FrenchText.Colon + Reason(ex) + " Aucun dossier final n’est créé.");
        }
        finally
        {
            Discard(temporary, isFolder: true);
        }
    }

    private void PrepareFolder()
    {
        var info = new DirectoryInfo(Folder!);
        if (info.Exists && info.Attributes.HasFlag(FileAttributes.ReparsePoint))
        {
            throw new IOException("Exports folder is a link.");
        }
        info.Create();
    }

    private string Unique(string name, bool isFolder)
    {
        var stem = isFolder ? name : Path.GetFileNameWithoutExtension(name);
        var extension = isFolder ? "" : Path.GetExtension(name);
        for (var n = 1; n < 100; n++)
        {
            var candidate = Path.Combine(Folder!, stem + (n == 1 ? "" : "-" + n.ToString(CultureInfo.InvariantCulture)) + extension);
            if (!File.Exists(candidate) && !Directory.Exists(candidate))
            {
                return candidate;
            }
        }
        throw new IOException("No free name.");
    }

    private static async Task WriteAsync(string path, byte[] bytes, CancellationToken cancellationToken)
    {
        var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough | FileOptions.Asynchronous);
        await using (stream.ConfigureAwait(false))
        {
            await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            stream.Flush(flushToDisk: true);
        }
    }

    private void Discard(string path, bool isFolder)
    {
        if (path.Length == 0)
        {
            return;
        }
        try
        {
            if (isFolder && Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
            else if (!isFolder && File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Assistance : fichier temporaire non supprimé ({ex.GetType().Name}).");
        }
    }

    private static string Reason(Exception ex) => ex switch
    {
        UnauthorizedAccessException => "accès refusé au dossier des exports.",
        PathTooLongException => "chemin trop long.",
        _ when ex.Message == "Exports folder is a link." => "le dossier des exports est un lien, refusé.",
        _ => "le disque a refusé l’écriture (plein, verrouillé ou indisponible).",
    };
}
