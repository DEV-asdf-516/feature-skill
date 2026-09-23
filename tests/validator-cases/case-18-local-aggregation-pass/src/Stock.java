import java.util.HashMap;
import java.util.Map;

public class Stock {
  private final Map<String, Integer> onHand = new HashMap<>();
  public void add(String sku, int qty) { onHand.merge(sku, qty, Integer::sum); }
  public int onHand(String sku) { return onHand.getOrDefault(sku, 0); }
}
