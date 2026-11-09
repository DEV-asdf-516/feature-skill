import java.util.List;

public interface Db {
  List<Order> query(String sql);
}
