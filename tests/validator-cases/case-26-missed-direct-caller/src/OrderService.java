import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

public class OrderService {
  private final OrderQuery query;
  public OrderService(OrderQuery query) { this.query = query; }

  public List<Order> findAll() { return query.selectOrders(); }

  public Map<String, List<Order>> findAllSummary() {
    return query.selectOrders().stream().collect(Collectors.groupingBy(Order::stage));
  }
}
