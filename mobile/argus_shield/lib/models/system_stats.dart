// The four System status numbers on the admin Overview (admin_overview_stats).
class SystemStats {
  final int totalCases;
  final int activeCases; // open or under_review
  final int pendingCases; // submissions not in a case yet
  final int investigators;

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
