using System.Collections.Immutable;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>
/// Preferences of the interface kept by the engine (shell.interface.get, docs/ops/shell.md): the presentation choices
/// (theme, motion, menu…), the remembered layouts of the lists and panels, the layouts of the boards and the favourite OUs of
/// the domain of the session. Never a row of data, never a secret.
/// </summary>
/// <param name="Persistent">False when the values live for this session only (capture, E2E, no data folder).</param>
/// <param name="Interface">Normalized presentation choices (closed list of fields, bounded values).</param>
/// <param name="Layouts">Layouts of the lists and panels, by key (column order and widths, panel widths).</param>
/// <param name="Boards">Layouts of the boards, by board name (versioned document with its previous versions).</param>
/// <param name="OuFavourites">Favourite OUs of the domain of the session, in their order; never the domain root.</param>
/// <param name="Warning">Sentence for the operator when the last change could not be written (it holds for the session).</param>
public sealed record ShellInterfaceSnapshot(
    bool Persistent,
    JsonElement Interface,
    JsonElement Layouts,
    JsonElement Boards,
    ImmutableArray<string> OuFavourites,
    string? Warning);

/// <summary>Write receipts as the activity button counts them.</summary>
/// <param name="Available">False when the receipts cannot be read for now (file locked, access denied).</param>
public sealed record ShellReceiptCounts(bool Available, int Total, int Pending, int Unreadable);

/// <summary>One line of the operations journal of the session.</summary>
public sealed record ShellJournalLine(DateTimeOffset At, string Label, Tone Tone);

/// <summary>
/// Activity of the session for the « Opérations » button of the top bar (Domenia 1 TRV-049, TRV-053): reads in progress or
/// waiting, receipts still to check, and the latest lines of the operations journal. Local only.
/// </summary>
/// <param name="Active">Reads in progress and waiting, plus receipts to check: the number on the counter.</param>
/// <param name="CounterText">Text of the counter: empty at zero, the number up to 99, then « 99+ ».</param>
/// <param name="Detail">One sentence for the tooltip of the button.</param>
public sealed record ShellActivity(
    TaskCounters Tasks,
    ShellReceiptCounts Receipts,
    int Active,
    string CounterText,
    string Detail,
    ImmutableArray<ShellJournalLine> Journal,
    DateTimeOffset At);

/// <summary>Kinds of objects the embedded picker can look for (Domenia 1 TRV-243).</summary>
public enum ShellLookupKind
{
    User,
    Computer,
    Ou,
}

/// <summary>One object found by the embedded picker.</summary>
/// <param name="Detail">Account, principal name or DNS name: what tells two objects of the same name apart.</param>
/// <param name="Path">Readable path of its container (« example.local › Utilisateurs › Lyon »).</param>
/// <param name="Enabled">False for a disabled account; always true for an OU.</param>
public sealed record ShellLookupItem(
    ShellLookupKind Kind,
    string KindLabel,
    string Name,
    string Dn,
    string ObjectGuid,
    string? Detail,
    string Path,
    bool Enabled);

/// <summary>Result of shell.lookup: at most 100 objects, in the order kind then name.</summary>
public sealed record ShellLookupResult(ImmutableArray<ShellLookupItem> Items, int Total, bool Truncated, string Summary);

/// <summary>
/// Check of a picked object before it is handed to a form (Domenia 1: « choisir revérifie le DN et le GUID »).
/// </summary>
/// <param name="State">« ok », « moved » (same GUID, other DN), « missing » or « denied » (refused for this account).</param>
public sealed record ShellLookupCheck(string State, string Message, ShellLookupItem? Item);

/// <summary>One category of objects the demonstration directory must hold (Domenia 1 TRV-047).</summary>
public sealed record ShellDemoFixture(string Id, string Label, int Count, bool Present, string Detail);

/// <summary>What the fictitious directory of the simulation holds, checked category by category.</summary>
public sealed record ShellDemoCoverage(bool Available, string Mode, ImmutableArray<ShellDemoFixture> Fixtures, int Present, int Total, string Summary);

/// <summary>Perimeter of a command of the local automation contract: exactly one kind, or none for the global commands.</summary>
public sealed record AutomationPerimeter(string Kind, string? OrganizationalUnit, ImmutableArray<string> Computers, ImmutableArray<string> Guids);

/// <summary>A command line of the automation contract, once validated.</summary>
public sealed record AutomationRequest(string Command, string Format, AutomationPerimeter Perimeter, int Limit);

/// <summary>One workstation of a « postes » answer (no secret, no internal field).</summary>
public sealed record AutomationComputerRow(
    string Name,
    string? DnsHostName,
    string Guid,
    string Dn,
    bool Enabled,
    string? OperatingSystem,
    DateTimeOffset? LastLogon);

/// <summary>A command of the contract.</summary>
public sealed record AutomationCommand(string Name, string Kind, string Description, bool Perimeter, ImmutableArray<string> Formats);

/// <summary>An exit code of the command line.</summary>
public sealed record AutomationExitCode(int Code, string Name, string Meaning);

/// <summary>Bounds of one command; a bound reached is always reported, never hidden.</summary>
public sealed record AutomationLimits(int DefaultRows, int MaxRows, int MaxNames, int MaxOuLength);

/// <summary>An option of the command line: its name as typed, what it means, an example value.</summary>
public sealed record AutomationOption(string Name, string Meaning, string Example);

/// <summary>The local automation contract (Domenia 1 TRV-067): versioned commands, bounds, exit codes and options.</summary>
public sealed record AutomationContract(
    string Contract,
    int Version,
    string Transport,
    ImmutableArray<AutomationCommand> Commands,
    ImmutableArray<AutomationExitCode> ExitCodes,
    AutomationLimits Limits,
    ImmutableArray<string> Rules,
    ImmutableArray<AutomationOption> Options);

/// <summary>
/// Check of a command line of the contract, with the answer it would give when the local data can serve it
/// (shell.automation.preview).
/// </summary>
public sealed record AutomationPreview(
    bool Valid,
    int ExitCode,
    string? Error,
    AutomationRequest? Request,
    string? Output,
    string? OutputFormat,
    int Rows,
    bool Truncated,
    string Summary);
