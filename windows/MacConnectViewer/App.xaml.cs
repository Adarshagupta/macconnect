using System.Diagnostics;
using System.Windows;
using MacConnectViewer.Services;
using Forms = System.Windows.Forms;

namespace MacConnectViewer;

public partial class App : System.Windows.Application
{
    private const string RestartedFlag = "--restarted";
    private static long _startedTicks;
    private static bool _wasRestarted;

    private Mutex? _instance;
    private BeaconService? _beacon;
    private SessionService? _session;
    private Forms.NotifyIcon? _tray;
    private MainWindow? _window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _startedTicks = Environment.TickCount64;
        _wasRestarted = e.Args.Contains(RestartedFlag);

        if (!AcquireSingleInstance())
        {
            ViewerLog.Write("MacConnect Viewer is already running");
            Shutdown();
            return;
        }

        RegisterCrashHandlers();

        var allowList = new AllowListStore();
        _window = new MainWindow();
        MainWindow = _window;
        _session = new SessionService(allowList, macName => _window.Dispatcher.Invoke(() => _window.AskApproval(macName)));
        _window.Attach(_session);
        CreateTray();
        PowerRequest.Set(keepDisplayOn: false);
        _window.EnterFullScreen();
        _window.Show();

        _session.Start();
        _beacon = new BeaconService(Protocol.Wire.TcpPort, Environment.MachineName);
        _beacon.Start();
        ViewerLog.Write(_wasRestarted ? "MacConnect Viewer restarted after a crash" : "MacConnect Viewer started");
    }

    public void ExitApp()
    {
        _tray?.Dispose();
        _tray = null;
        _beacon?.Dispose();
        _session?.Dispose();
        _window?.ForceClose();
        Shutdown();
        try
        {
            _instance?.ReleaseMutex();
        }
        catch
        {
            // Released by another thread or already gone.
        }

        _instance?.Dispose();
    }

    private bool AcquireSingleInstance()
    {
        _instance = new Mutex(false, "Local\\MacConnectViewer");
        try
        {
            // After a crash the old process may need a moment to exit.
            return _instance.WaitOne(_wasRestarted ? 15000 : 0);
        }
        catch (AbandonedMutexException)
        {
            // The previous copy died without releasing it. We own it now.
            return true;
        }
    }

    private void RegisterCrashHandlers()
    {
        DispatcherUnhandledException += (_, args) =>
        {
            ViewerLog.Write($"UI error: {args.Exception}");
            args.Handled = true;
        };

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            ViewerLog.Write($"Background error: {args.Exception}");
            args.SetObserved();
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            ViewerLog.Write($"Fatal error: {args.ExceptionObject}");
            RestartAfterCrash();
        };
    }

    private static void RestartAfterCrash()
    {
        try
        {
            // If a restarted copy dies within 30 seconds, stop here instead of looping forever.
            if (_wasRestarted && Environment.TickCount64 - _startedTicks < 30_000)
            {
                ViewerLog.Write("Crashed again right after a restart; not restarting");
                return;
            }

            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe))
            {
                return;
            }

            Process.Start(new ProcessStartInfo(exe, RestartedFlag) { UseShellExecute = false });
            ViewerLog.Write("Restarting MacConnect Viewer");
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not restart: {ex.Message}");
        }
    }

    private static void ShowAddress()
    {
        var addresses = NetworkInfo.LocalAddresses();
        if (addresses.Count == 0)
        {
            System.Windows.MessageBox.Show("This PC is not connected to a network.", "MacConnect");
            return;
        }

        try
        {
            System.Windows.Clipboard.SetText(addresses[0]);
        }
        catch
        {
            // The clipboard can be busy; the address is still shown below.
        }

        System.Windows.MessageBox.Show(
            $"This PC's address: {string.Join(", ", addresses)}\n\n" +
            $"{addresses[0]} was copied. On the Mac, run:\n" +
            $"bash scripts/set-windows-ip.sh {addresses[0]}",
            "MacConnect");
    }

    private void CreateTray()
    {
        _tray = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Visible = true,
            Text = "MacConnect — waiting for Mac",
        };

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Full screen", null, (_, _) => _window?.Dispatcher.Invoke(() => _window.EnterFullScreenFromUser()));
        menu.Items.Add("Show this PC's address", null, (_, _) => _window?.Dispatcher.Invoke(ShowAddress));
        menu.Items.Add("Exit", null, (_, _) => _window?.Dispatcher.Invoke(ExitApp));
        _tray.ContextMenuStrip = menu;
        _tray.DoubleClick += (_, _) => _window?.Dispatcher.Invoke(() => _window.EnterFullScreenFromUser());

        if (_window is not null)
        {
            _window.StatusChanged += status =>
            {
                if (_tray is not null)
                {
                    _tray.Text = status.Length > 63 ? status[..63] : status;
                }
            };
        }
    }
}
