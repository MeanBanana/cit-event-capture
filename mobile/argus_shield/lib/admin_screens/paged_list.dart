// paged_list.dart — a list that loads more rows as you scroll.
//
// Used by every admin list that can grow without limit (submissions,
// cases, location and linked groups). Only the first page loads when the
// list opens; the next page is fetched when you get near the bottom, so
// the app never downloads or builds rows you haven't scrolled to:
//   * ListView.builder only builds the cards on screen
//   * each page is one small database call (the database pages with a
//     cursor, so later pages are as fast as the first)
//
// To reload from the top (a filter changed, an action changed a row), give
// the PagedList a new key, e.g. ValueKey('$view/$query/$generation').

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';

/// Loads the next page. [loaded] = everything loaded so far (empty for the
/// first page): use loaded.last as the cursor, or loaded.length as an
/// offset.
typedef PageLoader<T> = Future<List<T>> Function(List<T> loaded);

class PagedList<T> extends StatefulWidget {
  final PageLoader<T> loadPage;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// A page shorter than this is the last one.
  final int pageSize;

  /// Shown when the first page is empty.
  final String emptyText;

  /// Shown when the first page fails.
  final String errorText;

  /// Optional widget above the first row (scrolls with the list).
  final Widget? header;

  /// Identifies a row so a page that repeats rows (e.g. something new was
  /// reported while scrolling) doesn't show them twice.
  final Object Function(T item)? idOf;

  /// Space between rows.
  final double spacing;

  const PagedList({
    super.key,
    required this.loadPage,
    required this.itemBuilder,
    this.pageSize = 30,
    this.emptyText = 'Nothing to show.',
    this.errorText = 'Could not load this list. Check your connection.',
    this.header,
    this.idOf,
    this.spacing = AppSpacing.medium,
  });

  @override
  State<PagedList<T>> createState() => _PagedListState<T>();
}

class _PagedListState<T> extends State<PagedList<T>> {
  final List<T> _items = [];
  bool _loading = false; // a page is being fetched
  bool _hasMore = true;
  String? _error; // error of the last fetch
  int _generation = 0; // ignores pages that arrive after a refresh

  @override
  void initState() {
    super.initState();
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.loadPage(List.unmodifiable(_items));
      if (!mounted || generation != _generation) return;
      final idOf = widget.idOf;
      final seen = idOf == null ? null : _items.map(idOf).toSet();
      final fresh = seen == null
          ? page
          : page.where((item) => !seen.contains(idOf!(item))).toList();
      setState(() {
        _items.addAll(fresh);
        // Stop when the page is short, or when it brought nothing new
        // (protects against a cursor that doesn't move).
        _hasMore = page.length >= widget.pageSize && fresh.isNotEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = widget.errorText;
        _loading = false;
      });
    }
  }

  /// Pull to refresh: start again from the first page.
  Future<void> _refresh() async {
    _generation++;
    setState(() {
      _items.clear();
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    await _loadMore();
  }

  @override
  Widget build(BuildContext context) {
    // First page: spinner / error / empty in the middle
    if (_items.isEmpty) {
      Widget middle;
      if (_error != null) {
        middle = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: AppText.bodyMuted, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.small),
            TextButton(onPressed: _loadMore, child: const Text('Try again')),
          ],
        );
      } else if (_loading || _hasMore) {
        middle = const CircularProgressIndicator();
      } else {
        middle = Text(widget.emptyText,
            style: AppText.bodyMuted, textAlign: TextAlign.center);
      }
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ?widget.header,
            const SizedBox(height: AppSpacing.large),
            Center(child: middle),
          ],
        ),
      );
    }

    final header = widget.header;
    final offset = header == null ? 0 : 1;
    final showFooter = _hasMore || _error != null;

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        // a small gap after the last card, so it isn't flush with the
        // bottom of the screen
        padding: const EdgeInsets.only(bottom: 12),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: offset + _items.length + (showFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (header != null && index == 0) return header;
          final i = index - offset;

          if (i >= _items.length) return _footer();

          // Near the end: fetch the next page after this frame
          if (_hasMore && !_loading && _error == null && i >= _items.length - 5) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _loadMore();
            });
          }
          return Padding(
            padding: EdgeInsets.only(
                bottom: i == _items.length - 1 && !showFooter ? 0 : widget.spacing),
            child: widget.itemBuilder(context, _items[i]),
          );
        },
      ),
    );
  }

  Widget _footer() {
    if (_error != null) {
      return Center(
        child: TextButton(
          onPressed: _loadMore,
          child: const Text('Could not load more. Tap to try again.'),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: AppSpacing.medium),
      child: Center(
        child: SizedBox(
            width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
  }
}
