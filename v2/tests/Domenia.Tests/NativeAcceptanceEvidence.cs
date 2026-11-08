using System.Security.Cryptography;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>Append-only recipe evidence; no result is promoted to functional acceptance.</summary>
internal sealed class NativeAcceptanceEvidence : IDisposable
{
    internal const int MaximumEventBytes = 2 * 1024 * 1024;
    internal const long MaximumBytes = 64L * 1024 * 1024;
    private const int TerminalReserve = 4096;
    private static readonly JsonSerializerOptions Compact = new(NativeAcceptanceManifest.Json) { WriteIndented = false };
    private readonly FileStream stream;
    private readonly TimeProvider clock;
    private readonly NativeAcceptanceReadSelection? selection;
    private readonly HashSet<string> readsStarted = new(StringComparer.Ordinal);
    private int sequence;
    private bool terminal;
    private string? lastOperation;

    internal NativeAcceptanceEvidence(string path, TimeProvider? clock = null, NativeAcceptanceReadSelection? selection = null)
    {
        if (selection is not null) { NativeAcceptanceReadSelection.Validate(selection.Selected); }
        this.selection = selection;
        this.clock = clock ?? TimeProvider.System;
        // ReadWrite permits the digest to be measured through this same exclusively owned handle.
        stream = new(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read, 4096, FileOptions.WriteThrough);
    }

    internal int Errors { get; private set; }
    internal Func<CancellationToken, Task>? BeforeRead { get; set; }
    internal void Save(string operation, object value) => Append(operation, value, final: false);

    private void Append(string operation, object value, bool final)
    {
        if (terminal) { throw new InvalidOperationException("Journal de recette déjà terminé."); }
        if (operation is not { Length: > 0 and <= 128 } || operation.Any(char.IsControl))
        { throw new InvalidDataException("Nom d’opération de recette invalide."); }
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { sequence = sequence + 1, at = clock.GetUtcNow(), operation, value }, Compact);
        var limit = final ? TerminalReserve : MaximumEventBytes;
        if (bytes.Length + 1 > limit || sequence >= (final ? 129 : 128)
            || stream.Length + bytes.Length + 1 > MaximumBytes - (final ? 0 : TerminalReserve))
        { throw new InvalidDataException("Limite du journal de recette atteinte ; preuves antérieures conservées."); }
        // Serialize and check the complete event before appending. A torn final line after an OS interruption
        // remains evidence of interruption; there is no repair, truncation, or automatic replay.
        stream.Write(bytes); stream.WriteByte((byte)'\n'); stream.Flush(true);
        sequence++; lastOperation = operation; terminal = final;
    }

    internal void Finish(bool canaryRequested)
    {
        if (selection is not null && (!readsStarted.SetEquals(selection.Selected) || canaryRequested != selection.CanaryRequested))
        { throw new InvalidDataException("Sélection native incomplète ou consentement différent ; aucune fin réussie déduite."); }
        Append("finished", new
        {
            state = Errors == 0 ? "ProtocolCompleted" : "ProtocolCompletedWithErrors",
            errors = Errors, canaryRequested, qualified = false,
            reason = "Retours bruts à examiner ; aucun succès métier déduit du protocole. Replis SYSTEM/PsExec non sollicités."
        }, final: true);
    }

    internal void Abort(Exception exception) => Append("aborted", new
    {
        state = "Aborted", qualified = false, lastOperation, errors = Errors,
        type = exception.GetType().Name, code = (exception as DomeniaOperationException)?.Code,
        reason = "État à examiner dans les preuves et les reçus durables ; aucun rejeu ni compensation automatique."
    }, final: true);

    internal (long Bytes, string Sha256) Measure()
    {
        stream.Flush(true);
        var position = stream.Position;
        try
        {
            stream.Position = 0;
            return (stream.Length, Convert.ToHexStringLower(SHA256.HashData(stream)));
        }
        finally { stream.Position = position; }
    }

    internal async Task Read<T>(string operation, Func<CancellationToken, Task<T>> call)
    {
        if (selection is not null && (!selection.Selected.Contains(operation, StringComparer.Ordinal) || readsStarted.Contains(operation)))
        { throw new InvalidDataException("Lecture native hors sélection ou répétée ; aucun contact."); }
        var guard = BeforeRead ?? throw new InvalidOperationException("Qualification des identités obligatoire avant une lecture native.");
        Save(operation + ".started", new { state = "Started", qualified = false });
        readsStarted.Add(operation);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        // A failed identity guard stops the whole protocol, even when its exception is not an IOException.
        await guard(timeout.Token).ConfigureAwait(false);
        T result;
        try { result = await call(timeout.Token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is not (IOException or UnauthorizedAccessException))
        {
            Errors++;
            Save(operation, new { state = "Failed", qualified = false, type = ex.GetType().Name,
                code = (ex as DomeniaOperationException)?.Code });
            return;
        }
        await guard(timeout.Token).ConfigureAwait(false);
        Save(operation, new { state = "Returned", qualified = false, identitiesCheckedAfter = true, result });
    }

    public void Dispose() => stream.Dispose();
}
