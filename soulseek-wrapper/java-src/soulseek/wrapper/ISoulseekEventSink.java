package soulseek.wrapper;

/**
 * Java interface for the Soulseek event sink callback.
 *
 * Kotlin implements this interface and passes an instance to
 * {@link SoulseekBridge#setEventSink(Java.Lang.Object)}.
 * The C# bridge invokes {@link #onEvent(String)} via JNI to deliver
 * SoulseekEventDto JSON strings (transfer progress, state changes, etc.).
 *
 * This interface is declared in Java (not generated from the C#
 * [Register] interface) because .NET Android class libraries do not
 * generate Java interface stubs from C# interfaces — only ACWs for
 * classes extending Java.Lang.Object are generated.
 */
public interface ISoulseekEventSink
{
    /**
     * Called from the C# bridge with a JSON-serialised SoulseekEventDto.
     *
     * @param json JSON string describing the event.
     */
    void onEvent(String json);
}
