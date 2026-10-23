using System.Text.Json;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class InventoryConsoleEvidenceTests
{
    private static WmiInstance Row(params (string Name, object? Value)[] values) => new(values.ToDictionary(v => v.Name, v => v.Value));
    private static Task<InventorySnapshot> Read(Func<IReadOnlyList<WmiInstance>> computer, FixedTimeProvider? clock = null, bool denyOs = false)
    {
        clock ??= TestClock.Fixed();
        var reader = new WmiWorkstationReader(clock)
        {
            SessionFactory = (host, budget, token) => new(host, budget, clock, cancellationToken: token)
            { RegistryOverride = (_, _) => new(2, null), ReadOverride = (_, query, _) =>
                query.Contains("Win32_ComputerSystem", StringComparison.Ordinal) ? computer()
                : query.Contains("Win32_OperatingSystem", StringComparison.Ordinal) ? denyOs ? throw new UnauthorizedAccessException("Refus OS simulé")
                    : [Row(("Caption", "Windows"), ("BuildNumber", "26100"))] : [] },
        };
        return reader.ReadAsync("PC1.test.local", WorkstationReading.Survey, null, CancellationToken.None);
    }

    [Test]
    public static async Task Inventory_console_requires_a_well_typed_field_even_when_the_system_category_answered()
    {
        var rows = new[] { Row(("Name", "PC1")), Row(("Name", "PC1"), ("UserName", 42)), Row(("Name", "PC1"), ("UserName", "")),
            Row(("Name", "PC1"), ("UserName", new[] { @"TEST\alice" })), Row(("Name", "PC1"), ("UserName", "TEST\\alice\n")) };
        foreach (var row in rows)
        {
            var value = await Read(() => [row]);
            Check.Equal("PC1", value.ReportedName!, "identité Windows reçue"); Check.Null(value.Console, "champ non concluant");
            var facts = AdSearchReader.MapInventory(Fixtures.Computer("PC1").ObjectGuid, value).Machines.Values.Single();
            Check.Null(facts.ConsoleAt, "aucune date d’absence inventée"); Check.Null(facts.ConsoleUser, "aucun texte converti arbitrairement");
        }
    }

    [Test]
    public static async Task Explicit_null_is_a_dated_empty_console_and_timestamp_is_after_the_system_read()
    {
        var clock = TestClock.Fixed();
        var value = await Read(() => { clock.Advance(TimeSpan.FromSeconds(2)); return [Row(("Name", "PC1"), ("UserName", null))]; }, clock);
        Check.True(value.Console is not null, "null natif explicite reconnu"); Check.Null(value.Console!.Account, "aucun compte");
        Check.Equal(Fixtures.Now.AddSeconds(2), value.Console.At, "date après retour natif"); Check.Equal(Fixtures.Now, value.CollectedAt, "début de collecte distinct");
        var facts = AdSearchReader.MapInventory(Fixtures.Computer("PC1").ObjectGuid, value).Machines.Values.Single();
        Check.Equal(value.Console.At, facts.ConsoleAt!.Value, "date indépendante dans le cache");
    }

    [Test]
    public static async Task Multiple_system_instances_never_choose_an_arbitrary_identity_or_console()
    {
        var value = await Read(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice")), Row(("Name", "OTHER"), ("UserName", @"TEST\bob"))]);
        Check.Null(value.ReportedName, "identité ambiguë écartée"); Check.Null(value.Console, "aucune console arbitraire");
        Check.Equal(SourceStatus.Partial, value.StatusOf(InventoryCategories.System), "ambiguïté visible");
    }

    [Test]
    public static async Task A_separate_OS_refusal_does_not_fabricate_a_console_failure_or_erase_its_completed_read()
    {
        var value = await Read(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))], denyOs: true);
        Check.Equal(@"TEST\alice", value.Console!.Account!, "console réellement reçue malgré OS non lu");
        Check.Null(value.Os?.Caption is { Length: > 0 } ? value.Os.Caption : null, "aucun libellé OS inventé");
        Check.Equal(Fixtures.Now, AdSearchReader.MapInventory(Fixtures.Computer("PC1").ObjectGuid, value).Machines.Values.Single().ConsoleAt!.Value, "date de console conservée séparément");
    }

    [Test]
    public static async Task Removing_the_system_source_also_removes_its_console_evidence_but_other_sources_do_not()
    {
        var value = await Read(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))]);
        Check.Null(value.WithStatus([InventoryCategories.System], SourceStatus.Unavailable, "Identité non confirmée").Console, "preuve système écartée");
        Check.Equal(value.Console!, value.WithStatus([InventoryCategories.Network], SourceStatus.Refused, "Accès réseau refusé").Console!, "source console indépendante");
    }

    [Test]
    public static async Task An_old_snapshot_without_console_evidence_cannot_refresh_or_clear_a_previous_console_fact()
    {
        var id = Fixtures.Computer("PC1").ObjectGuid;
        var original = await Read(() => [Row(("Name", "PC1"), ("UserName", @"TEST\alice"))]);
        var fleet = CachedFleet.Empty("fixture").Merge(AdSearchReader.MapInventory(id, original));
        var oldFormat = original with { CollectedAt = Fixtures.Now.AddMinutes(1), Console = null, System = original.System! with { UserName = null } };
        var json = JsonSerializer.Serialize(oldFormat); Check.False(json.Contains("\"Console\":", StringComparison.Ordinal), "ancien format sans nouveau champ");
        var decoded = JsonSerializer.Deserialize<InventorySnapshot>(json)!; Check.Null(decoded.Console, "aucune preuve inventée au chargement");
        var kept = fleet.Merge(AdSearchReader.MapInventory(id, decoded));
        Check.Equal(@"TEST\alice", kept.Facts.Machines[id].ConsoleUser!, "ancien compte conservé");
        Check.Equal(Fixtures.Now, kept.Facts.Machines[id].ConsoleAt!.Value, "ancienne date conservée");
        var empty = await Read(() => [Row(("Name", "PC1"), ("UserName", null))]);
        empty = empty with { CollectedAt = Fixtures.Now.AddMinutes(2), Console = empty.Console! with { At = Fixtures.Now.AddMinutes(2) } };
        var cleared = kept.Merge(AdSearchReader.MapInventory(id, empty));
        Check.Null(cleared.Facts.Machines[id].ConsoleUser, "nouvelle console explicitement vide appliquée");
        Check.Equal(Fixtures.Now.AddMinutes(2), cleared.Facts.Machines[id].ConsoleAt!.Value, "date de ce constat seulement");
    }
}
