using System.Collections.Immutable;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Core.Poste;

public sealed record PosteQueryCard(string Title, string RecipeId, long Revision, long CurrentRevision, string Fingerprint,
    string Verdict, string Explanation, DateTimeOffset EvaluatedAt, string Provenance);

public static class PosteQueryCards
{
    /// <summary>Evaluate the explicitly linked revision on this one workstation's local dataset. No population scan or collection.</summary>
    public static PosteQueryCard Build(FleetLayoutItem item, QueryLibraryContent library, QueryDataset dataset,
        Guid computer, string dn, DateTimeOffset now, ImmutableArray<FrozenProbe> personalProbes = default)
    {
        if (item.Source != FleetWidgetSource.Query || item.Paused || item.QueryBinding is null)
        { throw new InvalidDataException("Carte absente, en pause ou sans révision confirmée."); }
        if (!dataset.Directory.Computers.Any(c => c.ObjectGuid == computer && DistinguishedName.AreEqual(c.DistinguishedName, dn)))
        { throw new InvalidDataException("Identité du poste remplacée dans les données locales."); }
        var (binding, record, query) = PosteQueryLayout.Resolve(item, library, dataset.Directory.Domain.RootDn);
        QueryPersonalProbes.Confirm(query, personalProbes);
        var single = QueryRecordBuilder.Computer(dataset, computer, now)
            ?? throw new InvalidDataException("Poste absent du jeu de données local.");
        var context = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), now);
        var population = query.InPopulation(single, context);
        var verdict = population ? QueryTexts.VerdictKey(query.Evaluate(single, context)) : "outside";
        return new(item.Title ?? record.Name, record.Id, binding.Revision, record.Revision, binding.Fingerprint,
            verdict, string.Join(" ; ", query.Explain(single, context).Select(row =>
                row.Section + " · " + row.Condition + " : " + row.Value + " — " + row.Verdict + " (" + row.State
                + (row.ObservedAt is { } at ? ", " + at.ToString("u", System.Globalization.CultureInfo.InvariantCulture) : "") + ")")), now, "Calcul local sur la révision " + binding.Revision + " · empreinte " + binding.Fingerprint
                + (record.Revision != binding.Revision ? " · une révision plus récente attend votre confirmation dans l’atelier" : ""));
    }
}
