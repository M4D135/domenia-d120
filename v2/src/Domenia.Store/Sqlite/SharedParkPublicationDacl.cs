using System.Security.AccessControl;

namespace Domenia.Store;

/// <summary>Recognizes only the legacy-to-auto-inherited duplication observed in the Windows publication fixtures.
/// Recognition is permission to restore the confirmed DACL, never permission to accept the converted one as success.</summary>
internal static class SharedParkPublicationDacl
{
    private const ControlFlags DaclFlags = ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclDefaulted
        | ControlFlags.DiscretionaryAclUntrusted | ControlFlags.ServerSecurity | ControlFlags.DiscretionaryAclAutoInheritRequired
        | ControlFlags.DiscretionaryAclAutoInherited | ControlFlags.DiscretionaryAclProtected;

    internal static bool IsLegacyInheritedDuplication(RawSecurityDescriptor initial, RawSecurityDescriptor observed)
    {
        if ((initial.ControlFlags & DaclFlags) != ControlFlags.DiscretionaryAclPresent
            || (observed.ControlFlags & DaclFlags) != (ControlFlags.DiscretionaryAclPresent | ControlFlags.DiscretionaryAclAutoInherited))
        { return false; }
        var before = initial.DiscretionaryAcl; var after = observed.DiscretionaryAcl;
        if (before is null || after is null || before.Revision != GenericAcl.AclRevision || after.Revision != before.Revision
            || before.Count == 0 || after.Count != before.Count * 2)
        { return false; }
        for (var i = 0; i < before.Count; i++)
        {
            // No deny, object-specific, callback, conditional, explicit or propagating ACE shape is inferred from these fixtures.
            var ace = before[i];
            if (ace.AceType != AceType.AccessAllowed || ace.AceFlags != AceFlags.Inherited
                || !SameAce(ace, after[i], explicitCopy: true) || !SameAce(ace, after[before.Count + i]))
            { return false; }
        }
        return true;
    }

    internal static bool IsExact(RawSecurityDescriptor initial, RawSecurityDescriptor observed)
    {
        if ((initial.ControlFlags & DaclFlags) != (observed.ControlFlags & DaclFlags)) { return false; }
        var before = initial.DiscretionaryAcl; var after = observed.DiscretionaryAcl;
        if (before is null || after is null) { return before is null && after is null; }
        if (before.Revision != after.Revision || before.Count != after.Count) { return false; }
        for (var i = 0; i < before.Count; i++) { if (!SameAce(before[i], after[i])) { return false; } }
        return true;
    }

    private static bool SameAce(GenericAce initial, GenericAce observed, bool explicitCopy = false)
    {
        if (initial.BinaryLength != observed.BinaryLength) { return false; }
        var expected = new byte[initial.BinaryLength]; var actual = new byte[observed.BinaryLength];
        initial.GetBinaryForm(expected, 0); observed.GetBinaryForm(actual, 0);
        if (explicitCopy) { expected[1] = (byte)(expected[1] & ~(byte)AceFlags.Inherited); }
        return expected.AsSpan().SequenceEqual(actual);
    }
}
