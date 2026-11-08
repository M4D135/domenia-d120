using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// Explicit read of the shared survey: the lexical validator never touches the disk or the network (an UNC included is only a
/// string), and the read runs off the UI thread behind real attribute guards on the file and on every parent. Nothing is created,
/// no access error becomes an absence, no reparse point is crossed, and the bytes of the other console are never rewritten.
/// </summary>
internal static class SharedParkRemoteReadTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly DateTimeOffset Now = TestClock.Reference;
    private static readonly UTF8Encoding NoMark = new(false, false);
    private static readonly byte[] Mark = [0xEF, 0xBB, 0xBF];
    private static readonly string Db = @"C:\domenia-tests\base.sqlite";

    private static string Line(string computer, DateTimeOffset at, string status, string? user, int attempts)
        => string.Join('\t', computer, at.ToString("O", CultureInfo.InvariantCulture), status, user ?? string.Empty, attempts.ToString(CultureInfo.InvariantCulture));

    private static byte[] BytesWithMark(string text)
    {
        var body = NoMark.GetBytes(text);
        var bytes = new byte[Mark.Length + body.Length];
        Mark.AsSpan().CopyTo(bytes);
        body.CopyTo(bytes, Mark.Length);
        return bytes;
    }

    private static string Validate(string path, string? db = null, ImmutableArray<string>? configs = null, ImmutableArray<string>? protectedDirectories = null)
        => SharedParkRemoteReader.Validate(path, db ?? Db, configs ?? [], protectedDirectories ?? [], None);

    private static Task<SharedParkRemoteRead> Read(string path, TemporaryFolder folder, ImmutableArray<string>? configs = null, ImmutableArray<string>? protectedDirectories = null)
        => SharedParkRemoteReader.ReadAsync(path, folder.File("base.sqlite"), configs ?? [], protectedDirectories ?? [], Now, None);

    [Test]
    public static void A_local_and_an_explicit_UNC_path_are_lexically_valid_without_any_access()
    {
        Check.Equal(@"C:\domenia\parc.tsv", Validate(@"C:\domenia\parc.tsv"), "un chemin absolu local ordinaire est qualifié et rendu canonique");
        Check.Equal(@"\\serveur\partage\parc.tsv", Validate(@"\\serveur\partage\parc.tsv"), "un partage UNC explicite est qualifié sans jamais ouvrir le partage");
        Check.Equal(@"\\serveur\partage\sous\parc.tsv", Validate(@"\\serveur\partage\sous\parc.tsv"), "des sous-répertoires du partage restent lexicaux");
    }

    [Test]
    public static void Relative_device_ADS_root_and_ambiguous_components_are_refused()
    {
        Check.Throws<InvalidDataException>(() => Validate(string.Empty), "un chemin vide n’est pas un chemin");
        Check.Throws<InvalidDataException>(() => Validate("parc.tsv"), "un chemin relatif est refusé, rien n’est complété en silence");
        Check.Throws<InvalidDataException>(() => Validate(@"\\?\C:\domenia\parc.tsv"), "un préfixe d’étendue est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"\\.\C:\domenia\parc.tsv"), "un chemin de périphérique est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"\\.\physicaldrive0\parc.tsv"), "un disque physique n’est pas un partage");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\parc.tsv:secret"), "un flux de données alternatif est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\"), "la racine seule n’est pas un fichier ordinaire");
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur\partage"), "le partage seul est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur"), "le serveur seul n’est pas une origine de fichier");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\..\parc.tsv"), "dotdot est refusé, jamais normalisé pour devenir acceptable");
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur\partage\..\parc.tsv"), "dotdot est refusé aussi sur un partage");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\.\parc.tsv"), "dot est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\\parc.tsv"), "un séparateur doublé est un composant ambigu");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\parc.tsv "), "un espace final n’est pas rogné en silence");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\parc.tsv."), "un point final n’est pas rogné en silence");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\pa>rc.tsv"), "un caractère interdit est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\parc|1.tsv"), "un second caractère interdit est refusé");
    }

    [Test]
    public static void Dos_reserved_device_names_are_refused_in_any_component()
    {
        Check.Throws<InvalidDataException>(() => Validate(@"C:\CON\parc.tsv"), "un nom réservé de périphérique DOS est refusé même comme répertoire");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\nul.tsv"), "NUL avec extension reste réservé");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia\COM2.tsv"), "COM2 est refusé");
        Check.Throws<InvalidDataException>(() => Validate("C:\\domenia\\COM\u00B9.tsv"), "COM avec exposant 1 (U+00B9) est refusé comme COM1");
        Check.Throws<InvalidDataException>(() => Validate("C:\\domenia\\COM\u00B2.tsv"), "COM avec exposant 2 (U+00B2) est refusé comme COM2");
        Check.Throws<InvalidDataException>(() => Validate("C:\\domenia\\COM\u00B3.tsv"), "COM avec exposant 3 (U+00B3) est refusé comme COM3");
        Check.Throws<InvalidDataException>(() => Validate("C:\\domenia\\LPT\u00B9.tsv"), "LPT avec exposant 1 (U+00B9) est refusé comme LPT1");
        Check.Throws<InvalidDataException>(() => Validate("C:\\domenia\\LPT\u00B2.tsv"), "LPT avec exposant 2 (U+00B2) est refusé comme LPT2");
        Check.Throws<InvalidDataException>(() => Validate("C:\\domenia\\LPT\u00B3.tsv"), "LPT avec exposant 3 (U+00B3) est refusé comme LPT3");
        Check.Equal("C:\\domenia\\COM\u2081.tsv", Validate("C:\\domenia\\COM\u2081.tsv"), "l’indice ₁ (U+2081) n’est pas un nom réservé : COM₁.tsv reste un voisin ordinaire");
        Check.Equal("C:\\domenia\\LPT\u2083.tsv", Validate("C:\\domenia\\LPT\u2083.tsv"), "l’indice ₃ (U+2083) n’est pas un nom réservé : LPT₃.tsv reste un voisin ordinaire");
        Check.Equal(@"C:\domenia\console.tsv", Validate(@"C:\domenia\console.tsv"), "un nom ordinaire qui ressemble à un réservé reste valable");
        Check.Equal(@"C:\domenia\COMX.tsv", Validate(@"C:\domenia\COMX.tsv"), "un nom voisin de COM mais non réservé reste valable");
    }

    [Test]
    public static void UNC_server_and_share_names_follow_the_same_ambiguity_rules()
    {
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur\..\parc.tsv"), "dotdot comme nom de partage est refusé, sans accès réseau");
        Check.Throws<InvalidDataException>(() => Validate(@"\\..\partage\parc.tsv"), "dotdot comme nom de serveur est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur\partage.\parc.tsv"), "point final sur le partage est refusé, jamais rogné");
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur\partage \parc.tsv"), "espace final sur le partage est refusé, jamais rogné");
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur.\partage\parc.tsv"), "point final sur le serveur est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"\\CON\partage\parc.tsv"), "nom de périphérique DOS réservé comme serveur est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"\\serveur\con\parc.tsv"), "nom de périphérique DOS réservé comme partage est refusé");
        Check.Equal(@"\\serveur.local\partage.données\parc.tsv", Validate(@"\\serveur.local\partage.données\parc.tsv"),
            "un serveur et un partage ordinaires avec des points internes restent valables");
    }

    [Test]
    public static void The_active_base_and_its_sidecars_are_refused_whatever_the_case()
    {
        var db = @"C:\domenia-tests\base.sqlite";
        Check.Throws<InvalidDataException>(() => Validate(db, db), "le TSV ne peut pas viser la base active");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\DOMENIA-TESTS\BASE.SQLITE", db), "la collision avec la base se juge sans distinction de casse");
        Check.Throws<InvalidDataException>(() => Validate(db + "-wal", db), "le sidecar -wal est refusé");
        Check.Throws<InvalidDataException>(() => Validate(db + "-shm", db), "le sidecar -shm est refusé");
        Check.Throws<InvalidDataException>(() => Validate(db + "-journal", db), "le sidecar -journal est refusé");
        Check.Throws<InvalidDataException>(() => Validate(db + ".lock", db), "le fichier de verrou de la base est refusé");
        Check.Equal(@"C:\domenia-tests\parc.tsv", Validate(@"C:\domenia-tests\parc.tsv", db), "un fichier voisin de la base reste valable");
    }

    [Test]
    public static void A_protected_config_file_is_refused_on_the_exact_collision_whatever_the_case()
    {
        var configs = ImmutableArray.Create(@"C:\domenia-tests\Domenia.config.json");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\Domenia.config.json", configs: configs), "un fichier de configuration protégé ne peut pas être le TSV");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\DOMENIA-TESTS\DOMENIA.CONFIG.JSON", configs: configs), "la collision exacte se juge sans distinction de casse");
        Check.Equal(@"C:\domenia-tests\Domenia.config.json.bak", Validate(@"C:\domenia-tests\Domenia.config.json.bak", configs: configs), "un nom différent reste valable");
    }

    [Test]
    public static void A_descendant_of_a_protected_directory_is_refused_and_a_like_prefixed_neighbor_is_allowed()
    {
        var protectedDirectories = ImmutableArray.Create(@"C:\domenia-tests\Backups");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\Backups\parc.tsv", protectedDirectories: protectedDirectories), "un descendant de Backups est refusé");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\Backups\Sous\parc.tsv", protectedDirectories: protectedDirectories), "et chaque niveau plus profond aussi");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\backups\parc.tsv", protectedDirectories: protectedDirectories), "la frontière se juge sans distinction de casse");
        Check.Equal(@"C:\domenia-tests\Backups-voisin\parc.tsv", Validate(@"C:\domenia-tests\Backups-voisin\parc.tsv", protectedDirectories: protectedDirectories),
            "le voisin au préfixe semblable n’est pas pris par la limite du répertoire protégé");
    }

    [Test]
    public static void Missing_protections_and_oversized_lists_are_refused_rather_than_ignored()
    {
        Check.Throws<InvalidDataException>(() => SharedParkRemoteReader.Validate(@"C:\domenia-tests\parc.tsv", Db, default, [], None), "un tableau de configurations default est refusé, pas ignoré");
        Check.Throws<InvalidDataException>(() => SharedParkRemoteReader.Validate(@"C:\domenia-tests\parc.tsv", Db, [], default, None), "un tableau de répertoires protégés default est refusé, pas ignoré");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\parc.tsv", configs: [null!]), "une entrée absente est refusée, pas ignorée");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\parc.tsv", configs: ["parc.json"]), "une identité de chemin invalide est refusée");
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\parc.tsv", db: string.Empty), "une base sans identité est refusée");
        var many = ImmutableArray.CreateRange(Enumerable.Range(0, SharedParkRemoteReader.MaxProtectedEntries + 1)
            .Select(i => @"C:\domenia-tests\prot-" + i.ToString(CultureInfo.InvariantCulture)));
        Check.Throws<InvalidDataException>(() => Validate(@"C:\domenia-tests\parc.tsv", protectedDirectories: many), "une liste au-delà de la borne est refusée");
        Check.Equal(@"C:\domenia-tests\parc.tsv", Validate(@"C:\domenia-tests\parc.tsv", configs: [], protectedDirectories: []),
            "des listes vides disent explicitement qu’il n’y a rien à protéger : ce n’est pas une protection absente");
    }

    [Test]
    public static async Task A_valid_local_TSV_reads_with_the_sha_of_the_original_bytes_including_the_mark()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("parc.tsv");
        var bytes = BytesWithMark(Line("POSTE-1", Now, "CONFIRME", "élodie.martin", 3) + "\n");
        File.WriteAllBytes(path, bytes);
        var read = await Read(path, folder);
        Check.True(read.Exists, "le relevé existe");
        Check.Equal(System.IO.Path.GetFullPath(path), read.Path, "le chemin canonique qualifié est associé au résultat");
        Check.True(bytes.SequenceEqual(read.Bytes), "les octets sont ceux du fichier, préambule compris, sans duplication");
        Check.Equal(SharedParkFile.Hash(bytes), read.Sha256, "l’empreinte porte sur les octets originaux, BOM inclus");
        Check.Equal(1, read.Rows.Length, "la ligne est décodée au-delà du préambule");
        Check.Equal("POSTE-1", read.Rows[0].Computer, "le nom est conservé");
        Check.False(File.Exists(path + ".lock"), "la lecture ne pose aucun verrou");
    }

    [Test]
    public static async Task An_empty_present_file_stays_distinct_from_an_absent_one()
    {
        using var folder = new TemporaryFolder();
        var empty = folder.File("vide.tsv");
        File.WriteAllBytes(empty, []);
        var present = await Read(empty, folder);
        var absent = await Read(folder.File("absent.tsv"), folder);
        Check.True(present.Exists, "un fichier vide présent n’est pas un fichier absent");
        Check.False(absent.Exists, "seul le fichier terminal réellement absent, sous parents qualifiés, se lit comme absent");
        Check.Equal(0, present.Bytes.Length, "aucun octet présent");
        Check.Equal(0, absent.Bytes.Length, "aucun octet absent");
        Check.Equal(SharedParkFile.Hash([]), present.Sha256, "la même empreinte du vide");
        Check.Equal(SharedParkFile.Hash([]), absent.Sha256, "qui seule ne distinguerait rien : c’est Exists qui distingue");
        Check.False(File.Exists(absent.Path), "la lecture d’un absent n’a rien créé");
    }

    [Test]
    public static async Task An_absent_parent_and_a_directory_target_are_refused()
    {
        using var folder = new TemporaryFolder();
        var under = folder.File("sous-dossier-absent");
        var ex = await Check.ThrowsAsync<InvalidDataException>(() => Read(Path.Combine(under, "parc.tsv"), folder), "un parent manquant est refusé, jamais lu comme un absent");
        Check.Contains("Parent", ex.Message, "le refus nomme la cause");
        var dossier = folder.File("dossier");
        Directory.CreateDirectory(dossier);
        await Check.ThrowsAsync<InvalidDataException>(() => Read(dossier, folder), "une cible qui est un dossier est refusée");
    }

    [Test]
    public static async Task Invalid_data_is_refused_without_rewriting_the_file()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("ambigu.tsv");
        var bytes = NoMark.GetBytes("POSTE-1\t" + Now.ToString("O", CultureInfo.InvariantCulture) + "\tCONFIRME\talm\t2\tconsole\textra\n");
        File.WriteAllBytes(path, bytes);
        await Check.ThrowsAsync<InvalidDataException>(() => Read(path, folder), "une ligne mal formée est refusée");
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(path)), "les octets de l’autre console restent intacts, aucune réécriture");
    }

    [Test]
    public static async Task A_pre_cancelled_read_creates_nothing()
    {
        using var folder = new TemporaryFolder();
        var path = Path.Combine(folder.File("nouveau"), "parc.tsv");
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => SharedParkRemoteReader.ReadAsync(path, folder.File("base.sqlite"), [], [], Now, cancelled.Token),
            "une annulation préalable interrompt sans lire");
        Check.False(Directory.Exists(System.IO.Path.GetDirectoryName(path)!), "aucun dossier n’a été créé");
        Check.False(File.Exists(path), "aucun fichier n’a été créé");
    }

    [Test]
    public static async Task A_directory_link_on_the_way_is_refused_by_the_read_guard()
    {
        using var folder = new TemporaryFolder();
        var real = folder.File("reel");
        Directory.CreateDirectory(real);
        File.WriteAllBytes(Path.Combine(real, "parc.tsv"), NoMark.GetBytes(Line("POSTE-1", Now, "LU", null, 0) + "\n"));
        var link = folder.File("lien");
        Directory.CreateSymbolicLink(link, real);
        try
        {
            var ex = await Check.ThrowsAsync<InvalidDataException>(() => Read(Path.Combine(link, "parc.tsv"), folder),
                "un lien symbolique de répertoire sur le chemin est refusé par la garde de lecture ; cette garde n’est pas un verrou, elle arrête la lecture");
            Check.Contains("point d’analyse", ex.Message, "le refus nomme la cause");
        }
        finally
        {
            Directory.Delete(link);
        }
    }
}
