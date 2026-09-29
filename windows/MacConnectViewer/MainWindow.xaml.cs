using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
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
    private readonly object _frameLock = new();
    private byte[]? _pendingFrame;
    private bool _decoding;
    private BitmapSource? _readyImage;
    private byte[]? _readyPixels;
    private int _readyWidth;
    private int _readyHeight;
    private WriteableBitmap? _frameBitmap;
    private H264Decoder? _h264;
    private bool _presentQueued;
    private bool _showing;
    private float _cursorX;
    private float _cursorY;
    private bool _cursorQueued;
    private bool _cursorSeen;
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
    private readonly HashSet<ushort> _keysDown = new();
    private DateTime _lastMoveUtc = DateTime.MinValue;

    public event Action<string>? StatusChanged;

    public MainWindow()
    {
        InitializeComponent();
        AddressText.Text = NetworkInfo.Describe();
        PreviewKeyDown += OnPreviewKeyDown;
        PreviewKeyUp += OnPreviewKeyUp;
        Deactivated += (_, _) => ReleaseAllInput();
        SizeChanged += (_, _) => UpdateCursor();
    }

    public void Attach(SessionService session)
    {
        _session = session;
        session.MacAccepted += OnMacAccepted;
        session.FrameReceived += OnFrameReceived;
        session.CursorReceived += OnCursorReceived;
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
            _showing = true;
            PowerRequest.Set(keepDisplayOn: true);
            StatusChanged?.Invoke($"MacConnect — {name}");
            Show();
            if (!_userShrunk)
            {
                EnterFullScreen();
            }

            Activate();
        });
    }

    /// Called for every picture from the Mac, on the network thread. Only the newest waiting picture is
    /// kept, and it is decoded on a background thread so the window never waits on decoding.
    private void OnFrameReceived(byte[] frame)
    {
        lock (_frameLock)
        {
            _pendingFrame = frame;
            if (_decoding)
            {
                return;
            }

            _decoding = true;
        }

        _ = Task.Run(DecodeLoop);
    }

    private void DecodeLoop()
    {
        while (true)
        {
            byte[]? frame;
            lock (_frameLock)
            {
                frame = _pendingFrame;
                _pendingFrame = null;
                if (frame is null)
                {
                    _decoding = false;
                    return;
                }
            }

            BitmapSource? image = null;
            byte[]? pixels = null;
            var width = 0;
            var height = 0;
            if (frame.Length >= 2 && frame[0] == 0xFF && frame[1] == 0xD8)
            {
                image = DecodeJpeg(frame);
            }
            else if (DecodeH264(frame, out pixels, out width, out height))
            {
                // Pixels are presented on the window thread.
            }
            else
            {
                continue;
            }

            bool queue;
            lock (_frameLock)
            {
                _readyImage = image;
                _readyPixels = pixels;
                _readyWidth = width;
                _readyHeight = height;
                queue = !_presentQueued;
                _presentQueued = true;
            }

            if (queue)
            {
                Dispatcher.BeginInvoke(DispatcherPriority.Render, new Action(Present));
            }
        }
    }

    private bool DecodeH264(byte[] frame, out byte[]? pixels, out int width, out int height)
    {
        pixels = null;
        width = 0;
        height = 0;
        _h264 ??= new H264Decoder(_frameWidth, _frameHeight);
        if (!_h264.TryDecode(frame, out var bgra, out width, out height))
        {
            return false;
        }

        pixels = bgra;
        return true;
    }

    private static BitmapImage? DecodeJpeg(byte[] jpeg)
    {
        if (jpeg.Length == 0)
        {
            return null;
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
            return image;
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not decode a frame: {ex.Message}");
            return null;
        }
    }

    /// Runs on the window thread: shows the newest decoded picture and skips any older one.
    private void Present()
    {
        BitmapSource? image;
        byte[]? pixels;
        int width;
        int height;
        lock (_frameLock)
        {
            image = _readyImage;
            pixels = _readyPixels;
            width = _readyWidth;
            height = _readyHeight;
            _readyImage = null;
            _readyPixels = null;
            _presentQueued = false;
        }

        if (!_showing)
        {
            return;
        }

        if (pixels is not null && width > 0 && height > 0)
        {
            if (_frameBitmap is null || _frameBitmap.PixelWidth != width || _frameBitmap.PixelHeight != height)
            {
                _frameBitmap = new WriteableBitmap(width, height, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null);
                FrameImage.Source = _frameBitmap;
            }

            _frameBitmap.WritePixels(new Int32Rect(0, 0, width, height), pixels, width * 4, 0);
            WaitingPanel.Visibility = Visibility.Collapsed;
            return;
        }

        if (image is null)
        {
            return;
        }

        FrameImage.Source = image;
        WaitingPanel.Visibility = Visibility.Collapsed;
    }

    private void OnDisconnected()
    {
        Dispatcher.BeginInvoke(() =>
        {
            _showing = false;
            _h264?.Dispose();
            _h264 = null;
            _frameBitmap = null;
            _cursorSeen = false;
            MacCursor.Visibility = Visibility.Collapsed;
            FrameImage.Cursor = null;
            FrameImage.Source = null;
            AddressText.Text = NetworkInfo.Describe();
            WaitingPanel.Visibility = Visibility.Visible;
            _keysDown.Clear();
            _leftDown = false;
            _rightDown = false;
            _middleDown = false;
            FrameImage.ReleaseMouseCapture();
            PowerRequest.Set(keepDisplayOn: false);
            StatusChanged?.Invoke("MacConnect — waiting for Mac");
        });
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
        if (virtualKey == 0)
        {
            return;
        }

        _keysDown.Add(virtualKey);
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

        // Only release keys the Mac saw go down. Esc that shrank the window never reached the Mac.
        if (_keysDown.Remove(virtualKey))
        {
            _ = _session.SendKeyAsync(virtualKey, down: false);
            e.Handled = IsFullScreen;
        }
    }

    private void ReleaseAllInput()
    {
        if (_session is not null)
        {
            foreach (var virtualKey in _keysDown)
            {
                _ = _session.SendKeyAsync(virtualKey, down: false);
            }
        }

        _keysDown.Clear();
        ReleaseButtons();
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_session is null || !_session.IsConnected)
        {
            return;
        }

        if (DateTime.UtcNow - _lastMoveUtc < TimeSpan.FromMilliseconds(8))
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

    /// Where the Mac picture sits inside the window (the picture keeps its shape, so there can be bars).
    private bool TryGetContentRect(out double contentX, out double contentY, out double contentWidth, out double contentHeight)
    {
        contentX = 0;
        contentY = 0;
        contentWidth = 0;
        contentHeight = 0;
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

        return true;
    }

    /// Called on the network thread for every Mac pointer position. Only the newest one is drawn.
    private void OnCursorReceived(float x, float y)
    {
        bool queue;
        lock (_frameLock)
        {
            _cursorX = x;
            _cursorY = y;
            queue = !_cursorQueued;
            _cursorQueued = true;
        }

        if (queue)
        {
            Dispatcher.BeginInvoke(DispatcherPriority.Send, new Action(UpdateCursor));
        }
    }

    private void UpdateCursor()
    {
        float x;
        float y;
        lock (_frameLock)
        {
            x = _cursorX;
            y = _cursorY;
            _cursorQueued = false;
        }

        if (!_showing || !TryGetContentRect(out var contentX, out var contentY, out var contentWidth, out var contentHeight))
        {
            return;
        }

        if (!_cursorSeen)
        {
            // From now on the Mac pointer is the one you follow, so the Windows pointer is hidden over the picture.
            // Older Mac agents never send a position, so in that case the Windows pointer stays visible.
            _cursorSeen = true;
            FrameImage.Cursor = System.Windows.Input.Cursors.None;
            MacCursor.Visibility = Visibility.Visible;
        }

        System.Windows.Controls.Canvas.SetLeft(MacCursor, contentX + Math.Clamp(x, 0f, 1f) * contentWidth);
        System.Windows.Controls.Canvas.SetTop(MacCursor, contentY + Math.Clamp(y, 0f, 1f) * contentHeight);
    }

    private bool TryNormalize(Point position, out float x, out float y)
    {
        x = 0;
        y = 0;
        if (!TryGetContentRect(out var contentX, out var contentY, out var contentWidth, out var contentHeight))
        {
            return false;
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
