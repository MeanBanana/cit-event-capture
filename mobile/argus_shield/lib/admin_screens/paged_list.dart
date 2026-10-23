// A list that loads more as you scroll, used by every admin list that can
// grow without bound (submissions, cases, location and linked groups).
//
// Only the first page loads up front and the next one is fetched as you
// get near the bottom. ListView.builder only builds what's on screen, and
// the database pages with a cursor, so page 10 is as cheap as page 1.
//
// To reload from the top (filter changed, an action changed a row), just
// give the PagedList a new key, e.g. ValueKey('$view/$query/$generation').

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';

/// Loads the next page. [loaded] is everything so far (empty on the first
/// call), so use loaded.last as a cursor or loaded.length as an offset.
typedef PageLoader<T> = Future<List<T>> Function(List<T> loaded);

class PagedList<T> extends StatefulWidget {
  final PageLoader<T> loadPage;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// A page shorter than this means we've reached the end.
  final int pageSize;

  /// Shown if the first page comes back empty.
  final String emptyText;

  /// Shown if the first page fails.
  final String errorText;

  /// Optional widget above the first row, scrolls with the list.
  final Widget? header;

  /// Identifies a row, so if a page repeats rows (say something new got
  /// reported while scrolling) they don't show up twice.
  final Object Function(T item)? idOf;

  /// Gap between rows.
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
  bool _loading = false; // fetching a page right now
  bool _hasMore = true;
  String? _error; // from the last fetch
  int _generation = 0; // so pages that land after a refresh get ignored

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
        // Stop on a short page, or one that brought nothing new (guards
        // against a cursor that's stuck).
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

  /// Pull to refresh, start over from page one.
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
    // first page: spinner / error / empty message in the middle
    if (_items.isEmpty) {
      Widget middle;
      if (_error != null) {
        middle = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: mutedOnPage(context), textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.small),
            TextButton(onPressed: _loadMore, child: const Text('Try again')),
          ],
        );
      } else if (_loading || _hasMore) {
        middle = const CircularProgressIndicator();
      } else {
        middle = Text(widget.emptyText,
            style: mutedOnPage(context), textAlign: TextAlign.center);
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
        // small gap after the last card so it isn't flush with the bottom
        padding: const EdgeInsets.only(bottom: 12),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: offset + _items.length + (showFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (header != null && index == 0) return header;
          final i = index - offset;

          if (i >= _items.length) return _footer();

          // close to the end, fetch the next page after this frame
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
