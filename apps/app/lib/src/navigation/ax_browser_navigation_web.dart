// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

import 'ax_browser_route.dart';
import 'ax_browser_navigation_stub.dart';

export 'ax_browser_navigation_stub.dart'
    show AxBrowserNavigation, AxBrowserConnectivity, AxBrowserVisibility;

AxBrowserNavigation createAxBrowserNavigation() => _WebAxBrowserNavigation();

final class _WebAxBrowserNavigation
    implements AxBrowserNavigation, AxBrowserConnectivity, AxBrowserVisibility {
  final _connectivity = StreamController<bool>.broadcast(sync: true);
  final _subscriptions = <StreamSubscription<html.Event>>[];
  _WebAxBrowserNavigation() {
    _subscriptions
        .add(html.window.onOnline.listen((_) => _connectivity.add(true)));
    _subscriptions
        .add(html.window.onOffline.listen((_) => _connectivity.add(false)));
  }
  @override
  bool get visible => html.document.visibilityState == 'visible';
  @override
  bool get online => html.window.navigator.onLine ?? true;
  @override
  Stream<bool> get connectivityChanges => _connectivity.stream;
  static const _statePrefix = 'syntila-route-v1:';
  static const _oauthReturnKey = 'syntila-oauth-return-v1';

  Uri _current() {
    final location = Uri.parse(html.window.location.href);
    final address = Uri(
        path: location.path,
        query: location.hasQuery ? location.query : null,
        fragment: location.hasFragment ? location.fragment : null);
    final state = html.window.history.state;
    final stored = state is String && state.startsWith(_statePrefix)
        ? state.substring(_statePrefix.length)
        : null;
    var internal = AxBrowserRoute.restore(address, stored);
    // OAuth leaves this document; sessionStorage survives the same-tab return.
    try {
      final pending = html.window.sessionStorage[_oauthReturnKey];
      if (pending != null) {
        final target = Uri.tryParse(pending);
        if (target != null && AxBrowserRoute.visible(target) == address) {
          internal = target;
          html.window.sessionStorage.remove(_oauthReturnKey);
        } else if (target != null &&
            address.path == '/login' &&
            address.queryParameters.containsKey('error')) {
          internal = address.replace(queryParameters: {
            ...address.queryParameters,
            'returnTo': target.toString(),
          });
          html.window.sessionStorage.remove(_oauthReturnKey);
        }
      }
    } catch (_) {
      // Storage can be unavailable in restricted browser contexts.
    }
    // Convert old deep links on entry, and persist restored OAuth state.
    if (AxBrowserRoute.visible(internal) != address ||
        (stored == null && internal != address)) {
      replace(internal);
    }
    return internal;
  }

  @override
  Uri get current => _current();

  @override
  Stream<Uri> get changes => html.window.onPopState.map((_) => _current());

  @override
  Stream<void> get lifecycleChanges => html.document.onVisibilityChange
      .where((_) => html.document.visibilityState == 'visible')
      .map((_) {});

  @override
  void push(Uri uri) => html.window.history.pushState(
      '$_statePrefix$uri', '', AxBrowserRoute.visible(uri).toString());

  @override
  void replace(Uri uri) => html.window.history.replaceState(
      '$_statePrefix$uri', '', AxBrowserRoute.visible(uri).toString());

  @override
  void replaceWithLogin(Uri returnTo) {
    if (returnTo.path == '/login') {
      replace(returnTo);
      return;
    }
    final returnToString = returnTo.toString();
    final uri = Uri(
      path: '/login',
      queryParameters: (returnToString.isEmpty || returnToString == '/')
          ? null
          : {'returnTo': returnToString},
    );
    replace(uri);
  }

  @override
  void startSocialLogin(String provider, Uri returnTo) {
    // Same API base as every other request: in local development the Cloud
    // Worker and this app run on different ports, so a bare '/api' path would
    // hit the app's own dev server. The return target is an absolute URL of
    // this app; Cloud accepts only its own or the configured app origin.
    const configuredApi = String.fromEnvironment('SYNTILA_API_URL');
    final apiBase = configuredApi.isNotEmpty ? configuredApi : '/api';
    var visibleReturn = returnTo;
    try {
      html.window.sessionStorage[_oauthReturnKey] = returnTo.toString();
      visibleReturn = AxBrowserRoute.visible(returnTo);
    } catch (_) {
      // Preserve login return behavior when browser storage is unavailable.
    }
    final uri = Uri.parse('$apiBase/auth/sign-in/$provider').replace(
      queryParameters: {
        'returnTo': Uri.base.resolveUri(visibleReturn).toString()
      },
    );
    html.window.location.assign(uri.toString());
  }

  @override
  void openExternal(Uri uri) => html.window.open(uri.toString(), '_blank');

  @override
  bool closeCurrentWindow() {
    html.window.close();
    return html.window.closed ?? false;
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_connectivity.close());
  }
}
