using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class TechnicalJournalTests
{
    [Test]
    public static void Untrusted_text_cannot_forge_a_record_or_reveal_recognized_secrets()
    {
        var line = TechnicalJournalRecord.Format(TestClock.Reference, "ERREUR", "password=NEVER-LOG-THIS\r\n2026-10-23T12:00:00Z [INFO] forged\tBearer TOKEN-NEVER-LOG\u2028control\0");
        Check.False(line.Contains("NEVER-LOG", StringComparison.Ordinal), "les secrets reconnus sont masqués avant l’échappement");
        Check.Contains("\\r\\n", line, "sauts de ligne échappés");
        Check.Contains("\\t", line, "tabulation échappée");
        Check.Contains("\\u2028", line, "séparateur Unicode échappé");
        Check.Contains("\\u0000", line, "caractère nul échappé");
        var parsed = TechnicalLogTail.Parse(line, startsMidway: false, out _);
        Check.Equal(1, parsed.Length, "une seule entrée malgré la fausse date");
        Check.Equal("ERREUR", parsed[0].Level, "le niveau de la vraie entrée est conservé");
        var oversized = TechnicalJournalRecord.Format(TestClock.Reference, "\n[ERREUR]", new string('x', TechnicalJournalRecord.MaximumInput + 1));
        Check.Contains("[INFO] Message hors limites", oversized, "entrée trop grande refusée sans conserver un fragment non masqué");
        Check.True(oversized.Length < 200, "taille bornée");
    }

    [Test]
    public static void Rotation_keeps_the_previous_generation_and_flush_is_idempotent_without_new_lines()
    {
        using var folder = new TemporaryFolder();
        var path = folder.File("domenia.log");
        using (var previous = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            previous.Write(Encoding.UTF8.GetBytes("ancienne génération"));
            previous.SetLength(RotatingTechnicalJournal.MaximumBytes - 1);
        }
        var journal = new RotatingTechnicalJournal(path, null, TestClock.Fixed());
        journal.Enqueue("INFO", "après rotation");
        journal.Flush();
        Check.Equal("ready", journal.Status.State, "écriture relue disponible");
        Check.Equal(0, journal.Status.Pending, "file acquittée après écriture disque");
        Check.Equal(RotatingTechnicalJournal.MaximumBytes - 1, new FileInfo(path + ".1").Length, "une génération précédente conservée");
        Check.Contains("après rotation", File.ReadAllText(path), "nouvelle ligne dans le fichier courant");
        var bytes = File.ReadAllBytes(path);
        journal.Flush();
        Check.True(bytes.SequenceEqual(File.ReadAllBytes(path)), "une seconde vidange n’ajoute rien");
    }

    [Test]
    public static void Unwritable_primary_uses_an_explicit_local_fallback()
    {
        using var folder = new TemporaryFolder();
        var blocked = folder.File("blocked");
        File.WriteAllText(blocked, "fichier, pas dossier");
        var fallback = folder.File("fallback/domenia.log");
        var journal = new RotatingTechnicalJournal(Path.Combine(blocked, "domenia.log"), fallback, TestClock.Fixed());
        journal.Enqueue("ATTENTION", "secours vérifiable");
        journal.Flush();
        Check.Equal("fallback", journal.Status.State, "secours annoncé");
        Check.Equal(fallback, journal.Status.Path, "le lecteur voit le chemin réellement écrit");
        Check.NotNull(journal.Status.Problem, "cause du secours visible");
        Check.Contains("secours vérifiable", File.ReadAllText(fallback), "contenu conservé au secours");
    }

    [Test]
    public static void Disk_failure_keeps_a_bounded_queue_counts_losses_and_recovers_on_explicit_flush()
    {
        using var folder = new TemporaryFolder();
        var blocked = folder.File("blocked");
        File.WriteAllText(blocked, "obstacle");
        var path = Path.Combine(blocked, "domenia.log");
        var journal = new RotatingTechnicalJournal(path, null, TestClock.Fixed());
        for (var i = 0; i < RotatingTechnicalJournal.MaximumPending + 9; i++) { journal.Enqueue("INFO", "événement " + i); }
        journal.Flush();
        Check.Equal("unavailable", journal.Status.State, "aucun faux succès disque");
        Check.Equal(RotatingTechnicalJournal.MaximumPending, journal.Status.Pending, "file bornée gardée après échec");
        Check.Equal(9L, journal.Status.Dropped, "pertes comptées");
        File.Delete(blocked); Directory.CreateDirectory(blocked);
        journal.Flush();
        Check.Equal("ready", journal.Status.State, "reprise réelle");
        Check.Equal(0, journal.Status.Pending, "file écrite puis vidée");
        Check.Equal(9L, journal.Status.Dropped, "pertes passées toujours visibles après reprise");
        var lines = File.ReadAllLines(path);
        Check.Equal(RotatingTechnicalJournal.MaximumPending + 1, lines.Length, "lignes survivantes et reçu de pertes");
        Check.Contains("9 ligne(s) perdue(s)", lines[0], "pertes inscrites dans le journal récupéré");
        Check.Contains("événement 9", lines[1], "plus ancien événement survivant gardé");
    }
}
