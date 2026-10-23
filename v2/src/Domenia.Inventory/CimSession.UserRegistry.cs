using System.Collections.Immutable;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using Domenia.Core;
using Domenia.Core.Poste;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Inventory;

public sealed partial class CimSession
{
    private const string ActiveComputerNameKey = @"SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName";
    internal Func<string, string, RegistryReply>? UserRegistryOverride { get; init; }

    internal WorkstationUserReading ReadRemoteRegistryUserIdentity()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var startedAt = clock.GetTimestamp();
        WorkstationUserReading Result(string? name, SourceStatus status, string detail, ImmutableArray<WorkstationUserCandidate> candidates) =>
            new(name, new("RemoteRegistry", status, detail, (int)clock.GetElapsedTime(startedAt).TotalMilliseconds, candidates.Length, InventoryTransport.RemoteRegistry)
            { AuthenticationRejected = authenticationRefused }, candidates);
        if (!RegistryEnabled) { return Result(null, SourceStatus.Skipped, "Registre distant désactivé par Remote.UseRemoteRegistry ; aucun contact.", []); }
        if (authenticationRefused) { return Result(null, SourceStatus.Refused, "Identifiants déjà refusés ; aucune nouvelle connexion.", []); }
        if (OutOfBudget || cancellationToken.IsCancellationRequested) { return Result(null, SourceStatus.Interrupted, "Budget atteint avant le registre distant.", []); }
        WorkstationUserReading Read(RegistryKey? root)
        {
            RegistryReply Value(string key, string name)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (OutOfBudget) { throw new TimeoutException(); }
                try
                {
                    var reply = UserRegistryOverride?.Invoke(key, name) ?? RemoteRegistryText(root!, key, name);
                    authenticationRefused |= WindowsAuthenticationErrors.IsRejected(unchecked((int)reply.Code));
                    if (reply.Code == 0 && (reply.Value is not string text || text.Length > 320 || text.Any(char.IsControl))) { return new(13, null); }
                    return reply;
                }
                catch (Exception ex) when (ex is Win32Exception or IOException or UnauthorizedAccessException or SecurityException)
                {
                    var code = RegistryUserError(ex); authenticationRefused |= WindowsAuthenticationErrors.IsRejected(unchecked((int)code));
                    return new(code, null);
                }
            }
            var identity = Value(ActiveComputerNameKey, "ComputerName");
            var computer = identity.Code == 0 ? identity.Value as string : null;
            if (!string.Equals(computer, Host.Split('.')[0], StringComparison.OrdinalIgnoreCase))
            { return Result(computer, identity.Code is 5 or 1314 || authenticationRefused ? SourceStatus.Refused : SourceStatus.Unavailable,
                "Identité Windows non confirmée dans le registre ; LogonUI non interrogé.", []); }
            var candidates = ImmutableArray.CreateBuilder<WorkstationUserCandidate>();
            uint failure = 0;
            foreach (var name in new[] { "LastLoggedOnSAMUser", "LastLoggedOnUser" })
            {
                var read = Value(InventoryRegistry.LogonUi, name);
                if (read.Code == 0 && read.Value is string { Length: > 0 } text)
                { candidates.Add(new(text, null, null, "Registre distant LogonUI." + name)); }
                else if (read.Code is not (0 or 2 or 3)) { failure = read.Code; }
                if (authenticationRefused) { break; }
            }
            if (authenticationRefused) { return Result(computer, SourceStatus.Refused, "Identifiants rejetés ; aucune autre valeur ni identité essayée.", []); }
            var final = Value(ActiveComputerNameKey, "ComputerName");
            if (final.Code != 0 || !string.Equals(final.Value as string, computer, StringComparison.OrdinalIgnoreCase))
            { return Result(null, final.Code is 5 or 1314 || authenticationRefused ? SourceStatus.Refused : SourceStatus.Unavailable,
                "Identité du registre non confirmée après la lecture ; candidats écartés.", []); }
            var status = failure == 0 ? candidates.Count == 0 ? SourceStatus.Empty : SourceStatus.Ok
                : failure is 5 or 1314 ? SourceStatus.Refused : candidates.Count > 0 ? SourceStatus.Partial : SourceStatus.Unavailable;
            return Result(computer, status, "Derniers noms affichés par LogonUI (RPC), sans date de connexion ni SID ; lecture seule."
                + (failure != 0 ? " Une valeur n’a pas pu être lue (code " + failure + ")." : ""), candidates.ToImmutable());
        }
        try
        {
            if (UserRegistryOverride is not null) { return Read(null); }
            return WithNetworkIdentity(() =>
            {
                using var root = RegistryKey.OpenRemoteBaseKey(RegistryHive.LocalMachine, Host, RegistryView.Registry64);
                return Read(root);
            });
        }
        catch (Exception ex) when (ex is Win32Exception or IOException or UnauthorizedAccessException or SecurityException)
        {
            var code = RegistryUserError(ex); authenticationRefused |= WindowsAuthenticationErrors.IsRejected(unchecked((int)code));
            return Result(null, authenticationRefused || code is 5 or 1314 ? SourceStatus.Refused : SourceStatus.Unavailable,
                "Registre distant refusé ou indisponible (code " + code + ") ; aucune modification de service.", []);
        }
    }

    private static uint RegistryUserError(Exception ex)
    {
        if (ex is UnauthorizedAccessException or SecurityException) { return 5; }
        var code = unchecked((uint)(ex is Win32Exception native ? native.NativeErrorCode : ex.HResult));
        return (code & 0xffff0000) == 0x80070000 ? code & ushort.MaxValue : code;
    }

    private static RegistryReply RemoteRegistryText(RegistryKey root, string path, string name)
    {
        using var key = root.OpenSubKey(path, writable: false);
        if (key is null) { return new(2, null); }
        uint length = 0;
        var code = RegQueryUserValue(key.Handle, name, IntPtr.Zero, out var type, null, ref length);
        if (code != 0) { return new(unchecked((uint)code), null); }
        if (type is not (1 or 2) || length > 2048 || (length & 1) != 0) { return new(13, null); }
        var data = new byte[length]; var capacity = length;
        code = RegQueryUserValue(key.Handle, name, IntPtr.Zero, out var actualType, data, ref length);
        if (code != 0) { return new(unchecked((uint)code), null); }
        if (length > capacity || actualType != type) { return new(13, null); }
        try { return new(0, DecodeUserRegistryText(data.AsSpan(0, (int)length))); }
        catch (InvalidDataException) { return new(13, null); }
    }

    internal static string DecodeUserRegistryText(ReadOnlySpan<byte> data)
    {
        if (data.Length > 2048 || (data.Length & 1) != 0) { throw new InvalidDataException("Texte registre hors limites."); }
        string text;
        try { text = new UnicodeEncoding(false, false, true).GetString(data).TrimEnd('\0'); }
        catch (DecoderFallbackException ex) { throw new InvalidDataException("UTF-16 registre invalide.", ex); }
        if (text.Length > 320 || text.Any(char.IsControl)) { throw new InvalidDataException("Texte registre hors contrat."); }
        // REG_EXPAND_SZ remains literal: never expand a path or an environment variable into an account identity.
        return text;
    }

    [DllImport("advapi32.dll", EntryPoint = "RegQueryValueExW", CharSet = CharSet.Unicode)]
    private static extern int RegQueryUserValue(SafeRegistryHandle key, string name, IntPtr reserved, out uint type, [Out] byte[]? data, ref uint length);
}
