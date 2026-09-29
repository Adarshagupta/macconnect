using System.Runtime.InteropServices;

namespace MacConnectViewer.Services;

/// <summary>
/// Stops Windows from sleeping while the viewer runs. If this PC sleeps, the Mac has no display.
/// Call from the UI thread; the request belongs to the calling thread.
/// </summary>
public static class PowerRequest
{
    private const uint EsContinuous = 0x80000000;
    private const uint EsSystemRequired = 0x00000001;
    private const uint EsDisplayRequired = 0x00000002;

    [DllImport("kernel32.dll")]
    private static extern uint SetThreadExecutionState(uint flags);

    public static void Set(bool keepDisplayOn)
    {
        try
        {
            var flags = EsContinuous | EsSystemRequired;
            if (keepDisplayOn)
            {
                flags |= EsDisplayRequired;
            }

            SetThreadExecutionState(flags);
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not change the sleep setting: {ex.Message}");
        }
    }
}
