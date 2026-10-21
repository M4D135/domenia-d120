using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.App.E2e;

/// <summary>
/// The --e2e-port &lt;n&gt; option (docs/E2E.md): opens the DevTools protocol of the WebView2 on 127.0.0.1:&lt;n&gt; so the
/// end-to-end harness (tests/Domenia.E2E) can drive the interface. It takes effect only together with the environment
/// variable DOMENIA_E2E=1: neither of them alone opens anything. The option and its value are taken out of the command
/// line before the mode is resolved, like --capture. Pure (no I/O): compiled as is into the harness for its self-tests.
/// </summary>
internal sealed partial record E2eArguments(bool Requested, int Port, string? Error, IReadOnlyList<string> Remaining)
{
    public const string Option = "--e2e-port";
    public const string Variable = "DOMENIA_E2E";
    public const int MinPort = 1024;
    public const int MaxPort = 65535;

    /// <summary>Exit code of a refused E2E start: same as a refused capture.</summary>
    public const int FailureCode = 2;

    /// <summary>True when the debugging port must be opened: option, valid port and DOMENIA_E2E=1.</summary>
    public bool Enabled => Requested && Error is null && Port is >= MinPort and <= MaxPort;

    /// <summary>
    /// Arguments of the WebView2 browser process. Chromium binds its DevTools server to the IPv4 loopback by default; the
    /// address is stated anyway, and the harness checks the listening sockets before it connects.
    /// </summary>
    public string BrowserArguments => Enabled
        ? "--remote-debugging-port=" + Port.ToString(CultureInfo.InvariantCulture) + " --remote-debugging-address=127.0.0.1"
        : string.Empty;

    /// <summary>
    /// Same matching as --simulation and --capture: exact value, any case, no « = » form, admitted once. The value must be
    /// a decimal port number from 1024 to 65535. Without DOMENIA_E2E=1 the option is refused (the run stops with code 2):
    /// a command line alone never opens the protocol.
    /// </summary>
    public static E2eArguments Parse(IReadOnlyList<string> arguments, string? variableValue)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        var remaining = new List<string>(arguments.Count);
        var found = 0;
        string? value = null;
        string? error = null;
        for (var n = 0; n < arguments.Count; n++)
        {
            if (!string.Equals(arguments[n], Option, StringComparison.OrdinalIgnoreCase))
            {
                remaining.Add(arguments[n]);
                continue;
            }
            found++;
            var next = n + 1 < arguments.Count ? arguments[n + 1] : null;
            // « --e2e-port --simulation »: the value was forgotten; the next option is left in place.
            if (string.IsNullOrWhiteSpace(next) || next.StartsWith("--", StringComparison.Ordinal))
            {
                error ??= E2eTexts.PortMissing;
                if (next is not null && string.IsNullOrWhiteSpace(next))
                {
                    n++;
                }
                continue;
            }
            value ??= next;
            n++;
        }
        if (found == 0)
        {
            return new E2eArguments(false, 0, null, remaining);
        }
        if (found > 1)
        {
            error = E2eTexts.Repeated;
        }
        var port = 0;
        if (error is null && !TryParsePort(value, out port))
        {
            error = E2eTexts.PortInvalid;
        }
        if (error is null && !string.Equals(variableValue?.Trim(), "1", StringComparison.Ordinal))
        {
            error = E2eTexts.VariableMissing;
        }
        return error is null ? new E2eArguments(true, port, null, remaining) : new E2eArguments(true, 0, error, remaining);
    }

    /// <summary>Decimal digits only (no sign, no space, no hexadecimal), from 1024 to 65535.</summary>
    public static bool TryParsePort(string? value, out int port)
    {
        port = 0;
        if (value is null || !PortPattern().IsMatch(value))
        {
            return false;
        }
        var parsed = int.Parse(value, NumberStyles.None, CultureInfo.InvariantCulture);
        if (parsed is < MinPort or > MaxPort)
        {
            return false;
        }
        port = parsed;
        return true;
    }

    [GeneratedRegex("^[0-9]{4,5}$", RegexOptions.CultureInvariant)]
    private static partial Regex PortPattern();
}

/// <summary>
/// Environment variables through which WebView2 would take browser arguments or open a debugging channel behind the
/// application's back. Without the E2E mode, a variable that opens the DevTools protocol is neutralized for this process
/// (and therefore for the browser processes it starts); with the E2E mode, the arguments variable is neutralized whatever
/// it holds, so that only the loopback port of --e2e-port applies.
/// </summary>
internal static class BrowserArgumentsGuard
{
    public const string ArgumentsVariable = "WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS";
    public const string ScriptDebuggerVariable = "WEBVIEW2_PIPE_FOR_SCRIPT_DEBUGGER";

    /// <summary>
    /// Variables to remove from the process environment, given their values. Pure: the caller applies the result and
    /// traces each name (never the value). The script debugger pipe is kept for Debug builds only (local debugging of
    /// the page from an editor).
    /// </summary>
    public static IReadOnlyList<string> VariablesToNeutralize(string? arguments, string? scriptDebugger, bool e2e, bool debugBuild)
    {
        var result = new List<string>(2);
        if (!string.IsNullOrWhiteSpace(arguments) && (e2e || OpensDebugging(arguments)))
        {
            result.Add(ArgumentsVariable);
        }
        if (!string.IsNullOrWhiteSpace(scriptDebugger) && !debugBuild)
        {
            result.Add(ScriptDebuggerVariable);
        }
        return result;
    }

    /// <summary>« --remote-debugging-port », « --remote-debugging-pipe », « --remote-debugging-address »… in any case.</summary>
    public static bool OpensDebugging(string arguments) =>
        arguments.Contains("remote-debugging", StringComparison.OrdinalIgnoreCase);
}

/// <summary>French texts of the E2E mode (standard error and technical journal).</summary>
internal static class E2eTexts
{
    public const string PortMissing = "Mode E2E refusé : indiquez le port après --e2e-port (nombre de 1024 à 65535).";
    public const string PortInvalid = "Mode E2E refusé : port invalide après --e2e-port (nombre entier de 1024 à 65535).";
    public const string Repeated = "Mode E2E refusé : l’option --e2e-port n’est admise qu’une fois.";
    public const string VariableMissing = "Mode E2E refusé : --e2e-port exige aussi la variable d’environnement DOMENIA_E2E=1.";
    public const string WithCapture = "Mode E2E refusé : --e2e-port ne se combine pas avec --capture.";

    /// <summary>Visible in the title bar while the harness drives the window.</summary>
    public const string WindowTitleSuffix = " — pilotage E2E";

    public static string Neutralized(string variable) => variable == BrowserArgumentsGuard.ArgumentsVariable
        ? $"Variable {variable} neutralisée pour ce processus : elle ouvrait le protocole de débogage de WebView2 ou aurait remplacé les arguments du mode E2E (valeur non recopiée)."
        : $"Variable {variable} neutralisée pour ce processus : canal de débogage de scripts non admis hors compilation Debug (valeur non recopiée).";

    public static string Active(int port, string profile) =>
        $"Mode E2E actif : protocole DevTools de WebView2 ouvert sur 127.0.0.1:{port.ToString(CultureInfo.InvariantCulture)} pour le harnais de tests, profil {profile} vidé au démarrage, préférences en mémoire seulement.";
}
