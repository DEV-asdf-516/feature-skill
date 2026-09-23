public class Classifier {
  public boolean accepts(Item item) {
    return item.weight() > 0;
  }
}
