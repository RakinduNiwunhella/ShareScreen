using System.Text.Json.Serialization;

namespace ShareDisplay.Viewer;

internal sealed class SignalingMessage
{
    [JsonPropertyName("type")]
    public string? Type { get; set; }

    [JsonPropertyName("token")]
    public string? Token { get; set; }

    [JsonPropertyName("sdp")]
    public string? Sdp { get; set; }

    [JsonPropertyName("candidate")]
    public string? Candidate { get; set; }

    [JsonPropertyName("sdpMLineIndex")]
    public int? SdpMLineIndex { get; set; }

    [JsonPropertyName("sdpMid")]
    public string? SdpMid { get; set; }

    [JsonPropertyName("message")]
    public string? Message { get; set; }
}
