namespace Domenia.Core;

public enum InitialLoginChoice { Offline, WindowsIdentity, OtherAccount }

public sealed record InitialLoginAttempt(bool Connected, string? Message = null, bool ReconcileSession = false);

/// <summary>Native startup choice only; opening it never authenticates or reads a credential vault.</summary>
public interface IInitialLoginWindow : IScreenReader
{
    Task<InitialLoginChoice> ChooseAsync(LoginAppearance appearance, string? feedback, string? rememberedLogin, CancellationToken token);
}

/// <summary>Explicit startup choices. A failed or cancelled attempt returns to the choice, never to another attempt.</summary>
public static class InitialLogin
{
    public static bool ShouldOffer(AppMode mode, LaunchOptions launch, bool capture, bool e2e)
    {
        ArgumentNullException.ThrowIfNull(launch);
        return mode == AppMode.Directory && !launch.NoAutoConnect && !capture && !e2e;
    }

    public static async Task<bool> RunAsync(
        Func<string?, CancellationToken, Task<InitialLoginChoice>> choose,
        Func<CancellationToken, Task<InitialLoginAttempt>> windows,
        Func<CancellationToken, Task<InitialLoginAttempt>> otherAccount,
        CancellationToken token,
        Func<CancellationToken, Task<bool>>? hasConnectedSession = null)
    {
        ArgumentNullException.ThrowIfNull(choose);
        ArgumentNullException.ThrowIfNull(windows);
        ArgumentNullException.ThrowIfNull(otherAccount);
        string? feedback = null;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var choice = await choose(feedback, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            if (choice == InitialLoginChoice.Offline) return false;
            var attempt = await (choice switch
            {
                InitialLoginChoice.WindowsIdentity => windows(token),
                InitialLoginChoice.OtherAccount => otherAccount(token),
                _ => throw new InvalidDataException("Choix de connexion initiale inconnu ; aucun essai envoyé."),
            }).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            if (attempt.Connected) return true;
            // Authentication can already have committed before a later local preference write fails. Never offer
            // "offline" for an authenticated source; the callback must inspect local state without any network retry.
            if (attempt.ReconcileSession && hasConnectedSession is not null && await hasConnectedSession(token).ConfigureAwait(false))
            {
                token.ThrowIfCancellationRequested();
                return true;
            }
            feedback = attempt.Message ?? "La connexion n’est pas établie. Choisissez une nouvelle tentative ou continuez hors connexion.";
        }
    }
}
