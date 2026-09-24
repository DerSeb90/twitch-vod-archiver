// Platform-specific update service: real implementation on Android/Windows,
// a stub for the web build (the web app is updated with the server image).
export 'update_service_stub.dart' if (dart.library.io) 'update_service_io.dart';
