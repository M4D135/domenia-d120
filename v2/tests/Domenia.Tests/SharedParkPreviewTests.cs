using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// The real preview that wires the qualified local read, the shared TSV read, the merge and the bounded spool into one compact
/// reference plus a held lease, on real temporary files only. It never publishes, never migrates, never invents an identity and never
/// touches the sources: the proposed bytes live only behind the lease handle and must be re-read. No AD, no share, no network here.
/// </summary>
internal static class SharedParkPreviewTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly DateTimeOffset T1 = new(2026, 10, 21, 16, 16, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset T1New = new(2026, 10, 21, 16, 17, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset T2 = new(2026, 10, 21, 16, 6, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset T3 = new(2026, 10, 21, 16, 21, 0, TimeSpan.Zero);
    private static readonly string EmptySha = SharedParkFile.Hash([]);

    private static DomeniaDatabase Fresh(TemporaryFolder folder, string name) => new(folder.File(name), Fixtures.Root, TestClock.Fixed());

    private static async Task<DomeniaDatabase> Native(TemporaryFolder folder, string name = "parc.db", FixedTimeProvider? clock = null)
    {
        var db = new DomeniaDatabase(folder.File(name), Fixtures.Root, clock ?? TestClock.Fixed());
        await db.InitializeAsync(None);
        return db;
    }

    private static void Insert(DomeniaDatabase db, string key, string name, string at, string status, string? user, int attempts)
    {
        using var store = new SqliteDatabase(db.Path, false);
        store.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES(?1,?2,?3,?4,?5,?6);", key, name, at, status, user, attempts);
    }

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

    private static void AddIdentityColumns(DomeniaDatabase db) => Script(db, "ALTER TABLE park_state ADD COLUMN computer_guid TEXT; ALTER TABLE park_state ADD COLUMN computer_dn TEXT;");

    private static void InsertIdentified(DomeniaDatabase db, string key, string name, string at, string status, string? user, int attempts, string guid, string dn)
    {
        using var store = new SqliteDatabase(db.Path, false);
        store.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts,computer_guid,computer_dn) VALUES(?1,?2,?3,?4,?5,?6,?7,?8);",
            key, name, at, status, user, attempts, guid, dn);
    }

    private static byte[] Tsv(params SharedParkLine[] lines) => SharedParkFile.Encode([.. lines]);

    private static int SpoolFiles(TemporaryFolder folder) => Directory.EnumerateFiles(folder.File("spool"), "*.sharedpark", SearchOption.AllDirectories).Count();

    private static (string Computer, string Status, DateTimeOffset At)[] ParseProposed(byte[] bytes)
    {
        var rows = new List<(string, string, DateTimeOffset)>();
        using var reader = new StringReader(Encoding.UTF8.GetString(bytes));
        while (reader.ReadLine() is { Length: > 0 } line)
        {
            var f = line.Split('\t');
            rows.Add((f[0], f[2], DateTimeOffset.Parse(f[1], CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal)));
        }
        return [.. rows];
    }

    [Test]
    public static async Task A_preview_merges_local_and_remote_into_a_reread_proposal_without_touching_the_sources()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        AddIdentityColumns(db);
        var pc1 = Fixtures.Computer("PC1");
        var pc2 = Fixtures.Computer("PC2");
        InsertIdentified(db, "PC1", "PC1", "2026-10-21T16:16:00Z", "SESSION", "alice", 3, pc1.ObjectGuid.ToString("D"), pc1.DistinguishedName);
        InsertIdentified(db, "PC2", "PC2", "2026-10-21T16:06:00Z", "SESSION", "bob", 2, pc2.ObjectGuid.ToString("D"), pc2.DistinguishedName);
        Exec(db, "UPDATE domenia_store_state SET revision=7;");
        var localBefore = await db.ReadSharedParkLocalAsync(None);
        Check.Equal(7L, localBefore.Revision, "la révision réellement relue est celle de la base");
        Check.Equal(pc1.ObjectGuid, localBefore.Sweeps.Rows.Single(x => x.StorageKey == "PC1").ComputerGuid ?? Guid.Empty, "le GUID local est réellement relu");
        Check.Equal(pc1.DistinguishedName, localBefore.Sweeps.Rows.Single(x => x.StorageKey == "PC1").ComputerDn ?? string.Empty, "le DN local est réellement relu");
        Check.Equal(pc2.ObjectGuid, localBefore.Sweeps.Rows.Single(x => x.StorageKey == "PC2").ComputerGuid ?? Guid.Empty, "le second GUID local est réellement relu");
        Check.Equal(pc2.DistinguishedName, localBefore.Sweeps.Rows.Single(x => x.StorageKey == "PC2").ComputerDn ?? string.Empty, "le second DN local est réellement relu");
        var tsv = folder.File("parc.tsv");
        File.WriteAllBytes(tsv, Tsv(
            new SharedParkLine("PC1", T1New, "CONFIRME", "carol", 4, "dc-1"),
            new SharedParkLine("PC2", T2, "CONFIRME", "erika", 9, "dc-1"),
            new SharedParkLine("PC3", T3, "CONFIRME", "dave", 1, "dc-1")));
        var dbBefore = SHA256.HashData(File.ReadAllBytes(db.Path));
        var tsvBefore = SHA256.HashData(File.ReadAllBytes(tsv));
        var session = WritePlans.NewId();
        var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), session, 7, None);
        try
        {
            var r = preview.Reference;
            Check.Equal(3, r.MergedRows, "trois lignes fusionnées");
            Check.Equal(1, r.Added, "un nom distant ajouté");
            Check.Equal(1, r.Replaced, "un nom remplacé par un distant plus récent");
            Check.True(r.LocalExists, "la base locale est présente");
            Check.True(r.RemoteExists, "le TSV est présent");
            Check.Equal(session, r.SessionId, "la session est liée");
            Check.Equal(7L, r.Epoch, "l’époque de source est liée");
            Check.Equal(7L, r.Revision, "la référence compacte porte la révision réellement relue");
            Check.Equal(db.StoreId, r.StoreId, "le store est lié");
            Check.Equal(Fixtures.Root, r.DomainDn, "le domaine est lié");
            Check.True(r.Path.EndsWith("parc.tsv", StringComparison.Ordinal), "le chemin canonique du TSV est lié, jamais un chemin de spool");
            var bytes = await preview.ReadProposedAsync(session, 7, None);
            Check.Equal(r.ProposedSha256, Convert.ToHexStringLower(SHA256.HashData(bytes)), "l’empreinte proposée est celle des octets réellement relus");
            Check.Equal(bytes.LongLength, r.PayloadBytes, "la taille proposée est celle des octets relus");
            var proposedText = Encoding.UTF8.GetString(bytes);
            Check.False(proposedText.Contains(pc1.ObjectGuid.ToString("D"), StringComparison.OrdinalIgnoreCase), "aucun GUID local n’est recopié depuis le TSV");
            Check.False(proposedText.Contains(pc1.DistinguishedName, StringComparison.Ordinal), "aucun DN local n’est recopié depuis le TSV");
            var rows = ParseProposed(bytes);
            Check.Equal(3, rows.Length, "trois lignes réellement présentes dans le spool");
            Check.Equal(T1New, rows.Single(x => x.Computer == "PC1").At, "le distant plus récent remplace la proposition");
            Check.Equal("CONFIRME", rows.Single(x => x.Computer == "PC1").Status, "la ligne gagnante est la distante");
            Check.Equal(T2, rows.Single(x => x.Computer == "PC2").At, "à date égale le local est gardé");
            Check.Equal("SESSION", rows.Single(x => x.Computer == "PC2").Status, "la ligne gagnante reste la locale");
            Check.True(rows.Any(x => x.Computer == "PC3"), "le nom distant ajouté est présent");
            Check.True(dbBefore.SequenceEqual(SHA256.HashData(File.ReadAllBytes(db.Path))), "la base est restée octet pour octet identique");
            Check.True(tsvBefore.SequenceEqual(SHA256.HashData(File.ReadAllBytes(tsv))), "le TSV est resté octet pour octet identique");
            Check.Equal(1, SpoolFiles(folder), "un seul spool créé");
            Check.Equal(0, Directory.EnumerateFiles(folder.Path, "*.lock", SearchOption.AllDirectories).Count(), "aucun verrou créé");
        }
        finally
        {
            preview.Dispose();
        }
        Check.False(Directory.EnumerateFiles(folder.File("spool"), "*.sharedpark", SearchOption.AllDirectories).Any(), "le spool disparaît avec la lease");
    }

    [Test]
    public static async Task An_absent_local_with_a_present_survey_merges_remote_only()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "absent.db");
        var tsv = folder.File("parc.tsv");
        File.WriteAllBytes(tsv, Tsv(new SharedParkLine("PC1", T3, "CONFIRME", "alice", 1, null), new SharedParkLine("PC2", T3, "CONFIRME", "bob", 1, null)));
        var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), WritePlans.NewId(), 7, None);
        try
        {
            var r = preview.Reference;
            Check.False(r.LocalExists, "base absente");
            Check.True(r.RemoteExists, "TSV présent");
            Check.Equal(2, r.MergedRows, "les deux lignes distantes");
            Check.Equal(2, r.Added, "deux ajouts");
            Check.Equal(0, r.Replaced, "aucun remplacement");
            Check.False(File.Exists(db.Path), "aucune base n’est créée par l’aperçu");
        }
        finally
        {
            preview.Dispose();
        }
    }

    [Test]
    public static async Task An_absent_survey_with_a_present_base_merges_local_only()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-21T16:16:00Z", "SESSION", "alice", 3);
        var preview = await db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, None);
        try
        {
            var r = preview.Reference;
            Check.True(r.LocalExists, "base présente");
            Check.False(r.RemoteExists, "TSV absent");
            Check.Equal(EmptySha, r.RemoteSha256, "le SHA du distant absent est celui du vide");
            Check.Equal(1, r.MergedRows, "la seule ligne locale");
            Check.Equal(0, r.Added, "aucun ajout");
            Check.Equal(0, r.Replaced, "aucun remplacement");
            Check.False(File.Exists(folder.File("parc.tsv")), "aucun TSV n’est créé");
        }
        finally
        {
            preview.Dispose();
        }
    }

    [Test]
    public static async Task When_both_are_absent_the_proposal_is_empty_and_nothing_is_created()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "absent.db");
        var preview = await db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, None);
        try
        {
            var r = preview.Reference;
            Check.False(r.LocalExists, "base absente");
            Check.False(r.RemoteExists, "TSV absent");
            Check.Equal(0, r.MergedRows, "aucune ligne proposée");
            Check.Equal(0, r.Added, "aucun ajout");
            Check.Equal(0, r.Replaced, "aucun remplacement");
            Check.Equal(EmptySha, r.ProposedSha256, "l’empreinte du vide proposé");
            Check.False(File.Exists(db.Path), "aucune base créée");
            Check.False(File.Exists(folder.File("parc.tsv")), "aucun TSV créé");
            Check.Equal(0, Directory.EnumerateFiles(folder.Path, "*.lock", SearchOption.AllDirectories).Count(), "aucun verrou créé");
            Check.Equal(1, SpoolFiles(folder), "un spool du vide est pourtant tenu");
        }
        finally
        {
            preview.Dispose();
        }
    }

    [Test]
    public static async Task A_brand_new_profile_with_missing_parents_is_a_real_absence_without_creating_the_base()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, Path.Combine("newprofile", "parc.db"));
        var tsv = folder.File("parc.tsv");
        File.WriteAllBytes(tsv, Tsv(new SharedParkLine("PC1", T3, "CONFIRME", "alice", 1, null)));
        var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), WritePlans.NewId(), 7, None);
        try
        {
            Check.False(preview.Reference.LocalExists, "un profil neuf reste une vraie absence");
            Check.Equal(1, preview.Reference.MergedRows, "la fusion repart du seul distant");
        }
        finally
        {
            preview.Dispose();
        }
        Check.False(Directory.Exists(folder.File("newprofile")), "aucun répertoire parent n’est créé");
        Check.False(File.Exists(db.Path), "aucune base n’est créée");
    }

    [Test]
    public static async Task A_brand_new_profile_with_two_missing_parents_is_a_real_absence_without_creating_them()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, Path.Combine("newprofile", "missing", "parc.db"));
        var tsv = folder.File("parc.tsv");
        File.WriteAllBytes(tsv, Tsv(new SharedParkLine("PC1", T3, "CONFIRME", "alice", 1, null)));
        var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), WritePlans.NewId(), 7, None);
        try
        {
            Check.False(preview.Reference.LocalExists, "deux parents manquants sous un dossier qualifié restent une vraie absence");
            Check.Equal(1, preview.Reference.MergedRows, "la fusion repart du seul distant");
        }
        finally
        {
            preview.Dispose();
        }
        Check.False(Directory.Exists(folder.File("newprofile")), "aucun premier parent manquant n’est créé");
        Check.False(Directory.Exists(folder.File(Path.Combine("newprofile", "missing"))), "aucun second parent manquant n’est créé");
        Check.False(File.Exists(db.Path), "aucune base n’est créée");
    }

    [Test]
    public static async Task A_directory_where_the_base_belongs_is_refused_not_read_as_absent()
    {
        using var folder = new TemporaryFolder();
        var directory = folder.File("corrompue.db");
        Directory.CreateDirectory(directory);
        var db = new DomeniaDatabase(directory, Fixtures.Root, TestClock.Fixed());
        await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, None),
            "un dossier à la place de la base est refusé, jamais lu comme une absence");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool créé");
    }

    [Test]
    public static async Task A_non_directory_parent_is_refused()
    {
        using var folder = new TemporaryFolder();
        var fileParent = folder.File("fichier");
        File.WriteAllBytes(fileParent, new byte[] { 1, 2, 3 });
        var db = new DomeniaDatabase(Path.Combine(fileParent, "parc.db"), Fixtures.Root, TestClock.Fixed());
        await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, None),
            "un parent qui n’est pas un répertoire est refusé");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool créé");
    }

    [Test]
    public static async Task A_non_directory_ancestor_two_levels_above_the_base_is_refused()
    {
        using var folder = new TemporaryFolder();
        var fileAncestor = folder.File("ancetre");
        File.WriteAllBytes(fileAncestor, new byte[] { 1, 2, 3 });
        var db = new DomeniaDatabase(Path.Combine(fileAncestor, "enfant", "petit-fils", "parc.db"), Fixtures.Root, TestClock.Fixed());
        var baselineLeases = SharedParkPreviewFile.ActiveLeases;
        var baselineBytes = SharedParkPreviewFile.ReservedBytes;
        var ex = await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, None),
            "un ancêtre fichier suivi de deux niveaux manquants n’est jamais une absence de profil");
        Check.Contains("n’est pas un répertoire", ex.Message, "le refus nomme l’ancêtre non répertoire");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool créé");
        Check.Equal(baselineLeases, SharedParkPreviewFile.ActiveLeases, "aucune réservation ne fuit");
        Check.Equal(baselineBytes, SharedParkPreviewFile.ReservedBytes, "aucun octet n’est réservé");
    }

    [Test]
    public static async Task A_present_but_foreign_base_is_refused_never_read_as_absent()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-21T16:16:00Z", "SESSION", "alice", 3);
        Exec(db, "UPDATE domenia_store_state SET store_id=?1;", new string('0', 64));
        var ex = await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, None),
            "une base présente mais étrangère est refusée, jamais réduite à Exists=false");
        Check.Contains("autre", ex.Message, "le refus nomme l’étrangeté de la base");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool retenu");
    }

    [Test]
    public static async Task A_non_sqlite_base_is_refused_and_no_reservation_is_retained()
    {
        using var folder = new TemporaryFolder();
        var corrupt = folder.File("corrompue.db");
        File.WriteAllBytes(corrupt, Encoding.UTF8.GetBytes("ceci n’est pas une base SQLite"));
        var corruptBefore = SHA256.HashData(File.ReadAllBytes(corrupt));
        var db = new DomeniaDatabase(corrupt, Fixtures.Root, TestClock.Fixed());
        var baselineLeases = SharedParkPreviewFile.ActiveLeases;
        var baselineBytes = SharedParkPreviewFile.ReservedBytes;
        var ex = await Check.ThrowsAsync<SqliteStoreException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, None),
            "une base illisible refuse tout l’aperçu, jamais Exists=false");
        Check.Equal(26, ex.SqliteCode & 255, "le refus vient du code primaire SQLite SQLITE_NOTADB");
        Check.True(corruptBefore.SequenceEqual(SHA256.HashData(File.ReadAllBytes(corrupt))), "la base illisible reste intacte");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool retenu");
        Check.Equal(baselineLeases, SharedParkPreviewFile.ActiveLeases, "aucune réservation ne fuit");
        Check.Equal(baselineBytes, SharedParkPreviewFile.ReservedBytes, "aucun octet n’est réservé");
    }

    [Test]
    public static async Task A_malformed_survey_is_refused_and_no_spool_is_retained()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-21T16:16:00Z", "SESSION", "alice", 3);
        var tsv = folder.File("parc.tsv");
        File.WriteAllText(tsv, "mauvaise\nligne\there\n");
        await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), WritePlans.NewId(), 7, None),
            "un TSV malformé refuse tout l’aperçu");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool retenu");
    }

    [Test]
    public static async Task A_survey_colliding_with_the_spool_or_a_protected_path_is_refused_before_any_read()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "parc.db");
        var spool = folder.File("spool");
        await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(Path.Combine(spool, "parc.tsv"), [], [], spool, WritePlans.NewId(), 7, None),
            "le TSV ne peut pas viser le répertoire de spool");
        var config = folder.File("Domenia.config.json");
        File.WriteAllText(config, "{}");
        await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(config, [config], [], spool, WritePlans.NewId(), 7, None),
            "le TSV ne peut pas viser un fichier de configuration protégé");
        Check.False(Directory.Exists(spool), "refusé avant toute création de spool");
        Check.False(File.Exists(db.Path), "refusé avant toute lecture/création de la base");
    }

    [Test]
    public static async Task An_invalid_session_or_epoch_is_refused_before_any_access()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "parc.db");
        await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), "pas-un-identifiant", 7, None),
            "une session hors WritePlans est refusée");
        await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), -1, None),
            "une époque négative est refusée");
        Check.False(Directory.Exists(folder.File("spool")), "aucun accès, aucune création");
        Check.False(File.Exists(db.Path), "aucune base créée");
    }

    [Test]
    public static async Task An_invalid_local_spool_is_refused_before_the_tsv_is_read()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "parc.db");
        var tsv = folder.File("parc.tsv");
        File.WriteAllText(tsv, "mauvaise\nligne\there\n");
        var baselineLeases = SharedParkPreviewFile.ActiveLeases;
        var baselineBytes = SharedParkPreviewFile.ReservedBytes;
        var ex = await Check.ThrowsAsync<InvalidDataException>(() => db.PreviewSharedParkAsync(tsv, [], [], @"\\serveur\partage\spool", WritePlans.NewId(), 7, None),
            "le spool local est qualifié avant toute lecture du TSV");
        Check.Contains("disque local", ex.Message, "le refus nomme le spool local, pas le TSV malformé");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool local créé");
        Check.True(File.ReadAllBytes(tsv).Length > 0, "le TSV malformé reste intact");
        Check.Equal(baselineLeases, SharedParkPreviewFile.ActiveLeases, "aucune réservation ne fuit");
        Check.Equal(baselineBytes, SharedParkPreviewFile.ReservedBytes, "aucun octet n’est réservé");
    }

    [Test]
    public static async Task A_pre_cancelled_preview_never_reads_nor_creates()
    {
        using var folder = new TemporaryFolder();
        var db = Fresh(folder, "parc.db");
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => db.PreviewSharedParkAsync(folder.File("parc.tsv"), [], [], folder.File("spool"), WritePlans.NewId(), 7, cancelled.Token),
            "une annulation préalable n’engage rien");
        Check.False(Directory.Exists(folder.File("spool")), "aucun spool créé");
        Check.False(File.Exists(db.Path), "aucune base créée");
    }

    [Test]
    public static async Task The_held_proposal_refuses_another_session_or_epoch()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-21T16:16:00Z", "SESSION", "alice", 3);
        var tsv = folder.File("parc.tsv");
        File.WriteAllBytes(tsv, Tsv(new SharedParkLine("PC2", T3, "CONFIRME", "bob", 1, null)));
        var session = WritePlans.NewId();
        var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), session, 7, None);
        try
        {
            await Check.ThrowsAsync<InvalidDataException>(() => preview.ReadProposedAsync(WritePlans.NewId(), 7, None), "une autre session que celle liée ne relit pas");
            await Check.ThrowsAsync<InvalidDataException>(() => preview.ReadProposedAsync(session, 8, None), "une autre époque que celle liée ne relit pas");
            var bytes = await preview.ReadProposedAsync(session, 7, None);
            Check.True(bytes.Length > 0, "le bon contexte relit réellement les octets proposés");
        }
        finally
        {
            preview.Dispose();
        }
    }

    [Test]
    public static async Task Abandoning_the_preview_closes_its_lease_and_frees_the_reservation()
    {
        using var folder = new TemporaryFolder();
        var db = await Native(folder);
        Insert(db, "PC1", "PC1", "2026-10-21T16:16:00Z", "SESSION", "alice", 3);
        var tsv = folder.File("parc.tsv");
        File.WriteAllBytes(tsv, Tsv(new SharedParkLine("PC2", T3, "CONFIRME", "bob", 1, null)));
        var baselineLeases = SharedParkPreviewFile.ActiveLeases;
        var baselineBytes = SharedParkPreviewFile.ReservedBytes;
        var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), WritePlans.NewId(), 7, None);
        var spoolFile = Directory.EnumerateFiles(folder.File("spool"), "*.sharedpark", SearchOption.AllDirectories).Single();
        Check.Equal(baselineLeases + 1, SharedParkPreviewFile.ActiveLeases, "une lease de plus est tenue");
        Check.True(SharedParkPreviewFile.ReservedBytes > baselineBytes, "les octets de ce spool sont réservés");
        preview.Dispose();
        Check.False(File.Exists(spoolFile), "l’abandon ferme et supprime le seul fichier possédé");
        Check.Equal(baselineLeases, SharedParkPreviewFile.ActiveLeases, "la réservation est rendue");
        Check.Equal(baselineBytes, SharedParkPreviewFile.ReservedBytes, "les octets sont rendus");
        await Check.ThrowsAsync<InvalidDataException>(() => preview.ReadProposedAsync(preview.Reference.SessionId, preview.Reference.Epoch, None),
            "une lecture après abandon est refusée par les gardes du spool, sans réouverture par le nom");
    }

    [Test]
    public static async Task An_expired_preview_invalidates_its_read_and_frees_the_reservation()
    {
        using var folder = new TemporaryFolder();
        var clock = TestClock.Fixed();
        var db = await Native(folder, "parc.db", clock);
        Insert(db, "PC1", "PC1", "2026-10-21T16:16:00Z", "SESSION", "alice", 3);
        var tsv = folder.File("parc.tsv");
        File.WriteAllBytes(tsv, Tsv(new SharedParkLine("PC2", T3, "CONFIRME", "bob", 1, null)));
        var session = WritePlans.NewId();
        var baselineLeases = SharedParkPreviewFile.ActiveLeases;
        var baselineBytes = SharedParkPreviewFile.ReservedBytes;
        var preview = await db.PreviewSharedParkAsync(tsv, [], [], folder.File("spool"), session, 7, None);
        var spoolFile = Directory.EnumerateFiles(folder.File("spool"), "*.sharedpark", SearchOption.AllDirectories).Single();
        Check.Equal(baselineLeases + 1, SharedParkPreviewFile.ActiveLeases, "une lease de plus est tenue");
        Check.True(SharedParkPreviewFile.ReservedBytes > baselineBytes, "les octets de ce spool sont réservés");
        clock.Advance(TimeSpan.FromMinutes(11));
        var ex = await Check.ThrowsAsync<InvalidDataException>(() => preview.ReadProposedAsync(session, 7, None), "l’horizon dépassé refuse la relecture");
        Check.Contains("expiré", ex.Message, "le refus nomme l’expiration");
        Check.False(File.Exists(spoolFile), "la lease expirée a fermé et supprimé son propre fichier");
        Check.Equal(baselineLeases, SharedParkPreviewFile.ActiveLeases, "la réservation a été rendue");
        Check.Equal(baselineBytes, SharedParkPreviewFile.ReservedBytes, "les octets ont été rendus");
        preview.Dispose();
    }

    [Test]
    public static void The_compact_reference_serializes_without_payload_and_binds_every_scalar_in_its_fingerprint()
    {
        var batch = new SharedParkBatch("0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210", 7, @"C:\domenia-tests\parc.tsv",
            new string('0', 64), Fixtures.Root, 3, 3, true, false, new string('a', 64), new string('b', 64), true, new string('c', 64),
            T1, T3, 3, 120, new string('d', 64), 1, 1);
        Check.Equal(SharedParkIdentity.Fingerprint(batch), SharedParkIdentity.Fingerprint(batch), "mêmes scalaires, même empreinte");
        Check.False(SharedParkIdentity.Fingerprint(batch with { LocalExists = false }) == SharedParkIdentity.Fingerprint(batch), "l’existence locale lie l’empreinte");
        Check.False(SharedParkIdentity.Fingerprint(batch with { RemoteExists = false }) == SharedParkIdentity.Fingerprint(batch), "l’existence distante lie l’empreinte");
        Check.False(SharedParkIdentity.Fingerprint(batch with { Epoch = 8 }) == SharedParkIdentity.Fingerprint(batch), "l’époque lie l’empreinte");
        Check.False(SharedParkIdentity.Fingerprint(batch with { SessionId = "00000000000000000000000000000000" }) == SharedParkIdentity.Fingerprint(batch), "la session lie l’empreinte");
        Check.False(SharedParkIdentity.Fingerprint(batch with { Generation = 4 }) == SharedParkIdentity.Fingerprint(batch), "la génération lie l’empreinte");
        Check.False(SharedParkIdentity.Fingerprint(batch with { RemoteSha256 = new string('e', 64) }) == SharedParkIdentity.Fingerprint(batch), "le SHA distant lie l’empreinte");
        Check.False(SharedParkIdentity.Fingerprint(batch with { ProposedSha256 = new string('e', 64) }) == SharedParkIdentity.Fingerprint(batch), "le SHA proposé lie l’empreinte");
        var presentEmpty = batch with { RemoteExists = true, RemoteSha256 = EmptySha };
        var absentEmpty = batch with { RemoteExists = false, RemoteSha256 = EmptySha };
        Check.False(SharedParkIdentity.Fingerprint(presentEmpty) == SharedParkIdentity.Fingerprint(absentEmpty), "absent n’est jamais confondu avec un présent au même SHA vide");
        var json = Encoding.UTF8.GetString(JsonSerializer.SerializeToUtf8Bytes(batch));
        Check.False(json.Contains('['), "aucune collection ni payload sérialisé");
        Check.False(json.Contains(".sharedpark", StringComparison.Ordinal), "aucun chemin de spool exposé");
        Check.False(json.Contains("spool", StringComparison.OrdinalIgnoreCase), "aucun chemin de spool exposé");
    }
}
