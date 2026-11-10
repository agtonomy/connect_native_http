package com.agtonomy.connect_native_http

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.chromium.net.BidirectionalStream
import org.chromium.net.CronetEngine
import org.chromium.net.CronetException
import org.chromium.net.NetworkException
import org.chromium.net.QuicOptions
import org.chromium.net.UrlResponseInfo
import java.net.URI
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

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

    // Cronet callbacks, read-idle timers and all state below run on this one thread, so none of it needs locking.
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val engines = HashMap<Int, Engine>()
    private val calls = HashMap<Int, Call>()
    private var nextEngineId = 1

    private class EngineOptions(val quicHints: List<Pair<String, Int>>, val quicIdleTimeoutSeconds: Int?)

    // One CronetEngine and the calls on it. An engine whose call hit its read-idle timeout is retired: new calls go to
    // a fresh one, with its own connections, and the retired one shuts down once its last call ends.
    private class Pool(val cronet: CronetEngine) {
        val callIds = HashSet<Int>()

        // When this engine last received anything from each origin ("host:port"), in System.nanoTime().
        val lastReceived = HashMap<String, Long>()
    }

    private class Engine(val options: EngineOptions, var current: Pool) {
        val retired = ArrayList<Pool>()
        var shuttingDown = false
    }

    private class Call(
        val callId: Int,
        val engineId: Int,
        val pool: Pool,
        val origin: String,
        val readIdleTimeoutNanos: Long?,
    ) {
        lateinit var stream: BidirectionalStream

        // When the call last received anything from the server, or started, for its read-idle timeout.
        var lastReceived = System.nanoTime()
        var readIdleTimer: ScheduledFuture<*>? = null

        // No request body is written before Cronet reports the stream ready, which is what lets Dart treat a
        // failure before this point as "never sent".
        var ready = false
        var responseComplete = false
        var endQueued = false
        val pending = ArrayDeque<Pair<ByteArray, Boolean>>()

        // Set once Dart has been told how the call ended. After the bridge fails a call itself, Cronet's own final
        // callback still follows, to release the stream.
        var reported = false
    }

    fun cancelAll() {
        execute(null) {
            calls.values.forEach { it.stream.cancel() }
        }
    }

    // Runs [task] on the bridge's thread. An exception escaping it would end that thread, and with it the app: Android's
    // default handler for uncaught exceptions kills the process. So it is logged, and fails the call it concerns.
    private fun execute(callId: Int?, task: () -> Unit) {
        executor.execute {
            try {
                task()
            } catch (e: Exception) {
                Log.e(TAG, "call $callId failed in the bridge", e)
                if (callId != null) {
                    abort(callId, e)
                }
            }
        }
    }

    // Handles one method call. [reply] is called on the main thread, and arguments Dart got wrong are refused with an
    // error reply rather than thrown on it.
    fun handle(method: String, args: Map<String, Any?>, reply: (Reply) -> Unit) {
        val result: (Reply) -> Unit = { r -> main.post { reply(r) } }
        try {
            dispatch(method, args, result)
        } catch (e: Exception) {
            // Not the arguments themselves: an open's include the request headers, credentials among them.
            Log.e(TAG, "$method: bad arguments", e)
            result(Reply.Error("badArguments", "$method: ${e.message}"))
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun dispatch(method: String, args: Map<String, Any?>, result: (Reply) -> Unit) {
        when (method) {
            "createEngine" -> {
                val options = EngineOptions(
                    (args["quicHints"] as List<List<Any>>?).orEmpty().map { it[0] as String to it[1] as Int },
                    args["quicIdleTimeoutSeconds"] as Int?,
                )
                executor.execute {
                    try {
                        val id = nextEngineId++
                        engines[id] = Engine(options, Pool(build(options)))
                        result(Reply.Success(id))
                    } catch (e: Throwable) {
                        // Throwable, not Exception: failing to load Cronet's native library is an UnsatisfiedLinkError.
                        Log.e(TAG, "createEngine failed", e)
                        result(Reply.Error("createEngine", e.toString()))
                    }
                }
            }
            "shutdownEngine" -> {
                val engineId = args["engineId"] as Int
                execute(null) {
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
                val headers = (args["headers"] as List<List<String>>).map { it[0] to it[1] }
                // A Dart int arrives as an Int or, past 32 bits, a Long.
                val readIdleTimeoutMs = (args["readIdleTimeoutMs"] as Number?)?.toLong()
                require(readIdleTimeoutMs == null || readIdleTimeoutMs > 0) { "readIdleTimeoutMs: $readIdleTimeoutMs" }
                execute(callId) { open(engineId, callId, url, httpMethod, headers, readIdleTimeoutMs) }
                result(Reply.Success(null))
            }
            "write" -> {
                val callId = args["callId"] as Int
                val data = args["data"] as ByteArray
                execute(callId) { enqueue(callId, data, false) }
                result(Reply.Success(null))
            }
            "end" -> {
                val callId = args["callId"] as Int
                execute(callId) { enqueue(callId, ByteArray(0), true) }
                result(Reply.Success(null))
            }
            "cancel" -> {
                val callId = args["callId"] as Int
                // Set when the call hit its deadline. The server was given a deadline a step earlier, so on a live
                // connection its deadline_exceeded would have ended the call first.
                val evictConnection = args["evictConnection"] as Boolean? ?: false
                execute(callId) {
                    val c = calls[callId] ?: return@execute
                    if (evictConnection) {
                        evict(c)
                    }
                    c.stream.cancel()
                }
                result(Reply.Success(null))
            }
            else -> result(Reply.NotImplemented)
        }
    }

    private fun build(options: EngineOptions): CronetEngine {
        val builder = CronetEngine.Builder(context).enableHttp2(true).enableQuic(true)
        for ((host, port) in options.quicHints) {
            builder.addQuicHint(host, port, port)
        }
        if (options.quicIdleTimeoutSeconds != null) {
            builder.setQuicOptions(
                QuicOptions.builder().setIdleConnectionTimeoutSeconds(options.quicIdleTimeoutSeconds.toLong()),
            )
        }
        return builder.build()
    }

    private fun open(
        engineId: Int,
        callId: Int,
        url: String,
        method: String,
        headers: List<Pair<String, String>>,
        readIdleTimeoutMs: Long?,
    ) {
        val engine = engines[engineId]
        if (engine == null || engine.shuttingDown) {
            emit(failure(callId, false, "engine $engineId is shut down", null))
            return
        }
        val pool = engine.current
        val target = URI(url)
        val port = if (target.port != -1) target.port else if (target.scheme == "http") 80 else 443
        val c = Call(
            callId,
            engineId,
            pool,
            "${target.host}:$port",
            readIdleTimeoutMs?.let { TimeUnit.MILLISECONDS.toNanos(it) },
        )
        val builder = pool.cronet.newBidirectionalStreamBuilder(url, Callback(c), executor).setHttpMethod(method)
        for ((name, value) in headers) {
            builder.addHeader(name, value)
        }
        c.stream = builder.build()
        // Throws on a method or header Cronet rejects, such as a value with a line break. The call is registered only
        // once it has started, so abort() then reports it as never sent, with no stream to release.
        c.stream.start()
        calls[callId] = c
        pool.callIds.add(callId)
        c.lastReceived = System.nanoTime()
        scheduleReadIdleCheck(c, c.readIdleTimeoutNanos)
    }

    // Read-idle timeout. Rather than rescheduling on every chunk received, each check finds when the call last received
    // something and, unless the timeout has run out since, schedules the next check for when it would.
    private fun scheduleReadIdleCheck(c: Call, delayNanos: Long?) {
        if (delayNanos == null) {
            return
        }
        val check = Runnable {
            try {
                checkReadIdle(c)
            } catch (e: Exception) {
                Log.e(TAG, "call ${c.callId} failed in the bridge", e)
                abort(c.callId, e)
            }
        }
        c.readIdleTimer = executor.schedule(check, delayNanos, TimeUnit.NANOSECONDS)
    }

    private fun checkReadIdle(c: Call) {
        val timeout = c.readIdleTimeoutNanos ?: return
        if (c.reported || calls[c.callId] !== c) {
            return
        }
        val idle = System.nanoTime() - c.lastReceived
        if (idle < timeout) {
            scheduleReadIdleCheck(c, timeout - idle)
            return
        }
        val message = "read idle timeout: nothing received for ${TimeUnit.NANOSECONDS.toMillis(idle)} ms"
        report(c, failure(c.callId, c.ready, message, ERR_TIMED_OUT))
        // Cronet's onCanceled then releases the call and the stream.
        c.stream.cancel()
        evict(c)
    }

    // Anything from the server shows the call's connection is alive.
    private fun received(c: Call) {
        val now = System.nanoTime()
        c.lastReceived = now
        c.pool.lastReceived[c.origin] = now
    }

    // A call that ran out of time (its read-idle timeout, or its deadline) may be stuck on a dead connection.
    // It is taken to be if nothing has arrived from the call's origin, on any call, since the call last received
    // anything; otherwise only that call was slow. Cronet has no call that closes one connection, so the engine's
    // CronetEngine is retired: new calls go to a fresh one, which dials its own connections, and the old one shuts down
    // once the calls still on it end. Calls that time out together on the same dead connection retire it once.
    private fun evict(c: Call) {
        val engine = engines[c.engineId] ?: return
        if (engine.current !== c.pool || engine.shuttingDown) {
            return
        }
        val heard = c.pool.lastReceived[c.origin]
        if (heard != null && heard - c.lastReceived > 0) {
            return
        }
        val fresh = try {
            Pool(build(engine.options))
        } catch (e: Throwable) {
            // Keep the engine there is; new calls on a dead connection fail on their own timeouts.
            Log.e(TAG, "engine ${c.engineId}: could not replace the CronetEngine after a read idle timeout", e)
            return
        }
        engine.retired.add(engine.current)
        engine.current = fresh
        Log.i(TAG, "engine ${c.engineId}: call ${c.callId} ran out of time on a quiet connection; moved to a new engine")
    }

    // Fails a call the bridge itself could not carry on with, after an exception on its thread.
    private fun abort(callId: Int, e: Exception) {
        val message = "connect_native_http bridge: $e"
        val c = calls[callId]
        if (c == null) {
            // Not started, so nothing was sent and there is no stream to release. A call that has already finished
            // is gone too; Dart ignores events for calls it no longer has.
            emit(failure(callId, false, message, null))
            return
        }
        report(c, failure(callId, c.ready, message, null))
        // Cronet's onCanceled then releases the call and the stream.
        c.stream.cancel()
    }

    private fun enqueue(callId: Int, data: ByteArray, endOfStream: Boolean) {
        val c = calls[callId] ?: return
        enqueue(c, data, endOfStream)
    }

    private fun enqueue(c: Call, data: ByteArray, endOfStream: Boolean) {
        // Cronet rejects writes after the end of the request, which the bridge may already have sent itself, and an
        // empty write before it, which has nothing to send anyway.
        if (c.endQueued || c.reported || (data.isEmpty() && !endOfStream)) {
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

    // Cronet's final callback for a call: releases it and, unless the bridge has already failed it, reports [event].
    private fun finish(c: Call, event: Map<String, Any?>) {
        c.readIdleTimer?.cancel(false)
        calls.remove(c.callId)
        c.pool.callIds.remove(c.callId)
        report(c, event)
        shutdownIfIdle(c.engineId)
    }

    private fun report(c: Call, event: Map<String, Any?>) {
        if (!c.reported) {
            c.reported = true
            emit(event)
        }
    }

    // Shuts down the engine's retired CronetEngines that no call uses any more, and the whole engine once it is shutting
    // down and idle.
    private fun shutdownIfIdle(engineId: Int) {
        val engine = engines[engineId] ?: return
        val idle = engine.retired.filter { it.callIds.isEmpty() }
        engine.retired.removeAll(idle)
        idle.forEach { shutdown(engineId, it) }
        if (engine.shuttingDown && engine.current.callIds.isEmpty() && engine.retired.isEmpty()) {
            engines.remove(engineId)
            shutdown(engineId, engine.current)
        }
    }

    private fun shutdown(engineId: Int, pool: Pool) {
        try {
            pool.cronet.shutdown()
        } catch (e: Exception) {
            // Cronet refuses while it still counts a request as running. The engine is unreachable either way.
            Log.w(TAG, "engine $engineId did not shut down", e)
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

    // Cronet catches exceptions from these methods itself: one from onStreamReady, onResponseHeadersReceived or
    // onReadCompleted fails the stream (onFailed, with a CallbackException), and one from a final callback is logged.
    private inner class Callback(private val c: Call) : BidirectionalStream.Callback() {
        override fun onStreamReady(stream: BidirectionalStream) {
            c.ready = true
            drain(c)
        }

        override fun onResponseHeadersReceived(stream: BidirectionalStream, info: UrlResponseInfo) {
            received(c)
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
            received(c)
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
            received(c)
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
        const val TAG = "connect_native_http"
        const val READ_BUFFER_BYTES = 32 * 1024

        // Chromium's net::ERR_TIMED_OUT (net/base/net_error_list.h), reported for a read idle timeout.
        const val ERR_TIMED_OUT = -7
    }
}
