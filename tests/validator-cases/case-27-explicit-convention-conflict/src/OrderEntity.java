public class OrderEntity {
  private final long id;
  private final String status;
  private final String internalNote;
  public OrderEntity(long id, String status, String internalNote) { this.id = id; this.status = status; this.internalNote = internalNote; }
  public long id() { return id; }
  public String status() { return status; }
  public String internalNote() { return internalNote; }
}
