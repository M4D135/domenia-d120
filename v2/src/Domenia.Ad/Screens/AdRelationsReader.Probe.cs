using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    internal Func<string, CancellationToken, Task<bool>>? PingOverride { get; init; }
    internal WorkstationPresenceReader? PresenceReaderOverride { get; init; }

    public async Task<RelationDetection> ProbeAsync(string planId, IProgress<RelationProbeProgress>? progress, CancellationToken stop, CancellationToken cancellationToken)
    {
        if (!WritePlans.IsPlanId(planId)) { throw new DomeniaOperationException(RelationErrors.PlanExpired, RelationErrors.PlanExpiredMessage); }
        var epoch = source.Epoch; var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false); EnsureEpoch(epoch);
        var results = AdRelationResults.For(source); var pending = results.Recall<AdRelationProbePlan>(planId, epoch);
        if (!pending.Plan.Allowed || pending.Plan.Id != planId || pending.Plan.Targets.Length is 0 or > 50)
        { throw new DomeniaOperationException(RelationErrors.PlanRefused, "Périmètre non exécutable ; aucun contact."); }
        long AccessVersion() => source.AccountContext is { } c ? AccountAccess.From(c).SelectionVersion : 0;
        long MachineGeneration() => source.AccountContext is { } c ? MachineAccountService.From(c).Generation : 0;
        if (pending.AccessVersion != AccessVersion() || pending.MachineGeneration != MachineGeneration())
        { throw new DomeniaOperationException(RelationErrors.PlanExpired, "Compte modifié depuis le plan ; préparez de nouveau la liste avant tout contact."); }
        if (!results.BeginProbe(epoch)) { throw new DomeniaOperationException(RelationErrors.ProbeBusy, RelationErrors.ProbeBusyMessage); }
        try
        {
            var held = results.Take<AdRelationProbePlan>(planId, epoch); var plan = held.Plan; var sweep = held.Mode == "sweep";
            using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(120), source.Clock);
            using var abort = new CancellationTokenSource();
            using var stopRun = CancellationTokenSource.CreateLinkedTokenSource(stop, elapsed.Token, abort.Token);
            using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(stopRun.Token, cancellationToken);
            var attempts = ImmutableArray.CreateBuilder<RelationAttempt>();
            var candidates = held.Candidates.Where(c => c.Guid is not null).GroupBy(c => c.Guid!, StringComparer.OrdinalIgnoreCase)
                .Where(g => g.Count() == 1).ToDictionary(g => g.Key, g => g.Single(), StringComparer.OrdinalIgnoreCase);
            var observations = ImmutableDictionary.CreateBuilder<string, StoredRelation>(StringComparer.Ordinal);
            var readings = new Dictionary<string, ConsoleResult>(StringComparer.OrdinalIgnoreCase);
            string? interrupted = null; string? memoryIssue = null;
            RelationSweepCacheSnapshot? sweepMemory = null;
            var passes = ImmutableArray.CreateBuilder<RelationSweepUpdate>();
            var sweepWriter = source.LocalStore as IRelationSweepWriter;
            try
            {
                if (sweepWriter is not null) { sweepMemory = await sweepWriter.ReadRelationSweepsAsync(cancellationToken).ConfigureAwait(false); }
                else { memoryIssue = "Stockage des passages indisponible ; les lectures restent affichées mais la file du parc ne sera pas actualisée."; }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException)
            { memoryIssue = "Mémoire des passages illisible ; les lectures seront affichées sans actualiser la file du parc."; }
            if (sweepMemory is not null && !DistinguishedName.AreEqual(sweepMemory.DomainDn, local.Directory.Domain.RootDn))
            { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Mémoire des passages d’un autre domaine ; aucune sonde."); }
            EnsureEpoch(epoch);
            // Admit the LDAP and first exact machine once, in the order required by their leases. A spent
            // one-shot must not invalidate the first send, nor silently switch later targets to a fallback.
            var firstId = Guid.Parse(plan.Targets[0].Guid);
            if (!held.Targets.TryGetValue(firstId, out var firstExpected) || !held.Hosts.TryGetValue(firstId, out var firstHost)
                || !DistinguishedName.AreEqual(firstExpected.Dn, plan.Targets[0].Dn))
            { throw new DomeniaOperationException(RelationErrors.PlanRefused, "Première cible étrangère à la préparation conservée ; aucun contact."); }
            AdWorkstationReadAccess? acquired = null;
            try
            {
                if (!stopRun.IsCancellationRequested)
                {
                    acquired = await AdWorkstationReadAccess.AcquireAsync(source, firstHost, firstExpected.Dn, lifetime.Token,
                        held.AccessVersion, held.MachineGeneration).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && stopRun.IsCancellationRequested) { }
            using var retained = acquired;
            var firstMachine = retained?.Machine;
            var directory = retained?.Directory;
            var accessVersion = AccessVersion(); var machineGeneration = MachineGeneration();
            void Current()
            {
                EnsureEpoch(epoch); cancellationToken.ThrowIfCancellationRequested();
                if (accessVersion != AccessVersion() || machineGeneration != MachineGeneration())
                {
                    interrupted = "Sélection de compte modifiée pendant le relevé ; aucune autre cible demandée.";
                    abort.Cancel(); throw new OperationCanceledException(abort.Token);
                }
                directory?.EnsureCurrent();
            }
            if (held.Subject is { } subject && directory is not null)
            {
                var fresh = (await AdRelationDirectory.ExactAsync(directory, local.Directory.Domain, subject.Dn, subject.Guid, false, lifetime.Token).ConfigureAwait(false)).Object;
                if (fresh.Kind != RelationSubjectKind.User || fresh.Login != subject.Login || fresh.Sid != subject.Sid || fresh.Created != subject.Created)
                { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Compte recherché modifié depuis la collecte ; aucune sonde lancée."); }
            }
            async Task<RelationConsoleOutcome> Read(RelationPlanTarget target, CancellationToken token)
            {
                var began = source.Clock.GetTimestamp(); Current(); token.ThrowIfCancellationRequested();
                var id = Guid.Parse(target.Guid);
                if (!held.Targets.TryGetValue(id, out var expected) || !held.Hosts.TryGetValue(id, out var host) || !DistinguishedName.AreEqual(expected.Dn, target.Dn))
                { throw new DomeniaOperationException(RelationErrors.PlanRefused, "Cible étrangère à la préparation conservée ; aucun contact."); }
                ConsoleResult read;
                try
                {
                    if (id != firstId && firstMachine?.SingleUse == true)
                    {
                        interrupted = "Bail à usage unique engagé pour la première cible ; aucun compte de repli choisi pour les consoles suivantes.";
                        throw new DomeniaOperationException(AccountAccess.EpochChanged, interrupted);
                    }
                    using var selected = id == firstId ? null : await AdWorkstationAccess.AcquireAsync(source, host, token, MachineGeneration()).ConfigureAwait(false);
                    var machine = selected ?? firstMachine ?? throw new OperationCanceledException(lifetime.Token);
                    read = await ReadConsoleAsync(local.Directory.Domain, expected, epoch, token, directory, host, retainedAccess: machine).ConfigureAwait(false);
                }
                catch (DomeniaOperationException ex) when (ex.Code == AccountAccess.EpochChanged)
                { interrupted ??= "Compte ou session modifié ; le relevé s’arrête sans changer d’identité."; abort.Cancel(); throw new OperationCanceledException(abort.Token); }
                catch (DomeniaOperationException ex) when (ex.Code is MachineErrors.PasswordMissing or AccountAccess.ContextRefused)
                {
                    interrupted = "Compte choisi inutilisable pour le relevé ; aucun autre compte essayé."; abort.Cancel();
                    return new("REFUSE", "Compte non utilisable", interrupted, null, (long)source.Clock.GetElapsedTime(began).TotalMilliseconds);
                }
                catch (DomeniaOperationException)
                { return new("ERREUR", "Identité non confirmée", "Identité déplacée, remplacée ou devenue illisible ; cible écartée sans substitution.", null, (long)source.Clock.GetElapsedTime(began).TotalMilliseconds); }
                Current(); token.ThrowIfCancellationRequested(); readings[target.Guid] = read;
                var confirmed = read.Relation is { } relation && (held.Subject is null || relation.UserGuid == held.Subject.Guid);
                if (confirmed)
                {
                    var accepted = AdRelationSession.For(source).ObserveValidated(read.Relation!, epoch);
                    if (accepted.Accepted) { observations[RelationRules.Key(read.Relation!)] = read.Relation!; }
                    else { memoryIssue = accepted.Reason; }
                }
                var status = confirmed ? "CONFIRME" : read.Status switch
                {
                    "VIDE" => "LU", "LU" when read.Relation is not null => "LU", "REFUSE" => "REFUSE", "AUTH_REJETEE" => "AUTH_REJETEE",
                    "ARRETE" => "DELAI", _ => "ERREUR",
                };
                var label = confirmed ? "Console confirmée" : status == "LU" ? read.Observed is null ? "Aucun compte console" : "Autre compte console"
                    : RelationRules.AttemptStatus(status).Label;
                return new(status, label, read.Message, read.Observed?.Account, (long)source.Clock.GetElapsedTime(began).TotalMilliseconds);
            }
            async Task<PresenceMeasure> Ping(RelationPlanTarget target, CancellationToken token)
            {
                Current(); token.ThrowIfCancellationRequested();
                var host = held.Hosts[Guid.Parse(target.Guid)];
                PresenceMeasure measure;
                if (PingOverride is { } injected)
                {
                    var answer = await injected(host, token).ConfigureAwait(false);
                    var at = source.Clock.GetUtcNow();
                    measure = new(MeasureState.Known, answer, at, answer ? at : null);
                }
                else measure = await (PresenceReaderOverride ?? new WorkstationPresenceReader(source.Clock, source.AccountContext?.Log))
                    .ReadAsync(host, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(1), null, token).ConfigureAwait(false);
                Current(); token.ThrowIfCancellationRequested(); return measure;
            }
            void Step(RelationProbeStep step)
            {
                var target = step.Target; var outcome = step.Outcome; var label = RelationRules.AttemptStatus(outcome.Status);
                if (readings.TryGetValue(target.Guid, out var read)) { attempts.AddRange(read.Attempts); }
                else { attempts.Add(new(step.PingFailed || step.PingUnconfirmed ? "Ping groupé" : "Identité de cible", outcome.Status, label.Label, label.Tone, target.Computer, outcome.Detail, outcome.DurationMs, step.PingFailed || step.PingUnconfirmed ? "Réseau · ICMP" : "Annuaire")); }
                candidates.TryGetValue(target.Guid, out var previous);
                var confirmed = outcome.Status == "CONFIRME";
                var badge = RelationRules.BadgeOf(confirmed ? RelationKind.Console : RelationKind.Hint);
                var at = read?.Observed?.ObservedAt;
                // A confirmed read replaces the pre-read hint (and the sweep origin), so the card does not contradict its own result.
                var origins = confirmed && sweep ? RelationRules.SweepReadOrigin : previous?.Origins ?? target.Source;
                var why = confirmed ? RelationRules.ConsoleReadWhy(at ?? source.Clock.GetUtcNow(), source.Clock.GetUtcNow(), source.Zone, outcome.Account) : previous?.Why ?? target.Source;
                candidates[target.Guid] = new(target.Guid, target.Computer, target.Dn, origins,
                    why, confirmed, confirmed ? null : outcome.Detail, badge.Badge, badge.Label, badge.Tone,
                    outcome.Label, outcome.Account, at, RelationRules.WhenText(at, source.Clock.GetUtcNow(), source.Zone), confirmed, previous?.Known ?? false, previous?.AlreadyLinked ?? false);
                var status = step.PingFailed ? "PING_MUET" : outcome.Status is "CONFIRME" or "LU" or "REFUSE" or "AUTH_REJETEE" or "DELAI" ? outcome.Status : "ERREUR";
                passes.Add(new(Guid.Parse(target.Guid), target.Dn, target.Computer, source.Clock.GetUtcNow(), status, outcome.Account));
                progress?.Report(new(planId, step.Counters, target.Computer, outcome.Status, outcome.Label, label.Tone, outcome.Account));
            }
            var run = await RelationProbeLoop.RunQualifiedAsync(plan, Read, sweep ? Ping : null, Step, stopRun.Token, cancellationToken).ConfigureAwait(false);
            EnsureEpoch(epoch); cancellationToken.ThrowIfCancellationRequested();
            string? passMessage = null;
            if (passes.Count > 0 && sweepMemory is not null && sweepWriter is not null)
            {
                try
                {
                    var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false); EnsureEpoch(epoch);
                    using var writeLease = source.AcquireWriteLease(session);
                    var saved = await sweepWriter.ApplyRelationSweepsAsync(new(sweepMemory.StoreId, WritePlans.NewId(), sweepMemory.Generation, passes.ToImmutable()), cancellationToken).ConfigureAwait(false);
                    EnsureEpoch(epoch); passMessage = saved.Detail;
                }
                catch (Exception ex) when (ex is DomeniaOperationException or IOException or UnauthorizedAccessException or InvalidDataException)
                { memoryIssue = "Passages non confirmés dans la mémoire du parc (écriture refusée ou mémoire effacée entre-temps) ; aucun rejeu. Les observations de relations restent indépendantes."; }
            }
            var found = observations.ToImmutable();
            var resultId = results.RememberObservations(sweep ? "Relevé du parc" : "Détection", found, epoch);
            var message = (interrupted ?? (run.AuthRejected ? "Relevé arrêté au premier rejet d’identifiants ; aucun autre poste interrogé."
                : elapsed.IsCancellationRequested ? "Budget global de 120 secondes atteint ; résultat partiel."
                : run.Counters.Stopped ? "Arrêt demandé ; observations déjà confirmées conservées." : "Liste confirmée parcourue.")) + " " + run.Counters.Text + ".";
            if (run.PingFailures > 0) { message += " " + FrenchText.Count(run.PingFailures, "poste sans réponse ICMP", "postes sans réponse ICMP") + " : console non demandée, état allumé/éteint inconnu."; }
            var unconfirmedPings = run.Steps.Count(s => s.PingUnconfirmed);
            if (unconfirmedPings > 0) { message += " " + FrenchText.Count(unconfirmedPings, "présence non confirmée", "présences non confirmées") + " : erreur ou délai du test, console non demandée."; }
            if (found.Count > 0) { message += " " + FrenchText.Count(found.Count, "observation qualifiée en mémoire", "observations qualifiées en mémoire") + " ; mémorisation locale demandée par le pont, aucune affectation remplacée."; }
            if (memoryIssue is not null) { message += " " + memoryIssue; }
            if (passMessage is not null) { message += " " + passMessage; }
            if (resultId == RelationChange.SessionResultId) { message += " Aperçus individuels pleins ; observations regroupées avec les attentes de la session."; }
            var subjectView = held.Subject is { } who ? new RelationSubject(who.Kind, who.Dn, who.Guid.ToString("D"), who.Name, who.Login, who.Detail,
                RelationRules.Path(who.Dn, local.Directory.Domain.DnsName), who.Enabled, who.LastLogon, who.Created) : null;
            return new(resultId, sweep ? "sweep" : "probe", subjectView, attempts.ToImmutable(),
                [.. candidates.Values.OrderByDescending(c => c.Confirmed).ThenBy(c => c.Computer, StringComparer.OrdinalIgnoreCase)], [], plan, run.Counters,
                run.Counters.Stopped || !run.Complete || memoryIssue is not null, run.Within, run.Complete && memoryIssue is null, found.Count, message);
        }
        finally { results.EndProbe(); }
    }
}
