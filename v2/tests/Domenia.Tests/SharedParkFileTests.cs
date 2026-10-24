using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>
/// The bounded D1 TSV of the shared park survey, on real local temporary files. The file carries names and the words of the console
/// that wrote it, never a certified AD identity: a refusal leaves the bytes of the other console untouched and never steals a lock.
/// </summary>
internal static class SharedParkFileTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 21, 16, 26, 0, TimeSpan.Zero);
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly UTF8Encoding NoMark = new(false, false);
    private static readonly byte[] Mark = [0xEF, 0xBB, 0xBF];

    private static string Line(string computer, DateTimeOffset at, string status, string? user, int attempts, string? probedBy = null)
        => probedBy is null
            ? string.Join('\t', computer, at.ToString("O", CultureInfo.InvariantCulture), status, user ?? string.Empty, attempts.ToString(CultureInfo.InvariantCulture))
            : string.Join('\t', computer, at.ToString("O", CultureInfo.InvariantCulture), status, user ?? string.Empty, attempts.ToString(CultureInfo.InvariantCulture), probedBy);

    private static string Write(TemporaryFolder folder, string text)
    {
        var path = folder.File("parc-" + Guid.NewGuid().ToString("N") + ".tsv");
        File.WriteAllBytes(path, NoMark.GetBytes(text));
        return path;
    }

    private static string Write(TemporaryFolder folder, byte[] bytes)
    {
        var path = folder.File("parc-" + Guid.NewGuid().ToString("N") + ".tsv");
        File.WriteAllBytes(path, bytes);
        return path;
    }

    /// <summary>Real preamble bytes on disk: an <see cref="UTF8Encoding"/> built with the identifier only emits it through a stream writer, never through GetBytes.</summary>
    private static byte[] Prefixed(string text, int marks)
    {
        var body = NoMark.GetBytes(text);
        var bytes = new byte[Mark.Length * marks + body.Length];
        for (var i = 0; i < marks; i++) { Mark.AsSpan().CopyTo(bytes.AsSpan(Mark.Length * i)); }
        body.CopyTo(bytes, Mark.Length * marks);
        return bytes;
    }

    private static SharedParkLine RowOf(string computer, string status, string? user = null, int attempts = 0, DateTimeOffset? at = null, string? probedBy = null)
        => new(computer, at ?? Now, status, user, attempts, probedBy);

    [Test]
    public static void Five_column_lines_are_read_and_the_missing_prober_stays_absent()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, Line("POSTE-1", Now, "CONFIRME", "jdupont", 3) + "\n");
        var read = SharedParkFile.ReadFile(path, Now, None);
        Check.True(read.Exists, "le relevé existe");
        Check.Equal(1, read.Rows.Length, "une ligne lue");
        var row = read.Rows[0];
        Check.Equal("POSTE-1", row.Computer, "le nom est conservé tel quel");
        Check.Equal(Now, row.At, "la date est relue à l’identique");
        Check.Equal("CONFIRME", row.Status, "le mot de la console est conservé, jamais converti en identité certifiée");
        Check.Equal("jdupont", row.User ?? string.Empty, "l’utilisateur vu est conservé");
        Check.Equal(3, row.Attempts, "le compteur repart de la valeur enregistrée");
        Check.Null(row.ProbedBy, "aucune console n’est inventée quand la sixième colonne manque");
        Check.Equal(SharedParkFile.Hash(File.ReadAllBytes(path)), read.Sha256, "l’empreinte porte sur les octets réellement lus");
    }

    [Test]
    public static void Six_column_lines_keep_the_console_that_probed()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, Line("POSTE-2", Now, "PARTAGE_PING_MUET", null, 12, "console-atelier") + "\n");
        var row = SharedParkFile.ReadFile(path, Now, None).Rows.Single();
        Check.Equal("console-atelier", row.ProbedBy ?? string.Empty, "la console qui a relevé est nommée");
        Check.Equal("PARTAGE_PING_MUET", row.Status, "le préfixe d’observation externe reste dans le fichier");
        Check.Equal(ParkStatus.Unreachable, SyncPark.StoredStatus(row.Status), "et se lit comme une observation, pas comme une certitude");
        Check.Null(row.User, "un poste injoignable n’a pas d’utilisateur inventé");
    }

    [Test]
    public static void Blank_lines_are_skipped_without_inventing_a_row()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, "\n" + Line("POSTE-1", Now, "LU", null, 0) + "\n\n\n" + Line("POSTE-2", Now, "LU", null, 0) + "\n");
        var read = SharedParkFile.ReadFile(path, Now, None);
        Check.Equal(2, read.Rows.Length, "les lignes vides ne deviennent pas des postes");
        Check.Equal("POSTE-1|POSTE-2", string.Join('|', read.Rows.Select(r => r.Computer)), "dans l’ordre du fichier");
    }

    [Test]
    public static void Roundtrip_keeps_accented_french_values_and_strict_utf8_bytes()
    {
        using var folder = new TemporaryFolder();
        var rows = ImmutableArray.Create(RowOf("POSTE-1", "PARTAGE_CONFIRME", "élodie.martin", 2, probedBy: "console-atelier"), RowOf("POSTE-2", "LU"));
        var bytes = SharedParkFile.Encode(rows);
        Check.False(bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF, "l’écriture n’ajoute aucun jeu d’octets de début");
        var read = SharedParkFile.ReadFile(Write(folder, bytes), Now, None);
        Check.True(bytes.AsSpan().SequenceEqual(read.Bytes), "les octets relus sont exactement ceux écrits");
        var first = read.Rows.Single(r => r.Computer == "POSTE-1");
        Check.Equal("élodie.martin", first.User ?? string.Empty, "les accents de l’utilisateur survivent au roundtrip");
        Check.Equal("console-atelier", first.ProbedBy ?? string.Empty, "les accents de la console survivent au roundtrip");
        Check.Equal("PARTAGE_CONFIRME", first.Status, "les accents du statut survivent au roundtrip");
        Check.Null(read.Rows.Single(r => r.Computer == "POSTE-2").User, "une valeur absente reste absente, jamais vide par défaut");
    }

    [Test]
    public static void One_initial_byte_order_mark_is_accepted_and_never_reaches_a_value()
    {
        using var folder = new TemporaryFolder();
        var text = Line("POSTE-1", Now, "LU", null, 0) + "\n";
        var path = Write(folder, Prefixed(text, 1));
        var onDisk = File.ReadAllBytes(path);
        Check.Equal("EFBBBF", Convert.ToHexString(onDisk.AsSpan(0, Mark.Length)), "les trois premiers octets du fichier sont bien le préambule UTF-8");
        Check.True(onDisk.AsSpan(Mark.Length).SequenceEqual(NoMark.GetBytes(text)), "au-delà du préambule, le fichier porte exactement la ligne attendue");
        var row = SharedParkFile.ReadFile(path, Now, None).Rows.Single();
        Check.Equal("POSTE-1", row.Computer, "le jeu d’octets de début n’entre pas dans la valeur");
        Check.False(row.Computer.Contains('\uFEFF'), "aucun caractère caché résiduel");
    }

    [Test]
    public static void A_second_byte_order_mark_is_refused_not_ignored_in_silence()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, Prefixed(Line("POSTE-1", Now, "LU", null, 0) + "\n", 2));
        var onDisk = File.ReadAllBytes(path);
        Check.Equal("EFBBBFEFBBBF", Convert.ToHexString(onDisk.AsSpan(0, 2 * Mark.Length)), "le fichier contient bien deux préambules consécutifs");
        var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(path, Now, None), "un second jeu d’octets de début est refusé");
        Check.Contains("jeu d’octets de début", ex.Message, "le refus nomme la cause");
        Check.True(onDisk.AsSpan().SequenceEqual(File.ReadAllBytes(path)), "le fichier de l’autre console n’est pas réécrit");
    }

    [Test]
    public static void A_hidden_byte_order_mark_inside_a_value_is_refused_on_reading_and_on_writing()
    {
        using var folder = new TemporaryFolder();
        var cases = new (string Field, string Status, string? User, string? ProbedBy)[]
        {
            ("statut", "LU\uFEFF", null, null),
            ("utilisateur", "CONFIRME", "\uFEFFalm", null),
            ("console", "CONFIRME", "alm", "console\uFEFFatelier"),
        };
        foreach (var (field, status, user, probedBy) in cases)
        {
            var path = Write(folder, Line("POSTE-1", Now, status, user, 1, probedBy) + "\n");
            var before = File.ReadAllBytes(path);
            var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(path, Now, None), $"un U+FEFF caché dans le {field} est refusé, jamais remplacé");
            Check.Contains("non qualifiée", ex.Message, $"le refus du {field} nomme la cause");
            Check.True(before.AsSpan().SequenceEqual(File.ReadAllBytes(path)), "les octets de l’autre console restent intacts");
            Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf("POSTE-1", status, user, 1, probedBy: probedBy)]),
                $"aucun octet n’est produit avec un U+FEFF dans le {field}");
        }
        Check.Equal(1, SharedParkFile.ReadFile(Write(folder, Line("POSTE-1", Now, "LU", "alm", 1, "console-atelier") + "\n"), Now, None).Rows.Length,
            "les mêmes champs sans U+FEFF restent valides : le refus porte sur le caractère caché");
    }

    [Test]
    public static void Invalid_utf8_bytes_are_refused_without_a_replacement_character()
    {
        using var folder = new TemporaryFolder();
        var bytes = NoMark.GetBytes(Line("POSTE-1", Now, "CONFIRME", "élodie.martin", 1) + "\n");
        bytes[^3] = 0xFF;
        var path = Write(folder, bytes);
        var before = File.ReadAllBytes(path);
        var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(path, Now, None), "un octet invalide n’est jamais remplacé par « ? » ou U+FFFD");
        Check.Contains("UTF-8 strict", ex.Message, "le refus dit pourquoi");
        Check.True(before.AsSpan().SequenceEqual(File.ReadAllBytes(path)), "le fichier source reste octet pour octet identique");
    }

    [Test]
    public static void Duplicate_names_ignoring_case_are_refused_never_merged()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, Line("POSTE-1", Now, "LU", null, 0) + "\n" + Line("poste-1", Now.AddMinutes(-1), "CONFIRME", "alm", 1) + "\n");
        var before = File.ReadAllBytes(path);
        var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(path, Now, None), "deux lignes du même poste ne sont jamais fusionnées au hasard");
        Check.Contains("dupliqué", ex.Message, "le refus nomme la cause");
        Check.True(before.AsSpan().SequenceEqual(File.ReadAllBytes(path)), "aucune réécriture d’un relevé ambigu");
    }

    [Test]
    public static void Sentinel_dates_are_refused_on_reading_and_on_writing()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, Line("POSTE-1", DateTimeOffset.UnixEpoch, "LU", null, 0) + "\n");
        Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(path, Now, None), "la date sentinelle n’est jamais un relevé valable");
        var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf("POSTE-1", "LU", at: DateTimeOffset.UnixEpoch)]), "aucun octet n’est produit pour une date sentinelle");
        Check.Contains("non qualifiée", ex.Message, "la même règle garde l’écriture");
        Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf("POSTE-1", "LU", at: DateTimeOffset.MinValue)]), "DateTime.MinValue non plus");
    }

    [Test]
    public static void Future_dates_are_refused_beyond_the_two_minute_margin()
    {
        using var folder = new TemporaryFolder();
        Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(Write(folder, Line("POSTE-1", Now.AddMinutes(3), "CONFIRME", null, 0) + "\n"), Now, None),
            "une ligne plus récente que l’horloge de plus de deux minutes est refusée");
        var read = SharedParkFile.ReadFile(Write(folder, Line("POSTE-2", Now.AddMinutes(1), "CONFIRME", null, 0) + "\n"), Now, None);
        Check.Equal(1, read.Rows.Length, "la marge d’horloge d’une minute reste acceptée");
    }

    [Test]
    public static void Wrong_field_count_is_refused()
    {
        using var folder = new TemporaryFolder();
        var stamp = Now.ToString("O", CultureInfo.InvariantCulture);
        var four = string.Join('\t', "POSTE-1", stamp, "LU", "0");
        Check.Equal(4, four.Split('\t').Length, "le cas est réellement construit avec quatre colonnes");
        Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(Write(folder, four + "\n"), Now, None), "quatre colonnes ne suffisent pas");
        var six = string.Join('\t', "POSTE-2", stamp, "CONFIRME", "alm", "2", "console-atelier");
        Check.Equal(6, six.Split('\t').Length, "le cas valide est réellement construit avec six colonnes");
        Check.Equal(1, SharedParkFile.ReadFile(Write(folder, six + "\n"), Now, None).Rows.Length, "six colonnes restent acceptées");
        var seven = string.Join('\t', "POSTE-3", stamp, "CONFIRME", "alm", "2", "console-atelier", "extra");
        Check.Equal(7, seven.Split('\t').Length, "le cas est réellement construit avec sept colonnes");
        var path = Write(folder, seven + "\n");
        var before = File.ReadAllBytes(path);
        var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(path, Now, None), "sept colonnes sont refusées, jamais réduites en silence");
        Check.Contains("Ligne TSV partagée invalide", ex.Message, "le refus nomme la cause");
        Check.True(before.AsSpan().SequenceEqual(File.ReadAllBytes(path)), "aucune réécriture d’un relevé mal formé");
    }

    [Test]
    public static void Oversized_lines_and_surveys_are_refused()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, Line("POSTE-1", Now, "CONFIRME", new string('u', 5_000), 0) + "\n");
        var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(path, Now, None), "une ligne hors limites est refusée avant d’être tronquée");
        Check.Contains("4 096", ex.Message, "la limite annoncée est celle qui est appliquée");
        var many = new StringBuilder();
        for (var i = 0; i <= SharedParkFile.MaxRows; i++) { many.Append(Line("P" + i.ToString(CultureInfo.InvariantCulture), Now, "LU", null, 0)).Append('\n'); }
        Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(Write(folder, many.ToString()), Now, None), "plus de 50 000 postes sont refusés à la lecture");
        Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([.. Enumerable.Range(0, SharedParkFile.MaxRows + 1)
            .Select(i => RowOf("P" + i.ToString(CultureInfo.InvariantCulture), "LU"))]), "et à l’écriture");
    }

    [Test]
    public static void Negative_counters_and_control_characters_are_refused()
    {
        using var folder = new TemporaryFolder();
        var stamp = Now.ToString("O", CultureInfo.InvariantCulture);
        Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(Write(folder, $"POSTE-1\t{stamp}\tLU\t\t-1\n"), Now, None), "un compteur négatif est refusé");
        Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(Write(folder, $"POSTE-1\t{stamp}\tLU\t\t12x\n"), Now, None), "un compteur non décimal est refusé");
        Check.Throws<InvalidDataException>(() => SharedParkFile.ReadFile(Write(folder, Line("POSTE-1", Now, "LU\u0007", null, 1) + "\n"), Now, None), "un caractère de contrôle lu est refusé");
        Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf("POSTE-1", "LU", attempts: -1)]), "aucun octet pour un compteur négatif");
        Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf("POSTE-1", "LU\u0007")]), "aucun octet pour un caractère de contrôle");
        Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf(" POSTE-1", "LU")]), "un nom encadré d’espaces n’est pas corrigé en silence");
        Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf("POSTE 1", "LU")]), "un nom avec espace interne n’est pas écrit");
    }

    [Test]
    public static void Encoding_refuses_duplicate_names_that_differ_only_by_case()
    {
        var ex = Check.Throws<InvalidDataException>(() => SharedParkFile.Encode([RowOf("POSTE-1", "LU"), RowOf("poste-1", "CONFIRME", "alm", 1)]),
            "deux lignes qui ne diffèrent que par la casse ne sont jamais écrites");
        Check.Contains("casse", ex.Message, "le refus nomme la cause");
    }

    [Test]
    public static void Encoding_sorts_by_name_and_ends_every_line_with_one_newline()
    {
        var rows = ImmutableArray.Create(RowOf("POSTE-B", "LU"), RowOf("POSTE-a", "CONFIRME", "alm", 2));
        var bytes = SharedParkFile.Encode(rows);
        var text = new UTF8Encoding(false, true).GetString(bytes);
        var lines = text.Split('\n');
        Check.Equal(string.Empty, lines[^1], "le fichier se termine par un seul saut de ligne");
        Check.Equal(2, lines.Length - 1, "une ligne par poste");
        Check.True(lines[0].StartsWith("POSTE-a\t", StringComparison.Ordinal), "tri sans distinction de casse, donc relisible par D1");
        Check.False(text.Contains('\r'), "aucun retour chariot ajouté");
        Check.True(bytes.AsSpan().SequenceEqual(SharedParkFile.Encode(rows)), "le même contenu produit exactement les mêmes octets");
        Check.Equal(SharedParkFile.Hash(bytes), SharedParkFile.Hash(SharedParkFile.Encode(rows)), "et la même empreinte");
    }

    [Test]
    public static void A_missing_survey_reads_as_empty_and_creates_no_file()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("absent.tsv");
        var read = SharedParkFile.ReadFile(path, Now, None);
        Check.False(read.Exists, "aucun relevé n’est inventé");
        Check.Equal(0, read.Rows.Length, "aucune ligne");
        Check.Equal(0, read.Bytes.Length, "aucun octet");
        Check.Equal(SharedParkFile.Hash([]), read.Sha256, "l’empreinte est celle d’un contenu vide");
        Check.False(File.Exists(path), "la lecture n’a rien créé");
    }

    [Test]
    public static void A_cancelled_read_touches_nothing()
    {
        using var folder = new TemporaryFolder();
        var path = Write(folder, Line("POSTE-1", Now, "CONFIRME", "élodie.martin", 4) + "\n");
        var before = File.ReadAllBytes(path);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        Check.Throws<OperationCanceledException>(() => SharedParkFile.ReadFile(path, Now, cancelled.Token), "une annulation préalable interrompt sans lire");
        Check.True(before.AsSpan().SequenceEqual(File.ReadAllBytes(path)), "le fichier est resté octet pour octet identique");
    }

    [Test]
    public static async Task A_preexisting_lock_is_kept_and_never_stolen()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("parc.tsv");
        var lockPath = path + ".lock";
        File.WriteAllText(lockPath, "autre-console");
        using var cancelled = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));
        await Check.ThrowsAsync<OperationCanceledException>(() => SharedParkFile.LockAsync(path, cancelled.Token),
            "le verrou posé par une autre console attend, il n’est jamais volé");
        Check.True(File.Exists(lockPath), "le verrou de l’autre console est encore là");
        Check.Equal("autre-console", File.ReadAllText(lockPath), "et son contenu est intact");
        Check.False(File.Exists(path), "aucun relevé n’a été créé au passage");
    }

    [Test]
    public static async Task A_cancelled_attempt_creates_no_lock_at_all()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("parc.tsv");
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => SharedParkFile.LockAsync(path, cancelled.Token), "aucun essai n’est tenté après annulation");
        Check.False(File.Exists(path + ".lock"), "aucun fichier de verrou créé");
        Check.False(File.Exists(path), "aucun fichier de relevé créé");
    }

    [Test]
    public static async Task The_lock_is_taken_once_and_released_on_dispose()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("parc.tsv");
        var lease = await SharedParkFile.LockAsync(path, None);
        try
        {
            Check.Equal(1, lease.Attempts, "verrou obtenu au premier essai quand personne ne le tient");
            Check.True(File.Exists(path + ".lock"), "le verrou est visible des autres consoles");
            Check.True(lease.Stream.CanWrite, "le verrou tenu reste utilisable");
        }
        finally
        {
            lease.Dispose();
        }
        Check.False(File.Exists(path + ".lock"), "le verrou disparaît avec la console qui le tenait");
    }

    [Test]
    public static async Task A_held_lock_blocks_a_second_console_without_being_stolen()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("parc.tsv");
        var lease = await SharedParkFile.LockAsync(path, None);
        try
        {
            using var cancelled = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));
            await Check.ThrowsAsync<OperationCanceledException>(() => SharedParkFile.LockAsync(path, cancelled.Token),
                "une seconde console attend et renonce, elle ne prend pas le verrou en cours");
            Check.True(File.Exists(path + ".lock"), "le verrou tenu est toujours présent");
            Check.True(lease.Stream.CanWrite, "et reste valable pour sa console");
        }
        finally
        {
            lease.Dispose();
        }
        Check.False(File.Exists(path + ".lock"), "rien ne survit à la libération");
    }

    [Test]
    public static void An_ordinary_absolute_path_is_required_for_the_shared_survey()
    {
        Check.Throws<InvalidDataException>(() => SharedParkFile.PathValue(string.Empty), "un chemin vide n’est pas un chemin");
        Check.Throws<InvalidDataException>(() => SharedParkFile.PathValue("parc.tsv"), "un chemin relatif est refusé");
        Check.Throws<InvalidDataException>(() => SharedParkFile.PathValue(@"C:\domenia\base.db"), "jamais la base SQLite");
        Check.Throws<InvalidDataException>(() => SharedParkFile.PathValue(@"C:\domenia\parc.lock"), "jamais un fichier de verrou");
        Check.Throws<InvalidDataException>(() => SharedParkFile.PathValue(@"\\?\C:\domenia\parc.tsv"), "jamais un préfixe d’étendue");
        Check.Throws<InvalidDataException>(() => SharedParkFile.PathValue(@"\\.\C:\domenia\parc.tsv"), "jamais un flux alternatif");
        Check.Equal(@"\\serveur\partage\parc.tsv", SharedParkFile.PathValue(@"\\serveur\partage\parc.tsv"), "un partage ordinaire est accepté");
    }
}
