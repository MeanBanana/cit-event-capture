// case_chat_tab.dart — the "Chat" tab of the investigator case page: a group
// chat for the investigators assigned to the case (like a WhatsApp group).
//
//   ┌──────────────────────────────────────────────┐
//   │            ── 15/10/2026 ──                    │
//   │ Alice Mokoena                                  │
//   │ ┌───────────────────────────┐                 │
//   │ │ Suspect vehicle on the R21 │ 14:02          │
//   │ └───────────────────────────┘                 │
//   │                 ┌────────────────────┐        │
//   │           14:03 │ On my way           │ (mine) │
//   │                 └────────────────────┘        │
//   ├──────────────────────────────────────────────┤
//   │ [ Message the investigators on this case ] ➤  │
//   └──────────────────────────────────────────────┘
//
// New messages from others appear by themselves (Supabase Realtime, with a
// check every 30 seconds as a fallback). The database decides who may read
// and post (migration 20261015100000_case_chat.sql): only investigators
// assigned to the case; a closed case's chat is read-only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/models/case_message.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/theme/app_theme.dart';

class CaseChatTab extends StatefulWidget {
  final int caseId;
  final SupabaseService service;

  /// A closed case: messages can be read, not sent.
  final bool readOnly;

  /// How often to check for new messages in case a live update is missed.
  final Duration fallbackCheck;

  const CaseChatTab({
    super.key,
    required this.caseId,
    required this.service,
    this.readOnly = false,
    this.fallbackCheck = const Duration(seconds: 30),
  });

  @override
  State<CaseChatTab> createState() => _CaseChatTabState();
}

class _CaseChatTabState extends State<CaseChatTab>
    with AutomaticKeepAliveClientMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<CaseMessage> _messages = [];
  bool _loading = true;
  bool _sending = false;
  bool _fetching = false;
  String? _error;
  void Function()? _stopWatching;
  Timer? _timer;

  // keep the chat (and its live connection) when switching to another tab
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    try {
      _stopWatching =
          widget.service.watchCaseMessages(widget.caseId, _fetchNew);
    } catch (e) {
      debugPrint('Live chat updates not available: $e');
    }
    _timer = Timer.periodic(widget.fallbackCheck, (_) => _fetchNew());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopWatching?.call();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final messages = await widget.service.getCaseMessages(widget.caseId);
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(messages);
        _error = null;
        _loading = false;
      });
    } catch (e) {
      debugPrint('Could not load the chat of case ${widget.caseId}: $e');
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the chat. Pull down to try again.';
        _loading = false;
      });
    }
  }

  /// Adds messages newer than the last one shown (live update / check).
  Future<void> _fetchNew() async {
    if (_fetching || _loading || !mounted) return;
    _fetching = true;
    try {
      final after = _messages.isEmpty ? null : _messages.last.messageId;
      final fresh =
          await widget.service.getCaseMessages(widget.caseId, afterId: after);
      if (mounted && fresh.isNotEmpty) setState(() => _add(fresh));
    } catch (e) {
      debugPrint('Could not check for new chat messages: $e');
    } finally {
      _fetching = false;
    }
  }

  /// Adds messages once each, in order (a message can arrive both from the
  /// live update and from our own send).
  void _add(Iterable<CaseMessage> messages) {
    final known = {for (final m in _messages) m.messageId};
    _messages.addAll(messages.where((m) => known.add(m.messageId)));
    _messages.sort((a, b) => a.messageId.compareTo(b.messageId));
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final sent = await widget.service.sendCaseMessage(widget.caseId, text);
      if (!mounted) return;
      _input.clear();
      setState(() => _add([sent]));
      if (_scroll.hasClients) {
        _scroll.animateTo(0,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _list()),
        if (widget.readOnly)
          Container(
            color: AppColors.header,
            padding: const EdgeInsets.all(12),
            child: NavyText(
              child: Text('This case is closed: its chat is read-only.',
                textAlign: TextAlign.center,
                style: AppText.bodyMuted.copyWith(fontSize: 13)),
            ),
          )
        else
          _composer(),
      ],
    );
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final empty = _error ??
        'No messages yet.\nMessages here go to every investigator '
            'assigned to this case.';
    if (_error != null || _messages.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(32),
          children: [
            Icon(Icons.forum_outlined,
                size: 40,
                color: _error != null ? AppColors.danger : AppColors.textHint),
            const SizedBox(height: 12),
            Text(empty,
                textAlign: TextAlign.center,
                style: AppText.bodyMuted.copyWith(
                    color: _error != null ? AppColors.danger : null)),
          ],
        ),
      );
    }
    // newest at the bottom; reverse so it opens there and stays there
    final items = _messages.reversed.toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final m = items[i];
          final older = i + 1 < items.length ? items[i + 1] : null;
          final newDay = older == null || !_sameDay(older.sentAt, m.sentAt);
          // the name only above the first of several messages in a row
          final showName = !m.isMine &&
              (newDay || older!.senderId != m.senderId);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (newDay) _DayLabel(m.sentAt),
              _Bubble(message: m, showName: showName),
            ],
          );
        },
      ),
    );
  }

  Widget _composer() => Material(
        color: AppColors.header,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat-input'),
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    style: AppText.body.copyWith(fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Message the investigators on this case',
                      hintStyle: AppText.bodyMuted.copyWith(fontSize: 14),
                      counterText: '',
                      isDense: true,
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 4),
                _sending
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        key: const ValueKey('chat-send'),
                        tooltip: 'Send',
                        icon: const Icon(Icons.send, color: AppColors.accent),
                        onPressed: _send,
                      ),
              ],
            ),
          ),
        ),
      );
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _time(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _DayLabel extends StatelessWidget {
  final DateTime day;
  const _DayLabel(this.day);

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final text = _sameDay(day, now)
        ? 'Today'
        : _sameDay(day, now.subtract(const Duration(days: 1)))
            ? 'Yesterday'
            : formatDate(day);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.header,
            borderRadius: BorderRadius.circular(10),
          ),
          child: NavyText(
            child: Text(text, style: AppText.bodyMuted.copyWith(fontSize: 12)),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final CaseMessage message;
  final bool showName;

  const _Bubble({required this.message, required this.showName});

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: Container(
          margin: EdgeInsets.only(top: showName ? 8 : 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          decoration: BoxDecoration(
            color: mine ? AppColors.accent.withAlpha(45) : AppColors.header,
            border: Border.all(
                color: mine ? AppColors.accent.withAlpha(120) : AppColors.fieldBorder.withAlpha(90)),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(mine ? 14 : 3),
              bottomRight: Radius.circular(mine ? 3 : 14),
            ),
          ),
          child: NavyText(
            child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(message.senderName,
                      style: AppText.body.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppColors.accent)),
                ),
              Text(message.body, style: AppText.body.copyWith(fontSize: 15)),
              const SizedBox(height: 2),
              Text(_time(message.sentAt),
                  style: AppText.bodyMuted.copyWith(fontSize: 11)),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
