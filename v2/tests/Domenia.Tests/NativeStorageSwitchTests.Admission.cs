using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

internal static partial class NativeStorageSwitchTests
{
    [Test]
    public static async Task Invalid_switch_marker_explains_refusal_without_selecting_or_modifying_any_database()
    {
        using var setup = new Setup(); await setup.Initialize();
        await setup.Cache.ApplyStorageSwitchAsync(await setup.Move(), None);
        var name = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(Fixtures.Root.ToLowerInvariant()))) + ".json";
        var marker = Path.Combine(setup.User, "Domenia-v2", "Storage", name);
        var valid = File.ReadAllText(marker);
        var before = DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path);
        var destination = DomeniaDatabase.SwitchFileFingerprint(setup.Destination);
        foreach (var damage in new[] { "hash", "domain", "identity", "copyIdentity", "stage", "null", "missingCopy" })
        {
            var envelope = JsonNode.Parse(valid)!.AsObject();
            var state = JsonNode.Parse(envelope["json"]!.GetValue<string>())!.AsObject();
            if (damage == "domain") state["domainDn"] = "DC=other,DC=local";
            if (damage == "identity") state["originalStoreId"] = new string('f', 64);
            if (damage == "copyIdentity") state["copySource"]!["storeId"] = new string('f', 64);
            if (damage == "stage") state["stage"] = "ambiguous";
            if (damage == "null") state["originalPlanFingerprint"] = null;
            if (damage == "missingCopy") state["copy"] = null;
            var content = state.ToJsonString(); envelope["json"] = content;
            envelope["sha256"] = damage == "hash" ? new string('0', 64) : Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(content)));
            var damaged = envelope.ToJsonString(); File.WriteAllText(marker, damaged);
            var reopened = setup.Reopen(); var report = await reopened.InspectLocalStoreAsync(false, true, None);
            Check.False(report.Available, "aucune base choisie depuis un marqueur non vérifiable : " + damage);
            Check.Equal("", report.PathLabel, "aucun chemin deviné");
            Check.True(report.Writer.Suspended && report.Maintenance.Locked, "suspension visible dans le vrai snapshot");
            Check.Equal("failed", report.Integrity!.Checks.Single(c => c.Id == "redirect").Status, "défaut de bascule explicite");
            Check.Contains("fichiers conservés", report.LastFailure, "consigne de reprise visible");
            await ExpectFailure(() => reopened.PrepareAsync(None), "aucune préparation réseau sur une base de repli");
            Check.Equal(damaged, File.ReadAllText(marker), "marqueur conservé pour examen");
            Check.Equal(before, DomeniaDatabase.SwitchFileFingerprint(setup.Database.Path), "original intact");
            Check.Equal(destination, DomeniaDatabase.SwitchFileFingerprint(setup.Destination), "destination intacte");
        }
    }

    [Test]
    public static async Task Pending_switch_stops_collections_and_a_completed_marker_never_rearms_a_failed_writer()
    {
        using var setup = new Setup(); await setup.Initialize();
        setup.Cache.SwitchCheckpoint = point => { if (point == "copied") throw new IOException("arrêt injecté"); };
        var move = await setup.Move();
        await ExpectFailure(() => setup.Cache.ApplyStorageSwitchAsync(move, None), "copie interrompue");
        var reopened = setup.Reopen();
        Check.True((await reopened.CollectionStorageAsync(None)).Maintenance, "admission suspendue avant toute lecture réseau");
        var pending = await reopened.InspectLocalStoreAsync(false, true, None);
        Check.Equal("warning", pending.Integrity!.Checks.Single(c => c.Id == "redirect").Status, "bascule pendante contrôlée");
        await ExpectFailure(() => reopened.PrepareAsync(None), "la réserve disque seule ne permet pas de collecter");
        var resume = Seal(await reopened.PrepareStorageResumeAsync(None)); await reopened.ApplyStorageSwitchAsync(resume, None);
        var active = await reopened.DatabaseAsync(None);
        active.FreeSpaceProbe = () => 1;
        await Check.ThrowsAsync<IOException>(() => active.SaveFleetAsync(Domenia.Core.Accueil.FleetCachePatch.Empty, None), "écrivain suspendu par le disque");
        active.FreeSpaceProbe = () => long.MaxValue;
        var failed = await reopened.InspectLocalStoreAsync(false, true, None);
        Check.True(failed.Writer.Suspended, "un marqueur terminé ne gomme pas la suspension réelle");
        Check.Equal("ok", failed.Integrity!.Checks.Single(c => c.Id == "redirect").Status, "bascule vérifiée séparément de la santé écrivain");
    }
}
