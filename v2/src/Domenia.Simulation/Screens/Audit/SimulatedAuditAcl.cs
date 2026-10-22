using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Security descriptors of the fictitious domain (owner and DACL, no SACL), built from templates per kind of object and per
/// place in the tree, like the defaults of Active Directory plus the delegations of this lab: support on users, workstation
/// administrators on OU=Postes, server administrators on OU=Serveurs, replication rights given to svc-annuaire on the root.
/// Protected accounts and groups (adminCount = 1) carry the AdminSDHolder template, with inheritance disabled.
/// </summary>
internal static class SimulatedAuditAcl
{
    private const string LocalSystem = "S-1-5-18";
    private const string Self = "S-1-5-10";
    private const string Everyone = "S-1-1-0";
    private const string Authenticated = "S-1-5-11";
    private const string EnterpriseControllers = "S-1-5-9";
    private const string Administrators = "S-1-5-32-544";
    private const string AccountOperators = "S-1-5-32-548";
    private const string PreWindows2000 = "S-1-5-32-554";

    private static AceRead Ace(string sid, string rights, Guid? objectType = null, Guid? inheritedType = null, bool inherited = false, string inheritance = "None", bool allow = true) =>
        new(sid, allow, rights, objectType, inheritedType, inherited, inheritance);

    public static (ImmutableArray<AceRead> Aces, bool Protected) Build(
        DirectorySnapshot directory, AuditTarget target, Func<int, string> rid, Func<string, string?> userSid, Func<string, string?> groupSid)
    {
        ArgumentNullException.ThrowIfNull(directory);
        ArgumentNullException.ThrowIfNull(target);
        var domainAdmins = rid(512);
        var enterpriseAdmins = rid(519);
        var aces = new List<AceRead>();
        bool Under(string container)
        {
            try
            {
                return DistinguishedName.IsWithin(target.Dn, container + "," + directory.Domain.RootDn, subtree: true)
                    || DistinguishedName.AreEqual(target.Dn, container + "," + directory.Domain.RootDn);
            }
            catch (FormatException)
            {
                return false;
            }
        }
        var adminCount = target.Kind switch
        {
            AuditObjectKind.User => directory.Users.FirstOrDefault(u => u.ObjectGuid == target.ObjectGuid)?.AdminCount,
            AuditObjectKind.Group => directory.Groups.FirstOrDefault(g => g.ObjectGuid == target.ObjectGuid)?.AdminCount,
            _ => null,
        };
        if (adminCount == 1)
        {
            // AdminSDHolder: the same explicit list on every protected object, no inherited entry.
            aces.Add(Ace(LocalSystem, "GenericAll"));
            aces.Add(Ace(domainAdmins, "CreateChild, Self, WriteProperty, ExtendedRight, Delete, GenericRead, WriteDacl, WriteOwner"));
            aces.Add(Ace(enterpriseAdmins, "CreateChild, Self, WriteProperty, ExtendedRight, Delete, GenericRead, WriteDacl, WriteOwner"));
            aces.Add(Ace(Administrators, "CreateChild, Self, WriteProperty, ExtendedRight, Delete, GenericRead, WriteDacl, WriteOwner"));
            aces.Add(Ace(Authenticated, "GenericRead"));
            aces.Add(Ace(Everyone, "ExtendedRight", SimulatedAuditData.ChangePassword));
            aces.Add(Ace(Self, "ExtendedRight", SimulatedAuditData.ChangePassword));
            aces.Add(Ace(PreWindows2000, "ReadProperty", SimulatedAuditData.GeneralInformation));
            return ([.. aces], true);
        }
        switch (target.Kind)
        {
            case AuditObjectKind.Domain:
                aces.Add(Ace(LocalSystem, "GenericAll", inheritance: "All"));
                aces.Add(Ace(enterpriseAdmins, "GenericAll", inheritance: "All"));
                aces.Add(Ace(domainAdmins, "CreateChild, Self, WriteProperty, ExtendedRight, GenericRead, WriteDacl, WriteOwner"));
                aces.Add(Ace(Administrators, "CreateChild, Self, WriteProperty, ExtendedRight, Delete, GenericRead, WriteDacl, WriteOwner", inheritance: "All"));
                aces.Add(Ace(Administrators, "ExtendedRight", SimulatedAuditData.ReplicateChanges));
                aces.Add(Ace(Administrators, "ExtendedRight", SimulatedAuditData.ReplicateAllChanges));
                aces.Add(Ace(EnterpriseControllers, "ExtendedRight", SimulatedAuditData.ReplicateChanges));
                aces.Add(Ace(rid(516), "ExtendedRight", SimulatedAuditData.ReplicateAllChanges));
                if (userSid(SimulatedAuditData.ReplicationRightsAccount) is string sync)
                {
                    // The finding of the lab: replication rights outside the administrators (DCSync).
                    aces.Add(Ace(sync, "ExtendedRight", SimulatedAuditData.ReplicateChanges));
                    aces.Add(Ace(sync, "ExtendedRight", SimulatedAuditData.ReplicateAllChanges));
                }
                aces.Add(Ace(Authenticated, "GenericRead"));
                aces.Add(Ace(Authenticated, "ExtendedRight", SimulatedAuditData.ApplyGroupPolicy));
                aces.Add(Ace(PreWindows2000, "ListChildren, ReadProperty, ListObject, ReadControl", inheritedType: SimulatedAuditData.UserClass, inheritance: "Descendents"));
                aces.Add(Ace(Everyone, "ReadProperty", inheritance: "None"));
                return ([.. aces], false);
            case AuditObjectKind.OrganizationalUnit:
                aces.Add(Ace(LocalSystem, "GenericAll"));
                aces.Add(Ace(domainAdmins, "GenericAll"));
                aces.Add(Ace(AccountOperators, "CreateChild, DeleteChild", SimulatedAuditData.UserClass));
                aces.Add(Ace(AccountOperators, "CreateChild, DeleteChild", SimulatedAuditData.ComputerClass));
                aces.Add(Ace(AccountOperators, "CreateChild, DeleteChild", SimulatedAuditData.GroupClass));
                aces.Add(Ace(Authenticated, "GenericRead"));
                AddDelegations(aces, Under, groupSid, onContainer: true, target.Kind);
                aces.Add(Ace(enterpriseAdmins, "GenericAll", inherited: true, inheritance: "All"));
                aces.Add(Ace(PreWindows2000, "ListChildren, ReadProperty, ListObject, ReadControl", inheritedType: SimulatedAuditData.UserClass, inherited: true, inheritance: "Descendents"));
                return ([.. aces], false);
            case AuditObjectKind.User:
                aces.Add(Ace(LocalSystem, "GenericAll"));
                aces.Add(Ace(domainAdmins, "GenericAll"));
                aces.Add(Ace(AccountOperators, "GenericAll"));
                aces.Add(Ace(Self, "ReadProperty, WriteProperty", SimulatedAuditData.PersonalInformation));
                var service = target.Dn.Contains("OU=Comptes de service", StringComparison.OrdinalIgnoreCase);
                // « User cannot change password » on the service accounts: two explicit refusals, first in the list.
                if (service)
                {
                    aces.Insert(0, Ace(Everyone, "ExtendedRight", SimulatedAuditData.ChangePassword, allow: false));
                    aces.Insert(1, Ace(Self, "ExtendedRight", SimulatedAuditData.ChangePassword, allow: false));
                }
                else
                {
                    aces.Add(Ace(Self, "ExtendedRight", SimulatedAuditData.ChangePassword));
                    aces.Add(Ace(Everyone, "ExtendedRight", SimulatedAuditData.ChangePassword));
                }
                aces.Add(Ace(Authenticated, "ReadProperty", SimulatedAuditData.GeneralInformation));
                aces.Add(Ace(Authenticated, "ReadProperty", SimulatedAuditData.PublicInformation));
                aces.Add(Ace(Authenticated, "ReadControl"));
                aces.Add(Ace(rid(553), "ReadProperty", SimulatedAuditData.RemoteAccess));
                AddDelegations(aces, Under, groupSid, onContainer: false, target.Kind);
                aces.Add(Ace(enterpriseAdmins, "GenericAll", inherited: true, inheritance: "All"));
                aces.Add(Ace(PreWindows2000, "ListChildren, ReadProperty, ListObject, ReadControl", inheritedType: SimulatedAuditData.UserClass, inherited: true));
                return ([.. aces], false);
            case AuditObjectKind.Computer:
                aces.Add(Ace(LocalSystem, "GenericAll"));
                aces.Add(Ace(domainAdmins, "GenericAll"));
                aces.Add(Ace(AccountOperators, "GenericAll"));
                aces.Add(Ace(Self, "Self", SimulatedAuditData.DnsHostNameWrite));
                aces.Add(Ace(Self, "Self", SimulatedAuditData.SpnWrite));
                aces.Add(Ace(Authenticated, "GenericRead"));
                AddDelegations(aces, Under, groupSid, onContainer: false, target.Kind);
                aces.Add(Ace(enterpriseAdmins, "GenericAll", inherited: true, inheritance: "All"));
                aces.Add(Ace(PreWindows2000, "ListChildren, ReadProperty, ListObject, ReadControl", inherited: true));
                return ([.. aces], false);
            case AuditObjectKind.Group:
                aces.Add(Ace(LocalSystem, "GenericAll"));
                aces.Add(Ace(domainAdmins, "GenericAll"));
                aces.Add(Ace(AccountOperators, "GenericAll"));
                aces.Add(Ace(Authenticated, "GenericRead"));
                AddDelegations(aces, Under, groupSid, onContainer: false, target.Kind);
                aces.Add(Ace(enterpriseAdmins, "GenericAll", inherited: true, inheritance: "All"));
                return ([.. aces], false);
            default:
                aces.Add(Ace(LocalSystem, "GenericAll"));
                aces.Add(Ace(domainAdmins, "GenericAll"));
                aces.Add(Ace(Authenticated, "GenericRead"));
                return ([.. aces], false);
        }
    }

    /// <summary>
    /// Delegations of the lab, posed on their OU and inherited by the objects below (onContainer: the OU itself, where they are
    /// explicit and inherit-only for the objects they target).
    /// </summary>
    private static void AddDelegations(List<AceRead> aces, Func<string, bool> under, Func<string, string?> groupSid, bool onContainer, AuditObjectKind kind)
    {
        void Delegate(string group, string rights, Guid? objectType, Guid inheritedType, AuditObjectKind appliesTo)
        {
            if (groupSid(group) is not string sid)
            {
                return;
            }
            if (onContainer)
            {
                aces.Add(Ace(sid, rights, objectType, inheritedType, inherited: false, inheritance: "Descendents"));
            }
            else if (kind == appliesTo)
            {
                aces.Add(Ace(sid, rights, objectType, inheritedType, inherited: true, inheritance: "None"));
            }
        }
        if (under("OU=Utilisateurs"))
        {
            Delegate("GG-Support-N2", "ExtendedRight", SimulatedAuditData.ResetPassword, SimulatedAuditData.UserClass, AuditObjectKind.User);
            Delegate("GG-Support-N2", "ReadProperty, WriteProperty", SimulatedAuditData.LockoutTime, SimulatedAuditData.UserClass, AuditObjectKind.User);
            Delegate("GG-Support-N1", "ReadProperty, WriteProperty", SimulatedAuditData.LockoutTime, SimulatedAuditData.UserClass, AuditObjectKind.User);
        }
        if (under("OU=Postes"))
        {
            Delegate("GG-Admins-Postes", "GenericAll", null, SimulatedAuditData.ComputerClass, AuditObjectKind.Computer);
            Delegate("GG-Support-N2", "ExtendedRight", SimulatedAuditData.ResetPassword, SimulatedAuditData.ComputerClass, AuditObjectKind.Computer);
        }
        if (under("OU=Serveurs"))
        {
            Delegate("GG-Admins-Serveurs", "GenericAll", null, SimulatedAuditData.ComputerClass, AuditObjectKind.Computer);
        }
        if (under("OU=Groupes"))
        {
            Delegate("GG-Support-N2", "ReadProperty, WriteProperty", SimulatedAuditData.Member, SimulatedAuditData.GroupClass, AuditObjectKind.Group);
        }
    }
}
