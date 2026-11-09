public interface OrderRepository {
  String noteOf(long orderId);
  void updateNote(long orderId, String note);
}
