using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

// The tests read the CSV rules of the exports (neutralized cells, never overwritten, link refused) directly.
[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("Domenia.Tests")]

namespace Domenia.Bridge;

/// <summary>
/// CSV written by the « Synchronisation et base autonome » screen (docs/ops/synchro.md § 6): results of the local index and
/// comparison reports, in %LOCALAPPDATA%\Domenia\Exports (Exports-simulation in simulation). Every file is new and dated, never
/// overwritten (« -2 », « -3 »… when a name is taken), written in a temporary file of the same folder (write-through, flushed)
/// then renamed. Semicolon, French headers, UTF-8 with BOM, cells starting with = + - @ neutralized. Where the receipts of the
/// mode live in memory (capture, E2E, no data folder), nothing is written: the result says so and keeps the fingerprint.
/// </summary>
internal sealed class SyncExports
{
    public const int MaxBytes = 16 * 1024 * 1024;
    private static readonly UTF8Encoding Utf8Bom = new(encoderShouldEmitUTF8Identifier: true);
    private readonly EngineContext context;

    public SyncExports(EngineContext context)
    {
        this.context = context;
        var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.DoNotVerify);
        Folder = context.Receipts.Persistent && Path.IsPathFullyQualified(root)
            ? Path.Combine(root, ProductInfo.Name, context.Mode == AppMode.Simulation ? "Exports-simulation" : "Exports")
            : null;
    }

    /// <summary>Folder of the exports; null when nothing may be written in this mode.</summary>
    public string? Folder { get; }

    /// <summary>CSV text: header then rows, every cell escaped and neutralized.</summary>
    public static string Csv(IReadOnlyList<string> headers, IEnumerable<IReadOnlyList<string?>> rows)
    {
        ArgumentNullException.ThrowIfNull(headers);
        ArgumentNullException.ThrowIfNull(rows);
        var builder = new StringBuilder();
        builder.AppendJoin(';', headers.Select(Cell)).Append("\r\n");
        foreach (var row in rows)
        {
            builder.AppendJoin(';', row.Select(Cell)).Append("\r\n");
        }
        return builder.ToString();
    }

    /// <summary>One CSV cell: formula prefixes neutralized by a leading apostrophe, quotes doubled, quoted when needed.</summary>
    public static string Cell(string? value)
    {
        var text = value ?? "";
        if (text.Length > 0 && text[0] is '=' or '+' or '-' or '@' or '\t' or '\r')
        {
            text = "'" + text;
        }
        return text.IndexOfAny([';', '"', '\r', '\n']) >= 0 ? "\"" + text.Replace("\"", "\"\"", StringComparison.Ordinal) + "\"" : text;
    }

    /// <summary>Writes the CSV under a new dated name (Domenia-&lt;topic&gt;-AAAAMMJJ-HHmmss.csv); prepared only when nothing may be written.</summary>
    public async Task<SyncExport> SaveAsync(string topic, string csv, int rows, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(topic);
        ArgumentNullException.ThrowIfNull(csv);
        var bytes = Utf8Bom.GetPreamble().Concat(Utf8Bom.GetBytes(csv)).ToArray();
        if (bytes.Length > MaxBytes)
        {
            throw new DomeniaOperationException("synchro.exportTooLarge", "Export trop volumineux (plus de 16 Mo) : affinez la recherche, rien n’a été écrit.");
        }
        var sha = Convert.ToHexStringLower(SHA256.HashData(bytes));
        var stamp = TimeZoneInfo.ConvertTime(context.Clock.GetUtcNow(), context.Clock.LocalTimeZone).ToString("yyyyMMdd'-'HHmmss", CultureInfo.InvariantCulture);
        var name = "Domenia-" + topic + "-" + stamp + ".csv";
        if (Folder is null)
        {
            return new SyncExport(false, null, name, rows, sha, "Export préparé, non écrit" + FrenchText.Colon + "ce mode garde tout en mémoire (capture, E2E ou sans dossier de données).");
        }
        var temporary = "";
        try
        {
            var folder = Directory.CreateDirectory(Folder);
            if (folder.LinkTarget is not null)
            {
                throw new DomeniaOperationException("synchro.exportRefused", "Dossier des exports remplacé par un lien" + FrenchText.Colon + "rien n’a été écrit.");
            }
            var target = Path.Combine(Folder, name);
            for (var n = 2; File.Exists(target); n++)
            {
                target = Path.Combine(Folder, Path.GetFileNameWithoutExtension(name) + "-" + n.ToString(CultureInfo.InvariantCulture) + ".csv");
            }
            temporary = Path.Combine(Folder, ".domenia-" + Guid.NewGuid().ToString("N") + ".tmp");
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }
            File.Move(temporary, target, overwrite: false);
            temporary = "";
            return new SyncExport(true, target, Path.GetFileName(target), rows, sha, "Export enregistré dans " + target + ", jamais remplacé.");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Export CSV de la synchronisation non écrit ({ex.GetType().Name}).");
            throw new DomeniaOperationException("synchro.exportFailed", "Export non écrit (disque plein, droits ou fichier verrouillé)" + FrenchText.Colon + "rien n’a été remplacé.");
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
                    context.Log.Warning($"Fichier temporaire d’export non supprimé ({ex.GetType().Name}).");
                }
            }
        }
    }
}
