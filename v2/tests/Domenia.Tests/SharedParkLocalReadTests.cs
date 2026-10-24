using System.Collections.Immutable;
using System.Security.Cryptography;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// The local, read-only SQLite read of the stored park survey, on real temporary bases. It only prepares a merge: it never migrates
/// the base, never invents a date or a GUID, and refuses as a whole any survey the bounded TSV codec could not write back.
/// </summary>
internal static class SharedParkLocalReadTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly string EmptyFingerprint = Convert.ToHexStringLower(SHA256.HashData([]));
    private static readonly string OtherStore = new('0', 64);

    private static DomeniaDatabase Fresh(TemporaryFolder folder, string name) => new(folder.File(name), Fixtures.Root, TestClock.Fixed());

    private static async Task<DomeniaDatabase> Native(TemporaryFolder folder, string name = "parc.db")
    {
        var db = Fresh(folder, name);
        await db.InitializeAsync(None);
        return db;
    }

    /// <summary>Schema 11 really creates six columns: every plain Domenia 1 row is inserted without touching the native ones.</summary>
    private static void Insert(DomeniaDatabase db, string key, string name, string? at, string status, string? user, int attempts)
        => Exec(db, "INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES(?1,?2,?3,?4,?5,?6);", key, name, at, status, user, attempts);

    /// <summary>Needs the computer_guid column, added only by the fixture that asks for it.</summary>
    private static void InsertGuid(DomeniaDatabase db, string key, string name, string? at, string status, string? user, int attempts, string guid)
        => Exec(db, "INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts,computer_guid) VALUES(?1,?2,?3,?4,?5,?6,?7);", key, name, at, status, user, attempts, guid);

    /// <summary>Needs both native columns, added only by the fixture that asks for them.</summary>
    private static void InsertIdentified(DomeniaDatabase db, string key, string name, string? at, string status, string? user, int attempts, string guid, string dn)
        => Exec(db, "INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts,computer_guid,computer_dn) VALUES(?1,?2,?3,?4,?5,?6,?7,?8);",
            key, name, at, status, user, attempts, guid, dn);

    private static void AddGuidColumn(DomeniaDatabase db) => Script(db, "ALTER TABLE park_state ADD COLUMN computer_guid TEXT;");

    private static void AddIdentityColumns(DomeniaDatabase db) => Script(db, "ALTER TABLE park_state ADD COLUMN computer_guid TEXT; ALTER TABLE park_state ADD COLUMN computer_dn TEXT;");

    private static void Exec(DomeniaDatabase db, string statement, params object?[] values)
    {
        using var store = new SqliteDatabase(db.Path, false);
        store.Execute(statement, values);
    }

    private static void Script(DomeniaDatabase db, string statements)
    {
        using var store = new SqliteDatabase(db.Path, false);
        store.Script(statements);
    }

    private static long Count(DomeniaDatabase db, string statement)
    {
        using var store = new SqliteDatabase(db.Path, true);
        return (long)store.Scalar(statement)!;
    }

    private static string Columns(DomeniaDatabase db)
    {
        using var store = new SqliteDatabase(db.Path, true);
        return string.Join('|', store.Query("PRAGMA table_info(park_state);").Select(r => (string)r["name"]!));
    }

    private static RelationSweepRecord Row(string key, string name, DateTimeOffset? at, string status = "SESSION", string? user = null, int attempts = 1, Guid? guid = null, string? dn = null)
        => new(key, new string('A', 64), name, guid, dn, at, status, user, attempts) { PreservedFingerprint = new string('B', 64) };

    private static RelationSweepCacheSnapshot Snapshot(DomeniaDatabase db, ImmutableArray<RelationSweepRecord> rows, long total = -1, int rejected = 0, int uncertain = 0, bool truncated = false, long generation = 0)
        => new(db.StoreId, db.DomainDn, rows, total < 0 ? rows.Length : total, rejected, uncertain, truncated, EmptyFingerprint, "instantané de test") { Generation = generation };

    [Test]
    public static async Task An_absent_base_reads_as_absent_and_creates_no_file()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "absente.db");
        var read = await db.ReadSharedParkLocalAsync(None);
        Check.False(read.Exists, "aucune base n’est inventée");
        Check.False(read.Legacy, "une base absente n’est pas déclarée héritée");
        Check.Equal(0L, read.Revision, "révision zéro");
        Check.Equal(0L, read.Generation, "génération zéro");
        Check.Equal(0, read.Sweeps.Rows.Length, "aucune ligne");
        Check.Equal(0L, read.Sweeps.Total, "aucun total");
        Check.Equal(db.StoreId, read.StoreId, "identité du store attendue");
        Check.Equal(Fixtures.Root, read.DomainDn, "domaine attendu");
        Check.Equal(EmptyFingerprint, read.RowsFingerprint, "empreinte d’un contenu vide");
        Check.Equal(0, read.CodecLines().Length, "rien à encoder");
        Check.False(File.Exists(db.Path), "la lecture n’a créé aucun fichier");
    }

    [Test]
    public static async Task A_base_without_the_storage_checkpoint_is_read_as_inherited_and_never_migrated()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        Script(db, "DROP TABLE domenia_store_state;");
        var before = SHA256.HashData(File.ReadAllBytes(db.Path));
        var read = await db.ReadSharedParkLocalAsync(None);
        Check.True(read.Exists, "base présente");
        Check.True(read.Legacy, "révision zéro déclarée héritée, sans migration");
        Check.Equal(0L, read.Revision, "aucune révision n’est inventée");
        Check.Equal(1, read.Sweeps.Rows.Length, "ligne D1 à six colonnes conservée");
        Check.Equal("PC1", read.Sweeps.Rows[0].StorageKey, "clé de stockage originale conservée");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "octets identiques : aucune migration d’une base D1");
        Check.Equal(0L, Count(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='domenia_store_state';"), "aucune table d’état recréée par la lecture");
    }

    [Test]
    public static async Task A_native_base_reports_store_domain_revision_and_generation()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        Script(db, "CREATE TABLE domenia_v2_sweep_state(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL CHECK(generation>=0));"
            + "INSERT INTO domenia_v2_sweep_state(id,generation) VALUES(1,4);");
        Exec(db, "UPDATE domenia_store_state SET revision=7;");
        var read = await db.ReadSharedParkLocalAsync(None);
        Check.True(read.Exists, "base présente");
        Check.False(read.Legacy, "base native");
        Check.Equal(db.StoreId, read.StoreId, "store exact");
        Check.Equal(Fixtures.Root, read.DomainDn, "domaine exact");
        Check.Equal(7L, read.Revision, "révision relue");
        Check.Equal(4L, read.Generation, "génération relue");
        Check.Equal(read.Sweeps.Fingerprint, read.RowsFingerprint, "l’empreinte des lignes est celle du lecteur de relevés");
        Check.Equal(DomeniaDatabase.SharedParkLocalFingerprint(db.StoreId, Fixtures.Root, 7, 4, false, read.Sweeps.Fingerprint), read.Fingerprint, "l’empreinte liée est reproductible");
        Check.Equal(1, read.CodecLines().Length, "ligne représentable dans le codec");
        Check.Equal("alice", read.CodecLines()[0].User ?? string.Empty, "l’utilisateur D1 est conservé pour l’aperçu");
        Check.Equal(3, read.CodecLines()[0].Attempts, "le compteur repart de la valeur enregistrée");
        Check.Equal("computer_key|computer|last_probe|status|user_login|attempts", Columns(db), "aucune colonne native ajoutée par cette fixture D1");
    }

    [Test]
    public static async Task The_local_read_never_migrates_nor_touches_the_base()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        Script(db, "CREATE TABLE domenia_v2_sweep_state(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL CHECK(generation>=0));"
            + "INSERT INTO domenia_v2_sweep_state(id,generation) VALUES(1,9);");
        var before = SHA256.HashData(File.ReadAllBytes(db.Path));
        var columns = Columns(db);
        var first = await db.ReadSharedParkLocalAsync(None);
        var again = await db.ReadSharedParkLocalAsync(None);
        Check.Equal(first.Fingerprint, again.Fingerprint, "deux lectures, même empreinte");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "aucun octet déplacé par la lecture");
        Check.Equal(columns, Columns(db), "aucune colonne ajoutée à park_state");
        Check.Equal(9L, Count(db, "SELECT generation FROM domenia_v2_sweep_state WHERE id=1;"), "génération jamais incrémentée par une lecture");
    }

    [Test]
    public static async Task A_foreign_domain_or_store_is_refused()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        var foreign = new DomeniaDatabase(db.Path, "DC=foreign,DC=local", TestClock.Fixed());
        await Check.ThrowsAsync<InvalidDataException>(() => foreign.ReadSharedParkLocalAsync(None), "autre domaine refusé");
        Exec(db, "UPDATE domenia_store_state SET store_id=?1;", OtherStore);
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadSharedParkLocalAsync(None), "autre store refusé");
        Check.Equal(1L, Count(db, "SELECT count(*) FROM park_state;"), "aucune ligne perdue par un refus");
    }

    [Test]
    public static async Task An_unreadable_revision_is_refused_and_never_becomes_zero()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        Exec(db, "UPDATE domenia_store_state SET revision=-1;");
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadSharedParkLocalAsync(None), "révision négative refusée");
        Exec(db, "UPDATE domenia_store_state SET revision='provisoire';");
        var text = await Check.ThrowsAsync<InvalidDataException>(() => db.ReadSharedParkLocalAsync(None), "révision non entière refusée, jamais convertie en zéro");
        Check.Contains("illisible", text.Message, "le refus nomme la cause");
        Exec(db, "UPDATE domenia_store_state SET revision=2;");
        Exec(db, "DELETE FROM domenia_store_state;");
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadSharedParkLocalAsync(None), "ligne d’état absente refusée alors que la table existe");
        Script(db, "DROP TABLE domenia_store_state; CREATE TABLE domenia_store_state(id INTEGER PRIMARY KEY,store_id TEXT NOT NULL,domain_dn TEXT NOT NULL,revision INTEGER NOT NULL);");
        Exec(db, "INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(1,?1,?2,2);", db.StoreId, Fixtures.Root);
        Exec(db, "INSERT INTO domenia_store_state(id,store_id,domain_dn,revision) VALUES(2,?1,?2,3);", db.StoreId, Fixtures.Root);
        await Check.ThrowsAsync<InvalidDataException>(() => db.ReadSharedParkLocalAsync(None), "état de stockage multiple refusé");
        Check.Equal(1L, Count(db, "SELECT count(*) FROM park_state;"), "le relevé reste intact après chaque refus");
    }

    [Test]
    public static async Task A_missing_date_is_refused_even_when_no_date_is_counted_uncertain()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", null, "SESSION", "alice", 3);
        var raw = await db.ReadRelationSweepsAsync(None);
        Check.Equal(0, raw.UncertainDates, "une date absente n’est pas comptée comme incertaine");
        Check.Null(raw.Rows.Single().At, "le lecteur de relevés ne fabrique aucune date");
        var ex = await Check.ThrowsAsync<InvalidDataException>(() => db.ReadSharedParkLocalAsync(None), "le partage refuserait une ligne sans date réelle");
        Check.Contains("jamais substitué", ex.Message, "aucun DateTimeOffset.MinValue de substitution");
    }

    [Test]
    public static async Task Sentinel_and_future_dates_are_refused()
    {
        using var folder = new TemporaryFolder();
        var sentinel = await Native(folder, "sentinelle.db");
        Insert(sentinel, "PC1", "PC1", "1970-01-01T00:00:00+00:00", "SESSION", "alice", 1);
        Check.Equal(DateTimeOffset.UnixEpoch, (await sentinel.ReadRelationSweepsAsync(None)).Rows.Single().At ?? default, "la sentinelle est relue telle quelle par le lecteur de relevés");
        var sentinelEx = await Check.ThrowsAsync<InvalidDataException>(() => sentinel.ReadSharedParkLocalAsync(None), "date sentinelle refusée pour la publication");
        Check.Contains("non qualifiée", sentinelEx.Message, "le refus nomme la cause");
        var future = await Native(folder, "future.db");
        Insert(future, "PC2", "PC2", "2099-01-01T00:00:00Z", "SESSION", null, 1);
        Check.Null((await future.ReadRelationSweepsAsync(None)).Rows.Single().At, "la date future n’est pas retenue par le lecteur de relevés");
        await Check.ThrowsAsync<InvalidDataException>(() => future.ReadSharedParkLocalAsync(None), "date future refusée à la publication");
    }

    [Test]
    public static async Task Rejected_rows_and_values_the_codec_could_not_write_refuse_the_whole_survey()
    {
        using var folder = new TemporaryFolder();
        var unreadable = await Native(folder, "illisibles.db");
        AddGuidColumn(unreadable);
        InsertGuid(unreadable, "bon", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 1, "not-a-guid");
        var raw = await unreadable.ReadRelationSweepsAsync(None);
        Check.Equal(1, raw.Rejected, "ligne illisible repérée par le lecteur de relevés");
        Check.Equal(0, raw.Rows.Length, "aucune coercition de cellule");
        var rejectedEx = await Check.ThrowsAsync<InvalidDataException>(() => unreadable.ReadSharedParkLocalAsync(None), "une ligne illisible refuse tout le relevé");
        Check.Contains("illisibles", rejectedEx.Message, "le refus dit pourquoi rien n’est publié");
        var emptyStatus = await Native(folder, "statut-vide.db");
        Insert(emptyStatus, "PC1", "PC1", "2026-10-20T10:00:00Z", string.Empty, null, 1);
        Check.Equal(0, (await emptyStatus.ReadRelationSweepsAsync(None)).Rejected, "un statut vide reste lisible pour D1");
        await Check.ThrowsAsync<InvalidDataException>(() => emptyStatus.ReadSharedParkLocalAsync(None), "le codec n’écrirait aucun statut vide");
        var spaced = await Native(folder, "nom-espaces.db");
        Insert(spaced, "cle", "PC 1", "2026-10-20T10:00:00Z", "SESSION", null, 1);
        await Check.ThrowsAsync<InvalidDataException>(() => spaced.ReadSharedParkLocalAsync(None), "un nom à espace interne n’est pas représentable dans le TSV");
        var negative = await Native(folder, "compteur.db");
        Insert(negative, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", null, -4);
        await Check.ThrowsAsync<InvalidDataException>(() => negative.ReadSharedParkLocalAsync(None), "un compteur négatif refuse tout le relevé");
        Check.Equal(1L, Count(negative, "SELECT count(*) FROM park_state;"), "une erreur ne modifie aucune donnée");
    }

    [Test]
    public static void A_truncated_or_inconsistent_snapshot_is_refused_as_a_whole()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "synthese.db");
        var good = Row("PC1", "PC1", Fixtures.Now.AddHours(-1), user: "alice");
        Check.Equal(1, db.QualifySharedParkLocal(Snapshot(db, [good]), 0, false).Sweeps.Rows.Length, "un relevé qualifié est accepté");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [good], truncated: true), 0, false), "lecture partielle refusée");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [good], rejected: 1), 0, false), "une ligne rejetée refuse tout");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [good], uncertain: 1), 0, false), "une date incertaine refuse tout");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [good], total: 2), 0, false), "total incohérent refusé");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [good]), -1, false), "révision négative refusée");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [good], generation: -1), 0, false), "génération négative refusée");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [Row("PC1", "PC1", null)]), 0, false), "date absente refusée");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [Row("PC1", "PC1", Fixtures.Now.AddHours(-1), status: "")]), 0, false), "statut vide refusé");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [Row("PC1", "PC 1", Fixtures.Now.AddHours(-1))]), 0, false), "nom non représentable refusé");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(Snapshot(db, [Row("PC1", "PC1", DateTimeOffset.UnixEpoch)]), 0, false), "date sentinelle refusée");
        Check.Throws<InvalidDataException>(() => db.QualifySharedParkLocal(new RelationSweepCacheSnapshot("autre-store", db.DomainDn, [good], 1, 0, 0, false, EmptyFingerprint, "") { Generation = 0 }, 0, false),
            "store étranger refusé");
        Check.False(File.Exists(db.Path), "aucune base créée par une qualification");
    }

    [Test]
    public static void A_pre_cancelled_qualification_refuses_before_inspecting_any_row()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "annulee.db");
        var rows = ImmutableArray.Create(Row("PC1", "PC1", Fixtures.Now.AddHours(-1), user: "alice"), Row("PC2", "PC2", Fixtures.Now.AddHours(-2)));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Check.Throws<OperationCanceledException>(() => db.QualifySharedParkLocal(Snapshot(db, rows), 3, false, cancelled.Token), "une qualification annulée n’inspecte aucune ligne");
        Check.Throws<OperationCanceledException>(() => db.QualifySharedParkLocal(Snapshot(db, [Row("PC1", "PC 1", Fixtures.Now.AddHours(-1))]), 3, false, cancelled.Token),
            "l’annulation prime sur une valeur pourtant refusée");
        Check.False(File.Exists(db.Path), "aucune base créée par une qualification annulée");
    }

    [Test]
    public static async Task The_bound_fingerprint_is_deterministic_and_binds_every_qualifier()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        var first = await db.ReadSharedParkLocalAsync(None);
        var second = await db.ReadSharedParkLocalAsync(None);
        Check.Equal(first.Fingerprint, second.Fingerprint, "mêmes octets, même empreinte liée");
        var rows = first.Sweeps.Fingerprint;
        Check.False(DomeniaDatabase.SharedParkLocalFingerprint(db.StoreId, Fixtures.Root, 1, 0, false, rows) == first.Fingerprint, "la révision lie l’empreinte");
        Check.False(DomeniaDatabase.SharedParkLocalFingerprint(db.StoreId, Fixtures.Root, 0, 1, false, rows) == first.Fingerprint, "la génération lie l’empreinte");
        Check.False(DomeniaDatabase.SharedParkLocalFingerprint(db.StoreId, Fixtures.Root, 0, 0, true, rows) == first.Fingerprint, "l’héritage lie l’empreinte");
        Check.False(DomeniaDatabase.SharedParkLocalFingerprint(OtherStore, Fixtures.Root, 0, 0, false, rows) == first.Fingerprint, "le store lie l’empreinte");
        Check.False(DomeniaDatabase.SharedParkLocalFingerprint(db.StoreId, "DC=autre,DC=local", 0, 0, false, rows) == first.Fingerprint, "le domaine lie l’empreinte");
        Check.False(DomeniaDatabase.SharedParkLocalFingerprint(db.StoreId, Fixtures.Root, 0, 0, false, new string('A', 64)) == first.Fingerprint, "l’empreinte exhaustive des lignes lie l’empreinte");
        Check.Equal(DomeniaDatabase.SharedParkLocalFingerprint(db.StoreId, Fixtures.Root, 0, 0, false, rows), first.Fingerprint, "et elle reste reproductible");
    }

    [Test]
    public static async Task A_d1_extension_changes_the_row_fingerprint_and_the_bound_fingerprint()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        var before = await db.ReadSharedParkLocalAsync(None);
        Script(db, "ALTER TABLE park_state ADD COLUMN extension BLOB;");
        Exec(db, "UPDATE park_state SET extension=?1;", new byte[] { 1, 2, 3 });
        var after = await db.ReadSharedParkLocalAsync(None);
        Check.False(after.Sweeps.Fingerprint == before.Sweeps.Fingerprint, "l’extension D1 entre dans l’empreinte des lignes");
        Check.False(after.Fingerprint == before.Fingerprint, "l’empreinte liée suit l’extension");
        Check.Equal(before.Sweeps.Rows[0].StorageKey, after.Sweeps.Rows[0].StorageKey, "même ligne originale");
        Check.Equal(before.Sweeps.Rows[0].Attempts, after.Sweeps.Rows[0].Attempts, "compteur conservé");
        Check.Equal(before.Sweeps.Rows[0].ComputerGuid, after.Sweeps.Rows[0].ComputerGuid, "aucune identité ajoutée par la relecture");
    }

    [Test]
    public static async Task Two_rows_with_the_same_name_keep_their_own_identities()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        var pc = Fixtures.Computer("PC1");
        AddIdentityColumns(db);
        InsertIdentified(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3, pc.ObjectGuid.ToString("D"), pc.DistinguishedName);
        Insert(db, "shared:PC1", "PC1", "2026-10-20T09:00:00Z", "PARTAGE_LU", null, 1);
        var read = await db.ReadSharedParkLocalAsync(None);
        Check.Equal(2, read.Sweeps.Rows.Length, "les deux lignes physiques sont conservées, sans écrasement ni réduction");
        var local = read.Sweeps.Rows.Single(r => r.StorageKey == "PC1");
        var external = read.Sweeps.Rows.Single(r => r.StorageKey == "shared:PC1");
        Check.Equal(local.Computer, external.Computer, "même nom, deux origines différentes");
        Check.Equal(pc.ObjectGuid, local.ComputerGuid ?? Guid.Empty, "identité prouvée pour la ligne locale");
        Check.Equal(pc.DistinguishedName, local.ComputerDn ?? string.Empty, "DN d’origine conservé");
        Check.Null(external.ComputerGuid, "aucun GUID déduit d’un nom partagé");
        Check.Null(external.ComputerDn, "aucun DN inventé pour l’observation externe");
        Check.True(local.PreservedFingerprint.Length == 64 && external.PreservedFingerprint.Length == 64, "empreintes de conservation portées par chaque ligne");
        Check.Equal("PARTAGE_LU", external.Status, "le mot du partage reste un mot, jamais une identité");
        Check.Equal(2, read.CodecLines().Length, "aucune sélection par nom avant le lot suivant");
    }

    [Test]
    public static async Task A_cancelled_read_touches_nothing()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-20T10:00:00Z", "SESSION", "alice", 3);
        var before = SHA256.HashData(File.ReadAllBytes(db.Path));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => db.ReadSharedParkLocalAsync(cancelled.Token), "une annulation préalable interrompt sans lire");
        Check.True(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "le fichier est resté octet pour octet identique");
    }
}
