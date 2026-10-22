using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AdMachineAccountReaderTests
{
    [Test]
    public static async Task Machine_picker_reads_only_the_local_directory_and_never_resolves_an_unknown_target()
    {
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        var reader = ScreenReaders.Discover(source, [typeof(AdDirectorySource).Assembly]).Require<IMachineAccountReader>();
        Check.Null(await reader.FindWorkstationAsync("PC1", CancellationToken.None), "aucune cible avant relevé");
        var unknown = await reader.ProbeAccessAsync(new MachineProbeRequest("PC1", MachineAccountSource.Windows, @"TEST\adm", null), CancellationToken.None);
        Check.Equal("TargetUnknown", unknown.Outcome, "pas de résolution réseau implicite");
        Check.Equal(0, connection.Calls, "construction et recherches locales sans LDAP");
        var sid = new SecurityIdentifier("S-1-5-21-1-2-3-1001");
        var bytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(bytes, 0);
        connection.SearchAnswer = query => query.Filter == AdDirectoryMapper.ComputerFilter
            ? [new AdEntry("CN=PC1," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>
            {
                ["objectGUID"] = [Fixtures.IdOf("PC1").ToByteArray()], ["objectSid"] = [bytes], ["name"] = ["PC1"],
                ["dNSHostName"] = ["pc1.test.local"], ["sAMAccountName"] = ["PC1$"], ["userAccountControl"] = ["4096"],
            })] : [];
        await source.RefreshAsync(MeasureFamily.Directory, new ScopeSelection(Fixtures.Postes, "Postes", true), CancellationToken.None);
        var calls = connection.Calls;
        var selected = await reader.FindWorkstationAsync("pc1.test.local", CancellationToken.None);
        Check.Equal("PC1", selected?.Name, "poste indexé");
        Check.Equal("unknown", selected?.Presence.State, "aucune présence inventée");
        Check.Equal(1, (await reader.SearchWorkstationsAsync("pc", 50, CancellationToken.None)).Length, "suggestion locale");
        Check.Equal(calls, connection.Calls, "aucun LDAP pour le sélecteur");
    }

    [Test]
    public static async Task Machine_trial_never_substitutes_Windows_for_an_explicit_missing_credential()
    {
        var workstation = new MachineWorkstation(Guid.NewGuid(), "PC1", "pc1.test.local", "CN=PC1," + Fixtures.Postes, "Postes", null, true,
            new MachinePresence("unknown", "Non mesuré", Tone.Off, null));
        var result = await new WmiMachineAccessProbe(TestClock.Fixed()).ReadAsync(
            new MachineProbeRequest("PC1", MachineAccountSource.Connection, @"TEST\another", null), workstation, CancellationToken.None);
        Check.Equal("CredentialMissing", result.Category, "refus avant connexion CIM");
        Check.Null(result.Caption, "aucune observation fabriquée");
        Check.Equal("AuthRejected", WmiMachineAccessProbe.Classify(new System.Runtime.InteropServices.COMException("secret", unchecked((int)0x8007052E)))?.Outcome, "rejet d’authentification");
    }
}
