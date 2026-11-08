namespace Domenia.Core;

public sealed partial class WriteCircuit
{
    private const int DenialCapacity = 256;
    private static readonly TimeSpan DenialLifetime = TimeSpan.FromMinutes(5);
    private readonly Dictionary<(WritePlanOrigin Owner, string Guid, string Capability), DateTimeOffset> deniedCapabilities = new();
    private const string DenialText = "Le contrôleur a refusé cette action sur cet objet avec ce compte. Attendez cinq minutes ou changez explicitement de compte avant de préparer un nouveau plan.";

    private static string Capability(string kind, IEnumerable<WriteChange>? changes = null) => kind switch
    {
        ObjectWrites.UpdateKind or ObjectWrites.RawKind => kind + ":" + string.Join(",", (changes ?? []).Select(c => c.Attribute.ToLowerInvariant()).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)),
        AccountActivation.EnableKind or AccountActivation.DisableKind or ObjectWrites.EnabledKind => "account.activation",
        AccountPasswordReset.Kind or ObjectWrites.ResetPasswordKind => "account.passwordReset",
        AccountMustChangePassword.Kind or ObjectWrites.ExpirePasswordKind => "account.passwordExpire",
        _ => kind,
    };
    private void AlignDenialsLocked()
    {
        var now = clock.GetUtcNow();
        foreach (var key in deniedCapabilities.Where(p => now >= p.Value).Select(p => p.Key).ToArray()) deniedCapabilities.Remove(key);
    }
    private void RequireCapability(SessionSnapshot owner, string kind, WriteTarget target, IEnumerable<WriteChange> changes)
    {
        if (writers.ForKind(kind) is not IDirectoryMutationExecutor) return;
        // Draft validation remains owned by WritePlans.Seal; do not turn a malformed draft into an unexpected exception here.
        if (!Guid.TryParse(target.ObjectGuid, out var id) || id == Guid.Empty || changes.Any(c => string.IsNullOrEmpty(c.Attribute))) return;
        lock (gate)
        {
            AlignDenialsLocked();
            if (deniedCapabilities.ContainsKey((WritePlanOrigin.From(owner), id.ToString("D"), Capability(kind, changes))))
                throw WriteErrors.Refusal("write.capabilityDenied", DenialText);
        }
    }
    private void RememberCapabilityRefusal(SessionSnapshot owner, WritePlan plan, IWriteExecutor executor, DomeniaOperationException error)
    {
        // Only an actual controller permission denial on a directory mutation. Never an ACL estimate, timeout, local file error or credential failure.
        if (executor is not IDirectoryMutationExecutor || error.Code != "ad.accessDenied") return;
        lock (gate)
        {
            AlignDenialsLocked();
            deniedCapabilities[(WritePlanOrigin.From(owner), Guid.Parse(plan.Target.ObjectGuid).ToString("D"), Capability(plan.Kind, plan.Changes))] = clock.GetUtcNow() + DenialLifetime;
            while (deniedCapabilities.Count > DenialCapacity) deniedCapabilities.Remove(deniedCapabilities.MinBy(p => p.Value).Key);
        }
    }
    public IReadOnlyDictionary<string, string> RefusedActions(SessionSnapshot owner, Guid objectGuid)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        lock (gate)
        {
            AlignDenialsLocked();
            foreach (var (action, kind) in new (string, string)[]
            {
                ("unlock", AccountUnlock.Kind), ("enable", ObjectWrites.EnabledKind), ("disable", ObjectWrites.EnabledKind),
                ("resetPassword", ObjectWrites.ResetPasswordKind), ("expirePassword", ObjectWrites.ExpirePasswordKind),
                ("expiration", ObjectWrites.ExpirationKind), ("options", ObjectWrites.OptionsKind),
                ("move", ObjectWrites.MoveKind), ("delete", ObjectWrites.DeleteKind), ("groupAdd", ObjectWrites.MemberKind),
            })
                if (deniedCapabilities.ContainsKey((WritePlanOrigin.From(owner), objectGuid.ToString("D"), Capability(kind)))) result[action] = DenialText;
        }
        return result;
    }
}
