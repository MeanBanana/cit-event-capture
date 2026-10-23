// One message in a case's investigator chat (list_case_messages /
// send_case_message).

class CaseMessage {
  final int messageId;
  final int caseId;
  final int senderId;

  /// e.g. "Alice Mokoena"
  final String senderName;

  /// Sent by whoever's signed in, so it goes on the right.
  final bool isMine;
  final String body;
  final DateTime sentAt;

  const CaseMessage({
    required this.messageId,
    required this.caseId,
    required this.senderId,
    required this.senderName,
    required this.isMine,
    required this.body,
    required this.sentAt,
  });

  factory CaseMessage.fromMap(Map<String, dynamic> m) => CaseMessage(
        messageId: (m['messageid'] as num).toInt(),
        caseId: (m['caseid'] as num).toInt(),
        senderId: (m['senderid'] as num).toInt(),
        senderName: ((m['sender_name'] as String?) ?? '').trim().isEmpty
            ? 'Investigator'
            : (m['sender_name'] as String).trim(),
        isMine: m['is_mine'] == true,
        body: (m['body'] as String?) ?? '',
        sentAt: DateTime.parse(m['sentat'] as String).toLocal(),
      );
}
