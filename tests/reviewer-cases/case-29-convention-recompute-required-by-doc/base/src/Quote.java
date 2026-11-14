public class Quote {
  private final long id;
  private final String title;
  private final long amount;
  private final String dueDate;
  public Quote(long id, String title, long amount, String dueDate) { this.id = id; this.title = title; this.amount = amount; this.dueDate = dueDate; }
  public long id() { return id; }
  public String title() { return title; }
  public long amount() { return amount; }
  public String dueDate() { return dueDate; }
  public Quote applied(QuoteUpdate update) { return new Quote(id, update.title(), update.amount(), update.dueDate()); }
}
