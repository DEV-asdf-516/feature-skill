import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

public class TagMergerTest {
  private final TagMerger merger = new TagMerger();

  @Test void normalize_trims() {
    assertEquals("java", merger.normalize("  java "));
  }
}
