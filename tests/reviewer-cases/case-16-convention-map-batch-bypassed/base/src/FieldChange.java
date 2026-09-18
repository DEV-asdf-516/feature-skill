public final class FieldChange {
  private final String before;
  private final String after;
  public FieldChange(String before, String after) { this.before = before; this.after = after; }
  public String before() { return before; }
  public String after() { return after; }
}
