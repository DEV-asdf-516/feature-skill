public record StockImportMessage(String sku, Integer quantity) {
  public StockChange toChange() {
    boolean missing = false;
    if (sku == null) {
      missing = true;
    }
    if (quantity == null) {
      missing = true;
    }
    if (missing) {
      throw new IllegalArgumentException("stock import message: required field missing");
    }
    return new StockChange(sku, StockChange.Type.IN, quantity);
  }
}
