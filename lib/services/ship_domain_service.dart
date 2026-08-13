import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rowing_navigator/types/ship_domain_type.dart';
import 'dart:math';

import '../config/boat_config.dart';
import '../config/risk_evaluator_config.dart';
import '../models/boat_model.dart';
import '../types/boat_type.dart';
import '../utils/geo_math.dart';

class ShipDomainParam {
  final double h;
  final double w;
  final double s;

  ShipDomainParam({
    required this.h,
    required this.w,
    required this.s,
  });
}

class ShipDomains {
  final Polygon shipBodyDomain;
  final Polygon exclusiveDomain;

  List<Polygon> get allDomains => [shipBodyDomain, exclusiveDomain];

  ShipDomains({
    required this.shipBodyDomain,
    required this.exclusiveDomain,
  });
}

class ShipDomainService {
// 一つの船舶領域の全頂点の地理座標を求める関数
  List<LatLng> getShipDomainPoints(LatLng center, double heading, double height,
      double width, double sideHeight) {
    double halfHeight = height / 2;
    double halfWidth = width / 2;
    double halfSideHeight = sideHeight / 2;

    // 船舶領域の頂点のオフセット（距離と方位角）を定義
    List<Map<String, double>> offsets = [
      {"distance": halfHeight, "angle": heading}, // 1
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading + 90 - atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 2
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading + 90 + atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 3
      {"distance": halfHeight, "angle": heading + 180}, // 4
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading - 90 - atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 5
      {
        "distance": sqrt(pow(halfSideHeight, 2) + pow(halfWidth, 2)),
        "angle": heading - 90 + atan2(halfSideHeight, halfWidth) * 180 / pi
      }, // 6
    ];

    List<LatLng> vertices = [];
    for (var offset in offsets) {
      LatLng vertex =
          computeOffset(center, offset["distance"]!, offset["angle"]!);
      vertices.add(vertex);
    }

    return vertices;
  }

  /// 艇の進行方位を信頼してよい速度かどうか。
  ///
  /// 低速時の course-over-ground は不安定で、実装は最後の進行方位を保持する。
  /// 停止して回頭する場面(折り返し・整列)では、この保持した方位が実際の
  /// 艇の向きと最大90度ずれる。
  ///
  /// なお、船体領域の六角形は中心について点対称なので、方位が180度ずれても
  /// 形は変わらない。バック(逆漕ぎ)で course-over-ground が艇首と逆向きに
  /// なっても領域は正しく、特別な扱いは要らない。問題になるのは90度前後の
  /// 誤差だけである。
  static bool headingIsReliable(Boat boat) =>
      boat.speed.isFinite &&
      boat.speed >= shipDomainReliableHeadingSpeedMetersPerSecond;

  /// 方位が信頼できないときに横方向へ加える拡張量 [m]。
  ///
  /// 艇長の半分 × sin(想定方位誤差) が、90度誤差で痩せる幅の目安。
  /// 狭い川で過剰警告にならないよう上限で頭打ちにする。
  static double lowSpeedLateralInflationMeters(ShipDomainParam param) {
    final halfLength = param.h / 2;
    final uncertainty = sin(
      shipDomainLowSpeedHeadingUncertaintyDegrees * pi / 180,
    );
    return min(
      shipDomainMaxLowSpeedLateralInflationMeters,
      halfLength * uncertainty,
    );
  }

  /// この艇に実際に適用される領域パラメータを返す。
  ///
  /// broad-phase の到達半径を求める側が、低速時の横方向拡張を見落として
  /// 「届かない」と判定すると、拡張したはずの領域が触れる障害物を
  /// 評価前に捨ててしまう。半径計算は必ずこの実効値から求めること。
  static ShipDomainParams effectiveParamsFor(
    Boat boat, {
    bool? headingReliable,
  }) {
    final params = boatConfigs.byBoatType(boat.boatType).shipDomainParams;
    if (headingReliable ?? headingIsReliable(boat)) return params;
    return ShipDomainParams(
      shipBodyParam: _widenForHeadingUncertainty(params.shipBodyParam),
      exclusiveParam: _widenForHeadingUncertainty(params.exclusiveParam),
    );
  }

  /// 実効的な排他領域の外接円半径 [m]。低速時の横拡張を含む。
  static double effectiveExclusiveRadius(
    Boat boat, {
    bool? headingReliable,
    double positionSetBoundingRadiusMeters = 0,
  }) =>
      boundingRadius(
        effectiveParamsFor(boat, headingReliable: headingReliable)
            .exclusiveParam,
      ) +
      (positionSetBoundingRadiusMeters.isFinite &&
              positionSetBoundingRadiusMeters > 0
          ? positionSetBoundingRadiusMeters
          : 0);

  /// 艇の船体領域・排他領域を返す。
  ///
  /// [inflateMeters] を指定すると、両領域を全方向におよそ指定メートル
  /// 分だけ拡張する。GPS誤差やデータの古さによる位置不確実性を
  /// 衝突判定に反映するために使う(判定専用。地図描画では0のまま)。
  ///
  /// [headingReliable] を省略すると [headingIsReliable] で自動判定する。
  /// 信頼できない場合は横方向だけを有界に広げ、方位誤差で領域が痩せて
  /// 警告が漏れることを防ぐ。地図描画では `headingReliable: true` を渡し、
  /// 表示形状を変えないこと。
  ShipDomains getShipDomains(
    Boat boat, {
    double inflateMeters = 0,
    double lateralInflateMeters = 0,
    bool? headingReliable,
  }) {
    BoatType boatType = boat.boatType;
    ShipDomainParam shipBodyParam; // 船体領域
    ShipDomainParam exclusiveParam; // 排他領域

    switch (boatType) {
      case BoatType.r_1x:
        shipBodyParam = boatConfigs.r_1x_.shipDomainParams.shipBodyParam;
        exclusiveParam = boatConfigs.r_1x_.shipDomainParams.exclusiveParam;
        break;
      case BoatType.r_2x:
        shipBodyParam = boatConfigs.r_2x_.shipDomainParams.shipBodyParam;
        exclusiveParam = boatConfigs.r_2x_.shipDomainParams.exclusiveParam;
        break;
      case BoatType.r_4x:
        shipBodyParam = boatConfigs.r_4x_.shipDomainParams.shipBodyParam;
        exclusiveParam = boatConfigs.r_4x_.shipDomainParams.exclusiveParam;
        break;
      case BoatType.r_8p:
        shipBodyParam = boatConfigs.r_8p_.shipDomainParams.shipBodyParam;
        exclusiveParam = boatConfigs.r_8p_.shipDomainParams.exclusiveParam;
        break;
    }
    if (!(headingReliable ?? headingIsReliable(boat))) {
      shipBodyParam = _widenForHeadingUncertainty(shipBodyParam);
      exclusiveParam = _widenForHeadingUncertainty(exclusiveParam);
    }
    if (inflateMeters > 0 && inflateMeters.isFinite) {
      shipBodyParam = _inflate(shipBodyParam, inflateMeters);
      exclusiveParam = _inflate(exclusiveParam, inflateMeters);
    }
    if (lateralInflateMeters > 0 && lateralInflateMeters.isFinite) {
      shipBodyParam = _inflateLateral(shipBodyParam, lateralInflateMeters);
      exclusiveParam = _inflateLateral(exclusiveParam, lateralInflateMeters);
    }
    final shipDomains = ShipDomains(
      shipBodyDomain: Polygon(
        polygonId: PolygonId(ShipDomainType.shipBodyDomain.value),
        points: getShipDomainPoints(LatLng(boat.lat, boat.lng), boat.heading,
            shipBodyParam.h, shipBodyParam.w, shipBodyParam.s),
        strokeWidth: 0,
        fillColor: Colors.red.withValues(alpha: 0.5),
      ),
      exclusiveDomain: Polygon(
        polygonId: PolygonId(ShipDomainType.exclusiveDomain.value),
        points: getShipDomainPoints(LatLng(boat.lat, boat.lng), boat.heading,
            exclusiveParam.h, exclusiveParam.w, exclusiveParam.s),
        strokeWidth: 0,
        fillColor: Colors.yellow.withValues(alpha: 0.5),
      ),
    );
    return shipDomains;
  }

  /// 静的危険区域の掃引に使う領域パラメータ。
  ///
  /// 前後方向(h)と s は排他領域のまま、横方向(w)だけ
  /// 「船体領域の横幅 + 2×[clearancePerSideMeters]」にする。
  /// h を変えないので、区域へ向かって進んでいる艇の検知時刻(前方掃引)は
  /// 一切変わらない。減るのは「並走で横に触れる」偽陽性だけである。
  ///
  /// [clearancePerSideMeters] の既定値は
  /// [StaticObstacleKind.staticSweepClearanceMeters] が持つ。1.5m を渡すと
  /// 全艇種で排他領域と完全に一致する(1x/2x/4x: 6.0+3.0=9.0、8+: 7.5+3.0=10.5)。
  ///
  /// **不変条件8**: broad-phase の到達半径には
  /// [effectiveExclusiveRadius](排他領域ベース)を使い続ける。ここで返す
  /// 領域が排他領域より広くなると broad-phase が過小評価になるため、
  /// 横幅は排他領域の横幅で頭打ちにする。設定値の取り違えで
  /// 「触れる区域を評価前に捨てる」警告漏れを作らないための保険。
  ///
  /// **不変条件9**: h も s も排他領域のままなので `s <= h` の凸性は不変。
  static ShipDomainParam staticSweepParam(
    Boat boat, {
    required double clearancePerSideMeters,
    double lowSpeedLateralInflationFactor = 1.0,
    bool? headingReliable,
  }) {
    final params = boatConfigs.byBoatType(boat.boatType).shipDomainParams;
    final exclusive = params.exclusiveParam;
    final clearance =
        clearancePerSideMeters.isFinite && clearancePerSideMeters > 0
            ? clearancePerSideMeters
            : 0.0;
    final param = ShipDomainParam(
      h: exclusive.h,
      w: min(params.shipBodyParam.w + 2 * clearance, exclusive.w),
      s: exclusive.s,
    );
    if (headingReliable ?? headingIsReliable(boat)) return param;
    final factor = lowSpeedLateralInflationFactor.isFinite
        ? lowSpeedLateralInflationFactor.clamp(0.0, 1.0).toDouble()
        : 1.0;
    return _widenForHeadingUncertainty(param, factor: factor);
  }

  /// 静的危険区域の掃引に使う多角形。
  ///
  /// 処理順は [getShipDomains] と完全に揃えてある
  /// (艇種→方位不確かさの横拡張→[inflateMeters] の全方向拡張)。
  Polygon getStaticSweepDomain(
    Boat boat, {
    required double clearancePerSideMeters,
    double lowSpeedLateralInflationFactor = 1.0,
    double inflateMeters = 0,
    double lateralInflateMeters = 0,
    bool? headingReliable,
  }) {
    var param = staticSweepParam(
      boat,
      clearancePerSideMeters: clearancePerSideMeters,
      lowSpeedLateralInflationFactor: lowSpeedLateralInflationFactor,
      headingReliable: headingReliable,
    );
    if (inflateMeters > 0 && inflateMeters.isFinite) {
      param = _inflate(param, inflateMeters);
    }
    if (lateralInflateMeters > 0 && lateralInflateMeters.isFinite) {
      param = _inflateLateral(param, lateralInflateMeters);
    }
    return Polygon(
      polygonId: const PolygonId('staticSweepDomain'),
      points: getShipDomainPoints(
        LatLng(boat.lat, boat.lng),
        boat.heading,
        param.h,
        param.w,
        param.s,
      ),
      strokeWidth: 0,
      fillColor: Colors.orange.withValues(alpha: 0.5),
    );
  }

  /// 領域パラメータを全方向に margin [m] 拡張する
  ShipDomainParam _inflate(ShipDomainParam p, double margin) {
    return ShipDomainParam(
      h: p.h + 2 * margin,
      w: p.w + 2 * margin,
      s: p.s + 2 * margin,
    );
  }

  /// 領域パラメータを横方向だけに margin [m] 拡張する。
  /// 曲率マージンは折れ線弦の横ずれを補う量なので、前後方向へは足さない。
  ShipDomainParam _inflateLateral(ShipDomainParam p, double margin) {
    return ShipDomainParam(h: p.h, w: p.w + 2 * margin, s: p.s);
  }

  /// 方位が信頼できないとき、横方向(幅)だけを広げる。
  /// 長さは広げない。艇の占める面積は方位が変わっても増えないため。
  ///
  /// `s`(六角形の平行辺の長さ = 前後方向の寸法)まで広げると、
  /// 8+ では `s`(26.88m) が `h`(22.9m) を上回って六角形が凹になり、
  /// 実効的な全長が前後に約2mずつ伸びていた。方位誤差 θ で艇が掃く幅を
  /// 補うのは `w` の役目なので、広げるのは `w` だけにする。
  static ShipDomainParam _widenForHeadingUncertainty(
    ShipDomainParam p, {
    double factor = 1.0,
  }) {
    final lateral = lowSpeedLateralInflationMeters(p) * factor;
    return ShipDomainParam(
      h: p.h,
      w: p.w + 2 * lateral,
      s: p.s,
    );
  }

  /// 領域の外接円半径 [m](中心からの最大頂点距離)。
  ///
  /// 六角形の頂点は「船首・船尾方向の h/2」と「側方4点の
  /// sqrt((s/2)² + (w/2)²)」の2種類。`s > h` の艇種(8+など)では側方頂点の
  /// ほうが遠いため、`0.5·sqrt(h² + w²)` だけでは**過小評価になる**。
  /// 到達距離の見積り(broad-phase)と円フォールバックの両方で使うため、
  /// ここを過小評価すると触れる障害物を評価前に捨ててしまう。
  /// 従来値(外接長方形の対角の半分)より小さくならないようにもする。
  /// 円フォールバックの安全余裕を、この修正で減らさないため。
  static double boundingRadius(ShipDomainParam p) {
    final halfLength = p.h / 2;
    final sideVertex = sqrt((p.s / 2) * (p.s / 2) + (p.w / 2) * (p.w / 2));
    final rectangleDiagonal = 0.5 * sqrt(p.h * p.h + p.w * p.w);
    return max(max(halfLength, sideVertex), rectangleDiagonal);
  }
}
