public final class PriceCalculator {
  private PriceCalculator() {}
  public static long total(Order order) {
    long sum = 0;
    for (Line line : order.lines()) {
      sum += line.priceCents() * line.qty();
    }
    return sum;
  }
}
