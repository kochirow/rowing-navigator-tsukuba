import 'package:flutter_test/flutter_test.dart';
import 'package:rowing_navigator/config/boat_config.dart';
import 'package:rowing_navigator/types/boat_type.dart';

void main() {
  test('保存された艇種名を画面用の表記にする', () {
    expect(boatTypeDisplayLabel('r_1x'), '1x');
    expect(boatTypeDisplayLabel('r_2x'), '2x');
    expect(boatTypeDisplayLabel('r_4x'), '4x');
    expect(boatTypeDisplayLabel('r_8p'), '8+');
  });

  test('列挙に無い古い名前は数字から推定し、推定できなければそのまま返す', () {
    expect(boatTypeDisplayLabel('8+'), '8+');
    expect(boatTypeDisplayLabel('1x'), '1x');
    expect(boatTypeDisplayLabel(''), '');
    expect(boatTypeDisplayLabel('カヌー'), 'カヌー');
  });

  test('表記は航行開始シートの艇種ボタン(BoatConfig.label)と一致する', () {
    for (final config in boatConfigs.allConfigs) {
      expect(config.type.displayLabel, config.label);
    }
  });
}
