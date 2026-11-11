using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class NativeReadDiagnosticsTests
{
    [Test]
    public static void Reading_process_warmup_is_local_repeatable_and_has_its_own_phase()
    {
        // Bench of 11/11/2026: the cold path of a fresh reading process (9.5 s for the first DCOM source) plus a 4.2 s
        // WinRM refusal passed the first request's deadline. The preparation runs in the startup bound, in memory only.
        NativeReadProtocol.Prime();
        NativeReadProtocol.Prime();
        NativeReadWarmup.Run(InventoryTransport.Dcom);
        NativeReadWarmup.Run(InventoryTransport.WinRm);
        var frame = NativeReadDiagnostics.Capture(NativeReadDiagnostics.Phase.Warmup, new System.Runtime.InteropServices.COMException("PRIVATE-WARMUP", unchecked((int)0x80040154)));
        Check.Equal(frame, NativeReadDiagnostics.TryParse(NativeReadDiagnostics.Encode(frame)), "phase de préparation transportée");
        string? path = null;
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
            for (DirectoryInfo? current = new(start); current is not null && path is null; current = current.Parent)
                foreach (var candidate in new[] { Path.Combine(current.FullName, "v2", "src"), Path.Combine(current.FullName, "src") })
                    if (File.Exists(Path.Combine(candidate, "Domenia.Inventory", "NativeReadWarmup.cs"))) { path = Path.Combine(candidate, "Domenia.Inventory", "NativeReadWarmup.cs"); break; }
        var source = File.ReadAllText(path ?? throw new TestFailureException("Source de la préparation introuvable."));
        foreach (var contact in new[] { ".Connect(", ".Get(", "CreateSession", "Enumerate(", "Identify(", "Dns.", "Socket" })
        { Check.False(source.Contains(contact, StringComparison.Ordinal), "aucun contact dans la préparation : " + contact); }
    }

    [Test]
    public static async Task Child_diagnostic_keeps_only_bounded_facts_and_rejects_arbitrary_stderr()
    {
        var error = new Win32Exception(5, "PRIVATE-DIAGNOSTIC-MESSAGE");
        error.Data["PRIVATE-DIAGNOSTIC-DATA"] = "PRIVATE-DIAGNOSTIC-VALUE";
        var captured = NativeReadDiagnostics.Capture(NativeReadDiagnostics.Phase.Execute, error);
        var bytes = NativeReadDiagnostics.Encode(captured);
        var decoded = NativeReadDiagnostics.TryParse(bytes);
        Check.Equal(captured, decoded, "faits exacts transportés");
        Check.Equal(error.HResult, decoded!.HResult, "code original");
        Check.Equal(5, decoded.Win32Code!.Value, "code Win32 distinct");
        Check.False(Encoding.ASCII.GetString(bytes).Contains("PRIVATE-", StringComparison.Ordinal), "ni message ni Data");
        Check.True(bytes.Length <= NativeReadDiagnostics.MaxFrameBytes, "trame bornée");
        using var valid = new MemoryStream(bytes);
        Check.Equal(captured, await NativeReadDiagnostics.ReadAsync(valid), "lecture jusqu’à EOF");

        foreach (var text in new[]
        {
            "", "arbitrary runtime exception text", "DR1|999|System.Exception|80004005|",
            "DR1|0|System.Exception|80004005|", "DR1|Execute||80004005|",
            "DR1|Execute|System.Exception|5|", "DR1|Execute|System.Exception|80004005|5",
            "DR1|Execute|Bad;field|80004005|", "DR1|Execute|Bad\nType|80004005|",
            "DR1|Execute|BadéType|80004005|", Encoding.ASCII.GetString(bytes) + "\n",
            Encoding.ASCII.GetString(bytes) + Encoding.ASCII.GetString(bytes), new string('X', 513),
        })
        {
            var malformed = Encoding.UTF8.GetBytes(text);
            Check.Null(NativeReadDiagnostics.TryParse(malformed), "trame malformée rejetée intégralement");
            using var stream = new MemoryStream(malformed);
            Check.Null(await NativeReadDiagnostics.ReadAsync(stream), "aucun stderr brut conservé");
            Check.Equal(stream.Length, stream.Position, "flux invalide drainé sans accumulation");
        }
    }

    [Test]
    public static async Task Real_worker_reports_its_validation_exception_and_natural_exit_without_contact()
    {
        var before = NativeReadProcess.Running;
        var name = "Domenia.NativeRead." + Guid.NewGuid().ToString("N");
        using var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var child = NativeReadProcess.Start(name);
        using var process = Process.GetProcessById(child.Id);
        await pipe.WaitForConnectionAsync(deadline.Token);
        NativeReadProcess.VerifyClient(pipe, child.Id);
        // A malformed hello is rejected by the real worker before a session or native contact exists.
        await NativeReadProtocol.WriteAsync(pipe, new NativeReadHello("", InventoryTransport.Dcom, 20000, true, null, false, false), NativeReadProtocol.RequestLimit, deadline.Token);
        await NativeReadProtocol.WritePasswordAsync(pipe, null, deadline.Token);
        await Check.ThrowsAsync<EndOfStreamException>(() => NativeReadProtocol.ReadAsync<bool>(pipe, 32, deadline.Token), "aucun acquittement de hello invalide");
        await process.WaitForExitAsync(deadline.Token);
        child.Stop();
        var observed = child.ExitObservation!;
        Check.NotNull(observed.Failure, "exception originale transmise par le vrai catch enfant");
        var failure = observed.Failure!;
        Check.Equal(NativeReadDiagnostics.Phase.ValidateHello, failure.Stage, "phase exacte avant contact");
        Check.Equal(typeof(InvalidDataException).FullName, failure.ExceptionType, "type original");
        Check.Equal(2, observed.ExitCode, "sortie naturelle du catch");
        Check.False(observed.ParentTerminationRequested, "aucune terminaison parent inventée après sortie naturelle");
        child.Dispose();
        Check.Equal(before, NativeReadProcess.Running, "place restituée après fin physique");
    }

    [Test]
    public static async Task Client_keeps_child_diagnostic_after_cleanup_and_drains_oversize_without_replay()
    {
        foreach (var mode in new[] { "fault", "oversize" })
        {
            var before = NativeReadProcess.Running;
            var journal = new Journal();
            var hello = new NativeReadHello("PC-TEST", InventoryTransport.Dcom, 60000, true, null, false, false);
            var request = new NativeReadRequest(NativeReadKind.Query, 20000)
            { Category = "system", Namespace = @"root\cimv2", Query = "SELECT Name FROM Win32_ComputerSystem", MaxItems = 1 };
            using var client = new NativeReadClient(hello, null, default, adaptive: new AdaptiveReadBudget(TimeProvider.System), journal: journal);
            await Check.ThrowsAsync<EndOfStreamException>(() => client.ReadAsync(request,
                NativeReadDiagnosticFixture.Prefix + mode + "-" + Guid.NewGuid().ToString("N")), "EOF original conservé");
            Check.Equal(before, NativeReadProcess.Running, "aucun enfant vivant après l’exception");
            Check.Equal(before, journal.Running.Single(), "journal après restitution physique");
            var warning = journal.Warnings.Single();
            Check.Contains("childExitCode=0x00000002;", warning, "code de sortie observé");
            Check.Contains("parentTerminationRequested=", warning, "origine d’une éventuelle terminaison explicite");
            Check.Contains("callerCancellation=False; requestDeadline=False;", warning, "aucun faux timeout");
            if (mode == "fault")
            {
                Check.Contains("childPhase=Execute; childType=System.ComponentModel.Win32Exception;", warning, "faits validés conservés après Dispose");
                Check.Contains("childWin32=0x00000005;", warning, "code natif distinct");
            }
            else { Check.Contains("childPhase=absent; childType=absent;", warning, "flux trop long entièrement rejeté"); }
            Check.False(warning.Contains("PRIVATE-", StringComparison.Ordinal) || warning.Contains(hello.Host, StringComparison.Ordinal)
                || warning.Contains(request.Query!, StringComparison.Ordinal), "ni secret, ni cible, ni requête");
            await Check.ThrowsAsync<ObjectDisposedException>(() => client.ReadAsync(request), "aucune relance implicite");
            Check.Equal(1, journal.Warnings.Count, "une seule trace de l’échec");
        }
    }

    private sealed class Journal : ITechnicalJournal
    {
        internal List<string> Warnings { get; } = [];
        internal List<int> Running { get; } = [];
        public void Trace(string message) { }
        public void Info(string message) { }
        public void Error(string message, Exception exception) { }
        public void Warning(string message) { Warnings.Add(message); Running.Add(NativeReadProcess.Running); }
    }
}

/// <summary>Local test executable only: private handshake, one request, then diagnostic or bounded invalid output.</summary>
internal static class NativeReadDiagnosticFixture
{
    internal const string Prefix = "--native-read-diag-fixture-";
    internal static bool IsRequested(string[] args) => args.Length > 0 && args[0].StartsWith(Prefix, StringComparison.Ordinal);
    internal static async Task<int> RunAsync(string[] args)
    {
        if (!IsRequested(args) || args.Length != 3 || !NativeReadWorkerHost.ValidPipeName(args[1]) || !int.TryParse(args[2], out var parent)) { return 2; }
        var suffix = args[0][Prefix.Length..];
        var separator = suffix.IndexOf('-');
        if (separator < 0 || !Guid.TryParseExact(suffix[(separator + 1)..], "N", out _)) { return 2; }
        var mode = suffix[..separator];
        if (mode is not ("fault" or "oversize")) { return 2; }
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(deadline.Token); NativeReadProcess.VerifyServer(pipe, parent);
        var hello = await NativeReadProtocol.ReadAsync<NativeReadHello>(pipe, NativeReadProtocol.RequestLimit, deadline.Token);
        using var password = await NativeReadProtocol.ReadPasswordAsync(pipe, deadline.Token);
        if (!hello.Session || password is not null) { return 2; }
        await NativeReadProtocol.WriteAsync(pipe, true, 32, deadline.Token);
        var request = await NativeReadProtocol.ReadAsync<NativeReadRequest>(pipe, NativeReadProtocol.RequestLimit, deadline.Token);
        request.Check();
        if (mode == "fault")
        {
            var error = new Win32Exception(5, "PRIVATE-FIXTURE-MESSAGE");
            error.Data["PRIVATE-FIXTURE-DATA"] = "PRIVATE-FIXTURE-VALUE";
            NativeReadDiagnostics.TryWrite(NativeReadDiagnostics.Phase.Execute, error);
        }
        else
        {
            using var stderr = Console.OpenStandardError();
            var chunk = Encoding.ASCII.GetBytes(new string('X', 2048));
            for (var i = 0; i < 64; i++) { await stderr.WriteAsync(chunk, deadline.Token); }
            await stderr.FlushAsync(deadline.Token);
        }
        return 2;
    }
}
