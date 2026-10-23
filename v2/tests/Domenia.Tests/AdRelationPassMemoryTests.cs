using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationPassMemoryTests
{
    private static WmiInstance Row(object? account) => new(new Dictionary<string, object?> { ["Name"] = "PC1", ["UserName"] = account });
    private static WmiWorkstationReader Inventory(Func<IReadOnlyList<WmiInstance>> answer, Func<RegistryRequest, RegistryReply>? registry = null) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        { ReadOverride = (_, query, _) => query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? answer() : [], RegistryOverride = (r, _) => registry?.Invoke(r) ?? new(2, null),
            UserRegistryOverride = (_, _) => new(2, null) },
    };
    private static void Directory(AdBoundaryTests.RecordingAdConnection ldap)
    {
        ldap.SearchAnswer = q => q.BaseDn == Fixtures.Computer("PC1").DistinguishedName ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))]
            : [AdRelationDirectoryTests.User(Fixtures.User("alice"))];
    }

    [Test]
    public static async Task Relations_native_contract_is_discovered_and_navigation_remains_local()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source;
        var reader = ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]).Require<IRelationsReader>();
        Check.True(reader is AdRelationsReader, "contrat réel découvert");
        await reader.OverviewAsync(CancellationToken.None); await reader.ListAsync(CancellationToken.None);
        await reader.SubjectAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None);
        await reader.PendingAsync(CancellationToken.None); await reader.JournalAsync(CancellationToken.None);
        Check.Equal(0, ldap.Searches.Count, "navigation sans annuaire réseau");
        Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "navigation sans passage fabriqué");
    }

    [Test]
    public static async Task Single_console_updates_the_same_passage_as_a_sweep_without_double_counting_same_dates()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Inventory(() => [Row(@"TEST\alice")]) };
        await reader.ComputerSessionAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None);
        var row = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single();
        Check.Equal(Fixtures.Computer("PC1").ObjectGuid, row.ComputerGuid!.Value, "GUID du passage"); Check.Equal("CONFIRME", row.Status, "console qualifiée");
        Check.Equal(@"TEST\alice", row.UserLogin!, "compte observé conservé"); Check.Equal(1, row.Attempts, "une tentative");
        await reader.ComputerSessionAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None);
        Check.Equal(1, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Attempts, "même date non comptée deux fois");
        ((FixedTimeProvider)source.Clock).Advance(TimeSpan.FromSeconds(1));
        await reader.ComputerSessionAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None);
        Check.Equal(2, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Attempts, "nouveau passage compté");
        Check.Equal(1, (await reader.PendingAsync(CancellationToken.None)).Total, "relation indépendante en attente du pont");
    }

    [Test]
    public static async Task A_reset_during_a_single_console_does_not_resurrect_passages_or_discard_its_qualified_relation()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Script("CREATE TABLE domenia_v2_sweep_state(id INTEGER PRIMARY KEY,generation INTEGER NOT NULL); INSERT INTO domenia_v2_sweep_state VALUES(1,0);"); }
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Inventory(() =>
        {
            using var sql = new SqliteDatabase(db.Path, false); sql.Execute("UPDATE domenia_v2_sweep_state SET generation=1;"); return [Row(@"TEST\alice")];
        }) };
        var result = await reader.ComputerSessionAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None);
        Check.True(result.Savable, "relation qualifiée conservée"); Check.Contains("aucun rejeu", result.Message, "conflit local visible");
        Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "aucun passage ressuscité");
        Check.Equal(1, (await reader.PendingAsync(CancellationToken.None)).Total, "observation disponible séparément");
    }

    [Test]
    public static async Task A_local_passage_failure_keeps_console_results_and_rolls_back_the_memory_write()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        using (var sql = new SqliteDatabase(db.Path, false))
        { sql.Script("CREATE TRIGGER no_pass BEFORE INSERT ON park_state BEGIN SELECT RAISE(ABORT,'refus contrôlé'); END;"); }
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Inventory(() => [Row(@"TEST\alice")]) };
        var result = await reader.ComputerSessionAsync(Fixtures.Computer("PC1").DistinguishedName, CancellationToken.None);
        Check.True(result.Savable, "résultat non perdu"); Check.Contains("Passage non confirmé", result.Message, "erreur de cache visible");
        Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "écriture annulée");
    }

    [Test]
    public static async Task An_unresolved_console_followed_by_LogonUI_history_never_marks_the_console_complete()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Inventory(() => [Row(@"PC1\local")], _ => new(0, @"TEST\alice")) };
        var result = await reader.DetectLastUserAsync(Fixtures.Computer("PC1").DistinguishedName, null, CancellationToken.None);
        Check.True(result.Verified, "compte historique résolu");
        Check.Equal(RelationKind.History, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.Kind, "historique non promu en console");
        var passage = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single();
        Check.Equal("ERREUR", passage.Status, "console non qualifiée reste à relire"); Check.Equal(@"PC1\local", passage.UserLogin!, "pas de substitution du compte historique");
    }

    [Test]
    public static async Task A_genuinely_empty_console_is_revalidated_and_remembered_even_without_any_historical_candidate()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Inventory(() => [Row(null)]) };
        var result = await reader.DetectLastUserAsync(Fixtures.Computer("PC1").DistinguishedName, null, CancellationToken.None);
        Check.False(result.Verified, "aucun utilisateur prétendu");
        var passage = (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single(); Check.Equal("LU", passage.Status, "console vide effectivement lue");
        Check.Null(passage.UserLogin, "aucun compte inventé"); Check.Equal(2, ldap.Searches.Count, "parent avant et après même sans utilisateur");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun lien vide");
    }

    [Test]
    public static async Task Malformed_console_fields_are_partial_in_both_native_console_apis()
    {
        foreach (var malformed in new object[] { 42, Array.Empty<string>(), "", "  ", "TEST\\alice\n", new string('x', 321) })
        {
            var reader = Inventory(() => [Row(malformed)]);
            var console = await reader.ReadConsoleAccountAsync("PC1.test.local", CancellationToken.None);
            Check.Equal(SourceStatus.Partial, console!.Status, "valeur illisible non transformée en absence de console");
            var detected = await reader.ReadUserSourceAsync("PC1.test.local", UserDetectionSource.Console, CancellationToken.None);
            Check.Equal(SourceStatus.Partial, detected.Access.Status, "détection également partielle"); Check.Equal(0, detected.Candidates.Length, "aucun candidat invalide");
        }
    }
}
