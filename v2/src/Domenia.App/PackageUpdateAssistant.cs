using System.Diagnostics;
using System.Globalization;
using System.IO.Pipes;
using System.Security.Cryptography;
using Domenia.Core;

namespace Domenia.App;

internal sealed record PackageUpdateLaunch(int Format, string Target, string SourceManifest, string? CurrentManifest, string Confirmation, long ParentStartedTicks);
internal sealed record PackageUpdateReady(int Format, int ProcessId, string SourceManifest, string Nonce);
internal sealed record PackageUpdateDecision(int Format, string Nonce, bool Install);

/// <summary>Separate instance of the verified portable EXE. Never changes databases or kills the original application.</summary>
internal static class PackageUpdateAssistant
{
    internal const string Argument = "--package-update-assistant";
    internal const string HealthArgument = "--package-update-health";

    internal static PackageLifecyclePlan Preview(string preparedRoot, string expectedManifestSha256)
    {
        using var incoming = PackageIntegrity.Open(PackageLifecycleFiles.Root(preparedRoot), true);
        if (!Hash(expectedManifestSha256) || incoming.ManifestHash != expectedManifestSha256)
        { throw new InvalidDataException("Copie préparée différente de l’empreinte examinée."); }
        return new PackageLifecycle(preparedRoot, TimeProvider.System) { RequireHealth = true }
            .PreviewUpdate(PackageLayout.ApplicationRoot, CancellationToken.None);
    }

    internal static bool TryRun(string[] args, out int exitCode)
    {
        exitCode = 2;
        if (args.Length == 0 || args[0] is not (Argument or HealthArgument)) return false;
        try
        {
            if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess || args.Length != 3
                || !PackageUpdateChannel.ValidName(args[1]) || !int.TryParse(args[2], NumberStyles.None, CultureInfo.InvariantCulture, out var parentId)
                || parentId <= 0 || parentId == Environment.ProcessId)
            { throw new InvalidDataException("Arguments fermés de l’assistant invalides."); }
            exitCode = args[0] == HealthArgument ? RunHealth(args[1], parentId) : RunAssistant(args[1], parentId);
        }
#pragma warning disable CA1031 // Process boundary: every failed private startup exits without entering the real application.
        catch (Exception error) { Console.Error.WriteLine("Assistant refusé : " + error.GetType().Name + ". Aucune réussite annoncée."); }
#pragma warning restore CA1031
        return true;
    }

    internal static async Task<PackageUpdateSession> PrepareAsync(string preparedRoot, string manifest, string confirmation, CancellationToken token)
    {
        var plan = Preview(preparedRoot, manifest);
        if (plan.Confirmation != confirmation) { throw new InvalidDataException("Aperçu de mise à jour périmé ; aucune fermeture."); }
        var pin = PackageIntegrity.Open(preparedRoot, true);
        if (pin.ManifestHash != manifest) { pin.Dispose(); throw new InvalidDataException("Paquet préparé modifié avant lancement de l’assistant."); }
        var name = PackageUpdateChannel.Name(); var pipe = PackageUpdateChannel.Server(name); Process? child = null;
        try
        {
            child = PackageUpdateChannel.Start(preparedRoot, Argument, name);
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(token); limit.CancelAfter(TimeSpan.FromSeconds(60));
            await pipe.WaitForConnectionAsync(limit.Token).ConfigureAwait(false); PackageUpdateChannel.VerifyClient(pipe, child.Id);
            PackageUpdateChannel.VerifyImage(child, preparedRoot);
            using var self = Process.GetCurrentProcess();
            await PackageUpdateChannel.SendAsync(pipe, new PackageUpdateLaunch(1, plan.Target, manifest, plan.ActiveIdentity, confirmation, self.StartTime.ToUniversalTime().Ticks), limit.Token).ConfigureAwait(false);
            var ready = await PackageUpdateChannel.ReadAsync<PackageUpdateReady>(pipe, limit.Token).ConfigureAwait(false);
            if (ready.Format != 1 || ready.ProcessId != child.Id || ready.SourceManifest != manifest || !Hash(ready.Nonce))
            { throw new InvalidDataException("Préparation de l’assistant non confirmée."); }
            return new(pipe, child, pin, ready.Nonce);
        }
        catch
        {
            pipe.Dispose();
            if (child is not null)
            {
                var exited = await PackageUpdateChannel.StopOwnedAsync(child).ConfigureAwait(false); child.Dispose();
                if (!exited) { pin.Dispose(); throw new PackageHealthException("Arrêt de l’assistant non confirmé ; installation non autorisée.", false); }
            }
            pin.Dispose(); throw;
        }
    }

    private static int RunAssistant(string pipeName, int parentId)
    {
        using var ownPack = OwnPack();
        using var parent = Process.GetProcessById(parentId);
        using var pipe = PackageUpdateChannel.Client(pipeName);
        using var connect = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        pipe.ConnectAsync(connect.Token).GetAwaiter().GetResult(); PackageUpdateChannel.VerifyServer(pipe, parentId);
        var launch = PackageUpdateChannel.ReadAsync<PackageUpdateLaunch>(pipe, connect.Token).GetAwaiter().GetResult();
        if (launch.Format != 1 || ownPack.ManifestHash != launch.SourceManifest || !Hash(launch.Confirmation))
        { throw new InvalidDataException("Source de l’assistant différente de l’aperçu."); }
        var target = PackageLifecycleFiles.Root(launch.Target); PackageUpdateChannel.VerifyImage(parent, target, launch.ParentStartedTicks);
        var delivery = new PackageLifecycle(PackageLayout.ApplicationRoot, TimeProvider.System) { RequireHealth = true, HealthCheck = CheckHealth };
        var plan = delivery.PreviewUpdate(target, connect.Token);
        if (plan.Confirmation != launch.Confirmation || plan.ActiveIdentity != launch.CurrentManifest)
        { throw new InvalidDataException("Installation ou plan modifié avant fermeture ; rien ne sera remplacé."); }
        var nonce = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        PackageUpdateChannel.SendAsync(pipe, new PackageUpdateReady(1, Environment.ProcessId, launch.SourceManifest, nonce), connect.Token).GetAwaiter().GetResult();
        var decision = PackageUpdateChannel.ReadAsync<PackageUpdateDecision>(pipe, connect.Token).GetAwaiter().GetResult();
        if (decision.Format != 1 || !decision.Install || decision.Nonce != nonce) { return 2; }
        pipe.Dispose();
        // A stale PID cannot substitute for this held Process. We wait, never kill the parent or another launcher.
        return PackageUpdateProgress.Run(async progress =>
        {
            progress("Fermeture de l’application en cours…");
            await parent.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(60)).ConfigureAwait(false);
            progress("Sauvegarde vérifiée, remplacement du code et contrôle de santé…");
            var result = await Task.Run(() => delivery.Update(target, launch.Confirmation, CancellationToken.None)).ConfigureAwait(false);
            if (!result.HealthConfirmed)
            {
                return new(3, "La mise à jour a échoué. Les anciens binaires ont été restaurés et vérifiés ; les données n’ont pas été restaurées."
                    + (result.Failure is { } failure ? "\nCause : " + failure : "") + "\nTransaction : " + result.Transaction, target, File.Exists(Path.Combine(target, "Domenia.exe")));
            }
            return new(0, "Paquet installé et contrôle local du runtime / de l’affichage confirmé. La base et la session réelle seront ouvertes seulement par votre prochain lancement.\nTransaction : " + result.Transaction, target, true);
        });
    }

    private static int RunHealth(string pipeName, int parentId)
    {
        using var pipe = PackageUpdateChannel.Client(pipeName);
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        pipe.ConnectAsync(limit.Token).GetAwaiter().GetResult(); PackageUpdateChannel.VerifyServer(pipe, parentId);
        var request = PackageUpdateChannel.ReadAsync<PackageHealthRequest>(pipe, limit.Token).GetAwaiter().GetResult();
#pragma warning disable CA1031 // The waiting parent must learn why; the failure is rethrown and this child exits with code 2.
        try { return RunHealth(request, parentId, pipe, limit.Token); }
        catch (Exception error)
        {
            // A failure receipt never authorizes anything: the parent refuses it, waits for this exit and rolls back.
            var failure = new PackageHealthReceipt(1, request.Transaction, request.ManifestSha256, "", Environment.ProcessId,
                ProductInfo.Version, "", false, false) { Failure = PackageHealthReceipt.Describe(error) };
            try { PackageUpdateChannel.SendAsync(pipe, failure, limit.Token).GetAwaiter().GetResult(); }
            catch (Exception notSent) { Console.Error.WriteLine("Échec de santé non transmis : " + notSent.GetType().Name + "."); }
            throw;
        }
#pragma warning restore CA1031
    }

    private static int RunHealth(PackageHealthRequest request, int parentId, NamedPipeClientStream pipe, CancellationToken token)
    {
        using var parent = Process.GetProcessById(parentId);
        var parentRoot = PackageLifecycleFiles.Root(Path.GetDirectoryName(parent.MainModule?.FileName) ?? "");
        PackageUpdateChannel.VerifyImage(parent, parentRoot);
        if (string.Equals(parentRoot, Path.TrimEndingDirectorySeparator(PackageLayout.ApplicationRoot), StringComparison.OrdinalIgnoreCase))
        { throw new UnauthorizedAccessException("L’assistant doit rester extérieur à l’installation contrôlée."); }
        using var parentPack = PackageIntegrity.Open(parentRoot, true);
        if (parentPack.ManifestHash != request.ManifestSha256) { throw new UnauthorizedAccessException("Assistant d’une autre livraison."); }
        using var ownPack = PackageIntegrity.OpenForHealth(PackageLayout.ApplicationRoot, request);
        CheckBuild(ownPack);
        var probe = PackageUpdateHealthProbe.Run(request, ownPack);
        var receipt = new PackageHealthReceipt(1, request.Transaction, request.ManifestSha256, request.Nonce, Environment.ProcessId,
            ProductInfo.Version, probe.BrowserVersion, probe.DocumentLoaded, probe.ScriptReady);
        PackageUpdateChannel.SendAsync(pipe, receipt, token).GetAwaiter().GetResult();
        return 0;
    }

    internal static PackageHealthReceipt CheckHealth(PackageHealthRequest request, CancellationToken token)
        => CheckHealthAsync(request, token).GetAwaiter().GetResult();

    private static async Task<PackageHealthReceipt> CheckHealthAsync(PackageHealthRequest request, CancellationToken token)
    {
        var name = PackageUpdateChannel.Name(); using var pipe = PackageUpdateChannel.Server(name);
        using var job = new PackageUpdateHealthJob(); Process? child = null; var assigned = false; var stopped = false;
        try
        {
            child = PackageUpdateChannel.Start(request.Target, HealthArgument, name); job.Assign(child); assigned = true;
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(token); limit.CancelAfter(TimeSpan.FromSeconds(60));
            await pipe.WaitForConnectionAsync(limit.Token).ConfigureAwait(false); PackageUpdateChannel.VerifyClient(pipe, child.Id);
            PackageUpdateChannel.VerifyImage(child, request.Target);
            await PackageUpdateChannel.SendAsync(pipe, request, limit.Token).ConfigureAwait(false);
            var receipt = await PackageUpdateChannel.ReadAsync<PackageHealthReceipt>(pipe, limit.Token).ConfigureAwait(false);
            if (receipt.ProcessId != child.Id) { throw new InvalidDataException("Accusé d’un autre processus de santé."); }
            var reason = PackageHealthReceipt.Bound(receipt.Failure);
            await child.WaitForExitAsync(limit.Token).ConfigureAwait(false);
            var code = child.ExitCode;
            stopped = await job.StopAndConfirmAsync(child).ConfigureAwait(false);
            if (!stopped) { throw new PackageHealthException("Fin des processus de santé non confirmée ; preuves conservées.", false); }
            if (code != 0 || reason is not null)
            { throw new PackageHealthException("Le contrôle de santé s’est terminé en échec" + (reason is null ? "." : " : " + reason), true); }
            return receipt;
        }
#pragma warning disable CA1031 // All failures after child creation must carry the physical-end fact, including unexpected native errors.
        catch (Exception error)
        {
            if (!stopped && child is not null)
            {
                try { stopped = assigned ? await job.StopAndConfirmAsync(child).ConfigureAwait(false) : await PackageUpdateChannel.StopOwnedAsync(child).ConfigureAwait(false); }
                catch { stopped = false; }
            }
            throw new PackageHealthException("Contrôle de santé non confirmé ; " + (child is null || stopped ? "enfant terminé." : "arrêt physique non prouvé, aucune restauration."), child is null || stopped, error);
        }
#pragma warning restore CA1031
        finally { child?.Dispose(); }
    }

    private static PackageIntegrity OwnPack()
    {
        var pack = PackageIntegrity.Open(PackageLayout.ApplicationRoot, true);
        try { CheckBuild(pack); return pack; } catch { pack.Dispose(); throw; }
    }
    private static void CheckBuild(PackageIntegrity pack)
    {
        var release = PackageLifecycle.Release(PackageLayout.ApplicationRoot, pack.Components);
        if (release is null || release.Build != ProductInfo.Version || release.Version != ProductInfo.DevelopmentVersion)
        { throw new InvalidDataException("Identité compilée différente du paquet de l’assistant."); }
    }
    private static bool Hash(string? value) => value is { Length: 64 } && value.All(Uri.IsHexDigit);
}

internal sealed class PackageUpdateSession(NamedPipeServerStream pipe, Process process, PackageIntegrity pin, string nonce) : IAsyncDisposable
{
    private bool authorized;
    internal async Task AuthorizeAsync(CancellationToken token)
    {
        if (authorized) { throw new InvalidOperationException("Assistant déjà autorisé."); }
        await PackageUpdateChannel.SendAsync(pipe, new PackageUpdateDecision(1, nonce, true), token).ConfigureAwait(false);
        authorized = true;
    }
    public async ValueTask DisposeAsync()
    {
        pipe.Dispose();
        if (!authorized)
        {
            var exited = await PackageUpdateChannel.StopOwnedAsync(process).ConfigureAwait(false);
            if (!exited) { process.Dispose(); pin.Dispose(); throw new PackageHealthException("Assistant non autorisé encore actif.", false); }
        }
        process.Dispose(); pin.Dispose();
    }
}
