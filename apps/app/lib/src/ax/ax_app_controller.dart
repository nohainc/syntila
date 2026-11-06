part of 'ax_app.dart';

extension _AxAppController on _AxAppStateMixin {
  Future<void> _pollDesktopAuthStatus() async {
    final intentId = _desktopAuthIntentId;
    if (intentId == null ||
        _desktopAuthStatusRequestActive ||
        desktopAuthApproved ||
        desktopAuthCancelled) {
      return;
    }
    _desktopAuthStatusRequestActive = true;
    try {
      final intentStatus = await widget.dataSource.loadDesktopAuthIntentStatus(
        intentId: intentId,
      );
      if (!mounted) return;
      if (intentStatus.status == 'pending') {
        _updateState(() => desktopAuthIntentStatus = intentStatus);
        return;
      }
      browserNavigation.replace(Uri(path: '/'));
      final approved =
          intentStatus.status == 'approved' || intentStatus.status == 'claimed';
      _updateState(() {
        desktopAuthIntentStatus = intentStatus;
        desktopAuthApproved = approved;
        desktopAuthCancelled = !approved;
      });
      _desktopAuthStatusTimer?.cancel();
    } on Object {
      // Temporary network or sign-in errors should not disrupt browser auth.
    } finally {
      _desktopAuthStatusRequestActive = false;
    }
  }

  void _enterUnauthenticatedState() {
    _dismissOpenModalRoutes();
    final targetUri = navigation.toUri();
    final nextLogin = navigation.kind == AxRouteKind.login
        ? navigation
        : AxNavigation.login(
            returnTo: targetUri.path == '/' && !targetUri.hasQuery
                ? null
                : targetUri.toString(),
          );
    _updateState(() {
      _resetSensitiveAuthInputs();
      authError = null;
      authNotice = null;
      authRequired = true;
      isLoading = false;
      navigation = nextLogin;
    });
    browserNavigation.replaceWithLogin(targetUri);
  }

  Future<void> _loadSession() async {
    try {
      final session = await store.auth.load();
      unawaited(_loadViewerAvatar(session.viewer?.avatarUrl));
      if (!session.authenticated) {
        if (!mounted) return;
        _enterUnauthenticatedState();
        return;
      }
      if (navigation.kind == AxRouteKind.login) {
        final target = navigation.loginReturnTo == null
            ? const AxNavigation.home()
            : AxNavigation.fromUri(
                Uri.parse(navigation.loginReturnTo!),
              );
        if (mounted) _updateState(() => navigation = target);
        browserNavigation.replace(target.toUri());
      }
      if (navigation.kind == AxRouteKind.desktopAuthApproval) {
        if (mounted) _updateState(() => isLoading = false);
        return;
      }
      final hydrated = await store.hydrateReadCache();
      if (!mounted) return;
      if (hydrated) {
        _updateState(() {
          authRequired = false;
          isLoading = false;
          loadError = null;
          selectedSpaceId =
              navigation.spaceId ?? store.spaces.items.firstOrNull?.id;
          _applySpaceNavigation();
        });
        _startRealtime();
        _ensureNavigationResources(navigation);
      }
      final accountSecurityLoad = navigation.kind == AxRouteKind.profileSecurity
          ? _loadAccountSecurity()
          : null;
      // Bootstrap already reads the Workspace list; reuse it instead of a
      // separate list request, and fetch only if bootstrap did not complete.
      unawaited(_loadAttachmentPolicy());
      final bootstrapped = await _loadBootstrapState(showSpinner: !hydrated);
      if (mounted && store.auth.session?.authenticated == true) {
        if (mounted && store.auth.session?.authenticated == true) {
          await _loadWorkspaces(fetch: !bootstrapped);
        }
      }
      if (accountSecurityLoad != null) await accountSecurityLoad;
    } catch (_) {
      if (mounted) {
        _updateState(() {
          isLoading = false;
          loadError = 'Authentication service is unavailable.';
        });
      }
    }
  }

  /// The account's upload limits come from Cloud; the composers use them for
  /// early per-file feedback. Cloud still enforces every limit on upload.
  Future<void> _loadAttachmentPolicy() async {
    final Object source = store.dataSource;
    if (source is! AxAccountPlanDataSource) return;
    try {
      final plan = await source.loadAccountPlan();
      AxAccountPlanCache.instance.plan = plan;
      AxAttachmentPolicy.instance.updateFromPlan(plan);
    } on Object {
      // Free limits stay in force until the next successful load.
    }
  }

  Future<void> _logout() async {
    try {
      AxAttachmentPolicy.instance.reset();
      AxAccountPlanCache.instance.plan = AxAccountPlan.free;
      await store.logout();
      expandedSpaceIds.clear();
      _sidebarRestoredSpaceIds.clear();
      _readHomeAttentionIds.clear();
      if (!mounted) return;
      selectedSpaceId = null;
      _enterUnauthenticatedState();
    } catch (error) {
      if (mounted) _updateState(() => loadError = error.toString());
    }
  }

  Future<void> _submitEmailAuth() async {
    final email = authEmailController.text.trim();
    final password = authPasswordController.text;
    final confirmPassword = authConfirmPasswordController.text;
    final verificationCode = authVerificationCodeController.text.trim();
    final resetToken = navigation.loginToken ??
        browserNavigation.current.queryParameters['token'];
    if (resetToken != null) {
      if (password.isEmpty) {
        _updateState(() => authError = 'Enter a new password.');
        return;
      }
    } else if (authResetRequest) {
      if (email.isEmpty) {
        _updateState(() => authError = 'Enter your email address.');
        return;
      }
    } else if (email.isEmpty || password.isEmpty) {
      _updateState(() => authError = 'Enter your email and password.');
      return;
    }
    if (authSignUp && authNameController.text.trim().isEmpty) {
      _updateState(() => authError = 'Enter your name.');
      return;
    }
    if ((authSignUp || resetToken != null) && password != confirmPassword) {
      _updateState(() => authError = 'The passwords do not match.');
      return;
    }
    if ((authSignUp || resetToken != null) && password.length < 8) {
      _updateState(
          () => authError = 'Use a password with at least 8 characters.');
      return;
    }
    if (authSignUp &&
        authSignUpAwaitingCode &&
        !RegExp(r'^\d{6}$').hasMatch(verificationCode)) {
      _updateState(() => authError =
          'Enter the 6-digit verification code sent to your email.');
      return;
    }
    _updateState(() {
      authBusy = true;
      authError = null;
      authNotice = null;
    });
    try {
      if (resetToken != null) {
        await widget.dataSource.resetPassword(
          token: resetToken,
          password: password,
        );
        final nextLogin =
            AxNavigation.login(returnTo: navigation.loginReturnTo);
        browserNavigation.replace(nextLogin.toUri());
        if (mounted) {
          _updateState(() {
            navigation = nextLogin;
            authBusy = false;
            authNotice = 'Password changed. You can sign in now.';
            _resetSensitiveAuthInputs();
          });
        }
        return;
      }
      if (authResetRequest) {
        await widget.dataSource.requestPasswordReset(email: email);
        if (mounted) {
          _updateState(() {
            authBusy = false;
            authNotice =
                'If an account exists for that email, a password reset link is on its way.';
          });
        }
        return;
      }
      if (authSignUp) {
        if (!authSignUpAwaitingCode) {
          await widget.dataSource.requestSignUpVerificationCode(
            email: email,
            name: authNameController.text.trim(),
          );
          if (mounted) {
            _updateState(() {
              authBusy = false;
              authSignUpAwaitingCode = true;
              authVerificationCodeController.clear();
              authNotice = null;
            });
          }
          return;
        }
        await widget.dataSource.signUpWithEmail(
          name: authNameController.text.trim(),
          email: email,
          password: password,
          otp: verificationCode,
        );
      } else {
        await widget.dataSource.signInWithEmail(
          email: email,
          password: password,
        );
      }
      if (!mounted) return;
      TextInput.finishAutofillContext();
      _updateState(() {
        authBusy = false;
        _resetSensitiveAuthInputs();
        authRequired = false;
        isLoading = true;
      });
      await _loadSession();
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        authBusy = false;
        authError = error.toString();
      });
    }
  }

  Future<void> _resendSignUpCode() async {
    final email = authEmailController.text.trim();
    final name = authNameController.text.trim();
    if (email.isEmpty || authBusy) return;
    _updateState(() {
      authBusy = true;
      authError = null;
      authNotice = null;
    });
    try {
      await widget.dataSource.requestSignUpVerificationCode(
        email: email,
        name: name,
      );
      if (!mounted) return;
      _updateState(() {
        authBusy = false;
        authVerificationCodeController.clear();
        authNotice = 'A new 6-digit verification code was sent to $email.';
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        authBusy = false;
        authError = error.toString();
      });
    }
  }

  /// Release builds pass `--dart-define=SYNTILA_APP_VERSION=<version>`.
  static const syntilaAppVersion = String.fromEnvironment(
    'SYNTILA_APP_VERSION',
    defaultValue: '0.1.0',
  );

  Future<void> _showAboutSyntila() {
    final dialogContext = navigatorKey.currentState?.context ?? context;
    return showDialog<void>(
      context: dialogContext,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            SyntilaBrand.logoMark(size: 26),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'About Syntila',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Syntila brings people and AI Workers together in Spaces and Threads to discuss ideas, share context, and get work done.',
                style: TextStyle(fontSize: 13.5, height: 1.45),
              ),
              const SizedBox(height: 8),
              const Text(
                'Team conversations, AI requests, and results stay together in one place. Choose how Workers handle tasks through Workflows, and run AI work on your own machines with Syntila Workspace and the provider CLIs you already use.',
                style: TextStyle(fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 16),
              Builder(builder: (context) {
                final dark = Theme.of(context).brightness == Brightness.dark;
                final foreground = SyntilaColors.primaryForeground(dark);
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: SyntilaColors.primarySoftColor(dark),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.verified_outlined,
                          size: 14, color: foreground),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Version $syntilaAppVersion',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: foreground,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 12),
              Text(
                '© ${DateTime.now().year} Syntila',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              browserNavigation
                  .openExternal(Uri.parse('https://conclaveax.com'));
            },
            child: const Text('Visit website'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadWorkspaces({bool fetch = true}) async {
    try {
      if (fetch) await store.workspaces.list();
      if (!mounted) return;
      try {
        await store.catalogs.ensureWorkers();
      } catch (_) {
        // Workspace inventory remains independently optional during registration.
      }
      _startRealtime();
    } catch (_) {
      // Snapshot loading remains the primary path for anonymous development.
    }
  }

  /// A superseded recovery means a newer refresh already holds fresher data.
  void _reportRefreshFailure(Object error) {
    if (error is AxRecoverySupersededException || !mounted) return;
    _showSnackBar('Live update refresh failed: $error');
  }

  void _onRealtimeEvent(Map<String, dynamic> event) {
    AxRenderDiagnostics.instance.realtimeEvent(event);
    final type = event['type'];
    if (!mounted) return;
    final recoveryGeneration = const {
      'reconnect.required',
      'realtime.ready',
      'realtime.connection',
      'realtime.stale'
    }.contains(type)
        ? ++_realtimeRecoveryGeneration
        : _realtimeRecoveryGeneration;
    final routed = store.realtimeCacheRouter.handle(event);
    if (type != 'reconnect.required') {
      unawaited(routed.catchError((Object error) {
        _reportRefreshFailure(error);
      }));
    }
    if (type == 'realtime.connection') {
      final status = event['status'];
      _realtimeTransportConnected = status == 'connected';
      _updateLiveState(() {
        realtimeStale = status != 'connected';
        realtimeNotice = realtimeStale
            ? 'Live updates paused. Syntila is reconnecting.'
            : 'Live updates connected.';
      });
      // Cloud closes the socket when the account or session is removed, and
      // the reconnect handshake then fails. Re-check the session so a removed
      // user is signed out instead of retrying forever.
      if (realtimeStale && store.auth.session?.authenticated == true) {
        unawaited(_verifySessionAfterDisconnect());
      }
      return;
    }
    if (type == 'realtime.ready') {
      _realtimeTransportConnected = true;
      unawaited(_syncNotificationFeed());
      // The first ready follows sign-in, whose bootstrap already loads Spaces
      // and invitations; only reconnects need the catch-up refresh.
      if (realtimeReadyOnce) {
        unawaited(_refreshRealtimeFeatures('space.updated'));
      }
      realtimeReadyOnce = true;
      _updateLiveState(() => realtimeStale = false);
      return;
    }
    if (type == 'reconnect.required') {
      final scope = AxSyncScope.fromEvent(event);
      _updateLiveState(() {
        realtimeStale = true;
        realtimeNotice =
            'Some live updates were missed. Refreshing the affected view.';
      });
      unawaited(_recoverRealtimeScope(scope, routed, recoveryGeneration));
      return;
    }
    _recordNotification(event);
    _handleSoundNotification(event);
    if (type is String && type.startsWith('typing')) return;
    if (type is String &&
        (type.startsWith('assignment.activity') ||
            type.startsWith('worker.status') ||
            type.startsWith('heartbeat'))) {
      _announceRealtimeProgress(event);
      return;
    }
    if (type == 'run.input_required' || type == 'run.approval_required') {
      final payload = event['payload'];
      final prompt = payload is Map ? payload['prompt'] : null;
      if (prompt is String && prompt.trim().isNotEmpty) {
        store.pendingRunPrompt.value = prompt.trim();
      }
    }
    _announceRealtimeProgress(event);
    unawaited(
        _refreshRealtimeFeatures(type is String ? type : '', event: event));
  }

  Future<void> _recoverRealtimeScope(
      AxSyncScope scope, Future<void> routed, int generation) async {
    Future<void> workspaceRecovery() async {
      if (scope.kind == 'execution_workspace' && scope.id != null) {
        await store.resynchronizeWorkspace(scope.id!);
      } else if (scope.kind == 'user') {
        await Future.wait([
          _refreshRealtimeFeatures('space.updated'),
          _refreshRealtimeFeatures('workspace.updated'),
          _refreshRealtimeFeatures('workspace_invitation.updated'),
        ]);
      }
    }

    try {
      await Future.wait([routed, workspaceRecovery()]);
      // The shared Work router receives the same transport frame, independently
      // of rendering. Wait for that recovery without delivering it twice.
      await store.workRealtime.pendingRecovery;
      if (!mounted ||
          generation != _realtimeRecoveryGeneration ||
          !_realtimeTransportConnected) {
        return;
      }
      _updateLiveState(() {
        realtimeStale = false;
        realtimeNotice = 'Live updates connected.';
      });
    } catch (error) {
      _reportRefreshFailure(error);
    }
  }

  Future<void> _refreshRealtimeFeatures(String type,
      {Map<String, dynamic>? event}) async {
    final workspaceId = executionWorkspaceId;
    if (type.startsWith('product.update.') ||
        type.startsWith('product_update.')) {
      final payload = event?['payload'];
      if (payload is Map<String, dynamic>) {
        try {
          final update = AxProductUpdate.fromJson(payload);
          store.addProductUpdate(update);
        } catch (_) {}
      }
      return;
    }
    if (type == 'workspace_invitation.updated') {
      // Invitee: the Inbox list. Owner: the open sharing section, and any
      // newly lent Workspace once the invitee accepts.
      store.workspaceInvitationRevision.value++;
      try {
        await Future.wait<void>([
          store.refreshWorkspaceInvitations(),
          store.workspaces.list(),
        ]);
      } catch (error) {
        _reportRefreshFailure(error);
      }
      return;
    }
    if ((workspaceId == null || workspaceId.isEmpty) &&
        !type.startsWith('space.') &&
        type != 'space_workspace_grant.updated') {
      return;
    }
    try {
      if (type.startsWith('workspace.')) {
        await Future.wait(
            [store.workspaces.list(), store.catalogs.refreshWorkers()]);
        return;
      }
      if (type.startsWith('worker.inventory.')) {
        // The cache router owns invalidation; the shared query updates consumers.
        return;
      }
      if (type.startsWith('space.invitation.') ||
          type.startsWith('space.invitation.') ||
          type.startsWith('invitation.') ||
          type.startsWith('workspace.invitation.') ||
          type.startsWith('space.') ||
          type == 'space_workspace_grant.updated') {
        // AxRealtimeCacheRouter already revalidates Spaces and invitations
        // for Space-scoped events; superseding its read would repeat them.
        final routed =
            (type.startsWith('space.') || type.startsWith('invitation.')) &&
                _eventSpaceId(event) != null;
        await Future.wait([
          if (!routed) store.spaces.refresh(),
          if (!routed) store.invitations.refresh(),
          store.refreshWorkspaceInvitations(),
        ]);
        if (!mounted) return;
        return;
      }
      // Execution events are reconciled by the shared Work router, never by
      // reloading Spaces, Workspaces, authentication, or bootstrap state.
    } catch (error) {
      _reportRefreshFailure(error);
    }
  }

  /// The Space the cache router keys Space and invitation events by.
  String? _eventSpaceId(Map<String, dynamic>? event) {
    if (event == null) return null;
    final payload = event['payload'];
    String? id(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    return id(event['spaceId']) ??
        (payload is Map
            ? id(payload['spaceId']) ?? id(payload['entityId'])
            : null);
  }

  /// Merges the durable Cloud feed so notifications survive reloads and
  /// reach other devices; failures keep the live list as is.
  Future<void> _syncNotificationFeed() async {
    final source = store.dataSource;
    if (source is! AxNotificationDataSource ||
        store.auth.session?.authenticated != true) {
      return;
    }
    try {
      final feed = [
        for (final n in notificationsFromFeed(
            await (source as AxNotificationDataSource).loadNotificationFeed()))
          n.withPlace(_notificationPlace(n))
      ];
      if (!mounted) return;
      _updateNotifications(() {
        for (final item in feed) {
          final index = notifications.indexWhere((n) => n.id == item.id);
          if (index < 0) {
            notifications.add(item);
          } else if (item.read && !notifications[index].read) {
            notifications[index] = notifications[index].markRead();
          }
        }
      });
    } catch (_) {}
  }

  /// Persists read state for Work notifications; [ids] null marks all.
  void _persistNotificationsRead({List<String>? ids}) {
    final source = store.dataSource;
    if (source is! AxNotificationDataSource) return;
    final serverIds = ids
        ?.where((id) => id.startsWith('work-request:'))
        .map((id) => id.substring('work-request:'.length))
        .toList();
    if (serverIds != null && serverIds.isEmpty) return;
    unawaited((source as AxNotificationDataSource)
        .markNotificationsRead(ids: serverIds)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  /// Drops notifications whose Space or Thread was removed or cleared, so the
  /// bell never links to content that no longer exists. Server-backed entries
  /// are also marked read so a feed reload does not bring them back.
  void _discardNotificationsFor({String? spaceId, String? threadId}) {
    bool matches(AxNotification n) =>
        (threadId != null && n.threadId == threadId) ||
        (spaceId != null && n.spaceId == spaceId);
    final removedIds = notifications.where(matches).map((n) => n.id).toList();
    if (removedIds.isEmpty) return;
    _persistNotificationsRead(ids: removedIds);
    _updateNotifications(() => notifications.removeWhere(matches));
  }

  /// "Space › Thread" (or the Workspace) the notification is about, from the
  /// names already loaded; null when none is known yet.
  String? _notificationPlace(AxNotification n) {
    String? spaceName;
    for (final space in store.spaces.items) {
      if (space.id == n.spaceId) spaceName = space.name;
    }
    String? threadName;
    if (n.spaceId != null && n.threadId != null) {
      for (final thread in store.spaceThreads.peek(n.spaceId!)) {
        if (thread.id == n.threadId) threadName = thread.name;
      }
    }
    final parts = [
      if (spaceName != null && spaceName.trim().isNotEmpty) spaceName,
      if (threadName != null && threadName.trim().isNotEmpty) threadName,
    ];
    if (parts.isEmpty && n.workspaceId != null) {
      for (final workspace in store.workspaces.items) {
        if (workspace.id == n.workspaceId && workspace.name.isNotEmpty) {
          return workspace.name;
        }
      }
    }
    return parts.isEmpty ? null : parts.join(' › ');
  }

  Set<String> _currentInvitationIds() => {
        for (final invite in store.invitations.value) 'space:${invite.id}',
        for (final invite in store.workspaceInvitations.value)
          'workspace:${invite.id}',
      };

  /// Announces an invitation that arrived live in the Notification Center
  /// (and as a browser alert when the tab is in the background). In-app
  /// snackbars are intentionally quiet in this app.
  void _onInvitationsChanged() {
    final known = _knownInvitationIds;
    if (known == null || !mounted) return;
    _knownInvitationIds = _currentInvitationIds();
    void announce(String id, String type, String summary) =>
        _recordNotification({
          'eventId': 'invitation:$id',
          'type': type,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          // No spaceId: the invitee cannot open the Space before accepting.
          'payload': {'summary': summary},
        });
    for (final invite in store.invitations.value) {
      if (known.contains('space:${invite.id}')) continue;
      announce(
          'space:${invite.id}',
          'space.invitation.received',
          '${invite.invitedByDisplay} invited you to '
              '${invite.spaceName.isNotEmpty ? invite.spaceName : 'a Space'}');
    }
    for (final invite in store.workspaceInvitations.value) {
      if (known.contains('workspace:${invite.id}')) continue;
      announce('workspace:${invite.id}', 'workspace.invitation.received',
          '${invite.ownerName} invited you to use ${invite.workspaceName}');
    }
  }

  void _recordNotification(Map<String, dynamic> event) {
    final raw = notificationFromRealtimeEvent(event,
        viewerId: store.auth.session?.viewer?.id);
    final notification = raw?.withPlace(_notificationPlace(raw));
    if (notification == null ||
        notifications.any((item) => item.id == notification.id)) {
      return;
    }
    final currentRunId =
        executionSnapshot.run?.id ?? executionSnapshot.activeRunId;
    final isViewingRun = showRunDetails &&
        notification.runId != null &&
        notification.runId == currentRunId;
    // Finished Work on the Thread you are looking at is already on screen.
    final isViewingThread = notification.threadId != null &&
        navigation.threadId == notification.threadId &&
        _tabVisible;
    if (isViewingThread) _persistNotificationsRead(ids: [notification.id]);
    // Anything not already on screen is also surfaced as a browser alert, so
    // it is noticed with the tab in the background and in the foreground.
    if (shouldShowBrowserAlert(
        read: notification.read,
        tabVisible: _tabVisible,
        viewingRun: isViewingRun,
        viewingThread: isViewingThread)) {
      browserAlerts.show(
        title: notification.title,
        body: notification.message,
        tag: notification.id,
        onClick: () => _navigateToNotification(notification),
      );
    }
    _updateNotifications(() {
      notifications.insert(
        0,
        isViewingRun || isViewingThread
            ? notification.markRead()
            : notification,
      );
    });
  }

  void _handleSoundNotification(Map<String, dynamic> event) {
    if (_viewPreferences.muteSound) return;
    final type = event['type'];
    if (type is! String) return;

    if (type == 'work_request.completed' || type == 'thread.completed') {
      final raw = event['payload'];
      final payload = raw is Map ? raw : null;
      final status = payload?['status'] as String? ?? 'completed';
      if (status == 'completed') {
        soundNotifications.playRequestCompleted();
      }
      return;
    }

    if (type == 'discussion.created' || type == 'thread.discussion.created') {
      final raw = event['payload'];
      final payload = raw is Map ? raw : null;
      final authorUserId = payload?['authorUserId'] ??
          payload?['author_user_id'] ??
          event['authorUserId'] ??
          event['author_user_id'];
      final viewerId = store.auth.session?.viewer?.id ?? store.auth.viewer?.id;
      if (authorUserId != null && authorUserId == viewerId) {
        return;
      }
      soundNotifications.playMessageReceived();
    }
  }

  Future<void> _acceptInvitation(AxSpaceInvitation invite) async {
    try {
      await store.acceptInvitation(invite);
      if (!mounted) return;
      _showSnackBar(
          'Joined ${invite.spaceName.isNotEmpty ? invite.spaceName : "Space"}.');
      if (invite.spaceId.isNotEmpty) {
        _navigateTo(AxNavigation.space(invite.spaceId));
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to accept invitation: $error',
            type: ToastType.error);
      }
    }
  }

  Future<void> _acceptWorkspaceInvitation(
      AxMyWorkspaceInvitation invite) async {
    try {
      await store.acceptWorkspaceInvitation(invite);
      await Future.wait([
        store.workspaces.list(),
        store.catalogs.refreshWorkers(),
      ]);
      if (!mounted) return;
      _showSnackBar('You can now use ${invite.workspaceName}.');
      _navigateTo(const AxNavigation.workspaces());
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to accept invitation: $error',
            type: ToastType.error);
      }
    }
  }

  Future<void> _declineWorkspaceInvitation(
      AxMyWorkspaceInvitation invite) async {
    try {
      await store.declineWorkspaceInvitation(invite);
      if (mounted) _showSnackBar('Invitation declined.');
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to decline invitation: $error',
            type: ToastType.error);
      }
    }
  }

  Widget _invitationCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String badge,
    required String invitedBy,
    required VoidCallback onDecline,
    required VoidCallback onAccept,
  }) =>
      AxInvitationCard(
        icon: icon,
        title: title,
        badge: badge,
        invitedBy: invitedBy,
        onDecline: onDecline,
        onAccept: onAccept,
      );

  Future<void> _declineInvitation(AxSpaceInvitation invite) async {
    try {
      await store.declineInvitation(invite);
      if (mounted) {
        _showSnackBar('Invitation declined.');
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar('Failed to decline invitation: $error',
            type: ToastType.error);
      }
    }
  }

  void _readHomeAttentionItem(String id) {
    _updateState(() => _readHomeAttentionIds.add(id));
    final invitation = store.invitations.items
        .where((invite) => 'invite-${invite.id}' == id)
        .firstOrNull;
    final ids = notifications
        .where((item) =>
            item.id == id ||
            (invitation != null &&
                item.spaceId == invitation.spaceId &&
                (item.kind == AxNotificationKind.spaceInvitationReceived ||
                    item.kind == AxNotificationKind.invitationReceived)))
        .map((item) => item.id)
        .toList();
    if (ids.isEmpty) return;
    _persistNotificationsRead(ids: ids);
    _updateNotifications(() {
      for (var index = 0; index < notifications.length; index++) {
        if (ids.contains(notifications[index].id)) {
          notifications[index] = notifications[index].markRead();
        }
      }
    });
  }

  Future<void> _showNotifications() async {
    final dialogContext = navigatorKey.currentState?.context ?? context;
    final orderedNotifications = [...notifications]..sort((a, b) {
        final priority = b.priority.index.compareTo(a.priority.index);
        return priority != 0 ? priority : b.createdAt.compareTo(a.createdAt);
      });
    final width = navigatorKey.currentState?.overlay?.context.size?.width ??
        MediaQuery.sizeOf(dialogContext).width;
    final isDesktop = SyntilaBrand.isDesktop(width);
    final sidebarWidth = _desktopSidebarCollapsed ? 50.0 : _desktopSidebarWidth;
    Widget buildInbox(BuildContext context) => ListenableBuilder(
          listenable:
              Listenable.merge([store.invitations, store.workspaceInvitations]),
          builder: (context, _) {
            final pendingInvitations = store.invitations.items;
            final workspaceInvitations = store.workspaceInvitations.value;
            final isEmpty = pendingInvitations.isEmpty &&
                workspaceInvitations.isEmpty &&
                notifications.isEmpty;
            // Keep desktop notifications beside their sidebar entry point.
            return AlertDialog(
              alignment: isDesktop ? Alignment.topLeft : Alignment.topCenter,
              insetPadding: isDesktop
                  ? EdgeInsets.fromLTRB(sidebarWidth + 8, 16, 16, 16)
                  : EdgeInsets.zero,
              constraints: isDesktop
                  ? const BoxConstraints(maxWidth: 400)
                  : BoxConstraints(minWidth: width, maxWidth: width),
              title: Row(
                children: [
                  const Expanded(child: Text('Inbox')),
                  if (notifications.isNotEmpty)
                    IconButton(
                      onPressed: () {
                        _persistNotificationsRead();
                        _updateNotifications(() {
                          for (var index = 0;
                              index < notifications.length;
                              index++) {
                            notifications[index] =
                                notifications[index].markRead();
                          }
                        });
                        Navigator.of(context).pop();
                      },
                      tooltip: 'Mark all as read',
                      icon: const Icon(Icons.done_all_rounded),
                    ),
                  if (browserAlerts.supported)
                    IconButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        if (browserAlerts.enabled) {
                          browserAlerts.disable();
                          _showSnackBar('Desktop alerts turned off.');
                        } else {
                          unawaited(browserAlerts.enable().then((on) {
                            if (!mounted) return;
                            _showSnackBar(on
                                ? 'Desktop alerts turned on for background tabs.'
                                : 'Desktop alerts need browser permission.');
                          }));
                        }
                      },
                      tooltip: browserAlerts.enabled
                          ? 'Turn off desktop alerts'
                          : 'Turn on desktop alerts',
                      icon: Icon(browserAlerts.enabled
                          ? Icons.notifications_active_outlined
                          : Icons.notifications_off_outlined),
                    ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              content: SizedBox(
                width: 400,
                child: isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('You are all caught up.'),
                      )
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (pendingInvitations.isNotEmpty ||
                                workspaceInvitations.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  'Pending invitations',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                                ),
                              ),
                              for (final invite in workspaceInvitations)
                                _invitationCard(
                                  context,
                                  icon: Icons.computer_outlined,
                                  title: invite.workspaceName,
                                  badge: 'WORKSPACE',
                                  invitedBy: invite.ownerName,
                                  onDecline: () => unawaited(
                                      _declineWorkspaceInvitation(invite)),
                                  onAccept: () {
                                    Navigator.of(context).pop();
                                    unawaited(
                                        _acceptWorkspaceInvitation(invite));
                                  },
                                ),
                              for (final invite in pendingInvitations)
                                _invitationCard(
                                  context,
                                  icon: Icons.folder_outlined,
                                  title: invite.spaceName.isNotEmpty
                                      ? invite.spaceName
                                      : 'Space Invitation',
                                  badge: 'SPACE',
                                  invitedBy: invite.invitedByDisplay,
                                  onDecline: () =>
                                      unawaited(_declineInvitation(invite)),
                                  onAccept: () {
                                    Navigator.of(context).pop();
                                    unawaited(_acceptInvitation(invite));
                                  },
                                ),
                              if (notifications.isNotEmpty)
                                const Divider(height: 24),
                            ],
                            if (notifications.isNotEmpty) ...[
                              if (pendingInvitations.isNotEmpty ||
                                  workspaceInvitations.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    'Activity',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: orderedNotifications.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final notification =
                                      orderedNotifications[index];
                                  return ListTile(
                                    leading: Icon(
                                      switch (notification.kind) {
                                        AxNotificationKind.threadNeedsInput ||
                                        AxNotificationKind
                                            .workflowRunNeedsApproval ||
                                        AxNotificationKind.approvalRequired =>
                                          Icons.help_outline,
                                        AxNotificationKind.threadFailed ||
                                        AxNotificationKind.workflowRunFailed ||
                                        AxNotificationKind.failed =>
                                          Icons.error_outline,
                                        AxNotificationKind.threadCompleted ||
                                        AxNotificationKind
                                            .workflowRunCompleted ||
                                        AxNotificationKind.completed =>
                                          Icons.check_circle_outline,
                                        AxNotificationKind.workspaceOffline =>
                                          Icons.cloud_off_outlined,
                                        AxNotificationKind
                                              .workerCredentialProblem =>
                                          Icons.key_off_outlined,
                                        AxNotificationKind
                                              .workerInstallFailed =>
                                          Icons.download_for_offline_outlined,
                                        AxNotificationKind.spaceInvitationReceived ||
                                        AxNotificationKind
                                            .spaceInvitationReceived ||
                                        AxNotificationKind.invitationReceived =>
                                          Icons.mail_outline,
                                      },
                                      semanticLabel:
                                          '${notification.priority.name} priority, ${notification.read ? 'Read' : 'Unread'}',
                                      color: notification.read
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant
                                          : notification.priority ==
                                                  AxNotificationPriority.high
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .error
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .primary,
                                    ),
                                    title: Text(notification.title),
                                    subtitle: notification.message.isEmpty
                                        ? null
                                        : Text(notification.message),
                                    onTap: () =>
                                        Navigator.of(context).pop(notification),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
            );
          },
        );
    final selected = isDesktop
        ? await showDialog<AxNotification>(
            context: dialogContext,
            barrierColor: Colors.transparent,
            builder: buildInbox,
          )
        : await showModalBottomSheet<AxNotification>(
            context: dialogContext,
            isScrollControlled: true,
            useSafeArea: true,
            constraints: BoxConstraints(minWidth: width, maxWidth: width),
            builder: buildInbox,
          );
    if (!mounted || selected == null) return;
    _persistNotificationsRead(ids: [selected.id]);
    _updateNotifications(() {
      final index = notifications.indexWhere((item) => item.id == selected.id);
      if (index >= 0) notifications[index] = notifications[index].markRead();
    });
    _navigateToNotification(selected);
  }

  void _navigateToNotification(AxNotification notification) {
    switch (notification.target) {
      case AxNotificationTarget.thread:
        final spaceId = notification.spaceId;
        final threadId = notification.threadId;
        if (spaceId != null && threadId != null) {
          _navigateTo(AxNavigation.thread(spaceId, threadId));
        } else if (spaceId != null) {
          _navigateTo(AxNavigation.space(spaceId));
        }
      case AxNotificationTarget.workflowRun:
      case AxNotificationTarget.run:
        final spaceId = notification.spaceId;
        if (spaceId != null && notification.runId != null) {
          _navigateTo(AxNavigation.run(spaceId, notification.runId!));
        } else if (spaceId != null) {
          _navigateTo(AxNavigation.space(spaceId));
        }
      case AxNotificationTarget.space:
        final spaceId = notification.spaceId;
        if (spaceId != null) {
          _navigateTo(AxNavigation.space(spaceId));
        }
      case AxNotificationTarget.workspaces:
      case AxNotificationTarget.workspace:
        final workspaceId = notification.workspaceId ??
            workspaceWorkers
                .where((worker) => worker.id == notification.workerId)
                .map((worker) => worker.workspaceId)
                .firstOrNull;
        _navigateTo(AxNavigation.workspaces(workspaceId: workspaceId));
      case null:
        break;
    }
  }

  void _announceRealtimeProgress(Map<String, dynamic> event) {
    final payload = event['payload'];
    final summary = payload is Map
        ? (payload['summary'] ?? payload['status'] ?? payload['phase'])
        : null;
    if (summary is String && summary.trim().isNotEmpty) {
      final notice = summary.trim();
      _updateLiveState(() => realtimeNotice = notice);
    }
  }

  Future<void> _copyRunDiagnostics() async {
    final run = executionSnapshot.run;
    if (run == null) return;
    final diagnostics = <String, Object?>{
      'format': 'syntila-run-diagnostics-v1',
      'diagnosticSchemaVersion': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'workspaceId': executionSnapshot.workspaceId,
      'spaceId': selectedSpaceId,
      'runId': run.id,
      'status': run.status.name,
      'requestSubmissionState': run.status.name,
      'tasks': executionSnapshot.tasks
          .map((task) => {
                'id': task.id,
                'status': task.status.name,
                'worker': task.worker,
                if (task.errorCode != null) 'errorCode': task.errorCode,
              })
          .toList(),
      'events': executionSnapshot.events
          .map((event) => {
                'eventId': event.eventId,
                'correlationId': event.correlationId,
                'time': event.time,
                'type': event.kind,
              })
          .toList(),
    };
    await Clipboard.setData(ClipboardData(text: jsonEncode(diagnostics)));
    if (mounted) _showSnackBar('Run diagnostics copied without secrets.');
  }

  void _startRealtime() {
    final workspaceId = executionWorkspaceId;
    if (!realtimeStarted) {
      realtimeStarted = true;
      final apiBaseUrl =
          const String.fromEnvironment('SYNTILA_API_URL').isNotEmpty
              ? const String.fromEnvironment('SYNTILA_API_URL')
              : '/api';
      unawaited(
        realtimeClient.connect(
          realtimeEndpointForApi(apiBaseUrl),
          workspaceId,
        ),
      );
    }
    unawaited(realtimeClient.setScopes(
      spaceId: selectedSpaceId,
      threadId: navigation.threadId,
      runId: navigation.runId,
      executionWorkspaceId: workspaceId,
    ));
  }

  Future<void> _loadAccountSecurity() async {
    final existing = _accountSecurityLoadFlight;
    if (existing != null) return existing;
    final flight = _loadAccountSecurityOnce();
    _accountSecurityLoadFlight = flight;
    try {
      await flight;
    } finally {
      if (identical(_accountSecurityLoadFlight, flight)) {
        _accountSecurityLoadFlight = null;
      }
    }
  }

  Future<void> _loadAccountSecurityOnce() async {
    if (!mounted) return;
    store.securityError.value = null;
    _updateSecurity(() => accountSecurityLoading = true);
    final sessionId = store.auth.session?.sessionId;
    try {
      final loaded = await widget.dataSource.loadAccountSecurity();
      if (!mounted) return;
      if (store.auth.session?.sessionId != sessionId) {
        // The session changed mid-flight; drop the stale result and let the
        // profile page request a fresh load instead of spinning forever.
        _updateSecurity(() => accountSecurityLoading = false);
        return;
      }
      _updateSecurity(() {
        accountSecurity = loaded;
        accountSecurityLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (store.auth.session?.sessionId != sessionId) {
        _updateSecurity(() => accountSecurityLoading = false);
        return;
      }
      _updateSecurity(() {
        accountSecurityLoading = false;
        store.securityError.value = error.toString();
      });
    }
  }

  Future<void> _revokeAccountSession(AxAuthSession session) async {
    if (_isCurrentAccountSession(session)) return;
    if (!revokingAccountSessionTokens.add(session.token)) return;
    _updateState(() {});
    try {
      await widget.dataSource.revokeAccountSession(session.token);
      final current = accountSecurity;
      if (current != null) {
        accountSecurity = current.copyWith(
          sessions: current.sessions
              .where((item) => item.token != session.token)
              .toList(growable: false),
        );
      }
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    } finally {
      revokingAccountSessionTokens.remove(session.token);
      if (mounted) _updateState(() {});
    }
  }

  Future<void> _revokeAllAccountSessions() async {
    if (revokingAllAccountSessions) return;
    final security = accountSecurity;
    if (security == null) return;
    final sessions = security.sessions
        .where((session) => !_isCurrentAccountSession(session))
        .toList(growable: false);
    if (sessions.isEmpty) return;

    _updateState(() {
      revokingAllAccountSessions = true;
      revokingAccountSessionTokens
          .addAll(sessions.map((session) => session.token));
    });
    final revokedTokens = <String>[];
    var failed = false;
    try {
      await Future.wait(sessions.map((session) async {
        try {
          await widget.dataSource.revokeAccountSession(session.token);
          revokedTokens.add(session.token);
        } catch (_) {
          failed = true;
        }
      }));
      final current = accountSecurity;
      if (current != null && revokedTokens.isNotEmpty) {
        final revoked = revokedTokens.toSet();
        accountSecurity = current.copyWith(
          sessions: current.sessions
              .where((session) => !revoked.contains(session.token))
              .toList(growable: false),
        );
      }
      if (failed && mounted) {
        _showSnackBar('Some sessions could not be revoked.',
            type: ToastType.error);
      }
    } finally {
      revokingAccountSessionTokens.removeAll(sessions.map((s) => s.token));
      if (mounted) {
        _updateState(() => revokingAllAccountSessions = false);
      } else {
        revokingAllAccountSessions = false;
      }
    }
  }

  Future<void> _deleteAccount() async {
    if (deletingAccount) return;
    final confirmEmail = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (_) =>
          DeleteAccountDialog(email: store.auth.viewer?.email ?? ''),
    );
    if (confirmEmail == null || !mounted) return;
    _updateState(() => deletingAccount = true);
    try {
      await widget.dataSource.deleteAccount(confirmEmail: confirmEmail);
      await store.markAccountDeleted();
      if (!mounted) return;
      deletingAccount = false;
      selectedSpaceId = null;
      _enterUnauthenticatedState();
    } catch (error) {
      if (!mounted) return;
      _updateState(() => deletingAccount = false);
      _showSnackBar(error.toString(), type: ToastType.error);
    }
  }

  Future<void> _uploadAvatar() async {
    if (avatarUploadBusy) return;
    AxAvatarFile? selected;
    try {
      selected = await pickAvatarFile();
    } on Object catch (error) {
      if (mounted) _showSnackBar(error.toString());
      return;
    }
    if (selected == null || !mounted) return;
    _updateState(() => avatarUploadBusy = true);
    try {
      final url = await widget.dataSource.uploadAvatar(
        bytes: selected.bytes,
        thumbnailBytes: selected.thumbnailBytes,
        mediaType: selected.mediaType,
      );
      final viewer = store.auth.viewer;
      if (viewer != null) {
        store.auth.viewer = viewer.copyWith(avatarUrl: url);
      }
      if (mounted) {
        _updateState(() => viewerAvatarBytes = selected!.thumbnailBytes);
      }
      await _loadViewerAvatar(url);
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    } finally {
      if (mounted) _updateState(() => avatarUploadBusy = false);
    }
  }

  Future<void> _loadViewerAvatar(String? url) async {
    if (url == null || url.isEmpty) {
      if (mounted) {
        _updateState(() => viewerAvatarBytes = null);
      }
      return;
    }
    try {
      final bytes = await widget.dataSource.loadAvatar(url: url);
      if (!mounted || store.auth.viewer?.avatarUrl != url) return;
      if (bytes != null && bytes.isNotEmpty) {
        _updateState(() => viewerAvatarBytes = bytes);
      }
    } catch (error) {
      if (mounted) _showSnackBar('Could not load your avatar: $error');
    }
  }

  Future<void> _editDisplayName() async {
    var draft = store.auth.viewer?.displayName ?? '';
    final value = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename profile'),
        content: TextFormField(
          initialValue: draft,
          onChanged: (value) => draft = value,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: 'Name'),
          onFieldSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(draft),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final name = value?.trim() ?? '';
    if (name.isEmpty || !mounted) return;
    try {
      await widget.dataSource.updateDisplayName(displayName: name);
      final viewer = store.auth.viewer;
      if (viewer != null) {
        store.auth.viewer = viewer.copyWith(displayName: name);
      }
      if (mounted) _updateState(() {});
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  Future<void> _editEmail() async {
    final source = widget.dataSource;
    final email = await showDialog<String>(
      context: navigatorKey.currentContext ?? context,
      barrierDismissible: false,
      builder: (_) => EmailChangeDialog(
        currentEmail: store.auth.viewer?.email ?? 'your current address',
        requestCode: (newEmail) =>
            source.requestEmailChangeCode(newEmail: newEmail),
        verifyNewEmail: (code) => source.verifyNewEmailCode(code: code),
        confirm: (code) => source.confirmEmailChange(code: code),
      ),
    );
    if (email == null || !mounted) return;
    final viewer = store.auth.viewer;
    if (viewer != null) {
      store.auth.viewer = viewer.copyWith(email: email);
    }
    _updateState(() {});
    _showSnackBar('Email updated.');
  }

  Future<void> _unlinkAccountProvider(AxAuthAccount account) async {
    if (unlinkingAccountIds.isNotEmpty) return;
    final sessionId = store.auth.session?.sessionId;
    final provider = _providerLabel(account.providerId);
    final confirmed = await showDialog<bool>(
      context: navigatorKey.currentContext ?? context,
      builder: (context) => AlertDialog(
        title: Text('Unlink $provider?'),
        content: Text(
            'You will no longer be able to sign in with this $provider account. '
            'Make sure you have another sign-in method before continuing.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        store.auth.session?.sessionId != sessionId ||
        unlinkingAccountIds.isNotEmpty) {
      return;
    }
    unlinkingAccountIds.add(account.id);
    _updateState(() => accountUnlinkError = null);
    try {
      await widget.dataSource.unlinkAccount(accountId: account.id);
      if (!mounted || store.auth.session?.sessionId != sessionId) return;
      final current = accountSecurity;
      if (current != null) {
        accountSecurity = current.copyWith(
            accounts: current.accounts
                .where((item) => item.id != account.id)
                .toList());
      }
      await _loadAccountSecurity();
      if (mounted && store.auth.session?.sessionId == sessionId) {
        _showSnackBar('${_providerLabel(account.providerId)} unlinked.');
      }
    } catch (error) {
      if (mounted && store.auth.session?.sessionId == sessionId) {
        _updateState(() => accountUnlinkError = error.toString());
      }
    } finally {
      unlinkingAccountIds.remove(account.id);
      if (mounted) _updateState(() {});
    }
  }

  Future<void> _linkAccountProvider(String provider) async {
    try {
      final uri = await widget.dataSource
          .beginAccountLink(provider, Uri(path: '/settings/profile'));
      browserNavigation.openExternal(uri);
    } catch (error) {
      if (mounted) _showSnackBar(error.toString());
    }
  }

  /// Returns true when the bootstrap snapshot (Spaces, Workspaces, viewer)
  /// was loaded and applied.
  Future<bool> _loadBootstrapState(
      {String? spaceId, String? workspaceId, bool showSpinner = true}) async {
    if (store.auth.session?.authenticated != true) return false;
    final resolvedSpaceId = spaceId;
    if (showSpinner) {
      final reconnecting = !isLoading && store.spaces.items.isNotEmpty;
      _updateState(() {
        isLoading = true;
        loadError = null;
        isReconnecting = reconnecting;
      });
    }
    try {
      final loaded = await store.loadBootstrapState(
          spaceId: resolvedSpaceId, workspaceId: workspaceId);
      if (!mounted) return false;
      unawaited(store.people
          .ensure()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      unawaited(Future.wait<void>([
        store.invitations.refresh(),
        store.refreshWorkspaceInvitations(),
      ]).then<void>((_) => _knownInvitationIds ??= _currentInvitationIds(),
          onError: (Object _, StackTrace __) {}));
      optimisticRunStatus = null;
      if (showSpinner) {
        _updateState(() {
          selectedSpaceId = loaded.spaces.any(
                  (space) => space.id == (resolvedSpaceId ?? selectedSpaceId))
              ? (resolvedSpaceId ?? selectedSpaceId)
              : loaded.spaces.firstOrNull?.id;
          isLoading = false;
          isReconnecting = false;
          authRequired = false;
          _applySpaceNavigation();
        });
      }
      _ensureNavigationResources(navigation);
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (error is AxApiException && error.statusCode == 401) {
        _enterUnauthenticatedState();
        return false;
      }
      if (!showSpinner) {
        _showSnackBar(error.toString(), type: ToastType.error);
        return false;
      }
      _updateState(() {
        isLoading = false;
        isReconnecting = false;
        loadError = error.toString();
      });
    }
    return false;
  }

  Future<void> _verifySessionAfterDisconnect() {
    return _disconnectSessionCheck ??=
        _syncSession().whenComplete(() => _disconnectSessionCheck = null);
  }

  Future<void> _syncSession() async {
    try {
      final session = await store.auth.load();
      if (!mounted) return;
      if (session.authenticated &&
          store.persistence.userId != null &&
          store.persistence.userId != session.viewer?.id) {
        store.clearServerState();
        expandedSpaceIds.clear();
        _sidebarRestoredSpaceIds.clear();
        _updateState(() => authRequired = true);
      }
      if (!session.authenticated && !authRequired) {
        store.clearServerState();
        expandedSpaceIds.clear();
        _sidebarRestoredSpaceIds.clear();
        _enterUnauthenticatedState();
        return;
      }
      if (session.authenticated && authRequired) {
        final target = navigation.loginReturnTo == null
            ? const AxNavigation.home()
            : AxNavigation.fromUri(
                Uri.parse(navigation.loginReturnTo!),
              );
        _updateState(() {
          navigation = target;
          authRequired = false;
          isLoading = true;
          loadError = null;
        });
        browserNavigation.replace(target.toUri());
        final hydrated = await store.hydrateReadCache();
        if (!mounted) return;
        if (hydrated) {
          _updateState(() {
            isLoading = false;
            _applySpaceNavigation();
          });
        }
        final bootstrapped = await _loadBootstrapState(showSpinner: !hydrated);
        if (mounted && store.auth.session?.authenticated == true) {
          if (mounted && store.auth.session?.authenticated == true) {
            await _loadWorkspaces(fetch: !bootstrapped);
          }
        }
      }
    } catch (_) {
      // The normal load/error path will explain an unavailable auth service.
    }
  }

  void _applySpaceNavigation() {
    final routeSpace = navigation.spaceId;
    if (routeSpace != null &&
        store.spaces.items.any((space) => space.id == routeSpace)) {
      selectedSpaceId = routeSpace;
    }
  }

  /// Navigation is applied synchronously before independent resource requests.
  void _ensureNavigationResources(AxNavigation target) {
    final spaceId = target.spaceId;
    if (spaceId == null || store.auth.session?.authenticated != true) return;
    unawaited(store.spaceDetails
        .ensure(spaceId)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(store.spaceThreads.ensure(spaceId).then<void>(
        (_) => _scheduleMarkViewedRead(),
        onError: (Object _, StackTrace __) {}));
  }

  void _onBrowserNavigation(Uri uri) {
    final next = AxNavigation.fromUri(uri);
    final canonicalUri = next.toUri();
    if (!_isCanonicalWorkspaceUri(uri, canonicalUri)) {
      browserNavigation.replace(canonicalUri);
    }
    if (next == navigation) return;
    _updateState(() {
      navigation = next;
      final spaceId = next.spaceId;
      selectedSpaceId = spaceId ?? selectedSpaceId;
      if (next.kind == AxRouteKind.thread && spaceId != null) {
        expandedSpaceIds.add(spaceId);
      }
    });
    if (next.kind == AxRouteKind.profileSecurity) {
      unawaited(_loadAccountSecurity());
    }
    _ensureNavigationResources(next);
    unawaited(realtimeClient.setScopes(
      spaceId: next.spaceId ?? selectedSpaceId,
      threadId: next.threadId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  bool _isCanonicalWorkspaceUri(Uri actual, Uri canonical) =>
      actual.path == canonical.path &&
      mapEquals(actual.queryParameters, canonical.queryParameters);

  void _navigateTo(AxNavigation next,
      {bool replace = false, bool expandThreadSpace = true}) {
    if ((next.spaceId?.startsWith('local-space-') ?? false) ||
        (next.spaceId?.startsWith('local-space-') ?? false) ||
        (next.threadId?.startsWith('local-thread-') ?? false) ||
        (next.threadId?.startsWith('local-thread-') ?? false)) {
      return;
    }
    if (next.kind != AxRouteKind.search &&
        _searchQueryController.text.isNotEmpty) {
      _searchQueryController.removeListener(_onSearchQueryChanged);
      _searchQueryController.clear();
      _searchQuery = '';
      _navigationBeforeSearch = null;
      _searchQueryController.addListener(_onSearchQueryChanged);
    }
    _updateState(() {
      navigation = next;
      final spaceId = next.spaceId;
      selectedSpaceId = spaceId ?? selectedSpaceId;
      if (expandThreadSpace &&
          next.kind == AxRouteKind.thread &&
          spaceId != null) {
        expandedSpaceIds.add(spaceId);
      }
    });
    if (replace) {
      browserNavigation.replace(next.toUri());
    } else {
      browserNavigation.push(next.toUri());
    }
    _ensureNavigationResources(next);
    unawaited(realtimeClient.setScopes(
      spaceId: next.spaceId ?? selectedSpaceId,
      threadId: next.threadId,
      runId: next.runId,
      executionWorkspaceId: executionWorkspaceId,
    ));
  }

  void _handleContextualCreate() {
    if (isLoading ||
        authRequired ||
        loadError != null ||
        desktopAuthApproved ||
        desktopAuthCancelled ||
        navigation.kind == AxRouteKind.desktopAuthApproval) {
      return;
    }
    final space = selectedSpace;
    if (space != null) {
      _createThread(space);
    } else {
      _createSpace();
    }
  }
}
