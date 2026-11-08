using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    public async Task<UserGroupComparison> CompareAsync(string leftDn, string right, CancellationToken cancellationToken)
    {
        var epoch = source.Epoch; var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false); EnsureEpoch(epoch); var domain = local.Directory.Domain;
        AdRelationDirectory.ValidateDn(leftDn, domain);
        var text = right.Trim();
        if (text.Length is < 2 or > 4096 || text.Any(char.IsControl)) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Identifiant du second compte invalide."); }
        var rightDn = text.Contains('=') ? text : null; string? filter = null;
        if (rightDn is not null) { AdRelationDirectory.ValidateDn(rightDn, domain); }
        else
        {
            if (text.Length > 320) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Identifiant du second compte trop long."); }
            var qualified = text.Contains('\\') || text.Contains('@') ? text : domain.NetbiosName + "\\" + text;
            filter = AdSessionIdentity.Filter(domain, qualified, null, true)
                ?? throw new DomeniaOperationException(RelationErrors.CompareUnresolved, "Compte mal formé ou d’un autre domaine ; aucune comparaison lancée.");
        }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(30), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
        var lookup = AdRelationLookup.For(local.Directory);
        var left = await new AdUserGroupReader(source, access, domain).ReadAsync(leftDn, lookup.Find(leftDn)?.Guid, budget.Token).ConfigureAwait(false);
        Guid? rightGuid = rightDn is null ? null : lookup.Find(rightDn)?.Guid;
        if (rightDn is null)
        {
            var matches = await access.SearchAsync(new(domain.RootDn, filter!, AdSearchScope.Subtree, AdRelationDirectory.Attributes)
            { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(8), ExpandRanges = false }, budget.Token).ConfigureAwait(false);
            if (matches.Count != 1 || AdRelationDirectory.Map(matches[0], domain) is not { Kind: RelationSubjectKind.User } identity)
            { throw new DomeniaOperationException(RelationErrors.CompareUnresolved, "Second compte absent, ambigu ou illisible avec ce compte de lecture."); }
            var wanted = text.Contains('\\') ? text[(text.IndexOf('\\') + 1)..] : text;
            if (!(text.Contains('@') ? string.Equals(identity.Upn, wanted, StringComparison.OrdinalIgnoreCase) : string.Equals(identity.Login, wanted, StringComparison.OrdinalIgnoreCase)))
            { throw AdAttributeRange.Incomplete(); }
            rightDn = identity.Dn; rightGuid = identity.Guid;
        }
        var other = await new AdUserGroupReader(source, access, domain).ReadAsync(rightDn, rightGuid, budget.Token).ConfigureAwait(false);
        if (left.User.ObjectGuid == other.User.ObjectGuid && (left.User.UsnChanged != other.User.UsnChanged || left.Company != other.Company
            || !DistinguishedName.AreEqual(left.User.DistinguishedName, other.User.DistinguishedName) || left.User.SamAccountName != other.User.SamAccountName
            || left.User.Title != other.User.Title || left.User.Department != other.User.Department || left.User.Office != other.User.Office || left.User.ManagerDn != other.User.ManagerDn
            || !left.User.MemberOf.Order(StringComparer.OrdinalIgnoreCase).SequenceEqual(other.User.MemberOf.Order(StringComparer.OrdinalIgnoreCase), StringComparer.OrdinalIgnoreCase)))
        { throw WriteErrors.Refusal(WriteErrors.Stale, "Le même compte a changé entre les deux lectures ; relancez la comparaison."); }
        var groups = new Dictionary<string, DirectoryGroup>(StringComparer.OrdinalIgnoreCase); var ids = new Dictionary<Guid, string>();
        foreach (var group in left.Groups.Concat(other.Groups))
        {
            if (ids.TryGetValue(group.ObjectGuid, out var oldDn) && !DistinguishedName.AreEqual(oldDn, group.DistinguishedName))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Un groupe a changé d’emplacement entre les lectures ; relancez la comparaison."); }
            if (groups.TryGetValue(group.DistinguishedName, out var previous) && (previous.ObjectGuid != group.ObjectGuid || previous.Sid != group.Sid
                || previous.UsnChanged != group.UsnChanged || previous.Name != group.Name || previous.GroupType != group.GroupType || previous.AdminCount != group.AdminCount
                || !previous.MemberOf.Order(StringComparer.OrdinalIgnoreCase).SequenceEqual(group.MemberOf.Order(StringComparer.OrdinalIgnoreCase), StringComparer.OrdinalIgnoreCase)))
            { throw WriteErrors.Refusal(WriteErrors.Stale, "Un groupe commun a changé entre les lectures ; aucune combinaison de versions publiée."); }
            ids[group.ObjectGuid] = group.DistinguishedName; groups[group.DistinguishedName] = group;
        }
        access.EnsureCurrent(); EnsureEpoch(epoch);
        var readAt = source.Clock.GetUtcNow(); var directory = new DirectorySnapshot(domain, readAt, false, [], [left.User, other.User], [], [.. groups.Values]);
        var compared = UserGroupComparer.Compare(left.User, other.User, directory, readAt, source.Zone,
            companyOf: u => u.ObjectGuid == left.User.ObjectGuid ? left.Company : other.Company);
        var limits = compared.Limits.Concat(left.Limits.Select(l => left.User.SamAccountName + " : " + l)).Concat(other.Limits.Select(l => other.User.SamAccountName + " : " + l)).Distinct(StringComparer.Ordinal).ToImmutableArray();
        var result = compared with
        {
            Limits = limits,
            Summary = (limits.Length > 0 ? "Comparaison partielle. " : "") + compared.Summary,
            Note = "Appartenances visibles avec " + access.Account + ", relevées successivement. Les droits effectifs nécessitent leur propre analyse. Groupes d’autres domaines non interrogés ; aucune différence appliquée.",
        };
        return result with { Ticket = UserGroupComparer.Ticket(result, source.Zone) };
    }
}
