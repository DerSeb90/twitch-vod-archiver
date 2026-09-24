import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';

/// Network image with a soft fade-in and a neutral placeholder.
class NetImg extends StatelessWidget {
  const NetImg(this.src, {super.key, this.fit = BoxFit.cover, this.width, this.height, this.cacheWidth});
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
        return AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 280), curve: Curves.easeOut, child: child);
      },
    );
  }

  Widget _placeholder() => Container(
        width: width,
        height: height,
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [C.surface2, C.surface3], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
      );
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.src, this.size = 40, this.live = false});
  final String src;
  final double size;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final img = ClipOval(child: NetImg(src, width: size, height: size, cacheWidth: (size * 3).round()));
    if (!live) {
      return Container(
        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.border, width: 1)),
        child: img,
      );
    }
    final ring = math.max(2.0, size / 22);
    return Container(
      padding: EdgeInsets.all(ring),
      decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [C.live, C.pink])),
      child: Container(
        padding: EdgeInsets.all(ring * 0.8),
        decoration: const BoxDecoration(shape: BoxShape.circle, color: C.bg),
        child: ClipOval(child: NetImg(src, width: size - ring * 3.6, height: size - ring * 3.6, cacheWidth: (size * 3).round())),
      ),
    );
  }
}

/// Small pill used for durations, "LIVE", quality etc.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.icon, this.textColor = Colors.white});
  final String text;
  final Color? color;
  final Color textColor;
  final Widget? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: color ?? Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[icon!, const SizedBox(width: 4)],
          Text(text, style: TextStyle(color: textColor, fontSize: 11.5, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
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
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

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
            boxShadow: [BoxShadow(color: C.live.withValues(alpha: 0.6 * (1 - _c.value)), blurRadius: 0, spreadRadius: widget.size * 0.9 * _c.value)],
          ),
        ),
      );
}

class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, required this.style, this.gradient = C.brandGradient});
  final String text;
  final TextStyle style;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => gradient.createShader(Rect.fromLTWH(0, 0, r.width, r.height)),
        child: Text(text, style: style),
      );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.leading});
  final String title;
  final Widget? trailing, leading;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 36, bottom: 16),
        child: Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: 10)],
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          ?trailing,
        ]),
      );
}

/// Centers content and applies responsive side padding.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child});
  final Widget child;

  static double pad(double w) => w < 600 ? 16 : (w < 1100 ? 28 : 40);

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
          child: LayoutBuilder(builder: (context, c) => Padding(padding: EdgeInsets.symmetric(horizontal: pad(c.maxWidth)), child: child)),
        ),
      );
}

/// Hover lift effect for cards on desktop/web.
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
        child: GestureDetector(onTap: widget.onTap, behavior: HitTestBehavior.opaque, child: widget.builder(context, _hover)),
      );
}

class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.height, this.width, this.radius = kRadius, this.aspectRatio});
  final double? height, width, aspectRatio;
  final double radius;
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();
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
    if (widget.aspectRatio != null) box = AspectRatio(aspectRatio: widget.aspectRatio!, child: box);
    return box;
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(shape: BoxShape.circle, color: C.primary.withValues(alpha: 0.12)),
            child: Icon(icon, size: 34, color: C.primarySoft),
          ),
          const SizedBox(height: 18),
          Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Text(subtitle!, style: const TextStyle(color: C.muted, height: 1.5), textAlign: TextAlign.center),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ]),
      );
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Server nicht erreichbar',
        subtitle: '$error\n\nBist du mit dem VPN verbunden? Die Server-Adresse lässt sich in den Einstellungen ändern.',
        action: onRetry == null ? null : FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Erneut versuchen')),
      );
}

/// Grid delegate for 16:9 cards with a fixed text block below the image.
SliverGridDelegate cardGrid(double width, {double maxItem = 380, double textBlock = 96, double gap = 20}) {
  final cols = math.max(1, (width / maxItem).ceil());
  final itemW = (width - gap * (cols - 1)) / cols;
  return SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: cols,
    crossAxisSpacing: gap,
    mainAxisSpacing: gap + 8,
    mainAxisExtent: itemW * 9 / 16 + textBlock,
  );
}
