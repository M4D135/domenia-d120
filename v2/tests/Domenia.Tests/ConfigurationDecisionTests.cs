using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;

namespace Domenia.Tests;

internal static class ConfigurationDecisionTests
{
    [Test]
    public static async Task A_partial_or_altered_receipt_never_hides_the_first_start_proposal_or_overwrites_the_document()
    {
        var document = PortableConfiguration.Read(PortableConfiguration.Export(new Dictionary<string, JsonElement>(), [], null, "Annuaire", TestClock.Reference).Text);
        var id = ConfigurationChanges.DecisionId("build-A", document.Sha256);
        var original = JsonSerializer.SerializeToElement(new { id, build = "build-A", sourceSha256 = document.Sha256, choice = "declined", at = TestClock.Reference, backup = (string?)null, backupSha256 = (string?)null });
        foreach (var change in new Action<JsonObject>[]
        {
            row => row.Remove("choice"),
            row => row["build"] = "other-build",
            row => row["sourceSha256"] = new string('0', 64),
            row => row["at"] = "invalid-date",
            row => row["future"] = true,
            row => row["backupSha256"] = new string('1', 64),
        })
        {
            var altered = JsonNode.Parse(original.GetRawText())!.AsObject(); change(altered);
            var preferences = new MemoryPreferenceStore();
            var proof = JsonSerializer.SerializeToElement(new[] { altered });
            await preferences.SetAsync(ConfigurationChanges.DecisionsKey, proof, CancellationToken.None);
            var writes = preferences.Writes;
            var coordinator = new ConfigurationSeedCoordinator(AppMode.Directory, true, preferences, "build-A", TestClock.Fixed(),
                _ => new(document, document.Sha256), (_, _) => throw new TestFailureException("Aucun commit attendu."));
            await Check.ThrowsAsync<InvalidDataException>(() => coordinator.ExamineAsync(true, CancellationToken.None), "preuve incomplète ou contradictoire refusée");
            Check.Equal(writes, preferences.Writes, "aucun faux reçu réparé silencieusement");
            Check.True(preferences.TryGet(ConfigurationChanges.DecisionsKey, out var after) && after.GetRawText() == proof.GetRawText(), "preuve originale intacte");
        }
    }
}
