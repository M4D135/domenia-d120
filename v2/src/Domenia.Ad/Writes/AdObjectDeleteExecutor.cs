using Domenia.Core;

namespace Domenia.Ad;

public sealed class AdObjectDeleteExecutor : AdFicheWriteExecutor, IObjectDeleteExecutor
{
    private readonly Func<CancellationToken, Task<FicheSecurityPolicy>> readPolicy;
    public AdObjectDeleteExecutor(AdDirectorySource source) : this(source, token => AdFichePolicies.ReadAsync(source, token)) { }
    internal AdObjectDeleteExecutor(AdDirectorySource source, Func<CancellationToken, Task<FicheSecurityPolicy>> policy) : base(source) => readPolicy = policy;
    public override string Kind => ObjectWrites.DeleteKind;
    private protected override bool StoreReadBack => false;

    public Task<WritePlanDraft> PlanAsync(string dn, FicheSecurityPolicy policy, CancellationToken cancellationToken) => PrepareAsync(dn, async (entry, session) =>
    {
        if (Source.LocalStore is not null and not IDirectoryDeletionCache)
        { throw FicheErrors.Error(FicheErrors.Refused, "La base locale ne permet pas de nettoyer une suppression ; aucune écriture préparée."); }
        var native = await readPolicy(cancellationToken).ConfigureAwait(false);
        var effective = policy with { AllowContainerDelete = policy.AllowContainerDelete && native.AllowContainerDelete,
            RequireTypedDeleteConfirmation = policy.RequireTypedDeleteConfirmation || native.RequireTypedDeleteConfirmation };
        await EnsureEmptyAsync(entry.Dn, cancellationToken).ConfigureAwait(false);
        var links = Source.LocalStore is IDirectoryDeletionCache cache
            ? await cache.CountDeletionLinksAsync(ObjectWrites.Target(entry), cancellationToken).ConfigureAwait(false) : new DirectoryDeletionLinks(0, 0);
        var draft = ObjectWrites.Delete(entry, 0, effective, session.Controller?.DnsName, links.Identified);
        return links.Unresolved == 0 ? draft : draft with { Risks = [.. draft.Risks, new(Tone.Warn,
            FrenchText.Count(links.Unresolved, "association historique sans identité", "associations historiques sans identité") + " : conservées pour revue, aucun retrait fondé sur le seul nom.")] };
    }, cancellationToken);

    private protected override async Task ValidateCurrentAsync(WritePlan plan, FicheEntry? current, SessionSnapshot session, CancellationToken token)
    {
        if (current is null) { return; }
        var native = await readPolicy(token).ConfigureAwait(false);
        // Run the same business guards again with the actual native policy.
        _ = ObjectWrites.Delete(current, 0, native, Source.ControllerName);
        if (native.RequireTypedDeleteConfirmation && (!plan.Confirmation.TypedNameRequired || plan.Confirmation.TypedName != ObjectWrites.TypedName(current)))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "La confirmation nominative requise n’est plus conforme ; préparez de nouveau la suppression."); }
        await EnsureEmptyAsync(current.Dn, token).ConfigureAwait(false);
    }

    private async Task EnsureEmptyAsync(string dn, CancellationToken token)
    {
        var rows = await Source.Connection.SearchAsync(new(dn, "(objectClass=*)", AdSearchScope.OneLevel, ["objectGUID"])
        { SizeLimit = 1, PageSize = 1, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, token).ConfigureAwait(false);
        if (rows.Count != 0) { throw FicheErrors.Error(FicheErrors.Refused, "L’objet contient au moins un enfant : suppression non récursive uniquement, rien n’a été envoyé."); }
    }

    private protected override async Task<WriteOutcome> SendAsync(WritePlan plan, FicheEntry current, CancellationToken cancellationToken)
    {
        await Source.Connection.DeleteAsync(GuidDn(plan.Target.ObjectGuid), cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "Suppression non récursive acceptée ; vérification du GUID et nettoyage local en cours.");
    }

    private protected override async Task<WriteVerification> VerifyCurrentAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        if (current is not null) { return new(VerificationState.Mismatch, "L’objet existe encore à la relecture par GUID ; aucune association locale retirée."); }
        try
        {
            var links = await Source.ForgetDeletedAsync(plan.Target, Source.Clock.GetUtcNow(), token).ConfigureAwait(false);
            return new(VerificationState.Verified, "GUID relu absent de l’annuaire ; projections locales retirées. "
                + FrenchText.Count(links.Identified, "association retirée", "associations retirées") + "."
                + (links.Unresolved == 0 ? "" : " " + FrenchText.Count(links.Unresolved, "association historique conservée pour revue", "associations historiques conservées pour revue") + "."));
        }
        catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException)
        { return new(VerificationState.Unknown, "GUID relu absent de l’annuaire, mais nettoyage local non confirmé ; réessayez la relecture du reçu, jamais la suppression."); }
    }

    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        if (entry.Int32("adminCount") == 1 || entry.Kind is FicheKind.Container
            || session.Account.Dn is not null && FicheValues.SameDn(entry.Dn, session.Account.Dn)
            || entry.Kind == FicheKind.User && session.Account.Dn is null
            || entry.Kind == FicheKind.Computer && (entry.Int32("userAccountControl") is not { } uac || AdValues.HasFlag(uac, AdValues.ServerTrustAccount))
            || entry.Kind == FicheKind.Group && FicheMemberships.IsPrivileged(entry.Name, entry.First("objectSid"), entry.Int32("adminCount")))
        { throw FicheErrors.Error(FicheErrors.Protected, "Objet protégé, compte de session ou contrôleur du domaine : suppression refusée."); }
        if (plan?.Confirmation.TypedNameRequired == true && plan.Confirmation.TypedName != ObjectWrites.TypedName(entry))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Le nom confirmé a changé ; aucune suppression envoyée."); }
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Changes.Length != 1 || plan.Changes[0] is not { Attribute: ObjectWrites.DnAttribute, Kind: WriteChangeKind.Remove, AfterValue: null, ReferenceGuid: null }
            || !FicheValues.SameDn(plan.Target.Dn, plan.Changes[0].BeforeValue))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Plan de suppression non conforme ; rien n’a été envoyé."); }
    }
}
