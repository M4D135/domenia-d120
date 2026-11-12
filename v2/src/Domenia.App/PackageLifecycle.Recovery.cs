using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.App;

internal sealed partial class PackageLifecycle
{
    private static (string Path, Transaction Journal) ReadTransaction(PackageLifecycleFiles paths, string target, string id)
    {
        var root = Storage(target); var transaction = TransactionPath(target, id);
        paths.Pin(root); paths.Pin(transaction); PackageLifecycleFiles.RequirePrivate(root); PackageLifecycleFiles.RequirePrivate(transaction);
        foreach (var entry in Directory.EnumerateFileSystemEntries(transaction))
        {
            var name = Path.GetFileName(entry);
            if (name is "old" or "new" or "removed-data") { paths.PinTree(entry); }
            else if (Enumerable.Range(1, HealthAttempts).Any(n => name == $"health-profile-{n}"))
            { PackageLifecycleFiles.RequirePrivate(entry); paths.PinTree(entry); }
            else if (name == "health") { ValidateHealthFolder(paths, entry); }
            else if (name == JournalName) { PackageLifecycleFiles.Check(entry); }
            else { throw new InvalidDataException("Entrée de transaction inattendue ; preuves conservées."); }
        }
        var journal = ReadJson<Transaction>(Path.Combine(transaction, JournalName), 4 * 1024 * 1024);
        static bool Hash(string? value) => value is { Length: 64 } && value.All(Uri.IsHexDigit);
        if (journal.Format != 1 || journal.Id != id || journal.Action is not ("update" or "uninstall")
            || !string.Equals(journal.Target, target, StringComparison.OrdinalIgnoreCase) || !Hash(journal.NewIdentity)
            || journal.OldIdentity is not null && !Hash(journal.OldIdentity) || journal.Preserved is null || journal.Preserved.Count > 4096)
        { throw new InvalidDataException("Journal de livraison incompatible ; preuves conservées."); }
        if (journal.Action == "uninstall" && (journal.OldIdentity is null || journal.OldIdentity != journal.NewIdentity))
        { throw new InvalidDataException("Identité du journal de désinstallation invalide."); }
        if (journal.Preserved.Select(c => c.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() != journal.Preserved.Count
            || journal.Preserved.Any(c => !PackageIntegrity.ValidRelativePath(c.Path) || c.Length < 0 || !Hash(c.Sha256)))
        { throw new InvalidDataException("Liste de conservation du journal invalide."); }
        if (journal.Action != "uninstall" && journal.DataRemoval is not null) throw new InvalidDataException("Suppression de données interdite dans une mise à jour.");
        Limits(journal.Preserved);
        ValidateMarker(target, transaction, journal, allowDamaged: true);
        return (transaction, journal);
    }

    private static IReadOnlyList<PackageComponent> Manifest(string root)
    {
        var path = PackageLayout.At(root, PackageIntegrity.ManifestName); PackageLifecycleFiles.Check(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var components = PackageIntegrity.ReadManifest(stream); Limits(components); return components;
    }

    private IReadOnlyList<PackageComponent> VerifiedCopy(string path, string? identity, out PackageSignatureVerdict? publisher, bool admit = false)
    {
        publisher = null;
        if (identity is null)
        {
            if (Directory.EnumerateFileSystemEntries(path).Any()) { throw new InvalidDataException("Sauvegarde de première installation non vide."); }
            return [];
        }
        using var pack = PackageIntegrity.Open(path, true);
        if (pack.ManifestHash != identity) { throw new InvalidDataException("Identité de sauvegarde ou de préparation différente du journal."); }
        if (admit) publisher = Publisher(pack);
        Limits(pack.Components); return pack.Components;
    }

    private PackageLifecyclePlan RecoveryPlan(string target, string transaction, Transaction journal, bool restore)
    {
        if (journal.Action == "uninstall")
        {
            if (restore) { throw new InvalidDataException("La désinstallation se reprend explicitement ; aucune restauration automatique de fichiers modifiés n’est proposée."); }
            var backup = Path.Combine(transaction, "old");
            var components = Manifest(backup);
            if (PackageLifecycleFiles.Measure(backup, PackageLayout.Relative(backup, PackageIntegrity.ManifestName)).Sha256 != journal.OldIdentity)
            { throw new InvalidDataException("Preuve du manifeste de désinstallation modifiée."); }
            return UninstallPlan(target, components, journal.OldIdentity!, journal.Id, journal.Preserved, journal.DataRemoval);
        }
        var oldPath = Path.Combine(transaction, "old"); var newPath = Path.Combine(transaction, "new");
        var old = VerifiedCopy(oldPath, journal.OldIdentity, out var oldPublisher, admit: restore);
        var next = VerifiedCopy(newPath, journal.NewIdentity, out var newPublisher, admit: !restore);
        var desired = restore ? old : next; var other = restore ? next : old;
        bool Kept(PackageComponent c) => !restore && PackageIntegrity.IsDefaults(c.Path) && !desired.Any(d => d.Path.Equals(c.Path, StringComparison.OrdinalIgnoreCase));
        var observed = ObserveTransition(target, old, next, journal);
        var sourceRelease = desired.Count == 0 ? null : Release(restore ? oldPath : newPath, desired);
        var previousRelease = other.Count == 0 ? null : Release(restore ? newPath : oldPath, other);
        return Seal(new(restore ? "restore" : "resume", target, restore ? journal.OldIdentity : journal.NewIdentity,
            restore ? journal.NewIdentity : journal.OldIdentity, journal.Id, sourceRelease, previousRelease,
            desired.Select(c => c.Path).ToArray(), [.. other.Where(c => !desired.Any(d => d.Path.Equals(c.Path, StringComparison.OrdinalIgnoreCase)) && !Kept(c)).Select(c => c.Path), .. observed.Temporary.Select(c => c.Path)],
            Preserved(target, old.Concat(next).Where(c => !Kept(c)).Concat(observed.Temporary).ToArray()), Advice(sourceRelease, previousRelease, restore), "")
        { Publisher = restore ? oldPublisher : newPublisher, RequiresHealth = journal.RequiresHealth && !restore, ObservedIdentity = observed.Identity, TemporaryFiles = observed.Temporary, PendingMarker = PendingObservation(target) });
    }

    private static (string Identity, IReadOnlyList<PackageComponent> Temporary) ObserveTransition(string target, IReadOnlyList<PackageComponent> old, IReadOnlyList<PackageComponent> next, Transaction journal)
    {
        var observations = new List<PackageComponent>();
        foreach (var group in old.Concat(next).GroupBy(c => c.Path, StringComparer.OrdinalIgnoreCase))
        {
            var path = PackageLifecycleFiles.At(target, group.Key);
            if (!PackageLifecycleFiles.Exists(path)) { observations.Add(new(group.Key, -1, "absent")); continue; }
            var actual = PackageLifecycleFiles.Measure(target, group.Key);
            if (!group.Any(c => c.Length == actual.Length && c.Sha256 == actual.Sha256))
            { throw new InvalidDataException("Composant modifié après l’interruption : " + group.Key + ". Conservation sans écrasement."); }
            observations.Add(actual);
        }
        var manifestPath = PackageLayout.At(target, PackageIntegrity.ManifestName);
        if (PackageLifecycleFiles.Exists(manifestPath))
        {
            var manifest = PackageLifecycleFiles.Measure(target, PackageLayout.Relative(target, PackageIntegrity.ManifestName));
            if (manifest.Sha256 != journal.OldIdentity && manifest.Sha256 != journal.NewIdentity)
            { throw new InvalidDataException("Manifeste actif étranger à la transaction ; conservation."); }
            observations.Add(manifest);
        }
        var temporary = new List<PackageComponent>();
        foreach (var group in old.Concat(next).Append(new(PackageLayout.Relative(target, PackageIntegrity.ManifestName), 2 * 1024 * 1024, "")).GroupBy(c => c.Path, StringComparer.OrdinalIgnoreCase))
        {
            var relative = TemporaryNames([group.Key], journal.Id).Single();
            if (PackageLifecycleFiles.Exists(PackageLifecycleFiles.At(target, relative)))
            { temporary.Add(PackageLifecycleFiles.Measure(target, relative, group.Max(c => c.Length))); }
        }
        observations.AddRange(temporary);
        return (Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(observations
            .Select(c => c with { Path = c.Path.ToLowerInvariant() }).OrderBy(c => c.Path, StringComparer.Ordinal), Json))), temporary);
    }

    private static IEnumerable<string> TemporaryNames(IEnumerable<string> names, string id) => names.Distinct(StringComparer.OrdinalIgnoreCase).Select(name => name + ".domenia-" + id + ".part");

    private void ApplyCode(PackageLifecycleFiles paths, string target, string desiredPath, string otherPath, Transaction journal, CancellationToken token, PackageLifecyclePlan? reviewed = null)
    {
        var desiredIdentity = Path.GetFileName(desiredPath) == "old" ? journal.OldIdentity : journal.NewIdentity;
        var otherIdentity = Path.GetFileName(otherPath) == "old" ? journal.OldIdentity : journal.NewIdentity;
        var desired = VerifiedCopy(desiredPath, desiredIdentity, out _, admit: true); var other = VerifiedCopy(otherPath, otherIdentity, out _);
        var observation = ObserveTransition(target, desired, other, journal);
        if (reviewed is not null && observation.Identity != reviewed.ObservedIdentity || reviewed is null && observation.Temporary.Count != 0)
        { throw new InvalidDataException("État ou copie temporaire modifiés depuis l’aperçu ; aucune suppression ni reprise."); }
        // The recorded random transaction id and the exact component paths bound these temporary files. Their bytes were
        // included in the recovery preview; a new update has none. Never sweep a prefix or an arbitrary directory.
        foreach (var temporary in reviewed?.TemporaryFiles ?? [])
        {
            token.ThrowIfCancellationRequested();
            if (!PackageLifecycleFiles.DeleteMatching(target, temporary)) { throw new IOException("Copie temporaire modifiée ; conservation."); }
        }
        foreach (var component in desired)
        {
            token.ThrowIfCancellationRequested(); var path = PackageLifecycleFiles.At(target, component.Path);
            if (PackageLifecycleFiles.Exists(path) && PackageLifecycleFiles.Measure(target, component.Path) == component) { continue; }
            Replace(paths, desiredPath, target, component, journal.Id, other.Concat(desired).Where(c => c.Path.Equals(component.Path, StringComparison.OrdinalIgnoreCase)), token); Checkpoint?.Invoke("component-replaced");
        }
        foreach (var obsolete in other.Where(c => !desired.Any(d => d.Path.Equals(c.Path, StringComparison.OrdinalIgnoreCase))))
        {
            // Going forward, a default configuration listed only by the old manifest (copy made before 2.1.6) stays in
            // place as operator data. A restore still removes one that only the abandoned new version brought.
            if (Path.GetFileName(otherPath) == "old" && PackageIntegrity.IsDefaults(obsolete.Path)) { continue; }
            token.ThrowIfCancellationRequested(); var path = PackageLifecycleFiles.At(target, obsolete.Path);
            if (!PackageLifecycleFiles.Exists(path)) { continue; }
            if (!PackageLifecycleFiles.DeleteMatching(target, obsolete)) { throw new InvalidDataException("Ancien composant modifié ; suppression refusée."); }
            Checkpoint?.Invoke("component-removed");
        }
        token.ThrowIfCancellationRequested(); Checkpoint?.Invoke("before-manifest");
        if (desiredIdentity is not null)
        {
            var manifest = PackageLifecycleFiles.Measure(desiredPath, PackageLayout.Relative(desiredPath, PackageIntegrity.ManifestName));
            var allowed = new List<PackageComponent> { manifest };
            if (otherIdentity is not null) { allowed.Add(PackageLifecycleFiles.Measure(otherPath, PackageLayout.Relative(otherPath, PackageIntegrity.ManifestName))); }
            Replace(paths, desiredPath, target, manifest, journal.Id, allowed, token);
        }
        else if (PackageLifecycleFiles.Exists(PackageLayout.At(target, PackageIntegrity.ManifestName))
            && !PackageLifecycleFiles.DeleteMatching(target, PackageLifecycleFiles.Measure(otherPath, PackageLayout.Relative(otherPath, PackageIntegrity.ManifestName))))
        { throw new InvalidDataException("Manifeste modifié ; conservation."); }
        Checkpoint?.Invoke("manifest-replaced");
    }

    private void Replace(PackageLifecycleFiles paths, string from, string target, PackageComponent component, string id, IEnumerable<PackageComponent> allowed, CancellationToken token)
    {
        var destination = PackageLifecycleFiles.At(target, component.Path);
        var temporary = destination + ".domenia-" + id + ".part";
        paths.Copy(PackageLifecycleFiles.At(from, component.Path), temporary, component, token);
        Checkpoint?.Invoke("component-staged");
        token.ThrowIfCancellationRequested();
        if (PackageLifecycleFiles.Exists(destination))
        {
            var current = PackageLifecycleFiles.Measure(target, component.Path);
            if (!allowed.Contains(current) || !PackageLifecycleFiles.DeleteMatching(target, current))
            { throw new InvalidDataException("Destination modifiée depuis l’aperçu ; copie temporaire et sauvegarde conservées."); }
        }
        // The pending marker blocks loading across the brief absent entry. Move never overwrites a foreign file that
        // appears after the checked old object was removed; that race leaves evidence and requires explicit recovery.
        File.Move(temporary, destination, false);
        if (PackageLifecycleFiles.Measure(target, component.Path) != component) { throw new InvalidDataException("Fichier remplacé non conforme ; marqueur conservé."); }
    }

    private PackageLifecycleResult Activate(string target, string transaction, Transaction journal, FileStream lifecycle, string? expected,
        IReadOnlyList<string> preserved, CancellationToken token, string action = "update")
    {
        token.ThrowIfCancellationRequested();
        using var verified = expected is null ? null : PackageIntegrity.OpenForLifecycle(target, lifecycle);
        if (verified is not null && verified.ManifestHash != expected) { throw new InvalidDataException("Contrôle final de l’ensemble différent ; aucune activation."); }
        if (expected is null && ObservedFiles(target).Any(p => !PackageLayout.IsState(p) && p is not ("Domenia.config.json" or "wad/Domenia.config.json") && !PackageIntegrity.IsDefaults(p)))
        { throw new InvalidDataException("Première installation restaurée mais fichiers inattendus conservés ; aucun retrait du marqueur."); }
        Checkpoint?.Invoke("verified-before-activation"); token.ThrowIfCancellationRequested();
        var healthConfirmed = journal.RequiresHealth && action != "restore";
        if (healthConfirmed) { VerifyHealth(target, transaction, journal, expected!, token); }
        token.ThrowIfCancellationRequested();
        ValidateMarker(target, transaction, journal, allowDamaged: false);
        DeleteMarker(target, transaction, journal);
        if (PackageLifecycleFiles.Exists(PackageLayout.At(target, Pending))) { throw new IOException("Marqueur encore présent ; activation non constatée."); }
        Checkpoint?.Invoke("activated");
        return new(action, target, journal.Id, expected, preserved) { HealthConfirmed = healthConfirmed };
    }

    private static void ValidateMarker(string target, string transaction, Transaction journal, bool allowDamaged)
    {
        if (PackageLifecycleFiles.Exists(Path.Combine(target, "Support", Pending))
            || PackageLifecycleFiles.Exists(Path.Combine(target, "wad", "Support", Pending)))
        { throw new InvalidDataException("Marqueur historique présent ; cette transaction v2 ne l’efface pas."); }
        var path = PackageLayout.At(target, Pending);
        if (!PackageLifecycleFiles.Exists(path)) { return; }
        Marker? marker;
        if (allowDamaged && new FileInfo(path).Length == 0) { PackageLifecycleFiles.Check(path); return; }
        try { marker = ReadJson<Marker>(path, 4096); }
        catch (JsonException) when (allowDamaged) { return; }
        if (marker.Format != 1 || marker.Transaction != journal.Id || marker.JournalSha256 != PackageLifecycleFiles.Measure(transaction, JournalName).Sha256)
        { throw new InvalidDataException("Marqueur d’une autre transaction ou journal modifié ; aucune reprise."); }
    }

    private static PackageComponent? PendingObservation(string target) => PackageLifecycleFiles.Exists(PackageLayout.At(target, Pending))
        ? PackageLifecycleFiles.Measure(target, PackageLayout.Relative(target, Pending)) : null;

    private void EnsurePending(string target, string transaction, Transaction journal, PackageComponent? expected = null, bool permitDamaged = false)
    {
        var path = PackageLayout.At(target, Pending);
        Checkpoint?.Invoke("before-marker-open");
        if (PackageLifecycleFiles.Exists(path))
        {
            PackageLifecycleFiles.Check(path);
            using var file = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough);
            PackageLifecycleFiles.Check(path);
            if (file.Length > 4096) { throw new InvalidDataException("Marqueur de livraison hors limites."); }
            var observed = new PackageComponent(PackageLayout.Relative(target, Pending), file.Length, Convert.ToHexStringLower(SHA256.HashData(file))); file.Position = 0;
            if (expected is not null && observed != expected) { throw new InvalidDataException("Marqueur remplacé depuis l’aperçu ; aucune réécriture."); }
            var receipt = new Marker(1, journal.Id, PackageLifecycleFiles.Measure(transaction, JournalName).Sha256);
            Marker? marker = null;
            try { if (file.Length != 0) { marker = ReadJson<Marker>(file, 4096); } }
            catch (JsonException) when (permitDamaged && expected is not null) { }
            if (marker is not null)
            {
                if (marker != receipt) { throw new InvalidDataException("Marqueur d’une autre transaction ; aucune réécriture."); }
                return;
            }
            if (!permitDamaged || expected is null) { throw new InvalidDataException("Marqueur endommagé sans aperçu correspondant ; conservation."); }
            // The same exclusive handle was measured and qualified. Its entry never disappears during repair.
            var bytes = JsonSerializer.SerializeToUtf8Bytes(receipt, Json);
            file.Position = 0; file.SetLength(0); file.Write(bytes); file.Flush(true); return;
        }
        if (expected is not null) { throw new InvalidDataException("Marqueur retiré depuis l’aperçu ; aucune activation."); }
        WritePending(target, transaction, journal);
    }

    private static void DeleteMarker(string target, string transaction, Transaction journal)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new Marker(1, journal.Id, PackageLifecycleFiles.Measure(transaction, JournalName).Sha256), Json);
        var expected = new PackageComponent(PackageLayout.Relative(target, Pending), bytes.Length, Convert.ToHexStringLower(SHA256.HashData(bytes)));
        if (!PackageLifecycleFiles.DeleteMatching(target, expected)) { throw new InvalidDataException("Marqueur modifié avant activation ; conservation."); }
    }
}
