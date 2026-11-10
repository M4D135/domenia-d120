namespace Domenia.Core;

public enum AdministrationIdentityState { Unknown, Standard, Administrator }

/// <summary>Identity policy for workstation access. This never grants an AD mutation or proves permissions on a target.</summary>
public sealed record AdministrationIdentity(AdministrationIdentityState State, string Detail)
{
    public bool AllowsRemote => State == AdministrationIdentityState.Administrator;
    public static AdministrationIdentity Unknown { get; } = new(AdministrationIdentityState.Unknown,
        "Rôle d’administration non confirmé. Chaque poste accepte ou refuse les lectures avec le compte choisi ; les écritures distantes exigent une validation d’administration.");
    public const string Required = "machine.administrationRequired";
    public void EnsureRemote()
    {
        if (!AllowsRemote) { throw new DomeniaOperationException(Required, Detail); }
    }
}
