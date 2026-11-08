using System.Globalization;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class SearchInventoryAttemptsTests
{
    private static SourceAccess Access(string category, SourceStatus status) => new(category, status, "Retour de fixture.", 1, 1, InventoryTransport.Dcom);

    [Test]
    public static void A_later_failure_preserves_completed_volumes_and_keeps_its_original_age_and_failure_visible()
    {
        var attempts = new SearchInventoryAttempts();
        var first = Empty(Fixtures.Now) with { Volumes = [new("C:", null, "NTFS", 100, 40)],
            Access = [Access(InventoryCategories.Volumes, SourceStatus.Ok), Access(InventoryCategories.Network, SourceStatus.Error)] };
        attempts.Preserve(first);
        var next = Empty(Fixtures.Now.AddMinutes(1)) with
        {
            Network = [new("Ethernet", 2, 1000, null, true, false, ["192.0.2.1"], 24, null, [], true, null)],
            Access = [Access(InventoryCategories.Volumes, SourceStatus.Error), Access(InventoryCategories.Network, SourceStatus.Ok)],
        };
        var result = attempts.Preserve(next);
        Check.Equal(1, result.Volumes.Length, "volume terminé avant la reprise conservé");
        Check.Equal(1, result.Network.Length, "nouvelle source reçue également conservée");
        Check.Equal(first.CollectedAt, result.CollectedAt, "aucun rajeunissement du contenu conservé");
        Check.Equal(SourceStatus.Partial, result.StatusOf(InventoryCategories.Volumes), "dernier échec pas présenté comme une réussite");
        Check.Contains(first.CollectedAt.ToString("O", CultureInfo.InvariantCulture), result.Access[0].Detail, "provenance datée visible dans le rapport");
        Check.Contains("Error", result.Access[0].Detail, "dernier échec visible");
        Check.Equal(0, next.Volumes.Length, "résultat natif brut inchangé pour les décisions de reprise");
    }

    [Test]
    public static void A_real_empty_result_replaces_old_values_and_a_third_failure_keeps_the_dated_empty_answer()
    {
        var attempts = new SearchInventoryAttempts();
        attempts.Preserve(Empty(Fixtures.Now) with { Volumes = [new("C:", null, null, 100, 40)], Access = [Access(InventoryCategories.Volumes, SourceStatus.Ok)] });
        var empty = Empty(Fixtures.Now.AddMinutes(1)) with { Access = [Access(InventoryCategories.Volumes, SourceStatus.Empty)] };
        var result = attempts.Preserve(empty);
        Check.Equal(0, result.Volumes.Length, "vide effectivement lu conservé");
        Check.Equal(empty.CollectedAt, result.CollectedAt, "nouvelle observation datée sans ancien contenu");
        var failed = attempts.Preserve(Empty(Fixtures.Now.AddMinutes(2)) with { Access = [Access(InventoryCategories.Volumes, SourceStatus.Interrupted)] });
        Check.Equal(0, failed.Volumes.Length, "ancien disque jamais ressuscité après le vide connu");
        Check.Equal(empty.CollectedAt, failed.CollectedAt, "date du vide conservée");
        Check.Equal(SourceStatus.Partial, failed.StatusOf(InventoryCategories.Volumes), "essai interrompu signalé");
    }

    [Test]
    public static void Preserved_system_data_does_not_restore_an_old_console_association()
    {
        var attempts = new SearchInventoryAttempts();
        attempts.Preserve(Empty(Fixtures.Now) with { Console = new("TEST\\alice", Fixtures.Now),
            System = new("Fabricant", "Modèle", null, [], null, 100, 1, null, "TEST\\alice"),
            Access = [Access(InventoryCategories.System, SourceStatus.Ok), Access(InventoryCategories.Board, SourceStatus.Ok)] });
        var result = attempts.Preserve(Empty(Fixtures.Now.AddMinutes(1)) with
        { Access = [Access(InventoryCategories.System, SourceStatus.Interrupted), Access(InventoryCategories.Board, SourceStatus.Interrupted)] });
        Check.Equal("Modèle", result.System!.Model, "identité matérielle précédemment lue conservée");
        Check.Null(result.Console, "aucune association console restaurée sans qualification récente");
        Check.Null(result.System.UserName, "aucun ancien compte publié comme actuellement connecté");
    }

    [Test]
    public static void Attempts_of_another_machine_are_refused()
    {
        var attempts = new SearchInventoryAttempts(); attempts.Preserve(Empty(Fixtures.Now));
        Check.Throws<InvalidDataException>(() => attempts.Preserve(Empty(Fixtures.Now) with { Computer = "AUTRE" }), "pas de mélange de cibles");
    }

    private static InventorySnapshot Empty(DateTimeOffset at) => new(
        Computer: "PC1", CollectedAt: at, Deep: false, DurationMs: 0, Transport: InventoryTransport.Dcom, Access: [],
        Os: null, System: null, Bios: null, Processors: [], MemoryModules: [], MemoryArray: null, Memory: null, Volumes: [], PhysicalDisks: [],
        BitLocker: [], Tpm: null, SecureBoot: null, Network: [], Firewall: [], Antivirus: [], Defender: null, Hotfixes: [], Updates: null,
        Software: [], Startup: [], Services: [], Devices: [], Displays: [], Batteries: [], UnsignedDrivers: [], Sessions: [], LocalAdmins: [],
        Shares: [], Printers: [], PendingReboot: null, ClockSkewSeconds: null, ClockAgainstController: false, Site: null, Proxy: null,
        Processes: [], SystemEvents: [], Tasks: [], Certificates: [], Connections: []);
}
