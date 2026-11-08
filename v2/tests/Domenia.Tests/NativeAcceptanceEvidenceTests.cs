using System.Security.Cryptography;
using System.Text.Json;

namespace Domenia.Tests;

internal static class NativeAcceptanceEvidenceTests
{
    private static JsonElement[] Events(string path) => File.ReadAllLines(path).Select(line =>
    {
        using var json = JsonDocument.Parse(line);
        return json.RootElement.Clone();
    }).ToArray();

    [Test]
    public static async Task Native_evidence_reads_back_real_bytes_without_promoting_return_to_acceptance()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("evidence.jsonl");
        var guards = 0; (long Bytes, string Sha256) measured;
        using (var evidence = new NativeAcceptanceEvidence(path, TestClock.Fixed()))
        {
            evidence.BeforeRead = _ => { guards++; return Task.CompletedTask; };
            await evidence.Read("fixture.read", _ => Task.FromResult(new { state = "Unknown", detail = "Pas de donnée observée" }));
            Check.Equal(2, guards, "identités réellement requalifiées avant et après le retour");
            evidence.Finish(canaryRequested: false); measured = evidence.Measure();
            Check.Throws<InvalidOperationException>(() => evidence.Save("late", new { }), "aucune ligne après terminaison");
            Check.Equal(measured, evidence.Measure(), "refus sans modifier les octets");
        }
        var bytes = File.ReadAllBytes(path);
        Check.Equal((long)bytes.Length, measured.Bytes, "longueur relue après fermeture");
        Check.Equal(Convert.ToHexStringLower(SHA256.HashData(bytes)), measured.Sha256, "SHA des octets réellement conservés");
        var events = Events(path); Check.Equal(3, events.Length, "début, résultat brut, terminaison distincts");
        for (var i = 0; i < events.Length; i++)
        {
            Check.Equal(i + 1, events[i].GetProperty("sequence").GetInt32(), "séquence durable");
            Check.False(events[i].GetProperty("value").GetProperty("qualified").GetBoolean(), "aucun événement ne vaut recette réussie");
        }
        var returned = events[1].GetProperty("value");
        Check.Equal("Returned", returned.GetProperty("state").GetString(), "méthode retournée");
        Check.Equal("Unknown", returned.GetProperty("result").GetProperty("state").GetString(), "état métier inconnu conservé tel quel");
        Check.True(returned.GetProperty("identitiesCheckedAfter").GetBoolean(), "seulement après le second garde réel");
        Check.Equal("ProtocolCompleted", events[2].GetProperty("value").GetProperty("state").GetString(), "fin de protocole explicitement nommée");
    }

    [Test]
    public static void Native_evidence_create_new_preserves_interrupted_run_and_never_invents_a_terminal_event()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("evidence.jsonl");
        using (var evidence = new NativeAcceptanceEvidence(path)) { evidence.Save("canary.plan", new { id = "retained" }); }
        var before = File.ReadAllBytes(path);
        Check.Throws<IOException>(() => { using var duplicate = new NativeAcceptanceEvidence(path); }, "même invocation jamais rouverte pour écrire");
        Check.True(before.SequenceEqual(File.ReadAllBytes(path)), "interruption conserve exactement les preuves précédentes");
        var events = Events(path); Check.Equal(1, events.Length, "Dispose ne fabrique pas une terminaison après interruption");
        Check.Equal("canary.plan", events[0].GetProperty("operation").GetString(), "plan conservé");
    }

    [Test]
    public static async Task Native_evidence_identity_failure_before_or_after_read_aborts_without_false_return()
    {
        using var folder = new TemporaryFolder();
        foreach (var failureAt in new[] { 1, 2 })
        {
            var path = folder.File("guard-" + failureAt + ".jsonl"); var guards = 0; var calls = 0;
            using (var evidence = new NativeAcceptanceEvidence(path))
            {
                evidence.BeforeRead = _ => ++guards == failureAt ? Task.FromException(new InvalidOperationException("Identité changée")) : Task.CompletedTask;
                var failure = await Check.ThrowsAsync<InvalidOperationException>(() => evidence.Read("fixture.read", _ =>
                { calls++; return Task.FromResult(42); }), "échec du garde remonte au pilote, même hors IOException");
                Check.Equal(failureAt == 1 ? 0 : 1, calls, "preuve que la frontière attendue est réellement atteinte");
                Check.Equal(failureAt, guards, "échec au bon garde");
                evidence.Abort(failure);
            }
            var events = Events(path); Check.Equal(2, events.Length, "aucun Returned après identité différente");
            Check.Equal("aborted", events[1].GetProperty("operation").GetString(), "arrêt durable");
            var value = events[1].GetProperty("value");
            Check.Equal("fixture.read.started", value.GetProperty("lastOperation").GetString(), "dernière frontière connue");
            Check.Equal("InvalidOperationException", value.GetProperty("type").GetString(), "cause structurée conservée");
            Check.False(value.GetProperty("qualified").GetBoolean(), "arrêt jamais qualifié");
        }
    }

    [Test]
    public static async Task Native_evidence_operation_failure_is_counted_and_does_not_log_exception_payload()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("failed.jsonl"); var calls = 0;
        using (var evidence = new NativeAcceptanceEvidence(path))
        {
            evidence.BeforeRead = _ => Task.CompletedTask;
            await evidence.Read<int>("fixture.read", _ => { calls++; throw new InvalidOperationException("private diagnostic not to persist"); });
            Check.Equal(1, calls, "l’opération a été invoquée"); Check.Equal(1, evidence.Errors, "échec décompté");
            evidence.Finish(false);
        }
        var events = Events(path);
        Check.Equal("Failed", events[1].GetProperty("value").GetProperty("state").GetString(), "pas de Returned sur exception");
        Check.Equal("ProtocolCompletedWithErrors", events[2].GetProperty("value").GetProperty("state").GetString(), "fin imparfaite explicite");
        Check.False(File.ReadAllText(path).Contains("private diagnostic", StringComparison.Ordinal), "le message arbitraire d’exception n’est pas enregistré");
    }

    [Test]
    public static void Native_evidence_rejects_oversized_event_before_append_and_keeps_room_for_abort()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("bounded.jsonl");
        using (var evidence = new NativeAcceptanceEvidence(path))
        {
            evidence.Save("fixture.first", new { value = 1 }); var before = evidence.Measure();
            var failure = Check.Throws<InvalidDataException>(() => evidence.Save("fixture.large", new { value = new string('x', NativeAcceptanceEvidence.MaximumEventBytes) }), "événement trop grand refusé");
            Check.Contains("Limite", failure.Message, "borne de journal réellement atteinte");
            Check.Equal(before, evidence.Measure(), "aucun octet de la réponse refusée ajouté");
            evidence.Abort(failure);
        }
        Check.Equal(2, Events(path).Length, "preuve précédente et abandon seulement");
        Check.Equal("aborted", Events(path)[1].GetProperty("operation").GetString(), "arrêt encore inscriptible");
    }

    [Test]
    public static async Task Native_evidence_requires_real_identity_guard_and_bounds_event_count_with_terminal_reserve()
    {
        using var folder = new TemporaryFolder(); var path = folder.File("count.jsonl"); var calls = 0;
        using (var evidence = new NativeAcceptanceEvidence(path))
        {
            await Check.ThrowsAsync<InvalidOperationException>(() => evidence.Read("unguarded", _ => { calls++; return Task.FromResult(1); }), "aucune identité vérifiée inventée");
            Check.Equal(0, calls, "pas d’appel sans garde"); Check.Equal(0L, evidence.Measure().Bytes, "pas d’événement trompeur");
            for (var i = 0; i < 128; i++) { evidence.Save("fixture.step", new { step = i }); }
            var before = evidence.Measure();
            var failure = Check.Throws<InvalidDataException>(() => evidence.Save("one.too.many", new { }), "nombre d’événements borné");
            Check.Contains("Limite", failure.Message, "refus du quota attendu");
            Check.Equal(before, evidence.Measure(), "preuve complète précédente intacte");
            evidence.Abort(failure);
        }
        Check.Equal(129, Events(path).Length, "réserve terminale disponible au plafond");
    }
}
