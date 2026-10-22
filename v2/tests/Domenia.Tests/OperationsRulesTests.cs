using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Tests;

/// <summary>
/// Pure rules of the Opérations screen (docs/ops/operations.md): durations and volumes, outcomes, listing and eviction, advice,
/// cancellation texts, summaries, latencies, slowness, paused sources, local save, SQLite waits, manual reviews and secrets,
/// postconditions and compensations, life-cycle sequences, redacted diagnostic and dossier. Written with the code, run at the end
/// (decision of David, 21/10).
/// </summary>
internal static class OperationsRulesTests
{
    private const string Nb = "\u00A0";

    // ---------------------------------------------------------------- durations, volumes, outcomes

    [Test]
    public static void Durations_and_volumes_are_written_in_french_and_never_invent_zero()
    {
        Check.Equal("non mesurée", ActivityRules.Duration(-1), "négatif : non mesuré");
        Check.Equal("<" + Nb + "1" + Nb + "ms", ActivityRules.Duration(0.4), "moins d’une milliseconde");
        Check.Equal("850" + Nb + "ms", ActivityRules.Duration(850), "millisecondes");
        Check.Equal("2,3" + Nb + "s", ActivityRules.Duration(2_340), "secondes, virgule décimale");
        Check.Equal("1" + Nb + "min 05" + Nb + "s", ActivityRules.Duration(65_000), "minutes et secondes");
        Check.Equal("volume non mesuré", ActivityRules.Volume(-1), "volume inconnu");
        Check.Equal("1 élément", ActivityRules.Volume(1), "singulier");
        Check.Equal("au moins 42 éléments", ActivityRules.Volume(42, complete: false), "compte incomplet");
    }

    [Test]
    public static void The_worst_end_wins_and_an_unknown_outcome_is_never_a_success()
    {
        Check.Equal(TaskOutcome.Failed, ActivityRules.Worst(TaskOutcome.Succeeded, TaskOutcome.Failed), "échec plus grave");
        Check.Equal(TaskOutcome.Unknown, ActivityRules.Worst(TaskOutcome.Unknown, TaskOutcome.Succeeded), "inconnu garde le dessus");
        Check.Equal(Tone.Warn, ActivityRules.Outcome(TaskOutcome.Unknown).Tone, "inconnu à vérifier, jamais vert");
        Check.Contains("relire avant toute nouvelle tentative", ActivityRules.Outcome(TaskOutcome.Unknown).Label, "libellé de Domenia 1");
        Check.Equal(TaskOutcome.Refused, ActivityRules.OutcomeOfCode("write.targetPending"), "refus attendu");
        Check.Equal(TaskOutcome.Failed, ActivityRules.OutcomeOfCode("operations.exportFailed"), "échec d’un enregistrement");
        Check.Equal(TaskOutcome.Unknown, ActivityRules.OutcomeOfCode("write.outcomeUnknown"), "issue inconnue");
    }

    [Test]
    public static void Operator_requests_are_listed_and_automatic_reads_only_when_they_end_badly()
    {
        Check.True(ActivityRules.IsForeground("dashboard.widget.refresh", TaskKind.NetworkRead), "lecture réseau : geste de l’opérateur");
        Check.True(ActivityRules.IsForeground("accounts.unlock.plan", TaskKind.LocalRead), "un plan est un geste");
        Check.False(ActivityRules.IsForeground("dashboard.summary", TaskKind.LocalRead), "lecture locale : peut être automatique");
        Check.True(ActivityRules.IsListed(true, TaskKind.LocalRead, false, TaskOutcome.Succeeded), "demande listée");
        Check.True(ActivityRules.IsListed(false, TaskKind.Write, true, null), "écriture toujours listée");
        Check.False(ActivityRules.IsListed(false, TaskKind.LocalRead, false, TaskOutcome.Succeeded), "lecture automatique réussie masquée");
        Check.False(ActivityRules.IsListed(false, TaskKind.LocalRead, false, TaskOutcome.Stopped), "arrêtée : rang 2, masquée");
        Check.True(ActivityRules.IsListed(false, TaskKind.LocalRead, false, TaskOutcome.Refused), "lecture automatique refusée listée");
        Check.False(ActivityRules.IsListed(false, TaskKind.LocalRead, true, null), "ouverte et automatique : pas encore listée");
    }

    [Test]
    public static void A_full_ring_drops_finished_automatic_tasks_first_and_open_ones_last()
    {
        var t0 = TestClock.Reference;
        var tasks = new List<(string, bool, bool, DateTimeOffset, DateTimeOffset)>
        {
            ("open", true, true, t0, t0.AddSeconds(1)),
            ("listed", false, true, t0.AddSeconds(2), t0.AddSeconds(3)),
            ("background", false, false, t0.AddSeconds(4), t0.AddSeconds(5)),
        };
        Check.True(ActivityRules.Eviction(tasks, maximum: 2).SequenceEqual(["background"]), "lecture automatique terminée d’abord");
        Check.True(ActivityRules.Eviction(tasks, maximum: 1).SequenceEqual(["background", "listed"]), "puis les demandes terminées");
        Check.True(ActivityRules.Eviction(tasks, maximum: 3).IsEmpty, "rien à retirer");
    }

    [Test]
    public static void Advice_never_proposes_a_retry_and_names_the_reference()
    {
        Check.Null(ActivityRules.Advice(TaskOutcome.Succeeded, TaskKind.Write, null, "abcd1234"), "rien après une réussite");
        var unknown = ActivityRules.Advice(TaskOutcome.Unknown, TaskKind.Write, WriteErrors.OutcomeUnknown, "abcd1234")!;
        Check.Contains("ne rejoue jamais une écriture", unknown, "jamais rejouée");
        Check.Contains("Référence abcd1234", unknown, "référence du journal technique");
        var refused = ActivityRules.Advice(TaskOutcome.Refused, TaskKind.LocalRead, WriteErrors.TargetPending, "abcd1234")!;
        Check.Contains("reste à vérifier", refused, "conseil propre au code");
        Check.False(ActivityRules.Advice(TaskOutcome.Failed, TaskKind.LocalRead, null, "xy")!.Contains("Référence", StringComparison.Ordinal), "référence mal formée tue");
        Check.Contains("non annulable après envoi", ActivityRules.CancelText("Déverrouillage", TaskState.Running, TaskKind.Write), "écriture jamais annulée");
        Check.Contains("La lecture est encore active", ActivityRules.CancelText("Lecture", TaskState.StopRequested, TaskKind.NetworkRead), "arrêt demandé n’est pas confirmé");
    }

    [Test]
    public static void Summaries_count_tasks_and_resources_in_plain_words()
    {
        Check.Equal("Aucune tâche", ActivityRules.Summary(0, 0, 0, 0, 0).Text, "au repos");
        var busy = ActivityRules.Summary(2, 0, 1, 0, 3);
        Check.Equal("2 en cours · 1 arrêt demandé", busy.Text, "résumé");
        Check.Equal(3, busy.Active, "actives : en cours et arrêt demandé");
        Check.Contains("3 jetons d’arrêt", busy.ResourcesText, "ressources détenues");
    }

    [Test]
    public static void Latencies_use_the_nearest_rank_and_state_a_95th_percentile_from_20_measures()
    {
        var empty = ActivityRules.Latency([]);
        Check.Equal(0, empty.Count, "aucune mesure");
        Check.Null(empty.P50, "jamais 0 ms inventé");
        var few = ActivityRules.Latency([10, 20, 30, double.NaN, -5]);
        Check.Equal(3, few.Count, "valeurs non mesurées écartées");
        Check.Equal(20.0, few.P50!.Value, "médiane au rang le plus proche");
        Check.False(few.P95Stated, "trop peu pour un 95e centile");
        Check.Contains("trop peu pour un 95e centile", ActivityRules.LatencyText("Lectures", few), "phrase de Domenia 1");
        var many = ActivityRules.Latency(Enumerable.Range(1, 40).Select(i => (double)i));
        Check.True(many.P95Stated, "95e centile à partir de 20 mesures");
        Check.Equal(38.0, many.P95!.Value, "rang ⌈0,95 n⌉");
        Check.Contains("aucune mesure dans cette session", ActivityRules.LatencyText("Écritures", empty), "catégorie non mesurée dite");
        var bins = ActivityRules.Histogram([5, 40, 80, 200, 450, 900, 4000, 9000]);
        Check.True(bins.All(b => b == 1), "une mesure par tranche");
    }

    [Test]
    public static void A_slowness_is_explained_and_an_unmeasured_phase_is_said_so()
    {
        var slow = ActivityRules.Slowness("Exécution d’une écriture", 200, 6_200, 1);
        Check.True(slow.Slow, "plus de 5 s");
        Check.Equal("engine", slow.Phase, "phase dominante");
        Check.Contains("interface non mesurée", slow.Text, "interface non mesurée, jamais 0");
        var quick = ActivityRules.Slowness("Lecture", -1, 120, -1);
        Check.False(quick.Slow, "sous le seuil");
        Check.Contains("file non mesurée", quick.Text, "file non mesurée");
    }

    [Test]
    public static void Paused_sources_are_named_and_healthy_ones_never_listed()
    {
        var now = TestClock.Reference;
        var zone = TestClock.Paris;
        ProviderState[] states =
        [
            new("Cim", "PC-MRS-0012", ProviderStateKind.Recovering, null, 1),
            new("Cim", "PC-MRS-0034", ProviderStateKind.Recovering, null, 1),
            new("Cim", "PC-MRS-0049", ProviderStateKind.Recovering, null, 1),
            new("Cim", "PC-LYO-0001", ProviderStateKind.Recovering, null, 1),
            new("Directory", "group:Marseille", ProviderStateKind.Paused, now.AddMinutes(5), 1),
            new("Directory", null, ProviderStateKind.Paused, now.AddMinutes(-1), 1),
            new("Wts", null, ProviderStateKind.Blocked, null, 1),
        ];
        var lines = ActivityRules.ProviderLines(states, now, zone);
        Check.Equal(3, lines.Length, "pause terminée non listée");
        Check.True(lines.Any(l => l.StartsWith("annuaire · site Marseille", StringComparison.Ordinal) && l.Contains("suspendues jusqu’à", StringComparison.Ordinal)), "site en pause");
        Check.True(lines.Any(l => l.Contains("identifiants rejetés", StringComparison.Ordinal)), "identifiants rejetés");
        Check.True(lines.Any(l => l.Contains("4 cibles (PC-LYO-0001, PC-MRS-0012, PC-MRS-0034 et 1 autre(s))", StringComparison.Ordinal)), "postes comptés avec quelques noms");
        Check.False(lines.Any(l => l.Contains("tout l’annuaire", StringComparison.Ordinal)), "jamais tout l’annuaire injoignable");
    }

    [Test]
    public static void The_local_save_sentence_never_claims_a_save_that_did_not_happen()
    {
        Check.Contains("En mémoire uniquement", ActivityRules.PersistenceLabel(0, 0, false, true, 0), "stockage indisponible d’abord");
        Check.Contains("enregistrement suspendu", ActivityRules.PersistenceLabel(2, 3, true, false, 0), "suspendu ensuite");
        Check.Contains("1 enregistrement(s) en échec", ActivityRules.PersistenceLabel(0, 1, false, false, 0), "échecs");
        Check.Contains("2 modification(s) à enregistrer", ActivityRules.PersistenceLabel(2, 0, false, false, 0), "en attente");
        Check.Equal("Enregistré.", ActivityRules.PersistenceLabel(0, 0, false, false, 0), "enregistré");
        Check.Equal(2500, ActivityRules.SqliteBusyTimeout(null), "défaut documenté");
        Check.Equal(100, ActivityRules.SqliteBusyTimeout("12"), "borne basse");
        Check.Equal(5000, ActivityRules.SqliteBusyTimeout("90000"), "borne haute");
        Check.Contains("aucune attente de verrou SQLite dépassée", ActivityRules.SqliteBusySummary(0, null, 2500, TestClock.Paris), "rien à signaler");
        Check.Contains("2 attente(s)", ActivityRules.SqliteBusySummary(2, TestClock.Reference, 2500, TestClock.Paris), "attentes comptées");
    }

    [Test]
    public static void Known_operations_have_short_labels_and_others_keep_their_first_clause()
    {
        Check.Equal("Exécution d’une écriture", ActivityRules.LabelOf("write.execute", "Exécute une fois…"), "libellé connu");
        Check.Equal("Recettes guidées", ActivityRules.LabelOf("assistance.recipes", "Recettes guidées, avec leur plan."), "première proposition");
        Check.Equal("abcd1234", ActivityRules.Reference("abcd1234-ef56"), "référence courte");
        Check.Equal("", ActivityRules.Reference("ab-1"), "trop court : aucune référence");
    }

    // ---------------------------------------------------------------- manual review and secrets

    [Test]
    public static void A_review_motive_is_bounded_and_never_looks_like_a_secret()
    {
        Check.False(ReceiptReviews.CheckReason("").Valid, "vide refusé");
        Check.Contains("12 au minimum", ReceiptReviews.CheckReason("trop court").Message, "trop court");
        Check.Contains("240 au maximum", ReceiptReviews.CheckReason(new string('a', 241)).Message, "trop long");
        Check.True(ReceiptReviews.CheckReason("  Vérifié dans ADUC sur DC01 : compte déverrouillé.  ").Valid, "motif valable, espaces retirés");
        var secret = ReceiptReviews.CheckReason("Vérifié avec password=<valeur-de-test> sur DC01");
        Check.False(secret.Valid, "ressemble à un secret");
        Check.Contains("ressemble à un secret", secret.Message, "raison dite");
        Check.True(ReceiptReviews.LooksSecret("clé 123456-123456-123456-123456-123456-123456-123456-123456"), "clé de récupération BitLocker");
        Check.True(ReceiptReviews.LooksSecret("Authorization: Bearer abc.def"), "en-tête d’autorisation");
        Check.True(ReceiptReviews.LooksSecret("net use /p:Secret1"), "commutateur de mot de passe");
        Check.False(ReceiptReviews.LooksSecret("Mot de passe changé par l’utilisateur au guichet"), "phrase sans valeur");
        Check.Equal("token: ***", ReceiptReviews.Mask("token: abc"), "masquage");
    }

    [Test]
    public static void The_pending_pill_never_says_zero_operation_and_names_the_oldest_receipt()
    {
        Check.False(ReceiptReviews.Pill(0).Visible, "invisible sans reçu à vérifier");
        Check.Equal("1 opération à vérifier", ReceiptReviews.Pill(1).Text, "singulier");
        Check.Equal("3 opérations à vérifier", ReceiptReviews.Pill(3).Text, "pluriel");
        Check.Contains("rien n’est rejoué", ReceiptReviews.Pill(2).Help, "rien n’est rejoué");
        Check.Contains("les nouvelles écritures restent bloquées", ReceiptReviews.Pill(2).Help, "texte de Domenia 1 : blocage de toutes les écritures");
        var older = WriteReceipts.Row(WriteReceipts.Sent(Plan("account.unlock"), WritePlans.NewId(), TestClock.Reference.AddMinutes(-30), new ReceiptDetail("Préconditions", "Relu.")));
        var newer = WriteReceipts.Row(WriteReceipts.Sent(Plan("account.enabled"), WritePlans.NewId(), TestClock.Reference, new ReceiptDetail("Préconditions", "Relu.")));
        Check.Equal(older.Id, ReceiptReviews.Oldest([newer, older])!.Id, "le plus ancien envoyé");
        var pill = ReceiptReviews.Pill(2, older, TestClock.Paris);
        Check.Contains("Le plus ancien", pill.Oldest!.Text, "au survol");
        Check.Contains("Objet d’essai", pill.Oldest.Text, "son objet");
        Check.Contains("Libellé", pill.Oldest.Text, "son opération");
        Check.Contains("21/10/2026 à 17:56", pill.Oldest.Text, "heure locale d’envoi");
    }

    [Test]
    public static void A_manual_review_settles_a_receipt_without_ever_being_a_success()
    {
        var plan = Plan("account.unlock");
        var sent = WriteReceipts.Sent(plan, WritePlans.NewId(), TestClock.Reference, new ReceiptDetail("Préconditions", "Relu."));
        var unknown = WriteReceipts.Completed(sent, new WriteOutcome(WriteResult.Unknown, "?"), new ReceiptError(WriteErrors.OutcomeUnknown, WriteErrors.OutcomeUnknownMessage), TestClock.Reference);
        Check.True(WriteReceipts.IsPending(unknown), "à vérifier avant la revue");
        var reviewed = WriteReceipts.Reviewed(unknown, "Vérifié dans ADUC sur DC01.", @"EXAMPLE\j.martin", TestClock.Reference);
        Check.False(WriteReceipts.IsPending(reviewed), "la revue lève le blocage");
        Check.Equal(Tone.Info, WriteReceipts.ToneOf(reviewed), "jamais vert");
        Check.Equal("Revue manuelle", WriteReceipts.VerificationLabel(reviewed.Result, reviewed.Verification), "libellé");
        Check.Contains("« Vérifié dans ADUC sur DC01 ».", reviewed.Details[^1].Value.Replace(Nb, " ", StringComparison.Ordinal), "motif cité, point final hors des guillemets");
        Check.Contains("ce n’est pas une vérification automatique", WriteReceipts.SummaryOf(reviewed), "dit dans la phrase du reçu");
        var reread = WriteReceipts.Verified(reviewed, new WriteVerification(VerificationState.Unknown, "Injoignable."), TestClock.Reference);
        Check.Equal(VerificationState.Reviewed, reread.Verification, "une relecture qui ne prouve rien garde la revue");
        var proven = WriteReceipts.Verified(reviewed, new WriteVerification(VerificationState.Verified, "Relu conforme."), TestClock.Reference);
        Check.Equal(VerificationState.Verified, proven.Verification, "une relecture conclusive remplace la revue");
    }

    [Test]
    public static void Receipt_actions_offer_a_re_read_when_the_executor_exists_and_a_review_only_when_uncertain()
    {
        var plan = Plan("account.unlock");
        var sent = WriteReceipts.Sent(plan, WritePlans.NewId(), TestClock.Reference, new ReceiptDetail("Préconditions", "Relu."));
        var pending = WriteReceipts.View(sent);
        var actions = ReceiptReviews.Actions(pending, executorAvailable: true, busy: false, simulation: true);
        Check.True(actions.CanVerify && actions.CanReview, "relecture et revue proposées");
        Check.Equal(4, actions.Templates.Length, "motifs fréquents");
        var noExecutor = ReceiptReviews.Actions(pending, executorAvailable: false, busy: false, simulation: false);
        Check.False(noExecutor.CanVerify, "pas de relecture sans exécuteur");
        Check.Contains("consignez votre revue", noExecutor.VerifyWhy, "la raison mène à la revue");
        var applied = WriteReceipts.View(WriteReceipts.Verified(WriteReceipts.Completed(sent, new WriteOutcome(WriteResult.Applied, "ok"), null, TestClock.Reference),
            new WriteVerification(VerificationState.Verified, "Relu."), TestClock.Reference));
        var resolved = ReceiptReviews.Actions(applied, executorAvailable: true, busy: false, simulation: true);
        Check.False(resolved.CanReview, "reçu résolu : aucune revue");
        Check.True(resolved.CanVerify, "une relecture reste possible : une lecture seulement");
        Check.False(ReceiptReviews.Actions(pending, true, busy: true, simulation: true).CanVerify, "rien pendant une écriture");
    }

    // ---------------------------------------------------------------- postconditions and compensations

    [Test]
    public static void Every_kind_names_the_re_read_that_proves_it()
    {
        Check.Contains("lockoutTime", WriteKindRules.Of("account.unlock").Check, "déverrouillage : lockoutTime");
        Check.False(WriteKindRules.Of("account.unlock").Compensable, "un déverrouillage ne se compense pas");
        Check.False(WriteKindRules.Of("remote.run").Verifiable, "script distant : revue manuelle");
        Check.True(WriteKindRules.Of("wol.send").Partial, "réveil : jamais plus que partiel");
        Check.Contains("à vérifier manuellement", WriteKindRules.Of("inconnu.kind").Check, "type inconnu : prudence");
        var rows = WriteKindRules.Rows(["account.unlock"]);
        Check.True(rows.Single(r => r.Kind == "account.unlock").Available, "servi dans ce mode");
        Check.False(rows.Single(r => r.Kind == "object.delete").Available, "pas encore servi");
        Check.True(WriteKindRules.IsSecretAttribute("unicodePwd"), "mot de passe");
        Check.False(WriteKindRules.IsSecretAttribute("msLAPS-PasswordExpirationTime"), "une date n’est pas un secret");
    }

    [Test]
    public static void A_compensation_is_offered_only_for_a_verified_compensable_write_and_read_backwards()
    {
        Check.False(WriteKindRules.Assess(Receipt("account.unlock", WriteResult.Applied, VerificationState.Verified)).Offered, "déverrouillage : jamais");
        Check.False(WriteKindRules.Assess(Receipt("account.enabled", WriteResult.Sent, VerificationState.Unknown)).Offered, "issue non vérifiée");
        Check.False(WriteKindRules.Assess(Receipt("account.enabled", WriteResult.Applied, VerificationState.Mismatch)).Offered, "valeur changée ailleurs");
        Check.False(WriteKindRules.Assess(Receipt("account.enabled", WriteResult.NotApplied, VerificationState.Verified)).Offered, "rien d’appliqué");
        Check.False(WriteKindRules.Assess(Receipt("account.enabled", WriteResult.Unknown, VerificationState.Reviewed)).Offered, "revue manuelle : relire d’abord");
        var offered = WriteKindRules.Assess(Receipt("account.enabled", WriteResult.Applied, VerificationState.Verified));
        Check.True(offered.Offered, "compensation possible");
        Check.True(offered.NewPlanRequired && !offered.Automatic, "nouvelle écriture, jamais automatique");
        var change = offered.Changes.Single();
        Check.Equal("Activé", change.Before, "l’après devient l’avant");
        Check.Equal("Désactivé", change.After, "l’avant devient l’après");
        Check.False(WriteKindRules.Assess(Receipt("password.reset", WriteResult.Applied, VerificationState.Verified)).Offered, "mot de passe : jamais");
    }

    // ---------------------------------------------------------------- life-cycle sequences

    [Test]
    public static void An_uncertain_step_blocks_the_sequence_and_is_never_replayed()
    {
        var plan = LifecyclePlans.New(LifecycleKind.Arrival, new LifecycleTemplate(["GG-A"], [], null, false));
        Check.Equal(3, plan.Steps.Length, "vérifier, groupes, activer");
        Check.False(plan.Deletes || plan.Migrates, "ni suppression ni migration");
        Check.Equal(1, LifecyclePlans.Next(plan)!.Id, "première étape");
        plan = LifecyclePlans.Record(plan, 1, LifecycleStepState.Verified);
        plan = LifecyclePlans.Record(plan, 2, LifecycleStepState.Uncertain, "issue inconnue");
        Check.True(plan.Blocked, "étape incertaine : bloquée");
        Check.Contains("ne sera pas rejouée", plan.BlockReason, "jamais rejouée");
        Check.Null(LifecyclePlans.Next(plan), "rien de plus tant qu’elle n’est pas tranchée");
        plan = LifecyclePlans.Record(plan, 2, LifecycleStepState.Verified, "relu", resolved: true);
        Check.False(plan.Blocked, "tranchée par une relecture");
        Check.Equal(3, LifecyclePlans.Next(plan)!.Id, "la suite reprend");
        var views = LifecyclePlans.Views(["account.enabled"]);
        Check.Equal(3, views.Length, "trois séquences");
        Check.True(views[0].Available[2], "activation servie");
        Check.False(views[0].Available[1], "groupes pas encore servis");
    }

    // ---------------------------------------------------------------- diagnostic and dossier

    [Test]
    public static void The_redacted_diagnostic_keeps_only_allowed_shapes()
    {
        var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), simulation: true);
        activity.Declare("dashboard.summary", TaskKind.LocalRead, "Tableau de bord");
        using (var task = activity.Begin("dashboard.summary", TaskKind.LocalRead, CancellationToken.None))
        {
            task.Complete(TaskOutcome.Succeeded, null, 9);
        }
        using (var task = activity.Begin("hors.registre", TaskKind.LocalRead, CancellationToken.None))
        {
            task.Complete(TaskOutcome.Refused, "Camille Bernard", -1);
        }
        var json = OperationsDiagnostics.Build(TestClock.Reference, AppMode.Simulation, new InterfaceFigures("154.0.4258.62", "dark", 3, 12, 40), 120, false, 1,
            activity.Snapshot(), ["dashboard.summary"], activity.Samples(), [("write.targetPending", 2), ("Camille Bernard", 1)], activity.Slow(), 0);
        Check.Contains("\"format\": \"Domenia.Diagnostic.3\"", json, "format");
        Check.Contains("\"webView2\": \"154.0.4258.62\"", json, "version admise");
        Check.Contains("write.targetPending", json, "code d’erreur gardé");
        Check.False(json.Contains("Camille", StringComparison.Ordinal), "aucun nom");
        Check.False(json.Contains("hors.registre", StringComparison.Ordinal), "opération hors registre écartée");
        var preview = OperationsDiagnostics.Preview(json);
        Check.True(preview[^1].StartsWith("Jamais inclus", StringComparison.Ordinal), "ce qui n’est jamais inclus est dit");
        Check.False(OperationsDiagnostics.IsVersion("C:\\Users\\x"), "un chemin n’est pas une version");
    }

    [Test]
    public static void The_dossier_with_pseudonyms_leaves_no_user_name_profile_path_workstation_nor_directory_example()
    {
        var session = new SessionSnapshot(ConnectionState.Simulated, new DomainIdentity("example.local", "EXAMPLE", "DC=example,DC=local"), new ControllerIdentity("DC01.example.local", "Paris"),
            new AccountIdentity(@"EXAMPLE\j.martin", "Julien Martin", "Julien", null), new AuthenticationInfo(AuthenticationMethod.None, null, "—"), null,
            new RightsInfo(RightsLevel.Read, "Lecture", true, ""), true, new StoreStatus(null, 0, true));
        var identity = new LocalIdentity("CNAMTS", "jdupont", "PC-ADM-007", @"C:\Users\jdupont", @"C:\Users\jdupont\AppData\Local");
        var check = OperationsDiagnostics.Report(TestClock.Reference, false,
        [
            new CheckRow("Stockage local", "Dossier des documents", CheckStatus.Ok, 1, @"Présent : C:\Users\jdupont\AppData\Local\Domenia\Exports"),
            new CheckRow("Annuaire", "Recherche utilisateur", CheckStatus.Ok, 2, "Exemple : Camille Bernard."),
            new CheckRow("Annuaire", "Recherche machine", CheckStatus.Ok, 2, "Exemple : PC-LYO-0042."),
            new CheckRow("Annuaire", "Session", CheckStatus.Ok, 3, @"Compte EXAMPLE\j.martin · domaine example.local · contrôleur DC01.example.local"),
            new CheckRow("Moteur", "Poste", CheckStatus.Ok, 1, "Lancé sur PC-ADM-007 par jdupont."),
        ]);
        var files = OperationsDiagnostics.Dossier(TestClock.Reference, SimulatedBridge.Decision, session, new InterfaceFigures(null, null, null, null, null), 100, 0, 0, true, true,
            ["account.unlock"], check, anonymize: true, identity);
        var all = string.Concat(files.Select(f => f.Text));
        Check.False(all.Contains("jdupont", StringComparison.OrdinalIgnoreCase), "nom d’utilisateur Windows remplacé partout, chemins compris");
        Check.False(all.Contains("PC-ADM-007", StringComparison.OrdinalIgnoreCase), "poste remplacé partout");
        Check.False(all.Contains("Camille", StringComparison.Ordinal) || all.Contains("PC-LYO-0042", StringComparison.Ordinal), "exemples d’objets de l’annuaire omis");
        Check.False(all.Contains("j.martin", StringComparison.OrdinalIgnoreCase), "compte remplacé, seul ou avec son domaine");
        Check.Contains("%LOCALAPPDATA%", all, "dossier du profil écrit comme variable");
        Check.Contains("Détail omis avec les pseudonymes", all, "détails libres de l’annuaire omis, et dit");
        Check.Contains("poste-1", all, "pseudonyme du poste");
        var plain = OperationsDiagnostics.Dossier(TestClock.Reference, SimulatedBridge.Decision, session, new InterfaceFigures(null, null, null, null, null), 100, 0, 0, true, true,
            ["account.unlock"], check, anonymize: false, identity);
        Check.Contains("jdupont", string.Concat(plain.Select(f => f.Text)), "sans pseudonymes, rien n’est remplacé (et c’est dit)");
    }

    [Test]
    public static void The_dossier_can_replace_every_name_by_a_pseudonym()
    {
        var session = new SessionSnapshot(ConnectionState.Simulated, new DomainIdentity("example.local", "EXAMPLE", "DC=example,DC=local"), new ControllerIdentity("DC01.example.local", "Paris"),
            new AccountIdentity(@"EXAMPLE\j.martin", "Julien Martin", "Julien", null), new AuthenticationInfo(AuthenticationMethod.None, null, "—"), null,
            new RightsInfo(RightsLevel.Read, "Lecture", true, ""), true, new StoreStatus(null, 0, true));
        var check = OperationsDiagnostics.Report(TestClock.Reference, false, [new CheckRow("Annuaire", "Session", CheckStatus.Ok, 3, @"Compte EXAMPLE\j.martin · domaine example.local")]);
        var files = OperationsDiagnostics.Dossier(TestClock.Reference, SimulatedBridge.Decision, session, new InterfaceFigures(null, null, null, null, null), 100, 0, 0, false, false,
            ["account.unlock"], check, anonymize: true);
        Check.True(files.Select(f => f.Name).SequenceEqual(["runtime.json", "configuration-expurgee.json", "verification.csv", "LISEZMOI.txt"]), "quatre fichiers");
        var all = string.Concat(files.Select(f => f.Text));
        Check.False(all.Contains("j.martin", StringComparison.OrdinalIgnoreCase), "compte remplacé partout");
        Check.False(all.Contains("example.local", StringComparison.OrdinalIgnoreCase), "domaine remplacé partout");
        Check.Contains("compte-1", all, "pseudonyme stable");
        var plain = OperationsDiagnostics.Dossier(TestClock.Reference, SimulatedBridge.Decision, session, new InterfaceFigures(null, null, null, null, null), 100, 0, 0, false, false,
            [], null, anonymize: false);
        Check.Contains("ne sont pas anonymisés", plain[^1].Text, "avertissement sans pseudonymes");
    }

    // ---------------------------------------------------------------- categories, interface, phases

    [Test]
    public static void Six_categories_of_Domenia_1_and_a_measure_never_counted_twice()
    {
        Check.Equal("writes", ActivityRules.CategoryOf("write.execute", TaskKind.Write), "écritures à part");
        Check.Equal("computers", ActivityRules.CategoryOf("operations.survey.resume", TaskKind.NetworkRead), "collecte sur les postes");
        Check.Equal("computers", ActivityRules.CategoryOf("poste.inventory.read", TaskKind.NetworkRead), "écran Poste");
        Check.Equal("directory", ActivityRules.CategoryOf("dashboard.widget.refresh", TaskKind.NetworkRead), "lectures de l’annuaire");
        Check.Equal("localSearch", ActivityRules.CategoryOf("directory.ou.search", TaskKind.LocalRead), "recherche locale");
        Check.Equal("local", ActivityRules.CategoryOf("dashboard.summary", TaskKind.LocalRead), "autres lectures locales");
        Check.Equal("local", ActivityRules.CategoryOf("session.setScope", TaskKind.LocalWrite), "écritures locales");
        var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), simulation: false);
        using (var task = activity.Begin("directory.ou.search", TaskKind.LocalRead, CancellationToken.None))
        {
            task.Complete(TaskOutcome.Succeeded, null, 3);
        }
        activity.RecordInterface([new InterfaceSample("liste", 40), new InterfaceSample("inconnu", 50)]);
        var categories = activity.Categories();
        Check.True(categories.Select(c => c.Id).SequenceEqual(["localSearch", "render", "local", "directory", "computers", "writes"]), "ordre de Domenia 1");
        Check.Equal(1, categories.Single(c => c.Id == "localSearch").Summary.Count, "une recherche locale");
        Check.Equal(1, categories.Single(c => c.Id == "render").Summary.Count, "un traitement d’interface (code inconnu écarté)");
        Check.Equal(2, categories.Sum(c => c.Summary.Count), "jamais compté deux fois : une opération, un traitement d’interface");
        Check.True(categories == activity.Categories(), "recalculé seulement si une série a bougé (même tableau)");
        Check.Contains("aucune mesure dans cette session", categories.Single(c => c.Id == "writes").Text, "catégorie sans mesure dite, jamais 0 ms");
    }

    [Test]
    public static void An_interface_work_above_120_ms_is_a_slowness_and_a_stall_is_never_guessed()
    {
        var slow = ActivityRules.Slowness("Affichage d’un écran", -1, -1, -1, interfaceMs: 180);
        Check.True(slow.Slow, "traitement d’interface au-dessus de son seuil");
        Check.Equal("interface", slow.Phase, "phase dominante : l’interface");
        var quick = ActivityRules.Slowness("Affichage d’un écran", -1, -1, -1, interfaceMs: 80);
        Check.False(quick.Slow, "sous 120 ms");
        var attributed = ActivityRules.StallText(new StallReport(812, "ecran", 640, null));
        Check.Contains("attribué à " + FrenchText.Quote("Affichage d’un écran"), attributed, "attribué au travail suivi");
        var unattributed = ActivityRules.StallText(new StallReport(812, null, null, 700));
        Check.Contains("non attribué", unattributed, "sans chevauchement : non attribué");
        Check.Contains("cause non établie", unattributed, "une tâche longue du navigateur n’est jamais une cause");
        Check.Null(ActivityRules.InterfaceWorkLabel("texte de la page"), "codes fermés seulement");
        var log = new RecordingJournal();
        var clock = TestClock.Fixed();
        var activity = new OperationActivity(clock, log, simulation: true);
        Check.False(activity.RecordStall(new StallReport(300, null, null, null)), "sous 400 ms : rien");
        Check.True(activity.RecordStall(new StallReport(900, "onglet", 500, null)), "première explication écrite");
        Check.False(activity.RecordStall(new StallReport(900, null, null, null)), "pas deux en 5 s");
        clock.Advance(TimeSpan.FromSeconds(5));
        Check.True(activity.RecordStall(new StallReport(900, null, null, null)), "de nouveau après 5 s");
        Check.True(log.Lines.Any(l => l.Contains("1 autre(s) depuis la ligne précédente", StringComparison.Ordinal)), "les blocages tus sont comptés");
    }

    [Test]
    public static void Phases_are_in_time_order_with_the_total_apart_and_a_next_step()
    {
        var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), simulation: true);
        using (var read = activity.Begin("dashboard.widget.refresh", TaskKind.NetworkRead, CancellationToken.None))
        {
            read.Complete(TaskOutcome.Succeeded, null, 1);
        }
        using (var write = activity.Begin("write.execute", TaskKind.Write, CancellationToken.None))
        {
            write.Step("Relecture de l’objet avant l’envoi", sequential: true);
            write.Step("Reçu enregistré, envoi du changement", sequential: true);
            write.Step("Relecture après l’écriture", sequential: true);
            write.Complete(TaskOutcome.Succeeded, null, 1);
        }
        var recent = activity.Snapshot().Recent;
        var readRow = recent.Single(r => r.Operation == "dashboard.widget.refresh");
        Check.True(readRow.Phases.Select(p => p.Phase).SequenceEqual(["request", "work", "publish", "end"]), "lecture : traitement, publication non mesurée, fin");
        Check.Equal("Traitement dans le moteur", readRow.DominantLabel, "étape dominante");
        Check.Contains("Aucune suite nécessaire", readRow.Next, "suite possible");
        var writeRow = recent.Single(r => r.Operation == "write.execute");
        Check.True(writeRow.Phases.Select(p => p.Phase).SequenceEqual(["request", "queue", "step", "step", "step", "publish", "end"]), "écriture : le total n’est pas une étape");
        Check.False(writeRow.Phases.Any(p => p.Phase == "work"), "jamais le temps lu deux fois");
        Check.False(writeRow.Phases.Single(p => p.Phase == "publish").Measured, "publication non mesurée");
        Check.Contains("total", writeRow.Text, "total donné à part");
    }

    // ---------------------------------------------------------------- activity

    [Test]
    public static void Reads_can_be_stopped_and_writes_never()
    {
        var activity = new OperationActivity(TestClock.Fixed(), new RecordingJournal(), simulation: true);
        using var read = activity.Begin("dashboard.widget.refresh", TaskKind.NetworkRead, CancellationToken.None);
        var row = activity.Stop(read.Id);
        Check.Equal(TaskState.StopRequested, row.State, "arrêt demandé");
        Check.True(read.Token.IsCancellationRequested, "sa propre annulation est levée");
        Check.False(row.CanStop, "un second arrêt n’est pas proposé");
        read.Complete(TaskOutcome.Stopped, "operation.stopped", -1);
        Check.Throws<DomeniaOperationException>(() => activity.Stop(read.Id), "tâche terminée : rien à arrêter");
        using var write = activity.Begin("write.execute", TaskKind.Write, CancellationToken.None);
        var refused = Check.Throws<DomeniaOperationException>(() => activity.Stop(write.Id), "écriture");
        Check.Equal(OperationActivity.TaskNotStoppable, refused.Code, "jamais arrêtée");
        Check.False(write.Token.CanBeCanceled, "une écriture garde la durée de vie de l’application");
        write.Step("Relecture de l’objet avant l’envoi", sequential: true);
        write.Complete(TaskOutcome.Unknown, WriteErrors.OutcomeUnknown, 1);
        var snapshot = activity.Snapshot();
        var done = snapshot.Recent.Single(r => r.Operation == "write.execute");
        Check.Equal(TaskOutcome.Unknown, done.Outcome, "issue inconnue gardée");
        Check.True(done.Phases.Any(p => p.Phase == "queue"), "attente du canal d’écriture mesurée");
        Check.Contains("ne rejoue jamais", done.Advice, "conseil");
        Check.True(snapshot.Open.IsEmpty, "plus rien en cours");
    }

    private static WritePlan Plan(string kind, string before = "Désactivé", string after = "Activé") => WritePlans.Seal(
        new WritePlanDraft(kind, "Titre", "Libellé", "Résumé.",
            new WriteTarget("user", "Compte utilisateur", "Objet d’essai", "CN=Objet d’essai,OU=Essais,DC=test,DC=local", FakeWriteExecutor.TargetGuid, "essai"),
            [new WriteChange("userAccountControl", "État du compte", WriteChangeKind.Replace, before, after, "514", "512")],
            ImmutableArray<WriteRisk>.Empty, new WriteConfirmation(false, null, "Simple."), new WriteReversibility(true, "Réversible", ""), "DC1.test.local"),
        WritePlans.NewId(), @"TEST\op", AppMode.Simulation, TestClock.Reference, TestClock.Paris);

    private static ReceiptView Receipt(string kind, WriteResult result, VerificationState verification)
    {
        var sent = WriteReceipts.Sent(Plan(kind), WritePlans.NewId(), TestClock.Reference, new ReceiptDetail("Préconditions", "Relu."));
        var receipt = result == WriteResult.Sent ? sent : WriteReceipts.Completed(sent, new WriteOutcome(result, "envoi"), null, TestClock.Reference);
        receipt = verification switch
        {
            VerificationState.Reviewed => WriteReceipts.Reviewed(receipt, "Contrôlé avec un autre outil.", @"TEST\op", TestClock.Reference),
            VerificationState.Unknown => receipt,
            _ => WriteReceipts.Verified(receipt, new WriteVerification(verification, "relu"), TestClock.Reference),
        };
        return WriteReceipts.View(receipt);
    }
}
