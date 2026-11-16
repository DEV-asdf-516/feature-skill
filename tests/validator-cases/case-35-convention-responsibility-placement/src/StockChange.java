public record StockChange(String sku, Type type, int quantity) {
  public enum Type { IN, OUT }
}
