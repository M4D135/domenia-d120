using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class WorkstationPresenceTests
{
    private static readonly TimeSpan Budget = TimeSpan.FromSeconds(2);
    private static readonly ScopeSelection Scope = new(Fixtures.Postes, "Postes", true);
    private static readonly IPAddress FirstAddress = IPAddress.Parse("192.0.2.10");

    [Test]
    public static async Task Presence_prefers_IPv4_like_v1_but_accepts_IPv6_only_hosts_and_short_domain_names()
    {
        var v6 = IPAddress.Parse("2001:db8::10");
        foreach (var addresses in new[] { new[] { v6, FirstAddress }, new[] { v6 } })
        {
            var resolutions = 0; var echoes = 0;
            var expected = addresses.Contains(FirstAddress) ? FirstAddress : v6;
            var reader = new WorkstationPresenceReader(TestClock.Fixed())
            {
                ResolveOverride = (host, _) => { resolutions++; Check.Equal("PC-DOMAINE", host, "nom court laissé au résolveur Windows"); return Task.FromResult(addresses); },
                EchoOverride = (address, _, _) => { echoes++; Check.Equal(expected, address, "IPv4 prioritaire sans exclure IPv6"); return Task.FromResult(new WorkstationPresenceReader.EchoReply(IPStatus.Success, address)); },
            };
            Check.Equal(true, (await reader.ReadAsync("PC-DOMAINE", Budget, Budget, null, default)).Answered, "réponse reçue");
            Check.Equal(1, resolutions, "une seule résolution"); Check.Equal(1, echoes, "un seul écho");
        }
    }

    [Test]
    public static async Task Presence_queue_does_not_consume_the_target_deadline_or_count_as_a_failed_probe()
    {
        var clock = new Clock(); var capacity = new AdaptiveReadBudget(clock, 1);
        using var held = capacity.Acquire("PC-OCCUPE");
        var resolutions = 0;
        var reader = new WorkstationPresenceReader(clock, adaptive: capacity)
        {
            ResolveOverride = (_, _) => { resolutions++; return Task.FromResult(new[] { FirstAddress }); },
            EchoOverride = (address, allowed, _) => { Check.Equal(Budget, allowed, "budget ICMP entier après la file"); return Task.FromResult(new WorkstationPresenceReader.EchoReply(IPStatus.Success, address)); },
        };
        var reading = reader.ReadAsync("PC-EN-ATTENTE", Budget, Budget, null, default);
        clock.Advance(TimeSpan.FromMinutes(1));
        Check.False(reading.IsCompleted, "la cible reste en attente sans faux timeout");
        Check.Equal(0, resolutions, "aucun DNS avant admission");
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "attente sans ressource physique");
        held.Dispose();
        var result = await reading.WaitAsync(TimeSpan.FromSeconds(5));
        Check.Equal(true, result.Answered, "cible réellement mesurée après libération");
        Check.Equal(1, resolutions, "aucune répétition");
        Check.Equal(0, capacity.Snapshot("PC-EN-ATTENTE").Failures, "aucune erreur de site inventée");
    }

    [Test]
    public static async Task Presence_shares_only_its_address_hint_with_CIM_without_sharing_provider_failures()
    {
        var host = "PC-ISOLATED-" + Guid.NewGuid().ToString("N");
        var address = IPAddress.Parse("198.18.77.10");
        var capacity = new AdaptiveReadBudget(TestClock.Fixed());
        var reader = new WorkstationPresenceReader(TestClock.Fixed(), adaptive: capacity)
        {
            ResolveOverride = (_, _) => Task.FromResult(new[] { address }),
            EchoOverride = (ip, _, _) => Task.FromResult(new WorkstationPresenceReader.EchoReply(IPStatus.Success, ip)),
        };
        await reader.ReadAsync(host, Budget, Budget, null, default);
        Check.Equal("site:198.18.77.0/24", AdaptiveReadBudget.Cim.Snapshot(host).Group, "groupement CIM appris sans DNS supplémentaire");
        using (var provider = AdaptiveReadBudget.Cim.Acquire(host))
            for (var i = 0; i < 3; i++) provider.Report(AdaptiveReadOutcome.Failure, TimeSpan.FromMilliseconds(1));
        Check.Equal("open", AdaptiveReadBudget.Cim.Snapshot(host).State, "échecs CIM réellement isolés");
        Check.Equal(true, (await reader.ReadAsync(host, Budget, Budget, null, default)).Answered, "le ping reste utilisable pendant la suspension CIM");
        Check.Equal("open", AdaptiveReadBudget.Cim.Snapshot(host).State, "un ping réussi ne guérit pas un fournisseur CIM");
    }

    [Test]
    public static async Task Presence_3500_hosts_complete_under_bounded_shared_admission_without_dropping_targets()
    {
        var active = 0; var peak = 0; var resolutions = 0; var echoes = 0;
        var reader = new WorkstationPresenceReader(TimeProvider.System)
        {
            ResolveOverride = async (_, _) =>
            {
                Interlocked.Increment(ref resolutions);
                var count = Interlocked.Increment(ref active);
                int observed; do { observed = Volatile.Read(ref peak); if (observed >= count) break; } while (Interlocked.CompareExchange(ref peak, count, observed) != observed);
                await Task.Yield();
                return [FirstAddress];
            },
            EchoOverride = async (address, _, _) =>
            {
                await Task.Yield();
                Interlocked.Increment(ref echoes); Interlocked.Decrement(ref active);
                return new WorkstationPresenceReader.EchoReply(IPStatus.Success, address);
            },
        };
        var results = new System.Collections.Concurrent.ConcurrentBag<PresenceMeasure>();
        await Parallel.ForEachAsync(Enumerable.Range(0, 3500), new ParallelOptions { MaxDegreeOfParallelism = 16 },
            async (i, token) => results.Add(await reader.ReadAsync("PC-CHARGE-" + i, Budget, Budget, null, token)))
            .WaitAsync(TimeSpan.FromSeconds(30));
        Check.Equal(3500, resolutions, "chaque cible résolue une fois");
        Check.Equal(3500, echoes, "chaque cible sondée une fois, aucune limite à dix");
        Check.True(results.All(r => r.Answered == true), "aucune perte de cible sur saturation locale");
        Check.True(peak is > 1 and <= PhysicalWorkBudget.ReadLimit, "parallélisme borné réellement observé");
        Check.Equal(0, PhysicalWorkBudget.Snapshot().Outstanding, "tous les baux rendus après fin physique");
    }

    [Test]
    public static void Workstation_ping_journal_preserves_unknown_diagnostics_instead_of_certifying_no_reply()
    {
        foreach (var outcome in new[] { PresenceReadOutcome.DnsNotFound, PresenceReadOutcome.NetworkUnavailable, PresenceReadOutcome.DeadlineExceeded })
        {
            var diagnostic = new PresenceDiagnostic(outcome, "test").Text;
            var reading = new PresenceReading(null, null, null, Fixtures.Now, null, false, diagnostic);
            var entry = PosteOperations.PingJournalEntry("PC-TEST", reading, Fixtures.Now);
            Check.Contains(diagnostic, entry.Label, "cause réelle conservée par le producteur du journal poste.ping");
            Check.False(entry.Label.Contains("pas de réponse", StringComparison.Ordinal), "échec technique distinct du silence ICMP");
            Check.Equal(Tone.Warn, entry.Tone, "aucun succès vert pour l’inconnu");
            Check.Equal(Fixtures.Now, entry.At, "date du geste journalisée");
        }
        var blank = new PresenceReading(null, null, null, Fixtures.Now, null, false, "");
        Check.Contains("présence inconnue", PosteOperations.PingJournalEntry("PC-TEST", blank, Fixtures.Now).Label, "inconnu explicite sans diagnostic");
        Check.Contains("pas de réponse ICMP", PosteOperations.PingJournalEntry("PC-TEST", blank with { Answered = false }, Fixtures.Now).Label, "silence réellement achevé");
        var reply = PosteOperations.PingJournalEntry("PC-TEST", blank with { Answered = true, RoundTripMs = 12 }, Fixtures.Now);
        Check.Contains("répond en 12", reply.Label, "latence réelle conservée");
        Check.Equal(Tone.Ok, reply.Tone, "réponse positive seule en succès");
    }

    [Test]
    public static void Workstation_presence_badge_retains_failed_attempt_date_and_cause_without_inventing_a_verdict()
    {
        var detail = new PresenceDiagnostic(PresenceReadOutcome.DnsNotFound, "dns").Text;
        var reading = new PresenceReading(null, null, null, Fixtures.Now, Fixtures.Now.AddDays(-1), false, detail);
        var badge = PosteHeaderRules.Badge(reading, TestClock.Paris, Fixtures.Now);
        Check.Equal(PresenceState.Unknown, badge.State, "une tentative DNS échouée ne prouve ni présence ni absence");
        Check.Equal(Tone.Warn, badge.Tone, "tentative non concluante signalée");
        Check.Equal<DateTimeOffset?>(Fixtures.Now, badge.CheckedAt, "date réelle de tentative conservée");
        Check.Contains(detail, badge.Help, "diagnostic lisible dans le bandeau");
        Check.False(badge.Help.Contains("Aucun test", StringComparison.Ordinal), "ne nie pas le geste réellement effectué");
        Check.Null(badge.RoundTripMs, "pas de latence sans réponse");
        foreach (var absent in new PresenceReading?[] { null, reading with { CheckedAt = null } })
        {
            var untested = PosteHeaderRules.Badge(absent, TestClock.Paris, Fixtures.Now);
            Check.Contains("Aucun test", untested.Help, "absence de tentative distincte d’un échec mesuré");
            Check.Null(untested.CheckedAt, "aucune date inventée");
            Check.Equal(Tone.Off, untested.Tone, "absence de mesure neutre");
        }
        var remembered = PosteHeaderRules.Badge(reading with { Remembered = true }, TestClock.Paris, Fixtures.Now);
        Check.True(remembered.Remembered, "origine mémoire conservée");
        Check.Null(remembered.CheckedAt, "aucune date de session prêtée à la mémoire");
        Check.Contains(detail, remembered.Help, "cause mémorisée conservée");
        Check.Equal(PresenceState.Unknown, remembered.State, "la mémoire n’invente pas de verdict");
    }

    [Test]
    public static async Task Dns_failures_are_unknown_presence_with_a_safe_stage_and_code_without_echo()
    {
        foreach (var (code, outcome, state) in new[]
        {
            (SocketError.HostNotFound, PresenceReadOutcome.DnsNotFound, MeasureState.Error),
            (SocketError.NoData, PresenceReadOutcome.DnsNotFound, MeasureState.Error),
            (SocketError.TryAgain, PresenceReadOutcome.DnsUnavailable, MeasureState.Error),
            (SocketError.TimedOut, PresenceReadOutcome.DnsTimeout, MeasureState.Incomplete),
        })
        {
            var journal = new RecordingJournal();
            var echoes = 0;
            var reader = new WorkstationPresenceReader(TestClock.Fixed(), journal)
            {
                ResolveOverride = (_, _) => Task.FromException<IPAddress[]>(new SocketException((int)code)),
                EchoOverride = (_, _, _) => { echoes++; throw new InvalidOperationException("DNS must succeed before echo."); },
            };
            var measure = await reader.ReadAsync("private-target.test.local", Budget, Budget, Fixtures.Now.AddDays(-1), CancellationToken.None);
            Check.Equal(0, echoes, "aucun ICMP envoyé après échec DNS");
            Check.Equal(state, measure.State, "échec distinct d’une réponse négative");
            Check.Null(measure.Answered, "aucun booléen hors ligne inventé");
            Check.False(measure.HasReading, "pas de mesure réussie");
            Check.Equal(Fixtures.Now.AddDays(-1), measure.LastOnlineAt, "dernière présence confirmée préservée");
            Check.Equal(new PresenceDiagnostic(outcome, "dns", (int)code), measure.Diagnostic, "cause fermée et code conservés");
            Check.Equal(1, journal.Lines.Count, "une trace de la cause réelle");
            Check.False(journal.Lines.Any(line => line.Contains("private-target", StringComparison.Ordinal) || line.Contains(FirstAddress.ToString(), StringComparison.Ordinal)), "aucun nom ni adresse dans la trace");
        }
    }

    [Test]
    public static async Task Invalid_and_unusable_targets_send_no_echo_and_do_not_fall_back()
    {
        var resolutions = 0; var echoes = 0;
        var reader = new WorkstationPresenceReader(TestClock.Fixed())
        {
            ResolveOverride = (_, _) => { resolutions++; return Task.FromResult(new[] { IPAddress.Any, FirstAddress }); },
            EchoOverride = (_, _, _) => { echoes++; throw new InvalidOperationException("No usable address."); },
        };
        var invalid = await reader.ReadAsync("bad target", Budget, Budget, null, CancellationToken.None);
        Check.Equal(PresenceReadOutcome.InvalidTarget, invalid.Diagnostic!.Outcome, "syntaxe refusée avant DNS");
        Check.Equal(0, resolutions, "aucune résolution d’une cible invalide");
        var unusable = await reader.ReadAsync("pc.test.local", Budget, Budget, null, CancellationToken.None);
        Check.Equal(PresenceReadOutcome.AddressUnavailable, unusable.Diagnostic!.Outcome, "adresse non utilisable explicite");
        Check.Equal(1, resolutions, "une seule résolution");
        Check.Equal(0, echoes, "aucun essai sur une adresse de remplacement");
        var empty = new WorkstationPresenceReader(TestClock.Fixed()) { ResolveOverride = (_, _) => Task.FromResult(Array.Empty<IPAddress>()) };
        Check.Equal(PresenceReadOutcome.AddressUnavailable, (await empty.ReadAsync("pc.test.local", Budget, Budget, null, CancellationToken.None)).Diagnostic!.Outcome, "ensemble DNS vide distinct d’un timeout ICMP");
    }

    [Test]
    public static async Task Icmp_reply_timeout_and_transport_error_have_different_measurements()
    {
        foreach (var (status, outcome, answered) in new[]
        {
            (IPStatus.Success, PresenceReadOutcome.Reply, (bool?)true),
            (IPStatus.TimedOut, PresenceReadOutcome.NoReply, (bool?)false),
            (IPStatus.DestinationHostUnreachable, PresenceReadOutcome.NetworkUnavailable, (bool?)null),
            (IPStatus.BadDestination, PresenceReadOutcome.AddressUnavailable, (bool?)null),
            (IPStatus.Unknown, PresenceReadOutcome.IcmpError, (bool?)null),
        })
        {
            var echoes = 0;
            var reader = new WorkstationPresenceReader(TestClock.Fixed())
            {
                ResolveOverride = (_, _) => throw new InvalidOperationException("Literal address must not use DNS."),
                EchoOverride = (address, _, _) => { echoes++; Check.Equal(FirstAddress, address, "adresse unique"); return Task.FromResult(new WorkstationPresenceReader.EchoReply(status, FirstAddress)); },
            };
            var measure = await reader.ReadAsync(FirstAddress.ToString(), Budget, Budget, Fixtures.Now.AddDays(-1), CancellationToken.None);
            Check.Equal(1, echoes, "un seul écho, sans réessai");
            Check.Equal(answered, measure.Answered, "réponse ICMP distincte d’une erreur technique");
            Check.Equal(answered is not null, measure.HasReading, "seul un résultat ICMP achevé fournit un booléen");
            Check.Equal(outcome, measure.Diagnostic!.Outcome, "cause conservée");
            Check.Equal(answered == true ? Fixtures.Now : Fixtures.Now.AddDays(-1), measure.LastOnlineAt, "seule une réponse actualise la dernière présence");
        }
    }

    [Test]
    public static async Task Wrapped_socket_failure_does_not_become_no_reply_or_try_a_second_address()
    {
        var resolutions = 0; var echoes = 0;
        var reader = new WorkstationPresenceReader(TestClock.Fixed())
        {
            ResolveOverride = (_, _) => { resolutions++; return Task.FromResult(new[] { FirstAddress, IPAddress.Parse("192.0.2.11") }); },
            EchoOverride = (address, _, _) =>
            {
                echoes++; Check.Equal(FirstAddress, address, "choix initial du système conservé");
                return Task.FromException<WorkstationPresenceReader.EchoReply>(new PingException("private native message", new SocketException((int)SocketError.NetworkUnreachable)));
            },
        };
        var measure = await reader.ReadAsync("pc.test.local", Budget, Budget, null, CancellationToken.None);
        Check.Equal(1, resolutions, "une seule résolution"); Check.Equal(1, echoes, "aucune seconde adresse");
        Check.Equal(new PresenceDiagnostic(PresenceReadOutcome.NetworkUnavailable, "icmp", (int)SocketError.NetworkUnreachable), measure.Diagnostic, "étape et code de transport conservés");
        Check.Equal(MeasureState.Error, measure.State, "échec technique"); Check.Null(measure.Answered, "aucune absence déduite");
    }

    [Test]
    public static async Task Dns_and_echo_deadlines_discard_late_results_without_restarting_the_budget()
    {
        var clock = new Clock(); var echoes = 0;
        var lateDns = new WorkstationPresenceReader(clock)
        {
            ResolveOverride = (_, _) => { clock.Advance(Budget); return Task.FromResult(new[] { FirstAddress }); },
            EchoOverride = (_, _, _) => { echoes++; throw new InvalidOperationException("DNS exhausted the budget."); },
        };
        var dns = await lateDns.ReadAsync("pc.test.local", Budget, Budget, null, CancellationToken.None);
        Check.Equal(PresenceReadOutcome.DnsTimeout, dns.Diagnostic!.Outcome, "budget consommé pendant DNS"); Check.Equal(0, echoes, "aucun ICMP après expiration");
        var lateEcho = new WorkstationPresenceReader(clock)
        {
            ResolveOverride = (_, _) => { clock.Advance(TimeSpan.FromMilliseconds(500)); return Task.FromResult(new[] { FirstAddress }); },
            EchoOverride = (_, remaining, _) =>
            {
                Check.Equal(TimeSpan.FromMilliseconds(1500), remaining, "DNS consomme le budget total");
                clock.Advance(remaining); return Task.FromResult(new WorkstationPresenceReader.EchoReply(IPStatus.Success, FirstAddress));
            },
        };
        var echo = await lateEcho.ReadAsync("pc.test.local", Budget, Budget, null, CancellationToken.None);
        Check.Equal(PresenceReadOutcome.DeadlineExceeded, echo.Diagnostic!.Outcome, "réponse tardive non publiée comme succès");
        Check.Equal(MeasureState.Incomplete, echo.State, "résultat hors budget incomplet"); Check.Null(echo.Answered, "aucune réponse inventée");
    }

    [Test]
    public static async Task Operator_cancellation_is_propagated_without_a_failure_measurement()
    {
        using var stop = new CancellationTokenSource();
        var journal = new RecordingJournal();
        var reader = new WorkstationPresenceReader(TestClock.Fixed(), journal)
        {
            ResolveOverride = (_, token) => { stop.Cancel(); token.ThrowIfCancellationRequested(); return Task.FromResult(new[] { FirstAddress }); },
        };
        await Check.ThrowsAsync<OperationCanceledException>(() => reader.ReadAsync("pc.test.local", Budget, Budget, null, stop.Token), "annulation de l’opérateur propagée");
        Check.Equal(0, journal.Lines.Count, "aucune erreur réseau supposée après arrêt");
    }

    [Test]
    public static async Task Home_keeps_failed_presence_and_skipped_inventory_without_erasing_dated_data()
    {
        var computer = Fixtures.Computer("PC");
        var old = Fixtures.Observe(computer, Fixtures.Presence(true, TimeSpan.FromMinutes(5)), Fixtures.Disk(100, 40, TimeSpan.FromDays(1)));
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [computer]));
        cache.Fleet = cache.Fleet.Merge(FleetCachePatch.Empty with { Observations = new(Fixtures.Now.AddMinutes(-5), [old]) });
        // A transient cause: the DNS server did not answer. The definitive « name absent from DNS » has its own test below.
        var probe = new FailedPresenceProbe(PresenceReadOutcome.DnsUnavailable);
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var ping = await source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None);
        Check.Null(ping.Observations.Workstations.Single().Presence.Answered, "échec transport non converti en poste hors ligne");
        Check.True(ping.Journal.Any(j => j.Tone == Tone.Warn && j.Label.Contains("1 lecture non confirmée", StringComparison.Ordinal)), "relevé non annoncé réussi, accord au singulier");
        var inventoryState = await source.RefreshAsync(MeasureFamily.Inventory, Scope, CancellationToken.None);
        Check.Equal(2, probe.Calls, "les deux demandes explicites utilisent le contrat qualifié");
        var stored = cache.Fleet.Observations.Workstations.Single();
        Check.Equal(old.Presence.LastOnlineAt, stored.Presence.LastOnlineAt, "dernière réponse conservée");
        Check.Equal(old.Inventory, stored.Inventory, "inventaire âgé d’un jour conservé malgré l’échec du préalable");
        Check.Equal(Fixtures.Now.AddDays(-1), stored.Inventory.CheckedAt, "aucun rafraîchissement fictif de la date d’inventaire");
        Check.Equal(MeasureState.NotRead, cache.Fleet.Facts.Machines[computer.ObjectGuid].WmiState, "inventaire non envoyé explicite");
        Check.Contains("Inventaire non envoyé", cache.Fleet.Facts.Machines[computer.ObjectGuid].WmiError, "préalable absent expliqué");
        var board = FleetBoardCalculator.Compute(new(inventoryState, Scope, Fixtures.Root, "test.local", HealthPolicyBook.Empty(Fixtures.Root),
            cache.Fleet.Facts, null, cache.Fleet.Probes, FleetCatalog.DefaultLayout(), [], Fixtures.Now, TimeZoneInfo.Utc));
        Check.Equal("WMI non relevé", board.Board.Entries["fleet.wmi"].Value, "la tentative non envoyée ne devient pas un succès WMI dans la synthèse");
        Check.False(board.Board.Entries["fleet.wmi"].Items.Any(part => part.Label == "WMI a répondu"), "aucun secteur vert inventé");
        Check.Equal(old.Inventory.Model, board.Rows[computer.ObjectGuid].Model, "modèle historique utile toujours visible");
        Check.Equal<double?>(40, board.Rows[computer.ObjectGuid].DiskFree, "disque historique conservé dans la même synthèse");
    }

    [Test]
    public static async Task Home_names_a_name_absent_from_dns_as_a_result_never_as_an_unconfirmed_reading()
    {
        var computer = Fixtures.Computer("PC");
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [computer]));
        var probe = new FailedPresenceProbe();
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), probe, ldap, cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var ping = await source.RefreshAsync(MeasureFamily.Presence, Scope, CancellationToken.None);
        var entry = ping.Journal.First(j => j.Label.StartsWith("Présence mesurée", StringComparison.Ordinal));
        Check.Contains("1 nom absent du DNS" + FrenchText.Colon + "aucun test ICMP envoyé, présence inconnue.", entry.Label, "réponse définitive du DNS nommée");
        Check.False(entry.Label.Contains("non confirmée", StringComparison.Ordinal), "un nom absent du DNS n’est pas une lecture non confirmée");
        Check.Equal(Tone.Info, entry.Tone, "aucun avertissement pour une réponse définitive");
        var measure = ping.Observations.Workstations.Single().Presence;
        Check.Null(measure.Answered, "présence toujours inconnue, jamais « sans réponse »");
        Check.False(CollectionNetworkPolicy.Eligible(measure, true), "jamais admissible à WMI, même avec la lecture sans écho");
        Check.True(PresenceOutcomes.Definitive(measure, Fixtures.Now), "classement définitif partagé");
    }

    [Test]
    public static void Presence_outcomes_are_classified_once_and_named_by_the_resolver_answer()
    {
        foreach (var outcome in Enum.GetValues<PresenceReadOutcome>())
        {
            var reading = outcome is PresenceReadOutcome.Reply or PresenceReadOutcome.NoReply;
            Check.True(reading ^ (PresenceOutcomes.IsDefinitive(outcome) ^ PresenceOutcomes.IsTransient(outcome)), "un seul classement pour " + outcome);
        }
        Check.True(PresenceOutcomes.IsDefinitive(PresenceReadOutcome.DnsNotFound) && PresenceOutcomes.IsDefinitive(PresenceReadOutcome.InvalidTarget), "nom absent ou invalide : définitif");
        PresenceMeasure Error(PresenceReadOutcome outcome, string stage, int? code, MeasureState state = MeasureState.Error) =>
            new(state, null, Fixtures.Now, null) { Diagnostic = new(outcome, stage, code) };
        var absent = Error(PresenceReadOutcome.DnsNotFound, "dns", (int)SocketError.HostNotFound);
        var noAddress = Error(PresenceReadOutcome.DnsNotFound, "dns", (int)SocketError.NoData);
        var invalid = Error(PresenceReadOutcome.InvalidTarget, "target", null);
        var timeout = Error(PresenceReadOutcome.DnsTimeout, "dns", null, MeasureState.Incomplete);
        Check.True(PresenceOutcomes.Settled(absent, Fixtures.Now) && PresenceOutcomes.Settled(invalid, Fixtures.Now), "réponse définitive datée : rien à redemander");
        Check.False(PresenceOutcomes.Settled(absent, Fixtures.Now.AddSeconds(1)), "réponse définitive plus ancienne que le relevé : à mesurer");
        Check.False(PresenceOutcomes.Settled(timeout, Fixtures.Now), "délai DNS : à reprendre");
        Check.Equal("1 nom absent du DNS · 1 nom sans adresse dans le DNS · 1 nom de poste invalide", PresenceOutcomes.DefinitiveText([absent, noAddress, invalid, timeout]), "réponses définitives nommées");
        Check.Equal("2 noms absents du DNS", PresenceOutcomes.DefinitiveText([absent, absent]), "pluriel");
        Check.Equal("délai DNS dépassé", PresenceOutcomes.Cause(timeout, Fixtures.Now), "cause transitoire nommée");
        Check.Equal("aucun résultat pour ce relevé", PresenceOutcomes.Cause(PresenceMeasure.Unread, Fixtures.Now), "aucune cause inventée sans tentative datée");
        Check.Equal("cause non enregistrée", PresenceOutcomes.Cause(new(MeasureState.Error, null, Fixtures.Now, null), Fixtures.Now), "tentative datée sans diagnostic");
        var search = SearchTexts.Presence(absent, Fixtures.Now);
        Check.Equal(SearchPresenceState.Error, search.State, "Recherche : état et filtre d’erreur conservés (RCH-092)");
        Check.Equal("Nom absent du DNS", search.Label, "Recherche : réponse du DNS nommée");
        Check.Contains("aucun test ICMP envoyé", search.Detail, "Recherche : aucun écho supposé");
        Check.Equal("Nom de poste invalide", SearchTexts.Presence(invalid, Fixtures.Now).Label, "Recherche : nom invalide, pas « Erreur de ping »");
        Check.Equal("Résolution DNS en erreur", SearchTexts.Presence(Error(PresenceReadOutcome.DnsUnavailable, "dns", (int)SocketError.TryAgain), Fixtures.Now).Label, "Recherche : erreur DNS transitoire inchangée");
        var unknown = SearchTexts.Presence(new(MeasureState.Error, null, Fixtures.Now, null), Fixtures.Now);
        Check.False(unknown.Detail.Contains("sonde en erreur", StringComparison.Ordinal) || unknown.Detail.Contains("non résolu", StringComparison.Ordinal), "Recherche : aucune cause supposée sans diagnostic");
    }

    [Test]
    public static async Task Provenance_and_fleet_board_name_each_definitive_answer_and_keep_a_DNS_error_in_error()
    {
        // 2.0.7 counted these four workstations « 4 en erreur »: only the unavailable DNS (transient) is still an error.
        static PresenceMeasure Failed(PresenceReadOutcome outcome, string stage, int? code) => new(MeasureState.Error, null, Fixtures.Now, null) { Diagnostic = new(outcome, stage, code) };
        (DirectoryComputer Computer, PresenceMeasure Presence)[] hosts =
        [
            (Fixtures.Computer("PC-ABSENT"), Failed(PresenceReadOutcome.DnsNotFound, "dns", (int)SocketError.HostNotFound)),
            (Fixtures.Computer("PC-SANS-ADRESSE"), Failed(PresenceReadOutcome.DnsNotFound, "dns", (int)SocketError.NoData)),
            (Fixtures.Computer("PC-INVALIDE"), Failed(PresenceReadOutcome.InvalidTarget, "target", null)),
            (Fixtures.Computer("PC-DNS"), Failed(PresenceReadOutcome.DnsUnavailable, "dns", (int)SocketError.TryAgain)),
        ];
        var source = new HomePipelineSource();
        source.Current = source.Current with
        {
            Directory = source.Current.Directory with { Computers = [.. hosts.Select(h => h.Computer)] },
            Observations = new(Fixtures.Now, [.. hosts.Select(h => Fixtures.Observe(h.Computer, h.Presence))]),
        };
        using var context = source.Context();
        var ping = (await AccueilService.From(context).ProvenanceAsync(CancellationToken.None)).Ping;
        Check.Equal("dnsAbsent=1 dnsNoAddress=1 error=1 invalidName=1", string.Join(" ", ping.States.Select(s => s.Key + "=" + FrenchText.Integer(s.Value))),
            "une clé par réponse définitive, l’erreur DNS reste « error »");
        const string reasons = "1 en erreur, 1 nom absent du DNS, 1 nom sans adresse dans le DNS, 1 nom de poste invalide";
        Check.Equal(reasons, CollectionClocks.StatesText(ping.States), "raisons nommées, dans l’ordre des clés");
        Check.Contains(reasons, ping.Text, "provenance : réponses du DNS nommées");
        var board = FleetBoardCalculator.Compute(new(source.Current, Scope, Fixtures.Root, "test.local", HealthPolicyBook.Empty(Fixtures.Root),
            AccueilFacts.Empty(HomePipelineSource.StoreId), null, ProbeReadings.Empty, FleetCatalog.DefaultLayout(), [], Fixtures.Now, TimeZoneInfo.Utc));
        Check.Equal("0 poste analysé sur 4 · sans mesure ping utilisable" + FrenchText.Colon + reasons, board.Board.Entries["fleet.presence"].Detail, "tableau du parc : mêmes raisons");
    }

    [Test]
    public static async Task Search_keeps_the_diagnostic_and_does_not_collect_after_failed_presence()
    {
        var pc = Fixtures.Computer("PC");
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        await source.DomainAsync(CancellationToken.None);
        await source.RememberObjectsAsync(Fixtures.Snapshot(computers: [pc]) with { Complete = false }, source.Epoch, CancellationToken.None);
        var failed = FailedPresenceProbe.Failure(null);
        var reader = new AdSearchReader(source)
        {
            EchoOverride = (_, _) => Task.FromResult(failed),
            InventoryOverride = (_, _) => throw new InvalidOperationException("Inventory must not be contacted."),
        };
        var outcome = await reader.ProbeAsync(pc.ObjectGuid, SurveyMode.Complete, 1, TimeSpan.Zero, CancellationToken.None);
        Check.False(outcome.Confirmed == true, "aucun faux succès de collecte");
        Check.Equal(SearchPresenceState.Error, outcome.Presence.State, "erreur distincte de sans réponse");
        Check.Equal(failed.Diagnostic!.Text, outcome.Detail, "cause utile transmise à la recherche");
        Check.Equal(failed, source.CurrentObservations.Workstations.Single().Presence, "diagnostic enregistré dans la source locale");
        Check.False(source.FleetDetails.Inventories.ContainsKey(pc.ObjectGuid), "aucune donnée d’inventaire inventée");
        Check.Equal(MeasureState.NotRead, source.FleetDetails.Facts.Machines[pc.ObjectGuid].WmiState, "tentative non envoyée visible après relecture locale");
    }

    [Test]
    public static async Task Confirmed_diagnostic_identity_is_checked_by_the_native_reader_before_dns_or_echo()
    {
        var pc = Fixtures.Computer("PC");
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var contacts = 0;
        var reader = new AdSearchReader(source)
        {
            DiagnosticDnsOverride = (_, _) => { contacts++; throw new InvalidOperationException("Identité non confirmée avant DNS."); },
            EchoOverride = (_, _) => throw new InvalidOperationException("Aucun écho autorisé."),
        };
        var expected = NetworkDiagnosticIdentity.Capture(pc)!;
        Check.NotNull(expected, "identité locale qualifiée");
        Check.False(expected.Matches(pc with { UserAccountControl = pc.UserAccountControl | AdValues.AccountDisabled }), "désactivation depuis la confirmation refusée");
        foreach (var altered in new[] { expected with { Host = "other.test.local" }, expected with { Sid = "S-1-5-21-1-2-3-9999" },
            expected with { Sam = "OTHER$" }, expected with { Created = expected.Created.AddSeconds(1) } })
        {
            var error = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.DiagnoseAsync(altered, default), "identité modifiée refusée au dernier lecteur");
            Check.Equal(SearchErrors.SurveyRefused, error.Code, "motif de confirmation obsolète");
        }
        Check.Equal(0, contacts, "aucun contact pour une cible différente");
    }

    [Test]
    public static async Task Network_diagnostic_explains_dns_failure_without_testing_ports_or_claiming_a_silent_echo()
    {
        var pc = Fixtures.Computer("PC");
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        foreach (var (code, text) in new[] { (SocketError.HostNotFound, "non résolu"), (SocketError.TryAgain, "DNS en erreur"), (SocketError.TimedOut, "DNS dépassé") })
        {
            var reader = new AdSearchReader(source)
            {
                DiagnosticDnsOverride = (_, _) => Task.FromException<IPAddress[]>(new SocketException((int)code)),
                EchoOverride = (_, _) => throw new InvalidOperationException("No echo after failed DNS."),
            };
            var result = await reader.DiagnoseAsync(pc.ObjectGuid, CancellationToken.None);
            Check.Contains(text, result.Summary, "cause DNS précise");
            Check.True(result.Ports.All(p => p.State == "untested"), "aucun port testé après échec DNS");
            Check.False(result.Ping.State == SearchPresenceState.NoReply, "aucun faux silence ICMP");
        }
    }

    [Test]
    public static async Task Presence_diagnostic_survives_sqlite_reopen_and_replaces_no_reply_without_losing_history()
    {
        using var folder = new TemporaryFolder();
        var pc = Fixtures.Computer("PC");
        var db = new DomeniaDatabase(folder.File("presence.db"), Fixtures.Root, TestClock.Fixed());
        await db.InitializeAsync(CancellationToken.None);
        await db.SaveDirectoryAsync(Guid.NewGuid().ToString("D"), Fixtures.Snapshot(computers: [pc]), Scope, null, CancellationToken.None);
        var lastOnline = Fixtures.Now.AddDays(-1);
        var old = Fixtures.Observe(pc, Fixtures.Presence(false, TimeSpan.FromMinutes(1), lastOnline));
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now.AddMinutes(-1), [old]) }, CancellationToken.None);
        var measure = FailedPresenceProbe.Failure(lastOnline);
        await db.SaveFleetAsync(FleetCachePatch.Empty with { Observations = new(Fixtures.Now, [old with { Presence = measure }]) }, CancellationToken.None);
        var reopened = new DomeniaDatabase(db.Path, Fixtures.Root, TestClock.Fixed());
        var stored = (await reopened.ReadFleetAsync(CancellationToken.None)).Observations.Workstations.Single().Presence;
        Check.Equal(measure, stored, "état, diagnostic, code et dates relus après réouverture SQLite");
        Check.False(stored.HasReading, "l’erreur ne devient pas une réponse négative à la relecture");
        Check.Equal(lastOnline, stored.LastOnlineAt, "histoire de présence préservée");
    }

    [Test]
    public static async Task Fiche_and_workstation_keep_dns_failure_unknown_and_workstation_keeps_success_latency()
    {
        var pc = Fixtures.Computer("PC");
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var native = new WorkstationPresenceReader(source.Clock)
        { ResolveOverride = (_, _) => Task.FromException<IPAddress[]>(new SocketException((int)SocketError.HostNotFound)) };
        var fiche = await new AdFicheReader(source) { PresenceReaderOverride = native }.PingAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal("unknown", fiche.State, "fiche : erreur DNS jamais hors ligne");
        Check.Contains("non résolu", fiche.Detail, "fiche : cause lisible");
        var poste = await new AdPosteReader(source) { PresenceReaderOverride = native }.PingAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Null(poste.Answered, "poste : erreur DNS jamais sans réponse");
        Check.Null(poste.RoundTripMs, "pas de latence inventée");
        Check.Contains("non résolu", poste.Source, "poste : cause lisible");
        Check.Equal(PresenceReadOutcome.DnsNotFound, cache.Fleet.Observations.Workstations.Single().Presence.Diagnostic!.Outcome, "diagnostic conservé par les deux consommateurs");
        var success = new WorkstationPresenceReader(source.Clock)
        {
            ResolveOverride = (_, _) => Task.FromResult(new[] { FirstAddress }),
            EchoOverride = (_, _, _) => Task.FromResult(new WorkstationPresenceReader.EchoReply(IPStatus.Success, FirstAddress, 12)),
        };
        poste = await new AdPosteReader(source) { PresenceReaderOverride = success }.PingAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal<int?>(12, poste.RoundTripMs, "latence réelle conservée");
        Check.Equal(FirstAddress.ToString(), poste.Address, "adresse de réponse réelle conservée pour l’affichage");
        Check.Equal(true, poste.Answered, "réponse positive qualifiée");
    }

    [Test]
    public static async Task A_standard_account_pings_from_fiche_workstation_and_search_without_administration()
    {
        // ICMP and DNS carry no credential: an account outside Domain Admins measures presence (David, 09/11/2026).
        var standard = new AdministrationIdentity(AdministrationIdentityState.Standard, "Lecture AD seule.");
        var pc = Fixtures.Computer("PC");
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = standard };
        var echoes = 0;
        var success = new WorkstationPresenceReader(source.Clock)
        {
            ResolveOverride = (_, _) => Task.FromResult(new[] { FirstAddress }),
            EchoOverride = (_, _, _) => { echoes++; return Task.FromResult(new WorkstationPresenceReader.EchoReply(IPStatus.Success, FirstAddress, 12)); },
        };
        var fiche = await new AdFicheReader(source) { PresenceReaderOverride = success }.PingAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal("online", fiche.State, "fiche : ping sans compte d’administration");
        var poste = await new AdPosteReader(source) { PresenceReaderOverride = success }.PingAsync(pc.DistinguishedName, CancellationToken.None);
        Check.Equal(true, poste.Answered, "poste : ping sans compte d’administration");
        Check.Equal(2, echoes, "un écho par demande");

        using var searchLdap = new AdBoundaryTests.RecordingAdConnection();
        using var searchSource = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: searchLdap) { AdministrationOverride = standard };
        await searchSource.DomainAsync(CancellationToken.None);
        await searchSource.RememberObjectsAsync(Fixtures.Snapshot(computers: [pc]) with { Complete = false }, searchSource.Epoch, CancellationToken.None);
        var searchEchoes = 0;
        var search = new AdSearchReader(searchSource)
        { EchoOverride = (_, _) => { searchEchoes++; return Task.FromResult(new PresenceMeasure(MeasureState.Known, true, Fixtures.Now, Fixtures.Now)); } };
        await search.ProbeAsync(pc.ObjectGuid, SurveyMode.Ping, 1, TimeSpan.Zero, CancellationToken.None);
        Check.Equal(1, searchEchoes, "recherche : écho sans compte d’administration");
        Check.True(searchSource.CurrentObservations.Workstations.Single().Presence.Answered == true, "recherche : présence enregistrée");
    }

    [Test]
    public static async Task Workshop_counts_unmeasured_presence_as_failure_and_retains_its_diagnostic()
    {
        var pc = Fixtures.Computer("PC");
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var reader = new AdQueryWorkshopReader(source)
        {
            PresenceReaderOverride = new(source.Clock) { ResolveOverride = (_, _) => Task.FromException<IPAddress[]>(new SocketException((int)SocketError.HostNotFound)) },
            InventoryReaderOverride = _ => throw new InvalidOperationException("No inventory requested."),
        };
        var result = await reader.MeasureAsync(new([pc.ObjectGuid], true, false, false, []), CancellationToken.None);
        Check.Equal(0, result.Answered, "aucune collecte réussie supposée");
        Check.Equal(1, result.Failed, "échec de présence compté");
        var measure = cache.Fleet.Observations.Workstations.Single().Presence;
        Check.Null(measure.Answered, "pas de faux état hors ligne dans l’atelier");
        Check.Equal(PresenceReadOutcome.DnsNotFound, measure.Diagnostic!.Outcome, "cause conservée malgré le bilan en échec");
    }

    [Test]
    public static async Task Workshop_campaign_outcome_skips_global_dataset_rebuild_but_normal_calls_keep_their_version()
    {
        var pc = Fixtures.Computer("PC");
        var cache = new AdPosteNetworkTests.Cache(Fixtures.Snapshot(computers: [pc]));
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = q => q.BaseDn == pc.DistinguishedName ? [AdPosteNetworkTests.Entry(pc)] : [] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\test", TestClock.Fixed(), connection: ldap, localStore: cache) { AdministrationOverride = AdBoundaryTests.NativeAdministrator };
        var datasets = 0; var pings = 0;
        var reader = new AdQueryWorkshopReader(source)
        {
            PingOverride = (_, _) => { pings++; return Task.FromResult(true); },
            DatasetReadObserved = () => datasets++,
        };
        var campaign = await reader.MeasureAsync(new([pc.ObjectGuid], true, false, false, []) { OnlyOutcome = true }, CancellationToken.None);
        Check.Equal(1, campaign.Answered, "lecture réelle qualifiée et conservée");
        Check.Equal(0, datasets, "aucun dataset global après ce poste");
        Check.Equal(0L, campaign.Version, "version non demandée explicitement nulle, jamais un reçu");
        var normal = await reader.MeasureAsync(new([pc.ObjectGuid], true, false, false, []), CancellationToken.None);
        Check.Equal(1, datasets, "contrat normal conserve son recalcul global");
        Check.Equal((await reader.DatasetAsync(CancellationToken.None)).Version, normal.Version, "version normale provient bien du dataset");
        Check.Equal(2, pings, "un ping pour chaque demande, aucun contact ajouté par les compteurs");
    }

    [Test]
    public static async Task Relation_loop_distinguishes_silent_echo_from_dns_failure_and_never_reads_their_console()
    {
        var names = new[] { "PC1", "PC2", "PC3" };
        var plan = new RelationDetectionPlan("p", true, "candidates", "postes connus", null, 50, 3, false,
            [.. names.Select(name => new RelationPlanTarget(Fixtures.IdOf(name).ToString("D"), name, "CN=" + name + "," + Fixtures.Postes, "test"))], "", "", "", null);
        var read = new List<string>();
        var result = await RelationProbeLoop.RunQualifiedAsync(plan,
            (target, _) => { read.Add(target.Computer); return Task.FromResult(new RelationConsoleOutcome("LU", "Aucun compte", "Console lue vide", null, 1)); },
            (target, _) => Task.FromResult(target.Computer == "PC1" ? FailedPresenceProbe.Failure(null) : Fixtures.Presence(target.Computer == "PC3", TimeSpan.Zero)),
            null, CancellationToken.None, CancellationToken.None);
        Check.Equal("PC3", string.Join(',', read), "console uniquement après présence positive");
        Check.Equal(1, result.PingFailures, "seul l’écho expiré est compté muet");
        var failed = result.Steps.Single(s => s.Target.Computer == "PC1");
        Check.True(failed.PingUnconfirmed, "erreur DNS explicitement non confirmée"); Check.False(failed.PingFailed, "pas de silence ICMP supposé");
        Check.Equal("ERREUR", failed.Outcome.Status, "erreur distincte du délai d’écho");
        Check.Contains("non résolu", failed.Outcome.Detail, "cause conservée");
        Check.False(result.Complete, "aucun faux succès de détection");
    }

    [Test]
    public static void Presence_keys_are_six_stable_tokens_whose_labels_stay_separate()
    {
        Check.Equal(6, PresenceKeys.All.Length, "le jeu décrit de six clés, dans un seul modèle");
        Check.Equal("Online,NoReply,Error,Pending,Unknown,None", string.Join(',', PresenceKeys.All), "ordre d’affichage fixe");
        Check.Equal(6, PresenceKeys.All.Select(PresenceKeys.Key).Distinct().Count(), "une clé par jeton, sans doublon");
        Check.Equal("online,noReply,error,pending,unknown,none", string.Join(',', PresenceKeys.All.Select(PresenceKeys.Key)), "jetons stables déjà écrits par la console et les filtres");
        Check.Equal(6, PresenceKeys.All.Select(PresenceKeys.Label).Distinct().Count(), "un libellé par clé");
        foreach (var key in PresenceKeys.All)
        {
            Check.False(PresenceKeys.Label(key).Equals(PresenceKeys.Key(key), StringComparison.OrdinalIgnoreCase), "le libellé n’est jamais la clé : il peut changer sans changer le sens");
            Check.True(PresenceKeys.TryKey(PresenceKeys.Key(key), out var parsed) && parsed == key, "aller-retour du jeton de " + key);
        }
        Check.False(PresenceKeys.TryKey("sans reponse", out _), "un libellé stocké n’est pas un jeton de clé");
        Check.False(PresenceKeys.TryKey("", out _), "rien d’écrit ne désigne une clé");
        Check.True(PresenceKeys.TryKey("NO_REPLY", out var tolerant) && tolerant == PresenceKey.NoReply, "jeton retrouvé sans casse ni soulignement");
    }

    [Test]
    public static void Presence_keys_read_the_stored_labels_of_every_page_including_pending_none_and_memory()
    {
        Check.Equal(PresenceKey.Online, PresenceKeys.FromStored("En ligne"), "libellé stocké du tableau de bord");
        Check.Equal(PresenceKey.NoReply, PresenceKeys.FromStored("Sans réponse"), "libellé stocké du tableau de bord");
        Check.Equal(PresenceKey.Unknown, PresenceKeys.FromStored("Non vérifié"), "libellé stocké du tableau de bord");
        Check.Equal(PresenceKey.Pending, PresenceKeys.FromStored("en attente"), "test pas encore rendu");
        Check.Equal(PresenceKey.Error, PresenceKeys.FromStored("ERREUR DE PING"), "erreur rendue sans casse ni accent");
        Check.Equal(PresenceKey.None, PresenceKeys.FromStored(null), "rien de stocké : aucune présence à rendre");
        Check.Equal(PresenceKey.None, PresenceKeys.FromStored("   "), "blancs seuls : aucune présence à rendre");
        Check.Equal(PresenceKey.None, PresenceKeys.FromStored("non applicable"), "cible sans présence possible");
        Check.Equal(PresenceKey.Online, PresenceKeys.FromStored("Répond au ping (mémoire)"), "une mémoire garde le verdict qu’elle porte");
        Check.True(PresenceKeys.IsRemembered("Répond au ping (mémoire)"), "la marque mémoire est reconnue");
        Check.True(PresenceKeys.IsRemembered("remembered"), "jeton anglais de la mémoire");
        Check.False(PresenceKeys.IsRemembered("Sans réponse"), "une lecture du jour n’est pas une mémoire");
        Check.Equal(PresenceKey.Unknown, PresenceKeys.FromStored("(mémoire)"), "la mémoire n’invente pas de verdict");
        Check.Equal(PresenceKey.Unknown, PresenceKeys.FromStored("un libellé qu’aucune page n’a écrit"), "un texte inconnu reste non vérifié, jamais « en ligne »");
        Check.Equal(PresenceKey.NoReply, PresenceKeys.FromStored("Sans réponse au ping"), "libellé de la liste de recherche");
    }

    [Test]
    public static void Presence_keys_and_page_states_translate_without_losing_their_sense()
    {
        Check.Equal(PresenceKey.NoReply, PresenceKeys.FromBadge(PresenceState.Offline), "aucune réponse ICMP n’est une preuve d’extinction : la clé dit « sans réponse »");
        Check.Equal(PresenceKey.Unknown, PresenceKeys.FromBadge(PresenceState.Remembered), "la mémoire ne certifie pas l’état actuel");
        Check.Equal(PresenceState.Offline, PresenceKeys.ToBadge(PresenceKey.NoReply), "la pastille rend « Ne répond pas au ping » sous la clé sans réponse");
        Check.Equal(PresenceState.Unknown, PresenceKeys.ToBadge(PresenceKey.None), "rien à rendre se montre comme non vérifié");
        Check.Equal(PresenceKey.Online, PresenceKeys.FromSearch(SearchPresenceState.Online), "liste et clés d’accord");
        Check.Equal(SearchPresenceState.Unknown, PresenceKeys.ToSearch(PresenceKey.Pending), "la liste ignore l’attente : non vérifié, pas un verdict");
        Check.Equal("En ligne", SearchTexts.PresenceLabel(SearchPresenceState.Online), "le libellé de la liste vient du modèle commun des clés");
        Check.Equal("Non vérifié", SearchTexts.PresenceLabel(SearchPresenceState.Unknown), "libellé commun de la clé inconnue");
        Check.Equal("En ligne", PresenceKeys.Label(PresenceKey.Online), "une seule source des libellés de présence");
        Check.Equal("online", SearchSurvey.OutcomeKind(SearchPresenceState.Online), "jeton du relevé inchangé");
        Check.Equal("noReply", SearchSurvey.OutcomeKind(SearchPresenceState.NoReply), "jeton du relevé inchangé");
        Check.Equal("error", SearchSurvey.OutcomeKind(SearchPresenceState.Unknown), "un poste sans mesure compte comme erreur du relevé");
        Check.Equal("online", PresenceKeys.GridKey(PresenceKey.Online), "le filtre de la grille des requêtes garde ses trois seules valeurs");
        Check.Equal("offline", PresenceKeys.GridKey(PresenceKey.NoReply), "valeur de grille « sans réponse »");
        Check.Equal("unchecked", PresenceKeys.GridKey(PresenceKey.Pending), "une attente n’est pas un constat de la grille");
        Check.Equal("unchecked", PresenceKeys.GridKey(PresenceKey.None), "rien de stocké : non vérifié de la grille");
    }

    /// <summary>A DNS stage failure: the definitive « name absent from DNS » by default, or the transient « DNS unavailable ».</summary>
    private sealed class FailedPresenceProbe(PresenceReadOutcome outcome = PresenceReadOutcome.DnsNotFound) : IWorkstationPresenceProbe
    {
        public int Calls { get; private set; }
        public static PresenceMeasure Failure(DateTimeOffset? lastOnline, PresenceReadOutcome outcome = PresenceReadOutcome.DnsNotFound) => new(MeasureState.Error, null, Fixtures.Now, lastOnline)
        { Diagnostic = new(outcome, "dns", (int)(outcome == PresenceReadOutcome.DnsNotFound ? SocketError.HostNotFound : SocketError.TryAgain)) };
        public Task<PresenceMeasure> ReadPresenceAsync(string host, TimeSpan timeout, DateTimeOffset? lastOnlineAt, CancellationToken cancellationToken)
        { Calls++; return Task.FromResult(Failure(lastOnlineAt, outcome)); }
        public Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) => throw new InvalidOperationException("The qualified contract must be used.");
        public Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken) => throw new InvalidOperationException("No inventory after failed presence.");
    }

    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = Fixtures.Now;
        private long ticks;
        public override DateTimeOffset GetUtcNow() => now;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => ticks;
        public void Advance(TimeSpan by) { now += by; ticks += by.Ticks; }
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) => new PassiveTimer();
        private sealed class PassiveTimer : ITimer
        {
            public bool Change(TimeSpan dueTime, TimeSpan period) => true;
            public void Dispose() { }
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }
}
