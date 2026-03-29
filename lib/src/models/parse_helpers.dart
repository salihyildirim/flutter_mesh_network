/// Safely parses an enum value from either an int index or a String name.
///
/// Returns [fallback] if the value is out of range, unrecognized, or null.
/// This handles both wire-format (String name) and legacy/database (int index).
T parseEnum<T extends Enum>(dynamic raw, List<T> values, T fallback) {
  if (raw is int) {
    return (raw >= 0 && raw < values.length) ? values[raw] : fallback;
  }
  if (raw is String) {
    for (final v in values) {
      if (v.name == raw) return v;
    }
  }
  return fallback;
}
