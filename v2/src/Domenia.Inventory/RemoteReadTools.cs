namespace Domenia.Inventory;

/// <summary>Closed optional-component policy shared by startup and the explicit remote-read fallback.
/// A permitted name is not approval: the exact bytes and ordinary local ancestors are pinned before admission.</summary>
public static class RemoteReadTools
{
    public static bool IsOptionalPackageComponent(string relativePath) =>
        relativePath.Equals("PsExec.exe", StringComparison.OrdinalIgnoreCase) ||
        relativePath.Equals("PsExec64.exe", StringComparison.OrdinalIgnoreCase) ||
        relativePath.Equals("wad/PsExec.exe", StringComparison.OrdinalIgnoreCase) ||
        relativePath.Equals("wad/PsExec64.exe", StringComparison.OrdinalIgnoreCase);

    public static IDisposable PinOptionalPackageComponent(string root, string relativePath, CancellationToken token)
    {
        if (!IsOptionalPackageComponent(relativePath))
        { throw new ArgumentException("Ce nom ne désigne pas un composant facultatif approuvé.", nameof(relativePath)); }
        return RemotePsExecBinary.Open(System.IO.Path.Combine(root, relativePath.Replace('/', System.IO.Path.DirectorySeparatorChar)),
            RemotePsExecBinary.ApprovedSha256, token);
    }
}
