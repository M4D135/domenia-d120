using System.Globalization;
using System.IO.Compression;
using System.Text;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Documents written by the Opérations screen (docs/ops/operations.md § 5): CSV exports, the redacted diagnostic and the diagnostic
/// dossier (ZIP), in %LOCALAPPDATA%\Domenia\Exports (Exports-simulation in simulation, never shared). Every document is new and
/// dated: nothing is ever overwritten (a name already taken gets « -2 », « -3 »…). A file is written beside its target in a
/// temporary file (write-through, flushed) then renamed, so a stop never leaves half a document under its final name; a link in place
/// of the folder is refused. Where the receipts of the mode live in memory (capture, E2E, no data folder), nothing is written: the
/// result says so and keeps the fingerprint. The folder is handed in (<see cref="DefaultFolder"/> for the application), so the
/// rules (no overwrite, link refused, size limit, temporary file removed) are tested on a folder of the test.
/// </summary>
public sealed class OperationsExports
{
    public const int MaxDocumentBytes = 4 * 1024 * 1024;

    public const string ExportFailed = "operations.exportFailed";
    public const string ExportTooLarge = "operations.exportTooLarge";

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);
    private readonly EngineContext context;

    /// <param name="context">Engine context (clock and journal).</param>
    /// <param name="folder">Folder of the documents; null when nothing may be written in this mode.</param>
    public OperationsExports(EngineContext context, string? folder)
    {
        ArgumentNullException.ThrowIfNull(context);
        this.context = context;
        Folder = folder is not null && Path.IsPathFullyQualified(folder) ? folder : null;
    }

    /// <summary>
    /// Folder of the documents of the application: %LOCALAPPDATA%\Domenia\Exports (Exports-simulation in simulation), only when the
    /// receipts of the mode live on the disk; null in capture, E2E or without a data folder.
    /// </summary>
    public static string? DefaultFolder(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify);
        return context.Receipts.Persistent && Path.IsPathFullyQualified(root)
            ? Path.Combine(root, ProductInfo.Name, context.Mode == AppMode.Simulation ? "Exports-simulation" : "Exports")
            : null;
    }

    /// <summary>Folder of the documents; null when nothing may be written in this mode.</summary>
    public string? Folder { get; }

    /// <summary>Local date for the file names (Domenia-Recus-AAAAMMJJ-HHmmss.csv).</summary>
    public string Stamp(DateTimeOffset at) => TimeZoneInfo.ConvertTime(at, context.Clock.LocalTimeZone).ToString("yyyyMMdd'-'HHmmss", CultureInfo.InvariantCulture);

    /// <summary>A text document (UTF-8, with a byte order mark for CSV files so that Excel reads the accents).</summary>
    public Task<ExportResult> SaveTextAsync(string name, string text, bool bom, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        var body = Utf8.GetBytes(text);
        byte[] bytes = bom ? [0xEF, 0xBB, 0xBF, .. body] : body;
        return SaveAsync(name, bytes, OperationsDiagnostics.Sha256(text), cancellationToken);
    }

    /// <summary>A ZIP archive of text files (the diagnostic dossier).</summary>
    public Task<ExportResult> SaveZipAsync(string name, IReadOnlyList<DossierFile> files, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(files);
        using var buffer = new MemoryStream();
        using (var archive = new ZipArchive(buffer, ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var file in files)
            {
                var entry = archive.CreateEntry(file.Name, CompressionLevel.Optimal);
                using var stream = entry.Open();
                var bytes = Utf8.GetBytes(file.Text);
                stream.Write(bytes);
            }
        }
        var data = buffer.ToArray();
        return SaveAsync(name, data, Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(data)), cancellationToken);
    }

    private async Task<ExportResult> SaveAsync(string name, byte[] bytes, string sha, CancellationToken cancellationToken)
    {
        var at = context.Clock.GetUtcNow();
        if (bytes.Length > MaxDocumentBytes)
        {
            throw new DomeniaOperationException(ExportTooLarge, "Document trop volumineux (plus de 4 Mo) : rien n’a été écrit.");
        }
        if (Folder is null)
        {
            return new ExportResult(false, null, name, null, sha, bytes.Length,
                "Document préparé, non écrit" + FrenchText.Colon + "ce mode (capture, E2E ou sans dossier de données) garde tout en mémoire.", at);
        }
        var temporary = "";
        try
        {
            var info = new DirectoryInfo(Folder);
            if (info.Exists && info.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                throw new IOException("Exports folder is a link.");
            }
            info.Create();
            var target = Unique(name);
            temporary = Path.Combine(Folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough | FileOptions.Asynchronous))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            File.Move(temporary, target, overwrite: false);
            temporary = "";
            return new ExportResult(true, target, Path.GetFileName(target), Folder, sha, bytes.Length, "Document enregistré" + FrenchText.Colon + Path.GetFileName(target), at);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            context.Log.Warning($"Opérations : document non enregistré ({ex.GetType().Name}).");
            throw new DomeniaOperationException(ExportFailed, "Document non enregistré" + FrenchText.Colon + Reason(ex) + " Rien n’a été remplacé.");
        }
        finally
        {
            if (temporary.Length > 0)
            {
                try
                {
                    File.Delete(temporary);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    context.Log.Warning($"Opérations : fichier temporaire laissé ({ex.GetType().Name}).");
                }
            }
        }
    }

    private string Unique(string name)
    {
        var extension = Path.GetExtension(name);
        var stem = Path.GetFileNameWithoutExtension(name);
        var candidate = Path.Combine(Folder!, name);
        for (var n = 2; File.Exists(candidate) || Directory.Exists(candidate); n++)
        {
            candidate = Path.Combine(Folder!, stem + "-" + n.ToString(CultureInfo.InvariantCulture) + extension);
        }
        return candidate;
    }

    private static string Reason(Exception ex) => ex switch
    {
        UnauthorizedAccessException => "accès refusé au dossier des documents.",
        IOException io when io.HResult is unchecked((int)0x80070070) or unchecked((int)0x80070027) => "disque plein.",
        _ => "dossier des documents indisponible (verrouillé, lien ou chemin non admis).",
    };
}
