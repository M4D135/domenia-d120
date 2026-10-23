using System.Management;
using System.Security.Principal;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal enum RegistryMethod { Keys, String, Dword, Strings }
internal sealed record RegistryRequest(uint Hive, string Key, string? Name, RegistryMethod Method);
internal sealed record RegistryReply(uint Code, object? Value);
internal sealed record RegistryReading(SourceStatus Status, bool Found, object? Value, string Detail, int DurationMs)
{
    internal bool AuthenticationRejected { get; init; }
    internal bool Answered => Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial;
    internal string? Text => Value as string;
    internal string[] Strings => Value as string[] ?? [];
    internal long? Number => WmiInstance.AsNumber(Value);
    internal bool? Flag => Number switch { 0 => false, 1 => true, _ => null };
}

/// <summary>A closed inventory-only registry projection, distinct from the SELECT query workshop.</summary>
internal static class InventoryRegistry
{
    internal const uint Machine = 0x80000002;
    internal const uint Users = 0x80000003;
    internal const string Uninstall = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";
    internal const string Uninstall32 = @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall";
    internal const string UpdatePolicy = @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";
    internal const string UpdateInstall = @"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install";
    internal const string CbsPending = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending";
    internal const string UpdatePending = @"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired";
    internal const string SessionManager = @"SYSTEM\CurrentControlSet\Control\Session Manager";
    internal const string SecureBoot = @"SYSTEM\CurrentControlSet\Control\SecureBoot\State";
    internal const string WindowsVersion = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
    internal const string Netlogon = @"SYSTEM\CurrentControlSet\Services\Netlogon\Parameters";
    internal const string LogonUi = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI";
    internal const string LocalFirewall = @"SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\";
    internal const string PolicyFirewall = @"SOFTWARE\Policies\Microsoft\WindowsFirewall\";

    internal static bool ProfileSid(string value)
    {
        if (!(value.StartsWith("S-1-5-21-", StringComparison.OrdinalIgnoreCase) || value.StartsWith("S-1-12-1-", StringComparison.OrdinalIgnoreCase))) { return false; }
        try { return new SecurityIdentifier(value).Value.Equals(value, StringComparison.OrdinalIgnoreCase); }
        catch (ArgumentException) { return false; }
    }

    internal static bool Allowed(RegistryRequest request)
    {
        if (!Enum.IsDefined(request.Method) || request.Key.Length > 1024 || request.Key.Any(char.IsControl)
            || request.Key.Split('\\').Any(p => p is "." or "..") || request.Key.Contains('/', StringComparison.Ordinal)
            || request.Name is { } name && (name.Length is 0 or > 256 || name.Any(char.IsControl))) { return false; }
        var key = request.Key;
        if (request.Hive == Users)
        {
            if (key.Length == 0) { return request.Method == RegistryMethod.Keys && request.Name is null; }
            var split = key.IndexOf('\\');
            if (split < 0 || !ProfileSid(key[..split])) { return false; }
            return Software(request with { Hive = Machine, Key = key[(split + 1)..] });
        }
        if (request.Hive != Machine) { return false; }
        if (Software(request)) { return true; }
        bool Is(string expected) => key.Equals(expected, StringComparison.OrdinalIgnoreCase);
        bool Value(string expected, RegistryMethod method) => request.Method == method && string.Equals(request.Name, expected, StringComparison.OrdinalIgnoreCase);
        if (Is(CbsPending) || Is(UpdatePending)) { return request.Method == RegistryMethod.Keys && request.Name is null; }
        if (Is(UpdatePolicy)) { return Value("WUServer", RegistryMethod.String); }
        if (Is(UpdatePolicy + @"\AU")) { return Value("UseWUServer", RegistryMethod.Dword); }
        if (Is(UpdateInstall)) { return Value("LastSuccessTime", RegistryMethod.String); }
        if (Is(SessionManager)) { return Value("PendingFileRenameOperations", RegistryMethod.Strings); }
        if (Is(SecureBoot)) { return Value("UEFISecureBootEnabled", RegistryMethod.Dword); }
        if (Is(WindowsVersion)) { return Value("DisplayVersion", RegistryMethod.String) || Value("UBR", RegistryMethod.Dword); }
        if (Is(Netlogon)) { return Value("DynamicSiteName", RegistryMethod.String) || Value("SiteName", RegistryMethod.String); }
        if (Is(LogonUi)) { return Value("LastLoggedOnUser", RegistryMethod.String) || Value("LastLoggedOnSAMUser", RegistryMethod.String); }
        foreach (var prefix in new[] { LocalFirewall, PolicyFirewall })
        {
            if (new[] { "DomainProfile", "StandardProfile", "PrivateProfile", "PublicProfile" }.Any(profile => Is(prefix + profile)))
            { return Value("EnableFirewall", RegistryMethod.Dword); }
        }
        const string services = @"SYSTEM\CurrentControlSet\Services\";
        return key.StartsWith(services, StringComparison.OrdinalIgnoreCase) && PosteServices.IsValidName(key[services.Length..])
            && Value("DependOnService", RegistryMethod.Strings);
    }

    private static bool Software(RegistryRequest request)
    {
        foreach (var root in new[] { Uninstall, Uninstall32 })
        {
            if (request.Key.Equals(root, StringComparison.OrdinalIgnoreCase)) { return request.Method == RegistryMethod.Keys && request.Name is null; }
            if (!request.Key.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase)) { continue; }
            var child = request.Key[(root.Length + 1)..];
            if (child.Length is 0 or > 256 || child.Contains('\\') || child.Any(char.IsControl)) { return false; }
            var allowed = request.Method switch
            {
                RegistryMethod.String => new[] { "DisplayName", "DisplayVersion", "Publisher", "InstallDate", "InstallLocation", "UninstallString", "ReleaseType", "ParentKeyName" },
                RegistryMethod.Dword => ["EstimatedSize", "SystemComponent"],
                _ => [],
            };
            return request.Name is not null && allowed.Contains(request.Name, StringComparer.OrdinalIgnoreCase);
        }
        return false;
    }
}

public sealed partial class CimSession
{
    internal Func<RegistryRequest, TimeSpan, RegistryReply>? RegistryOverride { get; init; }

    internal RegistryReading ReadRegistry(RegistryRequest request, TimeSpan? timeout = null)
    {
        var begin = clock.GetTimestamp();
        int Duration() => (int)clock.GetElapsedTime(begin).TotalMilliseconds;
        if (!InventoryRegistry.Allowed(request)) { return new(SourceStatus.Error, false, null, "Lecture de registre hors du contrat d’inventaire refusée avant contact.", 0); }
        if (authenticationRefused) { return new(SourceStatus.Refused, false, null, "Authentification déjà refusée ; aucun nouvel essai.", 0) { AuthenticationRejected = true }; }
        if (OutOfBudget || cancellationToken.IsCancellationRequested) { return new(SourceStatus.Interrupted, false, null, "Budget de lecture atteint.", 0); }
        var allowed = Bound(timeout ?? TimeSpan.FromSeconds(3));
        if (allowed > Remaining) { allowed = Remaining; }
        try
        {
            var reply = RegistryOverride?.Invoke(request, allowed) ?? RegistryQuery(request, allowed);
            cancellationToken.ThrowIfCancellationRequested();
            if (OutOfBudget || clock.GetElapsedTime(begin) >= allowed) { throw new TimeoutException(); }
            if (reply.Code is 2 or 3) { return new(SourceStatus.Empty, false, null, "Clé ou valeur absente.", Duration()); }
            if (reply.Code != 0)
            {
                var rejected = WindowsAuthenticationErrors.IsRejected(unchecked((int)(0x80070000U | reply.Code)));
                authenticationRefused |= rejected;
                return new(reply.Code == 5 || rejected ? SourceStatus.Refused : SourceStatus.Error, false, null,
                    reply.Code == 5 || rejected ? "Lecture du registre refusée." : "Le fournisseur de registre a refusé la lecture (code " + reply.Code + ").", Duration()) { AuthenticationRejected = rejected };
            }
            if (request.Method == RegistryMethod.String && reply.Value is string text && text.Length <= 32768)
            { return new(SourceStatus.Ok, true, text, "Valeur texte lue.", Duration()); }
            if (request.Method == RegistryMethod.Dword && WmiInstance.AsNumber(reply.Value) is long number and >= 0 and <= uint.MaxValue)
            { return new(SourceStatus.Ok, true, number, "Valeur numérique lue.", Duration()); }
            if (request.Method is RegistryMethod.Keys or RegistryMethod.Strings && (reply.Value is null || reply.Value is string[]))
            {
                var values = reply.Value as string[] ?? [];
                var capped = values.Take(2048).Where(v => v is not null && v.Length <= 32768).ToArray();
                return new(capped.Length != values.Length ? SourceStatus.Partial : SourceStatus.Ok, true, capped,
                    capped.Length != values.Length ? "Liste partielle ; plafond ou valeur illisible." : "Liste lue.", Duration());
            }
            return new(SourceStatus.Error, false, null, "Type de valeur du registre illisible.", Duration());
        }
        catch (Exception ex) when (Classify(ex) is SourceStatus state)
        {
            var rejected = WindowsAuthenticationErrors.IsRejected(ex.HResult); authenticationRefused |= rejected;
            return new(state, false, null, Detail(ex, state), Duration()) { AuthenticationRejected = rejected };
        }
    }

    private RegistryChannel? registryChannel;

    // One provider per bounded operation, owned by its worker; never shared across hosts or credentials.
    internal T RegistryBatch<T>(Func<T> read)
    {
        if (registryChannel is not null) { return read(); }
        using var channel = new RegistryChannel(this);
        registryChannel = channel;
        try { return read(); }
        finally { registryChannel = null; }
    }

    private RegistryReply RegistryQuery(RegistryRequest request, TimeSpan timeout)
    {
        if (registryChannel is not null) { return registryChannel.Query(request, timeout); }
        using var channel = new RegistryChannel(this);
        return channel.Query(request, timeout);
    }

    private sealed class RegistryChannel(CimSession session) : IDisposable
    {
        private ConnectionOptions? options;
        private ManagementScope? scope;
        private ManagementClass? provider;
        private readonly ManagementNamedValueCollection context = new() { { "__ProviderArchitecture", 64 }, { "__RequiredArchitecture", true } };

        internal RegistryReply Query(RegistryRequest request, TimeSpan timeout)
        {
            var begin = session.clock.GetTimestamp();
            TimeSpan Left()
            {
                session.cancellationToken.ThrowIfCancellationRequested();
                var left = timeout - session.clock.GetElapsedTime(begin);
                if (left <= TimeSpan.Zero) { throw new TimeoutException(); }
                return left;
            }
            if (provider is null)
            {
                options = new ConnectionOptions { Impersonation = ImpersonationLevel.Impersonate, Authentication = AuthenticationLevel.PacketPrivacy,
                    EnablePrivileges = false, Timeout = timeout < CimBudgets.Connect ? timeout : CimBudgets.Connect };
                if (session.credential is { Session: false } credential) { options.Username = credential.Account; options.SecurePassword = credential.Password; }
                scope = new ManagementScope(@"\\" + session.Host + @"\root\default", options);
                try
                {
                    scope.Connect();
                    provider = new(scope, new ManagementPath("StdRegProv"), new ObjectGetOptions { Timeout = Left(), Context = context });
                }
                catch { Dispose(); throw; }
            }
            provider.Options.Timeout = Left();
            var method = request.Method switch { RegistryMethod.Keys => "EnumKey", RegistryMethod.String => "GetStringValue", RegistryMethod.Dword => "GetDWORDValue", RegistryMethod.Strings => "GetMultiStringValue", _ => throw new InvalidOperationException() };
            using var input = provider.GetMethodParameters(method);
            input["hDefKey"] = request.Hive; input["sSubKeyName"] = request.Key;
            if (request.Method != RegistryMethod.Keys) { input["sValueName"] = request.Name; }
            using var output = provider.InvokeMethod(method, input, new InvokeMethodOptions { Timeout = Left(), Context = context });
            var code = WmiInstance.AsNumber(output?["ReturnValue"]);
            if (code is null or < 0 or > uint.MaxValue) { return new(uint.MaxValue, null); }
            var field = request.Method == RegistryMethod.Keys ? "sNames" : request.Method == RegistryMethod.Dword ? "uValue" : "sValue";
            var value = code == 0 ? output?[field] : null;
            return new((uint)code, value is Array array ? array.Clone() : value);
        }

        public void Dispose()
        {
            if (provider is not null) { provider.Scope.Options.SecurePassword = null; provider.Dispose(); provider = null; }
            if (scope is not null) { scope.Options.SecurePassword = null; scope = null; }
            if (options is not null) { options.SecurePassword = null; options = null; }
        }
    }
}
