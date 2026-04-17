using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using SIPSorcery.Net;
using SIPSorceryMedia.Abstractions;
using SIPSorceryMedia.FFmpeg;
using Zeroconf;

namespace ShareDisplay.Viewer;

internal sealed class MainForm : Form
{
    private readonly TextBox _host = new() { Width = 220 };
    private readonly NumericUpDown _port = new() { Minimum = 1, Maximum = 65535, Value = 8765, Width = 80 };
    private readonly TextBox _token = new() { Width = 120 };
    private readonly TextBox _ffmpegPath = new() { Width = 420 };
    private readonly Button _connect = new() { Text = "Connect" };
    private readonly Button _browse = new() { Text = "Discover (mDNS)" };
    private readonly PictureBox _picture = new()
    {
        Size = new Size(960, 540),
        SizeMode = PictureBoxSizeMode.Zoom,
        BorderStyle = BorderStyle.FixedSingle,
        BackColor = Color.Black
    };
    private readonly Label _status = new() { AutoSize = true, Text = "Idle" };
    private readonly CheckBox _topMost = new() { Text = "Always on top", AutoSize = true };

    private readonly ILogger _logger = NullLogger.Instance;

    private SignalingLineClient? _sig;
    private RTCPeerConnection? _pc;
    private FFmpegVideoEndPoint? _videoEp;
    private readonly System.Collections.Generic.Queue<RTCIceCandidateInit> _pendingRemoteCandidates = new();

    private bool _remoteDescriptionSet;

    public MainForm()
    {
        Text = "ShareDisplay Viewer (Windows)";
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        var row1 = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false };
        row1.Controls.Add(new Label { Text = "Host", AutoSize = true, Padding = new Padding(0, 8, 6, 0) });
        row1.Controls.Add(_host);
        row1.Controls.Add(new Label { Text = "Port", AutoSize = true, Padding = new Padding(12, 8, 6, 0) });
        row1.Controls.Add(_port);
        row1.Controls.Add(new Label { Text = "PIN", AutoSize = true, Padding = new Padding(12, 8, 6, 0) });
        row1.Controls.Add(_token);

        var row2 = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false };
        row2.Controls.Add(new Label { Text = "FFmpeg bin (bundled ffmpeg\\bin; override if needed)", AutoSize = true, Padding = new Padding(0, 8, 6, 0) });
        row2.Controls.Add(_ffmpegPath);
        _ffmpegPath.Text = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "ffmpeg", "bin"));

        var row3 = new FlowLayoutPanel { FlowDirection = FlowDirection.LeftToRight, AutoSize = true, WrapContents = false };
        row3.Controls.Add(_connect);
        row3.Controls.Add(_browse);
        row3.Controls.Add(_topMost);

        _topMost.CheckedChanged += (_, _) => TopMost = _topMost.Checked;

        _connect.Click += async (_, _) => await ConnectAsync().ConfigureAwait(true);
        _browse.Click += async (_, _) => await BrowseAsync().ConfigureAwait(true);

        KeyPreview = true;
        KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.F11)
            {
                WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
            }
        };

        Controls.Add(new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            AutoSize = true,
            Padding = new Padding(12),
            Controls =
            {
                row1,
                row2,
                row3,
                _status,
                _picture
            }
        });
    }

    private async Task BrowseAsync()
    {
        try
        {
            SetStatus("Browsing mDNS…");
            var responses = await ZeroconfResolver.ResolveAsync("_sharedisplay._tcp.local.").ConfigureAwait(true);
            var first = responses.FirstOrDefault();
            if (first == null)
            {
                SetStatus("No ShareDisplay hosts found on the LAN.");
                return;
            }

            _host.Text = first.IPAddress;
            var p = first.Services.Values.FirstOrDefault()?.Port;
            if (p is > 0)
            {
                _port.Value = (decimal)p.Value;
            }

            SetStatus($"Selected {first.DisplayName} at {_host.Text}:{_port.Value}");
        }
        catch (Exception ex)
        {
            SetStatus($"mDNS browse failed: {ex.Message}");
        }
    }

    private async Task ConnectAsync()
    {
        if (_sig != null)
        {
            await DisconnectAsync().ConfigureAwait(true);
            return;
        }

        var host = _host.Text.Trim();
        if (string.IsNullOrWhiteSpace(host))
        {
            SetStatus("Enter the Mac’s IP address (or use Discover).");
            return;
        }

        var token = _token.Text.Trim();
        if (string.IsNullOrWhiteSpace(token))
        {
            SetStatus("Enter the pairing PIN shown on the Mac.");
            return;
        }

        var ffmpeg = _ffmpegPath.Text.Trim();
        if (string.IsNullOrWhiteSpace(ffmpeg))
        {
            ffmpeg = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "ffmpeg", "bin"));
        }

        if (!IsValidFfmpegBinFolder(ffmpeg))
        {
            SetStatus(
                "FFmpeg shared DLLs missing. On the dev PC run: .\\download-ffmpeg.ps1 (in the Viewer folder), then rebuild. Or set this path to a folder containing avcodec-*.dll.");
            return;
        }

        try
        {
            FFmpegInit.Initialise(FfmpegLogLevelEnum.AV_LOG_WARNING, ffmpeg, _logger);
        }
        catch (Exception ex)
        {
            SetStatus($"FFmpeg init failed: {ex.Message}");
            return;
        }

        _connect.Enabled = false;
        SetStatus("Connecting…");

        try
        {
            var cts = new CancellationTokenSource();
            var client = new SignalingLineClient();
            client.MessageReceived += msg => BeginInvoke(new Action(() => OnSignalingMessage(msg)));
            client.Disconnected += () => BeginInvoke(new Action(() => OnDisconnected()));

            await client.ConnectAsync(host, (int)_port.Value, cts.Token).ConfigureAwait(true);
            _sig = client;

            client.SendHello(token);
            _connect.Text = "Disconnect";
            _connect.Enabled = true;
            SetStatus("Signaling connected; waiting for Mac offer…");
        }
        catch (Exception ex)
        {
            SetStatus($"Connect failed: {ex.Message}");
            _connect.Enabled = true;
        }
    }

    private void OnDisconnected()
    {
        _ = DisconnectAsync();
    }

    private async Task DisconnectAsync()
    {
        SetStatus("Disconnected");
        _remoteDescriptionSet = false;
        _pendingRemoteCandidates.Clear();

        try
        {
            _pc?.close();
        }
        catch
        {
            // ignore
        }

        _pc = null;

        try
        {
            await (_videoEp?.CloseVideo() ?? Task.CompletedTask).ConfigureAwait(true);
        }
        catch
        {
            // ignore
        }

        _videoEp = null;

        try
        {
            _sig?.Dispose();
        }
        catch
        {
            // ignore
        }

        _sig = null;

        _connect.Text = "Connect";
        _connect.Enabled = true;
    }

    private void OnSignalingMessage(SignalingMessage msg)
    {
        if (msg.Type == "error")
        {
            SetStatus($"Error: {msg.Message}");
            _ = DisconnectAsync();
            return;
        }

        if (msg.Type == "hello_ok")
        {
            SetStatus("Paired; waiting for offer…");
            return;
        }

        if (msg.Type == "offer" && !string.IsNullOrWhiteSpace(msg.Sdp))
        {
            _ = HandleOfferAsync(msg.Sdp);
            return;
        }

        if (msg.Type == "candidate" && msg.Candidate != null && msg.SdpMLineIndex != null)
        {
            HandleRemoteCandidate(msg.Candidate, msg.SdpMLineIndex.Value, msg.SdpMid);
        }
    }

    private async Task HandleOfferAsync(string sdp)
    {
        try
        {
            SetStatus("Received offer; starting WebRTC…");

            await DisconnectPeerAsync().ConfigureAwait(true);

            _videoEp = new FFmpegVideoEndPoint();
            _videoEp.OnVideoSinkDecodedSampleFaster += raw =>
            {
                if (raw.PixelFormat != VideoPixelFormatsEnum.Rgb)
                {
                    return;
                }

                BeginInvoke(new Action(() =>
                {
                    try
                    {
                        if (_picture.Width != raw.Width || _picture.Height != raw.Height)
                        {
                            _picture.Width = raw.Width;
                            _picture.Height = raw.Height;
                        }

                        using var bmp = new Bitmap(raw.Width, raw.Height, raw.Stride, PixelFormat.Format24bppRgb, raw.Sample);
                        var prev = _picture.Image;
                        _picture.Image = (Image)bmp.Clone();
                        prev?.Dispose();
                    }
                    catch
                    {
                        // ignore UI decode races
                    }
                }));
            };

            var config = new RTCConfiguration
            {
                iceServers = new System.Collections.Generic.List<RTCIceServer>
                {
                    new() { urls = "stun:stun.l.google.com:19302" }
                },
                X_UseRtpFeedbackProfile = true
            };

            _pc = new RTCPeerConnection(config);

            var videoTrack = new MediaStreamTrack(_videoEp.GetVideoSinkFormats(), MediaStreamStatusEnum.RecvOnly);
            _pc.addTrack(videoTrack);
            _pc.OnVideoFrameReceived += _videoEp.GotVideoFrame;
            _pc.OnVideoFormatsNegotiated += formats => _videoEp.SetVideoSinkFormat(formats.First());

            _pc.onicecandidate += ice =>
            {
                if (ice == null)
                {
                    return;
                }

                try
                {
                    _sig?.SendCandidate(ice.candidate, (int)ice.sdpMLineIndex, ice.sdpMid);
                }
                catch
                {
                    // ignore
                }
            };

            _pc.onconnectionstatechange += state =>
            {
                BeginInvoke(new Action(() => SetStatus($"PC state: {state}")));
            };

            var offer = new RTCSessionDescriptionInit
            {
                type = RTCSdpType.offer,
                sdp = sdp
            };

            _pc.setRemoteDescription(offer);
            _remoteDescriptionSet = true;
            FlushPendingCandidates();

            var answer = _pc.createAnswer();
            await _pc.setLocalDescription(answer).ConfigureAwait(true);
            _sig?.SendAnswer(answer.sdp);

            SetStatus("WebRTC negotiated; decoding video…");
        }
        catch (Exception ex)
        {
            SetStatus($"WebRTC failed: {ex.Message}");
            _ = DisconnectAsync();
        }
    }

    private void HandleRemoteCandidate(string candidate, int sdpMLineIndex, string? sdpMid)
    {
        var init = new RTCIceCandidateInit
        {
            candidate = candidate,
            sdpMid = sdpMid,
            sdpMLineIndex = (ushort)sdpMLineIndex
        };

        if (!_remoteDescriptionSet || _pc == null)
        {
            _pendingRemoteCandidates.Enqueue(init);
            return;
        }

        _pc.addIceCandidate(init);
    }

    private void FlushPendingCandidates()
    {
        if (_pc == null)
        {
            return;
        }

        while (_pendingRemoteCandidates.Count > 0)
        {
            var c = _pendingRemoteCandidates.Dequeue();
            _pc.addIceCandidate(c);
        }
    }

    private async Task DisconnectPeerAsync()
    {
        _remoteDescriptionSet = false;
        _pendingRemoteCandidates.Clear();

        try
        {
            _pc?.close();
        }
        catch
        {
            // ignore
        }

        _pc = null;

        try
        {
            await (_videoEp?.CloseVideo() ?? Task.CompletedTask).ConfigureAwait(true);
        }
        catch
        {
            // ignore
        }

        _videoEp = null;
    }

    private void SetStatus(string text)
    {
        _status.Text = text;
    }

    private static bool IsValidFfmpegBinFolder(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
        {
            return false;
        }

        try
        {
            return Directory.GetFiles(path, "avcodec-*.dll").Length > 0;
        }
        catch
        {
            return false;
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _ = DisconnectAsync();
        base.OnFormClosed(e);
    }
}
