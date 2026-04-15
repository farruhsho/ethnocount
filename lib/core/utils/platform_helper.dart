import 'platform_helper_stub.dart'
    if (dart.library.io) 'platform_helper_io.dart' as impl;

String getPlatformName() => impl.getPlatformName();

String getDeviceTypeFromPlatform() => impl.getDeviceTypeFromPlatform();
