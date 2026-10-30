import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

import 'ax_fixture_snapshot.dart';

/// Test-only fixture source. Production Ax always uses AxApiClient.
class AxFixtureDataSource implements AxDataSource, AxPeopleDataSource {
  @override
  Future<List<AxPerson>> loadPeople() async => const [];
  @override
  Future<void> invitePersonToSpace(
      {required String spaceId,
      required String userId,
      required String role,
      required AxSpacePermissions permissions}) async {}
  const AxFixtureDataSource({this.authenticated = true});

  final bool authenticated;

  @override
  Future<String> createWorkRequest({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError('Work Request fixture is not configured');

  @override
  Future<String> createWorkRequestWithSelection({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    String? idempotencyKey,
    Map<String, dynamic>? replyTo,
  }) =>
      createWorkRequest(
          threadId: threadId,
          workflowId: workflowId,
          prompt: prompt,
          attachments: attachments,
          idempotencyKey: idempotencyKey);

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async =>
      const [];

  @override
  Future<List<String>> validateWorkRequestEligibilityWithSelection({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
  }) =>
      validateWorkRequestEligibility(
          threadId: threadId, workflowId: workflowId, attachments: attachments);

  @override
  Future<AxConversationHistoryPage> loadConversationHistory(
          {required String threadId,
          required String conversationId,
          int afterSequence = 0,
          int? throughSequence,
          int limit = 50}) async =>
      AxConversationHistoryPage.fromJson({
        'conversationId': conversationId,
        'historyRevision': 0,
        'throughSequence': 0,
        'entries': [],
        'nextCursor': null
      });
  @override
  Future<AxWorkRequestStatus> loadWorkRequest({
    required String workRequestId,
  }) async =>
      throw UnimplementedError('Work Request fixture is not configured');

  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage(
          {required String threadId,
          int limit = 50,
          String? beforeCreatedAt,
          String? beforeId,
          bool activeOnly = false}) async =>
      AxWorkRequestPage(
          requests: await workRequestRows(
              threadId: threadId, activeOnly: activeOnly));

  Future<List<AxWorkRequest>> workRequestRows({
    required String threadId,
    bool activeOnly = false,
  }) async =>
      const [];

  @override
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? sessionStrategy,
    bool clearAiHistory = false,
    bool compactContext = false,
    bool confirmSideEffects = false,
  }) async {}

  @override
  Future<void> cancelWorkRequest({required String workRequestId}) async {}

  @override
  Future<AxIssueReport?> loadIssueReport({
    required String requestId,
    String? assignmentId,
  }) async =>
      null;

  @override
  Future<AxIssueReport> reportIssue({required String requestId}) async =>
      throw UnimplementedError(
          'Work Request issue reporting fixture is not configured');

  @override
  Future<AxSession> loadSession() async => AxSession(
        authenticated: authenticated,
        sessionId: authenticated ? 'fixture-session' : null,
      );

  @override
  Future<void> updateDisplayName({required String displayName}) async {}

  @override
  Future<List<int>?> loadAvatar({required String url}) async => null;

  @override
  Future<AxEmailChangeStep> requestEmailChangeCode(
          {required String newEmail}) async =>
      AxEmailChangeStep(email: newEmail, stage: 'new');

  @override
  Future<AxEmailChangeStep> verifyNewEmailCode({required String code}) async {
    if (code != '111111') throw const AxApiException('Invalid code');
    return const AxEmailChangeStep(email: 'current', stage: 'current');
  }

  @override
  Future<String> confirmEmailChange({required String code}) async {
    if (code != '222222') throw const AxApiException('Invalid code');
    return 'changed@example.test';
  }

  @override
  Future<String> uploadAvatar({
    required List<int> thumbnailBytes,
    required List<int> bytes,
    required String mediaType,
  }) async =>
      'https://test/avatar.png';

  @override
  Future<void> logout() async {}

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {}

  @override
  Future<void> requestSignUpVerificationCode({
    required String email,
    String? name,
  }) async {}

  @override
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
    String? otp,
  }) async {}

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<void> resetPassword({
    required String token,
    required String password,
  }) async {}

  @override
  Future<AxSpace> createSpace(
          {required String name,
          String? description,
          String? instructions}) async =>
      AxSpace(
        id: 'space-created',
        name: name,
        branch: '',
        lastActivity: 'Just now',
      );

  @override
  Future<AxSpace> updateSpace({
    required String spaceId,
    String? name,
    String? description,
    String? instructions,
    Map<String, dynamic>? settings,
  }) async {
    final space =
        (await loadSpaces()).where((item) => item.id == spaceId).firstOrNull;
    return AxSpace(
      id: spaceId,
      name: name ?? space?.name ?? 'Updated space',
      branch: space?.branch ?? '',
      lastActivity: 'Just now',
      description: description ?? space?.description ?? '',
      instructions: instructions ?? space?.instructions ?? '',
      settings: settings ?? space?.settings ?? const {},
    );
  }

  @override
  Future<void> archiveSpace({required String spaceId}) async {}

  @override
  Future<void> deleteSpace({required String spaceId}) async {}

  @override
  Future<AxDiscussionPage> loadDiscussionPage(
          {required String threadId,
          int limit = 50,
          String? before,
          String? after}) async =>
      AxDiscussionPage(messages: await discussionRows(threadId: threadId));

  Future<List<AxDiscussionMessage>> discussionRows({
    required String threadId,
  }) async =>
      const [];

  @override
  Future<List<int>> downloadThreadFile(String threadId, String fileId) async =>
      throw UnimplementedError('No fixture file');

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String threadId,
    required String text,
    List<String> references = const [],
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,
    Map<String, dynamic>? replyTo,
  }) async =>
      AxDiscussionMessage(
        id: 'msg-${DateTime.now().microsecondsSinceEpoch}',
        replyTo: replyTo == null
            ? null
            : AxReplyReference(
                kind: replyTo['kind'] as String,
                id: replyTo['id'] as String,
                authorName: 'Fixture',
                excerpt: 'Quoted fixture text'),
        threadId: threadId,
        authorUserId: 'user-owner',
        authorName: 'Vitalii',
        body: text,
        references: references,
        attachments: attachments,
        createdAt: DateTime.now().toIso8601String(),
        isMe: true,
      );

  @override
  Future<AxDiscussionMessage> loadDiscussionMessage(
          {required String messageId}) async =>
      throw UnimplementedError(
          'Discussion message lookup is not provided by this fixture');

  @override
  Future<AxDiscussionMessage> editDiscussionMessage({
    required String messageId,
    required String text,
    List<String> references = const [],
  }) async =>
      AxDiscussionMessage(
        id: messageId,
        threadId: 'thread-1',
        authorUserId: 'user-owner',
        authorName: 'Vitalii',
        body: text,
        references: references,
        editedAt: DateTime.now().toIso8601String(),
        createdAt: DateTime.now().toIso8601String(),
        isMe: true,
      );

  @override
  Future<void> deleteDiscussionMessage({
    required String messageId,
  }) async {}

  @override
  Future<List<AxSpaceMember>> loadSpaceMembers({
    required String spaceId,
  }) async =>
      const [
        AxSpaceMember(
          userId: 'user-owner',
          displayName: 'Vitalii',
          email: 'owner@example.com',
          role: 'owner',
          createdAt: 'today',
        ),
      ];

  @override
  Future<List<AxSpaceInvitation>> loadSpaceInvitations({
    required String spaceId,
  }) async =>
      const [];

  @override
  Future<List<AxAuditEntry>> loadSpaceAudit({
    required String spaceId,
  }) async =>
      const [];

  @override
  Future<void> changeSpaceMemberRole({
    required String spaceId,
    required String userId,
    required String role,
  }) async {}

  @override
  Future<void> removeSpaceMember({
    required String spaceId,
    required String userId,
  }) async {}

  @override
  Future<void> expireSpaceInvitation({
    required String spaceId,
    required String invitationId,
  }) async {}

  Future<void> revokeWorkspaceSpaceGrant({
    required String grantId,
  }) async {}

  @override
  Future<AxAccountSecurity> loadAccountSecurity() async =>
      const AxAccountSecurity(
        accounts: [
          AxAuthAccount(
              id: 'account-github', providerId: 'github', accountId: 'gh-1'),
        ],
        sessions: [
          AxAuthSession(
            token: 'fixture-session-token',
            id: 'fixture-session',
            createdAt: '2026-09-23T10:00:00Z',
            expiresAt: '2026-10-07T10:00:00Z',
            userAgent: 'Fixture browser',
          ),
          AxAuthSession(
            token: 'fixture-other-session-token',
            id: 'fixture-other-session',
            createdAt: '2026-09-22T10:00:00Z',
            expiresAt: '2026-10-06T10:00:00Z',
            userAgent: 'Other browser',
          ),
        ],
      );

  @override
  Future<void> approveDesktopAuthIntent({required String intentId}) async {}

  @override
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus(
          {required String intentId}) async =>
      const AxDesktopAuthIntentStatus(
        status: 'pending',
        clientName: 'Syntila Workspace',
        audience: 'syntila.desktop.management',
      );

  @override
  Future<void> denyDesktopAuthIntent({required String intentId}) async {}

  @override
  Future<void> revokeAccountSession(String token) async {}

  @override
  Future<void> unlinkAccount({required String accountId}) async {}

  @override
  Future<void> deleteAccount({required String confirmEmail}) async {}

  @override
  Future<Uri> beginAccountLink(String provider, Uri returnTo) async =>
      Uri.parse('https://accounts.example.test/link/$provider');

  @override
  Future<List<AxWorkspace>> loadWorkspaces() async => const [
        AxWorkspace(
          id: 'workspace-fixture',
          name: 'Fixture Workspace',
          slug: 'fixture-workspace',
          status: 'active',
          role: 'owner',
        ),
      ];

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      axFixtureSnapshot().spaces;

  @override
  Future<AxSpace> loadSpace({required String spaceId}) async {
    final space =
        (await loadSpaces()).where((p) => p.id == spaceId).firstOrNull;
    if (space == null) {
      throw const AxApiException('Space not found', statusCode: 404);
    }
    return space.copyWith(threads: const []);
  }

  Future<List<Map<String, dynamic>>> loadSpaceWorkflowWorkspaceGrants({
    required String spaceId,
  }) async =>
      const [];

  Future<void> createWorkspaceSpaceGrant({
    required String spaceId,
    required String workspaceId,
    List<String> allowedPermissions = const [],
  }) async {}

  Future<void> updateWorkspaceSpacePermissions({
    required String grantId,
    required List<String> allowedPermissions,
  }) async {}

  @override
  Future<List<AxThread>> loadSpaceThreads({
    required String spaceId,
  }) async =>
      axFixtureSnapshot()
          .spaces
          .where((space) => space.id == spaceId)
          .expand((space) => space.threads)
          .toList();

  @override
  Future<AxThread> createThread({
    required String spaceId,
    required String name,
    String? idempotencyKey,
  }) async =>
      AxThread(
        id: 'thread-created',
        spaceId: spaceId,
        name: name,
        lead: 'You',
        status: 'active',
        brief: '',
        primaryWorkspace: 'Not selected',
        queueStatus: 'Idle',
      );

  @override
  Future<AxThread> updateThread({
    required String threadId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
    Map<String, dynamic>? metadata,
  }) async =>
      AxThread(
        id: threadId,
        spaceId: 'space-1',
        name: name ?? 'Updated Thread',
        lead: 'You',
        status: status ?? 'active',
        brief: '',
        primaryWorkspace: 'Not selected',
        queueStatus: 'Idle',
        workConfig: workConfig ??
            const {
              'defaultWorkflowId': 'full_cycle',
              'bindings': <String, dynamic>{},
            },
      );

  @override
  Future<void> deleteThread({required String threadId}) async {}

  @override
  Future<String?> clearThreadWorkHistory({required String threadId}) async =>
      DateTime.now().toUtc().toIso8601String();

  @override
  Future<void> clearThreadChatHistory({required String threadId}) async {}

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [];

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async =>
      const [];

  @override
  Future<AxWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  }) async =>
      AxWorkspace(
        id: workspaceId,
        name: name,
        slug: name.toLowerCase().replaceAll(' ', '-'),
        status: 'active',
        role: 'owner',
      );

  @override
  Future<void> setWorkspaceParallelSlots({
    required String workspaceId,
    required int slots,
  }) async {}

  @override
  Future<List<AxWorkspaceMember>> loadWorkspaceMembers(
          {required String workspaceId}) async =>
      const [
        AxWorkspaceMember(
          userId: 'user-1',
          displayName: 'User One',
          email: 'user@example.test',
          role: 'owner',
          status: 'active',
          createdAt: 'Today',
        ),
      ];

  @override
  Future<List<AxWorkspaceInvitation>> loadWorkspaceInvitations(
          {required String workspaceId}) async =>
      const [];

  @override
  Future<List<AxAuditEntry>> loadWorkspaceAudit(
          {required String workspaceId}) async =>
      const [];

  @override
  Future<void> inviteWorkspaceMember({
    required String workspaceId,
    required String email,
    required String role,
  }) async {}

  @override
  Future<void> changeWorkspaceMemberRole({
    required String workspaceId,
    required String userId,
    required String role,
  }) async {}

  @override
  Future<void> setWorkspaceMemberStatus({
    required String workspaceId,
    required String userId,
    required String status,
  }) async {}

  @override
  Future<void> expireWorkspaceInvitation({
    required String workspaceId,
    required String invitationId,
  }) async {}

  @override
  Future<AxSnapshot> loadBootstrapState(
          {String? spaceId, String? workspaceId}) async =>
      axFixtureSnapshot();

  @override
  Future<void> controlRun(String runId, String command) async {}

  @override
  Future<void> respondToRunPrompt(String runId, String response) async {}

  @override
  Future<void> revokeWorkspace({required String workspaceId}) async {}

  @override
  Future<List<AxSpaceInvitation>> loadCurrentUserInvitations() async =>
      const [];

  @override
  Future<void> acceptSpaceInvitation({
    required String invitationId,
  }) async {}

  @override
  Future<void> declineSpaceInvitation({
    required String invitationId,
  }) async {}

  @override
  Future<void> updateSpaceMemberPermissions({
    required String spaceId,
    required String userId,
    required AxSpacePermissions permissions,
  }) async {}

  @override
  Future<void> inviteSpaceMemberWithPermissions({
    required String spaceId,
    required String email,
    required String role,
    required AxSpacePermissions permissions,
  }) async {}
}

/// Stateful fixture used by the empty-workspace onboarding test. It mirrors
/// the production API flow closely enough to verify the shell, space
/// creation and subsequent data refresh together.
class EmptyWorkspaceFixtureDataSource extends AxFixtureDataSource {
  EmptyWorkspaceFixtureDataSource() : super();

  bool hasSpace = false;

  @override
  Future<AxSnapshot> loadBootstrapState(
      {String? spaceId, String? workspaceId}) async {
    return _snapshot();
  }

  @override
  Future<AxSpace> createSpace(
      {required String name, String? description, String? instructions}) async {
    hasSpace = true;
    return AxSpace(
      id: 'space-created',
      name: name,
      branch: '',
      lastActivity: 'Just now',
    );
  }

  AxSnapshot _snapshot() {
    const space = AxSpace(
      id: 'space-created',
      name: 'My first space',
      branch: '',
      lastActivity: 'Just now',
    );
    return axFixtureSnapshot().copyWith(
      spaces: hasSpace ? [space] : const [],
    );
  }
}
