package com.agtonomy.connect_native_http

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CompletableFuture
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

// Bridge behavior the Dart integration tests can't reach, against test_server/. run_integration_tests.sh starts the
// server and passes its URL as the serverUrl instrumentation argument.
@RunWith(AndroidJUnit4::class)
class CronetBridgeTest {
    private lateinit var serverUrl: String
    private lateinit var bridge: CronetBridge
    private val incoming = LinkedBlockingQueue<Map<String, Any?>>()
    private val events = mutableListOf<Map<String, Any?>>()

    @Before
    fun setUp() {
        val url = InstrumentationRegistry.getArguments().getString("serverUrl")
        assumeTrue("serverUrl is not set; run these through run_integration_tests.sh", url != null)
        serverUrl = url!!
        bridge = CronetBridge(InstrumentationRegistry.getInstrumentation().targetContext) { incoming.put(it) }
    }

    @Test
    fun writesBeforeTheStreamIsReadyAreSentOnceItIs() {
        val engine = createEngine()
        open(engine, 1, SAY, "application/proto")
        invoke("write", mapOf("callId" to 1, "data" to sentence("hi")))
        invoke("end", mapOf("callId" to 1))
        assertEquals("done", awaitOutcome(1)["type"])
        assertTrue(received(1).contains("say: hi"))
    }

    @Test
    fun writeAfterTheServerFinishedTheCallIsDropped() {
        val engine = createEngine()
        open(engine, 1, CONVERSE, "application/connect+proto")
        invoke("write", mapOf("callId" to 1, "data" to envelope(sentence("bye"))))
        await(1, "responseComplete")
        // The bridge has already ended the request side; Cronet throws on a write after that.
        invoke("write", mapOf("callId" to 1, "data" to envelope(sentence("late"))))
        invoke("end", mapOf("callId" to 1))
        assertEquals("done", awaitOutcome(1)["type"])
        assertTrue(received(1).contains("echo: bye"))
    }

    @Test
    fun shutdownLetsACallInFlightFinishAndRefusesNewOnes() {
        val engine = createEngine()
        open(engine, 1, CONVERSE, "application/connect+proto")
        invoke("shutdownEngine", mapOf("engineId" to engine))
        invoke("write", mapOf("callId" to 1, "data" to envelope(sentence("bye"))))
        assertEquals("done", awaitOutcome(1)["type"])
        assertTrue(received(1).contains("echo: bye"))

        open(engine, 2, CONVERSE, "application/connect+proto")
        val refused = awaitOutcome(2)
        assertEquals("failed", refused["type"])
        assertEquals(false, refused["streamReady"])
    }

    private fun invoke(method: String, arguments: Map<String, Any?>): Any? {
        val result = CompletableFuture<CronetBridge.Reply>()
        bridge.handle(method, arguments) { result.complete(it) }
        return when (val reply = result.get(3, TimeUnit.SECONDS)) {
            is CronetBridge.Reply.Success -> reply.value
            else -> throw AssertionError("$method: $reply")
        }
    }

    private fun createEngine(): Int = invoke("createEngine", mapOf("quicHints" to emptyList<Any>())) as Int

    private fun open(engine: Int, callId: Int, path: String, contentType: String) {
        invoke("open", mapOf(
            "engineId" to engine,
            "callId" to callId,
            "url" to serverUrl + path,
            "method" to "POST",
            "headers" to listOf(listOf("content-type", contentType), listOf("connect-protocol-version", "1")),
        ))
    }

    // Each case opens a fresh connection to the host through the emulator, which once took 3 s to come up on CI (the
    // request reached the server just as a 3 s wait gave up). 10 s, like the Dart cases, still fails a real hang fast.
    private fun await(callId: Int, vararg types: String): Map<String, Any?> {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (true) {
            events.firstOrNull { it["callId"] == callId && it["type"] in types }?.let { return it }
            val left = deadline - System.nanoTime()
            val next = if (left > 0) incoming.poll(left, TimeUnit.NANOSECONDS) else null
            if (next == null) {
                fail("timed out waiting for ${types.toList()} on call $callId; events: $events")
            }
            events.add(next!!)
        }
    }

    private fun awaitOutcome(callId: Int) = await(callId, "done", "failed", "canceled")

    // The response body so far, as text; Connect framing and protobuf leave the sentences readable.
    private fun received(callId: Int): String = events
        .filter { it["callId"] == callId && it["type"] == "data" }
        .joinToString("") { String(it["data"] as ByteArray, Charsets.UTF_8) }

    private companion object {
        const val CONVERSE = "/connectrpc.eliza.v1.ElizaService/Converse"
        const val SAY = "/connectrpc.eliza.v1.ElizaService/Say"

        // A SayRequest or ConverseRequest: field 1, the sentence.
        fun sentence(text: String): ByteArray {
            val utf8 = text.toByteArray(Charsets.UTF_8)
            require(utf8.size < 128)
            return byteArrayOf(0x0A, utf8.size.toByte()) + utf8
        }

        // A Connect streaming message: flags, big-endian length, payload.
        fun envelope(payload: ByteArray): ByteArray {
            val n = payload.size
            return byteArrayOf(0, (n shr 24).toByte(), (n shr 16).toByte(), (n shr 8).toByte(), n.toByte()) + payload
        }
    }
}
