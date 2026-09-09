import java.util.ArrayList;
import java.util.List;

public class TagMerger {
  public String normalize(String tag) {
    return tag.trim();
  }

  public List<String> missing(List<String> existing, List<String> incoming) {
    List<String> result = new ArrayList<>();
    for (String tag : incoming) {
      if (!existing.contains(tag)) {
        result.add(tag);
      }
    }
    return result;
  }
}
