namespace Domenia.App;

internal sealed partial class PackageLifecycle
{
    internal PackageLifecyclePlan PreviewUninstall(string destination, CancellationToken token, PackageUninstallOptions? options = null)
    {
        var target = Target(destination); using var paths = new PackageLifecycleFiles(); PreparePaths(paths, target);
        using var tool = PackageIntegrity.Open(source, true); RefusePending(target);
        using var lifecycle = new FileStream(PackageLayout.At(target, LockName), FileMode.Open, FileAccess.Read, FileShare.Read);
        var components = Manifest(target); token.ThrowIfCancellationRequested();
        return UninstallPlan(target, components, PackageLifecycleFiles.Measure(target, PackageLayout.Relative(target, PackageIntegrity.ManifestName)).Sha256, data: RemovalPlan(paths, target, options ?? new()));
    }

    internal PackageLifecycleResult Uninstall(string destination, string confirmation, CancellationToken token, PackageUninstallOptions? options = null)
    {
        var target = Target(destination); using var paths = new PackageLifecycleFiles(); PreparePaths(paths, target);
        using var tool = PackageIntegrity.Open(source, true); RefusePending(target); using var lifecycle = Lock(target, paths);
        var components = Manifest(target); var manifest = PackageLifecycleFiles.Measure(target, PackageLayout.Relative(target, PackageIntegrity.ManifestName));
        var plan = UninstallPlan(target, components, manifest.Sha256, data: RemovalPlan(paths, target, options ?? new())); Confirm(plan, confirmation); token.ThrowIfCancellationRequested();
        using var removal = OpenRemoval(paths, target, plan.DataRemoval);
        var id = Guid.NewGuid().ToString("N"); var transaction = NewTransaction(paths, target, id);
        var backup = System.IO.Path.Combine(transaction, "old"); paths.MakeDirectory(backup);
        paths.Copy(PackageLayout.At(target, PackageIntegrity.ManifestName), PackageLifecycleFiles.At(backup, manifest.Path), manifest, token);
        var preserved = components.Where(c => plan.Preserved.Contains(c.Path, StringComparer.OrdinalIgnoreCase))
            .Select(c => PackageLifecycleFiles.Measure(target, c.Path)).ToArray();
        removal.Backup(paths, System.IO.Path.Combine(transaction, "removed-data"), token);
        var journal = new Transaction(1, id, "uninstall", target, manifest.Sha256, manifest.Sha256, clock.GetUtcNow(), preserved) { DataRemoval = plan.DataRemoval };
        WriteJournal(transaction, journal); token.ThrowIfCancellationRequested(); WritePending(target, transaction, journal);
        Checkpoint?.Invoke("pending-written");
        return FinishUninstall(paths, target, transaction, journal, lifecycle, token, removal);
    }

    private PackageLifecyclePlan UninstallPlan(string target, IReadOnlyList<PackageComponent> components, string manifestIdentity,
        string? transaction = null, IReadOnlyList<PackageComponent>? protectedFiles = null, PackageDataRemoval? data = null)
    {
        ValidateRemoval(target, data);
        var removed = new List<string>(); var preserved = Preserved(target, components).ToList(); var observations = new List<PackageComponent>();
        foreach (var component in components)
        {
            var path = PackageLifecycleFiles.At(target, component.Path);
            if (!PackageLifecycleFiles.Exists(path)) { observations.Add(new(component.Path, -1, "absent")); continue; }
            var actual = PackageLifecycleFiles.Measure(target, component.Path); observations.Add(actual);
            if (actual == component && protectedFiles?.Any(c => c.Path.Equals(component.Path, StringComparison.OrdinalIgnoreCase)) != true) { removed.Add(component.Path); }
            else { preserved.Add(component.Path); }
        }
        if (data is not null)
        {
            foreach (var file in data.Files)
            {
                var root = file.Kind == "local" ? target : data.ProfileRoot!;
                var label = file.Kind + ":" + file.Path;
                var path = PackageLifecycleFiles.At(root, file.Path);
                if (!PackageLifecycleFiles.Exists(path)) { observations.Add(new(label, -1, "absent")); continue; }
                var measured = PackageLifecycleFiles.Measure(root, file.Path); observations.Add(measured with { Path = label });
                if (measured.Length == file.Length && measured.Sha256 == file.Sha256)
                { removed.Add(label); if (file.Kind == "local") preserved.Remove(file.Path); }
                else preserved.Add(label);
            }
        }
        var identity = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(observations, Json)));
        return Seal(new(transaction is null ? "uninstall" : "resume-uninstall", target, null, manifestIdentity, transaction, null, null,
            [], removed, preserved.Order(StringComparer.Ordinal).ToArray(),
            ["Seuls les fichiers encore conformes au manifeste seront retirés. Les fichiers modifiés et leurs dossiers restent en place.",
                data?.Options.LocalData == true ? "Données locales et configuration : retrait des seuls fichiers listés et copiés dans la preuve privée." : "Données locales et configuration conservées.",
                data?.Options.ProfileData == true ? "Profil Windows partagé entre copies : retrait explicite des seuls fichiers listés, sauvegardés dans la preuve privée. Les autres copies utilisent ce même profil." : "Profil Windows partagé conservé.",
                "Coffre Windows, sauvegardes de code et preuves conservés. Aucun dossier supprimé récursivement ; verrou propriétaire conservé contre une substitution.",
                "Le manifeste est conservé comme preuve dans la transaction. Une interruption se reprend explicitement ; ce parcours ne restaure pas un code modifié."], "")
        { ObservedIdentity = identity, PendingMarker = PendingObservation(target), DataRemoval = data });
    }

    private PackageLifecycleResult FinishUninstall(PackageLifecycleFiles paths, string target, string transaction, Transaction journal, FileStream lifecycle, CancellationToken token, PackageRemovalLease? ownedRemoval = null)
    {
        using var reopenedRemoval = ownedRemoval is null ? OpenRemoval(paths, target, journal.DataRemoval) : null;
        var removal = ownedRemoval ?? reopenedRemoval!;
        removal.CheckBackups(System.IO.Path.Combine(transaction, "removed-data"), token);
        var backup = System.IO.Path.Combine(transaction, "old"); var manifest = PackageLifecycleFiles.Measure(backup, PackageLayout.Relative(backup, PackageIntegrity.ManifestName));
        if (manifest.Sha256 != journal.OldIdentity) { throw new InvalidDataException("Preuve du manifeste de désinstallation modifiée."); }
        var components = Manifest(backup); EnsurePending(target, transaction, journal);
        var preserved = Preserved(target, components).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var component in components)
        {
            token.ThrowIfCancellationRequested(); var path = PackageLifecycleFiles.At(target, component.Path);
            if (!PackageLifecycleFiles.Exists(path)) { continue; }
            if (journal.Preserved.Any(c => c.Path.Equals(component.Path, StringComparison.OrdinalIgnoreCase)) || PackageLifecycleFiles.Measure(target, component.Path) != component)
            { preserved.Add(component.Path); continue; }
            if (!PackageLifecycleFiles.DeleteMatching(target, component)) { preserved.Add(component.Path); continue; }
            if (PackageLifecycleFiles.Exists(path)) { throw new IOException("Composant encore présent après suppression ; reprise nécessaire."); }
            Checkpoint?.Invoke("component-removed");
        }
        var changedData = FinishRemoval(removal, transaction, token);
        if (journal.DataRemoval is { } data)
            foreach (var item in data.Files.Where(f => f.Kind == "local")) preserved.Remove(item.Path);
        preserved.UnionWith(changedData);
        var activeManifest = PackageLayout.At(target, PackageIntegrity.ManifestName);
        if (PackageLifecycleFiles.Exists(activeManifest))
        {
            if (PackageLifecycleFiles.Measure(target, PackageLayout.Relative(target, PackageIntegrity.ManifestName)).Sha256 != journal.OldIdentity)
            { throw new InvalidDataException("Manifeste modifié pendant la désinstallation ; marqueur conservé."); }
            if (!PackageLifecycleFiles.DeleteMatching(target, manifest)) { throw new InvalidDataException("Manifeste remplacé ; conservation."); }
        }
        token.ThrowIfCancellationRequested(); Checkpoint?.Invoke("verified-before-activation");
        ValidateMarker(target, transaction, journal, allowDamaged: false);
        DeleteMarker(target, transaction, journal);
        // Keep this owned metadata file. Deleting its path after closing the exclusive handle could delete a replacement.
        // No runtime remains eligible for launch because the published manifest has been removed.
        preserved.Add(PackageLayout.Relative(target, LockName));
        try
        {
            if (PackageLifecycleFiles.Exists(activeManifest) || PackageLifecycleFiles.Exists(PackageLayout.At(target, Pending)) || !lifecycle.CanRead)
            { throw new IOException("Nettoyage de désinstallation incomplet ; succès non constaté."); }
        }
        catch
        {
            if (!PackageLifecycleFiles.Exists(PackageLayout.At(target, Pending))) { WritePending(target, transaction, journal); }
            throw;
        }
        return new("uninstall", target, journal.Id, null, preserved.Order(StringComparer.Ordinal).ToArray());
    }
}
