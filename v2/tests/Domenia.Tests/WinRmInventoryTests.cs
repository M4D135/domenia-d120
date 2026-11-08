using System.Xml;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class WinRmInventoryTests
{
    private const string Resource = WsmanReadChannel.Prefix + "root/cimv2/Win32_ComputerSystem";
    private const string Registry = WsmanReadChannel.Prefix + "root/default/StdRegProv";

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

    private static void Refused(Action action)
    {
        var refused = false;
        try { action(); } catch (XmlException) { refused = true; }
        Check.True(refused, "réponse malformée refusée sans lecture secondaire");
    }
}
