package com.agtonomy.connect_native_http

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.chromium.net.BidirectionalStream
import org.chromium.net.CronetEngine
import org.chromium.net.CronetException
import org.chromium.net.NetworkException
import org.chromium.net.QuicOptions
import org.chromium.net.UrlResponseInfo
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

// Bridges Cronet BidirectionalStream to lib/src/cronet/cronet_http_client.dart, one stream per call. Dart sends
// request chunks as method calls; response headers, body chunks, trailers and the outcome go to [emit], from the
// bridge's own thread. Kept free of Flutter so it can be tested without a Flutter app.
class CronetBridge(
    private val context: Context,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    sealed interface Reply {
        data class Success(val value: Any?) : Reply
        data class Error(val code: String, val message: String?) : Reply
        data object NotImplemented : Reply
    }

    private val main = Handler(Looper.getMainLooper())

    // Cronet callbacks and all state below run on this one thread, so none of it needs locking.
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val engines = HashMap<Int, Engine>()
    private val calls = HashMap<Int, Call>()
    private var nextEngineId = 1

    private class Engine(val cronet: CronetEngine) {
        val callIds = HashSet<Int>()
        var shuttingDown = false
    }

    private class Call(val callId: Int, val engineId: Int) {
        lateinit var stream: BidirectionalStream

        // No request body is written before Cronet reports the stream ready, which is what lets Dart treat a
        // failure before this point as "never sent".
        var ready = false
        var responseComplete = false
        var endQueued = false
        val pending = ArrayDeque<Pair<ByteArray, Boolean>>()
    }

    fun cancelAll() {
        executor.execute {
            calls.values.forEach { it.stream.cancel() }
        }
    }

    // Handles one method call. [reply] is called on the main thread.
    fun handle(method: String, args: Map<String, Any?>, reply: (Reply) -> Unit) {
        val result = { r: Reply -> main.post { reply(r) } }
        when (method) {
            "createEngine" -> {
                val quicHints = (args["quicHints"] as List<List<Any>>?).orEmpty()
                val quicIdleTimeoutSeconds = args["quicIdleTimeoutSeconds"] as Int?
                executor.execute {
                    try {
                        val builder = CronetEngine.Builder(context).enableHttp2(true).enableQuic(true)
                        for (hint in quicHints) {
                            val port = hint[1] as Int
                            builder.addQuicHint(hint[0] as String, port, port)
                        }
                        if (quicIdleTimeoutSeconds != null) {
                            builder.setQuicOptions(
                                QuicOptions.builder().setIdleConnectionTimeoutSeconds(quicIdleTimeoutSeconds.toLong()),
                            )
                        }
                        val id = nextEngineId++
                        engines[id] = Engine(builder.build())
                        result(Reply.Success(id))
                    } catch (e: Exception) {
                        result(Reply.Error("createEngine", e.message))
                    }
                }
            }
            "shutdownEngine" -> {
                val engineId = args["engineId"] as Int
                executor.execute {
                    engines[engineId]?.let {
                        it.shuttingDown = true
                        shutdownIfIdle(engineId)
                    }
                }
                result(Reply.Success(null))
            }
            "open" -> {
                val engineId = args["engineId"] as Int
                val callId = args["callId"] as Int
                val url = args["url"] as String
                val httpMethod = args["method"] as String
                val headers = args["headers"] as List<List<String>>
                executor.execute { open(engineId, callId, url, httpMethod, headers) }
                result(Reply.Success(null))
            }
            "write" -> {
                val callId = args["callId"] as Int
                val data = args["data"] as ByteArray
                executor.execute { enqueue(callId, data, false) }
                result(Reply.Success(null))
            }
            "end" -> {
                val callId = args["callId"] as Int
                executor.execute { enqueue(callId, ByteArray(0), true) }
                result(Reply.Success(null))
            }
            "cancel" -> {
                val callId = args["callId"] as Int
                executor.execute { calls[callId]?.stream?.cancel() }
                result(Reply.Success(null))
            }
            else -> result(Reply.NotImplemented)
        }
    }

    private fun open(engineId: Int, callId: Int, url: String, method: String, headers: List<List<String>>) {
        val engine = engines[engineId]
        if (engine == null || engine.shuttingDown) {
            emit(failure(callId, false, "engine $engineId is shut down", null))
            return
        }
        val c = Call(callId, engineId)
        val builder = engine.cronet.newBidirectionalStreamBuilder(url, Callback(c), executor).setHttpMethod(method)
        for (h in headers) {
            builder.addHeader(h[0], h[1])
        }
        c.stream = builder.build()
        calls[callId] = c
        engine.callIds.add(callId)
        c.stream.start()
    }

    private fun enqueue(callId: Int, data: ByteArray, endOfStream: Boolean) {
        val c = calls[callId] ?: return
        enqueue(c, data, endOfStream)
    }

    private fun enqueue(c: Call, data: ByteArray, endOfStream: Boolean) {
        // Cronet rejects writes after the end of the request, which the bridge may already have sent itself.
        if (c.endQueued) {
            return
        }
        c.endQueued = endOfStream
        c.pending.addLast(data to endOfStream)
        if (c.ready) {
            drain(c)
        }
    }

    private fun drain(c: Call) {
        if (c.pending.isEmpty()) {
            return
        }
        while (c.pending.isNotEmpty()) {
            val (data, endOfStream) = c.pending.removeFirst()
            val buffer = ByteBuffer.allocateDirect(data.size)
            buffer.put(data)
            buffer.flip()
            c.stream.write(buffer, endOfStream)
        }
        c.stream.flush()
    }

    private fun finish(c: Call, event: Map<String, Any?>) {
        calls.remove(c.callId)
        engines[c.engineId]?.callIds?.remove(c.callId)
        emit(event)
        shutdownIfIdle(c.engineId)
    }

    private fun shutdownIfIdle(engineId: Int) {
        val engine = engines[engineId] ?: return
        if (engine.shuttingDown && engine.callIds.isEmpty()) {
            engines.remove(engineId)
            engine.cronet.shutdown()
        }
    }

    private fun failure(callId: Int, streamReady: Boolean, message: String?, internalErrorCode: Int?) = mapOf(
        "callId" to callId,
        "type" to "failed",
        "streamReady" to streamReady,
        "message" to message,
        "internalErrorCode" to internalErrorCode,
    )

    private fun headerPairs(headers: List<Map.Entry<String, String>>) = headers.map { listOf(it.key, it.value) }

    private inner class Callback(private val c: Call) : BidirectionalStream.Callback() {
        override fun onStreamReady(stream: BidirectionalStream) {
            c.ready = true
            drain(c)
        }

        override fun onResponseHeadersReceived(stream: BidirectionalStream, info: UrlResponseInfo) {
            emit(mapOf(
                "callId" to c.callId,
                "type" to "headers",
                "status" to info.httpStatusCode,
                "protocol" to info.negotiatedProtocol,
                "headers" to headerPairs(info.allHeadersAsList),
            ))
            stream.read(ByteBuffer.allocateDirect(READ_BUFFER_BYTES))
        }

        override fun onReadCompleted(
            stream: BidirectionalStream,
            info: UrlResponseInfo,
            buffer: ByteBuffer,
            endOfStream: Boolean,
        ) {
            buffer.flip()
            if (buffer.hasRemaining()) {
                val bytes = ByteArray(buffer.remaining())
                buffer.get(bytes)
                emit(mapOf("callId" to c.callId, "type" to "data", "data" to bytes))
            }
            if (endOfStream) {
                // Cronet reports success only once both sides are closed. The server has finished the call, so end
                // the request side here rather than wait for a caller that may be waiting on this response.
                c.responseComplete = true
                emit(mapOf("callId" to c.callId, "type" to "responseComplete"))
                enqueue(c, ByteArray(0), true)
            } else {
                buffer.clear()
                stream.read(buffer)
            }
        }

        override fun onWriteCompleted(
            stream: BidirectionalStream,
            info: UrlResponseInfo?,
            buffer: ByteBuffer,
            endOfStream: Boolean,
        ) {}

        override fun onResponseTrailersReceived(
            stream: BidirectionalStream,
            info: UrlResponseInfo,
            trailers: UrlResponseInfo.HeaderBlock,
        ) {
            emit(mapOf("callId" to c.callId, "type" to "trailers", "headers" to headerPairs(trailers.asList)))
        }

        override fun onSucceeded(stream: BidirectionalStream, info: UrlResponseInfo) {
            finish(c, mapOf("callId" to c.callId, "type" to "done"))
        }

        override fun onFailed(stream: BidirectionalStream, info: UrlResponseInfo?, error: CronetException) {
            // An HTTP/3 server may reset the request stream once it has sent the whole response, while the client
            // still has its side open. The response arrived intact, so report success.
            if (c.responseComplete) {
                finish(c, mapOf("callId" to c.callId, "type" to "done"))
                return
            }
            val code = (error as? NetworkException)?.cronetInternalErrorCode
            finish(c, failure(c.callId, c.ready, error.message, code))
        }

        override fun onCanceled(stream: BidirectionalStream, info: UrlResponseInfo?) {
            finish(c, mapOf("callId" to c.callId, "type" to "canceled"))
        }
    }

    private companion object {
        const val READ_BUFFER_BYTES = 32 * 1024
    }
}
