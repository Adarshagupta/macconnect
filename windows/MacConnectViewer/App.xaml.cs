using System.Windows;
using MacConnectViewer.Services;
using Forms = System.Windows.Forms;

namespace MacConnectViewer;

public partial class App : System.Windows.Application
{
    private Mutex? _instance;
    private BeaconService? _beacon;
    private SessionService? _session;
    private Forms.NotifyIcon? _tray;
    private MainWindow? _window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _instance = new Mutex(true, "Local\\MacConnectViewer", out var created);
        if (!created)
        {
            ViewerLog.Write("MacConnect Viewer is already running");
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            ViewerLog.Write($"UI error: {args.Exception}");
            args.Handled = true;
        };

        var allowList = new AllowListStore();
        _window = new MainWindow();
        MainWindow = _window;
        _session = new SessionService(allowList, macName => _window.Dispatcher.Invoke(() => _window.AskApproval(macName)));
        _window.Attach(_session);
        CreateTray();
        _window.EnterFullScreen();
        _window.Show();

        _session.Start();
        _beacon = new BeaconService(Protocol.Wire.TcpPort, Environment.MachineName);
        _beacon.Start();
        ViewerLog.Write("MacConnect Viewer started");
    }

    public void ExitApp()
    {
        _tray?.Dispose();
        _tray = null;
        _beacon?.Dispose();
        _session?.Dispose();
        _window?.ForceClose();
        Shutdown();
        _instance?.ReleaseMutex();
        _instance?.Dispose();
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
