using System.ComponentModel;
using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.App;

internal sealed record PackageHealthRequest(int Format, string Target, string Transaction, string TransactionDirectory,
    string ManifestSha256, string JournalSha256, string Nonce, string Attempt);
internal sealed record PackageHealthReceipt(int Format, string Transaction, string ManifestSha256, string Nonce,
    int ProcessId, string Build, string BrowserVersion, bool DocumentLoaded, bool ScriptReady);

/// <summary>A failed private health child may permit rollback only after its real termination was observed.</summary>
internal sealed class PackageHealthException(string message, bool childExited, Exception? inner = null) : IOException(message, inner)
{
    internal bool ChildExited { get; } = childExited;
}

internal sealed partial class PackageLifecycle
{
    private const int HealthAttempts = 4;

    private void VerifyHealth(string target, string transaction, Transaction journal, string expected, CancellationToken token)
    {
        var check = HealthCheck ?? throw new InvalidDataException("Assistant de santé absent ; transaction conservée en attente.");
        using var paths = new PackageLifecycleFiles();
        var folder = Path.Combine(transaction, "health"); paths.PrivateDirectory(folder); ValidateHealthFolder(paths, folder);
        var number = Enumerable.Range(1, HealthAttempts).FirstOrDefault(n => !PackageLifecycleFiles.Exists(Path.Combine(folder, $"attempt-{n}.json")));
        if (number == 0) { throw new IOException("Quatre contrôles de santé conservés ; archivez explicitement les preuves avant une nouvelle tentative."); }
        var nonce = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        var request = new PackageHealthRequest(1, target, journal.Id, transaction, expected,
            PackageLifecycleFiles.Measure(transaction, JournalName).Sha256, nonce, number.ToString(System.Globalization.CultureInfo.InvariantCulture));
        var nonceHash = Convert.ToHexStringLower(SHA256.HashData(Convert.FromHexString(nonce)));
        PackageLifecycleFiles.WriteNew(Path.Combine(folder, $"attempt-{number}.json"), JsonSerializer.SerializeToUtf8Bytes(new
        { format = 1, transaction = journal.Id, manifestSha256 = expected, journalSha256 = request.JournalSha256, nonceSha256 = nonceHash, at = clock.GetUtcNow() }, Json));
        Checkpoint?.Invoke("health-starting");
        var receipt = check(request, token);
        var release = Release(target, Manifest(target));
        if (receipt is null || receipt.Format != 1 || receipt.Transaction != journal.Id || receipt.ManifestSha256 != expected
            || receipt.Nonce is not { Length: 64 } || !receipt.Nonce.All(Uri.IsHexDigit)
            || !CryptographicOperations.FixedTimeEquals(Convert.FromHexString(nonce), Convert.FromHexString(receipt.Nonce))
            || receipt.ProcessId <= 0 || !receipt.DocumentLoaded || !receipt.ScriptReady
            || string.IsNullOrWhiteSpace(receipt.BrowserVersion) || receipt.BrowserVersion.Length > 100 || receipt.BrowserVersion.Any(char.IsControl)
            || release is null || receipt.Build != release.Build)
        { throw new InvalidDataException("Accusé de santé absent, périmé ou incompatible ; aucune activation."); }
        // Store a hash of the one-use challenge, never an authorization that a later startup could replay.
        PackageLifecycleFiles.WriteNew(Path.Combine(folder, $"ack-{number}.json"), JsonSerializer.SerializeToUtf8Bytes(new
        { format = 1, transaction = journal.Id, manifestSha256 = expected, nonceSha256 = nonceHash, receipt.ProcessId,
            receipt.Build, receipt.BrowserVersion, receipt.DocumentLoaded, receipt.ScriptReady, at = clock.GetUtcNow() }, Json));
        Checkpoint?.Invoke("health-confirmed");
    }

    internal static void ValidateHealthStartup(string directory, PackageHealthRequest request)
    {
        var target = PackageLifecycleFiles.Root(directory);
        if (request.Format != 1 || !string.Equals(request.Target, target, StringComparison.OrdinalIgnoreCase)
            || request.Nonce is not { Length: 64 } || !request.Nonce.All(Uri.IsHexDigit)
            || !int.TryParse(request.Attempt, out var attempt) || attempt is < 1 or > HealthAttempts
            || request.Attempt != attempt.ToString(System.Globalization.CultureInfo.InvariantCulture))
        { throw new InvalidDataException("Demande de santé non qualifiée."); }
        using var paths = new PackageLifecycleFiles(); paths.PinTree(target);
        var (transaction, journal) = ReadTransaction(paths, target, request.Transaction);
        if (!journal.RequiresHealth || journal.Action != "update" || journal.NewIdentity != request.ManifestSha256
            || !string.Equals(transaction, request.TransactionDirectory, StringComparison.OrdinalIgnoreCase)
            || PackageLifecycleFiles.Measure(transaction, JournalName).Sha256 != request.JournalSha256)
        { throw new InvalidDataException("Transaction de santé différente ou non autorisée."); }
        if (!PackageLifecycleFiles.Exists(PackageLayout.At(target, Pending))) { throw new InvalidDataException("Transaction déjà activée ; contrôle ancien refusé."); }
        ValidateMarker(target, transaction, journal, allowDamaged: false);
        var proof = ReadJson<HealthAttempt>(Path.Combine(transaction, "health", $"attempt-{attempt}.json"), 16384);
        if (proof.Format != 1 || proof.Transaction != journal.Id || proof.ManifestSha256 != journal.NewIdentity
            || proof.JournalSha256 != request.JournalSha256
            || proof.NonceSha256 != Convert.ToHexStringLower(SHA256.HashData(Convert.FromHexString(request.Nonce))))
        { throw new InvalidDataException("Tentative de santé différente ; aucun lancement."); }
        if (PackageLifecycleFiles.Exists(Path.Combine(transaction, "health", $"ack-{attempt}.json")))
        { throw new InvalidDataException("Tentative de santé déjà acquittée ; rejeu refusé."); }
    }

    private sealed record HealthAttempt(int Format, string Transaction, string ManifestSha256, string JournalSha256, string NonceSha256, DateTimeOffset At);

    private static void ValidateHealthFolder(PackageLifecycleFiles paths, string folder)
    {
        paths.Pin(folder); PackageLifecycleFiles.RequirePrivate(folder);
        var count = 0;
        foreach (var entry in Directory.EnumerateFileSystemEntries(folder))
        {
            if (++count > HealthAttempts * 3) { throw new InvalidDataException("Trop de preuves de santé ; conservation sans reprise."); }
            var name = Path.GetFileName(entry);
            var accepted = Enumerable.Range(1, HealthAttempts).Any(n => name == $"attempt-{n}.json" || name == $"ack-{n}.json" || name == $"outcome-{n}.json");
            if (!accepted) { throw new InvalidDataException("Preuve de santé inconnue ; conservation sans reprise."); }
            PackageLifecycleFiles.Check(entry);
            if (new FileInfo(entry).Length is <= 0 or > 16384) { throw new InvalidDataException("Preuve de santé hors limites."); }
        }
    }

    private static bool CanRestoreAfter(Exception error) => error is not PackageHealthException { ChildExited: false }
        && error is IOException or InvalidDataException or UnauthorizedAccessException or Win32Exception or OperationCanceledException;

    private PackageLifecycleResult RollbackAfterFailure(PackageLifecycleFiles paths, string target, string transaction,
        Transaction journal, FileStream lifecycle, Exception failure)
    {
        // This path never opens a database. Its health child used an isolated profile and no application composition.
        // An ordinary startup is still blocked by pending; a second process holding code prevents replacement by the lock.
        var plan = RecoveryPlan(target, transaction, journal, restore: true);
        EnsurePending(target, transaction, journal, plan.PendingMarker);
        ApplyCode(paths, target, Path.Combine(transaction, "old"), Path.Combine(transaction, "new"), journal, CancellationToken.None, plan);
        var restored = Activate(target, transaction, journal, lifecycle, journal.OldIdentity, plan.Preserved, CancellationToken.None, "restore");
        var folder = Path.Combine(transaction, "health"); paths.PrivateDirectory(folder); ValidateHealthFolder(paths, folder);
        var number = Enumerable.Range(1, HealthAttempts).FirstOrDefault(n => !PackageLifecycleFiles.Exists(Path.Combine(folder, $"outcome-{n}.json")));
        if (number == 0) { throw new IOException("Preuves de retour déjà présentes ; résultat conservé, bilan à relire."); }
        PackageLifecycleFiles.WriteNew(Path.Combine(folder, $"outcome-{number}.json"), JsonSerializer.SerializeToUtf8Bytes(new
        { format = 1, transaction = journal.Id, action = "rolledBack", activeIdentity = journal.OldIdentity,
            failure = failure.GetType().Name, databaseRestored = false, at = clock.GetUtcNow() }, Json));
        return restored with { Action = "rolledBack", HealthConfirmed = false };
    }
}
