public interface StockRepository {
  Stock get(String sku);
  void save(Stock stock);
}
