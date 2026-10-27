/// Parsed World Magnetic Model coefficient set (a `.COF` file).
///
/// The `.COF` format is: a header line `<epoch> <model> <date>`, then one line
/// per Gauss coefficient `n m g_nm h_nm gdot_nm hdot_nm`, terminated by lines
/// of `9`s. Coefficients are stored flat, indexed by [index] = n(n+1)/2 + m.
///
/// This is intentionally a pure parser over text so the numeric engine and its
/// tests never depend on Flutter's asset bundle; [wmm.dart] wraps it to load
/// the embedded asset at runtime.
class WmmCoefficients {
  WmmCoefficients._({
    required this.epoch,
    required this.modelName,
    required this.nMax,
    required this.g,
    required this.h,
    required this.gDot,
    required this.hDot,
  });

  /// Model epoch (decimal year), e.g. 2025.0.
  final double epoch;

  /// Model label from the header, e.g. "WMM-2025".
  final String modelName;

  /// Maximum spherical-harmonic degree (12 for WMM).
  final int nMax;

  /// Main-field and secular-variation coefficients, flat-indexed by
  /// [index](n, m). `h`/`hDot` are 0 where m = 0.
  final List<double> g;
  final List<double> h;
  final List<double> gDot;
  final List<double> hDot;

  static int index(int n, int m) => n * (n + 1) ~/ 2 + m;

  static int _size(int nMax) => (nMax + 1) * (nMax + 2) ~/ 2;

  /// Parses `.COF` text. Throws [FormatException] on a malformed file so a bad
  /// coefficient set fails loudly rather than silently mis-computing bearings.
  factory WmmCoefficients.parse(String text, {int nMax = 12}) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      throw const FormatException('Empty WMM coefficient file.');
    }

    final header = lines.first.split(RegExp(r'\s+'));
    final epoch = double.tryParse(header.first);
    if (epoch == null) {
      throw FormatException('Bad WMM header epoch: "${lines.first}"');
    }
    final modelName = header.length > 1 ? header[1] : 'WMM';

    final size = _size(nMax);
    final g = List<double>.filled(size, 0);
    final h = List<double>.filled(size, 0);
    final gDot = List<double>.filled(size, 0);
    final hDot = List<double>.filled(size, 0);

    for (final line in lines.skip(1)) {
      if (line.startsWith('9999')) break; // terminator
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 6) {
        throw FormatException('Malformed WMM coefficient line: "$line"');
      }
      final n = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      if (n < 1 || n > nMax || m < 0 || m > n) {
        throw FormatException('WMM coefficient (n=$n, m=$m) out of range.');
      }
      final i = index(n, m);
      g[i] = double.parse(parts[2]);
      h[i] = double.parse(parts[3]);
      gDot[i] = double.parse(parts[4]);
      hDot[i] = double.parse(parts[5]);
    }

    // Sanity: the WMM main dipole term must be present and large (~-29000 nT).
    if (g[index(1, 0)].abs() < 1000) {
      throw const FormatException(
          'WMM coefficients look wrong: dipole g(1,0) is implausibly small.');
    }

    return WmmCoefficients._(
      epoch: epoch,
      modelName: modelName,
      nMax: nMax,
      g: g,
      h: h,
      gDot: gDot,
      hDot: hDot,
    );
  }

  /// Latest decimal year the model is considered valid for (epoch + 5).
  double get validUntil => epoch + 5.0;
}
