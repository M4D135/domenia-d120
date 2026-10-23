using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    public async Task<RelationTargetSearch> TargetsAsync(string subjectDn, string text, CancellationToken cancellationToken)
    {
        var term = text.Trim();
        if (term.Length is < 2 or > 128 || term.Any(char.IsControl))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Saisissez entre 2 et 128 caractères pour rechercher dans le domaine."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false); var domain = local.Directory.Domain;
        AdRelationDirectory.ValidateDn(subjectDn, domain);
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(25), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
        var subject = (await AdRelationDirectory.ExactAsync(access, domain, subjectDn, local.Lookup.Find(subjectDn)?.Guid, false, budget.Token).ConfigureAwait(false)).Object;
        var kind = subject.Kind == RelationSubjectKind.User ? RelationSubjectKind.Computer : RelationSubjectKind.User;
        var literal = SearchText.LdapLiteral(term);
        var names = kind == RelationSubjectKind.Computer ? new[] { "name", "sAMAccountName", "dNSHostName" } : ["displayName", "sAMAccountName", "userPrincipalName", "name"];
        var filter = "(&" + (kind == RelationSubjectKind.Computer ? AdDirectoryMapper.ComputerFilter : AdDirectoryMapper.UserFilter)
            + "(|" + string.Concat(names.Select(a => "(" + a + "=*" + literal + "*)")) + "))";
        var entries = await access.SearchAsync(new(domain.RootDn, filter, AdSearchScope.Subtree, AdRelationDirectory.Attributes)
        { PageSize = 51, SizeLimit = 51, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = false }, budget.Token).ConfigureAwait(false);
        var candidates = entries.Take(51).Select(e => AdRelationDirectory.Map(e, domain)).OfType<RelationObject>().Where(o => o.Kind == kind).ToArray();
        var duplicatedDns = candidates.GroupBy(o => DistinguishedName.Format(DistinguishedName.Parse(o.Dn)), StringComparer.OrdinalIgnoreCase)
            .Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var unique = candidates.GroupBy(o => o.Guid).Where(g => g.Count() == 1).Select(g => g.Single())
            .Where(o => !duplicatedDns.Contains(DistinguishedName.Format(DistinguishedName.Parse(o.Dn)))).ToArray();
        var linked = RelationProjection.SubjectRelations(local.Stored.Rows.Select(r => r.Relation), subject)
            .Select(r => kind == RelationSubjectKind.User ? r.UserGuid : r.ComputerGuid).OfType<Guid>().ToHashSet();
        var shown = unique.OrderBy(o => o.Name, StringComparer.OrdinalIgnoreCase).Take(50)
            .Select(o => new RelationTarget(kind, o.Dn, o.Guid.ToString("D"), o.Name, o.Login, o.Detail, o.Enabled, linked.Contains(o.Guid))).ToImmutableArray();
        access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        var message = FrenchText.Count(shown.Length, "résultat relu dans le domaine", "résultats relus dans le domaine") + ".";
        if (entries.Count > 50) { message += " Limite de 50 résultats ; précisez la recherche."; }
        if (unique.Length < Math.Min(entries.Count, 51)) { message += " Des identités illisibles ou ambiguës ont été écartées."; }
        return new(term, kind, shown, entries.Count > 50, message);
    }
}
