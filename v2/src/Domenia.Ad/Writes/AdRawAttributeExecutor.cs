using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Raw scalar editor: schema-directed encoding and policy checked again at the native boundary.</summary>
public sealed class AdRawAttributeExecutor : AdFicheWriteExecutor, IRawAttributeExecutor
{
    private readonly object gate = new();
    private readonly Dictionary<string, (DateTimeOffset Until, FicheSecurityPolicy Policy)> policies = new(StringComparer.Ordinal);
    private readonly Func<CancellationToken, Task<FicheSecurityPolicy>> readPolicy;
    public AdRawAttributeExecutor(AdDirectorySource source) : this(source, token => AdFichePolicies.ReadAsync(source, token)) { }
    internal AdRawAttributeExecutor(AdDirectorySource source, Func<CancellationToken, Task<FicheSecurityPolicy>> policy) : base(source) => readPolicy = policy;
    public override string Kind => ObjectWrites.RawKind;

    public Task<WritePlanDraft> PlanAsync(string dn, string attribute, string? value, FicheSecurityPolicy policy, CancellationToken cancellationToken) => PrepareAsync(dn, async (entry, session) =>
    {
        Require(attribute, policy);
        Require(attribute, await readPolicy(cancellationToken).ConfigureAwait(false));
        var schema = await AdRawAttributeSchema.ReadAsync(Source.Connection, attribute.Trim(), cancellationToken).ConfigureAwait(false);
        var after = schema.Normalize(value);
        FicheEntry? reference = null;
        if (schema.IsDn && after is not null)
        {
            reference = await ReadAsync(after, cancellationToken).ConfigureAwait(false);
            after = reference.Dn;
        }
        var draft = ObjectWrites.Raw(entry, schema.Name, after, policy, session.Controller?.DnsName);
        // Validate the existing representation too: never delete a lossy decode of a binary field.
        _ = schema.Encode(draft.Changes[0].BeforeValue);
        return reference is null ? draft : draft with { Changes = [draft.Changes[0] with { ReferenceGuid = reference.ObjectGuid.ToString("D") }] };
    }, cancellationToken);

    public void Remember(string planId, DateTimeOffset expiresAt, FicheSecurityPolicy policy)
    {
        ArgumentException.ThrowIfNullOrEmpty(planId);
        ArgumentNullException.ThrowIfNull(policy);
        var now = Source.Clock.GetUtcNow();
        lock (gate)
        {
            foreach (var id in policies.Where(p => p.Value.Until <= now).Select(p => p.Key).ToArray()) { policies.Remove(id); }
            if (expiresAt <= now) { return; }
            if (policies.Count >= 64 && !policies.ContainsKey(planId)) { throw WriteErrors.Refusal(WriteErrors.Stale, "Trop de plans bruts préparés ; laissez expirer les précédents."); }
            policies[planId] = (expiresAt < now + WritePlans.Lifetime ? expiresAt : now + WritePlans.Lifetime, policy);
        }
    }

    private protected override void ValidatePlan(WritePlan plan)
    {
        base.ValidatePlan(plan);
        if (plan.Changes.Length != 1 || !plan.Confirmation.TypedNameRequired || plan.Changes[0].AfterValue is { Length: > 4096 }
            || plan.Changes[0].Kind is not (WriteChangeKind.Add or WriteChangeKind.Replace or WriteChangeKind.Clear))
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Un seul attribut brut et une confirmation nominative sont requis."); }
    }

    private protected override async Task ValidateCurrentAsync(WritePlan plan, FicheEntry? current, SessionSnapshot session, CancellationToken token)
    {
        var change = plan.Changes[0];
        FicheSecurityPolicy remembered;
        lock (gate)
        {
            if (!policies.TryGetValue(plan.Id, out var kept) || kept.Until <= Source.Clock.GetUtcNow())
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Politique du plan absente ou expirée ; préparez de nouveau l’écriture brute."); }
            remembered = kept.Policy;
        }
        Require(change.Attribute, remembered);
        Require(change.Attribute, await readPolicy(token).ConfigureAwait(false));
        var schema = await AdRawAttributeSchema.ReadAsync(Source.Connection, change.Attribute, token).ConfigureAwait(false);
        if (schema.IsDn && change.AfterValue is not null && change.ReferenceGuid is null || !schema.IsDn && change.ReferenceGuid is not null)
        { throw WriteErrors.Refusal(WriteErrors.PlanChanged, "Référence de l’attribut incompatible avec son schéma."); }
        _ = schema.Encode(change.BeforeValue);
        _ = schema.Encode(change.AfterValue);
        if (current is not null && plan.Confirmation.TypedName != ObjectWrites.TypedName(current))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Le nom de confirmation a changé ; préparez de nouveau le plan."); }
    }

    private protected override async Task<IReadOnlyList<AdModification>> ModificationsAsync(WritePlan plan, FicheEntry current, CancellationToken token)
    {
        var change = plan.Changes[0];
        var schema = await AdRawAttributeSchema.ReadAsync(Source.Connection, change.Attribute, token).ConfigureAwait(false);
        var changes = new List<AdModification>();
        if (schema.Encode(current.First(change.Attribute)) is { } before) { changes.Add(new(change.Attribute, AdModificationKind.Delete, [before])); }
        if (schema.Encode(change.AfterValue) is { } after) { changes.Add(new(change.Attribute, AdModificationKind.Add, [change.ReferenceGuid is { } id ? GuidDn(id) : after])); }
        return changes;
    }

    private static void Require(string attribute, FicheSecurityPolicy policy)
    {
        var decision = FicheAttributeRules.RawWriteAllowed(attribute, policy);
        if (!decision.Allowed) { throw FicheErrors.Error(FicheErrors.Refused, decision.Reason + " Rien n’a été envoyé."); }
    }
}

internal static class AdFichePolicies
{
    internal static async Task<FicheSecurityPolicy> ReadAsync(AdDirectorySource source, CancellationToken token) =>
        source.AccountContext?.Readers.Find<IFicheSettingsReader>() is { } reader
            ? FicheSecurityPolicy.From(await reader.ReadAsync(token).ConfigureAwait(false), AppMode.Directory) : FicheSecurityPolicy.Default;
}

internal sealed record AdRawAttributeSchema(string Name, string Syntax, int OmSyntax, long? Upper)
{
    internal bool IsDn => Syntax == "2.5.5.1";
    internal static async Task<AdRawAttributeSchema> ReadAsync(IAdConnection connection, string attribute, CancellationToken token)
    {
        if (!FicheAttributeRules.IsValidName(attribute) || FicheAttributeRules.IsSensitive(attribute)) { throw Invalid(); }
        var root = await connection.RootDseAsync(token).ConfigureAwait(false);
        if (!AdSchemaReader.ValidContext(root.SchemaNamingContext)) { throw AdAttributeRange.Incomplete(); }
        var rows = await connection.SearchAsync(new(root.SchemaNamingContext, "(&(objectClass=attributeSchema)(lDAPDisplayName=" + attribute + "))", AdSearchScope.OneLevel,
            ["lDAPDisplayName", "attributeSyntax", "oMSyntax", "systemOnly", "systemFlags", "linkID", "isDefunct", "rangeUpper"])
        { SizeLimit = 2, PageSize = 1, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, token).ConfigureAwait(false);
        if (rows.Count != 1 || !FicheValues.SameDn(DistinguishedName.Parent(rows[0].DistinguishedName), root.SchemaNamingContext)
            || !string.Equals(rows[0].String("lDAPDisplayName"), attribute, StringComparison.OrdinalIgnoreCase)) { throw Invalid(); }
        return From(rows[0]);
    }

    internal static AdRawAttributeSchema From(AdEntry row)
    {
        var syntax = row.String("attributeSyntax"); var om = row.Int("oMSyntax");
        if (!FicheAttributeRules.IsValidName(row.String("lDAPDisplayName"))
            || row.String("systemOnly") is { } system && !system.Equals("FALSE", StringComparison.OrdinalIgnoreCase)
            || row.String("isDefunct") is { } defunct && !defunct.Equals("FALSE", StringComparison.OrdinalIgnoreCase)
            || row.String("systemFlags") is not null && row.Long("systemFlags") is null
            || row.String("linkID") is not null && row.Long("linkID") is null
            || ((row.Long("systemFlags") ?? 0) & 4) != 0 || ((row.Long("linkID") ?? 0) & 1) != 0
            || (syntax, om) is not (("2.5.5.1", 127) or ("2.5.5.2", 6) or ("2.5.5.3", 27) or ("2.5.5.4", 20)
                or ("2.5.5.5", 19 or 22) or ("2.5.5.6", 18) or ("2.5.5.8", 1) or ("2.5.5.9", 2 or 10)
                or ("2.5.5.10", 4) or ("2.5.5.11", 23 or 24) or ("2.5.5.12", 64) or ("2.5.5.16", 65))) { throw Invalid(); }
        var upper = row.Long("rangeUpper");
        if (row.String("rangeUpper") is not null && (upper is null or < 0)) { throw Invalid(); }
        return new(row.String("lDAPDisplayName")!, syntax!, om.Value, upper);
    }

    internal string? Normalize(string? value)
    {
        if (string.IsNullOrEmpty(value)) { return null; }
        if (value.Length > 4096 || value.Contains('\0', StringComparison.Ordinal)) { throw Invalid(); }
        if (Syntax == "2.5.5.10")
        {
            try
            {
                var bytes = Convert.FromHexString(value);
                if (Upper is { } max && bytes.LongLength > max) { throw Invalid(); }
                return Convert.ToHexString(bytes);
            }
            catch (FormatException) { throw Invalid(); }
        }
        if (Upper is { } limit && Syntax is not ("2.5.5.9" or "2.5.5.16") && value.Length > limit) { throw Invalid(); }
        if (Syntax == "2.5.5.8") { return bool.TryParse(value, out var boolean) ? boolean ? "TRUE" : "FALSE" : throw Invalid(); }
        if (Syntax == "2.5.5.9") { return int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number) ? number.ToString(CultureInfo.InvariantCulture) : throw Invalid(); }
        if (Syntax == "2.5.5.16") { return long.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number) ? number.ToString(CultureInfo.InvariantCulture) : throw Invalid(); }
        if (IsDn) { AdFicheObjects.ValidateDn(value); }
        return value;
    }

    internal object? Encode(string? value)
    {
        var normalized = Normalize(value);
        return normalized is null ? null : Syntax == "2.5.5.10" ? Convert.FromHexString(normalized) : normalized;
    }
    private static DomeniaOperationException Invalid() => FicheErrors.Error(FicheErrors.Refused,
        "Attribut ou valeur non admis par le schéma pour cet éditeur : syntaxe simple requise, aucun champ système, calculé ou lien retour. Les octets s’écrivent en hexadécimal complet.");
}
