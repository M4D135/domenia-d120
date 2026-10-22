using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>What one console read of a confirmed workstation gave (status of the Domenia 1 vocabulary: CONFIRME, LU, REFUSE…).</summary>
public sealed record RelationConsoleOutcome(string Status, string Label, string Detail, string? Account, long DurationMs);

/// <summary>One workstation of a probe, as it ended: its outcome, the counters after it and whether the ping answered.</summary>
public sealed record RelationProbeStep(RelationPlanTarget Target, RelationConsoleOutcome Outcome, RelationCounters Counters, bool PingFailed);

/// <summary>
/// End of a probe: counters, the workstations really contacted, whether the list stayed inside the confirmed plan and matched it,
/// and why it stopped early (stop requested, or credentials rejected on <see cref="RejectedOn"/>).
/// </summary>
public sealed record RelationProbeRun(
    RelationCounters Counters,
    ImmutableArray<RelationProbeStep> Steps,
    ImmutableArray<string> Probed,
    bool Within,
    bool Complete,
    bool AuthRejected,
    string? RejectedOn,
    int PingFailures);

/// <summary>
/// Loop of a console probe over a confirmed plan, shared by every source (Domenia 1 Submit-DomeniaRelationsQuery,
/// Invoke-DomeniaRelationsTick and the relevé of the parc): only the targets of the plan, in its order, one at a time; an
/// optional ping by batches of <see cref="PingBatchSize"/> first (relevé: a workstation that does not answer is not asked
/// for its session, Domenia 1 REL-031); counters after each workstation; a stop request ends the probe after the workstation
/// being read and declares a partial result; the first rejection of the credentials (AUTH_REJETEE) stops it at once, with
/// nothing retried (Domenia 1 REL-021, TRV-206). The source only says how to read and ping one workstation.
/// </summary>
public static class RelationProbeLoop
{
    /// <summary>Workstations pinged together before the console reads of a relevé.</summary>
    public const int PingBatchSize = 8;

    /// <summary>Status of a credentials rejection (0x8007052E, 0x8009030C…): the probe stops on the first one.</summary>
    public const string AuthRejected = "AUTH_REJETEE";

    /// <summary>Runs the probe of <paramref name="plan"/>.</summary>
    /// <param name="plan">Confirmed plan (its targets only are contacted).</param>
    /// <param name="read">Console read of one target; may throw <see cref="OperationCanceledException"/> on a stop request.</param>
    /// <param name="ping">Optional ping of one target (true when it answers), run by batches before the console reads.</param>
    /// <param name="onStep">Called after each workstation, in order, on the calling flow.</param>
    /// <param name="stop">Stop request of the operator: partial result, nothing undone.</param>
    /// <param name="cancellationToken">Closing of the application.</param>
    public static async Task<RelationProbeRun> RunAsync(
        RelationDetectionPlan plan,
        Func<RelationPlanTarget, CancellationToken, Task<RelationConsoleOutcome>> read,
        Func<RelationPlanTarget, CancellationToken, Task<bool>>? ping,
        Action<RelationProbeStep>? onStep,
        CancellationToken stop,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(read);
        var counters = RelationRules.NewCounters(plan.Targets.Length);
        var steps = ImmutableArray.CreateBuilder<RelationProbeStep>();
        var probed = new List<string>();
        var silent = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(stop, cancellationToken);
        if (ping is not null)
        {
            for (var i = 0; i < plan.Targets.Length && !stop.IsCancellationRequested; i += PingBatchSize)
            {
                var batch = plan.Targets.Skip(i).Take(PingBatchSize).ToList();
                bool[] answers;
                try
                {
                    answers = await Task.WhenAll(batch.Select(t => ping(t, linked.Token))).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                for (var j = 0; j < batch.Count; j++)
                {
                    if (!answers[j])
                    {
                        silent.Add(batch[j].Guid);
                    }
                }
            }
        }
        var rejected = false;
        string? rejectedOn = null;
        foreach (var target in plan.Targets)
        {
            if (stop.IsCancellationRequested)
            {
                counters = RelationRules.Count(counters, RelationProbeOutcome.Stopped);
                break;
            }
            RelationConsoleOutcome outcome;
            var pingFailed = silent.Contains(target.Guid);
            if (pingFailed)
            {
                outcome = new RelationConsoleOutcome("DELAI", "Injoignable au ping",
                    "Aucune réponse au ping groupé" + FrenchText.Colon + "la session n’est pas demandée. Une absence de réponse n’est jamais un verdict d’arrêt.", null, 0);
            }
            else
            {
                try
                {
                    outcome = await read(target, linked.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    counters = RelationRules.Count(counters, RelationProbeOutcome.Stopped);
                    break;
                }
            }
            probed.Add(target.Guid);
            if (RelationRules.Outcome(outcome.Status) is { } counted)
            {
                counters = RelationRules.Count(counters, counted);
            }
            var step = new RelationProbeStep(target, outcome, counters, pingFailed);
            steps.Add(step);
            onStep?.Invoke(step);
            if (string.Equals(outcome.Status, AuthRejected, StringComparison.OrdinalIgnoreCase))
            {
                // The account of the session is refused: no other workstation is asked with it, nothing is retried.
                rejected = true;
                rejectedOn = target.Computer;
                counters = RelationRules.Count(counters, RelationProbeOutcome.Stopped);
                break;
            }
        }
        var planned = plan.Targets.Select(t => t.Guid).ToList();
        var within = RelationRules.WithinPlan(planned, probed);
        var complete = !rejected && RelationRules.MatchesPlan(planned, probed) && counters.Refused + counters.Unreachable == 0;
        return new RelationProbeRun(counters, steps.ToImmutable(), [.. probed], within, complete, rejected, rejectedOn, silent.Count);
    }
}
