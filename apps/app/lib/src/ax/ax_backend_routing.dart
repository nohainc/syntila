// Routes API calls between the two Syntila services:
//   - the Cloudflare auth Worker (same origin as the web app, `/api`) owns
//     sign-in, sessions and backend-token issuance;
//   - the VPS backend (`https://api.syntila.app/api`) serves everything else
//     and accepts only short-lived backend tokens.
// Call sites keep building URLs from one `baseUrl`; this client rewrites the
// non-auth ones to the backend and swaps the credential.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Paths (relative to the auth `/api` base) served by the auth Worker.
const _authOwnedPrefixes = <String>['/session', '/auth', '/desktop-auth', '/backend-token', '/dev'];

bool isAuthOwnedApiPath(String path) =>
    _authOwnedPrefixes.any((prefix) => path == prefix || path.startsWith('$prefix/'));

/// Backend API base: `--dart-define=SYNTILA_BACKEND_API_URL=...`, otherwise
/// derived from where the app runs (production web → api.syntila.app).
String defaultBackendApiUrl(String authBaseUrl) {
  const configured = String.fromEnvironment('SYNTILA_BACKEND_API_URL');
  if (configured.isNotEmpty) return configured.replaceFirst(RegExp(r'/$'), '');
  final auth = Uri.base.resolve(authBaseUrl);
  if (auth.host == 'syntila.app' || auth.host.endsWith('.syntila.app')) {
    return 'https://api.syntila.app/api';
  }
  return 'http://localhost:8788/api';
}

class AxBackendToken {
  AxBackendToken(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt;
  bool get fresh => DateTime.now().isBefore(expiresAt.subtract(const Duration(seconds: 60)));
}

/// Caches the backend token and fetches a new one from the auth Worker.
/// `_fetch` returns null when nobody is signed in.
class AxBackendTokenSource {
  AxBackendTokenSource(this._fetch);
  final Future<AxBackendToken?> Function() _fetch;
  AxBackendToken? _current;
  Future<AxBackendToken?>? _inFlight;

  /// The current backend token, or null when signed out (the backend then
  /// answers 401 itself, which the app turns into the sign-in screen).
  Future<String?> token() async {
    final current = _current;
    if (current != null && current.fresh) return current.token;
    final flight = _inFlight ??= _fetch().whenComplete(() => _inFlight = null);
    final next = await flight;
    _current = next;
    return next?.token;
  }

  void clear() {
    _current = null;
  }

  static AxBackendToken parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['token'] is! String) {
      throw const FormatException('Backend token response is malformed');
    }
    final expiresAt = DateTime.tryParse('${decoded['expiresAt']}') ??
        DateTime.now().add(const Duration(minutes: 5));
    return AxBackendToken(decoded['token'] as String, expiresAt);
  }
}

class AxBackendRoutingClient extends http.BaseClient {
  AxBackendRoutingClient({
    required this.inner,
    required String authBaseUrl,
    required String backendBaseUrl,
    required this.tokens,
  })  : authBase = Uri.base.resolve(authBaseUrl.replaceFirst(RegExp(r'/$'), '')),
        backendBase = Uri.parse(backendBaseUrl.replaceFirst(RegExp(r'/$'), ''));

  final http.Client inner;
  final Uri authBase;
  final Uri backendBase;
  final AxBackendTokenSource tokens;

  /// The API path below the auth base, or null when [url] is not an API call.
  String? _apiPath(Uri url) {
    // On the web the auth base is relative (`/api`), so request URLs can be too.
    if (!url.hasScheme) url = Uri.base.resolveUri(url);
    if (url.scheme != authBase.scheme || url.authority != authBase.authority) return null;
    final prefix = authBase.path;
    if (url.path != prefix && !url.path.startsWith('$prefix/')) return null;
    return url.path.substring(prefix.length);
  }

  Uri? backendUrlFor(Uri url) {
    final path = _apiPath(url);
    if (path == null || isAuthOwnedApiPath(path)) return null;
    return backendBase.replace(
      path: '${backendBase.path}$path',
      query: url.hasQuery ? url.query : null,
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final target = backendUrlFor(request.url);
    if (target == null) return inner.send(request);
    final token = await tokens.token();
    // Finalize first: a MultipartRequest sets its content-type (with the
    // boundary) and length only when its body is finalized.
    final body = request.finalize();
    final routed = http.StreamedRequest(request.method, target)
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection
      ..contentLength = request.contentLength;
    // (contentLength above is read after finalize, so multipart sizes are known.)
    request.headers.forEach((name, value) {
      final lower = name.toLowerCase();
      // Auth-Worker credentials never travel to the backend.
      if (lower == 'cookie' || lower == 'authorization' || lower == 'origin') return;
      routed.headers[name] = value;
    });
    if (token != null) routed.headers['authorization'] = 'Bearer $token';
    // Forward the body as it streams; pipe closes the routed sink when done.
    unawaited(body.pipe(routed.sink).catchError((Object _) {}));
    final response = await inner.send(routed);
    if (response.statusCode == 401) tokens.clear();
    return response;
  }

  @override
  void close() => inner.close();
}
