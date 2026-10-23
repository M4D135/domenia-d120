using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal sealed record RemoteTaskReadCleanup(bool Stopped, bool Removed, string Detail);
internal interface IRemoteTaskReadBackend : IDisposable
{
    void Preflight(CancellationToken token);
    void PrepareCleanup(RemoteTaskReadCompletion? previous, CancellationToken token);
    void Start(CancellationToken token);
    string? ReadResult();
    bool Finished { get; }
    RemoteTaskReadCleanup Cleanup(Action? recordStopped = null);
}

/// <summary>Owns only the task and directory named by this plan. A lost creation reply is never retried.</summary>
internal sealed class RemoteTaskReadBackend(RemoteTaskReadPlan plan, RemoteProbeCredential? credential) : IRemoteTaskReadBackend
{
    private object? service;
    private object? folder;
    private bool directoryAttempted, directoryCreated, manifestCreated, registrationAttempted, registrationConfirmed, started;
    private bool recovering, previouslyStopped;
    private string Parent => @"\\" + plan.Host + @"\ADMIN$\Temp";
    private string DirectoryPath => Parent + "\\" + plan.DirectoryName;
    private string Manifest => DirectoryPath + @"\owner.txt";
    private T Files<T>(Func<T> action) => RemoteNetworkIdentity.Run(credential, action);
    private static void Release(object? value) { if (value is not null && Marshal.IsComObject(value)) { Marshal.FinalReleaseComObject(value); } }
    private static bool Missing(Exception ex) => ex is FileNotFoundException or DirectoryNotFoundException || ex is COMException && ex.HResult is unchecked((int)0x80070002) or unchecked((int)0x80070003);
    private static FileAttributes? Attributes(string path)
    { try { return File.GetAttributes(path); } catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException) { return null; } }
    private static void DirectorySafe(string path)
    {
        if (Attributes(path) is not { } attributes || (attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
        { throw new IOException("Répertoire distant absent ou point de réanalyse ; aucun artefact autorisé."); }
    }
    private void ParentSafe() { DirectorySafe(@"\\" + plan.Host + @"\ADMIN$"); DirectorySafe(Parent); }

    private void Connect(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", throwOnError: true)!)!;
        TaskSchedulerConnection.Connect(service, plan.Host, credential);
        token.ThrowIfCancellationRequested(); folder = ((dynamic)service).GetFolder(@"\");
        if ((string)((dynamic)folder).Path != @"\") { throw new IOException("Dossier du planificateur inattendu."); }
    }

    public void Preflight(CancellationToken token)
    {
        Connect(token);
        object? existing = null;
        try { existing = Task(); if (existing is not null) { throw new IOException("Nom de tâche déjà présent ; aucun remplacement."); } }
        finally { Release(existing); }
        Files(() => { ParentSafe(); if (Attributes(DirectoryPath) is not null) { throw new IOException("Répertoire déjà présent ; aucun remplacement."); } return true; });
    }

    public void PrepareCleanup(RemoteTaskReadCompletion? previous, CancellationToken token)
    {
        Connect(token);
        // Recovery never creates or runs anything. Every surviving artifact must
        // prove ownership again; absence alone cannot prove that execution stopped.
        recovering = true;
        previouslyStopped = previous?.ExecutionStopped == true;
        started = !previouslyStopped;
        registrationAttempted = directoryAttempted = directoryCreated = manifestCreated = true;
    }

    public void Start(CancellationToken token)
    {
        if (started || directoryAttempted || registrationAttempted || folder is null) { throw new InvalidOperationException("Création déjà tentée ou précontrôle absent."); }
        token.ThrowIfCancellationRequested();
        Files(() =>
        {
            ParentSafe(); token.ThrowIfCancellationRequested(); directoryAttempted = true;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(RemoteTaskReadProgram.DirectoryAcl, 1, out var descriptor, out _))
            { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            try
            {
                var security = new SecurityAttributes { Length = Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor };
                if (!CreateDirectoryW(DirectoryPath, ref security)) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                directoryCreated = true;
            }
            finally { LocalFree(descriptor); }
            DirectorySafe(DirectoryPath); VerifyAcl();
            using var manifest = new FileStream(Manifest, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var bytes = Encoding.UTF8.GetBytes(RemoteTaskReadProgram.Marker(plan)); manifest.Write(bytes); manifest.Flush(true); manifestCreated = true;
            return true;
        });
        token.ThrowIfCancellationRequested();
        object? task = null; object? running = null;
        try
        {
            registrationAttempted = true;
            task = ((dynamic)folder).RegisterTask(plan.TaskName, RemoteTaskReadProgram.Xml(plan), 2, "SYSTEM", null, 5, RemoteTaskReadProgram.TaskAcl);
            registrationConfirmed = true;
            if (!Owns(task)) { throw new IOException("Tâche relue différente du plan ; aucun lancement."); }
            token.ThrowIfCancellationRequested(); started = true;
            running = ((dynamic)task).Run(null);
        }
        finally { Release(running); Release(task); }
    }

    private void VerifyAcl()
    {
        var security = new DirectoryInfo(DirectoryPath).GetAccessControl(AccessControlSections.Access);
        if (!security.AreAccessRulesProtected) { throw new IOException("ACL distante héritée ; lecture refusée."); }
        var rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        if (rules.Length != 2 || rules.Any(r => r.AccessControlType != AccessControlType.Allow || r.IsInherited || r.FileSystemRights != FileSystemRights.FullControl
            || r.InheritanceFlags != (InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit) || r.PropagationFlags != PropagationFlags.None)
            || !rules.Select(r => r.IdentityReference.Value).Order(StringComparer.Ordinal).SequenceEqual(new[] { "S-1-5-18", "S-1-5-32-544" }.Order(StringComparer.Ordinal)))
        { throw new IOException("ACL distante différente du périmètre SYSTEM/Administrateurs."); }
    }

    private static string BoundedFile(string path, int maximum)
    {
        if (Attributes(path) is not { } attributes || (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        { throw new IOException("Fichier distant absent ou indirect."); }
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length is < 1 || file.Length > maximum) { throw new IOException("Fichier distant hors limites."); }
        var bytes = new byte[checked((int)file.Length)]; file.ReadExactly(bytes);
        if (file.ReadByte() != -1) { throw new IOException("Fichier distant modifié pendant sa lecture."); }
        return new UTF8Encoding(false, true).GetString(bytes);
    }

    private void OwnDirectory()
    {
        ParentSafe(); DirectorySafe(DirectoryPath); VerifyAcl();
        if (BoundedFile(Manifest, 256) != RemoteTaskReadProgram.Marker(plan)) { throw new IOException("Propriétaire du répertoire non confirmé."); }
    }

    public string? ReadResult() => Files(() =>
    {
        OwnDirectory(); var path = DirectoryPath + @"\result.json";
        return Attributes(path) is null ? null : BoundedFile(path, RemoteTaskReadProgram.MaximumOutput);
    });

    private object? Task()
    {
        if (folder is null) { throw new IOException("Planificateur non connecté."); }
        try { return ((dynamic)folder).GetTask(plan.TaskName); }
        catch (Exception ex) when (Missing(ex)) { return null; }
    }
    private bool Owns(object task)
    {
        if ((string)((dynamic)task).Path != "\\" + plan.TaskName || !RemoteTaskReadProgram.OwnsTask((string)((dynamic)task).Xml, plan)) { return false; }
        object? definition = null; object? principal = null;
        try { definition = ((dynamic)task).Definition; principal = ((dynamic)definition).Principal; return (int)((dynamic)principal).LogonType == 5; }
        finally { Release(principal); Release(definition); }
    }
    private static bool IsStopped(object task)
    {
        object? instances = null;
        try { instances = ((dynamic)task).GetInstances(0); return (int)((dynamic)instances).Count == 0 && (int)((dynamic)task).State is not (2 or 4); }
        finally { Release(instances); }
    }
    public bool Finished
    {
        get
        {
            object? task = null;
            try { task = Task(); if (task is null || !Owns(task)) { throw new IOException("Tâche absente ou remplacée pendant la lecture."); } return IsStopped(task); }
            finally { Release(task); }
        }
    }

    public RemoteTaskReadCleanup Cleanup(Action? recordStopped = null)
    {
        if (!directoryAttempted && !registrationAttempted) { return new(true, true, "Aucun artefact créé."); }
        var stopped = !started; var taskRemoved = !registrationAttempted; object? task = null;
        try
        {
            if (registrationAttempted)
            {
                task = Task();
                if (task is null)
                {
                    if (recovering && !previouslyStopped || !recovering && !registrationConfirmed)
                    { return new(stopped, false, "Tâche absente sans preuve durable d’arrêt ; artefacts conservés pour vérification."); }
                    if (started) { return new(false, false, "Tâche disparue ; arrêt de son processus non confirmé."); }
                    taskRemoved = true;
                }
                else
                {
                    if (!Owns(task)) { return new(false, false, "Tâche différente du plan ; aucune autre tâche arrêtée ou supprimée."); }
                    ((dynamic)task).Enabled = false;
                    if (!IsStopped(task)) { ((dynamic)task).Stop(0); }
                    var until = Stopwatch.StartNew();
                    while (!IsStopped(task) && until.Elapsed < TimeSpan.FromSeconds(3)) { Thread.Sleep(100); }
                    stopped = IsStopped(task);
                    if (!stopped) { return new(false, false, "Arrêt de la tâche non confirmé ; fichiers conservés."); }
                    if (!Owns(task)) { return new(true, false, "Tâche modifiée avant suppression ; artefacts conservés."); }
                    // Save the stop before deleting its only remote evidence. A
                    // later session can then finish deleting the owned directory.
                    recordStopped?.Invoke();
                    ((dynamic)folder!).DeleteTask(plan.TaskName, 0);
                    object? after = null;
                    try { after = Task(); taskRemoved = after is null; } finally { Release(after); }
                }
            }
            if (!taskRemoved) { return new(stopped, false, "Suppression de la tâche non confirmée ; fichiers conservés."); }
            var removed = Files(() =>
            {
                if (!directoryAttempted) { return true; }
                ParentSafe();
                if (Attributes(DirectoryPath) is null) { return directoryCreated; }
                if (!directoryCreated) { return false; }
                if (manifestCreated) { OwnDirectory(); } else { DirectorySafe(DirectoryPath); VerifyAcl(); }
                var children = Directory.EnumerateFileSystemEntries(DirectoryPath).Take(5).ToArray();
                if (children.Any(p => !new[] { "owner.txt", "result.tmp", "result.json" }.Contains(Path.GetFileName(p), StringComparer.Ordinal)) || children.Length > 3)
                { throw new IOException("Contenu imprévu ; aucun nettoyage récursif."); }
                foreach (var child in children)
                {
                    if (Attributes(child) is not { } attributes || (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                    { throw new IOException("Artefact indirect ; nettoyage suspendu."); }
                }
                foreach (var child in children.OrderBy(p => Path.GetFileName(p) == "owner.txt" ? 1 : 0)) { File.Delete(child); }
                Directory.Delete(DirectoryPath, false);
                return Attributes(DirectoryPath) is null;
            });
            return new(stopped, removed, removed ? "Tâche arrêtée et artefacts supprimés, puis absence relue." : "Propriété ou suppression du répertoire non confirmée.");
        }
        catch (Exception ex) when (ex is IOException or Win32Exception or COMException or UnauthorizedAccessException or OperationCanceledException)
        { return new(stopped, false, "Nettoyage non confirmé (code 0x" + ex.HResult.ToString("X8") + ") ; journal conservé pour vérification."); }
        finally { Release(task); }
    }

    public void Dispose() { Release(folder); folder = null; Release(service); service = null; }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes { internal int Length; internal IntPtr Descriptor; internal int Inherit; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(string path, ref SecurityAttributes security);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern IntPtr LocalFree(IntPtr memory);
}
