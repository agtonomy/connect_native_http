package com.agtonomy.connect_native_http

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Connects a CronetBridge to its Flutter channels.
class ConnectNativeHttpPlugin : FlutterPlugin {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var bridge: CronetBridge
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        bridge = CronetBridge(binding.applicationContext) { event -> main.post { sink?.success(event) } }
        methods = MethodChannel(binding.binaryMessenger, "connect_native_http/cronet")
        methods.setMethodCallHandler { call, result ->
            @Suppress("UNCHECKED_CAST")
            val args = call.arguments as? Map<String, Any?> ?: emptyMap()
            bridge.handle(call.method, args) { reply ->
                when (reply) {
                    is CronetBridge.Reply.Success -> result.success(reply.value)
                    is CronetBridge.Reply.Error -> result.error(reply.code, reply.message, null)
                    CronetBridge.Reply.NotImplemented -> result.notImplemented()
                }
            }
        }
        events = EventChannel(binding.binaryMessenger, "connect_native_http/cronet/events")
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        bridge.close()
    }
}
