import 'package:flutter/material.dart';

/// Swipeable content tabs. The owner keeps the selected index so chip taps,
/// swipes and deep links all select the same page. Visited pages retain form
/// state; their scroll views should have distinct PageStorageKeys.
class SubPages extends StatefulWidget {
  final int index, count;
  final ValueChanged<int> onChanged;
  final IndexedWidgetBuilder builder;

  const SubPages({
    super.key,
    required this.index,
    required this.count,
    required this.onChanged,
    required this.builder,
  }) : assert(count > 0),
       assert(index >= 0 && index < count);

  @override
  State<SubPages> createState() => _SubPagesState();
}

class _SubPagesState extends State<SubPages> {
  late final PageController _controller;
  late int _shown;

  @override
  void initState() {
    super.initState();
    _shown = widget.index;
    _controller = PageController(initialPage: _shown);
  }

  @override
  void didUpdateWidget(covariant SubPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _shown && widget.count == oldWidget.count) return;
    _shown = widget.index;
    if (widget.count == oldWidget.count && _controller.hasClients) {
      _controller.jumpToPage(widget.index);
      return;
    }
    // Wait for the new page count's layout when an optional tab disappears.
    // Read the latest index: another selection may arrive before this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.hasClients) {
        _controller.jumpToPage(widget.index);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageView.builder(
    controller: _controller,
    itemCount: widget.count,
    onPageChanged: (index) {
      if (index == _shown) return;
      _shown = index;
      widget.onChanged(index);
    },
    itemBuilder: (context, index) =>
        _RetainedPage(child: widget.builder(context, index)),
  );
}

class _RetainedPage extends StatefulWidget {
  final Widget child;
  const _RetainedPage({required this.child});

  @override
  State<_RetainedPage> createState() => _RetainedPageState();
}

class _RetainedPageState extends State<_RetainedPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
