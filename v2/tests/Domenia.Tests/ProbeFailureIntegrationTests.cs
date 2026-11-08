using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

internal static class ProbeFailureIntegrationTests
{
    [Test]
    public static async Task Repeated_fleet_requests_do_not_recontact_failed_probes_until_the_delay_expires()
    {
        var clock = new CacheLifetimeTests.CacheClock(); var pc = Fixtures.Computer("PC1");
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc]));
        cache.Fleet = cache.Fleet.Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero))]) });
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", clock, connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var calls = 0;
        var reader = new AdAccueilReader(source) { ProbeOverride = (_, ids, _) =>
        {
            calls++;
            return Task.FromResult(ids.ToImmutableDictionary(id => id, _ => new ProbeReading(MeasureState.Error, clock.GetUtcNow(), [], "Transport indisponible") { FailureStatus = SourceStatus.Unreachable }));
        } };
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var first = await reader.CollectProbesAsync(["hw.model"], scope, new[] { pc.ObjectGuid }, default);
        clock.Seconds = 119;
        var second = await reader.CollectProbesAsync(["hw.model"], scope, new[] { pc.ObjectGuid }, default);
        Check.Equal(1, calls, "le vrai lecteur réutilise le refus avant tout contact LDAP/CIM");
        Check.Equal(first.ByProbe["hw.model"][pc.ObjectGuid].At, second.ByProbe["hw.model"][pc.ObjectGuid].At, "pas de faux relevé récent");
        Check.Equal(0, ldap.Calls, "aucun LDAP ajouté par le cache");
        clock.Seconds = 120;
        await reader.CollectProbesAsync(["hw.model"], scope, new[] { pc.ObjectGuid }, default);
        Check.Equal(2, calls, "nouvelle tentative après expiration");
        await reader.CollectProbesAsync(["hw.maker"], scope, new[] { pc.ObjectGuid }, default);
        Check.Equal(3, calls, "autre définition ne réutilise pas le refus");
        await reader.RetryFrozenProbesAsync(PersonalProbeCatalog.Builtins(["hw.model"]), scope,
            ImmutableDictionary<Guid, Domenia.Core.Queries.QueryComputerIdentity>.Empty.Add(pc.ObjectGuid, Domenia.Core.Queries.QueryComputerIdentity.Of(pc)), source.Epoch, default);
        Check.Equal(4, calls, "nouvel essai volontaire contourne le cache sans attendre");
    }
}
