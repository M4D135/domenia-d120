using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Tests;

internal static class WriteDeliveryTests
{
    [Test]
    public static void Delivery_is_not_an_effect_proof_or_a_generic_escape_from_uncertain_ad_writes()
    {
        foreach (var kind in new[] { PosteRemoteWrites.GpUpdateKind, PosteRemoteWrites.RunKind, PosteRemoteWrites.WakeKind, PosteRemoteWrites.RestartCancelKind })
        {
            var draft = FakeWriteExecutor.Draft() with { Kind = kind };
            var plan = WritePlans.Seal(draft, WritePlans.NewId(), @"TEST\operator", AppMode.Directory, Fixtures.Now, TimeZoneInfo.Utc);
            var first = WriteReceipts.Sent(plan, WritePlans.NewId(), Fixtures.Now, new("Contrôle", "Identité qualifiée."));
            var delivered = WriteReceipts.Completed(first, new(WriteResult.Delivered, "Transport terminé et nettoyage confirmé."), null, Fixtures.Now);
            Check.Equal(VerificationState.Unknown, delivered.Verification, "aucune preuve d’effet inventée");
            Check.False(WriteReceipts.IsPending(delivered), "fin du transport expressément acquittée");
            Check.Equal(Tone.Info, WriteReceipts.ToneOf(delivered), "jamais succès vert implicite");
            Check.Contains("effet non vérifié", WriteReceipts.ResultLabel(delivered.Result, false), "limite visible");
            Check.Contains("n’est pas prouvé", WriteReceipts.SummaryOf(delivered), "résumé explicite");
            var restored = JsonSerializer.Deserialize<WriteReceipt>(JsonSerializer.Serialize(delivered))!;
            Check.Equal(WriteResult.Delivered, restored.Result, "état conservé au redémarrage");
            var ad = first with { Plan = first.Plan with { Kind = "fiche.update" } };
            Check.Throws<InvalidOperationException>(() => WriteReceipts.Completed(ad, new(WriteResult.Delivered, "Réponse perdue"), null, Fixtures.Now), "aucun faux acquittement AD");
            Check.True(WriteReceipts.IsPending(first), "aucune réponse : toujours bloquant");
        }
    }
}
