using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Ad;

public sealed partial class AdOperationsReader : IHomeCampaignRecorder, IHomeWidgetAdmission
{
    public async Task<IDisposable> AcquireHomeWidgetAdmissionAsync(CancellationToken cancellationToken)
    {
        var epoch = source.Epoch;
        var lease = await Store.AcquireOperationsLeaseAsync(cancellationToken).ConfigureAwait(false);
        try { EnsureEpoch(epoch); return lease; }
        catch { lease.Dispose(); throw; }
    }

    public async Task<HomeCampaignStored> ReadHomeCampaignAsync(CancellationToken cancellationToken)
    {
        var state = await Store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
        OperationsPersistence.Validate(state);
        return new(state.Revision, state.HomeCampaign);
    }

    public async Task<IHomeCampaignLease> BeginHomeCampaignAsync(HomeCampaignCheckpoint plan, string? expectedToken, CancellationToken cancellationToken, bool replace = false)
    {
        var epoch = source.Epoch; IDisposable? exclusive = null;
        await saving.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (gate) { ObjectDisposedException.ThrowIf(disposed, this); }
            var store = Store;
            exclusive = await store.AcquireOperationsLeaseAsync(cancellationToken).ConfigureAwait(false);
            var before = await store.ReadOperationsAsync(cancellationToken).ConfigureAwait(false);
            EnsureEpoch(epoch); cancellationToken.ThrowIfCancellationRequested();
            HomeCampaignRules.Validate(plan, before.StoreId, before.DomainDn);
            if (before.Survey is not null)
            { throw new DomeniaOperationException("operations.surveyBusy", "Un relevé Recherche reste à reprendre ; son plan est conservé. Terminez-le ou abandonnez-le explicitement avant l’actualisation Accueil."); }
            if (expectedToken is null && before.HomeCampaign is not null) { throw Changed(); }
            if (expectedToken is not null)
            {
                var previous = before.HomeCampaign;
                if (new HomeCampaignStored(before.Revision, previous).Token != expectedToken || previous is null) { throw Changed(); }
                if (!replace && (!ScopeRules.SameScope(previous.Scope, plan.Scope) || previous.Mode != plan.Mode || previous.StartedAt != plan.StartedAt
                    || !previous.Stages.SequenceEqual(plan.Stages) || !previous.Targets.SequenceEqual(plan.Targets)
                    || !previous.Branches.SequenceEqual(plan.Branches)
                    || previous.ReadWithoutEcho != plan.ReadWithoutEcho
                    || !previous.Probes.SequenceEqual(plan.Probes) || !previous.Queries.SequenceEqual(plan.Queries)
                    || previous.DoneStages.Except(plan.DoneStages).Any() || previous.PresenceDone.Except(plan.PresenceDone).Any()
                    || previous.InventoryDone.Except(plan.InventoryDone).Any() || previous.PresenceStartedAt != plan.PresenceStartedAt
                    || previous.Forced && !plan.Forced)) { throw Changed(); }
            }
            var next = before with { Revision = checked(before.Revision + 1), Survey = null, HomeCampaign = plan with { UpdatedAt = Now, Interrupted = false } };
            var committed = await store.UpdateOperationsAsync(before.Revision, next, cancellationToken).ConfigureAwait(false);
            EnsureEpoch(epoch); cancellationToken.ThrowIfCancellationRequested();
            var lease = new HomeLease(this, store, exclusive, committed, epoch); exclusive = null;
            return lease;
        }
        finally { exclusive?.Dispose(); saving.Release(); }
    }

    private Task<DirectoryState> ReadHomeDirectoryAsync(CancellationToken token) => source.ReadLocalAsync(token);

    private sealed class HomeLease(AdOperationsReader owner, IOperationsLocalStore store, IDisposable exclusive, OperationsLocalState initial, long epoch) : IHomeCampaignLease
    {
        private readonly SemaphoreSlim serial = new(1, 1);
        private readonly Lock life = new();
        private OperationsLocalState current = initial;
        private HomeCampaignCheckpoint state = initial.HomeCampaign ?? throw new InvalidDataException("Plan Accueil absent après commit.");
        private bool disposeRequested;
        private int pending;
        private bool finished;
        public HomeCampaignCheckpoint State { get { lock (life) { return state; } } }

        public async Task SaveAsync(ImmutableArray<string> doneStages, ImmutableArray<Guid> presenceDone, ImmutableArray<Guid> inventoryDone,
            DateTimeOffset? presenceStartedAt, CancellationToken cancellationToken)
        {
            Enter();
            try
            {
                await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    if (finished) { throw Changed(); }
                    owner.EnsureEpoch(epoch);
                    if (state.DoneStages.Except(doneStages).Any() || state.PresenceDone.Except(presenceDone).Any() || state.InventoryDone.Except(inventoryDone).Any()
                        || state.PresenceStartedAt is not null && state.PresenceStartedAt != presenceStartedAt) { throw Changed(); }
                    var next = state with { DoneStages = doneStages, PresenceDone = presenceDone, InventoryDone = inventoryDone, PresenceStartedAt = presenceStartedAt, UpdatedAt = owner.Now };
                    HomeCampaignRules.Validate(next, current.StoreId, current.DomainDn);
                    await CommitAsync(next, cancellationToken).ConfigureAwait(false);
                    owner.EnsureEpoch(epoch);
                }
                finally { serial.Release(); }
            }
            finally { Exit(); }
        }

        public async Task BindDirectoryAsync(DirectoryState committed, CancellationToken cancellationToken)
        {
            Enter();
            try
            {
                await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    if (finished || !state.Stages.Contains("directory") || state.DoneStages.Contains("commit")
                        || state.PresenceStartedAt is not null || !state.PresenceDone.IsEmpty || !state.InventoryDone.IsEmpty
                        || state.DoneStages.Any(s => s is "presence" or "inventory" or "queries")) { throw Changed(); }
                    owner.EnsureEpoch(epoch);
                    var proof = committed.DirectoryCommit;
                    if (proof is null || proof.SessionEpoch != epoch || !proof.Receipt.Matches(current.StoreId, current.DomainDn, state.Scope, committed.Directory, owner.Now))
                    { throw Changed(); }
                    var targets = HomeCampaignRules.SelectTargets(committed.Directory, state.Scope, state.Branches);
                    var local = await owner.ReadHomeDirectoryAsync(cancellationToken).ConfigureAwait(false);
                    var actual = local.Directory.Computers.ToDictionary(c => c.ObjectGuid);
                    if (local.DirectoryCommit != proof || targets.Any(t => !actual.TryGetValue(t.Guid, out var pc) || !t.Matches(pc))) { throw Changed(); }
                    var next = state with { Targets = targets, UpdatedAt = owner.Now };
                    HomeCampaignRules.Validate(next, current.StoreId, current.DomainDn);
                    await CommitAsync(next, cancellationToken).ConfigureAwait(false);
                    owner.EnsureEpoch(epoch);
                }
                finally { serial.Release(); }
            }
            finally { Exit(); }
        }

        public async Task FinishAsync(bool complete, CancellationToken cancellationToken)
        {
            Enter();
            try
            {
                await serial.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    if (finished) { throw Changed(); }
                    if (complete && state.Stages.Except(state.DoneStages).Any()) { throw Changed(); }
                    // Finalization can preserve the last qualified progress after a source cancellation. It never adds a bit.
                    await CommitAsync(complete ? null : state with { UpdatedAt = owner.Now, Interrupted = true }, cancellationToken).ConfigureAwait(false);
                    finished = true;
                }
                finally { serial.Release(); }
            }
            finally { Exit(); }
        }

        private async Task CommitAsync(HomeCampaignCheckpoint? next, CancellationToken token)
        {
            var before = await store.ReadOperationsAsync(token).ConfigureAwait(false);
            if (before.StoreId != current.StoreId || before.Revision != current.Revision || before.HomeCampaign?.Id != state.Id || before.Survey is not null) { throw Changed(); }
            var saved = await store.UpdateOperationsAsync(before.Revision, before with { Revision = checked(before.Revision + 1), HomeCampaign = next }, token).ConfigureAwait(false);
            current = saved;
            if (next is not null) { lock (life) { state = saved.HomeCampaign ?? throw Changed(); } }
        }
        private void Enter() { lock (life) { ObjectDisposedException.ThrowIf(disposeRequested, this); pending++; } }
        private void Exit() { lock (life) { pending--; if (disposeRequested && pending == 0) { exclusive.Dispose(); } } }
        public void Dispose() { lock (life) { if (disposeRequested) { return; } disposeRequested = true; if (pending == 0) { exclusive.Dispose(); } } }
    }
}
