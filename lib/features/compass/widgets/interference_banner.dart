import 'package:flutter/material.dart';

import '../../../compass/magnetometer_interference.dart';
import '../../../core/theme/app_theme.dart';

/// Dismissible amber warning banner shown when the magnetometer reads likely
/// interference (metal/vehicle/antenna) or calibration is stale. Reinforces
/// that manual bearing entry stays available regardless.
class InterferenceBanner extends StatelessWidget {
  const InterferenceBanner({
    super.key,
    required this.assessment,
    required this.onDismiss,
  });

  final InterferenceAssessment assessment;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (!assessment.isInterfered) return const SizedBox.shrink();
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF241D10) : const Color(0xFFFFF7ED),
        border: Border.all(color: colors.fairAmber, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '⚠ ${assessment.message}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E),
              ),
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            child: Text('✕',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color:
                        isDark ? const Color(0xFFFBBF24) : const Color(0xFF92400E))),
          ),
        ],
      ),
    );
  }
}
