using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Tests;

internal static class CollectionCachePolicyTests
{
    [Test]
    public static void Qualified_identity_facts_survive_age_but_not_a_new_identity_force_or_empty_value()
    {
        var computer = Fixtures.Computer("PC1") with { WhenCreated = Fixtures.Now.AddYears(-3) };
        var identity = QueryComputerIdentity.Of(computer);
        var policy = new CollectionCachePolicy(CollectionSettingsRules.Default);
        var reading = new ProbeReading(MeasureState.Known, Fixtures.Now.AddYears(-1), ["Model"], null) { Identity = identity };
        foreach (var id in new[] { "hw.maker", "hw.model", "hw.serialmissing" })
        {
            reading = reading with { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find(id)!) };
            Check.True(policy.Probe(id, reading, identity, Fixtures.Now), "identité matérielle conservée sans nouveau WMI : " + id);
            Check.False(policy.Probe(id, reading, identity, Fixtures.Now, force: true), "relecture explicite contourne même les données stables");
            Check.False(policy.Probe(id, reading, identity with { Sid = "new-sid" }, Fixtures.Now), "autre identité ne réemploie pas ancien matériel");
            Check.False(policy.Probe(id, reading with { At = Fixtures.Now }, identity with { Sid = "new-sid" }, Fixtures.Now), "identité différente refuse aussi le cache très récent");
            Check.False(policy.Probe(id, reading with { Identity = null }, identity, Fixtures.Now), "cache ancien non qualifié n’est pas permanent");
            Check.False(policy.Probe(id, reading with { Values = [] }, identity, Fixtures.Now), "vide ne devient pas un succès permanent");
            Check.False(policy.Probe(id, reading with { Values = ["To Be Filled By O.E.M."] }, identity, Fixtures.Now), "valeur de remplacement non permanente");
            Check.False(policy.Probe(id, reading with { Error = "partiel" }, identity, Fixtures.Now), "erreur relue");
        }
        foreach (var id in new[] { "hw.ram", "hw.bios", "os.caption", "disk.cfree", "os.users", "hw.cpuload" })
        { Check.False(policy.Probe(id, reading with { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find(id)!) }, identity, Fixtures.Now), "information modifiable conserve sa durée : " + id); }
    }

    [Test]
    public static void Variable_inventory_and_probes_obey_the_profile_and_zero_disables_reuse()
    {
        var policy = new CollectionCachePolicy(CollectionSettingsRules.Default);
        Check.True(policy.Inventory(Fixtures.Disk(100, 50, TimeSpan.FromMinutes(4)), Fixtures.Now), "inventaire récent réutilisé");
        Check.False(policy.Inventory(Fixtures.Disk(100, 50, TimeSpan.FromMinutes(6)), Fixtures.Now), "disque vieux de six minutes relu, pas trente jours");
        var identity = QueryComputerIdentity.Of(Fixtures.Computer("PC1"));
        var reading = new ProbeReading(MeasureState.Known, Fixtures.Now.AddMinutes(-2), ["25"], null) { Identity = identity };
        Check.False(policy.Probe("hw.cpuload", reading with { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find("hw.cpuload")!) }, identity, Fixtures.Now), "charge périmée après une minute");
        Check.True(policy.Probe("hw.bios", reading with { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find("hw.bios")!) }, identity, Fixtures.Now), "BIOS réutilisé pendant sa durée réglée");
        var disabled = new CollectionCachePolicy(CollectionSettingsRules.Default with
        { Budgets = CollectionSettingsRules.Default.Budgets.SetItem(CollectionSettingsRules.CacheMinutes, 0) });
        Check.False(disabled.Inventory(Fixtures.Disk(100, 50, TimeSpan.Zero), Fixtures.Now), "zéro force inventaire");
        Check.False(disabled.Probe("hw.model", reading with { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find("hw.model")!) }, identity, Fixtures.Now), "zéro force aussi identité matérielle");
        var disabledFamily = new CollectionCachePolicy(CollectionSettingsRules.Default with
        { Freshness = ImmutableDictionary<string, ImmutableDictionary<string, int>>.Empty.Add(CollectionSettingsRules.Standard,
            ImmutableDictionary<string, int>.Empty.Add("staticProbe", 0)) });
        Check.False(disabledFamily.Probe("hw.model", reading with { DefinitionHash = ProbeDefinitionIdentity.Of(ProbeCatalog.Find("hw.model")!) }, identity, Fixtures.Now), "durée de famille zéro force aussi le matériel");
    }

    [Test]
    public static void A_missing_probe_does_not_make_fresh_inventory_stale()
    {
        var pc = Fixtures.Computer("PC1"); var identity = QueryComputerIdentity.Of(pc);
        var observation = Fixtures.Observe(pc, Fixtures.Presence(true, TimeSpan.Zero), Fixtures.Disk(100, 50, TimeSpan.Zero));
        var policy = new CollectionCachePolicy(CollectionSettingsRules.Default);
        var missing = policy.Missing([pc.ObjectGuid], new Dictionary<Guid, WorkstationObservation> { [pc.ObjectGuid] = observation },
            ProbeReadings.Empty, ["hw.model"], ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(pc.ObjectGuid, identity), Fixtures.Now);
        Check.Equal(1, missing.Length, "sonde seule manquante");
        Check.True(policy.Inventory(observation.Inventory, Fixtures.Now), "inventaire ne doit pas être relu pour cette sonde");
    }
}
