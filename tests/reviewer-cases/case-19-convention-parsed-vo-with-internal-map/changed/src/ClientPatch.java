public final class ClientPatch {
  private final java.util.Map<String, String> values;
  private ClientPatch(java.util.Map<String, String> values) { this.values = java.util.Collections.unmodifiableMap(new java.util.LinkedHashMap<>(values)); }
  public static ClientPatch parse(ClientUpdateRequest request) {
    if (request.getName() == null || request.getName().isBlank()) {
      throw new IllegalArgumentException("name");
    }
    if (request.getPhone() == null || !request.getPhone().matches("\\d{10,11}")) {
      throw new IllegalArgumentException("phone");
    }
    java.util.Map<String, String> values = new java.util.LinkedHashMap<>();
    values.put("name", request.getName());
    values.put("phone", request.getPhone());
    return new ClientPatch(values);
  }
  public String name() { return values.get("name"); }
  public String phone() { return values.get("phone"); }
}
