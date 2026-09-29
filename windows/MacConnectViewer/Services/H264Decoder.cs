using System.Runtime.InteropServices;

namespace MacConnectViewer.Services;

/// <summary>
/// Decodes one H.264 access unit (Annex B) into a BGRA picture. The decoder stays open for the
/// whole connection so later frames can refer to earlier ones, which is what keeps each picture small.
/// </summary>
public sealed class H264Decoder : IDisposable
{
    private const int MfVersion = 0x0002_0070;
    private const int MfStartupFull = 0;
    private const int NeedMoreInput = unchecked((int)0xC00D6D72);
    private const int StreamChange = unchecked((int)0xC00D6D61);
    private const int NotAccepting = unchecked((int)0xC00D36B5);
    private const int StartOfStream = 0x10000003;
    private const int BeginStreaming = 0x10000000;
    private const int OutputProvidesSamples = 0x100;
    private static bool _started;

    private IMFTransform? _transform;
    private bool _streaming;
    private bool _logged;
    private readonly int _width;
    private readonly int _height;

    public H264Decoder(int width, int height)
    {
        _width = width;
        _height = height;
    }

    public bool TryDecode(byte[] annexB, out byte[] bgra, out int width, out int height)
    {
        bgra = Array.Empty<byte>();
        width = _width;
        height = _height;
        if (annexB.Length < 5 || _width < 2 || _height < 2)
        {
            return false;
        }

        try
        {
            EnsureStarted();
            if (!Feed(annexB))
            {
                return false;
            }

            return Drain(out bgra, out width, out height);
        }
        catch (Exception ex)
        {
            if (!_logged)
            {
                _logged = true;
                ViewerLog.Write($"H.264 decode failed: {ex.Message}");
            }

            return false;
        }
    }

    public void Dispose()
    {
        if (_transform is not null)
        {
            Marshal.ReleaseComObject(_transform);
            _transform = null;
        }
    }

    private void EnsureStarted()
    {
        if (_transform is not null)
        {
            return;
        }

        if (!_started)
        {
            Check(MfNative.MFStartup(MfVersion, MfStartupFull), "MFStartup");
            _started = true;
        }

        var clsid = MfNative.ClsidH264Decoder;
        var iid = typeof(IMFTransform).GUID;
        Check(MfNative.CoCreateInstance(ref clsid, IntPtr.Zero, 1, ref iid, out var punk), "CoCreateInstance");
        _transform = (IMFTransform)Marshal.GetObjectForIUnknown(punk);
        Marshal.Release(punk);

        _transform.GetAttributes(out var attributes);
        attributes.U32(MfNative.LowLatency, 1);
        Marshal.ReleaseComObject(attributes);

        var input = CreateType(MfNative.H264, _width, _height);
        Check(_transform.SetInputType(0, input, 0), "SetInputType");
        Marshal.ReleaseComObject(input);

        IMFMediaType? nv12 = null;
        for (var index = 0; _transform.GetOutputAvailableType(0, index, out var candidate) >= 0; index++)
        {
            var subtypeKey = MfNative.Subtype;
            candidate.GetGUID(ref subtypeKey, out var subtype);
            if (subtype == MfNative.Nv12)
            {
                nv12 = candidate;
                break;
            }

            Marshal.ReleaseComObject(candidate);
        }

        if (nv12 is null)
        {
            throw new InvalidOperationException("The H.264 decoder has no NV12 output");
        }

        Check(_transform.SetOutputType(0, nv12, 0), "SetOutputType");
        Marshal.ReleaseComObject(nv12);
        Check(_transform.ProcessMessage(BeginStreaming, IntPtr.Zero), "BeginStreaming");
        Check(_transform.ProcessMessage(StartOfStream, IntPtr.Zero), "StartOfStream");
        _streaming = true;
    }

    private bool Feed(byte[] annexB)
    {
        if (_transform is null || !_streaming)
        {
            return false;
        }

        var sample = CreateSample(annexB);
        var hr = _transform.ProcessInput(0, sample, 0);
        Marshal.ReleaseComObject(sample);
        if (hr == NotAccepting)
        {
            return true;
        }

        Check(hr, "ProcessInput");
        return true;
    }

    private bool Drain(out byte[] bgra, out int width, out int height)
    {
        bgra = Array.Empty<byte>();
        width = _width;
        height = _height;
        if (_transform is null)
        {
            return false;
        }

        var produced = false;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            _transform.GetOutputStreamInfo(0, out var info);
            var provides = (info.dwFlags & OutputProvidesSamples) != 0;
            IMFSample? owned = null;
            var buffer = new MfNative.OutputBuffer
            {
                StreamId = 0,
                Sample = provides ? null : owned = CreateSample(new byte[Math.Max(info.cbSize, _width * _height * 3 / 2)]),
            };
            var outputs = new[] { buffer };
            var hr = _transform.ProcessOutput(0, 1, outputs, out _);
            if (hr == NeedMoreInput)
            {
                Release(owned);
                return produced;
            }

            if (hr == StreamChange)
            {
                Release(owned);
                Renegotiate();
                continue;
            }

            Check(hr, "ProcessOutput");
            var sample = outputs[0].Sample ?? owned;
            if (sample is null)
            {
                continue;
            }

            if (CopyNv12(sample, _width, _height, out bgra))
            {
                produced = true;
            }

            if (!ReferenceEquals(sample, owned))
            {
                Marshal.ReleaseComObject(sample);
            }

            Release(owned);
            return produced;
        }

        return produced;
    }

    private void Renegotiate()
    {
        if (_transform is null)
        {
            return;
        }

        if (_transform.GetOutputAvailableType(0, 0, out var output) < 0)
        {
            return;
        }

        _transform.SetOutputType(0, output, 0);
        Marshal.ReleaseComObject(output);
    }

    private static bool CopyNv12(IMFSample sample, int width, int height, out byte[] bgra)
    {
        bgra = Array.Empty<byte>();
        sample.ConvertToContiguousBuffer(out var buffer);
        buffer.Lock(out var scan0, out _, out var current);
        try
        {
            var ySize = width * height;
            if (current < ySize + ySize / 2)
            {
                return false;
            }

            var nv12 = new byte[current];
            Marshal.Copy(scan0, nv12, 0, current);
            bgra = new byte[ySize * 4];
            for (var y = 0; y < height; y++)
            {
                var yRow = y * width;
                var uvRow = ySize + (y / 2) * width;
                var dst = yRow * 4;
                for (var x = 0; x < width; x++)
                {
                    var c = nv12[yRow + x] - 16;
                    var d = nv12[uvRow + (x & ~1)] - 128;
                    var e = nv12[uvRow + (x & ~1) + 1] - 128;
                    bgra[dst++] = Clamp((298 * c + 516 * d + 128) >> 8);
                    bgra[dst++] = Clamp((298 * c - 100 * d - 208 * e + 128) >> 8);
                    bgra[dst++] = Clamp((298 * c + 409 * e + 128) >> 8);
                    bgra[dst++] = 255;
                }
            }

            return true;
        }
        finally
        {
            buffer.Unlock();
            Marshal.ReleaseComObject(buffer);
        }
    }

    private static byte Clamp(int value) => (byte)Math.Clamp(value, 0, 255);

    private static IMFSample CreateSample(byte[] data)
    {
        Check(MfNative.MFCreateSample(out var sample), "MFCreateSample");
        Check(MfNative.MFCreateMemoryBuffer(data.Length, out var buffer), "MFCreateMemoryBuffer");
        buffer.Lock(out var scan0, out _, out _);
        Marshal.Copy(data, 0, scan0, data.Length);
        buffer.Unlock();
        buffer.SetCurrentLength(data.Length);
        sample.AddBuffer(buffer);
        Marshal.ReleaseComObject(buffer);
        return sample;
    }

    private static IMFMediaType CreateType(Guid subtype, int width, int height)
    {
        Check(MfNative.MFCreateMediaType(out var type), "MFCreateMediaType");
        type.G(MfNative.MajorType, MfNative.Video);
        type.G(MfNative.Subtype, subtype);
        type.U64(MfNative.FrameSize, ((ulong)(uint)height << 32) | (uint)width);
        type.U64(MfNative.FrameRate, ((ulong)60 << 32) | 1);
        type.U64(MfNative.PixelAspect, ((ulong)1 << 32) | 1);
        type.U32(MfNative.Interlace, 2);
        return type;
    }

    private static void Release(object? com)
    {
        if (com is not null)
        {
            Marshal.ReleaseComObject(com);
        }
    }

    private static void Check(int hr, string what)
    {
        if (hr < 0)
        {
            throw new InvalidOperationException($"{what} 0x{hr:X8}");
        }
    }
}

internal static class MfNative
{
    public static readonly Guid ClsidH264Decoder = new("62CE7E72-4C71-4D20-B15D-452831A87D9D");
    public static readonly Guid LowLatency = new("9C27891A-ED7A-40e1-88E8-B22727A024EE");
    public static readonly Guid MajorType = new("48EBA18E-F8C9-4687-BF11-0A74C9F96A8F");
    public static readonly Guid Subtype = new("F7E34C9A-42E8-4714-B74B-CB29D72C35E5");
    public static readonly Guid FrameSize = new("1652C33D-D6B2-4012-B834-72030849A37D");
    public static readonly Guid FrameRate = new("C459A2E8-3D2C-4E44-B132-FEE5156C7BB0");
    public static readonly Guid PixelAspect = new("C6376A1E-8D0A-4027-BE45-6D9A0AD39BB6");
    public static readonly Guid Interlace = new("E2724BB8-E676-4806-B4B2-A8D6EFB44CCD");
    public static readonly Guid Video = new("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid H264 = new("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid Nv12 = new("3231564E-0000-0010-8000-00AA00389B71");

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFStartup(int version, int flags);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateMediaType(out IMFMediaType type);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateSample(out IMFSample sample);

    [DllImport("mfplat.dll", ExactSpelling = true)]
    public static extern int MFCreateMemoryBuffer(int maxLength, out IMFMediaBuffer buffer);

    [DllImport("ole32.dll", ExactSpelling = true)]
    public static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, int context, ref Guid iid, out IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    public struct OutputBuffer
    {
        public int StreamId;
        public IMFSample? Sample;
        public int Status;
        public IntPtr Events;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct StreamInfo
    {
        public int dwFlags;
        public int cbSize;
        public int cbAlignment;
    }
}

[ComImport]
[Guid("BF94C121-5B05-4E6F-8000-BA598961414D")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFTransform
{
    void GetStreamLimits(out int inputMinimum, out int inputMaximum, out int outputMinimum, out int outputMaximum);
    void GetStreamCount(out int inputs, out int outputs);
    void GetStreamIDs(int inputCount, [Out] int[] inputIds, int outputCount, [Out] int[] outputIds);
    void GetInputStreamInfo(int streamId, out MfNative.StreamInfo info);
    void GetOutputStreamInfo(int streamId, out MfNative.StreamInfo info);
    void GetAttributes(out IMFAttributes attributes);
    void GetInputStreamAttributes(int streamId, out IMFMediaType attributes);
    void GetOutputStreamAttributes(int streamId, out IMFMediaType attributes);
    void DeleteInputStream(int streamId);
    void AddInputStreams(int count, [In] int[] ids);
    int GetInputAvailableType(int streamId, int typeIndex, out IMFMediaType type);
    int GetOutputAvailableType(int streamId, int typeIndex, out IMFMediaType type);
    int SetInputType(int streamId, IMFMediaType type, int flags);
    int SetOutputType(int streamId, IMFMediaType type, int flags);
    void GetInputCurrentType(int streamId, out IMFMediaType type);
    void GetOutputCurrentType(int streamId, out IMFMediaType type);
    void GetInputStatus(int streamId, out int flags);
    void GetOutputStatus(out int flags);
    void SetOutputBounds(long lower, long upper);
    void ProcessEvent(int streamId, IntPtr eventPtr);
    int ProcessMessage(int message, IntPtr param);
    int ProcessInput(int streamId, IMFSample sample, int flags);
    int ProcessOutput(int flags, int bufferCount, [In, Out] MfNative.OutputBuffer[] buffers, out int status);
}

[ComImport]
[Guid("2CD2D921-C447-44A7-A13C-4ADABFC247E3")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFAttributes
{
    void GetItem(ref Guid key, IntPtr value);
    void GetItemType(ref Guid key, out int type);
    void CompareItem(ref Guid key, IntPtr value, out int result);
    void Compare(IMFAttributes other, int matchType, out int result);
    void GetUINT32(ref Guid key, out int value);
    void GetUINT64(ref Guid key, out long value);
    void GetDouble(ref Guid key, out double value);
    void GetGUID(ref Guid key, out Guid value);
    void GetStringLength(ref Guid key, out int length);
    void GetString(ref Guid key, IntPtr value, int size, out int length);
    void GetAllocatedString(ref Guid key, out IntPtr value, out int length);
    void GetBlobSize(ref Guid key, out int size);
    void GetBlob(ref Guid key, IntPtr buffer, int size, out int written);
    void GetAllocatedBlob(ref Guid key, out IntPtr buffer, out int size);
    void GetUnknown(ref Guid key, ref Guid iid, out IntPtr unknown);
    void SetItem(ref Guid key, IntPtr value);
    void DeleteItem(ref Guid key);
    void DeleteAllItems();
    void SetUINT32(ref Guid key, int value);
    void SetUINT64(ref Guid key, long value);
    void SetDouble(ref Guid key, double value);
    void SetGUID(ref Guid key, ref Guid value);
    void SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    void SetBlob(ref Guid key, IntPtr buffer, int size);
    void SetUnknown(ref Guid key, IntPtr unknown);
    void LockStore();
    void UnlockStore();
    void GetCount(out int count);
    void GetItemByIndex(int index, out Guid key, IntPtr value);
    void CopyAllItems(IntPtr destination);
}

internal static class MfAttr
{
    public static void U32(this IMFAttributes item, Guid key, int value) => item.SetUINT32(ref key, value);
    public static void U64(this IMFAttributes item, Guid key, long value) => item.SetUINT64(ref key, value);
    public static void G(this IMFAttributes item, Guid key, Guid value) => item.SetGUID(ref key, ref value);
    public static void U32(this IMFMediaType item, Guid key, int value) => item.SetUINT32(ref key, value);
    public static void U64(this IMFMediaType item, Guid key, long value) => item.SetUINT64(ref key, value);
    public static void G(this IMFMediaType item, Guid key, Guid value) => item.SetGUID(ref key, ref value);
}

[ComImport]
[Guid("44AE0FA8-EA31-4109-8D2E-4CAE4997C555")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaType
{
    void GetItem(ref Guid key, IntPtr value);
    void GetItemType(ref Guid key, out int type);
    void CompareItem(ref Guid key, IntPtr value, out int result);
    void Compare(IMFMediaType other, int matchType, out int result);
    void GetUINT32(ref Guid key, out int value);
    void GetUINT64(ref Guid key, out long value);
    void GetDouble(ref Guid key, out double value);
    void GetGUID(ref Guid key, out Guid value);
    void GetStringLength(ref Guid key, out int length);
    void GetString(ref Guid key, IntPtr value, int size, out int length);
    void GetAllocatedString(ref Guid key, out IntPtr value, out int length);
    void GetBlobSize(ref Guid key, out int size);
    void GetBlob(ref Guid key, IntPtr buffer, int size, out int written);
    void GetAllocatedBlob(ref Guid key, out IntPtr buffer, out int size);
    void GetUnknown(ref Guid key, ref Guid iid, out IntPtr unknown);
    void SetItem(ref Guid key, IntPtr value);
    void DeleteItem(ref Guid key);
    void DeleteAllItems();
    void SetUINT32(ref Guid key, int value);
    void SetUINT64(ref Guid key, long value);
    void SetDouble(ref Guid key, double value);
    void SetGUID(ref Guid key, ref Guid value);
    void SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    void SetBlob(ref Guid key, IntPtr buffer, int size);
    void SetUnknown(ref Guid key, IntPtr unknown);
    void LockStore();
    void UnlockStore();
    void GetCount(out int count);
    void GetItemByIndex(int index, out Guid key, IntPtr value);
    void CopyAllItems(IntPtr destination);
}

[ComImport]
[Guid("C40A00F2-B93A-4D80-AE8C-5A1C634F58E4")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFSample
{
    void GetItem(ref Guid key, IntPtr value);
    void GetItemType(ref Guid key, out int type);
    void CompareItem(ref Guid key, IntPtr value, out int result);
    void Compare(IMFMediaType other, int matchType, out int result);
    void GetUINT32(ref Guid key, out int value);
    void GetUINT64(ref Guid key, out long value);
    void GetDouble(ref Guid key, out double value);
    void GetGUID(ref Guid key, out Guid value);
    void GetStringLength(ref Guid key, out int length);
    void GetString(ref Guid key, IntPtr value, int size, out int length);
    void GetAllocatedString(ref Guid key, out IntPtr value, out int length);
    void GetBlobSize(ref Guid key, out int size);
    void GetBlob(ref Guid key, IntPtr buffer, int size, out int written);
    void GetAllocatedBlob(ref Guid key, out IntPtr buffer, out int size);
    void GetUnknown(ref Guid key, ref Guid iid, out IntPtr unknown);
    void SetItem(ref Guid key, IntPtr value);
    void DeleteItem(ref Guid key);
    void DeleteAllItems();
    void SetUINT32(ref Guid key, int value);
    void SetUINT64(ref Guid key, long value);
    void SetDouble(ref Guid key, double value);
    void SetGUID(ref Guid key, ref Guid value);
    void SetString(ref Guid key, [MarshalAs(UnmanagedType.LPWStr)] string value);
    void SetBlob(ref Guid key, IntPtr buffer, int size);
    void SetUnknown(ref Guid key, IntPtr unknown);
    void LockStore();
    void UnlockStore();
    void GetCount(out int count);
    void GetItemByIndex(int index, out Guid key, IntPtr value);
    void CopyAllItems(IntPtr destination);
    void GetSampleFlags(out int flags);
    void SetSampleFlags(int flags);
    void GetSampleTime(out long time);
    void SetSampleTime(long time);
    void GetSampleDuration(out long duration);
    void SetSampleDuration(long duration);
    void GetBufferCount(out int count);
    void GetBufferByIndex(int index, out IMFMediaBuffer buffer);
    void ConvertToContiguousBuffer(out IMFMediaBuffer buffer);
    void AddBuffer(IMFMediaBuffer buffer);
    void RemoveBufferByIndex(int index);
    void RemoveAllBuffers();
    void GetTotalLength(out int length);
    void CopyToBuffer(IMFMediaBuffer buffer);
}

[ComImport]
[Guid("045FA593-8799-42B8-BC8D-8968C6453507")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMFMediaBuffer
{
    void Lock(out IntPtr buffer, out int maxLength, out int currentLength);
    void Unlock();
    void GetCurrentLength(out int length);
    void SetCurrentLength(int length);
    void GetMaxLength(out int length);
}
