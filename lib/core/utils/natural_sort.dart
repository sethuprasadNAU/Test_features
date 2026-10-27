/// Compares two strings the way a person reads them: runs of digits compare
/// as numbers rather than character-by-character, so `"Tag 7"` sorts before
/// `"Tag 10"`. A plain `String.compareTo` puts `"Tag 10"` first, because `'1'`
/// is less than `'7'` — wrong for the numeric-ish tag names this project's
/// field data actually uses (task 11.178).
///
/// Case-insensitive, matching how a biologist scanning a printed list reads
/// names — nothing here depends on capitalisation being meaningful.
int naturalCompare(String a, String b) {
  final aLower = a.toLowerCase();
  final bLower = b.toLowerCase();
  var i = 0, j = 0;
  while (i < aLower.length && j < bLower.length) {
    final aChar = aLower[i];
    final bChar = bLower[j];
    final aIsDigit = _isDigit(aChar);
    final bIsDigit = _isDigit(bChar);
    if (aIsDigit && bIsDigit) {
      var aEnd = i;
      while (aEnd < aLower.length && _isDigit(aLower[aEnd])) {
        aEnd++;
      }
      var bEnd = j;
      while (bEnd < bLower.length && _isDigit(bLower[bEnd])) {
        bEnd++;
      }
      final aNum = BigInt.parse(aLower.substring(i, aEnd));
      final bNum = BigInt.parse(bLower.substring(j, bEnd));
      final cmp = aNum.compareTo(bNum);
      if (cmp != 0) return cmp;
      i = aEnd;
      j = bEnd;
    } else {
      final cmp = aChar.compareTo(bChar);
      if (cmp != 0) return cmp;
      i++;
      j++;
    }
  }
  return (aLower.length - i).compareTo(bLower.length - j);
}

bool _isDigit(String char) => char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39;
