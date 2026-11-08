using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.Tests;

/// <summary>Local Windows ACL fixtures only. These distinguish private preparation/retention from the permissions of the final TSV.</summary>
internal static class SharedParkPublicationAclTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private static readonly byte[] Before = Encoding.UTF8.GetBytes("PC1\t2026-10-20T10:00:00Z\tLU\t\t1\n");
    private static readonly byte[] After = Encoding.UTF8.GetBytes("PC2\t2026-10-20T11:00:00Z\tCONFIRME\talice\t2\n");

    private sealed class Setup : IDisposable
    {
        internal TemporaryFolder Folder { get; } = new();
        internal string Target => Folder.File("park.tsv");
        internal string Id { get; } = WritePlans.NewId();
        internal string Stage => Target + ".domenia-" + Id + ".tmp";
        internal string Previous => Target + ".domenia-" + Id + ".evidence\\previous.tsv";
        internal string ParentDacl { get; }
        internal string? InitialDacl { get; }
        internal SharedParkPublicationFile Publication { get; }

        internal Setup(bool existed, bool protectExisting = true, bool explicitExisting = false, bool useDefaultParent = false)
        {
            var parent = new DirectorySecurity(); parent.SetAccessRuleProtection(true, false);
            foreach (var sid in Principals())
            { parent.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow)); }
            // A real, intentionally non-private parent policy: ordinary readers inherit read permission. No machine/global ACL changes.
            parent.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.WorldSid, null), FileSystemRights.ReadAndExecute,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            if (!useDefaultParent) { new DirectoryInfo(Folder.Path).SetAccessControl(parent); }
            ParentDacl = Dacl(new DirectoryInfo(Folder.Path).GetAccessControl());
            if (existed)
            {
                File.WriteAllBytes(Target, Before);
                var file = new FileInfo(Target).GetAccessControl();
                if (explicitExisting)
                {
                    file.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinGuestsSid, null),
                        FileSystemRights.Read, AccessControlType.Allow));
                }
                if (protectExisting) { file.SetAccessRuleProtection(true, preserveInheritance: true); }
                if (protectExisting || explicitExisting) { new FileInfo(Target).SetAccessControl(file); }
                InitialDacl = Dacl(new FileInfo(Target).GetAccessControl());
            }
            Publication = new SharedParkPublicationFile(Target, Id, existed, SharedParkFile.Hash(existed ? Before : []), After, None);
        }

        public void Dispose() { Publication.Dispose(); Folder.Dispose(); }
    }

    private static SecurityIdentifier[] Principals()
    {
        using var user = WindowsIdentity.GetCurrent();
        return new[] { user.User!, new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) }.DistinctBy(s => s.Value).ToArray();
    }

    private static string Dacl(FileSystemSecurity security) => security.GetSecurityDescriptorSddlForm(AccessControlSections.Access);

    private static void PrivateFile(string path)
    {
        using var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
        var acl = held.GetAccessControl();
        var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        Check.True(acl.AreAccessRulesProtected, "DACL protégée sur le fichier lui-même");
        Check.Equal(Principals().Length, rules.Length, "exactement les identités privées distinctes");
        Check.True(Principals().Select(s => s.Value).ToHashSet().SetEquals(rules.Select(r => r.IdentityReference.Value)), "utilisateur, SYSTEM et Administrateurs uniquement");
        Check.True(rules.All(r => !r.IsInherited && r.AccessControlType == AccessControlType.Allow && r.FileSystemRights == FileSystemRights.FullControl
            && r.InheritanceFlags == InheritanceFlags.None && r.PropagationFlags == PropagationFlags.None), "aucune permission héritée du partage pendant la préparation ou la conservation");
    }

    [Test]
    public static void Prepared_bytes_are_private_on_a_parent_that_grants_read_to_everyone()
    {
        using var setup = new Setup(existed: true);
        PrivateFile(setup.Stage);
        Check.True(After.SequenceEqual(File.ReadAllBytes(setup.Stage)), "octets réellement présents dans le temporaire privé");
        Check.True(Before.SequenceEqual(File.ReadAllBytes(setup.Target)), "source non modifiée pendant la préparation");
        Check.Equal(setup.ParentDacl, Dacl(new DirectoryInfo(setup.Folder.Path).GetAccessControl()), "parent jamais reconfiguré");
        Check.False(setup.Publication.Attempted, "aucune tentative déduite de la seule création du temporaire");
    }

    [Test]
    public static void Cancelling_before_publication_keeps_the_prepared_file_private()
    {
        using var setup = new Setup(existed: true); using var cancel = new CancellationTokenSource(); cancel.Cancel();
        Check.Throws<OperationCanceledException>(() => setup.Publication.Publish(cancel.Token), "annulation avant toute tentative");
        setup.Publication.Dispose();
        PrivateFile(setup.Stage);
        Check.True(Before.SequenceEqual(File.ReadAllBytes(setup.Target)), "TSV initial inchangé");
        Check.False(setup.Publication.Attempted, "annulation prépublication distincte d’une issue incertaine");
    }

    [Test]
    public static void Replacing_an_existing_target_preserves_its_DACL_and_protects_the_displaced_inode()
    {
        using var setup = new Setup(existed: true);
        Check.True(new FileInfo(setup.Target).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>().Any(r => r.IdentityReference.Value == "S-1-1-0"), "fixture initiale réellement non privée");
        setup.Publication.Publish(None);
        Check.True(setup.Publication.Attempted, "remplacement réellement tenté");
        Check.Equal(setup.InitialDacl, Dacl(new FileInfo(setup.Target).GetAccessControl()), "droits exacts de la cible existante conservés");
        Check.True(After.SequenceEqual(File.ReadAllBytes(setup.Target)), "contenu publié relu");
        Check.True(Before.SequenceEqual(File.ReadAllBytes(setup.Previous)), "contenu déplacé inchangé");
        PrivateFile(setup.Previous);
        Check.Equal(setup.ParentDacl, Dacl(new DirectoryInfo(setup.Folder.Path).GetAccessControl()), "parent inchangé");
    }

    [Test]
    public static void Inherited_and_mixed_target_DACLs_survive_private_publication_without_losing_their_rules()
    {
        foreach (var explicitRule in new[] { false, true })
        {
            using var setup = new Setup(existed: true, protectExisting: false, explicitExisting: explicitRule);
            var before = new FileInfo(setup.Target).GetAccessControl();
            Check.False(before.AreAccessRulesProtected, "la cible de cette fixture hérite réellement du parent");
            var rules = before.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
            Check.True(rules.Any(r => r.IsInherited), "des ACE héritées sont réellement présentes");
            Check.Equal(explicitRule, rules.Any(r => !r.IsInherited), "cas hérité seul puis héritage et ACE explicite");
            PrivateFile(setup.Stage);
            try { setup.Publication.Publish(None); }
            catch
            {
                Console.WriteLine("DIAG SharedPark inherited DACL before=" + setup.InitialDacl
                    + " after=" + Dacl(new FileInfo(setup.Target).GetAccessControl()));
                throw;
            }
            Check.Equal(setup.InitialDacl, Dacl(new FileInfo(setup.Target).GetAccessControl()), "SDDL entier conservé, y compris protection et provenance des ACE");
            Check.False(new FileInfo(setup.Target).GetAccessControl().AreAccessRulesProtected, "héritage effectif toujours actif");
            Check.True(After.SequenceEqual(File.ReadAllBytes(setup.Target)), "nouveaux octets réellement publiés");
            Check.True(Before.SequenceEqual(File.ReadAllBytes(setup.Previous)), "ancien inode conservé avec ses octets");
            PrivateFile(setup.Previous);
            Check.Equal(setup.ParentDacl, Dacl(new DirectoryInfo(setup.Folder.Path).GetAccessControl()), "aucune modification du parent");
        }
    }

    [Test]
    public static void A_target_with_the_native_Windows_temporary_parent_DACL_remains_exact_after_replacement()
    {
        // Unlike the explicit-parent fixtures, retain every access rule/control flag inherited from the actual Windows Temp
        // hierarchy. This is the same starting policy used by the real Store/integration fixtures, not a normalized substitute.
        using var setup = new Setup(existed: true, protectExisting: false, useDefaultParent: true);
        PrivateFile(setup.Stage); string? owner = null; string? group = null;
        try
        {
            setup.Publication.Publish(None, immediatelyAfterRename: () =>
            {
                var security = new FileInfo(setup.Target).GetAccessControl();
                owner = security.GetOwner(typeof(SecurityIdentifier))?.Value;
                group = security.GetGroup(typeof(SecurityIdentifier))?.Value;
            });
        }
        catch
        {
            Console.WriteLine("DIAG SharedPark default parent DACL initial=" + setup.InitialDacl
                + " published=" + Dacl(new FileInfo(setup.Target).GetAccessControl()) + " parent=" + setup.ParentDacl);
            throw;
        }
        Check.Equal(setup.InitialDacl, Dacl(new FileInfo(setup.Target).GetAccessControl()), "SDDL entier du fichier Windows natif conservé");
        var final = new FileInfo(setup.Target).GetAccessControl();
        Check.NotNull(owner, "propriétaire relevé après remplacement, avant finalisation DACL");
        Check.Equal(owner, final.GetOwner(typeof(SecurityIdentifier))?.Value, "finalisation DACL sans modification du propriétaire");
        Check.Equal(group, final.GetGroup(typeof(SecurityIdentifier))?.Value, "finalisation DACL sans modification du groupe");
        Check.Equal(setup.ParentDacl, Dacl(new DirectoryInfo(setup.Folder.Path).GetAccessControl()), "parent Windows non réécrit pour adapter la fixture");
        Check.True(After.SequenceEqual(File.ReadAllBytes(setup.Target)), "octets effectivement publiés");
        Check.True(Before.SequenceEqual(File.ReadAllBytes(setup.Previous)), "ancienne version exacte conservée");
        PrivateFile(setup.Previous);
    }

    [Test]
    public static void A_changed_published_DACL_is_refused_without_repairing_its_ACEs()
    {
        foreach (var nativeParent in new[] { false, true })
        {
            using var setup = new Setup(existed: true, protectExisting: false, useDefaultParent: nativeParent); string? changed = null;
            Check.Throws<InvalidDataException>(() => setup.Publication.Publish(None, immediatelyAfterRename: () =>
            {
                var security = new FileInfo(setup.Target).GetAccessControl();
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinGuestsSid, null),
                    FileSystemRights.Read, AccessControlType.Allow));
                new FileInfo(setup.Target).SetAccessControl(security);
                changed = Dacl(new FileInfo(setup.Target).GetAccessControl());
            }), "une ACE concurrente après remplacement laisse une issue incertaine");
            Check.NotNull(changed, "la modification concurrente a réellement eu lieu après le renommage");
            Check.True(setup.Publication.Attempted, "aucun refus avant tentative inventé");
            Check.Equal(changed, Dacl(new FileInfo(setup.Target).GetAccessControl()), "l’ACL concurrente n’est pas remplacée par celle du plan");
            Check.True(After.SequenceEqual(File.ReadAllBytes(setup.Target)), "aucune compensation des octets publiés");
            PrivateFile(setup.Previous);
        }
    }

    [Test]
    public static void Legacy_conversion_recognition_requires_every_ACE_in_the_observed_order()
    {
        const string inherited = "(A;ID;FA;;;SY)(A;ID;FR;;;BA)(A;ID;FW;;;BU)";
        const string copied = "(A;;FA;;;SY)(A;;FR;;;BA)(A;;FW;;;BU)";
        var initial = new RawSecurityDescriptor("D:" + inherited);
        var observed = new RawSecurityDescriptor("D:AI" + copied + inherited);
        Check.True(SharedParkPublicationDacl.IsLegacyInheritedDuplication(initial, observed), "seule la duplication ordonnée précise est reconnue");
        Check.False(SharedParkPublicationDacl.IsExact(initial, observed), "la conversion reconnue n’est jamais un état final accepté");
        Check.True(SharedParkPublicationDacl.IsExact(initial, new RawSecurityDescriptor("D:" + inherited)), "descripteur initial exact distingué de sa conversion");
        foreach (var (label, candidate) in new[]
        {
            ("AI absent", "D:" + copied + inherited),
            ("ACE ajoutée", "D:AI" + copied + "(A;;FR;;;WD)" + inherited),
            ("ACE retirée", "D:AI(A;;FA;;;SY)(A;;FR;;;BA)" + inherited),
            ("ordre explicite changé", "D:AI(A;;FR;;;BA)(A;;FA;;;SY)(A;;FW;;;BU)" + inherited),
            ("ordre hérité changé", "D:AI" + copied + "(A;ID;FR;;;BA)(A;ID;FA;;;SY)(A;ID;FW;;;BU)"),
            ("masque explicite changé", "D:AI(A;;FR;;;SY)(A;;FR;;;BA)(A;;FW;;;BU)" + inherited),
            ("masque hérité changé", "D:AI" + copied + "(A;ID;FR;;;SY)(A;ID;FR;;;BA)(A;ID;FW;;;BU)"),
            ("SID explicite changé", "D:AI(A;;FA;;;WD)(A;;FR;;;BA)(A;;FW;;;BU)" + inherited),
            ("SID hérité changé", "D:AI" + copied + "(A;ID;FA;;;WD)(A;ID;FR;;;BA)(A;ID;FW;;;BU)"),
            ("type changé", "D:AI(D;;FA;;;SY)(A;;FR;;;BA)(A;;FW;;;BU)" + inherited),
            ("copie encore héritée", "D:AI(A;ID;FA;;;SY)(A;;FR;;;BA)(A;;FW;;;BU)" + inherited),
            ("héritage suffixe retiré", "D:AI" + copied + "(A;;FA;;;SY)(A;ID;FR;;;BA)(A;ID;FW;;;BU)")
        })
        { Check.False(SharedParkPublicationDacl.IsLegacyInheritedDuplication(initial, new RawSecurityDescriptor(candidate)), label + " refusé avant toute remise des droits"); }
        Check.False(SharedParkPublicationDacl.IsLegacyInheritedDuplication(new RawSecurityDescriptor("D:" + copied), observed), "ACL initiale explicite non assimilée à un héritage legacy");
        Check.False(SharedParkPublicationDacl.IsLegacyInheritedDuplication(new RawSecurityDescriptor("D:(D;ID;FR;;;BU)"),
            new RawSecurityDescriptor("D:AI(D;;FR;;;BU)(D;ID;FR;;;BU)")), "ACL de refus hors de la forme prouvée");
    }

    [Test]
    public static void Legacy_conversion_recognition_requires_the_exact_DACL_control_flags_and_revision()
    {
        const string before = "D:(A;ID;FA;;;SY)";
        const string after = "D:AI(A;;FA;;;SY)(A;ID;FA;;;SY)";
        foreach (var flag in new[] { ControlFlags.DiscretionaryAclProtected, ControlFlags.DiscretionaryAclAutoInheritRequired,
            ControlFlags.DiscretionaryAclAutoInherited, ControlFlags.DiscretionaryAclDefaulted,
            ControlFlags.DiscretionaryAclUntrusted, ControlFlags.ServerSecurity })
        {
            var altered = new RawSecurityDescriptor(before); altered.SetFlags(altered.ControlFlags | flag);
            Check.False(SharedParkPublicationDacl.IsLegacyInheritedDuplication(altered, new RawSecurityDescriptor(after)), "contrôle initial hors du modèle legacy refusé : " + flag);
        }
        foreach (var flag in new[] { ControlFlags.DiscretionaryAclProtected, ControlFlags.DiscretionaryAclAutoInheritRequired,
            ControlFlags.DiscretionaryAclDefaulted, ControlFlags.DiscretionaryAclUntrusted, ControlFlags.ServerSecurity })
        {
            var altered = new RawSecurityDescriptor(after); altered.SetFlags(altered.ControlFlags | flag);
            Check.False(SharedParkPublicationDacl.IsLegacyInheritedDuplication(new RawSecurityDescriptor(before), altered), "contrôle observé supplémentaire refusé : " + flag);
        }
        var revised = new RawSecurityDescriptor(after);
        var acl = revised.DiscretionaryAcl!; var bytes = new byte[acl.BinaryLength]; acl.GetBinaryForm(bytes, 0);
        bytes[0] = GenericAcl.AclRevisionDS; revised.DiscretionaryAcl = new RawAcl(bytes, 0);
        Check.False(SharedParkPublicationDacl.IsLegacyInheritedDuplication(new RawSecurityDescriptor(before), revised), "révision de RawAcl modifiée refusée même si le SDDL est identique");
        Check.False(SharedParkPublicationDacl.IsExact(new RawSecurityDescriptor(after), revised), "la relecture exacte vérifie aussi la révision de l’ACL");
        Check.False(SharedParkPublicationDacl.IsLegacyInheritedDuplication(new RawSecurityDescriptor("D:"), new RawSecurityDescriptor("D:AI")), "DACL vide hors de la forme prouvée");
    }

    [Test]
    public static void Directory_pins_block_ancestor_rename_until_disposal_and_allow_child_creation()
    {
        using var folder = new TemporaryFolder();
        var parent = folder.File("held"); var nested = System.IO.Path.Combine(parent, "nested");
        Directory.CreateDirectory(nested); var moved = folder.File("moved");
        using (var pins = new SharedParkPublicationFile.PathPins(nested, None))
        {
            File.WriteAllText(System.IO.Path.Combine(nested, "proof.txt"), "preuve");
            var refusal = Check.Throws<Exception>(() => Directory.Move(parent, moved), "le parent ne peut pas être renommé pendant sa détention");
            Check.True(refusal is IOException or UnauthorizedAccessException, "refus natif de partage ou d’accès attendu");
            Check.True(Directory.Exists(nested), "chemin qualifié toujours en place");
            Check.False(Directory.Exists(moved), "aucun alias déplacé créé");
        }
        Directory.Move(parent, moved);
        Check.Equal("preuve", File.ReadAllText(System.IO.Path.Combine(moved, "nested", "proof.txt")), "renommage possible après libération réelle des pins");
    }

    [Test]
    public static void Backup_directory_pins_block_ancestor_rename_until_the_evidence_is_closed()
    {
        using var folder = new TemporaryFolder(); var parent = folder.File("held"); Directory.CreateDirectory(parent);
        var root = System.IO.Path.Combine(parent, "backups"); SharedParkLocalPaths.CreateExclusive(root);
        var moved = folder.File("moved");
        using (var files = SharedParkBackupFiles.Open(root, folder.File("source.db"), folder.File("source.tsv"), [], [], None))
        {
            var refusal = Check.Throws<Exception>(() => Directory.Move(parent, moved), "le parent des copies privées reste fixé");
            Check.True(refusal is IOException or UnauthorizedAccessException, "refus natif de partage ou d’accès attendu");
            Check.True(Directory.Exists(root), "destination privée inchangée"); Check.False(Directory.Exists(moved), "aucune redirection du dossier détenu");
        }
        Directory.Move(parent, moved);
        Check.True(Directory.Exists(System.IO.Path.Combine(moved, "backups")), "détention réellement libérée après fermeture");
    }

    [Test]
    public static void A_new_target_inherits_the_parent_only_after_the_private_file_is_moved()
    {
        using var setup = new Setup(existed: false); var seam = false;
        setup.Publication.Publish(None, immediatelyAfterRename: () =>
        {
            seam = true; Check.True(File.Exists(setup.Target), "déplacement déjà effectué");
            PrivateFile(setup.Target); Check.False(File.Exists(setup.Stage), "plus aucun temporaire nommé");
        });
        Check.True(seam, "politique privée réellement observée après déplacement, avant héritage");
        var acl = new FileInfo(setup.Target).GetAccessControl();
        var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
        Check.False(acl.AreAccessRulesProtected, "héritage activé sur le nouveau TSV");
        Check.True(rules.Length > 0 && rules.All(r => r.IsInherited), "aucune ACE privée explicite du temporaire conservée");
        Check.True(rules.Any(r => r.IdentityReference.Value == "S-1-1-0"), "politique effective du parent héritée");
        Check.True(After.SequenceEqual(File.ReadAllBytes(setup.Target)), "publication conservée à l’identique");
        Check.Equal(setup.ParentDacl, Dacl(new DirectoryInfo(setup.Folder.Path).GetAccessControl()), "aucune modification du parent");
    }

    [Test]
    public static void Interruption_after_a_new_file_move_leaves_private_bytes_and_an_uncertain_attempt()
    {
        using var setup = new Setup(existed: false); var seam = false;
        var error = Check.Throws<IOException>(() => setup.Publication.Publish(None, immediatelyAfterRename: () =>
        { seam = true; throw new IOException("interruption après déplacement"); }), "interruption après tentative remontée au protocole Unknown");
        Check.True(seam && setup.Publication.Attempted, "frontière après déplacement effectivement atteinte");
        Check.Contains("interruption après déplacement", error.Message, "cause injectée effectivement traversée");
        PrivateFile(setup.Target);
        Check.True(After.SequenceEqual(File.ReadAllBytes(setup.Target)), "octets publiés conservés, aucun retour arrière");
    }

    [Test]
    public static void Interruption_after_replacement_still_protects_the_actual_displaced_file()
    {
        using var setup = new Setup(existed: true); var seam = false;
        Check.Throws<IOException>(() => setup.Publication.Publish(None, immediatelyAfterRename: () =>
        { seam = true; throw new IOException("interruption après remplacement"); }), "issue incertaine après tentative");
        Check.True(seam && setup.Publication.Attempted, "remplacement réellement passé");
        PrivateFile(setup.Previous);
        Check.True(Before.SequenceEqual(File.ReadAllBytes(setup.Previous)), "preuve déplacée conservée même après erreur");
        Check.Equal(setup.InitialDacl, Dacl(new FileInfo(setup.Target).GetAccessControl()), "DACL finale existante jamais remplacée par celle de la preuve");
    }

    [Test]
    public static void An_unexpected_displaced_file_is_protected_before_the_identity_mismatch_is_reported()
    {
        using var setup = new Setup(existed: true); var raced = Encoding.UTF8.GetBytes("concurrent bytes"); var seam = false;
        var error = Check.Throws<InvalidDataException>(() => setup.Publication.Publish(None, immediatelyBeforeReplace: () =>
        {
            File.Move(setup.Target, setup.Folder.File("concurrent-preserved.tsv"), overwrite: false);
            File.WriteAllBytes(setup.Target, raced); seam = true;
        }), "writer non coopératif détecté après déplacement");
        Check.True(seam && setup.Publication.Attempted, "rival réellement remplacé dans la fenêtre native");
        Check.Contains("effectivement déplacé", error.Message, "refus par identité/contenu, pas par la préparation");
        PrivateFile(setup.Previous);
        Check.True(raced.SequenceEqual(File.ReadAllBytes(setup.Previous)), "les octets inattendus sont conservés sans troncature");
    }

}
