/// 位置共有に載せる提示状態 `w` の後方互換プロトコル。
///
/// 生成側と送受信モデルが別々の値域を持つと、警告中の
/// 位置write全体がRulesに拒否される。Dart側はここを単一の正本とする。
abstract final class PresentationStateProtocol {
  /// o=他艇, b=橋, p=橋脚, s=岸, i=中州, d=流木, k=杭,
  /// c=カーブ, r=逆走, f=system fault, g=その他。
  static const categoryCodes = <String>{
    'o',
    'b',
    'p',
    's',
    'i',
    'd',
    'k',
    'c',
    'r',
    'f',
    'g',
  };

  static final RegExp _encodedPattern = RegExp(r'^[012][obpsidkcrfg]$');

  static bool isValid(String value) => _encodedPattern.hasMatch(value);
}
