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
    internal const string WsmanNamespace = "http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd";
    private const string AddressingNamespace = "http://schemas.xmlsoap.org/ws/2004/08/addressing";
    private const string CimCommonNamespace = "http://schemas.dmtf.org/wbem/wscim/1/common";
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
    /// <summary>Code of a failure that ends this session: no later call reconnects (see <see cref="EndsSession"/>).</summary>
    private int? sessionFailure;

    internal WsmanReadChannel(string host, RemoteProbeCredential? credential, TimeProvider clock, CancellationToken token)
    {
        // Kerberos does not authenticate an IP endpoint. Never silently change authentication or TrustedHosts.
        if (!CimQuery.IsHostName(host) || IPAddress.TryParse(host, out _)) { throw new ArgumentException("WinRM Kerberos demande le nom DNS ou NetBIOS du poste."); }
        this.host = host; this.credential = credential; this.clock = clock; this.token = token;
    }

    private dynamic Session(TimeSpan remaining)
    {
        token.ThrowIfCancellationRequested();
        if (sessionFailure is int failure) { throw new COMException("Session WinRM déjà en échec ; aucun nouvel essai.", failure); }
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
                // A late-bound null connectionOptions is refused with E_INVALIDARG: every WinRM read with the session identity failed
                // in 0x80070057 before any exchange (bench and hosted-runner replay of 11/11/2026). Omit the argument instead.
                var endpoint = "http://" + host + ":5985/wsman";
                connection = options is null ? ((dynamic)automation).CreateSession(endpoint, flags) : ((dynamic)automation).CreateSession(endpoint, flags, options);
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
            try { enumerator = Session(Left()).Enumerate(EnumerationResource(ns), query, WqlDialect, 0); }
            catch (Exception ex) when (ComFailure(ex) is { } com) { throw Fault(com); }
            while (true)
            {
                string xml;
                try
                {
                    Session(Left());
                    if (((dynamic)enumerator).AtEndOfStream) { break; }
                    xml = ((dynamic)enumerator).ReadItem();
                }
                catch (Exception ex) when (ComFailure(ex) is { } com) { throw Fault(com); }
                yield return ParseInstance(xml, resource, plan.Properties);
            }
        }
        finally { Release(enumerator); }
    }

    /// <summary>WS-Management accepts a WQL filter only on the namespace-wide resource (« winrm enumerate wmicimv2/* -filter »);
    /// a class resource with a WQL filter is refused (0x803380FB on a hosted runner, 11/11/2026). A projection comes back as
    /// an XmlFragment, « SELECT * » under its class resource; ParseInstance accepts both.</summary>
    internal static string EnumerationResource(string ns) => Prefix + ns.Replace('\\', '/') + "/*";

    internal void Identify(TimeSpan timeout)
    {
        try { CheckIdentify((string)Session(timeout).Identify(0)); }
        catch (Exception ex) when (ComFailure(ex) is { } com) { throw Fault(com); }
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
        catch (Exception ex) when (ComFailure(ex) is { } com) { throw Fault(com); }
        finally { Release(locator); }
    }

    /// <summary>An instance is either the class element in its resource namespace (« SELECT * ») or, for a WQL projection on the
    /// namespace resource, a WS-Management XmlFragment whose properties are unqualified (hosted runner, 11/11/2026). The fragment
    /// carries no class identity: the class is the one of the query the server filtered. Anything else is refused.</summary>
    internal static WmiInstance ParseInstance(string xml, string resource, IReadOnlyCollection<string> properties)
    {
        var root = ParseXml(xml);
        var separator = resource.LastIndexOf('/');
        string children;
        if (root.Name == XName.Get("XmlFragment", WsmanNamespace)) { children = ""; }
        else if (root.Name.NamespaceName == resource && root.Name.LocalName == resource[(separator + 1)..]) { children = resource; }
        else { throw new XmlException("Identité de projection WinRM inattendue."); }
        var allowed = properties.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var values = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in root.Elements().GroupBy(e => e.Name.LocalName, StringComparer.OrdinalIgnoreCase))
        {
            if (!allowed.Contains(group.Key)) { continue; } // Unrequested data, including secrets, is never retained.
            if (group.Count() > 2048 || group.Any(e => e.Name.NamespaceName != children)) { throw new XmlException("Projection WinRM invalide."); }
            var array = group.Select(e => Value(e, resource[..(separator + 1)])).ToArray();
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
        if (kind is RegistryMethod.Keys or RegistryMethod.Strings) { return new(0, elements.Select(e => Value(e)).Where(v => v is not null).Cast<string>().ToArray()); }
        if (elements.Length != 1) { throw new XmlException("Valeur de registre WinRM illisible."); }
        var text = Value(elements[0]);
        if (kind == RegistryMethod.Dword) { return uint.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var number) ? new(0, number) : new(0, null); }
        return new(0, text);
    }

    /// <summary>Text of one property. Two structured forms are rendered as their DCOM text: a CIM date (« Datetime » in ISO 8601)
    /// becomes the DMTF string the readers parse, and a reference (an endpoint reference in the queried namespace) becomes the
    /// relative WMI path « Class.Key="value" ». Any other nested content is refused.</summary>
    private static string? Value(XElement element, string? namespaceResource = null)
    {
        if (element.HasElements)
        {
            return (namespaceResource is null ? null : Datetime(element) ?? Reference(element, namespaceResource))
                ?? throw new XmlException("Valeur WinRM hors limites.");
        }
        if (element.Value.Length > 32768) { throw new XmlException("Valeur WinRM hors limites."); }
        return (string?)element.Attribute(XName.Get("nil", "http://www.w3.org/2001/XMLSchema-instance")) is "true" or "1" ? null : element.Value;
    }

    private static string? Datetime(XElement element)
    {
        var parts = element.Elements().ToArray();
        if (parts.Length != 1 || parts[0].Name.LocalName != "Datetime" || parts[0].Name.NamespaceName is not ("" or CimCommonNamespace)
            || parts[0].HasElements || parts[0].Value.Length > 40) { return null; }
        var text = parts[0].Value.Trim();
        // Only an explicit offset is a point in time; a date without one would be read in the reader's own zone.
        if (!(text.EndsWith('Z') || (text.Length > 6 && text[^6] is '+' or '-'))
            || !DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var value)) { return null; }
        var minutes = (int)value.Offset.TotalMinutes;
        return value.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture) + "."
            + (value.Ticks % TimeSpan.TicksPerSecond / 10).ToString("D6", CultureInfo.InvariantCulture)
            + (minutes < 0 ? "-" : "+") + Math.Abs(minutes).ToString("D3", CultureInfo.InvariantCulture);
    }

    private static string? Reference(XElement element, string namespaceResource)
    {
        var parameters = element.Element(XName.Get("ReferenceParameters", AddressingNamespace));
        var uri = (string?)parameters?.Element(XName.Get("ResourceURI", WsmanNamespace));
        var selectors = parameters?.Element(XName.Get("SelectorSet", WsmanNamespace))?.Elements().ToArray();
        if (element.Elements().Any(e => e.Name.NamespaceName != AddressingNamespace || e.Name.LocalName is not ("Address" or "ReferenceParameters"))
            || uri is null || !uri.StartsWith(namespaceResource, StringComparison.Ordinal) || selectors is not { Length: > 0 and <= 4 }) { return null; }
        var className = uri[namespaceResource.Length..];
        if (className.Length is 0 or > 128 || !className.All(c => char.IsAsciiLetterOrDigit(c) || c == '_')) { return null; }
        var keys = new List<string>();
        foreach (var selector in selectors)
        {
            var name = (string?)selector.Attribute("Name");
            if (selector.Name != XName.Get("Selector", WsmanNamespace) || selector.HasElements || name is not { Length: > 0 and <= 64 }
                || !name.All(char.IsAsciiLetter) || selector.Value.Length > 512) { return null; }
            keys.Add(name + "=\"" + selector.Value.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal) + "\"");
        }
        return className + "." + string.Join(',', keys);
    }

    private static XElement ParseXml(string xml)
    {
        if (xml.Length > 1_048_576) { throw new XmlException("Réponse WinRM hors limites."); }
        using var input = new StringReader(xml);
        using var reader = XmlReader.Create(input, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 1_048_576 });
        return XElement.Load(reader, LoadOptions.None);
    }

    /// <summary>A WSMan.Automation call fails as a COMException or, for some HRESULTs, as the managed type the runtime maps it
    /// to (E_INVALIDARG: ArgumentException, E_ACCESSDENIED: UnauthorizedAccessException). Both keep the numeric code; nothing
    /// else inside the guarded COM calls throws these types. Bench of 11/11/2026: CreateSession raised E_INVALIDARG, which
    /// escaped as an ArgumentException and stopped the reading process.</summary>
    internal static COMException? ComFailure(Exception exception) => exception switch
    {
        COMException com => com,
        ArgumentException or UnauthorizedAccessException or InvalidCastException or NotImplementedException
            => new COMException("Lecture WinRM refusée ou indisponible.", exception.HResult),
        _ => null,
    };

    /// <summary>A refusal, or a workstation that cannot be reached at all, ends the session. WSMan.Automation reconnects on
    /// every call and a refused connection costs about 4 s each time, whatever the session Timeout (bench and hosted-runner
    /// replay of 11/11/2026: no listener on 5985, 0x80338012 in 4.0 to 4.2 s, a 3 s Timeout not honoured). Repeating it for
    /// each source pushed the inventory past its « no new data » limit; later calls now fail at once with the same code.
    /// An operation timeout (0x80338029) or an absent class stays local to its source.</summary>
    internal static bool EndsSession(int code) => code == unchecked((int)0x80070005) || WindowsAuthenticationErrors.IsRejected(code)
        || code == unchecked((int)0x80338012) || code == unchecked((int)0x80338126);

    private COMException Fault(COMException original)
    {
        COMException Outcome(int code)
        {
            if (EndsSession(code)) { sessionFailure = code; }
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
        catch (Exception ex) when (ex is XmlException || ComFailure(ex) is not null) { /* Keep the original numeric outcome if the fault itself is unreadable. */ }
        return Outcome(original.HResult);
    }

    /// <summary>Loads WSMan.Automation, the late-bound COM binder and the XML reader once per reading process, during its
    /// startup (see <see cref="NativeReadWarmup"/>). Activation is local: no session is created and nothing is sent; only the
    /// automation object's own Error property is read, then the object is released.</summary>
    internal static void Prime()
    {
        object? automation = null;
        try
        {
            automation = Activator.CreateInstance(Type.GetTypeFromProgID("WSMan.Automation", throwOnError: true)!)!;
            _ = ((dynamic)automation).Error;
        }
        finally { Release(automation); }
        var resource = Prefix + "root/cimv2/Win32_OperatingSystem";
        _ = ParseInstance("<p:Win32_OperatingSystem xmlns:p=\"" + resource + "\"><p:Caption>Windows</p:Caption></p:Win32_OperatingSystem>", resource, ["Caption"]);
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
