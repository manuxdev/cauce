import 'dart:ui';

import 'package:flutter/material.dart';

import 'icons.dart';
import 'service_picker.dart';
import 'theme.dart';
import 'tint_scope.dart';

/// A pushed page about one thing with a cover: tinted with that cover's hue, a back button that
/// stays, and a frosted bar that takes the title once the big one has scrolled under it.
class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.cover,
    required this.title,
    required this.children,
    this.lightness = 0.19,
    this.chroma = 0.045,
    this.titleAt = 300,
    this.compactAction,
    this.header,
    this.barEdge,
  });

  /// The cover the page takes its hue from.
  final String? cover;
  final String title;
  final List<Widget> children;
  final double lightness;
  final double chroma;

  /// How far down the big title sits, where the bar takes it over.
  final double titleAt;

  /// Shown at the bar's end once it is compact, such as a small play button.
  final Widget? compactAction;

  /// Drawn behind the top of the list and moved by the scroll, such as an artist's photo. It
  /// gets the scroll offset.
  final Widget Function(BuildContext context, double offset)? header;

  /// Drawn along the bottom edge of the bar, such as how far a download has got.
  final Widget? barEdge;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  final _controller = ScrollController();
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() => _offset = _controller.offset));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CoverTint(
      url: widget.cover,
      child: Builder(
        builder: (context) {
          final tint = TintScope.of(context);
          final top = MediaQuery.paddingOf(context).top;
          final compact = _offset > widget.titleAt - top - 20;
          final page = tint.tone(widget.lightness, widget.chroma);
          return ColoredBox(
            color: page,
            child: Scaffold(
              body: Stack(
                children: [
                  if (widget.header case final header?) header(context, _offset),
                  ListView(
                    controller: _controller,
                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    padding: const EdgeInsets.only(bottom: bottomChromeInset),
                    children: widget.children,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: compact ? 24 : 0, sigmaY: compact ? 24 : 0),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          height: top + 50,
                          padding: EdgeInsets.only(top: top),
                          decoration: BoxDecoration(
                            color: compact ? page.withValues(alpha: 0.85) : Colors.transparent,
                            border: Border(
                              bottom: BorderSide(color: compact ? CauceColors.border : Colors.transparent, width: 0.5),
                            ),
                          ),
                          child: Row(
                            children: [
                              const SizedBox(width: 6),
                              _BackButton(raised: widget.header != null && !compact),
                              Expanded(
                                child: AnimatedOpacity(
                                  opacity: compact ? 1 : 0,
                                  duration: const Duration(milliseconds: 150),
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                              // As wide as the action needs, such as a Play pill, and no less than the
                              // back button so the title stays near the middle.
                              Container(
                                constraints: const BoxConstraints(minWidth: 50),
                                padding: const EdgeInsets.only(right: 10),
                                alignment: Alignment.centerRight,
                                child: AnimatedScale(
                                  scale: compact ? 1 : 0.6,
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutBack,
                                  child: AnimatedOpacity(
                                    opacity: compact ? 1 : 0,
                                    duration: const Duration(milliseconds: 150),
                                    child: IgnorePointer(ignoring: !compact, child: widget.compactAction),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.barEdge case final edge?) Positioned(left: 0, right: 0, top: top + 49, child: edge),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The back chevron in the accent, or white on a dark disc over a photo.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.raised});

  final bool raised;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).maybePop(),
      child: Container(
        width: 38,
        height: 38,
        margin: const EdgeInsets.only(left: 6),
        decoration: BoxDecoration(
          color: raised ? Colors.black.withValues(alpha: 0.3) : Colors.transparent,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: CauceIcon(
          CauceGlyph.chevronLeft,
          size: raised ? 20 : 24,
          color: raised ? Colors.white : CauceColors.accent,
          weight: 2.4,
        ),
      ),
    );
  }
}

/// A round accent play button, for a page's bar or beside an artist's name.
class RoundPlayButton extends StatelessWidget {
  const RoundPlayButton({super.key, required this.onPressed, this.size = 40});

  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: onPressed == null ? CauceColors.muted : CauceColors.accent,
          shape: BoxShape.circle,
          boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 16, offset: Offset(0, 6))],
        ),
        alignment: Alignment.center,
        child: CauceIcon(CauceGlyph.play, size: size * 0.4, color: CauceColors.onAccent),
      ),
    );
  }
}
