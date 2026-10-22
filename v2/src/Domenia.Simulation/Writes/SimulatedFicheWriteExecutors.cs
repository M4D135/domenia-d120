using System.Collections.Concurrent;
using System.Collections.Immutable;
using System.Globalization;
using System.Security;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Common part of the writes of the « Fiche » screen in simulation (docs/WRITES.md § 6): the plan reads the object as the session
/// sees it, the precondition and the postcondition are the generic rules of <see cref="ObjectWrites"/> on a fresh read by GUID,
/// and the write itself changes only the in-memory overlay of the source (or the memory of the screen for the attributes the
/// generated directory does not hold): no network, no disk, no real effect. Each step waits its own realistic delay
/// (« latency/screen/write/… »).
/// </summary>
public abstract class SimulatedFicheWriteExecutor
{
    private const string VanishedMessage = "L’objet n’existe plus dans l’annuaire fictif : rien n’a été modifié.";

    private protected SimulatedFicheWriteExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        Source = source;
    }

    private protected SimulatedDirectorySource Source { get; }

    private protected SimulatedFicheWorld World => SimulatedFicheWorld.For(Source);

    private protected string? Controller => Source.World.Session.Controller?.DnsName;

    private protected DateTimeOffset Now => Source.Clock.GetUtcNow();

    private protected Task PlanDelayAsync(CancellationToken cancellationToken) => Source.SimulateScreenLatencyAsync("write/plan", 90, 220, cancellationToken);

    /// <summary>The object at this DN as the session sees it; write.targetUnknown otherwise.</summary>
    private protected FicheEntry Read(string dn, string? message = null)
    {
        var item = World.Find(dn) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, message ?? "Ce nom distinctif ne désigne aucun objet de l’annuaire fictif : aucune écriture préparée.");
        return World.Entry(item);
    }

    private FicheEntry? ReadTarget(WritePlan plan) =>
        Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var id) && World.Find(id) is SimulatedObject item ? World.Entry(item) : null;

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("write/check", 60, 140, cancellationToken).ConfigureAwait(false);
        return ObjectWrites.Check(plan, ReadTarget(plan), World.Exists);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("write/execute", 280, 620, cancellationToken).ConfigureAwait(false);
        var current = ReadTarget(plan);
        if (ObjectWrites.AlreadyApplied(plan, current, World.Exists))
        {
            return new WriteOutcome(WriteResult.NoChange, "Objet déjà dans l’état demandé : aucune écriture.");
        }
        if (current is null || !Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var id))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, VanishedMessage);
        }
        if (!Apply(plan, current, id))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, VanishedMessage);
        }
        return new WriteOutcome(WriteResult.Applied, Describe(plan) + " dans l’annuaire fictif (en mémoire, aucun effet réel)" + (Controller is null ? "." : ", comme le ferait " + Controller + "."));
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await Source.SimulateScreenLatencyAsync("write/verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return ObjectWrites.Verify(plan, ReadTarget(plan), World.Exists);
    }

    /// <summary>Sends the write of the plan to the overlay; false when the object vanished.</summary>
    private protected abstract bool Apply(WritePlan plan, FicheEntry current, Guid id);

    /// <summary>What was done, for the receipt (« 3 champs écrits »).</summary>
    private protected virtual string Describe(WritePlan plan) =>
        plan.Changes.Length == 1 ? plan.Changes[0].Label + " écrit" : FrenchText.Count(plan.Changes.Length, "changement écrit", "changements écrits");

    private protected bool WritePlain(WritePlan plan, Guid id) => World.WriteAttributes(id, ObjectWrites.PlainChanges(plan), Now);
}

/// <summary>
/// What an executor keeps for one sealed plan until it runs or expires (policy of a raw write, password of a reset): taken once,
/// expired values dropped (and disposed when they hold a secret) at every new value.
/// </summary>
internal sealed class PlanMemory<T> where T : class
{
    private readonly ConcurrentDictionary<string, (T Value, DateTimeOffset ExpiresAt)> values = new(StringComparer.Ordinal);

    public void Keep(string planId, DateTimeOffset expiresAt, T value, DateTimeOffset now)
    {
        ArgumentException.ThrowIfNullOrEmpty(planId);
        ArgumentNullException.ThrowIfNull(value);
        foreach (var (id, kept) in values)
        {
            if (kept.ExpiresAt < now && values.TryRemove(id, out var gone))
            {
                (gone.Value as IDisposable)?.Dispose();
            }
        }
        if (values.TryRemove(planId, out var previous))
        {
            (previous.Value as IDisposable)?.Dispose();
        }
        values[planId] = (value, expiresAt);
    }

    /// <summary>The value of the plan (removed: a plan runs once), or null when none was kept or it expired.</summary>
    public T? Take(string planId, DateTimeOffset now)
    {
        if (!values.TryRemove(planId, out var kept))
        {
            return null;
        }
        if (kept.ExpiresAt < now)
        {
            (kept.Value as IDisposable)?.Dispose();
            return null;
        }
        return kept.Value;
    }
}

/// <summary>Save of the editable fields of a fiche in simulation (« object.update »).</summary>
public sealed class SimulatedObjectUpdateExecutor : SimulatedFicheWriteExecutor, IObjectUpdateExecutor
{
    public SimulatedObjectUpdateExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.UpdateKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, IReadOnlyDictionary<string, string?> fields, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(fields);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var entry = Read(dn);
        var dns = fields.Where(f => f.Key is "manager" or "managedBy").SelectMany(f => new[] { f.Value, entry.First(f.Key) }).Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v!.Trim()).ToList();
        var names = new Dictionary<string, FicheSummary>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in dns)
        {
            if (World.Find(value) is SimulatedObject item)
            {
                names[value] = World.Summary(item);
            }
        }
        return ObjectWrites.Update(entry, fields, names, Controller);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id) => WritePlain(plan, id);

    private protected override string Describe(WritePlan plan) => FrenchText.Count(plan.Changes.Length, "champ écrit", "champs écrits");
}

/// <summary>Activation or deactivation of an account in simulation (« account.enabled »).</summary>
public sealed class SimulatedAccountEnabledExecutor : SimulatedFicheWriteExecutor, IAccountEnabledExecutor
{
    public SimulatedAccountEnabledExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.EnabledKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, bool enabled, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return ObjectWrites.Enabled(Read(dn), enabled, Controller);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id) => WritePlain(plan, id);

    private protected override string Describe(WritePlan plan) => "Bit ACCOUNTDISABLE de userAccountControl écrit";
}

// « account.expiration » (FIC-016) is served by SimulatedAccountExpirationExecutor of SimulatedAccountWriteExecutors.cs (Comptes):
// a kind has a single executor (WriteExecutors.Discover), Fiche and Comptes plan it through the same contract.

/// <summary>« Expirer le mot de passe » in simulation (« password.expire »).</summary>
public sealed class SimulatedPasswordExpireExecutor : SimulatedFicheWriteExecutor, IPasswordExpireExecutor
{
    public SimulatedPasswordExpireExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.ExpirePasswordKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return ObjectWrites.ExpirePassword(Read(dn), Controller, World.Zone);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id) => WritePlain(plan, id);

    private protected override string Describe(WritePlan plan) => "pwdLastSet remis à zéro";
}

/// <summary>Security options of userAccountControl in simulation (« account.options »).</summary>
public sealed class SimulatedAccountOptionsExecutor : SimulatedFicheWriteExecutor, IAccountOptionsExecutor
{
    public SimulatedAccountOptionsExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.OptionsKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, IReadOnlyDictionary<string, bool> options, FicheSecurityPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(options);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return ObjectWrites.Options(Read(dn), options, policy, Controller);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id) => WritePlain(plan, id);

    private protected override string Describe(WritePlan plan) => "Bits changés de userAccountControl écrits";
}

/// <summary>
/// Raw attribute write in simulation (« attribute.raw »): the SE-02 rule is applied again before sending, with the policy the plan
/// was drafted with (kept by <see cref="Remember"/>); a plan without one is refused.
/// </summary>
public sealed class SimulatedRawAttributeExecutor : SimulatedFicheWriteExecutor, IRawAttributeExecutor
{
    private readonly PlanMemory<FicheSecurityPolicy> policies = new();

    public SimulatedRawAttributeExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.RawKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, string attribute, string? value, FicheSecurityPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(attribute);
        ArgumentNullException.ThrowIfNull(policy);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return ObjectWrites.Raw(Read(dn), attribute, value, policy, Controller);
    }

    public void Remember(string planId, DateTimeOffset expiresAt, FicheSecurityPolicy policy) => policies.Keep(planId, expiresAt, policy, Now);

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id)
    {
        // Double check (Domenia 1 Test-WRawAttributeAllowed): whatever the page or the plan said, the rule decides again here, with
        // the policy of the plan; without it, the strictest rule (raw writes closed) refuses.
        var policy = policies.Take(plan.Id, Now) ?? FicheSecurityPolicy.Default;
        foreach (var change in plan.Changes)
        {
            var decision = FicheAttributeRules.RawWriteAllowed(change.Attribute, policy);
            if (!decision.Allowed)
            {
                throw FicheErrors.Error(FicheErrors.Refused, decision.Reason + " Rien n’a été envoyé.");
            }
        }
        return WritePlain(plan, id);
    }
}

/// <summary>Move of an object in simulation (« object.move »).</summary>
public sealed class SimulatedObjectMoveExecutor : SimulatedFicheWriteExecutor, IObjectMoveExecutor
{
    public SimulatedObjectMoveExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.MoveKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, string targetDn, Guid? expectedGuid, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(targetDn);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var entry = Read(dn);
        if (expectedGuid is Guid expected && entry.ObjectGuid != expected)
        {
            throw FicheErrors.Error(FicheErrors.Refused, "L’objet a changé pendant le choix de l’OU" + FrenchText.Colon + "ce DN désigne maintenant un autre objet (GUID différent). Relisez la fiche. Aucune écriture préparée.");
        }
        var destination = World.Find(targetDn) ?? throw FicheErrors.Error(FicheErrors.Invalid, "OU de destination introuvable : aucune écriture préparée.");
        var rdn = entry.Kind == FicheKind.Contact || entry.Kind == FicheKind.User ? entry.First("cn") ?? entry.Name : entry.Name;
        var taken = World.Exists(DistinguishedName.Child("CN", rdn, destination.Dn));
        return ObjectWrites.Move(entry, World.Summary(destination), World.Directory.Domain.RootDn, taken, Controller);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id)
    {
        var destination = plan.Changes.First(c => c.Kind == WriteChangeKind.Move).AfterValue ?? throw new InvalidOperationException("A move plan has a destination.");
        return World.WriteMove(id, destination, Now);
    }

    private protected override string Describe(WritePlan plan) => "Objet déplacé (GUID inchangé)";
}

/// <summary>One membership change in simulation (« group.member »): member and memberOf both follow.</summary>
public sealed class SimulatedGroupMemberExecutor : SimulatedFicheWriteExecutor, IGroupMemberExecutor
{
    public SimulatedGroupMemberExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.MemberKind;

    public async Task<WritePlanDraft> PlanAsync(string groupDn, string memberDn, bool add, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(groupDn);
        ArgumentNullException.ThrowIfNull(memberDn);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var group = Read(groupDn, "Ce nom distinctif ne désigne aucun groupe de l’annuaire fictif : aucune écriture préparée.");
        var member = World.Find(memberDn) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, "Le membre désigné n’existe pas dans l’annuaire fictif : aucune écriture préparée.");
        return ObjectWrites.Member(group, World.Summary(member), add, World.Directory.Domain.RootDn, Controller);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id)
    {
        var change = plan.Changes.First(c => c.Attribute == ObjectWrites.MemberAttribute);
        var add = change.Kind == WriteChangeKind.Add;
        var dn = (add ? change.AfterValue : change.BeforeValue) ?? throw new InvalidOperationException("A membership plan names its member.");
        return World.WriteMember(id, dn, add, Now);
    }

    private protected override string Describe(WritePlan plan) => plan.Changes[0].Kind == WriteChangeKind.Add ? "Membre ajouté (member et memberOf)" : "Membre retiré (member et memberOf)";
}

/// <summary>
/// Deletion of an object in simulation (« object.delete »), never recursive; once the object is gone, its local associations
/// (workstations of a user, users of a workstation) are removed from the local memory (Domenia 1 Remove-LinksForDeletedObject).
/// </summary>
public sealed class SimulatedObjectDeleteExecutor : SimulatedFicheWriteExecutor, IObjectDeleteExecutor
{
    private readonly ConcurrentDictionary<string, int> unlinked = new(StringComparer.Ordinal);

    public SimulatedObjectDeleteExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.DeleteKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, FicheSecurityPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(policy);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var entry = Read(dn);
        var children = World.ChildrenOf(entry.Dn).Count();
        return ObjectWrites.Delete(entry, children, policy, Controller, World.LinkCount(entry.ObjectGuid));
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id)
    {
        if (World.ChildrenOf(current.Dn).Any())
        {
            throw FicheErrors.Error(FicheErrors.Refused, "L’objet a maintenant des enfants" + FrenchText.Colon + "suppression non récursive, rien n’a été envoyé.");
        }
        if (!World.WriteDelete(id))
        {
            return false;
        }
        // Domenia 1 Remove-LinksForDeletedObject: the local associations of a deleted object go with it.
        unlinked[plan.Id] = World.ForgetLinks(id);
        return true;
    }

    private protected override string Describe(WritePlan plan)
    {
        var count = unlinked.TryRemove(plan.Id, out var n) ? n : 0;
        return count > 0 ? "Objet supprimé, " + FrenchText.Count(count, "association locale retirée", "associations locales retirées") : "Objet supprimé";
    }
}

/// <summary>Creation of an OU in simulation (« ou.create »).</summary>
public sealed class SimulatedOuCreateExecutor : SimulatedFicheWriteExecutor, IOuCreateExecutor
{
    public SimulatedOuCreateExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.CreateOuKind;

    public async Task<WritePlanDraft> PlanAsync(string parentDn, string name, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(parentDn);
        ArgumentNullException.ThrowIfNull(name);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        var parent = Read(parentDn);
        var clean = name.Trim();
        var exists = clean.Length > 0 && World.Exists(DistinguishedName.Child("OU", clean, parent.Dn));
        return ObjectWrites.CreateOu(parent, name, exists, Controller);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id)
    {
        var child = plan.Changes.First(c => c.Attribute == ObjectWrites.OuAttribute).AfterValue ?? throw new InvalidOperationException("An OU creation plan names its OU.");
        return World.WriteCreateOu(child, Now);
    }

    private protected override string Describe(WritePlan plan) => "OU créée";
}

/// <summary>
/// Password reset in simulation (« password.reset »): the password typed or generated in the secure window of the host is held as
/// a SecureString for its plan only (<see cref="Hold"/>), taken once at the execution, used for the simulated write and disposed of
/// at once; it is never shown, never stored. A plan whose password is gone (expired, Domenia restarted) is refused, nothing sent.
/// </summary>
public sealed class SimulatedPasswordResetExecutor : SimulatedFicheWriteExecutor, IPasswordResetExecutor
{
    private static readonly string SecretGoneMessage = "Le nouveau mot de passe n’est plus en mémoire (plan expiré ou Domenia relancé)" + FrenchText.Colon + "préparez de nouveau la réinitialisation. Rien n’a été envoyé.";

    private readonly PlanMemory<SecureString> secrets = new();

    public SimulatedPasswordResetExecutor(SimulatedDirectorySource source) : base(source)
    {
    }

    public string Kind => ObjectWrites.ResetPasswordKind;

    public async Task<WritePlanDraft> PlanAsync(string dn, bool mustChange, bool unlock, bool generated, int length, FicheSecurityPolicy policy, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        ArgumentNullException.ThrowIfNull(policy);
        await PlanDelayAsync(cancellationToken).ConfigureAwait(false);
        return ObjectWrites.ResetPassword(Read(dn), mustChange, unlock, generated, length, policy, Controller);
    }

    public void Hold(string planId, DateTimeOffset expiresAt, SecureString password)
    {
        ArgumentNullException.ThrowIfNull(password);
        secrets.Keep(planId, expiresAt, password, Now);
    }

    private protected override bool Apply(WritePlan plan, FicheEntry current, Guid id)
    {
        using var password = secrets.Take(plan.Id, Now) ?? throw FicheErrors.Error(FicheErrors.Refused, SecretGoneMessage);
        var now = Now;
        var mustChange = plan.Changes.Any(c => c.Attribute == "pwdLastSet");
        var changes = new Dictionary<string, ImmutableArray<string>>(StringComparer.OrdinalIgnoreCase)
        {
            ["pwdLastSet"] = [mustChange ? "0" : AdValues.ToFileTime(now).ToString(CultureInfo.InvariantCulture)],
        };
        if (plan.Changes.Any(c => c.Attribute == "lockoutTime"))
        {
            changes["lockoutTime"] = ["0"];
        }
        // The simulated directory keeps no password: the value held for the plan only proves the secure path reached the executor.
        return password.Length > 0 && World.WriteAttributes(id, changes, now);
    }

    private protected override string Describe(WritePlan plan) => "Mot de passe réinitialisé (SecureString de la fenêtre sécurisée, ni affiché ni conservé)";
}
