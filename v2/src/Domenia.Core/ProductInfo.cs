namespace Domenia.Core;

/// <summary>Product identity shared by every layer (window title, logs, reports).</summary>
public static class ProductInfo
{
    public const string Name = "Domenia";
    public const string Version = "2.0.0-dev";

    /// <summary>Virtual host name under which the web interface is served by WebView2. Never resolved on the network.</summary>
    public const string WebHost = "domenia.local";
}
