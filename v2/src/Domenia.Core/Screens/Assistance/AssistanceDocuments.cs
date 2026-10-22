using System.Text;

namespace Domenia.Core;

/// <summary>
/// Documents of the Assistance screen (docs/ops/assistance.md § 7) over the document store of the mode
/// (<see cref="EngineContext.Documents"/>): captures, support dossiers and ticket reports, one at a time (Domenia 1 ASS-001 « un
/// document à la fois »), 30 seconds at most, 1 Mio at most each; the offline dossier, one at a time as well (Domenia 1
/// Test-DomeniaOfflineDossierRunning). The names written during the session are remembered: only they can be shown in Windows
/// Explorer afterwards. Never the directory, never a workstation. One instance per engine context (<see cref="From"/>), thread
/// safe.
/// </summary>
public sealed class AssistanceDocuments
{
    public const int MaxDocumentBytes = 1_048_576;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);
    private readonly IDocumentStore store;
    private readonly TimeProvider clock;
    private readonly TimeSpan timeout;
    private readonly Lock gate = new();
    private readonly HashSet<string> written = new(StringComparer.OrdinalIgnoreCase);
    private int documentBusy;
    private int dossierBusy;

    /// <param name="timeout">Longest write of a document (30 seconds; tests pass a shorter one).</param>
    public AssistanceDocuments(IDocumentStore store, TimeProvider clock, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(clock);
        this.store = store;
        this.clock = clock;
        this.timeout = timeout ?? Timeout;
    }

    public static AssistanceDocuments From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new AssistanceDocuments(c.Documents, c.Clock));
    }

    /// <summary>True when documents are written on the disk (false in capture or E2E mode, or without a data folder).</summary>
    public bool Persistent => store.Persistent;

    /// <summary>Where the documents go, for the operator.</summary>
    public string Label => store.Folder is { } folder
        ? "Documents enregistrés dans " + folder + ", jamais remplacés."
        : "Mode capture, E2E ou sans dossier de données" + FrenchText.Colon + "les documents restent en mémoire, rien n’est écrit sur le disque.";

    /// <summary>Local date of a file name: « 20261022-031912 ».</summary>
    public string Stamp(DateTimeOffset at) => AssistanceText.FileStamp(at, clock.LocalTimeZone);

    /// <summary>
    /// Writes a new text document (UTF-8 without BOM). Refused while another document is being written
    /// (<see cref="AssistanceErrors.DocumentBusy"/>), beyond 1 Mio (<see cref="AssistanceErrors.ExportTooLarge"/>), after 30 seconds
    /// (<see cref="AssistanceErrors.DocumentTimeout"/>) or when the disk refuses (<see cref="AssistanceErrors.ExportFailed"/>); nothing
    /// is ever replaced. In memory modes the result says it was not written and keeps the fingerprint.
    /// </summary>
    public async Task<ExportResult> SaveTextAsync(string name, string text, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        var bytes = Utf8.GetBytes(text);
        if (bytes.Length > MaxDocumentBytes)
        {
            throw new DomeniaOperationException(AssistanceErrors.ExportTooLarge, AssistanceErrors.ExportTooLargeMessage);
        }
        if (Interlocked.CompareExchange(ref documentBusy, 1, 0) != 0)
        {
            throw new DomeniaOperationException(AssistanceErrors.DocumentBusy, AssistanceErrors.DocumentBusyMessage);
        }
        try
        {
            var sha = TicketReport.Hash(text);
            var at = clock.GetUtcNow();
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            limit.CancelAfter(timeout);
            SavedDocument saved;
            try
            {
                saved = await store.SaveFileAsync(name, bytes, limit.Token).ConfigureAwait(false);
            }
            catch (DocumentStoreException ex)
            {
                throw new DomeniaOperationException(AssistanceErrors.ExportFailed, "Document non enregistré" + FrenchText.Colon + ex.Reason + " Rien n’a été remplacé.");
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new DomeniaOperationException(AssistanceErrors.DocumentTimeout, AssistanceErrors.DocumentTimeoutMessage);
            }
            if (!saved.Saved)
            {
                return new ExportResult(false, null, saved.Name, null, sha, bytes.Length, "Document préparé, non écrit" + FrenchText.Colon + "ce mode garde tout en mémoire.", at);
            }
            Remember(saved.Name);
            return new ExportResult(true, saved.Path, saved.Name, saved.Folder, sha, bytes.Length, "Document enregistré" + FrenchText.Colon + saved.Name, at);
        }
        finally
        {
            Volatile.Write(ref documentBusy, 0);
        }
    }

    /// <summary>Runs the preparation of one offline dossier; a second one is refused while it runs (<see cref="AssistanceErrors.DossierBusy"/>).</summary>
    public async Task<DossierResult> DossierAsync(Func<Task<DossierResult>> prepare)
    {
        ArgumentNullException.ThrowIfNull(prepare);
        if (Interlocked.CompareExchange(ref dossierBusy, 1, 0) != 0)
        {
            throw new DomeniaOperationException(AssistanceErrors.DossierBusy, AssistanceErrors.DossierBusyMessage);
        }
        try
        {
            var result = await prepare().ConfigureAwait(false);
            if (result.Saved)
            {
                Remember(result.Name);
            }
            return result;
        }
        finally
        {
            Volatile.Write(ref dossierBusy, 0);
        }
    }

    /// <summary>
    /// Shows in Windows Explorer a document written during this session (Domenia 1 Show-DomeniaPageBanner -ActionPath). Any
    /// other name, or a document that no longer exists, is refused (<see cref="AssistanceErrors.ExportMissing"/>).
    /// </summary>
    public async Task<bool> RevealAsync(string name, CancellationToken cancellationToken)
    {
        bool known;
        lock (gate)
        {
            known = written.Contains(name);
        }
        if (!known || !await store.RevealAsync(name, cancellationToken).ConfigureAwait(false))
        {
            throw new DomeniaOperationException(AssistanceErrors.ExportMissing, AssistanceErrors.ExportMissingMessage);
        }
        return true;
    }

    /// <summary>The document store of the screen (the offline dossier writes its folder through it).</summary>
    public IDocumentStore Store => store;

    private void Remember(string name)
    {
        lock (gate)
        {
            written.Add(name);
        }
    }
}
