public final class DiffUtil {
  private DiffUtil() {}
  public static java.util.Map<String, FieldChange> diff(java.util.Map<String, String> before, java.util.Map<String, String> after) {
    java.util.Map<String, FieldChange> changes = new java.util.LinkedHashMap<>();
    for (java.util.Map.Entry<String, String> e : after.entrySet()) {
      String old = before.get(e.getKey());
      if (!java.util.Objects.equals(old, e.getValue())) changes.put(e.getKey(), new FieldChange(old, e.getValue()));
    }
    return changes;
  }
}
