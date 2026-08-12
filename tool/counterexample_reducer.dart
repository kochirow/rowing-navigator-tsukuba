import 'replay_fault_injection.dart';

/// Delta debugging for a fault recipe. Callers provide the actual safety
/// predicate, which keeps the reducer independent of a particular evaluator.
class CounterexampleReducer {
  Future<FaultRecipe> reduce(
    FaultRecipe failingRecipe,
    Future<bool> Function(FaultRecipe recipe) stillFails,
  ) async {
    var transforms = [...failingRecipe.transforms];
    for (var index = 0; index < transforms.length;) {
      final candidate = FaultRecipe(
        seed: failingRecipe.seed,
        transforms: [...transforms]..removeAt(index),
      );
      if (await stillFails(candidate)) {
        transforms = candidate.transforms;
      } else {
        index++;
      }
    }
    return FaultRecipe(seed: failingRecipe.seed, transforms: transforms);
  }
}
