using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace Domenia.Store;

public sealed partial class FileReceiptStore
{
    private const string MarkerContents = "Domenia.ReceiptStore/1\n";
    private string MarkerPath => path + ".state";

    private static void ValidateReceiptPath(string candidate)
    {
        if (!Path.IsPathFullyQualified(candidate) || candidate.StartsWith(@"\\", StringComparison.Ordinal)
            || candidate.AsSpan(3).Contains(':') || Path.GetDirectoryName(candidate) == Path.GetPathRoot(candidate)
            || new DriveInfo(Path.GetPathRoot(candidate)!).DriveType != DriveType.Fixed)
        { throw new IOException("DOMENIA_RECEIPT_PATH : dossier des reçus local fixe requis, sans partage ni flux alternatif."); }
        CompatibleDirectoryCache.ValidateLocalPath(candidate);
    }

    private static SecurityIdentifier[] ReceiptPrincipals()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return [identity.User ?? throw new IOException("DOMENIA_RECEIPT_DACL : identité Windows absente."),
            new(WellKnownSidType.LocalSystemSid, null), new(WellKnownSidType.BuiltinAdministratorsSid, null)];
    }

    private void ProtectReceiptRoot()
    {
        ValidateReceiptPath(path);
        var parent = new DirectoryInfo(Path.GetDirectoryName(path)!);
        parent.Create(); ValidateReceiptPath(path);
        try
        {
            ProtectReceiptDirectory(parent);
            if (File.Exists(path)) { ProtectReceiptFile(path); }
            if (File.Exists(MarkerPath)) { ProtectReceiptFile(MarkerPath); }
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        { throw new IOException("DOMENIA_RECEIPT_DACL : protection du dossier et des reçus non confirmée ; aucun envoi autorisé.", ex); }
    }

    private static void ProtectReceiptDirectory(DirectoryInfo parent)
    {
        ValidateReceiptPath(Path.Combine(parent.FullName, "receipt-path-check"));
        var security = new DirectorySecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var principal in ReceiptPrincipals())
        { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
        parent.SetAccessControl(security);
        VerifyReceiptAccess(parent.GetAccessControl(AccessControlSections.Access), true);
    }

    private static void ProtectReceiptFile(string candidate)
    {
        ValidateReceiptPath(candidate);
        var security = new FileSecurity(); security.SetAccessRuleProtection(true, false);
        foreach (var principal in ReceiptPrincipals()) { security.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl, AccessControlType.Allow)); }
        var file = new FileInfo(candidate); file.SetAccessControl(security);
        VerifyReceiptAccess(file.GetAccessControl(AccessControlSections.Access), false);
    }

    private static void VerifyReceiptAccess(FileSystemSecurity security, bool directory)
    {
        var principals = ReceiptPrincipals().Select(p => p.Value).Distinct(StringComparer.Ordinal).ToHashSet(StringComparer.Ordinal);
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        var inheritance = directory ? InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit : InheritanceFlags.None;
        if (!security.AreAccessRulesProtected || rules.Length != principals.Count
            || rules.Any(r => r.IsInherited || r.AccessControlType != AccessControlType.Allow || r.FileSystemRights != FileSystemRights.FullControl
                || r.InheritanceFlags != inheritance || r.PropagationFlags != PropagationFlags.None || !principals.Contains(r.IdentityReference.Value))
            || !principals.SetEquals(rules.Select(r => r.IdentityReference.Value)))
        { throw new IOException("DOMENIA_RECEIPT_DACL : droits relus différents de la protection attendue."); }
    }

    private void EnsureReceiptMarker()
    {
        ValidateReceiptPath(MarkerPath);
        if (File.Exists(MarkerPath))
        {
            if (new FileInfo(MarkerPath).Length != Encoding.UTF8.GetByteCount(MarkerContents) || File.ReadAllText(MarkerPath, Encoding.UTF8) != MarkerContents)
            { throw new IOException("DOMENIA_RECEIPT_STATE : témoin du journal illisible ; état antérieur non établi."); }
            return;
        }
        using var stream = new FileStream(MarkerPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 128, FileOptions.WriteThrough);
        ProtectReceiptFile(MarkerPath);
        stream.Write(Encoding.UTF8.GetBytes(MarkerContents)); stream.Flush(true);
    }
}
