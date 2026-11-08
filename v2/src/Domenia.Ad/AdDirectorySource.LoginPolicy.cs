using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdDirectorySource : IWindowsSessionChoiceSource
{
    public WindowsSessionChoice WindowsSessionChoice => Domenia.Core.WindowsSessionChoice.Read(
        AuthenticationPolicy.Read(AccountContext?.Configuration).AllowWindowsSession, false, joinedDomain, accountLogin(), Environment.MachineName);
}
