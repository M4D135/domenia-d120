using System.Collections.Immutable;

namespace Domenia.Core.Poste;

/// <summary>State of the secure window of the host, as the page reads it (never the value).</summary>
public sealed record SecretWindowState(bool Open, bool Masked, string? Kind, string? Computer, string? Identifier, DateTimeOffset? Until, int ExtensionsLeft, string Text);

/// <summary>
/// The secure window of the host (Domenia.App): a native window above the main one that shows ONE secret for 30 s, extended
/// once, masked when it loses the focus (shown again by a click, without a new read), wiped at the deadline or on « Masquer »,
/// with a protected copy (excluded from the clipboard history and the cloud clipboard, emptied after 30 s only if the
/// clipboard still holds the value). The value never reaches the page, a response, a journal, a receipt or an export. Found
/// by the composition like a screen reader; absent from the tests and the browser preview, where a reveal is refused before
/// anything is read.
/// </summary>
public interface IPosteSecretWindow : IScreenReader
{
    /// <summary>Shows one secret (replacing the one shown, which is wiped). <paramref name="note"/> journals a copy (identifier only).</summary>
    Task<SecretShown> ShowAsync(SecretReading secret, Action<string> note, CancellationToken cancellationToken);

    /// <summary>Closes the window and wipes the value (page changed view or workstation, « Masquer »).</summary>
    Task<bool> HideAsync(CancellationToken cancellationToken);

    /// <summary>Whether a value is shown, masked or gone (the page follows the deadline with it).</summary>
    SecretWindowState State();
}

/// <summary>A Windows tool asked for one workstation (Domenia 1 Invoke-ComputerTool).</summary>
public sealed record ToolRequest(string Tool, string Host, string? OperationsAccount, bool Simulated);

/// <summary>A suite tool asked with the context of the workstation (Domenia 1 Open-DomeniaSuiteTool).</summary>
public sealed record SuiteRequest(string Tool, string Label, string? Path, string? Sha256, ImmutableDictionary<string, string?> Context, bool Simulated);

/// <summary>What the host launcher did: launched or not, the exact command (no password ever), and why.</summary>
public sealed record ToolLaunch(bool Launched, bool Simulated, string Tool, string Label, string Command, string Text, ImmutableArray<string> Checks);

/// <summary>
/// The launcher of the administration workstation (Domenia.App): Remote Desktop, Explorer on C$ (with the operations account
/// asked by the Windows credential prompt, the password handed to the Windows API only), Computer Management, Event Viewer,
/// Services, and the suite tools after their contract and fingerprint are checked. No shell, no argument read from the page
/// other than the validated host name; nothing is launched in simulation (fictitious workstations).
/// </summary>
public interface IPosteToolLauncher : IScreenReader
{
    Task<ToolLaunch> OpenToolAsync(ToolRequest request, CancellationToken cancellationToken);

    Task<ToolLaunch> OpenSuiteAsync(SuiteRequest request, CancellationToken cancellationToken);
}

/// <summary>One CSV file of an export: its part (« lignes », « sources », « liste ») and its text (UTF-8 with BOM on disk).</summary>
public sealed record ExportFile(string Part, string Csv);

/// <summary>
/// An export asked by the page (Domenia 1 Export-DomeniaInventory, Export-DomeniaSoftware, Export-DomeniaWmi): the file name
/// proposed (« Domenia-PC-PAR-0001-inventaire-20261022-1415.csv », named after the workstation that answered), and one or
/// two files; the second is written next to the first with its part as a suffix.
/// </summary>
public sealed record ExportRequest(string SuggestedName, ImmutableArray<ExportFile> Files);

/// <summary>What the save did: saved or not (cancelled), the file names written (never their folder in a journal), and why.</summary>
public sealed record PosteExportResult(bool Saved, ImmutableArray<string> Names, string Text);

/// <summary>
/// The « Enregistrer sous » of the host (Domenia.App): the Windows save dialog, the operator chooses the folder and the
/// name, the files are written in UTF-8 with BOM. Found like a screen reader; absent from the tests and the browser
/// preview, where the page copies the CSV to the clipboard instead.
/// </summary>
public interface IPosteFileExport : IScreenReader
{
    Task<PosteExportResult> SaveAsync(ExportRequest request, CancellationToken cancellationToken);
}
