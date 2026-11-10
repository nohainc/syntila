import 'ax_navigation.dart';

/// Converts internal routes to address-bar routes. The internal URI is kept in
/// the history entry, not in the address; it is not a security credential.
class AxBrowserRoute {
  static Uri visible(Uri internal) {
    final route = AxNavigation.fromUri(internal);
    switch (route.kind) {
      case AxRouteKind.space:
        return Uri(path: '/space');
      case AxRouteKind.spaceMembers:
        return Uri(path: '/space/members');
      case AxRouteKind.thread:
        return Uri(path: '/thread');
      case AxRouteKind.run:
        return Uri(path: '/run');
      case AxRouteKind.workspaces:
        if (route.workspaceId != null) return Uri(path: '/workspaces');
        break;
      case AxRouteKind.login:
        final returnTo = route.loginReturnTo;
        if (returnTo != null) {
          final target = Uri.tryParse(returnTo);
          if (target != null &&
              visible(target).toString() != target.toString()) {
            final query = Map<String, String>.of(internal.queryParameters)
              ..remove('returnTo');
            return Uri(
              path: internal.path,
              queryParameters: query.isEmpty ? null : query,
              fragment: internal.hasFragment ? internal.fragment : null,
            );
          }
        }
        break;
      default:
        break;
    }
    return internal;
  }

  /// Only restore state when it belongs to the displayed address. Without
  /// state, clean detail addresses safely open their parent section.
  static Uri restore(Uri address, String? stored) {
    final candidate = stored == null ? null : Uri.tryParse(stored);
    if (candidate != null &&
        visible(candidate).toString() == address.toString()) {
      return candidate;
    }
    if (address.path == '/space' ||
        address.path == '/space/members' ||
        address.path == '/thread' ||
        address.path == '/run') {
      return Uri(path: '/spaces');
    }
    return address;
  }
}
