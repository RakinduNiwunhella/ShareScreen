using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace ShareDisplay.Viewer;

/// <summary>
/// Newline-delimited JSON over a single TCP connection (matches macOS SignalingServer).
/// </summary>
internal sealed class SignalingLineClient : IDisposable
{
    private readonly object _gate = new();
    private TcpClient? _client;
    private StreamWriter? _writer;
    private StreamReader? _reader;
    private CancellationTokenSource? _readCts;
    private Task? _readLoop;

    public event Action<SignalingMessage>? MessageReceived;
    public event Action? Disconnected;

    public bool IsConnected => _client?.Connected == true;

    public Task ConnectAsync(string host, int port, CancellationToken ct)
    {
        return Task.Run(() =>
        {
            var c = new TcpClient();
            c.Connect(host, port);
            lock (_gate)
            {
                _client = c;
                var stream = c.GetStream();
                _writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true };
                _reader = new StreamReader(stream, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false);
            }

            _readCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            _readLoop = Task.Run(() => ReadLoop(_readCts.Token), ct);
        }, ct);
    }

    private void ReadLoop(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                string? line;
                lock (_gate)
                {
                    line = _reader?.ReadLine();
                }

                if (line == null)
                {
                    break;
                }

                SignalingMessage? msg;
                try
                {
                    msg = JsonSerializer.Deserialize<SignalingMessage>(line);
                }
                catch
                {
                    continue;
                }

                if (msg != null)
                {
                    MessageReceived?.Invoke(msg);
                }
            }
        }
        catch (ObjectDisposedException)
        {
            // ignore
        }
        catch (IOException)
        {
            // ignore
        }
        finally
        {
            Disconnected?.Invoke();
        }
    }

    public void SendHello(string token)
    {
        Send(new SignalingMessage { Type = "hello", Token = token });
    }

    public void SendAnswer(string sdp)
    {
        Send(new SignalingMessage { Type = "answer", Sdp = sdp });
    }

    public void SendCandidate(string candidate, int sdpMLineIndex, string? sdpMid)
    {
        Send(new SignalingMessage
        {
            Type = "candidate",
            Candidate = candidate,
            SdpMLineIndex = sdpMLineIndex,
            SdpMid = sdpMid
        });
    }

    private void Send(SignalingMessage msg)
    {
        var json = JsonSerializer.Serialize(msg);
        lock (_gate)
        {
            _writer?.WriteLine(json);
        }
    }

    public void Dispose()
    {
        try
        {
            _readCts?.Cancel();
        }
        catch
        {
            // ignore
        }

        try
        {
            _readLoop?.Wait(TimeSpan.FromSeconds(2));
        }
        catch
        {
            // ignore
        }

        lock (_gate)
        {
            try
            {
                _writer?.Dispose();
            }
            catch
            {
                // ignore
            }

            try
            {
                _reader?.Dispose();
            }
            catch
            {
                // ignore
            }

            try
            {
                _client?.Close();
            }
            catch
            {
                // ignore
            }

            _writer = null;
            _reader = null;
            _client = null;
        }

        _readCts?.Dispose();
    }
}
