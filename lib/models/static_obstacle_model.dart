import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/risk_evaluator_config.dart';

/// 固定区域の用途。危険区域の用途を保持しておくことで、
/// 旧アプリ由来の「カーブ」「逆走注意」を通常の障害物と区別して扱える。
enum StaticObstacleKind {
  generic,
  shore,
  bridge,
  bridgePier,
  island,
  driftwood,
  pile,
  curve,
  reverse,
  testZone;

  static StaticObstacleKind fromJson(String? value) {
    return StaticObstacleKind.values.firstWhere(
      (kind) => kind.name == value,
      orElse: () => StaticObstacleKind.generic,
    );
  }

  bool get isEntryGuidance => this == curve || this == reverse;

  /// 区域の外側で注意を出す既定の追加距離 [m]。
  ///
  /// 帰結の大きさで分ける。岸は常に近くを走るため最小、水面下で見えない
  /// 流木は最大。個別の上書きは [StaticObstacle.proximityCautionDistanceMeters]。
  double get defaultProximityCautionMeters {
    switch (this) {
      case StaticObstacleKind.shore:
        return shoreProximityCautionDistanceMeters;
      case StaticObstacleKind.bridge:
        return bridgeProximityCautionDistanceMeters;
      case StaticObstacleKind.bridgePier:
        return bridgePierProximityCautionDistanceMeters;
      case StaticObstacleKind.island:
        return islandProximityCautionDistanceMeters;
      case StaticObstacleKind.driftwood:
        return driftwoodProximityCautionDistanceMeters;
      case StaticObstacleKind.pile:
        // 杭は流木と同じく水面下・視認しづらく、局所的な衝突帰結が大きい。
        return driftwoodProximityCautionDistanceMeters;
      case StaticObstacleKind.testZone:
        return testZoneProximityCautionDistanceMeters;
      case StaticObstacleKind.curve:
      case StaticObstacleKind.reverse:
        return guidanceProximityCautionDistanceMeters;
      case StaticObstacleKind.generic:
        return genericProximityCautionDistanceMeters;
    }
  }

  /// 連続掃引に使う船体領域の横方向クリアランス [m](片側)。
  ///
  /// 掃引領域の横幅は「船体領域の横幅 + 2×この値」になる。
  /// 既定 [defaultStaticSweepClearanceMeters] は排他領域の横幅と全艇種で
  /// 一致するため、岸以外の挙動は従来と変わらない。岸だけ0にするのは
  /// DESIGN_PRINCIPLES 1.4「岸から数mを走るのは正常」に従うため。
  ///
  /// curve/reverse は掃引の対象外(区域進入イベントとして扱う)だが、
  /// 値としては既定を返しておく。
  double get staticSweepClearanceMeters {
    switch (this) {
      case StaticObstacleKind.shore:
        return shoreStaticSweepClearanceMeters;
      case StaticObstacleKind.bridge:
      case StaticObstacleKind.bridgePier:
      case StaticObstacleKind.island:
      case StaticObstacleKind.driftwood:
      case StaticObstacleKind.pile:
      case StaticObstacleKind.testZone:
      case StaticObstacleKind.curve:
      case StaticObstacleKind.reverse:
      case StaticObstacleKind.generic:
        return defaultStaticSweepClearanceMeters;
    }
  }

  /// 静的掃引で、低速時の方位不確かさを横方向へ反映する係数。
  ///
  /// 岸だけは停止・係留・岸際休憩が正常運用なので、艇の実体より広く
  /// 取らない。他艇の領域やbroad-phaseの半径には一切影響しない。
  double get staticSweepLowSpeedLateralInflationFactor {
    return this == StaticObstacleKind.shore
        ? shoreStaticSweepLowSpeedLateralInflationFactor
        : defaultStaticSweepLowSpeedLateralInflationFactor;
  }

  String get displayLabel {
    switch (this) {
      case StaticObstacleKind.curve:
        return 'カーブ';
      case StaticObstacleKind.reverse:
        return '逆走注意区域';
      case StaticObstacleKind.testZone:
        return 'テスト区域';
      case StaticObstacleKind.shore:
        return '岸';
      case StaticObstacleKind.bridge:
        return '橋';
      case StaticObstacleKind.bridgePier:
        return '橋脚';
      case StaticObstacleKind.island:
        return '中州';
      case StaticObstacleKind.driftwood:
        return '流木';
      case StaticObstacleKind.pile:
        return '杭';
      case StaticObstacleKind.generic:
        return '危険区域';
    }
  }

  String get spokenLabel {
    switch (this) {
      case StaticObstacleKind.curve:
        return 'カーブ';
      case StaticObstacleKind.reverse:
        return '逆走注意';
      case StaticObstacleKind.testZone:
        return 'テスト区域';
      case StaticObstacleKind.shore:
        return '岸';
      case StaticObstacleKind.bridge:
        return '橋';
      case StaticObstacleKind.bridgePier:
        return '橋脚';
      case StaticObstacleKind.island:
        return '島';
      case StaticObstacleKind.driftwood:
        return '流木';
      case StaticObstacleKind.pile:
        return '杭';
      case StaticObstacleKind.generic:
        return '危険区域';
    }
  }
}

class StaticObstacle {
  final String id;

  /// 同梱プリセット上の元ID。
  ///
  /// 1本の基準線から複数の矩形が生成される場合も同じ値を持ち、
  /// 現地校正では障害物全体を一括して移動する。
  final String? sourceId;

  /// 橋脚だけが持つ親の橋のID。橋脚群の警告集約に使う。
  final String? bridgeId;

  /// 危険区域の名前(任意)。プリセットデータの重複取り込み防止にも使用する。
  final String? name;
  final List<LatLng> points;

  /// アプリに同梱する固定危険区域かどうか。
  /// 固定区域は端末内データのため、編集画面から削除できない。
  final bool isDefault;

  /// 区域の外側で注意を出す追加距離[m]の**上書き**。
  ///
  /// nullなら [StaticObstacleKind.defaultProximityCautionMeters] を使う。
  /// 警告そのものを止めたい場合はこの値を0にせず、[isWarningEnabled] を
  /// falseにすること(データ調整と機能停止を混同しないため)。
  final double? proximityCautionDistanceMeters;

  /// この区域で実際に使う近接注意距離 [m]。
  double get effectiveProximityCautionMeters =>
      proximityCautionDistanceMeters ?? kind.defaultProximityCautionMeters;

  /// 区域の用途。未指定の臨時区域はgenericとして扱う。
  final StaticObstacleKind kind;

  /// この区域で使う警告音。nullの場合はkindごとの標準音を使う。
  /// assets/からの相対パス(例: audio/bridge_warning.mp3)を保持する。
  final String? warningAudioAsset;

  /// Firestoreで共有される臨時危険区域かどうか。
  final bool isTemporary;

  /// 円形の臨時危険区域を再編集するための中心と半径。
  /// 固定ポリゴンや旧形式の臨時区域ではnullになる。
  final LatLng? circleCenter;
  final double? circleRadiusMeters;

  /// falseなら地図には表示するが、衝突判定・音声・画面警告の対象にしない。
  /// 臨時危険区域は常にtrueで作成する。
  final bool isWarningEnabled;

  /// Firestoreの変形値で更新できる永続障害物かどうか。
  final bool isManaged;

  StaticObstacle({
    required this.id,
    required this.points,
    this.sourceId,
    this.bridgeId,
    this.name,
    this.isDefault = false,
    this.proximityCautionDistanceMeters,
    this.kind = StaticObstacleKind.generic,
    this.warningAudioAsset,
    this.isTemporary = false,
    this.circleCenter,
    this.circleRadiusMeters,
    this.isWarningEnabled = true,
    this.isManaged = false,
  });

  Map<String, dynamic> toJson() {
    return {
      if (sourceId != null) "sourceId": sourceId,
      if (bridgeId != null) "bridgeId": bridgeId,
      if (name != null) "name": name,
      if (kind != StaticObstacleKind.generic) "kind": kind.name,
      if (warningAudioAsset != null) "warningAudio": warningAudioAsset,
      "points": points
          .map((point) => GeoPoint(point.latitude, point.longitude))
          .toList(),
    };
  }
}
