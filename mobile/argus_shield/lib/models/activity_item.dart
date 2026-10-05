// activity_item.dart — one line in the admin Overview's RECENT ACTIVITY feed.
// Rows come from the recent_activity database function.
class ActivityItem {
  /// Short label in the box:
  ///   NEW  citizen submission      CASE  case created
  ///   ASGN investigator assigned   CLSD  case closed
  ///   INV  investigator added      VER   suspect confirmed
  ///   COR  AI detection corrected
  final String tag;
  final String text;
  final DateTime at;

  const ActivityItem({required this.tag, required this.text, required this.at});

  factory ActivityItem.fromMap(Map<String, dynamic> row) {
    return ActivityItem(
      tag: row['tag'] as String,
      text: row['message'] as String,
      at: DateTime.parse(row['occurredat'] as String).toLocal(),
    );
  }
}
