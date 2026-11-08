using System.Collections.Immutable;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Store;

/// <summary>Deferred local discovery of the Domenia 1 layout. No disk or network in the constructor.</summary>
public sealed partial class CompatibleDirectoryCache(string appFolder, string userFolder, string joinedDomain, TimeProvider clock, bool isolated = false, RuntimeConfiguration? configuration = null) : IPreparedDirectoryCache, IReadBackDirectoryCache, IAccueilCache, IObjectDirectoryCache, ILegacySearchCache, IFicheCache, IDirectoryDeletionCache, IRelationLocalWriter
{
    public async Task<DirectorySnapshot> ReadStoredAsync(DirectorySnapshot submitted, DirectoryStorageReceipt receipt, CancellationToken token) =>
        await (await CacheAsync(token).ConfigureAwait(false)).ReadStoredAsync(submitted, receipt, token).ConfigureAwait(false);

    public async Task<DirectoryStorageReceipt> SaveWithReceiptAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken token) =>
        await (await CacheAsync(token).ConfigureAwait(false)).SaveWithReceiptAsync(snapshot, scope, controller, token).ConfigureAwait(false);

    public async Task<WritePrecheck> CheckRelationsAsync(RelationStoreWrite request, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).CheckRelationsAsync(request, cancellationToken).ConfigureAwait(false);
    public async Task<RelationStoreResult> ApplyRelationsAsync(RelationStoreWrite request, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ApplyRelationsAsync(request, cancellationToken).ConfigureAwait(false);
    public async Task<RelationCacheSnapshot> ReadRelationsAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadRelationsAsync(cancellationToken).ConfigureAwait(false);
    public async Task<RelationJournalCache> ReadRelationJournalAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadRelationJournalAsync(cancellationToken).ConfigureAwait(false);
    private readonly SemaphoreSlim loading = new(1, 1);
    private SqliteDirectoryCache? cache;
    private string selectedMode = "Emplacement choisi";
    private OperationActivity? operations;

    public void ConfigureSession(OperationActivity activity)
    {
        ArgumentNullException.ThrowIfNull(activity);
        var previous = Interlocked.CompareExchange(ref operations, activity, null);
        if (previous is not null && !ReferenceEquals(previous, activity)) throw new InvalidOperationException("Cache déjà lié à une autre session.");
        cache?.Database.ConfigureSession(activity);
    }

    private DomeniaDatabase CreateDatabase(string path, string domainDn)
    {
        var database = new DomeniaDatabase(path, domainDn, clock);
        var profileData = System.IO.Path.Combine(userFolder, "Data");
        if (Within(path, profileData) && !Within(path, System.IO.Path.Combine(appFolder, "data"))) database.ConfigureUserLocalRoot(profileData);
        if (operations is { } activity) database.ConfigureSession(activity);
        database.ConfigureBackupTimeout(backupTimeoutSeconds);
        if (backupPreferences is { } preferences) database.ConfigureBackupPreferences(preferences);
        return database;
    }

    public async Task<DirectoryDeletionLinks> CountDeletionLinksAsync(WriteTarget target, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).CountDeletionLinksAsync(target, cancellationToken).ConfigureAwait(false);
    public async Task<DirectoryDeletionLinks> ApplyDeletionAsync(WriteTarget target, DateTimeOffset observedAt, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ApplyDeletionAsync(target, observedAt, cancellationToken).ConfigureAwait(false);

    public async Task<FicheLocalRead?> ReadFicheByGuidAsync(Guid id, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadFicheByGuidAsync(id, cancellationToken).ConfigureAwait(false);
    public async Task<FicheLocalRead?> ReadFicheAsync(string dn, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadFicheAsync(dn, cancellationToken).ConfigureAwait(false);
    public async Task<ImmutableArray<FicheSummary>> ReadFicheIndexAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadFicheIndexAsync(cancellationToken).ConfigureAwait(false);
    public async Task<FicheLocalRead> SaveFicheAsync(FicheLocalRead fiche, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveFicheAsync(fiche, cancellationToken).ConfigureAwait(false);

    public async Task<ImmutableArray<FleetSnapshot>> ReadFleetHistoryAsync(ScopeSelection scope, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadFleetHistoryAsync(scope, cancellationToken).ConfigureAwait(false);

    public async Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadAsync(cancellationToken).ConfigureAwait(false);

    public async Task<CachedFleet> ReadFleetAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadFleetAsync(cancellationToken).ConfigureAwait(false);

    public async Task<CachedFleet> SaveFleetAsync(FleetCachePatch patch, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveFleetAsync(patch, cancellationToken).ConfigureAwait(false);

    public async Task<DirectoryBackupReceipt> PrepareAsync(CancellationToken cancellationToken)
    {
        CollectionStorageRules.Ensure(await CollectionStorageAsync(cancellationToken).ConfigureAwait(false), clock.GetUtcNow(), clock.LocalTimeZone);
        return await (await CacheAsync(cancellationToken).ConfigureAwait(false)).PrepareAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveAsync(snapshot, scope, controller, cancellationToken).ConfigureAwait(false);

    public async Task<DirectorySnapshot?> ReadKnownAsync(CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).ReadKnownAsync(cancellationToken).ConfigureAwait(false);

    public async Task<DirectorySnapshot> SaveObjectsAsync(DirectorySnapshot objects, string? controller, CancellationToken cancellationToken) =>
        await (await CacheAsync(cancellationToken).ConfigureAwait(false)).SaveObjectsAsync(objects, controller, cancellationToken).ConfigureAwait(false);

    public async Task<ImmutableArray<SearchLegacySaved>> ReadLegacySearchesAsync(CancellationToken cancellationToken)
    {
        if (isolated) return [];
        var (paths, domain) = await LegacySearchPathsAsync(cancellationToken).ConfigureAwait(false);
        return await Task.Run(() => LegacySearchFile.Read(paths, domain, cancellationToken), cancellationToken).ConfigureAwait(false);
    }

    public async Task<System.Text.Json.JsonElement?> ReadLegacyWorkspacesAsync(CancellationToken cancellationToken)
    {
        if (isolated) return null;
        var (paths, _) = await LegacySearchPathsAsync(cancellationToken).ConfigureAwait(false);
        return await Task.Run(() => LegacySearchFile.ReadWorkspaces(paths, cancellationToken), cancellationToken).ConfigureAwait(false);
    }

    private async Task<(string[] Paths, string Domain)> LegacySearchPathsAsync(CancellationToken token)
    {
        var db = await DatabaseAsync(token).ConfigureAwait(false);
        var parent = System.IO.Path.GetDirectoryName(db.Path)!;
        var data = string.Equals(System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(parent)), "Domains", StringComparison.OrdinalIgnoreCase)
            ? System.IO.Path.GetDirectoryName(System.IO.Path.GetDirectoryName(parent))! : parent;
        return ([System.IO.Path.Combine(data, "Preferences", "Domenia.settings.json"), System.IO.Path.Combine(data, "Domenia.settings.json"),
            System.IO.Path.Combine(appFolder, "Domenia.settings.json"), System.IO.Path.Combine(data, "ADCC.settings.json"), System.IO.Path.Combine(appFolder, "ADCC.settings.json")], db.DomainDn);
    }

    public async Task<DomeniaDatabase> DatabaseAsync(CancellationToken cancellationToken) => (await CacheAsync(cancellationToken).ConfigureAwait(false)).Database;

    private async Task<SqliteDirectoryCache> CacheAsync(CancellationToken token)
    {
        using var measurements = operations is { } owner ? OperationsMeasurements.Enter(owner) : null;
        await loading.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return cache ??= await Task.Run(() =>
            {
                var labels = joinedDomain.Split('.');
                if (labels.Any(l => l.Length is 0 or > 63 || !l.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'))) { throw new InvalidDataException("Nom de domaine invalide pour le stockage local."); }
                var domainDn = string.Join(',', labels.Select(l => "DC=" + l));
                var path = ReadSwitchState()?.ActivePath ?? ResolvePath(appFolder, userFolder, domainDn, isolated, mode => selectedMode = mode, configuration);
                return new SqliteDirectoryCache(CreateDatabase(path, domainDn));
            }, token).ConfigureAwait(false);
        }
        finally { loading.Release(); }
    }

    internal static string ResolvePath(string appFolder, string userFolder, string domainDn, bool isolated, Action<string>? selectedMode = null, RuntimeConfiguration? configuration = null)
    {
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(domainDn.Trim().ToLowerInvariant())));
        if (isolated) { return System.IO.Path.Combine(userFolder, "E2E-Directory", hash[..32], "Domenia.db"); }
        var mode = "Compatible";
        var name = "Domenia.db";
        var config = System.IO.Path.Combine(appFolder, "Domenia.config.json");
        if (configuration is not null)
        {
            var entries = configuration.Report.Sections.Single(s => s.Id == "LocalStore").Entries;
            var modeEntry = entries.Single(e => e.Key == "Mode");
            var fileEntry = entries.Single(e => e.Key == "DatabaseFile");
            if (configuration.Report.FileState == "invalid" || modeEntry.Source == "invalid" || fileEntry.Source == "invalid")
                throw new InvalidDataException("Configuration de stockage illisible au démarrage : aucune base choisie par repli silencieux.");
            mode = modeEntry.Value; name = fileEntry.Value;
        }
        else if (File.Exists(config))
        {
            using var json = ReadJson(config, 1_048_576, requireLocal: false);
            var section = Property(json.RootElement, "LocalStore");
            if (section is { ValueKind: JsonValueKind.Object } local)
            {
                mode = String(local, "Mode") ?? mode;
                name = String(local, "DatabaseFile") ?? name;
            }
        }
        mode = mode.ToLowerInvariant() switch { "compatible" => "Compatible", "userlocal" => "UserLocal", "portable" => "Portable", _ => mode };
        if (mode is not ("Compatible" or "UserLocal" or "Portable")) { throw new InvalidDataException("Mode de stockage inconnu : aucun repli silencieux."); }
        selectedMode?.Invoke(mode);
        if (name.Length is 0 or > 128 || !char.IsAsciiLetterOrDigit(name[0]) || name.Contains("..", StringComparison.Ordinal)
            || !name.EndsWith(".db", StringComparison.OrdinalIgnoreCase) || !name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-'))
        { throw new InvalidDataException("LocalStore.DatabaseFile doit être un nom de fichier .db sans chemin."); }
        var portable = System.IO.Path.Combine(appFolder, "data");
        var data = mode == "Portable" || mode == "Compatible" && Directory.Exists(portable) && Directory.EnumerateFileSystemEntries(portable).Any()
            ? portable : System.IO.Path.Combine(userFolder, "Data");
        ValidateLocalPath(System.IO.Path.Combine(data, name));
        var preferences = new[] { System.IO.Path.Combine(data, "Preferences", "Domenia.settings.json"), System.IO.Path.Combine(data, "Domenia.settings.json"), System.IO.Path.Combine(appFolder, "Domenia.settings.json"), System.IO.Path.Combine(data, "ADCC.settings.json"), System.IO.Path.Combine(appFolder, "ADCC.settings.json") };
        foreach (var path in preferences.SelectMany(p => new[] { p, p + ".bak" }))
        {
            if (!File.Exists(path)) { continue; }
            using var json = ReadJson(path, LegacyQueryFile.MaxPreferenceBytes);
            var selected = String(json.RootElement, "Storage.Database." + hash);
            if (selected is not null)
            {
                ValidateLocalPath(selected);
                if (!File.Exists(selected)) { throw new FileNotFoundException("La base choisie a disparu : aucun remplacement par une base vide.", selected); }
                return selected;
            }
            break;
        }
        var legacy = System.IO.Path.Combine(data, name);
        if (!File.Exists(legacy) && name.Equals("Domenia.db", StringComparison.OrdinalIgnoreCase)) { legacy = System.IO.Path.Combine(data, "ADCC.db"); }
        if (File.Exists(legacy))
        {
            using var db = new SqliteDatabase(legacy, readOnly: true);
            var hasSync = (long?)db.Scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='sync_state';") == 1;
            if (hasSync && string.Equals(db.Scalar("SELECT base_dn FROM sync_state WHERE scope='directory';") as string, domainDn, StringComparison.OrdinalIgnoreCase)) { return legacy; }
        }
        var target = System.IO.Path.Combine(data, "Domains", hash[..32], name);
        if (!File.Exists(target) && name.Equals("Domenia.db", StringComparison.OrdinalIgnoreCase))
        {
            var old = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(target)!, "ADCC.db");
            if (File.Exists(old)) { target = old; }
        }
        ValidateLocalPath(target);
        return target;
    }

    internal static void ValidateLocalPath(string path)
    {
        if (!System.IO.Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal)) { throw new InvalidDataException("Le stockage actif doit rester sur un disque local."); }
        if (new DriveInfo(System.IO.Path.GetPathRoot(path)!).DriveType == DriveType.Network) { throw new InvalidDataException("Stockage SQLite sur lecteur réseau refusé."); }
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Fichier de stockage redirigé refusé."); }
        for (var parent = new DirectoryInfo(System.IO.Path.GetDirectoryName(path)!); parent is not null; parent = parent.Parent)
        {
            if (parent.Exists && (parent.Attributes & FileAttributes.ReparsePoint) != 0) { throw new InvalidDataException("Dossier de stockage redirigé refusé."); }
        }
    }

    private static JsonDocument ReadJson(string path, int maxBytes, bool requireLocal = true)
    {
        if (requireLocal) { ValidateLocalPath(path); }
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length > maxBytes) { throw new InvalidDataException("Configuration de stockage trop volumineuse."); }
        var bytes = new byte[checked((int)file.Length)]; file.ReadExactly(bytes);
        return JsonDocument.Parse(bytes);
    }

    private static JsonElement? Property(JsonElement element, string key)
    {
        if (element.ValueKind != JsonValueKind.Object) { throw new InvalidDataException("Configuration de stockage invalide."); }
        var found = element.EnumerateObject().Where(p => string.Equals(p.Name, key, StringComparison.OrdinalIgnoreCase)).ToArray();
        if (found.Length > 1) { throw new InvalidDataException("Clé de stockage dupliquée."); }
        return found.Length == 0 ? null : found[0].Value;
    }

    private static string? String(JsonElement element, string key) => Property(element, key) is { } value
        ? value.ValueKind == JsonValueKind.String ? value.GetString() : throw new InvalidDataException("Réglage de stockage non textuel.") : null;
}
