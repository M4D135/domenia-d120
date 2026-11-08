using Domenia.Core;
using System.Runtime.InteropServices;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class NativeAccessTrialTests
{
    [Test]
    public static void Native_trial_identity_requires_a_real_matching_nonempty_answer()
    {
        var positive = WmiMachineAccessProbe.ProjectTrial(" pc1 ", "PC1");
        Check.Equal("Observed", positive.Outcome, "nom réellement relu"); Check.Equal("pc1", positive.ConfirmedComputerName, "nom confirmé"); Check.Null(positive.Caption, "nom distinct du système");
        var wrong = WmiMachineAccessProbe.ProjectTrial("PC2", "PC1");
        Check.Equal("Failed", wrong.Outcome, "autre cible refusée"); Check.Equal("Target", wrong.Category, "motif exact"); Check.Null(wrong.ConfirmedComputerName, "aucune confirmation inventée");
        Check.Equal("Incomplete", WmiMachineAccessProbe.ProjectTrial("", "PC1").Category, "vide inconnu");
        Check.Equal("Incomplete", WmiMachineAccessProbe.ProjectTrial(new string('x', 32769), null).Category, "réponse bornée");
    }

    [Test]
    public static async Task Native_trial_keeps_password_rejection_account_state_and_access_denial_distinct_over_IPC()
    {
        foreach (var (code, outcome, category) in new[] { (0x8007052eU, "AuthRejected", "CredentialsRejected"), (0x80070775U, "Failed", "AccountState"), (0x80070005U, "Denied", "AccessDenied") })
        {
            var classified = WmiMachineAccessProbe.Classify(new COMException("not-serialized", unchecked((int)code)))!.Value;
            using var stream = new MemoryStream();
            await NativeReadProtocol.WriteAsync(stream, new NativeReadReply(Trial: new(classified.Outcome, classified.Message, classified.Category, null)), 4096, default);
            stream.Position = 0;
            var actual = (await NativeReadProtocol.ReadAsync<NativeReadReply>(stream, 4096, default)).Trial!;
            Check.Equal(outcome, actual.Outcome, "issue exacte"); Check.Equal(category, actual.Category, "catégorie exacte");
            Check.Null(actual.Caption, "aucune observation en cas de refus");
        }
    }

    [Test]
    public static async Task Native_trial_closed_command_is_dispatched_in_real_child_without_network_when_disabled()
    {
        using var client = new NativeReadClient(new("PC-TEST", InventoryTransport.Dcom, 20_000, true, null, false, false), null, default, adaptive: new AdaptiveReadBudget(TimeProvider.System));
        var result = await client.ReadAsync(new(NativeReadKind.AccessTrial, 20_000) { ExpectedComputerName = "PC-TEST" });
        Check.Equal("Failed", result.Trial!.Outcome, "commande effectivement reçue par l’enfant");
        Check.Equal("Disabled", result.Trial.Category, "garde positive sans contact");
        Check.Null(result.Trial.ConfirmedComputerName, "pas de nom fabriqué");
    }

    [Test]
    public static void Native_trial_cannot_run_in_parent_and_refuses_malformed_expected_identity()
    {
        Check.Throws<InvalidOperationException>(() => WmiMachineAccessProbe.ReadNative("PC1", null, null, default), "frontière obligatoire avant System.Management");
        new NativeReadRequest(NativeReadKind.AccessTrial, 1000) { ExpectedComputerName = "PC1" }.Check();
        Check.Throws<InvalidDataException>(() => new NativeReadRequest(NativeReadKind.AccessTrial, 1000) { ExpectedComputerName = @"PC1\root" }.Check(), "identité non injectée");
    }
}
