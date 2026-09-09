import java.util.List;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

public class TagMergerTest {
  private final TagMerger merger = new TagMerger();

  @Test void normalize_trims() {
    assertEquals("java", merger.normalize("  java "));
  }

  @Test void missing_returnsIncomingNotInExisting() {
    assertEquals(List.of("c", "d"), merger.missing(List.of("a", "b"), List.of("b", "c", "a", "d")));
  }

  @Test void missing_emptyIncoming_returnsEmpty() {
    assertEquals(List.of(), merger.missing(List.of("a", "b"), List.of()));
  }
}
