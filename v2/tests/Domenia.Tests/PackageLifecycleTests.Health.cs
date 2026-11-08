using System.Text.Json;
using Domenia.App;

namespace Domenia.Tests;

internal static partial class PackageLifecycleTests
{
    private static PackageHealthReceipt Healthy(PackageHealthRequest request) => new(1, request.Transaction,
        request.ManifestSha256, request.Nonce, 123, Release('b').Build, "fixture-webview", true, true);
    private static PackageLifecycle HealthDelivery(Fixture fixture, Func<PackageHealthRequest, CancellationToken, PackageHealthReceipt> check,
        Action<string>? checkpoint = null) => new(fixture.Source, TestClock.Fixed()) { RequireHealth = true, HealthCheck = check, Checkpoint = checkpoint, SignatureVerifier = UnsignedFixture, PublisherPolicy = PackagePublisherPolicy.Unconfigured };

    [Test]
    public static void Health_ack_is_required_before_activation_and_is_bound_to_the_verified_transaction()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b')); var reached = false;
        var delivery = HealthDelivery(fixture, (request, _) =>
        {
            reached = true;
            Check.Equal(Hash(Path.Combine(fixture.Source, PackageIntegrity.ManifestName)), request.ManifestSha256, "manifest réellement préparé");
            Check.Equal(fixture.Transaction, request.Transaction, "identité de la transaction durable");
            Check.Equal(Hash(Path.Combine(fixture.Storage, request.Transaction, "transaction.json")), request.JournalSha256, "journal relu");
            Check.True(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "pending tenu pendant le contrôle santé");
            Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(fixture.Target, true).Dispose(), "lancement ordinaire encore bloqué");
            return Healthy(request);
        });
        var plan = delivery.PreviewUpdate(fixture.Target, None); Check.True(plan.RequiresHealth, "aperçu dit la condition réelle");
        var result = delivery.Update(fixture.Target, plan.Confirmation, None);
        Check.True(reached && result.HealthConfirmed, "succès uniquement après le vrai point de santé");
        using var active = PackageIntegrity.Open(fixture.Target, true);
        Check.Equal(result.ActiveIdentity, active.ManifestHash, "paquet activé intégralement relu");
        var ackPath = Path.Combine(fixture.Storage, result.Transaction, "health", "ack-1.json");
        using var ack = JsonDocument.Parse(File.ReadAllBytes(ackPath));
        Check.False(ack.RootElement.TryGetProperty("nonce", out _), "autorisation non réutilisable dans le reçu");
        Check.True(ack.RootElement.GetProperty("scriptReady").GetBoolean(), "preuve persistée du contrôle demandé");
    }

    [Test]
    public static void Health_failure_restores_only_binary_bytes_and_preserves_configuration_and_data()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b'));
        var before = Hash(Path.Combine(fixture.Target, PackageIntegrity.ManifestName));
        var configuration = Path.Combine(fixture.Target, "Domenia.config.json"); File.WriteAllText(configuration, "operator configuration exact");
        var externalData = Path.Combine(fixture.Root, "operator.db"); File.WriteAllBytes(externalData, [0, 255, 1, 7]);
        var dataHash = Hash(externalData); var reached = false;
        var delivery = HealthDelivery(fixture, (request, _) => { reached = true; return Healthy(request) with { Nonce = (request.Nonce[0] == '0' ? "1" : "0") + request.Nonce[1..] }; });
        var plan = delivery.PreviewUpdate(fixture.Target, None); var result = delivery.Update(fixture.Target, plan.Confirmation, None);
        Check.True(reached, "refus après remplacement et contrôle, pas au setup");
        Check.Equal("rolledBack", result.Action, "restauration distincte d’un succès de mise à jour");
        Check.False(result.HealthConfirmed, "aucune santé inventée");
        using var active = PackageIntegrity.Open(fixture.Target, true); Check.Equal(before, active.ManifestHash, "ancien paquet réellement conforme");
        Check.Equal("operator configuration exact", File.ReadAllText(configuration), "réglages conservés octet pour octet");
        Check.Equal(dataHash, Hash(externalData), "base réelle non ouverte ni restaurée");
        Check.True(File.Exists(Path.Combine(fixture.Storage, result.Transaction, "health", "outcome-1.json")), "bilan de retour conservé");
    }

    [Test]
    public static void Health_child_without_confirmed_physical_exit_leaves_pending_and_both_verified_copies()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b')); var reached = false;
        var delivery = HealthDelivery(fixture, (_, _) => { reached = true; throw new PackageHealthException("Child remains alive", childExited: false); });
        var plan = delivery.PreviewUpdate(fixture.Target, None);
        var error = Check.Throws<PackageHealthException>(() => delivery.Update(fixture.Target, plan.Confirmation, None), "pas de remplacement sous enfant vivant");
        Check.False(error.ChildExited, "cause physique exacte"); Check.True(reached, "contrôle atteint");
        Check.True(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "marqueur bloquant conservé");
        using var backup = PackageIntegrity.Open(fixture.Backup, true);
        using var staged = PackageIntegrity.Open(Path.Combine(fixture.Storage, fixture.Transaction, "new"), true);
        Check.True(backup.ManifestHash != staged.ManifestHash, "deux ensembles distincts vérifiés restent présents");
        Check.Throws<InvalidDataException>(() => PackageIntegrity.Open(fixture.Target, true).Dispose(), "aucun lancement ordinaire");
    }

    [Test]
    public static void Health_required_recovery_cannot_be_bypassed_by_legacy_command_or_replay_of_previous_ack()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b')); PackageHealthReceipt? previous = null;
        var interrupted = HealthDelivery(fixture, (request, _) =>
        { previous = Healthy(request); throw new PackageHealthException("Termination unknown", childExited: false); });
        var update = interrupted.PreviewUpdate(fixture.Target, None);
        Check.Throws<PackageHealthException>(() => interrupted.Update(fixture.Target, update.Confirmation, None), "interruption réelle au contrôle");
        Check.True(previous is not null, "premier accusé construit au point exact");
        var ordinary = fixture.Delivery(); var preview = ordinary.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        Check.True(preview.RequiresHealth, "contrainte persistée dans le journal");
        var markerHash = Hash(Path.Combine(fixture.Target, ".update.pending"));
        Check.Throws<InvalidDataException>(() => ordinary.Recover(fixture.Target, fixture.Transaction, false, preview.Confirmation, None), "ancien chemin sans assistant refusé");
        Check.Equal(markerHash, Hash(Path.Combine(fixture.Target, ".update.pending")), "refus sans réécriture du marqueur");
        var replay = HealthDelivery(fixture, (_, _) => previous!);
        var replayPlan = replay.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        var refused = replay.Recover(fixture.Target, fixture.Transaction, false, replayPlan.Confirmation, None);
        Check.Equal("rolledBack", refused.Action, "ancien accusé refusé et binaires antérieurs restaurés");
        Check.False(refused.HealthConfirmed, "rejeu jamais affiché comme sain");
        var fresh = HealthDelivery(fixture, (request, _) => Healthy(request));
        var freshPlan = fresh.PreviewRecovery(fixture.Target, fixture.Transaction, false, None);
        var result = fresh.Recover(fixture.Target, fixture.Transaction, false, freshPlan.Confirmation, None);
        Check.True(result.HealthConfirmed, "nouvel accusé seulement après reprise explicite");
        using var active = PackageIntegrity.Open(fixture.Target, true); Check.Equal(result.ActiveIdentity, active.ManifestHash, "reprise vérifiée");
        Check.True(File.Exists(Path.Combine(fixture.Storage, fixture.Transaction, "health", "ack-3.json")), "tentatives distinctes conservées");
    }

    [Test]
    public static void Failed_replacement_rolls_back_without_starting_health_or_erasing_interruption_evidence()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b')); var stopped = false; var healthCalls = 0;
        var before = Hash(Path.Combine(fixture.Target, PackageIntegrity.ManifestName));
        var delivery = HealthDelivery(fixture, (request, _) => { healthCalls++; return Healthy(request); }, point =>
        { if (point == "component-replaced" && !stopped) { stopped = true; throw new IOException("Interrupted replacement"); } });
        var plan = delivery.PreviewUpdate(fixture.Target, None); var result = delivery.Update(fixture.Target, plan.Confirmation, None);
        Check.True(stopped, "au moins un remplacement réel effectué avant échec");
        Check.Equal(0, healthCalls, "santé jamais annoncée pour un ensemble incomplet"); Check.Equal("rolledBack", result.Action, "retour explicite");
        using var active = PackageIntegrity.Open(fixture.Target, true); Check.Equal(before, active.ManifestHash, "anciens octets vérifiés");
        Check.True(File.Exists(Path.Combine(fixture.Storage, fixture.Transaction, "transaction.json")), "journal durable conservé");
    }

    [Test]
    public static void A_foreign_change_that_prevents_rollback_keeps_pending_and_does_not_overwrite_it()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b')); var changed = false;
        var delivery = HealthDelivery(fixture, (_, _) => throw new PackageHealthException("Health failed after exit", true), point =>
        {
            // Before final verification pins the installed components, emulate a foreign writer during replacement.
            if (point == "component-replaced" && !changed)
            { changed = true; File.WriteAllText(Path.Combine(fixture.Target, "Domenia.exe"), "foreign bytes"); throw new IOException("Foreign writer"); }
        });
        var plan = delivery.PreviewUpdate(fixture.Target, None);
        Check.Throws<InvalidDataException>(() => delivery.Update(fixture.Target, plan.Confirmation, None), "restauration empêchée par octets étrangers");
        Check.True(changed, "interleaving atteint");
        Check.Equal("foreign bytes", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "aucun écrasement des octets étrangers");
        Check.True(File.Exists(Path.Combine(fixture.Target, ".update.pending")), "pending reste bloquant");
        using var backup = PackageIntegrity.Open(fixture.Backup, true); Check.True(backup.Packaged, "sauvegarde indépendante intacte");
    }

    [Test]
    public static void Required_health_without_checker_or_release_is_refused_before_any_transaction()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b'));
        var delivery = new PackageLifecycle(fixture.Source, TestClock.Fixed()) { RequireHealth = true, SignatureVerifier = UnsignedFixture, PublisherPolicy = PackagePublisherPolicy.Unconfigured };
        var plan = delivery.PreviewUpdate(fixture.Target, None); Check.True(plan.RequiresHealth, "aperçu positif");
        Check.Throws<InvalidDataException>(() => delivery.Update(fixture.Target, plan.Confirmation, None), "absence de contrôle refusée");
        Check.False(Directory.Exists(fixture.Storage), "aucune transaction créée");
        using var legacy = new Fixture();
        var missing = new PackageLifecycle(legacy.Source, TestClock.Fixed()) { RequireHealth = true, SignatureVerifier = UnsignedFixture, PublisherPolicy = PackagePublisherPolicy.Unconfigured };
        Check.Throws<InvalidDataException>(() => missing.PreviewUpdate(legacy.Target, None), "identité requise pour un accusé fiable");
        Check.False(Directory.Exists(legacy.Storage), "paquet historique laissé intact");
    }

    [Test]
    public static void Extended_release_metadata_is_optional_but_qualifies_project_platform_and_executable_bytes()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b'));
        using (var original = PackageIntegrity.Open(fixture.Source, true))
        { Check.Equal(Release('b'), PackageLifecycle.Release(fixture.Source, original.Components), "ancien format sans nouveaux champs accepté"); }
        var next = Release('b') with { Project = "Domenia", Architecture = "win-x64", PackageType = "PROD", SourceCommit = new string('a', 40),
            ExecutableSha256 = Hash(Path.Combine(fixture.Source, "Domenia.exe")), Dependencies = new Dictionary<string, string> { [".NET"] = "10.0.0", ["WebView2"] = "fixture" } };
        void Write(PackageRelease value)
        {
            File.WriteAllText(Path.Combine(fixture.Source, "package-release.json"), JsonSerializer.Serialize(value, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
            Manifest(fixture.Source, Components.Append("package-release.json"));
        }
        Write(next); var plan = fixture.Delivery().PreviewUpdate(fixture.Target, None);
        Check.Equal("PROD", plan.SourceRelease?.PackageType, "précondition complète positive");
        foreach (var invalid in new[] { next with { Project = "Other" }, next with { Architecture = "x86" }, next with { SourceCommit = "bad" }, next with { ExecutableSha256 = new string('0', 64) } })
        {
            Write(invalid); Check.Throws<InvalidDataException>(() => fixture.Delivery().PreviewUpdate(fixture.Target, None), "métadonnée incohérente refusée");
            Check.False(Directory.Exists(fixture.Storage), "aucune préparation pour une identité invalide");
        }
    }

    [Test]
    public static void Health_command_reports_rollback_with_nonzero_exit_code_and_preserves_the_old_package()
    {
        using var fixture = new Fixture(old: Release('a'), next: Release('b')); using var output = new StringWriter();
        var calls = 0;
        PackageHealthReceipt Failed(PackageHealthRequest request, CancellationToken token)
        { calls++; return Healthy(request) with { ScriptReady = false }; }
        Check.Equal(0, PackageLifecycleCommand.Run(fixture.Source, ["livraison", "apercu", fixture.Target], output, TestClock.Fixed(), healthCheck: Failed, signatureVerifier: UnsignedFixture), "aperçu sain sans contrôle anticipé");
        Check.Equal(0, calls, "l’aperçu ne lance rien");
        using var preview = JsonDocument.Parse(output.ToString()); var confirmation = preview.RootElement.GetProperty("Confirmation").GetString()!;
        Check.True(preview.RootElement.GetProperty("RequiresHealth").GetBoolean(), "contrat santé visible dans l’aperçu CLI");
        output.GetStringBuilder().Clear();
        Check.Equal(3, PackageLifecycleCommand.Run(fixture.Source, ["livraison", "appliquer", fixture.Target, confirmation], output, TestClock.Fixed(), healthCheck: Failed, signatureVerifier: UnsignedFixture), "restauré ne signifie pas mise à jour réussie");
        Check.Equal(1, calls, "contrôle réellement atteint après copie");
        using var result = JsonDocument.Parse(output.ToString()); Check.Equal("rolledBack", result.RootElement.GetProperty("Action").GetString(), "bilan explicite");
        Check.Equal("old:Domenia.exe", File.ReadAllText(Path.Combine(fixture.Target, "Domenia.exe")), "ancienne version conservée");
    }

}
