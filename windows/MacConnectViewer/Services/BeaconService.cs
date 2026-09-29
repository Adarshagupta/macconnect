using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using MacConnectViewer.Protocol;

namespace MacConnectViewer.Services;

public sealed class BeaconService : IDisposable
{
    private readonly CancellationTokenSource _cts = new();
    private readonly int _tcpPort;
    private readonly string _computerName;

    public BeaconService(int tcpPort, string computerName)
    {
        _tcpPort = tcpPort;
        _computerName = computerName;
    }

    public void Start()
    {
        _ = Task.Run(() => LoopAsync(_cts.Token));
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
    }

    private async Task LoopAsync(CancellationToken cancellationToken)
    {
        using var udp = new UdpClient();
        udp.EnableBroadcast = true;
        var packet = Wire.BuildBeacon(_tcpPort, _computerName);
        ViewerLog.Write($"Broadcasting as {_computerName} on UDP {Wire.BeaconPort}");

        while (!cancellationToken.IsCancellationRequested)
        {
            foreach (var endpoint in BroadcastEndpoints())
            {
                try
                {
                    await udp.SendAsync(packet, endpoint, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception ex)
                {
                    ViewerLog.Write($"Beacon send to {endpoint} failed: {ex.Message}");
                }
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private static IEnumerable<IPEndPoint> BroadcastEndpoints()
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var endpoints = new List<IPEndPoint>();

        void Add(IPAddress address)
        {
            if (seen.Add(address.ToString()))
            {
                endpoints.Add(new IPEndPoint(address, Wire.BeaconPort));
            }
        }

        Add(IPAddress.Broadcast);
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up)
                {
                    continue;
                }

                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                foreach (var address in nic.GetIPProperties().UnicastAddresses)
                {
                    if (address.Address.AddressFamily != AddressFamily.InterNetwork || address.IPv4Mask is null)
                    {
                        continue;
                    }

                    Add(BroadcastAddress(address.Address, address.IPv4Mask));
                }
            }
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not list network interfaces: {ex.Message}");
        }

        return endpoints;
    }

    private static IPAddress BroadcastAddress(IPAddress address, IPAddress mask)
    {
        var ip = address.GetAddressBytes();
        var subnet = mask.GetAddressBytes();
        var broadcast = new byte[4];
        for (var i = 0; i < 4; i++)
        {
            broadcast[i] = (byte)(ip[i] | ~subnet[i]);
        }

        return new IPAddress(broadcast);
    }
}
