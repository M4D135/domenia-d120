using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// The write circuit (docs/OPERATIONS.md § 12, docs/WRITES.md): the generic execution of a confirmed plan, the only operation
/// of class Write the admission guards accept, and the receipts read by Opérations. Every screen builds its plans with its own
/// « &lt;screen&gt;.&lt;verb&gt;.plan » operation (a read) and never declares a write of its own.
/// </summary>
public sealed class WriteOperations : IOperationModule
{
    /// <summary>Longest typed name accepted (a sAMAccountName has 20 characters, a CN at most 64).</summary>
    public const int MaxTypedNameLength = 256;

    private static readonly string[] ExecuteArguments = ["planId", "token", "typedName"];
    private static readonly string[] ReceiptArguments = ["id"];

    public string Screen => "write";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return Definitions(WriteCircuit.From(context));
    }

    /// <summary>The operations over a given circuit (tests and hosts that compose by hand).</summary>
    public static IReadOnlyList<OperationDefinition> Definitions(WriteCircuit circuit)
    {
        ArgumentNullException.ThrowIfNull(circuit);
        return
        [
            // Write: admitted by both guards for this operation only (AdmissionGuards.IsWriteCircuit). In simulation its
            // executors change the in-memory overlay of the fictitious directory, nothing real.
            new OperationDefinition(WriteCircuit.ExecuteOperation, OperationClass.Write, async (args, bridge, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ExecuteArguments);
                var planId = BridgeArguments.GetString(values, "planId");
                if (!WritePlans.IsPlanId(planId))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("planId") + " doit être un identifiant de plan (32 caractères hexadécimaux).");
                }
                var token = BridgeArguments.GetString(values, "token");
                if (!ConfirmationTokens.IsWellFormed(token))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("token") + " doit être un jeton de confirmation.");
                }
                var typedName = BridgeArguments.GetOptionalString(values, "typedName");
                if (typedName is { Length: > MaxTypedNameLength })
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("typedName") + " doit faire au plus " + FrenchText.Integer(MaxTypedNameLength) + " caractères.");
                }
                return await circuit.ExecuteAsync(planId, token, typedName,
                    stage => bridge.Publish("stage", new WriteStageEvent(stage, WriteCircuit.StageLabel(stage))),
                    cancellationToken).ConfigureAwait(false);
            }, "Exécute une fois un plan d’écriture confirmé, enregistre son reçu avant l’envoi puis relit l’objet\u00A0; jamais rejoué."),

            new OperationDefinition("write.receipts.list", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await circuit.ListAsync(cancellationToken).ConfigureAwait(false);
            }, "Reçus d’écriture du mode, ceux à vérifier d’abord."),

            new OperationDefinition("write.receipts.get", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var id = ReceiptId(args);
                return await circuit.GetAsync(id, cancellationToken).ConfigureAwait(false);
            }, "Un reçu d’écriture avec son plan et ses détails."),

            // NetworkRead: reads the target again on the directory (memory in simulation), after the operator's gesture; the
            // write itself is never sent again. The new version of the receipt is a local write of the application.
            new OperationDefinition("write.receipts.verify", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var id = ReceiptId(args);
                return await circuit.VerifyAsync(id, cancellationToken).ConfigureAwait(false);
            }, "Relit l’objet d’un reçu pour vérifier l’écriture\u00A0; rien n’est renvoyé.", ServedInSimulation: true),
        ];
    }

    private static string ReceiptId(System.Text.Json.JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, ReceiptArguments);
        var id = BridgeArguments.GetString(values, "id");
        return WritePlans.IsPlanId(id)
            ? id
            : throw BridgeArguments.Invalid(FrenchText.Quote("id") + " doit être un identifiant de reçu (32 caractères hexadécimaux).");
    }
}
