/// Lenient coercion of decoded JSON values. Never throws; a missing or
/// wrong-typed value becomes the empty/zero/null form noted per helper.
library;

/// `null` → '', anything else → its string form.
String asStr(dynamic v) => v == null ? '' : '$v';

/// Numbers truncate, numeric strings parse; anything else is null.
int? asIntOrNull(dynamic v) => v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) : null));

/// [asIntOrNull], or 0.
int asInt(dynamic v) => asIntOrNull(v) ?? 0;

/// A number as a double, else null.
double? asDouble(dynamic v) => v is num ? v.toDouble() : null;

/// A list's elements as strings; anything that is not a list is empty.
List<String> asStrings(dynamic v) => v is List ? [for (final e in v) '$e'] : const [];
