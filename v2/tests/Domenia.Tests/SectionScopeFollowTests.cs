using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class SectionScopeFollowTests
{
    private const string People = "OU=Utilisateurs,DC=example,DC=local";
    private const string Postes = "OU=Postes,DC=example,DC=local";
    private const string Paris = "OU=Paris,OU=Postes,DC=example,DC=local";
    private static string Args(object value) => JsonSerializer.Serialize(value);
    private static async Task<JsonElement> Row(SimulatedBridge bridge) => SimulatedBridge.Json(await bridge.CallAsync("settings.connection"))
        .GetProperty("sections").EnumerateArray().Single(s => s.GetProperty("id").GetString() == "accounts");
    private static async Task<string> Propose(SimulatedBridge bridge)
    {
        _ = SimulatedBridge.Json(await bridge.CallAsync("accounts.scope.set", Args(new { dn = People, subtree = false })));
        var row = await Row(bridge);
        Check.False(row.GetProperty("follows").GetBoolean(), "OU indépendante conservée");
        Check.True(row.GetProperty("canFollow").GetBoolean(), "proposition locale qualifiée");
        return row.GetProperty("followToken").GetString()!;
    }
    private static Task<BridgeResponse> Follow(SimulatedBridge bridge, string token, bool confirmed = true) =>
        bridge.CallAsync("settings.scope.follow", Args(new { section = "accounts", token, confirmed }));

    [Test]
    public static async Task Reading_and_refusing_the_proposal_preserve_the_own_scope_until_explicit_confirmation()
    {
        var bridge = new SimulatedBridge();
        var token = await Propose(bridge);
        Check.Equal("scope.confirmationRequired", (await Follow(bridge, token, false)).Error?.Code, "aucune confirmation implicite");
        Check.Equal(People, (await Row(bridge)).GetProperty("scopeDn").GetString(), "lecture et refus sans mutation");
        _ = SimulatedBridge.Json(await Follow(bridge, token));
        var row = await Row(bridge);
        Check.True(row.GetProperty("follows").GetBoolean(), "choix confirmé réutilise l’OU de travail");
        Check.Equal(Postes, row.GetProperty("scopeDn").GetString(), "OU effective");
        Check.False(bridge.Preferences.TryGet(AccountsSectionScope.PreferenceKey("DC=example,DC=local"), out _), "surcharge mémorisée retirée");
        Check.Equal("scope.confirmationStale", (await Follow(bridge, token)).Error?.Code, "confirmation consommée une seule fois");
    }

    [Test]
    public static async Task Changing_a_scope_even_back_to_the_same_value_invalidates_the_proposal()
    {
        var bridge = new SimulatedBridge();
        var token = await Propose(bridge);
        _ = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", Args(new { dn = Paris, subtree = true })));
        _ = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", Args(new { dn = Postes, subtree = true })));
        Check.Equal("scope.confirmationStale", (await Follow(bridge, token)).Error?.Code, "aller-retour de l’OU de travail ne réarme pas le jeton");
        token = (await Row(bridge)).GetProperty("followToken").GetString()!;
        _ = SimulatedBridge.Json(await bridge.CallAsync("accounts.scope.set", Args(new { dn = People, subtree = true })));
        _ = SimulatedBridge.Json(await bridge.CallAsync("accounts.scope.set", Args(new { dn = People, subtree = false })));
        Check.Equal("scope.confirmationStale", (await Follow(bridge, token)).Error?.Code, "aller-retour de la surcharge ne réarme pas le jeton");
        Check.Equal(People, (await Row(bridge)).GetProperty("scopeDn").GetString(), "aucune perte de surcharge");
    }

    [Test]
    public static async Task Whole_domain_and_expired_proposals_cannot_replace_an_accounts_ou()
    {
        var bridge = new SimulatedBridge();
        var token = await Propose(bridge);
        bridge.Clock.Advance(TimeSpan.FromMinutes(11));
        Check.Equal("scope.confirmationStale", (await Follow(bridge, token)).Error?.Code, "proposition périmée");
        _ = SimulatedBridge.Json(await bridge.CallAsync("session.setScope", Args(new { dn = "DC=example,DC=local", subtree = true })));
        var row = await Row(bridge);
        Check.False(row.GetProperty("canFollow").GetBoolean(), "lecture de comptes sur tout le domaine toujours refusée");
        Check.Equal(JsonValueKind.Null, row.GetProperty("followToken").ValueKind, "aucun jeton permettant le contournement");
        Check.Equal(People, row.GetProperty("scopeDn").GetString(), "OU propre préservée");
    }
}
