using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace MacConnectViewer.Services;

public static class NetworkInfo
{
    /// <summary>
    /// This PC's IPv4 addresses on the local network. Adapters that have a default gateway (the real
    /// network) come first and are preferred over virtual ones.
    /// </summary>
    public static IReadOnlyList<string> LocalAddresses()
    {
        var withGateway = new List<string>();
        var others = new List<string>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up ||
                    nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                {
                    continue;
                }

                var properties = nic.GetIPProperties();
                var hasGateway = properties.GatewayAddresses.Any(gateway =>
                    gateway.Address.AddressFamily == AddressFamily.InterNetwork && !gateway.Address.Equals(IPAddress.Any));

                foreach (var unicast in properties.UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork)
                    {
                        continue;
                    }

                    var text = unicast.Address.ToString();
                    if (text.StartsWith("169.254.", StringComparison.Ordinal))
                    {
                        continue;
                    }

                    (hasGateway ? withGateway : others).Add(text);
                }
            }
        }
        catch (Exception ex)
        {
            ViewerLog.Write($"Could not read this PC's addresses: {ex.Message}");
        }

        return (withGateway.Count > 0 ? withGateway : others).Distinct().ToList();
    }

    public static string Describe()
    {
        var addresses = LocalAddresses();
        return addresses.Count == 0
            ? "This PC is not connected to a network."
            : "This PC's address: " + string.Join(", ", addresses);
    }
}
