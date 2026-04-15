import 'dart:io' show Platform;

String getPlatformName() {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return 'Unknown';
}

String getDeviceTypeFromPlatform() {
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return 'Desktop';
  }
  if (Platform.isAndroid || Platform.isIOS) {
    return 'Mobile';
  }
  return 'Unknown';
}
