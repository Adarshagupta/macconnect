namespace MacConnectViewer.Services;

/// <summary>
/// The Windows H.264 decoder holds back several pictures unless the stream says it has no frame
/// reordering. The Mac encoder does not reorder, but its stream header (SPS) does not say so.
/// This adds that statement (VUI bitstream_restriction: no reordering, one reference picture buffer)
/// to every SPS, so each picture comes out as soon as it arrives. Anything unexpected leaves the
/// data untouched.
/// </summary>
internal static class H264SpsPatcher
{
    public static byte[] Patch(byte[] annexB)
    {
        // The stream header always comes first in a keyframe, so ordinary pictures are passed through untouched.
        var typeIndex = annexB.Length > 4 && annexB[0] == 0 && annexB[1] == 0 && annexB[2] == 0 && annexB[3] == 1 ? 4
            : annexB.Length > 3 && annexB[0] == 0 && annexB[1] == 0 && annexB[2] == 1 ? 3
            : -1;
        if (typeIndex < 0 || (annexB[typeIndex] & 0x1F) != 7)
        {
            return annexB;
        }

        var nals = SplitNals(annexB);
        var found = false;
        foreach (var (start, length) in nals)
        {
            if (length > 0 && (annexB[start] & 0x1F) == 7)
            {
                found = true;
                break;
            }
        }

        if (!found)
        {
            return annexB;
        }

        try
        {
            var output = new List<byte>(annexB.Length + 16);
            foreach (var (start, length) in nals)
            {
                var nal = new ReadOnlySpan<byte>(annexB, start, length);
                output.AddRange(new byte[] { 0, 0, 0, 1 });
                if (length > 4 && (nal[0] & 0x1F) == 7)
                {
                    output.AddRange(PatchSps(nal) ?? nal.ToArray());
                }
                else
                {
                    output.AddRange(nal.ToArray());
                }
            }

            return output.ToArray();
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not patch the H.264 header: {ex.Message}");
            return annexB;
        }
    }

    private static List<(int Start, int Length)> SplitNals(byte[] data)
    {
        var result = new List<(int, int)>();
        var starts = new List<int>();
        for (var i = 0; i + 2 < data.Length; i++)
        {
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            {
                starts.Add(i + 3);
                i += 2;
            }
        }

        for (var n = 0; n < starts.Count; n++)
        {
            var begin = starts[n];
            var end = n + 1 < starts.Count ? starts[n + 1] - 3 : data.Length;
            while (end > begin && data[end - 1] == 0)
            {
                end--;
            }

            if (end > begin)
            {
                result.Add((begin, end - begin));
            }
        }

        return result;
    }

    /// Returns the rewritten SPS NAL unit, or null when it should be left alone.
    private static byte[]? PatchSps(ReadOnlySpan<byte> nal)
    {
        var rbsp = Unescape(nal[1..]);
        if (rbsp.Length < 5)
        {
            return null;
        }

        var reader = new BitReader(rbsp, 24);
        var profile = rbsp[0];
        reader.Ue(); // seq_parameter_set_id
        if (profile is 100 or 110 or 122 or 244 or 44 or 83 or 86 or 118 or 128 or 138 or 139 or 134 or 135)
        {
            var chroma = reader.Ue();
            if (chroma == 3)
            {
                reader.Bit();
            }

            reader.Ue();
            reader.Ue();
            reader.Bit();
            if (reader.Bit() == 1)
            {
                var lists = chroma != 3 ? 8 : 12;
                for (var i = 0; i < lists; i++)
                {
                    if (reader.Bit() == 1)
                    {
                        SkipScalingList(reader, i < 6 ? 16 : 64);
                    }
                }
            }
        }

        reader.Ue(); // log2_max_frame_num_minus4
        var pocType = reader.Ue();
        if (pocType == 0)
        {
            reader.Ue();
        }
        else if (pocType == 1)
        {
            reader.Bit();
            reader.Se();
            reader.Se();
            var count = reader.Ue();
            for (var i = 0; i < count; i++)
            {
                reader.Se();
            }
        }

        var maxRefFrames = reader.Ue();
        reader.Bit(); // gaps_in_frame_num_value_allowed_flag
        reader.Ue();
        reader.Ue();
        if (reader.Bit() == 0)
        {
            reader.Bit(); // mb_adaptive_frame_field_flag
        }

        reader.Bit(); // direct_8x8_inference_flag
        if (reader.Bit() == 1)
        {
            reader.Ue();
            reader.Ue();
            reader.Ue();
            reader.Ue();
        }

        var vuiPosition = reader.Position;
        if (reader.Bit() == 1)
        {
            return null; // Already has a VUI. Leave it alone.
        }

        if (reader.Overrun)
        {
            return null;
        }

        var writer = new BitWriter();
        writer.CopyBits(rbsp, vuiPosition);
        writer.Bit(1); // vui_parameters_present_flag
        for (var i = 0; i < 7; i++)
        {
            writer.Bit(0); // aspect ratio, overscan, video signal, chroma loc, timing, nal hrd, vcl hrd: all absent
        }

        writer.Bit(0); // pic_struct_present_flag
        writer.Bit(1); // bitstream_restriction_flag
        writer.Bit(1); // motion_vectors_over_pic_boundaries_flag
        writer.Ue(0);  // max_bytes_per_pic_denom
        writer.Ue(0);  // max_bits_per_mb_denom
        writer.Ue(15); // log2_max_mv_length_horizontal
        writer.Ue(15); // log2_max_mv_length_vertical
        writer.Ue(0);  // max_num_reorder_frames: pictures leave the decoder in the order they arrive
        writer.Ue(Math.Max(1u, maxRefFrames)); // max_dec_frame_buffering
        writer.Bit(1); // rbsp_stop_one_bit
        writer.Align();

        var patched = new List<byte> { nal[0] };
        patched.AddRange(Escape(writer.ToArray()));
        return patched.ToArray();
    }

    private static void SkipScalingList(BitReader reader, int size)
    {
        var last = 8;
        var next = 8;
        for (var j = 0; j < size; j++)
        {
            if (next != 0)
            {
                var delta = reader.Se();
                next = (last + delta + 256) % 256;
            }

            last = next == 0 ? last : next;
        }
    }

    private static byte[] Unescape(ReadOnlySpan<byte> data)
    {
        var result = new List<byte>(data.Length);
        var zeros = 0;
        foreach (var value in data)
        {
            if (zeros >= 2 && value == 3)
            {
                zeros = 0;
                continue;
            }

            result.Add(value);
            zeros = value == 0 ? zeros + 1 : 0;
        }

        return result.ToArray();
    }

    private static List<byte> Escape(byte[] data)
    {
        var result = new List<byte>(data.Length + 4);
        var zeros = 0;
        foreach (var value in data)
        {
            if (zeros >= 2 && value <= 3)
            {
                result.Add(3);
                zeros = 0;
            }

            result.Add(value);
            zeros = value == 0 ? zeros + 1 : 0;
        }

        return result;
    }

    private sealed class BitReader
    {
        private readonly byte[] _data;

        public BitReader(byte[] data, int position)
        {
            _data = data;
            Position = position;
        }

        public int Position { get; private set; }

        public bool Overrun { get; private set; }

        public int Bit()
        {
            var index = Position >> 3;
            if (index >= _data.Length)
            {
                Overrun = true;
                Position++;
                return 0;
            }

            var bit = (_data[index] >> (7 - (Position & 7))) & 1;
            Position++;
            return bit;
        }

        public uint Ue()
        {
            var zeros = 0;
            while (Bit() == 0)
            {
                zeros++;
                if (zeros > 31 || Overrun)
                {
                    Overrun = true;
                    return 0;
                }
            }

            uint value = 0;
            for (var i = 0; i < zeros; i++)
            {
                value = (value << 1) | (uint)Bit();
            }

            return (1u << zeros) - 1 + value;
        }

        public int Se()
        {
            var value = Ue();
            var magnitude = (int)((value + 1) / 2);
            return (value & 1) == 1 ? magnitude : -magnitude;
        }
    }

    private sealed class BitWriter
    {
        private readonly List<byte> _bytes = new();
        private int _current;
        private int _count;

        public void Bit(int bit)
        {
            _current = (_current << 1) | (bit & 1);
            _count++;
            if (_count == 8)
            {
                _bytes.Add((byte)_current);
                _current = 0;
                _count = 0;
            }
        }

        public void CopyBits(byte[] source, int bitCount)
        {
            for (var i = 0; i < bitCount; i++)
            {
                Bit((source[i >> 3] >> (7 - (i & 7))) & 1);
            }
        }

        public void Ue(uint value)
        {
            var code = value + 1;
            var length = 0;
            for (var v = code; v > 1; v >>= 1)
            {
                length++;
            }

            for (var i = 0; i < length; i++)
            {
                Bit(0);
            }

            for (var i = length; i >= 0; i--)
            {
                Bit((int)((code >> i) & 1));
            }
        }

        public void Align()
        {
            while (_count != 0)
            {
                Bit(0);
            }
        }

        public byte[] ToArray() => _bytes.ToArray();
    }
}
