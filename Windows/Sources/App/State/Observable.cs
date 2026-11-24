// =============================================================================
//  Observable.cs — значення, за яким стежать
// =============================================================================
//  На Mac це `@Published` + `sink`: підписник одразу отримує поточне значення,
//  далі — кожне нове. Тут сповіщення йде ПІСЛЯ зміни (на Mac — перед нею, і
//  через це там читали значення з аргументу, а не зі стану).
// =============================================================================

namespace Slovo.App;

public sealed class Observable<T>
{
    T _value;
    public event Action<T>? Changed;

    public Observable(T value) { _value = value; }

    public T Value
    {
        get => _value;
        set
        {
            if (EqualityComparer<T>.Default.Equals(_value, value)) return;
            _value = value;
            Changed?.Invoke(value);
        }
    }

    /// Підписатися: тіло отримує поточне значення одразу й кожне наступне.
    public IDisposable Sink(Action<T> body, bool now = true)
    {
        if (now) body(_value);
        Changed += body;
        return new Unsubscribe(() => Changed -= body);
    }

    /// Встановити й повідомити, навіть якщо значення те саме.
    public void Force(T value) { _value = value; Changed?.Invoke(value); }

    sealed class Unsubscribe : IDisposable
    {
        Action? _undo;
        public Unsubscribe(Action undo) { _undo = undo; }
        public void Dispose() { _undo?.Invoke(); _undo = null; }
    }
}
