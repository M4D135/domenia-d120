using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryCacheTests
{
    [Test]
    public static async Task Stored_directory_is_available_offline_without_claiming_a_connection()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var cache = new Cache { Snapshot = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]) };
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        Check.Equal(0, cache.Reads, "construction sans disque");
        var session = await source.GetSessionAsync(CancellationToken.None);
        Check.Equal(ConnectionState.Disconnected, session.Connection, "cache distinct d’une connexion");
        Check.Equal(1, (await source.ReadLocalAsync(CancellationToken.None)).Directory.Computers.Length, "données locales disponibles");
        Check.Equal(1, cache.Reads, "une seule lecture locale");
        Check.Equal(0, ldap.Calls, "aucun LDAP implicite");
    }

    [Test]
    public static async Task A_failed_disk_commit_is_not_published_as_a_new_directory_state()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var original = Fixtures.Snapshot(computers: [Fixtures.Computer("PC1")]);
        var cache = new Cache { Snapshot = original, FailWrite = true };
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None);
        await Check.ThrowsAsync<IOException>(() => source.RefreshAsync(MeasureFamily.Directory, new ScopeSelection(Fixtures.Postes, "Postes", true), CancellationToken.None), "échec du stockage propagé");
        Check.Equal(original, source.CurrentDirectory, "ancien relevé conservé");
    }

    [Test]
    public static void Storage_layout_matches_Domenia_1_and_isolates_the_recipe()
    {
        using var folder = new TemporaryFolder();
        var app = folder.File("app");
        var user = folder.File("profile");
        Directory.CreateDirectory(app);
        var path = CompatibleDirectoryCache.ResolvePath(app, user, Fixtures.Root, false);
        Check.True(path.StartsWith(Path.Combine(user, "Data", "Domains"), StringComparison.OrdinalIgnoreCase), "dossier du domaine historique");
        Check.False(Directory.Exists(user), "lecture sans création de profil");
        Directory.CreateDirectory(Path.Combine(app, "data"));
        File.WriteAllText(Path.Combine(app, "data", "legacy.txt"), "legacy");
        var portable = CompatibleDirectoryCache.ResolvePath(app, user, Fixtures.Root, false);
        Check.True(portable.StartsWith(Path.Combine(app, "data", "Domains"), StringComparison.OrdinalIgnoreCase), "données portables existantes reprises");
        var isolated = CompatibleDirectoryCache.ResolvePath(app, user, Fixtures.Root, true);
        Check.True(isolated.StartsWith(Path.Combine(user, "E2E-Directory"), StringComparison.OrdinalIgnoreCase), "recette isolée des fichiers de l’opérateur");
    }

    [Test]
    public static async Task Missing_preferred_database_never_creates_a_default_replacement()
    {
        using var folder = new TemporaryFolder();
        var app = folder.File("app");
        var user = folder.File("profile");
        var preferences = Path.Combine(user, "Data", "Preferences");
        Directory.CreateDirectory(app);
        Directory.CreateDirectory(preferences);
        var key = "Storage.Database." + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Fixtures.Root.ToLowerInvariant())));
        File.WriteAllText(Path.Combine(preferences, "Domenia.settings.json"), System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, string> { [key] = folder.File("missing.db") }));
        await Check.ThrowsAsync<FileNotFoundException>(() => Task.Run(() => CompatibleDirectoryCache.ResolvePath(app, user, Fixtures.Root, false)), "préférence manquante signalée");
        Check.False(Directory.Exists(Path.Combine(user, "Data", "Domains")), "aucune base de remplacement");
    }

    private sealed class Cache : IDirectoryCache
    {
        public DirectorySnapshot? Snapshot { get; init; }
        public int Reads { get; private set; }
        public bool FailWrite { get; init; }
        public Task<DirectorySnapshot?> ReadAsync(CancellationToken cancellationToken) { Reads++; return Task.FromResult(Snapshot); }
        public Task SaveAsync(DirectorySnapshot snapshot, ScopeSelection scope, string? controller, CancellationToken cancellationToken) => FailWrite ? Task.FromException(new IOException("Disque plein (test).")) : Task.CompletedTask;
    }
}
