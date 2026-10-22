using System.Collections.Immutable;
using System.Globalization;
using System.Text.RegularExpressions;

namespace Domenia.Core.Poste;

/// <summary>Enable or disable the computer account (Domenia 1 PST-012, PST-024: one button chosen by userAccountControl).</summary>
public interface IPosteAccountStateExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, bool enable, CancellationToken cancellationToken);
}

/// <summary>Description, location and managedBy of the computer object (Domenia 1 PST-021, Save-ComputerProfile).</summary>
public interface IPosteProfileExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, string? description, string? location, string? managedByDn, CancellationToken cancellationToken);
}

/// <summary>Rename of the computer object in the directory only (the Windows workstation is not renamed).</summary>
public interface IPosteRenameExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, string newName, CancellationToken cancellationToken);
}

/// <summary>Adds the computer to a group or removes it (member of the group, memberOf of the computer).</summary>
public interface IPosteGroupExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, string groupDn, bool add, CancellationToken cancellationToken);
}

/// <summary>Moves the computer object to another OU of the domain.</summary>
public interface IPosteMoveExecutor : IWriteExecutor
{
    Task<WritePlanDraft> PlanAsync(string dn, string targetOuDn, CancellationToken cancellationToken);
}

/// <summary>
/// Pure rules of the directory writes of the workstation screen (docs/WRITES.md § 6): drafts built from the object as read,
/// preconditions read again just before sending, the change itself (for the simulated overlay) and the postcondition. Every
/// plan targets exactly one computer; the name to type is the sAMAccountName without « $ » when the plan asks for it.
/// </summary>
public static partial class PosteDirectoryWrites
{
    public const string AccountStateKind = "poste.accountState";
    public const string ProfileKind = "poste.profile";
    public const string RenameKind = "poste.rename";
    public const string GroupKind = "poste.group";
    public const string MoveKind = "poste.move";

    public const int MaxDescription = 1024;
    public const int MaxLocation = 1024;

    [GeneratedRegex(@"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex ComputerName();

    /// <summary>The name typed to confirm a dangerous change: the computer name (sAMAccountName without « $ »).</summary>
    public static string TypedName(DirectoryComputer computer)
    {
        ArgumentNullException.ThrowIfNull(computer);
        return computer.SamAccountName.TrimEnd('$');
    }

    public static WriteTarget Target(DirectoryComputer c)
    {
        ArgumentNullException.ThrowIfNull(c);
        return new WriteTarget("computer", "Compte ordinateur", c.Name, c.DistinguishedName, c.ObjectGuid.ToString("D"), c.SamAccountName);
    }

    private static WriteConfirmation Typed(DirectoryComputer c, string reason) => new(true, TypedName(c), "Saisie du nom exigée" + FrenchText.Colon + reason);

    private static WriteConfirmation Simple(string reason) => new(false, null, "Confirmation simple" + FrenchText.Colon + reason);

    // ------------------------------------------------------------------ enable / disable

    public static WritePlanDraft AccountState(DirectoryComputer c, bool enable, string? controller)
    {
        ArgumentNullException.ThrowIfNull(c);
        var disabled = AdValues.IsDisabled(c.UserAccountControl);
        if (enable && !disabled)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Ce compte ordinateur est déjà activé : aucune écriture à préparer.");
        }
        if (!enable && disabled)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Ce compte ordinateur est déjà désactivé : aucune écriture à préparer.");
        }
        var after = enable ? c.UserAccountControl & ~AdValues.AccountDisabled : c.UserAccountControl | AdValues.AccountDisabled;
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        if (!enable)
        {
            risks.Add(new WriteRisk(Tone.Alert, "Le poste ne pourra plus s’authentifier au domaine : plus d’ouverture de session par un compte du domaine ni d’application des stratégies."));
            risks.Add(new WriteRisk(Tone.Info, "Le compte reste dans son OU ; un déplacement vers la quarantaine est une écriture distincte."));
        }
        else
        {
            risks.Add(new WriteRisk(Tone.Warn, "Vérifiez que le poste est bien de retour en service : un mot de passe machine ancien peut exiger une nouvelle jonction."));
        }
        var where = controller is null ? "" : " sur " + controller;
        return new WritePlanDraft(
            AccountStateKind,
            enable ? "Activer le compte ordinateur" : "Désactiver le compte ordinateur",
            enable ? "Activation du compte ordinateur" : "Désactivation du compte ordinateur",
            c.Name + (enable ? " pourra de nouveau s’authentifier" : " ne pourra plus s’authentifier") + FrenchText.Colon + "userAccountControl modifié" + where + ".",
            Target(c),
            [new WriteChange("userAccountControl", "État du compte", WriteChangeKind.Replace, disabled ? "Désactivé" : "Activé", enable ? "Activé" : "Désactivé",
                c.UserAccountControl.ToString(CultureInfo.InvariantCulture), after.ToString(CultureInfo.InvariantCulture))],
            risks.ToImmutable(),
            enable ? Simple("réactivation d’un compte ordinateur.") : Typed(c, "le poste perd l’accès au domaine."),
            new WriteReversibility(true, "Réversible par un nouveau plan", enable ? "Une désactivation se prépare de nouveau depuis la carte du compte." : "Une réactivation se prépare de nouveau depuis la carte du compte ; rien n’est rejoué automatiquement."),
            controller);
    }

    public static WritePrecheck CheckAccountState(WritePlan plan, DirectoryComputer? c) => CheckValue(plan, c, "userAccountControl", c?.UserAccountControl.ToString(CultureInfo.InvariantCulture));

    public static DirectoryComputer ApplyAccountState(DirectoryComputer c, WritePlan plan, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(plan);
        var value = int.Parse(plan.Changes[0].AfterValue!, CultureInfo.InvariantCulture);
        return c with { UserAccountControl = value, WhenChanged = now, UsnChanged = usn };
    }

    // ------------------------------------------------------------------ profile (description, location, managedBy)

    public static WritePlanDraft Profile(DirectoryComputer c, string? description, string? location, string? managedByDn, string? managedByName, string? controller)
    {
        ArgumentNullException.ThrowIfNull(c);
        static string? Clean(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        var desc = Clean(description);
        var loc = Clean(location);
        var manager = Clean(managedByDn);
        if (desc?.Length > MaxDescription || loc?.Length > MaxLocation)
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Description ou emplacement trop long (1 024 caractères au plus) : aucune écriture préparée.");
        }
        if ((desc ?? "").Any(char.IsControl) || (loc ?? "").Any(char.IsControl))
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Retour à la ligne ou caractère de contrôle refusé : aucune écriture préparée.");
        }
        var changes = ImmutableArray.CreateBuilder<WriteChange>();
        void Change(string attribute, string label, string? before, string? after, string? beforeShown = null, string? afterShown = null)
        {
            if (string.Equals(before ?? "", after ?? "", StringComparison.Ordinal))
            {
                return;
            }
            changes.Add(new WriteChange(attribute, label, after is null ? WriteChangeKind.Clear : WriteChangeKind.Replace, beforeShown ?? before, afterShown ?? after, before, after));
        }
        Change("description", "Description", c.Description, desc);
        Change("location", "Emplacement", c.Location, loc);
        Change("managedBy", "Géré par", c.ManagedByDn, manager, c.ManagedByDn is null ? null : DistinguishedName.Parse(c.ManagedByDn)[0].Value, managedByName ?? (manager is null ? null : DistinguishedName.Parse(manager)[0].Value));
        if (changes.Count == 0)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Aucun champ modifié : aucune écriture à préparer.");
        }
        return new WritePlanDraft(ProfileKind, "Enregistrer la fiche du poste", "Fiche du poste",
            FrenchText.Count(changes.Count, "attribut modifié", "attributs modifiés") + " sur " + c.Name + (controller is null ? "" : " (" + controller + ")") + ".",
            Target(c), changes.ToImmutable(),
            [new WriteRisk(Tone.Info, "Attributs descriptifs seulement : aucun droit ni accès n’est modifié.")],
            Simple("attributs descriptifs du compte ordinateur."),
            new WriteReversibility(true, "Réversible par un nouveau plan", "Les valeurs précédentes sont gardées dans le reçu ; les rétablir est une nouvelle écriture, jamais automatique."),
            controller);
    }

    public static WritePrecheck CheckProfile(WritePlan plan, DirectoryComputer? c)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var basic = CheckIdentity(plan, c);
        if (!basic.Current || c is null)
        {
            return basic;
        }
        foreach (var change in plan.Changes)
        {
            var current = change.Attribute switch { "description" => c.Description, "location" => c.Location, _ => c.ManagedByDn };
            if (string.Equals(current ?? "", change.AfterValue ?? "", StringComparison.Ordinal))
            {
                continue;
            }
            if (!string.Equals(current ?? "", change.BeforeValue ?? "", StringComparison.Ordinal))
            {
                return WritePrecheck.Stale(change.Label + " a changé depuis le plan" + FrenchText.Colon + "relisez la fiche puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
            }
        }
        return WritePrecheck.Valid("Fiche relue" + (plan.Controller is null ? "" : " sur " + plan.Controller) + FrenchText.Colon + "valeurs « avant » inchangées, DN et GUID inchangés.");
    }

    public static DirectoryComputer ApplyProfile(DirectoryComputer c, WritePlan plan, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(plan);
        foreach (var change in plan.Changes)
        {
            c = change.Attribute switch
            {
                "description" => c with { Description = change.AfterValue },
                "location" => c with { Location = change.AfterValue },
                _ => c with { ManagedByDn = change.AfterValue },
            };
        }
        return c with { WhenChanged = now, UsnChanged = usn };
    }

    // ------------------------------------------------------------------ rename

    public static WritePlanDraft Rename(DirectoryComputer c, string newName, IEnumerable<DirectoryComputer> all, string? controller)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(newName);
        ArgumentNullException.ThrowIfNull(all);
        var name = newName.Trim().ToUpperInvariant();
        if (!ComputerName().IsMatch(name) || name.Length > 15)
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Nom invalide : 1 à 15 caractères (NetBIOS), lettres, chiffres et tirets, sans tiret au début ni à la fin. Aucune écriture préparée.");
        }
        if (string.Equals(name, c.Name, StringComparison.OrdinalIgnoreCase))
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le poste porte déjà ce nom : aucune écriture à préparer.");
        }
        if (all.Any(o => o.ObjectGuid != c.ObjectGuid && string.Equals(o.Name, name, StringComparison.OrdinalIgnoreCase)))
        {
            throw WriteErrors.Refusal(PosteErrors.Refused, "Un autre compte ordinateur porte déjà ce nom dans le domaine : aucune écriture préparée.");
        }
        var parent = DistinguishedName.Parent(c.DistinguishedName) ?? "";
        var newDn = DistinguishedName.Child("CN", name, parent);
        return new WritePlanDraft(RenameKind, "Renommer l’objet ordinateur", "Renommage de l’objet ordinateur",
            c.Name + " devient " + name + " dans l’annuaire seulement" + FrenchText.Colon + "le nom Windows du poste n’est pas changé.",
            Target(c),
            [
                new WriteChange("cn", "Nom de l’objet", WriteChangeKind.Move, c.Name, name, c.DistinguishedName, newDn),
                new WriteChange("sAMAccountName", "Nom de compte", WriteChangeKind.Replace, c.SamAccountName, name + "$", c.SamAccountName, name + "$"),
            ],
            [
                new WriteRisk(Tone.Alert, "Le nom Windows du poste reste " + c.Name + " : tant qu’il n’est pas renommé lui aussi (Rename-Computer), le poste et son objet ne correspondent plus."),
                new WriteRisk(Tone.Warn, "Les enregistrements DNS et les références au nom (scripts, partages, inventaires) ne suivent pas."),
            ],
            Typed(c, "le nom de l’objet change."),
            new WriteReversibility(true, "Réversible par un nouveau plan", "Renommer de nouveau l’objet est une nouvelle écriture, jamais automatique."),
            controller);
    }

    public static WritePrecheck CheckRename(WritePlan plan, DirectoryComputer? c) => CheckIdentity(plan, c);

    public static DirectoryComputer ApplyRename(DirectoryComputer c, WritePlan plan, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(plan);
        var name = plan.Changes[0].After!;
        var dnsSuffix = c.DnsHostName is { } dns && dns.Contains('.', StringComparison.Ordinal) ? dns[dns.IndexOf('.', StringComparison.Ordinal)..] : "";
        return c with { Name = name, SamAccountName = name + "$", DistinguishedName = plan.Changes[0].AfterValue!, DnsHostName = c.DnsHostName is null ? null : name.ToLowerInvariant() + dnsSuffix, WhenChanged = now, UsnChanged = usn };
    }

    // ------------------------------------------------------------------ group membership

    public static WritePlanDraft Group(DirectoryComputer c, DirectoryGroup group, bool add, string? controller)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(group);
        var member = c.MemberOf.Any(g => SameDn(g, group.DistinguishedName));
        if (add && member)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le poste est déjà membre de ce groupe : aucune écriture à préparer.");
        }
        if (!add && !member)
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le poste n’est pas membre de ce groupe : aucune écriture à préparer.");
        }
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        risks.Add(new WriteRisk(Tone.Info, "Le poste prend ou perd les droits et stratégies du groupe à son prochain redémarrage (jeton Kerberos de la machine)."));
        if (group.AdminCount == 1)
        {
            risks.Add(new WriteRisk(Tone.Alert, "Groupe protégé (adminCount = 1) : vérifiez la demande par un autre canal."));
        }
        return new WritePlanDraft(GroupKind, add ? "Ajouter le poste au groupe" : "Retirer le poste du groupe", add ? "Ajout au groupe" : "Retrait du groupe",
            c.Name + (add ? " devient membre de " : " n’est plus membre de ") + group.Name + FrenchText.Colon + "attribut member du groupe" + (controller is null ? "" : " sur " + controller) + ".",
            Target(c),
            [new WriteChange("member", "Membre de " + group.Name, add ? WriteChangeKind.Add : WriteChangeKind.Remove, add ? "Non membre" : "Membre", add ? "Membre" : "Non membre", group.DistinguishedName, c.DistinguishedName)],
            risks.ToImmutable(),
            group.AdminCount == 1 ? Typed(c, "groupe protégé.") : Simple("appartenance d’un poste à un groupe."),
            new WriteReversibility(true, "Réversible par un nouveau plan", add ? "Un retrait se prépare de nouveau depuis la carte du compte." : "Un ajout se prépare de nouveau depuis la carte du compte."),
            controller);
    }

    public static WritePrecheck CheckGroup(WritePlan plan, DirectoryComputer? c, DirectoryGroup? group)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var basic = CheckIdentity(plan, c);
        if (!basic.Current || c is null)
        {
            return basic;
        }
        if (group is null)
        {
            return WritePrecheck.Stale("Le groupe n’existe plus dans l’annuaire" + FrenchText.Colon + "rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Poste et groupe relus" + (plan.Controller is null ? "" : " sur " + plan.Controller) + FrenchText.Colon + "DN et GUID inchangés.");
    }

    // ------------------------------------------------------------------ move

    public static WritePlanDraft Move(DirectoryComputer c, DirectoryOu target, string? controller)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(target);
        var parent = DistinguishedName.Parent(c.DistinguishedName) ?? "";
        if (SameDn(parent, target.DistinguishedName))
        {
            throw WriteErrors.Refusal(WriteErrors.NothingToDo, "Le poste est déjà dans cette OU : aucune écriture à préparer.");
        }
        var newDn = DistinguishedName.Child("CN", c.Name, target.DistinguishedName);
        var risks = ImmutableArray.CreateBuilder<WriteRisk>();
        risks.Add(new WriteRisk(Tone.Warn, "Les stratégies de groupe liées changent avec l’OU : le poste les applique à son prochain rafraîchissement."));
        risks.Add(new WriteRisk(Tone.Info, "Les délégations de l’OU d’arrivée s’appliquent au compte ordinateur."));
        return new WritePlanDraft(MoveKind, "Déplacer le poste", "Déplacement du poste",
            c.Name + " passe de " + DistinguishedName.Parse(parent)[0].Value + " à " + target.Name + (controller is null ? "" : " sur " + controller) + ".",
            Target(c),
            [new WriteChange("distinguishedName", "Emplacement (OU)", WriteChangeKind.Move, DistinguishedName.Parse(parent)[0].Value, target.Name, c.DistinguishedName, newDn)],
            risks.ToImmutable(),
            Typed(c, "le poste change d’OU et de stratégies."),
            new WriteReversibility(true, "Réversible par un nouveau plan", "Un retour dans l’OU d’origine est une nouvelle écriture, jamais automatique."),
            controller);
    }

    public static WritePrecheck CheckMove(WritePlan plan, DirectoryComputer? c) => CheckIdentity(plan, c);

    public static DirectoryComputer ApplyMove(DirectoryComputer c, WritePlan plan, DateTimeOffset now, long usn)
    {
        ArgumentNullException.ThrowIfNull(c);
        ArgumentNullException.ThrowIfNull(plan);
        return c with { DistinguishedName = plan.Changes[0].AfterValue!, WhenChanged = now, UsnChanged = usn };
    }

    // ------------------------------------------------------------------ shared checks

    /// <summary>Same object at the same place as in the plan (GUID and DN), or why nothing is sent.</summary>
    public static WritePrecheck CheckIdentity(WritePlan plan, DirectoryComputer? c)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (c is null)
        {
            return WritePrecheck.Stale("Le compte ordinateur n’existe plus dans l’annuaire" + FrenchText.Colon + "rien n’a été envoyé.");
        }
        if (!string.Equals(c.ObjectGuid.ToString("D"), plan.Target.ObjectGuid, StringComparison.OrdinalIgnoreCase) || !SameDn(c.DistinguishedName, plan.Target.Dn))
        {
            return WritePrecheck.Stale("Le poste a été déplacé ou renommé depuis le plan" + FrenchText.Colon + "relisez-le puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        return WritePrecheck.Valid("Compte ordinateur relu" + (plan.Controller is null ? "" : " sur " + plan.Controller) + FrenchText.Colon + "DN et GUID inchangés.");
    }

    private static WritePrecheck CheckValue(WritePlan plan, DirectoryComputer? c, string attribute, string? current)
    {
        var basic = CheckIdentity(plan, c);
        if (!basic.Current)
        {
            return basic;
        }
        var change = plan.Changes.First(ch => ch.Attribute == attribute);
        if (string.Equals(current, change.AfterValue, StringComparison.Ordinal))
        {
            return WritePrecheck.Valid("Compte relu" + FrenchText.Colon + "déjà dans l’état demandé, rien ne sera écrit.");
        }
        if (!string.Equals(current, change.BeforeValue, StringComparison.Ordinal))
        {
            return WritePrecheck.Stale(change.Label + " a changé depuis le plan" + FrenchText.Colon + "relisez le poste puis préparez de nouveau l’écriture. Rien n’a été envoyé.");
        }
        return basic;
    }

    /// <summary>Postcondition of a directory write: the attributes of the plan read back with their « after » values.</summary>
    public static WriteVerification Verify(WritePlan plan, DirectoryComputer? c, DirectoryGroup? group)
    {
        ArgumentNullException.ThrowIfNull(plan);
        var where = plan.Controller is null ? "" : " sur " + plan.Controller;
        if (c is null)
        {
            return new WriteVerification(VerificationState.Unknown, "Compte ordinateur introuvable à la relecture" + FrenchText.Colon + "vérifiez-le dans l’annuaire.");
        }
        var ok = plan.Kind switch
        {
            AccountStateKind => string.Equals(c.UserAccountControl.ToString(CultureInfo.InvariantCulture), plan.Changes[0].AfterValue, StringComparison.Ordinal),
            ProfileKind => plan.Changes.All(ch => string.Equals((ch.Attribute switch { "description" => c.Description, "location" => c.Location, _ => c.ManagedByDn }) ?? "", ch.AfterValue ?? "", StringComparison.Ordinal)),
            RenameKind => string.Equals(c.Name, plan.Changes[0].After, StringComparison.OrdinalIgnoreCase),
            MoveKind => SameDn(c.DistinguishedName, plan.Changes[0].AfterValue ?? ""),
            GroupKind => group is not null && (plan.Changes[0].Kind == WriteChangeKind.Add) == group.Members.Any(m => SameDn(m, c.DistinguishedName)),
            _ => false,
        };
        return ok
            ? new WriteVerification(VerificationState.Verified, "Valeurs relues" + where + FrenchText.Colon + "conformes au plan.")
            : new WriteVerification(VerificationState.Mismatch, "Écart à la relecture" + where + FrenchText.Colon + "l’annuaire ne montre pas la valeur attendue (réplication en cours ou écriture concurrente).");
    }

    public static bool SameDn(string left, string right)
    {
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
