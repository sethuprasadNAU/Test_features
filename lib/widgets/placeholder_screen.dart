import 'package:flutter/material.dart';

/// Stand-in body for a screen not yet built. Each feature screen wraps this
/// so the router has a stable widget to point at before that phase lands.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, required this.phase});

  final String title;
  final String phase;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('Built in $phase', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
