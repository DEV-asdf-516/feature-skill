import java.util.ArrayList;
import java.util.List;

public class OrderService {
  private final OrderRepository repo;
  public OrderService(OrderRepository repo) { this.repo = repo; }

  public Order get(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("order " + id));
  }

  public List<String> statuses(List<Long> ids) {
    List<String> result = new ArrayList<>();
    for (Long id : ids) {
      Order order = repo.findById(id).orElseThrow(() -> new NotFoundException("order " + id));
      result.add(order.status());
    }
    return result;
  }
}
