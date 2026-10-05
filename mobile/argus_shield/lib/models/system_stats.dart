// system_stats.dart — the four numbers under SYSTEM STATUS on the admin
// Overview tab. Rows come from the admin_overview_stats database function.
class SystemStats {
  final int totalCases; // every case
  final int activeCases; // cases 'open' or 'under_review'
  final int pendingCases; // submissions not in a case yet ("unassigned")
  final int investigators; // registered investigators

  const SystemStats({
    required this.totalCases,
    required this.activeCases,
    required this.pendingCases,
    required this.investigators,
  });

  factory SystemStats.fromMap(Map<String, dynamic> row) {
    int read(String key) => (row[key] as num?)?.toInt() ?? 0;
    return SystemStats(
      totalCases: read('totalcases'),
      activeCases: read('activecases'),
      pendingCases: read('pendingcases'),
      investigators: read('investigators'),
    );
  }
}
