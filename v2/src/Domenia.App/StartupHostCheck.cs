namespace Domenia.App;

internal sealed record StartupHostFacts(string Runtime, string Browser, string Signature);

/// <summary>Runs after SHA admission and before composition. Signature verification uses only Windows' local cache.</summary>
internal static partial class StartupHostCheck
{
    internal static StartupHostFacts Inspect(string executable, string? browserFolder, Func<string?, string> browserVersion)
    {
        if (!OperatingSystem.IsWindows() || !Environment.Is64BitProcess || Environment.Version.Major < 10)
            throw new InvalidOperationException("Hôte incompatible : Windows 64 bits et runtime .NET 10 ou ultérieur requis.");
        var signature = Signature(executable);
        var browser = browserVersion(browserFolder);
        if (string.IsNullOrWhiteSpace(browser)) throw new InvalidDataException("Moteur WebView2 absent. Réextrayez le pack complet.");
        return new(Environment.Version.ToString(), browser, signature);
    }

    internal static string DescribeSignature(int status) => status switch
    {
        0 => "signature acceptée par la politique Windows locale ; révocation en ligne non interrogée",
        unchecked((int)0x800B0100) => "exécutable non signé ; cohérence SHA-256 seulement, éditeur non certifié",
        _ => throw new InvalidDataException("DOMENIA_HOST_SIGNATURE : signature non validée par Windows en mode local (0x" + status.ToString("X8", System.Globalization.CultureInfo.InvariantCulture) + ")."),
    };

    internal static string Signature(string executable)
    {
        var policy = PackagePublisherPolicy.ReadMachine();
        var verdict = PackagePublisherTrust.Verify(executable, policy);
        verdict.RequireAllowed(policy);
        return verdict.Notice;
    }
}
