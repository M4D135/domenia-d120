using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded reads of schema definitions, never object values (docs/ops/schema.md § 17.1).</summary>
public sealed class AdSchemaReader(AdDirectorySource source) : ISchemaReader
{
    private static readonly string[] AttributeFields =
    [
        "lDAPDisplayName", "adminDescription", "attributeID", "attributeSyntax", "oMSyntax", "isSingleValued",
        "searchFlags", "systemFlags", "isMemberOfPartialAttributeSet", "rangeLower", "rangeUpper", "linkID", "isDefunct",
    ];
    private static readonly string[] ClassFields =
    [
        "lDAPDisplayName", "adminDescription", "governsID", "subClassOf", "auxiliaryClass", "systemAuxiliaryClass",
        "mayContain", "systemMayContain", "mustContain", "systemMustContain", "objectClassCategory", "isDefunct",
    ];

    public async Task<SchemaReadResult> ReadDefinitionsAsync(SchemaReadLimits limits, IProgress<SchemaReadStage>? progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(limits);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(limits.MaxAttributes);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(limits.MaxAttributes, SchemaReadLimits.Default.MaxAttributes);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(limits.MaxClasses);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(limits.MaxClasses, SchemaReadLimits.Default.MaxClasses);
        if (limits.Budget <= TimeSpan.Zero || limits.Budget > SchemaReadLimits.Default.Budget)
        {
            throw new ArgumentOutOfRangeException(nameof(limits));
        }
        var started = source.Clock.GetTimestamp();
        var observedAt = source.Clock.GetUtcNow();
        using var elapsed = new CancellationTokenSource(limits.Budget, source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        progress?.Report(SchemaReadStage.Context);
        var root = await source.Connection.RootDseAsync(budget.Token).ConfigureAwait(false);
        if (!ValidContext(root.SchemaNamingContext))
        {
            throw new DomeniaOperationException(SchemaErrors.ReadFailed, "Contexte de schéma inattendu, lecture refusée.");
        }
        var attributes = ImmutableArray<SchemaAttributeDefinition>.Empty;
        var classes = ImmutableArray<SchemaClassDefinition>.Empty;
        var truncated = false;
        try
        {
            progress?.Report(SchemaReadStage.Attributes);
            var entries = await SearchAsync("attributeSchema", AttributeFields, limits.MaxAttributes, root.SchemaNamingContext, Remaining(), budget.Token).ConfigureAwait(false);
            attributes = [.. entries.Take(limits.MaxAttributes).Where(e => ValidName(e.String("lDAPDisplayName"))).Select(Attribute)];
            truncated = entries.Count > limits.MaxAttributes || attributes.Length != Math.Min(entries.Count, limits.MaxAttributes);
            budget.Token.ThrowIfCancellationRequested();
            progress?.Report(SchemaReadStage.Classes);
            entries = await SearchAsync("classSchema", ClassFields, limits.MaxClasses, root.SchemaNamingContext, Remaining(), budget.Token).ConfigureAwait(false);
            classes = [.. entries.Take(limits.MaxClasses).Where(e => ValidName(e.String("lDAPDisplayName"))).Select(Class)];
            truncated |= entries.Count > limits.MaxClasses || classes.Length != Math.Min(entries.Count, limits.MaxClasses);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested)
        {
            // Keep definitions already read, with an explicit incomplete flag. Never retry another controller.
            truncated = true;
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.Timeout && elapsed.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            truncated = true;
        }
        cancellationToken.ThrowIfCancellationRequested();
        return new SchemaReadResult(attributes, classes, root.DnsHostName, observedAt, truncated,
            (long)source.Clock.GetElapsedTime(started).TotalMilliseconds, root.DefaultNamingContext, root.SchemaNamingContext);

        TimeSpan Remaining()
        {
            budget.Token.ThrowIfCancellationRequested();
            var remaining = limits.Budget - source.Clock.GetElapsedTime(started);
            if (remaining <= TimeSpan.Zero)
            {
                elapsed.Cancel();
                budget.Token.ThrowIfCancellationRequested();
            }
            return remaining < TimeSpan.FromSeconds(60) ? remaining : TimeSpan.FromSeconds(60);
        }
    }

    private Task<IReadOnlyList<AdEntry>> SearchAsync(string kind, IReadOnlyList<string> fields, int limit, string context, TimeSpan timeout, CancellationToken cancellationToken) =>
        source.Connection.SearchAsync(new AdSearchRequest(context, "(objectClass=" + kind + ")", AdSearchScope.OneLevel, fields)
        {
            PageSize = 500,
            SizeLimit = limit + 1,
            Timeout = timeout,
        }, cancellationToken);

    internal static bool ValidContext(string context)
    {
        try
        {
            var parts = DistinguishedName.Parse(context);
            return parts.Length >= 3 && parts[0].Type.Equals("CN", StringComparison.OrdinalIgnoreCase)
                && parts[0].Value.Equals("Schema", StringComparison.OrdinalIgnoreCase)
                && parts[1].Type.Equals("CN", StringComparison.OrdinalIgnoreCase)
                && parts[1].Value.Equals("Configuration", StringComparison.OrdinalIgnoreCase)
                && parts.Skip(2).All(p => p.Type.Equals("DC", StringComparison.OrdinalIgnoreCase) && p.Value.Length > 0);
        }
        catch (FormatException)
        {
            return false;
        }
    }

    private static bool ValidName(string? name) => name is { Length: > 0 and <= 128 } && name.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');
    private static bool Flag(AdEntry entry, string name) => string.Equals(entry.String(name), "TRUE", StringComparison.OrdinalIgnoreCase);
    private static string? Description(AdEntry entry)
    {
        var text = entry.String("adminDescription");
        if (text is null) return null;
        var flat = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return flat.Length <= 500 ? flat : flat[..500];
    }
    private static ImmutableArray<string> Names(AdEntry entry, string first, string second) =>
        [.. entry.Strings(first).Concat(entry.Strings(second)).Where(ValidName).Distinct(StringComparer.OrdinalIgnoreCase)];
    private static SchemaAttributeDefinition Attribute(AdEntry e) => new(
        e.String("lDAPDisplayName")!, Description(e), e.String("attributeID"), e.String("attributeSyntax") ?? "", e.Int("oMSyntax"),
        Flag(e, "isSingleValued"), e.Long("searchFlags"), e.Long("systemFlags"), Flag(e, "isMemberOfPartialAttributeSet"),
        e.Long("rangeLower"), e.Long("rangeUpper"), e.Long("linkID"), Flag(e, "isDefunct"));
    private static SchemaClassDefinition Class(AdEntry e) => new(
        e.String("lDAPDisplayName")!, Description(e), e.String("governsID"), e.String("subClassOf"),
        Names(e, "auxiliaryClass", "systemAuxiliaryClass"), Names(e, "mustContain", "systemMustContain"),
        Names(e, "mayContain", "systemMayContain"), e.Int("objectClassCategory"), Flag(e, "isDefunct"));
}
