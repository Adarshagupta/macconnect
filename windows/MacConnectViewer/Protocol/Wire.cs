using System.IO;
using System.Buffers.Binary;
using System.Text;

namespace MacConnectViewer.Protocol;

/// <summary>
/// MacConnect wire format. See protocol/PROTOCOL.md. Multi-byte values are little-endian.
/// </summary>
public static class Wire
{
    public const int BeaconPort = 47901;
    public const int TcpPort = 47900;
    public const byte BeaconVersion = 1;
    public const int MaxPayload = 8_000_000;
    public const int MaxNameBytes = 200;

    public const byte Hello = 1;
    public const byte Frame = 2;
    public const byte Mouse = 3;
    public const byte Key = 4;
    public const byte Ping = 5;
    public const byte Pong = 6;
    public const byte Accept = 7;
    public const byte Cursor = 8;

    public const byte MouseMove = 0;
    public const byte MouseDown = 1;
    public const byte MouseUp = 2;
    public const byte MouseScroll = 3;

    public const byte ButtonNone = 0;
    public const byte ButtonLeft = 1;
    public const byte ButtonRight = 2;
    public const byte ButtonMiddle = 3;

    private static readonly byte[] BeaconMagic = { 0x4D, 0x43, 0x31, 0x00 };

    public static byte[] BuildBeacon(int tcpPort, string computerName)
    {
        var name = Encoding.UTF8.GetBytes(computerName);
        if (name.Length > MaxNameBytes)
        {
            name = name[..MaxNameBytes];
        }

        var packet = new byte[8 + name.Length];
        BeaconMagic.CopyTo(packet, 0);
        packet[4] = BeaconVersion;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(5, 2), (ushort)tcpPort);
        packet[7] = (byte)name.Length;
        name.CopyTo(packet, 8);
        return packet;
    }

    public static byte[] BuildHeader(byte type, int payloadLength)
    {
        var header = new byte[5];
        header[0] = type;
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(1, 4), (uint)payloadLength);
        return header;
    }

    public static byte[] BuildMouse(byte action, byte button, float x, float y, short wheelDelta)
    {
        var payload = new byte[12];
        payload[0] = action;
        payload[1] = button;
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(2, 4), Math.Clamp(x, 0f, 1f));
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(6, 4), Math.Clamp(y, 0f, 1f));
        BinaryPrimitives.WriteInt16LittleEndian(payload.AsSpan(10, 2), wheelDelta);
        return payload;
    }

    public static byte[] BuildKey(ushort virtualKey, bool down)
    {
        var payload = new byte[3];
        BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(0, 2), virtualKey);
        payload[2] = down ? (byte)1 : (byte)0;
        return payload;
    }

    /// Reads the Mac pointer position (two Float32 values from 0 to 1).
    public static bool TryParseCursor(ReadOnlySpan<byte> payload, out float x, out float y)
    {
        x = 0;
        y = 0;
        if (payload.Length < 8)
        {
            return false;
        }

        x = BinaryPrimitives.ReadSingleLittleEndian(payload);
        y = BinaryPrimitives.ReadSingleLittleEndian(payload[4..]);
        return float.IsFinite(x) && float.IsFinite(y);
    }

    public static byte[] BuildCursor(float x, float y)
    {
        var payload = new byte[8];
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(0, 4), x);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(4, 4), y);
        return payload;
    }

    public static bool TryParseHello(ReadOnlySpan<byte> payload, out string name, out int width, out int height)
    {
        name = "";
        width = 0;
        height = 0;
        if (payload.Length < 6)
        {
            return false;
        }

        var nameLength = BinaryPrimitives.ReadUInt16LittleEndian(payload);
        if (payload.Length < 2 + nameLength + 4)
        {
            return false;
        }

        name = Encoding.UTF8.GetString(payload.Slice(2, nameLength));
        var offset = 2 + nameLength;
        width = BinaryPrimitives.ReadUInt16LittleEndian(payload[offset..]);
        height = BinaryPrimitives.ReadUInt16LittleEndian(payload[(offset + 2)..]);
        return name.Length > 0 && width > 0 && height > 0 && width <= 16384 && height <= 16384;
    }

    public static async Task<Incoming?> ReadMessageAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[5];
        if (!await ReadExactAsync(stream, header, cancellationToken).ConfigureAwait(false))
        {
            return null;
        }

        var length = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(1, 4));
        if (length > MaxPayload)
        {
            throw new InvalidDataException($"Frame length {length} exceeds the protocol limit.");
        }

        var payload = length == 0 ? Array.Empty<byte>() : new byte[length];
        if (length > 0 && !await ReadExactAsync(stream, payload, cancellationToken).ConfigureAwait(false))
        {
            return null;
        }

        return new Incoming(header[0], payload);
    }

    public static async Task WriteMessageAsync(Stream stream, byte type, byte[] payload, SemaphoreSlim writeLock, CancellationToken cancellationToken)
    {
        var header = BuildHeader(type, payload.Length);
        await writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
            if (payload.Length > 0)
            {
                await stream.WriteAsync(payload, cancellationToken).ConfigureAwait(false);
            }

            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            writeLock.Release();
        }
    }

    private static async Task<bool> ReadExactAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset, buffer.Length - offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                return false;
            }

            offset += read;
        }

        return true;
    }
}

public readonly record struct Incoming(byte Type, byte[] Payload);
