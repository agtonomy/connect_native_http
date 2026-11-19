# connect_native_http

connect-dart `HttpClient`s that run on the platform's own HTTP stack: URLSession on iOS, and Cronet on Android. The platform negotiates HTTP/3 (QUIC) or HTTP/2 itself, falls back to HTTP/2 over TCP when QUIC fails, and
carries full-duplex streams, so all four Connect RPC kinds work, bidi included.

On iOS 27 and later, `NativeHttpConfig.enableDatagrams` swaps URLSession for
[swift-nio-http3](https://github.com/apple/swift-nio-http3), which advertises HTTP/3 datagram support to servers and
opens datagram sessions. See "HTTP datagrams (iOS 27+, opt-in)".

Status: experimental.

## Use

Pair it with the **Connect protocol**. Neither platform stack exposes HTTP trailers to the app, and the gRPC protocol
carries its status in trailers.

```dart
final origin = Uri.parse('https://example.com');
final native = await NativeHttpClient.create(
  NativeHttpConfig(
    http3Origins: {origin},
    onResponse: (info) => log('${info.url} over ${info.protocol}'),
  ),
);
final transport = connect_protocol.Transport(
  baseUrl: origin.toString(),
  codec: const ProtoCodec(),
  httpClient: native!.httpClient,
);
```

`NativeHttpClient.create` returns `null` on platforms without a native client.

**List every origin that serves HTTP/3 in `http3Origins`.** Without it, URLSession learns HTTP/3 from `Alt-Svc` but
only uses it on a new connection. A session that stays busy keeps reusing its first HTTP/2 connection indefinitely.

A failed request throws a `ConnectException` with code `unavailable`. Its `cause` is a `NativeHttpException` that says
whether the request provably never left the device (`requestNeverSent`), which makes re-sending it safe:

| Failure | iOS (`NSURLErrorDomain` code) | Android (Cronet) |
|---|---|---|
| `notSent` | Cannot find or connect to host, DNS failure, offline, TLS handshake failure | Failed before `onStreamReady`; the bridge writes no request body before it |
| `untrusted` | -1201 to -1204, certificate rejected | `net::` certificate errors -200 to -299, or a pin mismatch (-150) |
| `other` | Everything else, timeouts and dropped connections included | Any failure after `onStreamReady` |

No exception in the package should crash the app or leave a call hanging. Failures end the one call they concern:

- **A request the platform stack rejects** fails that call as `notSent`. For example, Cronet throws on a header value
  with a line break.
- **A method call the plugin can't parse** gets an error reply instead of a force-unwrap (iOS) or an uncaught
  exception (Android). Uncaught exceptions on the Android bridge's thread would otherwise kill the process.
- **A malformed event** fails its own call with `internal`.
- **An exception from `onResponse`** goes to `FlutterError.onError`, like other errors that have no caller. The call
  carries on.

`NativeHttpClient.create` throws a `PlatformException` if the platform can't create a client, for example when Cronet's
native library fails to load, or when `enableDatagrams` is set before iOS 27 (code `unsupported`).

### Read-idle timeout

A client can fail each of its calls once the call has received nothing from the server for a set time. Apart from
deadlines, this is the only way either client notices a dead HTTP/2 connection (see "Dead connections"):

```dart
NativeHttpConfig(readIdleTimeout: const Duration(seconds: 30));
```

It applies to every call on the client. For per-call bounds use deadlines (connect-dart's `TimeoutSignal` or
`DeadlineSignal`), which can also move the client off a dead connection (see "Calls that run out of time"). Streams
that go quiet for long need a client without a read-idle timeout, or periodic messages.

- **What it measures:** time since the call last received anything: headers, a body chunk or trailers. The timer starts
  when the call does, so it also bounds the wait for the response headers. A unary call the server holds longer than
  the timeout fails, and so does a stream that goes quiet for longer.
- **iOS:** `URLRequest.timeoutInterval`. URLSession treats a request's 60 s as unset and uses the session's value
  instead, so the bridge sends 60.001 s for a 60 s timeout.
- **Android:** a timer in the bridge.
- **The failure:** `unavailable`, with a `NativeHttpException` whose `platformCode` is `NSURLErrorTimedOut` (-1001) on
  iOS or `net::ERR_TIMED_OUT` (-7) on Android. On Android a timeout before `onStreamReady` is `notSent`, as with any
  other failure there.
- **The connection:** see "Calls that run out of time" below.

### Calls that run out of time

A call that hits its read-idle timeout, or its deadline with `evictOnDeadline`, may be stuck on a dead connection.
The client keeps new calls off such a connection, so they don't wait on it too.

```dart
NativeHttpConfig(
  readIdleTimeout: const Duration(seconds: 30), // optional
  deadlineStep: const Duration(seconds: 1),
  evictOnDeadline: true,
);
```

- **Read-idle timeout:** the connection counts as dead if nothing has arrived from the call's origin (host and port),
  on any call, since the call last received anything. If something has, the connection is alive and only that call
  was slow, so nothing changes.
- **Deadline, with `evictOnDeadline`:** the connection counts as dead under the same check as a read-idle timeout.
  Both options are off by default; use them together:
  - **`deadlineStep`** takes a step off the deadline each hop passes on. connect-dart sends the call's deadline in
    `connect-timeout-ms`, and the client sends the server that much less, or half the deadline when that is less, so
    the server never gets zero. A reachable server then times the call out first and answers `deadline_exceeded`
    before the client's own deadline fires. So when the client's deadline fires, the server's answer never came.
    Servers that call further services should take their own step off the deadline they pass on.
  - **Without a step,** the server enforces the same deadline, but its clock starts later. On a healthy connection the
    client's deadline usually fires first, and with `evictOnDeadline` alone the connection would be evicted for
    nothing.
- **A dead connection is evicted.** Neither stack can close a single connection, so the client moves its new calls to
  a fresh `URLSession` or `CronetEngine`, which dials its own connections. Calls already on the old one are not
  canceled. They finish there, and it is released after the last one ends. Several calls that run out of time on the
  same connection evict it once.

## HTTP datagrams (iOS 27+, opt-in)

URLSession has no HTTP datagram API. With `NativeHttpConfig(enableDatagrams: true)`, the iOS client runs on
swift-nio-http3 and [swift-nio-quic](https://github.com/apple/swift-nio-quic) instead, and every connection advertises
datagram support: QUIC's `max_datagram_frame_size` transport parameter (RFC 9221) and HTTP/3's `SETTINGS_H3_DATAGRAM`
(RFC 9297). Without the option, neither is sent and nothing changes. Android ignores it, since Cronet has no datagram
API either.

The swift-nio-http3 client carries Connect calls too, through the same `httpClient`, with these differences from
URLSession:

- **iOS 27.** swift-nio-http3 and swift-nio-quic mark their APIs `@available(iOS 27, macOS 27, …)`. On older iOS,
  `NativeHttpClient.create` throws a `PlatformException` with code `unsupported`.
- **HTTP/3 only.** There is no HTTP/2 fallback, so where UDP is blocked every call fails as `notSent`.
  `http3Origins` is unused.
- **Failures.** A rejected server certificate fails as `notSent` (`NSURLErrorSecureConnectionFailed`, -1200), not
  `untrusted`: the QUIC stack doesn't say why a TLS handshake failed. Read-idle timeouts (-1001) and dropped
  connections (-1005) are `other`, as with URLSession.
- **Settings.** `quicIdleTimeout` applies (any positive duration, rounded up to the millisecond), and so does
  `connectTimeout`: 10 s by default, it bounds how long a new connection may take to resolve its host and finish the
  QUIC handshake, after which its calls fail as `notSent` (-1004). QUIC ignores the ICMP error a closed UDP port
  answers with, so without it a server that isn't there would hold calls until their deadlines.
- **Negotiated protocol.** `NativeHttpResponseInfo.protocol` is `h3`.
- **Ending bidi calls.** The bridge ends a call on the response's end, so the Connect end-stream detector isn't needed.
  A server that has its answer typically also stops reading the request (`STOP_SENDING`); swift-nio-http3 sets
  swift-nio-quic's `halfCloseOnStopSending` on every request stream
  ([apple/swift-nio-http3#104](https://github.com/apple/swift-nio-http3/pull/104)), so that closes only the request
  side.
- **No write backpressure.** A write completes once swift-nio-quic has buffered it, so a server that stops reading
  leaves the rest in memory.
- **Pre-1.0 dependencies.** swift-nio-http3 has no release yet and is pinned to a commit in
  `ios/connect_native_http/Package.swift`; swift-nio-quic is taken `.upToNextMinor(from: "0.6.0")`. Both say their APIs
  aren't stable. Moving the pin is a deliberate change to test.
- **A QUIC stack in Swift, on BSD sockets.** swift-nio-quic implements QUIC itself (swift-network-evolution, SwiftTLS)
  on NIO's POSIX sockets, not Network.framework. System proxy settings and Wi-Fi Assist don't apply, and moving between
  networks has not been tested; expect a dropped connection, which the next call redials.
- **Logging.** swift-nio-quic logs through swift-log. With no logging backend set up, swift-log prints to stdout,
  which includes notices for every stream reset and TLS failure. An app can call `LoggingSystem.bootstrap` to route or
  silence it.

**Every app needs Xcode 27 (Swift 6.4) to build the plugin, with or without the option:** swift-nio-http3's manifest
needs Swift tools 6.4, and Swift Package Manager resolves every dependency of a package. The plugin's minimum stays iOS
15.

### Datagram sessions

A datagram session is an Extended CONNECT request (RFC 9220) whose stream stays open. Both sides can send HTTP
datagrams (RFC 9297) on it: unreliable, unordered messages that each fit in one QUIC packet. It shares its QUIC
connection with the client's RPCs to the same origin.

```dart
final native = await NativeHttpClient.create(const NativeHttpConfig(enableDatagrams: true));
final session = await native!.openDatagramSession(
  Uri.parse('https://example.com/telemetry'),
  protocol: 'my-datagrams', // the :protocol pseudo-header; the server routes on it
  headers: {'authorization': 'Bearer …'},
);
session.datagrams.listen((datagram) => handle(datagram));
await session.send(Uint8List.fromList(payload));
// …
await session.close(); // finishes the request stream; `done` completes when the server ends the session
await session.done;
```

- **Opening** throws `UnsupportedError` on a client without `enableDatagrams`, and on Android. Otherwise it waits for
  the server's HTTP/3 SETTINGS. If the server doesn't offer both `SETTINGS_H3_DATAGRAM` and
  `SETTINGS_ENABLE_CONNECT_PROTOCOL`, it fails with a `ConnectException` (`unavailable`, `NativeHttpException` cause)
  without sending anything. A server that answers with a status other than 2xx gets `DatagramSessionRejected`.
- **`send`** completes once QUIC has taken the datagram, which says nothing about delivery. It throws a
  `NativeHttpException` if the session has ended or the datagram is too large for the connection.
- **`datagrams`** buffers what arrives while nothing listens, and ends with the session, with the session's error if
  it failed. **`data`** carries anything the server writes on the stream itself, such as capsules.
- **Ending:** `close()` finishes the request stream and the server is expected to end its side; `cancel()` resets the
  stream at once. The connection's QUIC idle timeout and the client's `readIdleTimeout` apply as they do to calls.
  Datagrams count as received for the read-idle timeout.

The test server's `/datagrams/echo` (`test_server/datagrams.go`) shows the server side in quic-go: set
`http3.Server.EnableDatagrams`, accept the CONNECT with `WriteHeader(200)`, take the stream over with
`http3.HTTPStreamer`, and use `ReceiveDatagram` and `SendDatagram`.

## Server and infrastructure requirements

The clients only reach HTTP/3, and only keep bidi working, if the server side meets these requirements. Each was
found or verified with the tests in this package.

**Protocol**

- **The server speaks the Connect protocol.** connect-go serves it on the same handler as gRPC, with no
  configuration. Clients send `application/proto` (unary) and `application/connect+proto` (streams).
- **The server ends every Connect stream with an end-stream message.** connect-go always does. On iOS the client
  relies on it to end a bidi call the server finishes first, because URLSession over HTTP/3 does not complete a task
  while the request body is open.

**The HTTP/2 path (TCP, and the fallback when UDP is blocked)**

- **Bidi needs HTTP/2 from end to end.** Every proxy or load balancer on the way must forward HTTP/2 to the server.
  An AWS ALB HTTP/1.1 target group breaks bidi. HTTP/2 and gRPC target groups carry it, and AWS documents that an
  HTTP/2 POST to a gRPC target group succeeds
  ([target group protocol version](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-target-groups.html)).
- **Listener rules must route the Connect content types above to that target group.** A rule that matches only
  `application/grpc` sends Connect requests elsewhere.
- **No dead-connection detection apart from the read-idle timeout.** Neither stack sends HTTP/2 pings the caller
  controls, and server pings stop at any load balancer that terminates HTTP/2. A read-idle timeout notices a dead
  connection, but only if it is shorter than a stream's quiet periods. Idle timeouts on the path must exceed a
  stream's longest quiet period, or the stream must carry periodic messages. See "QUIC idle timeout vs HTTP/2
  keepalive pings".

**The HTTP/3 endpoint**

- **QUIC version 1 on UDP.** For the client's own fallback to work, the endpoint should use the same host and port
  as HTTP/2 over TCP. For example, an AWS NLB `TCP_QUIC` listener, which needs TCP and UDP on the same target port.
- **The certificate must chain to a public root.** Cronet refuses QUIC otherwise (`ERR_QUIC_CERT_ROOT_NOT_KNOWN`,
  `net/quic/crypto/proof_verifier_chromium.cc` in Chromium) and has no override. With a private CA, Android always
  stays on HTTP/2. ACM certificates (Amazon roots) qualify.
- **Clients must dial the HTTP/3 host directly and list it in `http3Origins`.** Don't rely on `Alt-Svc` to move
  them:
  - URLSession only acts on `Alt-Svc` for a new connection, and a busy session never opens one.
  - An `Alt-Svc` that names a different host is followed only if the certificate also covers that host.
- **QUIC idle timeout about 6–10 s, with pings every 2–3 s** (in quic-go: `MaxIdleTimeout`, `KeepAlivePeriod`).
  Keep the ping interval at most half the idle timeout.
  - The idle timeout sets how fast clients notice a dead path, and it is the only control iOS has. See "Dead
    connections" and "QUIC idle timeout vs HTTP/2 keepalive pings".
  - The pings keep healthy connections open, and they keep UDP flows alive through NATs and load balancers. An AWS
    NLB, for example, drops a UDP flow after 120 s of silence.
- **Send `Alt-Svc` on HTTP/2 responses** (`h3=":<port>"`) for clients that weren't configured with the origin.

**Observability**

- **Count requests by protocol on the server.** In Go that's `http.Request.Proto`. iOS doesn't report the protocol
  it negotiated, so the server is the only place to see how often clients fall back to HTTP/2. The test server echoes
  it in `X-Proto`.

## Platform behavior

| | iOS | Android |
|---|---|---|
| Stack | URLSession, through the Swift plugin in `ios/` (Swift Package Manager only); swift-nio-http3 with `enableDatagrams` (see "HTTP datagrams") | Cronet `BidirectionalStream`, through the Kotlin plugin in `android/` |
| HTTP/3 | From the first request for `http3Origins`; otherwise learned from `Alt-Svc` | Same |
| Certificates | System trust store | System trust store; QUIC only with certificates that chain to a public root |
| Negotiated protocol | Not exposed (`NativeHttpResponseInfo.protocol` is `null`) | `h2` or `quic/1+spdy/3` (HTTP/3) |
| QUIC idle timeout | No setting; the server's advertised value applies | `NativeHttpConfig.quicIdleTimeout`, in whole seconds |
| Read-idle timeout | `NativeHttpConfig.readIdleTimeout`, through `URLRequest.timeoutInterval`. Without one, a task that receives nothing for a day fails | `NativeHttpConfig.readIdleTimeout`, through a timer in the bridge. None without one |
| HTTP/1.1 and `http://` | Left to URLSession; not tested | Not carried: Cronet's `BidirectionalStream` fails a call unless HTTP/2 or HTTP/3 is negotiated (`net::ERR_FAILED`), and takes only `https://` URLs (`net::ERR_DISALLOWED_URL_SCHEME`) |
| Redirects | Followed only for requests without a body; otherwise the 3xx response is returned, since a streamed body can't be resent | Not tested |

### Dead connections

Over HTTP/3 a dead network path is detected by QUIC's idle timeout. QUIC uses the smaller of the two endpoints'
values (RFC 9000 §10.1), and the stack fails every call on the connection when it fires. The next call dials a fresh
connection on its own, so nothing has to reset anything. Two settings make this fast without closing healthy
connections:

- **Server: a short idle timeout and frequent pings.** For example `MaxIdleTimeout` 6–10 s and `KeepAlivePeriod`
  2–3 s. The pings keep a quiet but healthy connection alive. The idle timeout is what iOS gets, since URLSession has
  no setting of its own.
- **Android: optionally `quicIdleTimeout`.** Detection then doesn't depend on the server's value.

The integration tests measure both:

- With the server advertising 3 s, a frozen path failed an open iOS stream after 2.98 s.
- With pings every second, a quiet stream outlived twice the idle timeout.
- On Android, `quicIdleTimeout: 3s` ended a quiet stream within the bound, and the same stream without the setting
  was still open after 8 s.

Clients may enforce a floor on the peer's value. quic-go's client raises anything under 5 s to 5 s
(`protocol.MinRemoteIdleTimeout`), so measure any other client before relying on a short server value.

None of this works on the **HTTP/2 fallback** used where UDP is blocked. Neither stack exposes HTTP/2 pings, so a TCP
connection that dies without the interface going down goes unnoticed until a call on it runs out of time: a read-idle
timeout, or a deadline with `evictOnDeadline` (see "Calls that run out of time"). The integration tests check this:

- Over a frozen HTTP/2 connection nothing arrives for 3 s, and a new call on the same client waits on it until its
  deadline. With `evictOnDeadline`, the call after that goes out on a new connection.
- With a read-idle timeout, the call fails within the timeout, and the client's next call goes out on a new
  connection.
- With `deadlineStep`, the server answers a deadline with `deadline_exceeded` a step before the client's own
  deadline, and the client stays on the same connection.

### QUIC idle timeout vs HTTP/2 keepalive pings

The two mechanisms differ in who notices a dead path, which is why server settings protect the phone over HTTP/3 but
not over HTTP/2.

| | HTTP/3: QUIC idle timeout | HTTP/2: PING frames |
|---|---|---|
| Who enforces it | Both endpoints. Each closes the connection once it has received nothing for the idle timeout. | Only the endpoint that sends PINGs and times out waiting for the ACK |
| Who sets it | Both advertise a value; the connection uses the smaller (RFC 9000 §10.1) | Each side sets its own pings |
| Can a server setting make the client notice? | Yes. A short server value becomes the client's timeout, and the server's pings stop arriving once the path dies. | No. A server that detects a dead connection can't tell the client, because nothing gets through. |
| Through a load balancer | NLB QUIC passthrough is end to end, so the client sees the server's pings | An ALB ends HTTP/2 on each side, so the server's pings stop at the ALB. AWS doesn't document the ALB pinging clients, and nothing here relies on it. |
| Client control here | Android: `quicIdleTimeout`. iOS: none. Both: a read-idle timeout, and `evictOnDeadline`. | No pings: neither URLSession nor Cronet exposes HTTP/2 ping settings. Both: a read-idle timeout, and `evictOnDeadline`. |
| What a client that sends its own pings gets, for comparison | — | `package:http2` with 3 s pings and a 3 s timeout notices in about 6 s |

So for servers:

- **HTTP/3:** set both `MaxIdleTimeout` and `KeepAlivePeriod`, with the ping interval at most half the idle timeout.
  quic-go caps it there anyway (`keepAliveInterval = min(KeepAlivePeriod, idleTimeout/2)` in `connection.go`).
  - Too long an idle timeout delays detection.
  - Too few pings closes quiet connections that are healthy.
- **HTTP/2:** server pings, such as `http.HTTP2Config.SendPingTimeout` in Go, only clean up the server's side.
  - On the client, a silently dead connection lasts until a call deadline, a read-idle timeout, an
    application-level heartbeat, or TCP's own retransmission timeout, which takes minutes.
  - Every idle timeout on the path, such as a load balancer's, must exceed the longest quiet period of a stream, or
    the stream must carry periodic messages.

### When the server ends a bidi call first

Neither platform finishes a stream on its own while the client still has its request side open:

- **Cronet** reports `onSucceeded` only once both sides are closed. The bridge ends the call as soon as it has read
  the whole response, and closes the request side itself.
- **URLSession over HTTP/3** never completes the task while the request body is open. This holds even after the
  server sends `STOP_SENDING`, and Apple's own bound streams behave the same way. Over HTTP/2 the task completes.
  For Connect streaming responses (`application/connect+…`), the client therefore watches for the end-stream message
  and ends the call when it arrives.

### Design notes

- Both platforms use a small native plugin behind the same method and event channel protocol (the swift-nio-http3
  bridge adds the datagram methods and events), and one Dart adapter
  (`lib/src/channel/`) turns it into a connect-dart `HttpClient`. The package depends only on `connectrpc` and Flutter,
  so it can't conflict with an app over shared native-interop packages.
- `package:cupertino_http` isn't used: it builds its URLSession delegate in Dart through `package:objective_c`, which
  every package in an app must share. `objective_c` 9.6.3, for example, fails every session creation in iOS 18 debug
  builds.
- Cronet is bundled (`org.chromium.net:cronet-embedded`), not Google Play services Cronet. Every device runs the same
  version, and devices without Play services work. It costs about 6.5 MB uncompressed on arm64.
- `package:cronet_http` can't do this job: it uses Cronet's `UrlRequest`, which reads the whole request body before
  sending it.

## Tests

- **`test/`:** host unit tests, runnable on Linux CI. They cover error classification, Connect end-stream detection,
  URLSession response headers, which client `NativeHttpClient.create` picks for each platform and `enableDatagrams`,
  and the shared channel adapter and datagram sessions against fake plugins.
- **`test_server/`:** a Go server for `connectrpc.eliza.v1.ElizaService` over HTTP/2 and HTTP/3, scripted for tests
  (see `eliza.go`).
  - `-max-idle` and `-keepalive` set its QUIC idle timeout and ping interval.
  - `-admin-addr` serves an endpoint that simulates dead paths:
    - `POST /freeze?for=10s` drops all its UDP traffic, so every HTTP/3 connection.
    - `POST /freeze?for=10s&path=tcp` black-holes the TCP connections open at that moment, so the HTTP/2 connections
      clients already have. It drops what they send and what the server writes, then closes them. Connections opened
      later work, so a client that dials again gets through.
    - `POST /unfreeze` ends both.
  - `/datagrams/echo` accepts Extended CONNECT with `:protocol` `datagram-echo` and echoes every HTTP datagram. A
    datagram `close` ends the session from the server's side.
  - `GET /client-settings`, over HTTP/3, answers with the datagram support the client advertised, as JSON:
    `{"h3Datagram": …, "quicDatagrams": …}`.
  - Its own tests (`go test ./...`) check it over HTTP/3, including the idle timeout, pings, freezing, the datagram
    echo and `/client-settings`, and check the TCP freeze over HTTP/2.
  - It creates a CA in `test_server/certs/` on first start and reuses it, so a device only has to trust it once.
  - With `QLOGDIR` set, it writes a qlog trace of each QUIC connection there, which shows the server's side of a
    handshake.
  - `test_server/generate.sh` regenerates its stubs and the example's Dart client.
- **`example/integration_test/eliza_test.dart`:** run on a booted simulator or emulator. The script also starts the
  server:

  ```bash
  ./run_integration_tests.sh ios <simulator udid>
  ./run_integration_tests.sh android emulator-5554
  ./run_integration_tests.sh ios <udid> --plain-name bidi   # extra arguments go to `flutter test`
  SUITES=native ./run_integration_tests.sh ios <udid>       # only the native tests; SUITES=dart for only Dart
  FLUTTER=flutter ./run_integration_tests.sh ios <udid>     # the flutter on PATH instead of `fvm flutter`
  ```

  Output also goes to `build/integration_test_<platform>_<suites>.log`.

  It covers unary calls, errors, deadlines, server streaming, and full-duplex bidi where the server speaks first and
  finishes first. It also checks the failure classes (`notSent`, `untrusted`) and the negotiated protocol: HTTP/3 on
  iOS, and HTTP/2 on Android, since the server's private CA keeps Cronet off QUIC. On iOS a fresh client's first call,
  before any Alt-Svc, must reach HTTP/3 within a few fresh clients. A loaded simulator sometimes lets TCP win
  URLSession's race even locally, so a single fallback is logged rather than failed.

  Three cases cover `enableDatagrams`: a default client opens no datagram sessions; with the option, calls go over
  HTTP/3 (`h3`) and the server sees both datagram settings from the client; and a datagram session echoes datagrams.
  On Android the option leaves datagram sessions unsupported.

  The script starts the server with a 3 s idle timeout and 1 s pings. Over HTTP/3 (iOS) the tests also check two
  things: a quiet stream outlives the idle timeout, and a frozen path fails an open stream within it.

  The read-idle timeout is tested over HTTP/2 on both platforms. On iOS each of these cases freezes the server's UDP
  first, so URLSession falls back to TCP as it would where UDP is blocked. The server reports each call's client
  address in `X-Remote-Addr`, which shows whether two calls shared a connection. The cases check five things:
  - A quiet stream fails at its timeout.
  - A stream that keeps receiving outlives its timeout.
  - A frozen connection draws no error, and new calls go to it until one hits its deadline. With `evictOnDeadline`,
    the call after that is on a new connection.
  - With a read-idle timeout, the call fails and the client's next call is on a new connection.
  - With `deadlineStep`, the server answers a deadline a step before the client's, and the client stays on the same
    connection.
- **Native bridge tests:** the same script runs them after the Dart tests, against the same server. Each platform's
  bridge (`URLSessionBridge`, `HTTP3Bridge`, `CronetBridge`) has no Flutter dependency, and the tests call it directly, for behavior
  Dart can't reach:
  - **iOS (`ios/connect_native_http/Tests`, XCTest):** a write stuck on a full buffer returns once the call is
    canceled or its connection fails; a redirect of a request with a body is returned, not followed; shutting a
    session down lets its calls finish and refuses new ones; a read-idle timeout fails a quiet call with
    `NSURLErrorTimedOut`, and the engine's next call works; a call canceled at its deadline ends at once, and the
    engine's next call works.

    `HTTP3Bridge`'s tests cover the same ground over HTTP/3, plus: unary calls share one connection; a call ends with
    its response while its request side is still open; a certificate from another CA fails the handshake; the QUIC
    idle timeout fails a call on a frozen path. An engine created without `datagrams` advertises no datagram support
    (checked through `/client-settings`) and refuses datagram sessions without sending them; one created with it
    advertises both. Datagram sessions echo datagrams, may send before the server answers, end when the server ends
    them, share a connection with calls and other sessions, and refuse an oversized datagram without ending.
    `HTTP3Bridge` builds without Apple's SDKs, so CI also runs its tests on Linux in the `swift:6.4.2` image.

    The script runs them on the simulator. For a quick loop on the Mac, against a running test server:

    ```bash
    cd ios/connect_native_http && CONNECT_NATIVE_HTTP_CORE_ONLY=1 SERVER_URL=https://localhost:8443 \
      SERVER_CA=../../test_server/certs/ca.der swift test
    ```

  - **Android (`android/src/androidTest`, instrumented):** writes sent before Cronet is ready go out once it is; a
    write after the server finished the call is dropped instead of crashing; shutting an engine down lets its calls
    finish and refuses new ones; a header Cronet rejects fails its call as never sent; an empty write is skipped; a
    read-idle timeout fails a quiet call with -7, once, and the engine's next call works; data arriving resets the
    timer; a call canceled at its deadline ends at once, and the engine's next call works.
  - Both platforms' suites also check that malformed method calls get an error reply and leave the bridge working.
- **`example/integration_test/public_server_test.dart`:** HTTP/3 on Android against a server with a public
  certificate. It also checks that `quicIdleTimeout` ends a quiet connection, against a control without it. It is
  opt-in because it needs the internet:

  ```bash
  cd example && fvm flutter test integration_test/public_server_test.dart -d emulator-5554 \
    --dart-define=PUBLIC_ELIZA_URL=https://demo.connectrpc.com
  ```
