import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desktop_auth.dart';
import 'secure_credentials.dart';
import 'workspace_configuration.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_manager_ipc.dart';
import 'workspace_registration.dart';

/// Service-owned approval: only public progress crosses IPC. Credentials stay
/// in the service and the installation's recorded credential store.
class WorkspaceHeadlessAuth {
  WorkspaceHeadlessAuth({
    required this.dataDirectory,
    required this.cloudUrl,
    required this.credentialStore,
    required this.reloadRuntime,
    DesktopAuthClient Function(String)? clientFactory,
  }) : _clientFactory =
            clientFactory ?? ((url) => DesktopAuthClient(cloudUrl: url));

  final Directory dataDirectory;
  final String cloudUrl;
  final SecureCredentialStore credentialStore;
  final Future<void> Function() reloadRuntime;
  final DesktopAuthClient Function(String) _clientFactory;
  DesktopAuthClient? _client;
  DesktopAuthIntent? _intent;
  Future<void>? _operation;
  bool _cancelled = false;
  bool _committing = false;
  bool _starting = false;
  Map<String, Object?> _status = const {'phase': 'idle'};

  Map<String, Object?> status() => Map.of(_status);

  /// Test a private temporary credential before creating any remote state.
  /// A broken keyring must not leave a Cloud-only Workspace behind.
  Future<void> _probeStorage() async {
    final probeKey = 'setup-storage-probe-$pid';
    try {
      if (credentialStore is CredentialStorePreflight) {
        await (credentialStore as CredentialStorePreflight).verifyWritable();
      } else {
        await credentialStore.write(probeKey, 'storage-preflight');
        if (await credentialStore.read(probeKey) != 'storage-preflight') {
          throw StateError('Credential storage readback failed');
        }
        await credentialStore.delete(probeKey);
      }
    } on Object {
      throw const WorkspaceManagerProtocolException(
          'credential_store_unavailable',
          'Credential storage is unavailable. Check the recorded Linux credential store before signing in. No Cloud registration was started.');
    }
  }

  Future<Map<String, Object?>> start({String? email, String? password}) async {
    if (_starting || _operation != null || _client != null) {
      throw const WorkspaceManagerProtocolException(
          'login_in_progress', 'Sign-in is already in progress.');
    }
    _cancelled = false;
    _starting = true;
    try {
      await _probeStorage();
    } on WorkspaceManagerProtocolException {
      _starting = false;
      rethrow;
    }
    final client = _clientFactory(cloudUrl);
    _client = client;
    _starting = false;
    try {
      if (email != null || password != null) {
        if (email == null ||
            email.trim().isEmpty ||
            password == null ||
            password.isEmpty) {
          throw const FormatException('Email and password are required');
        }
        _status = const {'phase': 'pending', 'stage': 'password_sign_in'};
        _operation = _complete(client, null, email: email, password: password);
        return status();
      }
      final intent = await client.createIntent();
      _intent = intent;
      _status = {
        'phase': 'pending',
        'verificationUrl': intent.verificationUrl.toString(),
        'expiresAt': intent.expiresAt.toUtc().toIso8601String()
      };
      _operation = _complete(client, intent);
      return status();
    } on Object {
      _client = null;
      client.close();
      throw const WorkspaceManagerProtocolException('login_unavailable',
          'Could not start sign-in. Check Cloud connectivity.');
    }
  }

  Future<void> _registerWithSession(
    DesktopAuthClient client,
    DesktopHumanSession session,
    void Function(String stage) setStage, {
    bool replaceReleased = false,
  }) async {
    var registration = WorkspaceRegistrationStore(dataDirectory).readSync();
    final installationId =
        await InstallationIdentityStore(dataDirectory).getOrCreate();
    final preferences = WorkspaceLifecyclePreferencesStore(dataDirectory);
    final previous = preferences.readSync();
    if ((previous.ownerUserId != null &&
            previous.ownerUserId != session.userId) ||
        (registration != null && registration.ownerUserId != session.userId)) {
      throw StateError('Existing owner differs.');
    }
    setStage('ownership');
    final ownership = await client.checkWorkspaceOwnership(
        session: session,
        installationId: installationId,
        workspaceId: registration?.workspaceId,
        runtimeId: registration?.workspaceRuntimeId);
    // Cloud released this installation (for example from the web app). An
    // explicit registration claims it as a new Workspace and drops the stale
    // local identity.
    final releasedRebind =
        replaceReleased && ownership.state == WorkspaceOwnershipState.released;
    if (releasedRebind && registration != null) {
      await WorkspaceRegistrationStore(dataDirectory).clear();
      await credentialStore.delete(registration.workspaceRuntimeId);
      registration = null;
    }
    final fresh = releasedRebind ||
        (registration == null &&
            ownership.state == WorkspaceOwnershipState.unbound);
    final recoverCloudOnlyRegistration = registration == null &&
        ownership.state == WorkspaceOwnershipState.ownedByCurrentUser &&
        ownership.ownerMatchesCurrentSession == true &&
        ownership.ownerUserId == session.userId &&
        ownership.workspaceId != null;
    final existing = registration != null &&
        ownership.state == WorkspaceOwnershipState.ownedByCurrentUser &&
        ownership.workspaceId == registration.workspaceId &&
        ownership.workspaceRuntimeId == registration.workspaceRuntimeId &&
        ownership.ownerUserId == session.userId &&
        registration.installationId == installationId;
    if (!fresh && !recoverCloudOnlyRegistration && !existing) {
      throw StateError('Ownership requires recovery.');
    }
    if (_cancelled) throw StateError('Cancelled.');
    _committing = true;
    setStage('registration');
    if (fresh || recoverCloudOnlyRegistration) {
      await WorkspaceRegistrationService(
              dataDirectory: dataDirectory, credentialStore: credentialStore)
          .registerWithDesktopSession(
              cloudUrl: cloudUrl,
              desktopCredential: session.credential,
              expectedOwnerUserId: session.userId,
              expectedWorkspaceId:
                  recoverCloudOnlyRegistration ? ownership.workspaceId : null,
              facts: SafeMachineFacts.collect(
                  installationId: installationId,
                  // The name chosen on this computer wins over a name Cloud
                  // may still hold from an earlier registration.
                  name: previous.customWorkspaceName ??
                      ownership.workspaceName ??
                      Platform.localHostname));
    } else if ((await credentialStore.read(registration!.workspaceRuntimeId))
            ?.isNotEmpty !=
        true) {
      await WorkspaceRegistrationService(
              dataDirectory: dataDirectory, credentialStore: credentialStore)
          .registerWithDesktopSession(
              cloudUrl: cloudUrl,
              desktopCredential: session.credential,
              expectedOwnerUserId: session.userId,
              expectedWorkspaceId: registration.workspaceId,
              facts: SafeMachineFacts.collect(
                  installationId: installationId,
                  name: registration.name,
                  hostname: registration.hostname));
    }
    setStage('session_storage');
    await replaceStoredDesktopHumanSession(
        credentialStore: credentialStore, client: client, session: session);
    await preferences.write(previous.copyWith(
        ownerUserId: session.userId, ownerDisplayName: session.displayName));
    setStage('runtime_reload');
    await reloadRuntime();
  }

  Future<void> _complete(DesktopAuthClient client, DesktopAuthIntent? intent,
      {String? email, String? password}) async {
    var stage = email == null ? 'approval' : 'password_sign_in';
    try {
      final deviceId =
          await InstallationIdentityStore(dataDirectory).getOrCreate();
      final session = email == null
          ? await client.waitForApprovalAndClaim(intent!,
              isCancelled: () => _cancelled, deviceId: deviceId)
          : await client.signInWithPassword(email, password!,
              deviceId: deviceId);
      stage = 'session_validation';
      await client.validateSession(session);
      await _registerWithSession(client, session, (value) => stage = value);
      _status = const {'phase': 'complete'};
    } on Object catch (error) {
      // Only enumerated, locally-authored password errors cross IPC. Remote
      // response text and credentials never enter public diagnostics.
      final passwordFailure =
          error is DesktopPasswordSignInException ? error : null;
      _status = {
        'phase': _cancelled ? 'cancelled' : 'failed',
        'stage': stage,
        'code': _cancelled
            ? 'login_cancelled'
            : passwordFailure?.code ?? 'login_${stage}_failed',
        'message': _cancelled
            ? 'Sign-in cancelled.'
            : passwordFailure?.message ??
                'Sign-in or registration failed. Check Cloud access and existing ownership. Local state was retained; if registration completed, retry login.'
      };
    } finally {
      _committing = false;
      _intent = null;
      _client = null;
      _operation = null;
      client.close();
    }
  }

  /// Revokes the stored management session in Cloud (best effort) and removes
  /// it from this computer. Returns whether a session was stored.
  Future<bool> signOut() async {
    final raw = await credentialStore.read(desktopHumanCredentialKey);
    if (raw == null || raw.isEmpty) return false;
    final session = await readStoredDesktopHumanSession(credentialStore);
    if (session != null) {
      final client = _clientFactory(cloudUrl);
      try {
        await revokeDesktopHumanSessionQuietly(client, session);
      } finally {
        client.close();
      }
    }
    await credentialStore.delete(desktopHumanCredentialKey);
    return true;
  }

  /// Signs in with email and password and stores the management session. It
  /// does not register a Workspace; use [register] for that.
  Future<Map<String, Object?>> signIn({
    required String email,
    required String password,
  }) async {
    await _probeStorage();
    final client = _clientFactory(cloudUrl);
    var stage = 'password_sign_in';
    try {
      if (email.trim().isEmpty || password.isEmpty) {
        throw const FormatException('Email and password are required');
      }
      final session = await client.signInWithPassword(email.trim(), password,
          deviceId:
              await InstallationIdentityStore(dataDirectory).getOrCreate());
      stage = 'session_validation';
      await client.validateSession(session);
      final registration = WorkspaceRegistrationStore(dataDirectory).readSync();
      final preferences = WorkspaceLifecyclePreferencesStore(dataDirectory);
      final previous = preferences.readSync();
      if ((previous.ownerUserId != null &&
              previous.ownerUserId != session.userId) ||
          (registration != null &&
              registration.ownerUserId != session.userId)) {
        stage = 'ownership';
        throw StateError('Existing owner differs.');
      }
      stage = 'session_storage';
      await replaceStoredDesktopHumanSession(
          credentialStore: credentialStore, client: client, session: session);
      await preferences.write(previous.copyWith(
          ownerUserId: session.userId, ownerDisplayName: session.displayName));
      return const {'phase': 'complete'};
    } on Object catch (error) {
      return _failure(stage, error,
          fallback: 'Sign-in failed. Check your email, password and Cloud '
              'access.');
    } finally {
      client.close();
    }
  }

  /// Registers (or recovers) this Workspace using the stored management
  /// session from [signIn]. A Workspace that Cloud has released is claimed as a
  /// new one.
  Future<Map<String, Object?>> register() async {
    if (_committing || _operation != null) {
      throw const WorkspaceManagerProtocolException(
          'register_in_progress', 'Registration is already in progress.');
    }
    await _probeStorage();
    final client = _clientFactory(cloudUrl);
    var stage = 'session_validation';
    try {
      final raw = await credentialStore.read(desktopHumanCredentialKey);
      if (raw == null || raw.isEmpty) {
        return const {
          'phase': 'failed',
          'stage': 'session',
          'code': 'not_signed_in',
          'message': 'Not signed in. Run: syntila login',
        };
      }
      final DesktopHumanSession session;
      try {
        session = DesktopHumanSession.fromSecureJson(
            jsonDecode(raw) as Map<String, dynamic>);
      } on Object {
        return const {
          'phase': 'failed',
          'stage': 'session',
          'code': 'session_invalid',
          'message': 'The stored sign-in is unreadable. '
              'Run: syntila login',
        };
      }
      if (!session.expiresAt.isAfter(DateTime.now())) {
        return const {
          'phase': 'failed',
          'stage': 'session',
          'code': 'session_expired',
          'message': 'The sign-in has expired. Run: syntila login',
        };
      }
      await client.validateSession(session);
      await _registerWithSession(client, session, (value) => stage = value,
          replaceReleased: true);
      _status = const {'phase': 'complete'};
      return const {'phase': 'complete'};
    } on Object catch (error) {
      return _failure(stage, error,
          fallback: 'Registration failed. Check Cloud access and existing '
              'ownership. If the sign-in is no longer valid, run: '
              'syntila login');
    } finally {
      _committing = false;
      client.close();
    }
  }

  /// Only enumerated, locally authored text crosses to the caller: remote
  /// response text and credentials never enter public diagnostics.
  Map<String, Object?> _failure(String stage, Object error,
      {required String fallback}) {
    final passwordFailure =
        error is DesktopPasswordSignInException ? error : null;
    if (error is WorkspaceRegistrationException &&
        error.kind == WorkspaceRegistrationErrorKind.workspaceNameTaken) {
      return {
        'phase': 'failed',
        'stage': stage,
        'code': 'workspace_name_taken',
        'message': '${error.message} ${error.action}',
      };
    }
    return {
      'phase': 'failed',
      'stage': stage,
      'code': passwordFailure?.code ?? 'login_${stage}_failed',
      'message': passwordFailure?.message ?? fallback,
    };
  }

  Future<Map<String, Object?>> cancel() async {
    if (_committing) {
      throw const WorkspaceManagerProtocolException(
          'login_committing', 'Registration is completing; wait for status.');
    }
    _cancelled = true;
    final client = _client;
    final intent = _intent;
    if (client != null && intent != null) {
      try {
        await client.cancelIntent(intent);
      } on Object {/* local cancellation still applies */}
    }
    return status();
  }

  Future<void> close() async {
    if (!_committing) {
      _cancelled = true;
      _client?.close();
    }
    await _operation;
  }
}
