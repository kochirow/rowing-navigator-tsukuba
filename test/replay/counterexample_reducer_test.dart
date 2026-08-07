import 'package:flutter_test/flutter_test.dart';

import '../../tool/counterexample_reducer.dart';
import '../../tool/replay_difference_search.dart';
import '../../tool/replay_fault_injection.dart';

void main() {
  test('反例を失敗に必要な変換だけへ縮める', () async {
    const recipe = FaultRecipe(seed: 1, transforms: [
      {'id': 'drop_burst', 'durationSec': 10},
      {'id': 'delivery_delay', 'delaySec': 1},
    ]);
    final reduced = await CounterexampleReducer().reduce(
      recipe,
      (candidate) async => candidate.transforms.any(
          (item) => item['id'] == 'drop_burst' && item['durationSec'] == 10),
    );
    expect(reduced.transforms, hasLength(1));
    expect(reduced.transforms.single['id'], 'drop_burst');
  });

  test('差分探索はseed再現可能な複数の組合せを生成する', () {
    final first = generateDifferenceSearchRecipes(count: 8)
        .map((r) => r.toCanonicalJson())
        .toList();
    final second = generateDifferenceSearchRecipes(count: 8)
        .map((r) => r.toCanonicalJson())
        .toList();
    expect(first, second);
    expect(first.toSet(), hasLength(8));
  });
}
