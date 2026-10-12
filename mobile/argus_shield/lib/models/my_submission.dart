// my_submission.dart — one incident a citizen reported, as shown in their
// Submissions tab. Citizens only see their OWN reports (database RLS), and
// never the AI's findings (pictures of other people's faces and plates).

class MySubmission {
  final int incidentId;
  final String location;
  final DateTime? reportedAt;
  final String? description;

  /// 'pending' | 'accepted' | 'rejected' | 'duplicate' (the admin's review)
  final String reviewStatus;

  /// 'none' | 'processing' | 'ready' | 'outdated' | 'failed' (the AI analysis)
  final String aiStatus;
  final int fileCount;

  const MySubmission({
    required this.incidentId,
    required this.location,
    this.reportedAt,
    this.description,
    this.reviewStatus = 'pending',
    this.aiStatus = 'none',
    this.fileCount = 0,
  });

  /// [row] = a crimescene row; [fileCount] = its media rows.
  factory MySubmission.fromMap(Map<String, dynamic> row, {int fileCount = 0}) {
    final reported = (row['datereported'] ?? row['datetime']) as String?;
    return MySubmission(
      incidentId: (row['incidentid'] as num).toInt(),
      location: (row['location'] as String?) ?? '',
      reportedAt: reported == null ? null : DateTime.tryParse(reported)?.toLocal(),
      description: row['description'] as String?,
      reviewStatus: (row['reviewstatus'] as String?) ?? 'pending',
      aiStatus: (row['aisummarystatus'] as String?) ?? 'none',
      fileCount: fileCount,
    );
  }

  /// 42 -> "INC-0042" (the same reference the admins see).
  String get reference => 'INC-${incidentId.toString().padLeft(4, '0')}';

  /// What happened to the report, in the citizen's words.
  String get statusLabel => switch (reviewStatus) {
        'accepted' => 'Added to a case',
        'rejected' => 'Reviewed - not used',
        'duplicate' => 'Already reported',
        _ => 'Received',
      };

  /// The footage analysis, without any of its findings.
  String get aiLabel => switch (aiStatus) {
        'processing' => 'Footage being analysed…',
        'ready' || 'outdated' => 'Footage analysed',
        'failed' => 'Footage could not be analysed',
        _ => fileCount == 0 ? 'No footage uploaded' : 'Waiting for analysis',
      };
}
