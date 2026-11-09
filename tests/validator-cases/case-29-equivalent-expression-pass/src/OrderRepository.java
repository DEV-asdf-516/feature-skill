import java.util.List;

public interface OrderRepository {
  java.util.Optional<OrderEntity> findById(long id);
  List<OrderEntity> findRecent(int limit);
}
