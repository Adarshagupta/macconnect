package com.macconnect.macconnect_phone

import android.app.Activity
import android.content.Context
import android.media.MediaCodec
import android.media.MediaFormat
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import android.view.WindowManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface

/// Decodes the Mac's H.264 stream onto a Flutter texture, and reports USB-tether addresses.
class MacConnectPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private var textures: TextureRegistry? = null
    private var activity: Activity? = null
    private var context: Context? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val thread = HandlerThread("macconnect-h264").also { it.start() }
    private val handler = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var codec: MediaCodec? = null
    private var presentationTimeUs = 0L

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "macconnect/phone")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        handler.post { releaseDecoder() }
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        thread.quitSafely()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareNetwork" -> {
                prepareNetwork()
                result.success(null)
            }
            "cableStatus" -> result.success(cableStatus())
            "keepScreenOn" -> {
                val on = call.argument<Boolean>("on") == true
                val host = activity
                host?.runOnUiThread {
                    if (on) {
                        host.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        host.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                result.success(null)
            }
            "startDecoder" -> {
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                if (width < 2 || height < 2) {
                    result.error("size", "The Mac sent a picture size that cannot be shown.", null)
                    return
                }
                val registry = textures
                if (registry == null) {
                    result.error("texture", "The video surface is not ready.", null)
                    return
                }
                val created = try {
                    registry.createSurfaceProducer()
                } catch (error: Exception) {
                    result.error("texture", error.message, null)
                    return
                }
                created.setSize(width, height)
                val surface = created.surface
                if (surface == null) {
                    created.release()
                    result.error("texture", "The video surface was not created.", null)
                    return
                }
                handler.post {
                    try {
                        releaseDecoder()
                        startCodec(surface, width, height)
                        producer = created
                        result.success(created.id())
                    } catch (error: Exception) {
                        producer = null
                        codec = null
                        main.post {
                            try {
                                created.release()
                            } catch (_: Exception) {
                            }
                        }
                        result.error("decoder", error.message, null)
                    }
                }
            }
            "feed" -> {
                val bytes = call.arguments as? ByteArray
                if (bytes == null) {
                    result.success(false)
                    return
                }
                handler.post {
                    result.success(decode(bytes))
                }
            }
            "stopDecoder" -> {
                handler.post {
                    releaseDecoder()
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun prepareNetwork() {
        val app = context ?: return
        val wifi = app.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (multicastLock == null) {
            multicastLock = wifi.createMulticastLock("macconnect").apply {
                setReferenceCounted(false)
            }
        }
        val lock = multicastLock ?: return
        try {
            if (!lock.isHeld) lock.acquire()
        } catch (_: RuntimeException) {
        }
    }

    private fun cableStatus(): Map<String, Any?> {
        val app = context
        val usb = if (app == null) emptyList() else usbAddresses(app)
        return mapOf(
            "usb" to usb.isNotEmpty(),
            "address" to usb.firstOrNull(),
            "peers" to arpPeers(usb.toSet()),
        )
    }

    private fun startCodec(surface: Surface, width: Int, height: Int) {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4_000_000)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            format.setInteger(MediaFormat.KEY_PRIORITY, 0)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        val decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            try {
                decoder.configure(format, surface, null, 0)
            } catch (_: Exception) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    format.setInteger(MediaFormat.KEY_LOW_LATENCY, 0)
                }
                decoder.configure(format, surface, null, 0)
            }
            decoder.start()
            codec = decoder
            presentationTimeUs = 0
        } catch (error: Exception) {
            try {
                decoder.release()
            } catch (_: Exception) {
            }
            throw error
        }
    }

    private fun decode(data: ByteArray): Boolean {
        val decoder = codec ?: return false
        val index = decoder.dequeueInputBuffer(8_000)
        if (index < 0) return false
        val buffer = decoder.getInputBuffer(index) ?: return false
        if (data.size > buffer.capacity()) return false
        buffer.clear()
        buffer.put(data)
        val flags = if (isKeyframe(data)) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        presentationTimeUs += 16_667
        decoder.queueInputBuffer(index, 0, data.size, presentationTimeUs, flags)
        val info = MediaCodec.BufferInfo()
        while (true) {
            val out = decoder.dequeueOutputBuffer(info, 0)
            when {
                out == MediaCodec.INFO_TRY_AGAIN_LATER -> break
                out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> continue
                out >= 0 -> {
                    decoder.releaseOutputBuffer(out, true)
                    producer?.scheduleFrame()
                }
                else -> break
            }
        }
        return true
    }

    private fun releaseDecoder() {
        val oldCodec = codec
        codec = null
        try {
            oldCodec?.stop()
        } catch (_: Exception) {
        }
        try {
            oldCodec?.release()
        } catch (_: Exception) {
        }
        val oldProducer = producer
        producer = null
        if (oldProducer != null) {
            main.post {
                try {
                    oldProducer.release()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun isKeyframe(data: ByteArray): Boolean {
        var index = 0
        while (index + 4 < data.size) {
            val start = when {
                data[index] == 0.toByte() && data[index + 1] == 0.toByte() && data[index + 2] == 1.toByte() -> index + 3
                data[index] == 0.toByte() &&
                    data[index + 1] == 0.toByte() &&
                    data[index + 2] == 0.toByte() &&
                    data[index + 3] == 1.toByte() -> index + 4
                else -> -1
            }
            if (start in data.indices) {
                val nal = data[start].toInt() and 0x1F
                if (nal == 5 || nal == 7) return true
                index = start
            } else {
                index += 1
            }
        }
        return false
    }
}

private fun usbAddresses(context: Context): List<String> {
    val found = linkedSetOf<String>()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        for (network in manager.allNetworks) {
            val caps = manager.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_USB)) continue
            val link = manager.getLinkProperties(network) ?: continue
            for (item in link.linkAddresses) {
                val address = item.address
                if (address is Inet4Address && !address.isLoopbackAddress) {
                    address.hostAddress?.let { found.add(it) }
                }
            }
        }
    }
    val interfaces = NetworkInterface.getNetworkInterfaces() ?: return found.toList()
    for (nif in interfaces) {
        if (!nif.isUp) continue
        val name = nif.name.lowercase()
        val usb = name.contains("rndis") || name.contains("usb") || name.contains("ncm")
        if (!usb) continue
        for (address in nif.inetAddresses) {
            if (address is Inet4Address && !address.isLoopbackAddress) {
                address.hostAddress?.let { found.add(it) }
            }
        }
    }
    return found.toList()
}

private fun arpPeers(own: Set<String>): List<String> {
    val file = File("/proc/net/arp")
    if (!file.exists()) return emptyList()
    val peers = linkedSetOf<String>()
    val lines = try {
        file.readLines()
    } catch (_: Exception) {
        return emptyList()
    }
    for (line in lines.drop(1)) {
        val parts = line.trim().split(Regex("\\s+"))
        if (parts.size < 4 || parts[2] != "0x2") continue
        val ip = parts[0]
        if (ip == "0.0.0.0" || ip in own || ip.startsWith("127.")) continue
        peers.add(ip)
    }
    return peers.toList()
}
