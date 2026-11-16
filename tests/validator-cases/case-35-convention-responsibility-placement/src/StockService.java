public class StockService {
  private final StockRepository repo;
  public StockService(StockRepository repo) { this.repo = repo; }

  public Stock get(String sku) {
    return repo.get(sku);
  }
}
