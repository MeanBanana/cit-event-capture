// submission_groups.dart — the groups shown on the Submissions tab, the
// AI suggestions, a submission's clips and a case's history.
// Each comes from one database function (named on each class).

DateTime? _time(Map<String, dynamic> row, String key) => row[key] == null
    ? null
    : DateTime.parse(row[key] as String).toLocal();

List<String> _strings(Object? value) =>
    ((value as List?) ?? const []).cast<String>();

/// One location on the Location tab (list_location_groups). Submissions
/// whose location text is the same apart from capitals, commas and spaces
/// share a group ("N1, Midrand" and "n1 midrand").
class LocationGroup {
  final String locationKey; // pass to listSubmissionsPage(locationKey: ...)
  final String label; // the most common spelling, e.g. 'N1, Midrand'
  final int submissionCount;
  final int pendingCount;
  final DateTime? latestReported;

  const LocationGroup({
    required this.locationKey,
    required this.label,
    required this.submissionCount,
    this.pendingCount = 0,
    this.latestReported,
  });

  factory LocationGroup.fromMap(Map<String, dynamic> row) => LocationGroup(
        locationKey: row['locationkey'] as String,
        label: row['label'] as String,
        submissionCount: (row['submissioncount'] as num).toInt(),
        pendingCount: (row['pendingcount'] as num?)?.toInt() ?? 0,
        latestReported: _time(row, 'latestreported'),
      );
}

/// Submissions joined by AI cross-reference links (list_linked_groups):
/// e.g. the same car seen in three different reports.
class LinkedGroup {
  final int groupId; // lowest incident id in the group
  final List<int> incidentIds; // newest reported first
  final int pendingCount;
  final int linkCount;
  final int verifiedLinks;
  final double? bestConfidence; // 0..1
  final List<String> plates; // plates seen in 2+ of the submissions
  final DateTime? latestReported;

  const LinkedGroup({
    required this.groupId,
    required this.incidentIds,
    this.pendingCount = 0,
    this.linkCount = 0,
    this.verifiedLinks = 0,
    this.bestConfidence,
    this.plates = const [],
    this.latestReported,
  });

  factory LinkedGroup.fromMap(Map<String, dynamic> row) => LinkedGroup(
        groupId: (row['groupid'] as num).toInt(),
        incidentIds: ((row['incidentids'] as List?) ?? const [])
            .map((id) => (id as num).toInt())
            .toList(),
        pendingCount: (row['pendingcount'] as num?)?.toInt() ?? 0,
        linkCount: (row['linkcount'] as num?)?.toInt() ?? 0,
        verifiedLinks: (row['verifiedlinks'] as num?)?.toInt() ?? 0,
        bestConfidence: switch (row['bestconfidence']) {
          num n => n.toDouble(),
          String s => double.tryParse(s),
          _ => null,
        },
        plates: _strings(row['plates']),
        latestReported: _time(row, 'latestreported'),
      );

  int get size => incidentIds.length;
}

/// "This pending submission probably belongs in the case"
/// (suggest_incidents_for_case).
class IncidentSuggestion {
  final int incidentId;
  final int score; // higher = more likely; 30 is the minimum shown
  final List<String> reasons; // e.g. ['Same plate ND123456GP', '750 m apart']
  final int matchedIncidentId; // the submission in the case it matched

  const IncidentSuggestion({
    required this.incidentId,
    required this.score,
    this.reasons = const [],
    required this.matchedIncidentId,
  });

  factory IncidentSuggestion.fromMap(Map<String, dynamic> row) =>
      IncidentSuggestion(
        incidentId: (row['incidentid'] as num).toInt(),
        score: (row['score'] as num).toInt(),
        reasons: _strings(row['reasons']),
        matchedIncidentId: (row['matchedincidentid'] as num).toInt(),
      );
}

/// "This submission probably belongs in that case"
/// (suggest_cases_for_incident).
class CaseSuggestion {
  final int caseId;
  final int score;
  final List<String> reasons;
  final int matchedIncidentId; // the submission in that case it matched

  const CaseSuggestion({
    required this.caseId,
    required this.score,
    this.reasons = const [],
    required this.matchedIncidentId,
  });

  factory CaseSuggestion.fromMap(Map<String, dynamic> row) => CaseSuggestion(
        caseId: (row['caseid'] as num).toInt(),
        score: (row['score'] as num).toInt(),
        reasons: _strings(row['reasons']),
        matchedIncidentId: (row['matchedincidentid'] as num).toInt(),
      );
}

/// How sure a suggestion is, in words, from its score.
String suggestionStrength(int score) => score >= 90
    ? 'Strong match'
    : score >= 60
        ? 'Likely match'
        : 'Possible match';

/// One clip or photo of a submission, with what the AI saw in it
/// (list_incident_media).
class MediaItem {
  final int mediaId;
  final String mediaType; // 'video' | 'image' | 'audio'
  final String storagePath;
  final DateTime? captured;
  final DateTime? uploaded;
  final String processingStatus; // 'pending' | 'processing' | 'completed' | 'failed'
  final String? aiDescription;
  final int detections;
  final int verified; // detections an investigator confirmed

  const MediaItem({
    required this.mediaId,
    required this.mediaType,
    required this.storagePath,
    this.captured,
    this.uploaded,
    this.processingStatus = 'pending',
    this.aiDescription,
    this.detections = 0,
    this.verified = 0,
  });

  factory MediaItem.fromMap(Map<String, dynamic> row) => MediaItem(
        mediaId: (row['mediaid'] as num).toInt(),
        mediaType: row['mediatype'] as String,
        storagePath: row['storagepath'] as String,
        captured: _time(row, 'capturetimestamp'),
        uploaded: _time(row, 'uploadtimestamp'),
        processingStatus: (row['processingstatus'] as String?) ?? 'pending',
        aiDescription: row['aidescription'] as String?,
        detections: (row['detections'] as num?)?.toInt() ?? 0,
        verified: (row['verified'] as num?)?.toInt() ?? 0,
      );
}

/// One line of a case's history (list_case_events).
class CaseEvent {
  final int eventId;
  final String eventType; // 'added_to_case', 'status_changed', 'assigned' ...
  final int? incidentId;
  final String? detail;
  final String? actorName; // null = system / AI or not visible
  final DateTime occurredAt;

  const CaseEvent({
    required this.eventId,
    required this.eventType,
    this.incidentId,
    this.detail,
    this.actorName,
    required this.occurredAt,
  });

  factory CaseEvent.fromMap(Map<String, dynamic> row) => CaseEvent(
        eventId: (row['eventid'] as num).toInt(),
        eventType: row['eventtype'] as String,
        incidentId: (row['incidentid'] as num?)?.toInt(),
        detail: row['detail'] as String?,
        actorName: row['actorname'] as String?,
        occurredAt: _time(row, 'occurredat')!,
      );

  /// e.g. "INC-0042 added to the case · as a duplicate of INC-0041"
  String get text {
    final inc =
        incidentId == null ? '' : 'INC-${incidentId.toString().padLeft(4, '0')} ';
    final what = switch (eventType) {
      'submitted' => '${inc}submitted',
      'added_to_case' => '${inc}added to the case',
      'removed_from_case' => '${inc}removed from the case',
      'rejected' => '${inc}rejected',
      'duplicate' => '${inc}marked as a duplicate',
      'reopened' => '${inc}back to pending review',
      'case_created' => 'Case created',
      'case_edited' => 'Case edited',
      'status_changed' => 'Status changed',
      'case_deleted' => 'Case deleted',
      'assigned' => 'Investigator assigned',
      'unassigned' => 'Investigator removed',
      'lead_changed' => 'Lead investigator changed',
      'detection_verified' => '${inc}AI detection confirmed',
      'detection_unverified' => '${inc}AI detection un-confirmed',
      _ => eventType,
    };
    return detail == null || detail!.isEmpty ? what : '$what · $detail';
  }
}

/// "This pending submission most likely belongs in that case": one row of
/// the Suggested matches review list (list_suggested_matches). Nothing is
/// added to a case until an admin accepts it.
class SuggestedMatch {
  final int incidentId;
  final int caseId;
  final int score;
  final List<String> reasons;
  final int matchedIncidentId; // the submission in the case it matched
  final int otherCases; // other cases that also match well (be careful)

  const SuggestedMatch({
    required this.incidentId,
    required this.caseId,
    required this.score,
    this.reasons = const [],
    required this.matchedIncidentId,
    this.otherCases = 0,
  });

  factory SuggestedMatch.fromMap(Map<String, dynamic> row) => SuggestedMatch(
        incidentId: (row['incidentid'] as num).toInt(),
        caseId: (row['caseid'] as num).toInt(),
        score: (row['score'] as num).toInt(),
        reasons: _strings(row['reasons']),
        matchedIncidentId: (row['matchedincidentid'] as num).toInt(),
        otherCases: (row['othercases'] as num?)?.toInt() ?? 0,
      );
}
