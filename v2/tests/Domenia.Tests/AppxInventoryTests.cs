using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class AppxInventoryTests
{
    private const string Ns = "http://schemas.microsoft.com/wbem/wsman/1/windows/shell";
    private const string Shell = "11111111-2222-3333-4444-555555555555";
    private const string Command = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    private static string Payload(string host = "PC1", int code = 0, bool truncated = false) => JsonSerializer.Serialize(new
    {
        Format = "Domenia.AppxRead/1", Computer = host, Code = code, Truncated = truncated,
        Rows = new[] { new { Name = "App.Store", Version = "1.2", Publisher = "CN=Éditeur", Architecture = "X64", Location = @"C:\Program Files\WindowsApps\App", Secret = "NEVER-RETAIN" } },
    });
    private static string Frame(string command = Command, string state = "Done", string data = "") =>
        "<ReceiveResponse xmlns='" + Ns + "'><Stream Name='stdout' CommandId='" + command + "'>" + Convert.ToBase64String(Encoding.UTF8.GetBytes(data))
        + "</Stream><CommandState CommandId='" + command + "' State='" + Ns + "/CommandState/" + state + "'><ExitCode>0</ExitCode></CommandState></ReceiveResponse>";

    private sealed class Wire : IReadShellWire
    {
        internal int Creates, Commands, Deletes;
        internal string? Deleted, Script;
        internal bool FailCreate, FailDelete, Disposed;
        internal Func<string>? Read;
        public string Create(TimeSpan timeout, string input)
        {
            Creates++;
            if (FailCreate) { throw new COMException("response lost", unchecked((int)0x800706BE)); }
            return "<Shell xmlns='" + Ns + "'><ShellId>" + Shell + "</ShellId></Shell>";
        }
        public string Command(TimeSpan timeout, string shellId, string input)
        {
            Commands++;
            Check.Equal(Shell, shellId, "commande attachée au seul shell créé");
            var args = XElement.Parse(input).Element(XName.Get("Arguments", Ns))!.Value;
            var encoded = args[(args.LastIndexOf(' ') + 1)..];
            Script = Encoding.Unicode.GetString(Convert.FromBase64String(encoded));
            return "<CommandResponse xmlns='" + Ns + "'><CommandId>" + AppxInventoryTests.Command + "</CommandId></CommandResponse>";
        }
        public string Receive(TimeSpan timeout, string input) => Read?.Invoke() ?? Frame(data: Payload());
        public void Delete(TimeSpan timeout, string shellId)
        {
            Deletes++; Deleted = shellId;
            Check.Equal(TimeSpan.FromSeconds(2), timeout, "fermeture bornée");
            if (FailDelete) { throw new COMException("response lost"); }
        }
        public void Dispose() { Disposed = true; }
    }

    [Test]
    public static void Appx_shell_is_one_fixed_read_and_deletes_only_its_own_shell()
    {
        var wire = new Wire();
        using var channel = new WsmanReadChannel("PC1", null, TestClock.Fixed(), CancellationToken.None) { ShellOverride = wire };
        var result = channel.ReadAppx(TimeSpan.FromSeconds(58));
        Check.Equal(SourceStatus.Ok, result.Status, "lecture rendue");
        Check.Equal(1, wire.Creates, "une création"); Check.Equal(1, wire.Commands, "une commande"); Check.Equal(1, wire.Deletes, "une fermeture");
        Check.Equal(Shell, wire.Deleted, "aucun autre shell visé"); Check.True(wire.Disposed && result.CleanupComplete, "ressources libérées");
        Check.True(wire.Script!.Contains("Get-AppxPackage -AllUsers -ErrorAction Stop", StringComparison.Ordinal), "lecture fixe et refus non masqué");
        var parsed = CimSession.ParseAppx(result.Json!, "PC1.test.local");
        Check.Equal("App.Store", parsed.Instances.Single().Text("Name"), "projection du paquet");
        Check.Null(parsed.Instances.Single().Raw("Secret"), "aucun champ supplémentaire retenu");
    }

    [Test]
    public static void Appx_cancel_cleans_up_and_lost_creation_or_cleanup_is_never_reported_as_confirmed()
    {
        using var stop = new CancellationTokenSource();
        var wire = new Wire { Read = () => { stop.Cancel(); return Frame(state: "Running"); } };
        using var channel = new WsmanReadChannel("PC1", null, TestClock.Fixed(), stop.Token) { ShellOverride = wire };
        var result = channel.ReadAppx(TimeSpan.FromSeconds(58));
        Check.Equal(SourceStatus.Interrupted, result.Status, "arrêt respecté");
        Check.Equal(1, wire.Deletes, "fermeture malgré le jeton annulé"); Check.True(result.CleanupComplete, "fermeture connue");
        wire = new Wire { FailCreate = true };
        using var lost = new WsmanReadChannel("PC1", null, TestClock.Fixed(), CancellationToken.None) { ShellOverride = wire };
        result = lost.ReadAppx(TimeSpan.FromSeconds(58));
        Check.False(result.CleanupComplete, "création sans réponse : fermeture inconnue");
        Check.Equal(1, wire.Creates, "jamais de deuxième création"); Check.Equal(0, wire.Deletes, "aucune suppression sans identité");
        wire = new Wire { FailDelete = true };
        using var cleanup = new WsmanReadChannel("PC1", null, TestClock.Fixed(), CancellationToken.None) { ShellOverride = wire };
        Check.False(cleanup.ReadAppx(TimeSpan.FromSeconds(58)).CleanupComplete, "échec de fermeture explicite");
        Check.Equal(1, wire.Deletes, "pas de boucle de fermeture");
    }

    [Test]
    public static void Appx_receive_timeout_continues_the_same_command_without_relaunching_it()
    {
        var reads = 0;
        var wire = new Wire { Read = () => ++reads == 1 ? throw new COMException("wait", unchecked((int)0x80338029)) : Frame(data: Payload()) };
        using var channel = new WsmanReadChannel("PC1", null, TestClock.Fixed(), CancellationToken.None) { ShellOverride = wire };
        Check.Equal(SourceStatus.Ok, channel.ReadAppx(TimeSpan.FromSeconds(58)).Status, "réception poursuivie");
        Check.Equal(2, reads, "deux réceptions"); Check.Equal(1, wire.Creates, "un shell"); Check.Equal(1, wire.Commands, "une commande");
        Check.Equal<SourceStatus?>(SourceStatus.Interrupted, CimSession.Classify(new COMException("wait", unchecked((int)0x80338029))), "délai CIM WinRM distingué d’une erreur");
    }

    [Test]
    public static void Appx_rejects_foreign_command_output_and_wrong_machine_identity()
    {
        var wire = new Wire { Read = () => Frame(Guid.NewGuid().ToString("D"), data: Payload()) };
        using var channel = new WsmanReadChannel("PC1", null, TestClock.Fixed(), CancellationToken.None) { ShellOverride = wire };
        var result = channel.ReadAppx(TimeSpan.FromSeconds(58));
        Check.Equal(SourceStatus.Error, result.Status, "sortie étrangère écartée");
        Check.Null(result.Json, "aucune donnée étrangère"); Check.Equal(Shell, wire.Deleted, "fermeture du shell créé seulement");
        var rejected = false;
        try { CimSession.ParseAppx(Payload("OTHER"), "PC1"); } catch (JsonException) { rejected = true; }
        Check.True(rejected, "identité de poste différente refusée");
        rejected = false;
        try { CimSession.ParseAppx(Payload().Replace("\"Code\":0", "\"Code\":\"0\"", StringComparison.Ordinal), "PC1"); } catch (JsonException) { rejected = true; }
        Check.True(rejected, "type de résultat illisible refusé");
    }

    [Test]
    public static void Appx_truncation_and_unconfirmed_cleanup_are_partial_and_transport_option_is_respected()
    {
        Check.Equal(SourceStatus.Partial, CimSession.ParseAppx(Payload(truncated: true), "PC1").Status, "plafond explicite");
        var calls = 0;
        using var dcom = new CimSession("PC1", TimeSpan.FromSeconds(130), TestClock.Fixed()) { AppxOverride = _ => { calls++; return new(SourceStatus.Ok, Payload(), false, true); } };
        Check.Equal(SourceStatus.Unavailable, dcom.ReadAppx().Status, "aucun WinRM implicite"); Check.Equal(0, calls, "aucun contact");
        using var winrm = new CimSession("PC1", TimeSpan.FromSeconds(130), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        {
            AppxOverride = budget => { Check.Equal(TimeSpan.FromSeconds(58), budget, "deux secondes réservées à la fermeture"); return new(SourceStatus.Ok, Payload(), false, false); },
        };
        var result = winrm.ReadAppx();
        Check.Equal(SourceStatus.Partial, result.Status, "nettoyage incertain explicite"); Check.Equal(1, result.Items, "paquet déjà lu conservé");
        Check.True(result.Detail.Contains("Fermeture", StringComparison.Ordinal), "opérateur informé");
    }
}
