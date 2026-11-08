using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class DirectoryBranchCompositionTests
{
    [Test]
    public static async Task Application_deferred_cache_publishes_a_branch_and_reopens_its_durable_snapshot()
    {
        using var folder = new TemporaryFolder();
        // Same cache composition as App.Composition; only the LDAP transport is replaced by a recording fixture.
        var cache = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.DomainAsync(CancellationToken.None);
        ldap.SearchAnswer = _ => [new AdEntry(Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>
        { ["name"] = ["Postes"], ["objectClass"] = ["top", "organizationalUnit"] })];
        using var readers = ScreenReaders.Discover(source, [typeof(AdDirectoryBranchReader).Assembly]);
        var result = await readers.Require<IDirectoryBranchReader>().ReadBranchAsync(null, CancellationToken.None);
        Check.Equal(Fixtures.Postes, result.Children.Single().Dn, "lecture de branche publiée par la composition réelle");
        var reopened = new CompatibleDirectoryCache(folder.File("app"), folder.File("user"), "test.local", TestClock.Fixed(), isolated: true);
        var persisted = await reopened.ReadBranchAsync(Fixtures.Root, CancellationToken.None);
        Check.Equal(result.ReadId, persisted!.ReadId, "même snapshot après une nouvelle découverte locale");
        Check.Equal(result.Children.Single(), persisted.Children.Single(), "enfant réellement relu depuis SQLite");
    }
}
