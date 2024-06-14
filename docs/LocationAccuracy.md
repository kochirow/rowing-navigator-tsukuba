## LocationAccuracy 列挙型

位置精度の可能な値を表します。

### `lowest`

- **説明**: 位置は iOS で 3000m、Android で 500m 以内の精度です。
- **Android 対応**: [PRIORITY_PASSIVE](https://developers.google.com/android/reference/com/google/android/gms/location/Priority#public-static-final-int-priority_passive)

### `low`

- **説明**: 位置は iOS で 1000m、Android で 500m 以内の精度です。
- **Android 対応**: [PRIORITY_LOW_POWER](https://developers.google.com/android/reference/com/google/android/gms/location/Priority#public-static-final-int-priority_low_power)

### `medium`

- **説明**: 位置は iOS で 100m、Android で 100m から 500m の精度です。
- **Android 対応**: [PRIORITY_BALANCED_POWER_ACCURACY](https://developers.google.com/android/reference/com/google/android/gms/location/Priority#public-static-final-int-priority_balanced_power_accuracy)

### `high`

- **説明**: 位置は iOS で 10m、Android で 0m から 100m の精度です。
- **Android 対応**: [PRIORITY_HIGH_ACCURACY](https://developers.google.com/android/reference/com/google/android/gms/location/Priority#public-static-final-int-priority_high_accuracy)

### `best`

- **説明**: 位置は iOS で約 0m、Android で 0m から 100m の精度です。
- **Android 対応**: [PRIORITY_HIGH_ACCURACY](https://developers.google.com/android/reference/com/google/android/gms/location/Priority#public-static-final-int-priority_high_accuracy)

### `bestForNavigation`

- **説明**: iOS ではナビゲーションに最適化された位置精度で、Android では[LocationAccuracy.best](#best)と同じです。
- **Android 対応**: [PRIORITY_HIGH_ACCURACY](https://developers.google.com/android/reference/com/google/android/gms/location/Priority#public-static-final-int-priority_high_accuracy)

### `reduced`

- **説明**: iOS 14 以降のデバイスで位置精度が低下し、iOS 13 以下および他のすべてのプラットフォームでは[LocationAccuracy.lowest](#lowest)と同じです。
- **Android 対応**: [PRIORITY_PASSIVE](https://developers.google.com/android/reference/com/google/android/gms/location/Priority#public-static-final-int-priority_passive)
