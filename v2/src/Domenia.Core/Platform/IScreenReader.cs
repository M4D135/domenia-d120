namespace Domenia.Core;

/// <summary>
/// Marker of the read interfaces of a screen (one interface per screen and per file in Domenia.Core, such as
/// <see cref="IDirectoryTreeReader"/>). Implementations live next to their source: Domenia.Simulation now, Domenia.Ad
/// later. They are found by <see cref="ScreenReaders.Discover"/>: a public, non-abstract class whose single public
/// constructor takes the directory source of the mode (or a type it derives from). Read only, by design: no write method.
/// </summary>
public interface IScreenReader
{
}
