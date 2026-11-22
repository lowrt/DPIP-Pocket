import 'package:dpip/core/geo/device_location_reporter.dart';
import 'package:dpip/core/geo/location_api.dart';
import 'package:dpip/core/geo/location_service.dart'
    show GpsFix, LocationService;
import 'package:dpip/core/geo/town.dart';
import 'package:dpip/core/geo/town_directory.dart';
import 'package:dpip/core/notifications/notification_service.dart';
import 'package:dpip/core/logging/log.dart';
import 'package:dpip/core/platform/background_location.dart';
import 'package:dpip/core/settings/setting_keys.dart';
import 'package:dpip/core/settings/settings_store.dart';
import 'package:flutter/foundation.dart';

/// The optional fixed township used by push targeting. It is deliberately
/// separate from RegionStore: a notification preference must never pretend
/// that the phone's physical GPS position changed.
class ManualNotificationLocation extends ChangeNotifier {
  ManualNotificationLocation({
    required SettingsStore settings,
    required TownDirectory towns,
    required LocationService location,
    required DeviceLocationReporter reporter,
    required BackgroundLocationService background,
    required LocationApi api,
    required NotificationService notifications,
    required int platform,
    required String version,
    required Future<void> Function() recordSuccess,
  }) : _settings = settings,
       _towns = towns,
       _location = location,
       _reporter = reporter,
       _background = background,
       _api = api,
       _notifications = notifications,
       _platform = platform,
       _version = version,
       _recordSuccess = recordSuccess,
       _townCode = settings.getString(SettingKeys.manualNotificationTownCode);

  final SettingsStore _settings;
  final TownDirectory _towns;
  final LocationService _location;
  final DeviceLocationReporter _reporter;
  final BackgroundLocationService _background;
  final LocationApi _api;
  final NotificationService _notifications;
  final int _platform;
  final String _version;
  final Future<void> Function() _recordSuccess;

  String? _townCode;
  bool _saving = false;

  Town? get town => _towns.byCode(_townCode);
  bool get isManual => _townCode != null;
  bool get isSaving => _saving;

  /// GPS fallback used by DeviceRegistration. A selected township's centroid
  /// is intentionally used instead of requiring a device GPS fix.
  Future<GpsFix?> resolveFix() async {
    final selected = town;
    if (_townCode != null) {
      if (selected == null) return null;
      return (lat: selected.lat, lng: selected.lng);
    }
    if (_settings.getBool(SettingKeys.gpsEnabled) == false) return null;
    return _location.currentFix();
  }

  Future<void> select(Town selected) async {
    if (_saving || selected.code == _townCode) return;
    _saving = true;
    notifyListeners();
    try {
      // Switch the upload gate first. GPS fixes continue feeding the Home
      // location, but no new automatic coordinate can replace this override.
      await _settings.setString(
        SettingKeys.manualNotificationTownCode,
        selected.code,
      );
      _townCode = selected.code;
      notifyListeners();
      await _background.stop();
      await _reporter.waitForReports();

      final token = _notifications.token;
      if (token == null) {
        // If the token arrives later, force DeviceRegistration to publish the
        // selected centroid even when the previous token was recently reported.
        await _settings.remove(SettingKeys.registeredTokenHash);
      } else {
        await _api.updateDeviceLocation(
          platform: _platform,
          token: token,
          version: _version,
          lat: selected.lat,
          lng: selected.lng,
        );
        await _recordSuccess();
      }
    } catch (error, stackTrace) {
      await _settings.remove(SettingKeys.registeredTokenHash);
      Log.handle(error, stackTrace, 'manual notification location');
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  /// Removes the override and restores the normal GPS reporting paths.
  Future<void> clear() async {
    if (_saving || _townCode == null) return;
    _saving = true;
    notifyListeners();
    try {
      await _settings.remove(SettingKeys.manualNotificationTownCode);
      _townCode = null;
      notifyListeners();

      final gpsEnabled = _settings.getBool(SettingKeys.gpsEnabled) ?? true;
      final token = _notifications.token;
      final fix = gpsEnabled ? await _location.currentFix() : null;
      final stillGpsEnabled = _settings.getBool(SettingKeys.gpsEnabled) ?? true;
      if (token != null && fix != null && stillGpsEnabled) {
        try {
          await _api.updateDeviceLocation(
            platform: _platform,
            token: token,
            version: _version,
            lat: fix.lat,
            lng: fix.lng,
          );
          await _recordSuccess();
        } catch (error, stackTrace) {
          await _settings.remove(SettingKeys.registeredTokenHash);
          Log.handle(error, stackTrace, 'restore GPS notification location');
        }
      } else {
        await _settings.remove(SettingKeys.registeredTokenHash);
      }
      final gpsStillEnabled = _settings.getBool(SettingKeys.gpsEnabled) ?? true;
      if (gpsStillEnabled && await _location.granted()) _reporter.start();
      if (gpsStillEnabled && token != null && await _location.backgroundGranted()) {
        await _background.start(token);
      }
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    super.dispose();
  }
}
