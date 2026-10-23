using System.DirectoryServices.Protocols;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Dedicated secret boundary: no managed string, JSON or general attribute API receives a password.</summary>
public interface IAdPasswordConnection
{
    Task ResetPasswordAsync(Guid objectGuid, SecureString password, bool mustChange, bool unlock, CancellationToken cancellationToken);
}

public sealed partial class AdConnection
{
    public async Task ResetPasswordAsync(Guid objectGuid, SecureString password, bool mustChange, bool unlock, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(password);
        if (objectGuid == Guid.Empty || password.Length is 0 or > AccountPasswordReset.MaxLength)
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Compte ou mot de passe non conforme ; aucune écriture envoyée."); }
        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
        var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        var control = PasswordPolicyControl(_rootDse?.SupportedControls ?? []);
        await WithPasswordRequestAsync(objectGuid, password, mustChange, unlock, control,
            (request, token) => SendRequestAsync<ModifyResponse>(connection, request, NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15)), "modify", token), cancellationToken).ConfigureAwait(false);
    }

    internal static async Task WithPasswordRequestAsync(Guid objectGuid, SecureString password, bool mustChange, bool unlock, string control,
        Func<ModifyRequest, CancellationToken, Task> send, CancellationToken cancellationToken)
    {
        var request = new ModifyRequest("<GUID=" + objectGuid.ToString("D") + ">");
        var bytes = EncodePassword(password);
        try
        {
            request.Modifications.Add(new DirectoryAttributeModification { Name = "unicodePwd", Operation = DirectoryAttributeOperation.Replace });
            request.Modifications[0].Add(bytes);
            var lastSet = new DirectoryAttributeModification { Name = "pwdLastSet", Operation = DirectoryAttributeOperation.Replace };
            lastSet.Add(mustChange ? "0" : "-1"); request.Modifications.Add(lastSet);
            if (unlock)
            {
                var clear = new DirectoryAttributeModification { Name = "lockoutTime", Operation = DirectoryAttributeOperation.Replace };
                clear.Add("0"); request.Modifications.Add(clear);
            }
            // Critical, never silently ignored. The same signed/sealed Negotiate connection sends one Modify only.
            request.Controls.Add(new DirectoryControl(control, BerConverter.Encode("{i}", 1), true, true));
            await send(request, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
            foreach (DirectoryAttributeModification change in request.Modifications)
            {
                foreach (var value in change) { if (value is byte[] copy) { CryptographicOperations.ZeroMemory(copy); } }
                change.Clear();
            }
            request.Modifications.Clear();
        }
    }

    internal static string PasswordPolicyControl(IReadOnlyList<string> supported) => supported.Contains("1.2.840.113556.1.4.2239", StringComparer.Ordinal)
        ? "1.2.840.113556.1.4.2239" : supported.Contains("1.2.840.113556.1.4.2066", StringComparer.Ordinal) ? "1.2.840.113556.1.4.2066"
        : throw new DomeniaOperationException(AdErrors.Unwilling, "Ce contrôleur ne propose pas le contrôle de stratégie nécessaire à la réinitialisation ; aucune écriture envoyée.");

    internal static byte[] EncodePassword(SecureString password) => PasswordSecrets.Inspect(password, chars =>
    {
        var bytes = new byte[checked((chars.Length + 2) * 2)];
        bytes[0] = 0x22; bytes[^2] = 0x22;
        Encoding.Unicode.GetBytes(chars, bytes.AsSpan(2, chars.Length * 2));
        return bytes;
    });
}
