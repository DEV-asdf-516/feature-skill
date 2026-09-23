import java.util.List;

public class Batch {
  private final Classifier classifier;
  public Batch(Classifier classifier) { this.classifier = classifier; }
  public int size(List<Item> items) { return items.size(); }
}
