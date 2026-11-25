// =============================================================================
//  MfEncoders.cs — кодери H.264 і AAC з Media Foundation (для «Відео по Wi-Fi»)
// =============================================================================
//  На Mac кодує AVAssetWriter. У Windows 10/11 є свої кодери — перетворювачі
//  Media Foundation (MFT): «Microsoft H264 Encoder MFT» і «Microsoft AAC Audio
//  Encoder MFT»; нічого ставити не треба. Інтерфейси COM — з NAudio.Wasapi
//  (IMFTransform, IMFMediaType, IMFSample); ICodecAPI — тут.
//
//  H.264: на вхід NV12, профіль Baseline (без B-кадрів — мітка показу = мітці
//  декодування), ключовий кадр раз на секунду (шматок HLS — від ключового),
//  режим малої затримки (кадр виходить одразу, без черги на кілька кадрів),
//  постійна швидкість. На виході — Annex B (00 00 00 01 …).
//  AAC: на вхід PCM 16 біт 48 кГц стерео, на виході кадри з заголовком ADTS
//  (MF_MT_AAC_PAYLOAD_TYPE = 1) — їх і чекає MPEG-TS.
// =============================================================================

using System.Runtime.InteropServices;
using NAudio.MediaFoundation;

namespace Slovo.App;

static class MfGuids
{
    public static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    public static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    public static readonly Guid Video = new("73646976-0000-0010-8000-00AA00389B71");
    public static readonly Guid Audio = new("73647561-0000-0010-8000-00AA00389B71");
    public static readonly Guid H264 = new("34363248-0000-0010-8000-00AA00389B71");
    public static readonly Guid NV12 = new("3231564E-0000-0010-8000-00AA00389B71");
    public static readonly Guid AAC = new("00001610-0000-0010-8000-00AA00389B71");
    public static readonly Guid PCM = new("00000001-0000-0010-8000-00AA00389B71");
    public static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    public static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    public static readonly Guid PixelAspect = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    public static readonly Guid Interlace = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    public static readonly Guid AvgBitrate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    public static readonly Guid Profile = new("ad76a80b-2d5c-4e0b-b375-64e520137036");
    public static readonly Guid Channels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    public static readonly Guid SampleRate = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    public static readonly Guid BitsPerSample = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    public static readonly Guid AvgBytes = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    public static readonly Guid BlockAlign = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    public static readonly Guid AacPayload = new("bfbabe79-7434-4d1c-94f0-72a3b9e17188");
    public static readonly Guid AacProfileLevel = new("7632f0e6-9538-4d61-acda-ea29c8c14456");
    public static readonly Guid CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");
    // ICodecAPI
    public static readonly Guid GopSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    public static readonly Guid LowLatency = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid RateControl = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    public static readonly Guid MeanBitrate = new("f7222374-2144-4815-b550-a37f8e12ee52");
}

[ComImport, Guid("901db4c7-31ce-41a2-85dc-8fa0bf41b8da"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ICodecAPI
{
    [PreserveSig] int IsSupported(ref Guid api);
    [PreserveSig] int IsModifiable(ref Guid api);
    [PreserveSig] int GetParameterRange(ref Guid api, IntPtr min, IntPtr max, IntPtr step);
    [PreserveSig] int GetParameterValues(ref Guid api, out IntPtr values, out uint count);
    [PreserveSig] int GetDefaultValue(ref Guid api, IntPtr value);
    [PreserveSig] int GetValue(ref Guid api, IntPtr value);
    [PreserveSig] int SetValue(ref Guid api, [In, MarshalAs(UnmanagedType.Struct)] ref object value);
}

/// Один вихідний шматок кодера: байти, мітка (100 нс), чи ключовий.
public readonly record struct EncodedUnit(byte[] Data, long Time, bool Key);

/// Спільне для обох кодерів: запуск MF, вхід, вихід із черги.
abstract class MfEncoder : IDisposable
{
    const int NeedMoreInput = unchecked((int)0xC00D6D72), StreamChange = unchecked((int)0xC00D6D61);
    static bool _started;
    protected IMFTransform Transform = null!;
    bool _providesSamples;
    int _outputSize;

    protected static void StartUp()
    {
        if (_started) return;
        MediaFoundationApi.Startup();
        _started = true;
    }

    protected static IMFTransform Create(Guid clsid) =>
        (IMFTransform)Activator.CreateInstance(System.Type.GetTypeFromCLSID(clsid, throwOnError: true)!)!;

    protected void Begin()
    {
        Transform.GetOutputStreamInfo(0, out var info);
        _providesSamples = ((int)info.dwFlags & 0x100) != 0;   // MFT_OUTPUT_STREAM_PROVIDES_SAMPLES
        _outputSize = Math.Max(info.cbSize, 1 << 20);
        Transform.ProcessMessage(MFT_MESSAGE_TYPE.MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, IntPtr.Zero);
        Transform.ProcessMessage(MFT_MESSAGE_TYPE.MFT_MESSAGE_NOTIFY_START_OF_STREAM, IntPtr.Zero);
    }

    protected static IMFMediaType Type(Guid major, Guid subtype)
    {
        var type = MediaFoundationApi.CreateMediaType();
        type.SetGUID(MfGuids.MajorType, major);
        type.SetGUID(MfGuids.Subtype, subtype);
        return type;
    }

    protected void Feed(byte[] data, int length, long time, long duration)
    {
        var buffer = MediaFoundationApi.CreateMemoryBuffer(length);
        buffer.Lock(out var pointer, out _, out _);
        Marshal.Copy(data, 0, pointer, length);
        buffer.Unlock();
        buffer.SetCurrentLength(length);
        var sample = MediaFoundationApi.CreateSample();
        sample.AddBuffer(buffer);
        sample.SetSampleTime(time);
        sample.SetSampleDuration(duration);
        Transform.ProcessInput(0, sample, 0);
        Marshal.ReleaseComObject(sample);
        Marshal.ReleaseComObject(buffer);
    }

    /// Забрати все, що кодер уже видав.
    protected List<EncodedUnit> Drain()
    {
        var result = new List<EncodedUnit>();
        while (true)
        {
            IMFSample? own = null;
            IMFMediaBuffer? ownBuffer = null;
            if (!_providesSamples)
            {
                own = MediaFoundationApi.CreateSample();
                ownBuffer = MediaFoundationApi.CreateMemoryBuffer(_outputSize);
                own.AddBuffer(ownBuffer);
            }
            var buffers = new MFT_OUTPUT_DATA_BUFFER[] { new() { dwStreamID = 0, pSample = own } };
            var hr = Transform.ProcessOutput(_MFT_PROCESS_OUTPUT_FLAGS.None, 1, buffers, out _);
            try
            {
                if (hr == NeedMoreInput) return result;
                if (hr == StreamChange)
                {
                    Transform.GetOutputAvailableType(0, 0, out var changed);
                    Transform.SetOutputType(0, changed, _MFT_SET_TYPE_FLAGS.None);
                    continue;
                }
                Marshal.ThrowExceptionForHR(hr);
                var sample = buffers[0].pSample;
                if (sample == null) return result;
                sample.ConvertToContiguousBuffer(out var contiguous);
                contiguous.Lock(out var pointer, out _, out var length);
                var bytes = new byte[length];
                Marshal.Copy(pointer, bytes, 0, length);
                contiguous.Unlock();
                sample.GetSampleTime(out var time);
                var key = false;
                try { sample.GetUINT32(MfGuids.CleanPoint, out var clean); key = clean != 0; } catch { }
                result.Add(new EncodedUnit(bytes, time, key));
                Marshal.ReleaseComObject(contiguous);
                if (_providesSamples) Marshal.ReleaseComObject(sample);
            }
            finally
            {
                if (ownBuffer != null) Marshal.ReleaseComObject(ownBuffer);
                if (own != null) Marshal.ReleaseComObject(own);
            }
        }
    }

    public void Dispose()
    {
        try
        {
            Transform.ProcessMessage(MFT_MESSAGE_TYPE.MFT_MESSAGE_NOTIFY_END_OF_STREAM, IntPtr.Zero);
            Transform.ProcessMessage(MFT_MESSAGE_TYPE.MFT_MESSAGE_NOTIFY_END_STREAMING, IntPtr.Zero);
        }
        catch { }
        Marshal.ReleaseComObject(Transform);
    }
}

sealed class MfH264Encoder : MfEncoder
{
    public readonly int Width, Height, Fps;

    public MfH264Encoder(int width, int height, int fps, int bitrate)
    {
        StartUp();
        Width = width; Height = height; Fps = fps;
        Transform = Create(new Guid("6ca50344-051a-4ded-9779-a43305165e35"));
        // Вихід — першим: так хоче кодер H.264.
        var output = Type(MfGuids.Video, MfGuids.H264);
        output.SetUINT32(MfGuids.AvgBitrate, bitrate);
        output.SetUINT64(MfGuids.FrameSize, ((long)width << 32) | (uint)height);
        output.SetUINT64(MfGuids.FrameRate, ((long)fps << 32) | 1);
        output.SetUINT64(MfGuids.PixelAspect, (1L << 32) | 1);
        output.SetUINT32(MfGuids.Interlace, 2);
        output.SetUINT32(MfGuids.Profile, 66);   // Baseline
        Transform.SetOutputType(0, output, _MFT_SET_TYPE_FLAGS.None);
        var input = Type(MfGuids.Video, MfGuids.NV12);
        input.SetUINT64(MfGuids.FrameSize, ((long)width << 32) | (uint)height);
        input.SetUINT64(MfGuids.FrameRate, ((long)fps << 32) | 1);
        input.SetUINT64(MfGuids.PixelAspect, (1L << 32) | 1);
        input.SetUINT32(MfGuids.Interlace, 2);
        Transform.SetInputType(0, input, _MFT_SET_TYPE_FLAGS.None);
        if (Transform is ICodecAPI codec)
        {
            object gop = (uint)fps, low = true, cbr = 0u, mean = (uint)bitrate;
            var g = MfGuids.GopSize; codec.SetValue(ref g, ref gop);
            var l = MfGuids.LowLatency; codec.SetValue(ref l, ref low);
            var r = MfGuids.RateControl; codec.SetValue(ref r, ref cbr);
            var m = MfGuids.MeanBitrate; codec.SetValue(ref m, ref mean);
        }
        Begin();
    }

    /// Кадр NV12 (w×h яскравості + w×h/2 кольору); час — у 100 нс.
    public List<EncodedUnit> Encode(byte[] nv12, long time)
    {
        Feed(nv12, Width * Height * 3 / 2, time, 10_000_000L / Fps);
        return Drain();
    }
}

sealed class MfAacEncoder : MfEncoder
{
    public const int Rate = 48000, Channels = 2;

    public MfAacEncoder(int bytesPerSecond = 16000)
    {
        StartUp();
        Transform = Create(new Guid("93AF0C51-2275-45d2-A35B-F2BA21CAED00"));
        // У кодера AAC навпаки — спершу вхід.
        var input = Type(MfGuids.Audio, MfGuids.PCM);
        input.SetUINT32(MfGuids.BitsPerSample, 16);
        input.SetUINT32(MfGuids.SampleRate, Rate);
        input.SetUINT32(MfGuids.Channels, Channels);
        input.SetUINT32(MfGuids.BlockAlign, Channels * 2);
        input.SetUINT32(MfGuids.AvgBytes, Rate * Channels * 2);
        Transform.SetInputType(0, input, _MFT_SET_TYPE_FLAGS.None);
        var output = Type(MfGuids.Audio, MfGuids.AAC);
        output.SetUINT32(MfGuids.BitsPerSample, 16);
        output.SetUINT32(MfGuids.SampleRate, Rate);
        output.SetUINT32(MfGuids.Channels, Channels);
        output.SetUINT32(MfGuids.AvgBytes, bytesPerSecond);
        output.SetUINT32(MfGuids.AacPayload, 1);           // ADTS
        output.SetUINT32(MfGuids.AacProfileLevel, 0x29);
        Transform.SetOutputType(0, output, _MFT_SET_TYPE_FLAGS.None);
        Begin();
    }

    /// PCM 16 біт, переплетений; час — у 100 нс.
    public List<EncodedUnit> Encode(byte[] pcm, int length, long time)
    {
        Feed(pcm, length, time, length / (Channels * 2) * 10_000_000L / Rate);
        return Drain();
    }
}
