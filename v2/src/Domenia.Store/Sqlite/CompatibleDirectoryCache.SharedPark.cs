using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class CompatibleDirectoryCache : ISharedParkStore
{
    private readonly SemaphoreSlim sharedParkOperations = new(1, 1);
    private readonly Lock sharedParkGate = new();
    private readonly Dictionary<string, SharedParkLease> sharedParkLeases = new(StringComparer.Ordinal);
    private readonly string sharedParkSession = WritePlans.NewId();
    private long sharedParkGeneration;

    private sealed class SharedParkLease(SharedParkPreparedPreview preview, WritePlanOrigin origin, DomeniaDatabase database, long generation)
    {
        internal readonly SharedParkPreparedPreview Preview = preview;
        internal readonly WritePlanOrigin Origin = origin;
        internal readonly DomeniaDatabase Database = database;
        internal readonly long Generation = generation;
        internal bool Borrowed, Revoked, Consumed;
    }

    private sealed record SharedParkPaths(string Root, string Spool, string Backups, string Journal,
        ImmutableArray<string> Configs, ImmutableArray<string> Protected);

    public Task<string?> SharedParkPathAsync(CancellationToken cancellationToken) => Task.Run(() => ReadSharedParkPath(cancellationToken), cancellationToken);

    private string? ReadSharedParkPath(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var config = System.IO.Path.Combine(appFolder, "Domenia.config.json");
        ValidateLocalPath(config);
        try { _ = File.GetAttributes(config); }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return null; }
        // A held, bounded read cannot convert an access error into an absent configuration or grow past the bound after stat.
        using var file = File.Open(config, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length > 1_048_576) { throw new InvalidDataException("Configuration de stockage supérieure à 1 Mio."); }
        var bytes = new byte[checked((int)file.Length)]; file.ReadExactly(bytes);
        if (file.ReadByte() != -1) { throw new InvalidDataException("Configuration agrandie pendant sa lecture."); }
        using var json = System.Text.Json.JsonDocument.Parse(bytes);
        var section = Property(json.RootElement, "ParkSweep");
        var path = section is { } value ? String(value, "SharedPath") : null;
        token.ThrowIfCancellationRequested();
        return string.IsNullOrWhiteSpace(path) ? null : SharedParkFile.PathValue(path);
    }

    private string RequireSharedParkPath(CancellationToken token) => ReadSharedParkPath(token)
        ?? throw new DomeniaOperationException(SyncErrors.SharedNotConfigured, SyncErrors.SharedNotConfiguredMessage);

    public Task<SharedParkPreviewInfo> ReadSharedParkAsync(WritePlanOrigin origin, Action validateSource, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        ArgumentNullException.ThrowIfNull(origin); ArgumentNullException.ThrowIfNull(validateSource);
        if (origin.Epoch < 0 || string.IsNullOrWhiteSpace(origin.SessionKey)) { throw new InvalidDataException("Origine de partage absente."); }
        await sharedParkOperations.WaitAsync(cancellationToken).ConfigureAwait(false);
        SharedParkPreparedPreview? prepared = null;
        try
        {
            long generation;
            lock (sharedParkGate)
            {
                ExpireSharedParkLeases(); generation = sharedParkGeneration;
                if (sharedParkLeases.Count >= SharedParkPreviewFile.MaxActiveLeases) { throw new InvalidDataException("Au plus huit aperçus du partage peuvent être conservés."); }
            }
            void Guard()
            {
                cancellationToken.ThrowIfCancellationRequested(); validateSource();
                lock (sharedParkGate) { if (generation != sharedParkGeneration) { throw new InvalidDataException("Source du partage invalidée pendant la lecture."); } }
            }
            Guard(); var db = await DatabaseAsync(cancellationToken).ConfigureAwait(false); Guard();
            var path = RequireSharedParkPath(cancellationToken); Guard();
            var paths = SharedParkStoragePaths(db);
            SharedParkRemoteReader.Validate(path, db.Path, paths.Configs, paths.Protected.Add(paths.Backups).Add(paths.Journal), cancellationToken);
            using var spoolPins = SharedParkLocalPaths.Open(paths.Spool, paths.Root, true, cancellationToken); Guard();
            prepared = await db.PreviewSharedParkAsync(path, paths.Configs, paths.Protected.Add(paths.Backups).Add(paths.Journal), paths.Spool,
                sharedParkSession, origin.Epoch, cancellationToken, Guard).ConfigureAwait(false);
            Guard();
            if (!ReferenceEquals(cache?.Database, db) || RequireSharedParkPath(cancellationToken) != path)
            { throw new InvalidDataException("Stockage ou chemin partagé changé pendant la lecture."); }
            Guard();
            lock (sharedParkGate)
            {
                if (generation != sharedParkGeneration) { throw new InvalidDataException("Lecture abandonnée par la source."); }
                sharedParkLeases.Add(prepared.Reference.Id, new(prepared, origin, db, generation));
                var info = prepared.Info; prepared = null; return info;
            }
        }
        finally { prepared?.Dispose(); sharedParkOperations.Release(); }
    }, cancellationToken);

    // Draft is metadata-only: no configuration, share or SQLite access. The normal write circuit seals and confirms it.
    public async Task<WritePlanDraft> DraftSharedParkAsync(SharedParkBatch batch, WritePlanOrigin origin, CancellationToken cancellationToken)
    {
        await sharedParkOperations.WaitAsync(cancellationToken).ConfigureAwait(false);
        SharedParkLease? held = null;
        try { held = BorrowSharedPark(batch, origin, false); return held.Database.DraftSharedPark(held.Preview, origin); }
        finally { ReturnSharedPark(held, false); sharedParkOperations.Release(); }
    }

    public Task<WritePrecheck> CheckSharedParkAsync(SharedParkBatch batch, WritePlanOrigin origin, Action validateSource, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        ArgumentNullException.ThrowIfNull(validateSource);
        await sharedParkOperations.WaitAsync(cancellationToken).ConfigureAwait(false);
        SharedParkLease? held = null;
        try
        {
            held = BorrowSharedPark(batch, origin, false);
            var paths = SharedParkStoragePaths(held.Database);
            void Guard() => GuardSharedPark(held, validateSource, cancellationToken);
            Guard();
            return await held.Database.CheckSharedParkPreviewAsync(held.Preview, paths.Configs,
                paths.Protected.Add(paths.Backups).Add(paths.Journal), Guard, cancellationToken).ConfigureAwait(false);
        }
        catch (InvalidDataException ex) { return WritePrecheck.Stale(ex.Message); }
        finally { ReturnSharedPark(held, false); sharedParkOperations.Release(); }
    }, cancellationToken);

    public Task<WriteOutcome> ApplySharedParkAsync(SharedParkBatch batch, WritePlan plan, WritePlanOrigin origin, Action validateSource, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        ArgumentNullException.ThrowIfNull(validateSource);
        await sharedParkOperations.WaitAsync(cancellationToken).ConfigureAwait(false);
        SharedParkLease? held = null;
        try
        {
            held = BorrowSharedPark(batch, origin, true);
            var paths = SharedParkStoragePaths(held.Database);
            void Guard() => GuardSharedPark(held, validateSource, cancellationToken);
            Guard();
            SharedParkRemoteReader.Validate(batch.Path, held.Database.Path, paths.Configs,
                paths.Protected.Add(paths.Backups).Add(paths.Journal), cancellationToken);
            using var backupPins = SharedParkLocalPaths.Open(paths.Backups, paths.Root, true, cancellationToken); Guard();
            using var journalPins = SharedParkLocalPaths.Open(paths.Journal, paths.Root, true, cancellationToken); Guard();
            // The callback is the caller's actual maintenance generation. The retained origin remains the original preview origin;
            // no hidden global epoch is compared with it after the caller has reserved its new maintenance generation.
            var outcome = await held.Database.ApplySharedParkConfirmedAsync(held.Preview, plan, paths.Backups, paths.Journal,
                paths.Configs, paths.Protected, Guard, cancellationToken).ConfigureAwait(false);
            try { Guard(); }
            catch when (outcome.Result is WriteResult.Applied or WriteResult.Unknown)
            { return new WriteOutcome(WriteResult.Unknown, "Publication tentée puis source invalidée ; preuves conservées, vérification explicite requise."); }
            return outcome;
        }
        finally { ReturnSharedPark(held, true); sharedParkOperations.Release(); }
    }, cancellationToken);

    public Task<WriteVerification> VerifySharedParkAsync(WritePlan plan, CancellationToken cancellationToken) => Task.Run(async () =>
    {
        var db = await DatabaseAsync(cancellationToken).ConfigureAwait(false);
        var paths = SharedParkStoragePaths(db);
        // No lease is needed after restart, and no directory is created by verification. The journal names the original TSV.
        var result = await db.VerifySharedParkConfirmedAsync(plan, paths.Backups, paths.Journal, paths.Configs, paths.Protected, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return ReferenceEquals(cache?.Database, db) ? result
            : new WriteVerification(VerificationState.Unknown, "Le stockage actif a changé pendant la vérification.");
    }, cancellationToken);

    public void DiscardSharedPark(string batchId)
    {
        if (string.IsNullOrEmpty(batchId)) { return; }
        lock (sharedParkGate)
        {
            if (sharedParkLeases.Remove(batchId, out var held)) { RevokeSharedPark(held); }
        }
    }

    public void DiscardSharedParkPreviews()
    {
        lock (sharedParkGate)
        {
            sharedParkGeneration = unchecked(sharedParkGeneration + 1);
            foreach (var held in sharedParkLeases.Values) { RevokeSharedPark(held); }
            sharedParkLeases.Clear();
        }
    }

    private void GuardSharedPark(SharedParkLease held, Action validateSource, CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); validateSource();
        lock (sharedParkGate)
        {
            if (held.Revoked || held.Generation != sharedParkGeneration || !ReferenceEquals(cache?.Database, held.Database))
            { throw new InvalidDataException("Aperçu du partage abandonné ou stockage remplacé."); }
        }
        if (RequireSharedParkPath(token) != held.Preview.Reference.Path) { throw new InvalidDataException("Chemin partagé changé depuis l’aperçu."); }
        token.ThrowIfCancellationRequested(); validateSource();
        lock (sharedParkGate)
        { if (held.Revoked || held.Generation != sharedParkGeneration) { throw new InvalidDataException("Source du partage invalidée."); } }
    }

    private SharedParkLease BorrowSharedPark(SharedParkBatch batch, WritePlanOrigin origin, bool consume)
    {
        ArgumentNullException.ThrowIfNull(batch); ArgumentNullException.ThrowIfNull(origin);
        lock (sharedParkGate)
        {
            ExpireSharedParkLeases();
            if (!sharedParkLeases.TryGetValue(batch.Id, out var held) || held.Revoked || held.Consumed || held.Borrowed
                || held.Preview.Reference != batch || held.Origin != origin || !ReferenceEquals(cache?.Database, held.Database))
            { throw new InvalidDataException("Aperçu absent, expiré, consommé ou rattaché à une autre source ; relisez le partage."); }
            held.Borrowed = true; held.Consumed = consume; return held;
        }
    }

    private void ReturnSharedPark(SharedParkLease? held, bool consumed)
    {
        if (held is null) { return; }
        lock (sharedParkGate)
        {
            held.Borrowed = false;
            if (consumed || held.Revoked)
            { sharedParkLeases.Remove(held.Preview.Reference.Id); CloseSharedParkPreview(held.Preview); }
        }
    }

    private static void RevokeSharedPark(SharedParkLease held)
    { held.Revoked = true; if (!held.Borrowed) { CloseSharedParkPreview(held.Preview); } }

    // Disposal is never allowed to reclassify a remote publication or make source closure fail. The spool's own finally releases
    // its reservation even if closing the OS handle reports an error; only its owned DeleteOnClose file is involved.
    private static void CloseSharedParkPreview(SharedParkPreparedPreview preview)
    { try { preview.Dispose(); } catch (Exception) { } }

    private void ExpireSharedParkLeases()
    {
        foreach (var pair in sharedParkLeases.Where(p => p.Value.Preview.Reference.ExpiresAt <= clock.GetUtcNow()).ToArray())
        { sharedParkLeases.Remove(pair.Key); RevokeSharedPark(pair.Value); }
    }

    private SharedParkPaths SharedParkStoragePaths(DomeniaDatabase db)
    {
        var root = System.IO.Path.Combine(userFolder, isolated ? "SharedPark-Isolated" : "SharedPark", db.StoreId);
        // Parent directories owned by this feature are also private, including its per-store directory.
        var boundary = System.IO.Path.GetDirectoryName(root)!;
        var spool = System.IO.Path.Combine(root, "Preview"); var backups = System.IO.Path.Combine(root, "Backups"); var journal = System.IO.Path.Combine(root, "Intentions");
        var data = System.IO.Path.Combine(userFolder, "Data"); var portable = System.IO.Path.Combine(appFolder, "data");
        var dbParent = System.IO.Path.GetDirectoryName(db.Path)!;
        var configFolders = new[] { appFolder, data, portable, dbParent, System.IO.Path.Combine(data, "Preferences"), System.IO.Path.Combine(portable, "Preferences") };
        var configs = configFolders.SelectMany(folder => new[] { "Domenia.config.json", "Domenia.settings.json", "ADCC.settings.json" }
            .SelectMany(name => new[] { System.IO.Path.Combine(folder, name), System.IO.Path.Combine(folder, name) + ".bak" }))
            .Append(SwitchFile).Distinct(StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        ImmutableArray<string> protectedDirectories = [spool, System.IO.Path.Combine(appFolder, "dev"), System.IO.Path.Combine(dbParent, "Backups"),
            System.IO.Path.Combine(data, "Preferences"), System.IO.Path.Combine(portable, "Preferences"), System.IO.Path.GetDirectoryName(SwitchFile)!];
        return new(boundary, spool, backups, journal, configs, protectedDirectories);
    }
}
