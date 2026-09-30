using System.Net;
using System.Net.Sockets;
using MacConnectViewer.Protocol;

namespace MacConnectViewer.Services;

/// <summary>
/// Accepts the Mac's TCP connection. Every connection has its own state, so a stale or half-open
/// connection can never block the Mac from reconnecting: the newest accepted connection wins.
/// </summary>
public sealed class SessionService : IDisposable
{
    private const int PreHelloIdleLimitMs = 20_000;
    private const int IdleLimitMs = 6_000;
    private const int DenyMemoryMs = 60_000;

    private readonly AllowListStore _allowList;
    private readonly Func<string, bool> _approveMac;
    private readonly int _port;
    private readonly CancellationTokenSource _cts = new();
    private readonly SemaphoreSlim _approvalLock = new(1, 1);
    private readonly object _gate = new();
    private readonly Dictionary<string, long> _deniedUntil = new(StringComparer.OrdinalIgnoreCase);
    private TcpListener? _listener;
    private Connection? _current;
    private Connection? _active;
    private int _framesLogged;

    public SessionService(AllowListStore allowList, Func<string, bool> approveMac, int port = Wire.TcpPort)
    {
        _allowList = allowList;
        _approveMac = approveMac;
        _port = port;
    }

    public bool IsConnected => _active is not null;

    public event Action<string, int, int>? MacAccepted;
    public event Action<byte[]>? FrameReceived;
    public event Action<float, float>? CursorReceived;
    public event Action? Disconnected;

    public void Start()
    {
        _ = Task.Run(() => ListenAsync(_cts.Token));
    }

    public Task SendMouseAsync(byte action, byte button, float x, float y, short wheelDelta)
    {
        var connection = _active;
        return connection is null
            ? Task.CompletedTask
            : connection.SendAsync(Wire.Mouse, Wire.BuildMouse(action, button, x, y, wheelDelta));
    }

    public Task SendKeyAsync(ushort virtualKey, bool down)
    {
        var connection = _active;
        if (connection is null || virtualKey == 0)
        {
            return Task.CompletedTask;
        }

        return connection.SendAsync(Wire.Key, Wire.BuildKey(virtualKey, down));
    }

    public void Dispose()
    {
        _cts.Cancel();
        Connection? current;
        Connection? active;
        lock (_gate)
        {
            current = _current;
            active = _active;
        }

        current?.Close();
        active?.Close();
        try
        {
            _listener?.Stop();
        }
        catch
        {
            // The listener may already be stopped.
        }
    }

    private async Task ListenAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpListener listener;
            try
            {
                listener = new TcpListener(IPAddress.Any, _port);
                listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                listener.Start(8);
                _listener = listener;
                ViewerLog.Write($"Listening for the Mac on TCP {_port}");
            }
            catch (Exception ex)
            {
                ViewerLog.Write($"Could not listen on TCP {_port}: {ex.Message}");
                if (!await DelayAsync(2000, token))
                {
                    return;
                }

                continue;
            }

            while (!token.IsCancellationRequested)
            {
                TcpClient client;
                try
                {
                    client = await listener.AcceptTcpClientAsync(token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception ex)
                {
                    ViewerLog.Write($"Accept failed, restarting the listener: {ex.Message}");
                    break;
                }

                ConfigureSocket(client);
                var connection = new Connection(client, token);
                Connection? stale = null;
                lock (_gate)
                {
                    // A connection that never finished the handshake is dropped. An accepted one keeps
                    // running until its replacement is accepted, so a stranger cannot cut the picture.
                    if (_current is not null && !ReferenceEquals(_current, _active))
                    {
                        stale = _current;
                    }

                    _current = connection;
                }

                stale?.Close();
                ViewerLog.Write($"Mac connected from {connection.Remote}");
                _ = Task.Run(() => HandleAsync(connection));
            }

            try
            {
                listener.Stop();
            }
            catch
            {
                // Already stopped.
            }

            if (!await DelayAsync(1000, token))
            {
                return;
            }
        }
    }

    private async Task HandleAsync(Connection connection)
    {
        _ = KeepAliveAsync(connection);
        try
        {
            var hello = await ReadHelloAsync(connection).ConfigureAwait(false);
            if (hello is null)
            {
                return;
            }

            var (name, width, height) = hello.Value;
            connection.HelloSeen = true;
            connection.Touch();
            ViewerLog.Write($"Hello from {name} ({width}x{height})");

            if (!await AuthorizeAsync(connection, name).ConfigureAwait(false))
            {
                return;
            }

            Connection? previous;
            lock (_gate)
            {
                if (connection.Token.IsCancellationRequested || !ReferenceEquals(_current, connection))
                {
                    ViewerLog.Write($"Connection from {name} was replaced before it started");
                    return;
                }

                previous = _active;
                _active = connection;
            }

            await connection.SendAsync(Wire.Accept, []).ConfigureAwait(false);
            connection.Touch();
            previous?.Close();
            ViewerLog.Write($"{name} is connected");
            MacAccepted?.Invoke(name, width, height);

            while (!connection.Token.IsCancellationRequested)
            {
                var message = await Wire.ReadMessageAsync(connection.Stream, connection.Token).ConfigureAwait(false);
                if (message is null)
                {
                    ViewerLog.Write("The Mac closed the connection");
                    return;
                }

                connection.Touch();
                switch (message.Value.Type)
                {
                    case Wire.Frame:
                        if (ReferenceEquals(_active, connection))
                        {
                            if (_framesLogged < 3)
                            {
                                _framesLogged++;
                                ViewerLog.Write($"Mac picture {_framesLogged}: {message.Value.Payload.Length} bytes");
                            }

                            FrameReceived?.Invoke(message.Value.Payload);
                        }

                        break;
                    case Wire.Cursor:
                        if (ReferenceEquals(_active, connection) && Wire.TryParseCursor(message.Value.Payload, out var cursorX, out var cursorY))
                        {
                            CursorReceived?.Invoke(cursorX, cursorY);
                        }

                        break;
                    case Wire.Ping:
                        _ = connection.SendAsync(Wire.Pong, []);
                        break;
                    case Wire.Pong:
                    case Wire.Hello:
                        break;
                    default:
                        ViewerLog.Write($"Ignored message type {message.Value.Type}");
                        break;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Closed on purpose.
        }
        catch (Exception ex)
        {
            if (!connection.Token.IsCancellationRequested)
            {
                ViewerLog.Write($"Session ended: {ex.Message}");
            }
        }
        finally
        {
            connection.Close();
            var wasActive = false;
            lock (_gate)
            {
                if (ReferenceEquals(_active, connection))
                {
                    _active = null;
                    wasActive = true;
                }

                if (ReferenceEquals(_current, connection))
                {
                    _current = null;
                }
            }

            if (wasActive)
            {
                Disconnected?.Invoke();
            }

            ViewerLog.Write(wasActive ? "The Mac disconnected. Waiting for it to connect again" : "Connection closed");
        }
    }

    private async Task<bool> AuthorizeAsync(Connection connection, string name)
    {
        if (_allowList.Allows(name))
        {
            return true;
        }

        if (IsRecentlyDenied(name))
        {
            ViewerLog.Write($"{name} was denied a moment ago");
            return false;
        }

        await _approvalLock.WaitAsync(connection.Token).ConfigureAwait(false);
        try
        {
            // Another connection may have been approved while this one was waiting.
            if (connection.Token.IsCancellationRequested)
            {
                return false;
            }

            if (_allowList.Allows(name))
            {
                return true;
            }

            if (IsRecentlyDenied(name))
            {
                return false;
            }

            var approved = await Task.Run(() => _approveMac(name)).ConfigureAwait(false);
            if (approved)
            {
                _allowList.Remember(name);
                return true;
            }

            ViewerLog.Write($"Denied {name}");
            lock (_gate)
            {
                _deniedUntil[name] = Environment.TickCount64 + DenyMemoryMs;
            }

            return false;
        }
        finally
        {
            _approvalLock.Release();
        }
    }

    private bool IsRecentlyDenied(string name)
    {
        lock (_gate)
        {
            return _deniedUntil.TryGetValue(name, out var until) && Environment.TickCount64 < until;
        }
    }

    private static async Task<(string Name, int Width, int Height)?> ReadHelloAsync(Connection connection)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
        timeout.CancelAfter(PreHelloIdleLimitMs);
        try
        {
            while (true)
            {
                var message = await Wire.ReadMessageAsync(connection.Stream, timeout.Token).ConfigureAwait(false);
                if (message is null)
                {
                    return null;
                }

                connection.Touch();
                if (message.Value.Type == Wire.Hello &&
                    Wire.TryParseHello(message.Value.Payload, out var name, out var width, out var height))
                {
                    return (name, width, height);
                }

                if (message.Value.Type == Wire.Ping)
                {
                    _ = connection.SendAsync(Wire.Pong, []);
                }
            }
        }
        catch (OperationCanceledException) when (!connection.Token.IsCancellationRequested)
        {
            ViewerLog.Write("The Mac did not send Hello in time");
            return null;
        }
    }

    /// <summary>
    /// Pings the Mac every 2 seconds and closes the connection if nothing at all arrives for too long.
    /// The idle check never waits on a write, so a stuck send cannot hide a dead connection.
    /// </summary>
    private static async Task KeepAliveAsync(Connection connection)
    {
        var tick = 0;
        try
        {
            while (!connection.Token.IsCancellationRequested)
            {
                await Task.Delay(1000, connection.Token).ConfigureAwait(false);
                var limit = connection.HelloSeen ? IdleLimitMs : PreHelloIdleLimitMs;
                if (connection.IdleMs > limit)
                {
                    ViewerLog.Write($"Nothing from the Mac for {limit / 1000} seconds; closing the connection");
                    connection.Close();
                    return;
                }

                tick++;
                if (tick % 2 == 0)
                {
                    _ = connection.SendAsync(Wire.Ping, []);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // The connection ended.
        }
    }

    private static void ConfigureSocket(TcpClient client)
    {
        try
        {
            client.NoDelay = true;
            var socket = client.Client;
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 10);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 3);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not tune the socket: {ex.Message}");
        }
    }

    private static async Task<bool> DelayAsync(int milliseconds, CancellationToken token)
    {
        try
        {
            await Task.Delay(milliseconds, token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    private sealed class Connection
    {
        private readonly TcpClient _client;
        private readonly SemaphoreSlim _writeLock = new(1, 1);
        private readonly CancellationTokenSource _cts;
        private long _lastReceiveTicks;

        public Connection(TcpClient client, CancellationToken appToken)
        {
            _client = client;
            Stream = client.GetStream();
            _cts = CancellationTokenSource.CreateLinkedTokenSource(appToken);
            Remote = SafeRemote(client);
            Touch();
        }

        public NetworkStream Stream { get; }

        public string Remote { get; }

        public CancellationToken Token => _cts.Token;

        public volatile bool HelloSeen;

        public long IdleMs => Environment.TickCount64 - Interlocked.Read(ref _lastReceiveTicks);

        public void Touch() => Interlocked.Exchange(ref _lastReceiveTicks, Environment.TickCount64);

        public async Task SendAsync(byte type, byte[] payload)
        {
            if (Token.IsCancellationRequested)
            {
                return;
            }

            try
            {
                await Wire.WriteMessageAsync(Stream, type, payload, _writeLock, Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException or OperationCanceledException or InvalidOperationException or SocketException)
            {
                if (!Token.IsCancellationRequested)
                {
                    ViewerLog.Write($"Send failed: {ex.Message}");
                }

                Close();
            }
        }

        public void Close()
        {
            try
            {
                _cts.Cancel();
            }
            catch
            {
                // Already cancelled.
            }

            try
            {
                _client.Close();
            }
            catch
            {
                // Already closed.
            }
        }

        private static string SafeRemote(TcpClient client)
        {
            try
            {
                return client.Client.RemoteEndPoint?.ToString() ?? "unknown";
            }
            catch
            {
                return "unknown";
            }
        }
    }
}
