import 'package:flutter/material.dart';

import '../../core/l10n.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../accounts/sign_in.dart';
import '../accounts/view_models/accounts_view_model.dart';
import '../../core/toast.dart';
import '../../core/error_text.dart';

/// The first screen without an account: what Cauce is, and a tile to connect each service.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.accounts, required this.onSkip});

  final AccountsViewModel accounts;

  /// Goes on without an account, to the files and downloads on the phone.
  final VoidCallback onSkip;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  String? _signingIn;

  Future<void> _connect(StreamingService service) async {
    setState(() => _signingIn = service.slug);
    try {
      await signIn(context, service, widget.accounts);
    } catch (error) {
      if (mounted) {
        showToast(Toast(title: context.t('connect.failed'), detail: explainError(error), tone: ToastTone.error));
      }
    }
    if (mounted) setState(() => _signingIn = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CauceColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CauceMetrics.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 40),
              const Padding(padding: EdgeInsets.only(left: 8), child: Wordmark()),
              const SizedBox(height: 22),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  context.t('connect.title'),
                  style: const TextStyle(
                    fontFamily: displayFont,
                    fontSize: 40,
                    height: 1.08,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  context.t('connect.subtitle'),
                  style: TextStyle(fontSize: 16, height: 1.45, color: CauceColors.mutedForeground),
                ),
              ),
              const Spacer(),
              Overline(context.t('connect.pick'), padding: const EdgeInsets.fromLTRB(6, 0, 6, 10)),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 2.8,
                children: [
                  for (final service in streamingServices)
                    _ServiceTile(
                      service: service,
                      busy: _signingIn == service.slug,
                      onTap: _signingIn == null ? () => _connect(service) : null,
                    ),
                ],
              ),
              const SizedBox(height: 60),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: OutlinedButton(
                  onPressed: widget.onSkip,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CauceColors.foreground,
                    side: BorderSide(color: CauceColors.foreground.withValues(alpha: 0.18)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  child: Text(context.t('connect.skip')),
                ),
              ),
              const SizedBox(height: 12),
              Center(child: Text(context.t('connect.later'), style: CauceText.caption)),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service, required this.busy, required this.onTap});

  final StreamingService service;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CauceColors.secondary,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              BrandBadge(slug: service.slug, size: 36),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    Text(context.t('connect.action'), style: TextStyle(fontSize: 13, color: CauceColors.accent)),
                  ],
                ),
              ),
              if (busy) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
        ),
      ),
    );
  }
}
