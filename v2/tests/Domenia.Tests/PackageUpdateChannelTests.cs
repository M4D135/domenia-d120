using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using Domenia.App;

namespace Domenia.Tests;

internal static class PackageUpdateChannelTests
{
    private sealed record Message(string Transaction, string Label);

    [Test]
    public static async Task Update_pipe_frames_round_trip_exactly_and_oversized_writes_send_nothing()
    {
        using var stream = new MemoryStream();
        var message = new Message("a123", "Apostrophe ’ | ; +33 et coordonnées -2,3");
        await PackageUpdateChannel.SendAsync(stream, message, CancellationToken.None); stream.Position = 0;
        Check.Equal(message, await PackageUpdateChannel.ReadAsync<Message>(stream, CancellationToken.None), "texte exact via le vrai codec");
        using var oversized = new MemoryStream();
        await Check.ThrowsAsync<InvalidDataException>(() => PackageUpdateChannel.SendAsync(oversized, new Message("a123", new string('x', 16384)), CancellationToken.None), "borne avant émission");
        Check.Equal(0L, oversized.Length, "pas même un en-tête envoyé hors borne");
    }

    [Test]
    public static async Task Update_pipe_rejects_repeated_unknown_and_truncated_fields_without_partial_values()
    {
        static MemoryStream Frame(string json)
        {
            var bytes = Encoding.UTF8.GetBytes(json); var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
            var stream = new MemoryStream(); stream.Write(header); stream.Write(bytes); stream.Position = 0; return stream;
        }
        using var repeated = Frame("{\"transaction\":\"a\",\"transaction\":\"b\",\"label\":\"x\"}");
        await Check.ThrowsAsync<InvalidDataException>(() => PackageUpdateChannel.ReadAsync<Message>(repeated, CancellationToken.None), "transaction répétée refusée");
        using var unknown = Frame("{\"transaction\":\"a\",\"label\":\"x\",\"command\":\"ignored?\"}");
        await Check.ThrowsAsync<JsonException>(() => PackageUpdateChannel.ReadAsync<Message>(unknown, CancellationToken.None), "champ étranger jamais ignoré");
        using var truncated = Frame("{\"transaction\":\"a\",\"label\":\"x\"}"); truncated.SetLength(truncated.Length - 1);
        await Check.ThrowsAsync<EndOfStreamException>(() => PackageUpdateChannel.ReadAsync<Message>(truncated, CancellationToken.None), "message incomplet ne produit aucun objet");
        using var huge = new MemoryStream(); var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, int.MaxValue); huge.Write(header); huge.Position = 0;
        await Check.ThrowsAsync<InvalidDataException>(() => PackageUpdateChannel.ReadAsync<Message>(huge, CancellationToken.None), "taille refusée avant allocation du payload");
    }

    [Test]
    public static async Task Update_pipe_authenticates_the_actual_local_client_and_server_process_ids()
    {
        var name = PackageUpdateChannel.Name(); Check.True(PackageUpdateChannel.ValidName(name), "nom généré admis");
        using var server = PackageUpdateChannel.Server(name); using var client = PackageUpdateChannel.Client(name);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await Task.WhenAll(server.WaitForConnectionAsync(timeout.Token), client.ConnectAsync(timeout.Token));
        PackageUpdateChannel.VerifyClient(server, Environment.ProcessId); PackageUpdateChannel.VerifyServer(client, Environment.ProcessId);
        Check.Throws<UnauthorizedAccessException>(() => PackageUpdateChannel.VerifyClient(server, -1), "PID client étranger refusé après vraie connexion");
        Check.Throws<UnauthorizedAccessException>(() => PackageUpdateChannel.VerifyServer(client, -1), "PID serveur étranger refusé après vraie connexion");
        var read = PackageUpdateChannel.ReadAsync<Message>(client, timeout.Token);
        await PackageUpdateChannel.SendAsync(server, new Message("owned", "Canal privé local"), timeout.Token);
        Check.Equal("owned", (await read).Transaction, "précondition positive du canal utilisable");
    }

    [Test]
    public static void Update_pipe_names_are_closed_and_cannot_designate_another_named_pipe()
    {
        foreach (var name in new[] { "other", "Domenia-update-", "Domenia-update-" + new string('a', 31), "Domenia-update-" + new string('a', 33), "\\\\server\\pipe\\Domenia-update-" + new string('a', 32) })
        { Check.False(PackageUpdateChannel.ValidName(name), "nom externe ou ambigu refusé"); }
        Check.True(PackageUpdateChannel.ValidName("Domenia-update-" + new string('a', 32)), "forme exacte admise");
    }
}
