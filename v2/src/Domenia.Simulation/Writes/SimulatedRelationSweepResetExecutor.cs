using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// « Oublier les relevés » in simulation (docs/ops/relations.md, Domenia 1 REL-031): the relevé memory of the session
/// (<see cref="SimulatedRelationState"/>: readings of the relevés, session reads and harvests, and console relations of the store)
/// is forgotten, so the next relevé starts again with the workstations never read. Memory only: no base is opened, nothing is
/// written to disk, no association is removed and Active Directory is never involved.
/// </summary>
public sealed class SimulatedRelationSweepResetExecutor : IRelationSweepResetExecutor
{
    private readonly SimulatedDirectorySource source;

    /// <summary>Found by WriteExecutors.Discover for the simulated source; cheap: nothing is read here.</summary>
    public SimulatedRelationSweepResetExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public string Kind => RelationSweepReset.Kind;

    private SimulatedRelationState State => SimulatedRelationState.For(source);

    public async Task<WritePlanDraft> PlanSweepResetAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("plan", 80, 180, cancellationToken).ConfigureAwait(false);
        var state = State;
        var (count, fingerprint, oldest) = state.Readings();
        var oldestText = oldest is DateTimeOffset at ? RelationRules.WhenText(at, state.Now, state.Zone) : null;
        return RelationSweepReset.Draft(count, fingerprint, oldestText, simulated: true, backupVerified: false);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await WaitAsync("check", 40, 120, cancellationToken).ConfigureAwait(false);
        var (count, fingerprint, _) = State.Readings();
        return RelationSweepReset.Check(plan, count, fingerprint);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await WaitAsync("execute", 80, 200, cancellationToken).ConfigureAwait(false);
        var state = State;
        var (count, fingerprint, _) = state.Readings();
        var check = RelationSweepReset.Check(plan, count, fingerprint);
        if (!check.Current)
        {
            throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail);
        }
        if (count == 0)
        {
            return new WriteOutcome(WriteResult.NoChange, "Mémoire des relevés déjà vide" + FrenchText.Colon + "aucune écriture.");
        }
        var forgotten = state.ForgetReadings();
        return new WriteOutcome(WriteResult.Applied, FrenchText.Count(forgotten, "relevé oublié", "relevés oubliés") + " dans la mémoire de la simulation (aucun effet réel)"
            + FrenchText.Colon + "le prochain relevé reprendra par les postes jamais relevés.");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await WaitAsync("verify", 40, 120, cancellationToken).ConfigureAwait(false);
        return RelationSweepReset.Verify(State.Readings().Count);
    }

    private Task WaitAsync(string step, int min, int max, CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync("write/relations/reset/" + step, min, max, cancellationToken);
}
