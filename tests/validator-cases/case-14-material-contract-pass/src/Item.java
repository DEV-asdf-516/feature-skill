public final class Item {
  private final long id;
  private final int weight;
  public Item(long id, int weight) { this.id = id; this.weight = weight; }
  public long id() { return id; }
  public int weight() { return weight; }
}
