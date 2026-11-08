using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Exact, bounded identity reads shared by search, fiches and pre-write revalidation.</summary>
internal sealed class AdObjectAccess(AdDirectorySource source)
{
    internal static readonly ImmutableArray<string> Attributes = [.. AdDirectoryMapper.OuAttributes
        .Concat(AdDirectoryMapper.UserAttributes).Concat(AdDirectoryMapper.ComputerAttributes).Concat(AdDirectoryMapper.GroupAttributes).Concat(AdDirectoryMapper.ContactAttributes)
        .Distinct(StringComparer.OrdinalIgnoreCase)];

    internal static string GuidFilter(Guid id)
    {
        if (id == Guid.Empty) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Identité d’objet vide : aucune recherche lancée."); }
        return "(objectGUID=" + string.Concat(id.ToByteArray().Select(b => "\\" + b.ToString("x2", CultureInfo.InvariantCulture))) + ")";
    }

    public async Task<DirectorySnapshot> ReadAsync(IReadOnlyCollection<Guid> ids, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(ids);
        if (ids.Count > 500 || ids.Any(id => id == Guid.Empty))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Relecture limitée à 500 identités valides : aucun objet lu."); }
        var wanted = ids.Distinct().ToArray();
        if (wanted.Length == 0)
        {
            var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
            return new(local.Directory.Domain, source.Clock.GetUtcNow(), false, [], [], [], []);
        }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(90), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        var domain = await source.DomainAsync(budget.Token).ConfigureAwait(false);
        var generation = source.Epoch;
        var entries = new List<AdEntry>();
        foreach (var batch in wanted.Chunk(40))
        {
            var filter = "(|" + string.Concat(batch.Select(GuidFilter)) + ")";
            var rows = await source.Connection.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, Attributes)
            { SizeLimit = batch.Length + 1, PageSize = 40, Timeout = TimeSpan.FromSeconds(30) }, budget.Token).ConfigureAwait(false);
            if (rows.Count > batch.Length || rows.Any(e => e.Guid("objectGUID") is not { } guid || !batch.Contains(guid)))
            { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Réponse d’identité incohérente : aucune fiche publiée."); }
            entries.AddRange(rows);
        }
        if (source.Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la relecture d’identités."); }
        return Project(entries, domain, source.Clock.GetUtcNow());
    }

    internal static DirectorySnapshot Project(IReadOnlyList<AdEntry> entries, DomainInfo domain, DateTimeOffset readAt)
    {
        var ous = ImmutableArray.CreateBuilder<DirectoryOu>();
        var users = ImmutableArray.CreateBuilder<DirectoryUser>();
        var computers = ImmutableArray.CreateBuilder<DirectoryComputer>();
        var groups = ImmutableArray.CreateBuilder<DirectoryGroup>();
        var contacts = ImmutableArray.CreateBuilder<DirectoryContact>();
        var ids = new HashSet<Guid>();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in entries)
        {
            if (entry.Guid("objectGUID") is not { } id || id == Guid.Empty || !ids.Add(id)
                || !ScopeRules.Contains(new(domain.RootDn, "", true), entry.DistinguishedName)
                || !names.Add(DistinguishedName.Format(DistinguishedName.Parse(entry.DistinguishedName))))
            { throw Invalid(); }
            var classes = entry.Strings("objectClass").ToHashSet(StringComparer.OrdinalIgnoreCase);
            object? value = classes.Contains("computer") ? AdDirectoryMapper.Computer(entry)
                : classes.Contains("group") ? AdDirectoryMapper.Group(entry)
                : classes.Contains("contact") ? AdDirectoryMapper.Contact(entry)
                : classes.Contains("user") && !classes.Contains("msDS-ManagedServiceAccount") && !classes.Contains("msDS-GroupManagedServiceAccount") ? AdDirectoryMapper.User(entry)
                : classes.Contains("organizationalUnit") || classes.Contains("container") ? AdDirectoryMapper.Ou(entry) : null;
            switch (value)
            {
                case DirectoryUser user: users.Add(user); break;
                case DirectoryComputer computer: computers.Add(computer); break;
                case DirectoryGroup group: groups.Add(group); break;
                case DirectoryOu ou: ous.Add(ou); break;
                case DirectoryContact contact: contacts.Add(contact); break;
                default: throw Invalid();
            }
        }
        // An exact selection or search page is never a complete census of the domain.
        return new(domain, readAt, false, ous.ToImmutable(), users.ToImmutable(), computers.ToImmutable(), groups.ToImmutable()) { Contacts = contacts.ToImmutable() };
    }

    private static DomeniaOperationException Invalid() => new(DomeniaErrors.SourceUnavailable, "Identité, type ou périmètre LDAP illisible : résultat non publié.");
}
