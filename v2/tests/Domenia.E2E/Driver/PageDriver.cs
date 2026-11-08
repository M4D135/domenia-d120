using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.E2E.Cdp;

namespace Domenia.E2E.Driver;

/// <summary>Exception thrown by a script of the harness inside the page (a bug of the harness or a broken page).</summary>
internal sealed class PageScriptException(string message) : Exception(message)
{
}

/// <summary>Where an element is and whether it can take a click (answer of <see cref="PageScripts.Target"/>).</summary>
internal sealed record TargetInfo(string State, int Count, string? What, string? By, double X, double Y, double Left, double Top, double Width, double Height, IReadOnlyList<string> Sample)
{
    public bool Ok => State == "ok";

    public static TargetInfo From(JsonElement value) => new(
        Str(value, "state") ?? "missing",
        value.TryGetProperty("count", out var c) && c.TryGetInt32(out var n) ? n : 0,
        Str(value, "what"),
        Str(value, "by"),
        Num(value, "x"), Num(value, "y"), Num(value, "left"), Num(value, "top"), Num(value, "width"), Num(value, "height"),
        value.TryGetProperty("sample", out var s) && s.ValueKind == JsonValueKind.Array ? [.. s.EnumerateArray().Select(e => e.GetString() ?? "")] : []);

    private static string? Str(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static double Num(JsonElement value, string name) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;
}

/// <summary>
/// Real input and page reads over the DevTools protocol: mouse events at the centre of an element
/// (Input.dispatchMouseEvent), text insertion (Input.insertText), key events (Input.dispatchKeyEvent), screenshots
/// (Page.captureScreenshot) and constant scripts with a JSON argument (Runtime.evaluate).
/// </summary>
internal sealed class PageDriver(CdpConnection cdp)
{
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(30);

    /// <summary>Evaluates a constant function with its JSON argument; the value comes back by value (JSON).</summary>
    public async Task<JsonElement> CallAsync(string function, JsonNode? argument, CancellationToken cancellationToken)
    {
        var result = await cdp.SendAsync("Runtime.evaluate", new JsonObject
        {
            ["expression"] = PageScripts.Call(function, argument),
            ["returnByValue"] = true,
            ["awaitPromise"] = true,
            ["silent"] = true,
            ["includeCommandLineAPI"] = false,
        }, CommandTimeout, cancellationToken).ConfigureAwait(false);
        if (result.ValueKind == JsonValueKind.Object && result.TryGetProperty("exceptionDetails", out var details))
        {
            throw new PageScriptException("Script du harnais en échec dans la page : " + DescribeException(details));
        }
        return result.ValueKind == JsonValueKind.Object && result.TryGetProperty("result", out var remote) && remote.TryGetProperty("value", out var value)
            ? value
            : default;
    }

    public async Task<TargetInfo> TargetAsync(JsonObject locator, CancellationToken cancellationToken) =>
        TargetInfo.From(await CallAsync(PageScripts.Target, locator, cancellationToken).ConfigureAwait(false));

    public Task<JsonElement> ProbeAsync(JsonObject spec, CancellationToken cancellationToken) =>
        CallAsync(PageScripts.Probe, spec, cancellationToken);

    /// <summary>Moves the mouse, then presses and releases the button (clickCount 1, or 1 then 2 for a double click).</summary>
    public async Task ClickAsync(double x, double y, string button, int clickCount, CancellationToken cancellationToken)
    {
        await MoveAsync(x, y, cancellationToken).ConfigureAwait(false);
        var buttons = button == "right" ? 2 : 1;
        for (var n = 1; n <= clickCount; n++)
        {
            await MouseAsync("mousePressed", x, y, button, buttons, n, cancellationToken).ConfigureAwait(false);
            await MouseAsync("mouseReleased", x, y, button, 0, n, cancellationToken).ConfigureAwait(false);
        }
    }

    public Task MoveAsync(double x, double y, CancellationToken cancellationToken) =>
        MouseAsync("mouseMoved", x, y, "none", 0, 0, cancellationToken);

    public Task WheelAsync(double x, double y, double deltaY, CancellationToken cancellationToken) =>
        cdp.SendAsync("Input.dispatchMouseEvent", new JsonObject
        {
            ["type"] = "mouseWheel",
            ["x"] = x,
            ["y"] = y,
            ["deltaX"] = 0,
            ["deltaY"] = deltaY,
        }, CommandTimeout, cancellationToken);

    /// <summary>Text into the focused element, as an input method would commit it (input events, no key events).</summary>
    public Task InsertTextAsync(string text, CancellationToken cancellationToken) =>
        cdp.SendAsync("Input.insertText", new JsonObject { ["text"] = text }, CommandTimeout, cancellationToken);

    /// <summary>Modifiers down, key down and up, modifiers up (in reverse order).</summary>
    public async Task PressAsync(KeyChord chord, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(chord);
        var mask = 0;
        for (var n = 0; n < chord.Modifiers.Count; n++)
        {
            mask |= Bit(chord.Modifiers[n]);
            await KeyAsync("rawKeyDown", chord.Modifiers[n], mask, cancellationToken).ConfigureAwait(false);
        }
        await KeyAsync(chord.Key.Text is null ? "rawKeyDown" : "keyDown", chord.Key, chord.ModifierMask, cancellationToken).ConfigureAwait(false);
        await KeyAsync("keyUp", chord.Key, chord.ModifierMask, cancellationToken).ConfigureAwait(false);
        for (var n = chord.Modifiers.Count - 1; n >= 0; n--)
        {
            mask &= ~Bit(chord.Modifiers[n]);
            await KeyAsync("keyUp", chord.Modifiers[n], mask, cancellationToken).ConfigureAwait(false);
        }
    }

    /// <summary>PNG of the viewport, or of a region in CSS pixels of the document.</summary>
    public async Task<byte[]> ScreenshotAsync(TargetInfo? clip, CancellationToken cancellationToken)
    {
        var parameters = new JsonObject { ["format"] = "png", ["fromSurface"] = true };
        if (clip is not null && clip.Width >= 1 && clip.Height >= 1)
        {
            parameters["clip"] = new JsonObject
            {
                ["x"] = Math.Floor(clip.Left),
                ["y"] = Math.Floor(clip.Top),
                ["width"] = Math.Ceiling(clip.Width),
                ["height"] = Math.Ceiling(clip.Height),
                ["scale"] = 1,
            };
        }
        var result = await cdp.SendAsync("Page.captureScreenshot", parameters, CommandTimeout, cancellationToken).ConfigureAwait(false);
        var data = result.ValueKind == JsonValueKind.Object && result.TryGetProperty("data", out var d) ? d.GetString() : null;
        return data is null ? throw new CdpException("Capture d’écran sans données.") : Convert.FromBase64String(data);
    }

    /// <summary>Loads the document again (startup scripts run first, every console message is seen).</summary>
    public Task ReloadAsync(CancellationToken cancellationToken) =>
        cdp.SendAsync("Page.reload", new JsonObject { ["ignoreCache"] = true }, CommandTimeout, cancellationToken);

    public Task NavigateAsync(string url, CancellationToken cancellationToken) =>
        cdp.SendAsync("Page.navigate", new JsonObject { ["url"] = url }, CommandTimeout, cancellationToken);

    public Task AddStartupScriptAsync(string source, CancellationToken cancellationToken) =>
        cdp.SendAsync("Page.addScriptToEvaluateOnNewDocument", new JsonObject { ["source"] = source }, CommandTimeout, cancellationToken);

    /// <summary>Domains whose events the run collects, and focus emulation (the window may not be in front).</summary>
    public async Task EnableAsync(CancellationToken cancellationToken)
    {
        foreach (var method in new[] { "Runtime.enable", "Log.enable", "Page.enable" })
        {
            await cdp.SendAsync(method, null, CommandTimeout, cancellationToken).ConfigureAwait(false);
        }
        await cdp.SendAsync("Emulation.setFocusEmulationEnabled", new JsonObject { ["enabled"] = true }, CommandTimeout, cancellationToken).ConfigureAwait(false);
    }

    private Task MouseAsync(string type, double x, double y, string button, int buttons, int clickCount, CancellationToken cancellationToken)
    {
        var parameters = new JsonObject
        {
            ["type"] = type,
            ["x"] = Math.Round(x, 2),
            ["y"] = Math.Round(y, 2),
            ["button"] = button,
            ["buttons"] = buttons,
            ["pointerType"] = "mouse",
        };
        if (clickCount > 0)
        {
            parameters["clickCount"] = clickCount;
        }
        return cdp.SendAsync("Input.dispatchMouseEvent", parameters, CommandTimeout, cancellationToken);
    }

    private Task KeyAsync(string type, KeyDefinition key, int modifiers, CancellationToken cancellationToken)
    {
        var parameters = new JsonObject
        {
            ["type"] = type,
            ["key"] = key.Key,
            ["code"] = key.Code,
            ["windowsVirtualKeyCode"] = key.VirtualKey,
            ["nativeVirtualKeyCode"] = key.VirtualKey,
            ["modifiers"] = modifiers,
        };
        if (type == "keyDown" && key.Text is not null)
        {
            parameters["text"] = key.Text;
            parameters["unmodifiedText"] = key.Text;
        }
        return cdp.SendAsync("Input.dispatchKeyEvent", parameters, CommandTimeout, cancellationToken);
    }

    private static int Bit(KeyDefinition modifier) => modifier.Key switch
    {
        "Alt" => 1,
        "Control" => 2,
        "Meta" => 4,
        "Shift" => 8,
        _ => 0,
    };

    private static string DescribeException(JsonElement details)
    {
        if (details.TryGetProperty("exception", out var exception) && exception.TryGetProperty("description", out var description) && description.GetString() is string text)
        {
            var firstLine = text.Split('\n')[0].Trim();
            return firstLine.Length > 300 ? firstLine[..300] + "…" : firstLine;
        }
        var line = details.TryGetProperty("lineNumber", out var l) && l.TryGetInt32(out var n) ? n.ToString(CultureInfo.InvariantCulture) : "?";
        return (details.TryGetProperty("text", out var t) ? t.GetString() : null) + " (ligne " + line + ")";
    }
}
