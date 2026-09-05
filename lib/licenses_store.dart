import 'package:shared_preferences/shared_preferences.dart';

const _kLicenses = 'licenses_json';

/// Plain prefs — flutter_secure_storage hangs forever on some Android builds.
Future<String?> readLicensesJson() async {
  final p = await SharedPreferences.getInstance();
  return p.getString(_kLicenses);
}

Future<void> writeLicensesJson(String raw) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_kLicenses, raw);
}
