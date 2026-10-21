using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class BridgeJsonTests
{
    private sealed record Sample(DateTimeOffset At, DateTimeOffset? Missing, DateOnly Day, Tone Tone, ModeReason Reason, string? Note);

    [Test]
    public static void Dates_enums_and_nulls_follow_the_contract()
    {
        var sample = new Sample(
            new DateTimeOffset(2026, 10, 21, 18, 14, 7, 456, TimeSpan.FromHours(2)),
            null,
            new DateOnly(2026, 10, 21),
            Tone.Alert,
            ModeReason.NotDomainJoined,
            null);
        var json = JsonSerializer.Serialize(sample, BridgeJson.Options);
        Check.Equal("{\"at\":\"2026-10-21T16:14:07Z\",\"missing\":null,\"day\":\"2026-10-21\",\"tone\":\"alert\",\"reason\":\"notDomainJoined\",\"note\":null}", json, "JSON du contrat");
    }

    [Test]
    public static void Error_is_written_only_when_set()
    {
        var result = JsonSerializer.Serialize(new BridgeResponse("r1", "result", "app.info", null), BridgeJson.Options);
        Check.Equal("{\"id\":\"r1\",\"kind\":\"result\",\"op\":\"app.info\",\"data\":null}", result, "réponse sans erreur");
        var error = JsonSerializer.Serialize(new BridgeResponse("r2", "error", "x.y", null, new BridgeError("widget.unknown", "Inconnu.")), BridgeJson.Options);
        Check.Contains("\"error\":{\"code\":\"widget.unknown\",\"message\":\"Inconnu.\"}", error, "erreur présente");
        Check.Contains("\"data\":null", error, "data nul écrit");
    }

    [Test]
    public static void Mode_text_is_annuaire_in_directory_mode()
    {
        var info = AppInfoBuilder.Build(ModeResolver.Resolve([], "0", () => throw new TestFailureException("sonde")), "10.0.12", "windows");
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(info, BridgeJson.Options));
        var root = document.RootElement;
        Check.Equal("annuaire", root.GetProperty("mode").GetString(), "mode annuaire");
        Check.Equal("environmentOptOut", root.GetProperty("modeReason").GetString(), "raison camelCase");
        Check.Equal(JsonValueKind.Null, root.GetProperty("banner").ValueKind, "bannière nulle écrite");
        string[] names = [.. root.EnumerateObject().Select(p => p.Name)];
        Check.True(names.SequenceEqual(["name", "version", "runtime", "webViewRuntime", "mode", "modeLabel", "modeReason", "modeDetail", "banner"]), "champs de app.info");
    }

    [Test]
    public static void Arguments_validation_never_copies_the_input()
    {
        using var document = JsonDocument.Parse("{\"id\":\"diskAlerts\",\"motDePasse\":\"Secret123\"}");
        var error = Check.Throws<BridgeOperationException>(() => BridgeArguments.ReadObject(document.RootElement, ["id"]), "propriété en trop refusée");
        Check.Equal("arguments.invalid", error.Code, "code");
        Check.Equal("Arguments invalides : propriété non admise.", error.Message, "précision fixe");
        Check.False(error.Message.Contains("Secret123", StringComparison.Ordinal) || error.Message.Contains("motDePasse", StringComparison.Ordinal), "saisie jamais recopiée");
        BridgeArguments.RequireNone(default);
        using var empty = JsonDocument.Parse("{}");
        BridgeArguments.RequireNone(empty.RootElement);
        using var number = JsonDocument.Parse("3");
        Check.Equal("Arguments invalides : un objet JSON est attendu.", Check.Throws<BridgeOperationException>(() => BridgeArguments.RequireNone(number.RootElement), "nombre refusé").Message, "objet attendu");
    }
}
