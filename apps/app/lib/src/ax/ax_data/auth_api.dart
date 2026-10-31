part of '../ax_data.dart';

mixin _AuthApi on _AxApiClientCore {
  Future<AxAccountPlan> loadAccountPlan() async =>
      AxAccountPlan.fromJson(await _getJson(Uri.parse('$baseUrl/me/plan')));

  @override
  Future<AxSession> loadSession() async {
    final response =
        await client.get(Uri.parse('$baseUrl/session'), headers: _headers());
    if (response.statusCode == 401) {
      _bindReadUser(null);
      return const AxSession(authenticated: false);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Session lookup failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final session =
        AxSession.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    _bindReadUser(session.authenticated ? session.viewer?.id : null);
    return session;
  }

  @override
  Future<List<int>?> loadAvatar({required String url}) async {
    final supplied = Uri.parse(url);
    // Private avatar URLs may carry the Cloud origin behind a web proxy.
    // Fetch through the same API origin as the authenticated session.
    final privateAvatar = supplied.path.startsWith('/api/users/') &&
        supplied.path.endsWith('/avatar');
    final target = privateAvatar
        ? Uri.parse('$baseUrl/').resolve(
            'users/${supplied.path.split('/')[3]}/avatar${supplied.hasQuery ? '?${supplied.query}' : ''}')
        : supplied;
    final response = await client.get(target, headers: {
      ..._headers(),
      'accept': 'image/*',
    });
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Avatar lookup failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    return response.bodyBytes;
  }

  @override
  Future<void> updateDisplayName({required String displayName}) =>
      _postAuth('/auth/update-user', {'name': displayName});

  @override
  Future<AxEmailChangeStep> requestEmailChangeCode(
          {required String newEmail}) async =>
      AxEmailChangeStep.fromJson(await _postAuthJson(
          '/auth/change-email/send-code', {'newEmail': newEmail}));

  @override
  Future<AxEmailChangeStep> verifyNewEmailCode({required String code}) async =>
      AxEmailChangeStep.fromJson(
          await _postAuthJson('/auth/change-email/verify-new', {'code': code}));

  @override
  Future<String> confirmEmailChange({required String code}) async {
    final body =
        await _postAuthJson('/auth/change-email/confirm', {'code': code});
    final email = body['email'];
    if (email is! String || email.isEmpty) {
      throw const AxApiException('Email change response is malformed');
    }
    return email;
  }

  Future<Map<String, dynamic>> _postAuthJson(
      String path, Map<String, dynamic> body) async {
    final response = await client.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(body),
    );
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on Object {
      // Non-JSON responses fall back to the status-based message.
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map && decoded['message'] is String
          ? decoded['message'] as String
          : decoded is Map && decoded['error'] is String
              ? decoded['error'] as String
              : 'Request failed (${response.statusCode})';
      throw AxApiException(message, statusCode: response.statusCode);
    }
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : const <String, dynamic>{};
  }

  @override
  Future<void> logout() async {
    clearConditionalReads();
    final response = await client.post(Uri.parse('$baseUrl/auth/sign-out'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode(const <String, dynamic>{}));
    clearConditionalReads();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Logout failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    sessionToken = null;
  }

  @override
  Future<void> deleteAccount({required String confirmEmail}) async {
    await _postAuth('/auth/delete-user', {'confirmEmail': confirmEmail});
    clearConditionalReads();
    sessionToken = null;
  }

  @override
  Future<String> uploadAvatar({
    required List<int> thumbnailBytes,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final upload =
        http.MultipartRequest('PUT', Uri.parse('$baseUrl/profile/avatar'))
          ..headers.addAll(_headers())
          ..files.add(http.MultipartFile.fromBytes('original', bytes,
              filename: 'original', contentType: MediaType.parse(mediaType)))
          ..files.add(http.MultipartFile.fromBytes('thumbnail', thumbnailBytes,
              filename: 'thumbnail.png',
              contentType: MediaType('image', 'png')));
    upload.headers.remove('content-type');
    final response = await http.Response.fromStream(await client.send(upload));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Avatar upload failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } on Object {
        // Keep the status-based message for non-JSON responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    final url = decoded is Map ? decoded['avatarUrl'] : null;
    if (url is! String || url.isEmpty) {
      throw const AxApiException('Avatar upload response is malformed');
    }
    return url;
  }

  Future<void> _postAuth(String path, Map<String, dynamic> body) async {
    final response = await client.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(body),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String message = 'Authentication request failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['message'] is String) {
          message = decoded['message'] as String;
        } else if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } catch (_) {
        // Keep the status-based message for non-JSON responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        if (decoded['token'] is String) {
          sessionToken = decoded['token'] as String;
        } else if (decoded['session'] is Map &&
            decoded['session']['token'] is String) {
          sessionToken = decoded['session']['token'] as String;
        }
      }
    } catch (_) {
      // Non-JSON response
    }
    try {
      final setCookie = response.headers['set-cookie'];
      if (setCookie != null &&
          (sessionToken == null || sessionToken!.isEmpty)) {
        final match = RegExp(
                r'(?:better-auth\.session_token|__Secure-better-auth\.session_token)=([^;]+)')
            .firstMatch(setCookie);
        if (match != null) {
          sessionToken = match.group(1);
        }
      }
    } catch (_) {
      // Ignored
    }
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) =>
      _postAuth('/auth/sign-in/email', {
        'email': email,
        'password': password,
      });

  @override
  Future<void> requestSignUpVerificationCode({
    required String email,
    String? name,
  }) =>
      _postAuth('/auth/sign-up/send-code', {
        'email': email,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      });

  @override
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
    String? otp,
  }) =>
      _postAuth('/auth/sign-up/email', {
        'name': name,
        'email': email,
        'password': password,
        if (otp != null && otp.trim().isNotEmpty) 'otp': otp.trim(),
        // The verification link lands here; a relative value would resolve
        // against the API origin, which differs from the app in local dev.
        'callbackURL': Uri.base.scheme == 'http' || Uri.base.scheme == 'https'
            ? '${Uri.base.origin}/'
            : '/',
      });

  @override
  Future<void> requestPasswordReset({required String email}) => _postAuth(
        '/auth/request-password-reset',
        {
          'email': email,
          'redirectTo': '${Uri.base.origin}/login',
        },
      );

  @override
  Future<void> resetPassword({
    required String token,
    required String password,
  }) =>
      _postAuth('/auth/reset-password', {
        'token': token,
        'newPassword': password,
      });

  @override
  Future<AxAccountSecurity> loadAccountSecurity() async {
    final responses = await Future.wait([
      client.get(Uri.parse('$baseUrl/auth/list-accounts'), headers: _headers()),
      client.get(Uri.parse('$baseUrl/auth/list-sessions'), headers: _headers()),
    ]);
    for (final response in responses) {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AxApiException(
            'Account security lookup failed (${response.statusCode})',
            statusCode: response.statusCode);
      }
    }
    final accountsBody = jsonDecode(responses[0].body);
    final sessionsBody = jsonDecode(responses[1].body);
    final accounts = accountsBody is List
        ? accountsBody
        : accountsBody is Map && accountsBody['accounts'] is List
            ? accountsBody['accounts'] as List
            : const [];
    final sessions = sessionsBody is List
        ? sessionsBody
        : sessionsBody is Map && sessionsBody['sessions'] is List
            ? sessionsBody['sessions'] as List
            : const [];
    return AxAccountSecurity.fromJson(
      accounts
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
      sessions
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList(growable: false),
    );
  }

  @override
  Future<void> approveDesktopAuthIntent({
    required String intentId,
  }) async {
    final response = await client.post(
      Uri.parse(
          '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/approve'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(const <String, Object?>{}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Desktop sign-in approval failed (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } on Object {
        // Keep the status-based message for non-JSON error responses.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
  }

  @override
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus({
    required String intentId,
  }) async {
    final body = await _getJson(Uri.parse(
      '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/browser-status',
    ));
    try {
      return AxDesktopAuthIntentStatus.fromJson(body);
    } on FormatException {
      throw const AxApiException('Sign-in request metadata is malformed');
    }
  }

  @override
  Future<void> denyDesktopAuthIntent({required String intentId}) async {
    final response = await client.post(
      Uri.parse(
        '$baseUrl/desktop-auth/intents/${Uri.encodeComponent(intentId)}/deny',
      ),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(const <String, Object?>{}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Sign-in cancellation failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> revokeAccountSession(String token) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/revoke-session'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'token': token}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Session revocation failed',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> unlinkAccount({required String accountId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/auth/unlink-account'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'accountId': accountId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var message = 'Could not unlink account. Try signing in again.';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['message'] is String) {
          message = body['message'] as String;
        }
      } on FormatException {
        // Keep the fallback for non-JSON errors.
      }
      throw AxApiException(message, statusCode: response.statusCode);
    }
  }

  @override
  Future<Uri> beginAccountLink(String provider, Uri returnTo) async {
    // Return to this app even when the API runs on another origin (local dev).
    final callbackURL = Uri.base.scheme == 'http' || Uri.base.scheme == 'https'
        ? Uri.base.resolveUri(returnTo).toString()
        : returnTo.toString();
    final response = await client.post(
      Uri.parse('$baseUrl/auth/link-social'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'provider': provider,
        'callbackURL': callbackURL,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Could not start account linking',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final url = body is Map ? body['url'] : null;
    if (url is! String || url.isEmpty) {
      throw const AxApiException('Account linking response is malformed');
    }
    return Uri.parse(url);
  }
}
