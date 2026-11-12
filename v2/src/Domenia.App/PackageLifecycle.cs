using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Domenia.App;

internal sealed record PackageRelease(string Version, string Build, int DataSchemaVersion, int DataSchemaRevision)
{
    public string? Project { get; init; }
    public string? Architecture { get; init; }
    public string? PackageType { get; init; }
    public string? SourceCommit { get; init; }
    public string? ExecutableSha256 { get; init; }
    public IReadOnlyDictionary<string, string>? Dependencies { get; init; }
}
internal sealed record PackageLifecyclePlan(string Action, string Target, string? SourceIdentity, string? ActiveIdentity,
    string? Transaction, PackageRelease? SourceRelease, PackageRelease? ActiveRelease,
    IReadOnlyList<string> Replaced, IReadOnlyList<string> Removed, IReadOnlyList<string> Preserved, IReadOnlyList<string> Advice, string Confirmation)
{
    public PackageDataRemoval? DataRemoval { get; init; }
    public PackageSignatureVerdict? Publisher { get; init; }
    public bool RequiresHealth { get; init; }
    public string? ObservedIdentity { get; init; }
    public PackageComponent? PendingMarker { get; init; }
    public IReadOnlyList<PackageComponent> TemporaryFiles { get; init; } = [];
}
internal sealed record PackageLifecycleResult(string Action, string Target, string Transaction, string? ActiveIdentity, IReadOnlyList<string> Preserved)
{
    public bool HealthConfirmed { get; init; }
    /// <summary>Set only by an automatic rollback: why the new code was not confirmed.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Failure { get; init; }
}

/// <summary>Portable, local code delivery. The caller runs from another verified package. No database, credential,
/// service or network mutation exists here. Machine publisher policy is read-only. Explicit uninstall data choices
/// retain byte copies outside the installation. Removing pending is the sole activation point.</summary>
internal sealed partial class PackageLifecycle
{
    private const string Pending = ".update.pending";
    private const string LockName = ".lifecycle.lock";
    private const string JournalName = "transaction.json";
    private const string ReleaseName = "package-release.json";
    private const int MaxTransactions = 4;
    private static readonly JsonSerializerOptions Json = new()
    { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow, MaxDepth = 10 };
    private readonly string source;
    private readonly TimeProvider clock;
    // Fault barriers are internal and are never selected by command-line input.
    internal Action<string>? Checkpoint { get; init; }
    internal bool RequireHealth { get; init; }
    internal PackagePublisherPolicy PublisherPolicy { get; init; } = PackagePublisherPolicy.ReadMachine();
    internal Func<FileStream, PackageNativeSignature>? SignatureVerifier { get; init; }
    private PackageSignatureVerdict Publisher(PackageIntegrity package)
    {
        var verdict = package.VerifyPublisher(PublisherPolicy, SignatureVerifier);
        verdict.RequireAllowed(PublisherPolicy); return verdict;
    }
    internal Func<PackageHealthRequest, CancellationToken, PackageHealthReceipt>? HealthCheck { get; init; }

    internal PackageLifecycle(string source, TimeProvider clock)
    { this.source = PackageLifecycleFiles.Root(source); this.clock = clock ?? throw new ArgumentNullException(nameof(clock)); }

    internal PackageLifecyclePlan PreviewUpdate(string destination, CancellationToken token)
    {
        var target = Target(destination); using var paths = new PackageLifecycleFiles(); PreparePaths(paths, target);
        using var incoming = PackageIntegrity.Open(source, true);
        using var active = OpenActive(target); token.ThrowIfCancellationRequested();
        return UpdatePlan(target, incoming, active);
    }

    internal PackageLifecycleResult Update(string destination, string confirmation, CancellationToken token)
    {
        var target = Target(destination); using var paths = new PackageLifecycleFiles(); PreparePaths(paths, target);
        using var incoming = PackageIntegrity.Open(source, true);
        using (var preview = OpenActive(target)) { Confirm(UpdatePlan(target, incoming, preview), confirmation); }
        if (RequireHealth && HealthCheck is null) { throw new InvalidDataException("Contrôle de santé obligatoire absent ; aucune installation."); }
        RefusePending(target); using var lifecycle = Lock(target, paths);
        using var active = OpenActive(target, lifecycle);
        var plan = UpdatePlan(target, incoming, active); Confirm(plan, confirmation); token.ThrowIfCancellationRequested();
        var id = Guid.NewGuid().ToString("N"); var transaction = NewTransaction(paths, target, id);
        var staged = Path.Combine(transaction, "new"); var backup = Path.Combine(transaction, "old");
        CopyPackage(paths, source, staged, incoming, token);
        using var stagedPack = PackageIntegrity.Open(staged, true);
        if (active is not null) { CopyPackage(paths, target, backup, active, token); }
        else { paths.MakeDirectory(backup); }
        Checkpoint?.Invoke("backup-verified");
        var journal = new Transaction(1, id, "update", target, active?.ManifestHash, incoming.ManifestHash!, clock.GetUtcNow(), []) { RequiresHealth = RequireHealth };
        WriteJournal(transaction, journal); token.ThrowIfCancellationRequested();
        active?.Dispose(); // A verified backup exists before any code handle is released for replacement.
        WritePending(target, transaction, journal); Checkpoint?.Invoke("pending-written");
        try
        {
            ApplyCode(paths, target, staged, backup, journal, token);
            return Activate(target, transaction, journal, lifecycle, incoming.ManifestHash, plan.Preserved, token);
        }
        catch (Exception error) when (journal.RequiresHealth && CanRestoreAfter(error))
        { return RollbackAfterFailure(paths, target, transaction, journal, lifecycle, error); }
    }

    private static readonly System.Version DefaultsAdmittedSince = new(2, 1, 6);

    // Before 2.1.6 a pack refuses every file outside its manifest: restoring such a release over a default configuration
    // written in place would leave an installation that cannot start. Only the explicit restoration is refused, before any
    // change and without moving anything; the automatic rollback after a failed health check is never blocked.
    private static void RefuseUnadmittedDefaults(string target, PackageLifecyclePlan plan)
    {
        if (plan.SourceRelease is not { } release || !System.Version.TryParse(release.Version.Split('-', '+')[0], out var version)
            || version >= DefaultsAdmittedSince) { return; }
        foreach (var relative in new[] { "wad/" + PackageIntegrity.DefaultsName, PackageIntegrity.DefaultsName })
        {
            if (plan.Replaced.Contains(relative, StringComparer.OrdinalIgnoreCase) || !PackageLifecycleFiles.Exists(PackageLifecycleFiles.At(target, relative))) { continue; }
            throw new InvalidDataException($"La version restaurée {release.Version} refuse tout fichier absent de son manifeste, dont la configuration par défaut "
                + $"écrite sur place ({relative}). Déplacez ce fichier hors du dossier de Domenia, puis relancez l’aperçu de restauration ; rien n’a été modifié.");
        }
    }

    internal PackageLifecyclePlan PreviewRecovery(string destination, string transactionId, bool restore, CancellationToken token)
    {
        var target = Target(destination); using var paths = new PackageLifecycleFiles(); PreparePaths(paths, target);
        using var tool = PackageIntegrity.Open(source, true);
        var (transaction, journal) = ReadTransaction(paths, target, transactionId);
        token.ThrowIfCancellationRequested();
        using var lifecycle = PackageLifecycleFiles.Exists(PackageLayout.At(target, LockName))
            ? new FileStream(PackageLayout.At(target, LockName), FileMode.Open, FileAccess.Read, FileShare.Read) : null;
        var plan = RecoveryPlan(target, transaction, journal, restore);
        if (restore) { RefuseUnadmittedDefaults(target, plan); }
        return plan;
    }

    internal PackageLifecycleResult Recover(string destination, string transactionId, bool restore, string confirmation, CancellationToken token)
    {
        Confirm(PreviewRecovery(destination, transactionId, restore, token), confirmation);
        var target = Target(destination); using var paths = new PackageLifecycleFiles(); PreparePaths(paths, target);
        using var tool = PackageIntegrity.Open(source, true);
        using var lifecycle = Lock(target, paths);
        var (transaction, journal) = ReadTransaction(paths, target, transactionId);
        var plan = RecoveryPlan(target, transaction, journal, restore); Confirm(plan, confirmation); token.ThrowIfCancellationRequested();
        if (restore) { RefuseUnadmittedDefaults(target, plan); }
        if (journal.RequiresHealth && !restore && HealthCheck is null)
        { throw new InvalidDataException("Cette transaction exige son assistant et un nouveau contrôle de santé ; aucune reprise sans accusé."); }
        EnsurePending(target, transaction, journal, plan.PendingMarker, permitDamaged: true);
        if (journal.Action == "uninstall") { return FinishUninstall(paths, target, transaction, journal, lifecycle, token); }
        var staged = Path.Combine(transaction, restore ? "old" : "new");
        var other = Path.Combine(transaction, restore ? "new" : "old");
        try
        {
            ApplyCode(paths, target, staged, other, journal, token, plan);
            return Activate(target, transaction, journal, lifecycle, restore ? journal.OldIdentity : journal.NewIdentity, plan.Preserved, token,
                restore ? "restore" : "resume");
        }
        catch (Exception error) when (journal.RequiresHealth && !restore && CanRestoreAfter(error))
        { return RollbackAfterFailure(paths, target, transaction, journal, lifecycle, error); }
    }

    private PackageLifecyclePlan UpdatePlan(string target, PackageIntegrity incoming, PackageIntegrity? active)
    {
        var publisher = Publisher(incoming);
        Limits(incoming.Components); if (active is not null) { Limits(active.Components); }
        if (active?.ManifestHash == incoming.ManifestHash) { throw new InvalidDataException("Ce paquet est déjà actif ; aucune installation à répéter."); }
        var next = Release(source, incoming.Components); var old = active is null ? null : Release(target, active.Components);
        if (RequireHealth && next is null) { throw new InvalidDataException("Métadonnées de version requises pour le contrôle de santé ; aucune installation."); }
        if (next is not null && old is not null && next.Build == old.Build)
        { throw new InvalidDataException("Identité de build déjà utilisée avec d’autres octets ; livraison incohérente."); }
        if (active is not null && active.IsLight != incoming.IsLight)
            throw new InvalidDataException("La mise à jour doit conserver la variante du paquet installé.");
        if (next is not null && old is not null && CompareSchema(next, old) < 0)
        { throw new InvalidDataException("Schéma de la version proposée plus ancien ; seule une restauration explicite du code est admise, sans toucher aux bases."); }
        var wanted = incoming.Components.Select(c => c.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        // A diffusion copy made before 2.1.6 lists its default configuration in its manifest; an official pack does not.
        // The file then stays in place, outside the new manifest, instead of leaving with the old code (ApplyCode).
        bool Kept(PackageComponent c) => PackageIntegrity.IsDefaults(c.Path) && !wanted.Contains(c.Path);
        var removed = active?.Components.Where(c => !wanted.Contains(c.Path) && !Kept(c)).Select(c => c.Path).ToArray() ?? [];
        var preserved = Preserved(target, active?.Components.Where(c => !Kept(c)).ToArray() ?? []);
        if (preserved.Any(p => wanted.Contains(p)))
        { throw new InvalidDataException("Un composant proposé remplacerait un fichier installé hors manifeste ; conservation sans écrasement."); }
        return Seal(new("update", target, incoming.ManifestHash, active?.ManifestHash, null, next, old,
            incoming.Components.Select(c => c.Path).ToArray(), removed, preserved, Advice(next, old, false).Append(publisher.Notice).ToArray(), "") { RequiresHealth = RequireHealth, Publisher = publisher });
    }

    private static PackageLifecyclePlan Seal(PackageLifecyclePlan plan)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(plan with { Confirmation = "" }, Json);
        if (bytes.Length > 4 * 1024 * 1024) { throw new InvalidDataException("Aperçu de livraison trop volumineux."); }
        return plan with { Confirmation = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
    }

    private static void Confirm(PackageLifecyclePlan plan, string confirmation)
    {
        if (!string.Equals(confirmation, plan.Confirmation, StringComparison.Ordinal))
        { throw new InvalidDataException("Confirmation absente ou aperçu périmé ; relisez le nouvel aperçu avant de confirmer."); }
    }

    private string Target(string destination)
    {
        var target = PackageLifecycleFiles.Root(destination);
        if (target.Equals(source, StringComparison.OrdinalIgnoreCase) || target.StartsWith(source + "\\", StringComparison.OrdinalIgnoreCase)
            || source.StartsWith(target + "\\", StringComparison.OrdinalIgnoreCase))
        { throw new InvalidDataException("Exécutez la livraison depuis un autre paquet indépendant de la cible."); }
        return target;
    }

    private void PreparePaths(PackageLifecycleFiles paths, string target)
    {
        paths.PinTree(source); paths.PinTree(target);
        PackageLifecycleFiles.RefuseDevelopment(source); PackageLifecycleFiles.RefuseDevelopment(target);
        PackageLayout.RequireSameLayout(source, target);
    }

    private FileStream Lock(string target, PackageLifecycleFiles paths)
    {
        var path = Path.Combine(target, PackageLayout.Relative(PackageLayout.IsWad(source), LockName));
        paths.MakeDirectory(Path.GetDirectoryName(path)!);
        if (PackageLifecycleFiles.Exists(path)) { PackageLifecycleFiles.Check(path); }
        return new(path, PackageLifecycleFiles.Exists(path) ? FileMode.Open : FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.WriteThrough);
    }

    private static PackageIntegrity? OpenActive(string target, FileStream? lifecycle = null)
    {
        RefusePending(target);
        if (PackageLifecycleFiles.Exists(PackageLayout.At(target, PackageIntegrity.ManifestName)))
        { return lifecycle is null ? PackageIntegrity.Open(target, true) : PackageIntegrity.OpenForLifecycle(target, lifecycle); }
        var wad = PackageLayout.IsWad(target);
        foreach (var entry in Directory.EnumerateFileSystemEntries(target))
        {
            if (wad && Path.GetFileName(entry) == PackageLayout.Payload)
            {
                PackageLifecycleFiles.Check(entry, directory: true);
                foreach (var nested in Directory.EnumerateFileSystemEntries(entry)) { CheckEmptyEntry(nested); }
            }
            else if (!wad) { CheckEmptyEntry(entry); }
            else { throw new InvalidDataException("Dossier sans manifeste non vide ; aucune superposition de fichiers."); }
        }
        static void CheckEmptyEntry(string path)
        {
            if (Path.GetFileName(path) is not (LockName or "Domenia.config.json" or PackageIntegrity.DefaultsName))
            { throw new InvalidDataException("Dossier sans manifeste non vide ; aucun déploiement par-dessus des fichiers inconnus."); }
            PackageLifecycleFiles.Check(path);
        }
        return null;
    }

    private static void RefusePending(string target)
    {
        if (PackageLifecycleFiles.Exists(PackageLayout.At(target, Pending)) || PackageLifecycleFiles.Exists(Path.Combine(target, "Support", Pending))
            || PackageLifecycleFiles.Exists(Path.Combine(target, "wad", "Support", Pending)))
        { throw new InvalidDataException("Livraison inachevée ; reprise ou restauration explicite requise."); }
    }

    private static void Limits(IReadOnlyList<PackageComponent> files)
    {
        long total = 0;
        foreach (var component in files)
        {
            var name = component.Path; var segments = name.Split('/');
            if (LocalRemovalPath(name) || segments.Any(s => s.Equals("data", StringComparison.OrdinalIgnoreCase) || s.Equals("profiles", StringComparison.OrdinalIgnoreCase)
                || s.Equals(".git", StringComparison.OrdinalIgnoreCase) || s.Equals("dev", StringComparison.OrdinalIgnoreCase))
                || name.EndsWith(".db", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".db-wal", StringComparison.OrdinalIgnoreCase)
                || name.EndsWith(".db-shm", StringComparison.OrdinalIgnoreCase) || name.EndsWith(".sqlite", StringComparison.OrdinalIgnoreCase)
                || name.EndsWith(Pending, StringComparison.OrdinalIgnoreCase))
            { throw new InvalidDataException("Le manifeste vise des données ou un état de livraison ; aucune mutation."); }
            total = checked(total + component.Length);
            if (component.Length > PackageLifecycleFiles.MaximumBytes || total > PackageLifecycleFiles.MaximumBytes)
            { throw new InvalidDataException("Paquet supérieur au plafond de 8 Gio."); }
        }
    }

    private static string Storage(string target) => Path.Combine(Path.GetDirectoryName(target)!, "." + Path.GetFileName(target) + ".domenia-lifecycle");
    private static string TransactionPath(string target, string id)
    {
        if (!Guid.TryParseExact(id, "N", out _)) { throw new InvalidDataException("Identifiant de transaction invalide."); }
        return Path.Combine(Storage(target), id);
    }

    private static string NewTransaction(PackageLifecycleFiles paths, string target, string id)
    {
        var root = Storage(target); paths.PrivateDirectory(root);
        var count = 0;
        foreach (var entry in Directory.EnumerateFileSystemEntries(root))
        {
            PackageLifecycleFiles.Check(entry, directory: true);
            if (!Guid.TryParseExact(Path.GetFileName(entry), "N", out _) || ++count >= MaxTransactions)
            { throw new IOException("Quatre transactions conservées ou entrée inconnue ; archivez explicitement les preuves avant une nouvelle livraison."); }
        }
        var transaction = TransactionPath(target, id); paths.PrivateDirectory(transaction); return transaction;
    }

    private static void CopyPackage(PackageLifecycleFiles paths, string from, string to, PackageIntegrity pack, CancellationToken token)
    {
        paths.MakeDirectory(to);
        foreach (var component in pack.Components)
        { paths.Copy(PackageLifecycleFiles.At(from, component.Path), PackageLifecycleFiles.At(to, component.Path), component, token); }
        var manifest = PackageLifecycleFiles.Measure(from, PackageLayout.Relative(from, PackageIntegrity.ManifestName));
        paths.Copy(PackageLayout.At(from, PackageIntegrity.ManifestName), PackageLifecycleFiles.At(to, pack.ManifestRelativePath), manifest, token);
        PackageLifecycleFiles.WriteNew(PackageLayout.At(to, LockName), []);
        using var verified = PackageIntegrity.Open(to, true);
        if (verified.ManifestHash != pack.ManifestHash) { throw new InvalidDataException("Identité de la copie différente ; aucun remplacement."); }
    }

    private static string[] Preserved(string root, IReadOnlyList<PackageComponent> components)
    {
        var declared = components.Select(c => c.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        using var paths = new PackageLifecycleFiles();
        return paths.FileNames(root)
            .Where(p => !declared.Contains(p) && !PackageLayout.IsState(p)).Order(StringComparer.Ordinal).ToArray();
    }

    private static string[] ObservedFiles(string root) { using var paths = new PackageLifecycleFiles(); return paths.FileNames(root); }

    internal static PackageRelease? Release(string root, IReadOnlyList<PackageComponent> components)
    {
        if (!components.Any(c => c.Path.Equals(PackageLayout.Relative(root, ReleaseName), StringComparison.OrdinalIgnoreCase))) { return null; }
        var release = ReadJson<PackageRelease>(PackageLayout.At(root, ReleaseName), 16384);
        if (string.IsNullOrWhiteSpace(release.Version) || release.Version.Length > 80 || release.Version.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('.' or '-'))
            || !Version.TryParse(release.Version.Split('-')[0], out var version) || version.Build < 0 || version.Revision != -1 || release.Version.EndsWith('-')
            || string.IsNullOrWhiteSpace(release.Build) || !release.Build.StartsWith(release.Version + "+", StringComparison.Ordinal)
            || release.Build.Length != release.Version.Length + 65 || !release.Build[(release.Version.Length + 1)..].All(Uri.IsHexDigit)
            || release.DataSchemaVersion is < 1 or > 1000000 || release.DataSchemaRevision is < 0 or > 1000000)
        { throw new InvalidDataException("Métadonnées de livraison invalides."); }
        static bool Hash(string? value, int size) => value is not null && value.Length == size && value.All(Uri.IsHexDigit);
        if (release.Project is not null && release.Project != "Domenia"
            || release.Architecture is not null && release.Architecture != "win-x64"
            || release.PackageType is not null && release.PackageType is not ("PROD" or "DEV" or PackageIntegrity.LightType)
            || release.SourceCommit is not null && !Hash(release.SourceCommit, 40)
            || release.ExecutableSha256 is not null && (!Hash(release.ExecutableSha256, 64)
                || !string.Equals(release.ExecutableSha256, components.Single(c => c.Path.Equals("Domenia.exe", StringComparison.OrdinalIgnoreCase)).Sha256, StringComparison.OrdinalIgnoreCase))
            || release.Dependencies is not null && (release.Dependencies.Count is < 1 or > 2
                || release.Dependencies.Any(d => d.Key is not (".NET" or "WebView2") || string.IsNullOrWhiteSpace(d.Value) || d.Value.Length > 100 || d.Value.Any(char.IsControl))))
        { throw new InvalidDataException("Projet, plateforme, provenance ou dépendances du paquet invalides."); }
        return release;
    }

    private static int CompareSchema(PackageRelease first, PackageRelease second) => first.DataSchemaVersion != second.DataSchemaVersion
        ? first.DataSchemaVersion.CompareTo(second.DataSchemaVersion) : first.DataSchemaRevision.CompareTo(second.DataSchemaRevision);
    private static string[] Advice(PackageRelease? incoming, PackageRelease? active, bool restore) =>
    ["Intégrité : SHA-256 du manifeste et des fichiers ; le verdict Authenticode et la politique machine de confiance restent séparés.",
        incoming is null || active is null ? "Schéma de données inconnu pour au moins un paquet ; aucune migration ni compatibilité de retour annoncée."
            : CompareSchema(incoming, active) > 0 ? "Schéma déclaré plus récent. L’application sauvegarde puis migre lors de son prochain démarrage ; la livraison ne touche aucune base."
            : CompareSchema(incoming, active) < 0 ? "Restauration explicite d’un code plus ancien. Une base plus récente reste conservée et doit être refusée par cette version ; sa restauration est une opération séparée."
            : "Schéma déclaré identique ; les bases et les reçus restent intacts.",
        restore ? "Retour de code explicite uniquement ; aucune restauration de données implicite." : "Configuration, données locales, profils et coffre Windows conservés."];

    private static T ReadJson<T>(string path, long maximum)
    {
        PackageLifecycleFiles.Check(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return ReadJson<T>(stream, maximum);
    }

    private static T ReadJson<T>(Stream stream, long maximum)
    {
        if (stream.Length is <= 0 || stream.Length > maximum) { throw new InvalidDataException("Document de livraison hors limites."); }
        using var document = JsonDocument.Parse(stream, new JsonDocumentOptions { MaxDepth = 10 });
        void Unique(JsonElement element)
        {
            if (element.ValueKind == JsonValueKind.Object)
            {
                var names = new HashSet<string>(StringComparer.Ordinal);
                foreach (var property in element.EnumerateObject()) { if (!names.Add(property.Name)) { throw new InvalidDataException("Champ de livraison répété."); } Unique(property.Value); }
            }
            else if (element.ValueKind == JsonValueKind.Array) { foreach (var item in element.EnumerateArray()) { Unique(item); } }
        }
        Unique(document.RootElement);
        return document.RootElement.Deserialize<T>(Json) ?? throw new InvalidDataException("Document de livraison vide.");
    }

    private sealed record Transaction(int Format, string Id, string Action, string Target, string? OldIdentity, string NewIdentity,
        DateTimeOffset CreatedAt, IReadOnlyList<PackageComponent> Preserved)
    {
        public bool RequiresHealth { get; init; }
        public PackageDataRemoval? DataRemoval { get; init; }
    }
    private sealed record Marker(int Format, string Transaction, string JournalSha256);
    private static void WriteJournal(string transaction, Transaction journal) => PackageLifecycleFiles.WriteNew(Path.Combine(transaction, JournalName), JsonSerializer.SerializeToUtf8Bytes(journal, Json));
    private static void WritePending(string target, string transaction, Transaction journal) => PackageLifecycleFiles.WriteNew(PackageLayout.At(target, Pending),
        JsonSerializer.SerializeToUtf8Bytes(new Marker(1, journal.Id, PackageLifecycleFiles.Measure(transaction, JournalName).Sha256), Json));
}
