using System.IO.Pipes;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>Portable child entry point. It must run before application logging, profile access and UI initialization.</summary>
public static class NativeReadWorkerHost
{
    internal const string Argument = "--native-read-worker";
    internal static bool IsWorker { get; private set; }
    public static bool IsRequested(string[] args) => args.Length > 0 && args[0] == Argument;

    public static int Run(string[] args)
    {
        if (!IsRequested(args) || args.Length != 3 || !ValidPipeName(args[1])
            || !int.TryParse(args[2], out var parent) || parent <= 0 || parent == Environment.ProcessId) { return 2; }
        var diagnostic = new NativeReadDiagnostics.Context();
#pragma warning disable CA1031 // Only bounded type, phase and numeric codes go to the private diagnostic channel.
        try { return RunAsync(args[1], parent, diagnostic).GetAwaiter().GetResult(); }
        catch (Exception ex) { NativeReadDiagnostics.TryWrite(diagnostic.Current, ex); return 2; }
#pragma warning restore CA1031
    }

    internal static bool ValidPipeName(string name) => name.StartsWith("Domenia.NativeRead.", StringComparison.Ordinal)
        && name.Length == "Domenia.NativeRead.".Length + 32 && name["Domenia.NativeRead.".Length..].All(char.IsAsciiHexDigit);

    private static async Task<int> RunAsync(string pipeName, int parent, NativeReadDiagnostics.Context diagnostic)
    {
        using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(310));
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        diagnostic.Current = NativeReadDiagnostics.Phase.Connect;
        using (var connect = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
        { connect.CancelAfter(TimeSpan.FromSeconds(10)); await pipe.ConnectAsync(connect.Token).ConfigureAwait(false); }
        diagnostic.Current = NativeReadDiagnostics.Phase.VerifyPeer;
        NativeReadProcess.VerifyServer(pipe, parent);
        diagnostic.Current = NativeReadDiagnostics.Phase.ReadHello;
        var hello = await NativeReadProtocol.ReadAsync<NativeReadHello>(pipe, NativeReadProtocol.RequestLimit, stop.Token).ConfigureAwait(false);
        diagnostic.Current = NativeReadDiagnostics.Phase.ReadPassword;
        using var password = await NativeReadProtocol.ReadPasswordAsync(pipe, stop.Token).ConfigureAwait(false);
        diagnostic.Current = NativeReadDiagnostics.Phase.ValidateHello;
        NativeIsolationPlan.CheckHello(hello, password is not null);
        using var credential = hello.Session ? null : new RemoteProbeCredential(hello.Account!, password!.Copy(), false);
        // Set only after the pipe's actual server PID and the fixed session have been qualified.
        IsWorker = true;
        // Before the handshake and before this session's budget starts: the parent bounds startup on its own clock.
        diagnostic.Current = NativeReadDiagnostics.Phase.Warmup;
        NativeReadWarmup.Run(hello.Transport);
        stop.CancelAfter(TimeSpan.FromMilliseconds(hello.BudgetMs));
        diagnostic.Current = NativeReadDiagnostics.Phase.CreateSession;
        using var session = new CimSession(hello.Host, TimeSpan.FromMilliseconds(hello.BudgetMs), TimeProvider.System,
            cancellationToken: stop.Token, credential: credential, transport: hello.Transport)
        { ReadsEnabled = hello.ReadsEnabled, RegistryEnabled = hello.RegistryEnabled };
        diagnostic.Current = NativeReadDiagnostics.Phase.Handshake;
        await NativeReadProtocol.WriteAsync(pipe, true, 32, stop.Token).ConfigureAwait(false);
        while (!stop.IsCancellationRequested)
        {
            NativeReadRequest request;
            diagnostic.Current = NativeReadDiagnostics.Phase.RequestRead;
            try { request = await NativeReadProtocol.ReadAsync<NativeReadRequest>(pipe, NativeReadProtocol.RequestLimit, stop.Token).ConfigureAwait(false); }
            catch (EndOfStreamException) { return 0; }
            diagnostic.Current = NativeReadDiagnostics.Phase.ValidateRequest;
            NativeIsolationPlan.CheckRequest(request);
            var timeout = TimeSpan.FromMilliseconds(request.BudgetMs);
            diagnostic.Current = NativeReadDiagnostics.Phase.Execute;
            NativeReadReply reply = request.Kind switch
            {
                NativeReadKind.Query => new NativeReadReply(Reading: session.Read(request.Category!, request.Namespace!, request.Query!, request.MaxItems, timeout)),
                NativeReadKind.Metadata => new(Reading: session.ReadMetadata(request.Metadata, request.Namespace!, request.ClassName)),
                NativeReadKind.Registry => new(Registry: session.ReadRegistry(request.Registry!, timeout)),
                NativeReadKind.Appx => new(Reading: session.ReadAppx()),
                NativeReadKind.Inventory => new(Reading: session.ReadInventoryShell(request.Inventory)),
                NativeReadKind.Events => new(Reading: session.ReadEvents(request.Events!)),
                NativeReadKind.LocalAdmins => new(Reading: session.ReadLocalAdmins()),
                NativeReadKind.Diagnostic => new(Reading: session.ReadDiagnosticTransport(request.Diagnostic)),
                NativeReadKind.WinRmUser => new(User: session.ReadWinRmUserIdentity()),
                NativeReadKind.RegistryUser => new(User: session.ReadRemoteRegistryUserIdentity()),
                NativeReadKind.AccessTrial => new(Trial: hello.ReadsEnabled
                    ? WmiMachineAccessProbe.ReadNative(hello.Host, request.ExpectedComputerName, credential, stop.Token, request.RequireLocalAdministrator, request.AdministrationPrincipal)
                    : new("Failed", "Lecture native désactivée ; aucun contact.", "Disabled", null)),
                _ => throw new InvalidDataException("Action native refusée."),
            };
            diagnostic.Current = NativeReadDiagnostics.Phase.ReplyWrite;
            await NativeReadProtocol.WriteAsync(pipe, reply, NativeReadProtocol.ResponseLimit, stop.Token).ConfigureAwait(false);
        }
        return 0;
    }
}
