using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class BitLockerStatusTests
{
    [Test]
    public static void Missing_codes_and_rounded_percentages_never_prove_encryption_or_its_absence()
    {
        foreach (var volume in new BitLockerVolume[]
        {
            new("C:", null, null, null, null, null), new("C:", 2, null, 6, null, null),
            new("C:", 0, null, 6, 100, null), new("C:", null, null, null, 0, null),
            new("C:", 1, 0, 0, 100, null),
        })
        {
            var status = BitLockerStatus.Of(volume);
            Check.Equal(FactState.Unknown, status.State, "preuve absente ou contradictoire");
            Check.False(status.Label.Contains("Non chiffré", StringComparison.OrdinalIgnoreCase), "aucun faux zéro");
            Check.False(status.Tone == Tone.Ok || status.Suspended, "ni conformité ni suspension inventée");
        }
        Check.Equal("Non chiffré", BitLockerStatus.Of(new("C:", 0, null, 0, null, null)).Label, "code méthode zéro explicite");
        Check.Equal("Non chiffré", PosteLabels.BitLockerMethod(0), "inventaire brut : le code zéro a le même sens que la fiche");
        Check.Equal("Non chiffré", BitLockerStatus.Of(new("C:", 0, 0, null, null, null)).Label, "conversion déchiffrée explicite");
        Check.Equal("Protégé", BitLockerStatus.Of(new("C:", 1, 1, 6, 100, 1)).Label, "protection lue");
        Check.True(BitLockerStatus.Of(new("C:", 0, 1, 6, 100, 1)).Suspended, "suspension prouvée par deux codes");
        Check.Equal("Chiffrement matériel déverrouillé", BitLockerStatus.Of(new("C:", 0, 0, 5, null, null)).Label, "cas du matériel explicitement déverrouillé");
        var progress = new[] { "Chiffrement en cours", "Déchiffrement en cours", "Chiffrement en pause", "Déchiffrement en pause" };
        for (var conversion = 2; conversion <= 5; conversion++)
        { Check.Equal(progress[conversion - 2], BitLockerStatus.Of(new("C:", 0, conversion, 6, 100, null)).Label, "le pourcentage arrondi ne remplace pas la conversion"); }
    }

    [Test]
    public static async Task Workstation_board_and_interpreted_reading_share_unknown_and_suspended_statuses()
    {
        var bridge = new SimulatedBridge();
        var dn = bridge.Source.CurrentDirectory.Computers.First().DistinguishedName;
        var data = SimulatedBridge.Json(await bridge.CallAsync("poste.open", JsonSerializer.Serialize(new { dn })));
        var computer = data.GetProperty("computer").Deserialize<PosteComputer>(PosteBoardLayouts.Json)!;
        foreach (var volume in new BitLockerVolume[] { new("C:", 2, null, 6, null, null), new("C:", 0, 1, 6, 100, 1) })
        {
            var inventory = EmptyInventory() with
            {
                Access = [new(InventoryCategories.BitLocker, SourceStatus.Ok, "fixture locale", 0, 1, InventoryTransport.Local)],
                BitLocker = [volume],
            };
            var board = PosteBoardBuilder.Build(computer, inventory, PosteHealthPolicy.Default, TestClock.Reference, TestClock.Paris);
            var section = board.Sections.Single(s => s.Key == "bitlocker");
            var expected = BitLockerStatus.Of(volume);
            Check.Equal(expected.Label, section.Value, "résumé central du tableau");
            Check.Equal(expected.State, section.Facts.Single().State, "preuve de la fiche");
            var store = new ProbeStore("PC1", inventory, [new("sec.bitlockervolumes", ProbeState.Read, TestClock.Reference, TestClock.Reference, null, 1) { DefinitionHash = ProbeDefinitionIdentity.Of(Domenia.Core.Poste.ProbeCatalog.Find("sec.bitlockervolumes")!) }], [], [], [], TestClock.Reference);
            var facts = PosteReadings.Build(store, PosteHealthPolicy.Default, [], TestClock.Reference, TestClock.Paris)
                .Readings.Single(r => r.Id == "protection").Facts;
            var fact = facts.Single(f => f.Label == "BitLocker C:");
            Check.Equal(section.Facts.Single().Value, fact.Value, "même statut et méthode dans les deux écrans");
            Check.Equal(expected.State, fact.State, "une lecture WMI réussie ne garantit pas un état connu");
            Check.Contains("XTS-AES 128", fact.Value, "méthode réellement lue conservée même si protection inconnue");
        }
    }

    private static InventorySnapshot EmptyInventory() => new(
        Computer: "PC1", CollectedAt: TestClock.Reference, Deep: false, DurationMs: 0, Transport: InventoryTransport.Local, Access: [],
        Os: null, System: null, Bios: null, Processors: [], MemoryModules: [], MemoryArray: null, Memory: null, Volumes: [], PhysicalDisks: [],
        BitLocker: [], Tpm: null, SecureBoot: null, Network: [], Firewall: [], Antivirus: [], Defender: null, Hotfixes: [], Updates: null,
        Software: [], Startup: [], Services: [], Devices: [], Displays: [], Batteries: [], UnsignedDrivers: [], Sessions: [], LocalAdmins: [],
        Shares: [], Printers: [], PendingReboot: null, ClockSkewSeconds: null, ClockAgainstController: false, Site: null, Proxy: null,
        Processes: [], SystemEvents: [], Tasks: [], Certificates: [], Connections: []);
}
