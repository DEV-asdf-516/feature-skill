import java.util.List;

public class OrderService {
  private final OrderRepository repo;
  public OrderService(OrderRepository repo) { this.repo = repo; }

  public Order get(long id) {
    return repo.findById(id).orElseThrow(() -> new NotFoundException("order " + id));
  }
}
