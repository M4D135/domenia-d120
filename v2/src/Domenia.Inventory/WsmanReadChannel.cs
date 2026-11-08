using System.Globalization;
using System.Net;
using System.Runtime.InteropServices;
using System.Xml;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Queries.Wmi;

namespace Domenia.Inventory;

/// <summary>One native WinRM session, owned and disposed by its worker. Only SELECT and the closed registry reads leave it.</summary>
internal sealed partial class WsmanReadChannel : IDisposable
{
    internal const string Prefix = "http://schemas.microsoft.com/wbem/wsman/1/wmi/";
    private const string WqlDialect = "http://schemas.microsoft.com/wbem/wsman/1/WQL";
    private const int Kerberos = 524288;
    private const int ExplicitCredential = 4096;
    private readonly string host;
    private readonly RemoteProbeCredential? credential;
    private readonly TimeProvider clock;
    private readonly CancellationToken token;
    private object? automation;
    private object? options;
    private object? connection;
    private int? refused;

    internal WsmanReadChannel(string host, RemoteProbeCredential? credential, TimeProvider clock, CancellationToken token)
    {
        // Kerberos does not authenticate an IP endpoint. Never silently change authentication or TrustedHosts.
        if (!CimQuery.IsHostName(host) || IPAddress.TryParse(host, out _)) { throw new ArgumentException("WinRM Kerberos demande le nom DNS ou NetBIOS du poste."); }
        this.host = host; this.credential = credential; this.clock = clock; this.token = token;
    }

    private dynamic Session(TimeSpan remaining)
    {
        token.ThrowIfCancellationRequested();
        if (refused is int failure) { throw new COMException("Session WinRM déjà refusée ; aucun nouvel essai.", failure); }
        if (remaining <= TimeSpan.Zero) { throw new TimeoutException(); }
        if (connection is null)
        {
            try
            {
                var type = Type.GetTypeFromProgID("WSMan.Automation", throwOnError: true)!;
                automation = Activator.CreateInstance(type)!;
                var flags = Kerberos;
                if (credential is { Session: false })
                {
                    options = ((dynamic)automation).CreateConnectionOptions();
                    var native = (IConnectionOptions)options;
                    native.SetUserName(credential.Account!);
                    var secret = Marshal.SecureStringToBSTR(credential.Password!);
                    try { native.SetPassword(secret); }
                    finally { Marshal.ZeroFreeBSTR(secret); }
                    flags |= ExplicitCredential;
                }
                connection = ((dynamic)automation).CreateSession("http://" + host + ":5985/wsman", flags, options);
            }
            catch { Dispose(); throw; }
        }
        ((dynamic)connection).Timeout = (int)Math.Clamp(Math.Ceiling(remaining.TotalMilliseconds), 1, int.MaxValue);
        return connection;
    }

    internal IEnumerable<WmiInstance> Query(string ns, string query, TimeSpan timeout)
    {
        if (!CimQuery.IsReadOnlySelect(query, ns)) { throw new ArgumentException("Requête WinRM hors du contrat de lecture."); }
        var plan = WqlRules.Parse(query);
        var resource = Prefix + ns.Replace('\\', '/') + "/" + plan.ClassName;
        var start = clock.GetTimestamp();
        TimeSpan Left() => timeout - clock.GetElapsedTime(start);
        object? enumerator = null;
        try
        {
            try { enumerator = Session(Left()).Enumerate(resource, query, WqlDialect, 0); }
            catch (COMException ex) { throw Fault(ex); }
            while (true)
            {
                string xml;
                try
                {
                    Session(Left());
                    if (((dynamic)enumerator).AtEndOfStream) { break; }
                    xml = ((dynamic)enumerator).ReadItem();
                }
                catch (COMException ex) { throw Fault(ex); }
                yield return ParseInstance(xml, resource, plan.Properties);
            }
        }
        finally { Release(enumerator); }
    }

    internal void Identify(TimeSpan timeout)
    {
        try { CheckIdentify((string)Session(timeout).Identify(0)); }
        catch (COMException ex) { throw Fault(ex); }
    }

    internal static void CheckIdentify(string xml)
    {
        var root = ParseXml(xml);
        var ns = root.Name.NamespaceName;
        if (root.Name.LocalName != "IdentifyResponse" || ns is not ("http://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd" or "https://schemas.dmtf.org/wbem/wsman/identity/1/wsmanidentity.xsd"))
        { throw new XmlException("Réponse Identify inattendue."); }
        var protocols = root.Elements().Where(e => e.Name.LocalName == "ProtocolVersion" && e.Name.NamespaceName == ns).ToArray();
        if (protocols.Length != 1 || protocols[0].HasElements || protocols[0].Value is not ("http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd" or "https://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"))
        { throw new XmlException("Version WS-Management non reconnue."); }
    }

    internal RegistryReply ReadRegistry(RegistryRequest request, TimeSpan timeout)
    {
        if (!InventoryRegistry.Allowed(request)) { throw new ArgumentException("Lecture WinRM du registre hors contrat."); }
        var method = request.Method switch
        {
            RegistryMethod.Keys => "EnumKey", RegistryMethod.String => "GetStringValue", RegistryMethod.Dword => "GetDWORDValue",
            RegistryMethod.Strings => "GetMultiStringValue", _ => throw new ArgumentException("Méthode de registre refusée."),
        };
        var start = clock.GetTimestamp();
        TimeSpan Left() => timeout - clock.GetElapsedTime(start);
        var resource = Prefix + "root/default/StdRegProv";
        XNamespace ns = resource;
        var input = new XElement(ns + (method + "_INPUT"), new XElement(ns + "hDefKey", request.Hive), new XElement(ns + "sSubKeyName", request.Key));
        if (request.Name is not null) { input.Add(new XElement(ns + "sValueName", request.Name)); }
        object? locator = null;
        try
        {
            Session(Left());
            locator = ((dynamic)automation!).CreateResourceLocator(resource);
            ((dynamic)locator).AddOption("__ProviderArchitecture", 64, 1);
            ((dynamic)locator).AddOption("__RequiredArchitecture", true, 1);
            var xml = (string)Session(Left()).Invoke(method, locator, input.ToString(SaveOptions.DisableFormatting), 0);
            return ParseRegistry(xml, resource, method, request.Method);
        }
        catch (COMException ex) { throw Fault(ex); }
        finally { Release(locator); }
    }

    internal static WmiInstance ParseInstance(string xml, string resource, IReadOnlyCollection<string> properties)
    {
        var root = ParseXml(xml);
        if (root.Name.NamespaceName != resource || root.Name.LocalName != resource[(resource.LastIndexOf('/') + 1)..]) { throw new XmlException("Identité de projection WinRM inattendue."); }
        var allowed = properties.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var values = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in root.Elements().GroupBy(e => e.Name.LocalName, StringComparer.OrdinalIgnoreCase))
        {
            if (!allowed.Contains(group.Key)) { continue; } // Unrequested data, including secrets, is never retained.
            if (group.Count() > 2048 || group.Any(e => e.Name.NamespaceName != resource)) { throw new XmlException("Projection WinRM invalide."); }
            var array = group.Select(Value).ToArray();
            values[group.Key] = array.Length == 1 ? array[0] : array;
        }
        return new(values);
    }

    internal static RegistryReply ParseRegistry(string xml, string resource, string method, RegistryMethod kind)
    {
        var root = ParseXml(xml);
        if (root.Name != XName.Get(method + "_OUTPUT", resource)) { throw new XmlException("Réponse de registre WinRM inattendue."); }
        var codes = root.Elements(XName.Get("ReturnValue", resource)).ToArray();
        if (codes.Length != 1 || !uint.TryParse(Value(codes[0]), NumberStyles.None, CultureInfo.InvariantCulture, out var code)) { throw new XmlException("Code de registre WinRM illisible."); }
        if (code != 0) { return new(code, null); }
        var field = kind == RegistryMethod.Keys ? "sNames" : kind == RegistryMethod.Dword ? "uValue" : "sValue";
        var elements = root.Elements(XName.Get(field, resource)).Take(2049).ToArray();
        if (kind is RegistryMethod.Keys or RegistryMethod.Strings) { return new(0, elements.Select(Value).Where(v => v is not null).Cast<string>().ToArray()); }
        if (elements.Length != 1) { throw new XmlException("Valeur de registre WinRM illisible."); }
        var text = Value(elements[0]);
        if (kind == RegistryMethod.Dword) { return uint.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var number) ? new(0, number) : new(0, null); }
        return new(0, text);
    }

    private static string? Value(XElement element)
    {
        if (element.HasElements || element.Value.Length > 32768) { throw new XmlException("Valeur WinRM hors limites."); }
        return (string?)element.Attribute(XName.Get("nil", "http://www.w3.org/2001/XMLSchema-instance")) is "true" or "1" ? null : element.Value;
    }

    private static XElement ParseXml(string xml)
    {
        if (xml.Length > 1_048_576) { throw new XmlException("Réponse WinRM hors limites."); }
        using var input = new StringReader(xml);
        using var reader = XmlReader.Create(input, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_048_576 });
        return XElement.Load(reader, LoadOptions.None);
    }

    private COMException Fault(COMException original)
    {
        COMException Outcome(int code)
        {
            if (code == unchecked((int)0x80070005) || WindowsAuthenticationErrors.IsRejected(code)) { refused = code; }
            return new COMException("Lecture WinRM refusée ou indisponible.", code);
        }
        // WinRM wraps native authentication failures in WSManFault; use its numeric code, never its server-supplied text.
        try
        {
            if (connection is not null && ((dynamic)connection).Error is string xml && xml.Length > 0)
            {
                var root = ParseXml(xml);
                var fault = root.DescendantsAndSelf().FirstOrDefault(e => e.Name.LocalName == "WSManFault");
                if (uint.TryParse((string?)fault?.Attribute("Code"), NumberStyles.None, CultureInfo.InvariantCulture, out var code))
                { return Outcome(unchecked((int)(code < 65536 ? 0x80070000U | code : code))); }
            }
        }
        catch (Exception ex) when (ex is COMException or XmlException) { /* Keep the original numeric outcome if the fault itself is unreadable. */ }
        return Outcome(original.HResult);
    }

    public void Dispose()
    {
        // Native credential options are released after the connection; no managed password string is ever made.
        Release(connection); connection = null;
        Release(options); options = null;
        Release(automation); automation = null;
    }
    private static void Release(object? value) { if (value is not null && Marshal.IsComObject(value)) { Marshal.FinalReleaseComObject(value); } }

    // ABI from WSManDisp.idl: IDispatch's four slots, get_UserName, put_UserName, put_Password.
    // Password is an input BSTR borrowed from SecureStringToBSTR, allowing immediate zeroing without a managed string.
    [ComImport, Guid("F704E861-9E52-464F-B786-DA5EB2320FDD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IConnectionOptions
    {
        void GetTypeInfoCount(); void GetTypeInfo(); void GetIdsOfNames(); void DispatchInvoke();
        [return: MarshalAs(UnmanagedType.BStr)] string GetUserName();
        void SetUserName([MarshalAs(UnmanagedType.BStr)] string value);
        void SetPassword(IntPtr value);
    }
}
