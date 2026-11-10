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

    // Cronet throws from start() on a header it rejects. On the bridge's thread that would have killed the app.
    @Test
    fun aHeaderCronetRejectsFailsTheCallAsNeverSent() {
        val engine = createEngine()
        open(engine, 1, SAY, "application/proto", extraHeaders = listOf(listOf("authorization", "Bearer x\r\ny")))
        val outcome = awaitOutcome(1)
        assertEquals("failed", outcome["type"])
        assertEquals(false, outcome["streamReady"])
        assertSayWorks(engine, 2)
    }

    // Cronet throws on an empty write before the end of the stream.
    @Test
    fun anEmptyWriteIsSkipped() {
        val engine = createEngine()
        open(engine, 1, SAY, "application/proto")
        invoke("write", mapOf("callId" to 1, "data" to ByteArray(0)))
        invoke("write", mapOf("callId" to 1, "data" to sentence("hi")))
        invoke("end", mapOf("callId" to 1))
        assertEquals("done", awaitOutcome(1)["type"])
        assertTrue(received(1).contains("say: hi"))
    }

    @Test
    fun aReadIdleTimeoutFailsAQuietCallAndTheEngineCarriesOn() {
        val engine = createEngine()
        // The timer also runs while the connection is set up, which through the emulator once took longer than the
        // timeout (the TLS handshake was cut off). A call first leaves a connection for the timed one to reuse.
        assertSayWorks(engine, 10)
        open(engine, 1, CONVERSE, "application/connect+proto", readIdleTimeoutMs = 500)
        await(1, "data")
        val start = System.nanoTime()
        val outcome = awaitOutcome(1)
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start)
        assertEquals("failed", outcome["type"])
        assertEquals(-7, outcome["internalErrorCode"])
        assertEquals(true, outcome["streamReady"])
        assertTrue("a 500 ms read-idle timeout took $elapsedMs ms", elapsedMs < 2000)
        // Cronet's own cancel follows, and changes nothing.
        Thread.sleep(200)
        assertEquals(listOf(outcome), events.filter { it["callId"] == 1 && it["type"] in OUTCOMES } + drained(1))

        // New calls go to a fresh CronetEngine.
        assertSayWorks(engine, 2)
    }

    @Test
    fun receivingResetsTheReadIdleTimer() {
        val engine = createEngine()
        assertSayWorks(engine, 10)
        open(engine, 1, CONVERSE, "application/connect+proto", readIdleTimeoutMs = 1000)
        await(1, "data")
        // Twice the timeout in all, 600 ms between replies.
        for (i in 0 until 3) {
            Thread.sleep(600)
            invoke("write", mapOf("callId" to 1, "data" to envelope(sentence("ping $i"))))
            awaitReceived(1, "echo: ping $i")
        }
        invoke("write", mapOf("callId" to 1, "data" to envelope(sentence("bye"))))
        assertEquals("done", awaitOutcome(1)["type"])
    }

    @Test
    fun malformedArgumentsAreRefusedInsteadOfCrashing() {
        val engine = createEngine()
        val malformed: List<Pair<String, Map<String, Any?>>> = listOf(
            "open" to emptyMap<String, Any?>(),
            "open" to mapOf("engineId" to "1", "callId" to 1),
            "write" to mapOf("callId" to 1, "data" to "not bytes"),
            "end" to mapOf("callId" to null),
            "cancel" to emptyMap<String, Any?>(),
            "shutdownEngine" to mapOf("engineId" to 1.5),
            "open" to openArguments(engine, 1, SAY, "application/proto") + ("readIdleTimeoutMs" to 0),
            "open" to openArguments(engine, 1, SAY, "application/proto") + ("readIdleTimeoutMs" to "soon"),
        )
        for ((method, arguments) in malformed) {
            val reply = reply(method, arguments)
            assertTrue("$method $arguments: $reply", reply is CronetBridge.Reply.Error)
        }
        val badHints = reply("createEngine", mapOf("quicHints" to listOf(listOf("localhost"))))
        assertTrue("createEngine with a bad hint: $badHints", badHints is CronetBridge.Reply.Error)
        assertSayWorks(engine, 1)
    }

    private fun assertSayWorks(engine: Int, callId: Int) {
        open(engine, callId, SAY, "application/proto")
        invoke("write", mapOf("callId" to callId, "data" to sentence("again")))
        invoke("end", mapOf("callId" to callId))
        assertEquals("done", awaitOutcome(callId)["type"])
        assertTrue(received(callId).contains("say: again"))
    }

    private fun reply(method: String, arguments: Map<String, Any?>): CronetBridge.Reply {
        val result = CompletableFuture<CronetBridge.Reply>()
        bridge.handle(method, arguments) { result.complete(it) }
        return result.get(3, TimeUnit.SECONDS)
    }

    private fun invoke(method: String, arguments: Map<String, Any?>): Any? =
        when (val reply = reply(method, arguments)) {
            is CronetBridge.Reply.Success -> reply.value
            else -> throw AssertionError("$method: $reply")
        }

    private fun createEngine(): Int = invoke("createEngine", mapOf("quicHints" to emptyList<Any>())) as Int

    private fun open(
        engine: Int,
        callId: Int,
        path: String,
        contentType: String,
        extraHeaders: List<List<String>> = emptyList(),
        readIdleTimeoutMs: Int? = null,
    ) {
        invoke("open", openArguments(engine, callId, path, contentType, extraHeaders) +
            ("readIdleTimeoutMs" to readIdleTimeoutMs))
    }

    private fun openArguments(
        engine: Int,
        callId: Int,
        path: String,
        contentType: String,
        extraHeaders: List<List<String>> = emptyList(),
    ): Map<String, Any?> = mapOf(
        "engineId" to engine,
        "callId" to callId,
        "url" to serverUrl + path,
        "method" to "POST",
        "headers" to listOf(listOf("content-type", contentType), listOf("connect-protocol-version", "1")) +
            extraHeaders,
    )

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

    private fun awaitOutcome(callId: Int) = await(callId, *OUTCOMES.toTypedArray())

    // Outcomes for [callId] that arrived since the last wait.
    private fun drained(callId: Int): List<Map<String, Any?>> {
        val more = mutableListOf<Map<String, Any?>>()
        incoming.drainTo(more)
        events.addAll(more)
        return more.filter { it["callId"] == callId && it["type"] in OUTCOMES }
    }

    private fun awaitReceived(callId: Int, text: String) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (!received(callId).contains(text)) {
            val left = deadline - System.nanoTime()
            val next = if (left > 0) incoming.poll(left, TimeUnit.NANOSECONDS) else null
            if (next == null) {
                fail("timed out waiting for \"$text\" on call $callId; events: $events")
            }
            events.add(next!!)
        }
    }

    // The response body so far, as text; Connect framing and protobuf leave the sentences readable.
    private fun received(callId: Int): String = events
        .filter { it["callId"] == callId && it["type"] == "data" }
        .joinToString("") { String(it["data"] as ByteArray, Charsets.UTF_8) }

    private companion object {
        const val CONVERSE = "/connectrpc.eliza.v1.ElizaService/Converse"
        const val SAY = "/connectrpc.eliza.v1.ElizaService/Say"
        val OUTCOMES = setOf("done", "failed", "canceled")

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
