using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Tests;

internal static class AccueilDurablePipelineTests
{
    private static readonly CancellationToken None = CancellationToken.None;

    [Test]
    public static async Task Local_refresh_status_without_an_OU_keeps_the_checkpoint_for_an_explicit_scope_choice()
    {
        var source = new HomePipelineSource { SessionScope = null };
        var saved = source.Checkpoint(); source.Saved = saved;
        using var context = source.Context(); var home = AccueilService.From(context);
        var empty = await home.RefreshStatusAsync(None);
        Check.False(empty.Running, "aucun lancement à l’ouverture");
        Check.Null(empty.Last, "aucune reprise affichée sans OU");
        Check.Equal(saved, source.Saved, "checkpoint conservé sans modification");
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => home.PlanRefreshAsync("inventory", None), "la collecte exige toujours une OU");
        Check.Equal(DomeniaErrors.ScopeTooWide, error.Code, "garde réseau conservée");
        await WorkingScope.From(context).SetAsync(await source.GetSessionAsync(None), Fixtures.Postes, true, None);
        var restored = await home.RefreshStatusAsync(None);
        Check.Equal(saved.Id, restored.Last!.Id, "même campagne retrouvée après choix de l’OU");
        Check.True(restored.Last.Resumable, "reprise seulement proposée");
        Check.Equal(0, source.DirectoryCalls + source.PresenceCalls + source.InventoryCalls, "aucune lecture réseau implicite");
    }

    [Test]
    public static async Task Inventory_after_filtered_ICMP_is_committed_and_resume_keeps_its_frozen_permission()
    {
        var source = new HomePipelineSource { EchoAnswered = false, HoldInventory = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using (CollectionNetworkPolicy.Enter(true))
        using (var context = source.Context())
        {
            var home = AccueilService.From(context); await home.SaveLayoutAsync([new("presence", FleetWidgetSource.Builtin, "fleet.lastcheck", "Kpi", "S", null, false, "Relevés des postes")], None);
            var plan = await home.PlanRefreshAsync("inventory", None); Check.True(plan.ReadWithoutEcho, "option figée avant confirmation");
            var running = home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            await source.InventoryEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)); home.StopRefresh(); source.HoldInventory!.SetResult();
            await running;
            Check.True(source.Saved!.ReadWithoutEcho, "permission conservée dans le checkpoint");
            Check.Equal(2, source.Saved.InventoryDone.Length, "les deux inventaires reçus sans réponse ICMP sont cochés");
            Check.True(source.Current.Observations.Workstations.All(o => o.Presence.Answered == false), "WMI réussi n’invente pas une réponse ICMP");
        }
        source.HoldInventory = null;
        using (CollectionNetworkPolicy.Enter(false))
        using (var context = source.Context())
        {
            var home = AccueilService.From(context); var resume = await home.PlanRefreshAsync("resume", None);
            Check.True(resume.ReadWithoutEcho, "paramètre courant ne change pas le contrat de la reprise confirmée");
            Check.Equal(1, source.InventoryCalls, "préparer la reprise n’envoie rien");
            var finished = await home.RunRefreshAsync(resume.Id, false, _ => { }, None);
            Check.Equal("success", finished.Status, "reprise termine les étapes restantes");
            Check.Equal(1, source.InventoryCalls, "aucun inventaire déjà confirmé n’est rejoué");
        }
    }

    [Test]
    public static async Task Interrupted_home_pipeline_reopens_without_replay_and_resumes_only_its_original_missing_identities()
    {
        var source = new HomePipelineSource { HoldPresence = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using (var context = source.Context())
        {
            var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("inventory", None);
            var running = home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            await source.PresenceEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            home.StopRefresh();
            Check.False(running.IsCompleted, "annuler ne libère pas le travail physique encore vivant");
            Check.True(source.Admitted, "admission conservée jusqu’à la fin réelle du lecteur");
            source.HoldPresence!.SetResult();
            var stopped = await running;
            Check.Equal("cancelled", stopped.Status, "arrêt du vrai pipeline Accueil");
            Check.Equal(1, source.Saved!.PresenceDone.Length, "seul le ping réellement enregistré est coché");
            Check.True(source.Saved!.Interrupted, "interruption conservée avant libération");
            Check.False(source.Admitted, "admission libérée après la sauvegarde finale");
        }
        var original = source.Saved!;
        source.Current = source.Current with { Directory = source.Current.Directory with { Computers = source.Current.Directory.Computers.Add(Fixtures.Computer("PC3")) } };
        source.HoldPresence = null;
        using var reopened = source.Context();
        var restored = AccueilService.From(reopened);
        var offer = await restored.RefreshStatusAsync(None);
        Check.True(offer.Last?.Resumable == true, "reprise exposée après une nouvelle instance du service");
        Check.Equal(1, source.PresenceCalls, "la lecture de l’offre n’a rejoué aucune collecte");
        var resume = await restored.PlanRefreshAsync("resume", None);
        Check.Equal(2, resume.Targets, "le nouveau poste de l’OU n’élargit pas le plan conservé");
        var finished = await restored.RunRefreshAsync(resume.Id, false, _ => { }, None);
        Check.Equal("success", finished.Status, "fin du pipeline repris");
        Check.True(source.PresenceRequests.Last().SequenceEqual(original.Targets.Select(t => t.Guid).Except(original.PresenceDone).Order()), "seules les identités sans bit confirmé sont repingées");
        Check.False(source.InventoryRequests.SelectMany(x => x).Contains(Fixtures.IdOf("PC3")), "aucune extension implicite de l’inventaire");
        Check.Null(source.Saved, "plan retiré seulement après toutes les étapes enregistrées");
    }

    [Test]
    public static async Task Rebound_identity_or_lost_committed_measure_refuses_resume_before_any_network_call()
    {
        foreach (var rebound in new[] { false, true })
        {
            var source = new HomePipelineSource();
            source.Saved = source.Checkpoint() with { PresenceDone = [source.Current.Directory.Computers[0].ObjectGuid], PresenceStartedAt = Fixtures.Now };
            if (rebound)
            {
                source.Current = source.Current with { Directory = source.Current.Directory with { Computers = source.Current.Directory.Computers.SetItem(0,
                    source.Current.Directory.Computers[0] with { DnsHostName = "other.test.local" }) } };
            }
            using var context = source.Context();
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => AccueilService.From(context).PlanRefreshAsync("resume", None), "preuve de reprise refusée");
            Check.Equal(rebound ? AccueilService.RefreshScopeChanged : "refresh.progressMissing", error.Code, "cause de refus qualifiée");
            Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "aucun appel de poste après refus");
            Check.NotNull(source.Saved, "plan original conservé pour examen");
        }
    }

    [Test]
    public static async Task A_failed_or_partial_directory_prerequisite_keeps_backup_and_blocks_all_later_collections()
    {
        foreach (var partial in new[] { false, true })
        {
            var source = new HomePipelineSource { DirectoryFailure = !partial, PartialDirectory = partial };
            using var context = source.Context();
            var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("all", None);
            var result = await home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            Check.Equal("error", result.Status, "échec préalable déclaré erreur, pas arrêt demandé");
            Check.Equal("done", result.Stages.Single(s => s.Id == "backup").State, "preuve de sauvegarde conservée");
            Check.Equal(1, source.BackupCalls, "une étape de sauvegarde exécutée");
            Check.Equal(1, source.DirectoryCalls, "un seul essai de lecture");
            Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "pas de nouvelles collectes après échec du prérequis");
            Check.True(source.Saved!.DoneStages.Contains("backup"), "acquis conservé durablement");
            Check.False(source.Saved.DoneStages.Contains("directory") || source.Saved.DoneStages.Contains("commit"), "aucune fausse lecture complète ni reçu");
            var polled = await home.RefreshStatusAsync(None);
            Check.Equal("error", polled.Last!.Status, "la consultation n’écrase pas l’erreur par cancelled");
            Check.Equal(result.Label, polled.Last.Label, "cause précise conservée dans cette session");
            home.AcknowledgeRefreshDraw(result.Id);
            var resume = await home.PlanRefreshAsync("resume", None);
            Check.Equal(plan.Scope, resume.Scope, "reprise liée au même périmètre");
            Check.True(resume.Stages.Any(s => s.Id == "directory"), "la lecture échouée est réellement reproposée");
            Check.Equal(1, source.DirectoryCalls, "préparer une reprise n’envoie rien");
            using var reopened = source.Context();
            var restored = await AccueilService.From(reopened).RefreshStatusAsync(None);
            Check.Equal("interrupted", restored.Last!.Status, "cause non persistée honnêtement inconnue après réouverture");
            Check.True(restored.Last.Resumable, "reprise explicite conservée");
        }
    }

    [Test]
    public static async Task Complete_directory_receipt_rebinds_the_provisional_population_before_any_workstation_contact()
    {
        foreach (var initiallyEmpty in new[] { false, true })
        {
            var source = new HomePipelineSource();
            var original = source.Current.Directory.Computers[0];
            source.Current = source.Current with { Directory = source.Current.Directory with { Computers = initiallyEmpty ? [] : [original with { DnsHostName = null, Sid = "" }] } };
            source.AfterDirectory = Fixtures.Snapshot(computers: [original, Fixtures.Computer("NEW")]) with { Coverage = HomePipelineSource.Scope };
            using var context = source.Context(); var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("all", None);
            Check.Equal(initiallyEmpty ? 0 : 1, plan.Targets, "estimation sur le cache provisoire seulement");
            var report = await home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            Check.Equal("success", report.Status, "enrichissement AD complet puis collecte dans la même OU");
            Check.Equal(1, source.BindCalls, "identités sauvées avant le premier ping");
            Check.Equal(2, source.PresenceRequests.Single().Length, "la population provient du reçu AD, même depuis un cache vide");
            Check.Equal(2, source.InventoryRequests.Single().Length, "inventaire de la population réellement qualifiée");
            Check.Null(source.Saved, "checkpoint retiré après fin complète");
        }
    }

    [Test]
    public static async Task Stop_between_directory_and_receipt_can_resume_with_a_new_qualified_census()
    {
        var source = new HomePipelineSource();
        var original = source.Current.Directory.Computers[0];
        source.Current = source.Current with { Directory = source.Current.Directory with { Computers = [original with { Sid = "", DnsHostName = null }] } };
        source.AfterDirectory = Fixtures.Snapshot(computers: [original, Fixtures.Computer("NEW")]) with { Coverage = HomePipelineSource.Scope };
        using (var context = source.Context())
        {
            var home = AccueilService.From(context); var plan = await home.PlanRefreshAsync("all", None);
            var report = await home.RunRefreshAsync(plan.Id, false, progress =>
            { if (progress.Stage == "directory" && progress.State == "done") { home.StopRefresh(); } }, None);
            Check.Equal("cancelled", report.Status, "arrêt entre lecture complète et liaison du reçu");
            Check.Equal(0, source.PresenceCalls + source.BindCalls, "aucun poste contacté avant arrêt");
            Check.False(source.Saved!.DoneStages.Contains("commit"), "population provisoire non prétendue confirmée");
        }
        using var reopened = source.Context(); var restored = AccueilService.From(reopened);
        var resume = await restored.PlanRefreshAsync("resume", None);
        Check.True(resume.Stages.Any(s => s.Id == "directory"), "nouvelle lecture complète explicitement prévue");
        var finished = await restored.RunRefreshAsync(resume.Id, false, _ => { }, None);
        Check.Equal("success", finished.Status, "enrichissement précédent n’empêche pas la reprise avant tout contact");
        Check.Equal(2, source.PresenceRequests.Single().Length, "la nouvelle population n’est utilisée qu’après son reçu");
        Check.Equal(1, source.BindCalls, "un seul rattachement durable avant postes");
    }

    [Test]
    public static async Task Missing_widget_probes_share_one_collection_without_rereading_fresh_inventory()
    {
        var source = new HomePipelineSource();
        source.Record(source.Current.Directory.Computers.Select(c => c.ObjectGuid), true);
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([
            new("model", FleetWidgetSource.Probe, "hw.model", "Bar", "S", null, false, "Inventaire"),
            new("bios", FleetWidgetSource.Probe, "hw.bios", "Bar", "S", null, false, "Inventaire")], None);
        var plan = await home.PlanRefreshAsync("inventory", None);
        var report = await home.RunRefreshAsync(plan.Id, false, _ => { }, None);
        Check.Equal("success", report.Status, "inventaire frais et sondes nouvellement enregistrées");
        Check.Equal(0, source.InventoryCalls, "une sonde manquante ne fait pas relire l’inventaire frais");
        Check.Equal(1, source.ProbeRequests.Count, "un seul groupe pour les deux sondes manquantes");
        Check.True(source.ProbeRequests.Single().Order().SequenceEqual(new[] { "hw.bios", "hw.model" }), "les sondes partagent le même lecteur par poste");
        Check.Null(source.Saved, "progression complète après lecture groupée");
    }

    [Test]
    public static async Task A_name_absent_from_DNS_completes_the_presence_stage_and_is_never_asked_again()
    {
        // Field report 2.0.7: the resolver answers NXDOMAIN for one host. That answer is a result, not a probe error.
        var source = new HomePipelineSource { EchoAnswered = false };
        source.PresenceFailures[Fixtures.IdOf("PC2")] = PresenceReadOutcome.DnsNotFound;
        using var context = source.Context();
        var home = AccueilService.From(context);
        var plan = await home.PlanRefreshAsync("presence", None);
        SurveyState? batch = null;
        var report = await home.RunRefreshAsync(plan.Id, false, progress =>
        { if (progress.Stage == "presence" && progress.State != "running") { batch = home.OperationsRefresh(); } }, None);
        var stage = report.Stages.Single(s => s.Id == "presence");
        Check.Equal("done", stage.State, "réponse définitive du DNS : étape terminée, pas en échec");
        Check.Equal("0 poste en ligne sur 2 · 1 sans réponse · 1 nom absent du DNS", stage.Detail, "nom absent du DNS nommé, jamais « sonde en erreur »");
        Check.Equal("success", report.Status, "relevé complet, pas partiel");
        Check.False(report.Resumable, "aucune reprise proposée : redemander le même nom ne change rien");
        Check.Equal("Présence relevée par ping" + FrenchText.Colon + "OU Postes · 1 nom absent du DNS", report.Label, "le compte rendu garde la précision après le repli des étapes");
        Check.Null(source.Saved, "checkpoint retiré après un relevé complet");
        var run = report.Runs.Single(r => r.Family == CollectionFamily.Presence);
        Check.Equal(CollectionStatus.Success, run.Status, "relevé de présence réussi dans « Relevés par OU »");
        Check.False(run.Postes.Contains("non confirmé", StringComparison.Ordinal), "aucun poste non confirmé");
        Check.NotNull(batch, "lot Opérations observé pendant le relevé");
        Check.Equal(0, batch!.Failed, "Opérations : pas de « Non confirmé »");
        Check.Equal(0, batch.PingErrors, "Opérations : pas d’« Erreur de ping »");
        Check.Equal("refresh.nothingToResume", (await Check.ThrowsAsync<DomeniaOperationException>(() => home.PlanRefreshAsync("resume", None), "rien à reprendre")).Code, "aucune reprise");
        Check.Equal(1, source.PresenceCalls, "aucun nouvel écho");
    }

    [Test]
    public static async Task A_DNS_timeout_keeps_the_refresh_partial_and_resume_retries_only_that_host()
    {
        var source = new HomePipelineSource();
        source.PresenceFailures[Fixtures.IdOf("PC1")] = PresenceReadOutcome.DnsNotFound;
        source.PresenceFailures[Fixtures.IdOf("PC2")] = PresenceReadOutcome.DnsTimeout;
        using (var context = source.Context())
        {
            var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("presence", None);
            var report = await home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            var stage = report.Stages.Single(s => s.Id == "presence");
            Check.Equal("partial", stage.State, "l’étape a tourné ; un poste reste à mesurer (ni « done » ni « failed »)");
            Check.Equal("0 poste en ligne sur 2 · 0 sans réponse · 1 nom absent du DNS · 1 non vérifié (délai DNS dépassé)", stage.Detail, "cause transitoire nommée");
            Check.Equal("partial", report.Status, "délai DNS : actualisation partielle");
            Check.True(report.Resumable, "reprise proposée pour la cause transitoire");
            Check.Equal("Actualisation partielle" + FrenchText.Colon + "OU Postes · 1 nom absent du DNS · 1 poste non vérifié (délai DNS dépassé)", report.Label,
                "compte rendu lisible seul : réponse définitive, puis poste restant avec son nom et sa cause");
            var run = report.Runs.Single(r => r.Family == CollectionFamily.Presence);
            Check.Equal(CollectionStatus.Partial, run.Status, "relevé de présence partiel");
            Check.Contains("1 poste avec une lecture non confirmée (délai DNS dépassé)", run.Reason, "seul le délai DNS est non confirmé");
            Check.Equal(Fixtures.IdOf("PC1"), source.Saved!.PresenceDone.Single(), "la réponse définitive est cochée, pas le délai DNS");
        }
        source.PresenceFailures.Remove(Fixtures.IdOf("PC2"));
        using var reopened = source.Context();
        var restored = AccueilService.From(reopened);
        var resume = await restored.PlanRefreshAsync("resume", None);
        var finished = await restored.RunRefreshAsync(resume.Id, false, _ => { }, None);
        Check.Equal(Fixtures.IdOf("PC2"), source.PresenceRequests.Last().Single(), "seul le poste au délai DNS est repingé");
        Check.Equal("success", finished.Status, "reprise terminée");
        Check.Equal("done", finished.Stages.Single(s => s.Id == "presence").State, "étape terminée après reprise");
        Check.Equal("1 poste en ligne sur 2 · 0 sans réponse · 1 nom absent du DNS", finished.Stages.Single(s => s.Id == "presence").Detail, "bilan de la campagne entière");
        Check.Equal(CollectionStatus.Success, finished.Runs.Single(r => r.Family == CollectionFamily.Presence).Status, "relevé de la campagne réussi après reprise");
        Check.Null(source.Saved, "plan retiré après reprise complète");
    }

    [Test]
    public static async Task Stop_during_WMI_after_a_name_absent_from_DNS_resumes_without_refusing_the_settled_presence()
    {
        var source = new HomePipelineSource { HoldInventory = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        source.PresenceFailures[Fixtures.IdOf("PC2")] = PresenceReadOutcome.DnsNotFound;
        using (var context = source.Context())
        {
            var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("inventory", None);
            var running = home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            await source.InventoryEntered.Task.WaitAsync(TimeSpan.FromSeconds(5)); home.StopRefresh(); source.HoldInventory!.SetResult();
            var stopped = await running;
            Check.Equal("cancelled", stopped.Status, "arrêt pendant WMI");
            Check.True(source.Saved!.DoneStages.Contains("presence"), "présence terminée malgré le nom absent du DNS");
            Check.Equal(2, source.Saved.PresenceDone.Length, "lecture et réponse définitive cochées");
            Check.Equal(Fixtures.IdOf("PC1"), source.InventoryRequests.Single().Single(), "WMI jamais sur un nom absent du DNS");
        }
        source.HoldInventory = null;
        using var reopened = source.Context();
        var restored = AccueilService.From(reopened);
        var resume = await restored.PlanRefreshAsync("resume", None);
        Check.False(resume.Stages.Any(s => s.Id == "presence"), "la présence terminée n’est pas reprise");
        var finished = await restored.RunRefreshAsync(resume.Id, false, _ => { }, None);
        Check.Equal("success", finished.Status, "reprise acceptée sans refresh.progressMissing");
        Check.Equal(1, source.PresenceCalls, "aucun nouvel écho");
        Check.Null(source.Saved, "plan retiré");
    }

    [Test]
    public static async Task No_name_resolved_in_the_scope_tells_to_check_the_DNS_of_this_workstation()
    {
        // A DNS or VPN fault of the operator's workstation makes every name « absent du DNS »: nothing to retry, so the refresh
        // stays a success, but it says so. A name that resolved, or an invalid name instead of a resolver answer, says nothing.
        const string hint = " · aucun nom résolu" + FrenchText.Colon + "vérifiez le DNS de ce poste";
        foreach (var (second, note, noAnswer) in new (PresenceReadOutcome? Second, string Note, int NoAnswer)[]
        {
            (PresenceReadOutcome.DnsNotFound, "2 noms absents du DNS" + hint, 0),
            (null, "1 nom absent du DNS", 1),
            (PresenceReadOutcome.InvalidTarget, "1 nom absent du DNS · 1 nom de poste invalide", 0),
        })
        {
            var source = new HomePipelineSource { EchoAnswered = false };
            source.PresenceFailures[Fixtures.IdOf("PC1")] = PresenceReadOutcome.DnsNotFound;
            if (second is { } outcome) { source.PresenceFailures[Fixtures.IdOf("PC2")] = outcome; }
            using var context = source.Context();
            var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("presence", None);
            var report = await home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            var stage = report.Stages.Single(s => s.Id == "presence");
            var unresolved = note.EndsWith(hint, StringComparison.Ordinal);
            Check.Equal("done", stage.State, "réponses définitives : étape terminée (" + note + ")");
            Check.Equal("0 poste en ligne sur 2 · " + FrenchText.Integer(noAnswer) + " sans réponse · " + note, stage.Detail, "détail de l’étape");
            Check.Equal("success", report.Status, "rien à redemander : relevé réussi (" + note + ")");
            Check.False(report.Resumable, "aucune reprise (" + note + ")");
            Check.Equal("Présence relevée par ping" + FrenchText.Colon + "OU Postes · " + note, report.Label, "compte rendu");
            Check.Equal(unresolved ? Tone.Warn : Tone.Ok, context.Journal.Snapshot().Single(j => j.Label == report.Label).Tone,
                unresolved ? "seule la ligne du journal avertit quand aucun nom n’est résolu" : "succès ordinaire au journal (" + note + ")");
        }
    }

    [Test]
    public static async Task A_refused_WMI_read_leaves_the_inventory_stage_incomplete_and_resume_reads_only_that_host()
    {
        // « failed » is kept for a stage that could not run: this one ran and left one workstation to read.
        var source = new HomePipelineSource();
        source.InventoryFailures.Add(Fixtures.IdOf("PC2"));
        using (var context = source.Context())
        {
            var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("inventory", None);
            var report = await home.RunRefreshAsync(plan.Id, false, _ => { }, None);
            var stage = report.Stages.Single(s => s.Id == "inventory");
            Check.Equal("partial", stage.State, "étape exécutée avec une lecture WMI refusée : « Incomplète », pas « Échec »");
            Check.Contains("1 poste avec une lecture incomplète ou refusée", stage.Detail, "lecture refusée comptée");
            Check.Equal("done", report.Stages.Single(s => s.Id == "presence").State, "présence complète");
            Check.Equal("partial", report.Status, "actualisation partielle");
            Check.True(report.Resumable, "reprise proposée pour la lecture restante");
            Check.Equal(Fixtures.IdOf("PC1"), source.Saved!.InventoryDone.Single(), "seul l’inventaire lu est coché");
        }
        source.InventoryFailures.Clear();
        using var reopened = source.Context();
        var restored = AccueilService.From(reopened);
        var resume = await restored.PlanRefreshAsync("resume", None);
        var finished = await restored.RunRefreshAsync(resume.Id, false, _ => { }, None);
        Check.Equal(Fixtures.IdOf("PC2"), source.InventoryRequests.Last().Single(), "seule la lecture refusée est redemandée");
        Check.Equal("success", finished.Status, "reprise terminée");
        Check.Null(source.Saved, "plan retiré après reprise complète");
    }

    [Test]
    public static async Task A_later_resume_counts_the_readings_of_the_interrupted_campaign_as_confirmed()
    {
        // The presence run of a resume is counted from the start of the campaign: PC1 read five minutes before the resume is a
        // confirmed reading of the same campaign, never « non confirmée » nor « aucun résultat pour ce relevé ».
        var source = new HomePipelineSource();
        source.PresenceFailures[Fixtures.IdOf("PC2")] = PresenceReadOutcome.DnsTimeout;
        using (var context = source.Context())
        {
            var home = AccueilService.From(context);
            var plan = await home.PlanRefreshAsync("presence", None);
            Check.Equal("partial", (await home.RunRefreshAsync(plan.Id, false, _ => { }, None)).Status, "délai DNS : relevé partiel");
        }
        source.PresenceFailures.Clear();
        source.Now = Fixtures.Now.AddMinutes(5);
        using var reopened = source.Context();
        var restored = AccueilService.From(reopened);
        var resume = await restored.PlanRefreshAsync("resume", None);
        var finished = await restored.RunRefreshAsync(resume.Id, false, _ => { }, None);
        Check.Equal(Fixtures.IdOf("PC2"), source.PresenceRequests.Last().Single(), "seul le poste au délai DNS est repingé");
        Check.Equal("success", finished.Status, "reprise terminée");
        Check.Equal("2 postes en ligne sur 2 · 0 sans réponse", finished.Stages.Single(s => s.Id == "presence").Detail, "bilan de la campagne entière");
        var run = finished.Runs.Single(r => r.Family == CollectionFamily.Presence);
        Check.Equal(CollectionStatus.Success, run.Status, "relevé de présence réussi après une reprise plus tardive");
        foreach (var text in new[] { run.Reason ?? "", run.Postes })
        {
            Check.False(text.Contains("non confirmé", StringComparison.Ordinal) || text.Contains("aucun résultat pour ce relevé", StringComparison.Ordinal),
                "lecture de la campagne interrompue tenue pour confirmée : " + text);
        }
    }

    [Test]
    public static async Task Resuming_a_checkpoint_left_by_2_0_7_asks_only_the_name_absent_from_DNS_and_finishes()
    {
        // 2.0.7 never ticked a name absent from DNS: its checkpoint keeps the presence stage open, with a bit for every host that
        // answered or not. « Reprendre » asks that name once more, then the stage is done and the checkpoint removed.
        var source = new HomePipelineSource { EchoAnswered = false };
        source.PresenceFailures[Fixtures.IdOf("PC2")] = PresenceReadOutcome.DnsNotFound;
        source.Record(source.Current.Directory.Computers.Select(c => c.ObjectGuid), false);
        source.Saved = source.Checkpoint() with { PresenceDone = [Fixtures.IdOf("PC1")], PresenceStartedAt = Fixtures.Now };
        using var context = source.Context();
        var home = AccueilService.From(context);
        Check.True((await home.RefreshStatusAsync(None)).Last?.Resumable == true, "« Reprendre » proposé par le checkpoint de la version 2.0.7");
        var resume = await home.PlanRefreshAsync("resume", None);
        var finished = await home.RunRefreshAsync(resume.Id, false, _ => { }, None);
        Check.Equal(Fixtures.IdOf("PC2"), source.PresenceRequests.Single().Single(), "seul le nom sans bit est redemandé");
        Check.Equal("success", finished.Status, "reprise terminée en succès");
        Check.Equal("done", finished.Stages.Single(s => s.Id == "presence").State, "étape de présence terminée");
        Check.Equal("Actualisation interrompue reprise et terminée" + FrenchText.Colon + "OU Postes · 1 nom absent du DNS", finished.Label, "réponse du DNS nommée");
        Check.Equal(0, source.InventoryCalls, "aucun WMI : aucun poste n’a répondu");
        Check.Null(source.Saved, "checkpoint retiré");
    }

    [Test]
    public static async Task A_checkpoint_write_refusal_prevents_the_first_workstation_read()
    {
        var source = new HomePipelineSource { RejectBegin = true };
        using var context = source.Context();
        var home = AccueilService.From(context);
        var plan = await home.PlanRefreshAsync("presence", None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunRefreshAsync(plan.Id, false, _ => { }, None), "journal initial refusé");
        Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "aucun réseau avant le journal durable");
        Check.False(source.Admitted, "refus initial ne fuit pas l’admission");
    }
}

internal static class AccueilWidgetCollectionTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static FleetLayoutItem Item(string id, string key) => new(id, FleetWidgetSource.Builtin, key, "Kpi", "S", null, false, "Relevés des postes");

    [Test]
    public static async Task A_large_widget_requires_confirmation_even_without_a_ceiling_and_respects_the_operator_limit()
    {
        var source = new HomePipelineSource();
        source.Current = source.Current with { Directory = Fixtures.Snapshot(computers:
            [.. Enumerable.Range(1, 201).Select(i => Fixtures.Computer("PC" + i))]) with { Coverage = HomePipelineSource.Scope } };
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("many", "fleet.lastcheck")], None);
        var plan = await home.PlanWidgetCollectionAsync("many", "add", None);
        Check.Equal(201, plan.Targets, "volume réel des seuls postes à lire");
        Check.True(plan.ConfirmationRequired, "sans plafond ne désactive pas la confirmation au-delà de 200");
        Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "plan local ne lance aucune collecte");
        await context.Preferences.SetAsync(CollectionSettingsRules.PreferenceKey,
            JsonSerializer.SerializeToElement(new { budgets = new { widgetMax = 200 } }), None);
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => home.PlanWidgetCollectionAsync("many", "add", None), "plafond explicite respecté");
        Check.Equal("widget.ceiling", refusal.Code, "aucune sélection tronquée silencieusement");
        await context.Preferences.SetAsync(CollectionSettingsRules.PreferenceKey,
            JsonSerializer.SerializeToElement(new { budgets = new { widgetMax = 100000 } }), None);
        Check.True((await home.PlanWidgetCollectionAsync("many", "add", None)).ConfirmationRequired, "cap V2 entreprise garde le geste explicite");
    }

    [Test]
    public static async Task Queue_admits_twenty_distinct_widgets_and_refuses_active_queued_duplicates_before_any_extra_read()
    {
        var source = new HomePipelineSource();
        using var context = source.Context(); var home = AccueilService.From(context);
        var items = Enumerable.Range(0, 21).Select(i => Item("queue-" + i, "fleet.lastcheck")).ToImmutableArray();
        await home.SaveLayoutAsync(items, None);
        var first = await home.PlanWidgetCollectionAsync(items[0].Id, "add", None);
        await home.RunWidgetCollectionAsync(first.Id, false, None); // Hold the real drawing acknowledgement.
        var waiting = new List<Task<HomeWidgetResult>>();
        try
        {
            var repeated = await home.PlanWidgetCollectionAsync(items[0].Id, "add", None);
            var duplicate = await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(repeated.Id, false, None), "actif déjà présent");
            Check.Equal("widget.duplicate", duplicate.Code, "même carte active refusée sans nouveau relevé");
            for (var i = 1; i < 20; i++)
            {
                var plan = await home.PlanWidgetCollectionAsync(items[i].Id, "add", None);
                waiting.Add(home.RunWidgetCollectionAsync(plan.Id, false, None));
                if (i == 1)
                {
                    repeated = await home.PlanWidgetCollectionAsync(items[i].Id, "add", None);
                    duplicate = await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(repeated.Id, false, None), "carte en attente déjà présente");
                    Check.Equal("widget.duplicate", duplicate.Code, "doublon dans la file refusé");
                }
            }
            Check.Equal(20, (await home.WidgetCollectionStateAsync(None)).Length, "un actif et dix-neuf en file");
            var overflow = await home.PlanWidgetCollectionAsync(items[20].Id, "add", None);
            var full = await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(overflow.Id, false, None), "vingt et unième carte refusée");
            Check.Equal("widget.queueFull", full.Code, "plafond de file explicite, sans perte des demandes précédentes");
            Check.True(waiting.All(task => !task.IsCompleted), "aucun démarrage avant acquittement réel");
            Check.Equal(1, source.PresenceCalls, "seule la première collecte a lu la source");
        }
        finally
        {
            home.CancelWidgetCollection(first.Id);
            foreach (var pending in waiting)
                await Check.ThrowsAsync<OperationCanceledException>(() => pending.WaitAsync(TimeSpan.FromSeconds(5)), "abandon du dessin arrête chaque demande en attente");
        }
        Check.Equal(0, (await home.WidgetCollectionStateAsync(None)).Length, "toutes les admissions sont rendues après l’arrêt");
        Check.Equal(1, source.PresenceCalls, "aucun lecteur parti lors du nettoyage");
    }

    [Test]
    public static async Task Queue_waits_for_actual_draw_and_reuses_the_previous_widget_measurements()
    {
        var source = new HomePipelineSource();
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("first", "fleet.lastcheck"), Item("second", "fleet.lastcheck")], None);
        var first = await home.PlanWidgetCollectionAsync("first", "add", None);
        var second = await home.PlanWidgetCollectionAsync("second", "add", None);
        Check.False(first.ConfirmationRequired, "ajout explicite de moins de 200 postes sans seconde confirmation");
        await home.RunWidgetCollectionAsync(first.Id, false, None);
        var queued = home.RunWidgetCollectionAsync(second.Id, false, None);
        Check.False(queued.IsCompleted, "résultat moteur seul ne libère pas la file avant le dessin");
        Check.Equal("drawing", (await home.WidgetCollectionStateAsync(None))[0].Phase, "phase de dessin explicite");
        home.AcknowledgeWidgetDraw("foreign");
        Check.False(queued.IsCompleted, "accusé d’une autre collecte ignoré");
        home.AcknowledgeWidgetDraw(first.Id);
        var result = await queued.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal(1, source.PresenceCalls, "la deuxième carte réutilise le commit de la première");
        Check.Equal(2, result.Fresh, "réemploi exact des deux mesures");
        home.AcknowledgeWidgetDraw(second.Id);
        Check.Equal(0, (await home.WidgetCollectionStateAsync(None)).Length, "file vide après dessin confirmé");
    }

    [Test]
    public static async Task A_name_absent_from_DNS_is_a_fresh_widget_result_not_a_failure()
    {
        var source = new HomePipelineSource();
        source.PresenceFailures[Fixtures.IdOf("PC2")] = PresenceReadOutcome.DnsNotFound;
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("first", "fleet.lastcheck"), Item("second", "fleet.lastcheck")], None);
        var first = await home.PlanWidgetCollectionAsync("first", "add", None);
        var result = await home.RunWidgetCollectionAsync(first.Id, false, None);
        Check.Equal(0, result.Failed, "un nom absent du DNS est un résultat, pas un échec");
        Check.Equal("Collecte terminée ; les mesures confirmées sont enregistrées.", result.Detail, "aucune collecte partielle annoncée");
        home.AcknowledgeWidgetDraw(first.Id);
        var second = await home.PlanWidgetCollectionAsync("second", "add", None);
        var again = await home.RunWidgetCollectionAsync(second.Id, false, None);
        Check.Equal(2, again.Fresh, "réponse définitive récente réutilisée comme une mesure");
        Check.Equal(1, source.PresenceCalls, "le même nom n’est pas redemandé dans la fenêtre de fraîcheur");
        home.AcknowledgeWidgetDraw(second.Id);
    }

    [Test]
    public static async Task Non_add_gestures_need_confirmation_and_rebound_targets_never_start()
    {
        var source = new HomePipelineSource(); using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("first", "fleet.lastcheck")], None);
        var refresh = await home.PlanWidgetCollectionAsync("first", "refresh", None);
        Check.True(refresh.ConfirmationRequired, "commande Actualiser demande une confirmation");
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(refresh.Id, false, None), "confirmation absente");
        Check.Equal("widget.confirmation", refused.Code, "refus précis");
        var add = await home.PlanWidgetCollectionAsync("first", "add", None);
        source.Current = source.Current with { Directory = source.Current.Directory with { Computers = source.Current.Directory.Computers.SetItem(0,
            source.Current.Directory.Computers[0] with { SamAccountName = "OTHER$" }) } };
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(add.Id, false, None), "identité réaffectée");
        Check.Equal(0, source.PresenceCalls, "aucune présence après ces deux refus");
    }

    [Test]
    public static async Task Working_scope_change_stops_the_active_widget_even_without_any_UI_callback()
    {
        var source = new HomePipelineSource { HoldPresence = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("first", "fleet.lastcheck")], None);
        var plan = await home.PlanWidgetCollectionAsync("first", "add", None);
        var running = home.RunWidgetCollectionAsync(plan.Id, false, None);
        await source.PresenceEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await WorkingScope.From(context).SetAsync(await source.GetSessionAsync(None), Fixtures.Root, true, None);
        Check.False(running.IsCompleted, "changement d’OU ne libère pas le lecteur physique");
        Check.True(source.Admitted, "admission toujours détenue pendant l’arrêt");
        source.HoldPresence!.SetResult();
        await Check.ThrowsAsync<OperationCanceledException>(() => running, "annulation moteur sans callback navigateur");
        Check.False(source.Admitted, "libération après la fin du lecteur");
        Check.Equal(1, source.PresenceCalls, "aucun nouvel appel après changement de portée");
    }

    [Test]
    public static async Task Returning_to_the_same_OU_does_not_reactivate_old_widget_or_refresh_confirmations()
    {
        var source = new HomePipelineSource(); using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("first", "fleet.lastcheck")], None);
        var widget = await home.PlanWidgetCollectionAsync("first", "add", None);
        var refresh = await home.PlanRefreshAsync("presence", None);
        var working = WorkingScope.From(context); var version = working.SelectionVersion;
        var session = await source.GetSessionAsync(None);
        await working.SetAsync(session, Fixtures.Root, true, None);
        await working.SetAsync(session, Fixtures.Postes, true, None);
        Check.True(working.SelectionVersion >= version + 2, "A vers B puis A reste un changement de sélection");
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunWidgetCollectionAsync(widget.Id, false, None), "ancien ajout refusé");
        await Check.ThrowsAsync<DomeniaOperationException>(() => home.RunRefreshAsync(refresh.Id, false, _ => { }, None), "ancienne confirmation globale refusée");
        Check.Equal(0, source.PresenceCalls, "aucune ancienne demande réactivée après le retour à A");
    }

    [Test]
    public static async Task Unknown_scope_volume_requires_confirmation_even_when_the_local_cache_is_empty()
    {
        var source = new HomePipelineSource();
        source.Current = source.Current with { Directory = source.Current.Directory with { Computers = [], Complete = false } };
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("directory", "fleet.machines"), Item("keys", "fleet.bitlocker")], None);
        foreach (var id in new[] { "directory", "keys" })
        {
            var plan = await home.PlanWidgetCollectionAsync(id, "add", None);
            Check.Equal(0, plan.Targets, "le cache ne connaît aucun poste");
            Check.True(plan.ConfirmationRequired, "volume réel inconnu : confirmation AD obligatoire");
            home.CancelWidgetCollection(plan.Id);
        }
        Check.Equal(0, source.PresenceCalls, "aucun envoi au stade de préparation");
    }

    [Test]
    public static async Task Failed_draw_cancels_the_queue_instead_of_starting_another_collection()
    {
        var source = new HomePipelineSource(); using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([Item("first", "fleet.lastcheck"), Item("second", "fleet.lastcheck")], None);
        var first = await home.PlanWidgetCollectionAsync("first", "add", None);
        var second = await home.PlanWidgetCollectionAsync("second", "add", None);
        await home.RunWidgetCollectionAsync(first.Id, false, None);
        var queued = home.RunWidgetCollectionAsync(second.Id, false, None);
        home.CancelWidgetCollection(first.Id);
        await Check.ThrowsAsync<OperationCanceledException>(() => queued.WaitAsync(TimeSpan.FromSeconds(5)), "dessin abandonné arrête les demandes suivantes");
        Check.Equal(1, source.PresenceCalls, "aucun second appel après dessin abandonné");
    }
}

// The fixture implements the same discovery, commit and lease contracts, without LDAP, ICMP or WMI.
public sealed class HomePipelineSource : IDirectorySource, IDirectoryRefreshPreparation
{
    internal DirectoryState Current = new(Fixtures.Snapshot(computers: [Fixtures.Computer("PC1"), Fixtures.Computer("PC2")]) with { Coverage = Scope }, FleetObservations.Empty, [], []);
    internal HomeCampaignCheckpoint? Saved;
    internal long Revision;
    internal bool Admitted, RejectBegin;
    internal TaskCompletionSource? HoldPresence;
    internal TaskCompletionSource? HoldInventory;
    internal TaskCompletionSource InventoryEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal bool EchoAnswered = true;
    /// <summary>Hosts whose ping fails with this outcome instead of answering (field report 2.0.7: a name absent from DNS).</summary>
    internal Dictionary<Guid, PresenceReadOutcome> PresenceFailures { get; } = [];
    /// <summary>Hosts whose WMI read is refused (access denied): no inventory reading.</summary>
    internal HashSet<Guid> InventoryFailures { get; } = [];
    /// <summary>Clock of the next context, and date of the measures and progress recorded from then on (a later resume).</summary>
    internal DateTimeOffset Now = Fixtures.Now;
    internal TaskCompletionSource PresenceEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int PresenceCalls, InventoryCalls, BackupCalls, DirectoryCalls;
    internal bool DirectoryFailure, PartialDirectory;
    internal DirectorySnapshot? AfterDirectory;
    internal int BindCalls;
    internal List<Guid[]> PresenceRequests { get; } = [];
    internal List<Guid[]> InventoryRequests { get; } = [];
    internal List<string[]> ProbeRequests { get; } = [];
    internal ProbeReadings StoredProbes = ProbeReadings.Empty;
    internal const string StoreId = "home-pipeline-store";
    internal string CurrentStoreId = StoreId;
    internal long SessionEpoch = 7;
    internal string SessionLogin = @"TEST\operator";
    internal ScopeSelection? SessionScope = Scope;
    internal TaskCompletionSource? HoldLocalRows;
    internal TaskCompletionSource LocalRowsEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int LocalRowsCalls, RequestedLocalRows;
    internal HashSet<Guid> MissingLocalRows { get; } = [];
    internal static ScopeSelection Scope => new(Fixtures.Postes, "Postes", true);
    public DirectorySourceKind Kind => DirectorySourceKind.ActiveDirectory;
    internal EngineContext Context() => new(ModeResolver.Resolve([], null, () => new DomainJoinInfo(DomainJoinState.Joined, "test.local")), this,
        new MemoryPreferenceStore(), TestClock.Fixed(Now), new RecordingJournal(), ScreenReaders.Discover(this, [typeof(HomePipelineReader).Assembly]));
    internal HomeCampaignCheckpoint Checkpoint() => new(Guid.NewGuid().ToString("D"), StoreId, Fixtures.Root, Scope, "inventory", ["presence", "inventory"], [],
        [.. Current.Directory.Computers.Select(QueryComputerIdentity.Of).OrderBy(t => t.Guid)], [], [], [], [], Now, Now, null, false, true);
    public Task<SessionSnapshot> GetSessionAsync(CancellationToken token) => Task.FromResult(new SessionSnapshot(ConnectionState.Connected,
        new("test.local", "TEST", Fixtures.Root), new("DC1.test.local", null), new(SessionLogin, null, null, null),
        new(AuthenticationMethod.WindowsSession, null, "Fixture"), SessionScope, new(RightsLevel.Read, "Lecture", false, "Fixture locale"), false,
        new(Current.Directory.ReadAt, Current.Directory.ObjectCount, Current.Directory.Complete), SessionEpoch));
    public Task<DirectoryState> ReadLocalAsync(CancellationToken token) => Task.FromResult(Current);
    public bool CanPrepareDirectoryRefresh => true;
    public Task<DirectoryBackupReceipt> PrepareDirectoryRefreshAsync(CancellationToken token)
    { token.ThrowIfCancellationRequested(); BackupCalls++; return Task.FromResult(new DirectoryBackupReceipt(StoreId, new string('a', 64), Fixtures.Now)); }
    public Task<DirectoryState> RefreshAsync(MeasureFamily family, ScopeSelection? scope, CancellationToken token)
    {
        if (family != MeasureFamily.Directory) { throw new InvalidOperationException("Frozen reader required."); }
        token.ThrowIfCancellationRequested(); DirectoryCalls++;
        Check.True(ScopeRules.SameScope(Scope, scope), "périmètre transmis au moteur");
        if (DirectoryFailure) { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Lecture LDAP refusée : cause=objet-modifié ; données précédentes conservées."); }
        Current = Current with { Directory = (AfterDirectory ?? Current.Directory) with { Complete = !PartialDirectory } };
        Current = Current with { DirectoryCommit = new(new(StoreId, Fixtures.Root, Scope, Current.Directory.ReadAt,
            Current.Directory.Complete, Guid.NewGuid().ToString("D"), new string('a', 64), 1, Current.Directory.ObjectCount, Fixtures.Now), 7) };
        return Task.FromResult(Current);
    }
    internal void Record(IEnumerable<Guid> ids, bool inventory)
    {
        var selected = ids.ToHashSet();
        var existing = Current.Observations.Workstations.ToDictionary(o => o.ComputerGuid);
        foreach (var pc in Current.Directory.Computers.Where(c => selected.Contains(c.ObjectGuid)))
        {
            var before = existing.GetValueOrDefault(pc.ObjectGuid)?.Inventory;
            existing[pc.ObjectGuid] = !inventory && PresenceFailures.TryGetValue(pc.ObjectGuid, out var failure)
                ? Fixtures.Observe(pc, Failed(failure), before)
                : Fixtures.Observe(pc, Fixtures.Presence(EchoAnswered, Fixtures.Now - Now) with
                    { Diagnostic = new(EchoAnswered ? PresenceReadOutcome.Reply : PresenceReadOutcome.NoReply, "icmp") },
                    !inventory ? before : InventoryFailures.Contains(pc.ObjectGuid) ? new InventoryMeasure(MeasureState.Refused, Now, null, null, null, null, null, null, null)
                        : Fixtures.Disk(100, 80, Fixtures.Now - Now));
        }
        Current = Current with { Observations = new(Now, [.. existing.Values]) };
    }
    // Same shape as WorkstationPresenceReader.Finish: no answer, dated, Incomplete for a late DNS or budget, Error otherwise.
    private PresenceMeasure Failed(PresenceReadOutcome outcome) => new(outcome is PresenceReadOutcome.DnsTimeout or PresenceReadOutcome.DeadlineExceeded
        ? MeasureState.Incomplete : MeasureState.Error, null, Now, null)
    { Diagnostic = new(outcome, outcome == PresenceReadOutcome.InvalidTarget ? "target" : "dns", outcome == PresenceReadOutcome.DnsNotFound ? 11001 : null) };
}

public sealed class HomePipelineReader(HomePipelineSource source) : IAccueilReader, IHomeCampaignRecorder, IHomeWidgetAdmission, IOrganizationalUnitIndex
{
    public Task<OuEntry?> FindLocalAsync(string dn, CancellationToken token) => Task.FromResult<OuEntry?>(DistinguishedName.AreEqual(dn, Fixtures.Postes)
        ? new(Fixtures.Postes, "Postes", "test.local / Postes", false, new(0, source.Current.Directory.Computers.Length, 0)) : null);
    public Task<AccueilFacts> FactsAsync(CancellationToken token) => Task.FromResult(AccueilFacts.Empty(source.CurrentStoreId));
    public Task<ImmutableArray<FleetSnapshot>> HistoryAsync(ScopeSelection scope, CancellationToken token) => Task.FromResult(ImmutableArray<FleetSnapshot>.Empty);
    public Task<BitLockerPresence> ReadBitLockerAsync(ScopeSelection scope, CancellationToken token) => throw new InvalidOperationException("No BitLocker request expected.");
    public Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> ids, ScopeSelection scope, IReadOnlyCollection<Guid> online, CancellationToken token) => Task.FromResult(ProbeReadings.Empty);
    public Task<ProbeReadings> StoredProbesAsync(CancellationToken token) => Task.FromResult(source.StoredProbes);
    public Task<ProbeReadings> CollectProbesAsync(ImmutableArray<string> ids, ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long epoch, CancellationToken token)
    {
        source.ProbeRequests.Add([.. ids]);
        var read = new ProbeReadings(ids.ToImmutableDictionary(id => id, id => targets.ToImmutableDictionary(p => p.Key,
            p => new Domenia.Core.Accueil.ProbeReading(MeasureState.Known, Fixtures.Now, ["Value"], null) { Identity = p.Value, DefinitionHash = ProbeDefinitionIdentity.Of(Domenia.Core.Accueil.ProbeCatalog.Find(id)!) }), StringComparer.Ordinal));
        source.StoredProbes = source.StoredProbes.Merge(read);
        return Task.FromResult(read);
    }
    public async Task<DirectoryState> ReadPresenceAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long epoch, CancellationToken token)
    {
        source.PresenceCalls++; source.PresenceRequests.Add([.. targets.Keys.Order()]);
        source.Record(source.HoldPresence is null ? targets.Keys : targets.Keys.Take(1), false);
        source.PresenceEntered.TrySetResult();
        if (source.HoldPresence is { } hold) { await hold.Task; }
        token.ThrowIfCancellationRequested();
        return source.Current;
    }
    public Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlyDictionary<Guid, QueryComputerIdentity> targets, long epoch, CancellationToken token) => ReadInventoryAsync(scope, targets.Keys.ToHashSet(), token);
    public async Task<DirectoryState> ReadInventoryAsync(ScopeSelection scope, IReadOnlySet<Guid> targets, CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); source.InventoryCalls++; source.InventoryRequests.Add([.. targets.Order()]); source.Record(targets, true);
        source.InventoryEntered.TrySetResult(); if (source.HoldInventory is { } hold) { await hold.Task; }
        token.ThrowIfCancellationRequested(); return source.Current;
    }
    public Task<HomeCampaignStored> ReadHomeCampaignAsync(CancellationToken token) => Task.FromResult(new HomeCampaignStored(source.Revision, source.Saved));
    public Task<IHomeCampaignLease> BeginHomeCampaignAsync(HomeCampaignCheckpoint plan, string? expectedToken, CancellationToken token, bool replace = false)
    {
        if (source.RejectBegin) { throw new DomeniaOperationException("fixture.checkpoint", "Écriture initiale refusée."); }
        if (expectedToken != new HomeCampaignStored(source.Revision, source.Saved).Token) { throw new DomeniaOperationException("fixture.changed", "Reprise modifiée."); }
        HomeCampaignRules.Validate(plan, HomePipelineSource.StoreId, Fixtures.Root);
        var admission = Admit(); source.Saved = plan; source.Revision++;
        return Task.FromResult<IHomeCampaignLease>(new Lease(source, admission));
    }
    public Task<IDisposable> AcquireHomeWidgetAdmissionAsync(CancellationToken token) { token.ThrowIfCancellationRequested(); return Task.FromResult(Admit()); }
    private IDisposable Admit()
    {
        if (source.Admitted) { throw new DomeniaOperationException("operations.surveyBusy", "Déjà admis."); }
        source.Admitted = true; return new Admission(source);
    }
    private sealed class Admission(HomePipelineSource source) : IDisposable { public void Dispose() => source.Admitted = false; }
    private sealed class Lease(HomePipelineSource source, IDisposable admission) : IHomeCampaignLease
    {
        private HomeCampaignCheckpoint state = source.Saved!;
        public HomeCampaignCheckpoint State => state;
        public Task SaveAsync(ImmutableArray<string> stages, ImmutableArray<Guid> presence, ImmutableArray<Guid> inventory, DateTimeOffset? since, CancellationToken token)
        {
            state = state with { DoneStages = stages, PresenceDone = presence, InventoryDone = inventory, PresenceStartedAt = since, UpdatedAt = source.Now };
            HomeCampaignRules.Validate(state, HomePipelineSource.StoreId, Fixtures.Root);
            source.Saved = state; source.Revision++; return Task.CompletedTask;
        }
        public Task BindDirectoryAsync(DirectoryState committed, CancellationToken token)
        {
            Check.Equal(0, source.PresenceCalls + source.InventoryCalls, "requalification avant tout contact de poste");
            Check.True(committed.DirectoryCommit!.Receipt.Matches(HomePipelineSource.StoreId, Fixtures.Root, state.Scope, committed.Directory, Fixtures.Now), "reçu de la population durable");
            state = state with { Targets = [.. committed.Directory.Computers.Where(c => ScopeRules.Contains(state.Scope, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl)).Select(QueryComputerIdentity.Of).OrderBy(t => t.Guid)] };
            source.Saved = state; source.Revision++; source.BindCalls++; return Task.CompletedTask;
        }
        public Task FinishAsync(bool complete, CancellationToken token)
        { source.Saved = complete ? null : state with { Interrupted = true }; source.Revision++; return Task.CompletedTask; }
        public void Dispose() => admission.Dispose();
    }
}
