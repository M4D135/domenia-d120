namespace Domenia.Core;

/// <summary>Lets a real source obtain the shared operation accounts after composition; attaching never reads the network.</summary>
public interface IAccountContextSource
{
    void BindAccountContext(EngineContext context);
}
