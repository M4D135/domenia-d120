using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Domenia.App;

internal sealed record PackageUninstallOptions(bool LocalData = false, bool ProfileData = false);
internal sealed record PackageRemovalFile(string Kind, string Path, long Length, string Sha256);
internal sealed record PackageDataRemoval(PackageUninstallOptions Options, string? ProfileRoot, IReadOnlyList<PackageRemovalFile> Files);

internal sealed partial class PackageLifecycle
{
    // Test roots are supplied by the native integration fixtures only, never by a web or command argument.
    internal Func<string?> ProfileRoot { get; init; } = () => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) is { Length: > 0 } root
        ? Path.Combine(root, "Domenia") : null;
    private static bool Within(string child, string parent) => child.Equals(parent, StringComparison.OrdinalIgnoreCase)
        || child.StartsWith(parent + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private string? RemovalProfile(string target, bool selected)
    {
        if (!selected) return null;
        var profile = PackageLifecycleFiles.Root(ProfileRoot() ?? throw new InvalidDataException("Profil local Windows indisponible ; aucune suppression de profil."));
        if (Within(source, profile) || Within(target, profile) || Within(profile, source) || Within(profile, target) || Within(Storage(target), profile))
            throw new InvalidDataException("Le profil contient le paquet de travail ou sa preuve ; choisissez un autre paquet indépendant pour désinstaller.");
        return profile;
    }
    private static bool LocalRemovalPath(string relative) => relative.StartsWith("data/", StringComparison.OrdinalIgnoreCase)
        || relative.StartsWith("wad/data/", StringComparison.OrdinalIgnoreCase)
        || relative is "Domenia.config.json" or "wad/Domenia.config.json" or "Domenia.settings.json" or "ADCC.settings.json"
            or "wad/Domenia.settings.json" or "wad/ADCC.settings.json";
    private PackageDataRemoval RemovalPlan(PackageLifecycleFiles paths, string target, PackageUninstallOptions options)
    {
        var profile = RemovalProfile(target, options.ProfileData);
        var files = new List<PackageRemovalFile>(); long total = 0;
        void Collect(string root, string kind, IEnumerable<string> names)
        {
            foreach (var name in names.Order(StringComparer.Ordinal))
            {
                if (files.Count >= 8192) throw new InvalidDataException("Plus de 8 192 fichiers de données : archivez explicitement avant désinstallation.");
                var measured = PackageLifecycleFiles.Measure(root, name);
                total = checked(total + measured.Length);
                if (total > PackageLifecycleFiles.MaximumBytes) throw new InvalidDataException("Données supérieures à 8 Gio ; archivez-les séparément avant désinstallation.");
                files.Add(new(kind, name, measured.Length, measured.Sha256));
            }
        }
        if (options.LocalData) Collect(target, "local", paths.FileNames(target).Where(LocalRemovalPath));
        if (profile is not null && PackageLifecycleFiles.Exists(profile)) Collect(profile, "profile", paths.FileNames(profile));
        return new(options, profile, files);
    }
    private void ValidateRemoval(string target, PackageDataRemoval? data)
    {
        if (data is null) return;
        if (data.Options is null || data.Files is null || data.Files.Count > 8192
            || data.ProfileRoot != RemovalProfile(target, data.Options.ProfileData)) throw new InvalidDataException("Choix de suppression de données incohérent.");
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var proofEntries = new HashSet<string>(StringComparer.OrdinalIgnoreCase); long total = 0;
        foreach (var file in data.Files)
        {
            if (file is null || !PackageIntegrity.ValidRelativePath(file.Path) || file.Kind is not ("local" or "profile") || file.Kind == "local" && (!data.Options.LocalData || !LocalRemovalPath(file.Path))
                || file.Kind == "profile" && !data.Options.ProfileData || !PackageIntegrity.ValidRelativePath(file.Path)
                || file.Length < 0 || file.Length > PackageLifecycleFiles.MaximumBytes - total || file.Sha256 is not { Length: 64 } || !file.Sha256.All(char.IsAsciiHexDigit)
                || !seen.Add(file.Kind + "/" + file.Path) || (total += file.Length) > PackageLifecycleFiles.MaximumBytes)
                throw new InvalidDataException("Inventaire de suppression de données invalide ; fichiers conservés.");
            var parts = file.Path.Split('/');
            if (parts.Length > 32) throw new InvalidDataException("Arborescence des données trop profonde pour une preuve reprenable.");
            var prefix = file.Kind; proofEntries.Add(prefix);
            foreach (var part in parts) { prefix += "/" + part; proofEntries.Add(prefix); }
            if (proofEntries.Count > 8192) throw new InvalidDataException("Preuve de données supérieure à 8 192 entrées ; archivez-les séparément.");
        }
        if (System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(data, Json).Length > 1024 * 1024)
            throw new InvalidDataException("Inventaire des données supérieur à 1 Mio ; archivez-les séparément avant désinstallation.");
    }
    private PackageRemovalLease OpenRemoval(PackageLifecycleFiles paths, string target, PackageDataRemoval? data)
    {
        ValidateRemoval(target, data);
        return new(paths, target, data);
    }
    private static IReadOnlyList<string> FinishRemoval(PackageRemovalLease removal, string transaction, CancellationToken token)
    {
        removal.CheckBackups(Path.Combine(transaction, "removed-data"), token);
        return removal.Remove(token);
    }
}

/// <summary>All selected files are held together before any deletion. SQLite writers and replacements cannot race this set.</summary>
internal sealed partial class PackageRemovalLease : IDisposable
{
    private sealed record Held(PackageRemovalFile Expected, FileStream File, bool Matches);
    private readonly List<Held> held = [];
    private readonly Dictionary<string, FileStream> backups = new(StringComparer.OrdinalIgnoreCase);
    internal PackageRemovalLease(PackageLifecycleFiles paths, string target, PackageDataRemoval? data)
    {
        try
        {
            if (data is null) return;
            foreach (var item in data.Files)
            {
                var root = item.Kind == "local" ? target : data.ProfileRoot!;
                var path = PackageLifecycleFiles.At(root, item.Path);
                if (!PackageLifecycleFiles.Exists(path)) continue;
                paths.Pin(Path.GetDirectoryName(path)!); PackageLifecycleFiles.Check(path);
                var handle = CreateFile(path, 0x80010000, FileShare.Read, IntPtr.Zero, 3, 0x00200000 | 0x08000000, IntPtr.Zero);
                if (handle.IsInvalid) { var code = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(code, "Donnée ouverte ou non retirable ; désinstallation refusée avant mutation."); }
                FileStream? stream = null;
                try
                {
                    stream = new FileStream(handle, FileAccess.Read, 65536); PackageLifecycleFiles.Check(path);
                    var matches = stream.Length == item.Length && Convert.ToHexStringLower(SHA256.HashData(stream)) == item.Sha256;
                    stream.Position = 0; held.Add(new(item, stream, matches));
                }
                catch { if (stream is null) handle.Dispose(); else stream.Dispose(); throw; }
            }
        }
        catch { Dispose(); throw; }
    }
    internal void Backup(PackageLifecycleFiles paths, string root, CancellationToken token)
    {
        if (held.Count == 0) return;
        paths.MakeDirectory(root);
        foreach (var item in held)
        {
            token.ThrowIfCancellationRequested();
            if (!item.Matches) throw new InvalidDataException("Données modifiées depuis confirmation ; aucune suppression.");
            var path = PackageLifecycleFiles.At(root, item.Expected.Kind + "/" + item.Expected.Path);
            // Parent creation follows the existing pinned directory chain and never accepts a redirect.
            var folders = new Stack<string>();
            for (var current = Path.GetDirectoryName(path)!; !PackageLifecycleFiles.Exists(current); current = Path.GetDirectoryName(current)!) folders.Push(current);
            while (folders.TryPop(out var directory)) paths.MakeDirectory(directory);
            using (var destination = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough))
            {
                item.File.Position = 0; var buffer = new byte[65536]; int count;
                while ((count = item.File.Read(buffer)) != 0) { token.ThrowIfCancellationRequested(); destination.Write(buffer, 0, count); }
                destination.Flush(true); item.File.Position = 0;
            }
        }
        CheckBackups(root, token);
    }
    internal void CheckBackups(string root, CancellationToken token)
    {
        foreach (var item in held.Where(x => x.Matches))
        {
            token.ThrowIfCancellationRequested();
            var path = PackageLifecycleFiles.At(root, item.Expected.Kind + "/" + item.Expected.Path);
            if (backups.ContainsKey(path)) continue;
            PackageLifecycleFiles.Check(path);
            var copy = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.SequentialScan);
            try
            {
                PackageLifecycleFiles.Check(path);
                if (copy.Length != item.Expected.Length || Convert.ToHexStringLower(SHA256.HashData(copy)) != item.Expected.Sha256)
                    throw new InvalidDataException("Copie de conservation des données non conforme ; aucune suppression de données.");
                backups.Add(path, copy); // Keep the verified preservation bytes immutable until deletion finishes.
            }
            catch { copy.Dispose(); throw; }
        }
    }
    internal IReadOnlyList<string> Remove(CancellationToken token)
    {
        var preserved = new List<string>();
        foreach (var item in held)
        {
            token.ThrowIfCancellationRequested();
            if (!item.Matches) { preserved.Add(item.Expected.Kind + ":" + item.Expected.Path); continue; }
            var disposition = new Disposition { Delete = 1 };
            if (!SetFileInformation(item.File.SafeFileHandle, 4, ref disposition, 1)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Suppression de la donnée détenue refusée ; preuve conservée.");
            item.File.Dispose();
        }
        return preserved;
    }
    public void Dispose()
    {
        foreach (var item in held) item.File.Dispose(); held.Clear();
        foreach (var file in backups.Values) file.Dispose(); backups.Clear();
    }
    [StructLayout(LayoutKind.Sequential)] private struct Disposition { internal byte Delete; }
    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial SafeFileHandle CreateFile(string path, uint access, FileShare sharing, IntPtr security, uint creation, uint flags, IntPtr template);
    [LibraryImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static partial bool SetFileInformation(SafeFileHandle handle, int kind, ref Disposition info, uint size);
}
