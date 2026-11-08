using Domenia.App;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static class HostIncidentReportTests
{
    [Test]
    public static void Pre_admission_BCL_report_keeps_its_reference_after_masking_and_real_disk_write()
    {
        using var folder = new TemporaryFolder();
        const string code = "INC-0123456789ABCDEF0123456789ABCDEF";
        var line = StartupBootstrap.FailureText(new InvalidOperationException("password=DO-NOT-DISPLAY"), code);
        var path = StartupBootstrap.WriteAt(folder.Path, "Domenia-startup-error.log", line);
        Check.NotNull(path, "trace BCL écrite dans le dossier de test");
        var actual = File.ReadAllText(path!);
        Check.Contains(code, actual, "référence conservée même quand le message initial contient un secret");
        Check.False(actual.Contains("DO-NOT-DISPLAY", StringComparison.Ordinal), "aucun chargement du masque produit nécessaire avant admission");
        Check.False(StartupBootstrap.FailureText(new Exception("refus"), "INC-bad\nforge").Contains("forge", StringComparison.Ordinal), "référence non fermée refusée");
    }

    [Test]
    public static void Native_report_and_real_journal_share_the_same_reference_and_actual_session_phase()
    {
        using var folder = new TemporaryFolder();
        foreach (var phase in new[] { HostPhase.Starting, HostPhase.Running, HostPhase.Closing })
        {
            HostIncidentReport.Starting();
            if (phase != HostPhase.Starting) HostIncidentReport.SessionShown();
            if (phase == HostPhase.Closing) HostIncidentReport.Closing();
            var path = folder.File(phase + ".log");
            var journal = new RotatingTechnicalJournal(path, null, TestClock.Fixed());
            var report = HostIncidentReport.Create(new InvalidOperationException("réponse inattendue"), text => journal.Enqueue("ERREUR", text),
                () => { journal.Flush(); return true; }, () => journal.Status);
            Check.Equal(phase, report.Phase, "phase de la session capturée au moment de l’incident");
            Check.Equal(path, report.JournalPath, "seulement le chemin réellement écrit");
            Check.Contains(report.Code, File.ReadAllText(path), "référence du dialogue présente dans le vrai fichier");
            Check.Contains(report.Code, report.Message, "référence à communiquer identique");
            Check.Equal(report.Code, SessionIncidents.CodeIn(report.Message), "code compris par les parcours d’assistance existants");
            Check.Contains(phase switch { HostPhase.Starting => "démarrage", HostPhase.Closing => "fermeture", _ => "erreur imprévue" }, report.Message, "texte spécifique à la phase");
            Check.False(report.Message.Contains("réponse inattendue", StringComparison.Ordinal), "détail réservé au journal en profil essentiel");
        }
        HostIncidentReport.CancelClosing(HostPhase.Running);
        Check.Equal(HostPhase.Running, HostIncidentReport.CurrentPhase, "annulation de fermeture revient à la session active");
        HostIncidentReport.Closing(); HostIncidentReport.SessionShown();
        Check.Equal(HostPhase.Closing, HostIncidentReport.CurrentPhase, "une notification de page tardive ne rouvre pas la phase active");
        HostIncidentReport.Starting();
    }

    [Test]
    public static void Unavailable_or_unflushed_journal_never_claims_a_path_and_fallback_is_masked()
    {
        using var folder = new TemporaryFolder();
        var blocked = folder.File("blocked"); File.WriteAllText(blocked, "obstacle");
        var journal = new RotatingTechnicalJournal(Path.Combine(blocked, "domenia.log"), null, TestClock.Fixed());
        var error = new InvalidOperationException("password=NEVER-SHOW-THIS ; lecture refusée");
        var report = HostIncidentReport.Create(error, text => journal.Enqueue("ERREUR", text),
            () => { journal.Flush(); return true; }, () => journal.Status);
        Check.Null(report.JournalPath, "chemin proposé par le journal mais jamais écrit non annoncé");
        Check.Contains("Journal non confirmé", report.Message, "absence de preuve explicite");
        Check.Contains(nameof(InvalidOperationException), report.Message, "diagnostic de repli utile");
        Check.False(report.Message.Contains("NEVER-SHOW-THIS", StringComparison.Ordinal), "secret masqué avant le dialogue");
        var unflushed = HostIncidentReport.Create(error, _ => { }, () => false,
            () => new("ready", folder.File("old.log"), 0, 0, null));
        Check.Null(unflushed.JournalPath, "un précédent fichier réussi ne prouve pas l’écriture de cet incident");
        var broken = HostIncidentReport.Create(error, _ => throw new IOException("disque indisponible"), () => true,
            () => throw new InvalidOperationException("aucun statut"));
        Check.Null(broken.JournalPath, "exception du journal n’écrase pas l’incident initial");
        Check.False(broken.Message.Contains("NEVER-SHOW-THIS", StringComparison.Ordinal), "repli masqué même si l’écriture lève");
    }

    [Test]
    public static void Real_fallback_path_and_expert_detail_are_explicit_and_oversized_diagnostics_keep_the_reference()
    {
        using var folder = new TemporaryFolder();
        var blocked = folder.File("blocked"); File.WriteAllText(blocked, "obstacle");
        var fallback = folder.File("fallback/domenia.log");
        var journal = new RotatingTechnicalJournal(Path.Combine(blocked, "domenia.log"), fallback, TestClock.Fixed());
        var report = HostIncidentReport.Create(new IOException("permission refusée"), text => journal.Enqueue("ERREUR", text),
            () => { journal.Flush(); return true; }, () => journal.Status, expert: true);
        Check.Equal(fallback, report.JournalPath, "chemin temporaire effectivement écrit");
        Check.Contains("permission refusée", report.Message, "détail disponible en profil Expert");
        var large = HostIncidentReport.Create(new IOException(new string('x', 70_000) + "password=SECRET"), text => journal.Enqueue("ERREUR", text),
            () => { journal.Flush(); return true; }, () => journal.Status, expert: true);
        Check.Contains(large.Code, File.ReadAllText(fallback), "grande exception ne fait pas supprimer la référence par la borne du journal");
        Check.Contains("hors limites", large.Message, "grand contenu remplacé entièrement avant masquage");
        Check.True(large.Message.Length < 1000, "rapport natif borné");
        Check.False(large.Message.Contains("SECRET", StringComparison.Ordinal), "aucun fragment de grand message non masqué");
    }
}
