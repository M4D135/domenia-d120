using System.Security.Cryptography;
using System.Text;
using Domenia.Core.Queries;

namespace Domenia.Core.Accueil;

public sealed partial class AccueilService
{
    private readonly SemaphoreSlim healthWrites = new(1, 1);
    public async Task<HealthQueryBinding> FreezeHealthQueryAsync(string id, long revision, CancellationToken token)
    {
        var library = queryLibrary ?? throw HealthRules.Invalid("Bibliothèque non raccordée à cette session.");
        var (_, _, domain) = await ScopeAsync(token).ConfigureAwait(false);
        var record = await library.FindAsync(domain, id, token).ConfigureAwait(false) ?? throw HealthRules.Invalid("Requête absente de la bibliothèque.");
        return HealthQueryRules.Freeze(record, revision);
    }

    private static string HealthConsumerId(string scope, string ruleId) => "health." + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(scope.ToUpperInvariant() + "|" + ruleId)))[..32];

    private async Task ReleaseObsoleteHealthQueriesAsync(string domain, string scope, HealthPolicy policy, CancellationToken token)
    {
        if (queryLibrary is not { } library) { return; }
        var keep = policy.CustomRules.Where(r => r.Enabled && r.Query is not null).Select(r => HealthConsumerId(scope, r.Id)).ToHashSet(StringComparer.Ordinal);
        // Only our scoped links, after the policy save succeeds. Legacy consumers remain intact.
        try
        {
            var content = await library.ReadAsync(domain, token).ConfigureAwait(false);
            foreach (var link in content.Consumers.Where(c => c.Kind == "health" && c.Id.StartsWith("health.", StringComparison.Ordinal)
                && string.Equals(c.Scope ?? "", scope, StringComparison.OrdinalIgnoreCase) && !keep.Contains(c.Id)))
            { await library.ReleaseConsumerAsync(domain, "health", link.Id, token).ConfigureAwait(false); }
        }
        catch (Exception ex) when (ex is QueryDefinitionException or IOException or UnauthorizedAccessException)
        {
            context.Log.Warning("Dépendances de santé conservées après enregistrement : " + ex.GetType().Name + ".");
            context.Journal.Add(new JournalEntry(Now, "Règles enregistrées ; certains anciens liens de bibliothèque restent à relire avant retrait.", Tone.Warn));
        }
    }

    private async Task BindHealthQueriesAsync(string domain, string scope, HealthPolicy policy, CancellationToken token)
    {
        var queries = policy.CustomRules.Where(r => r.Enabled && r.Query is not null).ToArray();
        if (queries.Length == 0) { return; }
        var library = queryLibrary ?? throw HealthRules.Invalid("Bibliothèque non lue : les règles de requête ne peuvent pas être confirmées.");
        foreach (var rule in queries)
        {
            var binding = rule.Query!;
            try
            {
                // The library checks the exact old revision inside its write transaction, without silently adopting current.
                await library.BindConsumerAsync(domain, "health", HealthConsumerId(scope, rule.Id), binding.RecipeId, rule.Name, scope, token,
                    binding.Revision, binding.Fingerprint).ConfigureAwait(false);
            }
            catch (QueryDefinitionException ex) { throw HealthRules.Invalid(ex.Message); }
        }
    }
}
