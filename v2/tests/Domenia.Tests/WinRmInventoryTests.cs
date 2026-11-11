using System.Xml;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WinRmInventoryTests
{
    private const string Resource = WsmanReadChannel.Prefix + "root/cimv2/Win32_ComputerSystem";
    private const string Registry = WsmanReadChannel.Prefix + "root/default/StdRegProv";

    [Test]
    public static void Winrm_wql_enumeration_targets_the_namespace_wildcard_and_keeps_the_class_check_on_instances()
    {
        // Hosted runner of 11/11/2026: a class resource with a WQL filter is refused (0x803380FB); the namespace resource answers.
        Check.Equal(WsmanReadChannel.Prefix + "root/cimv2/*", WsmanReadChannel.EnumerationResource(@"root\cimv2"), "WQL sur l’espace de noms entier");
        Check.Equal(WsmanReadChannel.Prefix + "root/Microsoft/Windows/Defender/*", WsmanReadChannel.EnumerationResource(@"root\Microsoft\Windows\Defender"), "espace de noms imbriqué");
        var xml = "<p:Win32_ComputerSystem xmlns:p='" + Resource + "'><p:Name>PC1</p:Name></p:Win32_ComputerSystem>";
        Check.Equal("PC1", WsmanReadChannel.ParseInstance(xml, Resource, ["Name"]).Text("Name"), "instance rendue sous sa classe");
        Refused(() => WsmanReadChannel.ParseInstance(xml.Replace(Resource, WsmanReadChannel.EnumerationResource(@"root\cimv2"), StringComparison.Ordinal), Resource, ["Name"]));
    }

    [Test]
    public static void Winrm_xml_retains_only_selected_values_with_nulls_arrays_and_no_nested_objects()
    {
        var xml = "<p:Win32_ComputerSystem xmlns:p='" + Resource + "' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>"
            + "<p:Name>PC1</p:Name><p:UnusedSecret>NEVER-RETAIN</p:UnusedSecret><p:Domain xsi:nil='true'/><p:ChassisTypes>8</p:ChassisTypes><p:ChassisTypes>9</p:ChassisTypes><p:Enabled>false</p:Enabled></p:Win32_ComputerSystem>";
        var row = WsmanReadChannel.ParseInstance(xml, Resource, ["Name", "Domain", "ChassisTypes", "Enabled"]);
        Check.Equal("PC1", row.Text("Name"), "identité lue");
        Check.Null(row.Raw("UnusedSecret"), "valeur non demandée non retenue");
        Check.Null(row.Raw("Domain"), "nil reste inconnu");
        Check.Equal<bool?>(false, row.Bool("Enabled"), "booléen textuel");
        Check.Equal("8,9", string.Join(',', row.Ints("ChassisTypes")), "valeurs de tableau distinctes");
        Refused(() => WsmanReadChannel.ParseInstance(xml.Replace("<p:Name>PC1</p:Name>", "<p:Name><p:Nested>PC1</p:Nested></p:Name>", StringComparison.Ordinal), Resource, ["Name"]));
    }

    [Test]
    public static void Winrm_xml_rejects_external_entities_wrong_identity_and_oversized_values()
    {
        Refused(() => WsmanReadChannel.ParseInstance("<!DOCTYPE a [<!ENTITY leak SYSTEM 'file:///C:/secret'>]><a>&leak;</a>", Resource, ["Name"]));
        Refused(() => WsmanReadChannel.ParseInstance("<Win32_Process xmlns='" + Resource + "'><Name>PC1</Name></Win32_Process>", Resource, ["Name"]));
        Refused(() => WsmanReadChannel.ParseInstance("<Win32_ComputerSystem xmlns='urn:foreign'><Name>PC1</Name></Win32_ComputerSystem>", Resource, ["Name"]));
        Refused(() => WsmanReadChannel.ParseInstance("<Win32_ComputerSystem xmlns='" + Resource + "'><Name>" + new string('a', 32769) + "</Name></Win32_ComputerSystem>", Resource, ["Name"]));
    }

    [Test]
    public static void Winrm_registry_decodes_missing_zero_multistring_and_refuses_a_different_method()
    {
        string Xml(string method, string content) => "<" + method + "_OUTPUT xmlns='" + Registry + "'>" + content + "</" + method + "_OUTPUT>";
        var reply = WsmanReadChannel.ParseRegistry(Xml("GetStringValue", "<ReturnValue>2</ReturnValue>"), Registry, "GetStringValue", RegistryMethod.String);
        Check.Equal(2U, reply.Code, "absence conservée");
        reply = WsmanReadChannel.ParseRegistry(Xml("GetDWORDValue", "<ReturnValue>0</ReturnValue><uValue>0</uValue>"), Registry, "GetDWORDValue", RegistryMethod.Dword);
        Check.Equal(0U, (uint)reply.Value!, "zéro distinct d’absence");
        reply = WsmanReadChannel.ParseRegistry(Xml("GetMultiStringValue", "<ReturnValue>0</ReturnValue><sValue>A</sValue><sValue>B</sValue>"), Registry, "GetMultiStringValue", RegistryMethod.Strings);
        Check.Equal("A,B", string.Join(',', (string[])reply.Value!), "tableau restitué");
        Refused(() => WsmanReadChannel.ParseRegistry(Xml("GetStringValue", "<ReturnValue>0</ReturnValue><sValue>A</sValue><sValue>B</sValue>"), Registry, "GetStringValue", RegistryMethod.String));
        Refused(() => WsmanReadChannel.ParseRegistry(Xml("SetStringValue", "<ReturnValue>0</ReturnValue>"), Registry, "GetStringValue", RegistryMethod.String));
    }

    [Test]
    public static void Winrm_uses_the_same_query_and_registry_guards_and_session_budget_as_DCOM()
    {
        var calls = 0;
        using var session = new CimSession("PC1.test.local", TimeSpan.FromSeconds(5), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        {
            ReadOverride = (_, _, _) => { calls++; return []; }, RegistryOverride = (_, _) => { calls++; return new(2, null); },
        };
        Check.Equal(InventoryTransport.WinRm, session.Transport, "transport distinct");
        Check.Equal(SourceStatus.Error, session.Read("test", @"root\cimv2", "SELECT Name FROM Win32_Product", 1).Status, "fournisseur MSI interdit avant contact");
        Check.Equal(SourceStatus.Error, session.ReadRegistry(new(InventoryRegistry.Machine, @"SAM\SAM", "Value", RegistryMethod.String)).Status, "hors contrat avant contact");
        Check.Equal(0, calls, "aucun appel interdit");
        Check.Equal(SourceStatus.Empty, session.Read("test", @"root\cimv2", "SELECT Name FROM Win32_ComputerSystem", 1).Status, "lecture admise");
        Check.Equal(1, calls, "un appel");
    }

    [Test]
    public static void Winrm_IP_targets_are_refused_before_any_CIM_or_registry_contact()
    {
        var calls = 0;
        using var session = new CimSession("10.77.0.5", TimeSpan.FromSeconds(5), TestClock.Fixed(), transport: InventoryTransport.WinRm)
        {
            ReadOverride = (_, _, _) => { calls++; return []; }, RegistryOverride = (_, _) => { calls++; return new(2, null); },
        };
        Check.Equal(SourceStatus.Unavailable, session.Read("test", @"root\cimv2", "SELECT Name FROM Win32_ComputerSystem", 1).Status, "pas de Kerberos IP");
        Check.Equal(SourceStatus.Unavailable, session.ReadRegistry(new(InventoryRegistry.Machine, InventoryRegistry.Uninstall, null, RegistryMethod.Keys)).Status, "pas de repli registre IP");
        Check.Equal(0, calls, "aucun essai d’authentification par IP");
    }

    [Test]
    public static void Winrm_projection_fragment_is_read_with_unqualified_properties_dates_and_arrays()
    {
        // Hosted runner of 11/11/2026: a WQL projection on the namespace resource answers an XmlFragment with unqualified
        // properties; CIM dates come wrapped in « Datetime » (ISO 8601) and must reach the readers as DMTF text, as over DCOM.
        const string Os = WsmanReadChannel.Prefix + "root/cimv2/Win32_OperatingSystem";
        var xml = "<w:XmlFragment xmlns:w='" + WsmanReadChannel.WsmanNamespace + "' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>"
            + "<Caption>Windows 11</Caption><Secret>NEVER-RETAIN</Secret><InstallDate><Datetime>2026-01-02T03:04:05Z</Datetime></InstallDate>"
            + "<LastBootUpTime><Datetime>2026-11-11T09:30:00.123456+01:00</Datetime></LastBootUpTime><Speed xsi:nil='true'/>"
            + "<IPAddress>10.0.0.1</IPAddress><IPAddress>fe80::1</IPAddress></w:XmlFragment>";
        var row = WsmanReadChannel.ParseInstance(xml, Os, ["Caption", "InstallDate", "LastBootUpTime", "Speed", "IPAddress"]);
        Check.Equal("Windows 11", row.Text("Caption"), "propriété non qualifiée lue");
        Check.Null(row.Raw("Secret"), "valeur non demandée non retenue");
        Check.Equal("20260102030405.000000+000", row.Text("InstallDate"), "date CIM rendue en DMTF");
        Check.Equal<DateTimeOffset?>(new DateTimeOffset(2026, 11, 11, 8, 30, 0, TimeSpan.Zero).AddTicks(1_234_560), row.Dmtf("LastBootUpTime"), "décalage et microsecondes conservés");
        Check.Null(row.Raw("Speed"), "nil reste inconnu");
        Check.Equal("10.0.0.1,fe80::1", string.Join(',', row.Strings("IPAddress")), "tableau restitué");

        string Fragment(string body) => "<w:XmlFragment xmlns:w='" + WsmanReadChannel.WsmanNamespace + "'>" + body + "</w:XmlFragment>";
        Refused(() => WsmanReadChannel.ParseInstance(Fragment("<w:Caption>Windows 11</w:Caption>"), Os, ["Caption"]));
        Refused(() => WsmanReadChannel.ParseInstance(Fragment("<InstallDate><Datetime>2026-01-02T03:04:05</Datetime></InstallDate>"), Os, ["InstallDate"]));
        Refused(() => WsmanReadChannel.ParseInstance(Fragment("<InstallDate><Interval>P1D</Interval></InstallDate>"), Os, ["InstallDate"]));
        Refused(() => WsmanReadChannel.ParseInstance("<w:Fragment xmlns:w='" + WsmanReadChannel.WsmanNamespace + "'><Caption>x</Caption></w:Fragment>", Os, ["Caption"]));
    }

    [Test]
    public static void Winrm_endpoint_references_become_the_relative_wmi_paths_the_session_reader_parses()
    {
        // Win32_LoggedOnUser over WinRM: Antecedent and Dependent are endpoint references (ResourceURI and selectors), where
        // DCOM gives « Win32_Account.Domain="…",Name="…" ». Only a reference into the queried namespace is rendered.
        const string Link = WsmanReadChannel.Prefix + "root/cimv2/Win32_LoggedOnUser";
        string Reference(string resource, string selectors) => "<a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address>"
            + "<a:ReferenceParameters><w:ResourceURI>" + resource + "</w:ResourceURI><w:SelectorSet>" + selectors + "</w:SelectorSet></a:ReferenceParameters>";
        string Fragment(string body) => "<w:XmlFragment xmlns:w='" + WsmanReadChannel.WsmanNamespace + "' xmlns:a='http://schemas.xmlsoap.org/ws/2004/08/addressing'>" + body + "</w:XmlFragment>";
        var xml = Fragment("<Antecedent>" + Reference(WsmanReadChannel.Prefix + "root/cimv2/Win32_UserAccount", "<w:Selector Name='Domain'>CORP</w:Selector><w:Selector Name='Name'>j\"o\\e</w:Selector>") + "</Antecedent>"
            + "<Dependent>" + Reference(WsmanReadChannel.Prefix + "root/cimv2/Win32_LogonSession", "<w:Selector Name='LogonId'>999</w:Selector>") + "</Dependent>");
        var row = WsmanReadChannel.ParseInstance(xml, Link, ["Antecedent", "Dependent"]);
        Check.Equal("Win32_UserAccount.Domain=\"CORP\",Name=\"j\\\"o\\\\e\"", row.Text("Antecedent"), "référence rendue en chemin WMI relatif");
        Check.Equal("j\"o\\e", WmiLogonSessionsReader.Reference(row.Text("Antecedent"), "PC-1.test.local", "Win32_UserAccount")?["Name"], "chemin relu par le lecteur des sessions");
        Check.Equal("999", WmiLogonSessionsReader.Reference(row.Text("Dependent"), "PC-1.test.local", "Win32_LogonSession")?["LogonId"], "session liée");

        Refused(() => WsmanReadChannel.ParseInstance(Fragment("<Antecedent>" + Reference(WsmanReadChannel.Prefix + "root/default/StdRegProv", "<w:Selector Name='Name'>x</w:Selector>") + "</Antecedent>"), Link, ["Antecedent"]));
        Refused(() => WsmanReadChannel.ParseInstance(Fragment("<Antecedent>" + Reference(WsmanReadChannel.Prefix + "root/cimv2/Win32_UserAccount", "<w:Selector Name='Name'><w:Nested>x</w:Nested></w:Selector>") + "</Antecedent>"), Link, ["Antecedent"]));
        Refused(() => WsmanReadChannel.ParseInstance(Fragment("<Antecedent>" + Reference(WsmanReadChannel.Prefix + "root/cimv2/Win32_UserAccount", "") + "</Antecedent>"), Link, ["Antecedent"]));
    }

    private static void Refused(Action action)
    {
        var refused = false;
        try { action(); } catch (XmlException) { refused = true; }
        Check.True(refused, "réponse malformée refusée sans lecture secondaire");
    }
}
