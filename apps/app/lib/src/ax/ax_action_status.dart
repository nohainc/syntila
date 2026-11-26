/// One lifecycle for every live action (message, work request, invitation):
/// sending → accepted by Syntila → delivered → seen / responded / processed,
/// or an end state. Each feature maps its own status strings onto it, so the
/// UI shows the same words and colors for the same stage.
enum AxActionStatus {
  sending,
  accepted,
  delivered,
  seen,
  responded,
  processed,
  failed,
  expired,
  revoked;

  bool get finished =>
      const {responded, processed, failed, expired, revoked}.contains(this);

  bool get problem => this == failed;
}

enum AxActionKind { message, workRequest, invitation }

extension AxActionStatusLabel on AxActionStatus {
  String label(AxActionKind kind) => switch ((this, kind)) {
        (AxActionStatus.sending, _) => 'Sending…',
        (AxActionStatus.accepted, AxActionKind.workRequest) => 'Received',
        (AxActionStatus.accepted, _) => 'Sent',
        (AxActionStatus.delivered, AxActionKind.workRequest) => 'Started',
        (AxActionStatus.delivered, _) => 'Delivered',
        (AxActionStatus.seen, _) => 'Seen',
        (AxActionStatus.responded, AxActionKind.invitation) => 'Answered',
        (AxActionStatus.responded, _) => 'Responded',
        (AxActionStatus.processed, _) => 'Done',
        (AxActionStatus.failed, _) => 'Failed',
        (AxActionStatus.expired, _) => 'Expired',
        (AxActionStatus.revoked, _) => 'Cancelled',
      };
}

/// Space invitation statuses from Cloud.
AxActionStatus axInvitationStatus(String status) => switch (status) {
      'pending' => AxActionStatus.accepted,
      'accepted' || 'declined' => AxActionStatus.responded,
      'expired' => AxActionStatus.expired,
      'revoked' => AxActionStatus.revoked,
      _ => AxActionStatus.accepted,
    };

/// Work Request statuses from Cloud.
AxActionStatus axWorkRequestStatus(String status) => switch (status) {
      'queued' => AxActionStatus.accepted,
      'running' || 'waiting' => AxActionStatus.delivered,
      'completed' => AxActionStatus.processed,
      'failed' => AxActionStatus.failed,
      'cancelled' => AxActionStatus.revoked,
      _ => AxActionStatus.accepted,
    };
