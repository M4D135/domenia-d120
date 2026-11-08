using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Plan of the unlock of a user account (docs/OPERATIONS.md § 12.2): the reference example of a write for the screens
/// (docs/WRITES.md). The operation only reads: the executor of the mode reads the account and drafts the change, the write
/// circuit seals the plan and issues its single-use token. The write itself goes through write.execute.
/// </summary>
public sealed class AccountUnlockOperations : IOperationModule
{
    private static readonly string[] PlanArguments = ["dn"];

    public string Screen => "accounts";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var writers = context.Writers;
        var circuit = WriteCircuit.From(context);
        // A plan reads the account fresh: memory in simulation, the controller in directory mode (after the operator's gesture).
        var readClass = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        return
        [
            new OperationDefinition("accounts.unlock.plan", readClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, PlanArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var draft = await writers.Require<IAccountUnlockExecutor>().PlanAsync(dn, cancellationToken).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, cancellationToken).ConfigureAwait(false);
            }, "Plan du déverrouillage d’un compte\u00A0: relecture du compte, changement, risques et jeton de confirmation\u00A0; rien n’est écrit."),
        ];
    }
}
