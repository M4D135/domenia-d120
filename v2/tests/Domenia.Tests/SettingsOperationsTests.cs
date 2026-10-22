using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Simulation;

namespace Domenia.Tests;

/// <summary>
/// Operations of the Paramètres screen over the real bridge and the simulated source (docs/ops/parametres.md): shapes, refusals
/// of the simulation, and every write of the local base through the write circuit (plan, confirmation, receipt, re-read).
/// Written with the code, run at the end (decision of David, 21/10).
/// </summary>
internal static class SettingsOperationsTests
{
    private static string Args(object value) => JsonSerializer.Serialize(value);

    private static string Execute(JsonElement planned, string? typedName = null) => Args(new
    {
        planId = planned.GetProperty("plan").GetProperty("id").GetString(),
        token = planned.GetProperty("token").GetString(),
        typedName,
    });

    private static string Domain(SimulatedBridge bridge) => bridge.Source.World.Directory.Domain.DnsName;

    private static LocalStoreSnapshot Store(SimulatedBridge bridge) => SimulatedLocalStore.For(bridge.Source).Snapshot();

    private static async Task<JsonElement> ResultAsync(SimulatedBridge bridge, string operation, string arguments = "{}") =>
        SimulatedBridge.Json(await bridge.CallAsync(operation, arguments));

    private static async Task<string?> ErrorAsync(SimulatedBridge bridge, string operation, string arguments = "{}")
    {
        var response = await bridge.CallAsync(operation, arguments);
        Check.Equal("error", response.Kind, operation + " devait être refusée");
        return response.Error?.Code;
    }

    [Test]
    public static async Task Reads_answer_in_simulation_with_the_contract_shape()
    {
        var bridge = new SimulatedBridge();
        var connection = await ResultAsync(bridge, "settings.connection");
        Check.True(connection.GetProperty("simulated").GetBoolean(), "simulation dite");
        Check.False(connection.GetProperty("preferences").GetProperty("editable").GetBoolean(), "préférences de connexion en lecture seule");
        Check.Equal(4, connection.GetProperty("sections").GetArrayLength(), "sections qui suivent l’OU de travail");

        var collection = await ResultAsync(bridge, "settings.collection");
        Check.Equal("standard", collection.GetProperty("profile").GetProperty("id").GetString(), "profil Standard par défaut");
        Check.Equal(3, collection.GetProperty("profiles").GetArrayLength(), "trois profils");
        Check.Equal(6, collection.GetProperty("budgets").GetArrayLength(), "six budgets");
        Check.Equal(7, collection.GetProperty("window").GetProperty("grid").GetArrayLength(), "grille de la semaine");

        var storage = await ResultAsync(bridge, "settings.storage");
        Check.True(storage.GetProperty("available").GetBoolean(), "base fictive disponible");
        Check.True(storage.GetProperty("simulated").GetBoolean(), "base fictive dite");
        Check.Equal(1284L, storage.GetProperty("revision").GetInt64(), "révision de la base fictive");
        Check.Equal(9, storage.GetProperty("backups").GetArrayLength(), "neuf sauvegardes initiales");
        Check.Equal(8, storage.GetProperty("purge").GetArrayLength(), "huit catégories de purge");
        Check.Equal(6, storage.GetProperty("retention").GetArrayLength(), "six familles de conservation");

        var demo = await ResultAsync(bridge, "settings.demo");
        Check.True(demo.GetProperty("active").GetBoolean(), "simulation active");
        Check.Equal(JsonValueKind.Object, demo.GetProperty("facts").ValueKind, "faits de l’annuaire fictif");
        Check.Equal(64, demo.GetProperty("facts").GetProperty("fingerprint").GetString()!.Length, "empreinte de l’annuaire généré");

        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage", Args(new { x = 1 })), "argument inattendu refusé");
    }

    [Test]
    public static async Task Measures_and_integrity_are_reads_that_change_nothing()
    {
        var bridge = new SimulatedBridge();
        var before = Store(bridge);
        var measured = await ResultAsync(bridge, "settings.storage.measure");
        Check.Equal(JsonValueKind.Object, measured.GetProperty("usage").ValueKind, "mesure de l’occupation");
        var checkedView = await ResultAsync(bridge, "settings.storage.integrity");
        var integrity = checkedView.GetProperty("integrity");
        Check.Equal(9, integrity.GetProperty("checks").GetArrayLength(), "neuf contrôles");
        Check.Equal(before.Revision, Store(bridge).Revision, "aucune écriture");
        Check.Equal(before.Backups.Length, Store(bridge).Backups.Length, "aucune sauvegarde");
        Check.Equal(0, ((MemoryReceiptStore)bridge.Receipts).Appends, "aucun reçu");
    }

    [Test]
    public static async Task Connection_preferences_are_refused_in_simulation()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(SettingsOperations.SimulationCode, await ErrorAsync(bridge, "settings.connection.set", Args(new { rememberLogin = true })), "rien n’est mémorisé en simulation");
        Check.Equal(SettingsOperations.SimulationCode, await ErrorAsync(bridge, "settings.connection.forget"), "rien à oublier en simulation");
        Check.False(bridge.Preferences.TryGet(SettingsViewRules.ConnectionKey, out _), "aucune préférence écrite");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.connection.set", Args(new { rememberLogin = "oui" })), "booléen exigé");
    }

    [Test]
    public static async Task Collection_settings_are_saved_and_an_invalid_window_never_is()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(SettingsOperations.WindowInvalidCode, await ErrorAsync(bridge, "settings.collection.set", Args(new { window = "lundy 08:00-09:00" })), "fenêtre invalide refusée");
        Check.False(bridge.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out _), "rien d’enregistré");

        var saved = await ResultAsync(bridge, "settings.collection.set", Args(new { profile = "slowNetwork", window = "lun-ven 07:30-18:00", budgets = new { concurrency = 2 } }));
        Check.Equal("slowNetwork", saved.GetProperty("profile").GetProperty("id").GetString(), "profil enregistré");
        Check.Equal("lun-ven 07:30-18:00", saved.GetProperty("window").GetProperty("text").GetString(), "fenêtre enregistrée");
        Check.True(saved.GetProperty("windowCustom").GetBoolean(), "fenêtre propre au profil");
        Check.True(bridge.Preferences.TryGet(CollectionSettingsRules.PreferenceKey, out _), "préférence écrite");

        var reset = await ResultAsync(bridge, "settings.collection.set", Args(new { window = (string?)null }));
        Check.False(reset.GetProperty("windowCustom").GetBoolean(), "fenêtre du profil rétablie");

        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.collection.set"), "au moins un réglage");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.collection.set", Args(new { profile = "turbo" })), "profil inconnu");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.collection.set", Args(new { budgets = new { concurrency = 99 } })), "budget hors bornes");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.collection.set", Args(new { freshness = new { presence = -1 } })), "durée négative");
    }

    [Test]
    public static async Task Window_check_reads_a_text_or_a_painted_grid()
    {
        var bridge = new SimulatedBridge();
        var text = await ResultAsync(bridge, "settings.collection.window.check", Args(new { text = "sam" }));
        Check.True(text.GetProperty("valid").GetBoolean(), "texte valide");
        var grid = Enumerable.Range(0, 7).Select(d => Enumerable.Range(0, 48).Select(h => d < 5 && h >= 16 && h < 36).ToArray()).ToArray();
        var painted = await ResultAsync(bridge, "settings.collection.window.check", Args(new { grid }));
        Check.Equal("lun-ven 08:00-18:00", painted.GetProperty("text").GetString(), "grille traduite en texte");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.collection.window.check", Args(new { grid = new[] { new bool[48] } })), "grille incomplète");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.collection.window.check", Args(new { text = "sam", grid })), "texte ou grille, pas les deux");
    }

    [Test]
    public static async Task Retention_and_schedule_settings_never_delete_anything()
    {
        var bridge = new SimulatedBridge();
        var before = Store(bridge);
        var view = await ResultAsync(bridge, "settings.storage.retention.set", Args(new { presenceDays = 10, consoleDays = 90, inventoryDays = 180, probeDays = 90, detailDays = 30, linkHistoryDays = 0 }));
        Check.Equal(10, view.GetProperty("policy").GetProperty("presenceDays").GetInt32(), "conservation enregistrée");
        Check.Equal(before.Revision, Store(bridge).Revision, "rien n’est supprimé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.retention.set", Args(new { presenceDays = 10 })), "les six durées sont exigées");

        var schedule = await ResultAsync(bridge, "settings.storage.backup.schedule.set", Args(new { enabled = true, hours = 12, keep = 5 }));
        Check.True(schedule.GetProperty("policy").GetProperty("automaticBackup").GetBoolean(), "sauvegarde automatique activée");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.backup.schedule.set", Args(new { enabled = true, hours = 0, keep = 5 })), "fréquence hors bornes");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.backup.schedule.set", Args(new { enabled = true, hours = 12, keep = 1 })), "une seule copie refusée");
    }

    [Test]
    public static async Task Backup_runs_once_through_the_write_circuit_with_a_verified_receipt()
    {
        var bridge = new SimulatedBridge();
        var before = Store(bridge).Backups.Length;
        var planned = await ResultAsync(bridge, "settings.storage.backup.plan");
        var plan = planned.GetProperty("plan");
        Check.Equal(StorageWritePlans.Backup, plan.GetProperty("kind").GetString(), "type de plan");
        Check.Equal(StorageWritePlans.TargetKind, plan.GetProperty("target").GetProperty("kind").GetString(), "cible : base locale");
        Check.False(plan.GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "confirmation simple");
        Check.Equal(before, Store(bridge).Backups.Length, "un plan n’écrit rien");
        Check.Equal(0, ((MemoryReceiptStore)bridge.Receipts).Appends, "aucun reçu pour un plan");

        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "sauvegarde faite");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "sauvegarde relue");
        Check.True(receipt.GetProperty("simulated").GetBoolean(), "reçu simulé");
        Check.Equal(before + 1, Store(bridge).Backups.Length, "une sauvegarde de plus");
        Check.True(StoragePolicyRules.IsVerified(Store(bridge).Backups.OrderByDescending(b => b.At).First()), "contrôle, empreinte et date présents");

        Check.Equal(WriteErrors.TokenUsed, await ErrorAsync(bridge, "write.execute", Execute(planned)), "jamais rejouée");
        Check.Equal(before + 1, Store(bridge).Backups.Length, "toujours une seule sauvegarde de plus");
    }

    [Test]
    public static async Task Retention_plan_is_bound_to_the_fingerprint_of_its_preview()
    {
        var bridge = new SimulatedBridge();
        var preview = await ResultAsync(bridge, "settings.storage.retention.preview");
        Check.False(preview.GetProperty("nothingToDo").GetBoolean(), "mesures anciennes à retirer");
        var fingerprint = preview.GetProperty("fingerprint").GetString()!;
        Check.Equal(StorageWritePlans.PreviewStale, await ErrorAsync(bridge, "settings.storage.retention.plan", Args(new { fingerprint = new string('0', 64) })), "autre empreinte : refaire la prévisualisation");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.retention.plan", Args(new { fingerprint = "abc" })), "empreinte mal formée");

        var planned = await ResultAsync(bridge, "settings.storage.retention.plan", Args(new { fingerprint }));
        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "conservation appliquée");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "conservation relue");
        Check.True((await ResultAsync(bridge, "settings.storage.retention.preview")).GetProperty("nothingToDo").GetBoolean(), "plus rien d’antérieur à la politique");
        Check.Equal(StorageWritePlans.PreviewStale, await ErrorAsync(bridge, "settings.storage.retention.plan", Args(new { fingerprint })), "l’ancienne prévisualisation ne sert plus");
    }

    [Test]
    public static async Task Purge_requires_the_domain_name_and_never_touches_receipts()
    {
        var bridge = new SimulatedBridge();
        var preview = await ResultAsync(bridge, "settings.storage.purge.preview", Args(new { categories = new[] { "observations" } }));
        var fingerprint = preview.GetProperty("fingerprint").GetString()!;
        Check.True(preview.GetProperty("totalRows").GetInt64() > 0, "lignes comptées");
        Check.True(preview.GetProperty("keepsReceipts").GetBoolean(), "reçus gardés");

        var refused = await ResultAsync(bridge, "settings.storage.purge.preview", Args(new { categories = new[] { "receipts" } }));
        Check.Equal(1, refused.GetProperty("refused").GetArrayLength(), "reçus jamais purgés");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.storage.purge.plan", Args(new { categories = new[] { "receipts" }, fingerprint = refused.GetProperty("fingerprint").GetString() })), "aucune purge préparée");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.purge.preview", Args(new { categories = Array.Empty<string>() })), "au moins une catégorie");

        var planned = await ResultAsync(bridge, "settings.storage.purge.plan", Args(new { categories = new[] { "observations" }, fingerprint }));
        var confirmation = planned.GetProperty("plan").GetProperty("confirmation");
        Check.True(confirmation.GetProperty("typedNameRequired").GetBoolean(), "saisie exigée");
        Check.Equal(Domain(bridge), confirmation.GetProperty("typedName").GetString(), "nom du domaine attendu");
        Check.Equal(WriteErrors.ConfirmationMismatch, await ErrorAsync(bridge, "write.execute", Execute(planned, "autre.local")), "mauvais nom : rien n’est envoyé");

        var again = await ResultAsync(bridge, "settings.storage.purge.plan", Args(new { categories = new[] { "observations" }, fingerprint }));
        var receipt = await ResultAsync(bridge, "write.execute", Execute(again, Domain(bridge)));
        Check.Equal("applied", receipt.GetProperty("result").GetString(), "purge appliquée");
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "catégorie relue vide");
        Check.Equal(0L, LocalStoreRules.PurgeRows(Store(bridge), "observations", LocalStoreRules.DefaultHistoryDays), "mesures retirées");
    }

    [Test]
    public static async Task Move_refuses_shares_and_relative_paths()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(StorageWritePlans.DestinationRefused, await ErrorAsync(bridge, "settings.storage.move.plan", Args(new { destination = @"\\serveur\partage\Domenia.db" })), "partage refusé");
        Check.Equal(StorageWritePlans.DestinationRefused, await ErrorAsync(bridge, "settings.storage.move.plan", Args(new { destination = "Domenia.db" })), "chemin relatif refusé");
        Check.Equal(StorageWritePlans.DestinationRefused, await ErrorAsync(bridge, "settings.storage.backupCopy.plan", Args(new { destination = @"D:\copie.txt" })), "copie : fichier .db exigé");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.move.plan", Args(new { destination = new string('a', 261) })), "chemin trop long");

        var planned = await ResultAsync(bridge, "settings.storage.move.plan", Args(new { destination = @"D:\Domenia\Domenia.db" }));
        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "base active relue au nouvel emplacement");
        Check.Equal(@"D:\Domenia\Domenia.db", Store(bridge).PathLabel, "nouvel emplacement");
        Check.True(Store(bridge).Maintenance.CanUndo, "retour possible");

        var back = await ResultAsync(bridge, "settings.storage.rollback.plan");
        Check.Equal("verified", (await ResultAsync(bridge, "write.execute", Execute(back))).GetProperty("verification").GetString(), "retour vérifié");
        Check.False(Store(bridge).PathLabel == @"D:\Domenia\Domenia.db", "base précédente rétablie");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.storage.rollback.plan"), "plus rien à annuler");
    }

    [Test]
    public static async Task Restore_takes_a_verified_backup_and_requires_the_domain_name()
    {
        var bridge = new SimulatedBridge();
        var backup = Store(bridge).Backups.First(StoragePolicyRules.IsVerified);
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.storage.restore.plan", Args(new { backupId = "pas-un-id" })), "identifiant mal formé");
        var planned = await ResultAsync(bridge, "settings.storage.restore.plan", Args(new { backupId = backup.Id }));
        Check.True(planned.GetProperty("plan").GetProperty("confirmation").GetProperty("typedNameRequired").GetBoolean(), "saisie exigée");
        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned, Domain(bridge)));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "base restaurée relue");
        Check.Equal(backup.Revision, Store(bridge).Revision, "révision de la sauvegarde");
        Check.True(Store(bridge).Backups.Any(b => b.Id == backup.Id), "la sauvegarde n’est jamais modifiée ni retirée");
    }

    [Test]
    public static async Task Legacy_takeover_is_idempotent()
    {
        var bridge = new SimulatedBridge();
        var preview = await ResultAsync(bridge, "settings.storage.legacy.preview");
        Check.True(preview.GetProperty("found").GetBoolean(), "données de Domenia 1 trouvées");
        var planned = await ResultAsync(bridge, "settings.storage.legacy.plan", Args(new { fingerprint = preview.GetProperty("fingerprint").GetString() }));
        var receipt = await ResultAsync(bridge, "write.execute", Execute(planned, Domain(bridge)));
        Check.Equal("verified", receipt.GetProperty("verification").GetString(), "reprise relue");
        var second = await ResultAsync(bridge, "settings.storage.legacy.preview");
        Check.True(second.GetProperty("nothingToDo").GetBoolean(), "rien de nouveau");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.storage.legacy.plan", Args(new { fingerprint = second.GetProperty("fingerprint").GetString() })), "une reprise ne se rejoue pas");
    }

    [Test]
    public static async Task Nothing_to_resume_is_said_never_planned()
    {
        var bridge = new SimulatedBridge();
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.storage.resume.plan"), "aucune bascule interrompue");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.storage.writerResume.plan"), "écrivain actif");
        Check.Equal(WriteErrors.NothingToDo, await ErrorAsync(bridge, "settings.storage.rollback.plan"), "aucune bascule à annuler");
    }

    [Test]
    public static async Task Reset_restores_the_defaults_of_one_group()
    {
        var bridge = new SimulatedBridge();
        await ResultAsync(bridge, "settings.collection.set", Args(new { profile = "troubleshooting" }));
        await ResultAsync(bridge, "settings.storage.retention.set", Args(new { presenceDays = 10, consoleDays = 90, inventoryDays = 180, probeDays = 90, detailDays = 30, linkHistoryDays = 0 }));
        var result = await ResultAsync(bridge, "settings.preferences.reset", Args(new { group = "collection" }));
        Check.Equal(1, result.GetProperty("changed").GetInt32(), "un groupe réinitialisé");
        Check.Equal("standard", (await ResultAsync(bridge, "settings.collection")).GetProperty("profile").GetProperty("id").GetString(), "profil par défaut");
        Check.Equal(10, (await ResultAsync(bridge, "settings.storage")).GetProperty("policy").GetProperty("presenceDays").GetInt32(), "les autres groupes restent");

        var all = await ResultAsync(bridge, "settings.preferences.reset", Args(new { group = "all" }));
        Check.Equal(0, all.GetProperty("failed").GetArrayLength(), "tout réinitialisé");
        Check.Equal(StoragePolicyRules.Default.PresenceDays, (await ResultAsync(bridge, "settings.storage")).GetProperty("policy").GetProperty("presenceDays").GetInt32(), "conservation par défaut");
        Check.Equal(DomeniaErrors.ArgumentsInvalid, await ErrorAsync(bridge, "settings.preferences.reset", Args(new { group = "tout" })), "groupe inconnu");
    }
}
