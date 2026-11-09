public class OrderNoteService {
  private final OrderRepository orders;
  private final ChangeHistoryRepository history;
  public OrderNoteService(OrderRepository orders, ChangeHistoryRepository history) { this.orders = orders; this.history = history; }

  public void updateNote(long orderId, String note) {
    String before = orders.noteOf(orderId);
    orders.updateNote(orderId, note);
    history.save("ORDER_NOTE", orderId, before, note);
  }
}
