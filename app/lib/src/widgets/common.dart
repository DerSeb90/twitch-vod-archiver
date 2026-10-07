import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../paging.dart';
import '../settings.dart';
import '../theme.dart';

/// Network image with a soft fade-in and a neutral placeholder.
class NetImg extends StatelessWidget {
  const NetImg(
    this.src, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
  });
  final String src;
  final BoxFit fit;
  final double? width, height;
  final int? cacheWidth;

  @override
  Widget build(BuildContext context) {
    if (src.isEmpty) return _placeholder();
    return Image.network(
      Api.instance.url(src),
      fit: fit,
      width: width,
      height: height,
      cacheWidth: cacheWidth,
      gaplessPlayback: true,
      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
      errorBuilder: (_, _, _) => _placeholder(),
      frameBuilder: (context, child, frame, sync) {
        if (sync) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0 : 1,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          child: child,
        );
      },
    );
  }

  Widget _placeholder() => Container(
    width: width,
    height: height,
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        colors: [C.surface2, C.surface3],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
  );
}

class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.src,
    this.size = 40,
    this.live = false,
  });
  final String src;
  final double size;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final img = ClipOval(
      child: NetImg(
        src,
        width: size,
        height: size,
        cacheWidth: (size * 3).round(),
      ),
    );
    if (!live) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: C.border, width: 1),
        ),
        child: img,
      );
    }
    final ring = math.max(2.0, size / 22);
    return Container(
      padding: EdgeInsets.all(ring),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [C.live, C.pink]),
      ),
      child: Container(
        padding: EdgeInsets.all(ring * 0.8),
        decoration: const BoxDecoration(shape: BoxShape.circle, color: C.bg),
        child: ClipOval(
          child: NetImg(
            src,
            width: size - ring * 3.6,
            height: size - ring * 3.6,
            cacheWidth: (size * 3).round(),
          ),
        ),
      ),
    );
  }
}

/// Small pill used for durations, "LIVE", quality etc.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.icon});
  final String text;
  final Color? color;
  final Widget? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color ?? Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[icon!, const SizedBox(width: 4)],
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

/// Pulsing red dot for active recordings.
class RecDot extends StatefulWidget {
  const RecDot({super.key, this.size = 8});
  final double size;
  @override
  State<RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<RecDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: C.live,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: C.live.withValues(alpha: 0.6 * (1 - _c.value)),
            blurRadius: 0,
            spreadRadius: widget.size * 0.9 * _c.value,
          ),
        ],
      ),
    ),
  );
}

class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    required this.style,
    this.gradient = C.brandGradient,
  });
  final String text;
  final TextStyle style;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) => ShaderMask(
    blendMode: BlendMode.srcIn,
    shaderCallback: (r) =>
        gradient.createShader(Rect.fromLTWH(0, 0, r.width, r.height)),
    child: Text(text, style: style),
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 36, bottom: 16),
    child: Row(
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// Titled card of the settings and admin pages.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.trailing,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: C.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: C.border),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: C.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: C.primarySoft),
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontSize: 18),
            ),
            const Spacer(),
            if (trailing != null) Flexible(child: trailing!),
          ],
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    ),
  );
}

/// Centers content and applies responsive side padding.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child});
  final Widget child;

  static double pad(double w) => w < 600 ? 16 : (w < 1100 ? 28 : 40);

  /// Side padding that lines full-width slivers and lists up with the
  /// content column ([pad] plus the margin beyond [kMaxContentWidth]).
  static double sliverPad(double w) {
    final inner = w.clamp(0.0, kMaxContentWidth);
    return pad(inner) + (w - inner) / 2;
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
      // full width: a narrow child (a heading column) stays left-aligned instead of centered
      child: LayoutBuilder(
        builder: (context, c) => Padding(
          padding: EdgeInsets.symmetric(horizontal: pad(c.maxWidth)),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    ),
  );
}

/// Horizontally scrolling row of cards, lined up with the content column.
/// Touch swipes it; a mouse can drag it or use the arrows shown on hover
/// (the wheel keeps scrolling the page, shift + wheel scrolls the row).
class CardRow extends StatefulWidget {
  const CardRow({super.key, required this.children});
  final List<Widget> children;

  @override
  State<CardRow> createState() => _CardRowState();
}

class _CardRowState extends State<CardRow> {
  final _c = ScrollController();
  bool _hover = false;
  (bool, bool) _arrows = (false, false);

  static const _gap = 16.0;
  static const _lift = 6.0; // room above and below for the card's hover lift

  /// Card width at [width] available: phones see a bit of the next card.
  static double _itemWidth(double width) => width < 600 ? 272 : 320;

  @override
  void initState() {
    super.initState();
    _c.addListener(_scrolled);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Whether there is more to the left / right.
  (bool, bool) _canScroll() {
    if (!_c.hasClients || !_c.position.hasContentDimensions) {
      return (false, false);
    }
    final p = _c.position;
    return (p.pixels > p.minScrollExtent + 1, p.pixels < p.maxScrollExtent - 1);
  }

  void _scrolled() {
    if (_hover && _canScroll() != _arrows) setState(() {});
  }

  void _page(int dir) {
    final p = _c.position;
    _c.animateTo(
      (p.pixels + dir * p.viewportDimension * 0.8).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final pad = ContentWidth.sliverPad(c.maxWidth);
      final w = _itemWidth(c.maxWidth);
      _arrows = _hover ? _canScroll() : (false, false);
      final arrowTop = _lift + w * 9 / 32 - 20; // middle of the thumbnail
      final arrowInset = math.max(4.0, pad - 20);
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(
          children: [
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: PointerDeviceKind.values.toSet(),
                scrollbars: false,
              ),
              child: SingleChildScrollView(
                controller: _c,
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.fromLTRB(pad, _lift, pad, _lift),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, child) in widget.children.indexed) ...[
                      if (i > 0) const SizedBox(width: _gap),
                      SizedBox(width: w, child: child),
                    ],
                  ],
                ),
              ),
            ),
            if (_arrows.$1)
              Positioned(
                left: arrowInset,
                top: arrowTop,
                child: _RowArrow(
                  icon: Icons.chevron_left_rounded,
                  onTap: () => _page(-1),
                ),
              ),
            if (_arrows.$2)
              Positioned(
                right: arrowInset,
                top: arrowTop,
                child: _RowArrow(
                  icon: Icons.chevron_right_rounded,
                  onTap: () => _page(1),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _RowArrow extends StatelessWidget {
  const _RowArrow({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Hoverable(
    onTap: onTap,
    builder: (context, hover) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: hover ? C.surface3 : C.surface2.withValues(alpha: 0.92),
        border: Border.all(color: hover ? C.primary : C.border),
        boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 16)],
      ),
      child: Icon(icon, color: C.text, size: 26),
    ),
  );
}

/// Section-header toggle that shows or hides watched VODs.
class ShowWatchedToggle extends StatelessWidget {
  const ShowWatchedToggle({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final on = Settings.instance.showWatched;
    return TextButton.icon(
      onPressed: () {
        Settings.instance.showWatched = !on;
        onChanged();
      },
      style: TextButton.styleFrom(
        foregroundColor: C.muted,
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(
        on ? Icons.visibility_off_rounded : Icons.visibility_rounded,
        size: 17,
      ),
      label: Text(on ? 'Gesehene ausblenden' : 'Gesehene anzeigen'),
    );
  }
}

/// Tracks mouse hover (for lift effects on desktop/web) and taps.
class Hoverable extends StatefulWidget {
  const Hoverable({super.key, required this.builder, this.onTap});
  final Widget Function(BuildContext context, bool hover) builder;
  final VoidCallback? onTap;
  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: widget.builder(context, _hover),
    ),
  );
}

class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.height,
    this.width,
    this.radius = kRadius,
    this.aspectRatio,
  });
  final double? height, width, aspectRatio;
  final double radius;
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget box = AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            colors: const [C.surface, C.surface2, C.surface],
            stops: const [0, 0.5, 1],
            begin: Alignment(-1 - 2 + _c.value * 4, 0),
            end: Alignment(1 - 2 + _c.value * 4, 0),
          ),
        ),
      ),
    );
    if (widget.aspectRatio != null) {
      box = AspectRatio(aspectRatio: widget.aspectRatio!, child: box);
    }
    return box;
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: C.primary.withValues(alpha: 0.12),
          ),
          child: Icon(icon, size: 34, color: C.primarySoft),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Text(
              subtitle!,
              style: const TextStyle(color: C.muted, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    ),
  );
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({
    super.key,
    required this.error,
    this.onRetry,
    this.title = 'Server nicht erreichbar',
  });
  final Object error;
  final VoidCallback? onRetry;
  final String title;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.cloud_off_rounded,
    title: title,
    subtitle:
        '$error\n\nBist du mit dem VPN verbunden? Die Server-Adresse lässt sich in den Einstellungen ändern.',
    action: onRetry == null
        ? null
        : FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Erneut versuchen'),
          ),
  );
}

/// End of a paged list: a spinner while the next page loads, a retry button
/// when it failed.
class PagerFooter extends StatelessWidget {
  const PagerFooter({super.key, required this.pager});
  final VodPager pager;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Center(
      child: pager.loading
          ? const CircularProgressIndicator(color: C.primary)
          : pager.error != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Weitere Aufnahmen konnten nicht geladen werden.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: C.muted),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: pager.retry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Erneut versuchen'),
                ),
              ],
            )
          : const SizedBox.shrink(),
    ),
  );
}

/// Grid delegate for 16:9 cards with a fixed text block below the image.
SliverGridDelegate cardGrid(
  double width, {
  double maxItem = 380,
  double textBlock = 96,
  double gap = 20,
}) {
  final cols = math.max(1, (width / maxItem).ceil());
  final itemW = (width - gap * (cols - 1)) / cols;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: cols,
    crossAxisSpacing: gap,
    mainAxisSpacing: gap,
    mainAxisExtent: itemW * 9 / 16 + textBlock,
  );
}
