using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;

namespace Domenia.Tests;

internal static class HomeMemoryCollectionTests
{
    private static readonly CustomHealthRule Rule = new("custom.00000000000000000000000000000027", "Mémoire", "MemoryUsed", "GreaterThan", 80, "Warn", true);

    [Test]
    public static async Task Recent_inventory_without_memory_is_recollected_and_never_marked_complete_without_the_frozen_fact()
    {
        var source = new HomePipelineSource();
        source.Current = source.Current with { Observations = new(Fixtures.Now, [.. source.Current.Directory.Computers.Select(pc =>
            Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(1000, 500, TimeSpan.Zero)))]) };
        using var context = source.Context(); var home = AccueilService.From(context);
        await home.SaveLayoutAsync([new("health", FleetWidgetSource.Builtin, "fleet.health", "Health", "M", null, false, "")], default);
        await home.SaveHealthAsync(null, HealthPolicy.Default with { CustomRules = [Rule] }, default);
        var plan = await home.PlanRefreshAsync("inventory", default);
        Check.Equal(0, plan.Reused, "inventaire ancien sans couple mémoire non réutilisable pour cette règle");
        Check.True(plan.MemoryPolicies.Any(p => p.Required), "dépendance incluse avant confirmation");
        // Changing the current rule cannot mutate an already approved collection's dependencies.
        await home.SaveHealthAsync(null, HealthPolicy.Default, default);
        var result = await home.RunRefreshAsync(plan.Id, false, _ => { }, default);
        Check.Equal(1, source.InventoryCalls, "vraie étape inventaire exécutée malgré les anciens disques récents");
        Check.Equal("partial", result.Status, "le lecteur fixture sans mémoire ne fabrique aucun succès mémoire");
        Check.True(source.Saved!.MemoryPolicies.Any(p => p.Required), "dépendance conservée dans le checkpoint");
        Check.True(source.Saved.InventoryDone.IsEmpty, "aucun poste coché sans la mémoire demandée");
        var resume = await home.PlanRefreshAsync("resume", default);
        Check.True(resume.MemoryPolicies.SequenceEqual(plan.MemoryPolicies), "reprise garde sa politique et non la règle actuelle");
    }

    [Test]
    public static void Memory_dependencies_keep_child_OU_exceptions_and_survive_the_real_durable_codec()
    {
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var child = "OU=Pause," + Fixtures.Postes;
        var policy = HealthPolicy.Default with { CustomRules = [Rule] };
        var book = HealthPolicyBook.Empty(Fixtures.Root) with { Default = policy };
        book = HealthRules.SetScopePolicy(book, child, policy with { CustomRules = [Rule with { Enabled = false }] }, Fixtures.Now);
        var resumed = "OU=Reprise," + child;
        book = HealthRules.SetScopePolicy(book, resumed, policy, Fixtures.Now);
        var frozen = HomeMemoryPolicy.Freeze(book, scope, Fixtures.Now);
        HomeMemoryPolicy.Validate(frozen, scope);
        var required = HomeMemoryPolicy.Resolver(frozen);
        Check.True(required("CN=PC1," + Fixtures.Postes), "règle héritée du domaine");
        Check.False(required("CN=PC2," + child), "pause locale n’impose pas une nouvelle lecture");
        Check.True(required("CN=PC3,OU=SansException," + Fixtures.Postes), "descendant sans exception garde sa dépendance");
        Check.False(required("CN=PC4,OU=SansException," + child), "pause héritée dans une sous-OU");
        Check.True(required("CN=PC5," + resumed), "exception plus précise réactive la lecture");
        Check.False(required("CN=PC6,OU=Ailleurs," + Fixtures.Root), "aucune règle inventée hors du périmètre");
        var source = new HomePipelineSource(); var plan = source.Checkpoint() with { MemoryPolicies = frozen };
        var state = new OperationsLocalState(plan.StoreId, Fixtures.Root, 1, [], [], null) { HomeCampaign = plan };
        var restored = OperationsDocumentCodec.Decode(OperationsDocumentCodec.Encode(state));
        Check.True(frozen.SequenceEqual(restored.HomeCampaign!.MemoryPolicies), "exceptions figées relues, pas oubliées par le codec");
        var invalid = plan with { MemoryPolicies = [new("OU=Other,DC=elsewhere,DC=local", true)] };
        Check.Throws<InvalidDataException>(() => HomeCampaignRules.Validate(invalid, plan.StoreId, Fixtures.Root), "scope étranger refusé");
        Check.Equal("volatileProbe", CollectionCachePolicy.Family("hw.memoryusage"), "mémoire instantanée jamais classée statique");
        var cache = CollectionCachePolicy.Read(new MemoryPreferenceStore());
        Check.False(cache.Memory(null, Fixtures.Now), "ancien cache sans mémoire reste inconnu");
        Check.True(cache.Memory(new(1000, 100, Fixtures.Now), Fixtures.Now), "couple récent peut être réutilisé");
        Check.False(cache.Memory(new(1000, 100, Fixtures.Now), Fixtures.Now, true), "tout relire ne réutilise pas la mémoire");
        Check.False(cache.Memory(new(1000, 100, Fixtures.Now.AddDays(-1)), Fixtures.Now), "pas de mémoire ancienne rajeunie par un autre relevé");
    }

    [Test]
    public static void Memory_scope_specificity_uses_DN_depth_and_accepts_equivalent_escaped_spellings()
    {
        const string escaped = @"OU=\50\6f\73\74\65\73,DC=\74\65\73\74,DC=\6c\6f\63\61\6c";
        var child = "OU=Pause," + Fixtures.Postes;
        var resumed = "OU=Reprise," + child;
        Check.True(escaped.Length > resumed.Length, "le parent échappé est plus long que ses descendants");
        ImmutableArray<HomeMemoryScope> policies = [new(escaped, true), new(child, false), new(resumed, true)];
        HomeMemoryPolicy.Validate(policies, new(Fixtures.Postes, "Postes", true));
        var required = HomeMemoryPolicy.Resolver(policies);
        Check.True(required("CN=PC1," + Fixtures.Postes), "parent exact reconnu malgré les échappements");
        Check.False(required("CN=PC2," + child), "exception enfant prioritaire sur le parent plus long");
        Check.False(required("CN=PC3,OU=Pause," + escaped), "autre orthographe conserve la même exception");
        Check.True(required("CN=PC4," + resumed), "exception la plus profonde appliquée");
        Check.Throws<InvalidDataException>(() => HomeMemoryPolicy.Validate([new(escaped, true), new(Fixtures.Postes, false)],
            new(Fixtures.Postes, "Postes", true)), "doublon canonique refusé");
    }
}
