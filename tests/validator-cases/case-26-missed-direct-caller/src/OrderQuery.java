import java.util.List;

public class OrderQuery {
  private final Db db;
  public OrderQuery(Db db) { this.db = db; }

  public List<Order> selectOrders() {
    return db.query("SELECT id, stage, archived FROM order ORDER BY id");
  }
}
