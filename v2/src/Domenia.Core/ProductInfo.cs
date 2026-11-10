namespace Domenia.Core;

/// <summary>Product identity shared by every layer (window title, logs, reports).</summary>
public static class ProductInfo
{
    public const string Name = "Domenia";
    public const string DevelopmentVersion = "2.1.4";
    /// <summary>Short version for screens; Version retains the full identity for package verification.</summary>
    public const string DisplayVersion = DevelopmentVersion;
    public static string Version { get; } = QualifyBuild(typeof(ProductInfo).Assembly
        .GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
        .Cast<System.Reflection.AssemblyMetadataAttribute>().SingleOrDefault(a => a.Key == "DomeniaBuildIdentity")?.Value);

    internal static string QualifyBuild(string? identity)
    {
        if (identity is null) { return DevelopmentVersion; }
        var prefix = DevelopmentVersion + "+";
        if (!identity.StartsWith(prefix, StringComparison.Ordinal) || identity.Length != prefix.Length + 64 || !identity.AsSpan(prefix.Length).ToString().All(Uri.IsHexDigit))
        { throw new InvalidDataException("Identité de livraison injectée invalide."); }
        return identity;
    }

    /// <summary>Virtual host name under which the web interface is served by WebView2. Never resolved on the network.</summary>
    public const string WebHost = "domenia.local";
}
