using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class DirectoryCapabilityRefusalTests
{
    private sealed class DirectoryWriter(string kind) : IWriteExecutor, IDirectoryMutationExecutor
    {
        internal FakeWriteExecutor Inner { get; } = new();
        public string Kind => kind;
        public Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken token) => Inner.CheckAsync(plan, token);
        public Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken token)
        { DirectoryWriteEvidence.Sent(); return Inner.ExecuteAsync(plan, token); }
        public Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken token) => Inner.VerifyAsync(plan, token);
    }
    [Test]
    public static async Task Actual_controller_denial_is_remembered_only_for_the_target_capability_and_session()
    {
        var clock = TestClock.Fixed(); var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var writer = new DirectoryWriter(ObjectWrites.EnabledKind);
        writer.Inner.OnExecute = _ => throw DirectoryNativeWriteBoundaryTests.Refusal(50);
        writer.Inner.OnVerify = _ => new(VerificationState.Mismatch, "État inchangé relu");
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(), writers: WriteExecutors.From([writer]));
        var circuit = WriteCircuit.From(context);
        var draft = FakeWriteExecutor.Draft() with { Kind = ObjectWrites.EnabledKind };
        var first = await circuit.PlanAsync(draft, default);
        await circuit.ExecuteAsync(first.Plan.Id, first.Token, null, null, default);
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(draft, default), "refus réel encore actif");
        Check.Equal("write.capabilityDenied", error.Code, "raison précise et locale"); Check.Equal(1, writer.Inner.Executes, "aucun nouvel envoi");
        var session = await source.GetSessionAsync(default);
        Check.True(circuit.RefusedActions(session, Guid.Parse(FakeWriteExecutor.TargetGuid)).ContainsKey("enable"), "fiche ciblée désactivée");
        Check.False(circuit.RefusedActions(session, Guid.Parse(FakeWriteExecutor.OtherGuid)).ContainsKey("enable"), "autre cible préservée");
        await circuit.PlanAsync(draft with { Target = draft.Target with { ObjectGuid = FakeWriteExecutor.OtherGuid } }, default);
        Check.Equal(0, circuit.RefusedActions(session with { Epoch = session.Epoch + 1 }, Guid.Parse(FakeWriteExecutor.TargetGuid)).Count, "nouvelle session n’hérite pas du verdict");
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(draft, default), "consulter un autre contexte ne supprime pas le refus réel");
    }

    [Test]
    public static async Task Attribute_sets_are_separate_and_the_expiration_does_not_replay_a_write()
    {
        var clock = TestClock.Fixed(); var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var writer = new DirectoryWriter(ObjectWrites.UpdateKind);
        writer.Inner.OnExecute = _ => throw DirectoryNativeWriteBoundaryTests.Refusal(50);
        writer.Inner.OnVerify = _ => new(VerificationState.Mismatch, "État inchangé");
        using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(), writers: WriteExecutors.From([writer]));
        var circuit = WriteCircuit.From(context); var draft = FakeWriteExecutor.Draft() with { Kind = ObjectWrites.UpdateKind };
        var first = await circuit.PlanAsync(draft, default); await circuit.ExecuteAsync(first.Plan.Id, first.Token, null, null, default);
        await Check.ThrowsAsync<DomeniaOperationException>(() => circuit.PlanAsync(draft, default), "même ensemble d’attributs bloqué");
        await circuit.PlanAsync(draft with { Changes = [draft.Changes[0] with { Attribute = "displayName" }] }, default);
        clock.Advance(TimeSpan.FromMinutes(5));
        await circuit.PlanAsync(draft, default);
        Check.Equal(1, writer.Inner.Executes, "expiration ne rejoue aucune écriture");
    }
    [Test]
    public static async Task Network_failures_credentials_and_non_directory_executors_never_create_an_AD_capability_verdict()
    {
        foreach (var (directory, code) in new[] { (true, "network.timeout"), (true, "ad.credentials"), (false, "ad.accessDenied") })
        {
            var clock = TestClock.Fixed(); var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
            var native = new DirectoryWriter(ObjectWrites.EnabledKind); var local = new FakeWriteExecutor();
            var fake = directory ? native.Inner : local;
            fake.OnExecute = _ => throw new DomeniaOperationException(code, "Échec synthétique distinct d’un refus de capacité AD");
            fake.OnVerify = _ => new(VerificationState.Mismatch, "État inchangé relu");
            IWriteExecutor writer = directory ? native : local;
            using var context = new EngineContext(SimulatedBridge.Decision, source, new MemoryPreferenceStore(), clock, new RecordingJournal(), writers: WriteExecutors.From([writer]));
            var circuit = WriteCircuit.From(context); var draft = FakeWriteExecutor.Draft() with { Kind = writer.Kind };
            var plan = await circuit.PlanAsync(draft, default); await circuit.ExecuteAsync(plan.Plan.Id, plan.Token, null, null, default);
            Check.Equal(0, circuit.RefusedActions(await source.GetSessionAsync(default), Guid.Parse(FakeWriteExecutor.TargetGuid)).Count, "aucune capacité AD déclarée refusée : " + code);
            Check.Equal(1, fake.Executes, "aucun rejeu");
        }
    }

}
