using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace Domenia.App.Capture;

/// <summary>
/// Drives the fixed capture sequence on the UI thread: prepares the capture profile, opens the interface, then for
/// each step runs its constant scripts, waits for the expected state and writes one PNG (CapturePreviewAsync).
/// </summary>
internal sealed class CaptureRunner(CoreWebView2 core, CaptureSession session)
{
    private static ReadOnlySpan<byte> PngSignature => [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    private string? lastScriptError;

    /// <summary>Profile preparation, navigation and the steps of the plan. Never throws: every failure ends in capture.log.</summary>
    /// <param name="startupBegan">Stopwatch timestamp of the window load: the profile preparation uses what is left of
    /// the single startup budget (CaptureSequence.StartupLimit).</param>
    public async Task RunAsync(CoreWebView2Environment environment, string address, long startupBegan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(environment);
        session.Write($"Moteur WebView2 : {environment.BrowserVersionString} ({(AppPaths.WebViewRuntime is null ? "installé dans Windows" : "embarqué dans le pack")}).");
        core.ProcessFailed += (_, e) => session.Write($"ATTENTION Processus WebView2 en échec : {e.ProcessFailedKind} ({e.Reason}).");
        core.NavigationCompleted += (_, e) =>
        {
            if (!e.IsSuccess)
            {
                session.Write($"ATTENTION Chargement de l’interface en échec : {e.WebErrorStatus}.");
            }
        };
        try
        {
            // The capture profile is used by nothing else: it starts empty, then gets its fixed preferences.
            await core.Profile.ClearBrowsingDataAsync().WaitAsync(CaptureSequence.StartupLeft(startupBegan), cancellationToken).ConfigureAwait(true);
            await core.AddScriptToExecuteOnDocumentCreatedAsync(CaptureSequence.PresetPreferences).WaitAsync(CaptureSequence.StartupLeft(startupBegan), cancellationToken).ConfigureAwait(true);
            core.Navigate(address);
        }
        catch (OperationCanceledException)
        {
            session.Abort("Fenêtre fermée pendant la préparation du profil de capture.");
            return;
        }
        catch (Exception ex) when (ex is TimeoutException or COMException or InvalidOperationException or ArgumentException)
        {
            TechnicalLog.Error("Capture : préparation du profil ou ouverture de l’interface impossible.", ex);
            session.Error("Préparation du profil de capture ou ouverture de l’interface impossible.", ex);
            session.Abort("Le profil de capture n’a pas pu être préparé ou l’interface n’a pas pu être ouverte.");
            return;
        }

        var steps = session.Plan.Steps;
        for (var n = 0; n < steps.Length; n++)
        {
            var passed = !cancellationToken.IsCancellationRequested && await RunStepAsync(n, steps[n], cancellationToken).ConfigureAwait(true);
            if (cancellationToken.IsCancellationRequested)
            {
                session.Abort("Fenêtre fermée avant la fin de la séquence.");
                return;
            }
            if (!passed && n == 0)
            {
                // The first step proves the Accueil screen and the reduced animations: without it, the next images could
                // be taken in the middle of an animation, or of nothing at all.
                session.Abort("Première étape en échec (écran Accueil ou animations réduites non vérifiés) : la séquence est arrêtée.");
                return;
            }
        }
        session.Complete();
    }

    /// <summary>
    /// One step: true once its image is written or the optional step is found without object, false when it failed or was
    /// interrupted (logged).
    /// </summary>
    private async Task<bool> RunStepAsync(int index, CaptureStep step, CancellationToken cancellationToken)
    {
        var prefix = $"[{(index + 1).ToString(CultureInfo.InvariantCulture)}/{session.Steps.ToString(CultureInfo.InvariantCulture)}] {step.Name}";
        var file = step.Name + ".png";
        var target = Path.Combine(session.Folder, file);
        var clock = Stopwatch.StartNew();
        var current = "préparation";
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        budget.CancelAfter(CaptureSequence.StepLimit);
        lastScriptError = null;
        try
        {
            // An image of an earlier run never passes for one of this run.
            File.Delete(target);
            if (step.SkipWhen is not null)
            {
                current = "examen du défilement de l’écran";
                if (await IsTrueAsync(step.SkipWhen, budget.Token).ConfigureAwait(true))
                {
                    session.StepSkipped();
                    var why = step.SkipWhen == CaptureSequence.NoMiddle ? "l’écran tient en deux hauteurs de fenêtre" : "l’écran ne défile pas";
                    session.Write($"{prefix} : sans objet — {why}, aucune image attendue.");
                    return true;
                }
            }
            foreach (var action in step.Actions)
            {
                current = action.Description;
                await PerformAsync(action, budget.Token).ConfigureAwait(true);
            }
            current = "stabilisation de l’affichage";
            await Task.Delay(CaptureSequence.Settle, budget.Token).ConfigureAwait(true);
            if (index == 0)
            {
                current = "lecture de la zone d’affichage";
                await DescribeViewportAsync(budget.Token).ConfigureAwait(true);
            }
            if (await IsTrueAsync(CaptureSequence.ErrorProbe, budget.Token).ConfigureAwait(true))
            {
                session.Write($"{prefix} : ATTENTION l’écran affiche une erreur au lieu de son contenu.");
            }
            current = "capture de l’image";
            var (width, height, length) = await CaptureAsync(target, budget.Token).ConfigureAwait(true);
            session.ImageWritten();
            session.Write($"{prefix} : réussie en {Ms(clock)} ms — {step.Label} ({file}, {width.ToString(CultureInfo.InvariantCulture)} × {height.ToString(CultureInfo.InvariantCulture)} px, {(length / 1024).ToString(CultureInfo.InvariantCulture)} Ko).");
            return true;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            var detail = lastScriptError is null ? "" : $" Dernière erreur du moteur : {lastScriptError}.";
            session.Write($"{prefix} : ÉCHEC après {Ms(clock)} ms — délai de {CaptureSequence.StepLimit.TotalSeconds.ToString(CultureInfo.InvariantCulture)} s dépassé pendant « {current} ».{detail}");
        }
        catch (OperationCanceledException)
        {
            session.Write($"{prefix} : interrompue après {Ms(clock)} ms — fenêtre fermée pendant « {current} ».");
        }
        catch (InvalidDataException ex)
        {
            // Thrown by CaptureAsync only, with a fixed French text (no path): the image of WebView2 is not a usable PNG.
            TechnicalLog.Error($"Capture : étape {step.Name} en échec.", ex);
            session.Write($"{prefix} : ÉCHEC après {Ms(clock)} ms pendant « {current} » — {ex.Message}");
        }
#pragma warning disable CA1031 // One failed step is traced and the sequence goes on: the exit code reports it.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            TechnicalLog.Error($"Capture : étape {step.Name} en échec.", ex);
            session.Error($"{prefix} : ÉCHEC après {Ms(clock)} ms pendant « {current} ».", ex);
        }
        return false;
    }

    /// <summary>Runs the gesture until it applies, then waits for its condition; both bounded by the step budget.</summary>
    private async Task PerformAsync(CaptureAction action, CancellationToken cancellationToken)
    {
        if (action.Script is not null)
        {
            while (!await IsTrueAsync(action.Script, cancellationToken).ConfigureAwait(true))
            {
                await Task.Delay(CaptureSequence.Poll, cancellationToken).ConfigureAwait(true);
            }
        }
        while (!await IsTrueAsync(action.Condition, cancellationToken).ConfigureAwait(true))
        {
            await Task.Delay(CaptureSequence.Poll, cancellationToken).ConfigureAwait(true);
        }
    }

    /// <summary>Runs one constant script; false while the document is not there yet or the engine refuses the call.</summary>
    private async Task<bool> IsTrueAsync(string script, CancellationToken cancellationToken)
    {
        try
        {
            var result = await core.ExecuteScriptAsync(script).WaitAsync(cancellationToken).ConfigureAwait(true);
            return string.Equals(result, "true", StringComparison.Ordinal);
        }
        catch (COMException ex)
        {
            // Typically during the first navigation: retried at the next poll, reported if the step times out.
            lastScriptError = $"{ex.GetType().Name} 0x{ex.HResult.ToString("X8", CultureInfo.InvariantCulture)}";
            return false;
        }
    }

    private async Task DescribeViewportAsync(CancellationToken cancellationToken)
    {
        var json = await core.ExecuteScriptAsync(CaptureSequence.ViewportProbe).WaitAsync(cancellationToken).ConfigureAwait(true);
        double width;
        double height;
        double ratio;
        try
        {
            using var document = JsonDocument.Parse(json);
            var values = document.RootElement;
            if (values.ValueKind != JsonValueKind.Array || values.GetArrayLength() != 3)
            {
                session.Write("ATTENTION Zone d’affichage de la page illisible.");
                return;
            }
            width = values[0].GetDouble();
            height = values[1].GetDouble();
            ratio = values[2].GetDouble();
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
        {
            // Information only: the images are still taken.
            session.Write($"ATTENTION Zone d’affichage de la page illisible ({ex.GetType().Name}).");
            return;
        }
        var expected = width == CaptureSequence.Viewport.Width && height == CaptureSequence.Viewport.Height;
        session.Write($"{(expected ? "" : "ATTENTION ")}Zone d’affichage de la page : {width.ToString(CultureInfo.InvariantCulture)} × {height.ToString(CultureInfo.InvariantCulture)} px CSS, échelle {ratio.ToString(CultureInfo.InvariantCulture)}"
            + (expected ? "." : $" (attendu : {CaptureSequence.Viewport.Width.ToString(CultureInfo.InvariantCulture)} × {CaptureSequence.Viewport.Height.ToString(CultureInfo.InvariantCulture)})."));
    }

    /// <summary>Captures the WebView2 surface as PNG, checks the image header, then writes the file in one move.</summary>
    private async Task<(int Width, int Height, int Length)> CaptureAsync(string target, CancellationToken cancellationToken)
    {
        var image = new MemoryStream();
        var capture = core.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, image);
        try
        {
            await capture.WaitAsync(cancellationToken).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            // WebView2 may still write into the stream later: it is released only once the capture ends.
            _ = capture.ContinueWith(_ => image.Dispose(), CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
            throw;
        }
        byte[] bytes;
        using (image)
        {
            bytes = image.ToArray();
        }
        if (bytes.Length < 24 || !bytes.AsSpan(0, 8).SequenceEqual(PngSignature) || !bytes.AsSpan(12, 4).SequenceEqual("IHDR"u8))
        {
            throw new InvalidDataException("Image PNG invalide renvoyée par WebView2.");
        }
        var width = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(16, 4));
        var height = BinaryPrimitives.ReadInt32BigEndian(bytes.AsSpan(20, 4));
        if (width <= 0 || height <= 0)
        {
            throw new InvalidDataException("Image PNG vide renvoyée par WebView2.");
        }
        var temporary = target + ".tmp";
        try
        {
            await File.WriteAllBytesAsync(temporary, bytes, cancellationToken).ConfigureAwait(true);
            File.Move(temporary, target, overwrite: true);
        }
        catch
        {
            // No half-written file is left behind; the original failure is the one reported.
            TryDelete(temporary);
            throw;
        }
        return (width, height, bytes.Length);
    }

    private void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            session.Write($"ATTENTION Fichier temporaire non supprimé : {Path.GetFileName(path)} ({ex.GetType().Name}).");
        }
    }

    private static string Ms(Stopwatch clock) => clock.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture);
}
