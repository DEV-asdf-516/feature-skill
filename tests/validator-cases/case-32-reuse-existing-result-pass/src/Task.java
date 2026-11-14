public class Task {
  private final long id;
  private final String title;
  private final long amount;
  private final String dueDate;
  public Task(long id, String title, long amount, String dueDate) { this.id = id; this.title = title; this.amount = amount; this.dueDate = dueDate; }
  public long id() { return id; }
  public String title() { return title; }
  public long amount() { return amount; }
  public String dueDate() { return dueDate; }
  public Task applied(TaskUpdate update) { return new Task(id, update.title(), update.amount(), update.dueDate()); }
}
