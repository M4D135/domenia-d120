using System.Collections.Frozen;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Binary syntax knowledge supplied by the connection that read the schema; fakes can supply their own schema.</summary>
public interface IAdBinarySchemaProvider
{
    Task<IReadOnlySet<string>> ReadBinaryAttributesAsync(CancellationToken cancellationToken);
}

public sealed partial class AdConnection
{
    private Task<IReadOnlySet<string>>? binarySchema;

    public Task<IReadOnlySet<string>> ReadBinaryAttributesAsync(CancellationToken cancellationToken)
    {
        TaskCompletionSource<IReadOnlySet<string>>? start = null;
        Task<IReadOnlySet<string>> task;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (binarySchema is null)
            {
                start = new(TaskCreationOptions.RunContinuationsAsynchronously);
                binarySchema = start.Task;
            }
            task = binarySchema;
        }
        if (start is not null) { _ = LoadBinarySchemaAsync(start); }
        return task.WaitAsync(cancellationToken);
    }

    private async Task LoadBinarySchemaAsync(TaskCompletionSource<IReadOnlySet<string>> completion)
    {
        try
        {
            using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var root = await RootDseAsync(budget.Token).ConfigureAwait(false);
            if (!AdSchemaReader.ValidContext(root.SchemaNamingContext)) { throw AdAttributeRange.Incomplete(); }
            var entries = await SearchAsync(new(root.SchemaNamingContext,
                "(&(objectClass=attributeSchema)(|(attributeSyntax=2.5.5.10)(attributeSyntax=2.5.5.15)(attributeSyntax=2.5.5.17)))",
                AdSearchScope.OneLevel, ["lDAPDisplayName", "attributeSyntax"])
            { SizeLimit = 2001, PageSize = 500, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, budget.Token).ConfigureAwait(false);
            var names = BinarySchemaNames(entries, root.SchemaNamingContext);
            completion.TrySetResult(names);
        }
#pragma warning disable CA1031 // Complete every waiter and clear a failed read; the bounded schema request is never left hanging.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            lock (_sync) { if (ReferenceEquals(binarySchema, completion.Task)) { binarySchema = null; } }
            completion.TrySetException(ex);
            // Observe even when every caller has cancelled its own wait.
            _ = completion.Task.Exception;
        }
    }

    internal static IReadOnlySet<string> BinarySchemaNames(IReadOnlyList<AdEntry> entries, string context)
    {
        if (!AdSchemaReader.ValidContext(context) || entries.Count > 2000) { throw AdAttributeRange.Incomplete(); }
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in entries)
        {
            var name = entry.String("lDAPDisplayName");
            if (!FicheValues.SameDn(DistinguishedName.Parent(entry.DistinguishedName), context)
                || !FicheAttributeRules.IsValidName(name) || entry.String("attributeSyntax") is not ("2.5.5.10" or "2.5.5.15" or "2.5.5.17")
                || !names.Add(name!)) { throw AdAttributeRange.Incomplete(); }
        }
        return names.Where(n => !FicheAttributeRules.IsSensitive(n)).ToFrozenSet(StringComparer.OrdinalIgnoreCase);
    }
}
