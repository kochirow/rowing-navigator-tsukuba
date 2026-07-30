const maxDisplayNameLength = 20;
const fallbackDisplayName = '名前未設定';

String normalizeDisplayName(String value) => value.trim();

String? displayNameValidationError(String value) {
  final normalized = normalizeDisplayName(value);
  if (normalized.isEmpty) return '名前を入力してください。';
  if (normalized.length > maxDisplayNameLength) {
    return '名前は$maxDisplayNameLength文字以内で入力してください。';
  }
  if (normalized.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    return '名前に改行や制御文字は使用できません。';
  }
  return null;
}
