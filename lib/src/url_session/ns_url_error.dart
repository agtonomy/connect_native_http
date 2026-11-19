import '../native_http_exception.dart';

/// `NSURLErrorDomain`, the domain URLSession reports its own failures in.
const nsUrlErrorDomain = 'NSURLErrorDomain';

/// `NSURLErrorDomain` codes that URLSession only reports before a connection exists, so the request body never left
/// the device. Timeouts (-1001) and dropped connections (-1005) are absent on purpose: they also happen mid-request.
const _notSentCodes = {
  -1003, // NSURLErrorCannotFindHost
  -1004, // NSURLErrorCannotConnectToHost
  -1006, // NSURLErrorDNSLookupFailed
  -1009, // NSURLErrorNotConnectedToInternet
  -1018, // NSURLErrorInternationalRoamingOff
  -1019, // NSURLErrorCallIsActive
  -1020, // NSURLErrorDataNotAllowed
  -1022, // NSURLErrorAppTransportSecurityRequiresSecureConnection
  -1200, // NSURLErrorSecureConnectionFailed
  -1205, // NSURLErrorClientCertificateRejected
  -1206, // NSURLErrorClientCertificateRequired
};

/// Server-trust failures, which also happen before the request is sent.
const _untrustedCodes = {
  -1201, // NSURLErrorServerCertificateHasBadDate
  -1202, // NSURLErrorServerCertificateUntrusted
  -1203, // NSURLErrorServerCertificateHasUnknownRoot
  -1204, // NSURLErrorServerCertificateNotYetValid
};

/// Classifies a URLSession task error from its `NSError` domain and code.
NativeHttpFailure classifyNsUrlError(String domain, int code) {
  if (domain != nsUrlErrorDomain) {
    return NativeHttpFailure.other;
  }
  if (_untrustedCodes.contains(code)) {
    return NativeHttpFailure.untrusted;
  }
  if (_notSentCodes.contains(code)) {
    return NativeHttpFailure.notSent;
  }
  return NativeHttpFailure.other;
}
