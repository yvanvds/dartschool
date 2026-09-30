// Keeps the tests off the network (#50).
//
// A test that reaches a live Smartschool depends on the network and on
// Smartschool, and may drive the login chain there with made-up credentials.
// A test gives its client a fake `HttpClientAdapter` instead
// (`client.dio.httpClientAdapter = ...`), or talks to a server of its own on
// loopback. forbidRealNetwork() fails a test that still sends a request to
// another host; network_guard_test.dart fails on a test file that does not
// call it.
import 'dart:io';

import 'package:test/test.dart';

/// Refuses every HTTP request of this isolate to a host other than loopback,
/// before it leaves the machine, and fails the test that sent it.
///
/// Call it first in `main()` of every test file (and of every other program
/// under `test/`, such as one a test runs as a separate process). It holds
/// for every `HttpClient` of the isolate that looks its proxy up the default
/// way, such as the one of Dio's default adapter, which a client whose test
/// did not give it a fake adapter sends its requests with: the request fails
/// before its host is looked up or connected to. The test that sent it fails
/// even when the code under test catches that failure, which it may well
/// take for a network error. Requests to `localhost` and to loopback
/// addresses (`127.0.0.1`, `::1`), such as those to an `HttpServer` of the
/// test, go out, straight to this machine.
void forbidRealNetwork() {
  HttpOverrides.global = NoRealNetwork();
}

/// The [HttpOverrides] that [forbidRealNetwork] installs.
///
/// `HttpClient` asks [findProxyFromEnvironment] which proxy to use for each
/// request before it connects anywhere; this answer refuses the request
/// instead when it goes to another machine.
class NoRealNetwork extends HttpOverrides {
  /// Refuses a request to another machine; sends one to this machine
  /// straight to it (`DIRECT`), whatever proxy the environment names
  /// (`HTTP_PROXY`, `NO_PROXY`): a proxy would reach a server of the test,
  /// if at all, only when it runs on this machine too.
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    if (isLoopbackHost(url.host)) return 'DIRECT';
    final error = RealNetworkForbidden(url);
    // Fails the test that sent the request (or, outside a test, the whole
    // test file or program) whatever the code under test does with the error
    // thrown below.
    registerException(error, StackTrace.current);
    throw error;
  }
}

/// Whether [host], the host of a request URL, is this machine: `localhost`
/// or a loopback address. A name is not looked up, so any other name counts
/// as another machine.
bool isLoopbackHost(String host) =>
    host.toLowerCase() == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);

/// The failure of a request that a test sent to another machine.
class RealNetworkForbidden implements Exception {
  /// The URL of the request.
  final Uri url;

  RealNetworkForbidden(this.url);

  @override
  String toString() =>
      'RealNetworkForbidden: a test sent a request to $url. Tests must not '
      'use the network: give the client a fake HttpClientAdapter '
      '(client.dio.httpClientAdapter = ...), or serve the request from a '
      'server of the test on loopback (test/support/no_network.dart, #50).';
}
