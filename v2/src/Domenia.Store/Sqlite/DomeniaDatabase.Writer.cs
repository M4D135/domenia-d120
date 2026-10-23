using System.Collections.Concurrent;
using System.Text.Json;
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
    internal Func<long>? FreeSpaceProbe { get; set; }
    private sealed class StorageSpaceException(string message) : IOException(message) { }
    private const long WriterReserveBytes = 32L * 1024 * 1024;
    private const long MaxHeldBytes = 256L * 1024 * 1024;

    private async Task<T> ObserveWriteAsync<T>(string label, object payload, bool retain, Func<CancellationToken, Task<T>> send, CancellationToken token)
    {
        var raw = JsonSerializer.SerializeToUtf8Bytes(payload, Json);
        var bytes = raw.LongLength;
        var payloadHash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(raw));
        var health = Health;
        lock (health.Gate)
        {
            if (health.Suspended) { throw new IOException("Enregistrements locaux suspendus ; utilisez la reprise explicite après contrôle du disque et des données en attente."); }
            health.Waiting++; health.WaitingBytes += bytes; health.Version++;
        }
        try { await health.Sending.WaitAsync(token).ConfigureAwait(false); }
        catch
        {
            lock (health.Gate) { health.Waiting--; health.WaitingBytes -= bytes; health.Version++; }
            throw;
        }
        string? before = null;
        var sendStarted = false;
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
            var result = await send(token).ConfigureAwait(false);
            lock (health.Gate) { health.Failures = 0; health.SavedAt = clock.GetUtcNow(); health.Fault = null; health.Version++; }
            return result;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Only a refusal before invoking the writer supplies a reliable initial state. Other faults retain data for examination only.
            if (retain && !sendStarted) { before = await TryWriteSnapshotAsync(token).ConfigureAwait(false); }
            lock (health.Gate)
            {
                health.Failures++; health.Conflicts += ex is SqliteStoreException { Busy: true } ? 1 : 0;
                health.Suspended |= ex is StorageSpaceException || health.Failures >= 3;
                health.Fault = ex is StorageSpaceException ? ex.Message : "Enregistrement local échoué : " + ex.Message;
                if (retain && !health.Held.Any(x => x.Label == label && x.PayloadHash == payloadHash && x.Before == (before ?? "")))
                {
                    if (health.Held.Count >= 32 || health.Held.Sum(x => x.Bytes) + bytes > MaxHeldBytes)
                    { health.Suspended = true; health.Fault += " File mémoire pleine ; ce lot n’y a pas été ajouté."; }
                    else { health.Held.Add(new(WritePlans.NewId(), label, bytes, payloadHash, before ?? "", async ct =>
                    {
                        var currentHash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(payload, Json)));
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
            lock (health.Gate) { health.Active = false; health.ActiveBytes = 0; health.Version++; }
            health.Sending.Release();
        }
    }

    private async Task<string?> TryWriteSnapshotAsync(CancellationToken token)
    {
        if (!File.Exists(Path)) { return null; }
        try { return await Task.Run(() => ReadWriteSnapshot(token), token).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException) { return null; }
    }
    private string ReadWriteSnapshot(CancellationToken token)
    {
        using var db = new SqliteDatabase(Path, true, cancellationToken: token);
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
                health.WaitingBytes + health.Held.Sum(x => x.Bytes));
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
