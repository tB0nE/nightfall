package com.godot.game;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.Build;
import android.util.Log;

import java.net.InetAddress;
import java.util.ArrayList;
import java.util.List;

// Horizon OS 2.5+ can present the headset's USB-C port as a real network
// interface (usb0) through ConnectivityManager, instead of ADB reverse port
// forwarding - see docs/plans/active/usb-link-streaming.md and the reference
// implementation this is based on:
// https://github.com/Gilleece/moonlight-android-xr/pull/31
//
// TRANSPORT_USB is API 31; every real target device (Quest 3, Horizon OS
// 14-based) is well above that, so this is gated behind a runtime SDK_INT
// check rather than supporting older devices at all.
public class UsbLinkManager {
    private static final String TAG = "UsbLinkManager";

    private final ConnectivityManager connectivityManager;
    private volatile boolean requested = false;
    private volatile Network network;
    private volatile LinkProperties linkProperties;

    private final ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
        @Override
        public void onAvailable(Network net) {
            network = net;
            Log.i(TAG, "USB link available: " + net);
        }

        @Override
        public void onLinkPropertiesChanged(Network net, LinkProperties props) {
            if (net.equals(network)) {
                linkProperties = props;
                Log.i(TAG, "USB link properties: " + props);
            }
        }

        @Override
        public void onLost(Network net) {
            Log.i(TAG, "USB link lost: " + net);
            if (net.equals(network)) {
                network = null;
                linkProperties = null;
            }
            // The request itself stays registered: on replug Android delivers
            // onAvailable() to this same callback (observed on Quest 3), and
            // stop() still has to unregister it.
        }

        @Override
        public void onUnavailable() {
            Log.i(TAG, "USB link request could not be satisfied");
            requested = false;
        }
    };

    public UsbLinkManager(Context context) {
        connectivityManager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
    }

    public static boolean isSupported() {
        return Build.VERSION.SDK_INT >= 31;
    }

    public synchronized boolean start() {
        if (!isSupported()) {
            Log.w(TAG, "start: unsupported SDK level " + Build.VERSION.SDK_INT);
            return false;
        }
        if (requested) {
            Log.i(TAG, "start: already requested");
            return true;
        }
        if (connectivityManager == null) {
            Log.e(TAG, "start: no ConnectivityManager");
            return false;
        }

        // NET_CAPABILITY_INTERNET and NET_CAPABILITY_TRUSTED both have to be
        // removed or the system never matches the USB link as a candidate -
        // confirmed by the reference implementation, not documented behavior.
        NetworkRequest.Builder builder = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_USB)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED);

        try {
            connectivityManager.requestNetwork(builder.build(), callback);
            requested = true;
            Log.i(TAG, "start: USB link requested");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "start: requestNetwork failed", e);
            requested = false;
            return false;
        }
    }

    public synchronized void stop() {
        if (!requested) {
            return;
        }
        try {
            connectivityManager.unregisterNetworkCallback(callback);
        } catch (Exception e) {
            Log.w(TAG, "stop: unregisterNetworkCallback failed", e);
        }
        requested = false;
        network = null;
        linkProperties = null;
        Log.i(TAG, "stop: USB link released");
    }

    public boolean isUp() {
        return network != null;
    }

    public Network getNetwork() {
        return network;
    }

    // Addresses as text, link-local IPv6 first (the only reliably-reachable
    // kind over usb0 - see the plan doc for why). Each entry already carries
    // its interface scope where InetAddress reports one (e.g. "%12"); callers
    // that build their own literal need that scope attached explicitly
    // instead, since this method's whole point is giving the caller a
    // directly-usable textual address.
    public List<String> getLinkLocalAddresses() {
        List<String> addresses = new ArrayList<>();
        LinkProperties props = linkProperties;
        if (props == null) {
            return addresses;
        }
        List<String> others = new ArrayList<>();
        for (LinkAddress linkAddr : props.getLinkAddresses()) {
            InetAddress addr = linkAddr.getAddress();
            if (addr.isLinkLocalAddress()) {
                addresses.add(addr.getHostAddress());
            } else {
                others.add(addr.getHostAddress());
            }
        }
        addresses.addAll(others);
        return addresses;
    }

    // The OS-assigned name (usually "usb0", but not guaranteed) - used as the
    // zone for link-local addresses discovered over the link.
    public String getInterfaceName() {
        LinkProperties props = linkProperties;
        String name = props != null ? props.getInterfaceName() : null;
        return name != null ? name : "";
    }

    // Transport of the app's default (non-USB-Link) network, for the stats
    // overlay: "Wi-Fi", "Ethernet", or "" when unknown/none.
    public String getActiveTransport() {
        if (connectivityManager == null) {
            return "";
        }
        NetworkCapabilities caps;
        try {
            Network active = connectivityManager.getActiveNetwork();
            caps = active != null ? connectivityManager.getNetworkCapabilities(active) : null;
        } catch (SecurityException e) {
            Log.w(TAG, "getActiveTransport: " + e.getMessage());
            return "";
        }
        if (caps == null) {
            return "";
        }
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            return "Ethernet";
        }
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            return "Wi-Fi";
        }
        return "";
    }

    public String describeLinkProperties() {
        LinkProperties props = linkProperties;
        return props != null ? props.toString() : "(no link)";
    }
}
