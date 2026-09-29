// Drives the viewer's SessionService with a fake Mac that speaks the wire protocol.
// Run: dotnet run --project windows/MacConnectViewer.Tests
using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using MacConnectViewer.Protocol;
using MacConnectViewer.Services;

const int Port = 47955;
var failures = 0;

void Check(bool condition, string what)
{
    Console.WriteLine($"{(condition ? "PASS" : "FAIL")}  {what}");
    if (!condition)
    {
        failures++;
    }
}

ViewerLog.FilePath = Path.Combine(Path.GetTempPath(), $"macconnect-test-{Guid.NewGuid():N}.log");
var allowPath = Path.Combine(Path.GetTempPath(), $"macconnect-allow-{Guid.NewGuid():N}.json");
var allowList = new AllowListStore(allowPath);
var approvals = 0;

using var service = new SessionService(allowList, name =>
{
    Interlocked.Increment(ref approvals);
    return name != "DenyMac";
}, Port);

var accepted = new SemaphoreSlim(0);
var frames = new SemaphoreSlim(0);
byte[]? lastFrame = null;
var disconnected = 0;
service.MacAccepted += (_, _, _) => accepted.Release();
service.FrameReceived += frame =>
{
    lastFrame = frame;
    frames.Release();
};
service.Disconnected += () => Interlocked.Increment(ref disconnected);
var cursors = new SemaphoreSlim(0);
float cursorX = -1, cursorY = -1;
service.CursorReceived += (x, y) =>
{
    cursorX = x;
    cursorY = y;
    cursors.Release();
};
service.Start();

static byte[] HelloPayload(string name, int width, int height)
{
    var nameBytes = Encoding.UTF8.GetBytes(name);
    var payload = new byte[2 + nameBytes.Length + 4];
    BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(0, 2), (ushort)nameBytes.Length);
    nameBytes.CopyTo(payload, 2);
    BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(2 + nameBytes.Length, 2), (ushort)width);
    BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(4 + nameBytes.Length, 2), (ushort)height);
    return payload;
}

static async Task<(TcpClient Client, NetworkStream Stream)> ConnectAsync()
{
    for (var attempt = 0; attempt < 50; attempt++)
    {
        try
        {
            var client = new TcpClient { NoDelay = true };
            await client.ConnectAsync("127.0.0.1", Port);
            return (client, client.GetStream());
        }
        catch (SocketException)
        {
            await Task.Delay(100);
        }
    }

    throw new InvalidOperationException("The viewer never started listening");
}

static async Task SendAsync(NetworkStream stream, byte type, byte[] payload)
{
    await stream.WriteAsync(Wire.BuildHeader(type, payload.Length));
    if (payload.Length > 0)
    {
        await stream.WriteAsync(payload);
    }
}

// Reads until a message of the wanted type arrives. Answers pings like the real Mac does.
static async Task<Incoming?> ReadUntilAsync(NetworkStream stream, byte wanted, int timeoutMs)
{
    using var cts = new CancellationTokenSource(timeoutMs);
    try
    {
        while (true)
        {
            var message = await Wire.ReadMessageAsync(stream, cts.Token);
            if (message is null)
            {
                return null;
            }

            if (message.Value.Type == Wire.Ping && wanted != Wire.Ping)
            {
                await SendAsync(stream, Wire.Pong, []);
            }

            if (message.Value.Type == wanted)
            {
                return message;
            }
        }
    }
    catch (OperationCanceledException)
    {
        return null;
    }
    catch (IOException)
    {
        return null;
    }
}

static async Task<bool> IsClosedByPeerAsync(NetworkStream stream, int timeoutMs)
{
    using var cts = new CancellationTokenSource(timeoutMs);
    var buffer = new byte[1024];
    try
    {
        while (true)
        {
            var read = await stream.ReadAsync(buffer, cts.Token);
            if (read == 0)
            {
                return true;
            }
        }
    }
    catch (OperationCanceledException)
    {
        return false;
    }
    catch (IOException)
    {
        return true;
    }
}

// 1. Handshake, first-time approval, remembered name.
var (clientA, streamA) = await ConnectAsync();
await SendAsync(streamA, Wire.Hello, HelloPayload("TestMac", 800, 600));
var accept = await ReadUntilAsync(streamA, Wire.Accept, 5000);
Check(accept is not null, "viewer accepts a new Mac after approval");
Check(await accepted.WaitAsync(3000), "MacAccepted event fires");
Check(approvals == 1, "the user was asked exactly once");
Check(service.IsConnected, "IsConnected is true after accept");

// 2. Frames reach the UI.
var jpeg = new byte[] { 0xFF, 0xD8, 0xFF, 0xD9 };
await SendAsync(streamA, Wire.Frame, jpeg);
Check(await frames.WaitAsync(3000) && lastFrame is not null && lastFrame.SequenceEqual(jpeg), "frame payload is delivered intact");

// 2b. The Mac pointer position reaches the UI.
await SendAsync(streamA, Wire.Cursor, Wire.BuildCursor(0.25f, 0.75f));
Check(await cursors.WaitAsync(3000) && Math.Abs(cursorX - 0.25f) < 0.0001f && Math.Abs(cursorY - 0.75f) < 0.0001f, "Mac pointer position is delivered");
await SendAsync(streamA, Wire.Cursor, new byte[] { 1, 2 });
Check(!await cursors.WaitAsync(300), "a short pointer message is ignored");

// 3. Viewer pings the Mac, and input reaches the Mac.
var ping = await ReadUntilAsync(streamA, Wire.Ping, 5000);
Check(ping is not null, "viewer sends pings");
await service.SendMouseAsync(Wire.MouseDown, Wire.ButtonLeft, 0.25f, 0.75f, 0);
var mouse = await ReadUntilAsync(streamA, Wire.Mouse, 3000);
Check(mouse is not null && mouse.Value.Payload.Length == 12 && mouse.Value.Payload[0] == Wire.MouseDown && mouse.Value.Payload[1] == Wire.ButtonLeft,
    "mouse click reaches the Mac");
if (mouse is not null)
{
    var x = BinaryPrimitives.ReadSingleLittleEndian(mouse.Value.Payload.AsSpan(2, 4));
    var y = BinaryPrimitives.ReadSingleLittleEndian(mouse.Value.Payload.AsSpan(6, 4));
    Check(Math.Abs(x - 0.25f) < 0.0001f && Math.Abs(y - 0.75f) < 0.0001f, "mouse position is preserved");
}

await service.SendKeyAsync(0x41, true);
var key = await ReadUntilAsync(streamA, Wire.Key, 3000);
Check(key is not null && key.Value.Payload.Length == 3 && key.Value.Payload[0] == 0x41 && key.Value.Payload[2] == 1, "key press reaches the Mac");

// 4. The Mac reconnects while the old socket is still open (a stale connection).
var disconnectedBefore = Volatile.Read(ref disconnected);
var (clientB, streamB) = await ConnectAsync();
await SendAsync(streamB, Wire.Hello, HelloPayload("TestMac", 800, 600));
var acceptB = await ReadUntilAsync(streamB, Wire.Accept, 5000);
Check(acceptB is not null, "a reconnect is accepted immediately while the old connection is still open");
Check(approvals == 1, "the remembered Mac is not asked about again");
Check(await IsClosedByPeerAsync(streamA, 3000), "the stale connection is closed by the viewer");
await Task.Delay(300);
Check(Volatile.Read(ref disconnected) == disconnectedBefore, "replacing a connection does not blank the screen");
Check(service.IsConnected, "still connected through the replacement");

// 5. The new connection goes silent: the viewer must notice and free the slot.
var silenceStarted = DateTime.UtcNow;
var noticed = false;
while (DateTime.UtcNow - silenceStarted < TimeSpan.FromSeconds(14))
{
    if (Volatile.Read(ref disconnected) > disconnectedBefore)
    {
        noticed = true;
        break;
    }

    await Task.Delay(200);
}

Check(noticed, $"a silent Mac is detected as gone ({(DateTime.UtcNow - silenceStarted).TotalSeconds:0.0}s)");
Check(!service.IsConnected, "IsConnected is false after the Mac goes silent");
clientA.Dispose();
clientB.Dispose();

// 6. A denied Mac is not asked again right away.
var approvalsBefore = approvals;
var (clientC, streamC) = await ConnectAsync();
await SendAsync(streamC, Wire.Hello, HelloPayload("DenyMac", 800, 600));
Check(await IsClosedByPeerAsync(streamC, 5000), "a denied Mac is disconnected");
var (clientD, streamD) = await ConnectAsync();
await SendAsync(streamD, Wire.Hello, HelloPayload("DenyMac", 800, 600));
Check(await IsClosedByPeerAsync(streamD, 5000), "a denied Mac is disconnected again");
Check(approvals == approvalsBefore + 1, "a denied Mac does not trigger a prompt every retry");
clientC.Dispose();
clientD.Dispose();

// 7. Garbage does not take the viewer down.
var (clientE, streamE) = await ConnectAsync();
await streamE.WriteAsync(new byte[] { 2, 0xFF, 0xFF, 0xFF, 0x7F, 1, 2, 3 });
Check(await IsClosedByPeerAsync(streamE, 5000), "an oversized frame closes only that connection");
clientE.Dispose();
var (clientF, streamF) = await ConnectAsync();
await SendAsync(streamF, Wire.Hello, HelloPayload("TestMac", 640, 480));
Check(await ReadUntilAsync(streamF, Wire.Accept, 5000) is not null, "the viewer still works after bad input");
clientF.Dispose();

Console.WriteLine();
Console.WriteLine(failures == 0 ? "All checks passed." : $"{failures} check(s) failed.");
File.Delete(allowPath);
return failures == 0 ? 0 : 1;
