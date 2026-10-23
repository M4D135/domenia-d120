using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Plain fiche changes: fresh attributes, sealed referenced identities, same connection and one atomic Modify.</summary>
public abstract class AdFicheWriteExecutor(AdDirectorySource source) : IWriteExecutor
{
    private protected AdDirectorySource Source { get; } = source;
    public abstract string Kind { get; }
    private protected virtual bool PasswordStamp => false;
    private protected virtual bool ScalarChanges => true;
    private protected virtual bool StoreReadBack => true;

    private protected async Task<WritePlanDraft> PrepareAsync(string dn,
        Func<FicheEntry, SessionSnapshot, Task<WritePlanDraft>> prepare, CancellationToken token)
    {
        AdFicheObjects.ValidateDn(dn);
        _ = await Source.DomainAsync(token).ConfigureAwait(false);
        var session = await Source.GetSessionAsync(token).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        var entry = await ReadAsync(dn, token).ConfigureAwait(false);
        Protect(entry, session, null);
        var draft = await prepare(entry, session).ConfigureAwait(false);
        foreach (var change in draft.Changes)
        {
            if (ScalarChanges && entry.All(change.Attribute).Length > 1)
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Un champ comporte plusieurs valeurs ; aucune valeur existante ne sera écrasée."); }
        }
        return draft with { Origin = WritePlanOrigin.From(session) };
    }

    private protected Task<FicheEntry> ReadAsync(string dn, CancellationToken token) => ReadCoreAsync(dn, token);
    private async Task<FicheEntry> ReadCoreAsync(string dn, CancellationToken token) =>
        (await new AdFicheObjects(Source).ReadAsync(dn, token).ConfigureAwait(false)).Entry;

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePlan(plan);
        var session = await Source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        EnsureController(plan);
        var current = await ReadTargetAsync(plan, cancellationToken).ConfigureAwait(false);
        return await CheckCurrentAsync(plan, current, session, cancellationToken).ConfigureAwait(false);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePlan(plan);
        var session = await Source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        EnsureController(plan);
        var current = await ReadTargetAsync(plan, cancellationToken).ConfigureAwait(false);
        var check = await CheckCurrentAsync(plan, current, session, cancellationToken).ConfigureAwait(false);
        if (!check.Current) { throw WriteErrors.Refusal(WriteErrors.Stale, check.Detail); }
        if (ObjectWrites.AlreadyApplied(plan, current, _ => false))
        { return new(WriteResult.NoChange, "État déjà conforme au plan ; aucune requête de modification envoyée."); }
        return await SendAsync(plan, current!, cancellationToken).ConfigureAwait(false);
    }

    private protected virtual async Task<WriteOutcome> SendAsync(WritePlan plan, FicheEntry current, CancellationToken cancellationToken)
    {
        var changes = await ModificationsAsync(plan, current, cancellationToken).ConfigureAwait(false);
        await Source.Connection.ModifyAsync(GuidDn(plan.Target.ObjectGuid), changes, cancellationToken).ConfigureAwait(false);
        return new(WriteResult.Applied, "Champs acceptés par le contrôleur dans une seule requête ; relecture en cours.");
    }

    private protected virtual Task<IReadOnlyList<AdModification>> ModificationsAsync(WritePlan plan, FicheEntry current, CancellationToken token)
    {
        var changes = new List<AdModification>();
        foreach (var change in plan.Changes)
        {
            var before = current!.First(change.Attribute);
            if (string.Equals(before ?? "", change.AfterValue ?? "", StringComparison.Ordinal)) { continue; }
            if (PasswordStamp)
            { changes.Add(new(change.Attribute, AdModificationKind.Replace, ["0"])); continue; }
            if (before is not null)
            { changes.Add(new(change.Attribute, AdModificationKind.Delete, [before])); }
            if (change.AfterValue is not null)
            { changes.Add(new(change.Attribute, AdModificationKind.Add, [change.ReferenceGuid is { } id ? GuidDn(id) : change.AfterValue])); }
        }
        return Task.FromResult<IReadOnlyList<AdModification>>(changes);
    }

    public virtual async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ValidatePlan(plan);
        _ = await Source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var session = await Source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        using var lease = Source.AcquireWriteLease(session);
        EnsureController(plan);
        var current = await ReadTargetAsync(plan, cancellationToken).ConfigureAwait(false);
        var dependencies = await ReferencesAsync(plan, cancellationToken).ConfigureAwait(false);
        if (!dependencies) { return new(VerificationState.Mismatch, "Un objet référencé par le plan a disparu ou changé d’identité."); }
        var read = await VerifyCurrentAsync(plan, current, cancellationToken).ConfigureAwait(false);
        if (current is not null && PasswordStamp && current.Int32("userAccountControl") is { } flags && AdValues.HasFlag(flags, AdValues.DontExpirePassword))
        { return new(VerificationState.Mismatch, "pwdLastSet relu, mais le mot de passe n’expire jamais ; le changement imposé reste sans effet."); }
        if (StoreReadBack && current is not null && Source.LocalStore is IFicheCache cache)
        {
            try { await cache.SaveFicheAsync(new(current, Source.Clock.GetUtcNow()), cancellationToken).ConfigureAwait(false); }
            catch (Exception ex) when (ex is System.IO.IOException or UnauthorizedAccessException)
            { return read with { Detail = read.Detail + " Cette relecture n’a pas pu être enregistrée dans la base locale." }; }
        }
        return read;
    }

    private protected virtual async Task<FicheEntry?> ReadTargetAsync(WritePlan plan, CancellationToken token)
    {
        var domain = await Source.DomainAsync(token).ConfigureAwait(false);
        var id = Guid.ParseExact(plan.Target.ObjectGuid, "D");
        var rows = await Source.Connection.SearchAsync(new(domain.RootDn, AdObjectAccess.GuidFilter(id), AdSearchScope.Subtree, ["objectGUID"])
        { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(10), Budget = TimeSpan.FromSeconds(10) }, token).ConfigureAwait(false);
        if (rows.Count == 0) { return null; }
        if (rows.Count != 1 || rows[0].Guid("objectGUID") != id) { throw AdAttributeRange.Incomplete(); }
        var entry = await ReadAsync(rows[0].DistinguishedName, token).ConfigureAwait(false);
        if (entry.ObjectGuid != id) { throw AdAttributeRange.Incomplete(); }
        return entry;
    }

    private async Task<WritePrecheck> CheckCurrentAsync(WritePlan plan, FicheEntry? current, SessionSnapshot session, CancellationToken token)
    {
        if (!string.Equals(plan.Operator, session.Account.Login, StringComparison.OrdinalIgnoreCase))
        { return WritePrecheck.Stale("Compte opérateur différent ; aucune modification envoyée."); }
        if (current is not null)
        {
            Protect(current, session, plan);
            foreach (var change in plan.Changes)
            {
                if (ScalarChanges && current.All(change.Attribute).Length > 1) { return WritePrecheck.Stale("Un champ possède désormais plusieurs valeurs ; rien n’a été envoyé."); }
            }
        }
        if (!await ReferencesAsync(plan, token).ConfigureAwait(false))
        { return WritePrecheck.Stale("Objet référencé remplacé, déplacé ou absent ; préparez un nouveau plan."); }
        await ValidateCurrentAsync(plan, current, session, token).ConfigureAwait(false);
        return await CheckRulesAsync(plan, current, token).ConfigureAwait(false);
    }

    private async Task<bool> ReferencesAsync(WritePlan plan, CancellationToken token)
    {
        foreach (var change in plan.Changes.Where(c => c.ReferenceGuid is not null))
        {
            var dn = change.AfterValue ?? change.BeforeValue;
            if (dn is null) { return false; }
            var reference = await new AdFicheObjects(Source).ReadExactAsync(dn, ["objectGUID"], TimeSpan.FromSeconds(10), token).ConfigureAwait(false);
            if (reference?.Guid("objectGUID")?.ToString("D") != change.ReferenceGuid) { return false; }
        }
        return true;
    }

    private protected virtual Task<WritePrecheck> CheckRulesAsync(WritePlan plan, FicheEntry? current, CancellationToken token) => Task.FromResult(ObjectWrites.Check(plan, current, _ => false));
    private protected virtual Task<WriteVerification> VerifyCurrentAsync(WritePlan plan, FicheEntry? current, CancellationToken token) => Task.FromResult(ObjectWrites.Verify(plan, current, _ => false));

    private protected virtual Task ValidateCurrentAsync(WritePlan plan, FicheEntry? current, SessionSnapshot session, CancellationToken token) => Task.CompletedTask;

    private protected virtual string ConfirmationName(FicheEntry entry) => ObjectWrites.TypedName(entry);

    private protected virtual void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        if (entry.First("objectSid") is { } sid && sid.EndsWith("-502", StringComparison.Ordinal)
            || string.Equals(entry.First("isCriticalSystemObject"), "TRUE", StringComparison.OrdinalIgnoreCase))
        { throw FicheErrors.Error(FicheErrors.Protected, "Objet système protégé ; aucune écriture depuis cette fiche."); }
        if (entry.All("objectClass").Any(c => c.Equals("msDS-ManagedServiceAccount", StringComparison.OrdinalIgnoreCase)
            || c.Equals("msDS-GroupManagedServiceAccount", StringComparison.OrdinalIgnoreCase)))
        { throw FicheErrors.Error(FicheErrors.Protected, "Compte de service géré ; cette modification n’est pas proposée."); }
        if (plan is not null && entry.Int32("adminCount") == 1
            && (!plan.Confirmation.TypedNameRequired || plan.Confirmation.TypedName != ConfirmationName(entry)))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Protection ou nom du compte modifié ; confirmation à préparer de nouveau."); }
    }

    private protected virtual void ValidatePlan(WritePlan plan)
    {
        if (plan.Kind != Kind || plan.Mode != AppInfoBuilder.DirectoryModeText || plan.Simulated || !WritePlans.IsIntact(plan)
            || !Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var id) || id == Guid.Empty || plan.Changes.IsDefaultOrEmpty
            || plan.Changes.Any(c => !FicheAttributeRules.IsValidName(c.Attribute) || FicheAttributeRules.IsSensitive(c.Attribute)
                || c.ReferenceGuid is { } reference && (!Guid.TryParseExact(reference, "D", out var guid) || guid == Guid.Empty)))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Plan de fiche non conforme ; rien n’a été envoyé."); }
    }
    private void EnsureController(WritePlan plan)
    {
        if (plan.Controller is null || !string.Equals(plan.Controller, Source.ControllerName, StringComparison.OrdinalIgnoreCase))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Contrôleur différent du plan ; rien n’a été envoyé."); }
    }
    private protected static string GuidDn(string guid) => "<GUID=" + Guid.ParseExact(guid, "D").ToString("D") + ">";
}

public sealed class AdObjectUpdateExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source), IObjectUpdateExecutor
{
    public override string Kind => ObjectWrites.UpdateKind;
    public Task<WritePlanDraft> PlanAsync(string dn, IReadOnlyDictionary<string, string?> fields, CancellationToken cancellationToken) => PrepareAsync(dn, async (entry, session) =>
    {
        var names = new Dictionary<string, FicheSummary>(StringComparer.OrdinalIgnoreCase);
        var normalized = new Dictionary<string, string?>(fields, StringComparer.OrdinalIgnoreCase);
        foreach (var field in fields.Where(f => f.Key.Equals("manager", StringComparison.OrdinalIgnoreCase) || f.Key.Equals("managedBy", StringComparison.OrdinalIgnoreCase)))
        {
            if (!string.IsNullOrWhiteSpace(field.Value))
            {
                var referenced = await ReadAsync(field.Value.Trim(), cancellationToken).ConfigureAwait(false);
                names[referenced.Dn] = FicheSummary.From(referenced, Source.Clock.GetUtcNow());
                normalized[field.Key] = referenced.Dn;
            }
        }
        var draft = ObjectWrites.Update(entry, normalized, names, session.Controller?.DnsName);
        return draft with { Changes = [.. draft.Changes.Select(c => c.Attribute is "manager" or "managedBy" && c.AfterValue is { } value
            ? c with { ReferenceGuid = names[value].ObjectGuid.ToString("D") } : c)] };
    }, cancellationToken);
    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        var kind = plan.Target.Kind switch { "user" => FicheKind.User, "computer" => FicheKind.Computer, "group" => FicheKind.Group, "ou" => FicheKind.Ou, "contact" => FicheKind.Contact, _ => FicheKind.Container };
        var allowed = FicheSheets.EditableAttributes(kind);
        if (plan.Changes.Any(c => !allowed.ContainsKey(c.Attribute) || c.AfterValue is { } value && value.Length > allowed[c.Attribute]
            || c.Attribute is "manager" or "managedBy" && c.AfterValue is not null && c.ReferenceGuid is null))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Champ ou référence non admis par ce plan."); }
    }
}

public sealed class AdAccountEnabledExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source), IAccountEnabledExecutor
{
    public override string Kind => ObjectWrites.EnabledKind;
    public Task<WritePlanDraft> PlanAsync(string dn, bool enabled, CancellationToken cancellationToken) => PrepareAsync(dn, (entry, session) =>
    {
        if (!enabled && (session.Account.Dn is null || FicheValues.SameDn(entry.Dn, session.Account.Dn)))
        { throw FicheErrors.Error(FicheErrors.Protected, "Le compte de session ne peut pas être désactivé."); }
        return Task.FromResult(ObjectWrites.Enabled(entry, enabled, session.Controller?.DnsName));
    }, cancellationToken);
    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        if (entry.Int32("userAccountControl") is not { } uac) { throw AdAttributeRange.Incomplete(); }
        if (plan is not null && int.TryParse(plan.Changes[0].AfterValue, NumberStyles.None, CultureInfo.InvariantCulture, out var after) && AdValues.IsDisabled(after)
            && (entry.Int32("adminCount") == 1 || AdValues.HasFlag(uac, AdValues.ServerTrustAccount) || session.Account.Dn is null || FicheValues.SameDn(entry.Dn, session.Account.Dn)))
        { throw FicheErrors.Error(FicheErrors.Protected, "Compte protégé devenu non désactivable ; rien n’a été envoyé."); }
    }
    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Changes.Length != 1 || plan.Changes[0].Attribute != "userAccountControl"
            || !int.TryParse(plan.Changes[0].BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out var before)
            || !int.TryParse(plan.Changes[0].AfterValue, NumberStyles.None, CultureInfo.InvariantCulture, out var after) || (before ^ after) != AdValues.AccountDisabled)
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Seul le bit de désactivation peut changer."); }
    }
}

public sealed class AdPasswordExpireExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source), IPasswordExpireExecutor
{
    public override string Kind => ObjectWrites.ExpirePasswordKind;
    private protected override bool PasswordStamp => true;
    public Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken) => PrepareAsync(dn,
        (entry, session) => Task.FromResult(ObjectWrites.ExpirePassword(entry, session.Controller?.DnsName, Source.Zone)), cancellationToken);
    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        if (entry.Int64("pwdLastSet") is null || entry.Int32("userAccountControl") is null) { throw AdAttributeRange.Incomplete(); }
    }
    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Changes.Length != 1 || plan.Changes[0] is not { Attribute: "pwdLastSet", AfterValue: "0" })
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Seul pwdLastSet peut être remis à zéro."); }
    }
}

public sealed class AdAccountOptionsExecutor(AdDirectorySource source) : AdFicheWriteExecutor(source), IAccountOptionsExecutor
{
    public override string Kind => ObjectWrites.OptionsKind;
    public Task<WritePlanDraft> PlanAsync(string dn, IReadOnlyDictionary<string, bool> options, FicheSecurityPolicy policy, CancellationToken cancellationToken) => PrepareAsync(dn,
        (entry, session) => Task.FromResult(ObjectWrites.Options(entry, options, policy, session.Controller?.DnsName)), cancellationToken);
    private protected override void Protect(FicheEntry entry, SessionSnapshot session, WritePlan? plan)
    {
        base.Protect(entry, session, plan);
        if (entry.Kind != FicheKind.User || entry.Int32("userAccountControl") is null) { throw AdAttributeRange.Incomplete(); }
    }
    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        var mask = FicheSheets.OptionFlags.Aggregate(0, (bits, option) => bits | option.Flag);
        if (plan.Changes.Length != 1 || plan.Changes[0].Attribute != "userAccountControl"
            || !int.TryParse(plan.Changes[0].BeforeValue, NumberStyles.None, CultureInfo.InvariantCulture, out var before)
            || !int.TryParse(plan.Changes[0].AfterValue, NumberStyles.None, CultureInfo.InvariantCulture, out var after) || ((before ^ after) & ~mask) != 0)
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Option de compte non admise dans ce plan."); }
    }
}
