using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdInventoryRelationTests
{
    private static WmiInstance Row(params (string Key, object? Value)[] values) => new(values.ToDictionary(v => v.Key, v => v.Value));
    private static WmiWorkstationReader Native(Func<IReadOnlyList<WmiInstance>> system) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) =>
            query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? system()
            : query.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? [Row(("Caption", "Windows"), ("BuildNumber", "26100"))] : [] },
    };
    private static void Directory(AdBoundaryTests.RecordingAdConnection ldap)
    {
        ldap.SearchAnswer = q => q.BaseDn == Fixtures.Computer("PC1").DistinguishedName ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))]
            : [AdRelationDirectoryTests.User(Fixtures.User("alice"))];
    }

    [Test]
    public static async Task Full_inventory_qualifies_its_own_console_without_an_extra_machine_read()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap); var reads = 0;
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Native(() => { reads++; return [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))]; }) };
        var result = await reader.InventoryAsync(Fixtures.Computer("PC1"), WorkstationReading.SurveyComplete, null, CancellationToken.None);
        Check.Equal(1, reads, "pas de seconde requête console"); Check.Equal(@"TEST\alice", result.Value.Console!.Account!, "observation reçue conservée");
        Check.Equal(3, ldap.Searches.Count, "identités avant/après et utilisateur exact");
        Check.Equal(RelationKind.Console, (await db.ReadRelationsAsync(CancellationToken.None)).Rows.Single().Relation.Kind, "console commune persistée");
        Check.Equal("CONFIRME", (await db.ReadRelationSweepsAsync(CancellationToken.None)).Rows.Single().Status, "passage partagé");
    }

    [Test]
    public static async Task Search_full_inventory_persists_both_hardware_and_qualified_relations_from_one_gesture()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        var reader = new AdSearchReader(source)
        {
            EchoOverride = (_, _) => Task.FromResult(new PresenceMeasure(MeasureState.Known, true, Fixtures.Now, Fixtures.Now)),
            ConsoleReaderOverride = _ => Native(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"), ("Model", "Modèle lu"))]),
        };
        var result = await reader.ProbeAsync(Fixtures.Computer("PC1").ObjectGuid, SurveyMode.Complete, 1, TimeSpan.Zero, CancellationToken.None);
        Check.False(result.Denied, "accès accepté");
        Check.Equal("Modèle lu", source.FleetDetails.Inventories[Fixtures.Computer("PC1").ObjectGuid].System!.Model, "inventaire conservé");
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "relation commune conservée");
    }

    [Test]
    public static async Task Poste_inventory_uses_the_same_qualified_console_and_passage_store()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        var reader = new AdPosteReader(source) { InventoryReaderOverride = _ => Native(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))]) };
        await reader.InventoryAsync(Fixtures.Computer("PC1").DistinguishedName, false, PosteHealthPolicy.Default, null, CancellationToken.None);
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "association issue du poste");
        Check.Equal(1L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "passage issu du même inventaire");
        Check.Equal(@"TEST\alice", source.FleetDetails.Facts.Machines[Fixtures.Computer("PC1").ObjectGuid].ConsoleUser!, "fait partagé");
    }

    private sealed class Progress(Action<PosteProgress> notify) : IProgress<PosteProgress> { public void Report(PosteProgress value) => notify(value); }

    [Test]
    public static async Task Stopping_after_the_system_step_keeps_its_payload_but_sends_no_final_LDAP_and_publishes_no_console_relation()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        using var stop = new CancellationTokenSource();
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Native(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"), ("Model", "Reçu avant arrêt"))]) };
        var progress = new Progress(p => { if (p.Done >= 1) { stop.Cancel(); } });
        var result = await reader.InventoryAsync(Fixtures.Computer("PC1"), WorkstationReading.Survey, progress, stop.Token);
        Check.Equal("Reçu avant arrêt", result.Value.System!.Model, "charge utile déjà reçue conservée"); Check.Null(result.Value.Console, "console non validée écartée");
        Check.Equal(1, ldap.Searches.Count, "seule la lecture initiale avait été faite");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "pas de lien après arrêt");
        Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "pas de passage final après arrêt");
    }

    [Test]
    public static async Task A_parent_changed_during_inventory_blocks_its_console_and_relation_before_publication()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; var pc = Fixtures.Computer("PC1"); var parents = 0;
        ldap.SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(++parents == 1 ? pc : pc with { ObjectGuid = Guid.NewGuid() })]
            : [AdRelationDirectoryTests.User(Fixtures.User("alice"))];
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Native(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))]) };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.InventoryAsync(pc, WorkstationReading.Survey, null, CancellationToken.None), "parent recréé pendant l’inventaire");
        Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "association non publiée");
        Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "passage non publié");
    }

    [Test]
    public static async Task Reset_during_inventory_does_not_restore_passages_but_keeps_the_independent_qualified_relation()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; Directory(ldap);
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Script("CREATE TABLE domenia_v2_sweep_state(id INTEGER PRIMARY KEY,generation INTEGER NOT NULL); INSERT INTO domenia_v2_sweep_state VALUES(1,0);"); }
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Native(() =>
        {
            using var sql = new SqliteDatabase(db.Path, false); sql.Execute("UPDATE domenia_v2_sweep_state SET generation=1;");
            return [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))];
        }) };
        var result = await reader.InventoryAsync(Fixtures.Computer("PC1"), WorkstationReading.Survey, null, CancellationToken.None);
        Check.Contains("aucun rejeu", result.Notice, "conflit local signalé"); Check.Equal(0L, (await db.ReadRelationSweepsAsync(CancellationToken.None)).Total, "ancienne génération non restaurée");
        Check.Equal(1L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "relation qualifiée sauvée séparément");
    }

    [Test]
    public static async Task Late_directory_refusal_keeps_hardware_but_never_turns_native_empty_console_into_verified_absence()
    {
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await AdRelationDirectoryTests.Open(folder); using var owned = source; var parents = 0;
        ldap.SearchAnswer = _ => ++parents == 1 ? [AdPosteNetworkTests.Entry(Fixtures.Computer("PC1"))]
            : throw new DomeniaOperationException(AdErrors.AccessDenied, "Refus final simulé");
        var reader = new AdRelationsReader(source) { InventoryReaderOverride = _ => Native(() => [Row(("Name", "PC1"), ("UserName", null), ("Model", "Lu"))]) };
        var result = await reader.InventoryAsync(Fixtures.Computer("PC1"), WorkstationReading.Survey, null, CancellationToken.None);
        Check.True(result.Denied, "refus de validation explicite"); Check.Null(result.Value.Console, "absence non validée non publiée");
        Check.Equal("Lu", result.Value.System!.Model, "données système terminées conservées"); Check.Equal(0L, (await db.ReadRelationsAsync(CancellationToken.None)).Total, "aucun lien");
    }
}
