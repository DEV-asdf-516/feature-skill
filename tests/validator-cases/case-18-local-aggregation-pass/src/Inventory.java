import java.util.List;

public class Inventory {
  private final Stock stock;
  public Inventory(Stock stock) { this.stock = stock; }
  public int onHand(String sku) { return stock.onHand(sku); }
}
