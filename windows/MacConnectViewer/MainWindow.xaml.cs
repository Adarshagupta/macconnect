using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using MouseButton = System.Windows.Input.MouseButton;
using MouseButtonEventArgs = System.Windows.Input.MouseButtonEventArgs;
using MouseEventArgs = System.Windows.Input.MouseEventArgs;
using MouseWheelEventArgs = System.Windows.Input.MouseWheelEventArgs;
using MessageBox = System.Windows.MessageBox;
using Point = System.Windows.Point;
using MacConnectViewer.Protocol;
using MacConnectViewer.Services;

namespace MacConnectViewer;

public partial class MainWindow : Window
{
    private SessionService? _session;
    private byte[]? _pendingFrame;
    private bool _renderQueued;
    private int _frameWidth;
    private int _frameHeight;
    private bool _userShrunk;
    private bool _forceClose;
    private bool _leftDown;
    private bool _rightDown;
    private bool _middleDown;
    private float _lastX;
    private float _lastY;
    private bool _hasPoint;
    private DateTime _lastMoveUtc = DateTime.MinValue;

    public event Action<string>? StatusChanged;

    public MainWindow()
    {
        InitializeComponent();
        PreviewKeyDown += OnPreviewKeyDown;
        PreviewKeyUp += OnPreviewKeyUp;
    }

    public void Attach(SessionService session)
    {
        _session = session;
        session.MacAccepted += OnMacAccepted;
        session.FrameReceived += OnFrameReceived;
        session.Disconnected += OnDisconnected;
    }

    public bool AskApproval(string macName)
    {
        var wasTopmost = Topmost;
        Topmost = false;
        var answer = MessageBox.Show(
            this,
            $"Allow {macName} to use this PC as its display?\n\nAfter you allow it, this Mac connects automatically.",
            "MacConnect",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);
        if (wasTopmost && IsFullScreen)
        {
            Topmost = true;
        }

        return answer == MessageBoxResult.Yes;
    }

    public void EnterFullScreenFromUser()
    {
        _userShrunk = false;
        Show();
        EnterFullScreen();
        Activate();
    }

    public void EnterFullScreen()
    {
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        WindowState = WindowState.Maximized;
        Topmost = true;
    }

    public void ForceClose()
    {
        _forceClose = true;
        Close();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_forceClose)
        {
            base.OnClosing(e);
            return;
        }

        e.Cancel = true;
        LeaveFullScreen();
        Hide();
    }

    private void OnMacAccepted(string name, int width, int height)
    {
        Dispatcher.Invoke(() =>
        {
            _frameWidth = width;
            _frameHeight = height;
            StatusChanged?.Invoke($"MacConnect — {name}");
            Show();
            if (!_userShrunk)
            {
                EnterFullScreen();
            }

            Activate();
        });
    }

    private void OnFrameReceived(byte[] jpeg)
    {
        lock (this)
        {
            _pendingFrame = jpeg;
            if (_renderQueued)
            {
                return;
            }

            _renderQueued = true;
        }

        Dispatcher.BeginInvoke(RenderPendingFrame);
    }

    private void OnDisconnected()
    {
        Dispatcher.BeginInvoke(() =>
        {
            FrameImage.Source = null;
            WaitingPanel.Visibility = Visibility.Visible;
            ReleaseButtons();
            StatusChanged?.Invoke("MacConnect — waiting for Mac");
        });
    }

    private void RenderPendingFrame()
    {
        byte[]? jpeg;
        lock (this)
        {
            jpeg = _pendingFrame;
            _pendingFrame = null;
            _renderQueued = false;
        }

        if (jpeg is null || jpeg.Length == 0)
        {
            return;
        }

        try
        {
            using var stream = new MemoryStream(jpeg, writable: false);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            FrameImage.Source = image;
            WaitingPanel.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not show a frame: {ex.Message}");
        }
    }

    private void LeaveFullScreen()
    {
        _userShrunk = true;
        Topmost = false;
        WindowStyle = WindowStyle.SingleBorderWindow;
        ResizeMode = ResizeMode.CanResize;
        WindowState = WindowState.Normal;
        Width = 1280;
        Height = 800;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && !e.IsRepeat && IsFullScreen)
        {
            LeaveFullScreen();
            e.Handled = true;
            return;
        }

        if (_session is null || !_session.IsConnected || !IsActive)
        {
            return;
        }

        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var virtualKey = (ushort)KeyInterop.VirtualKeyFromKey(key);
        _ = _session.SendKeyAsync(virtualKey, down: true);
        e.Handled = IsFullScreen;
    }

    private void OnPreviewKeyUp(object sender, KeyEventArgs e)
    {
        if (_session is null || !_session.IsConnected || !IsActive)
        {
            return;
        }

        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var virtualKey = (ushort)KeyInterop.VirtualKeyFromKey(key);
        _ = _session.SendKeyAsync(virtualKey, down: false);
        e.Handled = IsFullScreen;
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_session is null || !_session.IsConnected)
        {
            return;
        }

        if (DateTime.UtcNow - _lastMoveUtc < TimeSpan.FromMilliseconds(16))
        {
            return;
        }

        if (!TryNormalize(e.GetPosition(FrameImage), out var x, out var y))
        {
            return;
        }

        _lastMoveUtc = DateTime.UtcNow;
        Remember(x, y);
        var button = _leftDown ? Wire.ButtonLeft : _rightDown ? Wire.ButtonRight : _middleDown ? Wire.ButtonMiddle : Wire.ButtonNone;
        _ = _session.SendMouseAsync(Wire.MouseMove, button, x, y, 0);
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        FrameImage.Focus();
        FrameImage.CaptureMouse();
        if (!TryNormalize(e.GetPosition(FrameImage), out var x, out var y))
        {
            return;
        }

        SetButton(e.ChangedButton, down: true);
        Remember(x, y);
        _ = _session?.SendMouseAsync(Wire.MouseDown, ButtonCode(e.ChangedButton), x, y, 0);
        e.Handled = true;
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        var hasPoint = TryNormalize(e.GetPosition(FrameImage), out var x, out var y);
        SetButton(e.ChangedButton, down: false);
        if (!_leftDown && !_rightDown && !_middleDown)
        {
            FrameImage.ReleaseMouseCapture();
        }

        if (!hasPoint && _hasPoint)
        {
            x = _lastX;
            y = _lastY;
            hasPoint = true;
        }

        if (hasPoint)
        {
            Remember(x, y);
            _ = _session?.SendMouseAsync(Wire.MouseUp, ButtonCode(e.ChangedButton), x, y, 0);
        }

        e.Handled = true;
    }

    private void OnMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (!TryNormalize(e.GetPosition(FrameImage), out var x, out var y))
        {
            return;
        }

        _ = _session?.SendMouseAsync(Wire.MouseScroll, Wire.ButtonNone, x, y, (short)e.Delta);
        e.Handled = true;
    }

    private void OnMouseLeave(object sender, MouseEventArgs e)
    {
        ReleaseButtons();
    }

    private void ReleaseButtons()
    {
        if (_session is null)
        {
            return;
        }

        var x = _hasPoint ? _lastX : 0.5f;
        var y = _hasPoint ? _lastY : 0.5f;
        if (_leftDown)
        {
            _ = _session.SendMouseAsync(Wire.MouseUp, Wire.ButtonLeft, x, y, 0);
        }

        if (_rightDown)
        {
            _ = _session.SendMouseAsync(Wire.MouseUp, Wire.ButtonRight, x, y, 0);
        }

        if (_middleDown)
        {
            _ = _session.SendMouseAsync(Wire.MouseUp, Wire.ButtonMiddle, x, y, 0);
        }

        _leftDown = false;
        _rightDown = false;
        _middleDown = false;
        FrameImage.ReleaseMouseCapture();
    }

    private void SetButton(MouseButton button, bool down)
    {
        switch (button)
        {
            case MouseButton.Left:
                _leftDown = down;
                break;
            case MouseButton.Right:
                _rightDown = down;
                break;
            case MouseButton.Middle:
                _middleDown = down;
                break;
        }
    }

    private static byte ButtonCode(MouseButton button) => button switch
    {
        MouseButton.Left => Wire.ButtonLeft,
        MouseButton.Right => Wire.ButtonRight,
        MouseButton.Middle => Wire.ButtonMiddle,
        _ => Wire.ButtonNone,
    };

    private bool TryNormalize(Point position, out float x, out float y)
    {
        x = 0;
        y = 0;
        if (_frameWidth <= 0 || _frameHeight <= 0)
        {
            return false;
        }

        var controlWidth = FrameImage.ActualWidth;
        var controlHeight = FrameImage.ActualHeight;
        if (controlWidth <= 1 || controlHeight <= 1)
        {
            return false;
        }

        var imageAspect = _frameWidth / (double)_frameHeight;
        var controlAspect = controlWidth / controlHeight;
        double contentX;
        double contentY;
        double contentWidth;
        double contentHeight;
        if (controlAspect > imageAspect)
        {
            contentHeight = controlHeight;
            contentWidth = controlHeight * imageAspect;
            contentX = (controlWidth - contentWidth) / 2;
            contentY = 0;
        }
        else
        {
            contentWidth = controlWidth;
            contentHeight = controlWidth / imageAspect;
            contentX = 0;
            contentY = (controlHeight - contentHeight) / 2;
        }

        if (position.X < contentX || position.Y < contentY ||
            position.X > contentX + contentWidth || position.Y > contentY + contentHeight)
        {
            return false;
        }

        x = (float)((position.X - contentX) / contentWidth);
        y = (float)((position.Y - contentY) / contentHeight);
        return true;
    }

    private void Remember(float x, float y)
    {
        _lastX = x;
        _lastY = y;
        _hasPoint = true;
    }

    private bool IsFullScreen =>
        WindowStyle == WindowStyle.None && WindowState == WindowState.Maximized;
}
