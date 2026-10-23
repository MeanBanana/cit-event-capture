// One report a citizen made, as it shows in their Submissions tab. RLS means
// they only ever see their own, and never the AI's findings (those include
// other people's faces and plates).

class MySubmission {
  final int incidentId;
  final String location;
  final DateTime? reportedAt;
  final String? description;

  /// The admin's review: 'pending' | 'accepted' | 'rejected' | 'duplicate'
  final String reviewStatus;

  /// AI status: 'none' | 'processing' | 'ready' | 'outdated' | 'failed'
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

  /// [row] is a crimescene row, [fileCount] how many media rows it has.
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

  /// 42 -> "INC-0042", same reference the admins see.
  String get reference => 'INC-${incidentId.toString().padLeft(4, '0')}';

  /// What happened to the report, in plain words for the citizen.
  String get statusLabel => switch (reviewStatus) {
        'accepted' => 'Added to a case',
        'rejected' => 'Reviewed - not used',
        'duplicate' => 'Already reported',
        _ => 'Received',
      };

  /// The analysis status, without giving away anything it found.
  String get aiLabel => switch (aiStatus) {
        'processing' => 'Footage being analysed…',
        'ready' || 'outdated' => 'Footage analysed',
        'failed' => 'Footage could not be analysed',
        _ => fileCount == 0 ? 'No footage uploaded' : 'Waiting for analysis',
      };
}
