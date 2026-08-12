import 'replay_fault_injection.dart';

/// Deterministic low-discrepancy-style search recipes. The score is only a
/// search guide; callers must apply Stage 1's lexicographic acceptance rules.
Iterable<FaultRecipe> generateDifferenceSearchRecipes(
    {int count = 64, int seed = 20260806}) sync* {
  for (var index = 1; index <= count; index++) {
    double vanDerCorput(int value, int base) {
      var fraction = 0.0;
      var denominator = 1.0;
      while (value > 0) {
        denominator *= base;
        fraction += (value % base) / denominator;
        value ~/= base;
      }
      return fraction;
    }

    final dropout = 1 + (vanDerCorput(index, 2) * 10).round();
    final delay = .3 + vanDerCorput(index, 3) * 2.7;
    final bias = 5 + vanDerCorput(index, 5) * 15;
    yield FaultRecipe(seed: seed + index, transforms: [
      {'id': 'drop_burst', 'atSec': 60 + index, 'durationSec': dropout},
      {'id': 'batch_delivery', 'batchSize': 2 + index % 4},
      {'id': 'delivery_delay', 'delaySec': delay},
      {'id': 'bias_ramp', 'meters': bias},
    ]);
  }
}
