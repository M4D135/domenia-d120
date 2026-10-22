using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>One file of the exports folder.</summary>
public sealed record ShellExportEntry(string FileName, long Size, DateTimeOffset At, string Kind);

/// <summary>Result of an export (Domenia 1 Export-DomeniaCsv and Show-DomeniaExportResult, TRV-054).</summary>
/// <param name="Folder">Readable place of the file (« %LOCALAPPDATA%\Domenia\Exports »), never a user name.</param>
/// <param name="Stored">« disque », or « mémoire » when this session keeps nothing on disk (capture, E2E).</param>
/// <param name="Message">Sentence for the operator: rows exported, file name, values masked or withheld.</param>
public sealed record ShellExportResult(string FileName, string Folder, int Rows, int Masked, ImmutableArray<string> Withheld, string Stored, string Message);

/// <summary>Files of the exports folder, most recent first.</summary>
public sealed record ShellExportListing(string Folder, string Stored, ImmutableArray<ShellExportEntry> Items);

/// <summary>One entry of the embedded file picker (Domenia 1 TRV-244).</summary>
/// <param name="Kind">« folder », « file » or « root » (a starting place).</param>
public sealed record ShellFileEntry(string Name, string Path, string Kind, long? Size, DateTimeOffset? At);

/// <summary>A folder as the embedded file picker shows it; <see cref="Folder"/> is null for the list of starting places.</summary>
public sealed record ShellFolderListing(string? Folder, string? Label, string? Parent, ImmutableArray<ShellFileEntry> Entries, bool Truncated, string? Note);

/// <summary>A file read for an import: a CSV table (delimiter found) or a JSON text.</summary>
public sealed record ShellFileContent(
    string FileName,
    string Kind,
    string? Delimiter,
    ImmutableArray<string> Headers,
    ImmutableArray<ImmutableArray<string>> Rows,
    int Total,
    bool Truncated,
    string? Text);

/// <summary>Chapter of a guide and whether its PDF was found (and opened).</summary>
public sealed record ShellGuide(string Page, string Guide, string GuideTitle, int Chapter, string Title, string Text, string File, bool Found, bool Opened, string Message);

/// <summary>A fact of the « À propos » panel.</summary>
public sealed record ShellFact(string Label, string Value, Tone Tone);

/// <summary>
/// « À propos de Domenia » (Domenia 1 TRV-052): version, runtimes and the local facts of the workstation, read once per session
/// (registry, version of winsqlite3.dll), never the network.
/// </summary>
public sealed record ShellAbout(
    string Name,
    string Version,
    string Runtime,
    string WebViewRuntime,
    string Mode,
    string ModeLabel,
    string Compatibility,
    Tone CompatibilityTone,
    ImmutableArray<ShellFact> Facts);

/// <summary>
/// Where the exports of the session go (TRV-054): the Exports folder of the data folder, or memory when the session keeps
/// nothing on disk. Never overwrites a file: a second export of the same minute gets a numbered name.
/// </summary>
public interface IShellExportStore
{
    /// <summary>False when the exports live in memory for this session only.</summary>
    bool Persistent { get; }

    /// <summary>Readable place of the folder, without the user name.</summary>
    string FolderLabel { get; }

    /// <summary>Writes the content under a free name derived from <paramref name="fileName"/>; returns the name written.</summary>
    Task<string> SaveAsync(string fileName, ReadOnlyMemory<byte> content, CancellationToken cancellationToken);

    /// <summary>The exports, most recent first, at most <paramref name="max"/>.</summary>
    ImmutableArray<ShellExportEntry> List(int max);
}

/// <summary>Exports kept in memory for the session (capture, E2E, no data folder): nothing is written on disk.</summary>
public sealed class MemoryExportStore(TimeProvider clock) : IShellExportStore
{
    private readonly TimeProvider clock = clock ?? throw new ArgumentNullException(nameof(clock));

    /// <summary>Exports kept at most; the oldest leaves first.</summary>
    public const int Capacity = 20;

    private readonly Lock gate = new();
    private readonly List<ShellExportEntry> entries = [];

    public bool Persistent => false;

    public string FolderLabel => "Mémoire de la session (rien n’est écrit sur le disque)";

    public Task<string> SaveAsync(string fileName, ReadOnlyMemory<byte> content, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(fileName);
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            var name = ShellExportNames.Free(fileName, n => entries.Any(e => string.Equals(e.FileName, n, StringComparison.OrdinalIgnoreCase)));
            entries.Insert(0, new ShellExportEntry(name, content.Length, clock.GetUtcNow(), ShellExportNames.KindOf(name)));
            if (entries.Count > Capacity)
            {
                entries.RemoveAt(entries.Count - 1);
            }
            return Task.FromResult(name);
        }
    }

    public ImmutableArray<ShellExportEntry> List(int max)
    {
        lock (gate)
        {
            return [.. entries.Take(Math.Max(0, max))];
        }
    }
}

/// <summary>Names of the exports: never an overwrite (« -2 », « -3 »…), kind from the extension.</summary>
public static class ShellExportNames
{
    /// <summary>The name, or the first « nom-N.ext » not taken.</summary>
    public static string Free(string fileName, Func<string, bool> taken)
    {
        ArgumentException.ThrowIfNullOrEmpty(fileName);
        ArgumentNullException.ThrowIfNull(taken);
        if (!taken(fileName))
        {
            return fileName;
        }
        var dot = fileName.LastIndexOf('.');
        var stem = dot > 0 ? fileName[..dot] : fileName;
        var extension = dot > 0 ? fileName[dot..] : "";
        for (var suffix = 2; suffix < 10_000; suffix++)
        {
            var candidate = stem + "-" + suffix.ToString(System.Globalization.CultureInfo.InvariantCulture) + extension;
            if (!taken(candidate))
            {
                return candidate;
            }
        }
        throw new IOException("No free export name.");
    }

    /// <summary>« csv », « json » or « autre ».</summary>
    public static string KindOf(string fileName)
    {
        ArgumentNullException.ThrowIfNull(fileName);
        return fileName.EndsWith(".csv", StringComparison.OrdinalIgnoreCase) ? "csv"
            : fileName.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ? "json"
            : "autre";
    }

    /// <summary>An export name the page may give back (open the folder on it): « Domenia-….csv » or « .json », no path.</summary>
    public static bool IsExportName(string? fileName) =>
        !string.IsNullOrEmpty(fileName) && fileName.Length <= 120
        && fileName.StartsWith("Domenia-", StringComparison.Ordinal)
        && (fileName.EndsWith(".csv", StringComparison.OrdinalIgnoreCase) || fileName.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
        && fileName.All(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.')
        && !fileName.Contains("..", StringComparison.Ordinal);
}
