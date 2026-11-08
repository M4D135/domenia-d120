using System.Collections.Concurrent;
using System.Text.Json;
using System.Runtime.ExceptionServices;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record HeldWrite(string Id, string Label, long Bytes, string PayloadHash, string Before, Func<CancellationToken, Task> Replay);
    private sealed class WriterHealth
    {
        internal readonly Lock Gate = new();
        internal readonly SemaphoreSlim Sending = new(1, 1);
        internal readonly List<HeldWrite> Held = [];
        internal int Waiting; internal long WaitingBytes; internal long ActiveBytes; internal bool Active; internal bool Suspended;
        internal int Failures; internal int Conflicts; internal long Version;
        internal string? Fault; internal DateTimeOffset? SavedAt;
        internal long? FreeBytes; internal DateTimeOffset? SpaceAt;
    }
    private static readonly ConcurrentDictionary<string, WriterHealth> WriterHealths = new(StringComparer.OrdinalIgnoreCase);
    private WriterHealth Health => WriterHealths.GetOrAdd(Path, _ => new());
    internal TimeSpan? WriterAcknowledgementBudget { get; set; }
    internal Action? WriteQueued { get; set; }
    internal Func<long>? FreeSpaceProbe { get; set; }
    private sealed class StorageSpaceException(string message) : IOException(message) { }
    // Only explicitly identified contract refusals before data mutation bypass disk health.
    // Corrupt stored data, I/O faults and uncertain results after mutation still suspend normally.
    private sealed class WriteValidationRefusal(Exception cause) : Exception(cause.Message, cause) { }
    private static void ValidateBeforeWrite(Action validation)
    {
        try { validation(); }
        catch (Exception ex) when (ex is ArgumentException or InvalidDataException or DomeniaOperationException)
        { throw new WriteValidationRefusal(ex); }
    }
    private static WriteValidationRefusal RefuseBeforeWrite(Exception cause) => new(cause);
    private const long WriterReserveBytes = 32L * 1024 * 1024;
    private const long MaxHeldBytes = 256L * 1024 * 1024;
    internal const int MaxPendingWrites = 32;
    internal const long MaxPendingWriteBytes = 512L * 1024 * 1024;

    private async Task<T> ObserveWriteAsync<T>(string label, object payload, bool retain, Func<CancellationToken, Task<T>> send, CancellationToken token, long? estimatedBytes = null)
    {
        using var measurements = operations is { } owner ? OperationsMeasurements.Enter(owner) : null;
        using var batchMeasurement = OperationRequests.MeasureStorage(RequestStorageKind.WriteBatch);
        if (retain && estimatedBytes is not null) { throw new ArgumentException("Un lot rejouable exige son contenu intégral.", nameof(estimatedBytes)); }
        token.ThrowIfCancellationRequested();
        var health = Health;
        // Reserve a slot before serialization. Rejected callers retain their own data; nothing is silently dropped or replayed.
        lock (health.Gate)
        {
            if (health.Suspended) throw new IOException("Enregistrements locaux suspendus ; utilisez la reprise explicite après contrôle du disque et des données en attente.");
            if (health.Waiting + (health.Active ? 1 : 0) + health.Held.Count >= MaxPendingWrites)
                throw new IOException("File locale pleine (32 lots) ; attendez les enregistrements en cours avant de relancer cette collecte.");
            health.Waiting++; health.Version++;
        }
        long bytes = 0;
        string payloadHash;
        try
        {
            if (estimatedBytes is < 0 or > MaxPendingWriteBytes) throw new InvalidDataException("Estimation du lot hors limites ; aucune écriture.");
            var digest = await Task.Run(() => StoragePayloadDigest.Of(payload, Json, MaxPendingWriteBytes, token), token).ConfigureAwait(false);
            var size = Math.Max(digest.Bytes, estimatedBytes ?? 0);
            payloadHash = digest.Sha256;
            lock (health.Gate)
            {
                if (size > MaxPendingWriteBytes - health.WaitingBytes - health.ActiveBytes - health.Held.Sum(x => x.Bytes))
                    throw new IOException("File locale supérieure à 512 Mio ; attendez sa vidange avant de relancer la collecte. Ce lot n’a pas été ajouté.");
                bytes = size; health.WaitingBytes += bytes; health.Version++;
            }
            WriteQueued?.Invoke();
            await health.Sending.WaitAsync(token).ConfigureAwait(false);
        }
        catch
        {
            lock (health.Gate) { health.Waiting--; health.WaitingBytes -= bytes; health.Version++; }
            throw;
        }
        string? before = null;
        var sendStarted = false;
        using var deadline = new CancellationTokenSource(WriterAcknowledgementBudget ?? TimeSpan.FromSeconds(Math.Max(120, backupTimeoutSeconds + 30)));
        using var sendingToken = CancellationTokenSource.CreateLinkedTokenSource(token, deadline.Token);
        using var watch = deadline.Token.Register(() =>
        {
            lock (health.Gate)
            {
                health.Suspended = true;
                health.Fault = "Résultat de sauvegarde non confirmé dans le délai : vérifiez la base. La tâche garde sa place jusqu’à sa fin réelle ; aucun autre envoi ni rejeu automatique.";
                health.Version++;
            }
        });
        try
        {
            lock (health.Gate)
            {
                health.Waiting--; health.WaitingBytes -= bytes; health.ActiveBytes = bytes; health.Active = true; health.Version++;
                if (health.Suspended) { throw new IOException("Écrivain suspendu pendant l’attente ; aucun nouvel enregistrement."); }
            }
            CheckWriterSpace(bytes);
            using var budget = StorageWriteBudgetScope.Enter(Path, () => CheckWriterSpace(bytes));
            sendStarted = true;
            var result = await send(sendingToken.Token).ConfigureAwait(false);
            watch.Dispose();
            if (deadline.IsCancellationRequested)
                throw new IOException("Résultat de sauvegarde reçu après le délai : vérifiez la base et son reçu avant toute reprise.");
            batchMeasurement?.Success();
            lock (health.Gate) { health.Failures = 0; health.SavedAt = clock.GetUtcNow(); health.Fault = health.Held.Count > 0 ? "Des lots antérieurs restent en mémoire pour examen ou reprise explicite ; ils ne sont pas rejoués automatiquement." : null; health.Version++; }
            return result;
        }
        catch (WriteValidationRefusal refusal)
        {
            ExceptionDispatchInfo.Capture(refusal.InnerException!).Throw();
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException
            || sendStarted && ex is not (OutOfMemoryException or StackOverflowException or AccessViolationException))
        {
            // Only a refusal before invoking the writer supplies a reliable initial state. Other faults retain data for examination only.
            if (retain && !sendStarted) { before = await TryWriteSnapshotAsync(token).ConfigureAwait(false); }
            lock (health.Gate)
            {
                health.Failures++; health.Conflicts += ex is SqliteStoreException { Busy: true } or StorageBusyException ? 1 : 0;
                health.Suspended |= ex is StorageSpaceException || health.Failures >= 3;
                health.Fault = ex is StorageSpaceException ? ex.Message : "Résultat de sauvegarde non confirmé : vérifiez la base. " + ex.Message;
                if (retain && !health.Held.Any(x => x.Label == label && x.PayloadHash == payloadHash && x.Before == (before ?? "")))
                {
                    if (health.Held.Count >= 32 || health.Held.Sum(x => x.Bytes) + bytes > MaxHeldBytes)
                    { health.Suspended = true; health.Fault += " File mémoire pleine ; ce lot n’y a pas été ajouté."; }
                    else { health.Held.Add(new(WritePlans.NewId(), label, bytes, payloadHash, before ?? "", async ct =>
                    {
                        var currentHash = StoragePayloadDigest.Of(payload, Json, MaxPendingWriteBytes, ct).Sha256;
                        if (currentHash != payloadHash) { throw WriteErrors.Refusal(WriteErrors.Stale, "Le contenu du lot retenu a changé ; aucun rejeu."); }
                        _ = await send(ct).ConfigureAwait(false);
                    })); }
                }
                if (retain && before is null) { health.Fault += " État initial non vérifiable : lot retenu pour examen, sans rejeu autorisé."; }
                health.Version++;
            }
            throw;
        }
        finally
        {
            watch.Dispose();
            lock (health.Gate) { health.Active = false; health.ActiveBytes = 0; health.Version++; }
            health.Sending.Release();
        }
    }

    private async Task<string?> TryWriteSnapshotAsync(CancellationToken token)
    {
        if (!File.Exists(Path)) { return null; }
        try { return await Task.Run(() => ReadWriteSnapshot(token), token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or OperationCanceledException) { return null; }
    }
    private string ReadWriteSnapshot(CancellationToken token)
    {
        using var db = Open(true, cancellationToken: token);
        db.Begin(false); CheckIdentity(db, true); return StorageWriteSnapshot.Read(db, token);
    }
    private void CheckWriterSpace(long incomingBytes)
    {
        var health = Health;
        long waiting;
        lock (health.Gate) { waiting = health.WaitingBytes + health.Held.Sum(x => x.Bytes); incomingBytes = Math.Max(incomingBytes, health.ActiveBytes); }
        var needed = checked(WriterReserveBytes + 4 * checked(Math.Max(0, incomingBytes) + waiting));
        var free = FreeSpaceProbe?.Invoke() ?? new DriveInfo(System.IO.Path.GetPathRoot(Path)!).AvailableFreeSpace;
        lock (health.Gate) { health.FreeBytes = free; health.SpaceAt = clock.GetUtcNow(); }
        if (free < needed)
        { throw new StorageSpaceException("Espace libre insuffisant : " + SettingsFormat.Size(free) + " mesurés, " + SettingsFormat.Size(needed) + " requis (32 Mio et quatre fois les lots entrants/en attente). Aucun envoi local."); }
    }
    private LocalStoreWriter ActualWriterState(bool unavailable)
    {
        var health = Health;
        lock (health.Gate)
        {
            return new(unavailable, health.Suspended, health.Active || writer.CurrentCount == 0, health.Waiting + health.Held.Count,
                health.Waiting + health.Held.Count, health.WaitingBytes + health.Held.Sum(x => x.Bytes), health.Failures, health.Conflicts,
                health.SavedAt, health.Fault is { } fault && health.Held.Count > 0 ? fault + " Lots conservés dans cette session ; reprise sous contrôle de leur base d’origine." : health.Fault) { ManualRetry = true };
        }
    }
    private LocalStoreSpace ActualWriterSpace(LocalStoreSpace measured)
    {
        var health = Health;
        lock (health.Gate)
        {
            return new(health.SpaceAt > measured.MeasuredAt || measured.MeasuredAt is null ? health.FreeBytes : measured.FreeBytes,
                health.SpaceAt > measured.MeasuredAt || measured.MeasuredAt is null ? health.SpaceAt : measured.MeasuredAt,
                health.WaitingBytes + health.ActiveBytes + health.Held.Sum(x => x.Bytes));
        }
    }
    private string WriterStateFingerprint()
    {
        var health = Health;
        lock (health.Gate)
        {
            return BackupPreferencesRules.Sha256(JsonSerializer.Serialize(new { StoreId, health.Version, health.Suspended, health.Active, health.Waiting, health.WaitingBytes,
                health.Failures, health.Conflicts, Held = health.Held.Select(x => new { x.Id, x.Label, x.Bytes, x.PayloadHash, x.Before }) }, Json));
        }
    }
}
