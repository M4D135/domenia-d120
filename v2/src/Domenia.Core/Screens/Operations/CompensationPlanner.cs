using System.Globalization;

namespace Domenia.Core;

/// <summary>Creates a fresh inverse through the existing typed planner and checks its read values against the original receipt.</summary>
public static class CompensationPlanner
{
    private static DomeniaOperationException Refuse(string reason) => new("operations.compensationChanged", reason + " Aucune compensation préparée.");

    public static string CurrentDn(WritePlan plan)
    {
        if (plan.Kind != ObjectWrites.MoveKind) { return plan.Target.Dn; }
        var parent = plan.Changes.SingleOrDefault(c => c.Attribute == ObjectWrites.DnAttribute)?.AfterValue
            ?? throw Refuse("Destination d’origine non conservée.");
        var rdn = DistinguishedName.Parse(plan.Target.Dn)[0];
        return DistinguishedName.Child(rdn.Type, rdn.Value, parent);
    }

    public static async Task<PlannedWrite> PlanAsync(EngineContext context, string receiptId, string dn, CancellationToken token)
    {
        var circuit = WriteCircuit.From(context);
        var receipt = await circuit.GetAsync(receiptId, token).ConfigureAwait(false);
        var assessment = WriteKindRules.Assess(receipt);
        if (!assessment.Offered) { throw Refuse(assessment.Reason); }
        var original = receipt.Plan;
        if (context.Mode != AppMode.Simulation && original.Kind == ObjectWrites.MemberKind
            && original.Changes.Any(c => !Guid.TryParse(c.ReferenceGuid, out _)))
        { throw Refuse("Identité d’origine du membre non conservée dans ce reçu."); }
        var currentDn = CurrentDn(original);
        if (!DistinguishedName.AreEqual(currentDn, dn)) { throw Refuse("La fiche ne correspond pas à la cible du reçu."); }
        var settings = context.Readers.Find<IFicheSettingsReader>();
        var configuration = settings is null ? FicheConfiguration.Absent : await settings.ReadAsync(token).ConfigureAwait(false);
        var policy = FicheSecurityPolicy.From(configuration, context.Mode);
        var writers = context.Writers;
        var first = original.Changes[0];
        WritePlanDraft inverse;
        switch (original.Kind)
        {
            case ObjectWrites.UpdateKind:
                inverse = await writers.Require<IObjectUpdateExecutor>().PlanAsync(dn,
                    original.Changes.ToDictionary(c => c.Attribute, c => c.BeforeValue, StringComparer.OrdinalIgnoreCase), token).ConfigureAwait(false);
                break;
            case ObjectWrites.EnabledKind:
                inverse = await writers.Require<IAccountEnabledExecutor>().PlanAsync(dn, (Number(first.BeforeValue) & AdValues.AccountDisabled) == 0, token).ConfigureAwait(false);
                break;
            case AccountActivation.EnableKind:
            case AccountActivation.DisableKind:
                inverse = (Number(first.BeforeValue) & AdValues.AccountDisabled) == 0
                    ? await writers.Require<IAccountEnableExecutor>().PlanAsync(dn, token).ConfigureAwait(false)
                    : await writers.Require<IAccountDisableExecutor>().PlanAsync(dn,
                        (await context.Directory.GetSessionAsync(token).ConfigureAwait(false)).Account.Dn, token).ConfigureAwait(false);
                break;
            case ObjectWrites.OptionsKind:
                var old = Number(first.BeforeValue); var written = Number(first.AfterValue);
                var options = FicheSheets.OptionFlags.Where(o => (old & o.Flag) != (written & o.Flag))
                    .ToDictionary(o => o.Id, o => (old & o.Flag) != 0, StringComparer.Ordinal);
                inverse = await writers.Require<IAccountOptionsExecutor>().PlanAsync(dn, options, policy, token).ConfigureAwait(false);
                break;
            case ObjectWrites.ExpirationKind:
                inverse = await writers.Require<IAccountExpirationExecutor>().PlanAsync(dn,
                    AccountExpiration.DayOf(Number(first.BeforeValue), context.Clock.LocalTimeZone), token).ConfigureAwait(false);
                break;
            case ObjectWrites.RawKind:
                inverse = await writers.Require<IRawAttributeExecutor>().PlanAsync(dn, first.Attribute, first.BeforeValue, policy, token).ConfigureAwait(false);
                break;
            case ObjectWrites.MoveKind:
                inverse = await writers.Require<IObjectMoveExecutor>().PlanAsync(dn, first.BeforeValue ?? throw Refuse("Ancien conteneur inconnu."),
                    Guid.Parse(original.Target.ObjectGuid), token).ConfigureAwait(false);
                break;
            case ObjectWrites.MemberKind:
                inverse = await writers.Require<IGroupMemberExecutor>().PlanAsync(dn,
                    (first.Kind == WriteChangeKind.Add ? first.AfterValue : first.BeforeValue) ?? throw Refuse("Membre d’origine inconnu."), first.Kind == WriteChangeKind.Remove, token).ConfigureAwait(false);
                break;
            default: throw Refuse("Aucun plan inverse typé ne sert cette opération.");
        }
        VerifyInverse(original, inverse);
        var planned = await circuit.PlanAsync(inverse, token).ConfigureAwait(false);
        if (original.Kind == ObjectWrites.RawKind) { writers.Require<IRawAttributeExecutor>().Remember(planned.Plan.Id, planned.Plan.ExpiresAt, policy); }
        return planned;
    }

    private static long Number(string? text) => long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) && value >= 0
        ? value : throw Refuse("Valeur numérique d’origine absente ou invalide.");

    /// <summary>No historical value is sent unless a fresh typed plan read exactly the state written by the original.</summary>
    public static void VerifyInverse(WritePlan original, WritePlanDraft inverse)
    {
        if (!Guid.TryParse(original.Target.ObjectGuid, out var id) || !Guid.TryParse(inverse.Target.ObjectGuid, out var fresh) || id != fresh
            || !DistinguishedName.AreEqual(CurrentDn(original), inverse.Target.Dn)
            || !string.Equals(original.Controller, inverse.Controller, StringComparison.OrdinalIgnoreCase)
            || inverse.Changes.Length != original.Changes.Length)
        { throw Refuse("Identité, contrôleur ou ensemble d’attributs différent du reçu d’origine."); }
        foreach (var change in original.Changes)
        {
            var back = inverse.Changes.SingleOrDefault(c => c.Attribute.Equals(change.Attribute, StringComparison.OrdinalIgnoreCase));
            if (back is null || !Same(change.Attribute, back.BeforeValue, change.AfterValue) || !Same(change.Attribute, back.AfterValue, change.BeforeValue)
                || original.Kind == ObjectWrites.MemberKind && !string.Equals(change.ReferenceGuid, back.ReferenceGuid, StringComparison.OrdinalIgnoreCase))
            { throw Refuse("L’état relu diffère de la valeur écrite, ou l’inverse n’est pas exact."); }
        }
    }

    private static bool Same(string attribute, string? left, string? right) =>
        left is not null && right is not null && attribute is "distinguishedName" or "member" or "manager" or "managedBy"
            ? DistinguishedName.AreEqual(left, right) : string.Equals(left, right, StringComparison.Ordinal);
}
