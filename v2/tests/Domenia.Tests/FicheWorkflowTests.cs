using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Tests;

internal static class FicheWorkflowTests
{
    private static DirectoryUser User(SimulatedBridge bridge) => bridge.Source.CurrentDirectory.Users.Single(u => u.DisplayName == "Camille Bernard");
    private static async Task<PlannedWrite> UpdateAsync(SimulatedBridge bridge, string description)
    {
        var draft = await bridge.Context.Writers.Require<IObjectUpdateExecutor>().PlanAsync(User(bridge).DistinguishedName,
            new Dictionary<string, string?> { ["description"] = description }, CancellationToken.None);
        return await WriteCircuit.From(bridge.Context).PlanAsync(draft, CancellationToken.None);
    }
    private static Task<ReceiptView> ExecuteAsync(SimulatedBridge bridge, PlannedWrite write) => WriteCircuit.From(bridge.Context)
        .ExecuteAsync(write.Plan.Id, write.Token, write.Plan.Confirmation.TypedName, null, CancellationToken.None);
    private static LifecycleRequest Request(SimulatedBridge bridge) => new(LifecycleKind.ServiceChange, User(bridge).DistinguishedName, User(bridge).ObjectGuid,
        [], [], ImmutableDictionary<string, string?>.Empty.Add("description", "Nouveau service confirmé"), null);

    [Test]
    public static async Task Compensation_is_a_new_exact_plan_and_refuses_an_intervening_change()
    {
        var bridge = new SimulatedBridge(); var initial = User(bridge).Description;
        var receipt = await ExecuteAsync(bridge, await UpdateAsync(bridge, "Première modification"));
        var revision = bridge.Source.Overlay.Version;
        var inverse = await CompensationPlanner.PlanAsync(bridge.Context, receipt.Id, User(bridge).DistinguishedName, CancellationToken.None);
        Check.Equal(revision, bridge.Source.Overlay.Version, "préparation sans écriture");
        Check.Equal("Première modification", inverse.Plan.Changes.Single().BeforeValue, "état écrit relu");
        Check.Equal(initial, inverse.Plan.Changes.Single().AfterValue, "valeur initiale exacte");
        Check.True(inverse.Plan.Id != receipt.Plan.Id, "nouveau plan et nouveau jeton");
        await ExecuteAsync(bridge, await UpdateAsync(bridge, "Changement concurrent"));
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => CompensationPlanner.PlanAsync(bridge.Context, receipt.Id,
            User(bridge).DistinguishedName, CancellationToken.None), "pas d’écrasement du changement concurrent");
        Check.Equal("operations.compensationChanged", refusal.Code, "raison stable");
        Check.Equal("Changement concurrent", User(bridge).Description, "valeur préservée");
    }

    [Test]
    public static async Task Compensation_rejects_recreated_target_controller_change_or_incomplete_inverse()
    {
        var bridge = new SimulatedBridge(); var planned = await UpdateAsync(bridge, "Modification à inverser");
        var receipt = await ExecuteAsync(bridge, planned);
        var draft = await bridge.Context.Writers.Require<IObjectUpdateExecutor>().PlanAsync(User(bridge).DistinguishedName,
            new Dictionary<string, string?> { ["description"] = planned.Plan.Changes.Single().BeforeValue }, CancellationToken.None);
        CompensationPlanner.VerifyInverse(receipt.Plan, draft);
        Check.Throws<DomeniaOperationException>(() => CompensationPlanner.VerifyInverse(receipt.Plan,
            draft with { Target = draft.Target with { ObjectGuid = Guid.NewGuid().ToString("D") } }), "même DN autre GUID");
        Check.Throws<DomeniaOperationException>(() => CompensationPlanner.VerifyInverse(receipt.Plan, draft with { Controller = "other.example.local" }), "autre contrôleur");
        Check.Throws<DomeniaOperationException>(() => CompensationPlanner.VerifyInverse(receipt.Plan, draft with { Changes = [] }), "attribut non relu");
    }

    [Test]
    public static async Task Lifecycle_never_sends_a_write_on_prepare_and_requires_its_own_receipt_before_next_step()
    {
        var bridge = new SimulatedBridge(); var flow = LifecycleWorkflow.From(bridge.Context);
        var view = await flow.CreateAsync(Request(bridge), CancellationToken.None);
        var prepared = await flow.PrepareAsync(view.Id, false, CancellationToken.None);
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture à la création ni au plan");
        Check.Equal(prepared.Write!.Plan.Id, (await flow.PrepareAsync(view.Id, false, CancellationToken.None)).Write!.Plan.Id, "le même plan reste en attente");
        var alien = await ExecuteAsync(bridge, await UpdateAsync(bridge, "Autre opération"));
        await Check.ThrowsAsync<DomeniaOperationException>(() => flow.RecordAsync(view.Id, alien.Id, CancellationToken.None), "reçu étranger refusé");
        // The concurrent change makes the actual plan stale. It cannot silently advance the sequence.
        await Check.ThrowsAsync<DomeniaOperationException>(() => ExecuteAsync(bridge, prepared.Write), "plan périmé refusé avant envoi");
        Check.Equal(LifecycleStepState.Pending, (await flow.ReadAsync(view.Id, CancellationToken.None)).Plan.Steps[0].State, "aucun succès déduit");
    }

    [Test]
    public static async Task Verified_lifecycle_step_advances_but_unknown_receipt_blocks_without_replay()
    {
        var bridge = new SimulatedBridge(); var flow = LifecycleWorkflow.From(bridge.Context);
        var view = await flow.CreateAsync(Request(bridge), CancellationToken.None);
        var prepared = (await flow.PrepareAsync(view.Id, false, CancellationToken.None)).Write!;
        var sent = WriteReceipts.Sent(prepared.Plan, WritePlans.NewId(), TestClock.Reference, new("Préconditions", "Test"));
        await bridge.Receipts.AppendAsync(sent, CancellationToken.None);
        var blocked = await flow.RecordAsync(view.Id, sent.Id, CancellationToken.None);
        Check.True(blocked.Plan.Blocked, "issue inconnue bloque");
        await Check.ThrowsAsync<DomeniaOperationException>(() => flow.PrepareAsync(view.Id, false, CancellationToken.None), "aucun rejeu");
        Check.Equal(0L, bridge.Source.Overlay.Version, "aucune écriture envoyée");
        var checkedReceipt = WriteReceipts.Verified(WriteReceipts.Completed(sent, new(WriteResult.Applied, "Test"), null, TestClock.Reference),
            new(VerificationState.Verified, "Preuve de relecture du test"), TestClock.Reference);
        await bridge.Receipts.AppendAsync(checkedReceipt, CancellationToken.None);
        var resolved = await flow.RecordAsync(view.Id, sent.Id, CancellationToken.None);
        Check.False(resolved.Plan.Blocked, "la relecture du même reçu peut lever l’incertitude");
        Check.Equal(LifecycleStepState.Verified, resolved.Plan.Steps[0].State, "étape prouvée");
        var review = await flow.PrepareAsync(view.Id, true, CancellationToken.None);
        Check.Null(review.Write, "contrôle explicite sans mutation");
        Check.True(review.Workflow.Plan.Steps.All(s => s.State == LifecycleStepState.Verified), "séquence terminée");
    }

    [Test]
    public static async Task Lifecycle_bridge_rejects_extra_fields_duplicate_groups_and_secret_templates()
    {
        var bridge = new SimulatedBridge(); var request = Request(bridge);
        Check.Throws<DomeniaOperationException>(() => LifecycleWorkflow.Validate(request with { Fields = request.Fields.Add("unicodePwd", "test") }), "secret interdit");
        Check.Throws<DomeniaOperationException>(() => LifecycleWorkflow.Validate(request with { AddGroups = ["CN=Group,DC=example,DC=local"], RemoveGroups = ["CN=group,DC=example,DC=local"] }), "groupes contradictoires");
        Check.Throws<DomeniaOperationException>(() => LifecycleWorkflow.Validate(request with { Kind = LifecycleKind.Suspension, Fields = ImmutableDictionary<string, string?>.Empty }), "motif obligatoire");
        var response = await bridge.CallAsync("fiche.lifecycle.get", JsonSerializer.Serialize(new { id = "missing", execute = true }));
        Check.Equal(DomeniaErrors.ArgumentsInvalid, response.Error!.Code, "arguments fermés");
    }
}
