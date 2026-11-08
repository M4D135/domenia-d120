using System.Collections.Immutable;
using System.Security;
using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Wmi;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class QueryPersonalProbeNativeTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private const string Namespace = @"root\cimv2";
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(p => p.Name, p => p.Value));

    [Test]
    public static async Task Personal_workshop_projection_refuses_tampering_before_transport_and_requires_member_role_and_declared_type()
    {
        var original = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var changed = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model")).Single();
        var sessions = 0;
        var forbidden = new WmiWorkstationReader(TestClock.Fixed()) { SessionFactory = (_, _, _) =>
            { sessions++; throw new TestFailureException("Le transport ne doit pas être créé."); } };
        await Check.ThrowsAsync<QueryDefinitionException>(() => forbidden.ReadWorkshopSelectAsync("PC1", Namespace,
            WqlRules.Parse("SELECT Model FROM Win32_ComputerSystem"), 1, None, personalProbe: original, probeAt: Fixtures.Now), "projection remplacée refusée");
        await Check.ThrowsAsync<QueryDefinitionException>(() => forbidden.ReadWorkshopSelectAsync("PC1", Namespace,
            WqlRules.Parse("SELECT Manufacturer FROM Win32_ComputerSystem"), 1, None,
            personalProbe: original with { Definition = changed.Definition }, probeAt: Fixtures.Now), "déclaration valide sous mauvaise clé refusée");
        Check.Equal(0, sessions, "aucun contact avant validation de la déclaration entière");
        foreach (var role in new int?[] { null, 4, 5, 1 })
        {
            var selected = 0;
            var native = Native((query, _) => query.Contains("DomainRole", StringComparison.Ordinal)
                ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", role))]
                : Select(), "String");
            IReadOnlyList<WmiInstance> Select() { selected++; return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Manufacturer", "Constructeur réel"))]; }
            var read = await native.ReadWorkshopSelectAsync("PC1", Namespace, WqlRules.Parse("SELECT Manufacturer FROM Win32_ComputerSystem"), 1,
                None, awaitPhysicalCompletion: true, personalProbe: original, probeAt: Fixtures.Now);
            Check.Equal(role == 1 ? 1 : 0, selected, "SELECT personnel seulement sur rôle membre confirmé");
            Check.Equal(role == 1 ? 1 : 0, read.Rows.Length, "aucun chiffre produit pour un contrôleur ou rôle absent");
        }
        var calls = 0;
        var mismatch = Native((query, _) => query.Contains("DomainRole", StringComparison.Ordinal)
            ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))] : Wrong(), "UInt32");
        IReadOnlyList<WmiInstance> Wrong() { calls++; return [Row(("Manufacturer", 12))]; }
        var refused = await mismatch.ReadWorkshopSelectAsync("PC1", Namespace, WqlRules.Parse("SELECT Manufacturer FROM Win32_ComputerSystem"), 1,
            None, personalProbe: original, probeAt: Fixtures.Now);
        Check.Equal(0, calls, "type reçu contradictoire : aucune projection envoyée");
        Check.Equal(0, refused.Rows.Length, "aucune valeur interprétée selon une déclaration fausse");
    }

    [Test]
    public static async Task Actual_query_reader_uses_profile_frozen_definitions_and_stores_all_rows_with_exact_provenance()
    {
        using var fixture = new Fixture(); var original = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document(mode: "All")).Single();
        await fixture.Import(original);
        var selected = 0;
        var reader = new AdQueryWorkshopReader(fixture.Source)
        {
            InventoryReaderOverride = _ => Native((query, _) => query.Contains("DomainRole", StringComparison.Ordinal)
                ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))] : Values(), "String"),
        };
        IReadOnlyList<WmiInstance> Values()
        { selected++; return [Row(("Name", "PC1-A"), ("Manufacturer", "A")), Row(("Name", "PC1-B"), ("Manufacturer", "B"))]; }
        var request = fixture.Request(original);
        var result = await reader.MeasureAsync(request, None);
        Check.Equal(1, result.Answered, "collecte réellement aboutie via le lecteur AD");
        var reading = (await reader.DatasetAsync(None)).Probes[fixture.Computer.ObjectGuid].Single();
        Check.Equal(original.Key, reading.ProbeId, "clé personnalisée complète stockée");
        Check.Equal(original.Key, reading.PersonalDeclaration!.Key, "provenance stockée avec les valeurs");
        Check.True(reading.Instances.Select(r => r.Values["Manufacturer"] as string).SequenceEqual(["A", "B"]), "vrais résultats All, pas un booléen ou un simple compte");
        Check.True(reading.CountComplete, "compte cohérent avec les instances reçues");
        var replaced = request with { ExpectedIdentities = request.ExpectedIdentities!.SetItem(fixture.Computer.ObjectGuid,
            QueryComputerIdentity.Of(fixture.Computer) with { Host = "other.test.local" }) };
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.MeasureAsync(replaced, None), "identité figée différente refusée");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.MeasureAsync(replaced with
        { Probes = [.. QueryProbeCatalog.All.Select(p => p.Id), original.Key] }, None), "catalogue mixte accepté jusqu’à la garde de cible, au-delà de la seule borne embarquée");
        Check.Equal(1, selected, "pas de second contact après refus de cible");
        await fixture.Context.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, JsonSerializer.SerializeToElement<object?>(null), None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.MeasureAsync(request, None), "déclaration retirée du profil refuse un ancien plan");
        Check.Equal(1, selected, "la déclaration du cache ne donne pas autorité d’exécution");
    }

    [Test]
    public static async Task Profile_change_during_a_projection_refuses_its_unqualified_result_and_the_next_source()
    {
        using var fixture = new Fixture();
        var first = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var second = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model")).Single();
        await fixture.Import(first, second); var selected = 0;
        var reader = new AdQueryWorkshopReader(fixture.Source)
        {
            InventoryReaderOverride = _ => Native((query, _) =>
            {
                if (query.Contains("DomainRole", StringComparison.Ordinal)) { return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))]; }
                selected++;
                fixture.Context.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey, JsonSerializer.SerializeToElement<object?>(null), None).GetAwaiter().GetResult();
                return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("Manufacturer", "Mesure reçue"))];
            }, "String"),
        };
        var request = fixture.Request(first) with { Probes = [first.Key, second.Key], PersonalProbes = [first, second] };
        var result = await reader.MeasureAsync(request, None);
        Check.Equal(1, result.Failed, "campagne incomplète signalée"); Check.Equal(1, selected, "seconde projection non envoyée après retrait du profil");
        var rows = (await reader.DatasetAsync(None)).Probes[fixture.Computer.ObjectGuid];
        Check.NotNull(rows.Single(r => r.ProbeId == first.Key).Error, "retrait avant qualification finale : résultat inconnu, jamais publié comme mesure qualifiée");
        Check.NotNull(rows.Single(r => r.ProbeId == second.Key).Error, "source non lue inconnue, jamais zéro");
        Check.Equal(second.Key, rows.Single(r => r.ProbeId == second.Key).PersonalDeclaration!.Key, "échec qualifié par la définition prévue");
    }

    [Test]
    public static async Task Profile_removed_during_directory_admission_prevents_the_first_personal_CIM_projection()
    {
        using var fixture = new Fixture(); var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        await fixture.Import(probe); var sessions = 0;
        fixture.BeforeDirectoryRead = () => fixture.Context.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey,
            JsonSerializer.SerializeToElement<object?>(null), None).GetAwaiter().GetResult();
        var reader = new AdQueryWorkshopReader(fixture.Source) { InventoryReaderOverride = _ =>
        { sessions++; throw new TestFailureException("Aucun lecteur CIM sans la déclaration du profil."); } };
        var outcome = await reader.MeasureAsync(fixture.Request(probe), None);
        Check.Equal(1, outcome.Failed, "admission interrompue explicitement");
        Check.Equal(0, sessions, "profil requalifié après LDAP, avant création du lecteur natif");
    }

    [Test]
    public static async Task A_composed_collection_holds_one_machine_lease_for_ping_and_every_personal_projection()
    {
        using var fixture = new Fixture(); var a = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single();
        var b = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document("Model")).Single(); await fixture.Import(a, b);
        var machine = MachineAccountService.From(fixture.Context); var session = await fixture.Source.GetSessionAsync(None);
        using var secret = PasswordSecrets.FromText("one-shot-query-fixture");
        machine.AcceptTemporary(session, null, @"TEST\once", secret.Copy(), MachineLeaseMode.OneShot);
        _ = machine.Resolve(session, fixture.Computer.DnsHostName); var reads = 0; var pings = 0;
        var reader = new AdQueryWorkshopReader(fixture.Source)
        {
            PingOverride = (_, _) => { pings++; return Task.FromResult(true); },
            InventoryReaderOverride = _ => Native((query, _) =>
            {
                machine.Resolve(session, fixture.Computer.DnsHostName);
                if (query.Contains("DomainRole", StringComparison.Ordinal)) return [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))];
                Check.True(query is "SELECT Manufacturer FROM Win32_ComputerSystem" or "SELECT Model FROM Win32_ComputerSystem", "projection personnelle exacte, aucune clé Name ajoutée");
                reads++; return [Row(("Manufacturer", "Fabricant"), ("Model", "Modèle"))];
            }, "String"),
        };
        var request = fixture.Request(a) with { Presence = true, Probes = [a.Key, b.Key], PersonalProbes = [a, b],
            ExpectedAccountVersion = AccountAccess.From(fixture.Context).SelectionVersion, ExpectedMachineGeneration = machine.Generation };
        var outcome = await reader.MeasureAsync(request, None);
        Check.Equal(1, outcome.Answered, "collecte composée entièrement qualifiée avec le bail unique retenu");
        Check.Equal(1, pings, "un seul ping prévu"); Check.Equal(2, reads, "les deux sources prévues atteintes sans nouvelle sélection");
        Check.True(machine.Resolve(session, fixture.Computer.DnsHostName).Source != MachineAccountSource.Temporary, "bail consommé indisponible pour une autre lecture");
    }

    [Test]
    public static async Task A_presence_only_collection_does_not_consume_the_machine_one_shot_or_require_a_machine_reader()
    {
        using var fixture = new Fixture(); var machine = MachineAccountService.From(fixture.Context); var session = await fixture.Source.GetSessionAsync(None);
        using var secret = PasswordSecrets.FromText("ping-keeps-query-fixture");
        machine.AcceptTemporary(session, null, @"TEST\once", secret.Copy(), MachineLeaseMode.OneShot);
        _ = machine.Resolve(session, fixture.Computer.DnsHostName); var generation = machine.Generation;
        var reader = new AdQueryWorkshopReader(fixture.Source)
        { PingOverride = (_, _) => Task.FromResult(true), InventoryReaderOverride = _ => throw new TestFailureException("Aucun lecteur Machine pour ICMP seul.") };
        var request = new QueryMeasureRequest([fixture.Computer.ObjectGuid], true, false, false, [])
        { ExpectedAccountVersion = AccountAccess.From(fixture.Context).SelectionVersion, ExpectedMachineGeneration = generation };
        var outcome = await reader.MeasureAsync(request, None);
        Check.Equal(1, outcome.Answered, "ping qualifié par LDAP uniquement");
        Check.Equal(generation, machine.Generation, "aucune consommation du bail machine");
        Check.Equal(MachineAccountSource.Temporary, machine.Resolve(session, fixture.Computer.DnsHostName).Source, "bail toujours disponible pour la future lecture machine");
    }

    [Test]
    public static async Task A_single_use_collection_returns_a_partial_receipt_and_never_admits_the_next_target_with_fallback()
    {
        using var fixture = new Fixture(); var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single(); await fixture.Import(probe);
        var machine = MachineAccountService.From(fixture.Context); var session = await fixture.Source.GetSessionAsync(None);
        using var secret = PasswordSecrets.FromText("multi-target-query-fixture");
        machine.AcceptTemporary(session, null, @"TEST\once", secret.Copy(), MachineLeaseMode.OneShot);
        var admitted = 0;
        var reader = new AdQueryWorkshopReader(fixture.Source) { InventoryReaderOverride = _ =>
        {
            admitted++;
            return Native((query, _) => query.Contains("DomainRole", StringComparison.Ordinal)
                ? [Row(("Name", "PC1"), ("DNSHostName", "PC1"), ("Domain", "test.local"), ("DomainRole", 1))] : [Row(("Manufacturer", "Valeur qualifiée"))], "String");
        } };
        // No optional account versions: the actual admitted one-shot still prevents a fallback target.
        var request = fixture.Request(probe) with { Computers = [fixture.Computer.ObjectGuid, fixture.Other.ObjectGuid],
            ExpectedIdentities = new[] { fixture.Computer, fixture.Other }.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of) };
        var result = await reader.MeasureAsync(request, None);
        Check.Equal(1, result.Answered, "premier poste réellement qualifié"); Check.Equal(1, result.NotRead, "second poste explicitement non contacté");
        Check.Equal(1, result.Failed, "total demandé conservé sans prétendre la campagne terminée avec succès");
        Check.Equal(1, admitted, "une seule admission physique, aucun compte de repli pour PC2");
        Check.Contains("usage unique", result.StopReason, "motif exploitable par l’UI");
        var data = await reader.DatasetAsync(None);
        Check.Null(data.Probes[fixture.Computer.ObjectGuid].Single().Error, "reçu du premier poste préservé");
        Check.False(data.Probes.TryGetValue(fixture.Other.ObjectGuid, out var untouched) && untouched.Any(p => p.ProbeId == probe.Key), "aucun résultat fabriqué pour la cible non contactée");
    }

    [Test]
    public static async Task A_failed_directory_qualification_after_one_shot_consumption_stops_before_any_fallback_target()
    {
        using var fixture = new Fixture(); var probe = PersonalProbeCatalog.Import(PersonalProbeFixtures.Document()).Single(); await fixture.Import(probe);
        var session = await fixture.Source.GetSessionAsync(None); using var secret = PasswordSecrets.FromText("admission-stop-fixture");
        MachineAccountService.From(fixture.Context).AcceptTemporary(session, null, @"TEST\once", secret.Copy(), MachineLeaseMode.OneShot);
        var admissions = 0; var cim = 0;
        fixture.BeforeDirectoryRead = () => { admissions++; throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Qualification LDAP indisponible dans la fixture."); };
        var reader = new AdQueryWorkshopReader(fixture.Source) { InventoryReaderOverride = _ =>
        { cim++; throw new TestFailureException("CIM ne doit pas être admis après la qualification refusée."); } };
        var request = fixture.Request(probe) with { Computers = [fixture.Computer.ObjectGuid, fixture.Other.ObjectGuid],
            ExpectedIdentities = new[] { fixture.Computer, fixture.Other }.ToImmutableDictionary(c => c.ObjectGuid, QueryComputerIdentity.Of) };
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.MeasureAsync(request, None), "consommation sans propriétaire retenu ne permet jamais un repli");
        Check.Equal(AccountAccess.EpochChanged, error.Code, "changement de génération après l’admission interrompue signalé");
        Check.Equal(1, admissions, "aucune admission du second poste"); Check.Equal(0, cim, "aucun appel CIM");
    }

    private static WmiWorkstationReader Native(Func<string, TimeSpan, IReadOnlyList<WmiInstance>> read, string type) => new(TestClock.Fixed())
    {
        SessionFactory = (host, budget, token) => new(host, budget, TestClock.Fixed(), cancellationToken: token)
        {
            ReadOverride = (_, query, limit) => read(query, limit),
            MetadataOverride = (_, _, _, _) => [Row(("Name", "Name"), ("Type", "String"), ("Key", true)),
                Row(("Name", "Manufacturer"), ("Type", type), ("Key", false)), Row(("Name", "Model"), ("Type", "String"), ("Key", false))],
        },
    };

    private sealed class Fixture : IDisposable
    {
        internal DirectoryComputer Computer { get; } = Fixtures.Computer("PC1");
        internal DirectoryComputer Other { get; } = Fixtures.Computer("PC2");
        internal AdDirectorySource Source { get; }
        internal EngineContext Context { get; }
        internal Action? BeforeDirectoryRead { get; set; }
        internal Fixture()
        {
            var computers = new[] { Computer, Other };
            var cache = new AdQueryNativeTests.QueryCache(Fixtures.Snapshot(computers: [Computer, Other]));
            var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => [.. computers.Where(c => q.BaseDn == c.DistinguishedName).Select(AdPosteNetworkTests.Entry)] };
            Source = new("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: new AdBoundaryTests.RecordingAdConnection(), localStore: cache)
            { AdministrationOverride = AdBoundaryTests.NativeAdministrator,
                ReadConnectionFactory = _ => { BeforeDirectoryRead?.Invoke(); return new AdBoundaryTests.RecordingAdConnection
                { SearchAnswer = q => [.. computers.Where(c => q.BaseDn == c.DistinguishedName).Select(AdPosteNetworkTests.Entry)] }; } };
            Source.AdoptConnection(ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), Source.Epoch, false);
            Context = new(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), Source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
            using var password = new SecureString(); foreach (var c in "fixture-only") { password.AppendChar(c); }
            MachineAccountService.From(Context).UseRemote(@"TEST\probe", password.Copy());
        }
        internal Task Import(params FrozenProbe[] probes) => Context.Preferences.SetAsync(PersonalProbeCatalog.PreferenceKey,
            PersonalProbeCatalog.Merge(PersonalProbeCatalog.Read(null), [.. probes]), None);
        internal QueryMeasureRequest Request(FrozenProbe probe) => new([Computer.ObjectGuid], false, false, false, [probe.Key])
        { PersonalProbes = [probe], ExpectedEpoch = Source.Epoch,
            ExpectedIdentities = ImmutableDictionary<Guid, QueryComputerIdentity>.Empty.Add(Computer.ObjectGuid, QueryComputerIdentity.Of(Computer)) };
        public void Dispose() { Context.Dispose(); Source.Dispose(); }
    }
}
