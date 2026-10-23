using System.Globalization;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Ad;

/// <summary>Native workstation-directory writes share the same session, identity, CAS and readback boundary as Fiche.</summary>
public abstract class AdPosteDirectoryExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source)
{
    private protected Task<WritePlanDraft> PrepareComputerAsync(string dn, Func<DirectoryComputer, SessionSnapshot, Task<WritePlanDraft>> prepare, CancellationToken token) =>
        PrepareAsync(dn, async (entry, session) =>
        {
            var computer = Computer(entry);
            var draft = await prepare(computer, session).ConfigureAwait(false);
            return entry.Int32("adminCount") == 1 ? draft with
            { Confirmation = new(true, PosteDirectoryWrites.TypedName(computer), "Saisie du nom exigée : compte ordinateur protégé.") } : draft;
        }, token);

    private protected override string ConfirmationName(FicheEntry entry) => PosteDirectoryWrites.TypedName(Computer(entry));

    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        var computer = Computer(entry);
        if (AdValues.HasFlag(computer.UserAccountControl, AdValues.ServerTrustAccount))
        { throw FicheErrors.Error(FicheErrors.Protected, "Contrôleur de domaine : cette écriture de poste est refusée."); }
        if (plan?.Confirmation.TypedNameRequired == true && plan.Confirmation.TypedName != PosteDirectoryWrites.TypedName(computer))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Le nom de compte confirmé a changé ; préparez un nouveau plan."); }
    }

    private protected override async Task<WriteVerification> VerifyCurrentAsync(WritePlan plan, FicheEntry? current, CancellationToken token)
    {
        var read = await base.VerifyCurrentAsync(plan, current, token).ConfigureAwait(false);
        if (current is not null)
        {
            var computer = Computer(current);
            var domain = await Source.DomainAsync(token).ConfigureAwait(false);
            try { await Source.RememberObjectsAsync(new(domain, Source.Clock.GetUtcNow(), false, [], [], [computer], []), Source.Epoch, token).ConfigureAwait(false); }
            catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException)
            { return read with { Detail = read.Detail + " L’index local du poste n’a pas pu être actualisé." }; }
        }
        return read;
    }

    private protected static DirectoryComputer Computer(FicheEntry entry)
    {
        if (entry.Kind != FicheKind.Computer || entry.Int32("userAccountControl") is null || string.IsNullOrWhiteSpace(entry.First("sAMAccountName"))
            || entry.First("objectSid") is not { } sidText)
        { throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Identité ou état du compte ordinateur illisible ; aucun plan préparé."); }
        byte[] sid;
        try { var value = new SecurityIdentifier(sidText); sid = new byte[value.BinaryLength]; value.GetBinaryForm(sid, 0); }
        catch (ArgumentException) { throw AdAttributeRange.Incomplete(); }
        var fields = entry.Attributes.Where(p => !p.Key.StartsWith("__", StringComparison.Ordinal))
            .ToDictionary(p => p.Key, p => (IReadOnlyList<object>)p.Value.Cast<object>().ToArray(), StringComparer.OrdinalIgnoreCase);
        fields["objectGUID"] = [entry.ObjectGuid.ToByteArray()]; fields["objectSid"] = [sid];
        return AdDirectoryMapper.Computer(new(entry.Dn, fields)) ?? throw AdAttributeRange.Incomplete();
    }
}

public sealed class AdPosteAccountStateExecutor(AdDirectorySource source) : AdPosteDirectoryExecutor(source), IPosteAccountStateExecutor
{
    public override string Kind => PosteDirectoryWrites.AccountStateKind;
    public Task<WritePlanDraft> PlanAsync(string dn, bool enable, CancellationToken cancellationToken) => PrepareComputerAsync(dn, (computer, session) =>
    {
        if (!enable && session.Account.Dn is not null && FicheValues.SameDn(computer.DistinguishedName, session.Account.Dn))
        { throw FicheErrors.Error(FicheErrors.Protected, "Le compte de session ne peut pas être désactivé."); }
        return Task.FromResult(PosteDirectoryWrites.AccountState(computer, enable, session.Controller?.DnsName));
    }, cancellationToken);

    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        if (plan is not null && int.TryParse(plan.Changes[0].AfterValue, NumberStyles.None, CultureInfo.InvariantCulture, out var after)
            && AdValues.IsDisabled(after) && session.Account.Dn is not null && FicheValues.SameDn(entry.Dn, session.Account.Dn))
        { throw FicheErrors.Error(FicheErrors.Protected, "Le compte de session ne peut pas être désactivé."); }
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Target.Kind != "computer" || plan.Changes.Length != 1 || plan.Changes[0].Attribute != "userAccountControl"
            || !int.TryParse(plan.Changes[0].BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out var before)
            || !int.TryParse(plan.Changes[0].AfterValue, NumberStyles.None, CultureInfo.InvariantCulture, out var after) || (before ^ after) != AdValues.AccountDisabled)
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Seul le bit de désactivation du poste peut changer."); }
    }
}

public sealed class AdPosteProfileExecutor(AdDirectorySource source) : AdPosteDirectoryExecutor(source), IPosteProfileExecutor
{
    public override string Kind => PosteDirectoryWrites.ProfileKind;
    public Task<WritePlanDraft> PlanAsync(string dn, string? description, string? location, string? managedByDn, CancellationToken cancellationToken) =>
        PrepareComputerAsync(dn, async (computer, session) =>
        {
            FicheEntry? manager = null;
            if (!string.IsNullOrWhiteSpace(managedByDn))
            {
                manager = await ReadAsync(managedByDn.Trim(), cancellationToken).ConfigureAwait(false);
                if (manager.Kind is not (FicheKind.User or FicheKind.Group))
                { throw WriteErrors.Refusal(PosteErrors.Refused, "« Géré par » doit désigner un utilisateur ou un groupe du domaine."); }
                managedByDn = manager.Dn;
            }
            var draft = PosteDirectoryWrites.Profile(computer, description, location, managedByDn,
                manager?.First("displayName") ?? manager?.Name, session.Controller?.DnsName);
            return manager is null ? draft : draft with { Changes = [.. draft.Changes.Select(c => c.Attribute == "managedBy" && c.AfterValue is not null
                ? c with { ReferenceGuid = manager.ObjectGuid.ToString("D") } : c)] };
        }, cancellationToken);

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Target.Kind != "computer" || plan.Changes.Any(c => c.Attribute is not ("description" or "location" or "managedBy")
            || c.Kind is not (WriteChangeKind.Replace or WriteChangeKind.Clear)
            || c.Attribute is "description" or "location" && c.AfterValue is { } text && (text.Length > 1024 || text.Any(char.IsControl))
            || c.Attribute == "managedBy" && c.AfterValue is not null && c.ReferenceGuid is null))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Champ de poste ou référence non admis dans ce plan."); }
    }
}
