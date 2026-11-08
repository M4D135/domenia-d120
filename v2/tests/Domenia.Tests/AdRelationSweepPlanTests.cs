using System.Security.Cryptography;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class AdRelationSweepPlanTests
{
    private static async Task<(DomeniaDatabase Db, AdDirectorySource Source, AdBoundaryTests.RecordingAdConnection Ldap)> Open(TemporaryFolder folder, params DirectoryComputer[] computers)
    {
        var db = new DomeniaDatabase(folder.File("sweeps.db"), Fixtures.Root, TestClock.Fixed()); var cache = new SqliteDirectoryCache(db);
        await cache.SaveObjectsAsync(Fixtures.Snapshot(computers: computers), null, CancellationToken.None);
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap, localStore: cache);
        await source.ReadLocalAsync(CancellationToken.None); return (db, source, ldap);
    }
    private static void NativeColumns(SqliteDatabase sql) => sql.Script("ALTER TABLE park_state ADD COLUMN computer_guid TEXT; ALTER TABLE park_state ADD COLUMN computer_dn TEXT;");
    private static void Add(SqliteDatabase sql, DirectoryComputer computer, DateTimeOffset at, string? key = null, bool identified = true) => sql.Execute(
        "INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts,computer_guid,computer_dn) VALUES(?1,?2,?3,'Session','alice',1,?4,?5);",
        key ?? computer.Name, computer.Name, at.ToString("O"), identified ? computer.ObjectGuid.ToString("D") : null, identified ? computer.DistinguishedName : null);

    [Test]
    public static async Task Sweep_compatibility_reads_preserve_original_rows_unknown_columns_and_uncertain_dates_without_migration()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder, Fixtures.Computer("PC1")); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Script("ALTER TABLE park_state ADD COLUMN extension BLOB;");
            sql.Execute("INSERT INTO park_state VALUES('PC1','PC1','2025-10-26T02:30:00','Session','alice',4,?1);", new byte[] { 1, 2, 3 });
            sql.Execute("INSERT INTO park_state VALUES('PC2','PC2','2025-03-30T02:30:00','Refus',NULL,2,NULL);");
            sql.Execute("INSERT INTO park_state VALUES('PC3','PC3','2099-01-01T00:00:00Z','Erreur',NULL,2,NULL);");
        }
        var before = SHA256.HashData(File.ReadAllBytes(db.Path));
        var read = await db.ReadRelationSweepsAsync(CancellationToken.None);
        Check.Equal(3, read.Rows.Length, "anciennes lignes conservées"); Check.Equal(3, read.UncertainDates, "pli, trou DST et futur non datés");
        Check.True(read.Rows.All(r => r.At is null && r.ComputerGuid is null), "aucune identité ni date inventée");
        Check.Equal(4, read.Rows.Single(r => r.Computer == "PC1").Attempts, "tentatives originales");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "lecture strictement sans migration");
        using (var sql = new SqliteDatabase(db.Path, false)) { sql.Execute("UPDATE park_state SET extension=?1 WHERE computer_key='PC1';", new byte[] { 3, 2, 1 }); }
        var changed = await db.ReadRelationSweepsAsync(CancellationToken.None);
        Check.False(changed.Fingerprint == read.Fingerprint, "empreinte physique incluant extension D1");
    }

    [Test]
    public static async Task Sweep_reader_bounds_payloads_rejects_invalid_rows_and_leaves_foreign_bases_untouched()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            NativeColumns(sql);
            sql.Execute("INSERT INTO park_state(computer_key,computer,attempts,computer_guid) VALUES('bad-guid','PC1',1,'not-a-guid');");
            sql.Execute("INSERT INTO park_state(computer_key,computer,attempts) VALUES('bad-count','PC2',-1);");
            sql.Execute("INSERT INTO park_state(computer_key,computer,attempts,user_login) VALUES('huge','PC3',1,?1);", new string('a', 100_000));
            sql.Execute("INSERT INTO park_state(computer_key,computer,attempts,computer_dn) VALUES('foreign','PC4',1,'CN=PC4,DC=foreign,DC=local');");
        }
        var read = await db.ReadRelationSweepsAsync(CancellationToken.None);
        Check.Equal(4, read.Rejected, "lignes illisibles exclues"); Check.Equal(4L, read.Total, "lignes originales présentes");
        Check.Equal(0, read.Rows.Length, "pas de coercition des cellules");
        var foreign = new DomeniaDatabase(db.Path, "DC=foreign,DC=local", TestClock.Fixed());
        await Check.ThrowsAsync<InvalidDataException>(() => foreign.ReadRelationSweepsAsync(CancellationToken.None), "autre domaine refusé");
        var absent = new DomeniaDatabase(folder.File("missing.db"), Fixtures.Root, TestClock.Fixed());
        Check.Equal(0L, (await absent.ReadRelationSweepsAsync(CancellationToken.None)).Total, "fichier absent vide");
        Check.False(File.Exists(absent.Path), "aucun fichier créé par lecture");
    }

    [Test]
    public static async Task Sweep_compatibility_stops_at_the_aggregate_byte_budget_without_modifying_large_legacy_extensions()
    {
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            sql.Script("ALTER TABLE park_state ADD COLUMN extension TEXT;");
            sql.Execute("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<600) INSERT INTO park_state(computer_key,computer,attempts,extension) SELECT 'PC'||x,'PC'||x,1,?1 FROM n;", new string('a', 30_000));
        }
        var result = await db.ReadRelationSweepsAsync(CancellationToken.None);
        Check.Equal(600L, result.Total, "nombre complet déclaré"); Check.True(result.Truncated, "limite globale explicite");
        Check.True(result.Rows.Length is > 500 and < 600, "arrêt sous 16 Mio sans perdre les lignes déjà lues");
        Check.Equal(0, result.Rejected, "cellules individuelles valides");
        using var reread = new SqliteDatabase(db.Path, true);
        Check.Equal(600L, (long)reread.Scalar("SELECT count(*) FROM park_state WHERE length(extension)=30000;")!, "extensions conservées");
    }

    [Test]
    public static async Task Sweep_queue_uses_unique_GUID_readings_and_explicit_scope_without_suppressing_unknown_dates_or_legacy_names()
    {
        var pc1 = Fixtures.Computer("PC1"); var pc2 = Fixtures.Computer("PC2"); var pc3 = Fixtures.Computer("PC3");
        var pc4 = Fixtures.Computer("PC4") with { LastLogonTimestamp = 0 }; var pc5 = Fixtures.Computer("PC5");
        using var folder = new TemporaryFolder(); var (db, source, ldap) = await Open(folder, pc1, pc2, pc3, pc4, pc5); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            NativeColumns(sql); Add(sql, pc2, Fixtures.Now.AddDays(-2)); Add(sql, pc3, Fixtures.Now.AddHours(-1));
            Add(sql, pc4, Fixtures.Now.AddDays(-3)); Add(sql, pc5, Fixtures.Now.AddHours(-1), identified: false);
        }
        var reader = new AdRelationsReader(source);
        var plan = await reader.SweepPlanAsync(new(50, new(Fixtures.Postes, "Postes", true), []), CancellationToken.None);
        Check.Equal("PC1,PC5,PC4,PC2", string.Join(',', plan.Targets.Select(t => t.Computer)), "jamais liés au GUID puis anciens ; logon inconnu reste éligible");
        Check.False(plan.Targets.Any(t => t.Computer == "PC3"), "relevé après dernière authentification visible");
        Check.Contains("Index partiel", plan.Text, "couverture locale annoncée");
        var held = AdRelationResults.For(source).Recall<AdRelationProbePlan>(plan.Id!, source.Epoch);
        Check.Equal(plan, held.Plan, "liste affichée identique à la préparation détenue par moteur"); Check.Equal(4, held.Hosts.Count, "DNS exacts détenus");
        Check.Equal(0, ldap.Calls, "aucun contact pour préparer le plan");
    }

    [Test]
    public static async Task Loaded_sweep_lists_preserve_order_exclude_controllers_and_never_expand_to_the_working_OU()
    {
        var machines = Enumerable.Range(1, 5).Select(i => Fixtures.Computer("PC" + i)).ToArray();
        machines[2] = machines[2] with { UserAccountControl = AdValues.AccountDisabled | AdValues.WorkstationTrustAccount };
        machines[3] = machines[3] with { UserAccountControl = 8192 };
        machines[4] = machines[4] with { DnsHostName = "other.test.local" };
        using var folder = new TemporaryFolder(); var (_, source, ldap) = await Open(folder, machines); using var owned = source;
        var reader = new AdRelationsReader(source);
        var plan = await reader.SweepPlanAsync(new(1, new(Fixtures.Root, "Ignoré pour la liste", true), ["PC2", "PC2", "PC1", "PC3", "PC4", "PC5", "UNKNOWN"]), CancellationToken.None);
        Check.Equal("loaded", plan.Scope, "liste explicite"); Check.Equal("PC2", plan.Targets.Single().Computer, "ordre conservé sans doublon");
        Check.Equal(2, plan.Eligible, "seulement deux identités éligibles"); Check.True(plan.Truncated, "limite affichée");
        var empty = await reader.SweepPlanAsync(new(50, null, ["UNKNOWN"]), CancellationToken.None);
        Check.False(empty.Allowed, "liste vide pas remplacée par l’OU"); Check.Null(empty.Id, "aucun plan exécutable vide");
        foreach (var scope in new ScopeSelection?[] { null, new(Fixtures.Root, "Domaine", true), new("CN=Computers," + Fixtures.Root, "Conteneur", true), new("OU=Postes,DC=foreign,DC=local", "Autre", true) })
        { await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SweepPlanAsync(new(50, scope, []), CancellationToken.None), "périmètre non autorisé"); }
        Check.Equal(0, ldap.Calls, "refus et préparation locaux");
    }

    [Test]
    public static async Task Duplicate_or_recreated_sweep_identities_never_hide_computers_from_the_next_queue()
    {
        var pc1 = Fixtures.Computer("PC1"); var pc2 = Fixtures.Computer("PC2"); var pc3 = Fixtures.Computer("PC3"); var pc4 = Fixtures.Computer("PC4");
        using var folder = new TemporaryFolder(); var (db, source, _) = await Open(folder, pc1, pc2, pc3, pc4); using var owned = source;
        using (var sql = new SqliteDatabase(db.Path, false))
        {
            NativeColumns(sql); Add(sql, pc1, Fixtures.Now.AddHours(-1)); Add(sql, pc1, Fixtures.Now.AddHours(-2), "second");
            Add(sql, pc2 with { ObjectGuid = Guid.NewGuid() }, Fixtures.Now.AddHours(-1));
            Add(sql, pc3, pc3.WhenCreated.AddSeconds(-1));
            Add(sql, pc4, Fixtures.Now.AddHours(-1)); sql.Execute("UPDATE park_state SET status='Refus' WHERE computer_key='PC4';");
        }
        var plan = await new AdRelationsReader(source).SweepPlanAsync(new(50, new(Fixtures.Postes, "Postes", true), []), CancellationToken.None);
        Check.Equal(4, plan.Targets.Length, "doublon, ancien GUID, antériorité et refus ne suppriment aucune cible");
    }
}
