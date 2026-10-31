part of 'ax_app.dart';

extension _AxAppShellViews on _AxAppStateMixin {
  Widget _buildApp(BuildContext context) {
    return MaterialApp(
      title: 'Syntila',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      theme: SyntilaBrand.lightTheme(),
      darkTheme: SyntilaBrand.darkTheme(),
      themeMode: _themeMode,
      builder: (context, child) {
        // Multiplies the OS text size, capped so layouts stay usable.
        final media = MediaQuery.of(context);
        final system = media.textScaler.scale(1);
        return MediaQuery(
          data: media.copyWith(
              textScaler: TextScaler.linear(
                  (system * _viewPreferences.textSize.scale).clamp(1.0, 1.6))),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
              _handleContextualCreate,
          const SingleActivator(LogicalKeyboardKey.keyN, control: true):
              _handleContextualCreate,
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  if (desktopAuthApproved || desktopAuthCancelled) {
                    return _desktopAuthApprovalView();
                  }
                  if (isLoading) return _loadingScaffold();
                  if (authRequired) return _authScaffold();
                  if (loadError != null) return _errorScaffold();
                  if (navigation.kind == AxRouteKind.desktopAuthApproval) {
                    return _desktopAuthApprovalView();
                  }
                  final isDesktop =
                      SyntilaBrand.isDesktop(constraints.maxWidth);
                  final shell = _shellContext;
                  return Scaffold(
                    body: Row(
                      children: [
                        if (isDesktop)
                          _desktopSidebarCollapsed
                              ? AxIconRail(
                                  shellContext: shell,
                                  onNavigateTo: _navigateTo,
                                  onOpenDrawer: () {},
                                  onCreateSpace: _createSpace,
                                  onCreateThread: _createThread,
                                  searchController: _searchQueryController,
                                  searchFocusNode: _searchFocusNode,
                                  onSearchChanged: (_) =>
                                      _onSearchQueryChanged(),
                                  onClearSearch: _clearSearch,
                                  onOpenCommandPalette: _openCommandPalette,
                                  onOpenNotifications: _showNotifications,
                                  onToggleTheme: _toggleTheme,
                                  onSetThemeMode: _setThemeMode,
                                  onLogout: () => unawaited(_logout()),
                                  onOpenAbout: () =>
                                      unawaited(_showAboutSyntila()),
                                  onOpenExternal: (uri) =>
                                      browserNavigation.openExternal(uri),
                                  onOpenArchivedSpaces: _openArchivedSpaces,
                                  onToggleCollapse: () => _updateState(
                                      () => _desktopSidebarCollapsed = false),
                                )
                              : ResizableSidebar(
                                  width: _desktopSidebarWidth,
                                  onWidthChanged: (width) => _updateState(
                                      () => _desktopSidebarWidth = width),
                                  child: AxSidebar(
                                    shellContext: shell,
                                    onNavigateTo: _navigateTo,
                                    onNavigateToRecentThread: (next) =>
                                        _navigateTo(next,
                                            expandThreadSpace: false),
                                    onToggleSpaceExpanded: _toggleSpaceExpanded,
                                    onCreateSpace: _createSpace,
                                    onCreateThread: _createThread,
                                    onEditSpace: _editSpace,
                                    onArchiveSpace: _archiveSpace,
                                    onDeleteSpace: (space) =>
                                        _deleteSpace(space.id),
                                    onRenameThread: _renameThreadFromSidebar,
                                    onSetThreadArchived:
                                        _setThreadArchivedFromSidebar,
                                    onDeleteThread: _deleteThreadFromSidebar,
                                    onReorderThreads:
                                        _reorderThreadsFromSidebar,
                                    onSetSpacePinned:
                                        _setSpacePinnedFromSidebar,
                                    onSetThreadPinned:
                                        _setThreadPinnedFromSidebar,
                                    onReorderPinnedSpaces:
                                        _setSpacePinOrderFromSidebar,
                                    onReorderPinnedThreads:
                                        _setThreadPinOrderFromSidebar,
                                    searchController: _searchQueryController,
                                    searchFocusNode: _searchFocusNode,
                                    onClearSearch: _clearSearch,
                                    onOpenCommandPalette: _openCommandPalette,
                                    onOpenNotifications: _showNotifications,
                                    onToggleTheme: _toggleTheme,
                                    onSetThemeMode: _setThemeMode,
                                    onLogout: () => unawaited(_logout()),
                                    onOpenAbout: () =>
                                        unawaited(_showAboutSyntila()),
                                    onOpenExternal: (uri) =>
                                        browserNavigation.openExternal(uri),
                                    onOpenArchivedSpaces: _openArchivedSpaces,
                                    onToggleCollapse: () => _updateState(
                                        () => _desktopSidebarCollapsed = true),
                                  ),
                                ),
                        Expanded(
                          child: _content(
                            compact: !isDesktop,
                            showTopHud: !isDesktop,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadingScaffold() => Scaffold(
        body: Center(
          child: Semantics(
            liveRegion: true,
            label: 'Loading your Syntila workspace',
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 18),
                    Text('Loading your workspace',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    const Text(
                        'Your existing work stays safe while Syntila connects.',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
  Widget _authScaffold() {
    final returnTo = navigation.loginReturnTo == null
        ? Uri(path: '/')
        : Uri.parse(navigation.loginReturnTo!);
    final resetToken = navigation.loginToken ??
        browserNavigation.current.queryParameters['token'];
    final resetPassword = resetToken != null;
    final awaitingSignUpCode =
        !resetPassword && authSignUp && authSignUpAwaitingCode;
    final oauthError = _oauthErrorMessage(
      navigation.loginError ??
          browserNavigation.current.queryParameters['error'],
    );
    final pendingDesktopAppName = _intentIdFromNavigation(navigation) != null
        ? (desktopAuthIntentStatus?.applicationName ?? 'your desktop app')
        : null;
    final title = resetPassword
        ? 'Choose a new password'
        : authResetRequest
            ? 'Restore your password'
            : awaitingSignUpCode
                ? 'Verify your email address'
                : authSignUp
                    ? 'Create your account'
                    : 'Welcome to Syntila';
    return _authFormFrame(AutofillGroup(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SyntilaBrand.logoMark(size: 52),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
          if (resetPassword ||
              authResetRequest ||
              authSignUp ||
              awaitingSignUpCode ||
              pendingDesktopAppName != null) ...[
            const SizedBox(height: 8),
            Text(
                resetPassword
                    ? 'Choose a strong password for your account.'
                    : authResetRequest
                        ? 'Enter your email and we will send a reset link if an account exists.'
                        : awaitingSignUpCode
                            ? 'Enter the 6-digit verification code we sent to ${authEmailController.text.trim()}.'
                            : authSignUp
                                ? 'Create an account to start using Syntila. We will send a one-time code to verify your email.'
                                : 'Sign in to continue approving $pendingDesktopAppName.',
                textAlign: TextAlign.center),
          ],
          const SizedBox(height: 20),
          if (!resetPassword && authSignUp && !awaitingSignUpCode) ...[
            TextField(
              controller: authNameController,
              autofocus: true,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
          ],
          if (!resetPassword && !awaitingSignUpCode) ...[
            TextField(
              controller: authEmailController,
              autofocus: !authSignUp,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction: authResetRequest
                  ? TextInputAction.done
                  : TextInputAction.next,
              onSubmitted: (_) {
                if (authResetRequest) {
                  _submitEmailAuth();
                }
              },
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            if (!authResetRequest) const SizedBox(height: 10),
          ],
          if ((resetPassword || !authResetRequest) && !awaitingSignUpCode) ...[
            TextField(
              controller: authPasswordController,
              autofocus: resetPassword,
              obscureText: !authPasswordVisible,
              autofillHints: [
                if (authSignUp || resetPassword)
                  AutofillHints.newPassword
                else
                  AutofillHints.password,
              ],
              textInputAction: (!authSignUp && !resetPassword)
                  ? TextInputAction.done
                  : TextInputAction.next,
              onSubmitted: (_) {
                if (!authSignUp && !resetPassword) {
                  _submitEmailAuth();
                }
              },
              decoration: InputDecoration(
                labelText: 'Password',
                hintText: (authSignUp || resetPassword)
                    ? 'At least 8 characters'
                    : null,
                suffixIcon: IconButton(
                  tooltip:
                      authPasswordVisible ? 'Hide password' : 'Show password',
                  icon: Icon(
                    authPasswordVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  onPressed: () => _updateState(
                      () => authPasswordVisible = !authPasswordVisible),
                ),
              ),
            ),
            if (authSignUp || resetPassword) ...[
              const SizedBox(height: 10),
              TextField(
                controller: authConfirmPasswordController,
                obscureText: !authConfirmPasswordVisible,
                autofillHints: const [AutofillHints.newPassword],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitEmailAuth(),
                decoration: InputDecoration(
                  labelText: 'Confirm password',
                  suffixIcon: IconButton(
                    tooltip: authConfirmPasswordVisible
                        ? 'Hide password'
                        : 'Show password',
                    icon: Icon(
                      authConfirmPasswordVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    onPressed: () => _updateState(() =>
                        authConfirmPasswordVisible =
                            !authConfirmPasswordVisible),
                  ),
                ),
              ),
            ],
          ],
          if (awaitingSignUpCode) ...[
            TextField(
              controller: authVerificationCodeController,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              textInputAction: TextInputAction.done,
              maxLength: 6,
              onSubmitted: (_) => _submitEmailAuth(),
              decoration: const InputDecoration(
                labelText: 'Verification code',
                hintText: '6-digit code',
                counterText: '',
              ),
            ),
          ],
          if (authError != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(authError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: SyntilaColors.errorText(
                          Theme.of(context).brightness == Brightness.dark))),
            ),
          ],
          if (authError == null && oauthError != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(oauthError,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: SyntilaColors.errorText(
                          Theme.of(context).brightness == Brightness.dark))),
            ),
          ],
          if (authNotice != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(authNotice!, textAlign: TextAlign.center),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: authBusy ? null : _submitEmailAuth,
              child: Text(authBusy
                  ? 'Please wait…'
                  : resetPassword
                      ? 'Save new password'
                      : authResetRequest
                          ? 'Email reset link'
                          : awaitingSignUpCode
                              ? 'Verify & create account'
                              : authSignUp
                                  ? 'Create account'
                                  : 'Sign in with email'),
            ),
          ),
          if (awaitingSignUpCode)
            TextButton(
              onPressed: authBusy ? null : _resendSignUpCode,
              child: const Text('Resend code'),
            ),
          if (!resetPassword && !authSignUp && !authResetRequest)
            Align(
              alignment: Alignment.center,
              child: TextButton(
                onPressed: authBusy
                    ? null
                    : () => _updateState(() {
                          authResetRequest = true;
                          authError = null;
                          authNotice = null;
                        }),
                child: const Text('Forgot password?'),
              ),
            ),
          if (!resetPassword && !authResetRequest && !authSignUp)
            TextButton(
              onPressed: authBusy
                  ? null
                  : () => _updateState(() {
                        authSignUp = !authSignUp;
                        _resetSensitiveAuthInputs();
                        authError = null;
                        authNotice = null;
                      }),
              child: const Text('New here? Create an account'),
            ),
          if (resetPassword || authResetRequest || authSignUp)
            TextButton(
              onPressed: authBusy
                  ? null
                  : () {
                      if (resetPassword) {
                        final nextLogin = AxNavigation.login(
                          returnTo: navigation.loginReturnTo,
                        );
                        browserNavigation.replace(
                          nextLogin.toUri(),
                        );
                        _updateState(() {
                          navigation = nextLogin;
                          _resetSensitiveAuthInputs();
                          authError = null;
                          authNotice = null;
                        });
                        return;
                      }
                      _updateState(() {
                        authSignUp = false;
                        _resetSensitiveAuthInputs();
                        authResetRequest = false;
                        authError = null;
                        authNotice = null;
                      });
                    },
              child: const Text('Back to sign in'),
            ),
          if (!resetPassword && !authResetRequest && !authSignUp) ...[
            const Divider(height: 28),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: authBusy
                    ? null
                    : () =>
                        browserNavigation.startSocialLogin('github', returnTo),
                icon: Builder(
                    builder: (context) =>
                        _accountProviderIcon(context, 'github', size: 20)),
                label: const Text('Continue with GitHub'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: authBusy
                    ? null
                    : () =>
                        browserNavigation.startSocialLogin('google', returnTo),
                icon: Builder(
                    builder: (context) =>
                        _accountProviderIcon(context, 'google', size: 20)),
                label: const Text('Continue with Google'),
              ),
            ),
          ],
        ],
      ),
    ));
  }

  /// Shared sizing for login, signup, recovery and desktop authorization.
  Widget _authFormFrame(Widget content) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  // Keep form autofocus independent of the shell shortcut focus.
                  child: FocusScope(
                    child: SizedBox(width: double.infinity, child: content),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _desktopAuthApprovalView() {
    final appName =
        desktopAuthIntentStatus?.applicationName ?? 'desktop application';
    if (desktopAuthApproved || desktopAuthCancelled) {
      return _authFormFrame(Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(desktopAuthApproved ? 'Sign-in approved' : 'Sign-in canceled',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(desktopAuthApproved
              ? 'Return to $appName to finish signing in.'
              : 'This sign-in request was canceled.'),
          const SizedBox(height: 8),
          const Text('You can close this page, window, or tab.'),
        ],
      ));
    }
    final user = store.auth.viewer;
    return _authFormFrame(Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Sign in to $appName',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(desktopAuthIntentStatus == null
            ? 'Loading the desktop sign-in request…'
            : desktopAuthIntentStatus!.applicationName == null
                ? 'This request came from an unsupported desktop app. It cannot be approved here.'
                : 'Approve sign-in to $appName for ${user?.displayName ?? user?.email ?? 'your account'}? Return to that app after approval.'),
        const SizedBox(height: 22),
        if (desktopAuthError != null) ...[
          const SizedBox(height: 8),
          Text(desktopAuthError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed:
              desktopAuthBusy || desktopAuthIntentStatus?.canApprove != true
                  ? null
                  : _approveDesktopAuth,
          child: Text(desktopAuthBusy ? 'Approving…' : 'Approve sign-in'),
        ),
        TextButton(
          onPressed: desktopAuthBusy ? null : _cancelDesktopAuthFromBrowser,
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: desktopAuthBusy
              ? null
              : () => unawaited(_switchAccountForDesktopAuth()),
          child: const Text('Switch account'),
        ),
      ],
    ));
  }

  Future<void> _switchAccountForDesktopAuth() async {
    _updateState(() {
      desktopAuthBusy = true;
      desktopAuthError = null;
    });
    try {
      await _logout();
    } finally {
      if (mounted) {
        _updateState(() => desktopAuthBusy = false);
      }
    }
  }

  Future<void> _approveDesktopAuth() async {
    final intentId = navigation.desktopAuthIntentId;
    if (intentId == null || desktopAuthIntentStatus?.canApprove != true) {
      _updateState(() => desktopAuthError =
          'This desktop sign-in request is incomplete or unsupported. Start again from the requesting app.');
      return;
    }
    _updateState(() {
      desktopAuthBusy = true;
      desktopAuthError = null;
    });
    try {
      await widget.dataSource.approveDesktopAuthIntent(intentId: intentId);
      if (!mounted) return;
      browserNavigation.replace(Uri(path: '/'));
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthApproved = true;
      });
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthError = error.toString();
      });
    }
  }

  Future<void> _cancelDesktopAuthFromBrowser() async {
    final intentId = navigation.desktopAuthIntentId;
    if (intentId == null) {
      _navigateTo(const AxNavigation.home(), replace: true);
      return;
    }
    _updateState(() {
      desktopAuthBusy = true;
      desktopAuthError = null;
    });
    try {
      await widget.dataSource.denyDesktopAuthIntent(intentId: intentId);
      if (!mounted) return;
      browserNavigation.replace(Uri(path: '/'));
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthCancelled = true;
      });
      _desktopAuthStatusTimer?.cancel();
    } catch (error) {
      if (!mounted) return;
      _updateState(() {
        desktopAuthBusy = false;
        desktopAuthError = error.toString();
      });
    }
  }

  Widget _errorScaffold() => Scaffold(
        body: Center(
          child: _RecoveryPanel(
            icon: Icons.cloud_off_rounded,
            title: 'Syntila could not load live data',
            happened: loadError ?? 'The workspace connection did not respond.',
            safe: 'Your existing work is safe. No new work was started.',
            nextStep: 'Check your connection, then try again.',
            retrying: isReconnecting,
            onRetry: () => _loadBootstrapState(),
          ),
        ),
      );
  Widget _threadContextBuilder(Widget Function() build) {
    final spaceId = navigation.spaceId;
    if (spaceId == null) return build();
    return AxQueryBuilder<List<AxThread>>(
      engine: store.spaceThreads.engine,
      query: store.spaceThreads.query(spaceId),
      builder: (context, state) => build(),
    );
  }

  Widget _spaceContextBuilder(Widget Function() build) {
    final spaceId = navigation.spaceId;
    if (spaceId == null) return build();
    return AxQueryBuilder<AxSpace>(
      key: ValueKey('space-context-$spaceId'),
      engine: store.syncEngine,
      query: store.spaceDetails.query(spaceId),
      builder: (context, state) {
        if (selectedSpace != null) return build();
        return Center(
            child: state.error != null
                ? TextButton(
                    onPressed: () => store.spaceDetails
                        .ensure(spaceId)
                        .then<void>((_) {},
                            onError: (Object _, StackTrace __) {}),
                    child: const Text('Retry Space'))
                : const Text('Loading Space…'));
      },
    );
  }

  bool get _mobileListRoute =>
      navigation.kind == AxRouteKind.home ||
      navigation.kind == AxRouteKind.spaces;

  Widget _mobileSpacesList({String? spaceId}) => SingleChildScrollView(
        key: PageStorageKey(spaceId == null
            ? 'mobile-spaces-list'
            : 'mobile-space-threads-$spaceId'),
        controller: spaceId == null ? _mobileSpacesScroll : null,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: SpaceTree(
          pageLayout: true,
          spaceIdFilter: spaceId,
          shellContext: _shellContext,
          onNavigateTo: _navigateTo,
          onToggleSpaceExpanded: (spaceId) {
            _updateState(() => selectedSpaceId = spaceId);
            _toggleSpaceExpanded(spaceId);
          },
          onCreateThread: _createThread,
          onEditSpace: _editSpace,
          onArchiveSpace: _archiveSpace,
          onDeleteSpace: (space) => _deleteSpace(space.id),
          onRenameThread: _renameThreadFromSidebar,
          onSetThreadArchived: _setThreadArchivedFromSidebar,
          onDeleteThread: _deleteThreadFromSidebar,
          onReorderThreads: _reorderThreadsFromSidebar,
          onSetSpacePinned: _setSpacePinnedFromSidebar,
          onSetThreadPinned: _setThreadPinnedFromSidebar,
          onReorderPinnedSpaces: _setSpacePinOrderFromSidebar,
          onReorderPinnedThreads: _setThreadPinOrderFromSidebar,
          onOpenInvitations: _showNotifications,
        ),
      );

  Widget _contentWidth(Widget child) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: SizedBox(width: double.infinity, child: child),
        ),
      );

  Widget _content({required bool compact, required bool showTopHud}) {
    return _spaceContextBuilder(() => Stack(
          children: [
            Column(children: [
              if (showTopHud)
                _threadContextBuilder(() => ListenableBuilder(
                    listenable: store.topBarChanges,
                    builder: (context, _) => AxTopBar(
                          shellContext: _shellContext,
                          onNavigateTo: (next) {
                            if (compact && next.kind == AxRouteKind.space) {
                              _updateState(() {
                                _mobileSpaceFilter = next.spaceId;
                                selectedSpaceId = next.spaceId;
                                expandedSpaceIds.add(next.spaceId!);
                              });
                              _navigateTo(const AxNavigation.spaces());
                            } else {
                              if (compact && next.kind == AxRouteKind.spaces) {
                                _updateState(() => _mobileSpaceFilter = null);
                              }
                              _navigateTo(next);
                            }
                          },
                          onOpenCommandPalette: _openCommandPalette,
                          onOpenNotifications: _showNotifications,
                          searchController: _searchQueryController,
                          searchFocusNode: _searchFocusNode,
                          onClearSearch: _clearSearch,
                          onToggleTheme: _toggleTheme,
                          onSetThemeMode: _setThemeMode,
                          onOpenArchivedSpaces: _openArchivedSpaces,
                          onOpenAbout: () => unawaited(_showAboutSyntila()),
                          onLogout: () => unawaited(_logout()),
                          onOpenExternal: (uri) =>
                              browserNavigation.openExternal(uri),
                          compact: compact,
                          onCreateSpace: _createSpace,
                        ))),
              Expanded(
                child: IndexedStack(
                  index: compact && _mobileListRoute ? 0 : 1,
                  sizing: StackFit.expand,
                  children: [
                    if (compact)
                      IndexedStack(
                        index: _mobileSpaceFilter == null ? 0 : 1,
                        sizing: StackFit.expand,
                        children: [
                          _mobileSpacesList(),
                          if (_mobileSpaceFilter != null)
                            _mobileSpacesList(spaceId: _mobileSpaceFilter)
                          else
                            const SizedBox.shrink(),
                        ],
                      )
                    else
                      const SizedBox.shrink(),
                    compact && _mobileListRoute
                        ? const SizedBox.shrink()
                        : navigation.kind == AxRouteKind.thread
                            ? Padding(
                                padding: EdgeInsets.zero,
                                child: _threadView(),
                              )
                            : navigation.kind == AxRouteKind.space
                                ? Padding(
                                    padding: EdgeInsets.zero,
                                    child: _spaceOverviewView(),
                                  )
                                : navigation.kind == AxRouteKind.notes ||
                                        navigation.kind == AxRouteKind.files
                                    // My Notes scrolls its own list so a note's
                                    // editor can use the full page height;
                                    // My Files scrolls its own list too.
                                    ? Padding(
                                        padding: EdgeInsets.fromLTRB(
                                            compact ? 18 : 34,
                                            26,
                                            compact ? 18 : 34,
                                            20),
                                        child: _contentWidth(
                                            _runDetailsView(compact)),
                                      )
                                    : navigation.kind ==
                                            AxRouteKind.spaceMembers
                                        ? SingleChildScrollView(
                                            padding: EdgeInsets.fromLTRB(
                                                compact ? 18 : 34,
                                                26,
                                                compact ? 18 : 34,
                                                40),
                                            child: _contentWidth(
                                                _spaceResourceView(
                                                    SpacePageSection.members)),
                                          )
                                        : SingleChildScrollView(
                                            padding: EdgeInsets.fromLTRB(
                                              compact ? 18 : 34,
                                              navigation.kind ==
                                                      AxRouteKind.workspaces
                                                  ? 0
                                                  : 26,
                                              compact ? 18 : 34,
                                              40,
                                            ),
                                            child: _contentWidth(showRunDetails
                                                ? _runDetailsView(compact)
                                                : _homeView()),
                                          ),
                  ],
                ),
              ),
            ]),
            Positioned(
              top: showTopHud ? 60 : 10,
              left: 20,
              right: 20,
              child: _FloatingRealtimeStatusBanner(
                key: const ValueKey('floating-realtime-status-banner'),
                realtimeStatus: store.realtimeStatus,
                lifecycleNotice: store.lifecycleNotice,
                realtimeNotice: realtimeNotice,
              ),
            ),
          ],
        ));
  }
}

/// User-facing text for an OAuth error code Cloud appends to `/login?error=`.
/// Returns null when there is no error to show.
String? _oauthErrorMessage(String? code) {
  if (code == null || code.isEmpty) return null;
  return switch (code) {
    'provider_not_configured' =>
      'Sign-in with this provider is not set up on this server yet.',
    'account_not_linked' =>
      'An account with this email already exists. Sign in with your email and '
          'password, then link Google or GitHub in your profile security settings.',
    'access_denied' => 'Sign-in was cancelled.',
    _ => 'Sign-in with the provider failed. Please try again.',
  };
}

class _FloatingRealtimeStatusBanner extends StatefulWidget {
  const _FloatingRealtimeStatusBanner({
    super.key,
    required this.realtimeStatus,
    required this.lifecycleNotice,
    this.realtimeNotice,
  });

  final ValueNotifier<(bool, String?)> realtimeStatus;
  final ValueNotifier<String?> lifecycleNotice;
  final String? realtimeNotice;

  @override
  State<_FloatingRealtimeStatusBanner> createState() =>
      _FloatingRealtimeStatusBannerState();
}

class _FloatingRealtimeStatusBannerState
    extends State<_FloatingRealtimeStatusBanner> {
  static const _connectionWarningDelay = Duration(seconds: 3);
  Timer? _dismissTimer;
  Timer? _pendingConnectionWarning;
  Timer? _pendingNotice;
  bool _visible = false;
  String? _lastNoticeKey;
  String? _visibleNotice;

  @override
  void initState() {
    super.initState();
    widget.realtimeStatus.addListener(_onNoticeChanged);
    widget.lifecycleNotice.addListener(_onNoticeChanged);
    _onNoticeChanged();
  }

  @override
  void didUpdateWidget(covariant _FloatingRealtimeStatusBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.realtimeStatus != widget.realtimeStatus) {
      oldWidget.realtimeStatus.removeListener(_onNoticeChanged);
      widget.realtimeStatus.addListener(_onNoticeChanged);
    }
    if (oldWidget.lifecycleNotice != widget.lifecycleNotice) {
      oldWidget.lifecycleNotice.removeListener(_onNoticeChanged);
      widget.lifecycleNotice.addListener(_onNoticeChanged);
    }
    if (oldWidget.realtimeNotice != widget.realtimeNotice) {
      _onNoticeChanged();
    }
  }

  @override
  void dispose() {
    widget.realtimeStatus.removeListener(_onNoticeChanged);
    widget.lifecycleNotice.removeListener(_onNoticeChanged);
    _dismissTimer?.cancel();
    _pendingConnectionWarning?.cancel();
    _pendingNotice?.cancel();
    super.dispose();
  }

  void _onNoticeChanged() {
    final status = widget.realtimeStatus.value;
    final lifecycle = widget.lifecycleNotice.value;
    final noticeText = lifecycle ?? widget.realtimeNotice ?? status.$2;
    final isActive = status.$1 || lifecycle != null || noticeText != null;

    if (!isActive || noticeText == null || noticeText.isEmpty) {
      _dismissTimer?.cancel();
      _pendingConnectionWarning?.cancel();
      _pendingNotice?.cancel();
      if (_visible) {
        setState(() {
          _visible = false;
          _visibleNotice = null;
        });
      }
      return;
    }

    // A short reconnect should be invisible. If the transport is still stale
    // after three seconds, show the warning; a connected confirmation is not
    // useful for the brief transitions this banner is meant to cover.
    final isConnectedNotice =
        lifecycle == null && noticeText == 'Live updates connected.';
    if (isConnectedNotice) {
      _dismissTimer?.cancel();
      _pendingConnectionWarning?.cancel();
      _pendingNotice?.cancel();
      if (_visible) {
        setState(() {
          _visible = false;
          _visibleNotice = null;
        });
      }
      _lastNoticeKey = '$isActive:$noticeText';
      return;
    }

    final isConnectionWarning = lifecycle == null && status.$1;
    if (isConnectionWarning) {
      final key = '$isActive:$noticeText';
      if (key == _lastNoticeKey &&
          (_pendingConnectionWarning?.isActive == true || _visible)) {
        return;
      }
      _lastNoticeKey = key;
      _dismissTimer?.cancel();
      _pendingConnectionWarning?.cancel();
      _pendingNotice?.cancel();
      if (_visible) {
        setState(() {
          _visible = false;
          _visibleNotice = null;
        });
      }
      _pendingConnectionWarning = Timer(_connectionWarningDelay, () {
        _pendingConnectionWarning = null;
        if (!mounted) return;
        final currentStatus = widget.realtimeStatus.value;
        final currentLifecycle = widget.lifecycleNotice.value;
        final currentNotice =
            currentLifecycle ?? widget.realtimeNotice ?? currentStatus.$2;
        final currentKey = '$isActive:${currentNotice ?? ''}';
        if (currentKey == key &&
            currentStatus.$1 &&
            currentLifecycle == null &&
            currentNotice != null &&
            currentNotice.isNotEmpty) {
          _showNotice(currentNotice);
        }
      });
      return;
    }

    _pendingConnectionWarning?.cancel();

    final key = '$isActive:$noticeText';
    if (key == _lastNoticeKey &&
        (_pendingNotice?.isActive == true || _visible)) {
      return;
    }
    _lastNoticeKey = key;
    _dismissTimer?.cancel();
    _pendingNotice?.cancel();
    if (_visible) {
      setState(() {
        _visible = false;
        _visibleNotice = null;
      });
    }
  }

  void _showNotice(String noticeText) {
    if (!mounted) return;
    setState(() {
      _visible = true;
      _visibleNotice = noticeText;
    });
    _dismissTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _visible = false;
          _visibleNotice = null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.realtimeStatus.value;
    final lifecycle = widget.lifecycleNotice.value;
    final noticeText = _visibleNotice ??
        lifecycle ??
        widget.realtimeNotice ??
        status.$2 ??
        'Live updates are reconnecting.';

    if (!_visible) return const SizedBox.shrink();

    return IgnorePointer(
      ignoring: true,
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Semantics(
          liveRegion: true,
          label: noticeText,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                color: SyntilaColors.surface(
                    Theme.of(context).brightness == Brightness.dark),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cloud_off_outlined,
                        size: 16,
                        color: SyntilaColors.warning,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          noticeText,
                          style: const TextStyle(
                            color: SyntilaColors.warning,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                              SyntilaColors.warning),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
