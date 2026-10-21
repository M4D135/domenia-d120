using System.Text.Json;
using Domenia.Bridge;

namespace Domenia.Tests;

internal static class BridgeTests
{
    private static (BridgeDispatcher Dispatcher, List<BridgeResponse> Sent) Create()
    {
        var sent = new List<BridgeResponse>();
        var registry = new OperationRegistry(
        [
            new OperationDefinition("test.echo", OperationClass.Local, (args, _, _) => Task.FromResult<object?>(args.GetProperty("value").GetInt32() + 1), "echo"),
            new OperationDefinition("test.fail", OperationClass.Local, (_, _, _) => throw new BridgeOperationException("demo.refused", "Refusé."), "fail"),
        ]);
        return (new BridgeDispatcher(registry, sent.Add), sent);
    }

    [Test]
    public static async Task Declared_operation_answers_with_its_result()
    {
        var (d, sent) = Create();
        await d.HandleAsync("""{"id":"r1","op":"test.echo","args":{"value":41}}""", CancellationToken.None);
        Check.Equal("result", sent.Single().Kind, "type de réponse");
        Check.Equal(42, (int)sent.Single().Data!, "valeur");
    }

    [Test]
    public static async Task Unknown_operation_is_refused_without_running()
    {
        var (d, sent) = Create();
        await d.HandleAsync("""{"id":"r2","op":"ad.deleteEverything","args":{}}""", CancellationToken.None);
        Check.Equal("operation.unknown", sent.Single().Error!.Code, "code d'erreur");
    }

    [Test]
    public static async Task Malformed_and_oversized_messages_are_refused()
    {
        var (d, sent) = Create();
        await d.HandleAsync("{not json", CancellationToken.None);
        await d.HandleAsync(new string('x', BridgeDispatcher.MaxMessageLength + 1), CancellationToken.None);
        Check.Equal("message.json", sent[0].Error!.Code, "JSON illisible");
        Check.Equal("message.size", sent[1].Error!.Code, "taille");
    }

    [Test]
    public static async Task Expected_failure_keeps_its_code_and_message()
    {
        var (d, sent) = Create();
        await d.HandleAsync("""{"id":"r3","op":"test.fail","args":{}}""", CancellationToken.None);
        Check.Equal("demo.refused", sent.Single().Error!.Code, "code");
    }

    [Test]
    public static async Task Refusals_are_reported_with_their_code_and_declared_name_only()
    {
        var (d, sent) = Create();
        var refused = new List<(string Code, string? Operation)>();
        d.Refused += (code, operation) => refused.Add((code, operation));
        await d.HandleAsync("{not json", CancellationToken.None);
        await d.HandleAsync("""{"id":"r1","op":"test.absent","args":{}}""", CancellationToken.None);
        await d.HandleAsync("""{"id":"r2","op":"Pas Valide <motdepasse>","args":{}}""", CancellationToken.None);
        await d.HandleAsync("""{"id":"r3","op":"test.fail","args":{}}""", CancellationToken.None);
        await d.HandleAsync("""{"id":"r4","op":"test.echo","args":{"value":1}}""", CancellationToken.None);
        Check.Equal(5, sent.Count, "chaque message reçoit une réponse");
        Check.Equal(4, refused.Count, "quatre refus signalés, aucun pour la réponse normale");
        Check.Equal(("message.json", (string?)null), refused[0], "JSON illisible, sans contenu");
        Check.Equal(("operation.unknown", (string?)"test.absent"), refused[1], "nom bien formé signalé");
        Check.Equal(("operation.unknown", (string?)null), refused[2], "nom mal formé jamais recopié");
        Check.Equal(("demo.refused", (string?)"test.fail"), refused[3], "refus de l’opération avec son nom déclaré");
    }

    [Test]
    public static void Operation_names_are_strict()
    {
        Check.True(OperationRegistry.IsValidName("search.run"), "nom valide");
        Check.True(!OperationRegistry.IsValidName("Search.Run"), "majuscule refusée");
        Check.True(!OperationRegistry.IsValidName("run"), "un seul segment refusé");
        Check.True(!OperationRegistry.IsValidName("a.b-c"), "tiret refusé");
        _ = JsonDocument.Parse("{}");
    }
}
